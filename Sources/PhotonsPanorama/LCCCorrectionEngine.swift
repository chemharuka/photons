import PhotonsLocalization
import Foundation
import CoreImage

/// Both standalone correction modes share the panorama's RAW calibration pipeline.
public enum LCCCorrectionEngine {
    public static func traditional(scene:PanoramaSource,flatURL:URL,cancellation:PanoramaCancellation = .init(),
                                   progress:PanoramaEngine.Progress = {_ in}) throws->PanoramaPlan {
        let flat=try PanoramaSource(url:flatURL)
        if let issue=LCCInspector.incompatibility(scene:scene,flat:flat) {throw PanoramaFailure(issue)}
        guard let sensor=scene.sensor else {throw PanoramaFailure(L10n.tr("a56bfaee063f"))}
        var frame=try LCCCreationFrame(url:flatURL);frame.shiftX=0;frame.shiftY=0;frame.shiftConfirmed=true
        let profile=try LCCProfileBuilder.create(name:"LCC · "+flatURL.lastPathComponent,aperture:nil,notes:"Strict one-to-one flat-field correction",frames:[frame],
            sensorLongEdge:max(sensor.width,sensor.height),sensorShortEdge:min(sensor.width,sensor.height),cancellation:cancellation,progress:progress)
        return try single(scene:scene,profile:profile,position:.zero,refine:false,cancellation:cancellation,progress:progress).plan
    }
    public static func fields(_ profile:LCCLensProfile,cancellation:PanoramaCancellation = .init()) throws->[LCCCaptureOrientation:LCCCorrectionField] {
        var fields:[LCCCaptureOrientation:LCCCorrectionField]=[:]
        for orientation in profile.orientations {fields[orientation]=try LCCCorrectionField(profile:profile,orientation:orientation,cancellation:cancellation)}
        return fields
    }
    public static func single(scene:PanoramaSource,profile:LCCLensProfile,position:CGPoint? = nil,refine:Bool,
                              body:PanoramaCameraBody = .alpa12Max,orientation:PanoramaBodyOrientation = .degrees0,
                              cancellation:PanoramaCancellation = .init(),progress:PanoramaEngine.Progress = {_ in}) throws->(plan:PanoramaPlan,position:CGPoint) {
        guard let sensor=scene.sensor else {throw PanoramaFailure(L10n.tr("2b2e356aa95e"))}
        guard position.map({$0.x.isFinite && $0.y.isFinite}) ?? true else {throw PanoramaFailure(L10n.tr("9d273dbe67b9"))}
        let engine=PanoramaEngine(),fields=try fields(profile,cancellation:cancellation)
        let plan=try engine.prepareLCCImages(engine.singlePhoto(scene,cancellation:cancellation),cancellation:cancellation,progress:progress)
        var offset=position.map {CGPoint(x:-$0.x,y:-$0.y)} ?? .zero
        if refine || position == nil {
            offset=try LCCPositionSolver.solve(plan:plan,fields:fields,sensor:sensor,cameraBody:body,bodyOrientation:orientation,
                approximateOffset:position == nil ? nil:offset,searchRadius:3,cancellation:cancellation,progress:progress).offsetMM
        }
        let corrected=try engine.applyingLCC(plan,profile:profile,fields:fields,offsetMM:offset,sensor:sensor,crop:false,
            cancellation:cancellation,rebuildSeams:false,protectHighlights:false,whiteBalanceOverride:plan.whiteBalance,cameraBody:body,bodyOrientation:orientation)
        return (corrected,CGPoint(x:-offset.x,y:-offset.y))
    }
    /// Rendered images have lost their original camera channels. Use measured rendered-RGB
    /// fields, never misinterpret a CFA map as an RGB map. Recorded blend weights handle mixed
    /// orientations; normalized canvas/crop coordinates survive output resizing.
    public static func postProcess(scene:PanoramaSource,manifest original:PanoramaManifest,profile:LCCLensProfile,
                                   offset:CGPoint? = nil,cameraBody:PanoramaCameraBody = .alpa12Max,cancellation:PanoramaCancellation = .init(),
                                   progress:PanoramaEngine.Progress = {_ in}) throws->(plan:PanoramaPlan,manifest:PanoramaManifest) {
        try original.validate()
        guard original.registrationMode != .perspective else { throw PanoramaFailure(PanoramaRegistrationMode.perspectiveLCCNotice) }
        guard original.geometryUnrecoverable != true else {throw PanoramaFailure(L10n.tr("fc7ac1c0b0ab"))}
        guard !original.correctionApplied else {throw PanoramaFailure(L10n.tr("edbde7a1e03c"))}
        var rendered=profile
        rendered.captures=try profile.captures.map { capture in
            var c=capture
            guard let grid=c.renderGrid else {throw PanoramaFailure(L10n.tr("630c0e121a40"))}
            c.grid=grid;return c
        }
        let fields=try fields(rendered,cancellation:cancellation),engine=PanoramaEngine()
        var plan=try engine.singlePhoto(scene,cancellation:cancellation)
        let w=512,h=max(2,Int(512*scene.size.height/scene.size.width))
        guard h<=2048 else {throw PanoramaFailure(L10n.tr("759292c5a6ab"))}
        let chosenOffset=try offset ?? resolvePostProcessPosition(scene:scene,manifest:original,profile:profile,
            cameraBody:cameraBody,cancellation:cancellation,progress:progress).offsetMM
        guard chosenOffset.x.isFinite,chosenOffset.y.isFinite else {throw PanoramaFailure(L10n.tr("9d273dbe67b9"))}
        let calibrations=try original.frames.map {frame -> LCCOrientedField in
            try postProcessField(frame:frame,profile:rendered,fields:fields,body:original.cameraBody ?? cameraBody,orientation:original.bodyOrientation)
        }
        var values=[Float](repeating:1,count:w*h*4),uncovered=0,contributingPixels=0
        for y in 0..<h {
            try cancellation.check();if y%32==0 {progress(L10n.tr("f8cd32a1d0e0" , String(describing: (y)), String(describing: (h))))}
            for x in 0..<w {
                let point=original.canvasPoint(u:(Double(x)+0.5)/Double(w),v:(Double(y)+0.5)/Double(h))
                guard point.x.isFinite,point.y.isFinite,(0...1).contains(point.x),(0...1).contains(point.y) else {continue}
                let mx=min(original.maskWidth-1,max(0,Int(point.x*Double(original.maskWidth))))
                let my=min(original.maskHeight-1,max(0,Int(point.y*Double(original.maskHeight))))
                var response=SIMD3<Double>.zero,total=0.0,sourceWeight=0.0,missing=false
                for (i,frame) in original.frames.enumerated() {
                    let weight=Double(original.weights[i][my*original.maskWidth+mx])/255
                    guard weight>0.001 else {continue}
                    sourceWeight += weight
                    guard let sensor=frame.sensor else {throw PanoramaFailure(L10n.tr("e184fba3ced0"))}
                    let rect=frame.sensorRect ?? frame.rect
                    let local=frame.imageToCanvas?.inverse?.point(point) ?? CGPoint(x:(point.x-rect.minX)/rect.width,y:(point.y-rect.minY)/rect.height)
                    let unwarped=CGPoint(x:rect.minX+local.x*rect.width,y:rect.minY+local.y*rect.height)
                    let physical:CGPoint
                    physical=CGPoint(x:(unwarped.x-0.5)*sensor.width/rect.width-chosenOffset.x,
                                     y:(0.5-unwarped.y)*sensor.height/rect.height-chosenOffset.y)
                    if let g=calibrations[i].gain(at:physical) {
                        let exposureWeight=weight*(original.exposureGains?[i] ?? 1)
                        let photometry=original.photometricFields?[i].gain(at:local) ?? SIMD3(repeating:1)
                        // A blended pixel contains weighted *responses*, not weighted correction
                        // gains: C = S Σ(w e p / g). Remove shading and baked-in RGB photometry
                        // while retaining the recorded exposure: C' = S Σ(w e).
                        response += photometry/g*exposureWeight;total += exposureWeight
                    }
                    else {missing=true}
                }
                // Warped panoramas have empty canvas corners. Those pixels do not need a lens
                // calibration, and must not count as missing measured profile coverage.
                guard sourceWeight>0.001 else {continue}
                contributingPixels += 1
                if total>0 && !missing {
                    let gain=SIMD3(repeating:total)/response,o=(y*w+x)*4
                    values[o]=Float(gain.x);values[o+1]=Float(gain.y);values[o+2]=Float(gain.z)
                } else {uncovered += 1}
            }
        }
        guard contributingPixels>0,Double(uncovered)<Double(contributingPixels)*0.01 else {throw PanoramaFailure(L10n.tr("511abfcff05c"))}
        let image=CIImage(bitmapData:values.withUnsafeBytes {Data($0)},bytesPerRow:w*16,size:CGSize(width:w,height:h),format:.RGBAf,colorSpace:PanoramaEngine.linearSpace)
            .transformed(by:CGAffineTransform(scaleX:scene.size.width/Double(w),y:scene.size.height/Double(h)))
        let sensor=original.frames.first!.sensor!
        plan.lccState=PanoramaLCCState(profileID:profile.id,profileName:profile.name,offsetMM:chosenOffset,
            gainImages:[image],usesFixedDecode:[true],complete:true,coveredFraction:1,suggestedCropRect:nil,cropRect:nil,footprintRects:[],sensor:sensor,
            exposureEV:0,protectHighlights:false)
        plan.previewImages=[engine.applyGain(plan.previewImages[0],gain:image,scale:plan.previewScale)]
        engine.renderPreview(&plan)
        var manifest=original;manifest.profileID=profile.id;manifest.profileName=profile.name
        manifest.cameraBody=original.cameraBody ?? cameraBody
        manifest.profileOffsetMM=chosenOffset;manifest.correctionApplied=true;manifest.correctionMethod="rendered-rgb-post-correction"
        return (plan,manifest)
    }
}
