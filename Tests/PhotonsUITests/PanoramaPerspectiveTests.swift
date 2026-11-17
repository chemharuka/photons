import XCTest
import AppKit
import CoreImage
import ImageIO
import PhotonsPanorama
@testable import PhotonsUI

@MainActor
final class PanoramaPerspectiveTests:XCTestCase {
    private func waitUntilIdle(_ model:PanoramaWindowModel) async throws {
        let deadline=Date().addingTimeInterval(30)
        while model.busy && Date()<deadline {try await Task.sleep(nanoseconds:20_000_000)}
        XCTAssertFalse(model.busy,"Registration must finish or report failure")
    }
    // Same deterministic scene as the iPad perspective acceptance fixture, no private photos.
    private func fixtures(_ folder:URL,textured:Bool=true) throws->[URL] {
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let context=CIContext()
        return try (0..<2).map { n in
            let width=768,height=512,offset=n*220
            var pixels=[UInt8](repeating:255,count:width*height*4)
            for y in 0..<height {for x in 0..<width {
                let wx=x+offset,h=UInt32(truncatingIfNeeded:(wx/4) &* 73856093 ^ (y/4) &* 19349663)
                let checker=(wx/64+y/64)%2,noise=Int(h%67),i=(y*width+x)*4
                pixels[i]=textured ? UInt8(45+noise+checker*60):128
                pixels[i+1]=textured ? UInt8(45+noise+y*80/height):128
                pixels[i+2]=textured ? UInt8(45+noise+wx*60/1208):128
            }}
            let cg=try XCTUnwrap(CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,
                space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),
                provider:CGDataProvider(data:Data(pixels) as CFData)!,decode:nil,shouldInterpolate:true,intent:.defaultIntent))
            var image=CIImage(cgImage:cg)
            if n==1 && textured {image=image.applyingFilter("CIPerspectiveTransform",parameters:[
                "inputTopLeft":CIVector(x:0,y:512),"inputTopRight":CIVector(x:768,y:498),
                "inputBottomLeft":CIVector(x:12,y:4),"inputBottomRight":CIVector(x:756,y:0)])}
            let url=folder.appendingPathComponent("frame-\(n).tiff")
            try context.writeTIFFRepresentation(of:image.cropped(to:CGRect(x:0,y:0,width:width,height:height)),to:url,
                format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!)
            return url
        }
    }
    func testMacPerspectiveRegistrationAndExportPreserveModeWithoutShiftMetadata() async throws {
        _ = NSApplication.shared
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:folder)}
        let model=PanoramaWindowModel(urls:try fixtures(folder))
        model.knownPositions=[0:.zero,1:CGPoint(x:150,y:150)]
        model.positionReference = .init(sourceIndex:0,positionMM:CGPoint(x:4,y:5))
        model.sensorChoice=4;model.sensorWidth=54;model.sensorHeight=40
        model.prepare(mode:.perspective)
        XCTAssertFalse(model.canStitch)
        try await waitUntilIdle(model)
        XCTAssertNil(model.error)
        let plan=try XCTUnwrap(model.plan)
        XCTAssertEqual(plan.registrationMode,.perspective)
        let warps=try XCTUnwrap(plan.warps)
        XCTAssertEqual(warps.count,2)
        XCTAssertGreaterThan(abs(warps[1].values[1])+abs(warps[1].values[3]),0.001)
        XCTAssertTrue(model.canStitch)
        let manifest=model.exportManifest(for:plan)
        try manifest.validate()
        XCTAssertEqual(manifest.registrationMode,.perspective)
        XCTAssertNil(manifest.cameraBody);XCTAssertNil(manifest.profileID);XCTAssertNil(manifest.profileOffsetMM)
        XCTAssertTrue(manifest.frames.allSatisfy {$0.shiftMM==nil})
        let frozen=try JSONDecoder().decode(PanoramaSnapshot.self,from:JSONEncoder().encode(PanoramaSnapshot(plan:plan))).plan()
        XCTAssertEqual(frozen.registrationMode,.perspective)
        let output=folder.appendingPathComponent("perspective.dng"),engine=PanoramaEngine()
        try LinearDNGWriter.write(image:engine.renderComposite(frozen,outputLongEdge:800),context:CIContext(),to:output,manifest:manifest.encoded())
        XCTAssertEqual(try PanoramaManifest.read(from:output)?.registrationMode,.perspective)
        model.lccEnabled=true
        XCTAssertFalse(model.canStitch)
        model.changeLCC()
        XCTAssertFalse(model.lccEnabled)
        model.chooseMode()
        XCTAssertTrue(model.choosingMode);XCTAssertNil(model.plan);XCTAssertFalse(model.canStitch)
    }
    func testPerspectiveFailureHasNoShiftDraftAndShiftCanStillCreateDraft() async throws {
        _ = NSApplication.shared
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:folder)}
        let urls=try fixtures(folder,textured:false),model=PanoramaWindowModel(urls:urls)
        model.plan=try PanoramaEngine().alignmentDraft(urls:urls,knownPositions:[:],sensorOverride:nil,message:"previous plan")
        model.prepare(mode:.perspective)
        XCTAssertNil(model.plan)
        try await waitUntilIdle(model)
        XCTAssertNotNil(model.error);XCTAssertNil(model.plan);XCTAssertFalse(model.canStitch)
        model.prepare(mode:.shift)
        try await waitUntilIdle(model)
        XCTAssertNil(model.error)
        let draft=try XCTUnwrap(model.plan)
        XCTAssertEqual(draft.registrationMode,.shift);XCTAssertFalse(draft.isRegistered)
        XCTAssertFalse(model.canStitch)
    }
}
