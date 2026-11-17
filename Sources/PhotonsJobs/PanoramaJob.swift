import PhotonsLocalization
import Foundation
import CoreImage
import PhotonsCore
import PhotonsExport
import PhotonsPanorama

public struct PanoramaJob: Codable {
    public var snapshot: PanoramaSnapshot
    public var manifest: PanoramaManifest
    public var preset: ExportPreset
    public var linearDNG: Bool
    public var outputDirectory: URL
    public var bookmarks: [Data]
    public var stagingDirectory: URL?
    public init(snapshot:PanoramaSnapshot,manifest:PanoramaManifest,preset:ExportPreset,linearDNG:Bool,outputDirectory:URL,bookmarks:[Data],stagingDirectory:URL?=nil) {
        self.snapshot=snapshot;self.manifest=manifest;self.preset=preset;self.linearDNG=linearDNG;self.outputDirectory=outputDirectory;self.bookmarks=bookmarks;self.stagingDirectory=stagingDirectory
    }
    public func run(progress:@escaping(String,Double?)->Void) throws -> URL? {
        var access:[URL]=[]
        defer {for url in access {url.stopAccessingSecurityScopedResource()}}
        for data in bookmarks {
            var stale=false
            let url=try URL(resolvingBookmarkData:data,options:[.withoutUI,.withoutMounting],relativeTo:nil,bookmarkDataIsStale:&stale)
            if url.startAccessingSecurityScopedResource() {access.append(url)}
        }
        let plan=try snapshot.plan(),engine=PanoramaEngine()
        let report:PanoramaEngine.Progress = {message in
            var fraction:Double?
            if let re=try? NSRegularExpression(pattern:"([0-9]+)/([0-9]+)"),
               let m=re.firstMatch(in:message,range:NSRange(message.startIndex...,in:message)),
               let a=Range(m.range(at:1),in:message),let b=Range(m.range(at:2),in:message),
               let n=Double(message[a]),let total=Double(message[b]),total>0 {
                fraction=message.contains("DNG") ? 0.5+0.46*n/total : 0.05+0.4*(n-1)/total
            }
            progress(message,fraction)
        }
        progress(L10n.tr("21ce6456ecdb"),0.03)
        let scene=try engine.renderComposite(plan,progress:report)
        var item=ExportItem(id:"panorama",name:PanoramaManifest.defaultName(snapshot.sourceURLs),cameraKey:plan.sources.first?.camera)
        item.originalDirectory=snapshot.sourceURLs.sorted {$0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending}.first?.deletingLastPathComponent()
        item.panoramaMetadata=try manifest.encoded()
        let root=preset.destination == .sourceFolder ? (item.originalDirectory ?? outputDirectory):outputDirectory
        let subfolder=ExportNaming.subfolder(template:preset.subfolder,item:item)
        let directory=subfolder.isEmpty ? root:root.appendingPathComponent(subfolder,isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let base=ExportNaming.baseName(template:preset.nameTemplate,item:item,sequence:1)
        guard let url=OutputNameAllocator().reserve(base:base,ext:linearDNG ? "dng":preset.format.fileExtension,in:directory,policy:preset.conflict) else {return nil}
        guard !snapshot.sourceURLs.contains(url) else {throw PanoramaFailure(L10n.tr("dfcc7af61de8"))}
        // Parent knows this job-owned directory and removes it even when ImageIO crashes or the
        // process is terminated. Existing output files are replaced only after a complete encode.
        let stage=stagingDirectory ?? directory.appendingPathComponent(".photons-job-\(UUID().uuidString)",isDirectory:true)
        try FileManager.default.createDirectory(at:stage,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        defer {try? FileManager.default.removeItem(at:stage)}
        let temporary=stage.appendingPathComponent(url.lastPathComponent)
        if linearDNG {
            let scale=preset.renderScale(content:ImageSize(width:Int(scene.extent.width),height:Int(scene.extent.height)))
            let resized=scene.transformed(by:CGAffineTransform(scaleX:scale,y:scale))
            let context=CIContext(options:[.workingColorSpace:PanoramaEngine.linearSpace,.cacheIntermediates:false])
            defer {context.clearCaches()}
            try LinearDNGWriter.write(image:resized,context:context,to:temporary,manifest:item.panoramaMetadata,progress:report)
        } else {
        var stagedPreset=preset
        stagedPreset.destination = .chosenFolder;stagedPreset.subfolder="";stagedPreset.nameTemplate="{name}";stagedPreset.conflict = .overwrite
        item.name=url.deletingPathExtension().lastPathComponent
        let result=BatchExporter.run(items:[item],preset:stagedPreset,outputDirectory:stage,concurrency:1) {_,preset in
            let pixels=try PanoramaPixelRenderer.render(scene:scene,preset:preset,progress:progress)
            progress(L10n.tr("4206964a902f"),nil) // ImageIO provides no byte/row callback; never invent a percentage.
            return pixels
        }
        if let failure=result.failures.first {throw PanoramaFailure(failure.error ?? L10n.tr("6e4445df6957"))}
        guard result.written.first?.fileURL == temporary else {throw CocoaError(.fileWriteUnknown)}
        }
        switch preset.conflict {
        case .overwrite:
            if FileManager.default.fileExists(atPath:url.path) {_ = try FileManager.default.replaceItemAt(url,withItemAt:temporary)}
            else {try FileManager.default.moveItem(at:temporary,to:url)}
            return url
        case .skip:
            guard !FileManager.default.fileExists(atPath:url.path) else {return nil}
            try FileManager.default.moveItem(at:temporary,to:url)
            return url
        case .rename:
            // Another export can claim the name while ImageIO is encoding. Move without
            // replacement and allocate again; only an explicit overwrite may replace a file.
            var target=url
            for _ in 0..<32 {
                do {try FileManager.default.moveItem(at:temporary,to:target);return target}
                catch {
                    guard FileManager.default.fileExists(atPath:target.path),
                          let next=OutputNameAllocator().reserve(base:base,ext:url.pathExtension,in:directory,policy:.rename) else {throw error}
                    target=next
                }
            }
            throw CocoaError(.fileWriteFileExists)
        }
    }
}

public enum PanoramaPixelRenderer {
    public static func render(scene:CIImage,preset:ExportPreset,progress:(String,Double?)->Void = {_,_ in}) throws->DisplayImage {
        let content=ImageSize(width:Int(scene.extent.width),height:Int(scene.extent.height))
        let scale=preset.sizingMode == .longEdge ? preset.renderScale(content:content):1
        let size=ExportSizing.outputSize(content:content,scale:scale)
        let space=HDREncoding.linearColorSpace(for:preset.colorSpace)!
        let context=CIContext(options:[.workingColorSpace:space,.workingFormat:CIFormat.RGBAh,.cacheIntermediates:false])
        defer {context.clearCaches()}
        let image=scene.transformed(by:CGAffineTransform(translationX:-scene.extent.minX,y:-scene.extent.minY))
            .transformed(by:CGAffineTransform(scaleX:Double(size.width)/scene.extent.width,y:Double(size.height)/scene.extent.height))
        var pixels=[Float16](repeating:0,count:size.width*size.height*4)
        pixels.withUnsafeMutableBytes {bytes in
            // Bitmap rows are top-first; CI coordinates are bottom-first.
            for y in stride(from:0,to:size.height,by:256) {
                let h=min(256,size.height-y)
                context.render(image,toBitmap:bytes.baseAddress!.advanced(by:y*size.width*8),rowBytes:size.width*8,
                    bounds:CGRect(x:0,y:size.height-y-h,width:size.width,height:h),format:.RGBAh,colorSpace:space)
                progress(L10n.tr("bcb9008477f1" , String(describing: (y+h)), String(describing: (size.height))),0.45+0.3*Double(y+h)/Double(size.height))
            }
        }
        let linear=LinearPixels(width:size.width,height:size.height,rgba:pixels,primaries:preset.colorSpace)
        progress(L10n.tr("81d95bbdad66"),nil)
        return linear.displaySDR(bitDepth:preset.effectiveBitDepth,toneMap:preset.isHDR ? .global:(preset.sdrToneMapping == .standard ? .standard:(preset.appliesSDRToneMap ? .global:nil)))
    }
}

public struct PanoramaWorkerEvent:Codable {
    public var message:String
    public var fraction:Double?
    public var result:URL?
    public var finished:Bool
    public var error:String?
    public init(message:String,fraction:Double?=nil,result:URL?=nil,finished:Bool=false,error:String?=nil) {
        self.message=message;self.fraction=fraction;self.result=result;self.finished=finished;self.error=error
    }
}
