import XCTest
import AppKit
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 443 — `publishIngestedSource` registers a size **for the photo it describes**, not for whatever
/// photo happens to be the anchor when the frame lands.
///
/// The shipped defect: a canvas-cache hit for B read the previous photo's graph (via
/// `graphAtFrame`) and published it under B's live anchor id, so `maskSourceSize` described A's
/// landscape frame while the stand-in bitmap was B's portrait one. This suite pins the owner half:
/// a publication naming a different photo is refused outright.
@MainActor
final class IngestedSourceOwner443Tests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-ingest-owner-443-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
        workDir = nil
    }

    func testAPublicationForAnotherPhotoLeavesTheRegisteredSourceUntouched() throws {
        let (session, asset) = try CropUITestSupport.makeSession(in: workDir,
                                                                 width: 6000, height: 4000)
        let loupe = LoupeController(session: session)
        loupe.autoRenderEnabled = false
        loupe.collectsHistogram = false

        // The photo's own frame: the publication lands as usual (the 231 callers' shape).
        let ownPhoto = "\(asset.contentHash)|\(asset.id)"
        loupe.publishIngestedSourceForTesting(rung: ImageSize(width: 3000, height: 2000),
                                              decodeScale: 0.5, photo: ownPhoto)
        let registered = try XCTUnwrap(session.ingestedSourceFrame,
                                       "the matching publication did not register the frame")
        XCTAssertEqual(registered.assetID, asset.id)
        XCTAssertEqual(registered.size, ImageSize(width: 6000, height: 4000))

        // A frame rendered for another picture, landing late. Its size must not become this
        // photo's — neither the asset id nor the numbers may move.
        loupe.publishIngestedSourceForTesting(rung: ImageSize(width: 4000, height: 2000),
                                              decodeScale: 1,
                                              photo: "some-other-photo|\(UUID().uuidString)")
        let after = try XCTUnwrap(session.ingestedSourceFrame)
        XCTAssertEqual(after.assetID, registered.assetID,
                       "a late frame of another photo re-registered the source under this anchor")
        XCTAssertEqual(after.size, registered.size,
                       "a late frame of another photo moved this photo's source size")
    }
}
