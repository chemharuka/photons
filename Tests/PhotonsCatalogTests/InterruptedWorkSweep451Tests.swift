import XCTest
import Foundation
import CoreGraphics
import ImageIO
import GRDB
import PhotonsCore
@testable import PhotonsCatalog

/// 451 — 「降噪到一半杀掉 app，会留下某种状态的残留」.
///
/// The residue of a kill is a pair of facts, not a record: a hidden
/// `.<denoise|hdrmerge>-<UUID>.dng` in the photo's folder (the child wrote it after the host died)
/// and an `import_sessions` row still saying `running`. These tests pin the two boundaries that
/// matter — the sweep touches **only** those names and **only** that row — plus the "after a kill,
/// opening and browsing the library still works" end-to-end claim.
final class InterruptedWorkSweep451Tests: XCTestCase {
    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-451-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    // MARK: ① 宁漏不误删

    func testSweepRemovesOnlyStrictTempNames() throws {
        let library = workDir.appendingPathComponent("lib", isDirectory: true)
        let nested = library.appendingPathComponent("day2", isDirectory: true)
        let tooDeep = nested.appendingPathComponent("day3", isDirectory: true)
        for dir in [library, nested, tooDeep] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        let denoise = library.appendingPathComponent(".denoise-\(UUID().uuidString).dng")
        let hdr = nested.appendingPathComponent(".hdrmerge-\(UUID().uuidString).dng")
        let notice = library.appendingPathComponent(".hidden-notice.txt")
        let visible = library.appendingPathComponent("visible.dng")
        let looksClose = library.appendingPathComponent(".denoise-not-a-uuid.dng")
        let wrongExtension = library.appendingPathComponent(".denoise-\(UUID().uuidString).tmp")
        // Depth 3 is deliberately out of scope: the sweep is bounded to the root + one level.
        let deep = tooDeep.appendingPathComponent(".denoise-\(UUID().uuidString).dng")
        for url in [denoise, hdr, notice, visible, looksClose, wrongExtension, deep] {
            try Data(repeating: 0x7, count: 17).write(to: url)
        }

        let report = InterruptedWorkSweep.sweep(libraryRoot: library)

        XCTAssertEqual(report.filesRemoved, 2)
        XCTAssertEqual(report.bytes, 34)
        XCTAssertFalse(FileManager.default.fileExists(atPath: denoise.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: hdr.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: notice.path), "其它隐藏文件一律不动")
        XCTAssertTrue(FileManager.default.fileExists(atPath: visible.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: looksClose.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: wrongExtension.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: deep.path), "深度 3 不属于清扫范围")
    }

    func testMatcherIsTheWholeFilename() {
        XCTAssertTrue(InterruptedWorkSweep.isSweepableName(".denoise-\(UUID().uuidString).dng"))
        XCTAssertTrue(InterruptedWorkSweep.isSweepableName(".hdrmerge-\(UUID().uuidString.lowercased()).dng"))
        XCTAssertFalse(InterruptedWorkSweep.isSweepableName(".denoise-\(UUID().uuidString).DNG"))
        XCTAssertFalse(InterruptedWorkSweep.isSweepableName(".nlmf-\(UUID().uuidString).dng"))
        XCTAssertFalse(InterruptedWorkSweep.isSweepableName("x.denoise-\(UUID().uuidString).dng"))
        XCTAssertFalse(InterruptedWorkSweep.isSweepableName(".denoise-\(UUID().uuidString).dng.bak"))
    }

    // MARK: ② 孤儿 session 行

    func testSweepBooksRunningSessionsAsInterruptedAndLeavesOthersAlone() throws {
        let library = workDir.appendingPathComponent("L.\(LibraryLayout.packageExtension)", isDirectory: true)
        let catalog = try Catalog.create(at: library)
        let orphan = UUID().uuidString
        let done = UUID().uuidString
        let cancelled = UUID().uuidString
        try catalog.dbQueue.write { db in
            for (id, state) in [(orphan, "running"), (done, "finished"), (cancelled, "cancelled")] {
                try db.execute(sql: """
                    INSERT INTO import_sessions (id, source_root_id, mode, state, started_at)
                    VALUES (?, NULL, 'reference', ?, ?)
                    """, arguments: [id, state, ISO8601.now()])
            }
        }

        let report = InterruptedWorkSweep.sweep(libraryRoot: library, catalog: catalog)

        XCTAssertEqual(report.sessionsMarkedInterrupted, 1)
        XCTAssertNil(report.error)
        let states = try catalog.dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT state FROM import_sessions ORDER BY started_at, id")
        }
        XCTAssertEqual(Set(states), Set(["interrupted", "finished", "cancelled"]))
        XCTAssertEqual(states.filter { $0 == "interrupted" }.count, 1)
        let interruptedID = try catalog.dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT id FROM import_sessions WHERE state = 'interrupted'")
        }
        XCTAssertEqual(interruptedID, orphan)
    }

    // MARK: ③ 真·被杀之后的库

    /// `ImportService`'s `--test-interrupt-after` hook calls `exit(137)` **inside** the process it
    /// runs in — it cannot be exercised in-process without killing the test runner. So this test
    /// runs the real `photonsctl` binary (when this checkout has one built), exactly as the acceptance
    /// harness does. If the binary is not there the deterministic simulated test below still covers
    /// the same post-kill state.
    func testRealInterruptedCLIImportThenSweepAndOpenWorks() throws {
        guard let ctl = photonsctlURL else {
            throw XCTSkip("photonsctl is not built in this checkout; simulated test covers the state")
        }
        let library = workDir.appendingPathComponent("real.\(LibraryLayout.packageExtension)", isDirectory: true)
        let source = workDir.appendingPathComponent("real-src", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try makeJPEG(at: source.appendingPathComponent("a.jpg"))
        try makeJPEG(at: source.appendingPathComponent("b.jpg"))

        let created = try run(ctl, ["library", "create", library.path])
        XCTAssertEqual(created.status, 0, created.stderr)
        let imported = try run(ctl, ["library", "import", library.path, source.path,
                                     "--test-interrupt-after", "1"])
        XCTAssertEqual(imported.status, 137, "the seam must look like SIGKILL: \(imported.stderr)")

        // The child of a killed denoise also left its hidden temp file behind.
        let leftover = source.appendingPathComponent(".denoise-\(UUID().uuidString).dng")
        try Data(repeating: 0x1, count: 5).write(to: leftover)

        let catalog = try Catalog.open(at: library)
        let report = InterruptedWorkSweep.sweep(libraryRoot: source, catalog: catalog)
        XCTAssertEqual(report.filesRemoved, 1)
        XCTAssertEqual(report.sessionsMarkedInterrupted, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path))

        // What the next launch does: the tree and the grid are readable, no dead `running` row.
        XCTAssertFalse(try catalog.roots().isEmpty)
        XCTAssertFalse(try catalog.folderIndex().isEmpty)
        XCTAssertEqual(try catalog.assets(AssetFilter()).count, 1)
        XCTAssertEqual(try catalog.stats().total, 1)
        let running = try catalog.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM import_sessions WHERE state = 'running'")
        }
        XCTAssertEqual(running, 0)
    }

    /// The same post-kill state, written directly so the test does not depend on a built CLI:
    /// one imported row, one `running` session, one hidden temp file. After `sweep` the catalog's
    /// read paths (`roots`, `folderIndex`, `assets`, `stats`) must all still answer.
    func testSweepAfterKillLeavesCatalogReadable() throws {
        let library = workDir.appendingPathComponent("S.\(LibraryLayout.packageExtension)", isDirectory: true)
        let catalog = try Catalog.create(at: library)
        let source = workDir.appendingPathComponent("shoot", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let root = try catalog.ensureRoot(for: source, mode: .reference)
        let asset = Asset(sourceRootId: root.id,
                          relPath: "day2/a.dng",
                          filename: "a.dng",
                          ext: "dng",
                          kind: .raw,
                          size: 1024,
                          mtime: 0,
                          contentHash: UUID().uuidString)
        try catalog.dbQueue.write { db in
            try asset.insert(db)
            try db.execute(sql: """
                INSERT INTO import_sessions (id, source_root_id, mode, state, started_at)
                VALUES (?, ?, 'reference', 'running', ?)
                """, arguments: [UUID().uuidString, root.id, ISO8601.now()])
        }
        let leftover = source.appendingPathComponent(".hdrmerge-\(UUID().uuidString).dng")
        try Data(repeating: 0x2, count: 9).write(to: leftover)

        let report = InterruptedWorkSweep.sweep(libraryRoot: source, catalog: catalog)

        XCTAssertEqual(report.filesRemoved, 1)
        XCTAssertEqual(report.sessionsMarkedInterrupted, 1)
        XCTAssertEqual(try catalog.roots().map(\.id), [root.id])
        let folders = try catalog.folderIndex()
        XCTAssertEqual(folders[root.id]?.first(where: { $0.path.isEmpty })?.total, 1)
        XCTAssertEqual(try catalog.assets(AssetFilter()).count, 1)
        XCTAssertEqual(try catalog.stats().total, 1)
    }

    // MARK: helpers

    /// `<worktree>/.build/debug/photonsctl`, derived from this source file. `nil` when the binary has
    /// not been built (a plain `swift test` does not have to build the executable).
    private var photonsctlURL: URL? {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()        // Tests/PhotonsCatalogTests
            .deletingLastPathComponent()        // Tests
            .deletingLastPathComponent()        // worktree
        let ctl = root.appendingPathComponent(".build/debug/photonsctl")
        return FileManager.default.isExecutableFile(atPath: ctl.path) ? ctl : nil
    }

    private func run(_ executable: URL, _ arguments: [String]) throws -> (status: Int32, stderr: String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let err = Pipe()
        process.standardError = err
        process.standardOutput = Pipe()
        try process.run()
        let data = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private func makeJPEG(at url: URL) throws {
        let width = 8, height = 8
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = {
                  context.setFillColor(CGColor(red: 0.4, green: 0.2, blue: 0.1, alpha: 1))
                  context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                  return context.makeImage()
              }(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)
        else { throw XCTSkip("cannot write a JPEG in this environment") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw XCTSkip("cannot finalize JPEG") }
    }
}
