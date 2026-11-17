import Foundation
import CoreImage
import PhotonsCore
import PhotonsLocalization

public enum SliceResampling: String, Codable, CaseIterable, Sendable {
    case lanczosSharp = "lanczos_sharp", lanczos
    case bicubicSharp = "bicubic_sharp", bicubic, bilinear, nearest

    public var title: String { L10n.tr("slices.resampling.\(rawValue)") }
    var sharpens: Bool { self == .lanczosSharp || self == .bicubicSharp }
}

public enum SliceDynamicRange: String, Codable, CaseIterable, Sendable {
    case hdr, sdr
    public static var hdrAvailable: Bool {
        if #available(macOS 14.1, *) { return true }
        return false
    }
}

public struct SliceSettings: Codable, Equatable, Sendable {
    public var width = 3000
    public var height = 4000
    public var fill = 90.0
    public var quality = 95
    public var resampling: SliceResampling = .lanczosSharp
    public var dynamicRange: SliceDynamicRange = SliceDynamicRange.hdrAvailable ? .hdr : .sdr
    public init() {}

    public static let resolutions = [2400, 2800, 4000]

    public func validate() throws {
        guard Self.resolutions.contains(max(width, height)),
              min(width, height) * 4 == max(width, height) * 3 else {
            throw SliceError.invalid("slices.error.size")
        }
        guard fill.isFinite, (10...98).contains(fill), (60...100).contains(quality) else {
            throw SliceError.invalid("slices.error.settings")
        }
    }
}

public enum SliceError: LocalizedError {
    case invalid(String)
    case exists(URL)
    public var errorDescription: String? {
        switch self {
        case .invalid(let key): return L10n.tr(key)
        case .exists(let url): return L10n.tr("slices.error.exists", url.path)
        }
    }
}

/// Integer geometry mirrors pano_slicer/slicer.py, including Python's ties-to-even rounding.
/// ImageSize is the upright, edited image size, not the sensor or embedded thumbnail size.
public struct SliceLayout: Equatable, Sendable {
    public let count: Int
    public let tileWidth: Int
    public let tileHeight: Int
    public let photoWidth: Int
    public let photoHeight: Int
    public let x: Int
    public let y: Int
    public var canvasWidth: Int { count * tileWidth }

    private static func validateSource(_ size: ImageSize) throws {
        guard size.width > 0, size.height > 0, size.width <= 800_000_000,
              size.height <= 800_000_000, size.width * size.height <= 800_000_000 else {
            throw SliceError.invalid("slices.error.sourceSize")
        }
    }

    public static func sliceCount(size: ImageSize, settings: SliceSettings) throws -> Int {
        try validateSource(size)
        try settings.validate()
        let denominator = size.height * settings.width
        let count = max(1, (size.width * settings.height + denominator - 1) / denominator)
        guard count <= 100 else { throw SliceError.invalid("slices.error.tooLarge") }
        return count
    }

    public static func maximumFill(size: ImageSize, settings: SliceSettings) throws -> Double {
        let cw = Double(try sliceCount(size: size, settings: settings) * settings.width)
        let w = Double(size.width), h = Double(size.height), th = Double(settings.height)
        let limit = w >= h ? 98 * th * w / (cw * h) : 98 * cw * h / (th * w)
        return floor(min(98, limit) * 10) / 10
    }

    public static func plan(size: ImageSize, settings: SliceSettings) throws -> SliceLayout {
        let count = try sliceCount(size: size, settings: settings)
        guard settings.fill <= (try maximumFill(size: size, settings: settings)) + 0.001 else {
            throw SliceError.invalid("slices.error.fill")
        }
        let w = Double(size.width), h = Double(size.height)
        let pw: Int, ph: Int
        if w >= h {
            pw = max(1, Int((Double(count * settings.width) * settings.fill / 100).rounded(.toNearestOrEven)))
            ph = max(1, Int((Double(pw) * h / w).rounded(.toNearestOrEven)))
        } else {
            ph = max(1, Int((Double(settings.height) * settings.fill / 100).rounded(.toNearestOrEven)))
            pw = max(1, Int((Double(ph) * w / h).rounded(.toNearestOrEven)))
        }
        guard pw * ph <= 240_000_000 else { throw SliceError.invalid("slices.error.tooLarge") }
        return SliceLayout(count: count, tileWidth: settings.width, tileHeight: settings.height,
                           photoWidth: pw, photoHeight: ph,
                           x: (count * settings.width - pw) / 2, y: (settings.height - ph) / 2)
    }
}

/// A group is prepared once: the SDR projection, resampling and sharpening precede slicing.
/// Every tile carries the same gamut, reference white, gain-map range and full-size map.
public struct PreparedSlices: Sendable {
    public let photo: DisplayImage
    public let layout: SliceLayout
    public let headroom: Double

    public init(photo: DisplayImage, layout: SliceLayout, settings: SliceSettings) throws {
        self.layout = layout
        let resized = try SlicePixels.resize(photo, width: layout.photoWidth, height: layout.photoHeight,
                                             method: settings.resampling, projectSDRAfterResampling: true)
        self.photo = settings.dynamicRange == .hdr ? resized : resized.withLinear(nil)
        if settings.dynamicRange == .hdr {
            guard let linear = self.photo.linear else { throw SliceError.invalid("slices.error.noHDR") }
            // A dark tile must not auto-downgrade to SDR or acquire its own gain-map ceiling.
            // Include the actual HDR/SDR ratio as well as the absolute peak so the shared map
            // can reconstruct a highlight whose SDR base was rolled off below diffuse white.
            var peak = max(1.0001, GainMapHEIC.peak(of: linear))
            let base = self.photo.rgba
            for i in stride(from: 0, to: base.count, by: 4) {
                for c in 0..<3 {
                    let hdr = Double(max(0, Float(linear.rgba[i+c])))
                    let sdr = Double(GainMapHEIC.srgbToLinear(max(0, Float(base[i+c]))))
                    peak = max(peak, (hdr + 0.00001) / (sdr + 0.00001))
                }
            }
            headroom = peak
        } else { headroom = 1 }
    }

    public func tile(at index: Int) throws -> DisplayImage {
        guard (0..<layout.count).contains(index) else { throw SliceError.invalid("slices.error.tile") }
        func cut(_ rgba: [Float16]) -> [Float16] {
            // Diffuse white = 1 in BOTH the SDR base and linear HDR frame. Adding the border
            // after the global projection keeps it white and gives it exactly zero gain.
            var out = [Float16](repeating: 1, count: layout.tileWidth * layout.tileHeight * 4)
            let left = index * layout.tileWidth
            let start = max(left, layout.x), end = min(left + layout.tileWidth, layout.x + layout.photoWidth)
            if end > start {
                rgba.withUnsafeBufferPointer { source in
                    out.withUnsafeMutableBufferPointer { target in
                        for row in 0..<layout.photoHeight {
                            let src = (row * layout.photoWidth + start - layout.x) * 4
                            let dst = ((row + layout.y) * layout.tileWidth + start - left) * 4
                            target.baseAddress!.advanced(by: dst).update(from: source.baseAddress!.advanced(by: src),
                                                                      count: (end - start) * 4)
                        }
                    }
                }
            }
            return out
        }
        let linear = photo.linear.map { LinearPixels(width: layout.tileWidth, height: layout.tileHeight,
                                                      rgba: cut($0.rgba), primaries: $0.primaries) }
        return DisplayImage(width: layout.tileWidth, height: layout.tileHeight, rgba: cut(photo.rgba),
                            primaries: photo.primaries, bitDepth: 8, linear: linear)
    }
}

public enum SlicePixels {
    /// Core Image operates on the samples without a second colour conversion. HDR samples stay
    /// half-float and extended-range. Both companions use the same transform before any cuts.
    public static func resize(_ image: DisplayImage, width: Int, height: Int,
                              method: SliceResampling, projectSDRAfterResampling: Bool = false) throws -> DisplayImage {
        guard image.width > 0, image.height > 0, width > 0, height > 0,
              width <= 800_000_000, height <= 800_000_000, width * height <= 240_000_000,
              image.rgba.count == image.width * image.height * 4,
              image.linear == nil || (image.linear!.width == image.width && image.linear!.height == image.height
                                     && image.linear!.rgba.count == image.rgba.count) else {
            throw SliceError.invalid("slices.error.sourceSize")
        }
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(),
                                          .workingFormat: CIFormat.RGBAh, .cacheIntermediates: false])
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        let sx = Double(width) / Double(image.width), sy = Double(height) / Double(image.height)
        func scale(_ pixels: [Float16], linear: Bool) -> [Float16] {
            let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
            var ci = CIImage(bitmapData: data, bytesPerRow: image.width * 8,
                             size: CGSize(width: image.width, height: image.height), format: .RGBAh, colorSpace: nil)
            switch method {
            case .lanczos, .lanczosSharp:
                ci = ci.applyingFilter("CILanczosScaleTransform", parameters: ["inputScale": sy, "inputAspectRatio": sx / sy])
            case .bicubic, .bicubicSharp:
                ci = ci.applyingFilter("CIBicubicScaleTransform", parameters: ["inputScale": sy, "inputAspectRatio": sx / sy,
                                                                             "inputB": 0.0, "inputC": 0.5])
            case .bilinear:
                ci = ci.samplingLinear().transformed(by: CGAffineTransform(scaleX: sx, y: sy))
            case .nearest:
                ci = ci.samplingNearest().transformed(by: CGAffineTransform(scaleX: sx, y: sy))
            }
            ci = ci.cropped(to: rect)
            if method.sharpens {
                ci = ci.clampedToExtent().applyingFilter("CIUnsharpMask", parameters: ["inputRadius": 0.65, "inputIntensity": 0.65])
                    .cropped(to: rect)
            }
            var out = [Float16](repeating: 0, count: width * height * 4)
            context.render(ci, toBitmap: &out, rowBytes: width * 8, bounds: rect, format: .RGBAh, colorSpace: nil)
            for i in stride(from: 0, to: out.count, by: 4) {
                for c in 0..<3 {
                    let value = Float(out[i+c])
                    out[i+c] = Float16(value.isFinite ? min(max(0, value), linear ? 65504 : 1) : 0)
                }
                out[i+3] = 1
            }
            return out
        }
        let linear = image.linear.map { LinearPixels(width: width, height: height, rgba: scale($0.rgba, linear: true),
                                                      primaries: $0.primaries) }
        // Sharpen one linear photo, then project its SDR companion once for the whole group.
        // Sharpening already-tonemapped SDR independently can make a dark edge hit zero while
        // the HDR edge remains positive, producing an artificial, enormous gain ratio.
        if projectSDRAfterResampling, let linear { return linear.displaySDR(bitDepth: 8, toneMap: .global) }
        return DisplayImage(width: width, height: height, rgba: scale(image.rgba, linear: false),
                            primaries: image.primaries, bitDepth: 8, linear: linear)
    }
}

public struct SliceManifest: Codable {
    public let source: String
    public let settings: SliceSettings
    public let files: [String]
    public let hdr: GroupHDR?
    public struct GroupHDR: Codable {
        public let headroom: Double
        public let referenceWhite: Double
        public let gainMap: String
        public let halfSize: Bool
        public let colorSpace: String
    }
}

public enum SocialMediaSliceExporter {
    private static var gainMap: HDRExport.GainMap {
        if #available(macOS 15, *) { return .iso }
        return .apple
    }
    public static func outputDirectory(source: URL, parent: URL? = nil) -> URL {
        (parent ?? source.deletingLastPathComponent()).appendingPathComponent(
            "slice_" + source.deletingPathExtension().lastPathComponent, isDirectory: true)
    }

    @discardableResult
    public static func write(group: PreparedSlices, source: URL, settings: SliceSettings, to destination: URL,
                             replace: Bool = false, cancellation: CancellationToken = CancellationToken(),
                             progress: (Int, Int) -> Void = { _, _ in }) throws -> [URL] {
        try settings.validate()
        let fm = FileManager.default
        let parent = destination.deletingLastPathComponent()
        let stage = parent.appendingPathComponent(".pano_slicer_\(UUID().uuidString)", isDirectory: true)
        let backup = parent.appendingPathComponent(".pano_slicer_backup_\(UUID().uuidString)", isDirectory: true)
        func check() throws { if cancellation.isCancelled { throw CancellationError() } }
        try check()
        if fm.fileExists(atPath: destination.path) && !replace { throw SliceError.exists(destination) }
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stage) }
        let stem = source.deletingPathExtension().lastPathComponent
        let names = (1...group.layout.count).map { String(format: "%@_slice_%03d.jpg", stem, $0) }
        for (index, name) in names.enumerated() {
            try check()
            try autoreleasepool {
                let tile = try group.tile(at: index)
                let url = stage.appendingPathComponent(name)
                if settings.dynamicRange == .hdr {
                    guard let linear = tile.linear else { throw SliceError.invalid("slices.error.noHDR") }
                    try GainMapHEIC.write(sdr: tile, linear: linear, to: url,
                        options: HDRGainMapOptions(gainMap: gainMap, halfSize: false, headroom: .manual(group.headroom),
                            quality: Double(settings.quality) / 100, forceGainMap: true), format: .jpeg)
                } else {
                    try Exporter.write(tile, to: url, options: ExportOptions(format: .jpeg, quality: Double(settings.quality) / 100))
                }
            }
            progress(index + 1, names.count)
        }
        let manifest = SliceManifest(source: source.path, settings: settings, files: names,
            hdr: settings.dynamicRange == .hdr ? .init(headroom: group.headroom, referenceWhite: 1,
                gainMap: gainMap == .iso ? "ISO 21496-1 RGB" : "Apple HDR", halfSize: false,
                colorSpace: group.photo.primaries.rawValue) : nil)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(manifest).write(to: stage.appendingPathComponent("slices.json"))
        try check()

        // Stage the complete group before replacing anything. Preserve unrelated files, and
        // only retire old tiles named in our manifest (including manifests from the Python app).
        var hadDestination = false
        if fm.fileExists(atPath: destination.path) {
            guard replace else { throw SliceError.exists(destination) }
            let values = try destination.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw SliceError.invalid("slices.error.destination")
            }
            var managed = Set(names + ["slices.json"])
            if let data = try? Data(contentsOf: destination.appendingPathComponent("slices.json")),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let old = json["files"] as? [String] {
                for name in old where name == (name as NSString).lastPathComponent
                    && name.hasPrefix(stem + "_slice_") && name.hasSuffix(".jpg") { managed.insert(name) }
            }
            for url in try fm.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil)
                where !managed.contains(url.lastPathComponent) {
                try check()
                try fm.copyItem(at: url, to: stage.appendingPathComponent(url.lastPathComponent))
            }
            try check()
            try fm.moveItem(at: destination, to: backup)
            hadDestination = true
        }
        do { try fm.moveItem(at: stage, to: destination) }
        catch {
            if hadDestination { try fm.moveItem(at: backup, to: destination) }
            throw error
        }
        if hadDestination { try? fm.removeItem(at: backup) }
        return names.map { destination.appendingPathComponent($0) }
    }
}
