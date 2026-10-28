import XCTest
import AppKit
import GRDB
import PhotonsCore
import PhotonsCatalog
@testable import PhotonsCatalog
@testable import PhotonsUI

/// 派单 078 P0-7 on the **shipped path**: ⌘C/⌘V through `CatalogSession`, three photos in one
/// library, with the history counts and the field tables as the gate.
///
/// What is pinned, and why each assertion is the one that matters:
///
///   ① **只带非默认字段**: A (exposure + contrast, balance left at as-shot) → B (its own 4800 K
///      balance, its own −0.4 EV, its own saturation, its own mask). B's balance, saturation, crop
///      and mask are printed and asserted field by field; only A's two tone leaves move.
///   ② **选组**: pasting `[.light, .curve]` from a source that *does* pin a balance leaves that
///      balance — and colour, crop, masks — untouched: the narrowing is field-level, because
///      `.whiteBalance` and `.light` share one `LightPatch`.
///   ③ **一次粘贴 = 一条历史**: `history.count + 1`, and one ⌘Z puts every pasted leaf back (the
///      before/after values are printed, not just the count).
///   ④ **多选**: three selected photos → one paste → one row in *each* photo's own stack.
///   ⑤ **解码**: render-only sections never develop (`RAWDecoder.decodeCounts` +0); a white-balance
///      paste develops exactly once (+1) — counted on the real decoder, not by a stopwatch.
///   ⑥ **焦点**: with a text view owning the keyboard, ⌘C copies *text* (the item validates off and
///      the action forwards to `NSText.copy:`), and the settings clipboard is untouched.
@MainActor
final class CopyPasteSettingsTests: XCTestCase {

    private var workDir: URL!
    private var packageURL: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-copypaste-\\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        packageURL = workDir.appendingPathComponent("CP.\\(LibraryLayout.packageExtension)")
    }

    override func tearDownWithError() throws {
        RAWDecoder.resetDecodeCounts()
        try? FileManager.default.removeItem(at: workDir)
    }

    // MARK: - fixtures

    /// A: the look being carried. Tone only — its balance stays as-shot, which is the case that must
    /// not clobber B's.
    private func documentA() -> EditModel {
        var a = EditModel.neutral
        a.light.exposure = 1.2
        a.light.contrast = 15
        return a
    }

    /// B: everything a paste must leave alone. Pinned Kelvin, own tone, own saturation, own mask.
    private func documentB() -> EditModel {
        var b = EditModel.neutral
        b.light.temperature = 4800
        b.light.tint = 5
        b.light.exposure = -0.4
        b.color.saturation = 30
        b.geometry.crop = NormalizedRect(x: 0.15, y: 0.15, width: 0.7, height: 0.7)
        b.masks = [Mask(id: "B-mask", name: "B", feather: 0.6)]
        return b
    }

    /// A source that **does** pin a balance, for the 选组 case (so the payload can carry one).
    private func documentPinned() -> EditModel {
        var a = documentA()
        a.light.temperature = 5500
        a.light.tint = 10
        a.color.vibrance = 20
        a.geometry.crop = NormalizedRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        a.curve.white = [CurvePoint(0, 0), CurvePoint(1, 1.15), CurvePoint(2, 2)]
        return a
    }

    @discardableResult
    private func insertAsset(_ catalog: Catalog, name: String, edit: EditModel,
                             size: (Int, Int)? = nil) throws -> String {
        let rootDir = workDir.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
        let root = try catalog.ensureRoot(for: rootDir, mode: .reference)
        let blob = try Catalog.encode(edit)
        let asset = Asset(sourceRootId: root.id,
                          relPath: name,
                          filename: name,
                          ext: "dng",
                          kind: .raw,
                          size: 1024, mtime: 0,
                          contentHash: UUID().uuidString,
                          width: size?.0,
                          height: size?.1,
                          developJson: blob)
        try catalog.dbQueue.write { db in
            try asset.insert(db)
            try AssetHistory(assetId: asset.id, seq: 1, developJson: blob,
                             label: "import", createdAt: ISO8601.now()).insert(db)
        }
        return asset.id
    }

    /// A library with A, B, C and D, opened in a session with B as the anchor.
    private func makeSession() throws -> (CatalogSession, Catalog, [String]) {
        let setup = try Catalog.create(at: packageURL)
        let ids = [try insertAsset(setup, name: "A.dng", edit: documentA()),
                   try insertAsset(setup, name: "B.dng", edit: documentB()),
                   try insertAsset(setup, name: "C.dng", edit: documentB()),
                   try insertAsset(setup, name: "D.dng", edit: documentB())]
        let reader = try Catalog.open(at: packageURL)
        let session = CatalogSession()
        try session.open(packageURL)
        XCTAssertEqual(Set(session.assets.map(\.id)), Set(ids), "the library's rows are the fixtures")
        // Make B the anchor: the live document the paste goes through.
        session.selectOnly(ids[1])
        XCTAssertEqual(session.anchorID, ids[1])
        XCTAssertEqual(session.loadedEditAssetID, ids[1])
        return (session, reader, ids)
    }

    private func stored(_ catalog: Catalog, _ id: String) throws -> EditModel {
        try catalog.develop(forAsset: id)
    }

    private func changedKeys(_ before: EditModel, _ after: EditModel) -> Set<String> {
        var out: Set<String> = []
        for change in EditHistory.changedFields(between: before, and: after) {
            out.insert(change.field.key.hasPrefix("curve.") ? "curve.white" : change.field.key)
        }
        return out
    }

    // MARK: - ① 只带非默认字段 (A → B)

    func testCopyFromAAndPasteToBChangesOnlyAsNonDefaultLeaves() throws {
        let (session, catalog, ids) = try makeSession()
        let (a, b) = (ids[0], ids[1])
        let before = try stored(catalog, b)
        let rowsBefore = try catalog.editHistory(forAsset: b).count

        session.selectOnly(a)
        let payload = try XCTUnwrap(session.copySettingsFromAnchor())
        print("COPY  A → payload: \(payload.fieldCount) fields sections="
              + "\(EditSnapshotSection.panelOrder.filter { payload.sections.contains($0) }.map(\.title))"
              + " decode=\(payload.requiresDecode)")
        XCTAssertEqual(payload.fieldCount, 2, "A moved two leaves: exposure and contrast")

        session.selectOnly(b)
        let historyBefore = session.history.count
        let reports = session.pasteSettings()
        XCTAssertEqual(session.history.count, historyBefore + 1, "history.count +1 for the whole paste")
        XCTAssertEqual(reports.count, 1)
        let report = try XCTUnwrap(reports.first)
        print("PASTE A → B: \(report.summary) | changed=\(report.changed) decode=\(report.requiresDecode)")

        let after = try stored(catalog, b)
        // The before/after table, field by field.
        let table = [
            ("exposure",      "\(before.light.exposure)",  "\(after.light.exposure)"),
            ("contrast",      "\(before.light.contrast)",  "\(after.light.contrast)"),
            ("temperature",   "\(String(describing: before.light.temperature))",
                              "\(String(describing: after.light.temperature))"),
            ("tint",          "\(String(describing: before.light.tint))",
                              "\(String(describing: after.light.tint))"),
            ("saturation",    "\(before.color.saturation)", "\(after.color.saturation)"),
            ("crop.width",    "\(before.geometry.crop.width)", "\(after.geometry.crop.width)"),
            ("masks",         "\(before.masks.map(\.id))",  "\(after.masks.map(\.id))"),
        ]
        for (name, b0, b1) in table { print("FIELD  B.\(name): \(b0) → \(b1)") }

        XCTAssertEqual(after.light.exposure, 1.2)
        XCTAssertEqual(after.light.contrast, 15)
        // B's own values, unchanged: the source never carried them.
        XCTAssertEqual(after.light.temperature, 4800)
        XCTAssertEqual(after.light.tint, 5)
        XCTAssertEqual(after.color.saturation, 30)
        XCTAssertEqual(after.geometry.crop, before.geometry.crop)
        XCTAssertEqual(after.masks.map(\.id), ["B-mask"])
        XCTAssertEqual(changedKeys(before, after), ["light.exposure", "light.contrast"])
        XCTAssertFalse(report.requiresDecode, "tone only: no development")

        // ③ one paste = one row.
        XCTAssertEqual(try catalog.editHistory(forAsset: b).count, rowsBefore + 1,
                       "one history row for the whole paste, however many leaves it moved")
        // And the live document is the one that was written (no second truth).
        XCTAssertEqual(session.edit.light.exposure, 1.2)

        // One ⌘Z puts both leaves back — the before values again.
        XCTAssertTrue(session.undo())
        let undone = session.edit
        print("UNDO   B after ⌘Z: exposure=\(undone.light.exposure) contrast=\(undone.light.contrast)"
              + " temperature=\(String(describing: undone.light.temperature))")
        XCTAssertEqual(undone.light.exposure, before.light.exposure)
        XCTAssertEqual(undone.light.contrast, before.light.contrast)
        XCTAssertEqual(undone.light.temperature, 4800)
        XCTAssertEqual(try stored(catalog, b).light.exposure, before.light.exposure,
                       "the undo was persisted, not only shown")
    }

    // MARK: - ② 选组

    func testPastingOnlyExposureAndCurveLeavesBalanceColourCropAndMasksAlone() throws {
        let (session, catalog, ids) = try makeSession()
        let (source, target) = (ids[0], ids[1])
        // A pinned source, so the payload *has* a balance to drop.
        session.selectOnly(source)
        session.applyEdit { $0 = self.documentPinned() }
        XCTAssertTrue(session.commitEdit(label: "source look"))
        let payload = try XCTUnwrap(session.copySettingsFromAnchor())
        XCTAssertTrue(payload.sections.contains(.whiteBalance), "the source does pin a balance")

        let before = try stored(catalog, target)
        session.selectOnly(target)
        let reports = session.pasteSettings(sections: [.light, .curve])
        let report = try XCTUnwrap(reports.first)
        print("SECTION paste [.light,.curve] → B: \(report.summary) sections="
              + "\(EditSnapshotSection.panelOrder.filter { report.sections.contains($0) }.map(\.title))")

        let after = try stored(catalog, target)
        let table = [
            ("exposure",    "\(before.light.exposure)", "\(after.light.exposure)"),
            ("contrast",    "\(before.light.contrast)", "\(after.light.contrast)"),
            ("temperature", "\(String(describing: before.light.temperature))",
                            "\(String(describing: after.light.temperature))"),
            ("tint",        "\(String(describing: before.light.tint))",
                            "\(String(describing: after.light.tint))"),
            ("vibrance",    "\(before.color.vibrance)", "\(after.color.vibrance)"),
            ("saturation",  "\(before.color.saturation)", "\(after.color.saturation)"),
            ("crop",        "\(before.geometry.crop.keyString)", "\(after.geometry.crop.keyString)"),
            ("masks",       "\(before.masks.map(\.id))", "\(after.masks.map(\.id))"),
        ]
        for (name, b0, b1) in table { print("FIELD  B.\(name): \(b0) → \(b1)") }

        XCTAssertEqual(after.light.exposure, 1.2)
        XCTAssertEqual(after.light.contrast, 15)
        XCTAssertEqual(after.light.temperature, 4800)
        XCTAssertEqual(after.light.tint, 5)
        XCTAssertEqual(after.color.vibrance, 0)
        XCTAssertEqual(after.color.saturation, 30)
        XCTAssertEqual(after.geometry.crop, before.geometry.crop)
        XCTAssertEqual(after.masks.map(\.id), ["B-mask"])
        XCTAssertEqual(changedKeys(before, after), ["light.exposure", "light.contrast", "curve.white"],
                       "the source changed vibrance, balance and crop too — they were not checked in")
        XCTAssertFalse(report.requiresDecode)
    }

    // MARK: - ④ 多选粘贴：3 张各一条历史

    func testPastingToStringThreeSelectedPhotosWritesOneRowEach() throws {
        let (session, catalog, ids) = try makeSession()
        let (source, targets) = (ids[0], [ids[1], ids[2], ids[3]])
        session.selectOnly(source)
        _ = session.copySettingsFromAnchor()

        let rowsBefore = try ids.map { try catalog.editHistory(forAsset: $0).count }
        session.setSelection(Set(targets), anchor: targets[0])
        let reports = session.pasteSettings()

        print("MULTI  \(targets.count) selected → \(reports.count) reports: "
              + reports.map { "\($0.assetID.prefix(4)):\($0.summary)" }.joined(separator: " | "))
        XCTAssertEqual(reports.count, 3)
        XCTAssertTrue(reports.allSatisfy(\.changed))
        let rowsAfter = try ids.map { try catalog.editHistory(forAsset: $0).count }
        // The source itself is not a target here, so its stack is untouched; each target got one row.
        XCTAssertEqual(rowsAfter[0], rowsBefore[0], "the source photo was not pasted onto")
        for (i, id) in targets.enumerated() {
            XCTAssertEqual(rowsAfter[i + 1], rowsBefore[i + 1] + 1,
                           "photo \(id.prefix(4)): one paste = one row in its own stack")
            XCTAssertEqual(try stored(catalog, id).light.exposure, 1.2)
            XCTAssertEqual(try stored(catalog, id).light.temperature, 4800,
                           "each target kept its own pinned balance")
        }
        // ⌘Z on the anchor takes back the anchor's paste only — one row, not the batch.
        XCTAssertTrue(session.undo())
        XCTAssertEqual(session.edit.light.exposure, documentB().light.exposure)
        XCTAssertEqual(try stored(catalog, targets[2]).light.exposure, 1.2,
                       "another photo's paste is that photo's row; ⌘Z here does not reach it")
    }

    // MARK: - ⑤ 解码：渲染类 +0，白平衡 +1

    private func fixture() throws -> URL {
        let candidates = [
            ProcessInfo.processInfo.environment["PHOTONS_TEST_RAW"],
            NSString(string: "~/Desktop/test/L1030433.dng").expandingTildeInPath,
        ].compactMap { $0 }
        for c in candidates where FileManager.default.isReadableFile(atPath: c) {
            return URL(fileURLWithPath: c)
        }
        throw XCTSkip("no RAW fixture; set PHOTONS_TEST_RAW")
    }

    private func decodeTotal() -> Int { RAWDecoder.decodeCounts().values.reduce(0, +) }

    func testRenderOnlyPasteNeverDevelopsAndAWhiteBalancePasteDevelopsOnce() throws {
        let url = try fixture()
        let (session, catalog, ids) = try makeSession()
        let target = ids[1]
        let loupe = LoupeController(session: session)
        loupe.autoRenderEnabled = false
        loupe.collectsHistogram = false
        let viewport = ImageSize(width: 400, height: 300)
        let scale: Float = 0.125

        session.selectOnly(ids[0])
        session.applyEdit { $0 = self.documentPinned() }
        XCTAssertTrue(session.commitEdit(label: "source look"))
        _ = session.copySettingsFromAnchor()
        session.selectOnly(target)
        let base = try stored(catalog, target)

        RAWDecoder.resetDecodeCounts()
        _ = try loupe.makeFrame(url: url, viewport: viewport, decodeScale: scale, edit: base)
        let baseline = decodeTotal()
        print("DECODE baseline frame: \(RAWDecoder.decodeCounts())")

        // Render-only: exposure + curve + colour + crop, no balance.
        _ = session.pasteSettings(sections: [.light, .curve, .color, .geometry])
        _ = try loupe.makeFrame(url: url, viewport: viewport, decodeScale: scale, edit: session.edit)
        let afterRender = decodeTotal()
        print("DECODE after render-only paste: \(RAWDecoder.decodeCounts()) (+\(afterRender - baseline))")
        XCTAssertEqual(afterRender, baseline, "a render-only paste must not develop a new buffer")
        XCTAssertEqual(session.edit.light.exposure, 1.2)

        // The same document again: still nothing (the key, not the clock).
        _ = try loupe.makeFrame(url: url, viewport: viewport, decodeScale: scale, edit: session.edit)
        XCTAssertEqual(decodeTotal(), baseline)

        // White balance: one new development, because `CIRAWFilter.neutralTemperature` is part of the
        // buffer. Different rung scale than the baseline? No — same scale, new wb=… component.
        _ = session.pasteSettings(sections: [.whiteBalance])
        XCTAssertEqual(session.edit.light.temperature, 5500)
        _ = try loupe.makeFrame(url: url, viewport: viewport, decodeScale: scale, edit: session.edit)
        let afterWB = decodeTotal()
        print("DECODE after white-balance paste: \(RAWDecoder.decodeCounts()) (+\(afterWB - baseline))")
        XCTAssertEqual(afterWB, baseline + 1,
                       "a Kelvin paste re-develops exactly once: \(RAWDecoder.decodeCounts())")
    }

    // MARK: - ⑥ 焦点在文本域时 ⌘C 不被劫持

    func testCommandCCopiesTextWhenATextViewOwnsTheKeyboard() throws {
        // A library, then the controller's **own** session opens it: the window controller is what the
        // menu dispatches to, so the assertion has to be about the session it actually edits.
        let setup = try Catalog.create(at: packageURL)
        let ids = [try insertAsset(setup, name: "A.dng", edit: documentA()),
                   try insertAsset(setup, name: "B.dng", edit: documentB())]
        let controller = EditorWindowController(size: NSSize(width: 900, height: 600))
        let session = controller.session
        try session.open(packageURL)
        session.selectOnly(ids[0])
        XCTAssertEqual(session.copiedSettings, nil)

        let window = try XCTUnwrap(controller.window)
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        textView.string = "标题文字"
        textView.isEditable = true
        window.contentView?.addSubview(textView)
        XCTAssertTrue(window.makeFirstResponder(textView))
        textView.setSelectedRange(NSRange(location: 0, length: 4))
        XCTAssertTrue(controller.isTextEditing)
        NSPasteboard.general.clearContents()

        let item = NSMenuItem(title: "复制设置",
                              action: #selector(EditorWindowController.copySettingsAction(_:)),
                              keyEquivalent: "c")
        XCTAssertFalse(controller.validateMenuItem(item), "⌘C is the text field's while it is being edited")

        // The action itself hands the event back to `NSText` instead of capturing settings.
        controller.copySettingsAction(nil)
        XCTAssertNil(session.copiedSettings, "the settings clipboard stayed empty")
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "标题文字",
                       "⌘C copied the selection in the text view")

        // Outside the text field the same action captures the settings.
        XCTAssertTrue(window.makeFirstResponder(controller.rootView))
        XCTAssertFalse(controller.isTextEditing)
        XCTAssertTrue(controller.validateMenuItem(item))
        // 081 §1: ⌘C asks **before** it copies, so the sheet is what the action opens. The modal is a
        // closure (`presentCopySheet`), so this test answers it the way a click on 复制 would.
        var asked: [(CopySettingsAccessoryView.Purpose, CopySettingsSelection)] = []
        controller.presentCopySheet = { purpose, selection in
            asked.append((purpose, selection))
            return .confirm(selection)
        }
        controller.copySettingsAction(nil)
        XCTAssertEqual(asked.count, 1, "⌘C opened the card sheet exactly once")
        XCTAssertEqual(asked.first?.0, .copy)
        XCTAssertEqual(session.copiedSettings?.fieldCount, 2)
        // Cancelling the sheet copies nothing (the 反证 of 「⌘C 直接复制」: it now depends on the answer).
        controller.presentCopySheet = { _, _ in nil }
        controller.copySettingsAction(nil)
        XCTAssertEqual(session.copiedSettings?.fieldCount, 2, "a cancelled sheet leaves the clipboard as it was")
    }

    // MARK: - 选组对话框的三个答案

    func testTheChecklistDialogDrivesTheSharedModel() {
        let view = CopySettingsAccessoryView(selection: .all, purpose: .copy)
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.selection.sections, Set(EditSnapshotSection.copyable))
        XCTAssertEqual(view.statusLabel.stringValue,
                       "将复制：白平衡 · 黑电平 · Light · Color · 黑白 · HSL · 色彩分级 · 细节 · 曲线 · 效果 · 裁切 · 蒙版")
        XCTAssertEqual(view.presetPopUp.indexOfSelectedItem, 1, "全部 is the first preset row")

        // 全不选 / 全选 buttons.
        view.selectNoneButton.performClick(nil)
        XCTAssertTrue(view.selection.isEmpty)
        XCTAssertEqual(view.checkboxes.values.filter { $0.state == .on }.count, 0)
        XCTAssertEqual(view.statusLabel.stringValue, "未选任何组：粘贴什么也不会发生")

        view.selectAllButton.performClick(nil)
        XCTAssertEqual(view.selection.sections, Set(EditSnapshotSection.copyable))

        // A 预设组合 from the popup.
        let basicIndex = CopySettingsAccessoryView.popUpIndex(of: .basic)
        view.presetPopUp.selectItem(at: basicIndex)
        view.presetPopUp.sendAction(view.presetPopUp.action, to: view.presetPopUp.target)
        XCTAssertEqual(view.selection.sections, [.whiteBalance, .blackLevel, .light, .curve])
        XCTAssertEqual(view.checkboxes[.curve]?.state, .on)
        XCTAssertEqual(view.checkboxes[.color]?.state, .off)

        // 蒙版 is a selectable row since P1-5, with a tooltip that says what a mask copy does.
        let masks = view.checkboxes[.masks]
        XCTAssertEqual(masks?.isEnabled, true, "the 蒙版 row is no longer greyed out")
        XCTAssertEqual(masks?.title, "蒙版", "no 「（暂不支持）」 suffix any more")
        XCTAssertEqual(masks?.toolTip?.isEmpty, false, "the row still explains what it does")
        view.click(.masks)
        XCTAssertTrue(view.selection.contains(.masks), "a click checks it in")
        XCTAssertEqual(view.presetPopUp.indexOfSelectedItem, 0, "全部 + 自定义… is 自定义")
        view.click(.masks)
        XCTAssertFalse(view.selection.contains(.masks))

        // Any hand-made combination reads 自定义 (index 0), not the nearest preset.
        view.click(.color)
        XCTAssertEqual(view.presetPopUp.indexOfSelectedItem, 0)
    }

    // MARK: - ⑦ P1-5: 蒙版 through the shipped path (⌘C → ⌘V → ⌘Z)

    /// A(2 masks) → B(1 mask), pasted through `CatalogSession` with the aspect ratios the catalog
    /// rows carry: **three** masks in the live document, ids all distinct, A's circle re-anchored on
    /// the short edge, **one** history row, and one ⌘Z puts the list back to one.
    func testCopyingMasksFromAAndPastingToBAppendsThemAsOneUndoStep() throws {
        let setup = try Catalog.create(at: packageURL)
        var a = documentA()
        a.masks = [
            Mask(id: "m-a1", name: "天空", feather: 0.2, components: [
                MaskComponent(id: "c-a1", shape: .radialGradient(
                    RadialGradientShape(center: NormalizedPoint(0.25, 0.75),
                                        radius: NormalizedPoint(0.2, 0.2)))),
            ]),
            Mask(id: "m-a2", name: "地面", feather: 0.1),
        ]
        // 4:3 for A, 3:2 for B — the rows carry the pixel size the app reads at import.
        let sourceID = try insertAsset(setup, name: "MA.dng", edit: a, size: (4032, 3024))
        let targetID = try insertAsset(setup, name: "MB.dng", edit: documentB(), size: (6000, 4000))

        let session = CatalogSession()
        try session.open(packageURL)
        XCTAssertEqual(session.frameAspect(of: targetID) ?? 0, 1.5, accuracy: 1e-12)
        XCTAssertEqual(session.frameAspect(of: sourceID) ?? 0, 4.0 / 3.0, accuracy: 1e-12)

        session.selectOnly(sourceID)
        let payload = try XCTUnwrap(session.copySettingsFromAnchor(selection: .init(sections: [.masks])))
        print("UI     payload: masks=\(payload.maskCount) fields=\(payload.fieldCount)"
              + " aspect=\(String(describing: payload.masks?.frameAspect))")
        XCTAssertEqual(payload.maskCount, 2)
        XCTAssertEqual(payload.fieldCount, 0, "只勾蒙版: a tone leaf is not in the payload")
        XCTAssertEqual(payload.masks?.frameAspect ?? 0, 4.0 / 3.0, accuracy: 1e-12)

        session.selectOnly(targetID)
        let before = session.edit
        let rowsBefore = session.history.count
        let reports = session.pasteSettings()
        let report = try XCTUnwrap(reports.first)
        print("UI     paste → \(report.summary.prefix(80)) changed=\(report.changed)")

        XCTAssertEqual(session.history.count, rowsBefore + 1, "one paste = one history row")
        XCTAssertEqual(session.edit.masks.count, 3, "1 of B's own + 2 carried")
        let ids = session.edit.masks.map(\.id)
        XCTAssertEqual(Set(ids).count, 3, "ids unique in the live document; got \(ids)")
        XCTAssertEqual(ids.first, "B-mask")
        XCTAssertEqual(session.edit.light, before.light, "只粘蒙版: B's exposure is B's")
        XCTAssertEqual(session.edit.color, before.color)
        XCTAssertEqual(session.edit.curve, before.curve)
        XCTAssertEqual(session.edit.geometry, before.geometry)
        XCTAssertEqual(session.edit.masks[1].components.first?.shape,
                       .radialGradient(RadialGradientShape(center: NormalizedPoint(0.5 + (0.25 - 0.5) * (8.0 / 9.0), 0.75),
                                                           radius: NormalizedPoint(0.2, 0.2))),
                       "4:3 → 3:2 through the session: the circle is re-anchored, not moved blindly")

        // One ⌘Z: the whole paste, masks included — and it reaches the store, not just the screen.
        XCTAssertTrue(session.undo())
        print("UI     after ⌘Z: \(session.edit.masks.map(\.id))"
              + " stored=\(try stored(setup, targetID).masks.count)")
        XCTAssertEqual(session.edit.masks.map(\.id), before.masks.map(\.id))
        XCTAssertEqual(try stored(setup, targetID).masks.map(\.id), before.masks.map(\.id),
                       "one ⌘Z takes the whole paste back, in the document and on disk")
    }
}
