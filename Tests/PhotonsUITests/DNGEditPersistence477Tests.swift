import XCTest
import AppKit
import GRDB
import CoreImage
import CryptoKit
import PhotonsCatalog
import PhotonsCore
import PhotonsLocalization
@testable import PhotonsUI

/// 477 — 保存 is explicit (⌘S / right-click), writes only XMP, and writes a sidecar for non-DNG.
/// 更新缩略图 is its own slow command. These tests pin the two groups the brief names.
@MainActor
final class DNGEditPersistence477Tests: XCTestCase {

    private var workDir: URL!
    private var source: URL {
        let env = ProcessInfo.processInfo.environment["PHOTONS_TEST_RAW"]
        return URL(fileURLWithPath: env ?? NSString(string: "~/Desktop/test/L1030433.dng")
            .expandingTildeInPath)
    }

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-477-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    // MARK: - fixtures

    private func journal() -> DNGXMPJournal {
        DNGXMPJournal(directory: workDir.appendingPathComponent("journal", isDirectory: true))
    }

    private func auditLog() -> DNGXPMAuditLog {
        DNGXPMAuditLog(directory: workDir)
    }

    private struct Library {
        let session: CatalogSession
        let catalog: Catalog
        let sourceRoot: URL
        let package: URL
    }

    private func openEmptyLibrary() throws -> Library {
        _ = NSApplication.shared
        let package = workDir.appendingPathComponent("DNG477.\(LibraryLayout.packageExtension)")
        let catalog = try Catalog.create(at: package)
        let src = workDir.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        _ = try catalog.ensureRoot(for: src, mode: .reference)
        let session = CatalogSession(remembersRecentLibrary: false)
        session.dngJournal = journal()
        session.dngAuditLog = auditLog()
        try session.open(package)
        return Library(session: session, catalog: catalog, sourceRoot: src, package: package)
    }

    @discardableResult
    private func insertAsset(_ library: Library, filename: String = "IMG_477.dng",
                             ext: String = "dng", kind: AssetKind = .raw,
                             developJSON: String = "{}", copyRAW: Bool = true) throws -> (id: String, url: URL) {
        let url = library.sourceRoot.appendingPathComponent(filename)
        if !FileManager.default.fileExists(atPath: url.path) {
            if copyRAW, FileManager.default.fileExists(atPath: source.path) {
                try FileManager.default.copyItem(at: source, to: url)
            } else {
                try Data([0xFF, 0xD8, 0xFF, 0x00]).write(to: url)
            }
        }
        let id = UUID().uuidString
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 1
        let rootID = try library.catalog.roots()[0].id
        try library.catalog.dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO assets (id, source_root_id, rel_path, filename, ext, kind, size, mtime,
                                    content_hash, width, height, camera_make, camera_model, lens,
                                    develop_json, develop_version, imported_at, missing)
                VALUES (?, ?, ?, ?, ?, ?, ?, 0, ?, 9520, 6336, 'Leica Camera AG', 'Leica SL3',
                        'Vario-Elmarit-SL 24-90', ?, 1, '2026-11-09T00:00:00Z', 0)
                """, arguments: [id, rootID, filename, filename, ext,
                                 kind.rawValue, size, UUID().uuidString, developJSON])
        }
        library.session.reload()
        return (id, url)
    }

    private func load(_ id: String, in session: CatalogSession) {
        session.selectOnly(id)
        // A test may change the row behind the session's back; the production doors do not need
        // `force`, but the fixture does.
        session.loadEditForAnchor(force: true)
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

    private func fileStamp(_ url: URL) throws -> (size: Int, mtime: Date?) {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = attrs[.size] as? Int ?? 0
        let mtime = attrs[.modificationDate] as? Date
        return (size, mtime)
    }

    // MARK: - group ①: save writes XMP only; edits do not touch the file

    func testEditsNeverTouchTheFileUntilSave() throws {
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw XCTSkip("no test RAW at \(source.path)")
        }
        let library = try openEmptyLibrary()
        let asset = try insertAsset(library)
        load(asset.id, in: library.session)
        let before = try fileStamp(asset.url)

        // The library is the real-time store. These commits are three file-visible edits and a crop —
        // none of them may write the original.
        for ev in [0.25, 0.5, 0.75] {
            library.session.applyEdit { $0.light.exposure = ev }
            XCTAssertTrue(library.session.commitEdit(label: "曝光"))
        }
        library.session.applyEdit { $0.geometry.crop = NormalizedRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5) }
        XCTAssertTrue(library.session.commitEdit(label: "裁切"))

        // 反向门：以前的自动写有一个 1.5 s 合并窗口。这里把窗口跑完，再断言文件没动 —— 把自动写
        // 加回去，这条会红。
        RunLoop.current.run(until: Date().addingTimeInterval(1.8))

        let afterEdits = try fileStamp(asset.url)
        XCTAssertEqual(afterEdits.size, before.size, "编辑本身不许改 DNG 字节数")
        XCTAssertEqual(afterEdits.mtime, before.mtime, "编辑本身不许改 DNG mtime")
        XCTAssertNil(try DNGXMP.documentString(at: asset.url),
                     "没有执行保存前，文件里不许出现 photons:document")

        // …and the explicit save is what writes it.
        XCTAssertTrue(library.session.saveEditsNow(assetID: asset.id))
        XCTAssertEqual(library.session.dngWriteStats.xmpWrites, 1)
        let text = try XCTUnwrap(try DNGXMP.documentString(at: asset.url))
        XCTAssertTrue(text.contains("\"exposure\":0.75") || text.contains("0.75"))
        XCTAssertNotEqual(try fileStamp(asset.url).size, before.size)

        // 幂等：同一份 document 再按一次保存不写文件。
        let saved = try fileStamp(asset.url)
        XCTAssertTrue(library.session.saveEditsNow(assetID: asset.id))
        XCTAssertEqual(library.session.dngWriteStats.xmpWrites, 1)
        XCTAssertEqual(try fileStamp(asset.url).size, saved.size)
    }

    func testSaveWritesASidecarForNonDNG() throws {
        let library = try openEmptyLibrary()
        let asset = try insertAsset(library, filename: "IMG_1234.CR3", ext: "cr3",
                                    kind: .jpeg, copyRAW: false)
        load(asset.id, in: library.session)
        library.session.applyEdit { $0.light.exposure = 0.75 }
        XCTAssertTrue(library.session.commitEdit(label: "曝光"))
        let before = try fileStamp(asset.url)

        XCTAssertTrue(library.session.saveEditsNow(assetID: asset.id))
        XCTAssertEqual(library.session.dngWriteStats.sidecarWrites, 1)

        let sidecar = DNGXMP.sidecarURL(for: asset.url)
        XCTAssertEqual(sidecar.lastPathComponent, "IMG_1234.CR3.xmp")
        let packet = try String(contentsOf: sidecar, encoding: .utf8)
        XCTAssertTrue(packet.contains("photons:document"), "sidecar 必须是可读的 XMP 包")
        XCTAssertEqual(try DNGXMP.sidecarDocument(at: asset.url)?.isEmpty, false)
        XCTAssertEqual(try fileStamp(asset.url).size, before.size, "写 sidecar 不能改原文件")
        XCTAssertEqual(try fileStamp(asset.url).mtime, before.mtime)
    }

    func testSaveIsIdempotentOnDNG() throws {
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw XCTSkip("no test RAW at \(source.path)")
        }
        let library = try openEmptyLibrary()
        let asset = try insertAsset(library)
        load(asset.id, in: library.session)
        library.session.applyEdit { $0.light.exposure = 0.75 }
        XCTAssertTrue(library.session.commitEdit(label: "曝光"))

        XCTAssertTrue(library.session.saveEditsNow(assetID: asset.id))
        let size1 = try fileStamp(asset.url).size
        let text1 = try XCTUnwrap(try DNGXMP.documentString(at: asset.url))
        XCTAssertTrue(library.session.saveEditsNow(assetID: asset.id))
        XCTAssertEqual(library.session.dngWriteStats.xmpWrites, 1, "无变化不得再写文件")
        XCTAssertEqual(try fileStamp(asset.url).size, size1)
        XCTAssertEqual(try DNGXMP.documentString(at: asset.url), text1)
    }

    // MARK: - DB is the only truth / backfill / read

    func testDBDocumentWinsOverXMPAndIsNeverOverwritten() throws {
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw XCTSkip("no test RAW at \(source.path)")
        }
        let library = try openEmptyLibrary()
        let asset = try insertAsset(library, developJSON: "{}")

        var xmp = EditModel.neutral
        xmp.light.exposure = 0.75
        _ = try DNGXMP.writeDocument(try canonicalJSON(xmp), to: asset.url, journal: journal())

        var db = EditModel.neutral
        db.light.exposure = 1.25
        try library.catalog.dbQueue.write { dbq in
            try dbq.execute(sql: "UPDATE assets SET develop_json = ? WHERE id = ?",
                            arguments: [try canonicalJSON(db), asset.id])
        }
        library.session.reload()
        load(asset.id, in: library.session)
        XCTAssertEqual(library.session.edit.light.exposure, 1.25, accuracy: 1e-9,
                       "DB 有 develop_json 时必须用 DB，XMP 不覆盖")

        let expectation = expectation(description: "backfill scan")
        library.session.backfillEditsFromXMP { applied in
            XCTAssertEqual(applied, 0, "DB 可用时回填必须什么都不做")
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 10)
        XCTAssertEqual(try library.catalog.develop(forAsset: asset.id).light.exposure, 1.25,
                       accuracy: 1e-9)
    }

    func testEmptyRowIsBackfilledFromTheDNGAndAudited() throws {
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw XCTSkip("no test RAW at \(source.path)")
        }
        let library = try openEmptyLibrary()
        let asset = try insertAsset(library, developJSON: "{}")
        var xmp = EditModel.neutral
        xmp.light.exposure = 0.75
        xmp.color.bands[2].saturation = 22
        _ = try DNGXMP.writeDocument(try canonicalJSON(xmp), to: asset.url, journal: journal())

        let expectation = expectation(description: "backfill")
        var applied = -1
        library.session.backfillEditsFromXMP { n in
            applied = n
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 20)
        XCTAssertEqual(applied, 1)
        let restored = try library.catalog.develop(forAsset: asset.id)
        XCTAssertEqual(restored.light.exposure, 0.75, accuracy: 1e-9)
        XCTAssertEqual(restored.color.bands[2].saturation, 22, accuracy: 1e-9)
        XCTAssertEqual(library.session.dngWriteStats.backfills, 1)

        let log = workDir.appendingPathComponent("dng-xmp-audit.log")
        let text = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(text.contains("\"source\":\"xmp\""), text)
        XCTAssertTrue(text.contains(asset.id), text)

        library.session.reload()
        load(asset.id, in: library.session)
        XCTAssertEqual(library.session.edit.light.exposure, 0.75, accuracy: 1e-9)
    }

    func testClearingTheRowAndReopeningRefillsItFromXMP() throws {
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw XCTSkip("no test RAW at \(source.path)")
        }
        let library = try openEmptyLibrary()
        let asset = try insertAsset(library)
        var xmp = EditModel.neutral
        xmp.light.contrast = 31
        _ = try DNGXMP.writeDocument(try canonicalJSON(xmp), to: asset.url, journal: journal())

        try library.catalog.dbQueue.write { db in
            try db.execute(sql: "UPDATE assets SET develop_json = '{}' WHERE id = ?",
                           arguments: [asset.id])
        }
        let session2 = CatalogSession(remembersRecentLibrary: false)
        session2.dngJournal = journal()
        session2.dngAuditLog = auditLog()
        try session2.open(library.package)
        let expectation = expectation(description: "reopen backfill")
        session2.backfillEditsFromXMP { n in
            // `open` already starts the same scan asynchronously; whichever one lands first does the
            // write, the other sees a usable row and applies zero.
            XCTAssertTrue(n == 0 || n == 1, "applied \(n)")
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 20)
        XCTAssertEqual(try library.catalog.develop(forAsset: asset.id).light.contrast,
                       31, accuracy: 1e-9, "库丢掉的那一行必须从 XMP 回填")
    }

    func testReadFromDNGOverwritesTheRow() throws {
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw XCTSkip("no test RAW at \(source.path)")
        }
        let library = try openEmptyLibrary()
        let asset = try insertAsset(library)
        var xmp = EditModel.neutral
        xmp.light.exposure = 0.75
        _ = try DNGXMP.writeDocument(try canonicalJSON(xmp), to: asset.url, journal: journal())
        var db = EditModel.neutral
        db.light.exposure = -1.5
        try library.catalog.dbQueue.write { dbq in
            try dbq.execute(sql: "UPDATE assets SET develop_json = ? WHERE id = ?",
                            arguments: [try canonicalJSON(db), asset.id])
        }
        library.session.reload()
        load(asset.id, in: library.session)
        XCTAssertEqual(library.session.edit.light.exposure, -1.5, accuracy: 1e-9)

        XCTAssertTrue(library.session.readEditFromDNG(for: asset.id))
        XCTAssertEqual(library.session.edit.light.exposure, 0.75, accuracy: 1e-9)
        XCTAssertEqual(try library.catalog.develop(forAsset: asset.id).light.exposure,
                       0.75, accuracy: 1e-9)
        XCTAssertEqual(library.session.dngWriteStats.readsFromDNG, 1)
    }

    func testReadOnlyDNGReturnsOneSentenceAndLeavesTheFileAlone() throws {
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw XCTSkip("no test RAW at \(source.path)")
        }
        let library = try openEmptyLibrary()
        let asset = try insertAsset(library)
        let before = try Data(contentsOf: asset.url)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: asset.url.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644],
                                                   ofItemAtPath: asset.url.path)
        }
        load(asset.id, in: library.session)
        library.session.applyEdit { $0.light.exposure = 0.75 }
        _ = library.session.commitEdit(label: "曝光")

        XCTAssertFalse(library.session.saveEditsNow(assetID: asset.id))
        XCTAssertEqual(try Data(contentsOf: asset.url), before, "只读文件必须零字节变化")
        let sentence = try XCTUnwrap(library.session.lastDNGError)
        XCTAssertTrue(sentence.contains("只读") || sentence.contains("read-only"), sentence)
        XCTAssertEqual(library.session.dngWriteStats.failures, 1)
    }

    // MARK: - menus

    func testFileMenuHasSaveWithCommandS() {
        let menu = MainMenu.build()
        let file = menu.items.first { $0.submenu?.title == Loc.t("文件") }?.submenu
        let save = file?.items.first { $0.title == Loc.t("保存") }
        XCTAssertNotNil(save, "文件菜单缺「保存」")
        XCTAssertEqual(save?.keyEquivalent, "s")
        XCTAssertEqual(save?.keyEquivalentModifierMask, [.command])
    }

    func testRightClickMenuPutsSaveBelowExport() throws {
        let library = try openEmptyLibrary()
        let asset = try insertAsset(library)
        load(asset.id, in: library.session)
        let menu = NSMenu()
        ExportMenuBuilder.attach(to: menu, session: library.session, selectedIDs: [asset.id])
        let titles = menu.items.map(\.title)
        XCTAssertEqual(Array(titles.prefix(2)), [Loc.t("导出…"), Loc.t("保存")])
    }
}
