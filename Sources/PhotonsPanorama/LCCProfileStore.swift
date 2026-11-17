import PhotonsLocalization
import Foundation
import CryptoKit
import Compression

/// A versioned single-file container: small JSON catalog header + binary property list,
/// losslessly compressed with LZFSE. SHA-256 covers both header and uncompressed payload.
/// Measured Float32 cells round-trip bit-for-bit. It contains no RAW files or source paths.
public enum LCCProfileCodec {
    private static let magic=Data("PHLCC002".utf8)
    private static let oldMagic=Data("PHLCC001".utf8)
    private static let maximumBytes=256*1024*1024
    public static func encode(_ profile:LCCLensProfile) throws -> Data {
        try profile.validate()
        let e=PropertyListEncoder();e.outputFormat = .binary
        let payload=try e.encode(transformed(profile,decode:false)), header=try JSONEncoder().encode(LCCProfileSummary(profile))
        guard payload.count<=maximumBytes,header.count<=65536 else { throw PanoramaFailure(L10n.tr("1a2fca964681")) }
        let compressed=try (payload as NSData).compressed(using:.lzfse) as Data
        var result=magic
        for size in [header.count,payload.count] { var n=UInt32(size).littleEndian;withUnsafeBytes(of:&n) { result.append(contentsOf:$0) } }
        result.append(contentsOf:SHA256.hash(data:header+payload));result.append(header);result.append(compressed)
        return result
    }
    /// Reversible per-channel Float32 bit-pattern deltas and byte-plane shuffle. This improves
    /// compression of smooth calibration grids without quantizing a single measured value.
    private static func transformed(_ original:LCCLensProfile,decode:Bool)->LCCLensProfile {
        func bytes(_ data:Data,channels:Int)->Data {
            guard channels>0,data.count%4==0 else {return data}
            let count=data.count/4;var output=Data(count:data.count),previous=[UInt32](repeating:0,count:channels)
            data.withUnsafeBytes { source in output.withUnsafeMutableBytes { target in
                let src=source.bindMemory(to:UInt8.self),dst=target.bindMemory(to:UInt8.self)
                for i in 0..<count {
                    let c=i%channels
                    if decode {
                        let z=UInt32(src[i]) | UInt32(src[count+i])<<8 | UInt32(src[2*count+i])<<16 | UInt32(src[3*count+i])<<24
                        let delta=(z>>1) ^ (0 &- (z&1)),value=previous[c] &+ delta;previous[c]=value
                        for b in 0..<4 {dst[i*4+b]=UInt8(truncatingIfNeeded:value>>UInt32(b*8))}
                    } else {
                        let value=UInt32(littleEndian:source.loadUnaligned(fromByteOffset:i*4,as:UInt32.self))
                        let delta=value &- previous[c];previous[c]=value
                        let z=(delta<<1) ^ UInt32(bitPattern:Int32(bitPattern:delta)>>31)
                        for b in 0..<4 {dst[b*count+i]=UInt8(truncatingIfNeeded:z>>UInt32(b*8))}
                    }
                }
            }}
            return output
        }
        func grid(_ original:LCCMeasurementGrid)->LCCMeasurementGrid {
            var g=original;g.values=bytes(g.values,channels:g.channels.count)
            if let e=g.standardError {g.standardError=bytes(e,channels:g.channels.count)};return g
        }
        var result=original
        for i in result.captures.indices {
            result.captures[i].grid=grid(result.captures[i].grid)
            if let g=result.captures[i].renderGrid {result.captures[i].renderGrid=grid(g)}
        }
        return result
    }
    private static func lengths(_ data:Data) throws -> (header:Int,payload:Int) {
        guard data.count>=48,(data.prefix(8)==magic || data.prefix(8)==oldMagic) else { throw PanoramaFailure(L10n.tr("2bf1caca5511")) }
        let h=data.withUnsafeBytes { Int(UInt32(littleEndian:$0.loadUnaligned(fromByteOffset:8,as:UInt32.self))) }
        let n=data.withUnsafeBytes { Int(UInt32(littleEndian:$0.loadUnaligned(fromByteOffset:12,as:UInt32.self))) }
        guard (1...65536).contains(h),(1...maximumBytes).contains(n) else { throw PanoramaFailure(L10n.tr("d11ed0770c8f")) }
        return (h,n)
    }
    public static func decode(_ data:Data) throws -> LCCLensProfile {
        let l=try lengths(data)
        guard data.count>48+l.header,data.count<=maximumBytes+65584 else { throw PanoramaFailure(L10n.tr("38a335e41104")) }
        let header=data.subdata(in:48..<48+l.header), compressed=data.subdata(in:48+l.header..<data.count)
        var payload=Data(count:l.payload)
        let count=payload.withUnsafeMutableBytes { dst in compressed.withUnsafeBytes { src in
            compression_decode_buffer(dst.bindMemory(to:UInt8.self).baseAddress!,l.payload,
                                      src.bindMemory(to:UInt8.self).baseAddress!,compressed.count,nil,COMPRESSION_LZFSE)
        }}
        guard count==l.payload,Data(SHA256.hash(data:header+payload))==data.subdata(in:16..<48) else {
            throw PanoramaFailure(L10n.tr("968cb9104ff5"))
        }
        var profile=try PropertyListDecoder().decode(LCCLensProfile.self,from:payload)
        if data.prefix(8)==magic {profile=transformed(profile,decode:true)}
        try profile.validate()
        guard try JSONDecoder().decode(LCCProfileSummary.self,from:header)==LCCProfileSummary(profile) else {
            throw PanoramaFailure(L10n.tr("8615cf543f0a"))
        }
        return profile
    }
    public static func summary(at url:URL) throws -> LCCProfileSummary {
        let handle=try FileHandle(forReadingFrom:url);defer { try? handle.close() }
        guard let prefix=try handle.read(upToCount:48) else { throw PanoramaFailure(L10n.tr("4fb3133ed0ee")) }
        let l=try lengths(prefix)
        guard let header=try handle.read(upToCount:l.header),header.count==l.header else { throw PanoramaFailure(L10n.tr("05bc388feca5")) }
        let summary=try JSONDecoder().decode(LCCProfileSummary.self,from:header)
        guard !summary.name.isEmpty,!summary.variants.isEmpty,summary.captureCount<=256 else { throw PanoramaFailure(L10n.tr("93604323ed6f")) }
        return summary
    }
}

public struct LCCProfileCatalog {
    public var profiles: [LCCProfileSummary]
    public var issues: [String]
}
public struct LCCProfileStore {
    public let directory: URL
    public init(directory:URL? = nil) {
        self.directory=directory ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
            .appendingPathComponent("Photons/LensProfiles",isDirectory:true)
    }
    public func url(for id:UUID)->URL { directory.appendingPathComponent(id.uuidString.lowercased()+".photonslcc") }
    public func installBundledProfile() throws {
        let target=url(for:LCCLensProfile.builtInID)
        // This is a developer-created user sample, not a protected official profile. Once copied,
        // the user's file owns this ID: application updates must never overwrite their edits.
        if FileManager.default.fileExists(atPath:target.path) { return }
        guard let source=Bundle.module.url(forResource:"43xl-iiic-cfv100c",withExtension:"photonslcc",subdirectory:"Profiles") else {
            throw PanoramaFailure(L10n.tr("a76334bd19b7"))
        }
        let bytes=try Data(contentsOf:source)
        let profile=try LCCProfileCodec.decode(bytes)
        guard profile.id==LCCLensProfile.builtInID else { throw PanoramaFailure(L10n.tr("5b744aed063f")) }
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        try bytes.write(to:target,options:.atomic)
    }
    public func catalog()->LCCProfileCatalog {
        guard FileManager.default.fileExists(atPath:directory.path) else { return .init(profiles:[],issues:[]) }
        do {
            let files=try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil)
                .filter { $0.pathExtension=="photonslcc" }
            var profiles:[LCCProfileSummary]=[],issues:[String]=[]
            for file in files {
                do {
                    let p=try LCCProfileCodec.summary(at:file)
                    guard file.lastPathComponent==url(for:p.id).lastPathComponent else { throw PanoramaFailure(L10n.tr("0c807b983a78")) }
                    profiles.append(p)
                } catch { issues.append("\(file.lastPathComponent)：\(error.localizedDescription)") }
            }
            profiles.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return .init(profiles:profiles,issues:issues)
        } catch { return .init(profiles:[],issues:[error.localizedDescription]) }
    }
    public func load(_ id:UUID) throws -> LCCLensProfile {
        let u=url(for:id)
        let size=try u.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
        guard size>0,size<=256*1024*1024+65584 else { throw PanoramaFailure(L10n.tr("8c7ee4e7adb6")) }
        let profile=try LCCProfileCodec.decode(Data(contentsOf:u))
        guard profile.id==id else { throw PanoramaFailure(L10n.tr("848d4385ac80")) }
        return profile
    }
    @discardableResult public func save(_ profile:LCCLensProfile) throws -> URL {
        let data=try LCCProfileCodec.encode(profile)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let target=url(for:profile.id);try data.write(to:target,options:.atomic);return target
    }
    /// Identity belongs to a calibration, not to its lens/back name or capture body.
    /// Keep an imported revision alongside the local one without changing archived references.
    @discardableResult public func importProfile(_ profile:LCCLensProfile,keepingBoth:Bool) throws -> LCCProfileSummary {
        try profile.validate()
        var imported=profile
        if keepingBoth && FileManager.default.fileExists(atPath:url(for:profile.id).path) {
            // Older bundled samples infer their capture body from the fixed ID.
            imported.cameraBody=LCCProfileSummary(profile).calibrationBody
            imported.id=UUID()
            let names=Set(catalog().profiles.map(\.name)),base=String(profile.name.prefix(180))
            var number=2
            while names.contains("\(base) · \(number)") {number += 1}
            imported.name="\(base) · \(number)"
        }
        try save(imported)
        return LCCProfileSummary(imported)
    }
}
