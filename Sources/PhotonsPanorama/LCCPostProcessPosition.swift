import Foundation
import CoreGraphics
import PhotonsLocalization

public extension PanoramaManifest {
    /// Physical center before any projective warp, relative to the uncropped canvas center.
    func relativePosition(of index:Int) -> CGPoint? {
        guard frames.indices.contains(index),let sensor=frames[index].sensor else {return nil}
        let r=frames[index].sensorRect ?? frames[index].rect
        guard r.width>0,r.height>0 else {return nil}
        return CGPoint(x:(r.midX-0.5)*sensor.width/r.width,y:(0.5-r.midY)*sensor.height/r.height)
    }
    func position(of index:Int,offset:CGPoint?) -> CGPoint? {
        guard let center=relativePosition(of:index) else {return nil}
        if let offset {return CGPoint(x:center.x-offset.x,y:center.y-offset.y)}
        return frames[index].shiftMM
    }
    func offset(reference index:Int,position:CGPoint) -> CGPoint? {
        relativePosition(of:index).map {CGPoint(x:$0.x-position.x,y:$0.y-position.y)}
    }
    /// Center of the visible exported picture, including crop and output transforms. Its
    /// physical position is distinct from the optical origin and from any source-frame center.
    func pictureCenter(offset:CGPoint = .zero) -> CGPoint? {
        guard let frame=frames.first,let sensor=frame.sensor else {return nil}
        let r=frame.sensorRect ?? frame.rect,p=canvasPoint(u:0.5,v:0.5)
        guard r.width>0,r.height>0,p.x.isFinite,p.y.isFinite else {return nil}
        return CGPoint(x:(p.x-0.5)*sensor.width/r.width-offset.x,
                       y:(0.5-p.y)*sensor.height/r.height-offset.y)
    }
    func offset(pictureCenter position:CGPoint) -> CGPoint? {
        pictureCenter().map {CGPoint(x:$0.x-position.x,y:$0.y-position.y)}
    }
    /// Exported pixels → original canvas is already stored; invert it to sample an old frame
    /// from the current exported copy, including crop/rotation/perspective and arbitrary resizing.
    func outputPoint(canvas point:CGPoint) -> CGPoint? {
        guard let inverse=PanoramaTransform(outputTransform ?? PanoramaTransform.identity.values).inverse else {return nil}
        let p=inverse.point(CGPoint(x:(point.x-crop.minX)/crop.width,y:(point.y-crop.minY)/crop.height))
        guard p.x.isFinite,p.y.isFinite,(0...1).contains(p.x),(0...1).contains(p.y) else {return nil}
        return p
    }
}

public extension LCCCorrectionEngine {
    internal static func postProcessField(frame:PanoramaManifest.Frame,profile:LCCLensProfile,
                                         fields:[LCCCaptureOrientation:LCCCorrectionField],body:PanoramaCameraBody,
                                         orientation:PanoramaBodyOrientation) throws -> LCCOrientedField {
        guard let placement=LCCProfileSummary(profile).placement(camera:frame.camera,exifOrientation:frame.orientation,
            sensor:frame.sensor,cameraBody:body,bodyOrientation:orientation),let field=fields[placement.variant.orientation] else {
            throw PanoramaFailure(L10n.tr("f397a44809b0"))
        }
        return LCCOrientedField(field:field,bodyOrientation:placement.bodyOrientation)
    }
    /// Resolve optical position independently of whether LCC was applied before export. Reuse
    /// recorded positions first; otherwise sample the rendered panorama through its saved source
    /// geometry and use the same profile/scene search as the stitching workspace. Original RAWs
    /// are not required, and rendered RGB samples are never compared to camera-CFA calibrations.
    static func resolvePostProcessPosition(scene:PanoramaSource,manifest:PanoramaManifest,profile:LCCLensProfile,
                                          cameraBody:PanoramaCameraBody = .alpa12Max,
                                          cancellation:PanoramaCancellation = .init(),
                                          progress:PanoramaEngine.Progress = {_ in}) throws -> LCCPositionSolution {
        try manifest.validate()
        guard manifest.registrationMode != .perspective else { throw PanoramaFailure(PanoramaRegistrationMode.perspectiveLCCNotice) }
        guard manifest.geometryUnrecoverable != true else {throw PanoramaFailure(L10n.tr("fc7ac1c0b0ab"))}
        if let offset=manifest.profileOffsetMM,offset.x.isFinite,offset.y.isFinite {
            return .init(offsetMM:offset,explanation:L10n.tr("lcc.position.recorded"),flatCount:0)
        }
        let recorded=manifest.frames.indices.compactMap {i -> CGPoint? in
            guard let shift=manifest.frames[i].shiftMM,shift.x.isFinite,shift.y.isFinite else {return nil}
            return manifest.offset(reference:i,position:shift)
        }
        if let first=recorded.first {
            guard recorded.allSatisfy({hypot($0.x-first.x,$0.y-first.y)<0.1}) else {throw PanoramaFailure(L10n.tr("lcc.position.inconsistent"))}
            return .init(offsetMM:first,explanation:L10n.tr("lcc.position.recorded"),flatCount:0)
        }
        var rendered=profile
        rendered.captures=try profile.captures.map {capture in
            var copy=capture
            guard let grid=capture.renderGrid else {throw PanoramaFailure(L10n.tr("630c0e121a40"))}
            copy.grid=grid;return copy
        }
        let fields=try fields(rendered,cancellation:cancellation),body=manifest.cameraBody ?? cameraBody
        let centers=manifest.frames.indices.compactMap {manifest.relativePosition(of:$0)}
        guard centers.count==manifest.frames.count,
              let bounds=body.travel(at:manifest.bodyOrientation).opticalOriginBounds(centers:centers) else {
            throw PanoramaFailure(L10n.tr("lcc.position.geometry"))
        }
        let engine=PanoramaEngine(),plan=try engine.singlePhoto(scene,cancellation:cancellation)
        let image=plan.previewImages[0],scale=512/max(scene.size.width,scene.size.height)
        let raster=PanoramaRaster(image:image,context:engine.context,width:max(2,Int(scene.size.width*scale)),height:max(2,Int(scene.size.height*scale)))
        var observations:[LCCPositionSolver.Observation]=[]
        var calibrations:[LCCOrientedField]=[]
        for (i,frame) in manifest.frames.enumerated() {
            try cancellation.check()
            guard let sensor=frame.sensor else {throw PanoramaFailure(L10n.tr("lcc.position.geometry"))}
            let field=try postProcessField(frame:frame,profile:rendered,fields:fields,body:body,orientation:manifest.bodyOrientation)
            calibrations.append(field)
            for y in 2..<34 {for x in 2..<46 {
                let u=Double(x)/48,v=Double(y)/36
                let point=frame.imageToCanvas?.point(CGPoint(x:u,y:v)) ?? CGPoint(x:frame.rect.minX+u*frame.rect.width,y:frame.rect.minY+v*frame.rect.height)
                guard (0...1).contains(point.x),(0...1).contains(point.y),let uv=manifest.outputPoint(canvas:point) else {continue}
                let mx=min(manifest.maskWidth-1,Int(point.x*Double(manifest.maskWidth)))
                let my=min(manifest.maskHeight-1,Int(point.y*Double(manifest.maskHeight)))
                // A blended pixel cannot be treated as an independent sample from every source.
                guard manifest.weights[i][my*manifest.maskWidth+mx]>=230,
                      let rgb=raster.rgb(uv.x*Double(raster.width-1),uv.y*Double(raster.height-1)),
                      min(rgb.x,rgb.y,rgb.z)>0.00005 else {continue}
                let physical=CGPoint(x:centers[i].x+(u-0.5)*sensor.width,y:centers[i].y+(0.5-v)*sensor.height)
                let compensation=manifest.photometricFields?[i].gain(at:CGPoint(x:u,y:v)) ?? SIMD3(repeating:1)
                let originalRGB=rgb/compensation
                observations.append(.init(frame:i,point:physical,logRGB:SIMD3(log(originalRGB.x),log(originalRGB.y),log(originalRGB.z)),field:field))
            }}
        }
        guard observations.count>100 else {throw PanoramaFailure(L10n.tr("fb4baac95a8f"))}
        // Scene color alone can prefer an origin outside the measured lens atlas. Enforce
        // coverage of the actual exported pixels as well, not just the interior fit samples.
        // Sample a bounded 256-pixel long edge; frame/crop transforms remain normalized.
        let coverageScale=256/max(scene.size.width,scene.size.height)
        let cw=max(2,Int(scene.size.width*coverageScale)),ch=max(2,Int(scene.size.height*coverageScale))
        var coverage:[(point:CGPoint,frame:Int)]=[]
        for y in 0..<ch {
            try cancellation.check()
            for x in 0..<cw {
                let p=manifest.canvasPoint(u:(Double(x)+0.5)/Double(cw),v:(Double(y)+0.5)/Double(ch))
                guard p.x.isFinite,p.y.isFinite,(0...1).contains(p.x),(0...1).contains(p.y) else {continue}
                let mx=min(manifest.maskWidth-1,Int(p.x*Double(manifest.maskWidth)))
                let my=min(manifest.maskHeight-1,Int(p.y*Double(manifest.maskHeight)))
                for (i,frame) in manifest.frames.enumerated() where manifest.weights[i][my*manifest.maskWidth+mx]>0 {
                    let sensor=frame.sensor!,r=frame.sensorRect ?? frame.rect
                    let local=frame.imageToCanvas?.inverse?.point(p) ?? CGPoint(x:(p.x-r.minX)/r.width,y:(p.y-r.minY)/r.height)
                    let point=CGPoint(x:centers[i].x+(local.x-0.5)*sensor.width,y:centers[i].y+(0.5-local.y)*sensor.height)
                    coverage.append((point,i))
                }
            }
        }
        guard !coverage.isEmpty else {throw PanoramaFailure(L10n.tr("lcc.position.geometry"))}
        progress(L10n.tr("2fdf398a243c"))
        let result=try LCCPositionSolver.search(observations:observations,xRange:bounds.minX...bounds.maxX,yRange:bounds.minY...bounds.maxY,flat:false,cancellation:cancellation) {offset in
            var missing=0
            for sample in coverage where !calibrations[sample.frame].region.contains(CGPoint(x:sample.point.x-offset.x,y:sample.point.y-offset.y)) {
                missing += 1
                if Double(missing)>Double(coverage.count)*0.005 {return false}
            }
            return true
        }
        return .init(offsetMM:result.point,explanation:L10n.tr("lcc.position.estimated"),flatCount:0,residual:result.error,requiresManualSeed:false)
    }
}
