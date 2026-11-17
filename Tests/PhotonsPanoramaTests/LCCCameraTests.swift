import XCTest
import CoreImage
@testable import PhotonsPanorama
@testable import PhotonsExtensions

final class LCCCameraTests:XCTestCase {
    let neutral=SIMD3<Double>(0.4,1,0.65)
    let matrix=[0.6468,-0.1899,-0.0545,-0.4526,1.2267,0.2542,-0.0388,0.1276,0.6096]
    func fixture(orientation:Int=1) -> CameraMosaic {
        let w=320,h=240,pattern=[0,1,3,2],n=SIMD4<Double>(neutral.x,1,neutral.z,1)
        var samples=[Float](repeating:0,count:w*h)
        for y in 0..<h {for x in 0..<w {let c=pattern[(y%2)*2+x%2];samples[y*w+x]=Float(n[c]*0.3*falloff((Double(x)+0.5)/Double(w),(Double(y)+0.5)/Double(h))[c])}}
        return CameraMosaic(width:w,height:h,samples:samples,pattern:pattern,orientation:orientation,neutral:[neutral.x,1,neutral.z],matrix:matrix)
    }
    func falloff(_ x:Double,_ y:Double)->SIMD4<Double> {
        let r=(x-0.5)*(x-0.5)+(y-0.5)*(y-0.5)
        return SIMD4(exp(-4*r),exp(-6*r),exp(-8*r),exp(-6.2*r))
    }
    func profile()->LCCLensProfile {
        var p=LCCProfileTests().sample(),values:[Float]=[]
        let w=64,h=48,n=SIMD4<Double>(neutral.x,1,neutral.z,1)
        for y in 0..<h {for x in 0..<w {let v=n*falloff((Double(x)+0.5)/Double(w),(Double(y)+0.5)/Double(h));for c in 0..<4 {values.append(Float(v[c]))}}}
        p.captures[0].grid=LCCMeasurementGrid(x:(0..<w).map{(Double($0)+0.5)/Double(w)*36-18},y:(0..<h).map{12-(Double($0)+0.5)/Double(h)*24},channels:["R","G1","B","G2"],values:LCCMeasurementGrid.pack(values),space:"camera-cfa-normalized-v2")
        return p
    }
    func testCFAStageRemovesShadingAndPreservesWBMeaning() throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true);defer {try? FileManager.default.removeItem(at:dir)}
        let raw=fixture(),url=dir.appendingPathComponent("flat.dng");try raw.dng().data.write(to:url)
        let source=try PanoramaSource(url:url),sensor=SensorSize(width:36,height:24,source:"test")
        let field=try LCCCorrectionField(profile:profile(),orientation:.landscape)
        let map=LCCCameraGainMap(field:field,source:source,origin:.zero,panoramaSize:source.size,sensor:sensor,offset:.zero)
        let reading=try LCCCameraPipeline.whiteBalance(raw,gain:map,whitePlate:true)
        XCTAssertEqual(reading.neutral.x,neutral.x,accuracy:0.01);XCTAssertEqual(reading.neutral.z,neutral.z,accuracy:0.01)
        let engine=PanoramaEngine(),image=try LCCCameraPipeline.develop(raw,gain:map,whiteBalance:(reading.temperature,reading.tint),size:source.size,scale:1)
        let raster=PanoramaRaster(image:image,context:engine.context,width:80,height:60)
        let center=try XCTUnwrap(raster.rgb(40,30))
        for y in [8.0,30,52] {for x in [8.0,40,72] {
            let c=try XCTUnwrap(raster.rgb(x,y))
            XCTAssertEqual(c.y/center.y,1,accuracy:0.06)
            XCTAssertEqual(c.x/c.y,1,accuracy:0.04);XCTAssertEqual(c.z/c.y,1,accuracy:0.04)
        }}
        var dim=raw;dim.samples=raw.samples.map {$0*0.25}
        let dimImage=try LCCCameraPipeline.develop(dim,gain:map,whiteBalance:(reading.temperature,reading.tint),size:source.size,scale:1)
        let dimRaster=PanoramaRaster(image:dimImage,context:engine.context,width:80,height:60)
        XCTAssertEqual(try XCTUnwrap(dimRaster.rgb(40,30)).y/center.y,0.25,accuracy:0.005)
        let warm=try LCCCameraPipeline.develop(raw,gain:map,whiteBalance:(reading.temperature*1.3,reading.tint),size:source.size,scale:1)
        let warmColor=try XCTUnwrap(PanoramaRaster(image:warm,context:engine.context,width:80,height:60).rgb(40,30))
        XCTAssertGreaterThan(warmColor.x/warmColor.z,center.x/center.z+0.1)
        let roundtrip=try CameraMosaic(url:url,visibleWidth:320,visibleHeight:240)
        XCTAssertEqual(roundtrip.pattern,raw.pattern)
        XCTAssertEqual(roundtrip.samples[20_000],raw.samples[20_000],accuracy:0.00003)
        // Calibration illumination must cancel separately in each camera channel.
        var altered=profile(),v=altered.captures[0].grid.floats
        for i in v.indices {v[i] *= [Float(1.7),0.8,0.6,0.8][i%4]}
        altered.captures[0].grid.values=LCCMeasurementGrid.pack(v)
        let other=try LCCCorrectionField(profile:altered,orientation:.landscape)
        for p in [CGPoint.zero,CGPoint(x:10,y:8)] {
            let a=try XCTUnwrap(field.cameraGain(at:p)),b=try XCTUnwrap(other.cameraGain(at:p))
            for c in 0..<4 {XCTAssertEqual(a[c],b[c],accuracy:0.00001)}
        }
    }
    func testNewSingleFrameProfileKeepsCameraMeasurements() throws {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).dng")
        defer {try? FileManager.default.removeItem(at:url)}
        try fixture().dng().data.write(to:url)
        var frame=try LCCCreationFrame(url:url);frame.shiftConfirmed=true
        let p=try LCCProfileBuilder.create(name:"Test",aperture:11,notes:"",frames:[frame],sensorLongEdge:36,sensorShortEdge:24)
        XCTAssertEqual(p.captures.count,1);XCTAssertEqual(p.captures[0].grid.space,"camera-cfa-normalized-v2")
        XCTAssertEqual(p.captures[0].grid.channels,["R","G1","B","G2"])
        XCTAssertTrue(p.captures[0].grid.floats.allSatisfy {$0>0})
        XCTAssertEqual(try LCCProfileCodec.decode(LCCProfileCodec.encode(p)),p)
    }
    func testSensorClippingRecoveryDoesNotTintUnclippedPixels() {
        let original=SIMD4<Float>(0.7,0.5,0.3,0.5),corrected=original*2
        XCTAssertEqual(LCCCameraPipeline.recoverClipped(original:original,corrected:corrected,neutral:neutral),corrected)
        let clipped=SIMD4<Float>(0.6,1,0.975,1)
        let recovered=LCCCameraPipeline.recoverClipped(original:clipped,corrected:clipped,neutral:neutral)
        XCTAssertEqual(recovered.y,1.5,accuracy:0.0001);XCTAssertEqual(recovered.w,1.5,accuracy:0.0001)
        XCTAssertEqual(recovered.x,clipped.x)
    }
    func testProxyRetainsSensorClippingHiddenByAveraging() throws {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).dng")
        defer {try? FileManager.default.removeItem(at:url)}
        var data=fixture().dng().data
        let source=try SourceDNG(data:data),offset=Int(try XCTUnwrap(source.raw[273]?.firstUInt32))
        data[offset+2]=255;data[offset+3]=255
        try data.write(to:url)
        let full=try CameraMosaic(url:url,visibleWidth:320,visibleHeight:240)
        let proxy=try CameraMosaic(url:url,visibleWidth:320,visibleHeight:240,maxDimension:80)
        XCTAssertEqual(full.samples[1],1)
        XCTAssertLessThan(proxy.samples[1],0.97)
        XCTAssertGreaterThan(try XCTUnwrap(proxy.clipping?[1]),0)
        let clipped=SIMD4<Float>(repeating:1)
        let repaired=LCCCameraPipeline.recoverClipped(original:clipped,corrected:clipped,neutral:neutral)
        XCTAssertEqual(Double(repaired.x/repaired.y),neutral.x,accuracy:0.0001)
        XCTAssertEqual(Double(repaired.z/repaired.y),neutral.z,accuracy:0.0001)
    }
    func testOrientationMappingAndGainCoverage() {
        XCTAssertEqual(LCCCameraGainMap.orient(0.2,0.7,orientation:8).x,0.7)
        XCTAssertEqual(LCCCameraGainMap.orient(0.2,0.7,orientation:8).y,0.8)
        XCTAssertEqual(LCCCameraGainMap.orient(0.2,0.7,orientation:6).x,0.3,accuracy:1e-12)
    }
}
