import XCTest
import AppKit
import GRDB
import PhotonsCore
import PhotonsCatalog
@testable import PhotonsCatalog
@testable import PhotonsUI

/// 319 — the copy sheet, drawn like Lightroom's Copy Settings.
///
/// 「仿照 lightroom 去设计，即需要更加细分，而不是只按照卡片来」 is a claim about **rows**, and
/// 「复制开发卡片的复制没有效果（例如复制解码器版本为 v9dng 无效）」 is a claim about **one leaf**.
/// Both are measured on the real controls and the real catalog here:
///
///   ① `rows(showsChildren: true).count == 15 + Σ children`, and 15 cards are still 15 cards;
///   ② a card's box is on / off / **mixed** as its parameter rows move — three assertions, one per
///      state, driven through the checkbox the user would click;
///   ③ collapsing one card removes exactly its parameter rows (N of them) and leaves every other card
///      whole; 展开全部 / 收起全部 restore the whole list;
///   ④ 文档 A pins 解码器版本 9, 只勾「开发 → 解码器版本」, ⌘V onto B → `B.edit.decoderVersion == "9"`
///      and B's `DecodeCacheKey` **text** changes (both strings printed);
///   ⑤ 反证 for ④ at the paste level: a 开发 copy that does **not** ask for the version cannot move it.
///   ⑥ 只勾 Light → B's decoder stays what it was (no accidental re-decode of every photo).
@MainActor
final class CopySheetLightroomTests: XCTestCase {

    private var workDir: URL!
    private var packageURL: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-copysheet319-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        packageURL = workDir.appendingPathComponent("CS319.\(LibraryLayout.packageExtension)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    // MARK: - fixtures

    /// A: the look, with the decoder pinned to v9 — the user's own example.
    private func documentA() -> EditModel {
        var a = EditModel.neutral
        a.decoderVersion = "9"
        a.light.exposure = 1.2
        a.light.contrast = 15
        a.detail.sharpening = 40
        a.color.saturation = 25
        return a
    }

    /// B: its own values, no decoder pinned.
    private func documentB() -> EditModel {
        var b = EditModel.neutral
        b.light.exposure = -0.4
        b.light.contrast = 6
        b.detail.sharpening = 5
        b.color.saturation = 30
        return b
    }

    @discardableResult
    private func insertAsset(_ catalog: Catalog, name: String, edit: EditModel) throws -> String {
        let rootDir = workDir.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
        let root = try catalog.ensureRoot(for: rootDir, mode: .reference)
        let blob = try Catalog.encode(edit)
        let asset = Asset(sourceRootId: root.id, relPath: name, filename: name, ext: "dng",
                          kind: .raw, size: 1024, mtime: 0,
                          contentHash: UUID().uuidString, developJson: blob)
        try catalog.dbQueue.write { db in
            try asset.insert(db)
            try AssetHistory(assetId: asset.id, seq: 1, developJson: blob,
                             label: "import", createdAt: ISO8601.now()).insert(db)
        }
        return asset.id
    }

    private func makeSession() throws -> (CatalogSession, Catalog, [String]) {
        let setup = try Catalog.create(at: packageURL)
        let ids = [try insertAsset(setup, name: "A.dng", edit: documentA()),
                   try insertAsset(setup, name: "B.dng", edit: documentB())]
        let reader = try Catalog.open(at: packageURL)
        let session = CatalogSession()
        try session.open(packageURL)
        session.selectOnly(ids[0])
        return (session, reader, ids)
    }

    /// The cache key the store would file this document's buffer under. The spelling mirrors the
    /// loupe's: the document's pinned model, or `auto` when it follows the file.
    private func cacheKey(_ edit: EditModel, file: String) -> DecodeCacheKey {
        let inputs = edit.decodeInputs
        return DecodeCacheKey(fileSHA256: file,
                              decoderVersion: inputs.decoderVersion ?? "auto",
                              whiteBalance: inputs.whiteBalance,
                              detail: inputs.detail,
                              decodeRecipe: inputs.recipe)
    }

    // MARK: - ① rows

    func testTheSheetDrawsFifteenCardsPlusEveryParameterByDefault() {
        XCTAssertTrue(CopySettingsSheet.showsChildren, "319：子项默认展开（081 的开关翻过来了）")

        let childCount = EditSnapshotChild.allCases.count
        let rows = CopySettingsAccessoryView.rows(showsChildren: CopySettingsSheet.showsChildren)
        print("319 rows: \(rows.count) = 15 cards + \(childCount) parameters"
              + " (allCases=\(childCount), Σ sections=\(EditSnapshotSection.panelOrder.flatMap(\.children).count))")
        XCTAssertEqual(rows.filter(\.isCard).count, 15)
        XCTAssertEqual(rows.filter { !$0.isCard }.count, childCount)
        XCTAssertEqual(rows.count, 15 + childCount)
        XCTAssertEqual(EditSnapshotSection.panelOrder.flatMap(\.children).count, childCount,
                       "每张卡的子项表就是 allCases 的切分，二者不许各说一套")

        // The real sheet agrees with the pure function — that is the point of having one.
        let view = CopySettingsAccessoryView(selection: .all, purpose: .copy)
        view.layoutSubtreeIfNeeded()
        print("319 sheet: rows=\(view.rows.count) cardBoxes=\(view.checkboxes.count)"
              + " childBoxes=\(view.childCheckboxes.count) triangles=\(view.disclosureButtons.count)")
        XCTAssertEqual(view.rows.count, 15 + childCount)
        XCTAssertEqual(view.checkboxes.count, 15)
        XCTAssertEqual(view.childCheckboxes.count, childCount)
        XCTAssertEqual(view.disclosureButtons.count, 15, "每张卡一个展开三角")
        XCTAssertEqual(view.rows.filter(\.isCard).map(\.title),
                       CopySettingsAccessoryView.rows(showsChildren: false).map(\.title),
                       "卡序仍是 panelOrder")

        // 开发 卡 now has six parameters — the five it always had plus 解码器版本.
        let detailChildren = EditSnapshotSection.detail.children
        XCTAssertEqual(detailChildren.count, 6)
        XCTAssertTrue(detailChildren.contains(.decoderVersion))
        XCTAssertEqual(view.childCheckboxes[.decoderVersion]?.title, "解码器版本")
        XCTAssertEqual(view.childCheckboxes[.decoderVersion]?.controlSize, .small,
                       "参数行是 small（§2.3）")
    }

    // MARK: - ② three-state parent

    func testACardsBoxIsOnThenMixedThenOffAsItsParametersMove() {
        let view = CopySettingsAccessoryView(selection: .all, purpose: .copy)
        view.layoutSubtreeIfNeeded()
        let lightChildren = EditSnapshotSection.light.children
        XCTAssertEqual(lightChildren.count, 8)

        // on
        XCTAssertEqual(view.cardState(for: .light), .on, "全部参数在 → on")
        XCTAssertEqual(view.checkboxes[.light]?.allowsMixedState, true)

        // mixed — one parameter off, the rest untouched.
        view.click(.exposure)
        print("319 tri-state: after 1 off → state=\(view.cardState(for: .light).rawValue)"
              + " sections=\(view.selection.sections.map(\.rawValue).sorted())")
        XCTAssertEqual(view.cardState(for: .light), .mixed, "少一个参数 → mixed")
        XCTAssertEqual(view.checkboxes[.light]?.state, .mixed, "控件上真的画成 mixed")
        XCTAssertTrue(view.selection.sections.contains(.light), "mixed 的卡仍然参与粘贴")

        // off — every parameter off (and the model drops the card with its last child).
        view.click(.exposure)  // back on
        XCTAssertEqual(view.cardState(for: .light), .on)
        for child in lightChildren { view.click(child) }
        print("319 tri-state: after all off → state=\(view.cardState(for: .light).rawValue)"
              + " sections=\(view.selection.sections.map(\.rawValue).sorted())")
        XCTAssertEqual(view.cardState(for: .light), .off)
        XCTAssertEqual(view.checkboxes[.light]?.state, .off)
        XCTAssertFalse(view.selection.sections.contains(.light))

        // and back: clicking the (now off) card turns it whole on again.
        view.click(.light)
        XCTAssertEqual(view.cardState(for: .light), .on)
        XCTAssertEqual(view.selection.children.intersection(lightChildren), Set(lightChildren))

        // A card with no parameter rows at all — 蒙版 — is plain on/off, never mixed.
        XCTAssertTrue(EditSnapshotSection.masks.children.isEmpty)
        XCTAssertEqual(view.cardState(for: .masks), .on, "无子项的卡：勾选就是 on（初值 全部）")
        view.click(.masks)
        XCTAssertEqual(view.cardState(for: .masks), .off)
        view.click(.masks)
        XCTAssertEqual(view.cardState(for: .masks), .on)
    }

    // MARK: - ③ collapse / expand

    func testCollapsingOneCardRemovesExactlyItsParameterRows() {
        let view = CopySettingsAccessoryView(selection: .all, purpose: .copy)
        view.layoutSubtreeIfNeeded()
        let before = view.rows.count
        let beforeFrames = view.rowFrames.count
        XCTAssertEqual(before, beforeFrames, "每行都有框")

        let collapsed = EditSnapshotSection.detail
        let removedChildren = collapsed.children
        let otherCardsBefore = view.rows.compactMap { row -> EditSnapshotSection? in
            if case .child(_, let card) = row, card != collapsed { return card }
            return nil
        }
        print("319 collapse: 收起「\(collapsed.title)」 \(removedChildren.count) 个参数；"
              + "行数 \(before) → \(before - removedChildren.count)")

        view.clickDisclosure(collapsed)
        view.layoutSubtreeIfNeeded()
        print("319 collapse: rows=\(view.rows.count) frames=\(view.rowFrames.count)"
              + " collapsed=\(view.collapsedCards.map(\.title).sorted())")

        XCTAssertEqual(view.collapsedCards, [collapsed])
        XCTAssertEqual(view.rows.count, before - removedChildren.count, "只少了这一张卡的参数行")
        XCTAssertEqual(view.rowFrames.count, before - removedChildren.count, "框也跟着少了 N 行")
        XCTAssertFalse(view.rows.contains { row in
            if case .child(_, let card) = row { return card == collapsed }
            return false
        }, "被收起的卡一个参数行都不剩")
        XCTAssertTrue(view.rows.contains(.card(collapsed)), "卡片自己那一行还在")
        // Every other card keeps its parameter rows — the same cards, the same number of them.
        let otherCardsAfter = view.rows.compactMap { row -> EditSnapshotSection? in
            if case .child(_, let card) = row, card != collapsed { return card }
            return nil
        }
        XCTAssertEqual(otherCardsAfter, otherCardsBefore, "其余卡的参数行一个没动")
        XCTAssertEqual(view.childCheckboxes.count, EditSnapshotChild.allCases.count - removedChildren.count)
        // Collapsing is presentation only: nothing was unchecked.
        XCTAssertTrue(view.selection.children.isSuperset(of: removedChildren),
                      "收起只是不画，不许把勾去掉")

        // 展开全部 / 收起全部.
        view.collapseAllButton?.performClick(nil)   // 反证友好：没有这个按钮时只是不点，不崩
        view.layoutSubtreeIfNeeded()
        print("319 收起全部: rows=\(view.rows.count) frames=\(view.rowFrames.count) collapsed=\(view.collapsedCards.count)")
        XCTAssertEqual(view.rows.count, 15)
        XCTAssertEqual(view.rowFrames.count, 15)
        XCTAssertEqual(view.collapsedCards.count, 15)

        view.expandAllButton?.performClick(nil)
        view.layoutSubtreeIfNeeded()
        print("319 展开全部: rows=\(view.rows.count) frames=\(view.rowFrames.count) collapsed=\(view.collapsedCards.count)")
        XCTAssertEqual(view.rows.count, before)
        XCTAssertEqual(view.rowFrames.count, beforeFrames)
        XCTAssertTrue(view.collapsedCards.isEmpty)
    }

    // MARK: - ④ 解码器版本 is copied, and the buffer key moves

    func testADecoderVersionCopyMovesTheDecoderAndTheCacheKey() throws {
        let (session, catalog, ids) = try makeSession()
        let (a, b) = (ids[0], ids[1])
        session.selectOnly(a)

        // 只勾「开发 → 解码器版本」, through the real checkbox.
        let view = CopySettingsAccessoryView(selection: .none, purpose: .copy)
        view.layoutSubtreeIfNeeded()
        view.click(.decoderVersion)
        let choice = view.selection
        print("319 只勾解码器版本: sections=\(choice.sections.map(\.rawValue).sorted())"
              + " children=\(choice.children.map(\.rawValue).sorted())"
              + " cardState=\(view.cardState(for: .detail).rawValue)")
        XCTAssertEqual(choice.sections, [.detail])
        XCTAssertEqual(choice.children, [.decoderVersion])
        XCTAssertEqual(view.cardState(for: .detail), .mixed, "开发卡只有一个参数被勾 → mixed")

        let payload = try XCTUnwrap(session.copySettingsFromAnchor(selection: choice))
        XCTAssertEqual(payload.decoderVersion, "9", "只带版本，不带锐化")
        XCTAssertNil(payload.detail)
        XCTAssertTrue(payload.requiresDecode, "粘贴它要重解，且只重解这一种情况")
        XCTAssertFalse(payload.isEmpty)

        let before = try catalog.develop(forAsset: b)
        XCTAssertNil(before.decoderVersion, "B 本来跟随 Apple")
        let beforeKey = cacheKey(before, file: b)
        session.selectOnly(b)
        let reports = session.pasteSettings(selection: choice)
        let after = try catalog.develop(forAsset: b)
        let afterKey = cacheKey(after, file: b)

        print("319 paste → B: decoderVersion=\(String(describing: after.decoderVersion))"
              + " changed=\(reports.first?.changed ?? false)"
              + " requiresDecode=\(reports.first?.requiresDecode ?? false)"
              + " fields=\(reports.first?.fields.map(\.field.key) ?? [])")
        print("319 DecodeCacheKey before: \(beforeKey.keyText)")
        print("319 DecodeCacheKey after : \(afterKey.keyText)")

        XCTAssertEqual(after.decoderVersion, "9", "B 的解码器版本变成 A 的")
        XCTAssertNotEqual(beforeKey.keyText, afterKey.keyText,
                          "缓存键必须变：否则会命中旧的 v8 缓冲，画面不动")
        XCTAssertNotEqual(beforeKey.digest, afterKey.digest)
        XCTAssertTrue(afterKey.keyText.contains("9"), afterKey.keyText)
        XCTAssertEqual(after.light.exposure, before.light.exposure, "只勾版本时曝光不许动")
        XCTAssertEqual(after.detail, before.detail)
        XCTAssertEqual(after.color, before.color)
        XCTAssertTrue(reports.allSatisfy(\.requiresDecode))
        XCTAssertEqual(try catalog.editHistory(forAsset: b).count, 2, "粘贴写一行历史")
    }

    /// 反证 for ④ at the paste level: a 开发 copy that leaves 解码器版本 out cannot move the decoder, no
    /// matter what the source document says. This is the pre-319 behaviour, kept as a measurement.
    func testADevelopCopyWithoutTheVersionCannotMoveTheDecoder() throws {
        let (session, catalog, ids) = try makeSession()
        let (a, b) = (ids[0], ids[1])
        session.selectOnly(a)

        let view = CopySettingsAccessoryView(selection: .none, purpose: .copy)
        view.layoutSubtreeIfNeeded()
        for child in EditSnapshotSection.detail.children where child != .decoderVersion {
            view.click(child)
        }
        let choice = view.selection
        XCTAssertEqual(choice.sections, [.detail])
        XCTAssertFalse(choice.children.contains(.decoderVersion))

        let payload = try XCTUnwrap(session.copySettingsFromAnchor(selection: choice))
        XCTAssertNil(payload.decoderVersion)
        XCTAssertFalse(payload.requiresDecode, "其余五个参数只重渲染")

        let before = try catalog.develop(forAsset: b)
        session.selectOnly(b)
        _ = session.pasteSettings(selection: choice)
        let after = try catalog.develop(forAsset: b)
        print("319 反证 只勾锐化等五项 → B: version=\(String(describing: after.decoderVersion))"
              + " sharpening=\(after.detail.sharpening)")
        XCTAssertNil(after.decoderVersion, "不勾版本，解码器一个字节都不许动")
        XCTAssertEqual(after.detail.sharpening, 40, "该变的还是变了")
    }

    // MARK: - ⑥ 不误伤

    func testALightOnlyPasteLeavesTheDecoderAlone() throws {
        let (session, catalog, ids) = try makeSession()
        let (a, b) = (ids[0], ids[1])
        session.selectOnly(a)

        let view = CopySettingsAccessoryView(selection: .none, purpose: .copy)
        view.layoutSubtreeIfNeeded()
        view.click(.light)
        let choice = view.selection
        XCTAssertEqual(choice.sections, [.light])

        let payload = try XCTUnwrap(session.copySettingsFromAnchor(selection: choice))
        XCTAssertNil(payload.decoderVersion)
        XCTAssertFalse(payload.requiresDecode)

        let before = try catalog.develop(forAsset: b)
        session.selectOnly(b)
        _ = session.pasteSettings(selection: choice)
        let after = try catalog.develop(forAsset: b)
        print("319 只勾 Light → B: version \(String(describing: before.decoderVersion))"
              + " → \(String(describing: after.decoderVersion)) exposure=\(after.light.exposure)")
        XCTAssertNil(after.decoderVersion, "只勾 Light：B 的 decoderVersion 不变")
        XCTAssertEqual(after.light.exposure, 1.2)
        XCTAssertEqual(after.detail, before.detail)
    }
}
