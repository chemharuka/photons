import XCTest
import AppKit
import PhotonsCatalog
@testable import PhotonsUI

/// The left browser's 34 pt square is a **thumbnail**, not a colour chip.
///
/// That distinction is the whole bug these tests guard: the row used to paint
/// `PlaceholderSwatch.color(for:)` and had no image path at all, so the default browser mode
/// (`photons.browserMode = list`) was a wall of flat colours while the centre grid streamed real
/// images out of the same cache. A list row is 34 pt, so the tier it may ask for is `t256` — the
/// tier `photonsctl thumbs` and the grid already keep on disk — and a recycled row must never draw
/// the photo it used to hold, not even for one frame.
final class BrowserListThumbnailTests: XCTestCase {

    private func asset(id: String = "A",
                       hash: String = "abc",
                       ext: String = "dng",
                       width: Int? = 9520,
                       height: Int? = 6336) -> Asset {
        Asset(id: id,
              sourceRootId: "root",
              relPath: "\(id).\(ext)",
              filename: "\(id).\(ext)",
              ext: ext,
              kind: AssetKind.detect(ext) ?? .jpeg,
              size: 1024,
              mtime: 0,
              contentHash: hash,
              width: width,
              height: height)
    }

    private func solidImage() -> CGImage? {
        let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        ctx?.setFillColor(NSColor.systemRed.cgColor)
        ctx?.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        return ctx?.makeImage()
    }

    /// A 34 pt row must ask for the size the cache actually keeps, at every display scale a Mac
    /// ships: 34 px and 68 px are both inside `t256`, so the request is a disk hit rather than a
    /// regeneration, and the key is the exact string `ThumbKey.preview` writes on disk.
    func testARowAsksForTheTierItsSquareImplies() {
        let a = asset()
        for scale in [1.0, 2.0, 3.0] {
            let requested = ThumbnailProvider.tier(
                cellEdgePoints: BrowserPaneController.thumbnailSide,
                backingScale: scale,
                sourceLongEdge: ThumbnailProvider.sourceLongEdge(of: a))
            let tier = ThumbnailProvider.effectiveTier(requested: requested, ext: a.ext).tier
            XCTAssertEqual(tier, .t256, "34 pt @\(scale)x must stay inside t256")
            XCTAssertEqual(ThumbKey.preview(contentHash: a.contentHash, tier: tier).keyString,
                           "thumb|v1|abc|t256|preview|-",
                           "the list and photonsctl must agree on the key or the cache never hits")
        }
    }

    /// The square side is the only input the grid and the list share; if it grows past 128 pt the
    /// tier moves to `t512` and the list would start regenerating what the grid already holds.
    func testTheSquareSideIsTheOneTheGridAgreesOn() {
        XCTAssertEqual(BrowserPaneController.thumbnailSide, 34, accuracy: 0.001)
        let a = asset(ext: "jpg", width: 6000, height: 4000)
        let tier = ThumbnailProvider.tier(
            cellEdgePoints: BrowserPaneController.thumbnailSide,
            backingScale: 2,
            sourceLongEdge: ThumbnailProvider.sourceLongEdge(of: a))
        XCTAssertEqual(ThumbnailProvider.effectiveTier(requested: tier, ext: a.ext).tier, .t256)
    }

    /// Recycling contract: `configure` clears the previous photo *before* the controller re-applies
    /// from the memory cache, so a row that scrolls can never show the neighbour's image.
    func testARecycledRowDropsThePreviousPhotograph() {
        let cell = PhotoRowCell()
        cell.configure(asset: asset(id: "A", hash: "aaa"), isActive: false)
        XCTAssertNil(cell.thumbnail)
        XCTAssertEqual(cell.assetID, "A")

        guard let image = solidImage() else { return XCTFail("no CGImage") }
        cell.setThumbnail(image)
        XCTAssertNotNil(cell.thumbnail, "an image handed to the row must be the one it draws")

        cell.configure(asset: asset(id: "B", hash: "bbb"), isActive: false)
        XCTAssertNil(cell.thumbnail, "a recycled row must not draw the previous photo for a frame")
        XCTAssertEqual(cell.assetID, "B")
    }

    /// An image can arrive after its row was recycled onto another photo. The controller guards on
    /// the asset id (see `thumbnailDidLoad`); this asserts the property the guard reads is live.
    func testTheRowKnowsWhichAssetItIsShowing() {
        let cell = PhotoRowCell()
        cell.configure(asset: asset(id: "first", hash: "111"), isActive: true)
        XCTAssertEqual(cell.assetID, "first")
        cell.configure(asset: asset(id: "second", hash: "222"), isActive: false)
        XCTAssertEqual(cell.assetID, "second")
    }
}
