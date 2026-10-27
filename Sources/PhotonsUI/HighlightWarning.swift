import AppKit
import Metal
import PhotonsCore

// MARK: - highlight warning: a measurement, not an edit
//
// The clipping warning is drawn **on the canvas**, over the photo, and it must never touch the
// document: no snapshot, no `editRevision`, no `develop_json`. So it is a *reading* of the frame the
// loupe already rendered — `HighlightWarning.grid(of:)` walks the presented rgba16Float texture and
// reduces it to a coarse grid of "how much of this cell is above `Histogram.clipHighThreshold`" —
// and the overlay view is a transparent sibling of the `CAMetalLayer` that paints magenta where the
// shares are non-zero.
//
// Two reasons for a grid rather than a per-pixel mask:
//
//   · the readback is what costs. A per-pixel copy of a 4.10 Mpx frame is 32 MB; one 64 × 48 grid
//     sampled from `rows` single-row copies is under 1 MB, and the resolution of the *warning* only
//     has to be "which cells blow out", because the user's next action is a slider, not a pixel.
//   · the same threshold as `Histogram.clipHighThreshold` (0.999) means the warning and the
//     histogram card's 削顶 percentage are the *same* number: two features, one definition, so a
//     card that says "0.0 % clipped" can never sit next to a canvas full of magenta.

/// A coarse, display-encoded clipping map of one rendered frame.
public struct ClippedGrid: Equatable, Sendable {
    public let columns: Int
    public let rows: Int
    /// Row-major, `rows × columns`: share of the sampled pixels in the cell above the threshold.
    public let share: [Float]
    /// How many pixels per cell were actually inspected (the frame's width is sampled, not copied).
    public let samplesPerCell: Int
    /// Fraction of the whole frame above the threshold, measured on this grid.
    public let clippedFraction: Double
    /// Cells with any clipped sample at all — what the overlay paints.
    public let clippedCellCount: Int

    public init(columns: Int, rows: Int, share: [Float], samplesPerCell: Int,
                clippedFraction: Double, clippedCellCount: Int) {
        self.columns = columns
        self.rows = rows
        self.share = share
        self.samplesPerCell = samplesPerCell
        self.clippedFraction = clippedFraction
        self.clippedCellCount = clippedCellCount
    }

    public static let empty = ClippedGrid(columns: 0, rows: 0, share: [], samplesPerCell: 0,
                                          clippedFraction: 0, clippedCellCount: 0)

    public var isEmpty: Bool { columns == 0 || rows == 0 || share.isEmpty }

    public func share(column: Int, row: Int) -> Float {
        guard column >= 0, column < columns, row >= 0, row < rows else { return 0 }
        let index = row * columns + column
        return share.indices.contains(index) ? share[index] : 0
    }
}

public enum HighlightWarning {
    /// The grid's resolution. 64 × 48 is finer than the 8 pt a warning dot occupies at fit on a
    /// 1600 pt window, and coarse enough that the readback stays under a megabyte.
    public static let columns = 64
    public static let rows = 48

    /// The threshold the *histogram* calls clipped. Red said once.
    public static var threshold: Float { Float(Histogram.clipHighThreshold) }

    /// Reduce a rendered frame to a clipping grid. `nil` when the texture is not the rgba16Float the
    /// display stage writes (the caller then paints nothing rather than guessing).
    ///
    /// The readback is one `getBytes` per sampled row of the **full width** and the sampling happens
    /// afterwards on the CPU, because Metal has no strided read: a row of 2560 px is 20 KB, 48 of
    /// them is 983 KB, against 32 MB for the whole frame.
    public static func grid(of texture: MTLTexture,
                            columns: Int = HighlightWarning.columns,
                            rows: Int = HighlightWarning.rows) -> ClippedGrid? {
        let w = texture.width, h = texture.height
        guard w > 0, h > 0, columns > 0, rows > 0 else { return nil }
        guard texture.pixelFormat == .rgba16Float || texture.pixelFormat == .rgba32Float else {
            return nil
        }
        let isHalf = texture.pixelFormat == .rgba16Float
        let bytesPerComponent = isHalf ? MemoryLayout<UInt16>.size : MemoryLayout<Float>.size
        let bytesPerRow = w * 4 * bytesPerComponent
        let threshold = HighlightWarning.threshold

        var share = [Float](repeating: 0, count: rows * columns)
        var totalSamples = 0
        var totalHit = 0

        // One buffer per row, reused: 48 allocations would be 48 chances to be slow for no reason.
        var rowBuffer = [UInt8](repeating: 0, count: bytesPerRow)
        let stepY = max(1, h / rows)
        let sampleStepX = max(1, w / (columns * 8))     // ≤ 8 samples per cell, always ≥ 1

        for row in 0..<rows {
            let y = min(h - 1, row * stepY)
            rowBuffer.withUnsafeMutableBytes { buf in
                texture.getBytes(buf.baseAddress!, bytesPerRow: bytesPerRow,
                                 from: MTLRegionMake2D(0, y, w, 1), mipmapLevel: 0)
            }
            rowBuffer.withUnsafeBytes { raw in
                for column in 0..<columns {
                    let x0 = (column * w) / columns
                    let x1 = max(x0 + 1, ((column + 1) * w) / columns)
                    var sampled = 0
                    var hit = 0
                    var x = x0
                    while x < x1 {
                        let offset = x * 4 * bytesPerComponent
                        var peak: Float = 0
                        for c in 0..<3 {
                            let v = isHalf
                                ? Float(Float16(bitPattern: raw.loadUnaligned(fromByteOffset: offset + c * 2,
                                                                              as: UInt16.self)))
                                : raw.loadUnaligned(fromByteOffset: offset + c * 4, as: Float.self)
                            if v > peak { peak = v }
                        }
                        sampled += 1
                        if peak > threshold { hit += 1 }
                        x += sampleStepX
                    }
                    share[row * columns + column] = sampled == 0 ? 0 : Float(hit) / Float(sampled)
                    totalSamples += sampled
                    totalHit += hit
                }
            }
        }

        // A cell counts as painted when it holds *any* clipped sample: the warning is deliberately
        // more eager than the percentage, because "one blown pixel here" is exactly what a warning
        // is for.
        var nonEmptyCells = 0
        for row in 0..<rows {
            for column in 0..<columns where share[row * columns + column] > 0 { nonEmptyCells += 1 }
        }
        let perCell = totalSamples / max(1, rows * columns)
        return ClippedGrid(columns: columns, rows: rows, share: share,
                           samplesPerCell: perCell,
                           clippedFraction: totalSamples == 0 ? 0
                               : Double(totalHit) / Double(totalSamples),
                           clippedCellCount: nonEmptyCells)
    }
}

/// The clipping colour — **one definition for the whole app**.
///
/// `#FF00C7` (sRGB 255, 0, 199). It marks light this panel cannot show, in two places that must agree
/// on sight: the canvas wash (`HighlightOverlayView`, where it is the one colour that cannot be
/// confused with a photograph) and the histogram card's channel row, whose over-white digits are painted
/// in it (2026-10-27, 「如果 R/G/B 中某个超过屏幕的亮度，就把…字的颜色改为红色」 — the owner's "red" is
/// this clipping mark, chosen over the linear-domain accent `#FF375F` because the *semantics* are what
/// matter: a channel at +2.3 is clipped light, not a parameter that edits scene-linear data).
///
/// Deliberately **not** `NSColor.systemRed`: the wash and the digits have to be the same ink, and a
/// semantic system colour drifts with the appearance while this one must not.
///
/// The stored blue is `0.78` rather than `199/255 = 0.78039` because that is the literal the wash has
/// always been painted with (changing it would move canvas pixels for no gain); `0.78 × 255 = 198.9`, so
/// the bytes it lands on are `255, 0, 199` at 8-bit — i.e. `#FF00C7` to within a quarter of a code.
public enum ClippingMark {
    /// `#FF00C7`, opaque. The wash tints it with alpha; the digits paint it solid.
    public static let color = NSColor(srgbRed: 1.0, green: 0.0, blue: 0.78, alpha: 1)
}

/// The magenta wash, drawn *over* the canvas layer.
///
/// A sibling `NSView` of the `CAMetalLayer` rather than an extra pass in `RenderGraph`: the warning
/// is a UI affordance (like the mask overlay's red wash, but even less of a document fact), and
/// adding a stage for it would put a debug display into the export key chain. Transparent, never a
/// hit target, so a click still belongs to the canvas.
final class HighlightOverlayView: NSView {
    var grid: ClippedGrid? {
        didSet { needsDisplay = true }
    }

    /// Painted when the overlay is on but the frame has no grid yet (arming the toggle must be
    /// visible immediately, even before the next frame lands).
    var isArmed = false {
        didSet { if isArmed != oldValue { needsDisplay = true } }
    }

    override var isOpaque: Bool { false }
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard isArmed, let grid, !grid.isEmpty, bounds.width > 1, bounds.height > 1 else { return }
        let cellWidth = bounds.width / CGFloat(grid.columns)
        let cellHeight = bounds.height / CGFloat(grid.rows)
        // A primary, not a tint: this is the one colour that cannot be confused with the picture.
        // One definition for the app — `ClippingMark` (the card's over-white digits paint it too).
        let base = ClippingMark.color
        for row in 0..<grid.rows {
            for column in 0..<grid.columns {
                let share = grid.share(column: column, row: row)
                guard share > 0 else { continue }
                let alpha = CGFloat(min(1.0, 0.30 + 0.70 * share))
                base.withAlphaComponent(alpha).setFill()
                // Half-pixel overlap so neighbouring cells do not leave seams from the rounding.
                NSRect(x: bounds.minX + CGFloat(column) * cellWidth,
                       y: bounds.minY + CGFloat(row) * cellHeight,
                       width: cellWidth + 0.5, height: cellHeight + 0.5).fill()
            }
        }
    }
}

// MARK: - the card's arithmetic (no AppKit, so the smoke can check the numbers directly)

/// Formatting and path maths for the histogram card.
///
/// Pure on purpose: the percentages the card prints are the *Core* numbers
/// (`HistogramChannel.clippedHigh` / `clippedLow`), and having the formatter be a function of those
/// values is what lets `--ui-smoke` assert "the number on screen equals the number Core measured"
/// without reading pixels back out of a label.
public enum HistogramCardFormat {

    /// `"0.0%"`, `"<0.1%"` for a value that is clipped but under a tenth of a percent (a card that
    /// says 0.0 % next to a visible spike is the kind of lie this avoids).
    public static func percent(_ value: Double) -> String {
        guard value.isFinite, value > 0 else { return "0.0%" }
        if value < 0.0005 { return "<0.1%" }
        let pct = value * 100
        return pct >= 99.95 ? "100%" : String(format: "%.1f%%", pct)
    }

    /// The value `percent(_:)` displays, back as a number (what the smoke compares).
    public static func percentValue(_ value: Double) -> Double {
        guard value.isFinite, value > 0 else { return 0 }
        if value >= 0.9995 { return 1 }
        return (value * 1000).rounded() / 1000
    }

    public static func clipHigh(_ histogram: Histogram?, _ channel: Histogram.Channel) -> String {
        guard let histogram else { return "—" }
        return percent(histogram[channel].clippedHigh)
    }

    public static func clipLow(_ histogram: Histogram?, _ channel: Histogram.Channel) -> String {
        guard let histogram else { return "—" }
        return percent(histogram[channel].clippedLow)
    }

}
