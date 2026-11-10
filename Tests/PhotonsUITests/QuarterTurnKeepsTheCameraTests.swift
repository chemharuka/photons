import XCTest
import AppKit
import PhotonsCore
import PhotonsCatalog
@testable import PhotonsUI

/// 2026-11-02 — 「旋转之后照片被推到左边、右边纯黑，缩放一下才对」.
///
/// The document's quarter turn renames the photograph's two axes. The camera's window centre is stored
/// in **those** pixels, so a turn that leaves the number alone points the window at a different part of
/// the photograph: at a zoom the picture sits off-centre and the part of the canvas that is no longer
/// covered by a frame is painted as matte (`#0F0F0F`) — read as 「纯黑遮罩」. `⌘0` recomputed the centre
/// from the crop, which is why a zoom looked like the thing that 「fixed」 the render.
///
/// The rule pinned here: the centre turns **with** the picture, and a centre that was the photograph's
/// own centre stays the centre.
@MainActor
final class QuarterTurnKeepsTheCameraTests: XCTestCase {

    private var workDir: URL!
    private var windows: [NSWindow] = []
    /// `LoupeController.session` is **weak**: a session that only the local helper holds is deallocated
    /// the moment the helper returns, and every camera command then silently no-ops. The test owns it.
    private var session: CatalogSession?

    override func setUpWithError() throws {
        _ = NSApplication.shared
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-quarter-camera-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    private func pump(_ seconds: TimeInterval = 0.005) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// A library that **references the real fixture** (a symlink in a temp folder), so the loupe's own
    /// ladder decodes real pixels for a real catalog session — the same shape `RotateRenderProbeTests`
    /// uses. A synthetic row would leave `maskSourceSize` at 1 × 1 and the camera would have nothing to
    /// be a camera *of*.
    private func makeLoupe() throws -> LoupeController {
        guard let raw = [
            ProcessInfo.processInfo.environment["PHOTONS_TEST_RAW"],
            NSString(string: "~/Desktop/test/L1030433.dng").expandingTildeInPath,
        ].compactMap({ $0 }).first(where: { FileManager.default.isReadableFile(atPath: $0) }) else {
            throw XCTSkip("no RAW fixture; set PHOTONS_TEST_RAW")
        }
        let folder = workDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let package = folder.appendingPathComponent("Q.\(LibraryLayout.packageExtension)")
        let catalog = try Catalog.create(at: package)
        let src = folder.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let name = URL(fileURLWithPath: raw).lastPathComponent
        let link = src.appendingPathComponent(name)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: raw))
        let root = try catalog.ensureRoot(for: src, mode: .reference)
        let id = UUID().uuidString
        try catalog.dbQueue.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO assets (id, source_root_id, rel_path, filename, ext, kind, size, mtime,
                                    content_hash, width, height, camera_make, camera_model, lens,
                                    imported_at, missing)
                VALUES ('\(id)', '\(root.id)', '\(name)', '\(name)', 'dng', 'raw', 1, 0,
                        '\(UUID().uuidString)', 9520, 6336,
                        'Leica Camera AG', 'Leica SL3', 'Vario-Elmarit-SL 24-90',
                        '2026-11-02T00:00:00Z', 0)
                """)
        }
        let session = CatalogSession()
        self.session = session
        let loupe = LoupeController(session: session)
        loupe.collectsHistogram = false
        let window = TestWindows.make(contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = loupe.view
        loupe.canvasView.frame = window.contentLayoutRect
        windows.append(window)
        TestWindows.show(window)
        loupe.view.layoutSubtreeIfNeeded()
        pump(0.05)
        try session.open(package)
        session.selectOnly(id)
        session.mode = .loupe
        session.loadEditForAnchor()
        let deadline = Date().addingTimeInterval(5)
        while (session.anchorAsset == nil || loupe.cropSourceSize.width <= 1), Date() < deadline {
            pump(0.01)
        }
        XCTAssertEqual(loupe.framing()?.sourceWidth ?? 0, 9520,
                       "the fixture is the upright Leica frame (full pixels)")
        // One settled frame, so the canvas really has a projection to zoom (the probe harness this
        // shape comes from waits for it, and without it the camera commands below are no-ops).
        loupe.scheduleRender()
        let end = Date().addingTimeInterval(60)
        while loupe.lastFrame == nil, Date() < end { pump(0.01) }
        XCTAssertNotNil(loupe.lastFrame, "首帧没到，画布没有投影")
        pump(0.1)
        return loupe
    }

    /// Upright `9520 × 6336` (the fixture every crop suite uses) at 1:1, with the camera **panned off**
    /// the centre through the shipped gesture, so the assertions below are about a camera the app could
    /// really be holding.
    /// The turned frame in the **same unit as `viewState`** — `LoupeFraming.sourceWidth/Height`, i.e.
    /// full-resolution pixels. `cropSourceSize` is the decoded grid (half of these at the 0.5 rung),
    /// which is why the tests read the framing and not that readout.
    private func frameSize(_ loupe: LoupeController) -> ImageSize {
        guard let framing = loupe.framing() else { return ImageSize(width: 0, height: 0) }
        return ImageSize(width: Int(framing.sourceWidth.rounded()),
                         height: Int(framing.sourceHeight.rounded()))
    }

    private func zoomedLoupe(pannedBy delta: CGSize = CGSize(width: 240, height: 120))
        throws -> (loupe: LoupeController, centre: (x: Double, y: Double)) {
        let loupe = try makeLoupe()
        print("⌘] · before zoom: framing=\(loupe.framing() != nil)")
        loupe.zoom(to: 0.5)
        pump(0.05)
        print("⌘] · 缩放后 state=(mode \(loupe.viewState.mode) zoom \(loupe.viewState.zoom) "
              + "centre \(loupe.viewState.centerX),\(loupe.viewState.centerY)) cropSource=\(loupe.cropSourceSize)")
        loupe.panImage(byPoints: delta)
        pump(0.05)
        XCTAssertEqual(loupe.viewState.mode, .actual, "测试需要一台实际像素相机")
        let centre = (loupe.viewState.centerX, loupe.viewState.centerY)
        XCTAssertNotEqual(centre.0, 4760, "相机必须偏离照片中心，否则测不出搬移")
        print("⌘] · 起始 centre = (\(centre.0), \(centre.1))")
        return (loupe, centre)
    }

    /// ⌘] : `(x, y) ↦ (H − y, x)`, with `H` the height of the frame the camera was measured in
    /// (6336 upright → 9520 after the turn).
    func testAClockwiseTurnCarriesTheCameraCentre() throws {
        let (loupe, centre) = try zoomedLoupe()
        XCTAssertEqual(frameSize(loupe), ImageSize(width: 9520, height: 6336))

        XCTAssertTrue(loupe.rotateQuarterClockwise())
        pump(0.05)

        XCTAssertEqual(frameSize(loupe), ImageSize(width: 6336, height: 9520))
        XCTAssertEqual(loupe.viewState.centerX, 6336 - centre.y, accuracy: 1e-9, "H − y")
        XCTAssertEqual(loupe.viewState.centerY, centre.x, accuracy: 1e-9, "x")
        print("⌘] · centre (\(centre.0),\(centre.1)) → (\(loupe.viewState.centerX),\(loupe.viewState.centerY))")
    }

    /// ⌘[ is the inverse walk, so a clockwise turn followed by a counter-clockwise one is the identity
    /// on the camera as well as on the geometry.
    func testTheTwoTurnsAreInverseForTheCameraToo() throws {
        let (loupe, centre) = try zoomedLoupe()
        XCTAssertTrue(loupe.rotateQuarterCounterClockwise())
        pump(0.05)
        XCTAssertEqual(loupe.viewState.centerX, centre.y, accuracy: 1e-9, "y")
        XCTAssertEqual(loupe.viewState.centerY, 9520 - centre.x, accuracy: 1e-9, "W − x")

        XCTAssertTrue(loupe.rotateQuarterClockwise())
        pump(0.05)
        XCTAssertEqual(loupe.viewState.centerX, centre.x, accuracy: 1e-9)
        XCTAssertEqual(loupe.viewState.centerY, centre.y, accuracy: 1e-9)
        XCTAssertEqual(frameSize(loupe), ImageSize(width: 9520, height: 6336))
    }

    /// The camera on the photograph's own centre stays on it — that is the user-visible case: the
    /// picture must not jump when it is turned.
    func testThePhotographCentreStaysTheCentre() throws {
        let loupe = try makeLoupe()
        loupe.zoom(to: 0.5)
        pump(0.05)
        XCTAssertEqual(loupe.viewState.mode, .actual)
        XCTAssertEqual(loupe.viewState.centerX, 4760, accuracy: 1e-9)
        XCTAssertEqual(loupe.viewState.centerY, 3168, accuracy: 1e-9)
        XCTAssertTrue(loupe.rotateQuarterClockwise())
        pump(0.05)
        XCTAssertEqual(loupe.viewState.centerX, 3168, accuracy: 1e-9)
        XCTAssertEqual(loupe.viewState.centerY, 4760, accuracy: 1e-9)
        XCTAssertEqual(loupe.framing()?.cropOriginX ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(loupe.framing()?.cropOriginY ?? -1, 0, accuracy: 1e-9)
    }

    /// 适应 derives its centre from the crop every time, so the stored number (if any) is not the
    /// camera — nothing to move, and the turn must not invent a zoom.
    func testAFitCameraIsNotForcedIntoAnActualOne() throws {
        let loupe = try makeLoupe()
        loupe.zoomToFit()
        pump(0.05)
        let mode = loupe.viewState.mode
        XCTAssertNotEqual(mode, .actual)
        XCTAssertTrue(loupe.rotateQuarterClockwise())
        pump(0.05)
        XCTAssertEqual(loupe.viewState.mode, mode, "转 90° 不许把适应变成实际像素")
    }
}
