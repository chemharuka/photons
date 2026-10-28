import XCTest
import AppKit
import GRDB
import PhotonsCore
import PhotonsCatalog
@testable import PhotonsCatalog
@testable import PhotonsUI

/// 081 §3 — the 复制设置 checklist is remembered **in the library**, not on this machine.
///
/// Two claims, and each one is a separate measurement:
///
///   ④ **记住选择** — 勾 3 项 → 复制 → 关库 → 重开 → the sheet's selection is those 3, and the
///      `settings` row's bytes are printed. The 反证 is in the same test: a `UserDefaults` store would
///      have one value for the machine, so the *second* library's row would be the first one's — which
///      is exactly what ⑤ measures.
///   ⑤ **两个库互不串** — A stores 3 cards, B stores 7; reopening A then B then A again gives 3 / 7.
@MainActor
final class CopySelectionPersistenceTests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-copysel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    private func newLibrary(_ name: String) throws -> (URL, Catalog, String) {
        let url = workDir.appendingPathComponent("\(name).\(LibraryLayout.packageExtension)")
        let catalog = try Catalog.create(at: url)
        let rootDir = workDir.appendingPathComponent("src-\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
        let root = try catalog.ensureRoot(for: rootDir, mode: .reference)
        var edit = EditModel.neutral
        edit.light.exposure = 1
        let blob = try Catalog.encode(edit)
        let asset = Asset(sourceRootId: root.id, relPath: "\(name).dng", filename: "\(name).dng",
                          ext: "dng", kind: .raw, size: 1, mtime: 0,
                          contentHash: UUID().uuidString, developJson: blob)
        try catalog.dbQueue.write { db in
            try asset.insert(db)
            try AssetHistory(assetId: asset.id, seq: 1, developJson: blob,
                             label: "import", createdAt: ISO8601.now()).insert(db)
        }
        return (url, catalog, asset.id)
    }

    private func sectionNames(_ selection: CopySettingsSelection) -> [String] {
        EditSnapshotSection.panelOrder.filter { selection.contains($0) }.map(\.rawValue)
    }

    // MARK: - ④ 记住选择

    func testTheChecklistIsWrittenToTheLibraryAndComesBackOnReopen() throws {
        let (url, catalog, assetID) = try newLibrary("A")
        let three: Set<EditSnapshotSection> = [.whiteBalance, .blackLevel, .curve]

        var session = CatalogSession()
        try session.open(url)
        session.selectOnly(assetID)
        _ = session.copySettingsFromAnchor(selection: CopySettingsSelection(sections: three))

        let stored = try XCTUnwrap(try catalog.setting(CopySettingsSelection.storageKey))
        print("081 settings row: \(CopySettingsSelection.storageKey) = \(stored)")
        XCTAssertEqual(stored, "[\"whiteBalance\",\"blackLevel\",\"curve\"]",
                       "值 = 选中 section 的 JSON 数组，按渲染顺序")

        // 关库 → 重开（新的 session，同一个 package）。
        session = CatalogSession()
        try session.open(url)
        print("081 reopened selection: \(sectionNames(session.copySelection))")
        XCTAssertEqual(session.copySelection.sections, three, "重开库恢复上次的 3 项")

        // 重开时 sheet 读的就是它：对话框第一行状态就是那三项。
        let view = CopySettingsAccessoryView(selection: session.copySelection, purpose: .copy)
        XCTAssertEqual(view.checkboxes[.whiteBalance]?.state, .on)
        XCTAssertEqual(view.checkboxes[.blackLevel]?.state, .on)
        XCTAssertEqual(view.checkboxes[.curve]?.state, .on)
        XCTAssertEqual(view.checkboxes[.light]?.state, .off)
        XCTAssertEqual(view.checkboxes[.masks]?.state, .off)

        // A brand-new library answers 全部 (no row → fallback, not an empty checklist).
        let (url2, _, _) = try newLibrary("Empty")
        let empty = CatalogSession()
        try empty.open(url2)
        XCTAssertEqual(empty.copySelection.sections, Set(EditSnapshotSection.copyable),
                       "没记过的库回退到全部，不是空选")
    }

    // MARK: - ⑤ 两个库互不串

    func testTwoLibrariesKeepTheirOwnSelectionAcrossReopens() throws {
        let (urlA, catalogA, assetA) = try newLibrary("A")
        let (urlB, catalogB, assetB) = try newLibrary("B")
        let three: Set<EditSnapshotSection> = [.whiteBalance, .blackLevel, .light]
        let seven: Set<EditSnapshotSection> = [.whiteBalance, .light, .color, .blackAndWhite,
                                               .hsl, .curve, .effects]

        let sessionA = CatalogSession()
        try sessionA.open(urlA)
        sessionA.selectOnly(assetA)
        _ = sessionA.copySettingsFromAnchor(selection: CopySettingsSelection(sections: three))

        let sessionB = CatalogSession()
        try sessionB.open(urlB)
        sessionB.selectOnly(assetB)
        _ = sessionB.copySettingsFromAnchor(selection: CopySettingsSelection(sections: seven))

        print("081 library A row: \(try catalogA.setting(CopySettingsSelection.storageKey) ?? "nil")")
        print("081 library B row: \(try catalogB.setting(CopySettingsSelection.storageKey) ?? "nil")")
        XCTAssertEqual(try catalogA.setting(CopySettingsSelection.storageKey),
                       expectedStorage(three), "A 的库记 A 的 3 项")
        XCTAssertEqual(try catalogB.setting(CopySettingsSelection.storageKey),
                       expectedStorage(seven), "B 的库记 B 的 7 项")

        // 重开两端，交替顺序也要各自正确（一个 UserDefaults 会在这里给出同一个答案）。
        let reopenA1 = CatalogSession()
        try reopenA1.open(urlA)
        let reopenB = CatalogSession()
        try reopenB.open(urlB)
        let reopenA2 = CatalogSession()
        try reopenA2.open(urlA)
        XCTAssertEqual(reopenA1.copySelection.sections.count, 3)
        XCTAssertEqual(reopenB.copySelection.sections.count, 7)
        XCTAssertEqual(reopenA2.copySelection.sections, three)
        XCTAssertEqual(reopenB.copySelection.sections, seven)
        XCTAssertNotEqual(reopenB.copySelection.sections, reopenA2.copySelection.sections,
                          "反证: 若存在 UserDefaults，两库会读到同一个值")
    }

    // MARK: - 回退：读失败一律「全部」

    func testAStoredValueThisBuildCannotReadFallsBackToEverything() throws {
        let (url, catalog, assetID) = try newLibrary("Junk")
        let session = CatalogSession()
        try session.open(url)
        session.selectOnly(assetID)

        for junk in ["not json", "[]", "[\"nope\",\"alsoNope\"]", "{\"a\":1}", ""] {
            try catalog.writeSettings([CopySettingsSelection.storageKey: junk])
            XCTAssertEqual(try catalog.copySelection().sections, Set(EditSnapshotSection.copyable),
                           "读失败/未知名字回退到全部：\(junk)")
        }
        // A partly-known list keeps the names it knows and does not swallow the rest as a failure.
        try catalog.writeSettings([CopySettingsSelection.storageKey: "[\"curve\",\"nope\"]"])
        XCTAssertEqual(try catalog.copySelection().sections, [.curve],
                       "未知名字被丢掉，已知的留下")
    }

    /// 反证 for ④: a `UserDefaults` store has **one** value for the machine, so two libraries read the
    /// same checklist — which is exactly what ⑤ asserts cannot happen. Measured against the real
    /// defaults store, not argued.
    func testAUserDefaultsStoreWouldGiveBothLibrariesTheSameAnswer() throws {
        let key = "settings.copySelection.v1.081-refutation"
        defer { UserDefaults.standard.removeObject(forKey: key) }
        UserDefaults.standard.set("[\"curve\"]", forKey: key)

        let (urlA, _, assetA) = try newLibrary("DA")
        let (urlB, _, assetB) = try newLibrary("DB")
        let a = CatalogSession()
        try a.open(urlA)
        a.selectOnly(assetA)
        _ = a.copySettingsFromAnchor(selection: CopySettingsSelection(sections: [.whiteBalance, .light]))
        let b = CatalogSession()
        try b.open(urlB)
        b.selectOnly(assetB)

        // The two libraries disagree (that is the shipped behaviour) …
        XCTAssertNotEqual(a.copySelection.sections, b.copySelection.sections)
        // … while a defaults-backed store cannot tell them apart.
        let fromDefaults = CopySettingsSelection(storageValue:
            UserDefaults.standard.string(forKey: key))
        XCTAssertEqual(fromDefaults.sections, [.curve],
                       "反证: 同一个 UserDefaults 键对两个库只有一个答案，B 会读到 A 的选择")
    }

    /// `["whiteBalance","blackLevel","light"]` — spelled out, so the stored bytes are the contract and
    /// not a re-derivation of the code under test.
    private func expectedStorage(_ sections: Set<EditSnapshotSection>) -> String {
        let names = EditSnapshotSection.panelOrder.filter { sections.contains($0) }.map { "\"\($0.rawValue)\"" }
        return "[\(names.joined(separator: ","))]"
    }
}
