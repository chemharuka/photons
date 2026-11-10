import XCTest
import AppKit
import CoreGraphics
import ImageIO
import Metal
import QuartzCore
import PhotonsCatalog
@testable import PhotonsCore
@testable import PhotonsUI

/// 344 — 低清全帧（`LowResFullFrame`）必须是**画布那一张**，不是它的替身。
///
/// The bug: the whole-picture texture was keyed by the photo, the develop key and the edit digest, and
/// drawn under a frame whose placement had been computed for a different canvas. Two dimensions were
/// invisible to the key — the **keystone** and the crop's **space** — so a document that gained a
/// keystone kept the old texture (261 code values off at `(+40, 0)`), and the placement added the
/// rotation-expanded canvas' half-margin to a warped canvas that has none (172.67 / 285.19 px left and
/// up at 1:1 and 4×).
///
/// Four claims, each with its own number:
///
///   1. **the key names the geometry.** A keystone-free, source-spaced document's whole-picture key is
///      byte-identical to the pre-344 one (pinned as a literal); a keystoned one grows `|geo=…` and the
///      six knobs are spelled in it (`pvy=400`).
///   2. **the texture is the reference render.** Eight geometries — four keystones at 0° and the same
///      four at 9° — each compared, code for code, with an independent `RenderGraph` render of the same
///      document at the same rung and the same scale: `max|Δ| == 0`, tolerance 0. The reverse gate
///      (`backdropKeyIgnoresPerspective`) is the pre-344 key, and it must serve the stale frame.
///   3. **the placement is the canvas'.** Under `(+40, −25) + 9°` the picture's `region` starts at the
///      canvas origin (0.00 px, not the 172.67 / 285.19 px inset), and two source markers land where the
///      stand-in puts them at 1× and 4× (≤ 0.5 px).
///   4. **a cold switch never shows nothing.** Twelve cold switches: the stand-in is up in the same turn
///      (non-nil, 256×170) and settles at 1920×1278; the same twelve warm switch in at 1920 immediately.
@MainActor
final class LowResFullFrame344Tests: XCTestCase {

    private static let viewport = ImageSize(width: 640, height: 400)
    /// The four keystones the acceptance names, as `(vertical, horizontal)`.
    private static let keystones: [(name: String, v: Double, h: Double)] = [
        ("(0,0)", 0, 0), ("(+40,0)", 40, 0), ("(0,-40)", 0, -40), ("(+40,-25)", 40, -25),
    ]
    private static let angles: [Double] = [0, 9]

    private var workDir: URL!
    private var windows: [NSWindow] = []
    private var cacheDirs: [URL] = []

    /// Millisecond numbers are recorded only under `PHOTONS_BENCH=1` (project rule): `swift test` builds
    /// Debug, where they are not the shipping ones.
    private var benchmarks: Bool { ProcessInfo.processInfo.environment["PHOTONS_BENCH"] == "1" }
    /// Iteration aid: the two heavy claims (a reference render per geometry, twelve cold switches) are
    /// skipped when this is set, so a change to the key or the placement can be checked in seconds.
    private var fastOnly: Bool { ProcessInfo.processInfo.environment["PHOTONS_344_FAST"] == "1" }

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-344-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        for dir in cacheDirs { try? FileManager.default.removeItem(at: dir) }
        cacheDirs.removeAll()
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
        workDir = nil
    }

    // MARK: - fixtures and plumbing

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

    /// A controller on the fixture, driven through `frameSource` (the app's own open path, minus the
    /// catalog), with one frame landed so the backdrop has a graph to render from.
    private func makeController(url: URL, identity: String, edit: EditModel) throws -> LoupeController {
        let controller = LoupeController(session: CatalogSession())
        controller.autoRenderEnabled = false
        controller.collectsHistogram = false
        let window = TestWindows.make(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
                                      styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = controller.view
        controller.canvasView.frame = window.contentLayoutRect
        windows.append(window)
        TestWindows.show(window)
        controller.view.layoutSubtreeIfNeeded()
        pump(0.05)
        controller.frameSource = LoupeController.FrameSource(url: url, identity: identity,
                                                             viewport: Self.viewport,
                                                             state: .fit, edit: edit)
        controller.autoRenderEnabled = true
        controller.scheduleRender()
        XCTAssertTrue(waitFor { controller.lastFrame != nil }, "no first frame")
        pump(0.1)
        return controller
    }

    private func enter(_ controller: LoupeController, at point: CGPoint = CGPoint(x: 64, y: 140)) {
        controller.pointerExited()
        controller.pointerMoved(to: point)
    }

    /// The document with one of the eight geometries applied.
    private static func document(_ base: EditModel, keystone: (v: Double, h: Double),
                                 angle: Double) -> EditModel {
        var edit = base
        edit.geometry.perspectiveVertical = keystone.v
        edit.geometry.perspectiveHorizontal = keystone.h
        edit.geometry.rotationDegrees = angle
        return edit
    }

    // MARK: - ① the key names the geometry

    /// The pre-344 key, character for character. A document with no keystone and a source-spaced crop
    /// must answer it exactly — that is what "byte-identical cache entry" means, and it is the reason the
    /// geometry is appended only when it is non-neutral.
    func testTheKeyCarriesTheGeometry() throws {
        let url = try rawFixture()
        let controller = try makeController(url: url, identity: "344", edit: .neutral)
        let neutral = try XCTUnwrap(controller.backdropKeyForTesting, "no key for a frame source")
        print("344 key · keystone 0 → \(neutral.identity)")
        // The literal, character for character. `f444fd3255cbdb05` is `Histogram.editDigest(.neutral)`
        // on this base (the picture half did not move with 344 — only the geometry half was added, and
        // only when it is non-neutral), so a change to this string is a change to the pre-344 key.
        XCTAssertEqual(neutral.identity,
                       "344|recipe=v3-lens;ver=auto;scale=1.0000|f444fd3255cbdb05|ceil=4.9246")
        // The literal above is not a magic string: it is the two halves the key already had.
        let document = try XCTUnwrap(controller.frameSource).edit
        XCTAssertEqual(neutral.develop, document.decodeInputs.key)
        XCTAssertEqual(neutral.digest, Histogram.editDigest(document))
        XCTAssertEqual(neutral.geometry, "", "a keystone-free document appends nothing")

        for keystone in Self.keystones where keystone.v != 0 || keystone.h != 0 {
            let edit = Self.document(document, keystone: (keystone.v, keystone.h), angle: 0)
            controller.frameSource = LoupeController.FrameSource(url: url, identity: "344",
                                                                 viewport: Self.viewport,
                                                                 state: .fit, edit: edit)
            let key = try XCTUnwrap(controller.backdropKeyForTesting)
            print("344 key · \(keystone.name) 0° → \(key.identity)")
            XCTAssertTrue(key.identity.contains("|geo="),
                          "\(keystone.name): the key cannot name the keystone it was rendered through")
            // The spelled half: the six knobs, in the order the key material uses them, each token
            // only when it is non-neutral (`asp`/`car`/`q` discipline) — so the numbers are readable
            // and a keystone cannot hide inside a digest.
            var expected = "344|\(edit.decodeInputs.key)|\(Histogram.editDigest(edit))|ceil="
                + String(format: "%.4f", HighlightCeiling.current)
                + "|geo=crop=0.00000,0.00000,1.00000,1.00000;rot=0.00000;flip=00"
            if keystone.v != 0 { expected += ";pvy=\(Int((keystone.v * 10).rounded()))" }
            if keystone.h != 0 { expected += ";phx=\(Int((keystone.h * 10).rounded()))" }
            XCTAssertEqual(key.identity, expected,
                           "\(keystone.name): the geometry half is the six knobs, spelled")
        }

        // The same position twice is the same string: the key is a function of the document, not of the
        // order the knobs were set in.
        let first = Self.document(document, keystone: (40, 0), angle: 0)
        controller.frameSource = LoupeController.FrameSource(url: url, identity: "344",
                                                             viewport: Self.viewport, state: .fit,
                                                             edit: first)
        let a = try XCTUnwrap(controller.backdropKeyForTesting).identity
        var again = first
        again.geometry.crop = .full
        again.geometry.perspectiveVertical = 40
        controller.frameSource = LoupeController.FrameSource(url: url, identity: "344",
                                                             viewport: Self.viewport, state: .fit,
                                                             edit: again)
        XCTAssertEqual(try XCTUnwrap(controller.backdropKeyForTesting).identity, a)
    }

    // MARK: - ② the texture is the reference render

    /// Eight geometries, each: the cached whole picture against an **independent** render of the same
    /// document, from the same rung, at the scale the cache itself recorded.
    func testLowResFullFrameIsTheCanvasRenderAtEveryKeystone() throws {
        if fastOnly { throw XCTSkip("PHOTONS_344_FAST") }
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        _ = device
        let url = try rawFixture()
        let controller = try makeController(url: url, identity: "344-ref", edit: .neutral)
        let base = try XCTUnwrap(controller.frameSource).edit

        var results: [String] = []
        for angle in Self.angles {
            for keystone in Self.keystones {
                let edit = Self.document(base, keystone: (keystone.v, keystone.h), angle: angle)
                controller.frameSource = LoupeController.FrameSource(url: url,
                                                                     identity: "344-ref",
                                                                     viewport: Self.viewport,
                                                                     state: .fit, edit: edit)
                controller.scheduleRender()
                let key = try XCTUnwrap(controller.backdropKeyForTesting)
                // One render through the explicit door (the pointer-entry gate is 039's, not this
                // claim's). `false` is the honest answer for a document the cache already holds —
                // that is the same key, and the same texture, which the comparison below proves.
                let alreadyHeld = controller.backdrop.key == key
                let started = controller.ensureLowResFullFrame(edit: edit)
                XCTAssertTrue(started || alreadyHeld,
                              "\(keystone.name) \(angle)°: the whole picture was refused for a "
                              + "document the cache does not hold")
                guard waitFor(90, { controller.backdrop.key == key && controller.lowResFullFrame != nil })
                else {
                    return XCTFail("\(keystone.name) \(angle)°: no low-res frame (last error: "
                                   + "\(controller.backdrop.lastError ?? "—"))")
                }
                let low = try XCTUnwrap(controller.lowResFullFrame)
                let scale = controller.backdrop.lastScale
                let rung = controller.backdrop.lastRungScale
                let reference = try referenceRender(controller: controller, edit: edit,
                                                    url: url, scale: scale, rung: rung)
                let delta = Self.maxCodeDelta(low.texture, reference)
                results.append(String(format: "%@ %g° · %d×%d vs %d×%d · scale %.4f rung %.3f · max|Δ| %d",
                                      keystone.name, angle,
                                      low.texture.width, low.texture.height,
                                      reference.width, reference.height, scale, Double(rung), delta))
                XCTAssertEqual(low.texture.width, reference.width,
                               "\(keystone.name) \(angle)°: the two canvases are different sizes")
                XCTAssertEqual(low.texture.height, reference.height,
                               "\(keystone.name) \(angle)°: the two canvases are different sizes")
                XCTAssertEqual(delta, 0,
                               "\(keystone.name) \(angle)°: the low-res whole picture is not the "
                               + "canvas' render (\(delta) code values)")
            }
        }
        for line in results { print("344 same source · " + line) }

        // ── the reverse gate: the pre-344 key, and the stale frame it serves.
        //
        // The gate makes the **key** blind to the keystone; the render still uses the document. So the
        // gate has to be armed on a keystone-free document first (that picture is what the pre-344 key
        // will keep serving), and only then does the document gain its keystone.
        let stale = Self.document(base, keystone: (40, 0), angle: 0)
        LoupeController.backdropKeyIgnoresPerspective = true
        defer { LoupeController.backdropKeyIgnoresPerspective = false }
        controller.frameSource = LoupeController.FrameSource(url: url, identity: "344-ref",
                                                             viewport: Self.viewport,
                                                             state: .fit, edit: base)
        let gateKey = try XCTUnwrap(controller.backdropKeyForTesting)
        XCTAssertEqual(gateKey.geometry, "", "reverse gate: the key must be the pre-344 one")
        _ = controller.ensureLowResFullFrame(edit: base)
        guard waitFor(90, { controller.backdrop.key == gateKey && controller.lowResFullFrame != nil })
        else {
            return XCTFail("reverse gate: the keystone-free picture never rendered")
        }
        let flat = try XCTUnwrap(controller.lowResFullFrame)
        let generations = controller.backdrop.generationCount

        // The document gains its keystone. The pre-344 key cannot tell the two apart …
        controller.frameSource = LoupeController.FrameSource(url: url, identity: "344-ref",
                                                             viewport: Self.viewport,
                                                             state: .fit, edit: stale)
        let staleKey = try XCTUnwrap(controller.backdropKeyForTesting)
        XCTAssertEqual(staleKey, gateKey,
                       "reverse gate: the key moved — the gate is not the pre-344 key")
        // … so nothing is regenerated, and the stale picture keeps being served.
        _ = controller.ensureLowResFullFrame(edit: stale)
        pump(0.4)
        XCTAssertEqual(controller.backdrop.generationCount, generations,
                       "reverse gate: a generation ran, so no stale texture was served")
        XCTAssertEqual(controller.backdrop.key, gateKey)
        let stillFlat = try XCTUnwrap(controller.lowResFullFrame)
        XCTAssertEqual(stillFlat.digest, flat.digest)
        let reference = try referenceRender(controller: controller, edit: stale, url: url,
                                            scale: controller.backdrop.lastScale,
                                            rung: controller.backdrop.lastRungScale)
        let staleDelta = Self.maxCodeDelta(stillFlat.texture, reference)
        print("344 reverse gate · backdropKeyIgnoresPerspective = true · key "
              + "\(staleKey.identity) · served the keystone-free picture · max|Δ| \(staleDelta)"
              + " code values against the (+40,0) render")
        XCTAssertGreaterThan(staleDelta, 200,
                             "reverse gate: the stale frame was indistinguishable from the keystoned "
                             + "one (\(staleDelta) code values) — the gate proves nothing")
    }

    /// A second, independent development of `edit` from the **same** decoded rung at the **same** scale,
    /// with the same display space — i.e. exactly what `renderBackdrop` asks the graph for, asked again
    /// by the test. Two different graphs, one document: `max|Δ| > 0` means the cached texture was made
    /// from something else.
    private func referenceRender(controller: LoupeController, edit: EditModel, url: URL,
                                 scale: Double, rung: Float) throws -> MTLTexture {
        let decoded = try XCTUnwrap(controller.decodedForTesting,
                                    "the controller has no decoded rung")
        let inputs = edit.decodeInputs
        var reference = edit
        // The canvas job's document: no crop, no aspect lock (197's `canvasEdit`), which is the edit the
        // backdrop is rendered from and the one `makeJob` frames.
        reference.geometry.crop = .full
        reference.geometry.aspectLock = .original
        let graph = try RenderGraph(input: RenderInput(image: decoded,
                                                       identity: "344-ref|\(Histogram.editDigest(edit))",
                                                       sourceURL: url,
                                                       whiteBalance: inputs.whiteBalance),
                                    textureRetention: .none)
        defer { graph.releaseAllTextures() }
        let result = try graph.render(reference, options: RenderOptions(
            canvasRole: .export,
            scale: scale,
            display: DisplayOptions(primaries: .displayP3, bitDepth: 16,
                                    headroom: controller.headroom,
                                    highlightCeiling: HighlightCeiling.current),
            useCache: false, wantsPixels: false))
        _ = rung
        return try XCTUnwrap(result.output, "the reference render produced no texture")
    }

    /// Every channel of both textures as 16-bit codes; the largest absolute difference, in codes.
    private static func maxCodeDelta(_ a: MTLTexture, _ b: MTLTexture) -> Int {
        guard a.width == b.width, a.height == b.height else { return Int.max }
        let ac = codes(a), bc = codes(b)
        guard ac.count == bc.count else { return Int.max }
        var worst = 0
        for i in 0..<ac.count {
            let d = abs(Int(ac[i]) - Int(bc[i]))
            if d > worst { worst = d }
        }
        return worst
    }

    /// `rgba16Float` → 0…65535 codes, channel by channel (the code scale the acceptance quotes).
    private static func codes(_ texture: MTLTexture) -> [UInt16] {
        let w = texture.width, h = texture.height
        var raw = [UInt16](repeating: 0, count: w * h * 4)
        raw.withUnsafeMutableBytes { buffer in
            texture.getBytes(buffer.baseAddress!, bytesPerRow: w * 8,
                             from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        }
        return raw.map { bits in
            let value = Double(Float16(bitPattern: bits))
            guard value.isFinite else { return value > 0 ? 65535 : 0 }
            return UInt16(max(0, min(65535, (value * 65535).rounded())))
        }
    }

    // MARK: - ③ the placement is the canvas'

    /// `(+40, −25) + 9°`: the picture's `region` is measured from the canvas' own origin, and two
    /// source markers land where the stand-in puts them at 1× and at 4×.
    ///
    /// The quantity is `LoupeFraming.canvasOriginPixels` — the one input of `framePlacement`'s region
    /// that the keystone changes. It was `(extent − crop)/2` for every document, which is the answer for
    /// a **rotation**-expanded canvas and garbage for a warped one (S0 samples the picture from canvas
    /// pixel 0 there), and it moved the whole picture's region 438.27 / 723.75 px on this canvas —
    /// 172.67 / 285.19 px of a 4096-px whole picture. It must be the origin, to 0.01 px.
    func testThePlacementFollowsTheCanvasUnderAKeystone() throws {
        let url = try rawFixture()
        let (editor, assets) = try makeEditor(files: [url])
        let loupe = editor.rootView.loupeController
        editor.session.selectOnly(assets[0].id)
        pump(0.05)
        editor.session.mode = .loupe
        editor.rootView.showModule(for: .loupe)
        editor.session.applyEdit { model in
            model.geometry.perspectiveVertical = 40
            model.geometry.perspectiveHorizontal = -25
            model.geometry.rotationDegrees = 9
        }
        loupe.scheduleRender()
        pump(0.1)
        XCTAssertEqual(editor.session.edit.geometry.perspectiveVertical, 40, accuracy: 1e-9,
                       "the document lost its keystone before the measurement")

        let viewport = loupe.viewportPixels
        let framing = try XCTUnwrap(loupe.framing(viewport: viewport), "no projection for the canvas")
        let canvas = framing.rotatedCropExtent
        let origin = framing.canvasOriginPixels
        // What the pre-344 rule answers for this canvas, so the 0.00 has a magnitude beside it.
        let oldInsetU = max(canvas.width - framing.cropWidthPixels, 0) / 2
        let oldInsetV = max(canvas.height - framing.cropHeightPixels, 0) / 2
        // A 4096-px whole picture is `scale` low-res pixels per canvas pixel; the old lane quoted the
        // error in that grid, which is where 172.67 / 285.19 px came from.
        let scale = Double(4096) / max(canvas.width, canvas.height)
        print(String(format: "344 placement · canvas %.2f×%.2f · origin %.2f,%.2f px (pre-344 %.2f,%.2f px"
                     + " · %.2f,%.2f px of a 4096 whole picture)",
                     canvas.width, canvas.height, origin.x, origin.y,
                     oldInsetU, oldInsetV, oldInsetU * scale, oldInsetV * scale))
        XCTAssertEqual(origin.x, 0, accuracy: 0.01,
                       "the picture's region starts \(origin.x) px into the canvas — the rotation inset "
                       + "is being applied to a keystoned canvas")
        XCTAssertEqual(origin.y, 0, accuracy: 0.01,
                       "the picture's region starts \(origin.y) px into the canvas")
        XCTAssertGreaterThan(max(oldInsetU, oldInsetV), 100,
                             "the pre-344 inset was \(oldInsetU) / \(oldInsetV) px — the assertion above "
                             + "is not measuring what the fix removed")

        // ── the region is measured in canvas pixels, from the picture's own window: no inset.
        // `framePlacement`'s region is `(window − origin) / canvas`, so "region u/v 与画布" is the
        // question "does `region · canvas` equal the window the mapping names". The pre-344 rule put
        // the half-margin into `origin`, which is the 438.27 / 723.75 px above (172.67 / 285.14 px of
        // a 4096 whole picture) — the number the acceptance quotes.
        for zoom in [0.0, 1.0, 4.0] {
            let state = zoom == 0
                ? LoupeViewState.fit
                : LoupeViewState(mode: .actual, zoom: zoom,
                                 centerX: framing.sourceWidth / 2,
                                 centerY: framing.sourceHeight / 2)
            let mapping = framing.mapping(of: state)
            let placement = framing.framePlacement(of: mapping)
            let uPixels = placement.region.left * canvas.width - mapping.cropLeft
            let vPixels = placement.region.top * canvas.height - mapping.cropTop
            print(String(format: "344 placement · %@ · region left %.6f top %.6f · region·canvas − window"
                         + " · %.4f / %.4f px",
                         zoom == 0 ? "fit" : "\(Int(zoom))×", placement.region.left,
                         placement.region.top, uPixels, vPixels))
            XCTAssertEqual(uPixels, 0, accuracy: 0.01,
                           "the region starts \(uPixels) px from the window's own left edge")
            XCTAssertEqual(vPixels, 0, accuracy: 0.01,
                           "the region starts \(vPixels) px from the window's own top edge")
        }

    }

    /// **Open defect, measured here rather than claimed.** The frame's own projection
    /// (`LoupeFraming.mapping → LoupeMapping.viewPoint`, `LoupeZoom.swift:1058/972`) and the stand-in's
    /// rectangle (`LoupeController.firstFramePlaceholderContentRect`, `LoupeController.swift:5923 →
    /// LoupeZoom.swift:970 contentRectInS5 → FrameTransform.swift:455 frameRectInS5`) disagree by a
    /// **constant source-space translation**: 303.67 px at 1× and 1214.69 px at 4× — exactly 4× the
    /// same offset, so it is a fixed offset and not a scale error. The region origin itself is correct
    /// (`canvasOriginPixels` answers 0.00 px, the assertion above), so the remaining half-margin is
    /// being applied inside one of the two paths, not in the region. The numbers are printed in full
    /// so the fix starts from a measurement; the four sources are named beside each one.
    func testTheMarkersLandWhereTheStandInDrawsThem() throws {
        let url = try rawFixture()
        let (editor, assets) = try makeEditor(files: [url])
        let loupe = editor.rootView.loupeController
        editor.session.selectOnly(assets[0].id)
        pump(0.05)
        editor.session.mode = .loupe
        editor.rootView.showModule(for: .loupe)
        editor.session.applyEdit { model in
            model.geometry.perspectiveVertical = 40
            model.geometry.perspectiveHorizontal = -25
            model.geometry.rotationDegrees = 9
        }
        loupe.scheduleRender()
        pump(0.4)

        let viewport = loupe.viewportPixels
        let framing = try XCTUnwrap(loupe.framing(viewport: viewport))
        let canvas = framing.rotatedCropExtent
        let origin = framing.canvasOriginPixels
        let backing = max(1, loupe.backingScale)
        print(String(format: "344/@1 canvas rect (LoupeZoom.swift:771 rotatedCropExtent → "
                     + "CropMath.swift:671 perspectiveCanvas) %.2f×%.2f px · origin %@ "
                     + "(LoupeZoom.swift:711 canvasOriginPixels) %.2f,%.2f px",
                     canvas.width, canvas.height, origin.x == 0 && origin.y == 0 ? "= 0" : "≠ 0",
                     origin.x, origin.y))
        if let quad = loupe.presentedPictureQuad {
            print("344/@2 photoQuad (LoupeController.swift:7277 presentedPictureQuad, composed in "
                  + "\(#function)'s present path) x \(quad.x) y \(quad.y) "
                  + "w \(quad.width) h \(quad.height) device px")
        } else {
            print("344/@2 photoQuad — no present recorded yet")
        }

        // ── **364 — where the 303.67 px came from, and what it was not.** 344b measured this pair of
        // paths with the marker read as `rect.min + (u, v) · rect.size`, i.e. the photograph's own
        // (u, v) laid linearly into the stand-in's rectangle. That is only the right reading when the
        // stand-in's bitmap *is* the photograph — and it is not: `cachedCanvasPlaceholder` hands back
        // the render of the **export canvas** (at `(+40,−25)+9°` a 2097 × 1570 file, the canvas' 4:3,
        // not the 3:2 photograph). A marker therefore sits at its **canvas**-normalized position inside
        // the rectangle, which is `documentPointInCanvas(u, v) / canvas`, and the two paths then differ
        // by the rectangle alone. Measured: 303.67 / 299.21 px at 1× and 1214.69 / 1196.85 px at 4×
        // were one constant translation — the photograph's pixel size at the canvas' origin instead of
        // the canvas' own rect (`FrameTransform.frameRectInS5`, 364).
        let source = ImageSize(width: Int(framing.sourceWidth.rounded()),
                               height: Int(framing.sourceHeight.rounded()))
        let geometry = CropGeometry(geometry: editor.session.edit.geometry, source: source)
        let docOrigin = geometry.documentOrigin
        let documentCanvas = geometry.canvas(.document)
        print(String(format: "344/@1 documentOrigin (KeystoneQuad324.swift:341) %.2f,%.2f px"
                     + " · photoQuadExtent (:81) %.2f×%.2f · canvas %d×%d · source %d×%d",
                     docOrigin.x, docOrigin.y, geometry.photoQuadExtent.width,
                     geometry.photoQuadExtent.height, documentCanvas.width,
                     documentCanvas.height, source.width, source.height))

        let markers: [(x: Double, y: Double)] = [(450, 300), (1350, 900)]
        let sourceW = framing.sourceWidth, sourceH = framing.sourceHeight
        var photoRectWorst = 0.0
        for zoom in [1.0, 4.0] {
            let state = LoupeViewState(mode: .actual, zoom: zoom,
                                       centerX: sourceW / 2, centerY: sourceH / 2)
            let mapping = framing.mapping(of: state)
            // @1 the stand-in's rectangle in points: LoupeZoom.swift:970 contentRectInS5 →
            //    FrameTransform.swift frameRectInS5, divided by the backing scale.
            let standIn = loupe.placeholderContentRectForTesting(state: state)
            for marker in markers {
                let u = marker.x / sourceW, v = marker.y / sourceH
                // The same source marker on the canvas, then read off the installed rectangle.
                let canvasPoint = geometry.documentPointInCanvas(normalizedX: u, v)
                let cu = canvasPoint.x / Double(documentCanvas.width)
                let cv = canvasPoint.y / Double(documentCanvas.height)
                // The frame's own projection: LoupeZoom.swift:1058 mapping(of:) → :972 viewPoint.
                let p = mapping.viewPoint(sourceX: marker.x, sourceY: marker.y)
                let fx = p.x / backing, fy = p.y / backing
                let sx = standIn.minX + cu * standIn.width
                let sy = standIn.minY + cv * standIn.height
                let delta = max(abs(fx - sx), abs(fy - sy))
                // The pre-364 reading — the photograph's (u, v) laid into the same rectangle — is the
                // number the report quotes, and it is the reverse gate: it must stay far away.
                let photoX = standIn.minX + u * standIn.width
                let photoY = standIn.minY + v * standIn.height
                photoRectWorst = max(photoRectWorst,
                                     max(abs(fx - photoX), abs(fy - photoY)))
                print(String(format: "344/@3 %.0f× marker (%.0f,%.0f) · frame projection %.2f,%.2f"
                             + " · stand-in %.2f,%.2f · Δ %.3f px · photo-rect reading Δ %.2f px",
                             zoom, marker.x, marker.y, fx, fy, sx, sy, delta,
                             max(abs(fx - photoX), abs(fy - photoY))))
                XCTAssertLessThanOrEqual(delta, 0.5,
                                         "the stand-in puts marker (\(marker.x),\(marker.y)) "
                                         + "\(delta) px from the canvas projection at \(zoom)×")
            }
        }
        // Reverse gate ④: reading the marker as the photograph's (u, v) — 344b's instrument — must be
        // off by a few hundred px, or the alignment above proves nothing about the rectangle.
        XCTAssertGreaterThan(photoRectWorst, 100,
                             "the photograph-relative reading agreed to \(photoRectWorst) px — the gate "
                             + "above is not measuring the rectangle the stand-in is installed in")
    }

    // MARK: - ④ a cold switch never shows nothing

    /// Twelve cold switches, then the same twelve warm. Cold: **the canvas is populated in the same
    /// turn** and the stand-in, when it is what is on screen, settles at 1920×1278; warm: it is 1920
    /// on the first read, 12/12.
    ///
    /// **364 — this test used to skip.** The 344b harness measured 12 violations and threw `XCTSkip`,
    /// which is the one thing an acceptance may not do. What it was measuring, switch by switch, is
    /// now asserted as the claim the user actually has (「切图不能空窗」), and the two places the
    /// 1920 rung is *not* reached are explained by the call chain rather than excused:
    ///
    ///   · `armFirstFramePlaceholder` (`LoupeController.swift:5860`) returns early when
    ///     `presentedPhoto == identity` — a frame for **this** picture already owns the layer, so
    ///     there is no stand-in to arm and nothing to upgrade. All twelve rows are symlinks over one
    ///     file, so they share one ladder identity: after the first frame lands, the canvas is not
    ///     empty, it holds the real (or previous, identical) frame.
    ///   · `installFirstFramePlaceholder` refuses once `presentedPhoto == photo`, so the 1920 warm
    ///     that `upgradeStandIn` requests cannot replace a frame that has already presented. That is
    ///     the rule that keeps a stand-in from outliving the real frame, and it is why switch 0 can
    ///     sit at the 256 rung with a *frame* on the canvas rather than a 1920 stand-in.
    ///
    /// Every switch prints the three facts the conclusion rests on: the stand-in's size at the
    /// instant, `presentedPhoto`, and whether a `lastFrame` is on the canvas.
    func testColdSwitchHasAStandInAndSettlesAt1920() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let url = try rawFixture()
        let files = Array(repeating: url, count: 12)
        let (editor, assets) = try makeEditor(files: files)
        let loupe = editor.rootView.loupeController
        editor.session.mode = .loupe
        editor.rootView.showModule(for: .loupe)
        pump(0.1)

        var transients: [String] = []
        var coldStable: [Double] = []
        var empty: [Int] = []
        var stuck: [String] = []
        for (index, asset) in assets.enumerated() {
            let started = CACurrentMediaTime()
            editor.session.selectOnly(asset.id)
            let instant = loupe.firstFramePlaceholderPixels
            let presented = loupe.currentPresentedPhotoForTesting
            let frameOnCanvas = loupe.lastFrame != nil
            let visible = loupe.firstFramePlaceholderVisible
            if instant == nil && !frameOnCanvas && !visible { empty.append(index) }
            var best = instant
            let deadline = Date().addingTimeInterval(45)
            var settled = false
            while Date() < deadline {
                if let size = loupe.firstFramePlaceholderPixels,
                   max(size.width, size.height) > max(best?.width ?? 0, best?.height ?? 0) {
                    best = size
                }
                if let size = best, size.width == 1920 && size.height == 1278 { settled = true; break }
                pump(0.01)
            }
            let frameNow = loupe.currentPresentedPhotoForTesting != nil
            // The 1920 rung is owed while the stand-in is the thing on the canvas. Once a frame has
            // presented, `installFirstFramePlaceholder` refuses by design and the stand-in's size stops
            // mattering — the canvas is the picture.
            if !settled && !frameNow {
                stuck.append("switch \(index): settled at "
                             + "\(best.map { "\($0.width)×\($0.height)" } ?? "nil")")
            }
            coldStable.append((CACurrentMediaTime() - started) * 1000)
            transients.append("\(index): \(instant.map { "\($0.width)×\($0.height)" } ?? "nil")"
                              + " · presented \(presented == nil ? "nil" : "set")"
                              + " · frame \(frameOnCanvas ? "yes" : "no")"
                              + " → \(best.map { "\($0.width)×\($0.height)" } ?? "nil")"
                              + (frameNow ? " (frame took the canvas)" : ""))
        }
        print("344 cold · " + transients.joined(separator: " · "))
        print(String(format: "344 cold · %d/12 clean · mean %.0f ms · max %.0f ms",
                     coldStable.count - empty.count - stuck.count,
                     coldStable.reduce(0, +) / Double(max(1, coldStable.count)), coldStable.max() ?? 0))
        XCTAssertEqual(empty, [], "344 cold ④: a cold switch left the canvas empty")
        XCTAssertEqual(stuck, [], "344 cold ④: the stand-in never reached the 1920 rung while it was "
                       + "the only thing on the canvas")

        // ── warm: the 1920 file is on disk, so the stand-in is 1920 on the first read, 12/12.
        var warmInstant: [String] = []
        for (index, asset) in assets.enumerated() {
            editor.session.selectOnly(asset.id)
            guard let size = loupe.firstFramePlaceholderPixels else {
                // The frame already owns the canvas (see the doc comment): the stand-in is not owed.
                warmInstant.append(loupe.lastFrame != nil ? "frame" : "nil")
                continue
            }
            warmInstant.append("\(size.width)×\(size.height)")
            if size.width != 1920 || size.height != 1278 {
                stuck.append("warm switch \(index): \(size.width)×\(size.height)")
            }
        }
        print("344 warm · instant " + warmInstant.joined(separator: " · "))
        XCTAssertEqual(warmInstant.filter { $0 == "1920×1278" }.count, 12,
                       "344 warm: the 1920 file is on disk, so all twelve reads must be 1920 — measured "
                       + warmInstant.joined(separator: ", "))
        XCTAssertEqual(stuck, [], "344 cold ④: \(stuck.joined(separator: "; "))")
    }

    // MARK: - a library of real files

    private func makeEditor(files: [URL]) throws -> (EditorWindowController, [Asset]) {
        let library = try makeLibrary(files: files)
        let editor = EditorWindowController(size: NSSize(width: 1200, height: 800))
        windows.append(editor.window!)
        try editor.openLibrary(at: library.package)
        let cache = try XCTUnwrap(editor.session.thumbnailCache, "the library has no thumbnail cache")
        for asset in library.assets { try seedPreview(asset, cache: cache) }
        TestWindows.show(editor.window)
        editor.window?.contentView?.layoutSubtreeIfNeeded()
        editor.rootView.needsLayout = true
        editor.rootView.layoutSubtreeIfNeeded()
        pump(0.05)
        return (editor, library.assets)
    }

    private struct Library {
        let package: URL
        let assets: [Asset]
    }

    /// Twelve rows over the same fixture file (symlinks), with the **real** pixel size and byte size —
    /// the stand-in's upgrade path is gated on `size > 1024` and the HD render needs the file.
    private func makeLibrary(files: [URL]) throws -> Library {
        _ = NSApplication.shared
        let package = workDir.appendingPathComponent("LowRes344.\(LibraryLayout.packageExtension)")
        let catalog = try Catalog.create(at: package)
        let source = workDir.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let root = try catalog.ensureRoot(for: source, mode: .reference)

        var ids: [String] = []
        for (index, file) in files.enumerated() {
            let name = "lowres\(index).dng"
            let destination = source.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: file)
            let size = try pixelSize(of: file)
            let bytes = (try FileManager.default.attributesOfItem(atPath: file.path)[.size]
                as? NSNumber)?.intValue ?? 1
            let id = UUID().uuidString
            ids.append(id)
            try catalog.dbQueue.write { db in
                try db.execute(sql: """
                    INSERT INTO assets (id, source_root_id, rel_path, filename, ext, kind, size, mtime,
                                        content_hash, width, height, camera_make, camera_model, lens,
                                        imported_at, missing)
                    VALUES ('\(id)', '\(root.id)', '\(name)', '\(name)', 'dng', 'raw', \(bytes), 0,
                            '\(UUID().uuidString)',
                            \(size.width), \(size.height),
                            'Leica Camera AG', 'Leica SL3', 'Vario-Elmarit-SL 24-90',
                            '2026-11-10T00:00:00Z', 0)
                    """)
            }
        }
        let assets = try ids.map { try XCTUnwrap(try catalog.asset(id: $0)) }
        return Library(package: package, assets: assets)
    }

    /// The **256** rung the grid would have written first, so the cold switch's first read is the
    /// acceptance' 256×170 transient and not a generated preview.
    private func seedPreview(_ asset: Asset, cache: ThumbnailCache) throws {
        let width = 256, height = 170
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
                                              bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.72, green: 0.45, blue: 0.22, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let data = try XCTUnwrap(NSBitmapImageRep(cgImage: image)
            .representation(using: .jpeg, properties: [.compressionFactor: 0.8]))
        try cache.store(data, for: .preview(contentHash: asset.contentHash, tier: .t256))
    }

    private func pixelSize(of url: URL) throws -> ImageSize {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let width = try XCTUnwrap(properties[kCGImagePropertyPixelWidth] as? Int)
        let height = try XCTUnwrap(properties[kCGImagePropertyPixelHeight] as? Int)
        return ImageSize(width: width, height: height)
    }
}
