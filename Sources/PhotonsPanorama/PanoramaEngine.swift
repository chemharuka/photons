import PhotonsLocalization
import Foundation
import CoreImage
import CoreGraphics
import ImageIO

public final class PanoramaEngine {
    public static let linearSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    let context = CIContext(options: [.workingColorSpace: linearSpace, .cacheIntermediates: false])
    public init() {}
    public typealias Progress = (String) -> Void

    func decoded(_ source: PanoramaSource, scale: Double, whiteBalance: (Float,Float)?) throws -> CIImage {
        try LCCProfileBuilder.linearImage(source:source,scale:scale,whiteBalance:whiteBalance)
    }

    func materialize(_ image: CIImage) -> CIImage {
        let w = Int(ceil(image.extent.width)), h = Int(ceil(image.extent.height))
        var data = Data(count:w*h*8)
        data.withUnsafeMutableBytes { p in
            context.render(image,toBitmap:p.baseAddress!,rowBytes:w*8,
                           bounds:CGRect(x:0,y:0,width:w,height:h),format:.RGBAh,colorSpace:Self.linearSpace)
        }
        return CIImage(bitmapData:data,bytesPerRow:w*8,size:CGSize(width:w,height:h),format:.RGBAh,colorSpace:Self.linearSpace)
    }

    /// A single photo uses the same physical coordinate convention as a panorama.
    public func singlePhoto(_ source:PanoramaSource, cancellation:PanoramaCancellation = .init()) throws -> PanoramaPlan {
        let scale=min(1,1600/max(source.size.width,source.size.height))
        let wb:(Float,Float)?=source.temperature.flatMap {t in source.tint.map {(t,$0)}}
        let image=try materialize(decoded(source,scale:scale,whiteBalance:wb))
        var plan=PanoramaPlan(sources:[source],origins:[.zero],size:source.size,registrationScores:[1],whiteBalance:wb,
            gains:[1],ownership:[0],maskWidth:1,maskHeight:1,
            optical:OpticalEstimate(center:nil,confidence:0,explanation:"",occludedEdges:[]),options:.init(),previewScale:scale,previewImages:[image],preview:nil)
        renderPreview(&plan);return plan
    }

    public func analyze(urls: [URL], options: PanoramaOptions = .init(),knownPositions:[Int:CGPoint]=[:],sensorOverride:SensorSize?=nil,
                        registrationMode:PanoramaRegistrationMode = .shift,
                        cancellation: PanoramaCancellation = .init(), progress: Progress = { _ in }) throws -> PanoramaPlan {
        guard urls.count >= 2 else { throw PanoramaFailure(urls.isEmpty ? L10n.tr("977f178f562a") : L10n.tr("2e0b7140c7cc")) }
        guard urls.count <= 16 else { throw PanoramaFailure(L10n.tr("fc6d0bd57867")) }
        var sources: [PanoramaSource] = []
        for url in urls { try cancellation.check(); sources.append(try PanoramaSource(url:url, sensorOverride:sensorOverride)) }
        guard let first = sources.first else { throw PanoramaFailure(L10n.tr("2208e0978c6a")) }
        guard sources.allSatisfy({ abs($0.size.width-first.size.width)<2 && abs($0.size.height-first.size.height)<2 && $0.orientation == first.orientation }) else {
            throw PanoramaFailure(L10n.tr("ff9aa3d63f3f"))
        }
        let readings=sources.compactMap {s->(Float,Float)? in
            guard let temperature=s.temperature,let tint=s.tint,temperature.isFinite,tint.isFinite else {return nil}
            return (temperature,tint)
        }
        let wb:(Float,Float)?=readings.isEmpty ? nil:(readings.reduce(0) {$0+$1.0}/Float(readings.count),readings.reduce(0) {$0+$1.1}/Float(readings.count))
        let scale = min(1,2048/max(first.size.width,first.size.height))
        var images: [CIImage] = [], grays: [GrayRaster] = [], coarse: [GrayRaster] = []
        for (i,source) in sources.enumerated() {
            try cancellation.check(); progress(L10n.tr("f0f5a708b21d" , String(describing: (i+1)), String(describing: (sources.count)), String(describing: (source.url.lastPathComponent))))
            let image = try materialize(decoded(source,scale:scale,whiteBalance:wb)); images.append(image)
            grays.append(PanoramaRaster(image:image,context:context,width:Int(image.extent.width),height:Int(image.extent.height)).gray)
            coarse.append(PanoramaRaster(image:image,context:context,width:Int(image.extent.width)/2,height:Int(image.extent.height)/2).gray)
        }
        struct Edge { let a: Int; let b: Int; let transform: PanoramaTransform; let score: Double; var probes: [CGPoint] = [] }
        var edges: [Edge] = []
        if registrationMode == .shift {
        for a in 0..<sources.count-1 { for b in a+1..<sources.count {
            try cancellation.check(); progress(L10n.tr("ffa317474694" , String(describing: (a+1)), String(describing: (b+1))))
            let match:TranslationRegistration.Match?
            if let pa=knownPositions[a],let pb=knownPositions[b],let sensor=sensorOverride ?? first.sensor {
                progress(L10n.tr("421e14fe1c2b" , String(describing: (a+1)), String(describing: (b+1))))
                let expected=CGPoint(x:(pb.x-pa.x)/sensor.width*Double(coarse[a].width),y:-(pb.y-pa.y)/sensor.height*Double(coarse[a].height))
                match=try TranslationRegistration.align(coarse[a],coarse[b],near:expected,
                    radius:max(Double(coarse[a].width)/sensor.width,Double(coarse[a].height)/sensor.height)*1.5,cancellation:cancellation)
            } else {match=try TranslationRegistration.align(coarse[a],coarse[b],cancellation:cancellation)}
            if let match {
                let initial = CGPoint(x:match.offset.x*Double(grays[a].width)/Double(coarse[a].width),
                                      y:match.offset.y*Double(grays[a].height)/Double(coarse[a].height))
                let anchors = match.anchors.map { CGPoint(x:$0.x*Double(grays[a].width)/Double(coarse[a].width),
                                                          y:$0.y*Double(grays[a].height)/Double(coarse[a].height)) }
                let refined = TranslationRegistration.refine(grays[a],grays[b],offset:initial,radius:2,anchors:anchors)
                if refined.score > 0.7 {
                    edges.append(Edge(a:a,b:b,transform:.translation(CGPoint(x:refined.offset.x/scale,y:refined.offset.y/scale)),score:refined.score))
                }
            }
        }}
        }
        func connected() -> Bool {
            var reached:Set<Int>=[0]
            for _ in sources.indices {for edge in edges where reached.contains(edge.a) || reached.contains(edge.b) {reached.insert(edge.a);reached.insert(edge.b)}}
            return reached.count==sources.count
        }
        var projective=false
        if registrationMode == .perspective || !connected() {
            for a in 0..<sources.count-1 {for b in a+1..<sources.count where !edges.contains(where:{$0.a==a && $0.b==b}) {
                try cancellation.check()
                progress(L10n.tr("panorama.geometry",String(a+1),String(b+1)))
                guard let match=try ProjectiveRegistration.align(coarse[a],coarse[b],fineA:grays[a],fineB:grays[b],cancellation:cancellation) else {continue}
                let h=PanoramaTransform.scale(1/scale,1/scale).multiplied(by:match.transform).multiplied(by:.scale(scale,scale))
                if registrationMode == .shift, let pa=knownPositions[a],let pb=knownPositions[b],let sensor=sensorOverride ?? first.sensor {
                    let center=CGPoint(x:first.size.width/2,y:first.size.height/2),mapped=h.point(center)
                    let expected=CGPoint(x:(pb.x-pa.x)/sensor.width*first.size.width,y:-(pb.y-pa.y)/sensor.height*first.size.height)
                    guard hypot(mapped.x-center.x-expected.x,mapped.y-center.y-expected.y)<max(first.size.width/sensor.width,first.size.height/sensor.height)*1.5 else {continue}
                }
                edges.append(Edge(a:a,b:b,transform:h,score:match.score,probes:match.pairs.map {CGPoint(x:$0.b.x/scale,y:$0.b.y/scale)}))
                projective=true
            }}
        }
        // Maximum-confidence spanning tree: input filename order does not determine image layout.
        var poses=[PanoramaTransform?](repeating:nil,count:sources.count),scores=[Double](repeating:1,count:sources.count)
        poses[0] = .identity
        while poses.contains(where:{$0==nil}) {
            let choices=edges.filter {(poses[$0.a]==nil) != (poses[$0.b]==nil)}
            guard let edge=choices.max(by:{$0.score<$1.score}) else {
                let missing=sources.indices.filter {poses[$0]==nil}.map {sources[$0].url.lastPathComponent}.joined(separator:"、")
                throw PanoramaFailure(L10n.tr("a89e2a702257",missing))
            }
            if let a=poses[edge.a] {poses[edge.b]=a.multiplied(by:edge.transform);scores[edge.b]=edge.score}
            else if let b=poses[edge.b],let inverse=edge.transform.inverse {poses[edge.a]=b.multiplied(by:inverse);scores[edge.a]=edge.score}
        }
        var transforms=poses.map {$0!}
        for edge in edges where edge.score>0.8 {
            let probes=edge.probes.isEmpty ? [CGPoint(x:first.size.width/2,y:first.size.height/2)]:edge.probes
            let residuals=probes.map {p -> Double in
                let lhs=transforms[edge.a].point(edge.transform.point(p)),rhs=transforms[edge.b].point(p)
                return hypot(lhs.x-rhs.x,lhs.y-rhs.y)*scale
            }
            if median(residuals)>(projective ? 12:3) {throw PanoramaFailure(L10n.tr("8a5142e9f53e"))}
        }
        let boxes=transforms.enumerated().map {$0.element.bounds(sources[$0.offset].size)}
        let minX=floor(boxes.map(\.minX).min()!),minY=floor(boxes.map(\.minY).min()!)
        let size=CGSize(width:ceil(boxes.map(\.maxX).max()!-minX),height:ceil(boxes.map(\.maxY).max()!-minY))
        transforms=transforms.map {PanoramaTransform.translation(CGPoint(x:-minX,y:-minY)).multiplied(by:$0)}
        let origins=transforms.map {$0.point(.zero)}
        guard size.width*size.height < 600_000_000 else { throw PanoramaFailure(L10n.tr("04fcf0f7a641")) }
        var plan = PanoramaPlan(sources:sources,origins:origins,size:size,registrationScores:scores,whiteBalance:wb,
                                gains:[Double](repeating:1,count:sources.count),ownership:[],maskWidth:0,maskHeight:0,
                                optical:OpticalEstimate(center:nil,confidence:0,explanation:L10n.tr("bef4c76fe825"),occludedEdges:[]),
                                options:options,previewScale:scale,previewImages:images,preview:nil)
        plan.registrationMode = registrationMode
        if projective {plan.warps=transforms}
        plan = try update(plan,options:options,cancellation:cancellation,progress:progress)
        return plan
    }

    public func update(_ original: PanoramaPlan, options: PanoramaOptions,
                       cancellation: PanoramaCancellation = .init(), progress: Progress = { _ in }) throws -> PanoramaPlan {
        guard original.isRegistered else {throw PanoramaFailure(L10n.tr("c31363b407bf"))}
        var plan = original; plan.options = options
        progress(L10n.tr("0c65de60079d"))
        try PanoramaSeams.prepare(&plan,context:context,cancellation:cancellation)
        try cancellation.check(); progress(L10n.tr("b087e27f78f6"))
        renderPreview(&plan)
        return plan
    }

    func renderPreview(_ plan:inout PanoramaPlan) {
        let scale=min(1,1800/max(plan.size.width,plan.size.height))
        // Highlight protection is a pixel-local shoulder in composite(), not an exposure chosen
        // from the brightest 0.5% of the scene. Bright windows must not darken the foreground.
        plan.lccState?.highlightEV=0
        let scene=composite(plan,images:plan.previewImages,imageScale:plan.previewScale,outputScale:scale)
        // Match the application's EDR surfaces: half-float, extended linear Display P3.
        // SDR projection belongs to the chosen export format, never to the working preview.
        plan.preview=context.createCGImage(scene,from:scene.extent,format:.RGBAh,
            colorSpace:CGColorSpace(name:CGColorSpace.extendedLinearDisplayP3)!)
    }

    /// Adjust cached preview pixels without decoding RAWs, rebuilding seams or solving LCC again.
    public func applyingTone(_ original: PanoramaPlan, settings: PanoramaToneSettings,
                             cancellation: PanoramaCancellation = .init()) throws -> PanoramaPlan {
        guard settings.isValid else { throw PanoramaFailure("Invalid panorama brightness settings.") }
        try cancellation.check()
        var plan = original; plan.tone = settings
        renderPreview(&plan)
        try cancellation.check()
        return plan
    }

    // Additional hue-preserving SDR shoulder for the legacy TIFF writer. Linear DNG retains
    // HDR headroom after the explicitly chosen panorama brightness adjustments.
    private static let highlightKernel=CIColorKernel(source:"""
        kernel vec4 protectHighlights(__sample s) {
            float peak=max(s.r,max(s.g,s.b));
            float excess=max(0.0,peak-0.9);
            float mapped=0.9+0.1*excess/(excess+0.1);
            float scale=peak>0.9 ? mapped/peak : 1.0;
            return vec4(s.rgb*scale,s.a);
        }
        """)!
    static func protectedDisplay(_ image:CIImage)->CIImage {
        highlightKernel.apply(extent:image.extent,arguments:[image])!
    }

    // Fractional resampling/RAW decode coverage can leave alpha below one, even inside a
    // photographic frame. Weighted contributions are premultiplied, so normalize by their
    // accumulated coverage before displaying or dropping alpha for an opaque format such as DNG.
    // A genuinely uncovered part of the canvas remains transparent black.
    private static let coverageKernel = CIColorKernel(source: """
        kernel vec4 normalizeCoverage(__sample s) {
            return s.a > 0.000001 ? vec4(s.rgb / s.a, 1.0) : vec4(0.0);
        }
        """)!
    static func normalizedCoverage(_ image: CIImage) -> CIImage {
        coverageKernel.apply(extent: image.extent,arguments: [image])!
    }

    func composite(_ plan: PanoramaPlan, images: [CIImage], imageScale: Double, outputScale: Double) -> CIImage {
        let bounds = CGRect(x:0,y:0,width:ceil(plan.size.width*outputScale),height:ceil(plan.size.height*outputScale))
        var result = CIImage(color:.clear).cropped(to:bounds)
        for i in images.indices {
            let hasWeights = plan.blendMasks.indices.contains(i)
            let data = hasWeights ? plan.blendMasks[i] : Data(plan.ownership.map { $0 == Int16(i) ? UInt8(255) : UInt8(0) })
            let mask = CIImage(bitmapData:data,bytesPerRow:plan.maskWidth * (hasWeights ? 4:1),
                               size:CGSize(width:plan.maskWidth,height:plan.maskHeight),format:hasWeights ? .Lf:.L8,colorSpace:nil)
                .transformed(by:CGAffineTransform(scaleX:plan.size.width*outputScale/Double(plan.maskWidth),
                                                  y:plan.size.height*outputScale/Double(plan.maskHeight)))
            let source=plan.photometricGains.indices.contains(i) ? applyGain(images[i],gain:plan.photometricGains[i],scale:imageScale):images[i]
            let placed:CIImage
            if let warps=plan.warps {
                let corners=warps[i].corners(plan.sources[i].size).map {CIVector(x:$0.x*outputScale,y:(plan.size.height-$0.y)*outputScale)}
                placed=source.applyingFilter("CIPerspectiveTransform",parameters:["inputTopLeft":corners[0],"inputTopRight":corners[1],"inputBottomRight":corners[2],"inputBottomLeft":corners[3]])
            } else {
                placed=source.transformed(by:CGAffineTransform(scaleX:outputScale/imageScale,y:outputScale/imageScale))
                    .transformed(by:CGAffineTransform(translationX:plan.origins[i].x*outputScale,
                                                      y:(plan.size.height-plan.origins[i].y-plan.sources[i].size.height)*outputScale))
            }
            let image=placed.applyingFilter("CIExposureAdjust",parameters:["inputEV":log2(plan.gains[i])])
            let weighted = image.clampedToExtent().applyingFilter("CIBlendWithMask",parameters:[
                "inputBackgroundImage":CIImage(color:.clear),"inputMaskImage":mask]).cropped(to:bounds)
            // The masks form a partition of unity. Add their premultiplied contributions;
            // repeated source-over would darken every interpolated seam (0.5 + 0.5*0.5 != 1).
            result = weighted.applyingFilter("CIAdditionCompositing",parameters:["inputBackgroundImage":result]).cropped(to:bounds)
        }
        if let lcc=plan.lccState,lcc.highlightEV+lcc.exposureEV != 0 {
            result=result.applyingFilter("CIExposureAdjust",parameters:["inputEV":lcc.highlightEV+lcc.exposureEV])
        }
        result = Self.normalizedCoverage(result)
        result = PanoramaToneMapping.image(result,settings: plan.tone,lccProtection: plan.lccState?.protectHighlights == true)
        if let crop=plan.lccState?.cropRect {
            let rect=CGRect(x:crop.minX*outputScale,y:(plan.size.height-crop.maxY)*outputScale,width:crop.width*outputScale,height:crop.height*outputScale)
            return result.cropped(to:rect).transformed(by:CGAffineTransform(translationX:-rect.minX,y:-rect.minY))
        }
        return result
    }

    /// Frozen registration, masks, LCC and exposure shared by native HDR export and DNG.
    /// The UI adapts these linear pixels to PhotonsExport; this module has no Core/UI dependency.
    public func renderComposite(_ plan: PanoramaPlan, cancellation: PanoramaCancellation = .init(),
                                outputLongEdge: Int? = nil,
                                progress: Progress = { _ in }) throws -> CIImage {
        guard plan.isRegistered else {throw PanoramaFailure(L10n.tr("57119ed82d7a"))}
        guard plan.tone.isValid else { throw PanoramaFailure("Invalid panorama brightness settings.") }
        if let edge = outputLongEdge, edge <= 0 { throw PanoramaFailure("Output long edge must be positive.") }
        let scale = outputLongEdge.map { min(1, Double($0) / max(plan.outputSize.width, plan.outputSize.height)) } ?? 1
        // Materialize one decode per source, rather than re-decoding a 100 MP RAW for every tile.
        // Half-float storage is 8 bytes/pixel; enforce a memory bound before starting the job.
        let bytes = plan.sources.reduce(0.0) { $0+$1.size.width*$1.size.height*scale*scale*8 }
        guard bytes < Double(ProcessInfo.processInfo.physicalMemory)*0.45 else {
            throw PanoramaFailure(L10n.tr("c732647ded62"))
        }
        var images: [CIImage] = []
        for (i,source) in plan.sources.enumerated() {
            try cancellation.check(); progress(L10n.tr("dcc5db9b7e00" , String(describing: (i+1)), String(describing: (plan.sources.count))))
            if let lcc=plan.lccState,lcc.usesFixedDecode[i] {
                if lcc.cameraGains.indices.contains(i),let map=lcc.cameraGains[i] {
                    let raw=try LCCCameraPipeline.read(source)
                    images.append(try materialize(LCCCameraPipeline.develop(raw,gain:map,whiteBalance:lcc.whiteBalance,highlightNeutral:lcc.highlightNeutral,size:source.size,scale:scale,cancellation:cancellation)))
                } else {
                    let image=try LCCProfileBuilder.linearImage(source:source,scale:scale)
                    images.append(materialize(applyGain(image,gain:lcc.gainImages[i],scale:scale)))
                }
            } else {images.append(try materialize(decoded(source,scale:scale,whiteBalance:plan.whiteBalance)))}
        }
        try cancellation.check()
        return composite(plan,images:images,imageScale:scale,outputScale:scale)
    }

    public enum OutputFormat: String, CaseIterable { case dng, tiff }
    public func export(_ plan: PanoramaPlan, to destination: URL, format: OutputFormat,
                       cancellation: PanoramaCancellation = .init(), progress: Progress = { _ in }) throws {
        guard !plan.sources.contains(where: { $0.url.standardizedFileURL == destination.standardizedFileURL }) else {
            throw PanoramaFailure(L10n.tr("dfcc7af61de8"))
        }
        defer { context.clearCaches() }
        let scene = try renderComposite(plan,cancellation:cancellation,progress:progress)
        let manifest=PanoramaManifest(plan:plan)
        let temp = destination.deletingLastPathComponent().appendingPathComponent(".photons-\(UUID().uuidString).\(format.rawValue)")
        defer { try? FileManager.default.removeItem(at:temp) }
        if format == .dng {
            try LinearDNGWriter.write(image:scene,context:context,to:temp,manifest:try manifest.encoded(),cancellation:cancellation,progress:progress)
        } else {
            progress(L10n.tr("2c1ef19b2f8f"))
            let display=plan.lccState?.protectHighlights == true ? Self.protectedDisplay(scene):scene
            guard let cg = context.createCGImage(display,from:display.extent,format:.RGBA16,
                                                 colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!),
                  let destination = CGImageDestinationCreateWithURL(temp as CFURL,"public.tiff" as CFString,1,nil) else {
                throw PanoramaFailure(L10n.tr("b4cd18cf7cdc"))
            }
            CGImageDestinationAddImageAndMetadata(destination,cg,try manifest.metadata(),[kCGImagePropertyTIFFDictionary:[kCGImagePropertyTIFFCompression:5]] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw PanoramaFailure(L10n.tr("8f86e5986392")) }
        }
        try cancellation.check()
        if FileManager.default.fileExists(atPath:destination.path) {
            _ = try FileManager.default.replaceItemAt(destination,withItemAt:temp)
        } else { try FileManager.default.moveItem(at:temp,to:destination) }
    }
}
