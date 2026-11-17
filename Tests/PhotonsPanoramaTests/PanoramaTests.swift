import XCTest
import CoreImage
import ImageIO
@testable import PhotonsPanorama

final class PanoramaTests: XCTestCase {
    func testTranslationRejectsBlankAndRecoversDisplacement() throws {
        let w = 256, h = 220
        var scene = [Double](repeating:0,count:420*350)
        for y in 0..<350 { for x in 0..<420 {
            let hash = (x &* 73856093) ^ (y &* 19349663)
            scene[y*420+x] = Double(hash & 1023)/1023
        }}
        func crop(_ ox:Int,_ oy:Int) -> GrayRaster {
            var pixels = [Double](repeating:0,count:w*h)
            for y in 0..<h { for x in 0..<w {
                var v = 0.0
                for dy in -1...1 { for dx in -1...1 { v += scene[(y+oy+dy)*420+x+ox+dx] } }
                pixels[y*w+x] = v/9
            }}
            return GrayRaster(width:w,height:h,values:pixels)
        }
        let a = crop(30,60), b = crop(104,36)
        let match = try XCTUnwrap(TranslationRegistration.align(a,b,cancellation:.init()))
        XCTAssertEqual(match.offset.x,74,accuracy:0.2); XCTAssertEqual(match.offset.y,-24,accuracy:0.2)
        XCTAssertGreaterThan(match.score,0.95)
        let blank = GrayRaster(width:w,height:h,values:[Double](repeating:0.5,count:w*h))
        XCTAssertNil(try TranslationRegistration.align(blank,blank,cancellation:.init()))
    }
    func testUnknownSensorIsNotAssumedFullFrame() {
        XCTAssertNil(SensorSize.identify(properties:[:]))
        let p: [String:Any] = [kCGImagePropertyTIFFDictionary as String:[kCGImagePropertyTIFFModel as String:"CFV 100C/Electronic Shutter"]]
        XCTAssertEqual(SensorSize.identify(properties:p)?.width,43.8)
        let focal: [String:Any] = [kCGImagePropertyExifDictionary as String:[
            kCGImagePropertyExifFocalPlaneXResolution as String:10000,kCGImagePropertyExifFocalPlaneYResolution as String:10000,
            kCGImagePropertyExifFocalPlaneResolutionUnit as String:3,kCGImagePropertyExifPixelXDimension as String:54000,
            kCGImagePropertyExifPixelYDimension as String:40000]]
        XCTAssertEqual(SensorSize.identify(properties:focal)?.width,54)
    }
    func testPreviewAndFullRenderUseSameTopLeftPlan() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:dir) }
        let engine = PanoramaEngine(), bounds = CGRect(x:0,y:0,width:100,height:80)
        let images = [CIImage(color:CIColor(red:0.5,green:0,blue:0,alpha:1,colorSpace:PanoramaEngine.linearSpace)!).cropped(to:bounds),
                      CIImage(color:CIColor(red:0,green:0.5,blue:0,alpha:1,colorSpace:PanoramaEngine.linearSpace)!).cropped(to:bounds)]
        let sources = try images.enumerated().map { i,image -> PanoramaSource in
            let url = dir.appendingPathComponent("\(i).png")
            try engine.context.writePNGRepresentation(of:image,to:url,format:.RGBA8,colorSpace:PanoramaEngine.linearSpace)
            return try PanoramaSource(url:url)
        }
        var labels = [Int16](repeating:-1,count:14*14)
        for y in 0..<14 { for x in 0..<14 {
            if x<10 && y<8 { labels[y*14+x] = 0 }
            if x>=4 && y>=6 { labels[y*14+x] = 1 }
        }}
        let plan = PanoramaPlan(sources:sources,origins:[.zero,CGPoint(x:40,y:60)],size:CGSize(width:140,height:140),
            registrationScores:[1,1],whiteBalance:nil,gains:[1,1],ownership:labels,maskWidth:14,maskHeight:14,
            optical:OpticalEstimate(center:nil,confidence:0,explanation:"",occludedEdges:[]),options:.init(),previewScale:1,previewImages:images,preview:nil)
        var hdrPlan = plan
        hdrPlan.previewImages = images.map { $0.applyingFilter("CIExposureAdjust", parameters:["inputEV":3]) }
        engine.renderPreview(&hdrPlan)
        let hdrPreview = try XCTUnwrap(hdrPlan.preview)
        XCTAssertEqual(hdrPreview.bitsPerComponent,16)
        XCTAssertTrue(hdrPreview.bitmapInfo.contains(.floatComponents))
        XCTAssertEqual(hdrPreview.colorSpace?.name,CGColorSpace.extendedLinearDisplayP3)
        let hdrPixels = PanoramaRaster(image:CIImage(cgImage:hdrPreview),context:engine.context,width:140,height:140)
        XCTAssertGreaterThan(try XCTUnwrap(hdrPixels.rgb(20,20)).x,3.9)
        XCTAssertGreaterThan(try XCTUnwrap(hdrPixels.rgb(100,120)).y,3.9)
        XCTAssertEqual(hdrPlan.origins,plan.origins)
        for scale in [1.0,0.5] {
            let image = engine.composite(plan,images:images,imageScale:1,outputScale:scale)
            let pixels = PanoramaRaster(image:image,context:engine.context,width:140,height:140)
            XCTAssertGreaterThan(try XCTUnwrap(pixels.rgb(20,20)).x,0.4)
            XCTAssertLessThan(try XCTUnwrap(pixels.rgb(20,20)).y,0.01)
            XCTAssertGreaterThan(try XCTUnwrap(pixels.rgb(100,120)).y,0.4)
            XCTAssertLessThan(try XCTUnwrap(pixels.rgb(120,20)).x,0.01)
        }
        let tiff = dir.appendingPathComponent("result.tiff")
        try engine.export(plan,to:tiff,format:.tiff)
        let tiffSource = try XCTUnwrap(CGImageSourceCreateWithURL(tiff as CFURL,nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(tiffSource,0,nil) as? [String:Any])
        XCTAssertEqual(properties[kCGImagePropertyDepth as String] as? Int,16)
        let tags = properties[kCGImagePropertyTIFFDictionary as String] as? [String:Any]
        XCTAssertEqual(tags?[kCGImagePropertyTIFFCompression as String] as? Int,5)
        try Data([1,2,3]).write(to:sources[0].url)
        XCTAssertThrowsError(try sources[0].checkUnchanged())
    }
    func testConsensusAvoidsTransientObjectAndMasksStayNormalized() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:dir) }
        let engine = PanoramaEngine(), bounds = CGRect(x:0,y:0,width:120,height:100)
        let background = CIImage(color:CIColor(red:0.2,green:0.2,blue:0.2)).cropped(to:bounds)
        let object = CIImage(color:CIColor(red:0.8,green:0.01,blue:0.01)).cropped(to:CGRect(x:40,y:30,width:40,height:40)).composited(over:background)
        let images = [object,background,background]
        let sources = try images.enumerated().map { i,image -> PanoramaSource in
            let url = dir.appendingPathComponent("\(i).png")
            try engine.context.writePNGRepresentation(of:image,to:url,format:.RGBA8,colorSpace:PanoramaEngine.linearSpace)
            return try PanoramaSource(url:url)
        }
        var plan = PanoramaPlan(sources:sources,origins:[.zero,.zero,.zero],size:bounds.size,
            registrationScores:[1,1,1],whiteBalance:nil,gains:[1,1,1],ownership:[],maskWidth:0,maskHeight:0,
            optical:OpticalEstimate(center:nil,confidence:0,explanation:"",occludedEdges:[]),options:.init(),previewScale:1,previewImages:images,preview:nil)
        try PanoramaSeams.prepare(&plan,context:engine.context,cancellation:.init())
        XCTAssertNotEqual(plan.ownership[50*plan.maskWidth+60],0,"Prefer the two clean observations over the transient red object")
        let weights = plan.blendMasks.map { $0.withUnsafeBytes { Array($0.bindMemory(to:Float.self)) } }
        for p in stride(from:0,to:plan.ownership.count,by:11) where plan.ownership[p] >= 0 {
            XCTAssertEqual(weights.reduce(Float(0)) { $0+$1[p] },1,accuracy:0.00001,"Feathering must not darken the seam")
        }
    }
    func testCancelledWorkStopsBeforeReadingInputs() {
        let token = PanoramaCancellation(); token.cancel()
        XCTAssertThrowsError(try PanoramaEngine().analyze(urls:[URL(fileURLWithPath:"/missing/a"),URL(fileURLWithPath:"/missing/b")],cancellation:token)) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertThrowsError(try PanoramaCancellation(isCancelled:{true}).check()) { XCTAssertTrue($0 is CancellationError) }
    }
    func testCompressedLinearDNGRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:dir) }
        let url = dir.appendingPathComponent("linear.dng"), w = 512, h = 512
        var values = [Float](repeating:1,count:w*h*4)
        for y in 0..<h { for x in 0..<w {
            let p = (y*w+x)*4
            values[p] = y < h/2 ? 0.12:0.65; values[p+1] = Float(x)/Float(w)*0.5+0.05; values[p+2] = 0.2
            if x < 3 || y < 3 { values[p] = 0; values[p+1] = 0; values[p+2] = 0 }
        }}
        let data = values.withUnsafeBytes { Data($0) }
        let image = CIImage(bitmapData:data,bytesPerRow:w*16,size:CGSize(width:w,height:h),format:.RGBAf,colorSpace:PanoramaEngine.linearSpace)
        let context = CIContext(options:[.workingColorSpace:PanoramaEngine.linearSpace])
        try LinearDNGWriter.write(image:image,context:context,to:url)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL,nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [String:Any])
        XCTAssertEqual(props[kCGImagePropertyPixelWidth as String] as? Int,w)
        XCTAssertEqual(props[kCGImagePropertyPixelHeight as String] as? Int,h)
        let raw = try XCTUnwrap(CIRAWFilter(imageURL:url)); raw.boostAmount = 0; raw.isGamutMappingEnabled = false
        raw.sharpnessAmount = 0; raw.isLensCorrectionEnabled = false
        let decoded = try XCTUnwrap(raw.outputImage)
        let actual = PanoramaRaster(image:decoded,context:context,width:w,height:h)
        let low = try XCTUnwrap(actual.rgb(100,40)), high = try XCTUnwrap(actual.rgb(100,Double(h-40)))
        XCTAssertEqual(low.x,0.12,accuracy:0.035,"DNG color transform / row orientation")
        XCTAssertEqual(high.x,0.65,accuracy:0.04)
        XCTAssertEqual(low.z,0.2,accuracy:0.035)
        XCTAssertLessThan(try Data(contentsOf:url).count,w*h*6,"Flat gradients should losslessly compress")
    }
    func testPairStoreInvalidatesChangedFilesAndRejectsDuplicates() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:dir) }
        let a = dir.appendingPathComponent("a.3fr"), b = dir.appendingPathComponent("b.3fr"), c = dir.appendingPathComponent("c.3fr")
        for u in [a,b,c] { try Data([1,2,3]).write(to:u) }
        let pair = try LCCPairRecord(scene:a,flat:b,confirmed:true)
        let store = LCCPairingStore(url:dir.appendingPathComponent("pairs.json"))
        try store.save([pair]); XCTAssertEqual(store.records().count,1)
        XCTAssertThrowsError(try store.save([pair,LCCPairRecord(scene:c,flat:b,confirmed:true)]))
        try Data([1,2,3,4]).write(to:b); XCTAssertTrue(store.records().isEmpty)
    }
    func testDNGPreservesHighlightHeadroom() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).dng")
        defer { try? FileManager.default.removeItem(at:url) }
        let values: [Float] = [2.5,0.5,0.2,1]
        let pixel = values.withUnsafeBytes { Data($0) }
        let image = CIImage(bitmapData:pixel,bytesPerRow:16,size:CGSize(width:1,height:1),format:.RGBAf,colorSpace:PanoramaEngine.linearSpace)
            .clampedToExtent().cropped(to:CGRect(x:0,y:0,width:288,height:260))
        let context = CIContext(options:[.workingColorSpace:PanoramaEngine.linearSpace])
        let before = PanoramaRaster(image:image,context:context,width:32,height:32)
        XCTAssertEqual(try XCTUnwrap(before.rgb(16,16)).x,2.5,accuracy:0.01)
        try LinearDNGWriter.write(image:image,context:context,to:url)
        let raw = try XCTUnwrap(CIRAWFilter(imageURL:url)); raw.boostAmount = 0; raw.isGamutMappingEnabled = false
        let raster = PanoramaRaster(image:try XCTUnwrap(raw.outputImage),context:context,width:32,height:32)
        let color = try XCTUnwrap(raster.rgb(16,16))
        XCTAssertEqual(color.x,2.5,accuracy:0.08)
        XCTAssertEqual(color.y,0.5,accuracy:0.03)
    }
    func testDNGNormalizesPartialCoverageWithoutDarkLines() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).dng")
        defer { try? FileManager.default.removeItem(at: url) }
        let w = 513, h = 519
        var pixels = [Float](repeating: 0,count: w*h*4)
        for y in 0..<h { for x in 0..<w {
            let alpha: Float = x < 3 ? 0 : (x % 83 < 2 || y % 89 < 2 ? 0.6 : 1)
            let p = (y*w+x)*4
            pixels[p] = 2.5*alpha; pixels[p+1] = 0.5*alpha; pixels[p+2] = 0.2*alpha; pixels[p+3] = alpha
        }}
        let image = CIImage(bitmapData: pixels.withUnsafeBytes { Data($0) },bytesPerRow: w*16,
            size: CGSize(width: w,height: h),format: .RGBAf,colorSpace: PanoramaEngine.linearSpace)
        let context = CIContext(options: [.workingColorSpace: PanoramaEngine.linearSpace])
        try LinearDNGWriter.write(image: image,context: context,to: url)
        let raw = try XCTUnwrap(CIRAWFilter(imageURL: url)); raw.boostAmount = 0; raw.isGamutMappingEnabled = false
        raw.sharpnessAmount = 0; raw.isLensCorrectionEnabled = false
        let raster = PanoramaRaster(image: try XCTUnwrap(raw.outputImage),context: context,width: w,height: h)
        for point in [CGPoint(x: 83,y: 40),CGPoint(x: 84,y: 89),CGPoint(x: 256,y: 256),CGPoint(x: 166,y: 178)] {
            let c = try XCTUnwrap(raster.rgb(point.x,point.y))
            XCTAssertEqual(c.x,2.5,accuracy: 0.08); XCTAssertEqual(c.y,0.5,accuracy: 0.03)
        }
        XCTAssertLessThan(try XCTUnwrap(raster.rgb(1,40)).x,0.01,"Uncovered canvas stays black")
    }
    func testUserRAWIntegration() throws {
        guard let path = ProcessInfo.processInfo.environment["PHOTONS_PANORAMA_SAMPLES"] else { throw XCTSkip("Set PHOTONS_PANORAMA_SAMPLES to run private 3FR acceptance") }
        let root = URL(fileURLWithPath:path)
        let urls = (659...662).map { root.appendingPathComponent(String(format:"B%07d.3FR",$0)) }
        let out = URL(fileURLWithPath:ProcessInfo.processInfo.environment["PHOTONS_PANORAMA_OUTPUT"] ?? NSTemporaryDirectory())
        try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
        let engine = PanoramaEngine()
        let plan = try engine.analyze(urls:urls) { print("PANORAMA",$0) }
        print("PANORAMA layout",plan.origins,"size",plan.size,"scores",plan.registrationScores,"optical",plan.optical.explanation)
        XCTAssertEqual(plan.sources.count,4); XCTAssertNotNil(plan.preview)
        XCTAssertTrue(plan.registrationScores.allSatisfy { $0 > 0.7 })
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(out.appendingPathComponent("preview.png") as CFURL,"public.png" as CFString,1,nil))
        CGImageDestinationAddImage(dest,try XCTUnwrap(plan.preview),nil); XCTAssertTrue(CGImageDestinationFinalize(dest))
        var records: [LCCPairRecord] = []
        for n in 659...662 {
            let scene = try PanoramaSource(url:root.appendingPathComponent(String(format:"B%07d.3FR",n)))
            let lcc = try LCCInspector.inspect(root.appendingPathComponent(String(format:"B%07d.3FR",1325-n)))
            print("LCC",scene.url.lastPathComponent,"->",lcc.source.url.lastPathComponent,lcc.message)
            XCTAssertNil(LCCInspector.incompatibility(scene:scene,flat:lcc.source)); XCTAssertTrue(lcc.likelyFlat)
            records.append(try LCCPairRecord(scene:scene.url,flat:lcc.source.url,confirmed:true))
        }
        if ProcessInfo.processInfo.environment["PHOTONS_CONFIRM_SAMPLE_LCC"] == "1" { try LCCPairingStore().save(records) }
        if ProcessInfo.processInfo.environment["PHOTONS_PANORAMA_EXPORT"] == "1" {
            try engine.export(plan,to:out.appendingPathComponent("Boston-shift-panorama.dng"),format:.dng) { print("EXPORT",$0) }
            let decoded = try XCTUnwrap(CIRAWFilter(imageURL:out.appendingPathComponent("Boston-shift-panorama.dng")))
            XCTAssertEqual(decoded.nativeSize,plan.size)
            decoded.scaleFactor = 0.08
            try CIContext().writeJPEGRepresentation(of:try XCTUnwrap(decoded.outputImage),to:out.appendingPathComponent("export-check.jpg"),colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!)
        }
    }
}

final class PanoramaHintTests:XCTestCase {
    func testMeasuredShiftSearchRefinesLowContrastTextureAndRejectsBlank() throws {
        let w=256,h=220
        func image(_ ox:Int,_ oy:Int)->GrayRaster {
            var values:[Double]=[]
            for y in 0..<h {for x in 0..<w {
                let xx=x+ox,yy=y+oy,hash=(xx &* 73856093) ^ (yy &* 19349663)
                values.append(0.3+Double(hash & 1023)/1023*0.001)
            }}
            return GrayRaster(width:w,height:h,values:values)
        }
        let a=image(30,60),b=image(104,36)
        XCTAssertNil(try TranslationRegistration.align(a,b,cancellation:.init()),"This fixture deliberately lacks strong descriptor corners")
        let match=try XCTUnwrap(TranslationRegistration.align(a,b,near:CGPoint(x:78,y:-21),radius:10,cancellation:.init()))
        XCTAssertEqual(match.offset.x,74,accuracy:0.2);XCTAssertEqual(match.offset.y,-24,accuracy:0.2)
        let blank=GrayRaster(width:w,height:h,values:[Double](repeating:0.3,count:w*h))
        XCTAssertNil(try TranslationRegistration.align(blank,blank,near:.zero,radius:10,cancellation:.init()))
    }
}
