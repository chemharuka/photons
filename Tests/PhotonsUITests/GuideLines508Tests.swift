import XCTest
import AppKit
import CryptoKit
import SwiftUI
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// **508 — 双击「引导线」三个字：清空所有引导线，并把透视校正（垂直/水平）归零。**
///
/// 用户口径（508 §0）:
/// > 双击右边卡片中的「引导线」三个字后，清除所有引导线并恢复透视校正为0
///
/// 这一套只量三件事，而且每一件都是**四个字段**（线数 / v / h + 保持不动的 shear / aspect）:
///
///   ① 有 2 条线 + v=+30 / h=−20 ⇒ 双击后 线 0 条、v=0、h=0、**切变与宽高比逐位不变**、历史 +1（一条）；
///     ⌘Z 一次四字段全回来、⇧⌘Z 一次回去；
///   ② 幂等：本来没线且透视已 0 ⇒ 返回 false、不铸行、文档字节与 SHA 都不变；
///   ③ 有草稿：草稿与文档**两个读数**都归零，「应用」写出的文档透视也是 0；
///   ④ UI 级：向标题 `Text` 的坐标发一次**真实**双击 ⇒ 与直调动作逐位相同；单击标题**不触发**（反向门 ①）。
///
/// 另外守住 354 的两条老语义：垃圾桶按钮仍**只**清线（keystone 不动），它的历史 label 仍是「引导线」。
@MainActor
final class GuideLines508Tests: XCTestCase {

    private var workDir: URL!
    private var toolCount = 0

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-508-guides-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    // MARK: - the four fields, as one readable value

    /// 四个字段 + 线数。打印与断言都用它，这样「哪一位动了」一眼看得见。
    private struct State: Equatable {
        var lines: Int
        var v: Double
        var h: Double
        var shear: Double
        var aspect: Double

        var line: String {
            String(format: "线 %d · v %+.3f · h %+.3f · 切变 %.6f · 宽高比 %.6f",
                   lines, v, h, shear, aspect)
        }

        init(_ geometric: GeometryGroup, lines: Int) {
            self.lines = lines
            v = geometric.perspectiveVertical
            h = geometric.perspectiveHorizontal
            shear = geometric.perspectiveShear
            aspect = geometric.perspectiveAspect
        }
    }

    // MARK: - harness

    /// Two vertical guide lines in normalized source coordinates — 30 % / 70 % across, both ends
    /// inside the frame. Ordinary lines: the fit has nothing to solve here, they are only the state
    /// 508's gesture has to delete.
    private static var storedLines: [StoredGuideLine] {
        [StoredGuideLine(ax: 0.30, ay: 0.10, bx: 0.30, by: 0.90, vertical: true),
         StoredGuideLine(ax: 0.70, ay: 0.12, bx: 0.70, by: 0.88, vertical: true)]
    }

    /// A document with `perspective` (and 切变 / 宽高比, so "they did not move" has something to keep),
    /// `lines` lines, and — when `begin` — the crop tool open on it.
    ///
    /// The four numbers are written **before** `begin()`: that is the state the user double-clicks in,
    /// and for the draft test it is also what `begin()` seeds the draft with (30 → the draft's copy).
    private func makeTool(perspective: (vertical: Double, horizontal: Double) = (30, -20),
                          lines: Int = 2,
                          shear: Double = 0.07,
                          aspect: Double = 1.12,
                          begin: Bool = true) throws -> (CatalogSession, CropToolController) {
        toolCount += 1
        let directory = workDir.appendingPathComponent("tool-\(toolCount)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let (session, _) = try CropUITestSupport.makeSession(in: directory,
                                                             width: 1200, height: 1200)
        session.applyEdit {
            $0.geometry.perspectiveVertical = perspective.vertical
            $0.geometry.perspectiveHorizontal = perspective.horizontal
            $0.geometry.perspectiveShear = shear
            $0.geometry.perspectiveAspect = aspect
            $0.geometry.guideLines = lines == 0 ? [] : Self.storedLines
        }
        _ = session.commitEdit(label: "透视", coalesce: false)
        let tool = CropToolController(session: session)
        if begin {
            XCTAssertTrue(tool.begin(), "508: 进裁切模式")
            XCTAssertEqual(tool.guideLines.count, lines, "508: begin() 应该把文档里的线取回来")
        }
        return (session, tool)
    }

    private func state(_ session: CatalogSession, lines: Int) -> State {
        State(session.edit.geometry, lines: lines)
    }

    // MARK: - ① 2 条线 + v=+30/h=−20 → 线 0、v 0、h 0、shear/aspect 逐位相同、一条历史

    func testDoubleClickClearsEveryLineAndBothKeystonesInOneRow() throws {
        let (session, tool) = try makeTool()
        let before = state(session, lines: tool.guideLines.count)
        XCTAssertEqual(before.lines, 2, "508 ① 起手两条线")
        XCTAssertEqual(before.v, 30, accuracy: 1e-12)
        XCTAssertEqual(before.h, -20, accuracy: 1e-12)
        let rows = session.history.snapshots.count

        XCTAssertTrue(tool.clearGuideLinesAndResetPerspective(), "508 ① 有东西可清 ⇒ true")
        let after = state(session, lines: tool.guideLines.count)
        print("508 ① 双击: \(before.line) → \(after.line) · 历史 +\(session.history.snapshots.count - rows)")

        XCTAssertEqual(after.lines, 0, "508 ① 线全清")
        XCTAssertEqual(after.v, 0, accuracy: 1e-12, "508 ① 垂直透视归零")
        XCTAssertEqual(after.h, 0, accuracy: 1e-12, "508 ① 水平透视归零")
        XCTAssertEqual(after.shear.bitPattern, before.shear.bitPattern,
                       "508 ① 切变必须逐位不变（那是另外一行的事）")
        XCTAssertEqual(after.aspect.bitPattern, before.aspect.bitPattern,
                       "508 ① 宽高比校正必须逐位不变（它的恒等值是 1，不是 0）")
        XCTAssertEqual(session.history.snapshots.count, rows + 1, "508 ① 一条历史")
        XCTAssertEqual(session.history.snapshots.last?.label, "清除引导线与透视",
                       "508 ① 历史 label")
        XCTAssertEqual(session.edit.geometry.guideLines.count, 0, "508 ① 文档里的线也没了")

        // ⌘Z 一次：线 **与** 两个透视一起回来（四个字段都断言）。
        XCTAssertTrue(session.undo(), "508 ① ⌘Z 可用")
        let undone = state(session, lines: session.edit.geometry.guideLines.count)
        print("508 ① ⌘Z: \(undone.line)")
        XCTAssertEqual(undone.lines, 2, "508 ① ⌘Z 把两条线带回来")
        XCTAssertEqual(undone.v, before.v, accuracy: 1e-12, "508 ① ⌘Z 垂直回来")
        XCTAssertEqual(undone.h, before.h, accuracy: 1e-12, "508 ① ⌘Z 水平回来")
        XCTAssertEqual(undone.shear.bitPattern, before.shear.bitPattern)
        XCTAssertEqual(undone.aspect.bitPattern, before.aspect.bitPattern)

        // 重做回去。
        XCTAssertTrue(session.redo(), "508 ① ⇧⌘Z 可用")
        let redone = state(session, lines: session.edit.geometry.guideLines.count)
        XCTAssertEqual(redone.lines, 0)
        XCTAssertEqual(redone.v, 0, accuracy: 1e-12)
        XCTAssertEqual(redone.h, 0, accuracy: 1e-12)
        XCTAssertEqual(redone.shear.bitPattern, before.shear.bitPattern)
        XCTAssertEqual(redone.aspect.bitPattern, before.aspect.bitPattern)
    }

    // MARK: - ② 幂等：没线 + 透视已 0 ⇒ false，不铸行，字节不变

    func testWithNoLinesAndNoPerspectiveItWritesNothing() throws {
        let (session, tool) = try makeTool(perspective: (0, 0), lines: 0)
        let bytes = CropUITestSupport.documentBytes(session)
        let sha = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let rows = session.history.snapshots.count
        let before = state(session, lines: tool.guideLines.count)

        XCTAssertFalse(tool.clearGuideLinesAndResetPerspective(),
                       "508 ② 已经什么都没了 ⇒ false")
        let after = state(session, lines: tool.guideLines.count)
        let afterBytes = CropUITestSupport.documentBytes(session)
        let afterSHA = SHA256.hash(data: afterBytes).map { String(format: "%02x", $0) }.joined()
        print("508 ② 幂等: \(before.line) → \(after.line) · 历史 +\(session.history.snapshots.count - rows)"
              + " · SHA \(sha.prefix(12))… → \(afterSHA.prefix(12))…")

        XCTAssertEqual(session.history.snapshots.count, rows, "508 ② 不铸历史行")
        XCTAssertEqual(afterBytes, bytes, "508 ② 一个字节都不写")
        XCTAssertEqual(afterSHA, sha, "508 ② 文档 SHA 不变")
        XCTAssertEqual(after, before, "508 ② 四个字段原样")
    }

    // MARK: - ③ 有草稿：草稿与文档都归零

    func testWithACropDraftOpenBothTheDraftAndTheDocumentEndAtZero() throws {
        let (session, tool) = try makeTool()
        let draftBefore = State(tool.draft.geometry(flipsOf: session.edit.geometry),
                                lines: tool.draft.guideLines.count)
        print("508 ③ 双击前: 草稿 \(draftBefore.line) · 文档 \(state(session, lines: tool.guideLines.count).line)")
        XCTAssertEqual(tool.draft.perspectiveVertical, 30, accuracy: 1e-12,
                       "508 ③ 草稿是 begin() 从文档种的 +30")

        XCTAssertTrue(tool.clearGuideLinesAndResetPerspective())

        // 两个读数：草稿自己的副本，与文档。
        let draftAfter = State(tool.draft.geometry(flipsOf: session.edit.geometry),
                               lines: tool.draft.guideLines.count)
        let documentAfter = state(session, lines: tool.guideLines.count)
        print("508 ③ 双击后: 草稿 \(draftAfter.line) · 文档 \(documentAfter.line)")

        XCTAssertEqual(draftAfter.v, 0, accuracy: 1e-12, "508 ③ 草稿的垂直归零")
        XCTAssertEqual(draftAfter.h, 0, accuracy: 1e-12, "508 ③ 草稿的水平归零")
        XCTAssertEqual(draftAfter.lines, 0, "508 ③ 草稿里的线也没了")
        XCTAssertEqual(draftAfter.shear.bitPattern, draftBefore.shear.bitPattern,
                       "508 ③ 草稿的切变不动")
        XCTAssertEqual(draftAfter.aspect.bitPattern, draftBefore.aspect.bitPattern,
                       "508 ③ 草稿的宽高比不动")
        XCTAssertEqual(documentAfter.v, 0, accuracy: 1e-12)
        XCTAssertEqual(documentAfter.h, 0, accuracy: 1e-12)

        // 「应用」写出的文档透视也是 0（草稿若留着旧值就会写回去）。
        XCTAssertTrue(tool.apply(), "508 ③ 应用")
        let applied = state(session, lines: session.edit.geometry.guideLines.count)
        print("508 ③ 应用后: 文档 \(applied.line)")
        XCTAssertEqual(applied.v, 0, accuracy: 1e-12, "508 ③ 应用不会把旧透视写回文档")
        XCTAssertEqual(applied.h, 0, accuracy: 1e-12)
        XCTAssertEqual(applied.lines, 0)
        XCTAssertEqual(applied.shear.bitPattern, draftBefore.shear.bitPattern)
        XCTAssertEqual(applied.aspect.bitPattern, draftBefore.aspect.bitPattern)
    }

    // MARK: - 354 的垃圾桶：语义不变（只清线，keystone 不动）

    func testTheTrashButtonStillClearsOnlyTheLines() throws {
        let (session, tool) = try makeTool()
        let rows = session.history.snapshots.count
        XCTAssertTrue(tool.clearGuideLines())
        XCTAssertEqual(tool.guideLines.count, 0)
        XCTAssertEqual(session.edit.geometry.perspectiveVertical, 30, accuracy: 1e-12,
                       "508 §4 垃圾桶不动透视")
        XCTAssertEqual(session.edit.geometry.perspectiveHorizontal, -20, accuracy: 1e-12)
        XCTAssertEqual(session.history.snapshots.count, rows + 1)
        XCTAssertEqual(session.history.snapshots.last?.label, "引导线", "354 的 label 不变")
    }

    // MARK: - ④ UI 级：标题上的真实双击 == 直调动作；单击不触发

    func testARealDoubleClickOnTheTitleMatchesTheDirectActionAndASingleClickDoesNothing() throws {
        let (session, loupe, panel) = try transformPanel(width: 330)
        defer { panel.window.contentView = nil }
        XCTAssertTrue(loupe.isCropToolActive || loupe.beginCropTool())
        CropUITestSupport.pump(0.1)

        let tool = loupe.cropTool
        let title = try XCTUnwrap(panel.row(CorrectionCardRow.guideLines.titleID),
                                  "508 ④ 标题「引导线」的探针不在树上")
        XCTAssertEqual(CorrectionCardRow.guideLines.titleID, "inspector.crop.guideLines.title")
        print("508 ④ 标题矩形 \(title) · 线 \(tool.guideLines.count)")

        // A real click needs a real, key window: SwiftUI's tap recogniser reads the events the window
        // dispatches, and a window that was never ordered front receives none (`MaskSliderRowTests`'
        // path for the same reason).
        NSApplication.shared.setActivationPolicy(.accessory)
        TestWindows.show(panel.window, key: true)
        panel.host.layoutSubtreeIfNeeded()
        CropUITestSupport.pump(0.15)
        let titleNow = try XCTUnwrap(panel.row(CorrectionCardRow.guideLines.titleID),
                                     "508 ④ 上屏后标题仍在原处")
        print("508 ④ 上屏后标题矩形 \(titleNow)")

        let rows = session.history.snapshots.count
        let before = state(session, lines: tool.guideLines.count)

        // 反向门 ①：**单击**标题什么也不做。
        let point = CGPoint(x: titleNow.midX, y: titleNow.midY)
        Self.click(.leftMouseDown, at: point, in: panel.window, clickCount: 1, host: panel.host)
        Self.click(.leftMouseUp, at: point, in: panel.window, clickCount: 1, host: panel.host)
        CropUITestSupport.pump(0.1)
        let afterSingle = state(session, lines: tool.guideLines.count)
        print("508 ④ 单击: \(before.line) → \(afterSingle.line) · 历史 +\(session.history.snapshots.count - rows)")
        XCTAssertEqual(afterSingle, before, "508 ④ 单击标题不触发任何复位")
        XCTAssertEqual(session.history.snapshots.count, rows, "508 ④ 单击不铸行")

        // 真实双击：两下，第二下 clickCount = 2（SwiftUI 的 `onTapGesture(count: 2)` 读的就是它）。
        Self.doubleClick(at: point, in: panel.window, host: panel.host)
        CropUITestSupport.pump(0.2)
        let viaGesture = state(session, lines: tool.guideLines.count)
        let gestureRows = session.history.snapshots.count
        print("508 ④ 双击: \(viaGesture.line) · 历史 +\(gestureRows - rows)")

        // 直调动作，同一套 fixture 再走一遍。
        let (session2, tool2) = try makeTool()
        let directBefore = state(session2, lines: tool2.guideLines.count)
        let rows2 = session2.history.snapshots.count
        XCTAssertTrue(tool2.clearGuideLinesAndResetPerspective())
        let viaAction = state(session2, lines: tool2.guideLines.count)
        let actionRows = session2.history.snapshots.count - rows2
        print("508 ④ 直调: \(directBefore.line) → \(viaAction.line) · 历史 +\(actionRows)")

        XCTAssertEqual(viaGesture, viaAction, "508 ④ 真实双击与直调动作逐位相同")
        XCTAssertEqual(gestureRows - rows, 1, "508 ④ 双击 = 一条历史")
        XCTAssertEqual(gestureRows - rows, actionRows)
        XCTAssertEqual(viaGesture.lines, 0)
        XCTAssertEqual(viaGesture.v, 0, accuracy: 1e-12)
        XCTAssertEqual(viaGesture.h, 0, accuracy: 1e-12)
        XCTAssertEqual(session.history.snapshots.last?.label, "清除引导线与透视")
    }

    // MARK: - the panel harness (337's, so the coordinates are the same ones)

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

    /// A 校正 card on a document that already carries two lines and v=+30 / h=−20 — the same state
    /// the unit tests start from, reached through the **real** crop tool (`loupe.cropTool`), so the
    /// gesture the panel wires is the gesture the tool would get.
    private func transformPanel(width: CGFloat) throws -> (CatalogSession, LoupeController, Panel) {
        toolCount += 1
        let directory = workDir.appendingPathComponent("panel-\(toolCount)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let (session, _) = try CropUITestSupport.makeSession(in: directory, width: 1200, height: 1200)
        session.applyEdit {
            $0.geometry.perspectiveVertical = 30
            $0.geometry.perspectiveHorizontal = -20
            $0.geometry.perspectiveShear = 0.07
            $0.geometry.perspectiveAspect = 1.12
            $0.geometry.guideLines = Self.storedLines
        }
        _ = session.commitEdit(label: "透视", coalesce: false)

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
        _ = try waitFor { panel.cards.cardIDs == ["crop", "transformCorrection", "angle"] }
        return (session, loupe, panel)
    }

    @discardableResult
    private func waitFor(_ predicate: () -> Bool) throws -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if predicate() { return true }
            CropUITestSupport.pump(0.05)
        }
        return predicate()
    }

    // MARK: - the mouse

    /// One down/up pair in **window** coordinates. `host` converts the point the probe's frame gave us:
    /// the probe rect lives in the host's space, the event window's.
    private static func click(_ type: NSEvent.EventType, at pointInHost: CGPoint, in window: NSWindow,
                              clickCount: Int, host: NSView, settle: TimeInterval = 0.03) {
        let inWindow = host.convert(pointInHost, to: nil)
        guard let event = NSEvent.mouseEvent(with: type, location: inWindow, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil,
                                             eventNumber: 0, clickCount: clickCount,
                                             pressure: type == .leftMouseDown ? 1 : 0) else { return }
        window.sendEvent(event)
        CropUITestSupport.pump(settle)
    }

    /// A real double-click the way a mouse delivers one: two down/up pairs, the second carrying
    /// `clickCount = 2` — the number SwiftUI's `onTapGesture(count: 2)` reads.
    private static func doubleClick(at pointInHost: CGPoint, in window: NSWindow,
                                    host: NSView) {
        click(.leftMouseDown, at: pointInHost, in: window, clickCount: 1, host: host)
        click(.leftMouseUp, at: pointInHost, in: window, clickCount: 1, host: host)
        click(.leftMouseDown, at: pointInHost, in: window, clickCount: 2, host: host)
        click(.leftMouseUp, at: pointInHost, in: window, clickCount: 2, host: host)
    }
}
