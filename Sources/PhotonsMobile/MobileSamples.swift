#if os(iOS)
import Foundation
import CoreGraphics
import ImageIO

/// Generated fixtures for CI, plus optional owner-supplied Boston RAWs in local preview builds.
enum MobileSamples {
    static var boston: [URL] {
        (Bundle.main.urls(forResourcesWithExtension: "3FR", subdirectory: "BostonSamples") ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    static func create(in directory: URL? = nil) throws -> [URL] {
        let dir = directory ?? FileManager.default.temporaryDirectory.appendingPathComponent("PhotonsSamples-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try (0..<3).map { n in
            let width = 768, height = 512, offset = n * 220
            var pixels = [UInt8](repeating: 255, count: width * height * 4)
            for y in 0..<height { for x in 0..<width {
                let worldX = x + offset
                let h = UInt32(truncatingIfNeeded: (worldX / 4) &* 73856093 ^ (y / 4) &* 19349663)
                let checker = (worldX / 64 + y / 64) % 2
                let noise = Int(h % 67)
                let i = (y * width + x) * 4
                pixels[i] = UInt8(45 + noise + checker * 60)
                pixels[i+1] = UInt8(45 + noise + y * 80 / height)
                pixels[i+2] = UInt8(45 + noise + worldX * 60 / 1208)
            } }
            let data = Data(pixels) as CFData
            let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: CGDataProvider(data: data)!, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
            let url = dir.appendingPathComponent("Sample-0\(n + 1).tiff")
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.tiff" as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
            CGImageDestinationAddImage(destination, image, [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: "CFV 100C", kCGImagePropertyTIFFCompression: 5]] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
            return url
        }
    }
}
#endif
