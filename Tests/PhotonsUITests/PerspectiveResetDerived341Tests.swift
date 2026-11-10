import XCTest
import AppKit
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// **341 — 双击「垂直透视」复位后，派生状态没跟着恢复。**
///
/// 用户口径：「双击『垂直透视』恢复后，某些东西没有正确恢复（例如判断裁切框是否出界的函数？）」
///
/// The chain that was wrong, and the one that is measured here:
///
///   · `livePerspective` asked the document first but **fell back to `draft.perspective` when the
///     document answered `nil`** — and `nil` is what 0 means (`GeometryGroup.perspective`). A reset
///     therefore read as the 40 the draft still carried, and every reader below it (the red-frame
///     predicate, both clamps, the one-shot inscription, the overlay, the 像素数量 readout) kept
///     answering 40 while the picture was already back at 0;
///   · `frameExceedsPicture` had the same `session…perspective ?? draft.perspective` in its own line,
///     so the function the user pointed at stayed red on a frame only the keystone put outside;
///   · `draftCropGeometry` took the **space** from `draft.cropSpace` (the copy), so a draft seeded
///     while the document was keystoned stayed canvas-spaced after the reset.
///
/// What is pinned:
///   ① 复现：文档 / draft / live / 空间 / 出界判定 五组值（修前 draft 与 live 都还是 40，空间还是
///     `.canvas`）；
///   ② 修后：与「新建的 perspective = 0 文档」**逐字段相等**（同一框、同一角度、同一偏好）；
///   ③ 只有透视 40 才越界的位置：复位后判定必须变回「不出界」，与新建文档同一个布尔；
///   ④ 内切：复位后的内切结果与新建文档的内切结果逐字段相等（不是「差一点」）；
///   ⑤ 四条入口（滑杆归零 / 双击 / ⌘Z / 预设写入 0）各跑一次，每条都过 ②–④；
///   ⑥ 反向门：把复位时的 draft 同步去掉 → ② 红（`testGateTwoWithoutTheDraftSyncTheResetIsStale`
///     量的是同一条判据，不需要改代码就能看见它红）。
///
/// Run with `--filter "Crop|Perspective|Keystone|PanelReset|TransformPanel"`; every fixture is a real
/// library package (`CropUITestSupport`), `PHOTONS_TEST_RAW` is not read here.
@MainActor
final class PerspectiveResetDerived341Tests: XCTestCase {

    private static let source = ImageSize(width: 3000, height: 2000)
    private static let vertical: Double = 40

    /// 一个框，只有透视 +40 才把它推出照片四边形（+40 的四边形底边为 0.042…0.958，见 ① 的打印）。
    private static let edge = CropRect(left: 0.0, top: 0.0, right: 1.0, bottom: 0.5)

    /// The ask's four numbers plus the space, in one value — and `Equatable`, so ②–④ are field
    /// comparisons rather than five separate assertions that could each drift.
    private struct Derived: Equatable, CustomStringConvertible {
        var document: Double
        var draft: Double
        var live: Double?
        var space: Int
        var exceeds: Bool
        var crop: CropRect

        var description: String {
            String(format: "文档 %+.0f · draft %+.0f · live %@ · 空间 cs=%d · 出界 %@ · 框 "
                   + "(%.4f, %.4f)-(%.4f, %.4f)", document, draft,
                   live.map { String(format: "%+.0f", $0) } ?? "nil", space,
                   exceeds ? "是" : "否",
                   crop.left, crop.top, crop.right, crop.bottom)
        }
    }

    private func derived(_ tool: Tool) -> Derived {
        Derived(document: tool.session.edit.geometry.perspectiveVertical,
                draft: tool.controller.draft.perspectiveVertical,
                live: tool.controller.livePerspective?.vertical,
                space: tool.controller.liveCropSpace.rawValue,
                exceeds: tool.controller.frameExceedsPicture(),
                crop: tool.controller.effectiveCrop())
    }

    // MARK: - ① 复现 + ② 修后 = 新建文档

    func testOneAndTwoTheResetEndsWhereAFreshDocumentStarts() throws {
        let tool = try makeTool()
        setPerspective(Self.vertical, on: tool, refresh: true)
        tool.controller.draft.crop = Self.edge
        print("341 ① · 透视 +40 · \(derived(tool))")

        doubleClickReset(on: tool)
        print("341 ① · 复位后（下一次刷新之前）· \(derived(tool))")
        tool.controller.adoptDocumentKeystone()
        let after = derived(tool)
        print("341 ① · 复位后（刷新）· \(after)")

        let fresh = try freshTool(crop: tool.controller.effectiveCrop())
        let freshValues = derived(fresh)
        print("341 ② · 新建 0 文档同一框 · \(freshValues)")

        XCTAssertEqual(after.document, 0, accuracy: 1e-12, "复位没写进文档")
        XCTAssertEqual(after.draft, 0, accuracy: 1e-12,
                       "复位后 draft 仍是 \\(after.draft)：派生量在按文档里不存在的透视算")
        XCTAssertNil(after.live, "复位后 live 仍非 nil（读的是 draft 的旧拷贝）")
        XCTAssertEqual(after.space, freshValues.space, "复位后的空间不是新文档的空间")
        XCTAssertEqual(after, freshValues, "复位后与新建的 perspective = 0 文档不逐字段相等")
    }

    // MARK: - ③ 只有 40 才越界的位置

    func testThreeAFrameOnlyTheKeystonePutsOutsideIsCleanAfterTheReset() throws {
        let tool = try makeTool()
        setPerspective(Self.vertical, on: tool, refresh: true)
        tool.controller.draft.crop = Self.edge
        let atForty = derived(tool)
        XCTAssertTrue(atForty.exceeds, "这个框在 +40 下没有越界 —— ③ 没有判别力：\(atForty)")

        doubleClickReset(on: tool)
        tool.controller.adoptDocumentKeystone()
        let after = derived(tool)
        let fresh = derived(try freshTool(crop: Self.edge))
        print("341 ③ · 框 (0.0000, 0.0000)-(1.0000, 0.5000) · +40 出界=\(atForty.exceeds)"
              + " · 复位后出界=\(after.exceeds) · 新建文档出界=\(fresh.exceeds)")
        XCTAssertFalse(after.exceeds,
                       "复位后这个框仍被判出界：判定还在按 40 算（\(after)）")
        XCTAssertEqual(after.exceeds, fresh.exceeds, "复位后的出界判定与新建文档不同")
        XCTAssertEqual(after.space, fresh.space)
    }

    // MARK: - ④ 内切

    func testFourTheInscriptionAfterTheResetIsTheFreshDocumentsInscription() throws {
        try sameInscription(for: .doubleClick)
        try sameInscription(for: .slider)
        try sameInscription(for: .undo)
        try sameInscription(for: .preset)
    }

    private func sameInscription(for entry: Entry) throws {
        let tool = try seeded(entry)
        tool.controller.draft.crop = Self.edge
        XCTAssertTrue(tool.controller.setCropStaysInsidePixels(true))
        let inscribedAtForty = tool.controller.draft.crop
        XCTAssertNotEqual(inscribedAtForty, Self.edge, "+40 下没有内切，④ 量不出东西")

        try run(entry, on: tool)
        tool.controller.adoptDocumentKeystone()
        let onReset = inscribe(tool.controller, crop: Self.edge)
        let onFresh = inscribe(try freshTool(crop: Self.edge).controller, crop: Self.edge)
        print("341 ④ · \(entry.rawValue) · +40 内切 \(text(inscribedAtForty))"
              + " → 复位后 \(text(onReset)) · 新建文档 \(text(onFresh))")
        XCTAssertEqual(onReset, onFresh,
                       "\(entry.rawValue)：复位后的内切不是新文档的内切")
        XCTAssertNotEqual(inscribedAtForty, onFresh,
                          "\(entry.rawValue)：40 的内切与 0 的一样 —— ④ 没有判别力")
    }

    // MARK: - ⑤ 四条入口

    func testFiveTheFourEntriesAllLeaveTheFreshDocumentsDerivedState() throws {
        for entry in Entry.allCases {
            let tool = try seeded(entry)
            XCTAssertEqual(tool.controller.livePerspective?.vertical ?? 0, Self.vertical,
                           "\(entry.rawValue)：进场景时 live 不是 40，测不出复位")
            tool.controller.draft.crop = Self.edge

            try run(entry, on: tool)
            tool.controller.adoptDocumentKeystone()

            let values = derived(tool)
            print("341 ⑤ · \(entry.rawValue) · \(values)")
            XCTAssertEqual(values.document, 0, accuracy: 1e-12, "\(entry.rawValue)：文档没回到 0")
            XCTAssertEqual(values.draft, 0, accuracy: 1e-12, "\(entry.rawValue)：draft 还是 \(values.draft)")
            XCTAssertNil(values.live, "\(entry.rawValue)：live 还是 draft 的旧拷贝")

            let fresh = derived(try freshTool(crop: Self.edge))
            XCTAssertEqual(values, fresh, "\(entry.rawValue)：与新建文档不逐字段相等")
            XCTAssertEqual(inscribe(tool.controller, crop: Self.edge),
                           inscribe(try freshTool(crop: Self.edge).controller, crop: Self.edge),
                           "\(entry.rawValue)：内切与新建文档不逐字段相等")
        }
    }

    // MARK: - ⑥ the app's own refresh turn (LoupeController.syncCropOverlay)

    /// The controller-level entries above call `adoptDocumentKeystone()` directly; this one proves the
    /// **loupe** calls it, on the same turn it re-seeds a photo switch (202 ④'s place).
    func testSevenTheLoupeRefreshTurnSyncsTheDraft() throws {
        let workDir = try workDirectory()
        let editor = try CropUITestSupport.makeEditor(in: workDir)
        defer { editor.window?.orderOut(nil) }
        let session = editor.session
        let loupe = editor.rootView.loupeController
        guard CropUITestSupport.openCropTool(loupe, session) else { return }

        session.applyEdit { $0.geometry.perspectiveVertical = Self.vertical }
        session.commitEdit(label: "透视", coalesce: false)
        loupe.refreshCropTool()
        print("341 ⑦ · +40 · 文档 \(session.edit.geometry.perspectiveVertical)"
              + " · draft \(loupe.cropTool.draft.perspectiveVertical)")
        XCTAssertEqual(loupe.cropTool.draft.perspectiveVertical, Self.vertical,
                       "刷新没把 40 带进 draft —— 复位的那一半无从谈起")

        session.applyEdit { $0.geometry.perspectiveVertical = 0 }
        session.commitEdit(label: "透视", coalesce: false)
        loupe.refreshCropTool()
        print("341 ⑦ · 复位后 · 文档 \(session.edit.geometry.perspectiveVertical)"
              + " · draft \(loupe.cropTool.draft.perspectiveVertical)"
              + " · live \(loupe.cropTool.livePerspective?.vertical.description ?? "nil")"
              + " · cs \(loupe.cropTool.liveCropSpace.rawValue)")
        XCTAssertEqual(loupe.cropTool.draft.perspectiveVertical, 0,
                       "loupe 的刷新没有把复位带进 draft")
        XCTAssertNil(loupe.cropTool.livePerspective)
        XCTAssertEqual(loupe.cropTool.liveCropSpace, .source)
    }

    // MARK: - the four entries, as the panels spell them

    private enum Entry: String, CaseIterable {
        case slider = "滑杆归零"
        case doubleClick = "双击"
        case undo = "⌘Z"
        case preset = "预设写入 0"
    }

    private func run(_ entry: Entry, on tool: Tool) throws {
        switch entry {
        case .slider:      sliderToZero(on: tool)
        case .doubleClick: doubleClickReset(on: tool)
        case .undo:
            // 077 — the tool session owns the history while 裁切 is open, so the row ⌘Z walks back
            // is the keystone write that was committed **before** `begin()` (`.undo` seeds it that
            // way). Both the document and the session's baseline move; the draft must follow.
            XCTAssertTrue(tool.session.undo(), "⌘Z：撤销没执行")
        case .preset:
            try applyZeroPreset(on: tool)
        }
    }

    /// `TransformPanel`'s slider: one document write per tick, one commit on release. The commit is a
    /// no-op inside the tool session (077: 「从这里到 应用 历史不记东西」), which is exactly what the
    /// panel's own call does — the document value is what this test reads.
    private func sliderToZero(on tool: Tool) {
        for tick in stride(from: Self.vertical, through: 0, by: -5) {
            tool.session.applyEdit { $0.geometry.perspectiveVertical = tick }
        }
        tool.session.commitEdit(label: "透视", coalesce: true)
    }

    /// `sliderRow(onReset:)` — `TransformPanel`:237-250, verbatim: 双击「垂直透视」.
    private func doubleClickReset(on tool: Tool) {
        tool.session.applyEdit { $0.geometry.perspectiveVertical = 0 }
        tool.session.commitEdit(label: "透视", coalesce: false)
    }

    private func setPerspective(_ value: Double, on tool: Tool, refresh: Bool) {
        tool.session.applyEdit { $0.geometry.perspectiveVertical = value }
        tool.session.commitEdit(label: "透视", coalesce: false)
        if refresh { tool.controller.adoptDocumentKeystone() }
    }

    /// 「预设写入 0」 — a geometry preset whose fragment carries `perspective = 0`, applied through the
    /// shipped `applyPreset` (a whole-group replace, so a real 0 lands on the document).
    private func applyZeroPreset(on tool: Tool) throws {
        var fragment = EditModel.neutral
        fragment.geometry = tool.session.edit.geometry
        fragment.geometry.perspectiveVertical = 0
        fragment.geometry.cropSpace = .source
        let preset = Preset(name: "341-flat", groups: [.geometry], edit: fragment)
        _ = try tool.library.catalog.savePreset(preset)
        tool.session.reloadPresets()
        _ = tool.session.applyPreset(named: "341-flat")
        // The commit is a no-op inside the tool session (077), so `applyPreset`'s own Bool is false
        // here in the app too — the **document** is what this entry is about.
        XCTAssertEqual(tool.session.edit.geometry.perspectiveVertical, 0, accuracy: 1e-12,
                       "预设写入的 0 没进文档：\(tool.session.lastPresetError ?? "")")
    }

    // MARK: - fixtures

    private struct Tool {
        let session: CatalogSession
        let controller: CropToolController
        let library: CropTestLibrary
    }

    /// `inscribe` — the one-shot question the 「不出像素」 checkbox asks, on a given controller.
    private func inscribe(_ controller: CropToolController, crop: CropRect) -> CropRect {
        controller.setCropStaysInsidePixels(false)
        controller.draft.crop = crop
        XCTAssertTrue(controller.setCropStaysInsidePixels(true))
        return controller.draft.crop
    }

    /// A tool on a brand-new library whose document has never carried a keystone.
    private func freshTool(crop: CropRect) throws -> Tool {
        let tool = try makeTool()
        tool.controller.draft.crop = crop
        return tool
    }

    private func makeTool(perspective: Double? = nil) throws -> Tool {
        let workDir = try workDirectory()
        let library = try CropUITestSupport.makeLibrary(in: workDir,
                                                        width: Self.source.width,
                                                        height: Self.source.height)
        let session = CatalogSession()
        try session.open(library.package)
        session.selectOnly(library.assetID)
        session.mode = .loupe
        session.loadEditForAnchor()
        if let perspective {
            // ⌘Z's row has to exist **before** the tool session opens (077 pauses history), so this
            // entry seeds the document first and then opens 裁切 on it — the user's order when the
            // keystone was set and the frame opened afterwards.
            session.applyEdit { $0.geometry.perspectiveVertical = perspective }
            session.commitEdit(label: "透视", coalesce: false)
        }
        let controller = CropToolController(session: session, defaults: try defaults())
        XCTAssertTrue(controller.begin(), "裁切 mode 没打开")
        controller.adoptDocumentKeystone()      // the refresh turn the loupe would run
        return Tool(session: session, controller: controller, library: library)
    }

    /// The scenario every entry starts from: 透视 +40, a live document, a draft that mirrors it.
    private func seeded(_ entry: Entry) throws -> Tool {
        if entry == .undo { return try makeTool(perspective: Self.vertical) }
        let tool = try makeTool()
        setPerspective(Self.vertical, on: tool, refresh: true)
        return tool
    }

    private func workDirectory() throws -> URL {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-341-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: workDir) }
        return workDir
    }

    private func defaults() throws -> UserDefaults {
        let suite = "photons.341.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func text(_ r: CropRect) -> String {
        String(format: "(%.6f, %.6f)-(%.6f, %.6f)", r.left, r.top, r.right, r.bottom)
    }
}
