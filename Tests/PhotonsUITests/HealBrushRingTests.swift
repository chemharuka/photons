import XCTest
import AppKit
import PhotonsCore
@testable import PhotonsUI

/// 247 — the 修复 brush-size ring: one conversion, three write entries, no side effects.
///
/// The numbers the acceptance is about are the ring's diameter in points and its agreement with the
/// card/keys/wheel. Every projection is the shipped one (`LoupeFraming.mapping`), and every event is
/// sent to the real `LoupeCanvasView`, so the test reads the object the app uses.
@MainActor
final class HealBrushRingTests: XCTestCase {

    private var workDir: URL!
    private var windows: [NSWindow] = []

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-heal-ring-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    // MARK: - harness

    private func makeLoupe() throws -> (loupe: LoupeController, session: CatalogSession) {
        let (session, _) = try CropUITestSupport.makeSession(in: workDir)
        let loupe = LoupeController(session: session)
        loupe.autoRenderEnabled = false
        loupe.collectsHistogram = false
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = loupe.view
        loupe.canvasView.frame = window.contentLayoutRect
        windows.append(window)
        window.orderFront(nil)
        loupe.view.layoutSubtreeIfNeeded()
        CropUITestSupport.pump(0.05)
        return (loupe, session)
    }

    private func centre(_ loupe: LoupeController) -> CGPoint {
        CGPoint(x: loupe.canvasView.bounds.midX, y: loupe.canvasView.bounds.midY)
    }

    /// The diameter the ring *should* have for `radius`, from the same projection the controller
    /// reads: `2 × radius × shortEdge × canvasPerSource / backingScale`.
    private func expectedDiameter(_ loupe: LoupeController, radius: Double) throws -> CGFloat {
        let framing = try XCTUnwrap(loupe.framing())
        let mapping = framing.mapping(of: loupe.viewState)
        let frameSize = ImageSize(width: max(1, Int(mapping.frameWidth.rounded())),
                                  height: max(1, Int(mapping.frameHeight.rounded())))
        let points = BrushRing.radiusInPoints(shortEdgeFraction: radius,
                                              frameSize: frameSize,
                                              mapping: mapping,
                                              backingScale: CGFloat(loupe.backingScale))
        return CGFloat(points * 2)
    }

    private func scrollEvent(deltaY: Int32, options: Bool) throws -> NSEvent {
        let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .line,
                                       wheelCount: 2, wheel1: deltaY, wheel2: 0, wheel3: 0))
        cg.flags = options ? .maskAlternate : []
        let event = try XCTUnwrap(NSEvent(cgEvent: cg))
        XCTAssertEqual(event.modifierFlags.contains(.option), options,
                       "the synthetic scroll event lost its ⌥ flag")
        return event
    }

    private func keyEvent(_ key: String) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0, context: nil,
            characters: key, charactersIgnoringModifiers: key,
            isARepeat: false, keyCode: 0))
    }

    private func decodeTotal() -> Int { RAWDecoder.decodeCounts().values.reduce(0, +) }

    // MARK: - 1. the conversion

    func testRingDiameterIsTwoRadiiOfTheFrameShortEdge() throws {
        let frameSize = ImageSize(width: 6000, height: 4000)
        let backingScale: CGFloat = 2
        var rows: [String] = []

        for zoom in [0.193, 1.0, 2.0] {
            let mapping = LoupeMapping(viewport: ImageSize(width: 1400, height: 1000),
                                       contentWidth: 6000 * zoom,
                                       contentHeight: 4000 * zoom,
                                       cropLeft: 0, cropTop: 0,
                                       cropWidth: 6000, cropHeight: 4000,
                                       cosT: 1, sinT: 0, flipH: false, flipV: false,
                                       frameWidth: 6000, frameHeight: 4000)
            XCTAssertEqual(mapping.canvasPerSource, zoom, accuracy: 1e-12,
                           "the fixture must project at the zoom it names")
            for radius in [0.02, 0.1, 0.5] {
                let device = BrushRing.radiusInDevicePixels(shortEdgeFraction: radius,
                                                            frameSize: frameSize,
                                                            mapping: mapping)
                let points = BrushRing.radiusInPoints(shortEdgeFraction: radius,
                                                      frameSize: frameSize,
                                                      mapping: mapping,
                                                      backingScale: backingScale)
                let expectedDevice = radius * 4000 * zoom
                XCTAssertEqual(device, expectedDevice, accuracy: 1e-9)
                XCTAssertEqual(points * 2, 2 * expectedDevice / Double(backingScale), accuracy: 0.5,
                               "radius=\(radius) zoom=\(zoom) is not the frame-short-edge circle")
                rows.append(String(format: "RING r=%.3f zoom=%.3f d=%.2f px (%.2f pt)",
                                   radius, zoom, 2 * device, 2 * points))
            }
        }
        for row in rows { print(row) }
    }

    // MARK: - 2. hover

    func testHoverShowsTheRingAtTheBrushRadius() throws {
        let (loupe, session) = try makeLoupe()
        session.healTool = true
        session.healRadius = 0.08
        let point = centre(loupe)

        loupe.pointerMoved(to: point)
        CropUITestSupport.pump(0.02)

        XCTAssertTrue(loupe.canvasView.isHealPointerInside)
        XCTAssertTrue(loupe.healRingIsVisible, "修复 打开且指针在画布上时圈必须在")
        XCTAssertEqual(loupe.canvasView.brushRing.ringCenter, point,
                       "圈心跟着指针，差一个点都不对")
        let expected = try expectedDiameter(loupe, radius: session.healRadius)
        XCTAssertEqual(loupe.canvasView.brushRing.ringDiameter, expected, accuracy: 0.5)
        print(String(format: "RING hover r=%.3f center=(%.1f,%.1f) d=%.2f pt expected=%.2f pt",
                     session.healRadius, point.x, point.y,
                     Double(loupe.canvasView.brushRing.ringDiameter), Double(expected)))
    }

    // MARK: - 3. four entries, one value

    func testEachEntryChangesTheSameRadius() throws {
        let (loupe, session) = try makeLoupe()
        session.healTool = true
        session.healRadius = 0.05
        let point = centre(loupe)
        loupe.pointerMoved(to: point)
        let spot = try XCTUnwrap(loupe.addHealSpot(atViewPoint: point))
        XCTAssertEqual(session.selectedHealSpotID, spot.id)

        func radius() throws -> Double {
            try XCTUnwrap(session.edit.healSpots.first { $0.id == spot.id }?.radius)
        }
        func reset() {
            session.setHealRadius(0.05, for: spot.id, commit: false)
            loupe.refreshHealRing()
        }

        var diameters: [String: CGFloat] = [:]

        // ① 直接调用（键盘/滚轮共用的乘数入口）
        loupe.adjustHealRadius(by: 1.1)
        XCTAssertEqual(try radius(), 0.055, accuracy: 1e-9)
        diameters["adjust"] = loupe.canvasView.brushRing.ringDiameter

        // ② 真实 ⌥+滚轮（line 单位：一格 = 1.1×）
        reset()
        loupe.canvasView.scrollWheel(with: try scrollEvent(deltaY: 1, options: true))
        XCTAssertEqual(try radius(), 0.055, accuracy: 1e-9)
        diameters["wheel"] = loupe.canvasView.brushRing.ringDiameter

        // ③ 真实 `]` 键
        reset()
        loupe.canvasView.keyDown(with: try keyEvent("]"))
        XCTAssertEqual(try radius(), 0.055, accuracy: 1e-9)
        diameters["key"] = loupe.canvasView.brushRing.ringDiameter

        // ④ 卡片滑杆走的同一个门
        reset()
        session.setHealRadius(0.055, for: spot.id, commit: false)
        loupe.refreshHealRing()
        diameters["card"] = loupe.canvasView.brushRing.ringDiameter

        let expected = try expectedDiameter(loupe, radius: 0.055)
        for (name, diameter) in diameters.sorted(by: { $0.key < $1.key }) {
            XCTAssertEqual(diameter, expected, accuracy: 0.5,
                           "\(name) 入口的圈直径必须与同一个半径一致")
            print(String(format: "RING entry %@ r=%.3f d=%.2f pt", name, 0.055, Double(diameter)))
        }
        XCTAssertEqual(Set(diameters.values.map { Int(($0 * 100).rounded()) }).count, 1,
                       "四个入口必须落到同一个直径")
    }

    // MARK: - 4. no render / no decode / history rule

    func testChangingTheRadiusDoesNotRenderDecodeOrGrowHistory() throws {
        let (loupe, session) = try makeLoupe()
        session.healTool = true
        session.healRadius = 0.05
        let point = centre(loupe)
        loupe.pointerMoved(to: point)

        // 未选中 spot：改的是“下一个 spot 的默认半径”，只能是视图状态。
        let historyBefore = session.history.count
        let rendersBefore = loupe.editRenderCount
        let decodesBefore = decodeTotal()
        loupe.adjustHealRadius(by: 1.2)
        loupe.adjustHealRadius(by: 1.2)
        loupe.canvasView.scrollWheel(with: try scrollEvent(deltaY: 1, options: true))
        loupe.canvasView.keyDown(with: try keyEvent("["))
        XCTAssertNotEqual(session.healRadius, 0.05, "三个入口都没写进去")
        XCTAssertEqual(session.history.count, historyBefore, "未选中时改默认半径不进历史")
        XCTAssertEqual(loupe.editRenderCount, rendersBefore, "未选中时改默认半径不触发渲染")
        XCTAssertEqual(decodeTotal(), decodesBefore, "未选中时改默认半径不解码")

        // 选中 spot：拖动式调整只落一行。
        let spot = try XCTUnwrap(loupe.addHealSpot(atViewPoint: point))
        XCTAssertEqual(session.selectedHealSpotID, spot.id)
        let afterAdd = session.history.count
        for _ in 0..<3 { loupe.adjustHealRadius(by: 1.1) }
        XCTAssertEqual(session.history.count, afterAdd + 1,
                       "选中 spot 的滚轮/键盘一次手势 = 一行历史")
        XCTAssertEqual(loupe.editRenderCount, rendersBefore, "圈与调半径都不触发渲染")
        XCTAssertEqual(decodeTotal(), decodesBefore, "圈与调半径都不解码")
        print("RING side-effect · history \(historyBefore) → \(session.history.count) · "
              + "render \(rendersBefore) → \(loupe.editRenderCount) · "
              + "decode \(decodesBefore) → \(decodeTotal())")
    }

    // MARK: - 5. the click keeps it and the tool takes it away

    func testTheRingSurvivesTheClickAndDisappearsWithTheTool() throws {
        let (loupe, session) = try makeLoupe()
        session.healTool = true
        session.healRadius = 0.07
        let point = centre(loupe)
        loupe.pointerMoved(to: point)

        let spot = try XCTUnwrap(loupe.addHealSpot(atViewPoint: point))
        XCTAssertTrue(loupe.healRingIsVisible, "落点之后圈必须还在（半径变成新 spot 的）")
        XCTAssertEqual(loupe.canvasView.brushRing.ringDiameter,
                       try expectedDiameter(loupe, radius: spot.radius), accuracy: 0.5)

        session.healTool = false
        XCTAssertFalse(loupe.healRingIsVisible, "切走修复工具，圈立即消失")
        XCTAssertTrue(loupe.canvasView.brushRing.isHidden)
        let diameter = try expectedDiameter(loupe, radius: spot.radius)
        print(String(format: "RING tool off · d(before)=%.2f pt hidden=%@",
                     Double(diameter),
                     loupe.canvasView.brushRing.isHidden ? "true" : "false"))
    }
}
