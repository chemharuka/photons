import XCTest
import AppKit
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// ④ (2026-10-27) — the mask chrome belongs to the inspector's **蒙版** workspace, and leaving it
/// takes the chrome away for real.
///
/// The report: 「蒙版控件在退出蒙版菜单栏后应该隐藏」. 「隐藏」 here has three parts, and a test that
/// only checks the first would pass on a half-fix:
///
///   1. **not drawn** — `isHidden` on both overlays, and no layout left behind;
///   2. **not hit** — `hitMaskHandle` answers `nil`, the overlay's own `hitTest` answers `nil`, and
///      `gestureOwner` no longer calls a click on an old grip a `.maskHandle`;
///   3. **not computed** — `syncMaskOverlays` refuses before it touches a projection, so a 120 Hz zoom
///      animation behind a 调节 panel costs nothing (`maskOverlaySyncCount` frozen,
///      `maskOverlayHiddenSkips` growing).
///
/// And coming back is exact: the same frame, the same layout, value for value. A switch **mid-drag**
/// leaves the document and the history alone (the shape goes back to what it was at mouse-down) and
/// drops the rubber band, while the panel's armed 新建 state survives — that is the panel's, not a
/// gesture's, so the user can continue drawing after a glance at another tab.
@MainActor
final class MaskOverlayWorkspaceGateTests: XCTestCase {

    private static let viewport = ImageSize(width: 640, height: 400)
    private var workDir: URL!
    private var windows: [NSWindow] = []

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-mask-gate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    // MARK: - harness

    private func pump(_ seconds: TimeInterval = 0.005) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    @discardableResult
    private func waitFor(_ timeout: TimeInterval = 60, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            pump()
        }
        return condition()
    }

    private func radial() -> MaskShape {
        .radialGradient(RadialGradientShape(center: NormalizedPoint(0.45, 0.50),
                                            radius: NormalizedPoint(0.26, 0.20), angle: 8))
    }

    /// One mask, selected — what the grips are drawn for.
    @discardableResult
    private func install(_ shape: MaskShape, in session: CatalogSession, feather: Double = 0.5) -> String {
        let id = "m-gate"
        session.applyEdit {
            $0.masks = [Mask(id: id,
                             components: [MaskComponent(id: "c-gate", feather: feather, shape: shape)])]
        }
        session.setSelectedMaskID(id)
        session.commitEdit(label: "新建蒙版")
        return id
    }

    /// A real workspace: the panel, the loupe and the one wire between them
    /// (`InspectorWorkspaceState.onChange` → `setMasksWorkspaceActive`).
    private func makeWorkspace() throws -> (editor: EditorWindowController, loupe: LoupeController,
                                            session: CatalogSession) {
        let editor = try CropUITestSupport.makeEditor(in: workDir)
        let loupe = editor.rootView.loupeController
        windows.append(editor.window!)
        return (editor, loupe, editor.session)
    }

    /// Grips on screen, the chrome up, and a grip to aim at.
    private func openMasksPanel(_ editor: EditorWindowController, _ loupe: LoupeController)
        -> MaskHandlesLayout {
        editor.rootView.inspectorWorkspaces.select(.masks)
        pump(0.02)
        XCTAssertTrue(loupe.masksWorkspaceActive, "the 蒙版 tab must put the chrome up")
        guard let layout = loupe.maskHandlesLayout() else {
            XCTFail("④: no handle layout in the 蒙版 workspace")
            return MaskHandlesLayout()
        }
        return layout
    }

    // MARK: - 1. leaving hides, coming back restores — four workspaces

    func testLeavingTheMaskWorkspaceHidesTheChrome() throws {
        let (editor, loupe, session) = try makeWorkspace()
        defer { editor.window?.orderOut(nil) }
        install(radial(), in: session)

        let before = openMasksPanel(editor, loupe)
        let grip = try XCTUnwrap(before.grips.first { $0.kind == .radialEdge(.right) }?.point,
                                 "no right-rim grip")
        XCTAssertNotEqual(loupe.hitMaskHandle(atViewPoint: grip), nil,
                          "④ the grip must be hittable while the panel is up")
        XCTAssertFalse(loupe.maskHandlesOverlayView.isHidden)
        let frameBefore = loupe.maskHandlesOverlayView.frame

        var rows: [(workspace: String, hidden: Bool, hit: String, updates: Int, gesture: String)] = []
        for workspace in InspectorWorkspace.allCases where workspace != .masks {
            // The panel is up (a switch back re-lays the chrome out — legitimately), so the count for
            // the "away" half starts here, not at the top of the test.
            editor.rootView.inspectorWorkspaces.select(.masks)
            pump(0.02)
            let syncs = loupe.maskOverlaySyncCount

            editor.rootView.inspectorWorkspaces.select(workspace)
            pump(0.02)
            let hit = loupe.hitMaskHandle(atViewPoint: grip)
            let gesture = String(describing: loupe.gestureOwner(atViewPoint: grip))
            rows.append((workspace.rawValue, loupe.maskHandlesOverlayView.isHidden,
                         hit.map(\.label) ?? "nil", loupe.maskOverlaySyncCount - syncs, gesture))

            XCTAssertTrue(loupe.maskHandlesOverlayView.isHidden,
                          "④ \(workspace.rawValue): the grips are still drawn")
            XCTAssertTrue(loupe.maskDraftOverlayView.isHidden,
                          "④ \(workspace.rawValue): the rubber band layer is still up")
            XCTAssertNil(loupe.maskHandlesLayout(),
                         "④ \(workspace.rawValue): a hidden overlay still answers with a layout")
            XCTAssertNil(hit, "④ \(workspace.rawValue): a click on an old grip is still a handle")
            XCTAssertNil(loupe.maskHandlesOverlayView.hitTest(grip),
                         "④ \(workspace.rawValue): the overlay claimed the click")
            XCTAssertNotEqual(gesture, "maskHandle",
                              "④ \(workspace.rawValue): the router still says .maskHandle")
            XCTAssertNil(loupe.maskHandlesLayoutForTesting,
                         "④ \(workspace.rawValue): the overlay still holds a layout")
            XCTAssertEqual(loupe.maskOverlaySyncCount, syncs,
                           "④ \(workspace.rawValue): the overlay updated while hidden")

            // …and the very same panel puts it back, value for value.
            editor.rootView.inspectorWorkspaces.select(.masks)
            pump(0.02)
            XCTAssertFalse(loupe.maskHandlesOverlayView.isHidden)
            XCTAssertEqual(loupe.maskHandlesOverlayView.frame, frameBefore,
                           "④ \(workspace.rawValue): the layer's frame changed across a switch")
            XCTAssertEqual(loupe.maskHandlesLayoutForTesting, before,
                           "④ \(workspace.rawValue): the layout is not bit-for-bit what it was")
            XCTAssertEqual(loupe.hitMaskHandle(atViewPoint: grip), .radialEdge(.right),
                           "④ \(workspace.rawValue): the grip is not hittable again")
        }

        print("④ 切出蒙版工作区 × \(rows.count)")
        for row in rows {
            print("        → \(row.workspace.padding(toLength: 10, withPad: " ", startingAt: 0))"
                  + " isHidden \(row.hidden) · hit \(row.hit) · overlay 更新 +\(row.updates)"
                  + " · gestureOwner \(row.gesture)")
        }
        for row in rows {
            XCTAssertTrue(row.hidden)
            XCTAssertEqual(row.hit, "nil")
            XCTAssertEqual(row.updates, 0, "④ \(row.workspace): the overlay updated while hidden")
        }
    }

    /// The same gate under a **running** animation: the loupe has a real bridge and the panel is
    /// switched away mid-flight. Not one frame may be laid out (「隐藏期间 overlay 更新计数 == 0」),
    /// and every frame that was skipped is counted.
    func testAHiddenOverlayComputesNothingWhileTheZoomAnimationRuns() throws {
        let (loupe, session, window) = try makeLoupeWithFrames()
        defer { window.orderOut(nil) }
        let shape = radial()

        install(shape, in: session)
        loupe.setMasksWorkspaceActive(true)
        loupe.zoom(to: 1, aroundView: CGPoint(x: 160, y: 100))
        XCTAssertTrue(waitFor { loupe.zoomBridge == nil })
        let atRest = try XCTUnwrap(loupe.maskHandlesLayoutForTesting)

        // Away, then the animation.
        loupe.setMasksWorkspaceActive(false)
        let syncs = loupe.maskOverlaySyncCount
        let skips = loupe.maskOverlayHiddenSkips
        let armed = loupe.zoomBridgeArmedCount
        loupe.zoom(to: 0.25, aroundView: nil)
        XCTAssertNotNil(loupe.zoomBridge, "the bridge must run for this measurement")
        XCTAssertTrue(waitFor { loupe.zoomBridge == nil })
        pump(0.05)

        let frames = loupe.maskOverlayFollowFrames.filter { $0.serial == armed + 1 }
        let skipped = loupe.maskOverlayHiddenSkips - skips
        print("④ 隐藏期间跑 1:1 → 25 %：overlay 更新 +\(loupe.maskOverlaySyncCount - syncs)"
              + " · 跳过的几何计算 \(skipped) 次 · 记录的帧 \(frames.count)")
        XCTAssertEqual(loupe.maskOverlaySyncCount, syncs,
                       "④ a hidden overlay computed a layout")
        XCTAssertEqual(frames.count, 0, "④ a hidden overlay recorded a frame")
        XCTAssertGreaterThanOrEqual(skipped, 5, "④ the animation did not even reach the gate")
        XCTAssertNil(loupe.maskHandlesLayoutForTesting)
        XCTAssertTrue(loupe.maskHandlesOverlayView.isHidden)

        // Back: the chrome is the **current** camera's layout (the picture moved to 25 % while it was
        // hidden, so it must not come back with the 1:1 geometry), and every grip is on the picture.
        loupe.setMasksWorkspaceActive(true)
        let back = try XCTUnwrap(loupe.maskHandlesLayoutForTesting,
                                 "④ coming back left the overlay empty")
        let projection = try XCTUnwrap(loupe.maskPictureProjection())
        XCTAssertEqual(projection.carry, .identity, "the animation is over — no carry")
        let source = session.maskSourceSize
        var worst: CGFloat = 0
        for (index, grip) in back.grips.enumerated() {
            let handle = MaskHandles.handles(for: shape, source: source)[index]
            let v = projection.mapping.viewPoint(sourceX: handle.point.x * Double(source.width),
                                                 sourceY: handle.point.y * Double(source.height))
            let want = CGPoint(x: projection.carry.applyX(v.x) / projection.pointScale,
                               y: projection.carry.applyY(v.y) / projection.pointScale)
            worst = max(worst, hypot(grip.point.x - want.x, grip.point.y - want.y))
        }
        print(String(format: "④ 切回后手柄 vs 当前投影 最差 %.5f pt（at rest was %.1f pt off）",
                     worst,
                     hypot(back.grips[0].point.x - atRest.grips[0].point.x,
                           back.grips[0].point.y - atRest.grips[0].point.y)))
        XCTAssertLessThanOrEqual(worst, 0.5)
        XCTAssertNotEqual(back, atRest, "the picture is at 25 % now — the old geometry would be stale")
        XCTAssertEqual(back, loupe.maskHandlesLayout())
    }

    // MARK: - 2. mid-drag, and the panel state that is not a gesture

    func testSwitchingAwayMidDragLeavesTheDocumentAlone() throws {
        let (editor, loupe, session) = try makeWorkspace()
        defer { editor.window?.orderOut(nil) }
        let original = radial()
        install(original, in: session)
        let layout = openMasksPanel(editor, loupe)
        let grip = try XCTUnwrap(layout.grips.first { $0.kind == .radialEdge(.right) }?.point)

        let hashBefore = CropUITestSupport.documentHash(session)
        let historyBefore = session.history.count
        XCTAssertTrue(loupe.beginMaskHandleDrag(atViewPoint: grip), "the grip did not take the press")
        XCTAssertTrue(loupe.isMaskHandleDragging)
        for step in 1...3 {
            loupe.continueMaskHandleDrag(atViewPoint: CGPoint(x: grip.x + 18 * CGFloat(step),
                                                              y: grip.y + 6 * CGFloat(step)))
        }
        XCTAssertNotEqual(CropUITestSupport.documentHash(session), hashBefore,
                          "the live drag must have written the shape (otherwise this proves nothing)")
        XCTAssertEqual(session.history.count, historyBefore, "a live tick commits nothing")

        editor.rootView.inspectorWorkspaces.select(.adjust)
        pump(0.02)

        print("④ 拖动中切走：history \(historyBefore) → \(session.history.count)"
              + " · documentHash 恢复 \(CropUITestSupport.documentHash(session) == hashBefore)"
              + " · draft \(loupe.maskDraftForTesting == nil ? "nil" : "still there")")
        XCTAssertEqual(session.history.count, historyBefore, "④ the switch committed the drag")
        XCTAssertEqual(CropUITestSupport.documentHash(session), hashBefore,
                       "④ the switch left the half-dragged shape in the document")
        XCTAssertFalse(loupe.isMaskHandleDragging, "④ the drag survived the switch")
        XCTAssertNil(loupe.maskDraftForTesting, "④ the rubber band survived the switch")
        XCTAssertNil(loupe.maskHandlesLayoutForTesting)
        if let component = session.edit.masks.first?.components.first {
            XCTAssertEqual(component.shape, original, "④ the shape is not the one at mouse-down")
        } else {
            XCTFail("④ the mask disappeared")
        }
    }

    /// A half-drawn **creation** is dropped, but the panel's armed 新建 is kept: it is the panel's
    /// state, and re-choosing 线性渐变 after a glance at 色彩 would be the annoying behaviour.
    func testSwitchingAwayDropsTheDraftButKeepsTheArmedCreation() throws {
        let (editor, loupe, session) = try makeWorkspace()
        defer { editor.window?.orderOut(nil) }
        editor.rootView.inspectorWorkspaces.select(.masks)
        pump(0.02)
        XCTAssertTrue(session.createMask(.linearGradient) == nil, "a drag-created kind arms, not creates")
        XCTAssertEqual(session.pendingMaskShape, .linearGradient)

        loupe.beginShapeDrag(at: CGPoint(x: 300, y: 300))
        loupe.continueShapeDrag(at: CGPoint(x: 420, y: 380))
        XCTAssertNotNil(loupe.maskDraftForTesting, "the rubber band is not on screen")
        let hash = CropUITestSupport.documentHash(session)
        let depth = session.history.count

        editor.rootView.inspectorWorkspaces.select(.colour)
        pump(0.02)
        print("④ 画到一半切走：draft \(loupe.maskDraftForTesting == nil ? "nil" : "still there")"
              + " · pendingMaskShape \(session.pendingMaskShape?.rawValue ?? "nil")"
              + " · history \(depth) → \(session.history.count)")
        XCTAssertNil(loupe.maskDraftForTesting, "④ the half-drawn band survived the switch")
        XCTAssertEqual(session.pendingMaskShape, .linearGradient,
                       "④ the armed 新建 was cleared by a workspace switch")
        XCTAssertEqual(session.history.count, depth)
        XCTAssertEqual(CropUITestSupport.documentHash(session), hash, "④ a draft wrote to the document")

        // Back in the panel, the very same gesture can be drawn — and it lands.
        editor.rootView.inspectorWorkspaces.select(.masks)
        pump(0.02)
        loupe.beginShapeDrag(at: CGPoint(x: 300, y: 300))
        loupe.continueShapeDrag(at: CGPoint(x: 420, y: 380))
        XCTAssertNotNil(loupe.maskDraftForTesting)
        loupe.endShapeDrag(at: CGPoint(x: 420, y: 380))
        XCTAssertEqual(loupe.shapeDragsCreated, 1, "④ the created mask did not land")
        XCTAssertEqual(session.edit.masks.count, 1)
    }

    // MARK: - 3. the reverse evidence

    /// The pre-④ behaviour — the chrome hidden **only when the picture changes** (a photo switch),
    /// never on the panel's own edge. The new assertion must be red against it: the grips stay drawn
    /// and a click on one is still a `.maskHandle`.
    func testHidingOnlyOnAPhotoSwitchWouldBeRed() throws {
        let (editor, loupe, session) = try makeWorkspace()
        defer { editor.window?.orderOut(nil) }
        install(radial(), in: session)
        let layout = openMasksPanel(editor, loupe)
        let grip = try XCTUnwrap(layout.grips.first { $0.kind == .radialEdge(.right) }?.point)

        // Cut the one wire the fix added: the panel no longer tells the loupe anything.
        editor.rootView.inspectorWorkspaces.onChange = nil
        editor.rootView.inspectorWorkspaces.select(.adjust)
        pump(0.02)

        print("④ 反证（只在切图时隐藏）：isHidden \(loupe.maskHandlesOverlayView.isHidden)"
              + " · hit \(loupe.hitMaskHandle(atViewPoint: grip).map(\.label) ?? "nil")"
              + " · gestureOwner \(loupe.gestureOwner(atViewPoint: grip))")
        XCTAssertFalse(loupe.maskHandlesOverlayView.isHidden,
                       "without the panel edge the overlay stays up — which is the defect")
        XCTAssertNotNil(loupe.hitMaskHandle(atViewPoint: grip),
                        "…and it still eats the click")
    }

    // MARK: - a loupe whose canvas has real pixels (the bridge needs a texture to carry)

    private func makeLoupeWithFrames() throws -> (loupe: LoupeController, session: CatalogSession,
                                                 window: NSWindow) {
        let candidates = [
            ProcessInfo.processInfo.environment["PHOTONS_TEST_RAW"],
            NSString(string: "~/Desktop/test/L1030433.dng").expandingTildeInPath,
        ].compactMap { $0 }
        guard let path = candidates.first(where: { FileManager.default.isReadableFile(atPath: $0) }) else {
            throw XCTSkip("no RAW fixture; set PHOTONS_TEST_RAW")
        }
        let url = URL(fileURLWithPath: path)
        let (session, _) = try CropUITestSupport.makeSession(in: workDir)
        let loupe = LoupeController(session: session)
        loupe.autoRenderEnabled = false
        loupe.collectsHistogram = false
        loupe.reducesMotion = false
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = loupe.view
        loupe.canvasView.frame = window.contentLayoutRect
        windows.append(window)
        window.orderFront(nil)
        loupe.view.layoutSubtreeIfNeeded()
        pump(0.05)
        let deadline = Date().addingTimeInterval(2)
        while session.mode != .loupe || session.anchorAsset == nil, Date() < deadline { pump(0.01) }
        loupe.frameSource = LoupeController.FrameSource(url: url, identity: "mask-gate",
                                                        viewport: Self.viewport, state: .fit)
        loupe.autoRenderEnabled = true
        loupe.scheduleRender()
        XCTAssertTrue(waitFor { loupe.lastFrame != nil }, "no first frame")
        pump(0.1)
        return (loupe, session, window)
    }
}
