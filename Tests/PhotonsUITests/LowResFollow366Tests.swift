import XCTest
import AppKit
import CryptoKit
import ImageIO
import Metal
import QuartzCore
import PhotonsCatalog
@testable import PhotonsCore
@testable import PhotonsUI

/// 366 — 全尺寸低清预览必须同时跟上「透视校正」和「裁切」，缩放过渡帧用的必须是这张文档自己的低清图。
///
/// The user's sentence: 「透视校正+裁切后的全尺寸低清预览没有跟着透视校正，或者没有跟着裁切，
/// 导致缩放时过渡用的图像不对」. This suite measures the four documents the dispatch names —
/// A 原样 / B 只裁切 / C 只透视 / D 透视+裁切 — through the shipped paths (`CatalogSession` document
/// writes, `backdropKey`, `ensureLowResFullFrame`, `LoupeFraming.framePlacement`, the real canvas),
/// and it turns both halves red on purpose with the two reverse gates.
@MainActor
final class LowResFollow366Tests: XCTestCase {

    private static let crop = CropRect(x: 0.10, y: 0.10, width: 0.60, height: 0.80)
    private static let keystone = (v: 40.0, h: -25.0)
    private static let steps = ["A 原样", "B 只裁切", "C 只透视", "D 透视+裁切"]

    private var workDir: URL!
    private var windows: [NSWindow] = []

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-366-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        LoupeController.backdropKeyIgnoresCrop = false
        LoupeController.backdropPlacementIgnoresCrop = false
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
        workDir = nil
    }

    // MARK: - fixtures

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

    /// Report lines go to stderr: `swift test` buffers a passing test's stdout, so a measurement that
    /// only exists on stdout is a measurement nobody can quote. `XCTest` never swallows stderr.
    private func note(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
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
        let package = workDir.appendingPathComponent("LowRes366.\(LibraryLayout.packageExtension)")
        let catalog = try Catalog.create(at: package)
        let source = workDir.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let root = try catalog.ensureRoot(for: source, mode: .reference)
        let destination = source.appendingPathComponent("lowres366.dng")
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
                VALUES ('\(id)', '\(root.id)', 'lowres366.dng', 'lowres366.dng', 'dng', 'raw',
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
        loupe.hashesFrames = true
        loupe.scheduleRender()
        pump(0.1)
        XCTAssertTrue(waitFor { loupe.lastFrame != nil }, "no first frame")
        return editor
    }

    private func pixelSize(of url: URL) throws -> ImageSize {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let width = try XCTUnwrap(properties[kCGImagePropertyPixelWidth] as? Int)
        let height = try XCTUnwrap(properties[kCGImagePropertyPixelHeight] as? Int)
        return ImageSize(width: width, height: height)
    }

    private func apply(_ edit: EditModel, to editor: EditorWindowController) {
        editor.session.applyEdit { model in
            model.geometry.crop = edit.geometry.crop
            model.geometry.aspectLock = edit.geometry.aspectLock
            model.geometry.perspectiveVertical = edit.geometry.perspectiveVertical
            model.geometry.perspectiveHorizontal = edit.geometry.perspectiveHorizontal
            model.geometry.rotationDegrees = edit.geometry.rotationDegrees
            model.geometry.quarterTurns = edit.geometry.quarterTurns
        }
        editor.rootView.loupeController.scheduleRender()
    }

    /// One of the four documents, from the dispatch.
    private func document(_ name: String) -> EditModel {
        var edit = EditModel.neutral
        switch name {
        case "B 只裁切":
            edit.geometry.crop = Self.crop.normalizedRect
        case "C 只透视":
            edit.geometry.perspectiveVertical = Self.keystone.v
            edit.geometry.perspectiveHorizontal = Self.keystone.h
        case "D 透视+裁切":
            edit.geometry.crop = Self.crop.normalizedRect
            edit.geometry.perspectiveVertical = Self.keystone.v
            edit.geometry.perspectiveHorizontal = Self.keystone.h
        default:
            break
        }
        return edit
    }

    /// Settle the low-res whole picture for the document on screen.
    ///
    /// Retries the explicit door while it has nothing to do with the wait: the first frame's graph may
    /// still be landing, and 039's gate refuses while a generation is in flight. No long sleep — the
    /// condition is polled.
    @discardableResult
    private func settleLowRes(_ loupe: LoupeController, timeout: TimeInterval = 60) -> BackdropCache.Key? {
        guard let key = loupe.backdropKeyForTesting else { return nil }
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if loupe.backdrop.key == key && loupe.lowResFullFrame != nil { return key }
            if loupe.backdrop.isIdle { _ = loupe.ensureLowResFullFrame() }
            pump()
        }
        XCTFail("no low-res frame (\(loupe.backdrop.lastError ?? "—"))")
        return nil
    }

    private func read(_ texture: MTLTexture) -> [UInt16] {
        let w = texture.width, h = texture.height
        var raw = [UInt16](repeating: 0, count: w * h * 4)
        raw.withUnsafeMutableBytes { buffer in
            texture.getBytes(buffer.baseAddress!, bytesPerRow: w * 8,
                             from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        }
        return raw
    }

    private func sha(_ texture: MTLTexture) -> String {
        var hasher = SHA256()
        read(texture).withUnsafeBufferPointer {
            hasher.update(bufferPointer: UnsafeRawBufferPointer($0))
        }
        return hasher.finalize().prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    /// The sha of what a window **reads** out of a texture — a 16 × 16 nearest-neighbour grid, so two
    /// windows that sample different parts of one picture get different strings (the full-texture sha
    /// cannot see a misplaced window).
    private func windowedSha(_ codes: [UInt16], texture: MTLTexture,
                             window: PresentWindow) -> String {
        let w = texture.width, h = texture.height
        var hasher = SHA256()
        let n = 16
        for j in 0..<n {
            for i in 0..<n {
                let u = Double(window.u0) + (Double(i) + 0.5) / Double(n) * Double(window.du)
                let v = Double(window.v0) + (Double(j) + 0.5) / Double(n) * Double(window.dv)
                let x = min(max(Int(u * Double(w)), 0), w - 1)
                let y = min(max(Int(v * Double(h)), 0), h - 1)
                let o = (y * w + x) * 4
                var bytes = [UInt16](codes[o..<o + 4])
                bytes.withUnsafeBufferPointer {
                    hasher.update(bufferPointer: UnsafeRawBufferPointer($0))
                }
            }
        }
        return hasher.finalize().prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    private static func rect(_ w: PresentWindow) -> String {
        String(format: "%.4f,%.4f %.4f×%.4f", w.u0, w.v0, w.du, w.dv)
    }

    // MARK: - ① the one fingerprint names every dimension the render reads

    /// **`GeometryGroup.geometryFingerprint`** is the single function `366` rests on: it must name
    /// `crop`/`rot`/`flip`/`q`/`pvy`/`phx`/`cs` — every field the renderer's S0 takes from the
    /// document — and it may answer `""` only when all of them are neutral.
    func testTheFingerprintNamesEveryGeometryDimension() {
        var edit = EditModel.neutral
        XCTAssertEqual(edit.geometry.geometryFingerprint, "",
                       "a neutral document must keep the pre-344 key")
        XCTAssertTrue(edit.geometry.hasNeutralGeometry)

        var crop = edit
        crop.geometry.crop = Self.crop.normalizedRect
        XCTAssertEqual(crop.geometry.geometryFingerprint,
                       "crop=0.10000,0.10000,0.60000,0.80000;rot=0.00000;flip=00",
                       "366: a plain source-spaced crop is in the fingerprint, not only in the digest")

        var rot = edit
        rot.geometry.rotationDegrees = 4.5
        var flip = edit
        flip.geometry.flipHorizontal = true
        var quarter = edit
        quarter.geometry.turn(clockwise: true)
        var pvy = edit
        pvy.geometry.perspectiveVertical = 40
        var phx = edit
        phx.geometry.perspectiveHorizontal = -25
        var spaced = edit
        spaced.geometry.cropSpace = .canvas

        let dimensions: [(String, EditModel, String)] = [
            ("crop", crop, "crop=0.10000,0.10000,0.60000,0.80000"),
            ("rot", rot, ";rot=4.50000"),
            ("flip", flip, ";flip=10"),
            ("q", quarter, ";q=1"),
            ("pvy", pvy, ";pvy=400"),
            ("phx", phx, ";phx=-250"),
            ("cs", spaced, ";cs=1"),
        ]
        for (name, document, token) in dimensions {
            let fingerprint = document.geometry.geometryFingerprint
            XCTAssertFalse(fingerprint.isEmpty, "\(name): geometry is invisible to the fingerprint")
            XCTAssertTrue(fingerprint.contains(token),
                          "\(name): fingerprint \(fingerprint) does not name \(token)")
            note("366 fingerprint · \(name) → \(fingerprint)")
        }

        // The digest is the other half and it moves for every one of them too — the fingerprint is
        // there to *name* what moved, not to replace the digest.
        let digests = [edit, crop, rot, flip, quarter, pvy, phx, spaced]
            .map(Histogram.editDigest)
        XCTAssertEqual(Set(digests).count, digests.count, "a dimension does not move the digest")
    }

    // MARK: - ② A/B/C/D: key, digest, pixels, framing

    /// The four documents, each measured through the shipped pipeline: the key string, the digest,
    /// the low-res bitmap (size + sha of every texel), and the 1× framing the display uses.
    func testFourGeometriesFollowTheDocument() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let editor = try makeEditor(url: try rawFixture())
        let loupe = editor.rootView.loupeController
        defer { for window in windows { window.orderOut(nil) } }

        var keys: [String] = [], digests: [String] = [], sizes: [String] = []
        var shas: [String] = [], regions: [String] = []
        for name in Self.steps {
            apply(document(name), to: editor)
            guard let key = settleLowRes(loupe) else { return XCTFail("\(name): no key") }
            let low = try XCTUnwrap(loupe.lowResFullFrame)
            let framing = try XCTUnwrap(loupe.framing(), "\(name): no framing")
            let state = LoupeViewState(mode: .actual, zoom: 1,
                                       centerX: framing.sourceWidth / 2,
                                       centerY: framing.sourceHeight / 2)
            let placement = framing.framePlacement(of: framing.mapping(of: state))
            let region = String(format: "%.5f,%.5f %.5f×%.5f", placement.region.left,
                                placement.region.top, placement.region.width,
                                placement.region.height)
            keys.append(key.identity)
            digests.append(Histogram.editDigest(editor.session.edit))
            sizes.append("\(low.texture.width)×\(low.texture.height)")
            shas.append(sha(low.texture))
            regions.append(region)
            note("366 · \(name) · key=\(key.identity)")
            note("366 · \(name) · digest=\(digests.last!) geo=\(key.geometry.isEmpty ? "—" : key.geometry)")
            note("366 · \(name) · \(sizes.last!) · sha \(shas.last!) · 1x region \(region)")
        }
        // A must stay the pre-344 key: neutral geometry appends nothing.
        XCTAssertFalse(keys[0].contains("|geo="),
                       "366: A grew a geometry token — the neutral key moved")
        XCTAssertEqual(Set(keys).count, 4, "the four documents must be four keys")
        XCTAssertEqual(Set(digests).count, 4, "the four documents must be four digests")
        XCTAssertEqual(Set(shas).count, 4, "the four documents must be four pictures")
        XCTAssertGreaterThanOrEqual(Set(sizes).count, 3,
                                    "perspective and crop must move the bitmap's size, got \(sizes)")
        XCTAssertEqual(Set(regions).count, 4, "the four documents must be four framings")
        // Perspective must move the bitmap even at the same crop, crop must move it at the same
        // keystone: the two dimensions are independent halves of the same claim.
        XCTAssertNotEqual(sizes[0], sizes[2], "keystone (+40,−25) did not move the bitmap size")
        XCTAssertNotEqual(shas[0], shas[1], "the crop did not move the bitmap")
        XCTAssertNotEqual(shas[2], shas[3], "the crop did not move the keystoned bitmap")
        XCTAssertNotEqual(regions[0], regions[1], "the crop did not move the display framing")
        XCTAssertNotEqual(regions[2], regions[3], "the crop did not move the keystoned display framing")
    }

    // MARK: - ②b the low-res picture is this document's own render

    /// The pixels half of 「一个来源」: for A, B and D the cached whole picture must equal an
    /// **independent** `RenderGraph` render of the very document `backdropKey` names, from the same
    /// decoded rung at the same scale — code for code. That is how "the file followed the crop and the
    /// keystone" is measured rather than inferred from a changed sha.
    func testTheLowResPictureIsTheDocumentsOwnRender() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let url = try rawFixture()
        let editor = try makeEditor(url: url)
        let loupe = editor.rootView.loupeController
        defer { for window in windows { window.orderOut(nil) } }

        for name in ["A 原样", "B 只裁切", "D 透视+裁切"] {
            apply(document(name), to: editor)
            _ = settleLowRes(loupe)
            let low = try XCTUnwrap(loupe.lowResFullFrame)
            let scale = loupe.backdrop.lastScale
            let rung = loupe.backdrop.lastRungScale
            let reference = try referenceRender(loupe: loupe, edit: editor.session.edit,
                                                url: url, scale: scale)
            let delta = Self.maxCodeDelta(low.texture, reference)
            note(String(format: "366 render · %@ · %d×%d vs %d×%d · scale %.4f rung %.3f · max|Δ| %d",
                         name, low.texture.width, low.texture.height,
                         reference.width, reference.height, scale, Double(rung), delta))
            XCTAssertEqual(low.texture.width, reference.width, "\(name): different canvases")
            XCTAssertEqual(low.texture.height, reference.height, "\(name): different canvases")
            XCTAssertEqual(delta, 0, "\(name): the low-res picture is not the document's render "
                           + "(\(delta) code values)")
        }
    }

    private func referenceRender(loupe: LoupeController, edit: EditModel, url: URL,
                                 scale: Double) throws -> MTLTexture {
        let decoded = try XCTUnwrap(loupe.decodedForTesting, "the loupe has no decoded rung")
        let graph = try RenderGraph(input: RenderInput(image: decoded,
                                                       identity: "366-ref|\(Histogram.editDigest(edit))",
                                                       sourceURL: url,
                                                       whiteBalance: edit.decodeInputs.whiteBalance),
                                    textureRetention: .none)
        defer { graph.releaseAllTextures() }
        let result = try graph.render(edit, options: RenderOptions(
            canvasRole: .export,
            scale: scale,
            display: DisplayOptions(primaries: .displayP3, bitDepth: 16,
                                    headroom: loupe.headroom,
                                    highlightCeiling: HighlightCeiling.current),
            useCache: false, wantsPixels: false))
        return try XCTUnwrap(result.output, "the reference render produced no texture")
    }

    private static func maxCodeDelta(_ a: MTLTexture, _ b: MTLTexture) -> Int {
        guard a.width == b.width, a.height == b.height else { return Int.max }
        let ac = codes(a), bc = codes(b)
        var worst = 0
        for i in ac.indices {
            let d = abs(Int(ac[i]) - Int(bc[i]))
            if d > worst { worst = d }
        }
        return worst
    }

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

    // MARK: - ③ the transition uses this document's low-res frame

    /// Fit → 100 % → 适应, for each document. The transition's 5+ frames must sample the **same**
    /// low-res whole picture as the settled pose (same texture identity, same full sha); the window
    /// rect is the animation and is expected to move. No whole-picture render may start because of
    /// the zoom (`344`/`326`'s rule).
    func testTheTransitionCarriesTheDocumentsOwnLowResFrame() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let editor = try makeEditor(url: try rawFixture())
        let loupe = editor.rootView.loupeController
        defer { for window in windows { window.orderOut(nil) } }

        for name in Self.steps {
            apply(document(name), to: editor)
            guard let key = settleLowRes(loupe) else { return XCTFail("\(name): no key") }
            var low = try XCTUnwrap(loupe.lowResFullFrame)
            let restSha = sha(low.texture)
            let restSize = "\(low.texture.width)×\(low.texture.height)"
            note("366 transition · \(name) · rest \(restSize) sha \(restSha)")

            // ── fit → 100 %: sample the bridge's own frames. The held frame covers the canvas, so the
            //    low picture is not asked for (that is 039's rule), and the whole-picture cache must not
            //    move because a zoom happened.
            let generations = loupe.backdrop.generationCount
            let framesBefore = loupe.zoomBridgeFrames.count
            loupe.zoomToActualSize()
            XCTAssertTrue(waitFor { abs((loupe.lastFrame?.zoom ?? -1) - 1) < 1e-9 },
                          "\(name): no 100 % frame")
            XCTAssertTrue(waitFor { loupe.zoomBridge == nil }, "\(name): bridge never ended")
            let zoomFrames = Array(loupe.zoomBridgeFrames.dropFirst(framesBefore))
            let sample = stride(from: 0, to: zoomFrames.count, by: max(1, zoomFrames.count / 5))
                .prefix(5).map { zoomFrames[$0] }
            let inWindows = sample.map { Self.rect($0.window) }
            note("366 transition · \(name) · fit→100 % \(zoomFrames.count) frames · "
                  + "sample windows \(inWindows)")
            XCTAssertFalse(sample.isEmpty, "\(name): the fit → 100 % crossing presented no frame")
            XCTAssertEqual(loupe.backdrop.generationCount, generations,
                           "\(name): zooming started a whole-picture render")

            // The camera change can make the document migrate to canvas space (330) on a keystoned
            // document; let the one coalesced rebuild land so the transition below is measured on a
            // settled document, not mid-rewrite.
            pump(0.4)
            if loupe.backdropKeyForTesting != key {
                // A migration moved the document. Let the door rebuild and re-read the settled frame.
                _ = settleLowRes(loupe)
                low = try XCTUnwrap(loupe.lowResFullFrame)
            }
            let stableKey = try XCTUnwrap(loupe.backdropKeyForTesting)
            let stableSha = sha(low.texture)
            let stableID = ObjectIdentifier(low.texture)
            note("366 transition · \(name) · stable \(low.texture.width)×\(low.texture.height) "
                  + "sha \(stableSha)")

            // ── 100 % → 适应: the crossing where the whole picture is actually drawn.
            let before = loupe.backdropPresents.count
            loupe.zoomToFit()
            _ = waitFor(5, {
                loupe.backdropPresents.dropFirst(before).filter { $0.backdropIdentity != nil }.count >= 6
            })
            XCTAssertTrue(waitFor { loupe.zoomBridge == nil }, "\(name): bridge never ended")
            let presents = Array(loupe.backdropPresents.dropFirst(before))
            let drawn = presents.compactMap { present -> (String, ObjectIdentifier, String)? in
                guard let id = present.backdropIdentity else { return nil }
                return (Self.rect(present.backdropWindow), id, Self.rect(present.window))
            }
            note("366 transition · \(name) · 100 %→fit \(drawn.count) backdrop frames · "
                  + drawn.map { "rect \($0.0) from frame \($0.2)" }.joined(separator: " · "))
            XCTAssertGreaterThanOrEqual(drawn.count, 5,
                                        "\(name): fewer than 5 transition frames carry the backdrop")
            XCTAssertTrue(drawn.allSatisfy { $0.1 == stableID },
                          "\(name): a transition frame drew another picture's low-res frame")
            XCTAssertEqual(loupe.backdrop.key, stableKey)
            XCTAssertEqual(sha(try XCTUnwrap(loupe.backdrop.texture)), stableSha,
                           "\(name): the transition's picture is not the settled one")
            XCTAssertEqual(Set(drawn.map { $0.0 }).count, drawn.count,
                           "\(name): the transition's rects did not animate")
        }
    }

    // MARK: - ④ reverse gate ①: the key without its crop half

    /// The fingerprint's crop half is load-bearing: with the key built from a full-crop copy (the
    /// pre-366 key), a crop **keeps** the previous key, nothing is regenerated, and the stale whole
    /// picture is served. That is the B step of 验收 ② turned red on purpose.
    func testTheCropIsLoadBearingInTheKey() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let editor = try makeEditor(url: try rawFixture())
        let loupe = editor.rootView.loupeController
        defer { for window in windows { window.orderOut(nil) } }

        apply(document("A 原样"), to: editor)
        let aKey = try XCTUnwrap(settleLowRes(loupe))
        let aSha = sha(try XCTUnwrap(loupe.lowResFullFrame?.texture))
        let generations = loupe.backdrop.generationCount
        note("366 reverse ① · A key \(aKey.identity) · sha \(aSha)")

        LoupeController.backdropKeyIgnoresCrop = true
        apply(document("B 只裁切"), to: editor)
        pump(0.5)
        let gatedKey = try XCTUnwrap(loupe.backdropKeyForTesting)
        note("366 reverse ① · B key (crop blind) \(gatedKey.identity) · generations "
              + "\(loupe.backdrop.generationCount) (was \(generations))")
        XCTAssertEqual(gatedKey, aKey, "the gate is not the pre-366 key")
        XCTAssertEqual(loupe.backdrop.generationCount, generations,
                       "a generation ran, so no stale picture was served")
        XCTAssertEqual(sha(try XCTUnwrap(loupe.lowResFullFrame?.texture)), aSha,
                       "the gate did not serve the stale picture")
        XCTAssertNotEqual(Histogram.editDigest(editor.session.edit),
                          Histogram.editDigest(document("A 原样")),
                          "the document did not actually gain a crop — the gate proves nothing")
    }

    // MARK: - ④ reverse gate ②: the display without its crop transform

    /// The display-side crop transform is load-bearing too: with the placement ignored, the first
    /// transition frame reads the whole low picture where the settled frame reads a crop of it, so
    /// the rects **and** the windowed content shas disagree. Both numbers are printed.
    func testTheCropIsLoadBearingOnTheDisplay() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let editor = try makeEditor(url: try rawFixture())
        let loupe = editor.rootView.loupeController
        defer { for window in windows { window.orderOut(nil) } }

        apply(document("B 只裁切"), to: editor)
        _ = settleLowRes(loupe)
        loupe.zoomToActualSize()
        XCTAssertTrue(waitFor { loupe.zoomBridge == nil && abs((loupe.lastFrame?.zoom ?? -1) - 1) < 1e-9 },
                      "no 100 % frame")

        // ── the shipped transform: 100 % → 适应, first frame that draws the backdrop.
        let before = loupe.backdropPresents.count
        loupe.zoomToFit()
        XCTAssertTrue(waitFor { loupe.backdropPresents.dropFirst(before).contains { $0.backdropIdentity != nil } },
                      "the transition never drew the backdrop")
        let correct = try XCTUnwrap(loupe.backdropPresents.dropFirst(before)
            .first { $0.backdropIdentity != nil })
        XCTAssertTrue(waitFor { loupe.zoomBridge == nil }, "bridge never ended")
        let rest = try XCTUnwrap(loupe.lowResFullFrame)
        let codes = read(rest.texture)
        let correctRect = Self.rect(correct.backdropWindow)
        let correctSha = windowedSha(codes, texture: rest.texture, window: correct.backdropWindow)
        let frameRect = Self.rect(correct.window)
        note("366 reverse ② · shipped · transition rect \(correctRect) · frame \(frameRect) "
              + "· content sha \(correctSha)")

        // ── the gate: the same crossing, the placement ignored.
        LoupeController.backdropPlacementIgnoresCrop = true
        loupe.zoomToActualSize()
        XCTAssertTrue(waitFor { loupe.zoomBridge == nil && abs((loupe.lastFrame?.zoom ?? -1) - 1) < 1e-9 },
                      "no second 100 % frame")
        let gatedBefore = loupe.backdropPresents.count
        loupe.zoomToFit()
        XCTAssertTrue(waitFor { loupe.backdropPresents.dropFirst(gatedBefore)
            .contains { $0.backdropIdentity != nil } }, "the gated transition never drew the backdrop")
        let gated = try XCTUnwrap(loupe.backdropPresents.dropFirst(gatedBefore)
            .first { $0.backdropIdentity != nil })
        XCTAssertTrue(waitFor { loupe.zoomBridge == nil }, "gated bridge never ended")
        let gatedRect = Self.rect(gated.backdropWindow)
        let gatedSha = windowedSha(codes, texture: rest.texture, window: gated.backdropWindow)
        note("366 reverse ② · gate · transition rect \(gatedRect) · content sha \(gatedSha)")

        XCTAssertEqual(gated.backdropWindow, gated.window,
                       "the gate is not 'ignore the placement'")
        XCTAssertNotEqual(gatedRect, correctRect,
                          "ignoring the crop produced the same rect — the crop is not in the transform")
        XCTAssertNotEqual(gatedSha, correctSha,
                          "ignoring the crop sampled the same content — the rect difference is cosmetic")
    }

    // MARK: - ⑤ a crop commit: one generation, and the transition sees it

    /// 验收 ⑥: from a crop commit to the correct whole picture — the milliseconds and the generation
    /// count. The commit coalesces through 344's 0.25 s window, so the number includes it; the zoom
    /// that follows must add **no** generation (`344`/`326`'s no-render-during-zoom rule).
    func testACropCommitRebuildsOneGenerationAndTheTransitionSeesIt() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let editor = try makeEditor(url: try rawFixture())
        let loupe = editor.rootView.loupeController
        defer { for window in windows { window.orderOut(nil) } }

        apply(document("A 原样"), to: editor)
        _ = settleLowRes(loupe)
        pump(0.4)
        let generations = loupe.backdrop.generationCount

        let started = CACurrentMediaTime()
        editor.session.applyEdit { model in
            model.geometry.crop = CropRect(x: 0.15, y: 0.12, width: 0.55, height: 0.70).normalizedRect
        }
        let croppedKey = try XCTUnwrap(loupe.backdropKeyForTesting)
        XCTAssertTrue(waitFor(10, { loupe.backdrop.key == croppedKey && loupe.lowResFullFrame != nil }),
                      "the crop commit never produced its own whole picture")
        let milliseconds = (CACurrentMediaTime() - started) * 1000
        let built = loupe.backdrop.generationCount - generations
        note(String(format: "366 timing · crop commit → correct low-res %.1f ms · %d generation(s)",
                     milliseconds, built))

        // The transition that follows must not render the whole picture again.
        let beforeZoom = loupe.backdrop.generationCount
        loupe.zoomToActualSize()
        XCTAssertTrue(waitFor { loupe.zoomBridge == nil && abs((loupe.lastFrame?.zoom ?? -1) - 1) < 1e-9 },
                      "no 100 % frame")
        loupe.zoomToFit()
        XCTAssertTrue(waitFor { loupe.zoomBridge == nil }, "bridge never ended")
        let duringZoom = loupe.backdrop.generationCount - beforeZoom
        note("366 timing · zoom fit↔100 % → \(duringZoom) whole-picture generation(s)")
        XCTAssertEqual(built, 1, "a commit must rebuild exactly one generation")
        XCTAssertEqual(duringZoom, 0, "the zoom rendered the whole picture again")
    }
}
