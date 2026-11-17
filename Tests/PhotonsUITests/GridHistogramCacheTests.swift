import XCTest
import GRDB
import PhotonsCore
import PhotonsCatalog
@testable import PhotonsUI

@MainActor
final class GridHistogramCacheTests:XCTestCase {
    func testRepeatedSelectionUsesCachedCountsWithoutRAWDecoding() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root)}
        let library=root.appendingPathComponent("Test.photonslibrary")
        let catalog=try Catalog.create(at:library),source=try catalog.ensureRoot(for:root,mode:.reference)
        for i in 0..<2 {
            let asset=Asset(sourceRootId:source.id,relPath:"\(i).dng",filename:"\(i).dng",ext:"dng",kind:.raw,size:1,mtime:0,contentHash:"hist-\(i)",width:2000,height:1500)
            try catalog.dbQueue.write {try asset.insert($0)}
        }
        let session=CatalogSession();try session.open(library)
        let provider=ThumbnailProvider.shared(for:try XCTUnwrap(session.thumbnailCache))
        let snapshot=HistogramSnapshot(sample:LinearSample(width:1,height:1,rgba:[0.1,0.2,0.3,1]),canvas:ImageSize(width:2000,height:1500))
        for asset in session.assets {provider.histograms.cache.store(snapshot,for:HistogramCacheKey(thumbnail:ThumbnailProvider.hdJPEGKey(for:asset)))}
        let controller=GridHistogramController(session:session,headroom:{4})
        RAWDecoder.resetDecodeCounts()
        let computations=provider.histograms.cache.stats.computations
        for _ in 0..<10 {for asset in session.assets {
            session.selectOnly(asset.id);controller.refresh()
            XCTAssertEqual(session.lastHistogram?.sampleCount,1)
        }}
        XCTAssertEqual(provider.histograms.cache.stats.computations,computations)
        XCTAssertTrue(RAWDecoder.decodeCounts().values.allSatisfy {$0==0})
    }
}
