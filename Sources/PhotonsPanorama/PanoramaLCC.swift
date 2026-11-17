import PhotonsLocalization
import Foundation
import PhotonsFileAccess
import CoreImage
import PhotonsExtensions

/// Exact union coverage, including holes. A bounding box alone is not evidence of calibration.
public struct LCCCoverageRegion {
    public let rectangles:[CGRect]
    private struct Slab { var left:CGFloat;var right:CGFloat;var intervals:[ClosedRange<CGFloat>] }
    private let slabs:[Slab]
    public init(_ rectangles:[CGRect]) {
        self.rectangles=rectangles.filter {!$0.isEmpty && !$0.isNull}
        let xs=Array(Set(self.rectangles.flatMap {[$0.minX,$0.maxX]})).sorted()
        var result:[Slab]=[]
        for (left,right) in zip(xs,xs.dropFirst()) where right>left {
            let mid=(left+right)/2
            let ranges=self.rectangles.filter {$0.minX<=mid && $0.maxX>=mid}.map {$0.minY...$0.maxY}.sorted {$0.lowerBound<$1.lowerBound}
            var merged:[ClosedRange<CGFloat>]=[]
            for r in ranges {
                if let last=merged.last,r.lowerBound<=last.upperBound+1e-8 {merged[merged.count-1]=last.lowerBound...max(last.upperBound,r.upperBound)}
                else {merged.append(r)}
            }
            if let last=result.last,last.right==left,last.intervals==merged {result[result.count-1].right=right}
            else {result.append(Slab(left:left,right:right,intervals:merged))}
        }
        slabs=result
    }
    public func contains(_ point:CGPoint)->Bool {
        slabs.contains {$0.left<=point.x && $0.right>=point.x && $0.intervals.contains {$0.contains(point.y)}}
    }
    public func covers(_ query:CGRect)->Bool {
        guard !query.isEmpty else {return false}
        var end=query.minX
        for s in slabs where s.right>end && s.left<query.maxX {
            guard s.left<=end+1e-8,s.intervals.contains(where:{$0.lowerBound<=query.minY+1e-8 && $0.upperBound>=query.maxY-1e-8}) else {return false}
            end=s.right;if end>=query.maxX-1e-8 {return true}
        }
        return false
    }
    /// Largest fully-covered axis-aligned rectangle in a conservative cell mask.
    public static func largestRectangle(_ mask:[Bool],width:Int,height:Int)->CGRect? {
        guard width>0,height>0,mask.count==width*height else {return nil}
        var heights=[Int](repeating:0,count:width),best=CGRect.zero,bestArea=0
        for y in 0..<height {
            for x in 0..<width {heights[x]=mask[y*width+x] ? heights[x]+1:0}
            var stack:[Int]=[]
            for x in 0...width {
                let h=x==width ? 0:heights[x]
                while let top=stack.last,heights[top]>h {
                    _=stack.popLast();let left=(stack.last ?? -1)+1,area=heights[top]*(x-left)
                    if area>bestArea {bestArea=area;best=CGRect(x:left,y:y-heights[top]+1,width:x-left,height:heights[top])}
                }
                stack.append(x)
            }
        }
        return bestArea>0 ? best:nil
    }
}

private struct LCCSampler {
    let capture:LCCProfileCapture
    let grid:LCCMeasurementGrid
    let values:[Float]
    init?(_ capture:LCCProfileCapture) {
        let g=capture.grid
        self.capture=capture;grid=g;values=g.floats
    }
    func rgb(_ p:CGPoint)->SIMD4<Double>? {
        guard capture.fieldRect.contains(p) else {return nil}
        let x=p.x-capture.shiftX,y=p.y-capture.shiftY
        func bracket(_ values:[Double],_ p:Double,descending:Bool)->(Int,Double) {
            let sign=descending ? -1.0:1.0,v=p*sign
            var lo=0,hi=values.count-1
            while hi-lo>1 {let m=(lo+hi)/2;if values[m]*sign<=v {lo=m}else{hi=m}}
            let f=(p-values[lo])/(values[hi]-values[lo]);return (lo,min(1,max(0,f)))
        }
        let (ix,fx)=bracket(grid.x,x,descending:false),(iy,fy)=bracket(grid.y,y,descending:true)
        func at(_ x:Int,_ y:Int)->SIMD4<Double> {
            let n=grid.channels.count,i=(y*grid.width+x)*n
            // v1 built-in measurements subtracted LibRaw's 4094 DN; the file's black tag is
            // 4096. Match the native reader, including low-signal corners, without a tint offset.
            let black=grid.space=="camera-cfa-black-subtracted-v1" ? 2.0:0
            return SIMD4(Double(values[i])-black,Double(values[i+1])-black,Double(values[i+2])-black,Double(values[i+(n==4 ? 3:1)])-black)
        }
        return (at(ix,iy)*(1-fx)+at(ix+1,iy)*fx)*(1-fy)+(at(ix,iy+1)*(1-fx)+at(ix+1,iy+1)*fx)*fy
    }
    func weight(_ p:CGPoint)->Double {
        let r=capture.fieldRect
        // A measurement enters/leaves the atlas continuously. Equal-weight medians jump
        // whenever the set of overlapping captures changes, especially in green/luminance.
        let d=max(0,min(p.x-r.minX,r.maxX-p.x,p.y-r.minY,r.maxY-p.y))
        let t=min(1,d/4)
        return max(1e-12,t*t*(3-2*t))
    }
}

public final class LCCCorrectionField {
    public let orientation:LCCCaptureOrientation
    public let isCameraSpace:Bool
    public let region:LCCCoverageRegion
    public let bounds:CGRect
    private let samplers:[LCCSampler]
    private let width:Int,height:Int
    private var values:[SIMD4<Double>]=[]
    private var reference=SIMD4<Double>(repeating:1)
    public init(profile:LCCLensProfile,orientation:LCCCaptureOrientation,cancellation:PanoramaCancellation = .init()) throws {
        self.orientation=orientation;isCameraSpace=profile.captures(for:orientation).allSatisfy {$0.grid.space.hasPrefix("camera-cfa-")};samplers=profile.captures(for:orientation).compactMap(LCCSampler.init)
        guard !samplers.isEmpty else {throw PanoramaFailure(L10n.tr("da5dd0a43564" , String(describing: (orientation.title))))}
        region=LCCCoverageRegion(samplers.map {$0.capture.fieldRect});bounds=region.rectangles.reduce(.null) {$0.union($1)}
        width=max(2,min(512,Int(ceil(bounds.width/0.5))));height=max(2,min(512,Int(ceil(bounds.height/0.5))))
        for y in 0..<height {
            try cancellation.check()
            for x in 0..<width {
                let p=CGPoint(x:bounds.minX+(Double(x)+0.5)/Double(width)*bounds.width,
                              y:bounds.maxY-(Double(y)+0.5)/Double(height)*bounds.height)
                values.append(exact(p) ?? SIMD4(repeating:.nan))
            }
        }
        // Smooth the measured log field, not the photograph. No brightness threshold is
        // used: illuminated dark corners remain measurements and retain their coverage.
        let original=values
        let radius=3,sigma=1.5
        for y in 0..<height {
            try cancellation.check()
            for x in 0..<width where original[y*width+x].x.isFinite {
                var sum=SIMD4<Double>.zero,total=0.0
                for dy in -radius...radius {for dx in -radius...radius {
                    let xx=x+dx,yy=y+dy
                    guard xx>=0,xx<width,yy>=0,yy<height else {continue}
                    let c=original[yy*width+xx]
                    guard c.x>0,c.y>0,c.z>0,c.w>0 else {continue}
                    let weight=exp(-Double(dx*dx+dy*dy)/(2*sigma*sigma))
                    sum += SIMD4(log(c.x),log(c.y),log(c.z),log(c.w))*weight;total += weight
                }}
                if total>0 {let v=sum/total;values[y*width+x]=SIMD4(exp(v.x),exp(v.y),exp(v.z),exp(v.w))}
            }
        }
        if let central=sample(.zero),central.x>0,central.y>0,central.z>0,central.w>0 {reference=central}
        else {
            // A partial profile need not include the optical axis. Normalize at its brightest
            // measured green cell without pretending the missing center was measured.
            guard let best=values.filter({$0.x>0 && $0.y>0 && $0.z>0 && $0.w>0}).max(by:{$0.y<$1.y}) else {
                throw PanoramaFailure(L10n.tr("8c2a5480489f"))
            };reference=best
        }
    }
    private func exact(_ p:CGPoint)->SIMD4<Double>? {
        var sum=SIMD4<Double>.zero,total=0.0
        for sampler in samplers {
            guard let c=sampler.rgb(p),c.x>0,c.y>0,c.z>0,c.w>0 else {continue}
            let w=sampler.weight(p);sum += SIMD4(log(c.x),log(c.y),log(c.z),log(c.w))*w;total += w
        }
        guard total>0 else {return nil};let v=sum/total
        return SIMD4(exp(v.x),exp(v.y),exp(v.z),exp(v.w))
    }
    private func sample(_ p:CGPoint)->SIMD4<Double>? {
        guard region.contains(p) else {return nil}
        let xx=min(Double(width-1),max(0,(p.x-bounds.minX)/bounds.width*Double(width)-0.5))
        let yy=min(Double(height-1),max(0,(bounds.maxY-p.y)/bounds.height*Double(height)-0.5))
        let x=min(width-2,Int(xx)),y=min(height-2,Int(yy)),fx=xx-Double(x),fy=yy-Double(y)
        let a=values[y*width+x],b=values[y*width+x+1],c=values[(y+1)*width+x],d=values[(y+1)*width+x+1]
        var rgb=(a*(1-fx)+b*fx)*(1-fy)+(c*(1-fx)+d*fx)*fy
        if !rgb.x.isFinite || !rgb.y.isFinite || !rgb.z.isFinite || !rgb.w.isFinite {guard let v=exact(p) else {return nil};rgb=v}
        guard rgb.x>0,rgb.y>0,rgb.z>0,rgb.w>0 else {return nil}
        return rgb
    }
    public func cameraGain(at p:CGPoint)->SIMD4<Double>? {
        guard let rgb=sample(p) else {return nil}
        return reference/rgb
    }
    public func gain(at p:CGPoint)->SIMD3<Double>? {
        guard let v=cameraGain(at:p) else {return nil}
        return SIMD3(v.x,(v.y+v.w)/2,v.z)
    }
}

/// A measured field stays in body coordinates. Rotate coordinates, never interpolate
/// or rewrite the saved calibration, when the camera is placed in another orientation.
struct LCCOrientedField {
    let field:LCCCorrectionField
    let bodyOrientation:PanoramaBodyOrientation
    let region:LCCCoverageRegion
    init(field:LCCCorrectionField,bodyOrientation:PanoramaBodyOrientation) {
        self.field=field;self.bodyOrientation=bodyOrientation
        region=LCCCoverageRegion(field.region.rectangles.map {bodyOrientation.rotate($0)})
    }
    var isCameraSpace:Bool {field.isCameraSpace}
    func gain(at point:CGPoint)->SIMD3<Double>? {field.gain(at:bodyOrientation.inverse.rotate(point))}
}

public struct PanoramaLCCState {
    public var profileID:UUID
    public var profileName:String
    /// Optical/profile origin relative to the panorama center, right/up positive, in mm.
    public var offsetMM:CGPoint
    public var gainImages:[CIImage]
    public var usesFixedDecode:[Bool]
    public var complete:Bool
    public var coveredFraction:Double
    public var suggestedCropRect:CGRect?
    public var cropRect:CGRect?
    public var footprintRects:[CGRect]
    public var sensor:SensorSize
    public var exposureEV:Double
    public var cameraGains:[LCCCameraGainMap?] = []
    public var whiteBalance:(Float,Float)? = nil
    public var whiteBalanceSource:String = ""
    public var whiteBalanceWasManual=false
    public var highlightNeutral:SIMD3<Double>? = nil
    public var protectHighlights:Bool
    public var highlightEV:Double = 0
    public var cameraBody:PanoramaCameraBody? = nil
    public var bodyOrientation:PanoramaBodyOrientation = .degrees0
    public var warning:String? {
        complete ? nil:String(format:L10n.tr("39cf8921084d"),coveredFraction*100)
    }
}

extension PanoramaEngine {
    public func prepareLCCImages(_ original:PanoramaPlan,cancellation:PanoramaCancellation = .init(),progress:Progress = {_ in}) throws -> PanoramaPlan {
        var plan=original
        if plan.originalPreviewImages==nil {plan.originalPreviewImages=plan.previewImages}
        if plan.lccLinearPreviewImages==nil {
            var images:[CIImage]=[],raws:[CameraMosaic?]=[],flats:[CameraMosaic?]=[]
            let records=LCCPairingStore().records()
            for (i,source) in plan.sources.enumerated() {
                try cancellation.check();progress(L10n.tr("6267568b6d4b" , String(describing: (i+1)), String(describing: (plan.sources.count))))
                if ["3fr","dng"].contains(source.url.pathExtension.lowercased()) {
                    let raw=try LCCCameraPipeline.read(source,maxDimension:2048)
                    raws.append(raw);images.append(LCCCameraPipeline.cameraImage(raw))
                    if let pair=records.first(where:{$0.scene==source.url.standardizedFileURL}) {
                        let flatAccess=FileAccessStore.shared.access(to:pair.flat)
                        defer {withExtendedLifetime(flatAccess) {}}
                        let flat=try PanoramaSource(url:flatAccess.url)
                        guard LCCInspector.incompatibility(scene:source,flat:flat)==nil else {throw PanoramaFailure(L10n.tr("ee285a263f1c"))}
                        flats.append(try LCCCameraPipeline.read(flat,maxDimension:512))
                    } else {flats.append(nil)}
                } else {
                    raws.append(nil);flats.append(nil)
                    images.append(try materialize(LCCProfileBuilder.linearImage(source:source,scale:plan.previewScale)))
                }
            }
            plan.lccLinearPreviewImages=images;plan.lccRawPreviews=raws;plan.lccFlatPreviews=flats
        }
        return plan
    }
    public func removingLCC(_ original:PanoramaPlan,cancellation:PanoramaCancellation = .init()) throws -> PanoramaPlan {
        var plan=original;plan.lccState=nil;plan.previewImages=plan.originalPreviewImages ?? plan.previewImages
        return try update(plan,options:plan.options,cancellation:cancellation)
    }
    public func applyingLCC(_ original:PanoramaPlan,profile:LCCLensProfile,fields:[LCCCaptureOrientation:LCCCorrectionField],
                           offsetMM:CGPoint,sensor:SensorSize,crop:Bool,cancellation:PanoramaCancellation = .init(),
                           rebuildSeams:Bool=true,exposureEV:Double=0,protectHighlights:Bool=true,whiteBalanceOverride:(Float,Float)?=nil,
                           cameraBody:PanoramaCameraBody?=nil,bodyOrientation:PanoramaBodyOrientation = .degrees0) throws -> PanoramaPlan {
        guard original.registrationMode != .perspective else { throw PanoramaFailure(PanoramaRegistrationMode.perspectiveLCCNotice) }
        guard offsetMM.x.isFinite,offsetMM.y.isFinite,sensor.width>0,sensor.height>0 else {throw PanoramaFailure(L10n.tr("ff85097641dd"))}
        guard exposureEV.isFinite,(-8...8).contains(exposureEV) else {throw PanoramaFailure(L10n.tr("0d2075dd3f5d"))}
        if let wb=whiteBalanceOverride {
            guard wb.0.isFinite,wb.1.isFinite,(2000...50000).contains(wb.0),(-150...150).contains(wb.1) else {throw PanoramaFailure(L10n.tr("cdd222f5e634"))}
        }
        var plan=original
        let summary=LCCProfileSummary(profile),sw=plan.sources[0].size.width,sh=plan.sources[0].size.height
        let mx=sensor.width/sw,my=sensor.height/sh
        let matches=plan.sources.map { source -> LCCOrientedField? in
            guard let match=summary.placement(camera:source.camera,exifOrientation:source.orientation,sensor:source.sensor ?? sensor,
                cameraBody:cameraBody,bodyOrientation:bodyOrientation),let field=fields[match.variant.orientation] else {return nil}
            return LCCOrientedField(field:field,bodyOrientation:match.bodyOrientation)
        }
        func fieldPoint(_ p:CGPoint)->CGPoint {CGPoint(x:(p.x-plan.size.width/2)*mx-offsetMM.x,y:(plan.size.height/2-p.y)*my-offsetMM.y)}
        var gainImages:[CIImage]=[]
        for i in plan.sources.indices {
            try cancellation.check()
            let w=Int(sw>=sh ? 384:288),h=Int(sw>=sh ? 288:384)
            var pixels=[Float](repeating:1,count:w*h*4)
            if let field=matches[i] {
                for y in 0..<h {
                    if y%16==0 {try cancellation.check()}
                    for x in 0..<w {
                        let p=CGPoint(x:plan.origins[i].x+(Double(x)+0.5)/Double(w)*sw,y:plan.origins[i].y+(Double(y)+0.5)/Double(h)*sh)
                        if let gain=field.gain(at:fieldPoint(p)) {
                            let j=(y*w+x)*4;pixels[j]=Float(gain.x);pixels[j+1]=Float(gain.y);pixels[j+2]=Float(gain.z)
                        }
                    }
                }
            }
            let data=pixels.withUnsafeBytes {Data($0)}
            gainImages.append(CIImage(bitmapData:data,bytesPerRow:w*16,size:CGSize(width:w,height:h),format:.RGBAf,colorSpace:Self.linearSpace)
                .transformed(by:CGAffineTransform(scaleX:sw/Double(w),y:sh/Double(h))))
        }
        let gridScale=min(1,400/max(plan.size.width,plan.size.height)),cw=max(1,Int(ceil(plan.size.width*gridScale))),ch=max(1,Int(ceil(plan.size.height*gridScale)))
        let dx=plan.size.width/Double(cw),dy=plan.size.height/Double(ch)
        let photos=LCCCoverageRegion(plan.sources.indices.map {plan.sourceRect($0)})
        var mask=[Bool](repeating:false,count:cw*ch),used=0,covered=0
        for y in 0..<ch {
            if y%16==0 {try cancellation.check()}
            for x in 0..<cw {
                let rect=CGRect(x:Double(x)*dx,y:Double(y)*dy,width:dx,height:dy)
                let relevant=plan.sources.indices.filter {plan.sourceRect($0).intersects(rect)}
                guard !relevant.isEmpty else {continue};used+=1
                let a=fieldPoint(CGPoint(x:rect.minX,y:rect.maxY)),b=fieldPoint(CGPoint(x:rect.maxX,y:rect.minY))
                let fieldRect=CGRect(x:a.x,y:a.y,width:b.x-a.x,height:b.y-a.y)
                let good=relevant.allSatisfy { i in
                    guard let field=matches[i],field.region.covers(fieldRect) else {return false}
                    return field.gain(at:CGPoint(x:fieldRect.midX,y:fieldRect.midY)) != nil
                }
                if good {covered+=1};mask[y*cw+x]=good && photos.covers(rect)
            }
        }
        let candidate=LCCCoverageRegion.largestRectangle(mask,width:cw,height:ch).flatMap { r -> CGRect? in
            // Leave half a gain-map texel at internal calibration boundaries. This prevents
            // interpolation with identity gains just outside coverage from leaking into the crop.
            let px=sw/(sw>=sh ? 384:288)/2,py=sh/(sw>=sh ? 288:384)/2
            let x=ceil(r.minX*dx+(r.minX>0 ? px:0)),y=ceil(r.minY*dy+(r.minY>0 ? py:0))
            let right=floor(r.maxX*dx-(r.maxX<Double(cw) ? px:0)),bottom=floor(r.maxY*dy-(r.maxY<Double(ch) ? py:0))
            return right>x && bottom>y ? CGRect(x:x,y:y,width:right-x,height:bottom-y):nil
        }
        if crop && candidate==nil {throw PanoramaFailure(L10n.tr("b3cde958b3bb"))}
        var footprints:[CGRect]=[]
        for field in matches.compactMap({$0}) {
            for r in field.region.rectangles {
                footprints.append(CGRect(x:plan.size.width/2+(r.minX+offsetMM.x)/mx,
                    y:plan.size.height/2-(r.maxY+offsetMM.y)/my,width:r.width/mx,height:r.height/my))
            }
        }
        plan.lccState=PanoramaLCCState(profileID:profile.id,profileName:profile.name,offsetMM:offsetMM,gainImages:gainImages,
            usesFixedDecode:matches.map {$0 != nil},complete:covered==used && used>0,coveredFraction:used>0 ? Double(covered)/Double(used):0,
            suggestedCropRect:candidate,cropRect:crop ? candidate:nil,footprintRects:footprints,sensor:sensor,
            exposureEV:exposureEV,protectHighlights:protectHighlights,cameraBody:cameraBody,bodyOrientation:bodyOrientation)
        let base=plan.lccLinearPreviewImages ?? plan.previewImages
        var cameraGains=[LCCCameraGainMap?](repeating:nil,count:plan.sources.count)
        var readings:[LCCWhiteBalanceReading]=[],flatReadings:[LCCWhiteBalanceReading]=[]
        for i in plan.sources.indices {
            guard let field=matches[i],field.isCameraSpace else {continue}
            guard let raw=plan.lccRawPreviews?[i] else {throw PanoramaFailure(L10n.tr("8c0a27d8b9db" , String(describing: (plan.sources[i].url.lastPathComponent))))}
            let map=LCCCameraGainMap(field:field.field,source:plan.sources[i],origin:plan.origins[i],panoramaSize:plan.size,sensor:sensor,offset:offsetMM,bodyOrientation:field.bodyOrientation)
            cameraGains[i]=map
            if let flat=plan.lccFlatPreviews?[i] {
                flatReadings.append(try LCCCameraPipeline.whiteBalance(flat,gain:map,whitePlate:true))
            }
            if flatReadings.isEmpty {readings.append(try LCCCameraPipeline.whiteBalance(raw,gain:map,whitePlate:false))}
        }
        let wbReadings=flatReadings.isEmpty ? readings:flatReadings
        let wb:(Float,Float)?=whiteBalanceOverride ?? (wbReadings.isEmpty ? nil:(wbReadings.reduce(0){$0+$1.temperature}/Float(wbReadings.count),wbReadings.reduce(0){$0+$1.tint}/Float(wbReadings.count)))
        let neutral:SIMD3<Double>?=wbReadings.isEmpty ? nil:wbReadings.reduce(SIMD3<Double>.zero){$0+$1.neutral}/Double(wbReadings.count)
        for i in cameraGains.indices {
            if let map=cameraGains[i],let raw=plan.lccRawPreviews?[i] {cameraGains[i]=map.preparingHighlights(raw,neutral:neutral)}
        }
        plan.lccState?.cameraGains=cameraGains;plan.lccState?.whiteBalance=wb;plan.lccState?.highlightNeutral=neutral
        plan.lccState?.whiteBalanceWasManual=whiteBalanceOverride != nil
        plan.lccState?.whiteBalanceSource=whiteBalanceOverride != nil ? L10n.tr("d23649ab6a49"):(flatReadings.isEmpty ? L10n.tr("81f4b75a4c48"):L10n.tr("4b3606bb6ea6"))
        plan.previewImages=try plan.sources.indices.map {i in
            guard let field=matches[i] else {return (plan.originalPreviewImages ?? plan.previewImages)[i]}
            if let map=cameraGains[i],let raw=plan.lccRawPreviews?[i] {
                return try materialize(LCCCameraPipeline.develop(raw,gain:map,whiteBalance:wb,highlightNeutral:neutral,size:plan.sources[i].size,scale:plan.previewScale))
            }
            guard !field.isCameraSpace else {throw PanoramaFailure(L10n.tr("344c1f88edf9"))}
            // Legacy RGB profiles remain usable for rendered inputs only. Recreate from RAW
            // to obtain physically ordered LCC; never silently use them on a RAW photograph.
            if plan.sources[i].isRAW {throw PanoramaFailure(L10n.tr("4bb84000db0d"))}
            return applyGain(base[i],gain:gainImages[i],scale:plan.previewScale)
        }
        plan.photometricGains=[]
        if rebuildSeams {return try update(plan,options:plan.options,cancellation:cancellation)}
        renderPreview(&plan)
        return plan
    }
    func applyGain(_ image:CIImage,gain:CIImage,scale:Double)->CIImage {
        let g=gain.transformed(by:CGAffineTransform(scaleX:scale,y:scale)).clampedToExtent().cropped(to:image.extent)
        return image.applyingFilter("CIMultiplyCompositing",parameters:["inputBackgroundImage":g]).cropped(to:image.extent)
    }
}
