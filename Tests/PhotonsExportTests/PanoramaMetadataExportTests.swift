import XCTest
import CoreImage
import ImageIO
import PhotonsCore
import PhotonsPanorama
@testable import PhotonsExport

final class PanoramaMetadataExportTests:XCTestCase {
    func testPortableGeometryMatchesRenderedCropTurnFlipAndPerspective() throws {
        let w=160,h=100
        var rgba=[Float16](repeating:1,count:w*h*4)
        for y in 0..<h {for x in 0..<w {let i=(y*w+x)*4;rgba[i]=Float16((Double(x)+0.5)/Double(w));rgba[i+1]=Float16((Double(y)+0.5)/Double(h));rgba[i+2]=0.25}}
        let graph=try RenderGraph(input:.init(image:LinearImage(width:w,height:h,rgba:rgba,colorSpace:"extendedLinearSRGB",decoderVersion:"geometry-test"),identity:"geometry-test"))
        defer {graph.releaseAllTextures()}
        for kind in 0..<6 {
            var edit=EditModel.neutral
            edit.geometry.crop = .init(x:0.1,y:0.15,width:0.7,height:0.6)
            if kind==1 {edit.geometry.flipHorizontal=true}
            if kind==2 {edit.geometry.quarterTurns=1}
            if kind==3 {edit.geometry.rotationDegrees=17}
            if kind==4 {edit.geometry.perspectiveVertical=20;edit.geometry.cropSpace = .canvas}
            if kind==5 {edit.geometry.perspectiveHorizontal = -15;edit.geometry.rotationDegrees = -9;edit.geometry.quarterTurns=3;edit.geometry.flipVertical=true}
            let pixels=try XCTUnwrap(try graph.render(edit,options:RenderOptions(display:.init(primaries:.sRGB,bitDepth:16,linearOutput:true),useCache:false)).display)
            let x=pixels.width/3,y=pixels.height/2,u=(Double(x)+0.5)/Double(pixels.width),v=(Double(y)+0.5)/Double(pixels.height)
            let m=PanoramaExportMetadata.geometry(edit,source:.init(width:w,height:h)),z=m[6]*u+m[7]*v+m[8]
            let px=(m[0]*u+m[1]*v+m[2])/z,py=(m[3]*u+m[4]*v+m[5])/z
            XCTAssertEqual(Double(pixels.rgba[(y*pixels.width+x)*4]),px,accuracy:0.012,"geometry \(kind) x")
            XCTAssertEqual(Double(pixels.rgba[(y*pixels.width+x)*4+1]),py,accuracy:0.012,"geometry \(kind) y")
        }
    }
    func testResizedCroppedCopiesKeepGeometryAndEachSourceFolder() throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:folder)}
        var items:[ExportItem]=[]
        for name in ["a","b"] {
            let parent=folder.appendingPathComponent(name)
            try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:true)
            let url=parent.appendingPathComponent("photo.tiff")
            let ci=CIImage(color:CIColor(red:0.2,green:0.3,blue:0.4)).cropped(to:CGRect(x:0,y:0,width:128,height:64))
            try CIContext().writeTIFFRepresentation(of:ci,to:url,format:.RGBA16,colorSpace:PanoramaEngine.linearSpace)
            let plan=try PanoramaEngine().singlePhoto(PanoramaSource(url:url))
            let manifest=PanoramaManifest(plan:plan,profileName:"43XL",offsetMM:.zero,sensor:.init(width:36,height:24,source:"test"))
            let dng=parent.appendingPathComponent("pano.dng")
            try LinearDNGWriter.write(image:ci,context:CIContext(),to:dng,manifest:manifest.encoded())
            var edit=EditModel.neutral;edit.geometry.crop = .init(x:0.25,y:0.125,width:0.5,height:0.75)
            items.append(ExportItem(id:name,name:"copy",edit:edit,sourceURL:dng))
        }
        var preset=ExportPreset(format:.tiff,longEdge:40,bitDepth:16,colorSpace:.sRGB,hdr:HDRExport(enabled:false),nameTemplate:"{name}")
        preset.destination = .sourceFolder;preset.subfolder="copies";preset.metadataLevel = .none
        let result=BatchExporter.run(items:items,preset:preset,outputDirectory:folder,concurrency:1) {_,_ in
            DisplayImage(width:64,height:48,rgba:[Float16](repeating:0.3,count:64*48*4),primaries:.sRGB,bitDepth:16)
        }
        XCTAssertEqual(result.failures.count,0)
        XCTAssertEqual(result.written.count,2)
        for row in result.written {
            let url=try XCTUnwrap(row.fileURL),read=try XCTUnwrap(PanoramaManifest.read(from:url))
            XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent,"copies")
            XCTAssertEqual(read.profileName,"43XL")
            let point=read.canvasPoint(u:0.25,v:0.5)
            XCTAssertEqual(point.x,0.375,accuracy:1e-9);XCTAssertEqual(point.y,0.5,accuracy:1e-9)
        }
    }
}
