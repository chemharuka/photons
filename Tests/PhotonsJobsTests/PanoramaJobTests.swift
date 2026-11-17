import XCTest
import CoreImage
import ImageIO
import PhotonsCore
import PhotonsExport
import PhotonsPanorama
@testable import PhotonsJobs

final class PanoramaJobTests:XCTestCase {
    func testBostonCorrectedGeometryWorker() throws {
        guard let path=ProcessInfo.processInfo.environment["PHOTONS_BOSTON_CORRECTED_EXPORT"] else {throw XCTSkip("External corrected-geometry RAW export")}
        let output=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("local/audit/corrected-panorama-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        for range in [641...643,644...646] {
            let urls=range.map {URL(fileURLWithPath:path).appendingPathComponent(String(format:"B%07d.3FR",$0))}
            let plan=try PanoramaEngine().analyze(urls:urls)
            XCTAssertNotNil(plan.warps)
            let preset=ExportPreset(format:.tiff,longEdge:4000,bitDepth:16,colorSpace:.displayP3,hdr:HDRExport(enabled:true),nameTemplate:"{name}",sizingMode:.longEdge)
            let job=PanoramaJob(snapshot:try PanoramaSnapshot(plan:plan),manifest:PanoramaManifest(plan:plan),preset:preset,linearDNG:true,outputDirectory:output,bookmarks:[])
            let request=output.appendingPathComponent("request-\(range.lowerBound).json")
            try JSONEncoder().encode(job).write(to:request)
            let worker=Process(),pipe=Pipe()
            worker.executableURL=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent(".build/release/photons-panorama-worker")
            worker.arguments=[request.path];worker.standardOutput=pipe
            try worker.run();let data=pipe.fileHandleForReading.readDataToEndOfFile();worker.waitUntilExit()
            XCTAssertEqual(worker.terminationStatus,0,String(decoding:data,as:UTF8.self))
            let events=data.split(separator:10).compactMap {try? JSONDecoder().decode(PanoramaWorkerEvent.self,from:Data($0))}
            let url=try XCTUnwrap(events.last?.result,String(decoding:data,as:UTF8.self))
            let read=try XCTUnwrap(PanoramaManifest.read(from:url));XCTAssertEqual(read.version,2)
            XCTAssertEqual(read.frames.count,3);XCTAssertNotNil(read.frames[2].imageToCanvas)
            let filter=try XCTUnwrap(CIRAWFilter(imageURL:url));XCTAssertEqual(max(filter.nativeSize.width,filter.nativeSize.height),4000,accuracy:1)
            print("CORRECTED_PANORAMA_OUTPUT",url.path)
        }
    }

    func testBostonHDRWorker() throws {
        guard let sourceFolder=ProcessInfo.processInfo.environment["PHOTONS_BOSTON_EXPORT"] else {throw XCTSkip("External Boston RAW export")}
        let folder=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("local/audit/boston-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let urls=(659...662).map {URL(fileURLWithPath:sourceFolder).appendingPathComponent(String(format:"B%07d.3FR",$0))}
        let plan=try PanoramaEngine().analyze(urls:urls) {FileHandle.standardOutput.write(Data(("BOSTON \($0)\n").utf8))}
        let preset=ExportPreset(format:.heic,quality:0.85,bitDepth:8,colorSpace:.displayP3,hdr:HDRExport(gainMap:.iso),nameTemplate:"{name}",sizingMode:.none)
        let job=PanoramaJob(snapshot:try PanoramaSnapshot(plan:plan),manifest:PanoramaManifest(plan:plan),preset:preset,linearDNG:false,outputDirectory:folder,bookmarks:[])
        let request=folder.appendingPathComponent("request.json")
        try JSONEncoder().encode(job).write(to:request)
        let process=Process(),pipe=Pipe()
        process.executableURL=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent(".build/release/photons-panorama-worker")
        process.arguments=[request.path];process.standardOutput=pipe
        try process.run()
        var bytes=Data()
        while let part=try pipe.fileHandleForReading.read(upToCount:8192),!part.isEmpty {bytes.append(part);FileHandle.standardOutput.write(part)}
        process.waitUntilExit();XCTAssertEqual(process.terminationStatus,0)
        let result=bytes.split(separator:10).compactMap {try? JSONDecoder().decode(PanoramaWorkerEvent.self,from:Data($0))}.last
        let url=try XCTUnwrap(result?.result)
        XCTAssertNotNil(try PanoramaManifest.read(from:url))
        FileHandle.standardOutput.write(Data(("BOSTON_OUTPUT \(url.path)\n").utf8))
    }
    func testStripRenderingPreservesRowOrderAndSDRMapping() throws {
        let w=16,h=521,space=CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!
        var data=[Float](repeating:1,count:w*h*4)
        for y in 0..<h {for x in 0..<w {let i=(y*w+x)*4;data[i]=Float(y)/200;data[i+1]=Float(x)/8;data[i+2]=0.1}}
        let image=CIImage(bitmapData:data.withUnsafeBytes {Data($0)},bytesPerRow:w*16,size:CGSize(width:w,height:h),format:.RGBAf,colorSpace:space)
        let preset=ExportPreset(format:.tiff,bitDepth:16,colorSpace:.sRGB,sdrToneMapping:.standard,hdr:HDRExport(enabled:false))
        let result=try PanoramaPixelRenderer.render(scene:image,preset:preset)
        var expected=[Float16](repeating:0,count:w*h*4)
        CIContext(options:[.workingColorSpace:space]).render(image,toBitmap:&expected,rowBytes:w*8,bounds:image.extent,format:.RGBAh,colorSpace:space)
        let raw=try XCTUnwrap(result.linear)
        XCTAssertEqual(raw.rgba,expected,"Strip boundaries must not reverse rows or move image content")
        XCTAssertTrue(result.rgba.enumerated().filter {$0.offset%4 != 3}.allSatisfy {Float($0.element)<=1})
    }
    func testWorkerDNGHDRAndSDRExportProvenanceAndSourceSubfolder() throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:folder)}
        let sourceURL=folder.appendingPathComponent("B001.dng")
        let values:[Float]=[3,0.3,0.1,1]
        let image=CIImage(bitmapData:values.withUnsafeBytes {Data($0)},bytesPerRow:16,size:CGSize(width:1,height:1),format:.RGBAf,colorSpace:PanoramaEngine.linearSpace)
            .clampedToExtent().cropped(to:CGRect(x:0,y:0,width:640,height:320))
        try LinearDNGWriter.write(image:image,context:CIContext(),to:sourceURL)
        let imageSource=try XCTUnwrap(CGImageSourceCreateWithURL(sourceURL as CFURL,nil))
        let properties=try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(imageSource,0,nil) as? [CFString:Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int,640)
        let source=try PanoramaSource(url:sourceURL)
        XCTAssertEqual(source.size,CGSize(width:640,height:320),"DNG catalog dimensions must describe the RAW SubIFD, not the thumbnail")
        let plan=try PanoramaEngine().singlePhoto(source)
        let composite=try PanoramaEngine().renderComposite(plan)
        let rendered=try PanoramaPixelRenderer.render(scene:composite,preset:ExportPreset(colorSpace:.sRGB))
        XCTAssertGreaterThan(Float(try XCTUnwrap(rendered.linear).rgba[0]),2,"Reimporting a linear DNG must preserve HDR headroom")
        let snapshot=try PanoramaSnapshot(plan:plan),manifest=PanoramaManifest(plan:plan)
        let executable=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent(".build/debug/photons-panorama-worker")
        guard FileManager.default.isExecutableFile(atPath:executable.path) else {throw XCTSkip("Build worker before integration test")}
        // A competing exporter claims the final name after this job reserved it.
        var racePreset=ExportPreset(format:.heic,colorSpace:.sRGB,hdr:HDRExport(enabled:false),nameTemplate:"{name}")
        racePreset.conflict = .rename
        let race=PanoramaJob(snapshot:snapshot,manifest:manifest,preset:racePreset,linearDNG:false,outputDirectory:folder,bookmarks:[])
        let claimed=folder.appendingPathComponent("B001_pano.heic"),other=Data("another export".utf8)
        var inserted=false
        let renamed=try race.run {_,fraction in
            if fraction == nil && !inserted {inserted=true;try! other.write(to:claimed)}
        }
        XCTAssertTrue(inserted);XCTAssertNotEqual(renamed,claimed)
        XCTAssertEqual(try Data(contentsOf:claimed),other)
        for (dng,hdr,format) in [(true,true,ExportFormat.heic),(false,true,.heic),(false,false,.tiff)] {
            var preset=ExportPreset(format:format,bitDepth:format == .tiff ? 16:8,colorSpace:.displayP3,sdrToneMapping:.standard,hdr:HDRExport(enabled:hdr),nameTemplate:"{name}")
            preset.destination = .sourceFolder;preset.subfolder=dng ? "DNG":hdr ? "HDR":"SDR"
            let stage=folder.appendingPathComponent("staging")
            let job=PanoramaJob(snapshot:snapshot,manifest:manifest,preset:preset,linearDNG:dng,outputDirectory:folder.appendingPathComponent("wrong"),bookmarks:[],stagingDirectory:stage)
            let request=folder.appendingPathComponent("request.json")
            try JSONEncoder().encode(job).write(to:request)
            let process=Process(),pipe=Pipe();process.executableURL=executable;process.arguments=[request.path];process.standardOutput=pipe
            try process.run();let stdout=pipe.fileHandleForReading.readDataToEndOfFile();process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus,0,String(decoding:stdout,as:UTF8.self))
            let events=stdout.split(separator:10).compactMap {try? JSONDecoder().decode(PanoramaWorkerEvent.self,from:Data($0))}
            let output=try XCTUnwrap(events.last?.result,String(decoding:stdout,as:UTF8.self))
            XCTAssertEqual(output.deletingLastPathComponent().lastPathComponent,preset.subfolder)
            XCTAssertEqual(output.deletingPathExtension().lastPathComponent,"B001_pano")
            XCTAssertNotNil(try PanoramaManifest.read(from:output))
            XCTAssertFalse(FileManager.default.fileExists(atPath:stage.path))
            let read=try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL,nil))
            if #available(macOS 15.0,*), !dng {
                let aux=CGImageSourceCopyAuxiliaryDataInfoAtIndex(read,0,kCGImageAuxiliaryDataTypeISOGainMap)
                XCTAssertEqual(aux != nil,hdr,"Only HDR tab may write a gain map")
            }
        }
    }
}
