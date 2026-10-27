import XCTest
import AppKit
import Metal
import PhotonsCatalog
@testable import PhotonsCore
@testable import PhotonsUI

/// ④ — 拉直之后，全幅低清渲染的图也要跟着旋转.
///
/// Two halves, because the bug had two:
///
///   1. **the key.** `backdropKey` was built from `currentEdit` (the *document*) while `makeJob` —
///      the pixels — used `cropTool.previewEdit(...)` (the *draft*). So a 拉直 moved the sharp frame
///      and left the low-resolution one keyed as "nothing changed": the old texture kept being drawn,
///      at 0°, and zooming out showed the picture straighten itself.
///   2. **the pixels.** Both paths already go through the same `RenderGraph.render(edit, …)`; once
///      the edit is the same, the angle is the same. That half is measured on a synthetic line: the
///      slope of the line in the low-resolution frame and in the 1:1 frame has to agree (≤0.5 %), and
///      the anti-proof — the same low-resolution render with the rotation stripped — must not.
@MainActor
final class BackdropStraightenTests: XCTestCase {

    private var workDir: URL!
    private var window: NSWindow?

    /// 9° is the user's own number, and it is the angle that makes a horizontal line unmistakable.
    private static let angle = 9.0

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-backdrop-straighten-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        window?.orderOut(nil)
        window = nil
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    // MARK: - ④.1 the key follows the edit on screen

    private func makeLoupe() throws -> (loupe: LoupeController, session: CatalogSession) {
        let (session, _) = try CropUITestSupport.makeSession(in: workDir)
        let loupe = LoupeController(session: session)
        loupe.autoRenderEnabled = false
        loupe.collectsHistogram = false
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = loupe.view
        window.orderFront(nil)
        loupe.view.layoutSubtreeIfNeeded()
        self.window = window
        CropUITestSupport.pump(0.05)
        let deadline = Date().addingTimeInterval(2)
        while session.mode != .loupe || session.anchorAsset == nil, Date() < deadline {
            CropUITestSupport.pump(0.01)
        }
        return (loupe, session)
    }

    func testTheBackdropKeyIsTheEditTheCanvasRenders() throws {
        let (loupe, session) = try makeLoupe()
        defer { window?.orderOut(nil) }
        CropUITestSupport.openCropTool(loupe, session)

        // 0°: the draft adds nothing, so the two spellings agree — the control.
        loupe.cropTool.setStraighten(0)
        loupe.refreshCropTool()
        let neutral = try XCTUnwrap(loupe.backdropDigestForTesting)
        XCTAssertEqual(neutral, Histogram.editDigest(session.edit),
                       "④: at 0° the draft's edit is the document")

        // 9°: the key has to be the **preview** edit, not the document.
        loupe.cropTool.setStraighten(Self.angle)
        loupe.refreshCropTool()
        let straightened = try XCTUnwrap(loupe.backdropDigestForTesting)
        let preview = loupe.cropTool.previewEdit(from: session.edit)
        print("④ key · 0° \(neutral) · 9° \(straightened) · digest(document) "
              + "\(Histogram.editDigest(session.edit)) · digest(preview) \(Histogram.editDigest(preview))")
        XCTAssertEqual(straightened, Histogram.editDigest(preview),
                       "④: the low-resolution frame is filed under the edit the canvas renders")
        XCTAssertNotEqual(straightened, Histogram.editDigest(session.edit),
                          "④: and that is *not* the document while a straighten is in the draft")
        XCTAssertEqual(preview.geometry.straightenDegrees, Self.angle, accuracy: 1e-12)

        // The anti-proof: keyed on the document again, the 9° key collapses onto the 0° one.
        loupe.backdropUsesEffectiveEdit = false
        loupe.refreshCropTool()
        let oldStyle = try XCTUnwrap(loupe.backdropDigestForTesting)
        print("④ anti-proof · keyed on the document: \(oldStyle) (equal to the 0° key: "
              + "\(oldStyle == neutral))")
        XCTAssertEqual(oldStyle, neutral, "④ anti-proof: the pre-④ key cannot see the 拉直")
        XCTAssertNotEqual(oldStyle, straightened)
    }

    /// A texture filed under another edit is **refused** rather than drawn (no backdrop beats a
    /// backdrop at the wrong angle), and the same texture is accepted once the key matches again.
    func testAStaleBackdropTextureIsNotDrawn() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let (loupe, session) = try makeLoupe()
        defer { window?.orderOut(nil) }
        CropUITestSupport.openCropTool(loupe, session)
        loupe.cropTool.setStraighten(Self.angle)
        loupe.refreshCropTool()

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
                                                                 width: 8, height: 8, mipmapped: false)
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw XCTSkip("no texture")
        }
        let key = try XCTUnwrap(loupe.backdropKeyForTesting)
        // `du = 2` is the shrinking window: the picture is drawn twice the canvas' size, so the
        // canvas has area the frame does not reach — which is the only case a backdrop is drawn in.
        let window = PresentWindow(u0: 0, v0: 0, du: 2, dv: 2)
        XCTAssertFalse(window.coversCanvas)

        let serial = loupe.backdrop.begin(key)
        XCTAssertTrue(loupe.backdrop.finish(texture, key: key,
                                            content: ImageRect(x: 0, y: 0, width: 8, height: 8),
                                            histogram: nil, milliseconds: 0, serial: serial))
        XCTAssertNotNil(loupe.backdropTextureForTesting(for: window))

        // The draft moves: the texture is another angle now.
        loupe.cropTool.setStraighten(Self.angle + 4)
        loupe.refreshCropTool()
        print("④ stale · after the second 拉直 the texture is drawn: "
              + "\(loupe.backdropTextureForTesting(for: window) != nil) · held key "
              + "\(loupe.backdrop.key?.identity ?? "nil")")
        XCTAssertNil(loupe.backdropTextureForTesting(for: window),
                     "④: a texture under the old edit must not be drawn")
    }

    // MARK: - ④.2 the pixels: one line, two resolutions

    private let size = (width: 800, height: 600)

    /// A bright horizontal line across an almost-black field: the only thing a rotation can move.
    private func lineImage() -> LinearImage {
        var rgba = [Float16](repeating: 0, count: size.width * size.height * 4)
        for x in 0..<size.width {
            let y = size.height / 2
            let o = (y * size.width + x) * 4
            rgba[o] = 1; rgba[o + 1] = 1; rgba[o + 2] = 1; rgba[o + 3] = 1
        }
        for i in stride(from: 3, to: rgba.count, by: 4) where rgba[i] == 0 { rgba[i] = 1 }
        return LinearImage(width: size.width, height: size.height, rgba: rgba,
                           colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic")
    }

    private func render(degrees: Double, scale: Double) throws -> (texture: MTLTexture, size: ImageSize) {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let graph = try RenderGraph(input: RenderInput(image: lineImage(), identity: "④-line"))
        var edit = EditModel.neutral
        edit.geometry.crop = .full
        edit.geometry.rotationDegrees = degrees
        let options = RenderOptions(scale: scale,
                                    display: DisplayOptions(primaries: .sRGB, bitDepth: 16, headroom: 1),
                                    useCache: false, wantsPixels: false)
        let result = try graph.render(edit, options: options)
        let texture = try XCTUnwrap(result.output)
        return (texture, ImageSize(width: texture.width, height: texture.height))
    }

    private func pixels(_ texture: MTLTexture) -> [Float16] {
        let w = texture.width, h = texture.height
        var raw = [Float16](repeating: 0, count: w * h * 4)
        raw.withUnsafeMutableBytes { buf in
            texture.getBytes(buf.baseAddress!, bytesPerRow: w * 4 * MemoryLayout<Float16>.size,
                             from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        }
        return raw
    }

    /// Least-squares slope of the line, in **pixels of that render**, measured only where the whole
    /// column has a line (the rotated picture's corners are outside the source and come out black).
    private func slope(_ texture: MTLTexture) -> Double {
        let w = texture.width, h = texture.height
        let raw = pixels(texture)
        var xs: [Double] = [], ys: [Double] = []
        for x in 0..<w {
            var best = -1.0
            var bestY = -1
            for y in 0..<h {
                let value = Double(raw[((y * w) + x) * 4])
                if value > best { best = value; bestY = y }
            }
            // A line pixel is bright; a black column (outside the rotated frame) is not.
            if best > 0.25 { xs.append(Double(x)); ys.append(Double(bestY)) }
        }
        guard xs.count > 4 else { return 0 }
        let n = Double(xs.count)
        let mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
        var num = 0.0, den = 0.0
        for i in xs.indices {
            num += (xs[i] - mx) * (ys[i] - my)
            den += (xs[i] - mx) * (xs[i] - mx)
        }
        return den > 0 ? num / den : 0
    }

    /// The low-resolution whole picture and the 1:1 frame are **the same picture**: the line has the
    /// same slope at both, and stripping the rotation from the low-resolution one breaks it.
    func testTheLowResolutionFrameIsRotatedLikeTheSharpOne() throws {
        // The two scales the loupe actually uses: the backdrop is `BackdropScale` (≤½), a 1:1 frame
        // is `scale = 1`.
        let backdropScale = 0.5
        let lowRes = try render(degrees: Self.angle, scale: backdropScale)
        let sharp = try render(degrees: Self.angle, scale: 1)
        let lowSlope = slope(lowRes.texture)
        let sharpSlope = slope(sharp.texture)
        let delta = abs(lowSlope - sharpSlope) / max(abs(sharpSlope), 1e-9)
        print(String(format: "④ pixels · 9° · 低清 %.0f×%.0f slope %.6f · 锐利 %.0f×%.0f slope %.6f "
                     + "· 相对差 %.4f%%",
                     Double(lowRes.size.width), Double(lowRes.size.height), lowSlope,
                     Double(sharp.size.width), Double(sharp.size.height), sharpSlope, delta * 100))
        XCTAssertGreaterThan(abs(sharpSlope), 0.05, "④: the fixture really produced a turned line")
        XCTAssertLessThanOrEqual(delta, 0.005, "④: the two frames disagree about the angle")

        // Anti-proof: the low-resolution render without the rotation.
        let unrotated = try render(degrees: 0, scale: backdropScale)
        let unrotatedSlope = slope(unrotated.texture)
        print(String(format: "④ anti-proof · 低清 0° slope %.6f · vs 锐利 %.6f · 相对差 %.2f%%",
                     unrotatedSlope, sharpSlope,
                     abs(unrotatedSlope - sharpSlope) / max(abs(sharpSlope), 1e-9) * 100))
        XCTAssertGreaterThan(abs(unrotatedSlope - sharpSlope) / max(abs(sharpSlope), 1e-9), 0.005,
                             "④ anti-proof: without the rotation the slopes must differ")
    }
}
