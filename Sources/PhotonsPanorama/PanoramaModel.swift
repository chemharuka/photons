import PhotonsCore
import PhotonsLocalization
import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import PhotonsExtensions

public struct PanoramaFailure: LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message = message }
}

/// A token shared by the window and its serial worker. Closing the window cancels that job.
public final class PanoramaCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private let externalCancellation: () -> Bool
    public init(isCancelled: @escaping () -> Bool = { false }) { externalCancellation = isCancelled }
    public func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    public func check() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value || externalCancellation() { throw CancellationError() }
    }
}

public struct SensorSize: Codable, Equatable, Sendable {
    public var width: Double
    public var height: Double
    public var source: String
    public init(width: Double, height: Double, source: String) {
        self.width = width; self.height = height; self.source = source
    }
    public static func identify(properties: [String: Any]) -> SensorSize? {
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let model = (tiff[kCGImagePropertyTIFFModel as String] as? String ?? "").uppercased()
        // Focal-plane resolutions describe physical pitch, unlike print DPI. Reject implausible
        // units and dimensions; missing tags are not evidence of a 36 × 24 mm sensor.
        let unit = (exif[kCGImagePropertyExifFocalPlaneResolutionUnit as String] as? NSNumber)?.intValue
        let mm: Double? = unit == 2 ? 25.4 : (unit == 3 ? 10 : (unit == 4 ? 1 : (unit == 5 ? 0.001 : nil)))
        if let mm, let xr = (exif[kCGImagePropertyExifFocalPlaneXResolution as String] as? NSNumber)?.doubleValue,
           let yr = (exif[kCGImagePropertyExifFocalPlaneYResolution as String] as? NSNumber)?.doubleValue,
           let w = (exif[kCGImagePropertyExifPixelXDimension as String] as? NSNumber)?.doubleValue,
           let h = (exif[kCGImagePropertyExifPixelYDimension as String] as? NSNumber)?.doubleValue, xr > 0, yr > 0 {
            let sw = w / xr * mm, sh = h / yr * mm
            if (10...70).contains(sw), (10...60).contains(sh) {
                return SensorSize(width: sw, height: sh, source: L10n.tr("6470bc680f74"))
            }
        }
        // Hasselblad's CFV 100C data sheet: 43.8 × 32.9 mm. The actual 3FR model string also
        // contains '/Electronic Shutter'; match the back, not the attached camera or lens.
        if model.contains("CFV 100C") || model.contains("X2D 100C") {
            return SensorSize(width: 43.8, height: 32.9, source: L10n.tr("803071841b91" , String(describing: (model))))
        }
        return nil
    }
}

public struct PanoramaSource: Codable {
    public let url: URL
    public let size: CGSize
    public let sensor: SensorSize?
    public let camera: String
    public let orientation: Int
    public let temperature: Float?
    public let tint: Float?
    public let isRAW:Bool
    private let fileSize: Int?
    private let modified: Date?
    public init(url: URL, sensorOverride: SensorSize? = nil) throws {
        let identity = try url.resourceValues(forKeys:[.fileSizeKey,.contentModificationDateKey])
        fileSize = identity.fileSize; modified = identity.contentModificationDate
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] else {
            throw PanoramaFailure(L10n.tr("dbf58361c2d4" , String(describing: (url.lastPathComponent))))
        }
        self.url = url
        isRAW=CGImageSourceGetType(src).flatMap {UTType($0 as String)}?.conforms(to:.rawImage) == true
        orientation = (props[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue ?? 1
        let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        camera = tiff[kCGImagePropertyTIFFModel as String] as? String ?? L10n.tr("1e3818fd0c54")
        var identified = SensorSize.identify(properties: props)
        if isRAW, let initial = CIRAWFilter(imageURL: url) {
            let f = try LinearDNGCompatibility.filter(for: url, initial: initial)
            f.isLensCorrectionEnabled = false
            guard let image = f.outputImage else { throw PanoramaFailure(L10n.tr("ae0e8fc37498" , String(describing: (url.lastPathComponent)))) }
            size = image.extent.size
            temperature = f.neutralTemperature; tint = f.neutralTint
        } else if let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) {
            size = image.extent.size; temperature = nil; tint = nil
        } else { throw PanoramaFailure(L10n.tr("30fe5a21c7fe" , String(describing: (url.lastPathComponent)))) }
        if orientation >= 5, let s = identified {
            identified = SensorSize(width: s.height, height: s.width, source: s.source)
        }
        sensor = sensorOverride ?? identified
    }
    public func checkUnchanged() throws {
        var fresh = url; fresh.removeAllCachedResourceValues()
        let identity = try fresh.resourceValues(forKeys:[.fileSizeKey,.contentModificationDateKey])
        guard identity.fileSize == fileSize, identity.contentModificationDate == modified else {
            throw PanoramaFailure(L10n.tr("7e0e69f9c09a" , String(describing: (url.lastPathComponent))))
        }
    }
}

public enum PanoramaRegistrationMode: String, Codable, Sendable {
    case shift, perspective
    public static let perspectiveLCCNotice = "Apply LCC to individual photographs before perspective stitching. A rotated-camera layout does not describe physical lens-shift positions."
}

public struct PanoramaOptions: Codable, Equatable {
    public var avoidMotion = true
    public var matchExposure = true
    public var seamSoftness = 6.0
    /// -1: automatic. Otherwise prefer this source through ambiguous overlap regions.
    public var preferredSource = -1
    public init() {}
}

/// One measured frame fixes the optical origin. Replacing this value replaces the sole
/// constraint; there is no collection of potentially contradictory camera readings.
public struct PanoramaPositionReference:Equatable {
    public let sourceIndex:Int
    /// Same image-circle axes as LCC capture positions: right/up positive.
    public let positionMM:CGPoint
    public init(sourceIndex:Int,positionMM:CGPoint) {self.sourceIndex=sourceIndex;self.positionMM=positionMM}
    public func position(of index:Int,in plan:PanoramaPlan,sensor:SensorSize)->CGPoint {
        let a=plan.sensorRect(sourceIndex),b=plan.sensorRect(index)
        return CGPoint(x:positionMM.x+(b.midX-a.midX)*sensor.width/a.width,
                       y:positionMM.y-(b.midY-a.midY)*sensor.height/a.height)
    }
    public func profileOffset(in plan:PanoramaPlan,sensor:SensorSize)->CGPoint {
        let r=plan.sensorRect(sourceIndex)
        return CGPoint(x:(r.midX-plan.size.width/2)*sensor.width/r.width-positionMM.x,
                       y:(plan.size.height/2-r.midY)*sensor.height/r.height-positionMM.y)
    }
}

public struct OpticalEstimate {
    /// In panorama pixels, upper-left origin. Nil means the fit is underdetermined.
    public var center: CGPoint?
    public var confidence: Double
    public var explanation: String
    public var occludedEdges: [String]
}

/// The same full-resolution geometry and low-resolution ownership field are consumed by BOTH
/// renderers. Export cannot call registration. Stored coordinates use an upper-left origin;
/// only the Core Image compositor converts them to lower-left coordinates.
public struct PanoramaPlan {
    public var registrationMode: PanoramaRegistrationMode = .shift
    public var isRegistered = true
    public var warps: [PanoramaTransform]? = nil
    public let sources: [PanoramaSource]
    public let origins: [CGPoint]
    public let size: CGSize
    public let registrationScores: [Double]
    public let whiteBalance: (Float, Float)?
    public var gains: [Double]
    public var ownership: [Int16]
    public var blendMasks: [Data] = []
    /// Smooth residual overlap photometry, in full-resolution source coordinates.
    public var photometricGains: [CIImage] = []
    public var maskWidth: Int
    public var maskHeight: Int
    public var optical: OpticalEstimate
    public var options: PanoramaOptions
    public var previewScale: Double
    public var previewImages: [CIImage]
    public var preview: CGImage?
    /// Per-source orientation selection. This is calibration selection, not an implicit correction.
    public var lensProfileSelections: [LCCProfileBinding?] = []
    public var lccState: PanoramaLCCState?
    public var originalPreviewImages: [CIImage]?
    public var lccLinearPreviewImages: [CIImage]?
    public var lccRawPreviews:[CameraMosaic?]?
    public var lccFlatPreviews:[CameraMosaic?]?
    public var outputSize: CGSize { lccState?.cropRect?.size ?? size }

    public var megapixels: Double { size.width * size.height / 1_000_000 }
    public func sourcePoint(_ index:Int, panorama point:CGPoint) -> CGPoint {
        if let inverse=warps?[index].inverse {return inverse.point(point)}
        return CGPoint(x:point.x-origins[index].x,y:point.y-origins[index].y)
    }
    public func sensorRect(_ index:Int) -> CGRect {CGRect(origin:origins[index],size:sources[index].size)}
    public func sourceRect(_ index: Int, scale: Double = 1) -> CGRect {
        let rect = warps?[index].bounds(sources[index].size) ?? CGRect(origin: origins[index], size: sources[index].size)
        return rect.applying(CGAffineTransform(scaleX: scale, y: scale))
    }
}

/// Small CPU raster for matching/photometry; final pixels stay half-float, scene-linear on the GPU.
struct PanoramaRaster {
    let width: Int
    let height: Int
    let rgba: [Float]
    init(image: CIImage, context: CIContext, width: Int, height: Int) {
        self.width = width; self.height = height
        let scaled = image.transformed(by: CGAffineTransform(scaleX: Double(width) / image.extent.width,
                                                             y: Double(height) / image.extent.height))
        var pixels = [Float](repeating: 0, count: width * height * 4)
        context.render(scaled, toBitmap: &pixels, rowBytes: width * 16,
                       bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBAf,
                       colorSpace: PanoramaEngine.linearSpace)
        rgba = pixels
    }
    func rgb(_ x: Double, _ y: Double) -> SIMD3<Double>? {
        guard x >= 0, y >= 0, x < Double(width), y < Double(height) else { return nil }
        let cx = min(x, Double(width-1)), cy = min(y, Double(height-1))
        let ix = min(width-2, Int(cx)), iy = min(height-2, Int(cy)), fx = cx - Double(ix), fy = cy - Double(iy)
        func value(_ x: Int, _ y: Int) -> SIMD3<Double> {
            let p = (y * width + x) * 4
            return SIMD3(Double(rgba[p]), Double(rgba[p + 1]), Double(rgba[p + 2]))
        }
        return (value(ix, iy) * (1-fx) + value(ix+1, iy) * fx) * (1-fy)
            + (value(ix, iy+1) * (1-fx) + value(ix+1, iy+1) * fx) * fy
    }
    var gray: GrayRaster {
        GrayRaster(width: width, height: height, values: stride(from: 0, to: rgba.count, by: 4).map {
            sqrt(max(0, Double(rgba[$0]) * 0.2126 + Double(rgba[$0+1]) * 0.7152 + Double(rgba[$0+2]) * 0.0722))
        })
    }
}

struct GrayRaster {
    let width: Int
    let height: Int
    let values: [Double]
    func sample(_ x: Double, _ y: Double) -> Double {
        let ix = min(width-2, max(0, Int(x))), iy = min(height-2, max(0, Int(y)))
        let fx = min(1, max(0, x-Double(ix))), fy = min(1, max(0, y-Double(iy)))
        let p = iy * width + ix
        return (values[p] * (1-fx) + values[p+1] * fx) * (1-fy)
            + (values[p+width] * (1-fx) + values[p+width+1] * fx) * fy
    }
}

func median(_ input: [Double]) -> Double {
    guard !input.isEmpty else { return 0 }
    let sorted = input.sorted(); return sorted[sorted.count / 2]
}
