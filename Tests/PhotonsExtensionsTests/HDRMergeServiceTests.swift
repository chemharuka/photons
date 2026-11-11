import XCTest
import AppKit
@testable import PhotonsExtensions

/// Acceptance for the HDR merge path, run against the **real** `hdrmerge-swift` binary.
///
/// A stub would prove nothing: the whole contract is "spawn a foreign process, parse its JSON,
/// produce a CFA DNG, import it". Skipped (not failed) when the tool or the sample bracket is
/// missing, so a machine without them still gets a green `make verify`.
final class HDRMergeServiceTests: XCTestCase {

    private static let bracket = ["L1030664.dng", "L1030665.dng", "L1030666.dng"]

    private static func bracketURLs() -> [URL]? {
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop/austria")
        let urls = Self.bracket.map { dir.appendingPathComponent($0) }
        return urls.allSatisfy { FileManager.default.fileExists(atPath: $0.path) } ? urls : nil
    }

    private static func tempDirectory() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hdrmerge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: tool discovery

    func testToolIsDiscoverableAndSpeaksProtocol1() throws {
        let service = HDRMergeService()
        guard let client = service.client else {
            throw XCTSkip("hdrmerge-swift not installed (bundled at Contents/Resources/bin or /opt/homebrew/bin)")
        }
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: client.executableURL.path))
        XCTAssertEqual(try client.protocolVersion(), 1)
    }

    func testMissingToolIsATypedFailure() {
        let service = HDRMergeService(client: HDRMergeClient(executableURL: URL(fileURLWithPath: "/nonexistent/tool")))
        XCTAssertThrowsError(try service.merge([URL(fileURLWithPath: "/tmp/a.dng"),
                                                URL(fileURLWithPath: "/tmp/b.dng")])) { error in
            guard let failure = error as? HDRMergeService.Failure else {
                return XCTFail("expected a typed Failure, got \(error)")
            }
            XCTAssertEqual(failure.code, "tool_missing")
        }
    }

    func testOneFrameIsRejectedBeforeSpawningAnything() {
        let service = HDRMergeService()
        XCTAssertThrowsError(try service.merge([URL(fileURLWithPath: "/tmp/a.dng")])) { error in
            XCTAssertEqual((error as? HDRMergeService.Failure)?.code, "not_enough_frames")
        }
    }

    // MARK: the merge

    func testMergeWritesCFADNGNamedAfterTheLeastExposedFrame() throws {
        guard HDRMergeService().isAvailable else { throw XCTSkip("tool missing") }
        guard let frames = Self.bracketURLs() else { throw XCTSkip("no sample bracket") }

        let dir = try Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var copies: [URL] = []
        for url in frames {
            let dst = dir.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.copyItem(at: url, to: dst)
            copies.append(dst)
        }

        var progressLines: [String] = []
        let service = HDRMergeService()
        let outcome = try service.merge(copies) { line in
            progressLines.append(line)
        }

        XCTAssertEqual(outcome.output.lastPathComponent, "L1030664-merged.dng")
        XCTAssertEqual(outcome.output.deletingLastPathComponent().path, dir.path)
        XCTAssertEqual(outcome.frameCount, 3)
        XCTAssertEqual(outcome.metadataFrom.lastPathComponent, "L1030664.dng")
        XCTAssertEqual(outcome.whiteLevel, 65535, "headroom 4 in a 16-bit container")
        XCTAssertTrue(FileManager.default.fileExists(atPath: outcome.output.path))
        XCTAssertTrue(progressLines.contains { $0.hasPrefix("解码") })
        XCTAssertTrue(progressLines.contains("对齐并合并…"))

        // The result must be a CFA DNG that ImageIO accepts as a RAW image.
        let found = try DNGProbe.read(at: outcome.output)
        XCTAssertEqual(found.photometric, 32803, "PhotometricInterpretation must be CFA")
        XCTAssertEqual(found.white, 65535)
        XCTAssertEqual(found.width, outcome.width)
        XCTAssertEqual(found.cfaPattern, [0, 1, 1, 2], "RGGB survives the merge")

        let source = CGImageSourceCreateWithURL(outcome.output as CFURL, nil)
        XCTAssertNotNil(source, "ImageIO must open the merged DNG")
        XCTAssertEqual(outcome.bytes, (try FileManager.default
            .attributesOfItem(atPath: outcome.output.path)[.size] as? Int) ?? -1)
    }

    func testSecondMergeGetsANumberedName() throws {
        guard HDRMergeService().isAvailable else { throw XCTSkip("tool missing") }
        guard let frames = Self.bracketURLs() else { throw XCTSkip("no sample bracket") }
        let dir = try Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Naming is pure and does not need a merge to test.
        let base = dir.appendingPathComponent("L1030664.dng")
        let first = HDRMergeService.uniqueURL(base: base, in: dir)
        XCTAssertEqual(first.lastPathComponent, "L1030664-merged.dng")
        try Data().write(to: first)
        let second = HDRMergeService.uniqueURL(base: base, in: dir)
        XCTAssertEqual(second.lastPathComponent, "L1030664-merged-2.dng")
        try Data().write(to: second)
        XCTAssertEqual(HDRMergeService.uniqueURL(base: base, in: dir).lastPathComponent,
                       "L1030664-merged-3.dng")
        _ = frames
    }

    func testSelectionIsFilteredToDNGBeforeSpawning() throws {
        let service = HDRMergeService()
        // A JPEG in the list must be dropped, not handed to a tool that would fail on it.
        let mixed = [URL(fileURLWithPath: "/tmp/a.dng"), URL(fileURLWithPath: "/tmp/b.jpg")]
        XCTAssertThrowsError(try service.mergeSelection(mixed)) { error in
            guard let failure = error as? HDRMergeService.Failure else { return XCTFail("typed") }
            // Only one DNG survives the filter, so this is "not enough frames" — and crucially
            // not an "unsupported format" from the child process.
            XCTAssertEqual(failure.code, "not_enough_frames")
        }
    }

    // MARK: error vocabulary

    func testFailureCodesAreStableAndMessagesAreChinese() {
        let cases: [(HDRMergeService.Failure, String, String)] = [
            (.toolMissing, "tool_missing", "未找到"),
            (.notEnoughFrames(1), "not_enough_frames", "至少需要两张"),
            (.linearDNG("x"), "linear_dng", "线性 DNG"),
            (.notCFARaw("x"), "not_a_cfa_dng", "不是 CFA RAW"),
            (.unsupportedFormat("x"), "unsupported_compression", "压缩方式"),
            (.incompatibleFrames("x"), "geometry_mismatch", "无法合并"),
            (.unreadable("/tmp/x"), "io_error", "无法读取"),
            (.cannotWrite("/tmp/x"), "write_failed", "无法写入"),
            (.toolFailed("x"), "internal", "异常退出"),
        ]
        for (failure, code, fragment) in cases {
            XCTAssertEqual(failure.code, code)
            XCTAssertTrue(failure.description.contains(fragment),
                          "\(code) message should mention 「\(fragment)」, got «\(failure.description)»")
        }
    }

    func testToolErrorCodesMapOntoServiceFailures() {
        let linear = HDRMergeFailure(code: "linear_dng", message: "x", exitCode: 3)
        XCTAssertEqual(HDRMergeService.Failure.wrap(linear).code, "linear_dng")
        let mismatch = HDRMergeFailure(code: "geometry_mismatch", message: "x", exitCode: 4)
        XCTAssertEqual(HDRMergeService.Failure.wrap(mismatch).code, "geometry_mismatch")
        let io = HDRMergeFailure(code: "io_error", message: "x", exitCode: 3)
        XCTAssertEqual(HDRMergeService.Failure.wrap(io).code, "io_error")
    }
}

/// Deliberately independent of the tool's own reader: proves the bytes on disk are a CFA DNG by
/// walking the TIFF IFDs with Foundation alone.
enum DNGProbe {
    struct Found {
        let width: Int
        let height: Int
        let white: Int
        let photometric: Int
        let cfaPattern: [Int]
    }

    static func read(at url: URL) throws -> Found {
        let data = try Data(contentsOf: url)
        guard data.count > 8, data[0] == 0x49, data[1] == 0x49 else {
            throw NSError(domain: "DNGProbe", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "not a little-endian TIFF"])
        }
        func u16(_ o: Int) -> Int { Int(data[o]) | Int(data[o + 1]) << 8 }
        func u32(_ o: Int) -> Int {
            Int(data[o]) | Int(data[o + 1]) << 8 | Int(data[o + 2]) << 16 | Int(data[o + 3]) << 24
        }
        let sizes: [Int: Int] = [1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 7: 1, 10: 8]

        var offset = u32(4)
        var seen = 0
        while offset > 0 && offset + 2 < data.count && seen < 8 {
            seen += 1
            let count = u16(offset)
            var tags: [Int: (type: Int, count: Int, valueOffset: Int)] = [:]
            for i in 0..<count {
                let e = offset + 2 + i * 12
                guard e + 12 <= data.count else { break }
                let tag = u16(e), type = u16(e + 2), n = u32(e + 4)
                let byteSize = (sizes[type] ?? 1) * n
                let valueOffset = byteSize <= 4 ? e + 8 : u32(e + 8)
                tags[tag] = (type, n, valueOffset)
            }
            if tags[262].map({ type, _, off in
                (type == 3 ? u16(off) : u32(off)) == 32803
            }) == true {
                func value(_ tag: Int) -> Int {
                    guard let t = tags[tag] else { return 0 }
                    return t.type == 3 ? u16(t.valueOffset) : u32(t.valueOffset)
                }
                var cfa: [Int] = []
                if let t = tags[33422] {
                    for i in 0..<min(t.count, 4) { cfa.append(Int(data[t.valueOffset + i])) }
                }
                return Found(width: value(256), height: value(257),
                             white: value(50717), photometric: 32803, cfaPattern: cfa)
            }
            let next = offset + 2 + count * 12
            guard next + 4 <= data.count else { break }
            offset = u32(next)
        }
        throw NSError(domain: "DNGProbe", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "no CFA IFD in \(url.lastPathComponent)"])
    }
}
