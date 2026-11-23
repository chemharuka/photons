import XCTest
import AppKit
import CoreGraphics
import GRDB
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 525 — editing one member of a 降噪 stack must also refresh the **hidden sibling's** cell.
///
/// 487 gave a denoise pair one document in two rows; the commit writes both (that contract does not
/// move here). What was missing was the *refresh*: `persistCount` and `editedAssetID` only named the
/// photo the user was editing, so a cell showing the other member kept its pre-edit `ThumbKey` and
/// therefore its pre-edit bitmap. When the stack was expanded the original still looked unedited.
///
/// The fix is one more call on the existing edit-observation channel, for the sibling id
/// (`CatalogSession.persist()`). This suite drives that channel end to end:
///
///   · an expanded stack's member cell is an `AssetCardView` whose bitmap comes from the shared
///     `ThumbnailProvider` (no new cache family, no key change);
///   · after editing the product the original's cell must carry the **new** key *and* the bytes the
///     same row shows after a manual `reload()`;
///   · a plain stack (HDR / ⌘G) and a photo in no stack must not get a second signal.
///
/// **Reverse gate:** delete the `notifyEditObservers(assetID: linked.assetId)` call in `persist()`
/// and `testEditingTheProductRefreshesTheHiddenOriginalsCell` goes red twice — `notified` never
/// contains the original, and its cell still holds `oldKey`/`oldBytes`.
@MainActor
final class DenoiseSiblingThumb525Tests: XCTestCase {

    private var workDir: URL!
    private var cacheRoots: [URL] = []

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-525-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        _ = NSApplication.shared
    }

    override func tearDownWithError() throws {
        for root in cacheRoots { try? FileManager.default.removeItem(at: root) }
        cacheRoots.removeAll()
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
        workDir = nil
    }

    // MARK: - 1 · the hidden original follows the product

    func testEditingTheProductRefreshesTheHiddenOriginalsCell() throws {
        let library = try makeLibrary(filenames: ["L1030433.dng", "L1030433-denoised.dng"])
        let original = library.assets[0]
        let product = library.assets[1]
        let summary = try XCTUnwrap(try library.catalog.makeStack(resultAssetID: product.id,
                                                                  participantIDs: [original.id]))
        XCTAssertEqual(summary.kind, .denoise)
        XCTAssertEqual(summary.topID, product.id, "the product is the visible row")

        let session = try openSession(library.package)
        let cache = try XCTUnwrap(session.thumbnailCache)
        cacheRoots.append(cache.root)
        let display = ImageSize(width: 96, height: 64)
        let provider = ThumbnailProvider.shared(for: cache)

        // The expanded stack's original cell: the row as it was before the edit.
        let originalBefore = try XCTUnwrap(session.stackMembers(ofAssetID: original.id)?
            .first { $0.id == original.id })
        let oldKey = ThumbnailProvider.hdJPEGKey(for: originalBefore)
        try seed(cache, key: oldKey, color: .systemRed)
        let cell = MemberCell(provider: provider, session: session, display: display)
        cell.show(originalBefore)
        XCTAssertTrue(waitFor { cell.card.thumbnailKey == oldKey && cell.card.thumbnail != nil },
                      "the original's cell never drew its pre-edit bitmap")
        let oldBytes = try pixelBytes(cell.card.thumbnail)

        var edited = EditModel.neutral
        edited.light.exposure = 1.0
        let newKey = ThumbKey.hdJPEG(contentHash: originalBefore.contentHash, document: edited)
        XCTAssertNotEqual(newKey.digest, oldKey.digest)
        // The provider has a ready file for the post-edit key, so this test measures the signal
        // (which key the cell asks for) rather than the renderer.
        try seed(cache, key: newKey, color: .systemGreen)

        var notified: [String] = []
        let token = session.addEditObserver { id in
            notified.append(id)
            guard id == original.id,
                  let fresh = session.stackMembers(ofAssetID: id)?.first(where: { $0.id == id })
            else { return }
            cell.show(fresh)
        }
        defer { session.removeEditObserver(token) }

        session.selectOnly(product.id)
        XCTAssertEqual(session.loadedEditAssetID, product.id)
        session.applyEdit { $0.light.exposure = 1.0 }
        XCTAssertTrue(session.commitEdit(label: "曝光"))

        XCTAssertTrue(notified.contains(product.id), "the edited product keeps its own signal")
        XCTAssertTrue(notified.contains(original.id),
                      "reverse gate: the hidden original was never told its document moved")

        XCTAssertTrue(waitFor { cell.card.thumbnailKey == newKey && cell.card.thumbnail != nil },
                      "the original's cell stayed on \(cell.card.thumbnailKey?.digest.prefix(8) ?? "nil")"
                      + " instead of \(newKey.digest.prefix(8))")
        XCTAssertEqual(displayedThumbKey(cell.card), newKey,
                       "原图格子仍拿着编辑前的 ThumbKey")
        let refreshedBytes = try pixelBytes(cell.card.thumbnail)
        XCTAssertNotEqual(refreshedBytes, oldBytes, "原图格子的位图没有变")

        // 「先手工 reload() 再看」 — the fresh row from the library, drawn through the same provider.
        session.reload()
        let originalAfter = try XCTUnwrap(session.stackMembers(ofAssetID: original.id)?
            .first { $0.id == original.id })
        let reloadKey = ThumbnailProvider.hdJPEGKey(for: originalAfter)
        XCTAssertEqual(reloadKey, newKey, "reload serves the edited document")
        let reloadCell = MemberCell(provider: provider, session: session, display: display)
        reloadCell.show(originalAfter)
        XCTAssertTrue(waitFor { reloadCell.card.thumbnailKey == reloadKey
                                && reloadCell.card.thumbnail != nil })
        XCTAssertEqual(displayedThumbKey(reloadCell.card), displayedThumbKey(cell.card),
                       "刷新后的键与手工 reload 后不一致")
        XCTAssertEqual(try pixelBytes(reloadCell.card.thumbnail), refreshedBytes,
                       "刷新后的位图与手工 reload 后不是逐字节相同")
    }

    // MARK: - 2 · a plain stack's hidden member is not a second copy of the document

    func testAPlainStacksHiddenMemberKeepsItsOwnPixels() throws {
        let library = try makeLibrary(filenames: ["HDR_A.dng", "HDR_B.dng", "HDR_C.dng"])
        let top = library.assets[0]
        let hidden = library.assets[1]
        let summary = try XCTUnwrap(try library.catalog.makeStack(assetIDs: [top.id, hidden.id]))
        XCTAssertEqual(summary.kind, .plain)
        XCTAssertEqual(summary.topID, top.id)

        let session = try openSession(library.package)
        let cache = try XCTUnwrap(session.thumbnailCache)
        cacheRoots.append(cache.root)
        let display = ImageSize(width: 96, height: 64)
        let provider = ThumbnailProvider.shared(for: cache)

        let hiddenBefore = try XCTUnwrap(session.stackMembers(ofAssetID: hidden.id)?
            .first { $0.id == hidden.id })
        let hiddenKey = ThumbnailProvider.hdJPEGKey(for: hiddenBefore)
        try seed(cache, key: hiddenKey, color: .systemBlue)
        let hiddenCell = MemberCell(provider: provider, session: session, display: display)
        hiddenCell.show(hiddenBefore)
        XCTAssertTrue(waitFor { hiddenCell.card.thumbnailKey == hiddenKey
                                && hiddenCell.card.thumbnail != nil })
        let hiddenBytes = try pixelBytes(hiddenCell.card.thumbnail)

        let topBefore = try XCTUnwrap(session.assets.first { $0.id == top.id })
        var edited = EditModel.neutral
        edited.light.exposure = 0.75
        try seed(cache, key: ThumbKey.hdJPEG(contentHash: topBefore.contentHash, document: edited),
                 color: .systemYellow)

        var notified: [String] = []
        let token = session.addEditObserver { notified.append($0) }
        defer { session.removeEditObserver(token) }

        session.selectOnly(top.id)
        session.applyEdit { $0.light.exposure = 0.75 }
        XCTAssertTrue(session.commitEdit(label: "曝光"))
        pump(0.2)

        XCTAssertEqual(notified, [top.id],
                       "a plain stack must not refresh a hidden member (525 is denoise-only)")
        XCTAssertEqual(displayedThumbKey(hiddenCell.card), hiddenKey)
        XCTAssertEqual(try pixelBytes(hiddenCell.card.thumbnail), hiddenBytes,
                       "普通堆叠的隐藏成员位图被改动了")
        XCTAssertEqual(try library.catalog.develop(forAsset: hidden.id), .neutral,
                       "普通堆叠的隐藏成员文档被改写了")
    }

    // MARK: - 3 · a photo in no stack keeps the existing single-cell path

    func testASinglePhotoWithoutAStackIsUnaffected() throws {
        let library = try makeLibrary(filenames: ["Solo.dng"])
        let asset = try XCTUnwrap(library.assets.first)
        let session = try openSession(library.package)
        let cache = try XCTUnwrap(session.thumbnailCache)
        cacheRoots.append(cache.root)
        let display = ImageSize(width: 96, height: 64)
        let provider = ThumbnailProvider.shared(for: cache)

        let before = try XCTUnwrap(session.assets.first { $0.id == asset.id })
        let oldKey = ThumbnailProvider.hdJPEGKey(for: before)
        try seed(cache, key: oldKey, color: .systemOrange)
        let cell = MemberCell(provider: provider, session: session, display: display)
        cell.show(before)
        XCTAssertTrue(waitFor { cell.card.thumbnailKey == oldKey && cell.card.thumbnail != nil })
        let oldBytes = try pixelBytes(cell.card.thumbnail)

        var edited = EditModel.neutral
        edited.light.exposure = -0.5
        let newKey = ThumbKey.hdJPEG(contentHash: before.contentHash, document: edited)
        try seed(cache, key: newKey, color: .systemPurple)

        var notified: [String] = []
        let token = session.addEditObserver { notified.append($0) }
        defer { session.removeEditObserver(token) }

        session.selectOnly(asset.id)
        session.applyEdit { $0.light.exposure = -0.5 }
        XCTAssertTrue(session.commitEdit(label: "曝光"))

        XCTAssertEqual(notified, [asset.id], "a single photo names only itself")
        // One photo has no sibling signal: its cell moves through the existing `persistCount`
        // refresh, which reads the row `adoptCommittedDocument` just updated.
        let committed = try XCTUnwrap(session.assets.first { $0.id == asset.id })
        cell.show(committed)
        XCTAssertTrue(waitFor { cell.card.thumbnailKey == newKey && cell.card.thumbnail != nil })
        XCTAssertEqual(displayedThumbKey(cell.card), newKey)
        let newBytes = try pixelBytes(cell.card.thumbnail)
        XCTAssertNotEqual(newBytes, oldBytes)

        session.reload()
        let after = try XCTUnwrap(session.assets.first { $0.id == asset.id })
        let reloadKey = ThumbnailProvider.hdJPEGKey(for: after)
        XCTAssertEqual(reloadKey, newKey)
        let reloadCell = MemberCell(provider: provider, session: session, display: display)
        reloadCell.show(after)
        XCTAssertTrue(waitFor { reloadCell.card.thumbnailKey == reloadKey
                                && reloadCell.card.thumbnail != nil })
        XCTAssertEqual(displayedThumbKey(reloadCell.card), displayedThumbKey(cell.card))
        XCTAssertEqual(try pixelBytes(reloadCell.card.thumbnail), newBytes)
    }

    // MARK: - the expanded member's cell, through the shared provider

    /// The one-cell shape an expanded stack member uses: an `AssetCardView` fed by
    /// `ThumbnailProvider.shared(for:)`. Nothing here invents a cache family — the key is the
    /// `hdJPEG` key the grid/list/filmstrip already use.
    @MainActor
    private final class MemberCell {
        let card = AssetCardView()
        private let provider: ThumbnailProvider
        private let session: CatalogSession
        private let display: ImageSize
        private var token: ThumbnailRequest?

        init(provider: ThumbnailProvider, session: CatalogSession, display: ImageSize) {
            self.provider = provider
            self.session = session
            self.display = display
        }

        func show(_ asset: Asset) {
            let key = ThumbnailProvider.hdJPEGKey(for: asset)
            if let cached = provider.serveFromMemory(for: key, display: display) {
                card.applyThumbnail(cached, key: key, display: display)
                return
            }
            guard let url = session.fileURL(for: asset) else { return }
            token = provider.request(index: 0, asset: asset, fileURL: url, document: nil,
                                     tier: .t2048, spec: .hdJPEG, display: display) {
                [weak self] _, key, image in
                guard let self, let image else { return }
                self.card.applyThumbnail(image, key: key, display: self.display)
            }
        }
    }

    private func displayedThumbKey(_ card: AssetCardView) -> ThumbKey? { card.thumbnailKey }

    // MARK: - fixture

    private struct Library {
        let catalog: Catalog
        let package: URL
        let assets: [Asset]
    }

    private func makeLibrary(filenames: [String]) throws -> Library {
        let package = workDir.appendingPathComponent("Denoise525.\(LibraryLayout.packageExtension)",
                                                    isDirectory: true)
        let catalog = try Catalog.create(at: package)
        let source = workDir.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let root = try catalog.ensureRoot(for: source, mode: .reference)

        var assets: [Asset] = []
        for (index, filename) in filenames.enumerated() {
            try Data([0x00]).write(to: source.appendingPathComponent(filename))
            let asset = Asset(sourceRootId: root.id, relPath: filename, filename: filename,
                              ext: "dng", kind: .raw, size: 1, mtime: 0,
                              contentHash: UUID().uuidString,
                              width: 6000, height: 4000,
                              captureTime: String(format: "2026-11-23T10:%02d:00Z", index),
                              captureLocalDate: "2026-11-23 10:00",
                              cameraMake: "Leica Camera AG", cameraModel: "Leica SL3",
                              cameraKey: "leica|sl3")
            try catalog.dbQueue.write { db in try asset.insert(db) }
            assets.append(asset)
        }
        return Library(catalog: catalog, package: package, assets: assets)
    }

    private func openSession(_ package: URL) throws -> CatalogSession {
        let session = CatalogSession(remembersRecentLibrary: false)
        try session.open(package)
        return session
    }

    /// A ready HD JPEG for `key`, so the test measures the refresh signal instead of the RAW
    /// renderer. Distinct colours make "old bytes" and "new bytes" unambiguous.
    private func seed(_ cache: ThumbnailCache, key: ThumbKey, color: NSColor) throws {
        let width = 96, height = 64
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
                                              bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(color.usingColorSpace(.sRGB)?.cgColor
                             ?? CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        try cache.store(image: image, for: key)
    }

    private func pixelBytes(_ image: CGImage?) throws -> Data {
        let image = try XCTUnwrap(image)
        let width = image.width, height = image.height
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
                                              bitsPerComponent: 8, bytesPerRow: width * 4,
                                              space: space,
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let data = try XCTUnwrap(context.data)
        return Data(bytes: data, count: width * height * 4)
    }

    private func pump(_ seconds: TimeInterval = 0.005) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    @discardableResult
    private func waitFor(_ timeout: TimeInterval = 20, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            pump()
        }
        return condition()
    }
}
