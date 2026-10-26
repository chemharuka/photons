import SwiftUI
import AppKit
import PhotonsCatalog
import PhotonsCore

// MARK: - the numbers

/// The one place the marquee arithmetic lives, so it can be tested without a window.
///
/// The rule the user asked for is short: a row is exactly as wide as the card's content, it shows
/// the head of the string plus `…` until the pointer is over it, and then it plays *once* — left to
/// right, linear — and stops at the end. Hover off and it snaps back to head + `…` (no rewind
/// animation). A string that fits never moves and never grows an ellipsis.
public enum MarqueeLayout {
    /// Scroll speed. 60 pt/s is about one character per frame at 10 pt, which reads as motion
    /// rather than a jump cut; the duration is derived from it, then clamped.
    public static let pointsPerSecond: CGFloat = 60
    /// Floor: below this a 20 pt overflow would be a 0.33 s flick that reads as a glitch.
    public static let minimumDuration: TimeInterval = 0.4
    /// Ceiling: a pathological 500 pt lens name should not hold a timer for 8 s.
    public static let maximumDuration: TimeInterval = 3.0

    public static let ellipsis = "…"

    public static func attributes(font: NSFont, color: NSColor) -> [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: color]
    }

    /// Width of a single line, measured the way the spec asks for it: `NSAttributedString.size()`.
    /// No `GeometryReader`, no preference-key ping-pong — the view measures once per text change.
    public static func width(of text: String, font: NSFont, color: NSColor = .labelColor) -> CGFloat {
        (text as NSString).size(withAttributes: attributes(font: font, color: color)).width
    }

    /// How far the text has to travel: 0 when it already fits.
    public static func overflow(textWidth: CGFloat, width: CGFloat) -> CGFloat {
        max(0, textWidth - width)
    }

    /// `clamp(overflow / 60, 0.4, 3.0)` seconds.
    public static func duration(overflow: CGFloat) -> TimeInterval {
        guard overflow > 0 else { return 0 }
        return min(max(Double(overflow) / Double(pointsPerSecond), minimumDuration), maximumDuration)
    }

    /// Linear travel, clamped at the end. `elapsed` at or past `duration` is the end position, which
    /// is what makes "stop at the end, never loop, never bounce" a property of the arithmetic rather
    /// than of the timer's punctuality.
    public static func offset(elapsed: TimeInterval, overflow: CGFloat, duration: TimeInterval) -> CGFloat {
        guard overflow > 0, duration > 0 else { return 0 }
        let t = min(max(elapsed / duration, 0), 1)
        return -overflow * CGFloat(t)
    }

    /// Head of the string that fits in `width` **including** the trailing ellipsis; the string itself
    /// when nothing is cut. Character-by-character measurement (not a guess at an average glyph
    /// width) is what keeps the ellipsis from poking past the frame at 274 pt.
    public static func tailTruncated(_ text: String, font: NSFont, width: CGFloat,
                                     color: NSColor = .labelColor) -> String {
        guard width > 0, !text.isEmpty else { return "" }
        if self.width(of: text, font: font, color: color) <= width { return text }

        let ellipsisWidth = self.width(of: ellipsis, font: font, color: color)
        guard ellipsisWidth <= width else { return ellipsis }

        var best = ""
        var carried: CGFloat = 0
        for ch in text {
            let next = carried + self.width(of: String(ch), font: font, color: color)
            if next + ellipsisWidth > width { break }
            carried = next
            best.append(ch)
        }
        // Trailing whitespace before the ellipsis looks like a gap, not a truncation.
        while let last = best.last, last == " " { best.removeLast() }
        return best + ellipsis
    }

    /// How many characters survive truncation — the number the acceptance report quotes.
    public static func visibleCharacterCount(_ text: String, font: NSFont, width: CGFloat,
                                             color: NSColor = .labelColor) -> Int {
        tailTruncated(text, font: font, width: width, color: color).count
    }
}

// MARK: - the row

/// One fixed-width information line. AppKit rather than SwiftUI `Text` because the marquee needs
/// three things SwiftUI cannot give it cheaply: an exact measured text width, an offset that is a
/// value (not an implicit animation), and hover tracking that is per-row.
///
/// The view never changes its own width — SwiftUI lays it out (`maxWidth: .infinity`) to the card's
/// content width, and `layout()` re-truncates when that width changes (a window resize), which is
/// the "fixed width, re-fits on resize" behaviour without any measurement loop.
public final class MarqueeRowView: NSView {
    public var text: String { didSet { rebuild() } }
    public var font: NSFont { didSet { rebuild() } }
    public var textColor: NSColor { didSet { rebuild() } }
    /// Fixed row height, so four lines of information keep one rhythm.
    public let lineHeight: CGFloat

    /// Measured width of the **whole** string, never of the truncated one.
    public private(set) var textWidth: CGFloat = 0
    /// Measured width of what is on screen while not hovering (head + `…`).
    public private(set) var truncatedText = ""
    public private(set) var isOverflowing = false
    /// 0 = head; `-(textWidth - width)` = end of the string.
    public private(set) var offset: CGFloat = 0
    public private(set) var duration: TimeInterval = 0
    public private(set) var isHovering = false
    public private(set) var isPlaying = false
    /// Starts at 0 and increments once per hover-in with overflow — the "only once" witness.
    public private(set) var playCount = 0

    private var startTime: CFAbsoluteTime = 0
    private var timer: Timer?

    public init(text: String,
                font: NSFont = .systemFont(ofSize: 10),
                color: NSColor = .secondaryLabelColor,
                lineHeight: CGFloat = 14) {
        self.text = text
        self.font = font
        self.textColor = color
        self.lineHeight = lineHeight
        super.init(frame: .zero)
        rebuild()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("MarqueeRowView is created in code") }

    deinit { timer?.invalidate() }

    public override var isFlipped: Bool { true }
    public override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: lineHeight)
    }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: measurement

    private func rebuild() {
        textWidth = MarqueeLayout.width(of: text, font: font, color: textColor)
        isOverflowing = textWidth > bounds.width + 0.01
        truncatedText = MarqueeLayout.tailTruncated(text, font: font, width: bounds.width, color: textColor)
        duration = MarqueeLayout.duration(overflow: MarqueeLayout.overflow(textWidth: textWidth, width: bounds.width))
        if isOverflowing {
            offset = min(offset, 0)
            offset = max(offset, -MarqueeLayout.overflow(textWidth: textWidth, width: bounds.width))
        } else {
            offset = 0
            stopPlayback()
        }
        needsDisplay = true
        invalidateIntrinsicContentSize()
    }

    public override func layout() {
        super.layout()
        let wasOverflowing = isOverflowing
        rebuild()
        // A resize that changes the fit restarts the pass from the head; keeping a stale offset
        // would show the middle of a string after a narrower window.
        if isHovering && wasOverflowing { startPlayback(restart: true) }
    }

    // MARK: hover + playback

    public func setHovering(_ hovering: Bool) {
        guard hovering != isHovering else { return }
        isHovering = hovering
        if hovering {
            if isOverflowing { startPlayback(restart: true) } else { offset = 0 }
        } else {
            // Instant return to the head: no animation, per the spec.
            stopPlayback()
            offset = 0
        }
        needsDisplay = true
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    private func startPlayback(restart: Bool) {
        guard isOverflowing else { return }
        if restart {
            stopPlayback()
            offset = 0
            playCount += 1
            startTime = CACurrentMediaTime()
        }
        guard timer == nil else { return }
        isPlaying = true
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.advance(to: CACurrentMediaTime() - self.startTime)
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopPlayback() {
        timer?.invalidate()
        timer = nil
        isPlaying = false
    }

    /// Drive the scroll to an absolute elapsed time. Split out of the timer so tests can step it
    /// deterministically instead of sleeping through a 1.6 s animation.
    public func advance(to elapsed: TimeInterval) {
        guard isOverflowing, duration > 0 else { offset = 0; needsDisplay = true; return }
        let overflow = MarqueeLayout.overflow(textWidth: textWidth, width: bounds.width)
        offset = MarqueeLayout.offset(elapsed: elapsed, overflow: overflow, duration: duration)
        if elapsed >= duration {
            // At the end: park exactly on `-(textWidth - width)` and kill the timer — one pass only.
            offset = -overflow
            stopPlayback()
        }
        needsDisplay = true
    }

    // MARK: tracking

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    public override func mouseEntered(with event: NSEvent) { setHovering(true) }
    public override func mouseExited(with event: NSEvent) { setHovering(false) }

    public func reset() {
        setHovering(false)
        offset = 0
    }

    // MARK: drawing

    public override func draw(_ dirtyRect: NSRect) {
        let shown = (isHovering && isOverflowing) ? text : truncatedText
        guard !shown.isEmpty else { return }
        let attrs = MarqueeLayout.attributes(font: font, color: textColor)
        let attributed = NSAttributedString(string: shown, attributes: attrs)
        let height = attributed.size().height
        attributed.draw(at: NSPoint(x: offset, y: floor((bounds.height - height) / 2)))
    }

    // MARK: accessibility

    public override func isAccessibilityElement() -> Bool { true }
    public override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    public override func accessibilityLabel() -> String? { text }
    public override func accessibilityValue() -> Any? { text }
}

// MARK: - SwiftUI

/// The reusable line: filename, shooting parameters and the equipment line all use this.
///
/// Width is *not* a parameter: the view takes what its parent gives it (`maxWidth: .infinity`), which
/// for the inspector means the card's content width. That is what "fixed width" has to mean in a
/// resizable panel — a hard-coded 274 would be wrong at the panel's 300…364 range.
public struct MarqueeText: View {
    public var text: String
    public var fontSize: CGFloat
    public var weight: NSFont.Weight
    public var monospacedDigits: Bool
    public var color: NSColor

    public init(text: String,
                fontSize: CGFloat = 10,
                weight: NSFont.Weight = .regular,
                monospacedDigits: Bool = false,
                color: NSColor = .secondaryLabelColor) {
        self.text = text
        self.fontSize = fontSize
        self.weight = weight
        self.monospacedDigits = monospacedDigits
        self.color = color
    }

    private var font: NSFont {
        monospacedDigits
            ? .monospacedDigitSystemFont(ofSize: fontSize, weight: weight)
            : .systemFont(ofSize: fontSize, weight: weight)
    }

    public var body: some View {
        MarqueeLineRepresentable(text: text, font: font, color: color, lineHeight: fontSize + 4)
            .frame(maxWidth: .infinity, minHeight: fontSize + 4, maxHeight: fontSize + 4)
            .accessibilityLabel(text)
    }
}

private struct MarqueeLineRepresentable: NSViewRepresentable {
    var text: String
    var font: NSFont
    var color: NSColor
    var lineHeight: CGFloat

    func makeNSView(context: Context) -> MarqueeRowView {
        MarqueeRowView(text: text, font: font, color: color, lineHeight: lineHeight)
    }

    func updateNSView(_ view: MarqueeRowView, context: Context) {
        // Order matters: a new font changes the measured width, so set it before the text and let
        // each `didSet` rebuild; assigning equal values is a no-op only for the text, which is fine.
        if view.font != font { view.font = font }
        if view.textColor != color { view.textColor = color }
        if view.text != text { view.text = text }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MarqueeRowView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: lineHeight)
    }
}

// MARK: - the text of the block

/// The shooting-information strings, as pure functions so the acceptance can pin them.
///
/// Rules (deliberate, and the reason they are here rather than in the view):
///   · the parameters line always has four slots — `ISO · focal · aperture · shutter` — and a
///     missing slot is `—`. A line that shrank to three items would break the scan rhythm, and the
///     user asked to keep the order fixed.
///   · the equipment line shows **camera model only**, not `make + model`: `Leica Camera AG ·
///     Leica SL3 · Vario-Elmarit 24-90` is ~340 pt at 10 pt and would marquee on every photo, while
///     `Leica SL3` usually fits. The make is still the filter facet (`camera_key`); it is simply
///     not repeated in the row. When `model` is nil we fall back to `make` rather than showing `—`.
///   · a missing half keeps its slot with a word — `Leica SL3 · 未知镜头` / `未知相机 · Sigma …` —
///     so the `·` never dangles. Both missing collapses to the single word `未知相机`; printing
///     `未知相机 · 未知镜头` would spend the row saying nothing twice.
public enum InspectorPhotoInfo {

    /// The slot text for a half the file does not describe.
    public static let unknownCamera = "未知相机"
    public static let unknownLens = "未知镜头"

    /// The four cells of the exposure row, already formatted and **unpadded**: the row is laid out
    /// as four equal-width slots (LR's arrangement) rather than as a space-padded string, so the
    /// fields keep their positions no matter what the values are.
    public struct ParameterTokens: Equatable, Sendable {
        public let iso: String
        public let focal: String
        public let aperture: String
        public let shutter: String

        public var all: [String] { [iso, focal, aperture, shutter] }
    }

    public static func tokens(iso: Int?, focalLength: Double?, aperture: Double?,
                              shutter: String?) -> ParameterTokens {
        ParameterTokens(iso: "ISO " + (iso.map { "\($0)" } ?? "—"),
                        // One decimal on the aperture always: it is a photographic number, and a
                        // fixed `f/2.8` / `f/32.0` shape keeps the cell from breathing.
                        focal: (focalLength.map { decimal($0) } ?? "—") + " mm",
                        aperture: aperture.map { "f/" + String(format: "%.1f", $0) } ?? "f/—",
                        shutter: self.shutter(shutter) ?? "—")
    }

    /// The same row as one string — used for the accessibility label and by the tests. The visible
    /// row is `InspectorParameterRow`, which places these four tokens in equal-width slots
    /// (ISO flush left, shutter flush right, the other two centred in their slots).
    public static func parameters(iso: Int?, focalLength: Double?, aperture: Double?, shutter: String?) -> String {
        tokens(iso: iso, focalLength: focalLength, aperture: aperture, shutter: shutter)
            .all.joined(separator: " · ")
    }

    /// The exposure row, LR-style: four equal-width slots across the card's content width, ISO
    /// flush left, shutter flush right, focal length and aperture centred in the two middle slots.
    ///
    /// Equal slots rather than spacers on purpose — a spacer pair would let a longer value push its
    /// neighbours around, which is exactly the "快门位置会动" complaint.
    public struct InspectorParameterRow: View {
        public let tokens: InspectorPhotoInfo.ParameterTokens

        public init(tokens: InspectorPhotoInfo.ParameterTokens) { self.tokens = tokens }

        public var body: some View {
            HStack(spacing: 0) {
                cell(tokens.iso, alignment: .leading)
                cell(tokens.focal, alignment: .center)
                cell(tokens.aperture, alignment: .center)
                cell(tokens.shutter, alignment: .trailing)
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            .lineLimit(1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(tokens.all.joined(separator: " · "))
        }

        private func cell(_ text: String, alignment: Alignment) -> some View {
            Text(text)
                .frame(maxWidth: .infinity, alignment: alignment)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 像素数 / 尺寸 (派单 022)

    /// The one character a row prints when the library does not know the number.
    public static let noValue = "—"

    /// `9000×6000` → `54 MP`; `1000×900` → `0.9 MP`; a missing side → `—`.
    ///
    /// The user asked for the first row to be **values only** — no `像素`, no `尺寸`, no label
    /// beyond the unit the number itself needs (「不要写中文 就 L100000.dng   60 MP   9000×6000」).
    /// So: the space before `MP` stays (it is what keeps `60 MP` from reading as a product code),
    /// the megapixel figure is an integer from one megapixel up, and below that it keeps one
    /// decimal (`0.9`), because `0 MP` would be a lie about a photo that exists.
    public static func pixelCount(width: Int?, height: Int?) -> String {
        guard let pixels = pixelArea(width: width, height: height) else { return noValue }
        let megapixels = Double(pixels) / 1_000_000
        if megapixels >= 1 { return "\(Int(megapixels.rounded())) MP" }
        return String(format: "%.1f MP", megapixels)
    }

    /// `9000×6000` — U+00D7, no spaces around it, no unit, nothing else on the line.
    public static func pixelDimensions(width: Int?, height: Int?) -> String {
        guard let width, let height, width > 0, height > 0 else { return noValue }
        return "\(width)×\(height)"
    }

    /// Both sides, or nothing: half a size is not a size, and `9000×—` would read as a broken row.
    private static func pixelArea(width: Int?, height: Int?) -> Int? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        return width * height
    }

    // MARK: 裁切后的画布尺寸 (派单 049)

    /// What the first row prints, and the pixel grid it describes.
    ///
    /// The user, 2026-10-27:「裁剪后右上角信息栏中的像素大小也要改，这个视为画布的大小」— after a crop
    /// the canvas on screen is the cropped picture, so `60 MP / 9520×6336` becomes whatever the crop
    /// outputs. Two strings and the grid they came from, so a test can tell *why* a number is what it
    /// is instead of comparing text and hoping.
    public struct PhotoInfoMetrics: Equatable, Sendable {
        public let pixelCount: String
        public let pixelDimensions: String
        /// The grid the two strings describe — the crop's output, or the asset's own stored size.
        public let canvas: ImageSize?
        /// `true` when `canvas` is the crop's output rather than the asset's stored dimensions.
        public let isCroppedCanvas: Bool

        public init(pixelCount: String, pixelDimensions: String,
                    canvas: ImageSize?, isCroppedCanvas: Bool) {
            self.pixelCount = pixelCount
            self.pixelDimensions = pixelDimensions
            self.canvas = canvas
            self.isCroppedCanvas = isCroppedCanvas
        }
    }

    /// The one entry point for 「像素数量 / 尺寸」: the asset's stored size, run through the crop.
    ///
    /// The numbers come from `CropMath.outputSize(geometry.renderCrop(source:), in: source)` — the
    /// very call the export and the histogram make (`RenderGraph.measureHistogram`), so the row
    /// cannot disagree with the file that will be written or with the plot above it.
    ///
    /// **"Is there a crop" is the geometry moving the output, not `crop != nil`.** A whole-frame
    /// rectangle — `(0, 0, 1, 1)`, which is also what a document with no crop stores — leaves the
    /// output equal to the frame, and then the row prints the asset's own numbers *character for
    /// character*, which is what keeps 049 rule 2 (no crop ⇒ byte-identical) and rule 4 (full-canvas
    /// crop ≡ no crop) the same statement.
    ///
    /// - Parameters:
    ///   - storedWidth/storedHeight: the catalog row's dimensions, as the row has always read them.
    ///   - geometry: the geometry on screen — the crop tool's live draft while it is open, else the
    ///     document's. `nil` when no document is loaded for this photo.
    ///   - source: the upright frame the renderer ingested (`RenderGraph.sourceSize`), when known.
    ///     EXIF 5…8 transposes it, and the crop is measured on that frame, so a rotated photo's
    ///     `W×H` comes out the right way round. Without it the stored dimensions are the frame.
    public static func metrics(storedWidth: Int?, storedHeight: Int?,
                               geometry: GeometryGroup?,
                               source: ImageSize? = nil) -> PhotoInfoMetrics {
        guard let stored = size(storedWidth, storedHeight) else {
            return PhotoInfoMetrics(pixelCount: noValue, pixelDimensions: noValue,
                                    canvas: nil, isCroppedCanvas: false)
        }
        // No document for this photo: the asset's own numbers, exactly as before 049.
        guard let geometry else { return uncropped(stored) }

        let frame = source.flatMap { size($0.width, $0.height) } ?? stored
        let output = CropMath.outputSize(geometry.renderCrop(source: frame), in: frame)
        // The geometry did not change the grid (no crop, a whole-frame crop, a flip, or a straighten
        // — S0 keeps the crop as the output frame): print the asset's own size, untouched.
        guard output != frame else { return uncropped(stored) }

        return PhotoInfoMetrics(pixelCount: pixelCount(width: output.width, height: output.height),
                                pixelDimensions: pixelDimensions(width: output.width, height: output.height),
                                canvas: output, isCroppedCanvas: true)
    }

    private static func uncropped(_ stored: ImageSize) -> PhotoInfoMetrics {
        PhotoInfoMetrics(pixelCount: pixelCount(width: stored.width, height: stored.height),
                         pixelDimensions: pixelDimensions(width: stored.width, height: stored.height),
                         canvas: stored, isCroppedCanvas: false)
    }

    /// Both sides, or nothing — the same rule `pixelArea` applies to the strings.
    private static func size(_ width: Int?, _ height: Int?) -> ImageSize? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        return ImageSize(width: width, height: height)
    }

    /// The ids the geometry test reads off the first row's two value cells. Not an enum in the
    /// view: the probe publishes the string, and the test looks the string up by these keys.
    public enum SpecColumn: String, Sendable {
        case pixelCount = "center"
        case pixelDimensions = "trailing"
    }

    /// Four rows, first one is one line with three columns: `L100000.dng   60 MP   9000×6000` —
    /// file name flush left, megapixels centred on the card's own centre, dimensions flush right.
    ///
    /// The three columns are placed by `SpecRowLayout` rather than by `Spacer()`s, because the
    /// leading cell is a marquee: `MarqueeText` asks for `maxWidth: .infinity`, so in a plain
    /// `HStack` it would take the whole row and push the other two cells to the end. Here the
    /// middle and trailing cells are placed at their measured size first, and the marquee gets
    /// exactly the room left before them — so the name stays left-aligned *and* truncates only
    /// when it really would collide with `60 MP`.
    ///
    /// The two values carry an invisible AppKit probe in their background: SwiftUI draws text
    /// into layers, so a `Text` has no `NSView` to measure, and the alignment has to be proven on
    /// the frame SwiftUI actually handed the text (`MaskPanelProbe` is the same seam).
    public struct PhotoSpecRow: View {
        /// The marquee's own size, so the three columns sit on one baseline grid.
        public static let fontSize: CGFloat = 10
        /// Fixed, whatever the values are: a missing `—` must not make the row shorter.
        public static let height: CGFloat = fontSize + 4
        /// One gap between the name and the centred cell — the only air the row can spare.
        public static let columnGap: CGFloat = 8

        public let filename: String
        public let pixelCount: String
        public let pixelDimensions: String

        public init(filename: String, pixelCount: String, pixelDimensions: String) {
            self.filename = filename
            self.pixelCount = pixelCount
            self.pixelDimensions = pixelDimensions
        }

        public var body: some View {
            SpecRowLayout(gap: Self.columnGap) {
                // The marquee is kept: a long name still truncates with `…` and scrolls on hover.
                MarqueeText(text: filename)
                valueText(pixelCount, column: .pixelCount)
                valueText(pixelDimensions, column: .pixelDimensions)
            }
            .frame(height: Self.height)
        }

        private func valueText(_ text: String, column: SpecColumn) -> some View {
            Text(text)
                .font(.system(size: Self.fontSize))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                .lineLimit(1)
                .fixedSize()
                .background(SpecRowProbeRepresentable(id: column.rawValue, text: text))
        }
    }

    /// Three columns: `[0]` takes the room left over on the left, `[1]` is centred on `bounds.midX`,
    /// `[2]` ends on `bounds.maxX`. Centring on the bounds (not on the space between the other two
    /// cells) is what keeps `60 MP` from moving when the file name gets longer.
    struct SpecRowLayout: Layout {
        let gap: CGFloat

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            CGSize(width: proposal.width ?? 0, height: PhotoSpecRow.height)
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
                           cache: inout ()) {
            guard subviews.count == 3 else { return }
            let middle = subviews[1].sizeThatFits(.unspecified)
            let trailing = subviews[2].sizeThatFits(.unspecified)
            let middleMinX = bounds.midX - middle.width / 2

            subviews[2].place(at: CGPoint(x: bounds.maxX - trailing.width,
                                          y: bounds.midY - trailing.height / 2),
                              proposal: ProposedViewSize(trailing))
            subviews[1].place(at: CGPoint(x: middleMinX, y: bounds.midY - middle.height / 2),
                              proposal: ProposedViewSize(middle))
            let leadingWidth = max(0, middleMinX - gap - bounds.minX)
            subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.minY),
                              proposal: ProposedViewSize(width: leadingWidth, height: bounds.height))
        }
    }

    /// `Leica SL3 · Sigma 20-60 DG`; a missing half keeps its slot with `未知相机` / `未知镜头`,
    /// and only both-missing collapses to the bare `未知相机` (no separator, no second word).
    ///
    /// 派单 022 shows the two halves on their own rows instead (`camera` / `lens`); this string is
    /// kept as the join of those two so the words cannot drift apart, and still carries the
    /// both-missing collapse the single row needed.
    public static func equipment(make: String?, model: String?, lens rawLens: String?) -> String {
        guard cameraName(make: make, model: model) != nil || rawLens.flatMap(nonEmpty) != nil else {
            return unknownCamera
        }
        return "\(camera(make: make, model: model)) · \(lens(rawLens))"
    }

    /// Row 2 of 派单 022: the camera half of `equipment`, character for character — model first,
    /// make as the fallback, `未知相机` when the file names neither.
    public static func camera(make: String?, model: String?) -> String {
        cameraName(make: make, model: model) ?? unknownCamera
    }

    /// Row 3: the lens half of `equipment` — `未知镜头` when the file is silent about it.
    public static func lens(_ raw: String?) -> String {
        raw.flatMap(nonEmpty) ?? unknownLens
    }

    /// Model preferred, make as the fallback. See the note above for why the make is not prefixed.
    public static func cameraName(make: String?, model: String?) -> String? {
        if let model = model.flatMap(nonEmpty) { return model }
        return make.flatMap(nonEmpty)
    }

    /// `1/250` → `1/250s`; `1/250s` stays `1/250s`; empty → nil (the caller prints `—`).
    ///
    /// Legacy rows also come through here: a library imported before `ShutterFormat` existed has
    /// `55924/44739201` in `asset_metadata.shutter`, so the value is re-normalised at display time
    /// (the row is read-only here — no migration, no re-import).
    public static func shutter(_ raw: String?) -> String? {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        guard var s = ShutterFormat.standard(from: raw), !s.isEmpty else { return nil }
        if s.hasSuffix("s") || s.hasSuffix("S") { return s }
        s.append("s")
        return s
    }

    /// `24.0` → `24`, `24.5` → `24.5`, `2.80` → `2.8` — no `24.000000` in a 274 pt row.
    public static func decimal(_ value: Double) -> String {
        let rounded = value.rounded()
        if abs(value - rounded) < 0.0001 { return String(Int(rounded)) }
        var s = String(format: "%.1f", value)
        if s.hasSuffix(".0") { s.removeLast(2) }
        return s
    }

    private static func nonEmpty(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

// MARK: - the spec rows' AppKit seam

/// What a spec row published: which slot it is, and the exact string on it.
///
/// Invisible and click-through — it exists so a test can read (a) the frame SwiftUI gave the value
/// and (b) the value itself, without a screenshot and without a second copy of the formatter in the
/// test. `MaskPanelProbe` publishes the same way for the mask panel.
public final class InspectorSpecRowProbe: NSView {
    public private(set) var id: String
    public private(set) var text: String

    public init(id: String, text: String) {
        self.id = id
        self.text = text
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("InspectorSpecRowProbe is created in code") }

    func update(id: String, text: String) {
        if self.id != id { self.id = id }
        if self.text != text { self.text = text }
    }

    /// A measuring leaf, never a target: hover belongs to the marquee row above it.
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }
    public override var isOpaque: Bool { false }
    public override func draw(_ dirtyRect: NSRect) {}
}

private struct SpecRowProbeRepresentable: NSViewRepresentable {
    let id: String
    let text: String

    func makeNSView(context: Context) -> InspectorSpecRowProbe {
        InspectorSpecRowProbe(id: id, text: text)
    }

    func updateNSView(_ view: InspectorSpecRowProbe, context: Context) {
        view.update(id: id, text: text)
    }

    /// The background is proposed the primary view's frame; accepting it is what makes the probe's
    /// frame equal the text's frame instead of the row's.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: InspectorSpecRowProbe,
                      context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
}

// MARK: - metadata read

/// Reads the exposure row for the anchor photo. The panel is a leaf view, and `CatalogSession`
/// deliberately exposes no metadata accessor, so the inspector opens its **own** read handle once
/// per library and keeps it: one extra connection on the same WAL database, no writes, no schema
/// change. A failed open is remembered, so a broken library does not retry on every redraw.
public final class InspectorMetadataReader {
    private var catalog: Catalog?
    private var libraryURL: URL?

    public init() {}

    public func metadata(library: URL?, assetID: String?) -> AssetMetadata? {
        guard let library, let assetID else { return nil }
        if libraryURL != library {
            libraryURL = library
            catalog = try? Catalog.open(at: library)
        }
        return try? catalog?.metadata(assetId: assetID)
    }
}
