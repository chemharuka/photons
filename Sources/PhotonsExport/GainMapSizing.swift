import Foundation
import PhotonsCore

// MARK: - 163 §1.6 · half-size gain maps are even × even
//
// A gain map is exactly half the base in each axis. A HEIF auxiliary item cannot express an odd
// half, so the base itself is made even first: an odd source/crop loses its right/bottom 1 px
// (`floor`), and the gain map is then exactly `base / 2`. This is a real pixel change, so it is
// reported — in the sheet (before the export) and in the batch's non-fatal warnings (after it).

/// How much the right/bottom edges are trimmed to make a half-size gain map legal.
public struct HalfSizeCrop: Sendable, Equatable {
    public var dx: Int
    public var dy: Int

    public init(dx: Int, dy: Int) {
        self.dx = max(0, dx)
        self.dy = max(0, dy)
    }

    public static let none = HalfSizeCrop(dx: 0, dy: 0)

    public var isNeeded: Bool { dx > 0 || dy > 0 }

    /// `（右/下各 1 px）`, `（右 1 px）` or `（下 1 px）` — the parenthetical the UI and the note share.
    public var sideText: String {
        switch (dx > 0, dy > 0) {
        case (true, true): return "右/下各 \(dx) px"
        case (true, false): return "右 \(dx) px"
        case (false, true): return "下 \(dy) px"
        case (false, false): return ""
        }
    }

    /// The sheet's grey line; `nil` when nothing is cropped (the row is not built at all).
    public func hint(current: ImageSize) -> String? {
        guard isNeeded else { return nil }
        return "半尺寸需要偶数像素：当前 \(current.width)×\(current.height)，将裁到 "
            + "\(current.width - dx)×\(current.height - dy)（\(sideText)）"
    }

    /// The batch note — same numbers, past tense, and the (dx, dy) pair the metrics carry.
    public func exportNote(source: ImageSize) -> String {
        "半尺寸增益图：源 \(source.width)×\(source.height)，已裁 (\(dx),\(dy)) → "
            + "\(source.width - dx)×\(source.height - dy)（\(sideText)）"
    }
}

/// The sizes one half-size export will produce. Pure arithmetic, so the UI forecast, the batch crop
/// and the gain-map writer all read the same plan without allocating a pixel buffer.
public struct HalfSizePlan: Sendable, Equatable {
    public var input: ImageSize
    public var output: ImageSize
    public var gainMap: ImageSize
    public var crop: HalfSizeCrop

    public init(input: ImageSize, output: ImageSize, gainMap: ImageSize, crop: HalfSizeCrop) {
        self.input = input
        self.output = output
        self.gainMap = gainMap
        self.crop = crop
    }
}

public enum GainMapSizing {

    /// `halfSize == false` is the identity: full base, full map, no crop.
    public static func plan(_ size: ImageSize, halfSize: Bool) -> HalfSizePlan {
        guard halfSize else {
            return HalfSizePlan(input: size, output: size, gainMap: size, crop: .none)
        }
        let dx = size.width % 2
        let dy = size.height % 2
        let w = max(1, size.width - dx)
        let h = max(1, size.height - dy)
        return HalfSizePlan(input: size,
                            output: ImageSize(width: w, height: h),
                            gainMap: ImageSize(width: max(1, w / 2), height: max(1, h / 2)),
                            crop: HalfSizeCrop(dx: dx, dy: dy))
    }

    public static func plan(width: Int, height: Int, halfSize: Bool) -> HalfSizePlan {
        plan(ImageSize(width: width, height: height), halfSize: halfSize)
    }

    /// Trim the right/bottom edges. The linear companion is trimmed identically, so the gain-map
    /// ratio keeps referring to the same pixels as the base.
    public static func crop(_ image: DisplayImage, _ crop: HalfSizeCrop) -> DisplayImage {
        guard crop.isNeeded, image.width > crop.dx, image.height > crop.dy else { return image }
        let w = image.width - crop.dx
        let h = image.height - crop.dy
        var out = [Float16](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            let from = y * image.width * 4
            let to = y * w * 4
            for i in 0..<(w * 4) { out[to + i] = image.rgba[from + i] }
        }
        let linear = image.linear.map { GainMapSizing.crop($0, crop) }
        return DisplayImage(width: w, height: h, rgba: out, primaries: image.primaries,
                            bitDepth: image.bitDepth, linear: linear)
    }

    public static func crop(_ pixels: LinearPixels, _ crop: HalfSizeCrop) -> LinearPixels {
        guard crop.isNeeded, pixels.width > crop.dx, pixels.height > crop.dy else { return pixels }
        let w = pixels.width - crop.dx
        let h = pixels.height - crop.dy
        var out = [Float16](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            let from = y * pixels.width * 4
            let to = y * w * 4
            for i in 0..<(w * 4) { out[to + i] = pixels.rgba[from + i] }
        }
        return LinearPixels(width: w, height: h, rgba: out, primaries: pixels.primaries)
    }
}
