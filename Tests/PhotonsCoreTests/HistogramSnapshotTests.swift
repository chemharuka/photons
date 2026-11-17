import XCTest
@testable import PhotonsCore

final class HistogramSnapshotTests:XCTestCase {
    func testPersistentCountsExcludeMatteAndKeepHDR() throws {
        let sample=LinearSample(width:2,height:2,rgba:[0.18,0.18,0.18,1, 2,2,2,1, 8,8,8,1, HistogramSnapshot.excludedSample,0,0,1])
        let snapshot=HistogramSnapshot(sample:sample,canvas:ImageSize(width:2000,height:2000))
        XCTAssertTrue(snapshot.isValid)
        XCTAssertEqual(snapshot.hdr.sampleCount,3)
        XCTAssertEqual(snapshot.sdr.sampleCount,3)
        XCTAssertEqual(snapshot.hdr.red.hdrBins.reduce(0,+),2)
        XCTAssertEqual(snapshot.sdr.red.hdrBins.reduce(0,+),0)
        let higher=snapshot.histogram(hdr:true,headroom:4)
        XCTAssertEqual(higher.red.bins,snapshot.hdr.red.bins)
        XCTAssertEqual(higher.red.hdrBins,snapshot.hdr.red.hdrBins)
        XCTAssertEqual(higher.red.clippedCeiling,1.0/3,accuracy:0.01)
        XCTAssertEqual(try JSONDecoder().decode(HistogramSnapshot.self,from:JSONEncoder().encode(snapshot)),snapshot)
    }
}
