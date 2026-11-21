import XCTest
import AppKit
import PhotonsCatalog
import PhotonsCore
import PhotonsLocalization
@testable import PhotonsUI

/// **402 — 裁剪框/引导线不该盖到顶栏与胶片条背景上。**
///
/// 用户口径：
///
/// > 「裁剪框，引导线，之前修过会出区域到侧栏，实际上除了左侧栏，还会出现在顶部横条（包括红绿灯），
/// > 以及底部胶片条的背景上。」
///
/// 394 的「遮挡而不裁剪」路线不变（用户：「超出画布边界没问题」）。本单补齐两个漏面，而它们是**两种**
/// 不同的修法：
///
/// ① **顶栏是层级问题** —— `headerGlass` / `topBar` 曾经排在 `canvasHost` 之前（即之下），
///   越界的 overlay 连同画布的黑底盖住了顶栏与红绿灯；
/// ② **胶片条是缺底板** —— 它的 `view` 是 `drawsBackground = false` 的 `NSScrollView`、cell 背景
///   `.clear`，层次本来就对，但那块**没有像素**去遮挡越界部分。
///
/// 每一格都是「越界真实发生 **且** 被盖住」两件事同时成立，与 394 ② 同构。
@MainActor
final class CropOverlayAboveChrome402Tests: XCTestCase {

    private var workDir: URL!
    private var editors: [EditorWindowController] = []
    private var savedBrowserMode: Any?
    private var savedBrowserWidth: Any?

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-402-chrome-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        // `setBrowserMode` persists the mode in the user's defaults; a test must not leave the app
        // opening in whichever mode it switched to.
        savedBrowserMode = AppPreferences.store.object(forKey: "photons.browserMode")
        savedBrowserWidth = AppPreferences.store.object(forKey: "photons.browserWidth")
    }

    override func tearDownWithError() throws {
        for editor in editors { editor.window?.close() }
        editors.removeAll()
        for (key, value) in [("photons.browserMode", savedBrowserMode),
                             ("photons.browserWidth", savedBrowserWidth)] {
            if let value { AppPreferences.store.set(value, forKey: key) }
            else { AppPreferences.store.removeObject(forKey: key) }
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

    /// `canvasHost` is reached without new API: it is the superview `showModule(for:)` installs the
    /// loupe's own view into.
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

    private func drawnRect(_ layout: CropToolLayout) -> NSRect {
        let xs = layout.corners.map(\.x), ys = layout.corners.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return .zero }
        return NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func describe(_ r: NSRect) -> String {
        String(format: "(%.1f, %.1f) %.1f×%.1f", r.minX, r.minY, r.width, r.height)
    }

    /// One real offscreen composite of the whole workspace (`cacheDisplay`, the same path
    /// `HistogramCardHeightTests` / `NativeTrafficLightsTests` measure through).
    ///
    /// Why not `CGWindowListCreateImage`: it returns an all-zero bitmap in this process (no screen
    /// recording permission), so it cannot tell anything. `cacheDisplay` composites the view tree the
    /// way `draw` sees it, which is what this lane's claim is about: is the overhanging overlay
    /// painted into the top bar's pixels or not.
    private struct Snapshot {
        let rep: NSBitmapImageRep
        let scale: CGFloat

        func rgb(at p: NSPoint) -> (r: Double, g: Double, b: Double) {
            let x = Int((p.x * scale).rounded()), y = Int((p.y * scale).rounded())
            guard x >= 0, y >= 0, x < rep.pixelsWide, y < rep.pixelsHigh,
                  let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return (-1, -1, -1) }
            return (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
        }

        func triple(_ p: NSPoint) -> String {
            let v = rgb(at: p)
            return String(format: "(%.3f, %.3f, %.3f)", v.r, v.g, v.b)
        }
    }

    private func snapshot(_ root: WorkspaceRootView) throws -> Snapshot {
        guard let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else {
            throw XCTSkip("root cannot cache its display")
        }
        root.cacheDisplay(in: root.bounds, to: rep)
        return Snapshot(rep: rep, scale: CGFloat(rep.pixelsWide) / root.bounds.width)
    }

    private func maxChannelDelta(_ a: (r: Double, g: Double, b: Double),
                                 _ b: (r: Double, g: Double, b: Double)) -> Double {
        max(abs(a.r - b.r), max(abs(a.g - b.g), abs(a.b - b.b)))
    }

    /// The five faces, in `subviews` order, as one report line.
    private func inventory(_ w: Workspace) throws -> String {
        let host = try canvasHost(w)
        func pos(_ view: NSView?, _ name: String) -> String {
            guard let view, let i = index(of: view, in: w.root) else { return "\(name)[—]" }
            return "\(name)[\(i)]"
        }
        return [
            pos(w.root.headerGlass, "headerGlass"),
            pos(w.root.topBar, "topBar"),
            pos(host, "canvasHost"),
            pos(w.root.browserPane.view, "browserPane"),
            pos(w.root.inspectorHost, "inspectorHost"),
            pos(w.root.filmstripBackdrop, "filmstripBackdrop"),
            pos(w.root.filmstripController.view, "filmstrip"),
            pos(w.root.importProgressBar, "importProgressBar"),
            pos(w.root.forwardCompatNotice, "forwardCompatNotice"),
        ].joined(separator: " ")
    }

    // MARK: - ① the top bar

    /// ① — `headerGlass` and `topBar` are both **added after** `canvasHost` (so they sit on top and
    /// cover the overhang), `headerGlass` still before `topBar` (it is the buttons' backdrop), and a
    /// crop draft that really reaches above the canvas' top edge intersects `topBar.frame`.
    ///
    /// It also measures 2.1's regression risk: `headerGlass` spans the window's full width up to
    /// `topBar.maxY`, so if that height were wrong it would cover the canvas' top band. The overlap
    /// must be exactly 0 pt tall.
    func testTheTopBarIsAboveTheCanvas() throws {
        let w = try makeWorkspace()
        XCTAssertTrue(CropUITestSupport.openCropTool(w.loupe, w.session))
        CropUITestSupport.pump(0.05)

        // A frame reaching above the photograph: `top < 0` in the draft's normalized space. The canvas'
        // clamp is switched off **for the construction only** — this is the layering test, not the
        // clamp's own law (`clampsFrameToView = false` is the documented test gate 394 ② also uses).
        w.loupe.cropTool.clampsFrameToView = false
        w.loupe.cropTool.draft.crop = CropRect(left: 0.10, top: -0.35, right: 0.80, bottom: 0.75)
        w.loupe.refreshCropTool()
        CropUITestSupport.pump(0.05)

        let overlay = w.loupe.cropOverlayViewForAudit
        let layout = try XCTUnwrap(w.loupe.cropOverlayLayoutForTesting, "no frame drawn")
        let drawn = drawnRect(layout)
        let drawnInRoot = overlay.convert(drawn, to: w.root)
        let host = try canvasHost(w)
        let canvasRect = host.frame
        let topBarFrame = w.root.topBar.frame
        let overlap = drawnInRoot.intersection(topBarFrame)
        let glass = try requireIndex(of: w.root.headerGlass, in: w.root, "headerGlass")
        let bar = try requireIndex(of: w.root.topBar, in: w.root, "topBar")
        let canvas = try requireIndex(of: host, in: w.root, "canvasHost")
        let glassOverCanvas = w.root.headerGlass.frame.intersection(canvasRect)

        print("""
        402 ① · \(try inventory(w)) · \
        drawn(in overlay) \(describe(drawn)) · drawn(in root) \(describe(drawnInRoot)) · \
        canvas \(describe(canvasRect)) · topBar \(describe(topBarFrame)) · \
        交集 \(describe(overlap)) (null=\(overlap.isNull)) · \
        headerGlass \(describe(w.root.headerGlass.frame)) ∩ canvas 高度 \
        \(glassOverCanvas.isNull ? 0 : glassOverCanvas.height)
        """)

        XCTAssertLessThan(drawnInRoot.minY, canvasRect.minY,
                          "① 前提：框必须越出画布上边界，实际 \(describe(drawnInRoot)) vs 画布上沿 \(canvasRect.minY)")
        XCTAssertFalse(overlap.isNull, "① 前提：越界部分必须真的压在顶栏矩形上")
        XCTAssertGreaterThan(overlap.width, 1, "① 越界的那一块太窄，说明不了遮挡")
        XCTAssertGreaterThan(overlap.height, 1, "① 越界的那一块太窄，说明不了遮挡")
        XCTAssertGreaterThan(bar, canvas,
                             "① 期望 topBar 索引 \(canvas + 1) > canvasHost 索引 \(canvas)，"
                             + "实际 \(bar) vs \(canvas) — 顶栏在画布之下，越界 overlay 会盖住它和红绿灯")
        XCTAssertGreaterThan(glass, canvas,
                             "① 期望 headerGlass 索引 > canvasHost 索引 \(canvas)，实际 \(glass) vs \(canvas)"
                             + " — 玻璃在画布之下，红绿灯那条会露出 overlay")
        XCTAssertLessThan(glass, bar, "① headerGlass[\(glass)] 必须仍在 topBar[\(bar)] 之前（玻璃衬托按钮）")
        XCTAssertTrue(glassOverCanvas.isNull || glassOverCanvas.height <= 0.001,
                      "① 回归：headerGlass \(describe(w.root.headerGlass.frame)) 盖住了画布上沿 "
                      + "\(describe(glassOverCanvas))（必须为 0 高）")
    }

    // MARK: - ①b the pixels: the top bar really is opaque over the overhang

    /// ①b — ① 的索引关系只证明「顺序对」。这条证明**屏幕上真的看不见**：越界 overlay 现在压在
    /// `headerGlass`（`.headerView` / `.behindWindow` 的半透明采样层）**与** `topBar`（不填底色）之下，
    /// 两者自身都不遮挡。所以唯一能证明遮挡成立的是像素：整窗离屏合成一帧，
    /// 在三条带上读实测 RGB，并把这三条带与 `.aqua` / `.darkAqua` 两个外观各测一遍。
    ///
    ///   · a 带：顶栏那条里、越界 overlay 与 `topBar` 交集内部，**避开所有控件与描边**的纯背景列；
    ///   · b 带：顶栏里同一 `y`、交集之外（overlay 没画到）的同宽纯背景列；
    ///   · c 带：红绿灯所在那一行的三颗按钮之间的空白。
    ///
    /// 判据 a↔b 差 ≤ 0.06（同一条顶栏的同一行背景，overlay 在不在必须看不出来）；c 带不许偏青蓝，
    /// 且与 b 带差 ≤ 0.06。两条都有区分力，实测见 ⑧c：把 `headerGlass` 沉回数组最前（最底层）后
    /// aqua 的 |Δa−b| = 0.4481、darkAqua = 0.0923，两外观都红；本单顺序下两外观都是 0.0000。
    func testTheOverhangIsActuallyOpaqueUnderTheTopBar() throws {
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let w = try makeWorkspace()
            w.window.appearance = NSAppearance(named: appearanceName)
            w.root.layoutSubtreeIfNeeded()
            CropUITestSupport.pump(0.05)

            XCTAssertTrue(CropUITestSupport.openCropTool(w.loupe, w.session))
            CropUITestSupport.pump(0.05)
            // Control frame **before** the draft moves: the same bar row, nothing overhanging.
            w.root.layoutSubtreeIfNeeded()
            w.window.displayIfNeeded()
            let control = try snapshot(w.root)

            // The draft of ① but reaching **left as well**, so the overhang also crosses the
            // traffic-light end of the bar (`x < 88`): the intersection with `topBar` then starts at
            // x 0, which is where the traffic lights live.
            w.loupe.cropTool.clampsFrameToView = false
            w.loupe.cropTool.draft.crop = CropRect(left: -0.55, top: -0.35, right: 0.80, bottom: 0.75)
            w.loupe.refreshCropTool()
            w.root.layoutSubtreeIfNeeded()
            CropUITestSupport.pump(0.10)
            w.window.displayIfNeeded()

            let overlay = w.loupe.cropOverlayViewForAudit
            let layout = try XCTUnwrap(w.loupe.cropOverlayLayoutForTesting, "no frame drawn")
            let drawnInRoot = overlay.convert(drawnRect(layout), to: w.root)
            let bar = w.root.topBar.frame
            let inter = drawnInRoot.intersection(bar)
            XCTAssertFalse(inter.isNull, "①b 前提：越界部分必须真的压在顶栏上")

            let shot = try snapshot(w.root)
            // A column inside the intersection that is plain bar background: the bar's own controls
            // end at `sortButton.frame.maxX` (~452) and the status cluster starts at 1425, so
            // 460…1400 is bare. 700 is the column `NativeTrafficLightsTests` also measures.
            let yInBar = inter.minY + bar.height / 2          // middle of the bar row
            let insideX = max(inter.minX + 4, 700)
            let outsideX = min(inter.maxX + 40, bar.maxX - 20)
            XCTAssertTrue(inter.minX <= insideX && insideX <= inter.maxX,
                          "①b 前提：a 带 x=\(insideX) 必须落在交集 \(describe(inter)) 内")
            XCTAssertFalse(inter.minX <= outsideX && outsideX <= inter.maxX,
                           "①b 前提：b 带 x=\(outsideX) 必须在交集之外")
            // The traffic-light row: the gap between the mini and the zoom button (they are at
            // x 32…46 and 55…69 in this window), i.e. x = 50, and the gap before `close` (x < 9).
            let lightY = try XCTUnwrap(w.root.trafficLightCentreY(), "no traffic-light centre")
            let lightGapX: CGFloat = 50

            let a = shot.rgb(at: NSPoint(x: insideX, y: yInBar))
            let b = shot.rgb(at: NSPoint(x: outsideX, y: yInBar))
            let c = shot.rgb(at: NSPoint(x: lightGapX, y: lightY))
            // The same three points on the control frame (no overhang at all).
            let a0 = control.rgb(at: NSPoint(x: insideX, y: yInBar))
            let c0 = control.rgb(at: NSPoint(x: lightGapX, y: lightY))

            let abDelta = maxChannelDelta(a, b)
            let abControlDelta = maxChannelDelta(a, a0)
            let cbDelta = maxChannelDelta(c, b)
            let cc0Delta = maxChannelDelta(c, c0)
            let cIsCyan = c.b <= max(c.r, c.g) + 0.08

            print("""
            402 ①b [\(appearanceName.rawValue)] · 交集 \(describe(inter)) · \
            a-band (\(Int(insideX)),\(Int(yInBar))) \(shot.triple(NSPoint(x: insideX, y: yInBar))) · \
            b-band (\(Int(outsideX)),\(Int(yInBar))) \(shot.triple(NSPoint(x: outsideX, y: yInBar))) · \
            |Δa−b| \(String(format: "%.4f", abDelta)) · \
            c-band (\(Int(lightGapX)),\(Int(lightY))) \(shot.triple(NSPoint(x: lightGapX, y: lightY))) · \
            |Δc−b| \(String(format: "%.4f", cbDelta)) · c 不偏青蓝? \(cIsCyan) · \
            对照(无越界) a \(control.triple(NSPoint(x: insideX, y: yInBar))) c \
            \(control.triple(NSPoint(x: lightGapX, y: lightY))) · \
            |Δa−a0| \(String(format: "%.4f", abControlDelta)) |Δc−c0| \(String(format: "%.4f", cc0Delta))
            """)

            // ①b-1 the bar row: the overhang must not be visible.
            XCTAssertLessThanOrEqual(abDelta, 0.06,
                                     "\(appearanceName.rawValue): 顶栏里 overlay 越界那一段与没越界那一段差 "
                                     + "\(String(format: "%.4f", abDelta)) > 0.06 —— a \(shot.triple(NSPoint(x: insideX, y: yInBar)))"
                                     + " vs b \(shot.triple(NSPoint(x: outsideX, y: yInBar)))")
            // and it must not have changed at all vs the no-overhang frame.
            XCTAssertLessThanOrEqual(abControlDelta, 0.06,
                                     "\(appearanceName.rawValue): 画上越界 overlay 之后顶栏那段像素变了 "
                                     + "\(String(format: "%.4f", abControlDelta))："
                                     + "\(control.triple(NSPoint(x: insideX, y: yInBar))) → \(shot.triple(NSPoint(x: insideX, y: yInBar)))")
            // ①b-2 the traffic-light row: no crop-stroke colour bleeding in.
            XCTAssertTrue(cIsCyan,
                          "\(appearanceName.rawValue): 红绿灯那一行偏青蓝，落到 \(shot.triple(NSPoint(x: lightGapX, y: lightY)))"
                          + "（r \(String(format: "%.3f", c.r)) g \(String(format: "%.3f", c.g)) b \(String(format: "%.3f", c.b))）")
            XCTAssertLessThanOrEqual(cbDelta, 0.06,
                                     "\(appearanceName.rawValue): 红绿灯那一行与顶栏背景差 "
                                     + String(format: "%.4f", cbDelta) + " > 0.06")
            XCTAssertLessThanOrEqual(cc0Delta, 0.06,
                                     "\(appearanceName.rawValue): 红绿灯那一行被 overlay 改了 "
                                     + "\(String(format: "%.4f", cc0Delta))")

            w.window.appearance = nil
            for editor in editors { editor.window?.close() }
            editors.removeAll()
        }
    }

    // MARK: - ② the filmstrip plate
    /// ② — the filmstrip has a real plate: an `NSVisualEffectView` added **after** `canvasHost` (so it
    /// covers the overhang) and **before** `filmstripController.view` (so the thumbnails are on top),
    /// with exactly the strip's frame, `.underWindowBackground` / `.behindWindow`.
    ///
    /// Then the strip goes away (`.list`): the plate must go with it — a stale 86 pt plate over the
    /// canvas would be this lane's bug inverted.
    func testTheFilmstripHasAnOpaqueBackdrop() throws {
        let w = try makeWorkspace()
        w.root.setBrowserMode(.filmstrip)
        w.root.layoutSubtreeIfNeeded()
        CropUITestSupport.pump(0.05)
        w.root.layoutSubtreeIfNeeded()

        let host = try canvasHost(w)
        let canvas = try requireIndex(of: host, in: w.root, "canvasHost")
        let backdrop = w.root.filmstripBackdrop
        let plate = try requireIndex(of: backdrop, in: w.root, "filmstripBackdrop")
        let strip = try requireIndex(of: w.root.filmstripController.view, in: w.root,
                                     "filmstripController.view")
        let plateFrame = backdrop.frame
        let stripFrame = w.root.filmstripController.view.frame

        print("""
        402 ② · \(try inventory(w)) · backdrop \(describe(plateFrame)) · \
        strip \(describe(stripFrame)) · \
        frameEqual \(plateFrame == stripFrame) · \
        material \(backdrop.material.rawValue) blending \(backdrop.blendingMode.rawValue) \
        hidden \(backdrop.isHidden) · canvas \(describe(host.frame))
        """)

        // The overhang the user reported ("胶片条的背景上"): a crop frame whose bottom leaves the
        // canvas' bottom edge, so it crosses the strip's rect. Both facts are required — the overhang
        // really exists (the user accepts it: 「超出画布边界没问题」) **and** the plate is between it
        // and the window (`plate > canvas`, asserted below).
        XCTAssertTrue(CropUITestSupport.openCropTool(w.loupe, w.session))
        CropUITestSupport.pump(0.05)
        w.loupe.cropTool.clampsFrameToView = false
        w.loupe.cropTool.draft.crop = CropRect(left: 0.12, top: 0.10, right: 0.80, bottom: 1.45)
        w.loupe.refreshCropTool()
        w.root.layoutSubtreeIfNeeded()
        CropUITestSupport.pump(0.05)

        let overlay = w.loupe.cropOverlayViewForAudit
        let layout = try XCTUnwrap(w.loupe.cropOverlayLayoutForTesting, "no frame drawn")
        let drawnInRoot = overlay.convert(drawnRect(layout), to: w.root)
        let stripOverlap = drawnInRoot.intersection(plateFrame)
        print("""
        402 ② · 越界到胶片条 · draft bottom 1.45 · drawn(in root) \(describe(drawnInRoot)) · \
        plate \(describe(plateFrame)) · 交集 \(describe(stripOverlap)) (null=\(stripOverlap.isNull)) · \
        overlay 越出画布下沿 \(String(format: "%.1f", drawnInRoot.maxY - host.frame.maxY)) pt
        """)
        XCTAssertGreaterThan(drawnInRoot.maxY, host.frame.maxY,
                             "② 前提：框必须越出画布下边界，实际 \(describe(drawnInRoot)) vs 画布下沿 \(host.frame.maxY)")
        XCTAssertFalse(stripOverlap.isNull, "② 前提：越界部分必须真的压在胶片条矩形上")
        XCTAssertGreaterThan(stripOverlap.width, 1, "② 越界的那一块太窄，说明不了遮挡")
        XCTAssertGreaterThan(stripOverlap.height, 1, "② 越界的那一块太窄，说明不了遮挡")

        XCTAssertGreaterThan(plate, canvas,
                             "② 底板在画布之下（filmstripBackdrop[\(plate)] ≤ canvasHost[\(canvas)]），"
                             + "越界的 overlay 仍会画到胶片条那块")
        XCTAssertLessThan(plate, strip, "② 底板必须在胶片条之上层吗？不 —— 底板[\(plate)] 必须排在 "
                          + "filmstrip[\(strip)] 之前（缩略图要画在板上）")
        XCTAssertFalse(plateFrame.isEmpty, "② 胶片条模式下底板不能是空矩形")
        XCTAssertEqual(plateFrame.origin.x, stripFrame.origin.x, accuracy: 0, "② 底板 x 必须与胶片条相同")
        XCTAssertEqual(plateFrame.origin.y, stripFrame.origin.y, accuracy: 0, "② 底板 y 必须与胶片条相同")
        XCTAssertEqual(plateFrame.width, stripFrame.width, accuracy: 0, "② 底板宽必须与胶片条相同")
        XCTAssertEqual(plateFrame.height, stripFrame.height, accuracy: 0, "② 底板高必须与胶片条相同")
        XCTAssertEqual(plateFrame.height, WorkspaceLayout.filmstripHeight, accuracy: 0.001,
                       "② 底板高度必须就是那一条 86 pt")
        XCTAssertEqual(backdrop.material, .underWindowBackground, "② 材质与右侧检查器底板同款")
        XCTAssertEqual(backdrop.blendingMode, .behindWindow,
                       "② `.behindWindow` 才是完全不透明的采样层，overlay 透不过来")
        XCTAssertEqual(backdrop.state, .followsWindowActiveState)
        XCTAssertFalse(backdrop.isHidden, "② 胶片条模式底板必须在")

        // 观感/不透明度证据：真实渲染一帧，读板子与胶片条本体中心的像素 alpha。底板应当是不透明的
        // 采样层，而胶片条自己那个 `drawsBackground = false` 的滚动视图读出来是 0 —— 这正是漏色的
        // 原因（no assertion here: it is the *measurement* the report quotes, not a new contract）。
        for (name, view) in [("filmstripBackdrop", backdrop as NSView),
                             ("filmstrip.view", w.root.filmstripController.view)] {
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            let x = rep.pixelsWide / 2, y = rep.pixelsHigh / 2
            let a = rep.colorAt(x: x, y: y)?.alphaComponent ?? -1
            print(String(format: "402 ② · %@ centre pixel alpha %.3f", name, a))
        }

        // The strip is hidden → the plate goes with it.
        w.root.setBrowserMode(.list)
        w.root.layoutSubtreeIfNeeded()
        CropUITestSupport.pump(0.05)
        w.root.layoutSubtreeIfNeeded()
        print("""
        402 ② · mode .list · backdrop \(describe(backdrop.frame)) hidden \(backdrop.isHidden) · \
        strip hidden \(w.root.filmstripController.view.isHidden)
        """)
        XCTAssertTrue(backdrop.isHidden || backdrop.frame.height == 0,
                      "② 胶片条隐藏后仍留着 \(describe(backdrop.frame)) 的板子压着画布")
    }

    // MARK: - ③ 394's regression guard

    /// ③ — 394's result must survive this lane: the browser is still above the canvas, and a frame
    /// reaching left of the canvas really does intersect it.
    func testABorderlineOverlaysStillDoesNotCoverTheLeftBrowser() throws {
        let w = try makeWorkspace()
        XCTAssertTrue(CropUITestSupport.openCropTool(w.loupe, w.session))
        CropUITestSupport.pump(0.05)

        w.loupe.cropTool.clampsFrameToView = false
        w.loupe.cropTool.draft.crop = CropRect(left: -0.12, top: 0.25, right: 0.55, bottom: 0.95)
        w.loupe.refreshCropTool()
        CropUITestSupport.pump(0.05)

        let overlay = w.loupe.cropOverlayViewForAudit
        let layout = try XCTUnwrap(w.loupe.cropOverlayLayoutForTesting, "no frame drawn")
        let drawnInRoot = overlay.convert(drawnRect(layout), to: w.root)
        let panelFrame = w.root.browserPane.view.frame
        let overlap = drawnInRoot.intersection(panelFrame)
        let host = try canvasHost(w)
        let canvas = try requireIndex(of: host, in: w.root, "canvasHost")
        let browser = try requireIndex(of: w.root.browserPane.view, in: w.root, "browserPane.view")

        print("""
        402 ③ · \(try inventory(w)) · drawn(in root) \(describe(drawnInRoot)) · \
        browser \(describe(panelFrame)) · 交集 \(describe(overlap)) (null=\(overlap.isNull))
        """)

        XCTAssertFalse(overlap.isNull, "③ 前提：越界部分必须真的压在侧栏矩形上")
        XCTAssertGreaterThan(overlap.width, 1, "③ 越界的那一块太窄，说明不了遮挡")
        XCTAssertGreaterThan(browser, canvas,
                             "③ 394 的成果被改回去了：browserPane[\(browser)] ≤ canvasHost[\(canvas)]")
    }

    // MARK: - ④ notices stay topmost

    /// ④ — 394's first tier: the import line and the provenance notice stay above **every** panel.
    func testTheNoticeAndProgressStayOnTop() throws {
        let w = try makeWorkspace()
        let host = try canvasHost(w)
        let progress = try requireIndex(of: w.root.importProgressBar, in: w.root, "importProgressBar")
        let notice = try requireIndex(of: w.root.forwardCompatNotice, in: w.root,
                                      "forwardCompatNotice")
        var panels: [(String, Int)] = [
            ("headerGlass", try requireIndex(of: w.root.headerGlass, in: w.root, "headerGlass")),
            ("topBar", try requireIndex(of: w.root.topBar, in: w.root, "topBar")),
            ("canvasHost", try requireIndex(of: host, in: w.root, "canvasHost")),
            ("browserPane", try requireIndex(of: w.root.browserPane.view, in: w.root, "browserPane")),
            ("inspectorHost", try requireIndex(of: w.root.inspectorHost, in: w.root, "inspectorHost")),
            ("filmstripBackdrop", try requireIndex(of: w.root.filmstripBackdrop, in: w.root,
                                                   "filmstripBackdrop")),
            ("filmstrip", try requireIndex(of: w.root.filmstripController.view, in: w.root,
                                           "filmstrip")),
        ]
        for strip in w.root.subviews where strip is WorkspaceDivider {
            panels.append(("divider", try requireIndex(of: strip, in: w.root, "divider")))
        }

        print("""
        402 ④ · \(try inventory(w)) · importProgressBar[\(progress)] forwardCompatNotice[\(notice)] · \
        max panel index \(panels.map(\.1).max() ?? -1)
        """)

        for (name, i) in panels {
            XCTAssertGreaterThan(progress, i, "④ importProgressBar[\(progress)] 必须高于 \(name)[\(i)]")
            XCTAssertGreaterThan(notice, i, "④ forwardCompatNotice[\(notice)] 必须高于 \(name)[\(i)]")
        }
    }
}
