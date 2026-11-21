import XCTest
import Foundation
import CryptoKit
@testable import PhotonsCore

/// 477 stage A — the edit document written into the DNG's own XMP. Round trip, pixel identity,
/// idempotence, undo, and the read-only sentence.
final class DNGXMP477Tests: XCTestCase {

    private var source: URL {
        let env = ProcessInfo.processInfo.environment["PHOTONS_TEST_RAW"]
        return URL(fileURLWithPath: env ?? NSString(string: "~/Desktop/test/L1030433.dng")
            .expandingTildeInPath)
    }

    private func copyOfSource() throws -> URL {
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw XCTSkip("no test RAW at \(source.path)")
        }
        let dst = FileManager.default.temporaryDirectory
            .appendingPathComponent("dngxmp477-\(UUID().uuidString).dng")
        try FileManager.default.copyItem(at: source, to: dst)
        addTeardownBlock { try? FileManager.default.removeItem(at: dst) }
        return dst
    }

    private func journal() -> DNGXMPJournal {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dngxmp477-journal-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return DNGXMPJournal(directory: dir)
    }

    private func canonicalJSON(_ edit: EditModel) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(edit), as: UTF8.self)
    }

    private func decodedSHA(_ url: URL) throws -> String {
        let image = try RAWDecoder().decode(url, options: DecodeOptions(scale: 0.125))
        var hasher = SHA256()
        image.rgba.withUnsafeBytes { hasher.update(bufferPointer: $0) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// An edit that touches every group the acceptance names: light, curve, eight-band HSL, crop,
    /// and a mask (so the JSON has a non-trivial nested value too).
    private func sampleDocument() -> EditModel {
        var edit = EditModel.neutral
        edit.light.exposure = 0.75
        edit.light.contrast = 18
        edit.curve.white = [CurvePoint(0, 0), CurvePoint(0.42, 0.58), CurvePoint(1, 1)]
        edit.color.bands = (0..<ColorGroup.bandCount).map { i in
            HSLBand(hue: Double(i * 3 - 7), saturation: Double(i * 5 - 12),
                    luminance: Double(i * 2 - 6))
        }
        edit.geometry.crop = NormalizedRect(x: 0.1, y: 0.15, width: 0.6, height: 0.55)
        edit.geometry.rotationDegrees = 2.5
        edit.masks = [
            Mask(id: "m-477", name: "渐变 ‹&›", isEnabled: true, opacity: 0.9,
                 components: [MaskComponent(id: "c-477", feather: 0.4,
                                            shape: .radialGradient(RadialGradientShape(
                                                center: NormalizedPoint(0.4, 0.5),
                                                radius: NormalizedPoint(0.3, 0.3),
                                                angle: 12)))],
                 adjustments: LocalAdjustments(exposure: 1.25)),
        ]
        edit.effects.grain = 30
        edit.detailSettings.detail = 7
        return edit
    }

    func testEveryFieldRoundTripsThroughTheFilesOwnXMP() throws {
        let url = try copyOfSource()
        let document = sampleDocument()
        let text = try canonicalJSON(document)

        _ = try DNGXMP.writeDocument(text, to: url, journal: journal())
        let readBack = try XCTUnwrap(try DNGXMP.documentString(at: url))
        XCTAssertEqual(readBack, text)
        let decoded = try JSONDecoder().decode(EditModel.self, from: Data(readBack.utf8))
        XCTAssertEqual(decoded, document, "EditModel 逐字段必须相等（含 masks/curve/HSL 八带/crop）")
        print("XMP 往返：exposure +\(decoded.light.exposure) · HSL \(decoded.color.bands.count) 带 · mask \(decoded.masks.count) · crop \(decoded.geometry.crop.keyString)")
    }

    /// Acceptance #1's second half: an external reader must see our property. `exiftool` is skipped
    /// where it is not installed; the packet probe always runs.
    func testThePacketCarriesPhotonsDocumentAndExiftoolCanReadIt() throws {
        let url = try copyOfSource()
        let text = try canonicalJSON(sampleDocument())

        // What Adobe/Lightroom left in the file must survive: our writer merges into the packet, it
        // does not replace it.
        let before = try TIFFFile(Data(contentsOf: url))
        let beforePacket = try before.entries(of: 700, in: before.ifd0)
            .flatMap { try? before.payload($0) }
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""

        _ = try DNGXMP.writeDocument(text, to: url, journal: journal())

        let file = try TIFFFile(Data(contentsOf: url))
        let entry = try XCTUnwrap(file.entries(of: 700, in: file.ifd0))
        let packet = String(decoding: try file.payload(entry), as: UTF8.self)
        XCTAssertTrue(packet.contains("photons:document"))
        if beforePacket.contains("crs:") {
            XCTAssertTrue(packet.contains("crs:"), "别人的 crs:* 属性不能被我们写丢")
        }

        let exiftool = URL(fileURLWithPath: "/opt/homebrew/bin/exiftool")
        guard FileManager.default.isExecutableFile(atPath: exiftool.path) else {
            throw XCTSkip("exiftool not installed")
        }
        let process = Process()
        process.executableURL = exiftool
        process.arguments = ["-xmp", "-b", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertTrue(output.contains("photons:document"), "exiftool -xmp -b 没看到 photons:document")
    }

    func testWritingXMPDoesNotChangeTheDecodedPixels() throws {
        let url = try copyOfSource()
        let before = try decodedSHA(url)
        _ = try DNGXMP.writeDocument(try canonicalJSON(sampleDocument()), to: url, journal: journal())
        let after = try decodedSHA(url)
        XCTAssertEqual(before, after, "写 XMP 前后解码像素 SHA256 必须相同")
        print("XMP 像素 SHA：写前 \(before.prefix(16))… · 写后 \(after.prefix(16))…")
    }

    func testSameDocumentTwiceReusesTheSlotAndKeepsTheFileSize() throws {
        let url = try copyOfSource()
        let text = try canonicalJSON(sampleDocument())
        let first = try DNGXMP.writeDocument(text, to: url, journal: journal())
        let size1 = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
        let second = try DNGXMP.writeDocument(text, to: url, journal: journal())
        let size2 = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0

        XCTAssertTrue(second.reusedSlot, "第二次必须复用 tag 700 的 slot，实际 \(second)")
        XCTAssertEqual(second.appendedBytes, 0)
        XCTAssertEqual(size1, size2)
        print("幂等：第一次 reused=\(first.reusedSlot) appended=\(first.appendedBytes) · 第二次 reused=\(second.reusedSlot) appended=\(second.appendedBytes) · 文件 \(size2) 字节")
    }

    func testUndoRemovesOurDocumentAndLeavesForeignMetadataAlone() throws {
        let url = try copyOfSource()
        let j = journal()
        let original = try TIFFFile(Data(contentsOf: url)).headerBytes
        _ = try DNGXMP.writeDocument(try canonicalJSON(sampleDocument()), to: url, journal: j)
        XCTAssertNotNil(try DNGXMP.documentString(at: url))
        try DNGXMP.undo(at: url, journal: j)
        XCTAssertNil(try DNGXMP.documentString(at: url))
        XCTAssertEqual(Data(try TIFFFile(Data(contentsOf: url)).headerBytes), original)
    }

    func testReadOnlyFileFailsWithOneSentenceAndZeroBytesChanged() throws {
        let url = try copyOfSource()
        let before = try Data(contentsOf: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        }
        XCTAssertThrowsError(try DNGXMP.writeDocument(try canonicalJSON(sampleDocument()),
                                                      to: url, journal: journal())) { error in
            let sentence = String(describing: error)
            XCTAssertTrue(sentence.contains("只读") || sentence.contains("read-only"), sentence)
        }
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    // MARK: - non-DNG sidecar

    func testSidecarKeepsTheOriginalExtensionAndRoundTrips() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dngxmp-sidecar-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("IMG_1234.CR3")
        try Data([0x01, 0x02, 0x03]).write(to: source)

        let sidecar = DNGXMP.sidecarURL(for: source)
        XCTAssertEqual(sidecar.lastPathComponent, "IMG_1234.CR3.xmp")

        let text = try canonicalJSON(sampleDocument())
        let first = try DNGXMP.writeSidecar(document: text, for: source)
        XCTAssertTrue(first.wrote)
        XCTAssertGreaterThan(first.bytes, 0)
        XCTAssertEqual(try Data(contentsOf: source), Data([0x01, 0x02, 0x03]),
                       "写 sidecar 不能碰原文件")
        XCTAssertEqual(try DNGXMP.sidecarDocument(at: source), text)
        let packet = try String(contentsOf: sidecar, encoding: .utf8)
        XCTAssertTrue(packet.contains("photons:document"))

        let second = try DNGXMP.writeSidecar(document: text, for: source)
        XCTAssertFalse(second.wrote, "同一份 document 不该再写 sidecar")
        XCTAssertEqual(second.bytes, 0)
    }

    func testSidecarMergingKeepsForeignPropertiesAndFailsCleanlyWhenReadOnly() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dngxmp-sidecar-ro-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("IMG_9.JPG")
        try Data([0xFF, 0xD8]).write(to: source)
        let sidecar = DNGXMP.sidecarURL(for: source)

        let foreign = """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about="" xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/" crs:Exposure2012="+0.5"/>
        </rdf:RDF></x:xmpmeta>
        <?xpacket end="w"?>
        """
        try Data(foreign.utf8).write(to: sidecar)
        try DNGXMP.writeSidecar(document: #"{"v":1}"#, for: source)
        let packet = try String(contentsOf: sidecar, encoding: .utf8)
        XCTAssertTrue(packet.contains("crs:Exposure2012=\"+0.5\""))
        XCTAssertTrue(packet.contains("photons:document"))

        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: sidecar.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: sidecar.path)
        }
        XCTAssertThrowsError(try DNGXMP.writeSidecar(document: #"{"v":2}"#, for: source)) { error in
            let sentence = String(describing: error)
            XCTAssertTrue(sentence.contains("只读") || sentence.contains("read-only"), sentence)
        }
    }
}
