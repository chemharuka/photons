import Foundation

// MARK: - 080 · 原图 / 前后对比
//
// Two things live here, and they are deliberately separate from the editing graph:
//
//   · `RenderSource` — **which pixels a render is of**: the document as edited, or the decode
//     itself. 「显示原图」(`\`) is the second one, and the whole point is that it is not a spelling of
//     "clear the parameters and render again": a parameter-clearing render still passes S0 with the
//     document's **geometry** (crop, straighten, flip, CA), so it shows a cropped, rotated picture
//     with neutral tone. The decode is the whole frame the camera wrote. That difference is a pixel
//     difference (`BeforeAfterTests.testTheDecodeIsNotAParameterClearedRender`).
//
//   · `CompareSplit` — where the 分屏 line is, and which side of it is which source. The arithmetic
//     is here, in Swift, and the kernel reads the **same derived numbers** (a pixel index, an axis
//     and a line width) rather than re-deriving them from a fraction, so "which source owns this
//     pixel" cannot be answered two ways (`s5_before_after.metal` mirrors `side(x:y:canvas:)`).

/// Which pixels a render is of.
public enum RenderSource: String, Sendable, Codable, CaseIterable {
    /// The document, as it is: S0 → S1 → … → S4.
    case edited
    /// **The decode**, i.e. the `LinearImage` the ladder developed — before S0's crop and turn, and
    /// before every stage that shapes light or colour.
    ///
    /// The render is two passes: S0 with an **identity geometry** (which still applies the
    /// decoded-primaries → working-primaries matrix, so the colours are the decoder's and not a
    /// mislabelled Rec.2020), then S4's display encode. Nothing else runs, so the pixels are
    /// `OETF(M_working→out · M_decoded→working · decode)` — the same definition a reference
    /// implementation of "decode + OETF" computes on the CPU, which is what
    /// `BeforeAfterTests` checks to within one 8-bit code.
    ///
    /// **No decode is involved.** The buffer is the rung the ladder already holds; this selects a
    /// shorter pipeline over it, never a second development (`decodeCounts +0`).
    case decoded
}

/// Which side of the 分屏 line a pixel belongs to.
public enum CompareSide: String, Sendable, Codable, CaseIterable {
    /// The decode (`RenderSource.decoded`) — the left / top half.
    case original
    /// The document (`RenderSource.edited`) — the right / bottom half.
    case edited
    /// The line itself. Not a picture pixel: the composite paints it, so a reader cannot mistake a
    /// dark half-column for the photograph.
    case divider
}

/// The 分屏 line: which way it runs, and where it is.
///
/// A value type with no GPU in it, because the question the acceptance asks — 「分界线在 50 % 时左/右
/// 像素各属哪个源」 — has to be answerable without a render, and the answer has to agree with the one
/// the composite draws. `dividerPixel` is that single answer: the kernel is handed the **pixel
/// index** it computes (plus the axis and the line width), never the fraction, so a rounding
/// difference between CPU and GPU cannot put a pixel on the wrong side.
public struct CompareSplit: Sendable, Equatable, Codable {
    public enum Axis: String, Sendable, Codable, CaseIterable {
        /// The line runs top-to-bottom: original on the left, edited on the right.
        case vertical
        /// The line runs left-to-right: original above, edited below.
        case horizontal

        public var displayName: String {
            switch self {
            case .vertical: return "左右"
            case .horizontal: return "上下"
            }
        }
    }

    public var axis: Axis
    /// Position of the line along `axis`, 0…1 of the canvas. 0.5 = the middle.
    public var fraction: Double

    public init(axis: Axis = .vertical, fraction: Double = 0.5) {
        self.axis = axis
        self.fraction = fraction.isFinite ? min(max(fraction, 0), 1) : 0.5
    }

    public static let half = CompareSplit()

    /// Width of the painted line, in canvas pixels. Even, so the line straddles the boundary the
    /// same way at both ends of the travel.
    public static let lineWidth = 2

    /// The canvas column (`.vertical`) or row (`.horizontal`) the line is centred on.
    ///
    /// Rounded, then clamped to the canvas, so `fraction = 1` is a line at the far edge and
    /// `fraction = 0` at the near one — the two ends of a drag still produce a picture on both sides
    /// (zero pixels on one side is a legitimate state: the user dragged the line off the edge).
    public func dividerPixel(canvas: ImageSize) -> Int {
        let extent = axis == .vertical ? canvas.width : canvas.height
        let raw = (fraction * Double(extent)).rounded()
        return min(max(Int(raw.isFinite ? raw : 0), 0), extent)
    }

    /// Which source owns canvas pixel `(x, y)`.
    ///
    /// The line covers `lineWidth` pixels starting at `dividerPixel - lineWidth/2`, i.e. for the
    /// default index 200 the columns 199 and 200. Everything before it is `.original`, everything
    /// from the end of the line on is `.edited` — a half-open partition, so every pixel has exactly
    /// one owner.
    public func side(x: Int, y: Int, canvas: ImageSize) -> CompareSide {
        let p = axis == .vertical ? x : y
        let d = dividerPixel(canvas: canvas)
        let half = Self.lineWidth / 2
        if p >= d - half && p < d - half + Self.lineWidth { return .divider }
        return p < d ? .original : .edited
    }

    /// The composite's boundary, in the form the kernel is handed: the divider's pixel index on the
    /// axis, the axis itself, and the line width. `compareParams(canvas:)` is the one place a
    /// `CompareSplit` becomes numbers.
    func compareParams(canvas: ImageSize) -> (divider: Float, axis: Float, lineWidth: Float) {
        (Float(dividerPixel(canvas: canvas)),
         axis == .vertical ? 0 : 1,
         Float(Self.lineWidth))
    }
}
