import XCTest
import CoreImage
@testable import PhotonsPanorama

final class LCCProfileTests:XCTestCase {
    func sample()->LCCLensProfile {
        let grid=LCCMeasurementGrid(x:[-10,10],y:[8,-8],channels:["R","G","B"],values:LCCMeasurementGrid.pack([Float](repeating:0.1,count:12)),standardError:nil,space:"apple-linear-srgb-6500K-v1")
        let c=LCCProfileCapture(id:UUID(),filename:"white.tif",orientation:.landscape,shiftX:0,shiftY:0,sensorWidth:36,sensorHeight:24,pixelWidth:80,pixelHeight:60,iso:64,exposureSeconds:1/6,capturedAt:nil,grid:grid,thumbnail:nil)
        return LCCLensProfile(id:UUID(),name:"Test lens",camera:"Test back",aperture:11,notes:"",createdAt:Date(timeIntervalSince1970:1700000000),captures:[c])
    }
    func testLosslessContainerAndCorruption() throws {
        let p=sample(),data=try LCCProfileCodec.encode(p)
        XCTAssertEqual(try LCCProfileCodec.decode(data),p)
        var broken=data;broken[20] ^= 0xFF
        XCTAssertThrowsError(try LCCProfileCodec.decode(broken))
        XCTAssertThrowsError(try LCCProfileCodec.decode(data.prefix(50)))
    }
    func testPartialSingleOrientationStoreWithoutOriginalImages() throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:dir)}
        let store=LCCProfileStore(directory:dir),p=sample()
        let url=try store.save(p)
        XCTAssertTrue(FileManager.default.fileExists(atPath:url.path));XCTAssertEqual(try store.load(p.id),p)
        let summary=try XCTUnwrap(store.catalog().profiles.first)
        XCTAssertEqual(summary.captureCount,1)
        XCTAssertNotNil(summary.match(camera:"Test back/Electronic Shutter",exifOrientation:1,sensor:.init(width:36,height:24,source:"test")))
        XCTAssertNil(summary.match(camera:"Test back",exifOrientation:8,sensor:.init(width:24,height:36,source:"test")))
        XCTAssertNil(summary.match(camera:"Other back",exifOrientation:1,sensor:.init(width:36,height:24,source:"test")))
        XCTAssertNil(summary.match(camera:"Test back",exifOrientation:1,sensor:.init(width:54,height:40,source:"test")))
    }
    func testBuiltInOrientationAndDimCorners() throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:dir)}
        let store=LCCProfileStore(directory:dir);try store.installBundledProfile()
        let p=try store.load(LCCLensProfile.builtInID)
        XCTAssertEqual(p.captures(for:.landscape).count,36);XCTAssertEqual(p.captures(for:.portraitLeft).count,9)
        let summary=LCCProfileSummary(p)
        XCTAssertEqual(summary.match(camera:"CFV 100C",exifOrientation:8,sensor:.init(width:32.9,height:43.8,source:""))?.orientation,.portraitLeft)
        XCTAssertNil(summary.match(camera:"CFV 100C",exifOrientation:6,sensor:.init(width:32.9,height:43.8,source:"")))
        let corner=try XCTUnwrap(p.captures.first {$0.orientation == .portraitLeft && $0.shiftX==18 && $0.shiftY==25})
        XCTAssertGreaterThan(corner.grid.floats.min()!,0)
        XCTAssertLessThan(corner.grid.floats.min()!,300)
        XCTAssertEqual(corner.grid.width,137);XCTAssertEqual(corner.grid.height,183)
    }
    func testInstallingSampleAgainPreservesUserChanges() throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:dir)}
        let store=LCCProfileStore(directory:dir);try store.installBundledProfile()
        var profile=try store.load(LCCLensProfile.builtInID)
        profile.name="我的测量";profile.notes="用户修改必须保留"
        let url=try store.save(profile)
        let before=try Data(contentsOf:url)
        try store.installBundledProfile()
        XCTAssertEqual(try Data(contentsOf:url),before)
        XCTAssertEqual(try store.load(profile.id).name,"我的测量")
    }
    func testShiftNameParsingDoesNotGuessUnknownNames() {
        XCTAssertEqual(LCCShiftFilename.parse("V18D_H5L.3FR")?.x,-5)
        XCTAssertEqual(LCCShiftFilename.parse("V18D_H5L.3FR")?.y,-18)
        XCTAssertEqual(LCCShiftFilename.parse("V0_H0.3FR")?.x,0)
        XCTAssertNil(LCCShiftFilename.parse("B0000663.3FR"));XCTAssertNil(LCCShiftFilename.parse("V15_H5.3FR"))
    }
    func testCreateBuiltinRenderCalibrationIfRequested() throws {
        guard let root=ProcessInfo.processInfo.environment["PHOTONS_LCC_CALIBRATION_ROOT"],
              let output=ProcessInfo.processInfo.environment["PHOTONS_LCC_CALIBRATION_OUTPUT"] else {throw XCTSkip("Opt-in measured profile generation")}
        let bytes=try Data(contentsOf:URL(fileURLWithPath:output));var profile=try LCCProfileCodec.decode(bytes)
        if ProcessInfo.processInfo.environment["PHOTONS_LCC_REPACK"]=="1" {
            let packed=try LCCProfileCodec.encode(profile);XCTAssertEqual(try LCCProfileCodec.decode(packed),profile)
            try packed.write(to:URL(fileURLWithPath:output),options:.atomic);print("Lossless repack",packed.count,"bytes");return
        }
        var frames:[LCCCreationFrame]=[]
        for c in profile.captures {
            var f=try LCCCreationFrame(url:URL(fileURLWithPath:root).appendingPathComponent(c.orientation == .landscape ? "Landscape":"Portrait").appendingPathComponent(c.filename))
            f.shiftX=c.shiftX;f.shiftY=c.shiftY;f.shiftConfirmed=true;frames.append(f)
        }
        let rendered=try LCCProfileBuilder.create(name:profile.name,aperture:11,notes:"",frames:frames,sensorLongEdge:43.8,sensorShortEdge:32.9) {print($0)}
        for i in profile.captures.indices {profile.captures[i].grid=rendered.captures[i].grid;profile.captures[i].renderGrid=nil}
        let packed=try LCCProfileCodec.encode(profile);try packed.write(to:URL(fileURLWithPath:output),options:.atomic)
        XCTAssertEqual(try LCCProfileCodec.decode(packed),profile);print("Complete built-in profile",packed.count,"bytes")
    }
}

final class LCCCorrectionTests:XCTestCase {
    func testCoverageUnionHolesAndConservativeCrop() throws {
        let region=LCCCoverageRegion([CGRect(x:0,y:0,width:10,height:10),CGRect(x:20,y:0,width:10,height:10)])
        XCTAssertTrue(region.covers(CGRect(x:1,y:1,width:8,height:8)))
        XCTAssertFalse(region.covers(CGRect(x:0,y:0,width:30,height:10)))
        XCTAssertFalse(region.contains(CGPoint(x:15,y:5)))
        let adjacent=LCCCoverageRegion([CGRect(x:0,y:0,width:10,height:10),CGRect(x:10,y:0,width:10,height:10)])
        XCTAssertTrue(adjacent.covers(CGRect(x:0,y:0,width:20,height:10)))
        XCTAssertEqual(LCCCoverageRegion.largestRectangle([true,true,false,true,true,true,false,true,true,true,false,true],width:4,height:3),CGRect(x:0,y:0,width:2,height:3))
        XCTAssertNil(LCCCoverageRegion.largestRectangle([false],width:1,height:1))
    }
    func testDimSignalRetainedAndAbsentOrientationRejected() throws {
        var p=LCCProfileTests().sample()
        p.captures[0].grid.values=LCCMeasurementGrid.pack([0.3,0.3,0.3,0.3,0.3,0.3,0.001,0.001,0.001,0.001,0.001,0.001])
        let f=try LCCCorrectionField(profile:p,orientation:.landscape)
        XCTAssertGreaterThan(try XCTUnwrap(f.gain(at:CGPoint(x:0,y:-11))).y,100)
        XCTAssertNil(f.gain(at:CGPoint(x:19,y:0)))
        XCTAssertThrowsError(try LCCCorrectionField(profile:p,orientation:.portraitLeft))
    }
    func testPreviewExportCorrectionDirectionCropAndDisable() throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true);defer {try? FileManager.default.removeItem(at:dir)}
        let engine=PanoramaEngine(),bounds=CGRect(x:0,y:0,width:80,height:60),url=dir.appendingPathComponent("scene.png")
        let input=CIImage(color:CIColor(red:0.1,green:0.1,blue:0.1,alpha:1,colorSpace:PanoramaEngine.linearSpace)!).cropped(to:bounds)
        try engine.context.writePNGRepresentation(of:input,to:url,format:.RGBA16,colorSpace:PanoramaEngine.linearSpace)
        let source=try PanoramaSource(url:url)
        var p=LCCProfileTests().sample();p.camera=source.camera
        p.captures[0].grid.values=LCCMeasurementGrid.pack([0.3,0.3,0.3,0.3,0.3,0.3,0.1,0.1,0.1,0.1,0.1,0.1])
        var options=PanoramaOptions();options.matchExposure=false;options.avoidMotion=false
        var plan=PanoramaPlan(sources:[source],origins:[.zero],size:bounds.size,registrationScores:[1],whiteBalance:nil,gains:[1],ownership:[],maskWidth:0,maskHeight:0,optical:.init(center:nil,confidence:0,explanation:"",occludedEdges:[]),options:options,previewScale:0.5,previewImages:[input.transformed(by:.init(scaleX:0.5,y:0.5))],preview:nil)
        plan=try engine.update(plan,options:options);plan=try engine.prepareLCCImages(plan)
        let field=try LCCCorrectionField(profile:p,orientation:.landscape),sensor=SensorSize(width:36,height:24,source:"test")
        let corrected=try engine.applyingLCC(plan,profile:p,fields:[.landscape:field],offsetMM:.zero,sensor:sensor,crop:false)
        XCTAssertTrue(try XCTUnwrap(corrected.lccState).complete)
        let raster=PanoramaRaster(image:corrected.previewImages[0],context:engine.context,width:80,height:60)
        XCTAssertGreaterThan(try XCTUnwrap(raster.rgb(40,54)).y,try XCTUnwrap(raster.rgb(40,6)).y*2)
        let moved=try engine.applyingLCC(plan,profile:p,fields:[.landscape:field],offsetMM:CGPoint(x:8,y:0),sensor:sensor,crop:true)
        XCTAssertFalse(try XCTUnwrap(moved.lccState).complete);XCTAssertLessThan(moved.outputSize.width,80)
        let out=dir.appendingPathComponent("corrected.tiff");try engine.export(moved,to:out,format:.tiff)
        let decoded=try XCTUnwrap(CIImage(contentsOf:out));XCTAssertEqual(decoded.extent.size,moved.outputSize)
        let preview=try XCTUnwrap(moved.preview)
        let rendered=PanoramaRaster(image:CIImage(cgImage:preview),context:engine.context,width:40,height:40)
        let exported=PanoramaRaster(image:decoded,context:engine.context,width:40,height:40)
        for y in [5.0,20,35] {XCTAssertEqual(try XCTUnwrap(rendered.rgb(20,y)).y,try XCTUnwrap(exported.rgb(20,y)).y,accuracy:0.01)}
        let removed=try engine.removingLCC(moved);XCTAssertNil(removed.lccState);XCTAssertEqual(removed.outputSize,bounds.size)
    }
}

final class LCCQualityTests:XCTestCase {
    func testOverlappingCalibrationEdgesStayContinuousAndFalloffIsIndependent() throws {
        var p=LCCProfileTests().sample()
        var b=p.captures[0];b.id=UUID();b.shiftX=12;b.grid.values=LCCMeasurementGrid.pack([Float](repeating:0.2,count:12))
        p.captures.append(b)
        let field=try LCCCorrectionField(profile:p,orientation:.landscape)
        // The second capture begins at -6 mm. Equal-weight medians formerly jumped there.
        let left=try XCTUnwrap(field.gain(at:CGPoint(x:-6.05,y:0))),right=try XCTUnwrap(field.gain(at:CGPoint(x:-5.95,y:0)))
        XCTAssertLessThan(abs(log(left.y/right.y)),0.01)
        p.captures[0].grid.values=LCCMeasurementGrid.pack([0.2,0.2,0.2,0.2,0.2,0.2,0.08,0.04,0.02,0.08,0.04,0.02]);p.captures.removeLast()
        let color=try LCCCorrectionField(profile:p,orientation:.landscape)
        let full=try XCTUnwrap(color.gain(at:CGPoint(x:0,y:-10)))
        XCTAssertGreaterThan(full.y,2)
        XCTAssertGreaterThan(full.z,full.y)
        XCTAssertLessThan(full.x,full.y)

    }
    func testHighlightShoulderIsContinuousAndPreservesColorRatios() throws {
        let engine=PanoramaEngine()
        for peak in [0.2,0.899,0.901,1.2,4.0,20.0] {
            let image=CIImage(color:CIColor(red:peak,green:peak*0.5,blue:peak*0.2,alpha:1,colorSpace:PanoramaEngine.linearSpace)!).cropped(to:CGRect(x:0,y:0,width:4,height:4))
            let r=PanoramaRaster(image:PanoramaEngine.protectedDisplay(image),context:engine.context,width:4,height:4)
            let c=try XCTUnwrap(r.rgb(2,2))
            XCTAssertLessThan(c.x,1);XCTAssertEqual(c.y/c.x,0.5,accuracy:0.001);XCTAssertEqual(c.z/c.x,0.2,accuracy:0.001)
            if peak<0.9 {XCTAssertEqual(c.x,peak,accuracy:0.0001)}
        }
    }
    func testRobustOverlapPlaneRemovesGradientWithoutFollowingMovingObjects() {
        var samples:[PanoramaPhotometry.Sample]=[]
        for y in 0..<25 {for x in 0..<30 {
            let u=Double(x)/30-0.5,v=Double(y)/25-0.5,d=0.05+0.25*u-0.15*v
            let motion=(x+3*y)%17==0 ? 1.5:0
            samples.append(.init(a:0,b:1,ax:u,ay:v,bx:u,by:v,difference:SIMD3(repeating:d+motion)))
        }}
        let planes=PanoramaPhotometry.fit(samples,count:2)
        for u in [-0.4,0,0.4] {for v in [-0.4,0,0.4] {
            XCTAssertEqual(log(planes[0].gain(u,v).y/planes[1].gain(u,v).y),0.05+0.25*u-0.15*v,accuracy:0.025)
        }}
    }
    func testPositionSolverRecoversShiftFromWhiteField() throws {
        var p=LCCProfileTests().sample()
        let xs=(0..<40).map {Double($0)-19.5},ys=(0..<36).map {17.5-Double($0)}
        var values:[Float]=[]
        for y in ys {for x in xs {
            let g=exp(-(x*x+y*y)/250),r=g*exp(0.0008*x*x+0.0005*y*y),b=g*exp(-0.0004*y*y)
            values += [Float(r),Float(g),Float(b)]
        }}
        p.captures[0].sensorWidth=40;p.captures[0].sensorHeight=36
        p.captures[0].grid=LCCMeasurementGrid(x:xs,y:ys,channels:["R","G","B"],values:LCCMeasurementGrid.pack(values),standardError:nil,space:"apple-linear-srgb-6500K-v1")
        let field=try LCCCorrectionField(profile:p,orientation:.landscape),truth=CGPoint(x:2.2,y:-3.1)
        var observations:[LCCPositionSolver.Observation]=[]
        for y in stride(from:-10.0,through:10.0,by:2) {for x in stride(from:-12.0,through:12.0,by:2) {
            let point=CGPoint(x:x,y:y),g=try XCTUnwrap(field.gain(at:CGPoint(x:x-truth.x,y:y-truth.y)))
            observations.append(.init(frame:0,point:point,logRGB:SIMD3(-log(g.x),-log(g.y),-log(g.z)),field:LCCOrientedField(field:field,bodyOrientation:.degrees0)))
        }}
        let result=try LCCPositionSolver.search(observations:observations,xRange:-5...5,yRange:-6...4,flat:true,cancellation:.init())
        XCTAssertEqual(result.point.x,truth.x,accuracy:0.2);XCTAssertEqual(result.point.y,truth.y,accuracy:0.2)
    }
    func testAnyFrameReferenceDeterminesProfileOriginAndReplacement() throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true);defer {try? FileManager.default.removeItem(at:dir)}
        let url=dir.appendingPathComponent("a.png"),engine=PanoramaEngine()
        let image=CIImage(color:.white).cropped(to:CGRect(x:0,y:0,width:100,height:80))
        try engine.context.writePNGRepresentation(of:image,to:url,format:.RGBA8,colorSpace:PanoramaEngine.linearSpace)
        let source=try PanoramaSource(url:url)
        let plan=PanoramaPlan(sources:[source,source],origins:[.zero,CGPoint(x:30,y:20)],size:CGSize(width:130,height:100),registrationScores:[1,1],whiteBalance:nil,gains:[1,1],ownership:[],maskWidth:0,maskHeight:0,optical:.init(center:nil,confidence:0,explanation:"",occludedEdges:[]),options:.init(),previewScale:1,previewImages:[image,image],preview:nil)
        let sensor=SensorSize(width:40,height:32,source:"test")
        let a=PanoramaPositionReference(sourceIndex:1,positionMM:CGPoint(x:10,y:-5))
        XCTAssertEqual(a.position(of:0,in:plan,sensor:sensor),CGPoint(x:-2,y:3))
        XCTAssertEqual(a.profileOffset(in:plan,sensor:sensor),CGPoint(x:-4,y:1))
        let b=PanoramaPositionReference(sourceIndex:0,positionMM:CGPoint(x:0,y:0))
        XCTAssertEqual(b.position(of:1,in:plan,sensor:sensor),CGPoint(x:12,y:-8))
        XCTAssertEqual(b.profileOffset(in:plan,sensor:sensor),CGPoint(x:-6,y:4))
    }
}
