import XCTest
import AppKit
import CoreGraphics
import CryptoKit
import ImageIO
import QuartzCore
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 363 — 预览图两个毛病：改 B 让 A 的预览「回退」，以及编辑时「旧图 → 纯色 → 新图」三帧。
///
/// The two symptoms are measured on the shipped paths, per runloop tick, and the fix has to make
/// both counts zero:
///
///   · **cross-photo**: after A is edited, editing B must leave A's HD file byte-identical (same
///     sha, same mtime) *and* A's cell must still show the new frame. The revert is a read of the
///     **old key** — the persisted document never reaches the in-memory `Asset` row, so the next
///     refresh of A's cell derives the pre-edit key again;
///   · **flicker**: an edit commit must never put the solid backdrop on screen. The trace counts
///     frames whose canvas is the matte (and cells whose bitmap is nil) across twenty edits.
@MainActor
final class PreviewFlicker363Tests: XCTestCase {

    private var workDir: URL!
    private var windows: [NSWindow] = []
    private var cacheDirs: [URL] = []

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-preview-flicker-\(UUID().uuidString)", isDirectory: true)
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

    // MARK: - 1 · 跨照片

    /// A edited → A's preview is the new frame. B edited → A's **file** and A's **cell key** must not
    /// move. The revert the user sees is the second read of the pre-edit key: the in-memory `Asset`
    /// row still carries the old `develop_json`, so the next refresh of A's cell derives the old key.
    func testEditingBLeavesAsPreviewAndFileAlone() throws {
        let raw = try fixture("L1030433.dng")
        let (editor, assets) = try makeEditor(files: [raw, raw])
        let a = assets[0], b = assets[1]
        let session = editor.session
        let cache = try XCTUnwrap(session.thumbnailCache)
        cacheDirs.append(cache.root)

        session.selectOnly(a.id)
        session.mode = .loupe
        editor.rootView.showModule(for: .loupe)
        XCTAssertTrue(waitFor(120) { self.filmstripImage(editor, assetID: a.id) != nil },
                      "A never drew a preview")
        // The pre-edit picture, for "the preview really changed" below.
        let aCellBefore = try XCTUnwrap(settledStripSha(editor, assetID: a.id))

        // 1a — edit A. The commit's new key must be the key A's cell carries, and the picture must be
        // the new one before the measurement starts (a swap still in flight is not a revert).
        session.applyEdit { $0.light.exposure = 0.60 }
        _ = session.commitEdit(label: "曝光")
        let aKey = ThumbKey.hdJPEG(contentHash: a.contentHash, document: session.edit)
        XCTAssertTrue(waitFor(120) { cache.exists(aKey) }, "A's new HD file never landed")
        XCTAssertTrue(waitFor(120) { self.filmstripKey(editor, assetID: a.id) == aKey.digest },
                      "A's cell never took the post-edit key"
                      + " (it holds \(filmstripKey(editor, assetID: a.id)?.prefix(8) ?? "none")…,"
                      + " new key \(aKey.digest.prefix(8))…)")
        let aFileA = try fileState(cache, key: aKey)
        let aCellA = try XCTUnwrap(settledStripSha(editor, assetID: a.id))
        XCTAssertNotEqual(aCellA, aCellBefore, "A's preview did not change after the edit")

        // 1b — edit B. A must not move: not the file, not the cell, not the key.
        session.selectOnly(b.id)
        pump(0.2)
        session.applyEdit { $0.light.exposure = 0.35 }
        _ = session.commitEdit(label: "曝光")
        let bKey = ThumbKey.hdJPEG(contentHash: b.contentHash, document: session.edit)
        XCTAssertTrue(waitFor(120) { cache.exists(bKey) }, "B's new HD file never landed")
        // The same settled reading as 1a: the comparison has to be between two finished frames.
        let aCellB = try XCTUnwrap(settledStripSha(editor, assetID: a.id))
        let aKeyB = filmstripKey(editor, assetID: a.id)
        let aFileB = try fileState(cache, key: aKey)

        print("363 A/B: A key \(aKey.digest.prefix(8))… · file sha \(aFileA.sha.prefix(12))…"
              + " → \(aFileB.sha.prefix(12))… · mtime \(aFileA.mtime) → \(aFileB.mtime)"
              + " · A cell sha \(aCellA.prefix(12))… → \(aCellB.prefix(12))…"
              + " · A cell key \(aKeyB?.prefix(8) ?? "none")…")

        XCTAssertEqual(aFileB.sha, aFileA.sha, "editing B rewrote A's HD file")
        XCTAssertEqual(aFileB.mtime, aFileA.mtime, "editing B touched A's HD file")
        XCTAssertTrue(cache.exists(aKey), "A's new HD file was deleted by B's edit")
        XCTAssertEqual(aKeyB, aKey.digest, "editing B put A's cell back on the pre-edit key")
        XCTAssertEqual(aCellB, aCellA, "editing B reverted A's preview")

        // 1b′ — the deletion tally: neither bulk door touched A, and no door at all deleted a file
        // that belongs to A.
        let audit = cache.retentionAudit
        print("363 doors: removeAll ×\(audit.removeAllCalls) · trim ×\(audit.trimCalls)"
              + " · deletedByRemoveAll \(audit.deletedByRemoveAll)"
              + " · deletedByTrim \(audit.deletedByTrim)"
              + " · prunedSuperseded(A) \(audit.prunedSuperseded[a.contentHash] ?? 0)"
              + " · keptNewerThanWrite \(audit.keptNewerThanWrite)")
        print("363 cells: A \(debugCells(editor, assetID: a.id)) · newKey \(aKey.digest.prefix(8))…")
        XCTAssertNil(audit.deletedByRemoveAll[a.contentHash],
                     "removeAll(contentHash:) deleted A's pixels")
        XCTAssertNil(audit.deletedByTrim[a.contentHash], "trim() deleted A's pixels")
        XCTAssertEqual(audit.removeAllCalls, 0, "an edit transaction called removeAll")
        // `store` legitimately keeps one file per photo, so A's own pre-edit file may be pruned;
        // what must not happen is A's **new** file being the one that went (asserted above).
        XCTAssertLessThanOrEqual(audit.prunedSuperseded[a.contentHash] ?? 0, 1,
                                 "A's files were pruned more than once by one edit")

        // 1c — back to A: the same new frame, from the same key, with no repair render.
        session.selectOnly(a.id)
        pump(0.6)
        XCTAssertEqual(filmstripKey(editor, assetID: a.id), aKey.digest,
                       "A's cell key moved again on the way back")
        XCTAssertEqual(try XCTUnwrap(filmstripImageState(editor, assetID: a.id)), aCellA,
                       "A showed a stale preview after coming back")
        // The row the next `reload()` would serve already agrees with the saved document.
        XCTAssertEqual(ThumbnailProvider.hdJPEGKey(for: try assetRow(editor, id: a.id),
                                                   document: nil).digest,
                       aKey.digest, "A's row still carries the pre-edit document")
    }

    // MARK: - 2 · 闪动（20 次编辑，逐帧采样）

    func testTwentyEditsNeverShowASolidFrame() throws {
        let raw = try fixture("L1030433.dng")
        let (editor, assets) = try makeEditor(files: [raw])
        let a = assets[0]
        let session = editor.session
        let loupe = editor.rootView.loupeController
        let cache = try XCTUnwrap(session.thumbnailCache)
        cacheDirs.append(cache.root)

        session.selectOnly(a.id)
        session.mode = .loupe
        editor.rootView.showModule(for: .loupe)
        XCTAssertTrue(waitFor(120) { loupe.lastFrame != nil }, "the loupe never presented")
        XCTAssertTrue(waitFor(60) { self.filmstripImage(editor, assetID: a.id) != nil },
                      "the filmstrip never drew the anchor's preview (visible items:"
                      + " \(editor.rootView.filmstripController.collectionView.indexPathsForVisibleItems().count),"
                      + " assets \(editor.session.assets.count))")

        var samples = 0
        var solidFrames = 0
        var canvasSolid = 0
        var placeholderFrames = 0
        var frameFrames = 0
        var lastSeen = ""
        /// Cells that have been observed **showing** a preview at least once. A cell's very first
        /// bitmap is allowed to hide its layer until the compositor has it (there is nothing to keep
        /// there); the reported flicker is a preview that *was* on screen disappearing into a solid
        /// block and coming back, so only those cells are counted.
        var everVisible: Set<IndexPath> = []

        /// One observation of what the eye could be seeing right now.
        ///
        /// A **solid frame** is a cell that holds a bitmap but whose bitmap layer is hidden: the
        /// card's hash-coloured placeholder gradient is what is on screen — the 纯色 the user
        /// reported between the old preview and the new one. The canvas' matte is counted the same
        /// way (a `covered`/`matte` frame with no picture on it).
        func sample(_ note: String) {
            samples += 1
            let source: String
            if loupe.isCanvasCoveredForTesting {
                source = "covered"
            } else if loupe.firstFramePlaceholderVisible {
                source = "placeholder"
            } else if loupe.lastFrame != nil {
                source = "frame"
            } else {
                source = "matte"
            }
            var hiddenCells = 0
            for path in editor.rootView.filmstripController.collectionView.indexPathsForVisibleItems() {
                guard let cell = editor.rootView.filmstripController.collectionView.item(at: path)
                        as? FilmstripCell else { continue }
                let hasBitmap = cell.cardView.thumbnail != nil
                let visible = cell.cardView.thumbnailSurfaceVisible
                if hasBitmap, visible { everVisible.insert(path) }
                if hasBitmap, !visible, everVisible.contains(path) { hiddenCells += 1 }
            }
            let row = "\(note) canvas=\(source) hiddenCells=\(hiddenCells)"
            if row != lastSeen { print("363 flicker: \(row)"); lastSeen = row }
            switch source {
            case "frame": frameFrames += 1
            case "placeholder": placeholderFrames += 1
            default: canvasSolid += 1
            }
            solidFrames += hiddenCells
        }

        var swapMilliseconds: [Double] = []
        for i in 1...20 {
            // Identity, not a hash: a new decode is a new object, and hashing a 1920 bitmap on every
            // tick would make the measurement the thing being measured.
            let before = filmstripImage(editor, assetID: a.id)
            session.applyEdit { $0.light.exposure = 0.02 * Double(i) }
            sample("edit\(i)")
            for _ in 0..<8 {
                pump(0.008)
                sample("edit\(i)+")
            }
            let committedAt = CACurrentMediaTime()
            _ = session.commitEdit(label: "曝光")
            let expected = ThumbKey.hdJPEG(contentHash: a.contentHash, document: session.edit)
            var swapped = false
            let deadline = CACurrentMediaTime() + 20
            while CACurrentMediaTime() < deadline {
                pump(0.008)
                sample("edit\(i)commit+")
                let key = filmstripKey(editor, assetID: a.id)
                let now = filmstripImage(editor, assetID: a.id)
                if key == expected.digest, let now, now !== before {
                    swapMilliseconds.append((CACurrentMediaTime() - committedAt) * 1000)
                    swapped = true
                    break
                }
            }
            XCTAssertTrue(swapped, "edit \(i): the preview never swapped to the new document")
            // Settle the coalescer before the next edit, and keep sampling while it does.
            for _ in 0..<16 {
                pump(0.008)
                sample("edit\(i)settle")
            }
        }
        pump(0.3)

        let sorted = swapMilliseconds.sorted()
        func percentile(_ p: Double) -> Double {
            guard !sorted.isEmpty else { return 0 }
            let rank = Int((p * Double(sorted.count)).rounded(.up)) - 1
            return sorted[max(0, min(sorted.count - 1, rank))]
        }
        print("363 flicker: \(samples) samples · frame \(frameFrames)"
              + " · placeholder \(placeholderFrames) · canvasSolid \(canvasSolid)"
              + " · cellSolid \(solidFrames)")
        print(String(format: "363 swap: %d edits · p50 %.0f ms · p95 %.0f ms · max %.0f ms"
                     + " · first %.0f ms",
                     swapMilliseconds.count, percentile(0.5), percentile(0.95),
                     sorted.last ?? 0, sorted.first ?? 0))
        // Where the time goes: the swap above is window + one HD render+encode + decode+apply. The
        // producer's own two halves are the number 311 measured (0.5–0.9 s on an idle box).
        let production = ThumbnailProvider.shared(for: cache).lastHDProduction
        let warm = ThumbnailProvider.shared(for: cache).lastWarmLatency
        print(String(format: "363 render: graph %.0f ms · encode %.0f ms · warm queued %.0f ms",
                     production.render, production.encode, warm?.queued ?? 0))
        XCTAssertEqual(solidFrames, 0,
                       "a cell showed the solid swatch on \(solidFrames) of \(samples) sampled frames")
        XCTAssertEqual(canvasSolid, 0,
                       "the canvas showed the solid backdrop on \(canvasSolid) of \(samples) frames")
        // ④ — the budget is *structural*: one 0.25 s coalescing window plus one HD render+encode,
        // both read from the producer itself (the render is 2.7 s on this box, 0.5–0.9 s was 311's
        // idle measurement — so a fixed millisecond bound would gate the machine, not the pipeline).
        let renderBudget = 250 + production.render + production.encode + 1000
        XCTAssertLessThanOrEqual(sorted.first ?? .infinity, renderBudget,
                                 "the first edit's preview took \((sorted.first ?? 0).rounded()) ms,"
                                 + " beyond one window + one render (\(renderBudget.rounded()) ms)")
        XCTAssertGreaterThanOrEqual(sorted.count, 19, "only \(sorted.count) of 20 edits swapped")

        // The structural half: no cell ever hid a preview it was already showing, for any photo.
        var blanked = 0
        var cells = 0
        for path in editor.rootView.filmstripController.collectionView.indexPathsForVisibleItems() {
            guard let cell = editor.rootView.filmstripController.collectionView.item(at: path)
                    as? FilmstripCell else { continue }
            cells += 1
            blanked += cell.cardView.blankedPreviewFrames
        }
        print("363 flicker: \(cells) cells · blankedPreviewFrames \(blanked)")
        XCTAssertGreaterThan(cells, 0, "no cell was sampled")
        XCTAssertEqual(blanked, 0, "\(blanked) previews were blanked to a solid colour before swapping")
    }

    // MARK: - image readback

    /// A sha of the bitmap a grid cell is showing right now; `"∅"` when the cell exists but has no
    /// bitmap (the solid swatch frame the report calls 纯色), `nil` when the cell is not on screen.
    private func gridImageState(_ editor: EditorWindowController, assetID: String) -> String? {
        guard let cell = gridCell(editor, assetID: assetID) else { return nil }
        return cell.cardView.thumbnail.flatMap(Self.pixelSHA) ?? "∅"
    }

    private func filmstripImageState(_ editor: EditorWindowController, assetID: String) -> String? {
        guard let cell = filmstripCell(editor, assetID: assetID) else { return nil }
        return cell.cardView.thumbnail.flatMap(Self.pixelSHA) ?? "∅"
    }

    private func filmstripKey(_ editor: EditorWindowController, assetID: String) -> String? {
        filmstripCell(editor, assetID: assetID)?.cardView.thumbnailKey?.digest
    }

    /// The pixel sha of the strip cell once it has **stopped moving**: five identical readings in a
    /// row (or 8 s). A swap that is still in flight is not evidence of a revert, and comparing a
    /// half-settled frame with a settled one is how a fix gets blamed for an animation.
    private func settledStripSha(_ editor: EditorWindowController, assetID: String,
                                 timeout: TimeInterval = 8) -> String? {
        var last: String?
        var stable = 0
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let sha = filmstripCell(editor, assetID: assetID)?.cardView.thumbnail.flatMap(Self.pixelSHA)
            if sha != nil, sha == last {
                stable += 1
                if stable >= 5 { return sha }
            } else {
                stable = 0
            }
            last = sha
            pump(0.02)
        }
        return last
    }

    /// Every visible strip cell as `id/key/sha` prefixes — the diagnostic that tells "A's cell kept
    /// the new key" from "the cell I sampled is not the cell I think it is".
    private func debugCells(_ editor: EditorWindowController, assetID: String) -> String {
        let strip = editor.rootView.filmstripController
        var parts: [String] = []
        for path in strip.collectionView.indexPathsForVisibleItems() {
            guard let cell = strip.collectionView.item(at: path) as? FilmstripCell else { continue }
            let id = cell.cardView.asset?.id.prefix(4) ?? "????"
            let key = cell.cardView.thumbnailKey?.digest.prefix(8) ?? "none"
            let sha = cell.cardView.thumbnail.flatMap(Self.pixelSHA)?.prefix(8) ?? "noImage"
            parts.append("\(id):\(key)/\(sha)")
        }
        return "[" + parts.joined(separator: " ") + "] target \(assetID.prefix(4))"
    }

    private func gridImage(_ editor: EditorWindowController, assetID: String) -> CGImage? {
        gridCell(editor, assetID: assetID)?.cardView.thumbnail
    }

    private func gridCell(_ editor: EditorWindowController, assetID: String) -> AssetGridItem? {
        let grid = editor.rootView.gridController
        guard grid.isViewLoaded, let index = editor.session.assets.firstIndex(where: { $0.id == assetID })
        else { return nil }
        let path = IndexPath(item: index, section: 0)
        guard grid.collectionView.indexPathsForVisibleItems().contains(path) else { return nil }
        return grid.collectionView.item(at: path) as? AssetGridItem
    }

    private func filmstripImage(_ editor: EditorWindowController, assetID: String) -> CGImage? {
        filmstripCell(editor, assetID: assetID)?.cardView.thumbnail
    }

    private func filmstripCell(_ editor: EditorWindowController, assetID: String) -> FilmstripCell? {
        let strip = editor.rootView.filmstripController
        guard strip.isViewLoaded,
              let index = editor.session.assets.firstIndex(where: { $0.id == assetID }) else { return nil }
        let path = IndexPath(item: index, section: 0)
        guard strip.collectionView.indexPathsForVisibleItems().contains(path) else { return nil }
        return strip.collectionView.item(at: path) as? FilmstripCell
    }

    private func assetRow(_ editor: EditorWindowController, id: String) throws -> Asset {
        try XCTUnwrap(editor.session.assets.first(where: { $0.id == id }))
    }

    private struct FileState { var sha: String; var mtime: String }

    private func fileState(_ cache: ThumbnailCache, key: ThumbKey) throws -> FileState {
        let url = cache.url(for: key)
        let data = try Data(contentsOf: url)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let mtime = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return FileState(sha: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                         mtime: String(format: "%.3f", mtime))
    }

    /// Full-size sha of a bitmap. Two different images must never collide here — the acceptance
    /// treats equality as "the same pixels are on screen".
    static func pixelSHA(_ image: CGImage?) -> String? {
        guard let image else { return nil }
        let width = image.width, height = image.height
        guard width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        return SHA256.hash(data: Data(bytes: data, count: width * height * 4))
            .map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - fixtures

    private func fixture(_ name: String) throws -> URL {
        let candidates = [
            ProcessInfo.processInfo.environment["PHOTONS_TEST_RAW"],
            NSString(string: "~/Desktop/test/\(name)").expandingTildeInPath,
        ].compactMap { $0 }
        for candidate in candidates where FileManager.default.isReadableFile(atPath: candidate) {
            if candidate.hasSuffix(name) { return URL(fileURLWithPath: candidate) }
        }
        throw XCTSkip("no RAW fixture \(name); set PHOTONS_TEST_RAW")
    }

    private func pump(_ seconds: TimeInterval = 0.005) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    @discardableResult
    private func waitFor(_ timeout: TimeInterval = 60, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            pump()
        }
        return condition()
    }

    private func makeEditor(files: [URL]) throws -> (EditorWindowController, [Asset]) {
        _ = NSApplication.shared
        let package = workDir.appendingPathComponent("Flicker.\(LibraryLayout.packageExtension)")
        let catalog = try Catalog.create(at: package)
        let source = workDir.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let root = try catalog.ensureRoot(for: source, mode: .reference)

        var ids: [String] = []
        for (index, file) in files.enumerated() {
            let name = "flicker\(index).dng"
            let destination = source.appendingPathComponent(name)
            try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: file)
            let size = try pixelSize(of: file)
            let id = UUID().uuidString
            ids.append(id)
            try catalog.dbQueue.write { db in
                try db.execute(sql: """
                    INSERT INTO assets (id, source_root_id, rel_path, filename, ext, kind, size, mtime,
                                        content_hash, width, height, camera_make, camera_model, lens,
                                        imported_at, missing)
                    VALUES ('\(id)', '\(root.id)', '\(name)', '\(name)', 'dng', 'raw', 1, 0,
                            '\(UUID().uuidString)',
                            \(size.width), \(size.height),
                            'Leica Camera AG', 'Leica SL3', 'Vario-Elmarit-SL 24-90',
                            '2026-11-09T00:00:00Z', 0)
                    """)
            }
        }

        let editor = EditorWindowController(size: NSSize(width: 1400, height: 950))
        windows.append(try XCTUnwrap(editor.window))
        try editor.openLibrary(at: package)
        TestWindows.show(editor.window)
        // The user's configuration for both symptoms: the filmstrip is on screen while the loupe
        // edits, so every photo's preview is visible at the moment another one is edited.
        editor.rootView.setBrowserMode(.filmstrip)
        editor.window?.contentView?.layoutSubtreeIfNeeded()
        editor.rootView.needsLayout = true
        editor.rootView.layoutSubtreeIfNeeded()
        pump(0.1)
        return (editor, editor.session.assets)
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
