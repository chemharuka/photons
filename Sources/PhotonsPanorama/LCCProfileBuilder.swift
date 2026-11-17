import PhotonsCore
import PhotonsLocalization
import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

// Value snapshot; CGImage and PanoramaSource metadata are immutable.
public struct LCCCreationFrame: Identifiable, @unchecked Sendable {
    public var id=UUID()
    public let source: PanoramaSource
    public var orientation: LCCCaptureOrientation
    public var bodyOrientation:PanoramaBodyOrientation = .degrees0
    public var relativeOrientation:LCCCaptureOrientation {orientation.relative(to:bodyOrientation)}
    public var shiftX=0.0
    public var shiftY=0.0
    public var shiftConfirmed=false
    public let iso: Double?
    public let exposureSeconds: Double?
    public let capturedAt: String?
    public let thumbnail: CGImage?
    public let jpeg: Data?
    public init(url:URL) throws {
        let source=try PanoramaSource(url:url);self.source=source
        guard let orientation=LCCCaptureOrientation(rawValue:source.orientation) else {
            throw PanoramaFailure(L10n.tr("76eaacfe87d2" , String(describing: (url.lastPathComponent))))
        }
        self.orientation=orientation
        if let suggestion=LCCShiftFilename.parse(url.lastPathComponent) { shiftX=suggestion.x;shiftY=suggestion.y }
        let imageSource=CGImageSourceCreateWithURL(url as CFURL,nil)
        let p=imageSource.flatMap { CGImageSourceCopyPropertiesAtIndex($0,0,nil) as? [String:Any] } ?? [:]
        let e=p[kCGImagePropertyExifDictionary as String] as? [String:Any] ?? [:]
        iso=(e[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first?.doubleValue
        exposureSeconds=(e[kCGImagePropertyExifExposureTime as String] as? NSNumber)?.doubleValue
        capturedAt=e[kCGImagePropertyExifDateTimeOriginal as String] as? String
        let options:[CFString:Any]=[kCGImageSourceCreateThumbnailFromImageAlways:true,
            kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:320]
        thumbnail=imageSource.flatMap { CGImageSourceCreateThumbnailAtIndex($0,0,options as CFDictionary) }
        jpeg=thumbnail.flatMap { LCCProfileBuilder.jpeg($0) }
    }
}

public enum LCCProfileBuilder {
    public static func exposureIssue(_ frames:[LCCCreationFrame])->String? {
        for key in [\LCCCreationFrame.iso,\LCCCreationFrame.exposureSeconds] {
            let values=frames.compactMap { $0[keyPath:key] }
            if let first=values.first, values.contains(where: { abs($0-first)>max(0.000001,first*0.01) }) {
                return L10n.tr("5fbddcf57213")
            }
        }
        return nil
    }
    public static func create(name:String,aperture:Double?,notes:String,frames:[LCCCreationFrame],
                              sensorLongEdge:Double,sensorShortEdge:Double,
                              cameraBody:PanoramaCameraBody?=nil,
                              cancellation:PanoramaCancellation = .init(),progress:(String)->Void = { _ in }) throws -> LCCLensProfile {
        guard !name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,(1...256).contains(frames.count),
              (5...100).contains(sensorShortEdge),(sensorShortEdge...100).contains(sensorLongEdge),
              frames.allSatisfy(\.shiftConfirmed) else {
            throw PanoramaFailure(L10n.tr("a5a786d39ada"))
        }
        if let issue=exposureIssue(frames) { throw PanoramaFailure(issue) }
        guard Set(frames.map { LCCProfileSummary.cameraKey($0.source.camera) }).count==1 else {
            throw PanoramaFailure(L10n.tr("cc1009f86e6a"))
        }
        // Metadata dimensions must agree with the user's physical sensor dimensions when available.
        for frame in frames {
            if let s=frame.source.sensor,
               abs(max(s.width,s.height)-sensorLongEdge)>0.3 || abs(min(s.width,s.height)-sensorShortEdge)>0.3 {
                throw PanoramaFailure(L10n.tr("8431ceaff69a" , String(describing: (frame.source.url.lastPathComponent))))
            }
        }
        var captures:[LCCProfileCapture]=[]
        for (index,frame) in frames.enumerated() {
            try cancellation.check();try frame.source.checkUnchanged()
            progress(L10n.tr("2822ec9e0922" , String(describing: (index+1)), String(describing: (frames.count)), String(describing: (frame.source.url.lastPathComponent))))
            let source=frame.source
            let raw=try LCCCameraPipeline.read(source)
            let orientation=frame.relativeOrientation,portrait=orientation.isPortrait
            let sw=portrait ? sensorShortEdge:sensorLongEdge,sh=portrait ? sensorLongEdge:sensorShortEdge
            let rw=min(192,raw.width/2),rh=min(144,raw.height/2)
            var means=[SIMD4<Float>](repeating:.zero,count:rw*rh),sems=means
            for y in 0..<rh {
                try cancellation.check()
                for x in 0..<rw {
                    var sum=SIMD4<Double>.zero,sq=sum,count=0.0
                    for by in (y*(raw.height/2)/rh)..<((y+1)*(raw.height/2)/rh) {
                        for bx in (x*(raw.width/2)/rw)..<((x+1)*(raw.width/2)/rw) {
                            var c=SIMD4<Double>.zero
                            for site in 0..<4 {c[raw.pattern[site]]=Double(raw.samples[(by*2+site/2)*raw.width+bx*2+site%2])}
                            sum += c;sq += c*c;count += 1
                        }
                    }
                    let mean=sum/max(1,count),variance=(sq/max(1,count)-mean*mean)/max(1,count)
                    means[y*rw+x]=SIMD4<Float>(mean)
                    sems[y*rw+x]=SIMD4(Float(sqrt(max(0,variance.x))),Float(sqrt(max(0,variance.y))),Float(sqrt(max(0,variance.z))),Float(sqrt(max(0,variance.w))))
                }
            }
            let gw=portrait ? rh:rw,gh=portrait ? rw:rh
            var values:[Float]=[],errors:[Float]=[]
            for y in 0..<gh {for x in 0..<gw {
                let xx:Int,yy:Int
                switch orientation {
                case .portraitLeft:xx=rw-1-y;yy=x
                case .portraitRight:xx=y;yy=rh-1-x
                case .inverted:xx=rw-1-x;yy=rh-1-y
                case .landscape:xx=x;yy=y
                }
                let v=means[yy*rw+xx],e=sems[yy*rw+xx]
                for c in 0..<4 {values.append(v[c]);errors.append(e[c])}
            }}
            let grid=LCCMeasurementGrid(x:(0..<gw).map { (Double($0)+0.5)/Double(gw)*sw-sw/2 },
                y:(0..<gh).map { sh/2-(Double($0)+0.5)/Double(gh)*sh },channels:["R","G1","B","G2"],
                values:LCCMeasurementGrid.pack(values),standardError:LCCMeasurementGrid.pack(errors),space:"camera-cfa-normalized-v2")
            let fullLong=Int(max(source.size.width,source.size.height)),fullShort=Int(min(source.size.width,source.size.height))
            let shift=frame.bodyOrientation.inverse.rotate(CGPoint(x:frame.shiftX,y:frame.shiftY))
            captures.append(LCCProfileCapture(id:frame.id,filename:source.url.lastPathComponent,orientation:orientation,
                shiftX:shift.x,shiftY:shift.y,sensorWidth:sw,sensorHeight:sh,
                pixelWidth:portrait ? fullShort:fullLong,pixelHeight:portrait ? fullLong:fullShort,
                iso:frame.iso,exposureSeconds:frame.exposureSeconds,capturedAt:frame.capturedAt,grid:grid,thumbnail:frame.jpeg,bodyOrientation:frame.bodyOrientation))
            try source.checkUnchanged()
            let decoded=try linearImage(source:source,scale:min(1,512/max(source.size.width,source.size.height)))
            let rotated=decoded.transformed(by:CGAffineTransform(rotationAngle:-Double(frame.bodyOrientation.rawValue)*Double.pi/180))
            let renderImage=rotated.transformed(by:CGAffineTransform(translationX:-rotated.extent.minX,y:-rotated.extent.minY))
            let renderRaster=PanoramaRaster(image:renderImage,context:CIContext(options:[.workingColorSpace:PanoramaEngine.linearSpace]),width:gw,height:gh)
            var rgb:[Float]=[]
            for i in 0..<gw*gh {rgb += Array(renderRaster.rgba[i*4..<i*4+3])}
            captures[captures.count-1].renderGrid=LCCMeasurementGrid(x:grid.x,y:grid.y,channels:["R","G","B"],
                values:LCCMeasurementGrid.pack(rgb),space:"apple-linear-srgb-6500K-v1")

        }
        let profile=LCCLensProfile(schemaVersion:2,id:UUID(),name:name.trimmingCharacters(in:.whitespacesAndNewlines),camera:frames[0].source.camera,
                                   aperture:aperture,notes:notes,createdAt:Date(),captures:captures,cameraBody:cameraBody)
        try profile.validate();return profile
    }
    static func linearImage(source:PanoramaSource,scale:Double,whiteBalance:(Float,Float)?=nil) throws -> CIImage {
        try source.checkUnchanged()
        let output:CIImage
        if source.isRAW,let initial=CIRAWFilter(imageURL:source.url) {
            let raw=try LinearDNGCompatibility.filter(for:source.url,initial:initial)
            raw.isLensCorrectionEnabled=false;raw.isGamutMappingEnabled=false
            raw.boostAmount=0;raw.boostShadowAmount=0;raw.localToneMapAmount=0
            raw.exposure=0;if !source.camera.hasPrefix("Photons Linear") {raw.baselineExposure=0};raw.shadowBias=0;raw.sharpnessAmount=0
            raw.luminanceNoiseReductionAmount=0;raw.colorNoiseReductionAmount=0
            if !source.camera.hasPrefix("Photons Linear") {raw.neutralTemperature=whiteBalance?.0 ?? 6500;raw.neutralTint=whiteBalance?.1 ?? 0};raw.scaleFactor=Float(scale)
            guard let image=raw.outputImage else {throw PanoramaFailure(L10n.tr("12edd19f4454" , String(describing: (source.url.lastPathComponent))))};output=image
        } else if let image=CIImage(contentsOf:source.url,options:[.applyOrientationProperty:true,.expandToHDR:true]) {output=image}
        else {throw PanoramaFailure(L10n.tr("12edd19f4454" , String(describing: (source.url.lastPathComponent))))}
        let normal=output.transformed(by:CGAffineTransform(translationX:-output.extent.minX,y:-output.extent.minY))
        return normal.transformed(by:CGAffineTransform(scaleX:source.size.width*scale/normal.extent.width,y:source.size.height*scale/normal.extent.height))
    }
    static func jpeg(_ cg:CGImage)->Data? {
        let output=NSMutableData()
        guard let dest=CGImageDestinationCreateWithData(output,UTType.jpeg.identifier as CFString,1,nil) else { return nil }
        CGImageDestinationAddImage(dest,cg,[kCGImageDestinationLossyCompressionQuality:0.75] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? output as Data:nil
    }
}
