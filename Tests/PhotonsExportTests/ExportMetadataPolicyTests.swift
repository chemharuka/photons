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

    /// `.all` + `writeXMP: true`: the 25-key develop packet, byte for byte as 186 found it — for a
    /// **pre-186 document** (`schemaVersion` 12).
    ///
    /// 186's contract is about the packet *writer*, and one of the numbers it copies is the
    /// document's own: `schemaVersion` appears twice in the packet (`photons:schemaVersion` as an
    /// attribute, and `"schemaVersion"` inside the deflated `photons:settings` blob, which is why the
    /// base64 text moves with it). Schema 13 (b9f5a77, 120b's depth
    /// removal) took the current number to 13, so today's fixture exports `schema13PacketSHA` — the
    /// packet is the same 3719 bytes, and the 522 that differ are the single character of
    /// `photons:schemaVersion` plus the 600-character `photons:settings` base64 (re-deflating a
    /// one-byte change to the document moves the rest of that stream). Every key, every
    /// `crs:`/`dc:`/`photoshop:` value and their order are byte-identical.
    ///
    /// **Not** the 191 export-sharpen removal: export sharpening never wrote an XMP key
    /// (`crs:Sharpness`/`crs:SharpenRadius` come from the *document's* decoder detail group), and
    /// 191's diff contains no XMP writer at all.
    private let legacyPacketSHA = "1323a4c44d29dd2cbea2fa3cbdea431f72331fbc31e8ecd774dad817c43285b6"
    private let legacyFileSHAs = [
        "3dc213f56a9be083938d2c0c9f16d0324b20169c02bd1d15f7e60ec62c7e345f",
        "47a948e04eddc4590ca211513735c5d14a03679ae27b3916c16ff746e0c9fbb2",
    ]
    /// The same packet with today's `schemaVersion` 13: the setting blob re-deflates to a different
    /// base64, at the same length. Everything else is the pre-186 packet.
    private let schema13PacketSHA = "0e5a3aab1ef662da1dd626773e93975b7a32ad58d35967d4dbc01d914e96d584"
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

    private func item(sourceURL: URL, schemaVersion: Int = EditModel.currentSchemaVersion)
        -> ExportItem {
        var edit = EditModel.neutral
        edit.light.exposure = 0.75
        edit.color.vibrance = 20
        edit.schemaVersion = schemaVersion
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
    private func export(_ preset: ExportPreset, tag: String,
                        schemaVersion: Int = EditModel.currentSchemaVersion)
        throws -> (outcome: BatchExportOutcome, url: URL) {
        let directory = out.appendingPathComponent(tag, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let report = BatchExporter.run(items: [item(sourceURL: source, schemaVersion: schemaVersion)],
                                       preset: preset,
                                       outputDirectory: directory,
                                       render: { _, _ in self.image() })
        let outcome = try XCTUnwrap(report.written.first)
        return (outcome, try XCTUnwrap(outcome.fileURL))
    }

    /// 206 追单二 — the pre-206 byte path, with the 8-bit dither named off explicitly. `BatchExporter`
    /// runs the preset's default (dither on), so a "same bytes as main" pin has to be measured on
    /// this door; the dithered export is then compared by pixels, not by a magic SHA.
    private func exportWithoutDither(_ preset: ExportPreset, tag: String,
                                     schemaVersion: Int = EditModel.currentSchemaVersion) throws -> URL {
        let item = item(sourceURL: source, schemaVersion: schemaVersion)
        let directory = out.appendingPathComponent(tag, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("src.\(preset.format.fileExtension)")

        var sourceMetadata = SourceMetadata.read(from: item.sourceURL)
        if preset.removeLocation, var stripped = sourceMetadata {
            stripped.gps = [:]
            if let xmp = stripped.xmp {
                stripped.xmp = XMPWriter.metadataWithoutLocation(xmp) ?? xmp
            }
            sourceMetadata = stripped
        }
        let pngAt16 = preset.format == .png && preset.effectiveBitDepth == 16
        let embedsXMP = preset.metadataLevel == .all && preset.writeXMP
            && item.edit != nil && preset.format.supportsXMPEmbedding && !pngAt16
        let metadata = ExportMetadataContext(level: preset.metadataLevel, source: sourceMetadata,
                                             edit: item.edit, author: item.author,
                                             copyright: item.copyright, embedXMP: embedsXMP,
                                             ppi: preset.effectivePPI)
        var options = preset.exportOptions
        options.dither8Bit = false
        try Exporter.write(image(), to: url, options: options, metadata: metadata)
        return url
    }

    /// The dithered file must be the same picture: same size, colour space and metadata key shape,
    /// with every colour channel at most one code away from the undithered file.
    private func assertOnlyDitherChanged(_ dithered: URL, _ reference: URL,
                                        file: StaticString = #filePath, line: UInt = #line) throws {
        let a = try decoded(dithered), b = try decoded(reference)
        XCTAssertEqual(a.width, b.width, file: file, line: line)
        XCTAssertEqual(a.height, b.height, file: file, line: line)
        XCTAssertEqual(a.colorSpace?.name as String?, b.colorSpace?.name as String?,
                       "colour space moved", file: file, line: line)

        let pa = try properties(of: dithered), pb = try properties(of: reference)
        XCTAssertEqual(Set(pa.keys), Set(pb.keys), "top-level metadata keys moved",
                       file: file, line: line)
        for key in [kCGImagePropertyExifDictionary as String,
                    kCGImagePropertyTIFFDictionary as String,
                    kCGImagePropertyGPSDictionary as String,
                    kCGImagePropertyIPTCDictionary as String] {
            XCTAssertEqual(keySet(pa[key]), keySet(pb[key]), "\(key) keys moved",
                           file: file, line: line)
        }

        let ba = try rgba(a), bb = try rgba(b)
        var maxDelta = 0, differing = 0
        for i in stride(from: 0, to: ba.count, by: 4) {
            for c in 0..<3 {
                let delta = abs(Int(ba[i + c]) - Int(bb[i + c]))
                maxDelta = max(maxDelta, delta)
                if delta != 0 { differing += 1 }
            }
        }
        print("206b dither pixel delta · max \(maxDelta) · differing samples \(differing)")
        XCTAssertLessThanOrEqual(maxDelta, 1, "dither must move at most one code per channel",
                                 file: file, line: line)
    }

    private func keySet(_ value: Any?) -> [String] {
        if let d = value as? [String: Any] { return d.keys.sorted() }
        if let d = value as? [CFString: Any] { return d.keys.map { $0 as String }.sorted() }
        return []
    }

    private func decoded(_ url: URL) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    /// 8-bit RGBA in the image's own colour space (no conversion).
    private func rgba(_ image: CGImage) throws -> [UInt8] {
        let space = try XCTUnwrap(image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB))
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        guard let context = CGContext(data: &bytes, width: image.width, height: image.height,
                                      bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw XCTSkip("cannot build the readback context")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return bytes
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

    /// 206 追单二 — the two halves of "compatible" that the 8-bit dither split apart:
    ///   · with `dither8Bit = false` the container is still byte-for-byte a pre-186 `main` file;
    ///   · with the export default (`true`) the picture is the same — size, colour space, metadata
    ///     keys, every channel within one code — even though the bytes are not.
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
        // Today's document (schema 13): the packet differs from the pre-186 bytes in the schema
        // number alone — see `legacyPacketSHA` for the measurement.
        XCTAssertEqual(try packetSHA(exported.url), schema13PacketSHA,
                       "a pre-186 preset must export the same XMP packet as before 186")

        // The pre-186 bytes themselves, still produced to the byte — by the pre-186 *document*: the
        // same fixture, the same preset, `schemaVersion` 12. That the two exports differ only in the
        // number is the point: 186 owns the policy, the document owns its schema number.
        //
        // 206 追单二 — `dither8Bit = false` is the knob that reproduces those bytes: the default
        // (on) export is compared by pixels below, never by a re-measured SHA.
        let pre186 = try exportWithoutDither(decoded, tag: "legacy-schema12", schemaVersion: 12)
        XCTAssertEqual(try packetSHA(pre186), legacyPacketSHA,
                       "186 must not move the packet: a schema-12 document must export the pre-186 "
                       + "bytes exactly")
        // The container around it, up to ImageIO's per-process IIM ordering.
        let legacyFileSHA = try sha256(pre186)
        print("206b legacy dither-off file SHA \(legacyFileSHA)")
        XCTAssertTrue(legacyFileSHAs.contains(legacyFileSHA),
                      "legacy preset with dither off exported \(legacyFileSHA), which is not one of "
                      + "the shapes pre-186 `main` writes")
        XCTAssertEqual(fileXMPPaths(pre186).count, 25)
        XCTAssertEqual(fileXMPPaths(exported.url).count, 25)

        // The default path (8-bit dither on) may not share bytes with pre-206, but it must not move
        // the picture or the metadata shape.
        let dithered = try export(decoded, tag: "legacy-dithered", schemaVersion: 12)
        XCTAssertEqual(try packetSHA(dithered.url), legacyPacketSHA)
        try assertOnlyDitherChanged(dithered.url, pre186)

        // And the same preset, spelled out with today's defaults, produces the same bytes.
        let explicit = try export(preset(policy: .all, writeXMP: true), tag: "legacy-explicit")
        XCTAssertEqual(try packetSHA(explicit.url), schema13PacketSHA)
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
        // 206 追单二 — both sides name `dither8Bit: false`: "these two policies produce the same
        // bytes" is a byte claim, and the dithered path is covered by the pixel comparison above.
        let on = try exportWithoutDither(preset(policy: .none, writeXMP: true), tag: "none-on")
        let off = try exportWithoutDither(preset(policy: .none, writeXMP: false), tag: "none-off")
        XCTAssertEqual(try sha256(on), try sha256(off))
        XCTAssertEqual(try sha256(on), noneSHA)
        for url in [on, off] {
            let sidecar = url.deletingPathExtension().appendingPathExtension("xmp")
            XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path))
        }

        // 107's ImageIO-composed packet on `.all`/off is untouched by 186 — same bytes, same keys.
        let allOff = try exportWithoutDither(preset(policy: .all, writeXMP: false), tag: "all-off")
        XCTAssertEqual(try packetSHA(allOff), composedPacketSHA)
        let composedFileSHA = try sha256(allOff)
        print("206b composed dither-off file SHA \(composedFileSHA)")
        XCTAssertTrue(composedFileSHAs.contains(composedFileSHA),
                      "composed file with dither off exported \(composedFileSHA), which is not one "
                      + "of the shapes ImageIO writes")
        XCTAssertEqual(fileXMPPaths(allOff).count, 16)
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


