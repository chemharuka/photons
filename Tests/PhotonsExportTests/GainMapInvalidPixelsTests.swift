import XCTest
import PhotonsCore
@testable import PhotonsExport

final class GainMapInvalidPixelsTests:XCTestCase {
    func testNegativeAndNonfiniteChannelsDoNotCrashAnyGainMap() throws {
        let rgb:[Float16]=[-0.8,0.2,4,1, .nan,.infinity,-.infinity,1, 2,1,0,1, 0,0,0,0]
        let linear=LinearPixels(width:2,height:2,rgba:rgb,primaries:.displayP3)
        let base=DisplayImage(width:2,height:2,rgba:[Float16](repeating:0.5,count:16),primaries:.displayP3,bitDepth:8)
        for mode in [HDRExport.GainMap.iso,.mono,.apple] {
            for half in [true,false] {
                let map=try GainMapPixels(sdr:base,linear:linear,headroom:4,mode:mode,halfSize:half)
                XCTAssertEqual(map.data.count,map.width*map.height*map.channels)
            }
        }
        XCTAssertThrowsError(try GainMapPixels(sdr:base,linear:linear,headroom:.nan,mode:.iso,halfSize:true))
    }
    func testReducedMapAveragesGainsBeforeQuantizing() throws {
        let linear=LinearPixels(width:2,height:2,rgba:[0.5,0.5,0.5,1, 1,1,1,1, 2,2,2,1, 4,4,4,1],primaries:.sRGB)
        let base=DisplayImage(width:2,height:2,rgba:[Float16](repeating:0.5,count:16),primaries:.sRGB,bitDepth:8)
        let map=try GainMapPixels(sdr:base,linear:linear,headroom:4,mode:.iso,halfSize:true)
        let s=GainMapHEIC.srgbToLinear(0.5)
        let gains:[Float]=[0.5,1,2,4].map {min(1,max(0,log2(($0+GainMapHEIC.k)/(s+GainMapHEIC.k))/2))}
        let expected=UInt8((gains.reduce(0,+)/4*255+0.5))
        XCTAssertEqual(map.data,Data([255,expected,expected,expected]))
    }
}
