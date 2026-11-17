import XCTest
import PhotonsCore
@testable import PhotonsCatalog

final class HistogramCacheTests:XCTestCase {
    func testReopenEditInvalidationAndCorruptCacheRecovery() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let snapshot=HistogramSnapshot(sample:LinearSample(width:1,height:1,rgba:[0.2,0.4,2,1]),canvas:ImageSize(width:100,height:100))
        let key=HistogramCacheKey(thumbnail:.hdJPEG(contentHash:"photo",document:.neutral))
        let first=HistogramCache(root:root);first.store(snapshot,for:key)
        let reopened=HistogramCache(root:root)
        XCTAssertEqual(reopened.load(key),snapshot)
        XCTAssertEqual(reopened.stats.diskHits,1)
        XCTAssertEqual(reopened.load(key),snapshot)
        XCTAssertEqual(reopened.stats.diskHits,1,"Selecting again reuses memory counts")
        var edit=EditModel.neutral;edit.light.exposure=1
        let changed=HistogramCacheKey(thumbnail:.hdJPEG(contentHash:"photo",document:edit))
        XCTAssertNil(reopened.load(changed))
        reopened.store(snapshot,for:changed)
        XCTAssertEqual(first.url(for:key),first.url(for:changed),"Old edit generations do not accumulate on disk")
        XCTAssertNil(HistogramCache(root:root).load(key))
        try Data("broken".utf8).write(to:first.url(for:key))
        XCTAssertNil(HistogramCache(root:root).load(changed))
    }
}
