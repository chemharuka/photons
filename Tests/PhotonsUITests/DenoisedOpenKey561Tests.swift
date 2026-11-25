import XCTest
import AppKit
import GRDB
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsCatalog
@testable import PhotonsUI

/// §561 — **the open path must carry the denoise fact too**, so `ver=` and the pixels agree.
///
/// 559 taught the decoder (`RAWDecoder.decodeDetailed`) to fall back to the classic family when the
/// file name marks a denoise product. The open path resolves the document's spelling *before* that
/// decode, from `DocumentFacts`; if it forgets `facts.denoisedProduct`, the document stores `9`
/// while the pixels come from `8`, and the cache key names a buffer that never existed.
///
/// These cases use the real boston pair: `L1030946-denoised.dng` (marked, ISO 3200) and
/// `L1030946.dng` (the same frame, unmarked). The reverse gate is explicit: drop `denoised:` from
/// `CatalogSession.resolution(from:resolved:)` and the first scenario answers `"9"` (red).
@MainActor
final class DenoisedOpenKey561Tests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-561-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    private static func boston(_ name: String) -> URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop/boston/\(name)")
    }

    // MARK: - 1 + 2. the real open path

    /// Both halves of the acceptance pair live in one case on purpose: commenting out the `denoised:`
    /// fact makes this case red (the marked file opens as `"9"`), and the unmarked half is asserted in
    /// the same run so the two spellings cannot drift apart.
    func testOpenKeysCarryTheDenoiseMarkerAndLeaveUnmarkedFilesAlone() throws {
        let denoised = Self.boston("L1030946-denoised.dng")
        let plain = Self.boston("L1030946.dng")
        guard FileManager.default.isReadableFile(atPath: denoised.path),
              FileManager.default.isReadableFile(atPath: plain.path) else {
            throw XCTSkip("需要 ~/Desktop/boston/L1030946-denoised.dng 与 L1030946.dng")
        }

        // 1 — marked product: pixels come from the classic family, so the document and the key must
        // name 8, never the 9 the raw `available` list would pick at ISO 3200.
        let marked = try openLibrary(importing: denoised)
        XCTAssertEqual(marked.session.edit.resolvedDecoderVersion, "8",
                       "文件名带 denoise ⇒ 打开路径也选 8")
        let markedKey = marked.session.edit.decodeKey
        XCTAssertTrue(markedKey.contains("ver=8"), markedKey)
        XCTAssertFalse(markedKey.contains("ver=9"), "键必须与像素一致：\(markedKey)")
        marked.cleanUp()

        // 2 — the same frame without the marker: §554's high-ISO answer stays intact (ver=9).
        let unmarked = try openLibrary(importing: plain)
        XCTAssertEqual(unmarked.session.edit.resolvedDecoderVersion, "9",
                       "未标记文件仍是高 ISO ⇒ 9")
        let unmarkedKey = unmarked.session.edit.decodeKey
        XCTAssertTrue(unmarkedKey.contains("ver=9"), unmarkedKey)
        unmarked.cleanUp()
    }

    // MARK: - 3. the adopt path's new fact

    /// `adoptDecoderResolution` is what 560 will call. Its `denoised:` argument must reach the same
    /// resolver: `true` pulls bare `9` back to `8`, `false` keeps §554's `9`.
    func testAdoptDecoderResolutionHonoursTheDenoisedFact() {
        let all = ["9", "9.dng", "8", "8.dng"]

        let marked = CatalogSession()
        XCTAssertEqual(marked.adoptDecoderResolution(
            available: all, iso: 3200, denoised: true, effectiveDefault: "8"), "8")
        XCTAssertEqual(marked.edit.resolvedDecoderVersion, "8")

        let plain = CatalogSession()
        XCTAssertEqual(plain.adoptDecoderResolution(
            available: all, iso: 3200, denoised: false, effectiveDefault: "8"), "9")
        XCTAssertEqual(plain.edit.resolvedDecoderVersion, "9")

        // The default is the old behaviour, so existing callers keep their meaning.
        let byDefault = CatalogSession()
        XCTAssertEqual(byDefault.adoptDecoderResolution(
            available: all, iso: 3200, effectiveDefault: "8"), "9")
    }

    // MARK: - library fixture

    private final class MemoryStore: FilterPersistence.Store, PhotoSortPreferences.Store {
        var filters: [String: String] = [:]
        var sort: [String: String] = [:]
        func storedFilterJSON(forKey key: String) -> String? { filters[key] }
        func storeFilterJSON(_ json: String, forKey key: String) { filters[key] = json }
        func removeFilterJSON(forKey key: String) { filters.removeValue(forKey: key) }
        func sortOrderRaw(forKey key: String) -> String? { sort[key] }
        func storeSortOrderRaw(_ raw: String?, forKey key: String) { sort[key] = raw }
    }

    private struct Library {
        let catalog: Catalog
        let session: CatalogSession
        let assetID: String
        let workDir: URL

        func cleanUp() { try? FileManager.default.removeItem(at: workDir) }
    }

    /// A fresh library that imports the given real file by **reference** (no 67 MB copy), then opens
    /// it and selects it — the same shape 554/555 use for their library fixtures.
    private func openLibrary(importing file: URL) throws -> Library {
        let root = workDir.appendingPathComponent("lib-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let package = root.appendingPathComponent("L.\(LibraryLayout.packageExtension)",
                                                  isDirectory: true)
        let catalog = try Catalog.create(at: package)
        let summary = try ImportService(catalog: catalog).run(
            sources: [file], options: ImportOptions(mode: .reference))
        let assetID = try XCTUnwrap(summary.addedAssetIDs.first,
                                    "导入失败：added=\(summary.added) failed=\(summary.failed)")

        let store = MemoryStore()
        let session = CatalogSession(filterStore: store, sortPreferenceStore: store,
                                     remembersRecentLibrary: false)
        try session.open(package)
        session.setSortOrder(.newestFirst)
        session.selectOnly(assetID)
        return Library(catalog: catalog, session: session, assetID: assetID, workDir: root)
    }
}
