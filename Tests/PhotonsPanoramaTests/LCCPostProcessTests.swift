import XCTest
import CoreImage
@testable import PhotonsPanorama

final class LCCPostProcessTests:XCTestCase {
    func testRecordedPhotometryRetainsSpatialAxesAndChannels() throws {
        let plane=PanoramaPhotometry.Plane(constant:SIMD3(0.05,-0.07,0.11),x:SIMD3(0.2,0.1,-0.3),y:SIMD3(-0.3,0.2,0.1))
        let image=PanoramaPhotometry.image(plane,size:CGSize(width:1800,height:1200))
        let field=PanoramaManifest.PhotometricField(image:image,context:PanoramaEngine().context)
        let restored=try JSONDecoder().decode(PanoramaManifest.PhotometricField.self,from:JSONEncoder().encode(field))
        XCTAssertTrue(restored.isValid)
        for v in [0.1,0.4,0.85] {for u in [0.15,0.5,0.8] {
            let gain=restored.gain(at:CGPoint(x:u,y:v)),expected=plane.gain(u-0.5,v-0.5)
            for c in 0..<3 {XCTAssertEqual(gain[c],expected[c],accuracy:0.001)}
        }}
    }
    func testBostonGUIHEICWithUpperTravelReference() throws {
        guard let path=ProcessInfo.processInfo.environment["PHOTONS_LCC_GUI_HEIC"] else {throw XCTSkip("External HDR panorama fixture")}
        let url=URL(fileURLWithPath:path),source=try PanoramaSource(url:url)
        let manifest=try XCTUnwrap(PanoramaManifest.read(from:url))
        let profile=try LCCProfileCodec.decode(Data(contentsOf:URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/PhotonsPanorama/Profiles/43xl-iiic-cfv100c.photonslcc")))
        let engine=PanoramaEngine(),decoded=try engine.singlePhoto(source)
        let raster=PanoramaRaster(image:decoded.previewImages[0],context:engine.context,width:512,height:369)
        XCTAssertGreaterThan(raster.rgba.max() ?? 0,2,"Post LCC must decode the HDR gain map, not only its SDR base")
        let top=try XCTUnwrap(manifest.frames.indices.max {manifest.relativePosition(of:$0)!.y<manifest.relativePosition(of:$1)!.y})
        let center=try XCTUnwrap(manifest.relativePosition(of:top))
        // User-provided vertical anchor: the upper row was against the Alpa +25 mm stop.
        // X is left unchanged here; this fixture does not establish a measured horizontal origin.
        let offset=try XCTUnwrap(manifest.offset(reference:top,position:CGPoint(x:center.x,y:25)))
        let pictureCenter=try XCTUnwrap(manifest.pictureCenter(offset:offset))
        let roundtrip=try XCTUnwrap(manifest.offset(pictureCenter:pictureCenter))
        XCTAssertEqual(roundtrip.x,offset.x,accuracy:1e-10);XCTAssertEqual(roundtrip.y,offset.y,accuracy:1e-10)
        let corrected=try LCCCorrectionEngine.postProcess(scene:source,manifest:manifest,profile:profile,offset:offset)
        XCTAssertEqual(try XCTUnwrap(corrected.manifest.position(of:top,offset:offset)).y,25,accuracy:1e-10)
        XCTAssertNotNil(corrected.plan.preview)
        print("GUI HEIC POST LCC", "offset",offset,"picture center",pictureCenter,"HDR peak",raster.rgba.max() ?? 0)
        if let output=ProcessInfo.processInfo.environment["PHOTONS_LCC_DIAGNOSTICS"] {
            let dir=URL(fileURLWithPath:output);try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
            for (name,plan) in [("before",decoded),("corrected-top-reference",corrected.plan)] {
                // Fixed -2 EV for both inspection copies; these PNGs are not HDR exports.
                let image=CIImage(cgImage:try XCTUnwrap(plan.preview)).applyingFilter("CIExposureAdjust",parameters:["inputEV":-2])
                try engine.context.writePNGRepresentation(of:image,to:dir.appendingPathComponent(name+".png"),format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!)
            }
        }
    }
    func testBostonStandalonePanoramasResolveWithoutManualPosition() throws {
        guard let path=ProcessInfo.processInfo.environment["PHOTONS_LCC_POST_DIR"] else {throw XCTSkip("External panorama fixture")}
        let profileURL=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("Sources/PhotonsPanorama/Profiles/43xl-iiic-cfv100c.photonslcc")
        let profile=try LCCProfileCodec.decode(Data(contentsOf:profileURL))
        for name in ["B0000641_pano.dng","B0000644_pano.dng"] {
            let url=URL(fileURLWithPath:path).appendingPathComponent(name)
            let source=try PanoramaSource(url:url),manifest=try XCTUnwrap(PanoramaManifest.read(from:url))
            XCTAssertNil(manifest.profileOffsetMM)
            XCTAssertFalse(manifest.correctionApplied)
            let solved=try LCCCorrectionEngine.resolvePostProcessPosition(scene:source,manifest:manifest,profile:profile)
            print("BOSTON POST POSITION",name,solved.offsetMM)
            let result=try LCCCorrectionEngine.postProcess(scene:source,manifest:manifest,profile:profile,offset:solved.offsetMM)
            XCTAssertTrue(result.manifest.correctionApplied)
            XCTAssertNotNil(result.plan.preview)
            XCTAssertEqual(result.manifest.frames.count,3)
            XCTAssertTrue(solved.offsetMM.x.isFinite && solved.offsetMM.y.isFinite)
            print("BOSTON POST LCC",name,solved.offsetMM)
        }
    }
    func testAutomaticPostPositionUsesRenderedProfileWithoutOriginalFiles() throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:folder)}
        let context=CIContext(options:[.workingColorSpace:PanoramaEngine.linearSpace])
        let xs=stride(from:-18.0,through:18.0,by:3).map {$0},ys=stride(from:12.0,through:-12.0,by:-3).map {$0}
        var captures:[LCCProfileCapture]=[]
        for cy in [-12.0,0,12] {for cx in [-18.0,0,18] {
            var measured:[Float]=[]
            for y in ys {for x in xs {
                let px=x+cx,py=y+cy
                measured += [Float(exp(-0.0009*px*px-0.0002*py*py)),1,Float(exp(-0.0003*px*px-0.0011*py*py))]
            }}
            let grid=LCCMeasurementGrid(x:xs,y:ys,channels:["R","G","B"],values:LCCMeasurementGrid.pack(measured),space:"apple-linear-srgb-6500K-v1")
            var capture=LCCProfileCapture(id:UUID(),filename:"missing-flat.tiff",orientation:.landscape,shiftX:cx,shiftY:cy,sensorWidth:36,sensorHeight:24,pixelWidth:320,pixelHeight:160,iso:64,exposureSeconds:1,capturedAt:nil,grid:grid,thumbnail:nil)
            capture.renderGrid=grid;captures.append(capture)
        }}
        var profile=LCCLensProfile(id:UUID(),name:"Offline",camera:"",aperture:11,notes:"",createdAt:Date(),captures:captures)
        let field=try LCCCorrectionField(profile:profile,orientation:.landscape),expected=CGPoint(x:3,y:-2)
        let w=320,h=160
        var rgba=[Float](repeating:1,count:w*h*4)
        for y in 0..<h {for x in 0..<w {
            let p=CGPoint(x:((Double(x)+0.5)/Double(w)-0.5)*36-expected.x,y:(0.5-(Double(y)+0.5)/Double(h))*24-expected.y)
            let gain=try XCTUnwrap(field.gain(at:p)),i=(y*w+x)*4
            rgba[i]=Float(0.3/gain.x);rgba[i+1]=Float(0.3/gain.y);rgba[i+2]=Float(0.3/gain.z)
        }}
        let image=CIImage(bitmapData:rgba.withUnsafeBytes {Data($0)},bytesPerRow:w*16,size:CGSize(width:w,height:h),format:.RGBAf,colorSpace:PanoramaEngine.linearSpace)
        let url=folder.appendingPathComponent("standalone-pano.tiff")
        try context.writeTIFFRepresentation(of:image,to:url,format:.RGBA16,colorSpace:PanoramaEngine.linearSpace)
        let source=try PanoramaSource(url:url);profile.camera=source.camera
        var manifest=PanoramaManifest(plan:try PanoramaEngine().singlePhoto(source),sensor:.init(width:36,height:24,source:"fixture"))
        manifest.frames[0].filename="unavailable-original.3FR"
        let solution=try LCCCorrectionEngine.resolvePostProcessPosition(scene:source,manifest:manifest,profile:profile)
        XCTAssertEqual(solution.offsetMM.x,expected.x,accuracy:0.4)
        XCTAssertEqual(solution.offsetMM.y,expected.y,accuracy:0.4)
        let corrected=try LCCCorrectionEngine.postProcess(scene:source,manifest:manifest,profile:profile)
        XCTAssertNotNil(corrected.manifest.profileOffsetMM)
        XCTAssertTrue(corrected.manifest.correctionApplied)
        // A recorded frame position resolves the optical origin directly, without a scene fit.
        manifest.frames[0].shiftMM=CGPoint(x:-expected.x,y:-expected.y)
        let recorded=try LCCCorrectionEngine.resolvePostProcessPosition(scene:source,manifest:manifest,profile:profile)
        XCTAssertEqual(recorded.offsetMM,expected)
        XCTAssertEqual(manifest.position(of:0,offset:expected),manifest.frames[0].shiftMM)
        manifest.crop=CGRect(x:0.2,y:0.1,width:0.6,height:0.8)
        manifest.outputTransform=[0,1,0,-1,0,1,0,0,1]
        let point=manifest.canvasPoint(u:0.3,v:0.6),output=try XCTUnwrap(manifest.outputPoint(canvas:point))
        XCTAssertEqual(output.x,0.3,accuracy:1e-10);XCTAssertEqual(output.y,0.6,accuracy:1e-10)
        let pictureCenter=try XCTUnwrap(manifest.pictureCenter(offset:expected))
        let opticalOrigin=try XCTUnwrap(manifest.offset(pictureCenter:pictureCenter))
        XCTAssertEqual(opticalOrigin.x,expected.x,accuracy:1e-10);XCTAssertEqual(opticalOrigin.y,expected.y,accuracy:1e-10)
        // An asymmetric crop shifts the visible center away from the original canvas center.
        manifest.crop=CGRect(x:0.1,y:0.3,width:0.6,height:0.6);manifest.outputTransform=nil
        XCTAssertEqual(try XCTUnwrap(manifest.pictureCenter()).x,-3.6,accuracy:1e-10)
        XCTAssertEqual(try XCTUnwrap(manifest.pictureCenter()).y,-2.4,accuracy:1e-10)
    }
    func testPostCorrectionIsIndependentOfExportResolutionAndRejectsDoubleCorrection() throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:folder)}
        let context=CIContext(options:[.workingColorSpace:PanoramaEngine.linearSpace])
        func source(_ width:Int)throws->PanoramaSource {
            let url=folder.appendingPathComponent("pano-\(width).tiff")
            let image=CIImage(color:CIColor(red:0.2,green:0.2,blue:0.2)).cropped(to:CGRect(x:0,y:0,width:width,height:width/2))
            try context.writeTIFFRepresentation(of:image,to:url,format:.RGBA16,colorSpace:PanoramaEngine.linearSpace)
            return try PanoramaSource(url:url)
        }
        let original=try source(640),small=try source(320)
        let plan=try PanoramaEngine().singlePhoto(original)
        let manifest=PanoramaManifest(plan:plan,profileName:"Test",offsetMM:.zero,sensor:.init(width:36,height:24,source:"test"))
        let xs=[-18.0,-9,0,9,18],ys=[12.0,6,0,-6,-12]
        var values:[Float]=[]
        for _ in ys {for x in xs {values += [Float(0.5*(1-0.35*abs(x)/18)),0.5,0.5]}}
        let grid=LCCMeasurementGrid(x:xs,y:ys,channels:["R","G","B"],values:LCCMeasurementGrid.pack(values),space:"apple-linear-srgb-6500K-v1")
        var capture=LCCProfileCapture(id:UUID(),filename:"flat.tiff",orientation:.landscape,shiftX:0,shiftY:0,sensorWidth:36,sensorHeight:24,pixelWidth:640,pixelHeight:320,iso:64,exposureSeconds:1/6,capturedAt:nil,grid:grid,thumbnail:nil)
        capture.renderGrid=grid
        let profile=LCCLensProfile(id:UUID(),name:"Test",camera:original.camera,aperture:11,notes:"",createdAt:Date(),captures:[capture])
        let largeResult=try LCCCorrectionEngine.postProcess(scene:original,manifest:manifest,profile:profile)
        let smallResult=try LCCCorrectionEngine.postProcess(scene:small,manifest:manifest,profile:profile)
        let large=PanoramaRaster(image:try XCTUnwrap(largeResult.plan.lccState?.gainImages.first),context:context,width:64,height:32)
        let reduced=PanoramaRaster(image:try XCTUnwrap(smallResult.plan.lccState?.gainImages.first),context:context,width:64,height:32)
        for i in large.rgba.indices {XCTAssertEqual(large.rgba[i],reduced.rgba[i],accuracy:0.0001)}
        XCTAssertGreaterThan(try XCTUnwrap(large.rgb(3,16)).x,try XCTUnwrap(large.rgb(32,16)).x)
        XCTAssertThrowsError(try LCCCorrectionEngine.postProcess(scene:small,manifest:largeResult.manifest,profile:profile))
    }
    func testMixedOrientationBlendInvertsResponseAndRecordedPhotometry() throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:folder)}
        let engine=PanoramaEngine(),w=256,h=128,url=folder.appendingPathComponent("mixed.tiff")
        let bounds=CGRect(x:0,y:0,width:w,height:h)
        try engine.context.writeTIFFRepresentation(of:CIImage(color:CIColor(red:0.2,green:0.2,blue:0.2)).cropped(to:bounds),to:url,format:.RGBA16,colorSpace:PanoramaEngine.linearSpace)
        let initial=try PanoramaSource(url:url)
        let xs=stride(from:-18.0,through:18.0,by:3).map {$0},ys=stride(from:12.0,through:-12.0,by:-3).map {$0}
        var captures:[LCCProfileCapture]=[]
        for orientation in [LCCCaptureOrientation.landscape,.inverted] {
            let slope=orientation == .landscape ? 0.03:0.07
            var values:[Float]=[]
            for y in ys {for x in xs {values += [Float(exp(slope*x)),Float(exp(0.01*y)),Float(exp(-slope*x))]}}
            let grid=LCCMeasurementGrid(x:xs,y:ys,channels:["R","G","B"],values:LCCMeasurementGrid.pack(values),space:"apple-linear-srgb-6500K-v1")
            var capture=LCCProfileCapture(id:UUID(),filename:"flat",orientation:orientation,shiftX:0,shiftY:0,sensorWidth:36,sensorHeight:24,pixelWidth:w,pixelHeight:h,iso:100,exposureSeconds:1,capturedAt:nil,grid:grid,thumbnail:nil)
            capture.renderGrid=grid;captures.append(capture)
        }
        let profile=LCCLensProfile(id:UUID(),name:"Mixed",camera:initial.camera,aperture:11,notes:"",createdAt:Date(),captures:captures)
        let fields=try LCCCorrectionEngine.fields(profile)
        let p0=SIMD3<Double>(1.2,0.9,1.1),p1=SIMD3<Double>(0.8,1.3,0.95),weight0=64.0/255,weight1=191.0/255
        func compensation(_ p:SIMD3<Double>)->CIImage {
            CIImage(color:CIColor(red:p.x,green:p.y,blue:p.z,colorSpace:PanoramaEngine.linearSpace)!).cropped(to:bounds)
        }
        var plan=try engine.singlePhoto(initial)
        plan.photometricGains=[compensation(p0)]
        var manifest=PanoramaManifest(plan:plan,sensor:SensorSize(width:36,height:24,source:"test"))
        XCTAssertEqual(manifest.photometricFields?.count,1,"New exports retain their baked-in compensation")
        manifest.frames.append(manifest.frames[0]);manifest.frames[1].orientation=3
        manifest.exposureGains=[1,2]
        manifest.weights=[Data([64]),Data([191])]
        manifest.photometricFields?.append(.init(image:compensation(p1),context:engine.context))
        let decoded=try JSONDecoder().decode(PanoramaManifest.self,from:manifest.encoded())
        try decoded.validate()
        let calibration0=try XCTUnwrap(fields[.landscape]),calibration1=try XCTUnwrap(fields[.inverted])
        var pixels=[Float](repeating:1,count:w*h*4)
        for y in 0..<h {for x in 0..<w {
            let point=CGPoint(x:((Double(x)+0.5)/Double(w)-0.5)*36,y:(0.5-(Double(y)+0.5)/Double(h))*24)
            let g0=try XCTUnwrap(calibration0.gain(at:point)),g1=try XCTUnwrap(calibration1.gain(at:point))
            // Independent forward model: blend two shaded observations of a uniform scene.
            let observed=0.1*(weight0*p0/g0+weight1*2*p1/g1),i=(y*w+x)*4
            for c in 0..<3 {pixels[i+c]=Float(observed[c])}
        }}
        let image=CIImage(bitmapData:pixels.withUnsafeBytes {Data($0)},bytesPerRow:w*16,size:bounds.size,format:.RGBAf,colorSpace:PanoramaEngine.linearSpace)
        let observedURL=folder.appendingPathComponent("observed.tiff")
        try engine.context.writeTIFFRepresentation(of:image,to:observedURL,format:.RGBA16,colorSpace:PanoramaEngine.linearSpace)
        let source=try PanoramaSource(url:observedURL)
        let corrected=try LCCCorrectionEngine.postProcess(scene:source,manifest:decoded,profile:profile,offset:.zero)
        let actual=PanoramaRaster(image:corrected.plan.previewImages[0],context:engine.context,width:w,height:h)
        let expected=0.1*(weight0+weight1*2)
        for y in [12.0,64,115] {for x in [12.0,64,192,243] {
            let rgb=try XCTUnwrap(actual.rgb(x,y))
            for c in 0..<3 {XCTAssertEqual(rgb[c],expected,accuracy:0.004)}
        }}
        // Older manifests remain readable, while malformed optional fields are rejected.
        var legacy=decoded;legacy.photometricFields=nil
        XCTAssertNoThrow(try legacy.validate())
        var invalid=decoded;invalid.exposureGains=[1]
        XCTAssertThrowsError(try invalid.validate())
        invalid=decoded;invalid.photometricFields?[0].values=[1]
        XCTAssertThrowsError(try invalid.validate())
    }
}
