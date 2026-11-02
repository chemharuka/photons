import CoreGraphics
import CoreImage
import Foundation

/// 236 — **Apple's own white-balance eyedropper**.
///
/// `CIRAWFilter.neutralLocation` is the native dropper: assign an `(x, y)` pixel and the colour
/// engine solves the neutral in the **RAW domain**, then reports the answer through the same two
/// properties the document already stores (`neutralTemperature` / `neutralTint`). The decoder does
/// the work, so the result does not depend on anything that happened after the decode (tone map,
/// output primaries, an S1 3×3, a mask, a preview), and there is no iteration to run.
///
/// **Coordinates, measured on this machine (macOS 27, `CIRAWFilter.h:190-193`).**
///
/// `CIRAWFilter` hands back an **upright** image and honours the container's EXIF orientation
/// (`RAWDecoder` relies on the same fact), so the coordinates are *not* native sensor coordinates:
/// they are pixels of that upright output. Two details are easy to get wrong and are pinned by
/// `WhiteBalanceSectionTests`:
///
///   1. the origin is the **bottom-left** of the upright picture (Core Image's convention), while
///      `LoupeController`'s source coordinates are top-left; and
///   2. the y axis therefore has to be flipped against the upright height — not rotated by the EXIF
///      tag (the filter already did that rotation).
///
/// Evidence (synthetic `chart256.dng`, whose neutral cells are row 0–1, and `L1030409.dng`,
/// orientation 8): on the chart, the row-1 centre at top-left y = 48 reads back 6494 K / +0.2 only
/// when assigned y = 512 − 1 − 48 = 463; assigning 48 returns 7443 K / −88, which is a coloured
/// patch. On the oriented photo, the assigned point that makes a chosen patch neutral is the
/// bottom-left conversion of that patch's upright top-left position, not its native sensor
/// coordinate. The filter's output extent is already upright, so no EXIF lookup enters here.
///
/// A file the filter refuses, or a point whose answer is outside the document's range, returns
/// `nil`; the caller then keeps the iterative `WhiteBalanceDropperRefiner` as the fallback (see
/// `WhiteBalanceCommands`).
public enum WhiteBalanceNativeDropper {

    /// One click: the file, the **uncropped upright source pixel** the loupe resolved, and the
    /// upright height that turns it into `CIRAWFilter`'s bottom-left coordinate.
    public struct Probe: Sendable, Equatable {
        public let url: URL
        public let sourceX: Int
        public let sourceY: Int
        /// Full-resolution upright height (the source frame, not the decoded rung).
        public let uprightHeight: Int

        public init(url: URL, sourceX: Int, sourceY: Int, uprightHeight: Int) {
            self.url = url
            self.sourceX = sourceX
            self.sourceY = sourceY
            self.uprightHeight = uprightHeight
        }

        /// The one coordinate conversion. Top-left source pixel → `CIRAWFilter.neutralLocation`
        /// (upright output, bottom-left origin). Kept as a separate function so a test can pin the
        /// flip without opening a decoder.
        public static func neutralLocation(sourceX: Int, sourceY: Int,
                                           uprightHeight: Int) -> CGPoint {
            // `uprightHeight - 1` is the bottom row; clamp a click on the last row to it.
            let y = max(0, min(uprightHeight - 1, uprightHeight - 1 - sourceY))
            return CGPoint(x: CGFloat(sourceX), y: CGFloat(y))
        }

        public var neutralLocation: CGPoint {
            Self.neutralLocation(sourceX: sourceX, sourceY: sourceY,
                                 uprightHeight: uprightHeight)
        }
    }

    /// The pair Apple's decoder reports for a point, or `nil` when the point has no in-range answer.
    ///
    /// Fast enough for a click: this opens a filter and reads two properties; it does not render a
    /// frame. The caller still runs it off the main thread (`WhiteBalanceCommands.beginNativeDropper`)
    /// because constructing a `CIRAWFilter` reads the file's metadata.
    public static func whiteBalance(at probe: Probe) -> WhiteBalance? {
        whiteBalance(url: probe.url, neutralLocation: probe.neutralLocation)
    }

    /// The seam the tests use to prove the coordinate convention: same file, an arbitrary
    /// `neutralLocation`.
    public static func whiteBalance(url: URL, neutralLocation: CGPoint) -> WhiteBalance? {
        guard let filter = CIRAWFilter(imageURL: url) else { return nil }
        filter.neutralLocation = neutralLocation
        return whiteBalance(readBackFrom: filter)
    }

    /// The pair the filter currently reports, accepted only inside the document's own range.
    ///
    /// `neutralLocation` on a point the decoder cannot neutralise returns wild values (measured:
    /// 100000 K / −1030 on a chart cell when the coordinate was off by the y flip), so the range is
    /// the cheap way to tell "a real answer" from "no answer" — and it is the same range `commit`
    /// will clamp to, so accepting a value here cannot silently become a different one there.
    static func whiteBalance(readBackFrom filter: CIRAWFilter) -> WhiteBalance? {
        let temperature = Double(filter.neutralTemperature)
        let tint = Double(filter.neutralTint)
        guard temperature.isFinite, tint.isFinite,
              WhiteBalance.temperatureRange.contains(temperature),
              WhiteBalance.tintRange.contains(tint) else { return nil }
        return WhiteBalance(temperature: temperature, tint: tint)
    }
}
