import XCTest
import AppKit
import GRDB
import PhotonsCatalog
import PhotonsCore
import PhotonsExtensions
@testable import PhotonsUI

/// 487 — the three surfaces say 「降噪-XXX.dng」 / 「✦ N」 for a denoise stack, and a batch stacks
/// each photo as soon as that photo finishes rather than once at the end.
///
/// The name/icon assertions read the string the surface **actually drew** (`lastDrawnCaption`,
/// `nameDrawnText`, `lastBadgeLayout.stackText`), not a re-derivation — the same evidence rule the
/// 378/382 suites use.
@MainActor
final class DenoiseStackUI487Tests: XCTestCase {

    private var workDir: URL!
    private var activeGate: Gate?

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-487-ui-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for _ in 0..<8 { activeGate?.permits.signal() }
        activeGate = nil
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    // MARK: - library fixture

    private var package: URL!
    private var catalog: Catalog!
    private var root: SourceRoot!

    private func makeLibrary() throws {
        package = workDir.appendingPathComponent("U.\(LibraryLayout.packageExtension)",
                                                isDirectory: true)
        catalog = try Catalog.create(at: package)
        let shoot = workDir.appendingPathComponent("shoot", isDirectory: true)
        try FileManager.default.createDirectory(at: shoot, withIntermediateDirectories: true)
        root = try catalog.ensureRoot(for: shoot, mode: .reference)
    }

    @discardableResult
    private func seed(_ name: String, minute: Int = 0) throws -> Asset {
        let asset = Asset(sourceRootId: root.id, relPath: name, filename: name, ext: "dng",
                          kind: .raw, size: 16, mtime: 0, contentHash: UUID().uuidString,
                          captureTime: String(format: "2026-07-01T10:%02d:00Z", minute),
                          captureLocalDate: "2026-07-01")
        try catalog.dbQueue.write { db in try asset.insert(db) }
        return asset
    }

    private func openSession() throws -> CatalogSession {
        _ = NSApplication.shared
        let session = CatalogSession()
        try session.open(package)
        return session
    }

    private static func paint(_ view: NSView) {
        view.layout()
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                   pixelsWide: Int(max(1, view.bounds.width)),
                                   pixelsHigh: Int(max(1, view.bounds.height)),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        view.draw(view.bounds)
        for subview in view.subviews where !subview.isHidden { subview.draw(subview.bounds) }
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: - C ⑦⑧⑨ names + icon, one source for three surfaces

    func testThreeSurfacesShowTheDenoiseNameWithoutTheProductSuffix() throws {
        try makeLibrary()
        let original = try seed("L1030552.dng")
        let product = try seed("L1030552-denoised.dng", minute: 1)
        let stack = try XCTUnwrap(try catalog.makeStack(resultAssetID: product.id,
                                                        participantIDs: [original.id]))
        XCTAssertEqual(stack.kind, .denoise)
        let top = try XCTUnwrap(try catalog.asset(id: stack.topID))

        let expected = "降噪-L1030552.dng"
        XCTAssertNotEqual(expected, "降噪-L1030552-denoised.dng")
        XCTAssertNotEqual(expected, "堆叠 L1030552-denoised.dng")

        // ⑦ sidebar row
        let row = PhotoRowCell()
        row.frame = NSRect(x: 0, y: 0, width: 420, height: 46)
        row.configure(asset: top, isActive: false, stackCount: stack.count, stackKind: stack.kind)
        Self.paint(row)
        XCTAssertEqual(row.layoutProbe.nameDrawnText, expected, "⑦ 侧栏行显示降噪名")
        XCTAssertEqual(row.stackIndicatorText, "✦ 2", "⑦ 侧栏指示用降噪图标")

        // ⑧ grid + filmstrip, the same string
        let card = AssetCardView()
        card.frame = NSRect(x: 0, y: 0, width: 420, height: 180)
        card.asset = top
        card.stackCount = stack.count
        card.stackKind = stack.kind
        Self.paint(card)
        XCTAssertEqual(card.lastDrawnCaption, expected, "⑧ 网格同源")
        XCTAssertEqual(card.lastBadgeLayout.stackText, "✦ 2", "⑧ 网格专属图标 + 张数")
        XCTAssertEqual(card.badgeSignature, "✦2")

        let strip = FilmstripCard()
        strip.frame = NSRect(x: 0, y: 0, width: 420, height: 69)
        strip.asset = top
        strip.stackCount = stack.count
        strip.stackKind = stack.kind
        Self.paint(strip)
        XCTAssertEqual(strip.lastDrawnCaption, expected, "⑧ 胶片条同源")
        XCTAssertEqual(strip.lastBadgeLayout.stackText, "✦ 2", "⑧ 胶片条专属图标 + 张数")
        XCTAssertEqual(strip.badgeSignature, "✦2")
        print("⑦⑧ row \"\(row.layoutProbe.nameDrawnText)\" grid \"\(card.lastDrawnCaption ?? "?")" 
              + "\" strip \"\(strip.lastDrawnCaption ?? "?")" + "\" icon \(card.badgeSignature)")
    }

    func testPlainStackKeepsTheOldNameAndGlyph() throws {
        try makeLibrary()
        let a = try seed("A.dng")
        let b = try seed("B.dng", minute: 1)
        let stack = try XCTUnwrap(try catalog.makeStack(assetIDs: [a.id, b.id]))
        XCTAssertEqual(stack.kind, .plain)
        let top = try XCTUnwrap(try catalog.asset(id: stack.topID))

        let expected = "堆叠 A.dng"
        XCTAssertEqual(StackText.displayName("A.dng", isStack: true), expected,
                       "⑨ 普通堆叠的字符串口径不变")
        XCTAssertEqual(StackText.displayName("A.dng", isStack: true, kind: .plain), expected)

        let row = PhotoRowCell()
        row.frame = NSRect(x: 0, y: 0, width: 420, height: 46)
        row.configure(asset: top, isActive: false, stackCount: stack.count, stackKind: stack.kind)
        Self.paint(row)
        XCTAssertEqual(row.layoutProbe.nameDrawnText, expected)
        XCTAssertEqual(row.stackIndicatorText, "⧉ 2", "⑨ 普通堆叠图标一字节不动")

        let card = AssetCardView()
        card.frame = NSRect(x: 0, y: 0, width: 420, height: 180)
        card.asset = top
        card.stackCount = stack.count
        card.stackKind = stack.kind
        Self.paint(card)
        XCTAssertEqual(card.lastDrawnCaption, expected)
        XCTAssertEqual(card.badgeSignature, "⧉2")
        print("⑨ plain row \"\(row.layoutProbe.nameDrawnText)\" icon \(card.badgeSignature)")
    }

    // MARK: - B ③④ the session's commit door propagates

    private func historyLabels(_ id: String, in catalog: Catalog) -> [String] {
        (try? catalog.dbQueue.read { db in
            try String.fetchAll(db, sql: """
                SELECT COALESCE(label, '') FROM asset_history WHERE asset_id = ? ORDER BY seq
                """, arguments: [id])
        }) ?? []
    }

    private func bytes(_ id: String, in catalog: Catalog) -> String {
        (try? catalog.dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT develop_json FROM assets WHERE id = ?",
                                arguments: [id])
        }) ?? "<missing>"
    }

    func testCommitEditOnTheDenoiseTopWritesTheHiddenOriginal() throws {
        try makeLibrary()
        let original = try seed("L1030552.dng")
        let product = try seed("L1030552-denoised.dng", minute: 1)
        _ = try XCTUnwrap(try catalog.makeStack(resultAssetID: product.id,
                                                participantIDs: [original.id]))
        let session = try openSession()
        session.selectOnly(product.id)

        session.applyEdit { $0.light.exposure += 1 }
        XCTAssertTrue(session.commitEdit(label: "调整曝光"))

        XCTAssertEqual(bytes(original.id, in: catalog), bytes(product.id, in: catalog),
                       "③ 走 commitEdit 也是逐字节相同")
        XCTAssertTrue(historyLabels(original.id, in: catalog).contains { $0.contains("降噪联动") },
                      "③ 原图多一条「降噪联动」")
        print("③ session link labels \(historyLabels(original.id, in: catalog))")
    }

    func testCommitEditOnTheOriginalWritesTheDenoiseProduct() throws {
        try makeLibrary()
        let original = try seed("L1030552.dng")
        let product = try seed("L1030552-denoised.dng", minute: 1)
        // Top = the original: it is the row the session loads and edits.
        _ = try XCTUnwrap(try catalog.makeStack(assetIDs: [original.id, product.id]))
        let session = try openSession()
        session.selectOnly(original.id)

        session.applyEdit { $0.light.exposure += 2 }
        XCTAssertTrue(session.commitEdit(label: "调整曝光"))

        XCTAssertEqual(bytes(product.id, in: catalog), bytes(original.id, in: catalog),
                       "④ 反方向同样逐字节相同")
        XCTAssertTrue(historyLabels(product.id, in: catalog).contains { $0.contains("降噪联动") },
                      "④ 产物多一条「降噪联动」")
        print("④ session reverse labels \(historyLabels(product.id, in: catalog))")
    }

    // MARK: - E ⑬⑭ batch: one photo, one stack

    private final class MemoryStore: FilterPersistence.Store, PhotoSortPreferences.Store {
        var filters: [String: String] = [:]
        var sort: [String: String] = [:]
        func storedFilterJSON(forKey key: String) -> String? { filters[key] }
        func storeFilterJSON(_ json: String, forKey key: String) { filters[key] = json }
        func removeFilterJSON(forKey key: String) { filters[key] = nil }
        func sortOrderRaw(forKey key: String) -> String? { sort[key] }
        func storeSortOrderRaw(_ raw: String?, forKey key: String) { sort[key] = raw }
    }

    private static var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Tests/Fixtures/small-rggb.dng")
    }

    private final class Gate: @unchecked Sendable {
        let permits = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var starts = 0
        private var active = 0
        private var peak = 0
        func begin() {
            lock.lock(); starts += 1; active += 1; peak = max(peak, active); lock.unlock()
        }
        func end() { lock.lock(); active -= 1; lock.unlock() }
        var startedCount: Int { lock.lock(); defer { lock.unlock() }; return starts }
        var peakConcurrency: Int { lock.lock(); defer { lock.unlock() }; return peak }
    }

    private struct Fixture {
        let session: CatalogSession
        let catalog: Catalog
        let assets: [Asset]
    }

    private func makeBatchSession(dngCount: Int) throws -> Fixture {
        try makeLibrary()
        let src = workDir.appendingPathComponent("batchsrc", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let batchRoot = try catalog.ensureRoot(for: src, mode: .reference)
        var assets: [Asset] = []
        for i in 0..<dngCount {
            let name = String(format: "IMG_%04d.dng", i)
            var data = try Data(contentsOf: Self.fixtureURL)
            data.append(contentsOf: Array("batch-\(i)".utf8))
            try data.write(to: src.appendingPathComponent(name))
            let asset = Asset(sourceRootId: batchRoot.id, relPath: name, filename: name,
                              ext: "dng", kind: .raw, size: 1, mtime: 0,
                              contentHash: UUID().uuidString, width: 1024, height: 1024,
                              captureTime: String(format: "2026-05-01T10:%02d:00Z", i),
                              captureLocalDate: "2026-05-01",
                              cameraModel: "LEICA SL3", cameraKey: "leica|sl3")
            try catalog.dbQueue.write { db in try asset.insert(db) }
            assets.append(asset)
        }
        let store = MemoryStore()
        let session = CatalogSession(filterStore: store, sortPreferenceStore: store,
                                     remembersRecentLibrary: false)
        try session.open(package)
        session.setSortOrder(.oldestFirst)
        let model = workDir.appendingPathComponent("v_matmul_256.mlpackage", isDirectory: true)
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        session.nlmfModelURL = model
        return Fixture(session: session, catalog: catalog, assets: assets)
    }

    private func installBlockingBody(on session: CatalogSession, gate: Gate) {
        activeGate = gate
        session.nlmfDenoiseBody = { source, output, _ in
            gate.begin()
            defer { gate.end() }
            _ = gate.permits.wait(timeout: .now() + 30)
            try FileManager.default.copyItem(at: source, to: output)
            return NLMFDenoiseExecutor.Report(width: 1024, height: 1024, cfa: "rggb",
                                              tiles: 1, seconds: 0.01, byteCount: 1)
        }
    }

    private func pump(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    }

    @discardableResult
    private func waitUntil(_ what: String, timeout: TimeInterval = 30,
                           _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            pump(0.01)
        }
        XCTFail("\(what)：\(timeout) s 内没有成立")
        return false
    }

    private func task(in session: CatalogSession) throws -> BackgroundTask {
        let tasks = session.backgroundTasks.tasks.filter { $0.kind == .denoise }
        return try XCTUnwrap(tasks.last)
    }

    private func waitForTerminal(_ session: CatalogSession) {
        waitUntil("批次没有结束") { (try? self.task(in: session))?.state.isTerminal == true }
    }

    private func stackKind(of assetID: String, in catalog: Catalog) -> StackKind? {
        (try? catalog.stackKind(ofAsset: assetID)) ?? nil
    }

    func testBatchStacksTheFirstPhotoWhileTheSecondIsStillRunning() throws {
        let fixture = try makeBatchSession(dngCount: 3)
        let session = fixture.session
        let gate = Gate()
        installBlockingBody(on: session, gate: gate)
        session.setSelection(Set(fixture.assets.map(\.id)), anchor: fixture.assets[0].id)

        let participants = session.denoiseBatchSelection(engine: .nonlocal)
        XCTAssertEqual(participants.count, 3)

        waitUntil("第 1 张没有开始") { gate.startedCount == 1 }
        gate.permits.signal()
        waitUntil("第 2 张没有开始") { gate.startedCount == 2 }

        // The second item is inside the stand-in; the first must already be a denoise stack in the
        // library — not "stacked once at the end".
        XCTAssertEqual(stackKind(of: participants[0], in: fixture.catalog), .denoise,
                       "⑬ 第 1 张跑完就已经是 denoise 堆叠")
        let firstStackID = try XCTUnwrap(try fixture.catalog.stackID(ofAsset: participants[0]))
        XCTAssertEqual(try fixture.catalog.stackSummary(stackID: firstStackID)?.count, 2)
        XCTAssertEqual(try task(in: session).completed, 1)

        gate.permits.signal()
        waitUntil("第 3 张没有开始") { gate.startedCount == 3 }
        gate.permits.signal()
        waitForTerminal(session)
        print("⑬ batch stacked first while second ran; peak=\(gate.peakConcurrency)")
    }

    func testCancellingTheSecondLeavesTheFirstStacked() throws {
        let fixture = try makeBatchSession(dngCount: 3)
        let session = fixture.session
        let gate = Gate()
        installBlockingBody(on: session, gate: gate)
        session.setSelection(Set(fixture.assets.map(\.id)), anchor: fixture.assets[0].id)

        let participants = session.denoiseBatchSelection(engine: .nonlocal)
        let taskID = try XCTUnwrap(session.backgroundTasks.tasks.first?.id)

        waitUntil("第 1 张没有开始") { gate.startedCount == 1 }
        gate.permits.signal()
        waitUntil("第 2 张没有开始") { gate.startedCount == 2 }

        session.backgroundTasks.cancel(id: taskID)
        gate.permits.signal()
        waitForTerminal(session)

        XCTAssertEqual(try task(in: session).state, .cancelled)
        XCTAssertEqual(stackKind(of: participants[0], in: fixture.catalog), .denoise,
                       "⑭ 取消后第 1 张仍是 denoise 堆叠")
        let stackID = try XCTUnwrap(try fixture.catalog.stackID(ofAsset: participants[0]))
        XCTAssertEqual(try fixture.catalog.stackSummary(stackID: stackID)?.count, 2)
        print("⑭ cancel: first kind \(String(describing: stackKind(of: participants[0], in: fixture.catalog)))")
    }
}
