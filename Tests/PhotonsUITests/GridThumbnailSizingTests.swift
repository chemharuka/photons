import XCTest
import AppKit
@testable import PhotonsUI

@MainActor
final class GridThumbnailSizingTests:XCTestCase {
    func testPortraitAndLandscapeAreFittedWithoutCropping() throws {
        for size in [CGSize(width:40,height:100),CGSize(width:100,height:40)] {
            let context=try XCTUnwrap(CGContext(data:nil,width:Int(size.width),height:Int(size.height),bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
            let card=AssetCardView(frame:CGRect(x:0,y:0,width:200,height:172))
            card.thumbnail=context.makeImage();card.layoutSubtreeIfNeeded()
            let frame=try XCTUnwrap(card.thumbnailLayer?.frame)
            XCTAssertEqual(frame.width/frame.height,size.width/size.height,accuracy:0.001)
            XCTAssertLessThanOrEqual(frame.width,200)
            XCTAssertLessThanOrEqual(frame.height,150)
        }
    }
    func testSliderMetricsReduceColumnsAndFitNarrowWindows() {
        XCTAssertGreaterThan(GridLayout.metrics(forWidth:1000,preferredWidth:150).columns,GridLayout.metrics(forWidth:1000,preferredWidth:350).columns)
        XCTAssertLessThanOrEqual(GridLayout.metrics(forWidth:120,preferredWidth:420).itemSize.width,120)
    }
}
