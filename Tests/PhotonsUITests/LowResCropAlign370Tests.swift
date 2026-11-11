import XCTest
import AppKit
import ImageIO
import Metal
import PhotonsCatalog
@testable import PhotonsCore
@testable import PhotonsUI

/// 370 — 裁切后缩放：低清全尺寸预览必须跟着裁切，遮罩边与画面边不能错位.
///
/// The user's geometry is **旋转 + 透视校正 + 裁切**. Since 330 an applied crop is a rectangle of
/// the **document canvas** (`cropSpace == .canvas`), but `LoupeFraming` divided every crop metric by
/// the *turned source* size and handed the crop to `FrameTransform` as `.source`. On the 9520×6336
/// fixture a 9° / +60 keystone / 20 % crop gave a settled backdrop `region` of `1.33…2.33` instead of
/// `0…1`: the low-res texture was sampled past the picture (clamped), so the matte's inner edge and
/// the photograph's edge no longer met — exactly 「低清全尺寸预览没有相应的裁切」.
///
/// This suite measures the four edges of the photograph **as the transition draws them** (the quad
/// `FrameTransform.frameQuadInS5` reports, not its bounding box) against the edges the low-res layer
/// is sampled with (`FramePlacement` → `PresentWindow.onWholePicture`), at progress 0.25 / 0.5 / 0.75
/// of the 1:1 → 适应 crossing. The reverse gate (`LoupeFraming.readsCanvasCropAsSource`) restores the
/// pre-370 arithmetic and must turn the same numbers red.
@MainActor
final class LowResCropAlign370Tests: XCTestCase {

    private static let viewport = ImageSize(width: 2044, height: 1636)
    private static let source = ImageSize(width: 9520, height: 6336)
    private static let crop20 = CropRect(x: 0.40, y: 0.40, width: 0.20, height: 0.20)
    private static let crop60 = CropRect(x: 0.20, y: 0.20, width: 0.60, height: 0.60)
    private static let tolerance: Double = 0.5

    private static let steps: [(name: String, v: Double, degrees: Double, crop: CropRect)] = [
        ("θ=9° v=0 crop20", 0, 9, crop20),
        ("θ=0 v=+60 crop20", 60, 0, crop20),
        ("θ=9° v=+60 crop20", 60, 9, crop20),
        ("θ=9° v=+60 crop60", 60, 9, crop60),
    ]

    private var workDir: URL!
    private var windows: [NSWindow] = []

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-370-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        LoupeFraming.readsCanvasCropAsSource = false
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
        workDir = nil
    }

    private func note(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    private func document(_ step: (name: String, v: Double, degrees: Double, crop: CropRect))
        -> EditModel {
        var edit = EditModel.neutral
        edit.geometry.crop = step.crop.normalizedRect
        edit.geometry.cropSpace = .canvas
        edit.geometry.aspectLock = .original
        edit.geometry.perspectiveVertical = step.v
        edit.geometry.perspectiveHorizontal = 0
        edit.geometry.rotationDegrees = step.degrees
        return edit
    }

    // MARK: - the four edges of a quad

    private struct Edges {
        var left, top, right, bottom: Double

        static func of(_ quad: [SIMD2<Double>]) -> Edges {
            let xs = quad.map { $0.x }, ys = quad.map { $0.y }
            return Edges(left: xs.min() ?? 0, top: ys.min() ?? 0,
                         right: xs.max() ?? 0, bottom: ys.max() ?? 0)
        }

        func worstDelta(_ other: Edges) -> Double {
            max(abs(left - other.left), abs(top - other.top),
                abs(right - other.right), abs(bottom - other.bottom))
        }

        var text: String { String(format: "l %.2f t %.2f r %.2f b %.2f", left, top, right, bottom) }
    }

    /// The final similarity the bridge lands on, inverted: a point in the **target** canvas as it was
    /// in the **from** canvas.
    private func fromCamera(_ quad: [SIMD2<Double>], bridge: LoupeZoomBridge) -> [SIMD2<Double>] {
        let end = bridge.map(atProgress: 1)
        let scale = abs(end.scale) > 1e-12 ? end.scale : 1
        return quad.map { SIMD2(($0.x - end.x) / scale, ($0.y - end.y) / scale) }
    }

    private func corners(_ rect: CGRect) -> [SIMD2<Double>] {
        [SIMD2(rect.minX, rect.minY), SIMD2(rect.maxX, rect.minY),
         SIMD2(rect.maxX, rect.maxY), SIMD2(rect.minX, rect.maxY)]
    }

    private func projected(_ quad: [SIMD2<Double>], bridge: LoupeZoomBridge,
                           progress: Double) -> [SIMD2<Double>] {
        quad.map { SIMD2(bridge.canvasPoint(atProgress: progress, of: ($0.x, $0.y)).x,
                         bridge.canvasPoint(atProgress: progress, of: ($0.x, $0.y)).y) }
    }

    /// Where the low-res picture (its whole texture, `0…1`) lands on the canvas through the window the
    /// backdrop is sampled with.
    private func lowResQuad(_ window: PresentWindow, canvas: ImageSize) -> [SIMD2<Double>] {
        guard let r = window.canvasRect(ofTexture: 0, 0, 1, 1) else { return [] }
        let cw = Double(max(canvas.width, 1)), ch = Double(max(canvas.height, 1))
        return [SIMD2(r.x * cw, r.y * ch), SIMD2((r.x + r.width) * cw, r.y * ch),
                SIMD2((r.x + r.width) * cw, (r.y + r.height) * ch), SIMD2(r.x * cw, (r.y + r.height) * ch)]
    }

    // MARK: - ① / ③ the measurement (pure geometry, no drawable)

    /// For each document, the low-res layer's four edges at progress 0.25 / 0.5 / 0.75 must be the
    /// photograph's four edges carried by the bridge's own similarity, and at progress 1 they must be
    /// the settled fit frame's quad — bit-for-bit the geometry the camera reports.
    func testTheTransitionLowResEdgesSitOnThePhotographQuad() throws {
        for step in Self.steps {
            let edit = document(step)
            let framing = try XCTUnwrap(LoupeFraming(viewport: Self.viewport, decoded: Self.source,
                                                     decodeScale: 1, edit: edit,
                                                     canvasRole: .export),
                                        "\(step.name): no framing")
            let centre = framing.windowCenter(of: .fit)
            let actual = LoupeViewState(mode: .actual, zoom: 1,
                                        centerX: centre.x, centerY: centre.y)
            let fit = LoupeViewState.fit
            let actualMapping = framing.mapping(of: actual)
            let fitMapping = framing.mapping(of: fit)
            // The rendered photograph's rect in device pixels (364's one walk; `frameQuadInS5` is the
            // crop tool's un-turned frame, not what the pixels are). The export canvas is a rectangle,
            // so its four edges are the four sides.
            let fromQuad = corners(try XCTUnwrap(actualMapping.transform?.frameRectInS5(),
                                                 "\(step.name): no transform"))
            let fitQuad = corners(try XCTUnwrap(fitMapping.transform?.frameRectInS5(),
                                                "\(step.name): no transform"))
            let placement = framing.framePlacement(of: actualMapping)
            note(String(format: "370 · %@ · actual region %@ · fit region %@",
                        step.name,
                        String(format: "%.4f…%.4f / %.4f…%.4f", placement.region.left,
                               placement.region.right, placement.region.top, placement.region.bottom),
                        String(format: "%.4f…%.4f / %.4f…%.4f",
                               framing.framePlacement(of: fitMapping).region.left,
                               framing.framePlacement(of: fitMapping).region.right,
                               framing.framePlacement(of: fitMapping).region.top,
                               framing.framePlacement(of: fitMapping).region.bottom)))

            let bridge = LoupeZoomBridge(fromContent: framing.contentPixels(of: actual),
                                         toContent: framing.contentPixels(of: fit),
                                         fromMapping: actualMapping, toMapping: fitMapping,
                                         canvas: Self.viewport, anchor: .center)
            note("370 rects · \(step.name) · actual \(Edges.of(fromQuad).text) · fit \(Edges.of(fitQuad).text) · bridge scale \(bridge.scale)")
            // The whole picture under the *from* camera: the settled fit rect un-mapped by the
            // bridge's final similarity. (Projecting the from quad itself would apply the map twice.)
            let fromCameraQuad = fromCamera(fitQuad, bridge: bridge)

            var worst = 0.0
            for t in [0.25, 0.5, 0.75] {
                let window = bridge.window(atProgress: t, textureSize: Self.viewport)
                let back = window.onWholePicture(placement)
                let low = Edges.of(lowResQuad(back, canvas: Self.viewport))
                let expected = Edges.of(projected(fromCameraQuad, bridge: bridge, progress: t))
                let delta = low.worstDelta(expected)
                worst = max(worst, delta)
                note(String(format: "370 · %@ · t %.2f · photo %@ · low %@ · Δ %.2f px",
                            step.name, t, expected.text, low.text, delta))
            }
            XCTAssertLessThanOrEqual(worst, Self.tolerance,
                                     "\(step.name): the low-res edges left the photograph's quad")

            // ③ the end of the transition must be the *settled* fit geometry, not merely close to it.
            let endWindow = bridge.window(atProgress: 1, textureSize: Self.viewport)
            let endLow = Edges.of(lowResQuad(endWindow.onWholePicture(placement),
                                             canvas: Self.viewport))
            let settled = Edges.of(fitQuad)
            note(String(format: "370 · %@ · settled %@ · low@1 %@ · Δ %.2f px",
                        step.name, settled.text, endLow.text, settled.worstDelta(endLow)))
            XCTAssertLessThanOrEqual(settled.worstDelta(endLow), Self.tolerance,
                                     "\(step.name): transition end ≠ settled picture rect")
        }
    }

    /// The settled `region` is the whole picture: `0…1` in picture coordinates. This is the number the
    /// pre-370 walk got wrong (`1.33…2.33` on the 9° / +60 / 20 % document), which is why the low-res
    /// texture was read past its own edge.
    func testTheSettledPlacementRegionIsTheWholePicture() throws {
        for step in Self.steps {
            let framing = try XCTUnwrap(LoupeFraming(viewport: Self.viewport, decoded: Self.source,
                                                     decodeScale: 1, edit: document(step),
                                                     canvasRole: .export))
            let region = framing.framePlacement(of: framing.mapping(of: .fit)).region
            let picturePixels = framing.rotatedCropExtent.width
            let p0 = max(abs(region.left) * Double(framing.viewport.width), abs(region.top) * Double(framing.viewport.height))
            let p1 = max(abs(region.right - 1) * Double(framing.viewport.width),
                         abs(region.bottom - 1) * Double(framing.viewport.height))
            note(String(format: "370 settled · %@ · region %.4f…%.4f / %.4f…%.4f · edge Δ %.2f / %.2f px",
                        step.name, region.left, region.right, region.top, region.bottom, p0, p1))
            XCTAssertLessThanOrEqual(max(p0, p1), Self.tolerance,
                                     "\(step.name): the settled region is not the whole picture")
            XCTAssertGreaterThan(picturePixels, 0)
        }
    }

    // MARK: - ⑥ reverse gate

    /// With `readsCanvasCropAsSource` set, the same measurement must go red: the pre-370 walk reads a
    /// `.canvas` crop as a rect of the photograph, which is precisely the reported misalignment.
    func testTheCanvasSpaceIsLoadBearing() throws {
        let step = Self.steps[3]
        let correct = settledEdgeDelta(step: step)
        LoupeFraming.readsCanvasCropAsSource = true
        defer { LoupeFraming.readsCanvasCropAsSource = false }
        let gated = settledEdgeDelta(step: step)
        note(String(format: "370 gate · settled edge Δ correct %.2f px · pre-370 %.2f px",
                    correct, gated))
        XCTAssertLessThanOrEqual(correct, Self.tolerance, "the shipped walk is already misplaced")
        XCTAssertGreaterThan(gated, 10 * Self.tolerance,
                             "the gate did not restore the pre-370 misplacement")
    }

    /// The settled region's worst edge error, in canvas pixels.
    private func settledEdgeDelta(step: (name: String, v: Double, degrees: Double, crop: CropRect))
        -> Double {
        guard let framing = try? XCTUnwrap(LoupeFraming(viewport: Self.viewport, decoded: Self.source,
                                                        decodeScale: 1, edit: document(step),
                                                        canvasRole: .export)) else { return .infinity }
        let region = framing.framePlacement(of: framing.mapping(of: .fit)).region
        let w = Double(Self.viewport.width), h = Double(Self.viewport.height)
        return max(abs(region.left) * w, abs(region.top) * h,
                   abs(region.right - 1) * w, abs(region.bottom - 1) * h)
    }

    // MARK: - the geometry table: the backdrop's quad vs the matte's quad, per side

    /// Perpendicular distance from `p` to the line through `a` and `b`.
    private func distance(from p: CGPoint, toLine a: CGPoint, _ b: CGPoint) -> Double {
        let vx = b.x - a.x, vy = b.y - a.y
        let len = (vx * vx + vy * vy).squareRoot()
        guard len > 1e-9 else {
            return ((p.x - a.x) * (p.x - a.x) + (p.y - a.y) * (p.y - a.y)).squareRoot()
        }
        return abs((p.x - a.x) * vy - (p.y - a.y) * vx) / len
    }

    /// The four side differences: for each side `i`, the larger perpendicular distance from the
    /// **other** quad's two endpoints to this quad's side line.
    private func edgeDiffs(_ a: [CGPoint], _ b: [CGPoint]) -> [Double] {
        (0..<4).map { i in
            let j = (i + 1) % 4
            return max(distance(from: b[i], toLine: a[i], a[j]),
                       distance(from: b[j], toLine: a[i], a[j]))
        }
    }

    private func cgPoints(_ quad: [SIMD2<Double>]) -> [CGPoint] {
        quad.map { CGPoint(x: $0.x, y: $0.y) }
    }

    /// **The table.** For every group and every progress, the quad that places the low-resolution
    /// backdrop (`A`, the one `presentCanvas`/`PresentWindow.onWholePicture` produces) is measured
    /// against the quad that places the matte and the picture (`B`, the photograph's own quad through
    /// the bridge). Each cell is the worst of the four side differences, perpendicular, in device px.
    ///
    /// Shipped walk: every cell ≤ 0.5 px. Pre-370 walk (`readsCanvasCropAsSource`): the same cells are
    /// printed and must be **over** the limit, which is what makes the numbers evidence about the fix
    /// rather than about the tolerance.
    func testTheMatteAndTheBackdropShareOneQuadOnEveryTransitionFrame() throws {
        let limit = Self.tolerance
        var redBefore = 0, cells = 0
        for gated in [false, true] {
            LoupeFraming.readsCanvasCropAsSource = gated
            defer { LoupeFraming.readsCanvasCropAsSource = false }
            for step in Self.steps {
                let framing = LoupeFraming(viewport: Self.viewport, decoded: Self.source,
                                           decodeScale: 1, edit: document(step),
                                           canvasRole: .export)
                let centre = framing.windowCenter(of: .fit)
                let actual = LoupeViewState(mode: .actual, zoom: 1,
                                            centerX: centre.x, centerY: centre.y)
                let fit = LoupeViewState.fit
                let actualMapping = framing.mapping(of: actual)
                let fitMapping = framing.mapping(of: fit)
                let fitQuad = corners(try XCTUnwrap(fitMapping.transform?.frameRectInS5()))
                let placement = framing.framePlacement(of: actualMapping)
                let bridge = LoupeZoomBridge(fromContent: framing.contentPixels(of: actual),
                                             toContent: framing.contentPixels(of: fit),
                                             fromMapping: actualMapping, toMapping: fitMapping,
                                             canvas: Self.viewport, anchor: .center)
                let fromCameraQuad = fromCamera(fitQuad, bridge: bridge)
                for t in [0.25, 0.5, 0.75] {
                    let window = bridge.window(atProgress: t, textureSize: Self.viewport)
                    let back = window.onWholePicture(placement)
                    let backdrop = cgPoints(lowResQuad(back, canvas: Self.viewport))
                    let matte = cgPoints(projected(fromCameraQuad, bridge: bridge, progress: t))
                    let diffs = edgeDiffs(backdrop, matte)
                    let worst = diffs.max() ?? .infinity
                    cells += 1
                    if gated && worst > limit { redBefore += 1 }
                    note(String(format: "370 table · %@ · %@ · t %.2f · l %.2f t %.2f r %.2f b %.2f"
                                + " · worst %.2f px",
                                gated ? "PRE-370" : "SHIPPED", step.name, t,
                                diffs[0], diffs[1], diffs[2], diffs[3], worst))
                    if !gated {
                        XCTAssertLessThanOrEqual(worst, limit,
                                                 "\(step.name) @ \(t): the backdrop's side left the "
                                                 + "matte's side by \(worst) px")
                    }
                }
            }
        }
        note("370 table · PRE-370 cells over 0.5 px: \(redBefore) of \(cells / 2)")
        XCTAssertGreaterThan(redBefore, 0, "the gate is not load bearing: no cell went red")
    }

    // MARK: - the app path: a real crop commit, then the real bridge

    private func rawFixture() throws -> URL {
        let candidates = [
            ProcessInfo.processInfo.environment["PHOTONS_TEST_RAW"],
            NSString(string: "~/Desktop/test/L1030433.dng").expandingTildeInPath,
        ].compactMap { $0 }
        for c in candidates where FileManager.default.isReadableFile(atPath: c) {
            return URL(fileURLWithPath: c)
        }
        throw XCTSkip("no RAW fixture; set PHOTONS_TEST_RAW")
    }

    private func pump(_ seconds: TimeInterval = 0.005) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    @discardableResult
    private func waitFor(_ timeout: TimeInterval = 90, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            pump()
        }
        return condition()
    }

    private func makeEditor(url: URL) throws -> EditorWindowController {
        _ = NSApplication.shared
        let package = workDir.appendingPathComponent("LowRes370.\(LibraryLayout.packageExtension)")
        let catalog = try Catalog.create(at: package)
        let source = workDir.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let root = try catalog.ensureRoot(for: source, mode: .reference)
        let destination = source.appendingPathComponent("lowres370.dng")
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: url)
        let size = try pixelSize(of: url)
        let bytes = (try FileManager.default.attributesOfItem(atPath: url.path)[.size]
            as? NSNumber)?.intValue ?? 1
        let id = UUID().uuidString
        try catalog.dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO assets (id, source_root_id, rel_path, filename, ext, kind, size, mtime,
                                    content_hash, width, height, camera_make, camera_model, lens,
                                    imported_at, missing)
                VALUES ('\(id)', '\(root.id)', 'lowres370.dng', 'lowres370.dng', 'dng', 'raw',
                        \(bytes), 0, '\(UUID().uuidString)', \(size.width), \(size.height),
                        'Leica Camera AG', 'Leica SL3', 'Vario-Elmarit-SL 24-90',
                        '2026-11-10T00:00:00Z', 0)
                """)
        }
        let editor = EditorWindowController(size: NSSize(width: 1200, height: 800))
        windows.append(editor.window!)
        try editor.openLibrary(at: package)
        editor.session.selectOnly(id)
        pump(0.05)
        editor.session.mode = .loupe
        editor.rootView.showModule(for: .loupe)
        let loupe = editor.rootView.loupeController
        loupe.reducesMotion = false
        loupe.collectsHistogram = false
        loupe.scheduleRender()
        pump(0.1)
        XCTAssertTrue(waitFor { loupe.lastFrame != nil }, "no first frame")
        return editor
    }

    private func pixelSize(of url: URL) throws -> ImageSize {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let width = try XCTUnwrap((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue)
        let height = try XCTUnwrap((properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue)
        return ImageSize(width: width, height: height)
    }

    @discardableResult
    private func settleLowRes(_ loupe: LoupeController, timeout: TimeInterval = 60) -> Bool {
        guard let key = loupe.backdropKeyForTesting else { return false }
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if loupe.backdrop.key == key && loupe.lowResFullFrame != nil { return true }
            if loupe.backdrop.isIdle { _ = loupe.ensureLowResFullFrame() }
            pump()
        }
        return false
    }

    private func settle(_ loupe: LoupeController, zoom: Double? = nil,
                        timeout: TimeInterval = 60) -> Bool {
        waitFor(timeout) {
            guard loupe.zoomBridge == nil else { return false }
            if let zoom { return abs((loupe.lastFrame?.zoom ?? -1) - zoom) < 1e-9 }
            return true
        }
    }

    /// The crop commit → next-frame rule (②) and the transition/settled rule (③), on the shipped path:
    /// a real window, a real decode, a real `EditorWindowController`, a real crop document.
    func testACroppedCanvasSpaceDocumentSettlesOnItsOwnLowResGeometry() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let editor = try makeEditor(url: try rawFixture())
        let loupe = editor.rootView.loupeController
        defer { for window in windows { window.orderOut(nil) } }

        let step = Self.steps[2]
        editor.session.applyEdit { model in
            model.geometry.crop = step.crop.normalizedRect
            model.geometry.cropSpace = .canvas
            model.geometry.aspectLock = .original
            model.geometry.perspectiveVertical = step.v
            model.geometry.perspectiveHorizontal = 0
            model.geometry.rotationDegrees = step.degrees
        }
        loupe.scheduleRender()
        XCTAssertTrue(settleLowRes(loupe), "no low-res frame after the crop commit")
        pump(0.35)
        XCTAssertTrue(settle(loupe, zoom: loupe.framing()?.fitZoom), "did not settle at fit")
        let fitQuad = try XCTUnwrap(loupe.lastPresented?.pictureQuad)
        let fitRegion = try XCTUnwrap(loupe.lastBackdropPresent?.placement.region)
        let px = Double(loupe.viewportPixels.width)
        note(String(format: "370 app · fit quad %@ · region %.4f…%.4f / %.4f…%.4f",
                    Edges.of([SIMD2(Double(fitQuad.x), Double(fitQuad.y)),
                              SIMD2(Double(fitQuad.maxX), Double(fitQuad.maxY))]).text,
                    fitRegion.left, fitRegion.right, fitRegion.top, fitRegion.bottom))
        XCTAssertLessThanOrEqual(max(abs(fitRegion.left), abs(fitRegion.right - 1)) * px,
                                 Self.tolerance,
                                 "the settled frame does not place the whole picture")
        XCTAssertLessThanOrEqual(max(abs(fitRegion.top), abs(fitRegion.bottom - 1))
                                     * Double(loupe.viewportPixels.height),
                                 Self.tolerance,
                                 "the settled frame does not place the whole picture")

        loupe.zoomToActualSize()
        XCTAssertTrue(settle(loupe, zoom: 1), "no 1:1 frame")
        let actualPlacement = try XCTUnwrap(loupe.lastBackdropPresent?.placement)
        let actualTexture = try XCTUnwrap(loupe.lastPresented?.frameCanvas)

        let before = loupe.backdropPresents.count
        let framesBefore = loupe.zoomBridgeFrames.count
        loupe.zoomToFit()
        let bridge = try XCTUnwrap(loupe.zoomBridge, "no bridge")
        XCTAssertTrue(waitFor { loupe.zoomBridge == nil }, "bridge never ended")
        pump(0.05)
        let serial = loupe.zoomBridgeArmedCount

        // ② — the very first frame the transition draws already uses the committed crop's geometry:
        // its low-res window is the same placement the settled (new) document reports.
        let first = loupe.backdropPresents.dropFirst(before).first { $0.serial == serial }
        let firstFrame = loupe.zoomBridgeFrames.dropFirst(framesBefore).first { $0.serial == serial }
        XCTAssertNotNil(first, "the transition drew no frame")
        XCTAssertNotNil(firstFrame)
        if let first {
            XCTAssertEqual(first.placement.region.right, actualPlacement.region.right, accuracy: 1e-6)
            XCTAssertEqual(first.placement.region.bottom, actualPlacement.region.bottom, accuracy: 1e-6)
        }

        // ③ — the bridge's end geometry is the settled fit frame's, **value for value**. No tolerance:
        // the `1.0 px` this used to allow was a rounding difference between two walks of the same
        // point, and ③ asks for the bit-identical rect, not a close one. Both sides are the
        // **product's** own derivation (`PresentRequest`), so no hand rounding of a normalised rect
        // can manufacture a pixel of difference.
        if let low = loupe.lowResFullFrame {
            let endWindow = bridge.window(atProgress: 1, textureSize: actualTexture)
            let back = endWindow.onWholePicture(actualPlacement)
            let end = PresentRequest(picture: low.texture, photoRect: low.content,
                                     window: back, canvas: loupe.viewportPixels).pictureQuad
            note(String(format: "370 app · end %@ · settled %@ · exact %@",
                        "\(end)", "\(fitQuad)",
                        end == fitQuad ? "equal" : "NOT equal"))
            XCTAssertEqual(end.x, fitQuad.x, "the transition's end left edge")
            XCTAssertEqual(end.y, fitQuad.y, "the transition's end top edge")
            XCTAssertEqual(end.width, fitQuad.width, "the transition's end width")
            XCTAssertEqual(end.height, fitQuad.height, "the transition's end height")
        }
    }
}
