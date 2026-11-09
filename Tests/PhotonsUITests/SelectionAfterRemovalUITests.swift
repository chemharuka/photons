import XCTest
import AppKit
import CoreGraphics
import ImageIO
import PhotonsCatalog
@testable import PhotonsUI

/// 297 — 删除照片后接续「下一张」（没有下一张时上一张），不是第一张。
///
/// The pure function carries the rule; the session tests pin it to a real library so the same
/// selection/anchor source the grid and the loupe read is the one under test.
final class SelectionAfterRemovalUITests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-successor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    // MARK: - the pure rule

    func testMiddleRemovalTakesTheNextOne() {
        XCTAssertEqual(SelectionAfterRemoval.successor(order: ["a", "b", "c", "d"],
                                                       removing: ["b"], anchor: "b"), "c")
    }

    func testRemovingTheLastOneTakesThePrevious() {
        XCTAssertEqual(SelectionAfterRemoval.successor(order: ["a", "b", "c", "d"],
                                                       removing: ["d"], anchor: "d"), "c")
    }

    func testRemovingARunTakesTheFirstSurvivorAfterIt() {
        XCTAssertEqual(SelectionAfterRemoval.successor(order: ["a", "b", "c", "d"],
                                                       removing: ["b", "c"], anchor: "b"), "d")
        XCTAssertEqual(SelectionAfterRemoval.successor(order: ["a", "b", "c", "d"],
                                                       removing: ["c", "d"], anchor: "c"), "b")
    }

    func testAnUntouchedAnchorNeedsNoSuccessor() {
        XCTAssertEqual(SelectionAfterRemoval.successor(order: ["a", "b", "c"],
                                                       removing: ["a"], anchor: "b"), "b")
    }

    func testTheOnlyPhotoLeavesNoSuccessor() {
        XCTAssertNil(SelectionAfterRemoval.successor(order: ["a"], removing: ["a"], anchor: "a"))
        XCTAssertNil(SelectionAfterRemoval.successor(order: ["a", "b"], removing: [], anchor: nil))
    }

    // MARK: - fixture

    @discardableResult
    private func makeJPEG(at url: URL, seed: Int) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let w = 20, h = 16
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) {
            pixels[i * 4] = UInt8((i &* 11 &+ seed &* 41) & 0xFF)
            pixels[i * 4 + 1] = UInt8((i &* 5 &+ seed &* 23) & 0xFF)
            pixels[i * 4 + 2] = UInt8((i &+ seed &* 7) & 0xFF)
            pixels[i * 4 + 3] = 255
        }
        let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                            provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil,
                            shouldInterpolate: false, intent: .defaultIntent)!
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else {
            throw XCTSkip("cannot write JPEG")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw XCTSkip("cannot finalize JPEG") }
        return url
    }

    /// A temporary library with four photos, returned already opened and in the session's own order.
    @MainActor
    private func makeSession() throws -> (session: CatalogSession, ids: [String]) {
        _ = NSApplication.shared
        let package = workDir.appendingPathComponent("UI.\(LibraryLayout.packageExtension)")
        let catalog = try Catalog.create(at: package)
        let src = workDir.appendingPathComponent("src", isDirectory: true)
        var urls: [URL] = []
        for i in 0..<4 {
            urls.append(try makeJPEG(at: src.appendingPathComponent("p\(i).jpg"), seed: 300 + i))
        }
        _ = try ImportService(catalog: catalog).run(sources: urls, options: ImportOptions())

        let session = CatalogSession()
        try session.open(package)
        let ids = session.assets.map(\.id)
        XCTAssertEqual(ids.count, 4, "the fixture library holds four photos")
        return (session, ids)
    }

    // MARK: - the session

    /// The reverse gate: after deleting the third photo the anchor is the fourth, **never the first**.
    @MainActor
    func testDeletingTheAnchorLandsOnTheNextPhotoNotTheFirst() throws {
        let (session, ids) = try makeSession()
        session.selectOnly(ids[2])

        _ = session.deleteAssets([ids[2]])

        XCTAssertEqual(session.anchorID, ids[3], "接在删除前紧随其后的那张")
        XCTAssertNotEqual(session.anchorID, ids[0], "不是回到第一张")
    }

    @MainActor
    func testDeletingTheLastPhotoLandsOnThePreviousOne() throws {
        let (session, ids) = try makeSession()
        session.selectOnly(ids[3])

        _ = session.deleteAssets([ids[3]])

        XCTAssertEqual(session.anchorID, ids[2], "没有下一张，接上一张")
    }

    @MainActor
    func testMultiSelectionRemovalLandsAfterTheAnchor() throws {
        let (session, ids) = try makeSession()
        session.setSelection([ids[1], ids[2]], anchor: ids[1])

        _ = session.deleteAssets([ids[1], ids[2]])

        XCTAssertEqual(session.anchorID, ids[3], "多选也接在锚点之后")
    }
}
