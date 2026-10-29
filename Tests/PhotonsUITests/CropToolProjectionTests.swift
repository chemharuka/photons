import XCTest
import AppKit
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// The four things the crop tool's **projection** has to be, asserted where a user could see them.
///
/// The 19 cases in `CropToolTests` all drive `CropToolController` (or `loupe.cropTool.begin()`), i.e.
/// they never asked whether the frame is a rectangle on screen, whether the projection is a similarity,
/// or whether the overlay is on a view at all — which is how a sheared, rotating frame shipped.
@MainActor
final class CropToolProjectionTests: XCTestCase {

    private let landscape = ImageSize(width: 1200, height: 800)
    private let portrait = ImageSize(width: 800, height: 1200)

    private func mapping(source: ImageSize, viewport: ImageSize? = nil, degrees: Double,
                         crop: CropRect = .full) -> LoupeMapping {
        LoupeFraming(viewport: viewport ?? source,
                     sourceWidth: Double(source.width), sourceHeight: Double(source.height),
                     crop: crop, straightenDegrees: degrees).mapping(of: .fit)
    }

    /// The linear part of `view → source`, sampled with 1 px steps (the basis of the affine map).
    private func basis(_ m: LoupeMapping) -> (e1: (Double, Double), e2: (Double, Double)) {
        let o = m.sourcePoint(viewX: 0, viewY: 0)
        let dx = m.sourcePoint(viewX: 1, viewY: 0)
        let dy = m.sourcePoint(viewX: 0, viewY: 1)
        return ((dx.x - o.x, dx.y - o.y), (dy.x - o.x, dy.y - o.y))
    }

    // MARK: 1. the projection is a similarity (rotation + uniform scale), never a shear

    /// A straightened picture is **turned**, not tapered: `|e1| == |e2|` and `e1 ⟂ e2`.
    ///
    /// Baseline (73eca0b) fails both: at 9° on 1200×800 the basis came out (0.993179, 1.015180) with
    /// `cos = −0.1277`; at 45° the ratio was 1.5 and `cos = −0.3846` — the frame's W/H, because the
    /// rotation was applied to per-axis-normalised coordinates.
    func testStraightenIsASimilarityNotAShear() {
        for (name, source) in [("landscape", landscape), ("portrait", portrait)] {
            for degrees in [9.0, 45.0, -12.5] {
                let m = mapping(source: source, degrees: degrees)
                let b = basis(m)
                let l1 = (b.e1.0 * b.e1.0 + b.e1.1 * b.e1.1).squareRoot()
                let l2 = (b.e2.0 * b.e2.0 + b.e2.1 * b.e2.1).squareRoot()
                let dot = b.e1.0 * b.e2.0 + b.e1.1 * b.e2.1
                let cos = dot / (l1 * l2)
                print(String(format: "PROJ %@ %.1f° |e1|=%.6f |e2|=%.6f cos=%.9f",
                             name, degrees, l1, l2, cos))
                XCTAssertEqual(l2 / l1, 1, accuracy: 1e-9,
                               "\(name) \(degrees)°: the two axes must scale alike (no taper)")
                XCTAssertEqual(cos, 0, accuracy: 1e-9,
                               "\(name) \(degrees)°: the basis must stay orthogonal (no shear)")
                XCTAssertGreaterThan(b.e1.0 * b.e2.1 - b.e1.1 * b.e2.0, 0,
                                     "and the map keeps its orientation")
            }
        }
    }

    /// The picture really is turned by the document's angle — the tool's readout and the pixels agree.
    func testTheScreenAngleIsTheDocumentAngle() {
        let m = mapping(source: landscape, degrees: 9)
        let b = basis(m)
        let angle = atan2(b.e1.1, b.e1.0) * 180 / .pi
        // y is down on the canvas, so a positive document angle reads as a positive screen angle here.
        XCTAssertEqual(angle, 9, accuracy: 1e-6)
    }

    // MARK: 2. the crop frame stays an axis-aligned rectangle, whatever the straighten

    /// The eight grips are drawn from `CropTool.layout`, which must **not** inherit the picture's
    /// rotation: the frame is a window and the photo turns under it.
    ///
    /// Baseline fails loudly: at 9° the four corners formed a parallelogram — top `(592.61, −50.06)`,
    /// left `(93.86, 316.06)`, `dot = 39801`.
    func testTheCropFrameIsAxisAlignedAtEveryStraighten() {
        let crop = CropRect(x: 0.1, y: 0.2, width: 0.5, height: 0.4)
        for degrees in [0.0, 9.0, 45.0, -30.0] {
            let m = mapping(source: landscape, degrees: degrees, crop: crop)
            let layout = CropTool.layout(crop: crop, source: landscape, mapping: m,
                                         pointScale: 1, showsGrid: true)
            let c = layout.corners
            let top = (c[1].x - c[0].x, c[1].y - c[0].y)
            let left = (c[3].x - c[0].x, c[3].y - c[0].y)

            XCTAssertEqual(top.1, 0, accuracy: 1e-9, "\(degrees)°: the top edge is horizontal")
            XCTAssertEqual(left.0, 0, accuracy: 1e-9, "\(degrees)°: the left edge is vertical")
            XCTAssertEqual(top.0 * left.0 + top.1 * left.1, 0, accuracy: 1e-9,
                           "\(degrees)°: the frame's sides are perpendicular")

            // On-screen aspect = the crop's own pixel aspect (portrait must not be transposed).
            let cropW = crop.width * Double(landscape.width)
            let cropH = crop.height * Double(landscape.height)
            XCTAssertEqual(abs(top.0) / abs(left.1), cropW / cropH, accuracy: 1e-9)

            // The grips sit on the frame's own edges, not somewhere the picture dragged them.
            for grip in layout.grips {
                let onVertical = [c[0].x, c[1].x].contains { abs(grip.point.x - $0) < 1e-9 }
                let onHorizontal = [c[0].y, c[3].y].contains { abs(grip.point.y - $0) < 1e-9 }
                XCTAssertTrue(onVertical || onHorizontal, "\(grip.kind) leaves the frame at \(degrees)°")
            }
        }
    }

    /// The same claim for a portrait frame: 9° must not swap the axes or shear the other way.
    func testAPortraitFrameKeepsItsOwnAspectWhenStraightened() {
        let crop = CropRect(x: 0.15, y: 0.1, width: 0.5, height: 0.6)
        let m = mapping(source: portrait, degrees: 9, crop: crop)
        let layout = CropTool.layout(crop: crop, source: portrait, mapping: m, pointScale: 1)
        let c = layout.corners
        let w = abs(c[1].x - c[0].x), h = abs(c[3].y - c[0].y)
        XCTAssertEqual(h / w, (crop.height * 1200) / (crop.width * 800), accuracy: 1e-9,
                       "a portrait frame is tall on screen, not transposed")
        // 132: 适应 fits the *rotated whole frame* into the viewport, so the crop's on-screen width
        // is its pixel width × that zoom. The pre-132 assertion wrote `× (800/800)` — i.e. zoom = 1,
        // which is no longer the fit at 9° (it is 0.8181 → 327.24 px, not 400).
        let theta = 9.0 * .pi / 180
        let frameW = 800 * cos(theta) + 1200 * sin(theta)
        let frameH = 800 * sin(theta) + 1200 * cos(theta)
        let fitZoom = min(800 / frameW, 1200 / frameH)
        XCTAssertEqual(w, crop.width * 800 * fitZoom, accuracy: 1e-6)
    }

    // MARK: 3. a drag inside the frame follows the hand (same sign, same distance)

    /// 100 pt in each direction: the rect moves **with** the pointer. Baseline moves it against
    /// (`base.left - dx`), which is the 「方向反了」 report.
    func testDraggingInsideMovesTheFrameWithTheHand() {
        let source = landscape
        let viewport = ImageSize(width: 1200, height: 800)
        let m = mapping(source: source, viewport: viewport, degrees: 0)
        let start = CropRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4)
        let grab = CropToolController.normalized(CGPoint(x: 600, y: 400), mapping: m,
                                                 source: source, pointScale: 1)!
        let drag = CropToolDrag(handle: .inside, crop: start, grab: grab)
        let pxPerNorm = Double(source.width)   // view px == source px at this mapping

        for (name, dx, dy) in [("right", 100.0, 0.0), ("left", -100.0, 0.0),
                               ("down", 0.0, 100.0), ("up", 0.0, -100.0)] {
            let moved = CropToolController.normalized(CGPoint(x: 600 + dx, y: 400 + dy), mapping: m,
                                                      source: source, pointScale: 1)!
            let next = drag.crop(at: moved, source: source)
            let dLeft = (next.left - start.left) * pxPerNorm
            let dTop = (next.top - start.top) * Double(source.height)
            print(String(format: "PROJ drag %@ → dLeft=%+.2f dTop=%+.2f", name, dLeft, dTop))
            XCTAssertEqual(dLeft, dx, accuracy: 1e-6, "\(name): the frame follows the hand in x")
            XCTAssertEqual(dTop, dy, accuracy: 1e-6, "\(name): and in y")
        }

        // The inverse of the fix (the old `-dx`) must be visibly wrong — this is the guard against
        // somebody "restoring" the sign.
        let movedLeft = CropToolController.normalized(CGPoint(x: 500, y: 400), mapping: m,
                                                     source: source, pointScale: 1)!
        let withHand = drag.crop(at: movedLeft, source: source)
        XCTAssertLessThan(withHand.left, start.left, "a left drag moves the frame left")
        XCTAssertNotEqual(withHand.left, start.left + (grab.x - movedLeft.x), accuracy: 1e-12,
                          "and never back to the old opposite-sign answer")
    }

    // MARK: 4. the overlay is mounted, visible, and above the picture

    /// ⌘R has to put something on screen. Baseline has no test for it at all, and this is the claim
    /// the user's 「完全看不到」 is about: `superview` non-nil, not hidden, non-zero frame, finite
    /// corners, and the overlay ordered **above** the canvas.
    func testEnteringCropMountsAVisibleOverlayAboveTheCanvas() throws {
        _ = NSApplication.shared
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cropproj-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let package = dir.appendingPathComponent("Spec.\(LibraryLayout.packageExtension)")
        let catalog = try Catalog.create(at: package)
        let src = dir.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let root = try catalog.ensureRoot(for: src, mode: .reference)
        try Data([0x00]).write(to: src.appendingPathComponent("L1030433.dng"))
        let id = UUID().uuidString
        try catalog.dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO assets (id, source_root_id, rel_path, filename, ext, kind, size, mtime,
                                    content_hash, width, height, camera_make, camera_model, lens,
                                    imported_at, missing)
                VALUES ('\(id)', '\(root.id)', 'L1030433.dng', 'L1030433.dng', 'dng', 'raw', 1, 0,
                        '\(UUID().uuidString)', 1200, 800, 'L', 'M', 'X',
                        '2026-10-27T00:00:00Z', 0)
                """)
        }
        let session = CatalogSession()
        try session.open(package)
        session.selectOnly(id)
        session.mode = .loupe
        let loupe = LoupeController(session: session)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = loupe.view
        window.setContentSize(NSSize(width: 1000, height: 700))
        window.layoutIfNeeded()
        defer { window.contentView = nil }

        XCTAssertTrue(loupe.beginCropTool(), "⌘R enters the tool with a photo on screen")

        var overlay: CropToolOverlayView?
        func walk(_ v: NSView) {
            if let o = v as? CropToolOverlayView { overlay = o }
            v.subviews.forEach(walk)
        }
        walk(loupe.view)
        let found = try XCTUnwrap(overlay, "the crop overlay is in the loupe's view tree")
        XCTAssertNotNil(found.superview, "and it has a superview to be drawn in")
        XCTAssertFalse(found.isHidden, "and it is visible")
        XCTAssertGreaterThan(found.frame.width, 1)
        XCTAssertGreaterThan(found.frame.height, 1)
        XCTAssertFalse(loupe.cropBar.isHidden, "the 裁切 bar is visible too")
        XCTAssertGreaterThan(loupe.cropBar.frame.width, 1)

        let layout = try XCTUnwrap(found.layout ?? loupe.cropToolLayout())
        XCTAssertEqual(layout.corners.count, 4)
        for c in layout.corners {
            XCTAssertTrue(c.x.isFinite && c.y.isFinite, "finite corners, or nothing is drawn")
        }
        // Above the picture: the canvas is the first subview, the overlay comes later.
        let siblings = found.superview!.subviews
        let canvasIndex = try XCTUnwrap(siblings.firstIndex { $0 is LoupeCanvasView })
        let overlayIndex = try XCTUnwrap(siblings.firstIndex { $0 === found })
        XCTAssertGreaterThan(overlayIndex, canvasIndex, "the frame is drawn over the photograph")

        // And it goes away with the tool.
        loupe.cancelCropTool()
        XCTAssertTrue(found.isHidden)
    }
}
