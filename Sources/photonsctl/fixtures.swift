import Foundation
import CoreGraphics
import ImageIO
import PhotonsCatalog

// MARK: - deterministic synthetic photos (acceptance fixtures, not product code)

/// Generates N small JPEGs with *real* EXIF + XMP embedded, so the import path exercises the same
/// metadata code as a RAW would (`CGImageSourceCopyMetadataAtIndex`), not a shortcut.
func cmdFixtures(_ a: Args) throws {
    guard let dirPath = a.positional.first else {
        die("fixtures <dir> [--count N] [--dupes PCT] [--size WxH]")
    }
    let dir = URL(fileURLWithPath: (dirPath as NSString).expandingTildeInPath)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let count = a.value("--count").flatMap(Int.init) ?? 100
    let dupesPercent = max(0, min(50, a.value("--dupes").flatMap(Int.init) ?? 10))
    let size = {
        guard let s = a.value("--size") else { return (width: 320, height: 240) }
        let parts = s.lowercased().split(separator: "x")
        guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) else { return (320, 240) }
        return (w, h)
    }()

    let cameras = [("LEICA CAMERA AG", "LEICA SL3"), ("Canon", "EOS R5"), ("Nikon", "Z8"),
                   ("Sony", "A7RV"), ("FUJIFILM", "X-T5")]
    let labels = ["Red", "Yellow", "Green", "Blue", "Purple", "None"]

    var written = 0
    for i in 0..<count {
        let name = String(format: "IMG_%05d.jpg", i)
        let url = dir.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }

        // The last `dupesPercent`% of files are byte-identical copies of earlier ones, so the
        // duplicate count is exact and the acceptance can assert on it.
        let dupeCount = count * dupesPercent / 100
        if dupeCount > 0, i >= count - dupeCount {
            let source = dir.appendingPathComponent(String(format: "IMG_%05d.jpg", i - (count - dupeCount)))
            if FileManager.default.fileExists(atPath: source.path) {
                try FileManager.default.copyItem(at: source, to: url)
                written += 1
                continue
            }
        }

        let camera = cameras[i % cameras.count]
        let day = 1 + (i % 27)
        let month = 3 + (i % 6)
        let iso = 100 * (1 + (i % 6))
        let rating = i % 6
        let label = rating == 0 ? labels[5] : labels[rating - 1]

        let image = makeImage(width: size.width, height: size.height, seed: i)
        let metadata = makeMetadata(rating: rating, label: label,
                                    keywords: i % 3 == 0 ? ["travel", "coast"] : ["test"])
        let properties: [String: Any] = [
            kCGImagePropertyExifDictionary as String: [
                kCGImagePropertyExifDateTimeOriginal as String: String(format: "2026:%02d:%02d 10:%02d:00", month, day, i % 60),
                kCGImagePropertyExifOffsetTimeOriginal as String: "+08:00",
                kCGImagePropertyExifISOSpeedRatings as String: [iso],
                kCGImagePropertyExifFocalLength as String: Double(35 + iso % 40),
                kCGImagePropertyExifFNumber as String: 2.8,
                kCGImagePropertyExifExposureTime as String: 0.004,
            ],
            kCGImagePropertyTIFFDictionary as String: [
                kCGImagePropertyTIFFMake as String: camera.0,
                kCGImagePropertyTIFFModel as String: camera.1,
            ],
            kCGImagePropertyOrientation as String: 1,
            kCGImageDestinationLossyCompressionQuality as String: 0.85,
        ]
        let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)
        guard let dest else { throw CatalogError.fileOperationFailed("cannot create \(url.lastPathComponent)") }
        CGImageDestinationAddImageAndMetadata(dest, image, metadata, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw CatalogError.fileOperationFailed("cannot finalize \(url.lastPathComponent)")
        }
        written += 1
    }
    note("fixtures   \(written) files in \(dir.path)  (\(size.width)×\(size.height), dupes \(dupesPercent)%)")
}

private func makeImage(width: Int, height: Int, seed: Int) -> CGImage {
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let o = (y * width + x) * 4
            // Deterministic, high-frequency-ish content: different files must have different bytes.
            pixels[o] = UInt8((x &* 7 &+ seed &* 13) & 0xFF)
            pixels[o + 1] = UInt8((y &* 11 &+ seed &* 29) & 0xFF)
            pixels[o + 2] = UInt8(((x ^ y) &+ seed &* 3) & 0xFF)
            pixels[o + 3] = 255
        }
    }
    let provider = CGDataProvider(data: Data(pixels) as CFData)!
    return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                   bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: false,
                   intent: .defaultIntent)!
}

/// XMP only. EXIF (dates, ISO, lens…) has to go through the *properties* dictionary: ImageIO's XMP
/// serializer silently drops `exif:DateTimeOriginal` and ISO, so writing them as XMP produces a file
/// that looks right in a dump but has no EXIF — which is exactly the bug this generator exists to catch.
private func makeMetadata(rating: Int, label: String, keywords: [String]) -> CGImageMetadata {
    let md = CGImageMetadataCreateMutable()
    func set(_ path: String, _ value: CFString) {
        _ = CGImageMetadataSetValueWithPath(md, nil, path as CFString, value)
    }
    func setInt(_ path: String, _ value: Int) {
        _ = CGImageMetadataSetValueWithPath(md, nil, path as CFString, NSNumber(value: value))
    }

    setInt("xmp:Rating", rating)
    set("xmp:Label", label as CFString)
    set("xmp:CreatorTool", "photonsctl fixtures" as CFString)

    let dcNamespace = "http://purl.org/dc/elements/1.1/" as CFString
    if let tag = CGImageMetadataTagCreate(dcNamespace, "dc" as CFString, "subject" as CFString,
                                          .arrayUnordered, keywords as CFArray) {
        _ = CGImageMetadataSetTagWithPath(md, nil, "dc:subject" as CFString, tag)
    }
    return md
}
