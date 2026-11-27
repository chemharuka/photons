import XCTest
import AppKit
import GRDB
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// §566 — 降噪堆叠的右键菜单：「堆叠」改「降噪」、加「删除降噪文件」、去掉「设为置顶」。
///
/// The table is exact, so the suite walks it in order:
///
///   ① a plain stack keeps the old grammar verbatim — 「设为置顶」 in, 「删除降噪文件」 out;
///   ② a denoise pair says 「降噪」 and offers only 取消堆叠 / 删除降噪文件;
///   ③ a selection spanning a denoise pair and a plain stack falls back to the plain grammar;
///   ④ attaching both kinds to one menu leaves exactly one holder and no ghost;
///   ⑤ `denoiseProductFilename` is the one pure rule (and the same rule `forMemberFilenames` uses);
///   ⑥–⑧ deletion recycles the product even when the projection hides it, and a missing file is
///      just a row removal.
@MainActor
final class DenoiseStackMenu566Tests: XCTestCase {

    private var workDir: URL!
    private var package: URL!
    private var src: URL!
    private var catalog: Catalog!
    private var root: SourceRoot!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-denoise-menu-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        package = workDir.appendingPathComponent("D.\(LibraryLayout.packageExtension)", isDirectory: true)
        catalog = try Catalog.create(at: package)
        src = workDir.appendingPathComponent("shoot", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        root = try catalog.ensureRoot(for: src, mode: .reference)
    }

    override func tearDownWithError() throws {
        catalog = nil
        try? FileManager.default.removeItem(at: workDir)
    }

    // MARK: - fixture

    @discardableResult
    private func addAsset(_ filename: String, capture: String, writeFile: Bool = true) throws -> Asset {
        if writeFile {
            try Data([0x00]).write(to: src.appendingPathComponent(filename))
        }
        let asset = Asset(sourceRootId: root.id, relPath: filename, filename: filename,
                          ext: (filename as NSString).pathExtension, kind: .raw,
                          size: 1, mtime: 0, contentHash: UUID().uuidString,
                          captureTime: capture, captureLocalDate: "2026-03-01")
        try catalog.dbQueue.write { db in try asset.insert(db) }
        return asset
    }

    private func openSession() throws -> CatalogSession {
        _ = NSApplication.shared
        let session = CatalogSession()
        try session.open(package)
        return session
    }

    /// A denoise pair whose product is 置顶 (`productTop`) or whose original is (`productTop == false`).
    private func makeDenoisePair(productTop: Bool, writeProductFile: Bool = true) throws
        -> (original: Asset, product: Asset, summary: StackSummary) {
        let original = try addAsset("L.dng", capture: "2026-03-01T10:00:00Z")
        let product = try addAsset("L-denoised.dng", capture: "2026-03-01T10:01:00Z",
                                   writeFile: writeProductFile)
        let ordered = productTop ? [product.id, original.id] : [original.id, product.id]
        let summary = try XCTUnwrap(try catalog.makeStack(assetIDs: ordered, alignDenoiseEdits: false))
        XCTAssertEqual(summary.kind, .denoise)
        return (original, product, summary)
    }

    private func actionTitles(_ menu: NSMenu) -> [String] {
        menu.items.filter { !$0.isSeparatorItem }.map(\.title)
    }

    // MARK: - ① 普通堆叠：旧语法一个字不变

    func testAPlainStackKeepsTheOldMenu() throws {
        let l = try addAsset("A.dng", capture: "2026-03-01T10:00:00Z")
        let m = try addAsset("B.dng", capture: "2026-03-01T10:01:00Z")
        let summary = try XCTUnwrap(try catalog.makeStack(assetIDs: [l.id, m.id]))
        XCTAssertEqual(summary.kind, .plain)
        let session = try openSession()
        let target = StackMenuTarget(session: session)

        let menu = try XCTUnwrap(StackMenuBuilder.menu(session: session, target: target,
                                                        selectedIDs: [summary.topID]))
        XCTAssertEqual(menu.title, StackMenuBuilder.title, "① 普通堆叠仍叫「堆叠」")
        let titles = actionTitles(menu)
        XCTAssertTrue(titles.contains(StackMenuBuilder.setTopTitle), "① 普通堆叠仍有「设为置顶」")
        XCTAssertFalse(titles.contains(StackMenuBuilder.deleteDenoiseTitle),
                       "① 「本修改仅对降噪堆叠有效」：普通堆叠不许出现删除降噪文件")
        print("① plain = \(titles)")
    }

    // MARK: - ② 降噪堆叠：标题与两条动作

    func testADenoisePairSaysDenoiseAndOffersExactlyTwoVerbs() throws {
        let pair = try makeDenoisePair(productTop: true)
        let session = try openSession()
        let target = StackMenuTarget(session: session)

        let menu = try XCTUnwrap(StackMenuBuilder.menu(session: session, target: target,
                                                        selectedIDs: [pair.summary.topID]))
        XCTAssertEqual(menu.title, StackMenuBuilder.denoiseTitle)
        let titles = actionTitles(menu)
        XCTAssertEqual(titles, [StackMenuBuilder.ungroupTitle, StackMenuBuilder.deleteDenoiseTitle])
        XCTAssertFalse(titles.contains(StackMenuBuilder.setTopTitle), "② 不再提供「设为置顶」")
        XCTAssertFalse(titles.contains(StackMenuBuilder.makeTitle), "② 降噪子菜单不塞选择级动词")
        print("② denoise = \(titles)")
    }

    // MARK: - ③ 混合选择回落普通语法

    func testAMixedSelectionFallsBackToThePlainGrammar() throws {
        let denoise = try makeDenoisePair(productTop: true)
        let l = try addAsset("A.dng", capture: "2026-03-02T10:00:00Z")
        let m = try addAsset("B.dng", capture: "2026-03-02T10:01:00Z")
        let plain = try XCTUnwrap(try catalog.makeStack(assetIDs: [l.id, m.id]))
        let session = try openSession()
        let target = StackMenuTarget(session: session)

        let menu = try XCTUnwrap(StackMenuBuilder.menu(
            session: session, target: target,
            selectedIDs: [denoise.summary.topID, plain.topID]))
        XCTAssertEqual(menu.title, StackMenuBuilder.title, "③ 混合选择仍叫「堆叠」")
        XCTAssertFalse(actionTitles(menu).contains(StackMenuBuilder.deleteDenoiseTitle),
                       "③ 混合选择不提供删除降噪文件")
        print("③ mixed = \(actionTitles(menu))")
    }

    // MARK: - ④ attach 重入：不留幽灵 holder

    func testAttachReplacesBothHolderTitlesWithoutGrowingTheSeparators() throws {
        let denoise = try makeDenoisePair(productTop: true)
        let l = try addAsset("A.dng", capture: "2026-03-02T10:00:00Z")
        let m = try addAsset("B.dng", capture: "2026-03-02T10:01:00Z")
        let plain = try XCTUnwrap(try catalog.makeStack(assetIDs: [l.id, m.id]))
        let session = try openSession()
        let target = StackMenuTarget(session: session)

        let menu = NSMenu(title: "base")
        menu.addItem(NSMenuItem(title: "base", action: nil, keyEquivalent: ""))

        func separators() -> Int { menu.items.filter(\.isSeparatorItem).count }

        StackMenuBuilder.attach(to: menu, session: session, target: target,
                                selectedIDs: [plain.topID])
        let afterPlain = separators()
        XCTAssertEqual(menu.items.filter { $0.title == StackMenuBuilder.title }.count, 1)
        XCTAssertEqual(menu.items.filter { $0.title == StackMenuBuilder.denoiseTitle }.count, 0)

        StackMenuBuilder.attach(to: menu, session: session, target: target,
                                selectedIDs: [denoise.summary.topID])
        XCTAssertEqual(menu.items.filter { $0.title == StackMenuBuilder.title }.count, 0,
                       "④ 普通 holder 必须被清掉")
        XCTAssertEqual(menu.items.filter { $0.title == StackMenuBuilder.denoiseTitle }.count, 1)
        XCTAssertEqual(separators(), afterPlain, "④ 分隔线不增加")

        StackMenuBuilder.attach(to: menu, session: session, target: target,
                                selectedIDs: [plain.topID])
        XCTAssertEqual(menu.items.filter { $0.title == StackMenuBuilder.title }.count, 1)
        XCTAssertEqual(menu.items.filter { $0.title == StackMenuBuilder.denoiseTitle }.count, 0,
                       "④ 反向切换也不留「降噪」幽灵")
        XCTAssertEqual(separators(), afterPlain, "④ 反向切换分隔线不增加")
        print("④ holders = \(menu.items.map(\.title))")
    }

    // MARK: - ⑤ 纯函数

    func testDenoiseProductFilenameIsTheOneRule() {
        XCTAssertEqual(StackKind.denoiseProductFilename(["L.dng", "L-denoised.dng"]), "L-denoised.dng")
        XCTAssertEqual(StackKind.denoiseProductFilename(["L-denoised.dng", "L.dng"]), "L-denoised.dng")
        XCTAssertNil(StackKind.denoiseProductFilename(["L.dng", "L-denoised-2.dng"]))
        XCTAssertNil(StackKind.denoiseProductFilename(["L.dng", "M.dng"]))
        XCTAssertNil(StackKind.denoiseProductFilename(["L.dng", "L-denoised.dng", "M.dng"]))
        XCTAssertNil(StackKind.denoiseProductFilename(["L.dng", "L-denoised.jpg"]))
        XCTAssertEqual(StackKind.forMemberFilenames(["L.dng", "L-denoised.dng"]), .denoise)
        XCTAssertEqual(StackKind.forMemberFilenames(["L.dng", "M.dng"]), .plain)
        print("⑤ rule ok")
    }

    // MARK: - ⑥ 删除：产物置顶

    func testDeletingTheProductRecyclesItAndDissolvesTheStack() throws {
        let pair = try makeDenoisePair(productTop: true)
        let session = try openSession()
        XCTAssertEqual(session.assets.first { $0.id == pair.summary.topID }?.id, pair.product.id)

        var recycled: [URL] = []
        let outcome = session.deleteDenoiseProducts(inStackTopIDs: [pair.summary.topID]) {
            recycled.append($0)
        }
        print("⑥ files=\(outcome.filesTrashed) kept=\(outcome.keptIDs.count) fail=\(outcome.failures)")
        XCTAssertNotNil(outcome.removed)
        XCTAssertEqual(outcome.filesTrashed, 1)
        XCTAssertTrue(outcome.keptIDs.isEmpty)
        XCTAssertTrue(outcome.failures.isEmpty)
        XCTAssertEqual(recycled.map(\.lastPathComponent), ["L-denoised.dng"], "回收的是产物路径")
        XCTAssertNil(try catalog.asset(id: pair.product.id), "产物行被删")
        XCTAssertNotNil(try catalog.asset(id: pair.original.id), "原图仍在")
        XCTAssertNil(session.stacksByTopID[pair.summary.topID], "触发器解散了堆叠")

        let again = session.deleteDenoiseProducts(inStackTopIDs: [pair.summary.topID]) {
            recycled.append($0)
        }
        XCTAssertEqual(again.filesTrashed, 0, "再跑一次什么都不做")
        XCTAssertTrue(again.failures.isEmpty)
        print("⑥ after = \(session.assets.map(\.filename))")
    }

    // MARK: - ⑦ 产物被隐藏（置顶 = 原图）

    func testAHiddenProductIsStillRecycledAndItsRowDeleted() throws {
        let pair = try makeDenoisePair(productTop: false)
        let session = try openSession()
        XCTAssertFalse(session.assets.contains { $0.id == pair.product.id },
                       "投影里只有原图，产物是隐藏成员")

        var recycled: [URL] = []
        let outcome = session.deleteDenoiseProducts(inStackTopIDs: [pair.summary.topID]) {
            recycled.append($0)
        }
        print("⑦ files=\(outcome.filesTrashed) kept=\(outcome.keptIDs.count) fail=\(outcome.failures)")
        XCTAssertEqual(outcome.filesTrashed, 1, "隐藏的产物也必须被回收")
        XCTAssertTrue(outcome.failures.isEmpty)
        XCTAssertEqual(recycled.map(\.lastPathComponent), ["L-denoised.dng"])
        XCTAssertNil(try catalog.asset(id: pair.product.id), "隐藏产物的行也被删")
        XCTAssertNotNil(try catalog.asset(id: pair.original.id), "原图保留")
        XCTAssertNil(session.stacksByTopID[pair.summary.topID], "单成员后堆叠解散")
    }

    // MARK: - ⑧ 文件已不在盘上：只删行

    func testAMissingProductIsJustARowRemoval() throws {
        let pair = try makeDenoisePair(productTop: true, writeProductFile: false)
        let session = try openSession()

        var recycled: [URL] = []
        let outcome = session.deleteDenoiseProducts(inStackTopIDs: [pair.summary.topID]) {
            recycled.append($0)
        }
        print("⑧ files=\(outcome.filesTrashed) kept=\(outcome.keptIDs.count) fail=\(outcome.failures)")
        XCTAssertEqual(outcome.filesTrashed, 0)
        XCTAssertTrue(recycled.isEmpty)
        XCTAssertTrue(outcome.failures.isEmpty, "文件本来就不在，不是失败")
        XCTAssertNil(try catalog.asset(id: pair.product.id), "行仍然被删")
        XCTAssertNotNil(try catalog.asset(id: pair.original.id))
    }
}
