import PhotonsLocalization
import Foundation
import CoreImage

/// Private, local IPC snapshot. Unlike the portable manifest this contains source URLs and
/// their identities. Export reuses registration and seams exactly; it never registers again.
public struct PanoramaSnapshot: Codable {
    struct Image: Codable {
        var size: CGSize
        var width: Int
        var height: Int
        var bytes: Data
        init(_ image: CIImage, width:Int,height:Int,context:CIContext) {
            size=image.extent.size;self.width=width;self.height=height
            var data=Data(count:width*height*16)
            let scaled=image.transformed(by:CGAffineTransform(scaleX:Double(width)/size.width,y:Double(height)/size.height))
            data.withUnsafeMutableBytes {context.render(scaled,toBitmap:$0.baseAddress!,rowBytes:width*16,
                bounds:CGRect(x:0,y:0,width:width,height:height),format:.RGBAf,colorSpace:PanoramaEngine.linearSpace)}
            bytes=data
        }
        func image() throws->CIImage {
            guard width>0,height>0,width<=512,height<=512,bytes.count==width*height*16 else {throw PanoramaFailure(L10n.tr("bd0936d0eb8b"))}
            return CIImage(bitmapData:bytes,bytesPerRow:width*16,size:CGSize(width:width,height:height),format:.RGBAf,colorSpace:PanoramaEngine.linearSpace)
                .transformed(by:CGAffineTransform(scaleX:size.width/Double(width),y:size.height/Double(height)))
        }
    }
    struct LCC: Codable {
        var profileID:UUID,profileName:String,offset:CGPoint,sensor:SensorSize
        var gains:[Image],fixed:[Bool],cameraGains:[LCCCameraGainMap?]
        var crop:CGRect?,whiteBalance:[Float]?,neutral:[Double]?
        var exposure:Double,highlight:Double,protect:Bool
        var body:PanoramaCameraBody?,orientation:PanoramaBodyOrientation
        init(_ state:PanoramaLCCState,context:CIContext) {
            profileID=state.profileID;profileName=state.profileName;offset=state.offsetMM;sensor=state.sensor
            gains=state.gainImages.map {Image($0,width:$0.extent.width >= $0.extent.height ? 384:288,
                height:$0.extent.width >= $0.extent.height ? 288:384,context:context)}
            fixed=state.usesFixedDecode;cameraGains=state.cameraGains;crop=state.cropRect
            whiteBalance=state.whiteBalance.map {[$0.0,$0.1]};neutral=state.highlightNeutral.map {[$0.x,$0.y,$0.z]}
            exposure=state.exposureEV;highlight=state.highlightEV;protect=state.protectHighlights
            body=state.cameraBody;orientation=state.bodyOrientation
        }
        func state() throws->PanoramaLCCState {
            var state=PanoramaLCCState(profileID:profileID,profileName:profileName,offsetMM:offset,gainImages:try gains.map {try $0.image()},
                usesFixedDecode:fixed,complete:true,coveredFraction:1,suggestedCropRect:nil,cropRect:crop,footprintRects:[],sensor:sensor,
                exposureEV:exposure,protectHighlights:protect,highlightEV:highlight,cameraBody:body,bodyOrientation:orientation)
            state.cameraGains=cameraGains
            if let w=whiteBalance,w.count==2 {state.whiteBalance=(w[0],w[1])}
            if let n=neutral,n.count==3 {state.highlightNeutral=SIMD3(n[0],n[1],n[2])}
            return state
        }
    }
    var warps:[PanoramaTransform]?
    var tone: PanoramaToneSettings?
    var version=1
    var sources:[PanoramaSource],origins:[CGPoint],size:CGSize,whiteBalance:[Float]?
    var gains:[Double],ownership:[Int16],masks:[Data],maskWidth:Int,maskHeight:Int
    var photometry:[Image],options:PanoramaOptions,lcc:LCC?
    public init(plan:PanoramaPlan) throws {
        guard plan.isRegistered else {throw PanoramaFailure(L10n.tr("64a9879edbe2"))}
        let context=CIContext(options:[.workingColorSpace:PanoramaEngine.linearSpace,.cacheIntermediates:false])
        defer {context.clearCaches()}
        version=plan.warps == nil ? 1:2
        warps=plan.warps
        sources=plan.sources;origins=plan.origins;size=plan.size;whiteBalance=plan.whiteBalance.map {[$0.0,$0.1]}
        gains=plan.gains;ownership=plan.ownership;masks=plan.blendMasks;maskWidth=plan.maskWidth;maskHeight=plan.maskHeight
        photometry=plan.photometricGains.map {Image($0,width:64,height:64,context:context)}
        options=plan.options;lcc=plan.lccState.map {LCC($0,context:context)}
        tone = plan.tone
    }
    public func plan() throws->PanoramaPlan {
        guard tone?.isValid ?? true else { throw PanoramaFailure("Invalid panorama brightness settings.") }
        guard (version==1 && warps==nil || version==2 && warps != nil),(1...16).contains(sources.count),origins.count==sources.count,gains.count==sources.count,
              warps == nil || (warps!.count==sources.count && warps!.allSatisfy(\.isValid)),
              maskWidth>0,maskHeight>0,maskWidth<=8192,maskHeight<=8192,
              ownership.count==maskWidth*maskHeight,masks.isEmpty || (masks.count==sources.count && masks.allSatisfy({$0.count==maskWidth*maskHeight*4})),
              lcc == nil || (lcc!.gains.count==sources.count && lcc!.fixed.count==sources.count),
              size.width>0,size.height>0,size.width*size.height<600_000_000 else {throw PanoramaFailure(L10n.tr("6319cde4e732"))}
        for source in sources {try source.checkUnchanged()}
        let wb=whiteBalance.flatMap {$0.count==2 ? ($0[0],$0[1]):nil}
        var plan=PanoramaPlan(sources:sources,origins:origins,size:size,registrationScores:[],whiteBalance:wb,gains:gains,
            ownership:ownership,blendMasks:masks,photometricGains:try photometry.map {try $0.image()},maskWidth:maskWidth,maskHeight:maskHeight,
            optical:OpticalEstimate(center:nil,confidence:0,explanation:"",occludedEdges:[]),options:options,previewScale:1,previewImages:[],preview:nil)
        plan.tone=tone ?? .init();plan.warps=warps;plan.lccState=try lcc?.state();return plan
    }
    public var sourceURLs:[URL] {sources.map(\.url)}
}
