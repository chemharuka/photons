import XCTest
import AppKit
import Metal
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 570 — **one development must answer to both the key it was developed under and the spelling its
/// read-back gave it.**
///
/// `present` installs the decoder's effective spelling into the document (`resolvedDecoderVersion`),
/// which is right: the next *settled* frame must develop (or hit) the buffer the pixels really came
/// from. What broke was that the rung had already been stored under the automatic document's
/// spelling (`no ver=`), so the very next drag asked for `…|ver=8` and got `notResident`.
///
/// The fix is an explicit alias: `makeFrame` registers the read-back spelling as another name for
/// the one development it just made. These tests measure the registration (1), the cache hit it
/// buys (2), the drag it unblocks (3), that a photo switch drops it (4), and that a hand pick — which
/// already names its spelling — is byte-for-byte unchanged (5).
@MainActor
final class RungIdentity570Tests: XCTestCase {

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

    /// The controller's own ladder. It is private (this ticket may not add a producer seam), and the
    /// alias list is what test 1 has to read, so the test reflects the stored property instead of
    /// changing the shipped type.
    private func ladder(of loupe: LoupeController) throws -> DecodeLadder {
        for child in Mirror(reflecting: loupe).children where child.label == "ladder" {
            return try XCTUnwrap(child.value as? DecodeLadder, "the loupe's ladder is not a DecodeLadder")
        }
        throw XCTSkip("LoupeController has no stored ladder")
    }

    private func develop(_ loupe: LoupeController, _ url: URL, _ edit: EditModel) throws
        -> LoupeController.FrameResult {
        try loupe.makeFrame(url: url, viewport: Self.viewport, decodeScale: Self.decodeScale,
                            edit: edit, hashPixels: false)
    }

    private func decodeTotal() -> Int { RAWDecoder.decodeCounts().values.reduce(0, +) }

    private func pumpUntilPreviewSettles(_ loupe: LoupeController,
                                         timeout: TimeInterval = 15) {
        let deadline = Date().addingTimeInterval(timeout)
        while loupe.isRenderingWhiteBalancePreview, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    // MARK: - 1. one development, two names

    func testAFreshDevelopmentAlsoAnswersToItsReadBackSpelling() throws {
        let url = try fixtureURL()
        let session = CatalogSession()
        let loupe = makeLoupe(session)
        let frame = try develop(loupe, url, session.edit)
        let effective = try XCTUnwrap(frame.capabilities?.effectiveVersion,
                                      "the development must report the spelling it got")
        XCTAssertFalse(effective.isEmpty)

        let base = url.lastPathComponent
        let aliased = try ladder(of: loupe).aliasedIdentities
        XCTAssertEqual(aliased, ["\(base)|ver=\(effective)"],
                       "the read-back spelling must be registered as an alias of this development")

        let ladder = try ladder(of: loupe)
        XCTAssertNotNil(ladder.resident(identity: base, scale: Self.decodeScale),
                        "the primary identity is still the spelling the development was asked with")
        XCTAssertNotNil(ladder.resident(identity: "\(base)|ver=\(effective)", scale: Self.decodeScale),
                        "and the alias resolves to the same rung")
        XCTAssertEqual(ladder.residentScales, [Self.decodeScale])
        print("570 alias: base \(base) · effective \(effective) · aliases \(aliased)")
    }

    // MARK: - 2. the document's new spelling still hits the same rung

    func testAPresentedReadBackSpellingStillHitsTheSameDevelopment() throws {
        let url = try fixtureURL()
        let session = CatalogSession()
        let loupe = makeLoupe(session)
        let frame = try develop(loupe, url, session.edit)
        loupe.presentForTesting(frame, state: .fit)

        let effective = try XCTUnwrap(session.edit.resolvedDecoderVersion,
                                      "present must install the read-back spelling")
        XCTAssertEqual(session.edit.decodeInputs.decoderVersion, effective,
                       "the next frame's document identity carries the spelling")

        let developedBefore = try ladder(of: loupe).developedRungs[Self.decodeScale] ?? 0
        let decodesBefore = decodeTotal()
        let again = try develop(loupe, url, session.edit)

        XCTAssertTrue(again.usedCachedDecode,
                      "the document's spelling changed the decode key — the next real render missed")
        XCTAssertEqual(try ladder(of: loupe).developedRungs[Self.decodeScale] ?? 0, developedBefore,
                       "answering the spelled key must not develop the rung again")
        XCTAssertEqual(decodeTotal(), decodesBefore)
        print("570 cache: document spelling \(effective) · cached \(again.usedCachedDecode) · "
              + "developed \(developedBefore)")
    }

    // MARK: - 3. the drag rides the development, not a miss

    func testTheWhiteBalanceDragRidesTheAliasedRung() throws {
        let url = try fixtureURL()
        let session = CatalogSession()
        let loupe = makeLoupe(session)
        let frame = try develop(loupe, url, session.edit)
        loupe.presentForTesting(frame, state: .fit)

        loupe.beginWhiteBalancePreview()
        loupe.updateWhiteBalancePreview(temperature: 4650, tint: 10)
        pumpUntilPreviewSettles(loupe)
        XCTAssertGreaterThan(loupe.whiteBalancePreviewRenderCount, 0,
                             "a drag after present must render, not throw notResident")
        XCTAssertNil(loupe.lastPresentError)

        let preview = try loupe.renderWhiteBalancePreview(
            WhiteBalance(temperature: 4650, tint: 10))
        XCTAssertNotEqual(preview.whiteBalanceGain, SIMD3<Double>(1, 1, 1),
                          "the drag must still produce a real S1 gain")
        print("570 drag: renders \(loupe.whiteBalancePreviewRenderCount) · "
              + "gain \(preview.whiteBalanceGain)")
    }

    // MARK: - 4. the alias belongs to that photo only

    func testSwitchingPhotoDropsTheAlias() throws {
        let url = try fixtureURL()
        let session = CatalogSession()
        let loupe = makeLoupe(session)
        let frame = try develop(loupe, url, session.edit)
        loupe.presentForTesting(frame, state: .fit)
        let aliasedBefore = try ladder(of: loupe).aliasedIdentities
        XCTAssertFalse(aliasedBefore.isEmpty, "precondition: the first development registered an alias")
        let firstAlias = try XCTUnwrap(aliasedBefore.first)

        // Same bytes, a different photo identity: the ladder must not answer the new photo's key (or
        // the old alias) from the previous picture's rung.
        let name = url.lastPathComponent
        let other = Asset(sourceRootId: "570-root", relPath: name, filename: name,
                          ext: url.pathExtension, kind: .raw, size: 1, mtime: 0,
                          contentHash: "570-other-photo")
        _ = try loupe.makeFrame(asset: other, url: url, viewport: Self.viewport,
                                decodeScale: Self.decodeScale, edit: session.edit,
                                hashPixels: false)

        XCTAssertEqual(try ladder(of: loupe).aliasedIdentities, [],
                       "a photo switch must drop the previous development's aliases")
        XCTAssertNil(try ladder(of: loupe).resident(identity: firstAlias, scale: Self.decodeScale),
                     "the old alias must not resolve to the new photo's rung")
        print("570 switch: aliases \(aliasedBefore) → []")
    }

    // MARK: - 5. a hand pick already names its spelling

    func testAHandPickedVersionRegistersNoAlias() throws {
        let url = try fixtureURL()
        let available = try RAWDecoder.availableVersions(for: url)
        if !available.contains("9") { throw XCTSkip("this body does not offer v9; \(available)") }

        let session = CatalogSession()
        let loupe = makeLoupe(session)
        session.applyEdit { edit in
            edit.decoderVersion = "9"
            edit.decoderVersionPolicy = .v9
        }
        let frame = try develop(loupe, url, session.edit)
        XCTAssertEqual(frame.capabilities?.effectiveVersion, "9")
        XCTAssertEqual(try ladder(of: loupe).aliasedIdentities, [],
                       "a hand pick starts with its spelling, so there is nothing to alias")

        let developedBefore = try ladder(of: loupe).developedRungs[Self.decodeScale] ?? 0
        let decodesBefore = decodeTotal()
        let again = try develop(loupe, url, session.edit)
        XCTAssertTrue(again.usedCachedDecode)
        XCTAssertEqual(try ladder(of: loupe).developedRungs[Self.decodeScale] ?? 0, developedBefore)
        XCTAssertEqual(decodeTotal(), decodesBefore)
        print("570 hand pick: v9 spelling unchanged · aliases [] · developed \(developedBefore)")
    }
}
