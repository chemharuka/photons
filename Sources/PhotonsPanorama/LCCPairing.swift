import PhotonsLocalization
import Foundation
import CoreImage

public struct LCCInspection {
    public let source: PanoramaSource
    public let thumbnail: CGImage?
    public let likelyFlat: Bool
    public let clippedFraction: Double
    public let darkFraction: Double
    public let message: String
}

public enum LCCInspector {
    public static func inspect(_ url: URL) throws -> LCCInspection {
        let source = try PanoramaSource(url:url), engine = PanoramaEngine()
        let scale = min(1,640/max(source.size.width,source.size.height))
        let image = try engine.decoded(source,scale:scale,whiteBalance:nil)
        let raster = PanoramaRaster(image:image,context:engine.context,width:Int(image.extent.width),height:Int(image.extent.height))
        let gray = raster.gray
        var textured = 0, clipped = 0, dark = 0, total = 0
        for y in stride(from:4,to:gray.height-4,by:2) { for x in stride(from:4,to:gray.width-4,by:2) {
            let c = raster.rgb(Double(x),Double(y))!, p = y*gray.width+x
            let v = gray.values[p]
            let laplacian = abs(4*v-gray.values[p-2]-gray.values[p+2]-gray.values[p-gray.width*2]-gray.values[p+gray.width*2])
            if laplacian > 0.015 { textured += 1 }
            if max(c.x,c.y,c.z) >= 0.995 { clipped += 1 }
            if max(c.x,c.y,c.z) < 0.001 { dark += 1 }
            total += 1
        }}
        let fraction = Double(textured)/Double(max(1,total)), clip = Double(clipped)/Double(max(1,total)), black = Double(dark)/Double(max(1,total))
        let flat = fraction < 0.1 && black < 0.5
        var messages = [flat ? L10n.tr("5fecc8c5b050") : L10n.tr("bafa53262a70")]
        if clip > 0.01 { messages.append(L10n.tr("f29324f3114f" , String(describing: (Int(clip*100))))) }
        if black > 0.005 { messages.append(L10n.tr("2e52cbc0f6b8")) }
        let cg = engine.context.createCGImage(image,from:image.extent,format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!)
        return LCCInspection(source:source,thumbnail:cg,likelyFlat:flat,clippedFraction:clip,darkFraction:black,message:messages.joined(separator:"；"))
    }

    public static func incompatibility(scene: PanoramaSource, flat: PanoramaSource) -> String? {
        if scene.url.standardizedFileURL == flat.url.standardizedFileURL { return L10n.tr("22ae2734f10b") }
        if scene.size != flat.size { return L10n.tr("8883220d2555") }
        if scene.orientation != flat.orientation { return L10n.tr("d9bd50d31ae9") }
        if scene.camera != L10n.tr("1e3818fd0c54"), flat.camera != L10n.tr("1e3818fd0c54"), scene.camera != flat.camera { return L10n.tr("5d172d568146") }
        return nil
    }
}

public struct LCCPairRecord: Codable, Equatable {
    public let scene: URL
    public let flat: URL
    public let sceneSize: Int64
    public let flatSize: Int64
    public let sceneModified: Date
    public let flatModified: Date
    public let confirmed: Bool
    public init(scene: URL, flat: URL, confirmed: Bool) throws {
        self.scene = scene.standardizedFileURL; self.flat = flat.standardizedFileURL; self.confirmed = confirmed
        let a = try scene.resourceValues(forKeys:[.fileSizeKey,.contentModificationDateKey])
        let b = try flat.resourceValues(forKeys:[.fileSizeKey,.contentModificationDateKey])
        sceneSize = Int64(a.fileSize ?? 0); flatSize = Int64(b.fileSize ?? 0)
        sceneModified = a.contentModificationDate ?? .distantPast; flatModified = b.contentModificationDate ?? .distantPast
    }
    public var isCurrent: Bool {
        guard let current = try? LCCPairRecord(scene:scene,flat:flat,confirmed:confirmed) else { return false }
        return current == self
    }
}

/// Only explicitly confirmed pairs persist. A file replacement invalidates its stored pairing.
public struct LCCPairingStore {
    public let url: URL
    public init(url: URL? = nil) {
        self.url = url ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
            .appendingPathComponent("Photons/Panorama/LCC-pairs.json")
    }
    public func records() -> [LCCPairRecord] {
        guard let data = try? Data(contentsOf:url), let result = try? JSONDecoder().decode([LCCPairRecord].self,from:data) else { return [] }
        return result.filter { $0.confirmed && $0.isCurrent }
    }
    public func save(_ pairs: [LCCPairRecord]) throws {
        guard Set(pairs.map(\.scene)).count == pairs.count, Set(pairs.map(\.flat)).count == pairs.count else {
            throw PanoramaFailure(L10n.tr("39305921c957"))
        }
        var existing = records().filter { old in !pairs.contains { $0.scene == old.scene } }
        existing += pairs
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        try encoder.encode(existing).write(to:url,options:.atomic)
    }
}
