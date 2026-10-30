import SwiftUI
import PhotonsCore

// MARK: - 139 · the luminance range bar
//
// The owner asked for a second way to edit the same two numbers the 下限/上限 rows already own:
//
//   「亮度蒙版要提供范围条，可以手动修改」
//
// It is **not** a second model. The bar reads `LuminanceRangeShape.low/high/lowFeather/highFeather`
// from the document (through `MaskParameters`' write door) and writes them back with `commit: false`
// while the hand moves and `commit: true` on mouse-up — one drag, one history entry. The
// `MaskSliderRow` rows and the eyedropper are the other two entrances to exactly the same fields.
//
// 167 — the axis is the sampler's own HDR axis: OKLab `L` of **unclamped** working-linear light,
// `0…LuminanceRangeShape.hdrMax` (`cbrt(16) = 2.5198`, +4 EV). It is the same quantity
// `s1_5_mask_atlas.metal`'s `luminance_range_alpha` compares, so the bar's ends and the picker's
// value cannot mean different things. The SDR half still names display codes
// (`0 63 127 191 255`) at their own OKLab coordinates; the HDR half names `+1 … +4` EV.

/// One label under the bar. `value` is on the luminance axis (`0…hdrMax`) and `label` is what the
/// user reads — a display code in the SDR half, an EV stop in the HDR half.
public struct MaskRangeBarTick: Equatable, Sendable {
    public let value: Double
    public let label: String

    public init(value: Double, label: String) {
        self.value = value
        self.label = label
    }
}

/// What the hand grabbed. Pure geometry, so the hit test and the drag maths are testable without a
/// window (the SwiftUI view is a thin shell over these functions).
public enum MaskRangeBarHit: Equatable, Sendable {
    case lowHandle
    case highHandle
    case body
    case lowFeather
    case highFeather
}

/// One drag, frozen at mouse-down. Every move is computed from `startShape`/`startX`, never by
/// accumulating deltas into the shape a previous move already changed — that is what keeps a body
/// drag's width from drifting by an ulp per tick.
public struct MaskRangeBarDrag: Equatable, Sendable {
    public let hit: MaskRangeBarHit
    public let startShape: LuminanceRangeShape
    public let startX: Double

    public init(hit: MaskRangeBarHit, startShape: LuminanceRangeShape, startX: Double) {
        self.hit = hit
        self.startShape = startShape
        self.startX = startX
    }
}

public enum MaskRangeBarGeometry {

    /// A handle keeps a hit target of at least this many points even when the selected width is
    /// smaller than 0.002 — otherwise a window dragged to a point could never be grabbed again.
    public static let minimumHitWidth: Double = 10

    /// The bar's axis top. One constant, from Core, never a second literal here.
    public static var axisMax: Double { LuminanceRangeShape.hdrMax }

    /// The ticks the axis draws, in ascending order. The SDR half is the five display codes the
    /// curve card also draws (`CurveAxisTicks.codes`), each at its own OKLab `L`; the HDR half is
    /// `+1 … +4`, at `cbrt(2^stop)` — the same neutral-light fold the kernel reads.
    public static let axisTicks: [MaskRangeBarTick] = {
        let codes = [0, 63, 127, 191, 255].map { code -> MaskRangeBarTick in
            let encoded = Double(code) / 255
            return MaskRangeBarTick(value: OKLabMetric.fromSRGB(encoded, encoded, encoded).L,
                                    label: "\(code)")
        }
        let stops = (1...4).map { stop -> MaskRangeBarTick in
            MaskRangeBarTick(value: cbrt(pow(2.0, Double(stop))), label: "+\(stop)")
        }
        return codes + stops
    }()

    /// Pointer x → document value (`0…hdrMax`).
    public static func value(atX x: Double, width: Double) -> Double {
        guard width > 0 else { return 0 }
        return min(max(x / width, 0), 1) * axisMax
    }

    /// Document value → pointer x. The inverse of `value(atX:width:)`.
    public static func xPosition(forValue value: Double, width: Double) -> Double {
        guard width > 0 else { return 0 }
        return min(max(value / axisMax, 0), 1) * width
    }

    /// The bar's two handles, in document units (the value the engine sees, not "percent of bar").
    public static func handles(for shape: LuminanceRangeShape) -> (low: Double, high: Double) {
        (shape.low, shape.high)
    }

    public static func hit(atX x: Double, width: Double, shape: LuminanceRangeShape) -> MaskRangeBarHit? {
        guard width > 0 else { return nil }
        let lowX = xPosition(forValue: shape.low, width: width)
        let highX = xPosition(forValue: shape.high, width: width)
        let radius = max(minimumHitWidth / 2, 0.5)
        let dLow = abs(x - lowX)
        let dHigh = abs(x - highX)

        if dLow <= radius || dHigh <= radius {
            if dLow < dHigh { return .lowHandle }
            if dHigh < dLow { return .highHandle }
            // The two handles are on the same spot (width 0): the halves of the shared hit target
            // still reach both, so one can be pulled away from the other.
            return x < lowX ? .lowHandle : .highHandle
        }

        let lower = min(lowX, highX)
        let upper = max(lowX, highX)
        if x > lower && x < upper { return .body }

        let lowOnLeft = shape.low <= shape.high
        if x <= lower {
            let feather = (lowOnLeft ? shape.lowFeather : shape.highFeather) / axisMax * width
            if x >= lower - feather { return lowOnLeft ? .lowFeather : .highFeather }
        } else if x >= upper {
            let feather = (lowOnLeft ? shape.highFeather : shape.lowFeather) / axisMax * width
            if x <= upper + feather { return lowOnLeft ? .highFeather : .lowFeather }
        }
        return nil
    }

    public static func begin(atX x: Double, width: Double,
                             shape: LuminanceRangeShape) -> MaskRangeBarDrag? {
        guard let hit = hit(atX: x, width: width, shape: shape) else { return nil }
        return MaskRangeBarDrag(hit: hit, startShape: shape, startX: x)
    }

    /// The shape one drag position means. Handles and feathers use the absolute pointer position;
    /// the body uses the pointer's displacement from mouse-down so the width is preserved.
    public static func shape(for drag: MaskRangeBarDrag, atX x: Double,
                             width: Double) -> LuminanceRangeShape {
        var next = drag.startShape
        let v = value(atX: x, width: width)
        switch drag.hit {
        case .lowHandle:
            next.low = v
        case .highHandle:
            next.high = v
        case .lowFeather:
            next.lowFeather = min(max(abs(v - drag.startShape.low), 0), axisMax)
        case .highFeather:
            next.highFeather = min(max(abs(v - drag.startShape.high), 0), axisMax)
        case .body:
            next = translated(drag.startShape,
                              by: (x - drag.startX) / max(width, 1e-9) * axisMax)
        }
        return next
    }

    /// Translate both bounds by `delta`, preserving `high − low` exactly where neither end is clamped.
    ///
    /// `exactHigh` nudges the high bound by at most a few ULP until `high − low` reproduces the
    /// width bit for bit. Clamping one end means the window really is narrower (there is nowhere
    /// left to go); it is not re-normalised back to the old width.
    public static func translated(_ shape: LuminanceRangeShape,
                                  by delta: Double) -> LuminanceRangeShape {
        var next = shape
        let top = axisMax
        let w = shape.high - shape.low
        let proposedLow = shape.low + delta
        let proposedHigh = shape.high + delta
        if proposedLow < 0 {
            next.low = 0
            next.high = min(top, max(0, w))
        } else if proposedHigh > top {
            let pair = exactPair(high: top, width: w)
            next.low = max(0, pair.low)
            next.high = pair.high
        } else {
            // Derive low from the translated high (not the other way round): for the common
            // fractional widths this reproduces `high − low == w` bit for bit, and `exactPair`
            // nudges by a ULP where the subtraction rounds the other way.
            let pair = exactPair(high: proposedHigh, width: w)
            next.low = pair.low
            next.high = pair.high
        }
        return next
    }

    /// Double-click on a handle: that end goes back to the Core default. A feather handle resets its
    /// own feather. The other end is untouched.
    public static func resetting(_ hit: MaskRangeBarHit,
                                 in shape: LuminanceRangeShape) -> LuminanceRangeShape {
        var next = shape
        switch hit {
        case .lowHandle:
            next.low = LuminanceRangeShape.default.low
        case .highHandle:
            next.high = LuminanceRangeShape.default.high
        case .lowFeather:
            next.lowFeather = LuminanceRangeShape.default.lowFeather
        case .highFeather:
            next.highFeather = LuminanceRangeShape.default.highFeather
        case .body:
            return shape
        }
        return next
    }

    /// `high` fixed, `low = high − width`, with the subtraction nudged by at most a few ULP until
    /// `high − low` reproduces `width` exactly. If no representable neighbour can (the subtraction
    /// is not surjective), the ordinary `high − width` is returned — a one-ULP width is preferable
    /// to moving the bound the hand is holding.
    private static func exactPair(high: Double, width: Double) -> (low: Double, high: Double) {
        var h = high
        for _ in 0..<32 {
            let l = h - width
            let actual = h - l
            if actual == width { return (l, h) }
            h = actual < width ? h.nextUp : h.nextDown
        }
        return (high - width, high)
    }
}

// MARK: - the view

/// The bar itself. `onChange(shape, commit)` is the only write path: `false` on every move (the
/// panel's live-preview rule), `true` once on mouse-up (one snapshot).
public struct MaskRangeBar: View {

    public var shape: LuminanceRangeShape
    public var onChange: (LuminanceRangeShape, Bool) -> Void

    @State private var drag: MaskRangeBarDrag?

    public init(shape: LuminanceRangeShape,
                onChange: @escaping (LuminanceRangeShape, Bool) -> Void) {
        self.shape = shape
        self.onChange = onChange
    }

    public var body: some View {
        VStack(spacing: 2) {
            GeometryReader { geo in
                let width = max(Double(geo.size.width), 1)
                Canvas { context, size in
                    Self.draw(context: &context, size: size, shape: shape)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let active: MaskRangeBarDrag
                            if let drag {
                                active = drag
                            } else {
                                guard let began = MaskRangeBarGeometry.begin(
                                    atX: value.location.x, width: width, shape: shape) else { return }
                                drag = began
                                active = began
                            }
                            onChange(MaskRangeBarGeometry.shape(for: active,
                                                                atX: value.location.x,
                                                                width: width), false)
                        }
                        .onEnded { value in
                            let active = drag ?? MaskRangeBarGeometry.begin(
                                atX: value.location.x, width: width, shape: shape)
                            if let active {
                                onChange(MaskRangeBarGeometry.shape(for: active,
                                                                    atX: value.location.x,
                                                                    width: width), true)
                            }
                            drag = nil
                        }
                )
                .simultaneousGesture(
                    SpatialTapGesture(count: 2)
                        .onEnded { value in
                            guard let hit = MaskRangeBarGeometry.hit(
                                atX: value.location.x, width: width, shape: shape) else { return }
                            drag = nil
                            onChange(MaskRangeBarGeometry.resetting(hit, in: shape), true)
                        }
                )
                .accessibilityIdentifier("mask.luminance.rangebar")
                .help("拖动把手改边界；拖中间整体平移；拖斜纹改羽化；双击把手复位该端")
            }
            .frame(height: 28)

            // 167 — the axis itself: display codes on the SDR half, EV stops on the HDR half. Same
            // 9 pt monospaced tertiary treatment as the curve card's ticks (`CurveAxisTicks`).
            Canvas { context, size in
                Self.drawTicks(context: &context, size: size)
            }
            .frame(height: 11)

            HStack(spacing: 0) {
                Text(String(format: "%.2f", LuminanceRangeShape.default.low))
                Spacer(minLength: 2)
                Text(String(format: "亮度 0…%.2f（与吸管同一量纲）", LuminanceRangeShape.hdrMax))
                Spacer(minLength: 2)
                Text(String(format: "%.2f", LuminanceRangeShape.default.high))
            }
            .font(.system(size: 8, design: .monospaced))
            .foregroundStyle(.tertiary)
        }
    }

    private static func drawTicks(context: inout GraphicsContext, size: CGSize) {
        let w = size.width
        guard w > 1 else { return }
        for (i, tick) in MaskRangeBarGeometry.axisTicks.enumerated() {
            let x = MaskRangeBarGeometry.xPosition(forValue: tick.value, width: Double(w))
            let text = Text(tick.label)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.secondary)
            let anchor: UnitPoint = i == 0 ? .topLeading
                : (i == MaskRangeBarGeometry.axisTicks.count - 1 ? .topTrailing : .top)
            context.draw(context.resolve(text), at: CGPoint(x: x, y: 0), anchor: anchor)
        }
    }

    private static func draw(context: inout GraphicsContext, size: CGSize,
                             shape: LuminanceRangeShape) {
        let h = size.height
        let w = size.width
        guard w > 1, h > 1 else { return }
        let track = CGRect(x: 0, y: 5, width: w, height: h - 10)
        let lowX = MaskRangeBarGeometry.xPosition(forValue: shape.low, width: Double(w))
        let highX = MaskRangeBarGeometry.xPosition(forValue: shape.high, width: Double(w))
        let lower = min(lowX, highX)
        let upper = max(lowX, highX)

        context.fill(Path(roundedRect: track, cornerRadius: 4),
                     with: .color(Color.primary.opacity(0.07)))

        let selection = CGRect(x: lower, y: track.minY,
                               width: max(upper - lower, 0), height: track.height)
        if selection.width > 0 {
            context.fill(Path(selection), with: .color(Color.accentColor.opacity(0.32)))
        }

        // Feather zones: diagonal hatching, so they read as "transition" rather than another fill.
        let lowFeatherWidth = shape.lowFeather / MaskRangeBarGeometry.axisMax * Double(w)
        let highFeatherWidth = shape.highFeather / MaskRangeBarGeometry.axisMax * Double(w)
        let lowFeather = CGRect(x: max(0, lowX - lowFeatherWidth), y: track.minY,
                                width: min(lowX, max(0, lowFeatherWidth)), height: track.height)
        let highFeather = CGRect(x: highX, y: track.minY,
                                 width: max(0, min(Double(w) - highX, highFeatherWidth)),
                                 height: track.height)
        for rect in [lowFeather, highFeather] where rect.width > 0.5 {
            context.drawLayer { layer in
                layer.clip(to: Path(rect))
                layer.stroke(hatch(in: rect),
                             with: .color(Color.accentColor.opacity(0.42)), lineWidth: 1)
            }
        }

        // The two handles. Drawn 3 pt wide; the gesture's hit target is the 10 pt rule above.
        for x in [lowX, highX] {
            let handle = CGRect(x: x - 1.5, y: track.minY - 1, width: 3, height: track.height + 2)
            context.fill(Path(roundedRect: handle, cornerRadius: 1.5),
                         with: .color(Color.accentColor))
        }
    }

    private static func hatch(in rect: CGRect) -> Path {
        var path = Path()
        var x = rect.minX - rect.height
        while x < rect.maxX {
            path.move(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += 5
        }
        return path
    }
}
