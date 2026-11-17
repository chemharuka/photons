import PhotonsLocalization
import Foundation
import CoreGraphics
import ImageIO
import CoreImage

/// Portable geometry. Coordinates are fractions of the uncropped canvas, top/left origin;
/// millimetres stay physical when a copy is resized. No absolute paths or GPS are embedded.
public struct PanoramaManifest: Codable {
    /// The smooth RGB adjustment baked into each source before blending. Keep it portable
    /// so later LCC can remove it instead of correcting an already compensated field twice.
    public struct PhotometricField: Codable {
        var width:Int,height:Int,values:[Float]
        init(image:CIImage,context:CIContext) {
            width=32;height=32
            let raster=PanoramaRaster(image:image,context:context,width:width,height:height)
            values=(0..<width*height).flatMap {Array(raster.rgba[$0*4..<$0*4+3])}
        }
        var isValid:Bool {
            width>=2 && height>=2 && width<=64 && height<=64 && values.count==width*height*3 && values.allSatisfy {$0.isFinite && $0>0 && $0<=16}
        }
        func gain(at point:CGPoint)->SIMD3<Double> {
            let px=min(Double(width-1),max(0,point.x*Double(width)-0.5))
            let py=min(Double(height-1),max(0,point.y*Double(height)-0.5))
            let x=min(width-2,Int(px)),y=min(height-2,Int(py)),fx=px-Double(x),fy=py-Double(y)
            func sample(_ x:Int,_ y:Int)->SIMD3<Double> {
                let i=(y*width+x)*3
                return SIMD3(Double(values[i]),Double(values[i+1]),Double(values[i+2]))
            }
            return (sample(x,y)*(1-fx)+sample(x+1,y)*fx)*(1-fy)+(sample(x,y+1)*(1-fx)+sample(x+1,y+1)*fx)*fy
        }
    }
    public struct Frame: Codable {
        public var filename: String
        public var camera: String
        public var orientation: Int
        public var rect: CGRect
        public var sensor: SensorSize?
        public var shiftMM: CGPoint?
        public var imageToCanvas: PanoramaTransform? = nil
        public var sensorRect: CGRect? = nil
    }
    public var version = 1
    /// Already applied to the exported pixels; provenance, not an instruction to apply twice.
    public var tone: PanoramaToneSettings?
    public var projection = "translation"
    /// Missing in legacy manifests, whose physical model remains the shift workflow.
    public var registrationMode: PanoramaRegistrationMode? = nil
    public var canvas: CGSize
    public var crop: CGRect
    public var frames: [Frame]
    public var profileID: UUID?
    public var profileName: String?
    public var profileOffsetMM: CGPoint?
    public var bodyOrientation: PanoramaBodyOrientation
    public var cameraBody: PanoramaCameraBody? = nil
    public var correctionApplied: Bool
    public var correctionMethod: String?
    public var options: PanoramaOptions
    public var maskWidth: Int
    public var maskHeight: Int
    public var weights: [Data]
    /// Row-major homography from the current exported copy into the original crop.
    public var whiteBalance: [Float]?
    public var exposureGains: [Double]?
    public var photometricFields: [PhotometricField]? = nil
    public var outputTransform: [Double]?
    public var geometryUnrecoverable: Bool?

    public init(plan: PanoramaPlan, profileID: UUID? = nil, profileName: String? = nil,
                offsetMM: CGPoint? = nil, sensor: SensorSize? = nil,
                bodyOrientation: PanoramaBodyOrientation = .degrees0, cameraBody: PanoramaCameraBody? = nil) {
        canvas=plan.size
        tone = plan.tone
        registrationMode=plan.registrationMode
        version=plan.warps == nil ? 1:2
        projection=plan.warps == nil ? "translation":"projective"
        whiteBalance=plan.whiteBalance.map {[$0.0,$0.1]}
        exposureGains=plan.gains
        if !plan.photometricGains.isEmpty {
            let context=CIContext(options:[.workingColorSpace:PanoramaEngine.linearSpace,.cacheIntermediates:false])
            photometricFields=plan.photometricGains.map {PhotometricField(image:$0,context:context)}
        }
        let transform=CGAffineTransform(scaleX:1/canvas.width,y:1/canvas.height)
        crop=(plan.lccState?.cropRect ?? CGRect(origin:.zero,size:canvas)).applying(transform)
        self.profileID=plan.lccState?.profileID ?? profileID
        self.profileName=plan.lccState?.profileName ?? profileName
        self.profileOffsetMM=plan.lccState?.offsetMM ?? offsetMM
        self.bodyOrientation=plan.lccState?.bodyOrientation ?? bodyOrientation
        self.cameraBody=plan.lccState?.cameraBody ?? cameraBody
        correctionApplied=plan.lccState != nil
        correctionMethod=correctionApplied ? "profile-before-blending" : nil
        options=plan.options
        frames=plan.sources.indices.map { i in
            let source=plan.sources[i],rect=plan.sourceRect(i)
            let sensorRect=CGRect(origin:plan.origins[i],size:source.size)
            let physical=plan.lccState?.sensor ?? sensor ?? source.sensor
            var shift:CGPoint?
            if let physical,let offset=plan.lccState?.offsetMM ?? offsetMM {
                shift=CGPoint(x:(sensorRect.midX-plan.size.width/2)*physical.width/sensorRect.width-offset.x,
                              y:(plan.size.height/2-sensorRect.midY)*physical.height/sensorRect.height-offset.y)
            }
            var frame=Frame(filename:source.url.lastPathComponent,camera:source.camera,orientation:source.orientation,
                            rect:rect.applying(transform),sensor:physical,shiftMM:shift)
            if let warp=plan.warps?[i] {
                frame.imageToCanvas=PanoramaTransform.scale(1/plan.size.width,1/plan.size.height).multiplied(by:warp).multiplied(by:.scale(source.size.width,source.size.height))
                frame.sensorRect=sensorRect.applying(transform)
            }
            return frame
        }
        maskWidth=plan.maskWidth;maskHeight=plan.maskHeight
        // Preserve the actual seam weights, independent of exported pixel dimensions.
        weights=plan.sources.indices.map { i in
            if plan.blendMasks.indices.contains(i) {
                return plan.blendMasks[i].withUnsafeBytes { raw in
                    Data(raw.bindMemory(to:Float.self).map {UInt8((min(1,max(0,$0.isFinite ? $0:0))*255).rounded())})
                }
            }
            return Data(plan.ownership.map {$0==Int16(i) ? 255:0})
        }
    }
    public func metadata() throws -> CGImageMetadata {
        let result=CGImageMetadataCreateMutable()
        CGImageMetadataRegisterNamespaceForPrefix(result,"https://photons.app/ns/panorama/1.0/" as CFString,"photonsPano" as CFString,nil)
        CGImageMetadataSetValueWithPath(result,nil,"photonsPano:Manifest" as CFString,PanoramaMetadataPacket.string(try encoded()) as CFString)
        return result
    }
    public func encoded() throws -> Data { try JSONEncoder().encode(self) }
    public func canvasPoint(u:Double,v:Double)->CGPoint {
        let m=outputTransform ?? [1,0,0,0,1,0,0,0,1]
        let z=m[6]*u+m[7]*v+m[8]
        guard abs(z)>1e-12 else { return CGPoint(x:Double.nan,y:Double.nan) }
        return CGPoint(x:crop.minX+(m[0]*u+m[1]*v+m[2])/z*crop.width,
                       y:crop.minY+(m[3]*u+m[4]*v+m[5])/z*crop.height)
    }
    public static func read(from url:URL) throws -> Self? {
        guard let source=CGImageSourceCreateWithURL(url as CFURL,nil),
              let metadata=CGImageSourceCopyMetadataAtIndex(source,0,nil),
              let value=CGImageMetadataCopyStringValueWithPath(metadata,nil,"photonsPano:Manifest" as CFString) as String? else {return nil}
        guard let data=PanoramaMetadataPacket.data(value) else {throw PanoramaFailure(L10n.tr("fa397c8d29a6"))}
        let result=try JSONDecoder().decode(Self.self,from:data)
        try result.validate();return result
    }
    public func validate() throws {
        guard tone?.isValid ?? true else { throw PanoramaFailure("Invalid panorama brightness settings.") }
        guard (version==1 && projection=="translation" || version==2 && projection=="projective"),(1...16).contains(frames.count),
              canvas.width.isFinite,canvas.height.isFinite,canvas.width>0,canvas.height>0,
              crop.width>0,crop.height>0,crop.minX>=0,crop.minY>=0,crop.maxX<=1.001,crop.maxY<=1.001,
              maskWidth>0,maskHeight>0,maskWidth<=8192,maskHeight<=8192,
              outputTransform.map({$0.count==9 && $0.allSatisfy(\.isFinite)}) ?? true,
              exposureGains.map({$0.count==frames.count && $0.allSatisfy {$0.isFinite && $0>0 && $0<=16}}) ?? true,
              photometricFields.map({$0.count==frames.count && $0.allSatisfy(\.isValid)}) ?? true,
              weights.count==frames.count,weights.allSatisfy({$0.count==maskWidth*maskHeight}),
              frames.allSatisfy({frame in
                  guard let warp=frame.imageToCanvas else {return projection=="translation"}
                  guard warp.isValid,let sensor=frame.sensorRect,sensor.width.isFinite,sensor.height.isFinite,sensor.width>0,sensor.height>0 else {return false}
                  return warp.corners(CGSize(width:1,height:1)).allSatisfy {$0.x.isFinite && $0.y.isFinite && (-0.001...1.001).contains($0.x) && (-0.001...1.001).contains($0.y)}
              }),
              frames.allSatisfy({$0.rect.width>0 && $0.rect.height>0 && $0.rect.minX>=0 && $0.rect.minY>=0 && $0.rect.maxX<=1.001 && $0.rect.maxY<=1.001}) else {
            throw PanoramaFailure(L10n.tr("43898da0de51"))
        }
    }
    public static func defaultName(_ urls:[URL])->String {
        let first=urls.sorted {$0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending}.first
        return (first?.deletingPathExtension().lastPathComponent ?? "Panorama")+"_pano"
    }
}
