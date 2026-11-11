import XCTest
import AppKit
import ImageIO
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 376 — the backdrop's scale denominator is the canvas **this render allocates**.
///
/// The user's crash (2026-11-11): a canvas-spaced crop pulled down to a fraction of the picture, no
/// perspective needed, and the loupe aborted inside `-[MTLTextureDescriptorInternal
/// validateWithDevice:]` — Metal *asserts* on a descriptor past 16384 and does not return `nil`, so
/// `TexturePool.obtain`'s `guard let` could not catch it.
///
/// The arithmetic: `plan` sizes a `.document` render to the turned photograph's AABB
/// (`CropGeometry.canvas(.document)`), while the backdrop's scale was taken against the **crop frame**
/// (`EditModel.outputPixels`). `canvas × preview/frame` is unbounded as the frame shrinks. Taking the
/// denominator from `canvas(role)` makes the requested long edge `previewLongEdge(original)` —
/// **exactly** — for every role, space, crop and angle, which is what this suite pins.
///
/// Two doors: pure geometry over the whole parameter grid, and a real `RenderGraph` over the shapes
/// the report names (so `Plan.canvas` — the number the texture pool is handed — is checked too).
///
/// `denominatorIsCropFrame` is the reverse gate: flipped on from a test (never in the app), it
/// restores the pre-376 denominator and the same loop must go red.
@MainActor
final class BackdropCanvasLimit376Tests: XCTestCase {

    /// Metal's hard 2D texture limit on this machine (measured: 16384 legal, 16385 aborts).
    private static let metalLimit = 16384

    /// **Reverse gate — never true in the app.** `true` measures the pre-376 denominator
    /// (`EditModel.outputPixels`, the crop frame) and must report the 20480×13630 / 21800×14509
    /// `.document` requests on the 9520×6336 fixture. `PHOTONS_376_REVERSE=1` turns it on.
    nonisolated(unsafe) static var denominatorIsCropFrame =
        ProcessInfo.processInfo.environment["PHOTONS_376_REVERSE"] == "1"

    private static let reverse = ProcessInfo.processInfo.environment["PHOTONS_376_REVERSE"] == "1"

    private static let sources = [
        ImageSize(width: 9520, height: 6336),
        ImageSize(width: 1200, height: 800),
        ImageSize(width: 20000, height: 3000),
    ]
    private static let verticals = [-400.0, -200.0, 0.0, 200.0, 400.0]
    private static let horizontals = [-400.0, 0.0, 400.0]
    private static let angles = [-45.0, 0.0, 45.0]
    private static let widths = [1.0, 0.9, 0.7, 0.5, 0.3, 0.2, 0.15, 0.1, 0.05]

    private var windows: [NSWindow] = []

    override func tearDown() {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        Self.denominatorIsCropFrame = Self.reverse
        super.tearDown()
    }

    /// A centred square crop of `width` of the document, in the given space, with the knobs asked.
    private func document(source: ImageSize, space: CropSpace, vertical: Double,
                          horizontal: Double, angle: Double, width: Double) -> EditModel {
        let crop = NormalizedRect(x: (1 - width) / 2, y: (1 - width) / 2,
                                  width: width, height: width)
        var edit = EditModel.neutral
        edit.geometry = GeometryGroup(crop: crop,
                                      rotationDegrees: angle,
                                      aspectLock: .original,
                                      quarterTurns: 0,
                                      perspectiveVertical: vertical,
                                      perspectiveHorizontal: horizontal,
                                      cropSpace: space)
        return edit
    }

    /// The request a backdrop render makes: the canvas `plan` allocates, times the scale.
    private func request(_ canvas: ImageSize, scale: Double) -> ImageSize {
        ImageSize(width: Int((Double(canvas.width) * scale).rounded()),
                  height: Int((Double(canvas.height) * scale).rounded()))
    }

    // MARK: - the contract, over the whole grid

    func testTheBackdropRequestNeverExceedsTheMetalTextureLimit() {
        var worst = (edge: 0, label: "")
        for source in Self.sources {
            let originalLongEdge = max(source.width, source.height)
            let preview = BackdropScale.previewLongEdge(imageLongEdge: originalLongEdge)
            for space in [CropSpace.source, .canvas] {
                for vertical in Self.verticals {
                    for horizontal in Self.horizontals {
                        for angle in Self.angles {
                            for width in Self.widths {
                                let edit = document(source: source, space: space,
                                                    vertical: vertical, horizontal: horizontal,
                                                    angle: angle, width: width)
                                let geometry = CropGeometry(geometry: edit.geometry, source: source)
                                for role in [CanvasRole.export, .document] {
                                    let canvas = geometry.canvas(role)
                                    let denominator = Self.denominatorIsCropFrame
                                        ? edit.geometry.outputPixels(in: source)
                                        : canvas
                                    let scale = BackdropScale.renderScale(
                                        imageLongEdge: originalLongEdge,
                                        contentLongEdge: max(denominator.width, denominator.height))
                                    let size = request(canvas, scale: scale)
                                    // The report's table: the two crash rows plus the un-keystoned
                                    // full-crop control, both roles, old denominator beside new.
                                    if source.width == 9520, space == .canvas, angle == 0,
                                       (horizontal, vertical) == (0, 0)
                                        || (horizontal, vertical) == (0, -400)
                                        || (horizontal, vertical) == (-400, -400)
                                        || (horizontal, vertical) == (400, 400),
                                       [1.0, 0.5, 0.2, 0.05].contains(width) {
                                        let old = edit.geometry.outputPixels(in: source)
                                        let oldScale = BackdropScale.renderScale(
                                            imageLongEdge: originalLongEdge,
                                            contentLongEdge: max(old.width, old.height))
                                        let oldSize = request(canvas, scale: oldScale)
                                        print("[376] table \(role) v=\(vertical) w=\(width)"
                                              + " · canvas \(canvas.keyString)"
                                              + " · old \(oldSize.keyString)"
                                              + " · new \(size.keyString)")
                                    }
                                    let label = "\(source.width)×\(source.height) \(space)"
                                        + " v=\(vertical) h=\(horizontal) θ=\(angle) w=\(width)"
                                        + " \(role) → \(size.width)×\(size.height)"
                                        + " (canvas \(canvas.width)×\(canvas.height), scale \(scale))"
                                    if max(size.width, size.height) > worst.edge {
                                        worst = (max(size.width, size.height), label)
                                    }
                                    XCTAssertLessThanOrEqual(size.width, Self.metalLimit, label)
                                    XCTAssertLessThanOrEqual(size.height, Self.metalLimit, label)
                                    // The contract: the canvas sized by `scale` is the preview itself.
                                    XCTAssertEqual(max(size.width, size.height), preview, accuracy: 1,
                                                   label)
                                }
                            }
                        }
                    }
                }
            }
        }
        print("[376] worst request long edge \(worst.edge) at \(worst.label)")
    }

    // MARK: - the same numbers through a real allocation

    /// The render the backdrop asks for — no `canvas` option, the role's own canvas, the backdrop's
    /// own scale — over the shapes the report names: an applied crop from 100 % to 5 %, both crop
    /// spaces, no keystone and `pv=ph=±400`, upright and 9°.
    ///
    /// This checks one thing the pure loop cannot: that `RenderGraph.plan`'s canvas for a role **is**
    /// `CropGeometry.canvas(role)`. `Plan.canvas` is the size the texture pool is handed, so the
    /// identity the denominator now rests on is measured where the allocation happens, and a
    /// descriptor past the limit would abort the process rather than fail an assertion.
    func testTheDocumentRoleAllocationIsThePreviewLongEdge() throws {
        var widest = 0
        for source in [ImageSize(width: 900, height: 600), ImageSize(width: 3000, height: 2000)] {
            var rgba = [Float16](repeating: 0.18, count: source.width * source.height * 4)
            for i in stride(from: 3, to: rgba.count, by: 4) { rgba[i] = 1 }
            let image = LinearImage(width: source.width, height: source.height, rgba: rgba,
                                    colorSpace: "sRGB", decoderVersion: "backdrop-limit-376")
            let graph = try RenderGraph(input: RenderInput(image: image,
                                                           identity: "backdrop-limit-376"))
            let preview = BackdropScale.previewLongEdge(imageLongEdge: max(source.width,
                                                                          source.height))
            for space in [CropSpace.canvas, .source] {
                for (vertical, horizontal) in [(0.0, 0.0), (-400.0, -400.0), (400.0, 400.0)] {
                    for width in [1.0, 0.5, 0.2, 0.05] {
                        for angle in [0.0, 9.0] {
                            let edit = document(source: source, space: space, vertical: vertical,
                                                horizontal: horizontal, angle: angle, width: width)
                            for role in [CanvasRole.export, .document] {
                                let canvas = CropGeometry(geometry: edit.geometry,
                                                          source: source).canvas(role)
                                let scale = BackdropScale.renderScale(
                                    imageLongEdge: max(source.width, source.height),
                                    contentLongEdge: max(canvas.width, canvas.height))
                                let result = try graph.render(edit, options: RenderOptions(
                                    canvasRole: role, scale: scale,
                                    display: DisplayOptions(primaries: .sRGB, bitDepth: 16, headroom: 1),
                                    useCache: false, wantsPixels: false))
                                let size = result.canvas
                                if let texture = result.output { graph.recycle(output: texture) }
                                let label = "\(source.keyString) \(space) v=\(vertical)"
                                    + " h=\(horizontal) w=\(width) θ=\(angle) \(role)"
                                    + " canvas \(canvas.keyString) scale \(scale) → \(size.keyString)"
                                widest = max(widest, max(size.width, size.height))
                                XCTAssertLessThanOrEqual(size.width, Self.metalLimit, label)
                                XCTAssertLessThanOrEqual(size.height, Self.metalLimit, label)
                                XCTAssertEqual(max(size.width, size.height), preview, accuracy: 1,
                                               label)
                            }
                        }
                    }
                }
            }
            print("[376] gpu · \(source.keyString) · preview \(preview) · worst so far \(widest)")
        }
    }

    // MARK: - the real path: `.document` through `renderBackdrop`

    /// The whole-picture render on a real 9520×6336 file, with the crop tool on so
    /// `job.canvasRole` is `.document` (344's snapshot, not a defaulted `.export`).
    ///
    /// This is the path the crash came through (`renderBackdrop` → `graph.render` with no `canvas`),
    /// and it is where the two halves of the fix meet: the job's `.document` canvas is the turned
    /// whole photograph, and the denominator is that same rectangle. The texture the cache adopted is
    /// asserted, i.e. the allocation that really happened. The document carries a 5 % crop (the
    /// user's state when they reported it), but 197/`canvasEdit` renders it as `.full` while the tool
    /// is up, so the denominator must follow **the edit the render receives** — `job.edit` after
    /// `backdropEdit`, not the session's document. The cropped and keystoned shapes that used to ask
    /// for 20480 / 21800 / 67407 px are the two tests above, where the denominator is measured
    /// against the same `canvas(role)` the pool is handed.
    func testACroppedDocumentInTheCropToolRendersThePreviewLongEdge() throws {
        let url = try rawFixture()
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-376-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }
        let (session, _) = try CropUITestSupport.makeSession(in: workDir)

        let controller = LoupeController(session: session)
        controller.autoRenderEnabled = false
        controller.collectsHistogram = false
        let window = TestWindows.make(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
                                      styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = controller.view
        controller.canvasView.frame = window.contentLayoutRect
        windows.append(window)
        TestWindows.show(window)
        controller.view.layoutSubtreeIfNeeded()
        CropUITestSupport.pump(0.05)

        var edit = EditModel.neutral
        edit.geometry.crop = NormalizedRect(x: 0.475, y: 0.475, width: 0.05, height: 0.05)
        edit.geometry.aspectLock = .original
        edit.geometry.cropSpace = .canvas
        controller.frameSource = LoupeController.FrameSource(
            url: url, identity: "backdrop-376-\(UUID().uuidString)",
            viewport: ImageSize(width: 640, height: 400), state: .fit, edit: edit)
        controller.autoRenderEnabled = true
        controller.scheduleRender()
        XCTAssertTrue(waitFor { controller.lastFrame != nil }, "no first frame")
        XCTAssertTrue(CropUITestSupport.openCropTool(controller, session), "裁切 did not open")
        XCTAssertEqual(controller.cropTool.canvasRole, .document)

        controller.pointerExited()
        controller.pointerMoved(to: CGPoint(x: 64, y: 140))
        XCTAssertTrue(waitFor(60) { controller.backdrop.isIdle }, "the backdrop render never finished")
        let size = try XCTUnwrap(controller.backdrop.size, "no backdrop was adopted")

        let source = try sourceSize(of: url)
        let preview = BackdropScale.previewLongEdge(imageLongEdge: max(source.width, source.height))
        print("[376] live · \(source.keyString) · 5 % crop · .document · backdrop \(size.keyString)"
              + " · preview \(preview)")
        XCTAssertLessThanOrEqual(max(size.width, size.height), Self.metalLimit)
        XCTAssertEqual(max(size.width, size.height), preview, accuracy: 1)
    }

    private func rawFixture() throws -> URL {
        let candidates = [
            ProcessInfo.processInfo.environment["PHOTONS_TEST_RAW"],
            NSString(string: "~/Desktop/test/L1030433.dng").expandingTildeInPath,
        ].compactMap { $0 }
        for candidate in candidates where FileManager.default.isReadableFile(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }
        throw XCTSkip("no RAW fixture; set PHOTONS_TEST_RAW")
    }

    /// The file's own frame size, from the container — no decode.
    private func sourceSize(of url: URL) throws -> ImageSize {
        let imageSource = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil), "no image source")
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any], "no properties")
        let width = try XCTUnwrap(properties[kCGImagePropertyPixelWidth] as? Int, "no pixel width")
        let height = try XCTUnwrap(properties[kCGImagePropertyPixelHeight] as? Int, "no pixel height")
        return ImageSize(width: width, height: height)
    }

    private func pump(_ seconds: TimeInterval = 0.005) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func waitFor(_ timeout: TimeInterval = 30, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            pump()
        }
        return condition()
    }
}
