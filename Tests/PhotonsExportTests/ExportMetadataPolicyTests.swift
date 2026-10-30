import XCTest
import CryptoKit
import Darwin
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import PhotonsCore
@testable import PhotonsExport

/// 186 — the four metadata policies and GPS stripping, measured on the written file.
///
/// Every constant below was measured on the pre-186 `main` baseline with the exact fixture in this
/// file (file name, quality and canvas size are part of the contract).
///
/// Two different measurements per export, on purpose:
///
///   · the **XMP packet's** SHA-256 (`<?xpacket begin` … `<?xpacket end="w"?>`) — the bytes 186
///     filters. Stable across runs.
///   · the **whole file's** SHA-256 — has exactly two shapes on pre-186 `main` too: ImageIO's IIM
///     block comes out in Swift's per-process dictionary order, and the 8BIM 0x0425 digest follows
///     it. Both shapes are what `main` writes; which one a process produces is not deterministic, so
///     accepting the measured set is about Swift's hash seed, not about 186.
final class ExportMetadataPolicyTests: XCTestCase {

    // MARK: - baselines (measured on pre-186 `main`, same fixture)

    /// `.all` + `writeXMP: true`: the 25-key develop packet, byte for byte as 186 found it.
    private let legacyPacketSHA = "1323a4c44d29dd2cbea2fa3cbdea431f72331fbc31e8ecd774dad817c43285b6"
    private let legacyFileSHAs = [
        "3dc213f56a9be083938d2c0c9f16d0324b20169c02bd1d15f7e60ec62c7e345f",
        "47a948e04eddc4590ca211513735c5d14a03679ae27b3916c16ff746e0c9fbb2",
    ]
    /// `.all` + `writeXMP: false`: 107's ImageIO-composed packet, 16 keys. 186 must not move it.
    private let composedPacketSHA = "186c1bd738c80fe07aad301be948d487ee42a33fa982f2b455b8806005bbae0c"
    private let composedFileSHAs = [
        "035c32a062f074bd0d4916f8395380e71dc7a58b8b22f0e23bb84ea768d11c7e",
        "02c8e354ccbea69cf0811df0bd3de423096c01160df4b9edbafe9bba4407d23e",
    ]
    /// `.none` + `writeXMP: true`: no XMP at all (single shape — nothing is composed).
    private let noneSHA = "c3bbfc7dfd210672419411b5672e178747d95003cfbe29cc2ec54d11518778bc"

    // MARK: - harness

    private var scratch: URL!
    private var out: URL!
    private var source: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-policy-tests-\(UUID().uuidString)", isDirectory: true)
        out = scratch.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        source = try makeSourceJPEG()
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    // MARK: - fixture

    /// A camera-shaped source: EXIF/TIFF/GPS/IPTC blocks plus an XMP packet with keywords, rights,
    /// credit, a city and the `exif:GPS*` mirrors Lightroom writes.
    private func makeSourceJPEG() throws -> URL {
        let url = scratch.appendingPathComponent("src.jpg")
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))

        let xmp = CGImageMetadataCreateMutable()
        var err: Unmanaged<CFError>?
        for (uri, prefix) in [
            ("http://purl.org/dc/elements/1.1/", "dc"),
            ("http://ns.adobe.com/photoshop/1.0/", "photoshop"),
            ("http://ns.adobe.com/exif/1.0/", "exif"),
        ] {
            _ = CGImageMetadataRegisterNamespaceForPrefix(xmp, uri as CFString,
                                                          prefix as CFString, &err)
        }
        XCTAssertTrue(CGImageMetadataSetValueWithPath(
            xmp, nil, "dc:subject" as CFString, ["street", "night"] as CFArray))
        XCTAssertTrue(CGImageMetadataSetValueWithPath(
            xmp, nil, "dc:rights" as CFString, "© 2026 Ada" as CFString))
        XCTAssertTrue(CGImageMetadataSetValueWithPath(
            xmp, nil, "photoshop:Credit" as CFString, "Ada Lovelace" as CFString))
        XCTAssertTrue(CGImageMetadataSetValueWithPath(
            xmp, nil, "photoshop:City" as CFString, "Shanghai" as CFString))
        XCTAssertTrue(CGImageMetadataSetValueWithPath(
            xmp, nil, "exif:GPSLatitude" as CFString, "31,13.824N" as CFString))
        XCTAssertTrue(CGImageMetadataSetValueWithPath(
            xmp, nil, "exif:GPSLongitude" as CFString, "121,28.422E" as CFString))

        let properties: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifLensModel: "XF 23mm F1.4 R",
                kCGImagePropertyExifPixelXDimension: 64,
                kCGImagePropertyExifPixelYDimension: 48,
                kCGImagePropertyExifDateTimeOriginal: "2026:10:31 21:00:00",
            ],
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "FUJIFILM",
                kCGImagePropertyTIFFModel: "X-T5",
                kCGImagePropertyTIFFArtist: "Ada Lovelace",
                kCGImagePropertyTIFFCopyright: "© 2026 Ada",
            ],
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 31.2304,
                kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 121.4737,
                kCGImagePropertyGPSLongitudeRef: "E",
            ],
            // No `kCGImagePropertyIPTCDictionary`: ImageIO writes IIM datasets in Swift's
            // per-process dictionary order, which makes the file's SHA flip between two shapes
            // (see the class comment). Keywords and rights still travel in the XMP packet, which is
            // the thing a metadata policy filters.
        ]

        CGImageDestinationAddImageAndMetadata(dest, try sourceCGImage(), xmp,
                                              properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    private func sourceCGImage() throws -> CGImage {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 48,
                                              bitsPerComponent: 8, bytesPerRow: 0,
                                              space: space,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0.4, green: 0.5, blue: 0.6, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        return try XCTUnwrap(context.makeImage())
    }

    private func item(sourceURL: URL) -> ExportItem {
        var edit = EditModel.neutral
        edit.light.exposure = 0.75
        edit.color.vibrance = 20
        return ExportItem(id: "1", name: "src", edit: edit, sourceURL: sourceURL,
                          author: "Ada Lovelace", copyright: "© 2026 Ada")
    }

    private func image() -> DisplayImage {
        DisplayImage(width: 64, height: 48,
                     rgba: [Float16](repeating: 0.5, count: 64 * 48 * 4),
                     primaries: .displayP3, bitDepth: 8)
    }

    private func preset(policy: ExportMetadataPolicy, writeXMP: Bool,
                        removeLocation: Bool = false) -> ExportPreset {
        var p = ExportPreset(format: .jpeg, writeXMP: writeXMP)
        p.metadataPolicy = policy
        p.removeLocation = removeLocation
        return p
    }

    @discardableResult
    private func export(_ preset: ExportPreset, tag: String)
        throws -> (outcome: BatchExportOutcome, url: URL) {
        let directory = out.appendingPathComponent(tag, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let report = BatchExporter.run(items: [item(sourceURL: source)], preset: preset,
                                       outputDirectory: directory,
                                       render: { _, _ in self.image() })
        let outcome = try XCTUnwrap(report.written.first)
        return (outcome, try XCTUnwrap(outcome.fileURL))
    }

    private func sha256(_ url: URL) throws -> String {
        let digest = SHA256.hash(data: try Data(contentsOf: url))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// The packet's own bytes — `<?xpacket begin` through `<?xpacket end="w"?>` — which is exactly
    /// the region a metadata policy rewrites, and the only file region whose hash is stable across
    /// processes (see the class comment).
    private func packetSHA(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let begin = try XCTUnwrap(data.range(of: Data("<?xpacket begin".utf8)))
        let end = try XCTUnwrap(data.range(of: Data("<?xpacket end=\"w\"?>".utf8)))
        let packet = data.subdata(in: begin.lowerBound..<end.upperBound)
        return SHA256.hash(data: packet).map { String(format: "%02x", $0) }.joined()
    }

    private func fileXMPPaths(_ url: URL) -> [String] {
        guard let metadata = XMPReadback.metadata(of: url) else { return [] }
        return XMPReadback.paths(metadata)
    }

    private func properties(of url: URL) throws -> [String: Any] {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let raw = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil))
        if let d = raw as? [String: Any] { return d }
        let cd = raw as! [CFString: Any]
        var out: [String: Any] = [:]
        for (key, value) in cd { out[key as String] = value }
        return out
    }

    // MARK: - 1. legacy preset
    func testLegacyPresetDecodesToAllAndExportsIdentically() throws {
        // A preset written before 186: neither `metadataLevel` (`removeLocation` is 186's own key)
        // nor anything else that only exists today.
        let data = Data(#"{"format":"jpg","writeXMP":true}"#.utf8)
        let decoded = try JSONDecoder().decode(ExportPreset.self, from: data)
        XCTAssertEqual(decoded.metadataPolicy, .all)
        XCTAssertFalse(decoded.removeLocation)
        // Defaults are not written back: the preset the app saves is the preset it read.
        XCTAssertEqual(try decoded.data(), try JSONDecoder().decode(
            ExportPreset.self, from: try decoded.data()).data())

        let exported = try export(decoded, tag: "legacy")
        // The bytes 186 can touch: the develop packet, identical to what `main` wrote.
        XCTAssertEqual(try packetSHA(exported.url), legacyPacketSHA,
                       "a pre-186 preset must export the same XMP packet as before 186")
        // The container around it, up to ImageIO's per-process IIM ordering.
        let legacyFileSHA = try sha256(exported.url)
        XCTAssertTrue(legacyFileSHAs.contains(legacyFileSHA),
                      "legacy preset exported \(legacyFileSHA), which is not one of the shapes "
                      + "pre-186 `main` writes")
        XCTAssertEqual(fileXMPPaths(exported.url).count, 25)
        // And the same preset, spelled out with today's defaults, produces the same bytes.
        let explicit = try export(preset(policy: .all, writeXMP: true), tag: "legacy-explicit")
        XCTAssertEqual(try packetSHA(explicit.url), legacyPacketSHA)
    }

    // MARK: - 2. key lists

    func testPolicyKeyLists() throws {
        let all = try export(preset(policy: .all, writeXMP: true), tag: "keys-all")
        let allPaths = fileXMPPaths(all.url)
        print("KEYS|all|\(allPaths.joined(separator: ","))")
        XCTAssertEqual(allPaths.count, 25)
        XCTAssertEqual(allPaths, [
            "crs:Exposure2012", "crs:ProcessVersion", "crs:Version", "crs:Vibrance",
            "crs:WhiteBalance", "dc:creator", "dc:rights", "dc:subject",
            "exif:GPSLatitude", "exif:GPSLongitude", "exif:PixelXDimension",
            "exif:PixelYDimension", "exifEX:LensModel", "iio:hasIIM", "iio:hasXMP",
            "photons:highlightRecovery", "photons:processVersion", "photons:schemaVersion",
            "photons:settings", "photoshop:City", "photoshop:Credit", "photoshop:DateCreated",
            "tiff:Make", "tiff:Model", "tiff:Orientation",
        ])

        let allNoLocation = try export(preset(policy: .all, writeXMP: true, removeLocation: true),
                                       tag: "keys-all-noloc")
        let noLocationPaths = fileXMPPaths(allNoLocation.url)
        print("KEYS|all-noloc|\(noLocationPaths.joined(separator: ","))")
        XCTAssertEqual(noLocationPaths.count, 23)
        XCTAssertEqual(noLocationPaths, [
            "crs:Exposure2012", "crs:ProcessVersion", "crs:Version", "crs:Vibrance",
            "crs:WhiteBalance", "dc:creator", "dc:rights", "dc:subject",
            "exif:PixelXDimension", "exif:PixelYDimension", "exifEX:LensModel",
            "iio:hasIIM", "iio:hasXMP", "photons:highlightRecovery", "photons:processVersion",
            "photons:schemaVersion", "photons:settings", "photoshop:City", "photoshop:Credit",
            "photoshop:DateCreated", "tiff:Make", "tiff:Model", "tiff:Orientation",
        ])

        let copyright = try export(preset(policy: .copyrightOnly, writeXMP: true),
                                   tag: "keys-copyrightOnly")
        let sidecar = try XCTUnwrap(copyright.outcome.xmpURL)
        let copyrightMetadata = try XCTUnwrap(XMPReadback.metadata(fromXMP: sidecar))
        let copyrightPaths = XMPReadback.paths(copyrightMetadata)
        print("KEYS|copyrightOnly|\(copyrightPaths.joined(separator: ","))")
        // `iio:hasXMP` is ImageIO's own marker, added by the parser when it reads a packet back; it
        // is not a tag this writer put in the sidecar (its XML has only the two below).
        XCTAssertEqual(copyrightPaths, ["dc:rights", "iio:hasXMP", "photoshop:Credit"])
        XCTAssertEqual(copyrightPaths.filter { !$0.hasPrefix("iio:") },
                       ["dc:rights", "photoshop:Credit"])

        let none = try export(preset(policy: .none, writeXMP: true), tag: "keys-none")
        let nonePaths = fileXMPPaths(none.url)
        print("KEYS|none|\(nonePaths.joined(separator: ","))")
        XCTAssertTrue(nonePaths.isEmpty)
    }

    // MARK: - 3. GPS

    func testRemoveLocationDropsEveryGPSKey() throws {
        // (a) the embedded `.all` packet: no `exif:GPS*` mirror survives.
        let stripped = try export(preset(policy: .all, writeXMP: true, removeLocation: true),
                                  tag: "gps-packet")
        let metadata = try XCTUnwrap(XMPReadback.metadata(of: stripped.url))
        let gpsKeys = XMPReadback.paths(metadata).filter { $0.hasPrefix("exif:GPS") }
        XCTAssertTrue(gpsKeys.isEmpty, "GPS mirrors survived: \(gpsKeys)")

        // (b) the ImageIO-composed packet (writeXMP off) and the container's own GPS dictionary.
        let composed = try export(preset(policy: .all, writeXMP: false, removeLocation: true),
                                  tag: "gps-composed")
        let paths = fileXMPPaths(composed.url)
        XCTAssertTrue(paths.filter { $0.hasPrefix("exif:GPS") }.isEmpty,
                      "composed XMP still has GPS: \(paths)")
        let props = try properties(of: composed.url)
        let gps = props[kCGImagePropertyGPSDictionary as String] as? [String: Any] ?? [:]
        XCTAssertTrue(gps.isEmpty, "the EXIF GPS dictionary survived: \(gps)")
    }

    // MARK: - 4. `.none` wins over writeXMP

    func testNoneIsByteIdenticalToWriteXMPOff() throws {
        let on = try export(preset(policy: .none, writeXMP: true), tag: "none-on")
        let off = try export(preset(policy: .none, writeXMP: false), tag: "none-off")
        XCTAssertEqual(try sha256(on.url), try sha256(off.url))
        XCTAssertEqual(try sha256(on.url), noneSHA)
        for result in [on, off] {
            XCTAssertNil(result.outcome.xmpURL)
            let sidecar = result.url.deletingPathExtension().appendingPathExtension("xmp")
            XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path))
        }

        // 107's ImageIO-composed packet on `.all`/off is untouched by 186 — same bytes, same keys.
        let allOff = try export(preset(policy: .all, writeXMP: false), tag: "all-off")
        XCTAssertEqual(try packetSHA(allOff.url), composedPacketSHA)
        XCTAssertTrue(composedFileSHAs.contains(try sha256(allOff.url)))
        XCTAssertEqual(fileXMPPaths(allOff.url).count, 16)
    }

    // MARK: - 5. a failed packet leaves no half file

    func testFailedPacketLeavesNoHalfFile() throws {
        let directory = out.appendingPathComponent("fail", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // The sidecar's own name is taken by a directory, so `writeAtomically` cannot replace it.
        // A plain directory is not enough on this macOS (replaceItemAt happily swaps it for a file),
        // so it is pinned immutable for the duration of the export: the rename then fails and the
        // temporary file must be cleaned up.
        let blocker = directory.appendingPathComponent("src.xmp", isDirectory: true)
        try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: blocker.appendingPathComponent("keep.txt"))
        XCTAssertEqual(chflags(blocker.path, UInt32(UF_IMMUTABLE)), 0)
        defer { _ = chflags(blocker.path, 0) }

        let report = BatchExporter.run(items: [item(sourceURL: source)],
                                       preset: preset(policy: .copyrightOnly, writeXMP: true),
                                       outputDirectory: directory,
                                       render: { _, _ in self.image() })
        let outcome = try XCTUnwrap(report.written.first)
        XCTAssertNil(outcome.xmpURL)
        XCTAssertFalse(outcome.warnings.isEmpty)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: blocker.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue, "the blocking directory must still be there")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: blocker.appendingPathComponent("keep.txt").path),
                      "the blocking directory must not be half-replaced")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.contains(".tmp-") }
        XCTAssertTrue(leftovers.isEmpty, "temporary files survived: \(leftovers)")

        // Directly: a parent that cannot be created throws before anything is written, and a stale
        // temporary file is never left beside it.
        let notADirectory = scratch.appendingPathComponent("not-a-directory")
        try Data("x".utf8).write(to: notADirectory)
        let target = notADirectory.appendingPathComponent("nested.xmp")
        XCTAssertThrowsError(try XMPWriter.writeAtomically(Data("x".utf8), to: target))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        let scratchLeftovers = try FileManager.default.contentsOfDirectory(atPath: scratch.path)
            .filter { $0.contains(".tmp-") }
        XCTAssertTrue(scratchLeftovers.isEmpty, "temporary files survived: \(scratchLeftovers)")
    }
}


