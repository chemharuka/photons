import XCTest
import AppKit
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// **394 — 裁剪框与引导线不该盖到左侧栏上。**
///
/// 用户口径（两句，第二句是关键）：
///
/// > 「裁剪框以及引导线都会浮在左侧侧栏上方，左侧侧栏应当是UI的最上层部分之一」
/// > 「裁剪框与引导线超出画布边界没问题，只需要让UI盖住」
///
/// 所以这一单**不是**裁剪（`clipsToBounds` / `masksToBounds` 一个都不加）：用户要的是**遮挡**。
/// 画布里的 overlay 依旧画到 `canvasHost` 之外，只是左侧栏现在压在它上面。实现就是
/// `WorkspaceRootView.init` 里那一个 `addSubview` 循环的数组顺序 —— `addSubview` 把视图加在**最上层**，
/// 所以数组是从底到上，`browserPane.view` / `browserDivider` 排在 `canvasHost` **之后**。
///
/// 每一格验收都是数字：子视图索引、以及**越界矩形与侧栏矩形相交**（越界真实存在）**且**侧栏在它之上。
/// ②/③ 特意**不**断言「交集为空」——那正好是裁剪方案（方案 B）的判据，与本单目标相反。
@MainActor
final class CropOverlayAboveBrowser394Tests: XCTestCase {

    private var workDir: URL!
    private var editors: [EditorWindowController] = []
    private var savedBrowserWidth: Any?

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-394-overlay-order-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        // ④ drags the divider, which persists the width in the user's defaults. A test must not leave
        // the app opening at the width it dragged to.
        savedBrowserWidth = UserDefaults.standard.object(forKey: "photons.browserWidth")
    }

    override func tearDownWithError() throws {
        for editor in editors { editor.window?.close() }
        editors.removeAll()
        if let savedBrowserWidth {
            UserDefaults.standard.set(savedBrowserWidth, forKey: "photons.browserWidth")
        } else {
            UserDefaults.standard.removeObject(forKey: "photons.browserWidth")
        }
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    // MARK: - harness

    private struct Workspace {
        let editor: EditorWindowController
        let window: NSWindow
        let root: WorkspaceRootView
        let loupe: LoupeController
        let session: CatalogSession
    }

    /// A real editor window on the real workspace root, laid out — the same fixture the other crop
    /// suites use, so the indices below are the ones the app builds.
    private func makeWorkspace() throws -> Workspace {
        let editor = try CropUITestSupport.makeEditor(in: workDir)
        editors.append(editor)
        let window = try XCTUnwrap(editor.window)
        let root = try XCTUnwrap(editor.rootView)
        root.layoutSubtreeIfNeeded()
        CropUITestSupport.pump(0.05)
        root.layoutSubtreeIfNeeded()
        return Workspace(editor: editor, window: window, root: root,
                         loupe: root.loupeController, session: editor.session)
    }

    /// `canvasHost` is reached **without any new API on the workspace**: it is the superview of the
    /// loupe's own view (`showModule(for:)` installs the module there, `target.frame = canvasHost.bounds`).
    private func canvasHost(_ w: Workspace) throws -> NSView {
        try XCTUnwrap(w.loupe.view.superview, "the canvas module is not in a host")
    }

    private func index(of view: NSView, in root: WorkspaceRootView) -> Int? {
        root.subviews.firstIndex { $0 === view }
    }

    private func requireIndex(of view: NSView, in root: WorkspaceRootView,
                              _ label: String) throws -> Int {
        try XCTUnwrap(index(of: view, in: root), "\(label) is not a direct subview of the workspace")
    }

    /// The two `WorkspaceDivider` strips, left (browser) to right (inspector).
    private func dividers(of root: WorkspaceRootView) -> [WorkspaceDivider] {
        root.subviews.compactMap { $0 as? WorkspaceDivider }.sorted { $0.frame.minX < $1.frame.minX }
    }

    /// The rect a `CropToolLayout` covers, in the overlay's own points.
    private func drawnRect(_ layout: CropToolLayout) -> NSRect {
        let xs = layout.corners.map(\.x), ys = layout.corners.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return .zero }
        return NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func describe(_ r: NSRect) -> String {
        String(format: "(%.1f, %.1f) %.1f×%.1f → maxX %.1f",
               r.minX, r.minY, r.width, r.height, r.maxX)
    }

    // MARK: - ① ⑤ ⑥ the stacking order

    /// ① — `browserPane.view`'s index is **greater** than `canvasHost`'s, i.e. the panel is added later
    /// and therefore sits on top. ⑤ the inspector and the filmstrip stay above the panel; ⑥ the glass
    /// stays at the bottom (`subviews[0]`, :433's comment).
    func testTheBrowserSitsAboveTheCanvasAndBelowTheInspector() throws {
        let w = try makeWorkspace()
        let host = try canvasHost(w)
        let canvas = try requireIndex(of: host, in: w.root, "canvasHost")
        let browser = try requireIndex(of: w.root.browserPane.view, in: w.root, "browserPane.view")
        let inspector = try requireIndex(of: w.root.inspectorHost, in: w.root, "inspectorHost")
        let filmstrip = try requireIndex(of: w.root.filmstripController.view, in: w.root,
                                        "filmstripController.view")
        let glass = try requireIndex(of: w.root.headerGlass, in: w.root, "headerGlass")
        let strips = dividers(of: w.root)
        XCTAssertEqual(strips.count, 2, "two divider strips, one per panel edge")
        let dividerIndices = try strips.map { try requireIndex(of: $0, in: w.root, "divider") }
        print("""
        394 ① · subviews \(w.root.subviews.count) · headerGlass[\(glass)] canvasHost[\(canvas)] \
        browserPane[\(browser)] dividerL[\(dividerIndices[0])] dividerR[\(dividerIndices[1])] \
        inspectorHost[\(inspector)] filmstrip[\(filmstrip)] · \
        order \(browser > canvas ? "browser ABOVE canvas ✔" : "browser BELOW canvas ✘")
        """)

        XCTAssertGreaterThan(browser, canvas,
                             "① 左侧栏被画布压着：browserPane[\(browser)] ≤ canvasHost[\(canvas)] — "
                             + "overlay 越界就会浮在侧栏上方")
        XCTAssertGreaterThan(inspector, browser, "⑤ 检查器必须仍在侧栏之上")
        XCTAssertGreaterThan(filmstrip, browser, "⑤ 胶片条必须仍在侧栏之上")
        for (i, d) in dividerIndices.enumerated() {
            XCTAssertGreaterThan(d, canvas, "④ divider[\(i)] 必须在画布之上才能抓住")
        }
        XCTAssertEqual(glass, 0, "⑥ headerGlass 必须留在最底（红绿灯要与它一致）")
    }

    // MARK: - ② the crop frame overhangs the canvas and the panel covers it

    /// ② — a draft whose projected frame reaches **left of `canvasHost.bounds`** (`minX < 0` in the
    /// overlay's points). Two facts, and both are required:
    ///
    ///   · the drawn frame and the browser panel really **do intersect** (the overhang exists — the user
    ///     accepted it: 「超出画布边界没问题」);
    ///   · the browser is **above** the canvas in `subviews`, i.e. the overhanging part is covered.
    ///
    /// The clamp that would otherwise pull the frame back in (`⑦ clampToView`) is switched off for the
    /// construction only: this test is about the layering, not about the clamp's own law. No geometry,
    /// no drawing code and no clip flag is touched.
    func testTheOverhangingCropFrameIsCoveredByTheBrowser() throws {
        let w = try makeWorkspace()
        XCTAssertTrue(CropUITestSupport.openCropTool(w.loupe, w.session))
        CropUITestSupport.pump(0.05)

        // The overhang has to be **built**, not hoped for: the canvas clamps a frame that is dragged
        // outside it, so the acceptance takes the clamp out of the way (a documented test gate) and
        // writes the draft the user is describing — a frame whose left edge is off the canvas.
        w.loupe.cropTool.clampsFrameToView = false
        w.loupe.cropTool.draft.crop = CropRect(left: -0.12, top: 0.25, right: 0.55, bottom: 0.95)
        w.loupe.refreshCropTool()
        CropUITestSupport.pump(0.05)

        let overlay = w.loupe.cropOverlayViewForAudit
        let layout = try XCTUnwrap(w.loupe.cropOverlayLayoutForTesting, "no frame drawn")
        let drawn = drawnRect(layout)
        let drawnInRoot = overlay.convert(drawn, to: w.root)
        let panelFrame = w.root.browserPane.view.frame
        let overlap = drawnInRoot.intersection(panelFrame)
        let host = try canvasHost(w)
        let canvas = try requireIndex(of: host, in: w.root, "canvasHost")
        let browser = try requireIndex(of: w.root.browserPane.view, in: w.root, "browserPane.view")

        print("""
        394 ② · draft minX \(layout.corners.map(\.x).min() ?? 0) pt (负 = 越出画布左边界) · \
        drawn(in overlay) \(describe(drawn)) · drawn(in root) \(describe(drawnInRoot)) · \
        browser frame \(describe(panelFrame)) · 交集 \(describe(overlap)) \
        (null=\(overlap.isNull)) · browserPane[\(browser)] vs canvasHost[\(canvas)]
        """)

        XCTAssertLessThan(drawn.minX, 0,
                          "② 前提：框必须越出画布左边界（画布坐标 x<0），实际 \(describe(drawn))")
        XCTAssertFalse(overlap.isNull, "② 前提：越界部分必须真的压在侧栏矩形上")
        XCTAssertGreaterThan(overlap.width, 1, "② 越界的那一块太窄，说明不了遮挡")
        XCTAssertGreaterThan(overlap.height, 1, "② 越界的那一块太窄，说明不了遮挡")
        XCTAssertGreaterThan(browser, canvas,
                             "② 越界存在，但侧栏不在它之上（browserPane[\(browser)] ≤ canvasHost[\(canvas)]）"
                             + " — 用户看到的就是框浮在侧栏上")
    }

    // MARK: - ③ the guide lines, same two facts

    /// ③ — the guide lines are drawn from source pixels, so a line the user drew before a straighten
    /// can land off the canvas. Same two facts as ②: the drawn segment's rect really does cross into the
    /// panel's rect, and the panel is above the canvas.
    func testTheOverhangingGuideLineIsCoveredByTheBrowser() throws {
        let w = try makeWorkspace()
        XCTAssertTrue(CropUITestSupport.openCropTool(w.loupe, w.session))
        CropUITestSupport.pump(0.05)

        // One line, stored in source pixels, starting well left of the photograph — the shape a
        // document ends up with after a straighten/keystone change moved the picture under the line.
        let width = Double(w.session.maskSourceSize.width)
        let height = Double(w.session.maskSourceSize.height)
        w.session.applyEdit {
            $0.geometry.guideLines = [StoredGuideLine(ax: -0.08 * width, ay: 0.15 * height,
                                                      bx: 0.55 * width, by: 0.85 * height,
                                                      vertical: true)]
        }
        _ = w.session.commitEdit(label: "394 引导线", coalesce: false)
        XCTAssertTrue(w.loupe.cropTool.reloadGuideLines(), "the tool did not take the document's line")
        w.loupe.refreshCropTool()
        CropUITestSupport.pump(0.05)

        let overlay = w.loupe.cropOverlayViewForAudit
        let segments = w.loupe.cropOverlayGuideLines
        XCTAssertEqual(segments.count, 1, "③ one line, drawn")
        let a = overlay.convert(segments[0].a, to: w.root)
        let b = overlay.convert(segments[0].b, to: w.root)
        // The stroke's own width is part of what is on screen, so the rect is fattened by half of it.
        let half = CGFloat(GuideLineChrome.lineWidth / 2)
        let drawnInRoot = NSRect(x: min(a.x, b.x), y: min(a.y, b.y),
                                 width: abs(b.x - a.x), height: abs(b.y - a.y))
            .insetBy(dx: -half, dy: -half)
        let panelFrame = w.root.browserPane.view.frame
        let overlap = drawnInRoot.intersection(panelFrame)
        let host = try canvasHost(w)
        let canvas = try requireIndex(of: host, in: w.root, "canvasHost")
        let browser = try requireIndex(of: w.root.browserPane.view, in: w.root, "browserPane.view")

        print("""
        394 ③ · 线源坐标 x \(-0.06 * width)…\(0.55 * width) px · 端点(in root) \
        \(describe(NSRect(origin: a, size: .zero))) / \(describe(NSRect(origin: b, size: .zero))) · \
        drawn(in root) \(describe(drawnInRoot)) · browser frame \(describe(panelFrame)) · \
        交集 \(describe(overlap)) (null=\(overlap.isNull)) · \
        browserPane[\(browser)] vs canvasHost[\(canvas)]
        """)

        XCTAssertLessThan(min(a.x, b.x), w.root.browserPane.view.frame.maxX,
                          "③ 前提：线的端点在视图坐标上越出了画布左边界")
        XCTAssertFalse(overlap.isNull, "③ 前提：越界的那一段必须真的压在侧栏矩形上")
        XCTAssertGreaterThan(overlap.width, 1, "③ 越界的那一块太窄，说明不了遮挡")
        XCTAssertGreaterThan(browser, canvas,
                             "③ 越界存在，但侧栏不在它之上（browserPane[\(browser)] ≤ canvasHost[\(canvas)]）")
    }

    // MARK: - ④ the panel is still live

    /// ④ — the divider's grab strip is still the view under the hand (it is now above the canvas, which
    /// is what makes it grabbable at all), and a real drag through its own `mouseDown` still writes the
    /// browser width. `WorkspaceDivider.mouseDown` runs its own `nextEvent` loop, so the drag and the
    /// release are queued **before** it starts.
    func testTheBrowserDividerStillDragsAfterTheReorder() throws {
        let w = try makeWorkspace()
        let strips = dividers(of: w.root)
        XCTAssertEqual(strips.count, 2)
        let divider = try XCTUnwrap(strips.first)
        let dividerIndex = try requireIndex(of: divider, in: w.root, "browserDivider")
        let canvas = try requireIndex(of: try canvasHost(w), in: w.root, "canvasHost")

        // Start from the narrowest the layout allows, so the +40 pt drag has room in both directions.
        w.root.setBrowserWidth(WorkspaceLayout.browserWidthMin)
        w.root.layoutSubtreeIfNeeded()

        // The strip is the thing under the hand at its own centre — through the **root's** hit test,
        // i.e. through the same order that decides drawing.
        let centreInRoot = divider.convert(NSPoint(x: divider.bounds.midX, y: divider.bounds.midY),
                                           to: w.root)
        let hit = w.root.hitTest(centreInRoot)
        let before = w.root.currentBrowserWidth

        let start = divider.convert(NSPoint(x: divider.bounds.midX, y: divider.bounds.midY), to: nil)
        let finish = NSPoint(x: start.x + 40, y: start.y)
        let down = CropUITestSupport.mouse(.leftMouseDown, at: start, in: w.window)
        // `WorkspaceDivider.mouseDown` drains its own `nextEvent` loop, so the drag and the release are
        // queued **before** it starts, drag first — the loop stops at the first `.leftMouseUp` it sees.
        NSApp.postEvent(CropUITestSupport.mouse(.leftMouseDragged, at: finish, in: w.window),
                        atStart: false)
        NSApp.postEvent(CropUITestSupport.mouse(.leftMouseUp, at: finish, in: w.window),
                        atStart: false)
        divider.mouseDown(with: down)
        w.root.layoutSubtreeIfNeeded()
        let after = w.root.currentBrowserWidth

        print("""
        394 ④ · divider[\(dividerIndex)] (canvasHost[\(canvas)]) · hit at centre = \
        \(hit.map { String(describing: type(of: $0)) } ?? "nil") · \
        browserWidth \(before) → \(after) (Δ\(after - before)) · wired \(w.root.panelDividersAreWired)
        """)

        XCTAssertGreaterThan(dividerIndex, canvas, "④ 手柄在画布之下 —— 抓不到")
        XCTAssertNotNil(hit)
        XCTAssertTrue(hit === divider || (hit?.isDescendant(of: divider) ?? false),
                      "④ 手柄那一带的命中区不属于手柄，是 \(String(describing: hit))")
        XCTAssertTrue(w.root.panelDividersAreWired, "④ 回调没接上")
        XCTAssertGreaterThan(after, before + 1,
                             "④ 拖拽回调没触发：browserWidth \(before) → \(after)")
    }
}
