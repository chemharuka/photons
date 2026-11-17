import Foundation
import PhotonsCore

/// A planning range, not an encoded byte count. Compression depends on image content; estimating
/// from dimensions keeps the export sheet responsive even for very large panoramas.
public struct ExportFileSizeEstimate: Equatable, Sendable {
    public let lowerBytes: Int64
    public let upperBytes: Int64
    public let fileCount: Int

    public static func total(_ estimates: [Self]) -> Self? {
        guard !estimates.isEmpty else { return nil }
        func sum(_ values: [Int64]) -> Int64 {
            values.reduce(0) { a, b in
                let (result, overflow) = a.addingReportingOverflow(b)
                return overflow ? Int64.max : result
            }
        }
        return Self(lowerBytes: sum(estimates.map(\.lowerBytes)), upperBytes: sum(estimates.map(\.upperBytes)),
                    fileCount: estimates.reduce(0) { $0 + $1.fileCount })
    }
}

public enum ExportFileSizeEstimator {
    public static func estimate(contents: [ImageSize], preset: ExportPreset, linearDNG: Bool = false) -> ExportFileSizeEstimate? {
        guard !contents.isEmpty else { return nil }
        var estimates: [ExportFileSizeEstimate] = []
        for content in contents {
            guard content.width > 0, content.height > 0 else { return nil }
            let scale = preset.renderScale(content: content)
            guard scale.isFinite, scale > 0,
                  Double(content.width) * scale < Double(Int.max),
                  Double(content.height) * scale < Double(Int.max) else { return nil }
            let size: ImageSize
            if linearDNG {
                // LinearDNGWriter uses Int(CIImage.extent), rather than the display renderer's rounding.
                let w = Double(content.width) * scale, h = Double(content.height) * scale
                guard w < Double(Int.max), h < Double(Int.max) else { return nil }
                size = ImageSize(width: max(1, Int(w)), height: max(1, Int(h)))
            } else {
                size = ExportSizing.outputSize(content: content, scale: scale)
            }
            guard let estimate = file(output: size, preset: preset, linearDNG: linearDNG) else { return nil }
            estimates.append(estimate)
        }
        return .total(estimates)
    }

    /// `output` is already resized. Gain-map edge trimming is applied here, just as in BatchExporter.
    public static func file(output: ImageSize, preset: ExportPreset, linearDNG: Bool = false) -> ExportFileSizeEstimate? {
        guard output.width > 0, output.height > 0 else { return nil }
        var size = output
        let gainMap = !linearDNG && preset.isHDR && preset.hdrKind == .gainMap
        let mapPlan = GainMapSizing.plan(size, halfSize: preset.hdr?.halfSize ?? false)
        if gainMap { size = mapPlan.output }
        let pixels = Double(size.width) * Double(size.height)
        let quality = preset.quality.isFinite ? min(1, max(0, preset.quality)) : 0.85
        // Broad photographic ranges; flat graphics can be smaller and sensor noise can be larger.
        let jpegRate = 0.08 + 1.2 * pow(quality, 6)
        let overhead = 16_384.0 + (preset.effectiveWriteXMP ? 8_192 : 0)
        var lower: Double
        var upper: Double
        if linearDNG {
            // Lossless 16-bit RGB JPEG tiles, plus the embedded 512-pixel preview and metadata.
            let tiles = ceil(Double(size.width) / 256) * ceil(Double(size.height) / 256)
            let raw = tiles * 256 * 256 * 6
            lower = raw * 0.3 + 65_536
            upper = raw * 1.05 + 262_144 + tiles * 256
        } else {
            let depthFactor = Double(preset.effectiveBitDepth) / 8
            switch preset.format {
            case .jpeg, .heic, .avif:
                let codecFactor: Double = preset.format == .jpeg ? 1 : (preset.format == .heic ? 0.65 : 0.55)
                let rate = jpegRate * codecFactor * depthFactor
                lower = pixels * rate * 0.35
                upper = pixels * rate * 2
                if gainMap {
                    let mapPixels = Double(mapPlan.gainMap.width) * Double(mapPlan.gainMap.height)
                    let channels: Double = preset.hdr?.gainMap == .apple ? 0.4 : 1
                    lower += mapPixels * rate * 0.1 * channels + 8_192
                    upper += mapPixels * rate * 0.8 * channels + 32_768
                }
            case .png:
                let raw = pixels * 3 * depthFactor
                lower = raw * 0.25
                upper = raw * 1.05
            case .tiff:
                // ImageIO's default TIFF is uncompressed; allow RGB/RGBX storage and directory overhead.
                lower = pixels * 3 * depthFactor
                upper = pixels * 4 * depthFactor + 65_536
            }
        }
        func bytes(_ value: Double) -> Int64 {
            guard value.isFinite, value < Double(Int64.max) else { return Int64.max }
            return max(1, Int64(value.rounded(.up)))
        }
        return ExportFileSizeEstimate(lowerBytes: bytes(lower + overhead), upperBytes: bytes(upper + overhead), fileCount: 1)
    }
}
