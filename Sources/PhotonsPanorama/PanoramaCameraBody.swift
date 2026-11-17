import PhotonsLocalization
import Foundation

/// Body rotation is independent of the sensor's EXIF orientation. Coordinates are
/// image-plane right/up; a counterclockwise quarter turn moves body-up to image-left.
public enum PanoramaBodyOrientation:Int,Codable,CaseIterable,Identifiable,Sendable {
    case degrees0=0,degrees90=90,degrees180=180,degrees270=270
    public var id:Int {rawValue}
    public var inverse:Self {Self(rawValue:(360-rawValue)%360)!}
    public var swapsAxes:Bool {self == .degrees90 || self == .degrees270}
    public func rotate(_ p:CGPoint)->CGPoint {
        switch self {
        case .degrees0:return p
        case .degrees90:return CGPoint(x:-p.y,y:p.x)
        case .degrees180:return CGPoint(x:-p.x,y:-p.y)
        case .degrees270:return CGPoint(x:p.y,y:-p.x)
        }
    }
    public func rotate(_ r:CGRect)->CGRect {
        let a=rotate(CGPoint(x:r.minX,y:r.minY)),b=rotate(CGPoint(x:r.maxX,y:r.maxY))
        return CGRect(x:min(a.x,b.x),y:min(a.y,b.y),width:abs(b.x-a.x),height:abs(b.y-a.y))
    }
}

public struct PanoramaShiftRange:Hashable,Codable,Sendable {
    public let left:Double
    public let right:Double
    public let up:Double
    public let down:Double
    public init(left:Double,right:Double,up:Double,down:Double) {
        self.left=left;self.right=right;self.up=up;self.down=down
    }
    public func rotated(_ orientation:PanoramaBodyOrientation)->Self {
        switch orientation {
        case .degrees0:return self
        case .degrees90:return Self(left:up,right:down,up:right,down:left)
        case .degrees180:return Self(left:right,right:left,up:down,down:up)
        case .degrees270:return Self(left:down,right:up,up:left,down:right)
        }
    }
    /// Deduplicate by actual travel, including asymmetric single-axis bodies.
    public var distinctOrientations:[PanoramaBodyOrientation] {
        var seen:[Self]=[]
        return PanoramaBodyOrientation.allCases.filter {angle in
            let range=rotated(angle)
            guard !seen.contains(range) else {return false}
            seen.append(range);return true
        }
    }
    public func contains(_ position:CGPoint,tolerance:Double=0)->Bool {
        position.x >= -left-tolerance && position.x <= right+tolerance &&
        position.y >= -down-tolerance && position.y <= up+tolerance
    }
    /// Swept sensor footprint, in display coordinates (down-positive Y). When no
    /// absolute anchor exists, center the bounding rectangle rather than the zero point.
    public func coverage(sensor:SensorSize,centered:Bool)->CGRect {
        let width=left+right+sensor.width,height=up+down+sensor.height
        return CGRect(x:centered ? -width/2 : -left-sensor.width/2,
                      y:centered ? -height/2 : -up-sensor.height/2,width:width,height:height)
    }
    /// All frame centers must fit after subtracting the same optical-origin offset.
    /// The tolerance accounts for registration/scale noise, including on a fixed axis.
    public func opticalOriginBounds(centers:[CGPoint],tolerance:Double=0.75)->CGRect? {
        guard !centers.isEmpty else {return nil}
        let x0=centers.map {$0.x-right-tolerance}.max()!,x1=centers.map {$0.x+left+tolerance}.min()!
        let y0=centers.map {$0.y-up-tolerance}.max()!,y1=centers.map {$0.y+down+tolerance}.min()!
        guard x1>=x0,y1>=y0 else {return nil}
        return CGRect(x:x0,y:y0,width:x1-x0,height:y1-y0)
    }
    public var summary:String {
        String(format:L10n.tr("2964a5376783"),left,right,up,down)
    }
}

public enum PanoramaCameraBody:Codable,CaseIterable,Hashable,Identifiable,Sendable {
    case alpa12Max,alpa12XY,alpa12STC,alpa12Pano,alpa12Plus
    case custom(CameraBodyProfile)

    /// Keep the built-in order and wire IDs stable. User bodies are loaded by CameraBodyStore.
    public static let allCases:[Self] = [.alpa12Max,.alpa12XY,.alpa12STC,.alpa12Pano,.alpa12Plus]
    public var id:String {
        switch self {
        case .alpa12Max:return "alpa12Max"
        case .alpa12XY:return "alpa12XY"
        case .alpa12STC:return "alpa12STC"
        case .alpa12Pano:return "alpa12Pano"
        case .alpa12Plus:return "alpa12Plus"
        case .custom(let profile):return "custom:" + profile.id.uuidString.lowercased()
        }
    }
    public var isBuiltIn:Bool {if case .custom = self {return false};return true}
    public var name:String {
        switch self {
        case .alpa12Max:return "Alpa 12 Max"
        case .alpa12XY:return "Alpa 12 XY"
        case .alpa12STC:return "Alpa 12 STC"
        case .alpa12Pano:return "Alpa 12 Pano"
        case .alpa12Plus:return "Alpa 12 Plus"
        case .custom(let profile):return profile.name
        }
    }
    public var defaultTravel:PanoramaShiftRange {
        switch self {
        case .alpa12Max:return .init(left:18,right:18,up:25,down:18)
        case .alpa12XY:return .init(left:25,right:25,up:45,down:25)
        case .alpa12STC:return .init(left:18,right:18,up:0,down:0)
        case .alpa12Pano:return .init(left:35,right:35,up:10,down:10)
        case .alpa12Plus:return .init(left:20,right:20,up:20,down:20)
        case .custom(let profile):return profile.travel
        }
    }

    /// Existing profiles/manifests encode built-ins as strings. Custom bodies carry their full
    /// definition so later edits/deletion in Settings cannot change an archived calibration.
    private enum CodingKeys:String,CodingKey {case version,profile}
    public init(from decoder:Decoder) throws {
        if let id=try? decoder.singleValueContainer().decode(String.self),
           let body=Self.allCases.first(where:{$0.id==id}) {self=body;return}
        let values=try decoder.container(keyedBy:CodingKeys.self)
        guard try values.decode(Int.self,forKey:.version)==1 else {
            throw DecodingError.dataCorruptedError(forKey:.version,in:values,debugDescription:"Unsupported camera body version")
        }
        self = .custom(try values.decode(CameraBodyProfile.self,forKey:.profile))
    }
    public func encode(to encoder:Encoder) throws {
        if case .custom(let profile)=self {
            var values=encoder.container(keyedBy:CodingKeys.self)
            try values.encode(1,forKey:.version);try values.encode(profile,forKey:.profile)
        } else {var value=encoder.singleValueContainer();try value.encode(id)}
    }
    public var orientations:[PanoramaBodyOrientation] {defaultTravel.distinctOrientations}
    public func travel(at orientation:PanoramaBodyOrientation)->PanoramaShiftRange {defaultTravel.rotated(orientation)}
    public func canonicalOrientation(_ orientation:PanoramaBodyOrientation)->PanoramaBodyOrientation {
        orientations.first {travel(at:$0)==travel(at:orientation)} ?? .degrees0
    }
    public func equivalentOrientations(to orientation:PanoramaBodyOrientation)->[PanoramaBodyOrientation] {
        [orientation]+PanoramaBodyOrientation.allCases.filter {$0 != orientation && travel(at:$0)==travel(at:orientation)}
    }
    public func placementLabel(_ orientation:PanoramaBodyOrientation)->String {
        if orientations.count==1 {return L10n.tr("fe4ff4c2b79b")}
        if orientations.count==2 {return orientation == .degrees0 ? L10n.tr("0795fb1a4b4b"):L10n.tr("bf6b4f034de6")}
        switch orientation {
        case .degrees0:return L10n.tr("39b4d37525c7")
        case .degrees90:return L10n.tr("9eb2d65178e1")
        case .degrees180:return L10n.tr("920f1de3792d")
        case .degrees270:return L10n.tr("3206dbbbf8e1")
        }
    }
}
