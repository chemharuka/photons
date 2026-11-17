import XCTest
import CoreImage
import ImageIO
@testable import PhotonsPanorama

final class PanoramaProvenanceTests:XCTestCase {
    func testMetadataPacketReadsLegacyAndBoundsCompressedOutput() throws {
        let data=Data(repeating:65,count:2_000_000)
        let packet=PanoramaMetadataPacket.string(data)
        XCTAssertTrue(packet.hasPrefix("deflate:"))
        XCTAssertLessThan(packet.utf8.count,20_000)
        XCTAssertEqual(PanoramaMetadataPacket.data(packet),data)
        XCTAssertEqual(PanoramaMetadataPacket.data(data.base64EncodedString()),data)
        XCTAssertNil(PanoramaMetadataPacket.data(packet.replacingOccurrences(of:"deflate:2000000:",with:"deflate:10:")))
        XCTAssertNil(PanoramaMetadataPacket.data("deflate:999999999:AAAA"))
        XCTAssertNil(PanoramaMetadataPacket.data("deflate:4:broken"))
    }
    func fixture(_ folder:URL) throws->PanoramaPlan {
        let url=folder.appendingPathComponent("B002.tiff")
        let image=CIImage(color:CIColor(red:0.3,green:0.2,blue:0.1)).cropped(to:CGRect(x:0,y:0,width:64,height:32))
        let context=CIContext()
        try context.writeTIFFRepresentation(of:image,to:url,format:.RGBA16,colorSpace:PanoramaEngine.linearSpace)
        let source=try PanoramaSource(url:url)
        return PanoramaPlan(sources:[source,source],origins:[.zero,CGPoint(x:32,y:0)],size:CGSize(width:96,height:32),registrationScores:[1,1],whiteBalance:nil,
            gains:[1,1],ownership:[0,1],maskWidth:2,maskHeight:1,optical:.init(center:nil,confidence:0,explanation:"",occludedEdges:[]),options:.init(),previewScale:1,previewImages:[image,image],preview:nil)
    }
    func testProjectiveGeometrySurvivesWorkerAndDNGMetadata() throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:folder)}
        var plan=try fixture(folder)
        plan.warps=[.identity,PanoramaTransform([0.95,0.04,32,0,0.95,0.8,0.0003,0,1])]
        let manifest=PanoramaManifest(plan:plan,offsetMM:CGPoint(x:2,y:3),sensor:.init(width:43.8,height:32.9,source:"test"))
        try manifest.validate()
        XCTAssertEqual(manifest.version,2)
        let snapshot=try JSONDecoder().decode(PanoramaSnapshot.self,from:JSONEncoder().encode(PanoramaSnapshot(plan:plan)))
        let frozen=try snapshot.plan()
        XCTAssertEqual(frozen.warps,plan.warps)
        let p=CGPoint(x:0.3,y:0.4)
        let warp=try XCTUnwrap(manifest.frames[1].imageToCanvas)
        let canvas=warp.point(p)
        let restored=try XCTUnwrap(warp.inverse).point(canvas)
        XCTAssertEqual(restored.x,p.x,accuracy:0.000001)
        XCTAssertEqual(restored.y,p.y,accuracy:0.000001)
        XCTAssertEqual(try XCTUnwrap(manifest.frames[1].sensorRect).width,64.0/96.0,accuracy:1e-12)
        let image=try PanoramaEngine().renderComposite(frozen),url=folder.appendingPathComponent("projective.dng")
        try LinearDNGWriter.write(image:image,context:CIContext(),to:url,manifest:manifest.encoded())
        let read=try XCTUnwrap(PanoramaManifest.read(from:url))
        XCTAssertEqual(read.version,2)
        XCTAssertEqual(read.frames[1].imageToCanvas,warp)
        XCTAssertEqual(read.frames[1].sensorRect,manifest.frames[1].sensorRect)
    }

    func testDNGThumbnailManifestAndSnapshotRoundTrip() throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true);defer {try? FileManager.default.removeItem(at:folder)}
        let plan=try fixture(folder)
        let manifest=PanoramaManifest(plan:plan,profileID:LCCLensProfile.builtInID,profileName:"43XL",offsetMM:CGPoint(x:2,y:3),sensor:.init(width:43.8,height:32.9,source:"test"))
        let snapshot=try JSONDecoder().decode(PanoramaSnapshot.self,from:JSONEncoder().encode(PanoramaSnapshot(plan:plan)))
        let frozen=try snapshot.plan();XCTAssertEqual(frozen.origins,plan.origins);XCTAssertEqual(frozen.ownership,plan.ownership)
        let engine=PanoramaEngine(),scene=try engine.renderComposite(frozen),url=folder.appendingPathComponent("result.dng")
        try LinearDNGWriter.write(image:scene,context:CIContext(),to:url,manifest:manifest.encoded())
        let source=try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL,nil))
        let thumb=CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageIfAbsent:false,kCGImageSourceThumbnailMaxPixelSize:512] as CFDictionary)
        XCTAssertNotNil(thumb,"A real embedded thumbnail must be readable without RAW development")
        let read=try XCTUnwrap(PanoramaManifest.read(from:url));XCTAssertEqual(read.frames.count,2)
        XCTAssertEqual(read.profileName,"43XL");XCTAssertFalse(read.correctionApplied)
        XCTAssertEqual(read.canvasPoint(u:0.75,v:0.5),manifest.canvasPoint(u:0.75,v:0.5))
        XCTAssertFalse(String(data:try read.encoded(),encoding:.utf8)!.contains(folder.path))
        XCTAssertEqual(PanoramaManifest.defaultName([URL(fileURLWithPath:"/a/B10.3FR"),URL(fileURLWithPath:"/b/B2.3FR")]),"B2_pano")
    }
}
