import XCTest
import AppKit
import CryptoKit
import Metal
import SwiftUI
import PhotonsCore
@testable import PhotonsUI

/// 118/143b — the white-balance preview.
///
/// The three claims that make the feature honest, each measured rather than described:
///
///   1. **A drag develops nothing and writes nothing.** `RAWDecoder.decodeCounts` does not move, the
///      document keeps the old pair and the history keeps its row count, while the canvas is fed by
///      real `RenderGraph` frames (S1…S4) of the drag's target pair.
///   2. **Release commits once and the target frame survives until the real one.** The preview stays
///      active through the commit, and presenting the frame carrying that revision clears it.
///   3. **The preview is view state.** A frame rendered from the unchanged document is still a cache
///      hit: the target pair never reached a `RenderKey`, a decode key or a history snapshot.
///
/// Parity between the preview and the settled frame is measured in
/// `WhiteBalancePreviewParityTests`.
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

    /// Run the main runloop until the queued preview render has landed.
    private func pumpUntilPreviewSettles(_ loupe: LoupeController,
                                         timeout: TimeInterval = 15) {
        let deadline = Date().addingTimeInterval(timeout)
        while loupe.isRenderingWhiteBalancePreview, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    // MARK: - 1. a drag is a render of the scene buffer, never a decode or a document write

    func testTwentyDragTicksDecodeNothingAndReRunTheRenderGraph() throws {
        let url = try fixtureURL()
        let session = CatalogSession()
        let loupe = makeLoupe(session)
        let frame = try develop(loupe, url, session.edit)
        loupe.presentForTesting(frame, state: .fit)

        let decodesBefore = decodeTotal()
        let historyBefore = session.history.count
        let documentBefore = session.edit.light.whiteBalance
        let frameHash = try XCTUnwrap(frame.displayHash)

        for tick in 1...20 {
            loupe.updateWhiteBalancePreview(temperature: 4200 + Double(tick) * 75,
                                            tint: Double(tick) - 10)
            XCTAssertTrue(loupe.isWhiteBalancePreviewActive)
        }
        pumpUntilPreviewSettles(loupe)

        XCTAssertEqual(decodeTotal(), decodesBefore, "20 drag ticks must develop 0 times")
        XCTAssertEqual(session.edit.light.whiteBalance, documentBefore,
                       "the document must keep the old pair while the hand is down")
        XCTAssertEqual(session.history.count, historyBefore, "a drag writes no history")
        XCTAssertEqual(frame.displayHash, frameHash, "the frame's own pixels did not move")
        XCTAssertGreaterThan(loupe.whiteBalancePreviewRenderCount, 0,
                             "a drag must render preview frames, not repaint the old one")

        let preview = try loupe.renderWhiteBalancePreview(
            WhiteBalance(temperature: 4650, tint: 10))
        XCTAssertTrue(preview.trace.executed.contains(.sceneLinear),
                      "the preview must run S1")
        XCTAssertTrue(preview.trace.executed.contains(.toneMap),
                      "the preview must run S2…S4, not stop at the scene buffer")
        XCTAssertNotEqual(preview.whiteBalanceGain, SIMD3<Double>(1, 1, 1),
                          "a moved slider must produce a real S1 gain")

        print("WB preview drag: decodes +0 · history +0 · document \(documentBefore.summary) · "
              + "renders \(loupe.whiteBalancePreviewRenderCount) "
              + "(coalesced \(loupe.whiteBalancePreviewCoalesced)) · stages "
              + "\(preview.trace.csv)")
    }

    // MARK: - 2. release commits once; the target frame stays until the real one lands

    func testReleaseCommitsOnceAndSwapsAtomicallyWhenTheRealFrameArrives() throws {
        let url = try fixtureURL()
        let session = CatalogSession()
        let loupe = makeLoupe(session)
        session.applyEdit { $0.light.exposure = 0.1 }
        XCTAssertTrue(session.commitEdit(label: "起点"))
        let frame = try develop(loupe, url, session.edit)
        loupe.presentForTesting(frame, state: .fit)

        loupe.beginWhiteBalancePreview()
        loupe.updateWhiteBalancePreview(temperature: 3800, tint: 8)
        pumpUntilPreviewSettles(loupe)
        let historyBefore = session.history.count
        let decodesBefore = decodeTotal()

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
                      "the preview must stay until the frame it committed lands")

        let newFrame = try develop(loupe, url, session.edit)
        XCTAssertEqual(newFrame.editRevision, committedRevision)
        XCTAssertEqual(decodeTotal(), decodesBefore, "a white-balance release must not decode again")
        var settled = false
        loupe.onWhiteBalancePreviewSettled = { settled = true }
        loupe.presentForTesting(newFrame, state: .fit)

        XCTAssertTrue(settled, "the badge's callback must fire when the real frame lands")
        XCTAssertFalse(loupe.isWhiteBalancePreviewActive)
        let committed = WhiteBalanceEstimate.gain(
            for: WhiteBalance(temperature: 3800, tint: 8),
            asShot: loupe.measuredAsShotIlluminant)
        XCTAssertEqual(newFrame.whiteBalanceGain, SIMD3(committed.r, committed.g, committed.b),
                       "the settled frame applies the committed pair")
        XCTAssertNotEqual(newFrame.displayHash, frame.displayHash,
                          "the committed white balance must change the picture")

        print("WB preview release: history +1 · decode +0 · gain \(newFrame.whiteBalanceGain) "
              + "on revision \(committedRevision)")
    }

    /// A release that wrote nothing has no frame to wait for: the preview ends immediately.
    func testReleaseWithoutAWriteClearsImmediately() throws {
        let url = try fixtureURL()
        let session = CatalogSession()
        let loupe = makeLoupe(session)
        let frame = try develop(loupe, url, session.edit)
        loupe.presentForTesting(frame, state: .fit)

        loupe.beginWhiteBalancePreview()
        loupe.updateWhiteBalancePreview(temperature: 3800, tint: 8)
        pumpUntilPreviewSettles(loupe)
        var settled = false
        loupe.onWhiteBalancePreviewSettled = { settled = true }
        loupe.releaseWhiteBalancePreview(awaiting: nil)

        XCTAssertFalse(loupe.isWhiteBalancePreviewActive)
        XCTAssertTrue(settled)
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
        pumpUntilPreviewSettles(loupe)
        let again = try develop(loupe, url, session.edit)
        XCTAssertTrue(again.usedCachedDecode,
                      "a preview drag changed the decode key — the next real render missed")
        XCTAssertEqual(decodeTotal(), decodesBefore)
    }

    // MARK: - 4. nil is as shot, never 0 K

    func testNilUsesTheFilesAsShotPairNotZero() throws {
        let url = try fixtureURL()
        let session = CatalogSession()
        let loupe = makeLoupe(session)
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
        XCTAssertEqual(state.target, .asShot)
        XCTAssertEqual(state.targetGain, SIMD3(1, 1, 1),
                       "as shot is S1's identity, not a gain towards the file's number")
        pumpUntilPreviewSettles(loupe)
        let preview = try loupe.renderWhiteBalancePreview(.asShot)
        XCTAssertEqual(preview.whiteBalanceGain, SIMD3(1, 1, 1))
        print("WB preview nil pair → as shot \(shot.summary), S1 \(preview.whiteBalanceGain)")
    }

    // MARK: - 5. the present pass carries no white-balance gain any more

    func testPresentMetalHasNoDisplayDomainGain() throws {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("Sources/PhotonsCore/Kernels/present.metal").path) {
            let parent = dir.deletingLastPathComponent()
            if parent == dir { throw XCTSkip("repo root not found") }
            dir = parent
        }
        let url = dir.appendingPathComponent("Sources/PhotonsCore/Kernels/present.metal")
        let code = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(code.contains("float3 srgb_encode("),
                       "the 118 display-domain gain branch is still in present.metal")
        XCTAssertFalse(code.contains("misc.yzw"),
                       "present.metal still reads the preview gain uniform")
        print("WB preview: present.metal is a plain transfer — no display-domain gain")
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
}
