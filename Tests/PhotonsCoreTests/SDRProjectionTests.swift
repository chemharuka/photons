import XCTest
import Metal
@testable import PhotonsCore

final class SDRProjectionTests:XCTestCase {
    func testSDRPreviewAndStandardExportMatchAndHistogramFollows() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {throw XCTSkip("Metal unavailable")}
        let pixels:[Float16]=[0.2,0.3,0.4,1, 2,1,0.5,1, 4,3,2,1, 0.8,0.8,0.8,1]
        let input=LinearImage(width:2,height:2,rgba:pixels,colorSpace:"extendedLinearSRGB",decoderVersion:"sdr-proof")
        let graph=try RenderGraph(input:RenderInput(image:input,identity:"sdr-proof"))
        defer {graph.releaseAllTextures()}
        let preview=try graph.render(.neutral,options:RenderOptions(display:DisplayOptions(primaries:.displayP3,bitDepth:16,sdrProof:true),useCache:false,collectHistogram:true))
        let raw=try XCTUnwrap(try graph.render(.neutral,options:RenderOptions(display:DisplayOptions(primaries:.displayP3,bitDepth:16,linearOutput:true),useCache:false)).display)
        let exported=LinearPixels(raw).displaySDR(bitDepth:16,toneMap:.standard)
        let displayed=try XCTUnwrap(preview.display)
        for i in displayed.rgba.indices {XCTAssertEqual(Float(displayed.rgba[i]),Float(exported.rgba[i]),accuracy:0.002)}
        let histogram=try XCTUnwrap(preview.histogram)
        XCTAssertEqual(histogram.red.hdrBins.reduce(0,+),0)
        XCTAssertEqual(histogram.green.hdrBins.reduce(0,+),0)
        XCTAssertEqual(histogram.blue.hdrBins.reduce(0,+),0)
        XCTAssertEqual(SDRProjection.map(SIMD3(0.2,0.3,0.4)),SIMD3(0.2,0.3,0.4))
    }
}
