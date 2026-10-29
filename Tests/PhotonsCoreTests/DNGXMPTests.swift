import XCTest
import Foundation
@testable import PhotonsCore

/// `DNGXMP` writes edit settings into a DNG's own XMP. These tests hold the two promises that make it
/// safe to write to a photographer's original file:
///
/// 1. **the image does not change** — every IFD entry except tag 700 survives byte for byte, and the
///    decode hash is identical;
/// 2. **nobody else's metadata is touched** — a packet's foreign properties (`crs:*`, …) come out the
///    way they went in, and undo puts the file back.
final class DNGXMPTests: XCTestCase {

    private var source: URL {
        let env = ProcessInfo.processInfo.environment["PHOTONS_TEST_RAW"]
        return URL(fileURLWithPath: env ?? NSString(string: "~/Desktop/test/L1030433.dng")
            .expandingTildeInPath)
    }

    private func copyOfSource() throws -> URL {
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw XCTSkip("no test RAW at \(source.path)")
        }
        let dst = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dngxmp-\(UUID().uuidString).dng")
        try FileManager.default.copyItem(at: source, to: dst)
        addTeardownBlock { try? FileManager.default.removeItem(at: dst) }
        return dst
    }

    private func journal() -> DNGXMPJournal {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dngxmp-journal-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return DNGXMPJournal(directory: dir)
    }

    // MARK: - round trip

    func testDocumentRoundTripsThroughTheFile() throws {
        let url = try copyOfSource()
        let j = journal()
        let doc = #"{"schemaVersion":12,"light":{"exposure":0.75},"masks":[{"name":"渐变 ‹&›"}]}"#

        let outcome = try DNGXMP.writeDocument(doc, to: url, journal: j)
        XCTAssertFalse(outcome.reusedSlot, "第一次写要追加（原文件可能已有更小的包），实际 \(outcome)")
        XCTAssertGreaterThan(outcome.appendedBytes, 0)
        XCTAssertEqual(try DNGXMP.documentString(at: url), doc)

        // A second, shorter document reuses the slot the first one made.
        let second = #"{"schemaVersion":12}"#
        let again = try DNGXMP.writeDocument(second, to: url, journal: j)
        XCTAssertTrue(again.reusedSlot, "第二次应原地覆盖，文件不该再变长")
        XCTAssertEqual(again.appendedBytes, 0)
        XCTAssertEqual(try DNGXMP.documentString(at: url), second)
    }

    func testXMLSpecialCharactersSurvive() throws {
        let url = try copyOfSource()
        let doc = #"{"note":"a<b & c>d \"quoted\" 'single' — 中文"}"#
        try DNGXMP.writeDocument(doc, to: url, journal: journal())
        XCTAssertEqual(try DNGXMP.documentString(at: url), doc)
    }

    // MARK: - the image is untouched

    func testEveryOtherIFDEntrySurvivesByteForByte() throws {
        let url = try copyOfSource()
        let before = try TIFFFile(Data(contentsOf: url))
        try DNGXMP.writeDocument(#"{"schemaVersion":12,"light":{"contrast":22}}"#, to: url,
                                 journal: journal())
        let after = try TIFFFile(Data(contentsOf: url))

        let beforeTags = before.allEntries().filter { $0.tag != 700 }
        let afterTags = after.allEntries().filter { $0.tag != 700 }
        XCTAssertEqual(beforeTags.count, afterTags.count, "IFD0 条目数只允许 700 这一个变化")
        for (old, new) in zip(beforeTags, afterTags) {
            XCTAssertEqual(old.tag, new.tag)
            XCTAssertEqual(old.type, new.type)
            XCTAssertEqual(old.count, new.count)
            XCTAssertEqual(old.raw, new.raw, "tag \(old.tag) 的值被改动了")
        }
        // …and the entry that did change points at a packet that is really there.
        let packet = try after.payload(try XCTUnwrap(after.entries(of: 700, in: after.ifd0)))
        XCTAssertTrue(String(decoding: packet, as: UTF8.self).contains("photons:document"))
    }

    func testTheDecodedPixelsAreIdentical() throws {
        let url = try copyOfSource()
        let options = DecodeOptions(scale: 0.125)
        let before = try RAWDecoder().decode(url, options: options)
        try DNGXMP.writeDocument(#"{"schemaVersion":12}"#, to: url, journal: journal())
        let after = try RAWDecoder().decode(url, options: options)

        XCTAssertEqual(before.width, after.width)
        XCTAssertEqual(before.height, after.height)
        XCTAssertEqual(before.rgba, after.rgba, "写 XMP 之后解码出的像素必须完全一样")
    }

    // MARK: - other people's properties

    func testMergingKeepsForeignProperties() throws {
        let foreign = """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about="" xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/" crs:Exposure2012="+0.75"/>
        </rdf:RDF></x:xmpmeta>
        <?xpacket end="w"?>
        """
        let merged = DNGXMP.merged(existing: Data(foreign.utf8), document: #"{"schemaVersion":12}"#)
        let text = String(decoding: merged, as: UTF8.self)
        XCTAssertTrue(text.contains("crs:Exposure2012=\"+0.75\""), "别人的属性丢了：\(text)")
        XCTAssertTrue(text.contains("<photons:document>"), "我们的属性没写进去")
        XCTAssertEqual(DNGXMP.extractDocument(from: text), #"{"schemaVersion":12}"#)

        // Removing ours leaves theirs exactly as it was.
        let stripped = try XCTUnwrap(DNGXMP.removingDocument(from: text))
        XCTAssertFalse(stripped.contains("photons:document"))
        XCTAssertTrue(stripped.contains("crs:Exposure2012=\"+0.75\""))
    }

    func testReplacingOurPropertyDoesNotDuplicateIt() {
        let first = DNGXMP.merged(existing: nil, document: #"{"v":1}"#)
        let second = DNGXMP.merged(existing: first, document: #"{"v":2}"#)
        let text = String(decoding: second, as: UTF8.self)
        XCTAssertEqual(text.components(separatedBy: "<photons:document>").count, 2,
                       "第二次写必须替换，不是追加第二个属性")
        XCTAssertEqual(DNGXMP.extractDocument(from: text), #"{"v":2}"#)
    }

    // MARK: - growth and undo

    func testTwentyWritesStaySmall() throws {
        let url = try copyOfSource()
        let j = journal()
        let before = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
        // Only the first write needs space; 19 rewrites must fit the slot.
        // The first write pays for one copy of the packet Adobe already put there (~17 KB on a
        // camera DNG); the 19 after it must land in the slot it made.
        // The first write pays for one copy of the packet Adobe already put there (~17 KB on a camera
        // DNG); the 19 after it must land in that slot — including the one that grows the document by
        // a byte ("n":9 → "n":10), which is paid for out of the packet's own padding.
        for n in 0..<20 {
            try DNGXMP.writeDocument(#"{"schemaVersion":12,"n":\#(n)}"#, to: url, journal: j)
        }
        let after = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
        XCTAssertLessThanOrEqual(after - before, 20_000, "20 次编辑后文件长大了 \(after - before) 字节")
        XCTAssertEqual(try DNGXMP.documentString(at: url), #"{"schemaVersion":12,"n":19}"#)
    }

    func testUndoRestoresTheOriginalHeader() throws {
        let url = try copyOfSource()
        let j = journal()
        let originalHeader = try TIFFFile(Data(contentsOf: url)).headerBytes

        try DNGXMP.writeDocument(#"{"schemaVersion":12,"light":{"exposure":1.0}}"#, to: url, journal: j)
        XCTAssertNotNil(try DNGXMP.documentString(at: url))

        try DNGXMP.undo(at: url, journal: j)
        let restored = try TIFFFile(Data(contentsOf: url))
        XCTAssertEqual(Data(restored.headerBytes), originalHeader, "头指针必须回到原 IFD0")
        XCTAssertNil(try DNGXMP.documentString(at: url), "撤销后我们追加的属性必须失效")
        XCTAssertNotNil(restored.entries(of: 700, in: restored.ifd0),
                        "文件原有的 tag 700 不能因为我们撤销就消失")
    }

    func testWritingANonTIFFFileFailsCleanly() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("not-a-dng-\(UUID().uuidString).dng")
        try Data("hello".utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try DNGXMP.writeDocument("{}", to: url, journal: journal()))
    }
}
