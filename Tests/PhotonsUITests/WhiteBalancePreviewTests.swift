import XCTest
import AppKit
import CryptoKit
import Metal
import SwiftUI
import PhotonsCore
@testable import PhotonsUI

/// 118 — the simulated white-balance preview.
///
/// The three claims that make the feature honest, each measured rather than described:
///
///   1. **A drag develops nothing and writes nothing.** `RAWDecoder.decodeCounts` does not move, the
///      document keeps the old pair and the history keeps its row count, while the pixels handed to
///      the present pass really do change (the request carries a non-identity gain and its rendered
///      hash differs from the old frame's).
///   2. **Release commits once and the simulation survives until the real frame.** The preview stays
///      active — still old frame × gain — through the commit, and presenting the frame carrying that
///      revision is what clears it, in the same present that shows the new pixels.
///   3. **The preview is view state.** A frame rendered from the unchanged document is still a cache
///      hit: the gain never reached a `RenderKey`, a decode key or a history snapshot.
///
/// The fixture is the user's own RAW (set `PHOTONS_TEST_RAW`), so the suite skips when it is absent.
@MainActor
final class WhiteBalancePreviewTests: XCTestCase {

    private static let viewport = ImageSize(width: 800, height: 600)
    private static let decodeScale: Float = 0.125

    private func fixtureURL() throws -> URL {
        let candidates = [
            ProcessInfo.processInfo.environment["PHOTONS_TEST_RAW"],
            NSString(string: "~/Desktop/test/L1030433.dng").expandingTildeInPath,
        ].compactMap { $0 }
        for c in candidates where FileManager.default.isReadableFile(atPath: c) {
            return URL(fileURLWithPath: c)
        }
        throw XCTSkip("no RAW fixture; set PHOTONS_TEST_RAW")
    }

    private func makeLoupe(_ session: CatalogSession) -> LoupeController {
        let loupe = LoupeController(session: session)
        loupe.autoRenderEnabled = false       // every frame in this file is asked for explicitly
        _ = loupe.view
        loupe.canvasView.frame = NSRect(x: 0, y: 0,
                                        width: Self.viewport.width / 2,
                                        height: Self.viewport.height / 2)
        return loupe
    }

    private func develop(_ loupe: LoupeController, _ url: URL, _ edit: EditModel) throws
        -> LoupeController.FrameResult {
        try loupe.makeFrame(url: url, viewport: Self.viewport, decodeScale: Self.decodeScale,
                            edit: edit, hashPixels: true)
    }

    private func decodeTotal() -> Int { RAWDecoder.decodeCounts().values.reduce(0, +) }

    // MARK: - 1. a drag is display-only

    func testTwentyDragTicksDecodeNothingAndChangeOnlyThePresentedGain() throws {
        let url = try fixtureURL()
        let session = CatalogSession()
        let loupe = makeLoupe(session)
        let frame = try develop(loupe, url, session.edit)
        loupe.presentForTesting(frame, state: .fit)
        let oldRequest = try XCTUnwrap(loupe.lastPresentRequest)
        XCTAssertNil(oldRequest.whiteBalanceGain, "the settled frame must carry no preview gain")

        let decodesBefore = decodeTotal()
        let historyBefore = session.history.count
        let documentBefore = session.edit.light.whiteBalance
        let frameHash = try XCTUnwrap(frame.displayHash)

        for tick in 1...20 {
            loupe.updateWhiteBalancePreview(temperature: 4200 + Double(tick) * 75,
                                            tint: Double(tick) - 10)
            XCTAssertTrue(loupe.isWhiteBalancePreviewActive)
        }

        XCTAssertEqual(decodeTotal(), decodesBefore, "20 drag ticks must develop 0 times")
        XCTAssertEqual(session.edit.light.whiteBalance, documentBefore,
                       "the document must keep the old pair while the hand is down")
        XCTAssertEqual(session.history.count, historyBefore, "a drag writes no history")
        XCTAssertEqual(frame.displayHash, frameHash, "the frame's own pixels did not move")

        let previewRequest = try XCTUnwrap(loupe.lastPresentRequest)
        let gain = try XCTUnwrap(previewRequest.whiteBalanceGain,
                                 "the present pass was not handed a preview gain")
        XCTAssertNotEqual(gain, SIMD3<Float>(1, 1, 1), "a moved slider must produce a real gain")
        XCTAssertTrue(previewRequest.picture === frame.texture,
                      "the preview must reuse the frame already on the canvas, not a new render")

        // The same request, drawn twice: with the gain it is a different picture from the frame it
        // started as. This is the "画面像素确实变了" half of the acceptance, measured on the real pass.
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
        let presenter = try CanvasPresenter(device: device)
        let plain = try render(oldRequest, with: presenter, device: device)
        let simulated = try render(previewRequest, with: presenter, device: device)
        XCTAssertNotEqual(Self.hash(plain), Self.hash(simulated),
                          "the preview gain reached the request but not the pixels")

        print("WB preview drag: decodes +0 · history +0 · document \(documentBefore.summary) · "
              + "gain \(gain) · pixels changed")
    }

    // MARK: - 2. release commits once; the old frame keeps the gain until the new one lands

    func testReleaseCommitsOnceAndSwapsAtomicallyWhenTheRealFrameArrives() throws {
        let url = try fixtureURL()
        let session = CatalogSession()
        let loupe = makeLoupe(session)
        // A baseline snapshot so the commit has somewhere to undo to.
        session.applyEdit { $0.light.exposure = 0.1 }
        XCTAssertTrue(session.commitEdit(label: "起点"))
        let frame = try develop(loupe, url, session.edit)
        loupe.presentForTesting(frame, state: .fit)

        loupe.beginWhiteBalancePreview()
        loupe.updateWhiteBalancePreview(temperature: 3800, tint: 8)
        let historyBefore = session.history.count
        let decodesBefore = decodeTotal()

        // 松手: the inspector's `commitWhiteBalance` writes once, then hands the revision to the loupe.
        session.applyEdit {
            $0.light.temperature = 3800
            $0.light.tint = 8
        }
        XCTAssertTrue(session.commitEdit(label: "色温"))
        let committedRevision = session.editRevision
        loupe.releaseWhiteBalancePreview(awaiting: committedRevision)

        XCTAssertEqual(session.history.count, historyBefore + 1, "one release = one history row")
        XCTAssertEqual(session.edit.light.temperature, 3800)
        XCTAssertTrue(loupe.isWhiteBalancePreviewActive,
                      "the simulation must stay until the decode it committed lands")
        let between = try XCTUnwrap(loupe.lastPresentRequest)
        XCTAssertNotNil(between.whiteBalanceGain, "the screen fell back to the old white balance")
        XCTAssertTrue(between.picture === frame.texture,
                      "the between state must still be the old frame")

        // The real render arrives. Presenting it is the atomic switch: new pixels, gain gone. Since
        // 143 a white-balance release is a **render**, not a development: the same buffer is drawn
        // through the new S1 gain.
        let newFrame = try develop(loupe, url, session.edit)
        XCTAssertEqual(newFrame.editRevision, committedRevision)
        XCTAssertEqual(decodeTotal(), decodesBefore, "a white-balance release must not decode again")
        var settled = false
        loupe.onWhiteBalancePreviewSettled = { settled = true }
        loupe.presentForTesting(newFrame, state: .fit)

        XCTAssertTrue(settled, "the badge's callback must fire when the real frame lands")
        XCTAssertFalse(loupe.isWhiteBalancePreviewActive)
        let after = try XCTUnwrap(loupe.lastPresentRequest)
        XCTAssertNil(after.whiteBalanceGain, "the preview gain must be cleared with the new frame")
        XCTAssertTrue(after.picture === newFrame.texture)
        XCTAssertNotEqual(newFrame.displayHash, frame.displayHash,
                          "the committed white balance must change the picture")

        print("WB preview release: history +1 · decode +0 · gain cleared on the frame carrying "
              + "revision \(committedRevision)")
    }

    /// A release that wrote nothing has no decode to wait for: the preview ends immediately and the
    /// badge goes back to the state word.
    func testReleaseWithoutAWriteClearsImmediately() throws {
        let url = try fixtureURL()
        let session = CatalogSession()
        let loupe = makeLoupe(session)
        let frame = try develop(loupe, url, session.edit)
        loupe.presentForTesting(frame, state: .fit)

        loupe.beginWhiteBalancePreview()
        loupe.updateWhiteBalancePreview(temperature: 3800, tint: 8)
        var settled = false
        loupe.onWhiteBalancePreviewSettled = { settled = true }
        loupe.releaseWhiteBalancePreview(awaiting: nil)

        XCTAssertFalse(loupe.isWhiteBalancePreviewActive)
        XCTAssertTrue(settled)
        XCTAssertNil(try XCTUnwrap(loupe.lastPresentRequest).whiteBalanceGain,
                     "the real frame must be drawn again without the simulation")
    }

    // MARK: - 3. the preview does not dirty the render cache

    func testAnUnchangedDocumentStillHitsTheRenderCacheAfterADrag() throws {
        let url = try fixtureURL()
        let session = CatalogSession()
        let loupe = makeLoupe(session)
        _ = try develop(loupe, url, session.edit)
        let decodesBefore = decodeTotal()

        for tick in 1...12 {
            loupe.updateWhiteBalancePreview(temperature: 4300 + Double(tick) * 60, tint: 4)
        }
        let again = try develop(loupe, url, session.edit)
        XCTAssertTrue(again.usedCachedDecode,
                      "a preview drag changed the render key — the next real render missed")
        XCTAssertEqual(decodeTotal(), decodesBefore)
    }

    // MARK: - 4. nil is as shot, never 0 K

    func testNilUsesTheFilesAsShotPairNotZero() throws {
        let url = try fixtureURL()
        let session = CatalogSession()
        let loupe = makeLoupe(session)
        // Start from an explicit pair so the document is not as shot: dragging back to nil must predict
        // the *file's* pair, not the document's old number and not 0/6500.
        session.applyEdit {
            $0.light.temperature = 3000
            $0.light.tint = 20
        }
        _ = try develop(loupe, url, session.edit)
        let shot = try XCTUnwrap(loupe.asShotWhiteBalance, "the fixture decode must report a pair")
        if shot.temperature == nil { throw XCTSkip("the fixture reports no as-shot Kelvin") }

        loupe.beginWhiteBalancePreview()
        loupe.updateWhiteBalancePreview(temperature: nil, tint: nil)
        let state = try XCTUnwrap(loupe.whiteBalancePreview)
        let expected = WhiteBalanceEstimate.relativeGain(
            from: WhiteBalance(temperature: 3000, tint: 20), to: .asShot)
        XCTAssertEqual(state.gain.x, expected.r, accuracy: 1e-12)
        XCTAssertEqual(state.gain.y, expected.g, accuracy: 1e-12)
        XCTAssertEqual(state.gain.z, expected.b, accuracy: 1e-12)
        print("WB preview nil pair → as shot \(shot.summary), gain \(state.gain)")
    }

    // MARK: - 5. the shader's maths and the 8-bit approximation

    /// The display path multiplies in linear light. On the 16-bit (linear) drawable the result is the
    /// exact model; on the 8-bit fallback it is linearise → multiply → encode, which is the same
    /// arithmetic with one sRGB OETF round-trip. The old shortcut — multiplying the *encoded* bytes —
    /// is measured here too and written into the print, because it is exactly the error this branch
    /// avoids.
    func testPresentGainMultipliesInLinearLightAndTheEncodedErrorIsQuantisationSmall() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
        let presenter = try CanvasPresenter(device: device)
        let size = ImageSize(width: 8, height: 8)
        let source = try solid(device, size, value: 0.5)
        let gain = SIMD3<Float>(1.2, 0.8, 1.1)
        let request = PresentRequest(picture: source,
                                     photoRect: ImageRect(x: 0, y: 0, width: 8, height: 8),
                                     window: .whole, canvas: size,
                                     whiteBalanceGain: gain)

        let linearTarget = try makeTexture(device, size, .rgba16Float)
        XCTAssertTrue(presenter.render(request, into: linearTarget, linearize: true))
        let linear = Self.pixel(linearTarget, 4, 4)
        let encoded: [Float] = [0.5, 0.5, 0.5]
        let originalLinear = encoded.map { Self.srgbToLinear(Double($0)) }
        let expected = [originalLinear[0] * gain.x, originalLinear[1] * gain.y,
                        originalLinear[2] * gain.z]
        for c in 0..<3 {
            XCTAssertEqual(linear[c], expected[c], accuracy: 2e-4,
                           "the 16-bit path must be linearise → multiply, channel \(c)")
        }
        XCTAssertEqual(linear[3], 1, accuracy: 1e-4)

        let encodedTarget = try makeTexture(device, size, .bgra8Unorm)
        XCTAssertTrue(presenter.render(request, into: encodedTarget, linearize: false))
        let bytes = Self.pixel8(encodedTarget, 4, 4)   // BGRA
        let got = [bytes[2], bytes[1], bytes[0]].map { Float($0) / 255 }
        let want = expected.map { Self.srgbEncode($0) }
        let delta = zip(got, want).map { abs($0 - $1) }.max() ?? 0
        XCTAssertLessThan(delta, Float(2.0 / 255), "8-bit encode round-trip drifted by \(delta)")
        let oldShortcut = encoded.map { min(Double($0) * Double(gain.x), 1) }
        let oldError = abs(Double(Self.srgbEncode(expected[0])) - oldShortcut[0])
        print(String(format: "WB preview shader: 16-bit exact (≤2e-4); 8-bit OETF round-trip %.4f/255; "
                     + "multiplying encoded bytes would have been off by %.1f%%",
                     delta * 255, oldError * 100))
    }

    // MARK: - 6. the badge's box

    func testPreviewBadgeUsesTheAsShotBox() throws {
        XCTAssertEqual(WhiteBalanceStatusLabel.Kind.asShot.text, "as shot")
        XCTAssertEqual(WhiteBalanceStatusLabel.Kind.simulated.text, "模拟预览")
        XCTAssertEqual(WhiteBalanceStatusLabel.Kind.asShot.fontSize, 8)
        XCTAssertEqual(WhiteBalanceStatusLabel.Kind.simulated.fontSize, 9)

        let asShot = NSHostingView(rootView: WhiteBalanceStatusLabel(kind: .asShot))
        asShot.frame = NSRect(x: 0, y: 0, width: 120, height: 40)
        asShot.layoutSubtreeIfNeeded()
        let preview = NSHostingView(rootView: WhiteBalanceStatusLabel(kind: .simulated))
        preview.frame = NSRect(x: 0, y: 0, width: 120, height: 40)
        preview.layoutSubtreeIfNeeded()

        XCTAssertEqual(asShot.fittingSize.height, InspectorView.whiteBalanceStatusHeight, accuracy: 0.5)
        XCTAssertEqual(preview.fittingSize.height, asShot.fittingSize.height, accuracy: 0.5,
                       "the badge changed the row's height — the card jumps when a drag starts")
        print("WB badge: as shot \(asShot.fittingSize) · 模拟预览 \(preview.fittingSize) · "
              + "row height \(InspectorView.whiteBalanceStatusHeight)")
    }

    // MARK: - helpers

    private func render(_ request: PresentRequest, with presenter: CanvasPresenter,
                        device: MTLDevice) throws -> MTLTexture {
        let target = try makeTexture(device, request.canvas, .rgba16Float)
        XCTAssertTrue(presenter.render(request, into: target, linearize: true))
        return target
    }

    private func makeTexture(_ device: MTLDevice, _ size: ImageSize,
                             _ format: MTLPixelFormat) throws -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: size.width,
                                                          height: size.height, mipmapped: false)
        d.usage = [.shaderRead, .renderTarget]
        d.storageMode = .shared
        return try XCTUnwrap(device.makeTexture(descriptor: d))
    }

    private func solid(_ device: MTLDevice, _ size: ImageSize, value: Float) throws -> MTLTexture {
        let t = try makeTexture(device, size, .rgba16Float)
        var row = [UInt16](repeating: 0, count: size.width * 4)
        for x in 0..<size.width {
            row[x * 4] = Float16(value).bitPattern
            row[x * 4 + 1] = Float16(value).bitPattern
            row[x * 4 + 2] = Float16(value).bitPattern
            row[x * 4 + 3] = Float16(1).bitPattern
        }
        for y in 0..<size.height {
            row.withUnsafeBytes { buf in
                t.replace(region: MTLRegionMake2D(0, y, size.width, 1), mipmapLevel: 0,
                          withBytes: buf.baseAddress!, bytesPerRow: size.width * 8)
            }
        }
        return t
    }

    private static func hash(_ texture: MTLTexture) -> String {
        var raw = [UInt8](repeating: 0, count: texture.width * texture.height * 8)
        raw.withUnsafeMutableBytes { buf in
            texture.getBytes(buf.baseAddress!, bytesPerRow: texture.width * 8,
                             from: MTLRegionMake2D(0, 0, texture.width, texture.height),
                             mipmapLevel: 0)
        }
        return SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined()
    }

    private static func pixel(_ texture: MTLTexture, _ x: Int, _ y: Int) -> [Float] {
        var raw = [UInt16](repeating: 0, count: 4)
        raw.withUnsafeMutableBytes { buf in
            texture.getBytes(buf.baseAddress!, bytesPerRow: 8,
                             from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
        }
        return raw.map { Float(Float16(bitPattern: $0)) }
    }

    private static func pixel8(_ texture: MTLTexture, _ x: Int, _ y: Int) -> [UInt8] {
        var raw = [UInt8](repeating: 0, count: 4)
        raw.withUnsafeMutableBytes { buf in
            texture.getBytes(buf.baseAddress!, bytesPerRow: 4,
                             from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
        }
        return raw
    }

    private static func srgbToLinear(_ v: Double) -> Float {
        let x = min(max(v, 0), 1)
        return Float(x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4))
    }

    private static func srgbEncode(_ v: Float) -> Float {
        let x = min(max(Double(v), 0), 1)
        return Float(x <= 0.0031308 ? x * 12.92 : 1.055 * pow(x, 1 / 2.4) - 0.055)
    }
}
