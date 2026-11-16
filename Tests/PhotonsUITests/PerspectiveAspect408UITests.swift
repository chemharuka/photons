import XCTest
import AppKit
import SwiftUI
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// **408 — 校正卡里的「宽高比」一行，以及它的「自动」按钮。**
///
/// The core-side claims (the matrix, the canvas, the formula) live in
/// `PhotonsCoreTests/PerspectiveAspect408Tests`. This file is the panel's half — the things the user
/// actually touches:
///
/// | case | what it proves |
/// |---|---|
/// | ① | the row exists, sits in 校正's 透视 section after 切变, and reads `100%` at rest |
/// | ② | the readout is a real `NumberTextField` whose range is `50…200` — the travel the core clamps |
/// | ③ | typing writes the **document** (`perspectiveAspect`), one row, and 100% is the reset |
/// | ④ | 自动 writes `PerspectiveMap.compensatingAspect`, one history row, and ⌘Z puts it back |
/// | ⑤ | 自动 is disabled when there is nothing to correct (no keystone / already square) |
///
/// 408 §6.4.4: 「该按钮必须可撤销（进历史），且不许一次点就把用户手调的值覆盖掉而无提示」 — ④/⑤
/// hold that: the write goes through `applyEdit` + `commitEdit`, so it is one undoable step, and the
/// button is inert where it would be a no-op or an invention.
@MainActor
final class PerspectiveAspect408UITests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-408-aspect-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    // MARK: - ① the row

    func testTheCorrectionCardDrawsTheAspectRowAfterTheShear() throws {
        let (panel, loupe) = try transformPanel(width: 330)
        defer { panel.window.contentView = nil }
        XCTAssertTrue(loupe.isCropToolActive || loupe.beginCropTool(), "408: 进变换就该在裁切模式")

        // The row is the 透视 section's fifth and last row, and its name is 宽高比校正 — never the
        // crop card's own 宽高比 (that one is `AspectLock`, `;asp=`), and never a bare 比例.
        XCTAssertEqual(CorrectionCardRow.allCases.last, .perspectiveAspect)
        XCTAssertEqual(CorrectionCardRow.perspectiveAspect.title, "宽高比校正")
        XCTAssertNotEqual(CorrectionCardRow.perspectiveAspect.title, CropSection.crop.title,
                          "「宽高比校正」与裁切卡的「宽高比」必须分得开")
        XCTAssertNotEqual(CorrectionCardRow.perspectiveAspect.title,
                          CropSection.crop.title.replacingOccurrences(of: "宽高比", with: "比例"),
                          "408: 也不许与裁切的「比例锁定」同字")
        XCTAssertTrue(CropSection.perspective.fields.contains(.perspectiveAspect),
                      "408: 宽高比属于透视 section（它的复位要一起带走）")

        let correction = try XCTUnwrap(panel.row(CropCardID.correctionCard), "校正卡没有 frame")
        let shear = try XCTUnwrap(panel.row(CorrectionCardRow.perspectiveShear.probeID))
        let aspect = try XCTUnwrap(panel.row(CorrectionCardRow.perspectiveAspect.probeID),
                                   "408: 「宽高比」行没有画出来")
        XCTAssertTrue(correction.contains(CGPoint(x: aspect.midX, y: aspect.midY)),
                      "408: 宽高比行必须在校正卡里")
        XCTAssertGreaterThan(aspect.minY, shear.minY, "408: 宽高比在切变下面")
        XCTAssertGreaterThan(aspect.width, 60)

        // The resting readout is 100 % — the row's own number, not a bare 1.
        let field = try XCTUnwrap(panel.view(NumberTextField.self,
                                             identifier: "inspector.crop.perspective.aspect"),
                                  "408: 宽高比的读数没有画出来")
        XCTAssertEqual(field.stringValue, "100%", "408: 静止读数必须是 100%")
        let auto = try XCTUnwrap(panel.view(PerspectiveAspectAutoButton.self,
                                            identifier: PerspectiveAspectAutoButton.identifierID),
                                 "408: 「自动」按钮没有画出来")
        XCTAssertEqual(auto.title, "自动")
        XCTAssertFalse(auto.isEnabled, "408: 还没有透视时「自动」无事可做，必须禁用")
        print("408 ① 宽高比行 \(NSStringFromRect(aspect)) · 读数 \(field.stringValue) · 自动 \(auto.isEnabled)")
    }

    // MARK: - ② the travel

    func testTheAspectReadoutTravelsFromFiftyToTwoHundredPercent() throws {
        let (panel, _) = try transformPanel(width: 330)
        defer { panel.window.contentView = nil }
        let field = try XCTUnwrap(panel.view(NumberTextField.self,
                                             identifier: "inspector.crop.perspective.aspect"))
        let row = try XCTUnwrap(field.controller?.row, "408: 读数没有控制器")
        print("408 ② 行程 \(row.range) · 格式 \(row.format) · 静止 \(row.restingText)")
        XCTAssertEqual(row.range, 50 ... 200, "408: a ∈ [0.5, 2.0] 就是 50%…200%")
        XCTAssertEqual(row.range.upperBound, PerspectiveMap.aspectLimit * 100, "滑杆与夹取是同一个数")
        XCTAssertEqual(row.range.lowerBound, 100 / PerspectiveMap.aspectLimit)
        XCTAssertEqual(row.format, "%.0f%%")
        XCTAssertEqual(row.restingText, "100%")
    }

    // MARK: - ③ typing writes the document

    func testTypingAPercentageWritesTheDocumentAndOneHundredIsTheReset() throws {
        let (panel, _) = try transformPanel(width: 330)
        defer { panel.window.contentView = nil }
        let session = try XCTUnwrap(panel.session)
        TestWindows.show(panel.window, key: true)

        let field = try XCTUnwrap(panel.view(NumberTextField.self,
                                             identifier: "inspector.crop.perspective.aspect"))
        let before = session.history.count
        XCTAssertTrue(panel.window.makeFirstResponder(field), "408: 读数必须能成为第一响应者")
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView, "408: 没有 field editor")
        editor.insertText("105", replacementRange: editor.selectedRange())
        field.controller?.commit()

        print("408 ③ 键入 105 → 文档 a \(session.edit.geometry.perspectiveAspect) · 读数「\(field.stringValue)」"
              + " · 历史 \(before)→\(session.history.count)")
        XCTAssertEqual(session.edit.geometry.perspectiveAspect, 1.05, accuracy: 1e-12,
                       "408: 105% 必须落进文档")
        XCTAssertEqual(field.stringValue, "105%")
        XCTAssertTrue(session.edit.keyMaterial(.geometry).contains(";asp2=1050"),
                      "408: 键里必须有千分之一的 a：\(session.edit.keyMaterial(.geometry))")
        XCTAssertEqual(session.history.count, before + 1, "408: 一次键入 = 一条历史")

        // 双击标签 = 100 %，不是 0 —— and it is one command, not a drag.
        let resets = PanelResets(session: session)
        let rows = session.history.count
        XCTAssertTrue(resets.reset(fields: CropSection.perspective.fields, label: "透视"))
        XCTAssertEqual(session.edit.geometry.perspectiveAspect, 1, accuracy: 1e-12,
                       "408: 透视复位必须把宽高比带回 1.0（不是 0）")
        XCTAssertEqual(session.history.count, rows + 1)
        XCTAssertFalse(resets.reset(fields: CropSection.perspective.fields, label: "透视"),
                       "408: 已经 100% 了，空复位不许写历史")
    }

    // MARK: - ④ 自动

    func testTheAutoButtonWritesTheCompensatingAspectInOneUndoableRow() throws {
        let (panel, _) = try transformPanel(width: 330)
        defer { panel.window.contentView = nil }
        let session = try XCTUnwrap(panel.session)
        TestWindows.show(panel.window, key: true)

        // A real keystone: v = 100, the fixture every number in 408 §6.1 is stated on.
        session.applyEdit { $0.geometry.perspectiveVertical = 100 }
        XCTAssertTrue(session.commitEdit(label: "透视", coalesce: false))
        _ = waitFor(panel) { $0.view(PerspectiveAspectAutoButton.self,
                                     identifier: PerspectiveAspectAutoButton.identifierID)?.isEnabled == true }

        let auto = try XCTUnwrap(panel.view(PerspectiveAspectAutoButton.self,
                                            identifier: PerspectiveAspectAutoButton.identifierID))
        XCTAssertTrue(auto.isEnabled, "408: 有透视时「自动」必须有东西可做")

        let map = try XCTUnwrap(session.edit.geometry.perspective)
        let expected = try XCTUnwrap(map.compensatingAspect)
        let before = session.history.count
        let aBefore = session.edit.geometry.perspectiveAspect

        auto.performClick(nil)
        CropUITestSupport.pump(0.1)

        print(String(format: "408 ④ 自动：(v 100, a %.6f) → a %.6f · 历史 %d→%d",
                     aBefore, session.edit.geometry.perspectiveAspect, before, session.history.count))
        XCTAssertEqual(session.edit.geometry.perspectiveAspect, expected, accuracy: 1e-12,
                       "408: 自动写的必须是 compensatingAspect")
        XCTAssertEqual(expected, 1.11731843575419, accuracy: 1e-6,
                       "408 §6.1 的 v = 100 数字（1.1173，不是 1/1.2346）")
        XCTAssertEqual(session.history.count, before + 1, "408: 自动 = 一条历史")

        // The corrected canvas is square — the physical claim of the button.
        let corrected = try XCTUnwrap(session.edit.geometry.perspective)
        let rect = corrected.inscribedRect()
        XCTAssertEqual(rect.width, rect.height, accuracy: 1e-12,
                       "408: 自动之后画布必须恢复正方形")

        // …and it is undoable in one press: the user's own number comes back.
        XCTAssertTrue(session.undo())
        XCTAssertEqual(session.edit.geometry.perspectiveAspect, aBefore, accuracy: 1e-12,
                       "408: ⌘Z 一次就把宽高比放回去")
    }

    // MARK: - ⑤ disabled when there is nothing to correct

    func testTheAutoButtonIsInertWithoutAKeystoneOrWhenAlreadyCorrected() throws {
        let (panel, _) = try transformPanel(width: 330)
        defer { panel.window.contentView = nil }
        let session = try XCTUnwrap(panel.session)
        TestWindows.show(panel.window, key: true)

        let auto = try XCTUnwrap(panel.view(PerspectiveAspectAutoButton.self,
                                            identifier: PerspectiveAspectAutoButton.identifierID))
        XCTAssertFalse(auto.isEnabled, "408: 没有透视就没有要修的比例")

        // A bare shear is not a keystone: 自动 must stay inert (no canvas stretch to correct).
        session.applyEdit { $0.geometry.perspectiveShear = 0.1 }
        XCTAssertTrue(session.commitEdit(label: "透视", coalesce: false))
        CropUITestSupport.pump(0.1)
        XCTAssertFalse(auto.isEnabled, "408: 只有切变时「自动」不许出现")

        // With a keystone it lights up; once the canvas is already square it goes out again.
        session.applyEdit { $0.geometry.perspectiveVertical = 100 }
        XCTAssertTrue(session.commitEdit(label: "透视", coalesce: false))
        _ = waitFor(panel) { $0.view(PerspectiveAspectAutoButton.self,
                                     identifier: PerspectiveAspectAutoButton.identifierID)?.isEnabled == true }
        let a = try XCTUnwrap(session.edit.geometry.perspective?.compensatingAspect)
        session.applyEdit { $0.geometry.perspectiveAspect = a }
        XCTAssertTrue(session.commitEdit(label: "透视", coalesce: false))
        _ = waitFor(panel) { $0.view(PerspectiveAspectAutoButton.self,
                                     identifier: PerspectiveAspectAutoButton.identifierID)?.isEnabled == false }
        XCTAssertFalse(auto.isEnabled, "408: 已经是自动值时按钮必须禁用（不给空写）")
    }

    // MARK: - harness (334/337's, trimmed)

    private struct Panel {
        let host: NSHostingView<InspectorView>
        let window: NSWindow
        let state: InspectorWorkspaceState
        var session: CatalogSession?

        var cards: InspectorCardsProbe {
            views(ofType: InspectorCardsProbe.self).first ?? InspectorCardsProbe(frame: .zero)
        }

        var probes: [CropRowProbe] { views(ofType: CropRowProbe.self) }

        func row(_ id: String) -> CGRect? {
            probes.first { $0.rowID == id }.map { $0.convert($0.bounds, to: host) }
        }

        func view<T: NSView>(_ type: T.Type, identifier: String) -> T? {
            views(ofType: type).first { $0.accessibilityIdentifier() == identifier }
        }

        func views<T: NSView>(ofType: T.Type) -> [T] {
            var found: [T] = []
            func walk(_ root: NSView) {
                if let match = root as? T { found.append(match) }
                for sub in root.subviews { walk(sub) }
            }
            walk(host)
            return found
        }
    }

    private func transformPanel(width: CGFloat) throws -> (Panel, LoupeController) {
        let (session, _) = try CropUITestSupport.makeSession(in: workDir)
        let loupe = LoupeController(session: session)
        loupe.autoRenderEnabled = false
        loupe.collectsHistogram = false
        _ = loupe.view

        _ = NSApplication.shared
        let state = InspectorWorkspaceState()
        let host = NSHostingView(rootView: InspectorView(session: session, loupe: loupe,
                                                         workspaces: state))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 900)
        let window = TestWindows.make(contentRect: host.frame, styleMask: [.borderless],
                                      backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        CropUITestSupport.pump(0.4)
        host.layoutSubtreeIfNeeded()
        state.select(.transform)
        let panel = Panel(host: host, window: window, state: state, session: session)
        _ = waitFor(panel) { $0.cards.cardIDs == ["crop", "transformCorrection", "angle"] }
        _ = waitFor(panel) { $0.row(CorrectionCardRow.perspectiveAspect.probeID) != nil }
        return (panel, loupe)
    }

    @discardableResult
    private func waitFor(_ panel: Panel, _ predicate: (Panel) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if predicate(panel) { return true }
            CropUITestSupport.pump(0.05)
        }
        return predicate(panel)
    }
}
