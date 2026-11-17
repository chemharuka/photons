import PhotonsLocalization
import Foundation
import CoreGraphics

public enum LCCCaptureOrientation: Int, Codable, CaseIterable, Identifiable {
    case landscape = 1, inverted = 3, portraitRight = 6, portraitLeft = 8
    public var id: Int { rawValue }
    public var isPortrait: Bool { self == .portraitLeft || self == .portraitRight }
    public var rotation:PanoramaBodyOrientation {
        switch self {case .landscape:return .degrees0;case .portraitLeft:return .degrees90;case .inverted:return .degrees180;case .portraitRight:return .degrees270}
    }
    public func relative(to body:PanoramaBodyOrientation)->Self {
        let degrees=(rotation.rawValue-body.rawValue+360)%360
        return Self.allCases.first {$0.rotation.rawValue==degrees}!
    }
    public var title: String {
        switch self {
        case .landscape: return L10n.tr("d95352f4e044")
        case .inverted: return L10n.tr("b37dadee1b92")
        case .portraitLeft: return L10n.tr("8336178d7b2b")
        case .portraitRight: return L10n.tr("705571773f83")
        }
    }
}

/// Values are interleaved little-endian Float32, row-major from the top-left. Coordinates
/// describe cell centers in the already-oriented sensor plane, in millimetres (right/up +).
/// Camera CFA and developed linear RGB are deliberately distinct measurement spaces.
public struct LCCMeasurementGrid: Codable, Equatable {
    public var x: [Double]
    public var y: [Double]
    public var channels: [String]
    public var values: Data
    public var standardError: Data?
    public var space: String
    public var width: Int { x.count }
    public var height: Int { y.count }
    public var floats: [Float] { Self.unpack(values) }
    public static func pack(_ values: [Float]) -> Data {
        var bits = values.map { $0.bitPattern.littleEndian }
        return bits.withUnsafeMutableBytes { Data($0) }
    }
    public static func unpack(_ bytes: Data) -> [Float] {
        bytes.withUnsafeBytes { p in
            stride(from:0,to:bytes.count-bytes.count%4,by:4).map {
                Float(bitPattern:UInt32(littleEndian:p.loadUnaligned(fromByteOffset:$0,as:UInt32.self)))
            }
        }
    }
    func validate() throws {
        guard (2...1024).contains(width), (2...1024).contains(height),
              channels == ["R","G","B"] || channels == ["R","G1","B","G2"],
              values.count == width*height*channels.count*4,
              standardError == nil || standardError?.count == values.count,
              x.allSatisfy(\.isFinite), y.allSatisfy(\.isFinite),
              zip(x,x.dropFirst()).allSatisfy({ $0 < $1 }),
              zip(y,y.dropFirst()).allSatisfy({ $0 > $1 }),
              floats.allSatisfy(\.isFinite),
              ["camera-cfa-black-subtracted-v1","camera-cfa-normalized-v2","apple-linear-srgb-6500K-v1"].contains(space) else {
            throw PanoramaFailure(L10n.tr("b9d6d42dc0bf"))
        }
        if let standardError, !Self.unpack(standardError).allSatisfy({ $0.isFinite && $0 >= 0 }) {
            throw PanoramaFailure(L10n.tr("d02204483a8c"))
        }
    }
}

public struct LCCProfileCapture: Codable, Equatable, Identifiable {
    public var id: UUID
    public var filename: String
    public var orientation: LCCCaptureOrientation
    public var shiftX: Double
    public var shiftY: Double
    public var sensorWidth: Double
    public var sensorHeight: Double
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var iso: Double?
    public var exposureSeconds: Double?
    public var capturedAt: String?
    public var grid: LCCMeasurementGrid
    public var thumbnail: Data?
    /// Optional fixed-WB linear RGB measurements for the Core Image rendering pipeline.
    public var renderGrid: LCCMeasurementGrid? = nil
    /// Capture metadata; grids and shifts are normalized to the body's 0° coordinate system.
    public var bodyOrientation:PanoramaBodyOrientation? = nil
    public var fieldRect: CGRect {
        CGRect(x:shiftX-sensorWidth/2,y:shiftY-sensorHeight/2,width:sensorWidth,height:sensorHeight)
    }
}

public struct LCCLensProfile: Codable, Equatable, Identifiable {
    public static let builtInID = UUID(uuidString:"43A1CC00-1115-4000-8000-000000000001")!
    public var schemaVersion = 1
    public var id: UUID
    public var name: String
    public var camera: String
    public var aperture: Double?
    public var notes: String
    public var createdAt: Date
    public var captures: [LCCProfileCapture]
    /// Capture provenance only. Optical compatibility and measured coverage do not depend
    /// on this body; the active panorama body separately constrains attainable positions.
    public var cameraBody:PanoramaCameraBody? = nil
    public var orientations: [LCCCaptureOrientation] {
        Array(Set(captures.map(\.orientation))).sorted { $0.rawValue < $1.rawValue }
    }
    public func captures(for orientation: LCCCaptureOrientation) -> [LCCProfileCapture] {
        captures.filter { $0.orientation == orientation }
    }
    public func validate() throws {
        guard [1,2].contains(schemaVersion), !name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
              name.count <= 200, !camera.isEmpty, camera.count <= 200,
              notes.count <= 8000, (1...256).contains(captures.count),
              Set(captures.map(\.id)).count == captures.count,
              Set(captures.map { $0.grid.space }).count == 1,
              aperture == nil || (aperture!.isFinite && aperture! > 0 && aperture! <= 128) else {
            throw PanoramaFailure(L10n.tr("922f6b22f998"))
        }
        for c in captures {
            guard c.shiftX.isFinite, c.shiftY.isFinite, abs(c.shiftX)<=150, abs(c.shiftY)<=150,
                  (5...100).contains(c.sensorWidth), (5...100).contains(c.sensorHeight),
                  c.pixelWidth>0, c.pixelHeight>0,
                  c.iso == nil || (c.iso!.isFinite && c.iso!>0),
                  c.exposureSeconds == nil || (c.exposureSeconds!.isFinite && c.exposureSeconds!>0) else {
                throw PanoramaFailure(L10n.tr("a2dbc7bae4dd"))
            }
            try c.grid.validate()
            if let render=c.renderGrid { try render.validate(); guard render.space=="apple-linear-srgb-6500K-v1" else {throw PanoramaFailure(L10n.tr("6a7590d81df0"))} }
            guard c.grid.x.allSatisfy({ abs($0)<=c.sensorWidth/2+0.001 }),
                  c.grid.y.allSatisfy({ abs($0)<=c.sensorHeight/2+0.001 }) else {
                throw PanoramaFailure(L10n.tr("5a13415f2912"))
            }
        }
    }
}

public struct LCCProfileSummary: Codable, Equatable, Identifiable {
    public let id: UUID
    public let name: String
    public let camera: String
    public let aperture: Double?
    public let createdAt: Date
    public let variants: [LCCVariantSummary]
    public var cameraBody:PanoramaCameraBody? = nil
    public var calibrationBody:PanoramaCameraBody? {cameraBody ?? (id==LCCLensProfile.builtInID ? .alpa12Max:nil)}
    public init(_ profile: LCCLensProfile) {
        id=profile.id; name=profile.name; camera=profile.camera; aperture=profile.aperture; createdAt=profile.createdAt
        cameraBody=profile.cameraBody
        variants=profile.orientations.map { o in
            let frames=profile.captures(for:o)
            return LCCVariantSummary(orientation:o,count:frames.count,sensorWidth:frames[0].sensorWidth,
                                     sensorHeight:frames[0].sensorHeight)
        }
    }
    public var captureCount: Int { variants.reduce(0) { $0+$1.count } }
    public func match(camera:String,exifOrientation:Int,sensor:SensorSize?,cameraBody:PanoramaCameraBody?=nil,
                      bodyOrientation:PanoramaBodyOrientation = .degrees0)->LCCVariantSummary? {
        placement(camera:camera,exifOrientation:exifOrientation,sensor:sensor,cameraBody:cameraBody,bodyOrientation:bodyOrientation)?.variant
    }
    public func placement(camera:String,exifOrientation:Int,sensor:SensorSize?,cameraBody:PanoramaCameraBody?=nil,
                          bodyOrientation:PanoramaBodyOrientation = .degrees0)->LCCProfilePlacement? {
        guard Self.cameraKey(camera) == Self.cameraKey(self.camera),
              let orientation = LCCCaptureOrientation(rawValue:exifOrientation), let sensor else { return nil }
        // Body model is capture provenance, not an optical compatibility restriction.
        // The lens/back calibration can be reused on another body with the same geometry.
        let rotations=cameraBody?.equivalentOrientations(to:bodyOrientation) ?? [bodyOrientation]
        for rotation in rotations {
            let relative=orientation.relative(to:rotation)
            let width=rotation.swapsAxes ? sensor.height:sensor.width,height=rotation.swapsAxes ? sensor.width:sensor.height
            if let variant=variants.first(where:{$0.orientation==relative && abs($0.sensorWidth-width)<0.3 && abs($0.sensorHeight-height)<0.3}) {
                return LCCProfilePlacement(variant:variant,bodyOrientation:rotation)
            }
        }
        return nil
    }
    static func cameraKey(_ s:String) -> String {
        s.components(separatedBy:"/")[0].trimmingCharacters(in:.whitespacesAndNewlines).uppercased()
    }
}
public struct LCCProfilePlacement {
    public let variant:LCCVariantSummary
    public let bodyOrientation:PanoramaBodyOrientation
}
public struct LCCVariantSummary: Codable, Equatable {
    public var orientation: LCCCaptureOrientation
    public var count: Int
    public var sensorWidth: Double
    public var sensorHeight: Double
}

public struct LCCProfileBinding: Equatable {
    public let profileID: UUID
    public let orientation: LCCCaptureOrientation
    public let captureCount: Int
    public init(profile: LCCProfileSummary, variant: LCCVariantSummary) {
        profileID=profile.id; orientation=variant.orientation; captureCount=variant.count
    }
}

public enum LCCShiftFilename {
    /// A suggestion, never confirmation. Unrecognised names must remain unassigned in the UI.
    public static func parse(_ filename:String) -> (x:Double,y:Double)? {
        let stem=URL(fileURLWithPath:filename).deletingPathExtension().lastPathComponent.uppercased()
        guard let re=try? NSRegularExpression(pattern:"^V([0-9]+(?:\\.[0-9]+)?)([UD]?)_H([0-9]+(?:\\.[0-9]+)?)([LR]?)$"),
              let m=re.firstMatch(in:stem,range:NSRange(stem.startIndex...,in:stem)) else { return nil }
        func part(_ i:Int)->String { Range(m.range(at:i),in:stem).map { String(stem[$0]) } ?? "" }
        guard let v=Double(part(1)),let h=Double(part(3)),(v==0 || !part(2).isEmpty),(h==0 || !part(4).isEmpty) else { return nil }
        return (h*(part(4)=="L" ? -1:1),v*(part(2)=="D" ? -1:1))
    }
}
