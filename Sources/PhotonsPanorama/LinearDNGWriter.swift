import PhotonsLocalization
import Foundation
import PhotonsCore
import CoreImage
import ImageIO
import PhotonsExtensions

/// A new, demosaiced linear DNG. Never inherits source CFA, crop, lens opcodes or camera matrices:
/// those describe camera samples, whereas these samples are in linear sRGB after stitching.
public enum LinearDNGWriter {
    public static func write(image: CIImage, context: CIContext, to url: URL,
                             manifest: Data? = nil, cancellation: PanoramaCancellation = .init(),
                             progress: PanoramaEngine.Progress = { _ in }) throws {
        // Linear DNG has RGB samples and no alpha. Never encode premultiplied RGB: partial
        // coverage at resampled joins would become permanent dark lines in the RAW samples.
        let image = PanoramaEngine.normalizedCoverage(image)
        let width = Int(image.extent.width), height = Int(image.extent.height), tile = 256
        guard width>0, height>0, width*height<600_000_000 else { throw PanoramaFailure(L10n.tr("12dd189a96f3")) }
        var maximum = [Float](repeating:0,count:4)
        let maxImage = image.applyingFilter("CIAreaMaximum",parameters:["inputExtent":CIVector(cgRect:image.extent)])
        context.render(maxImage,toBitmap:&maximum,rowBytes:16,bounds:CGRect(x:0,y:0,width:1,height:1),format:.RGBAf,colorSpace:PanoramaEngine.linearSpace)
        // Store highlight headroom, and restore its scene exposure through BaselineExposure.
        let range = Double(max(1,maximum[0],maximum[1],maximum[2]))
        guard range.isFinite else { throw PanoramaFailure(L10n.tr("378062584513")) }
        let scaled = image.applyingFilter("CIExposureAdjust",parameters:["inputEV":-log2(range)])
        let nx = (width+tile-1)/tile, ny = (height+tile-1)/tile
        var offsets = [UInt32](repeating:0,count:nx*ny), sizes = offsets
        struct Entry { var tag: UInt16; var type: UInt16; var count: Int; var bytes: Data }
        func u16(_ v: UInt16) -> Data { var v = v.littleEndian; return Data(bytes:&v,count:2) }
        func u32(_ v: UInt32) -> Data { var v = v.littleEndian; return Data(bytes:&v,count:4) }
        func rational(_ value: Double) -> Data {
            u32(UInt32(bitPattern:Int32((value*1_000_000).rounded())))+u32(1_000_000)
        }
        var tags: [Entry] = []
        func short(_ t: UInt16, _ v: [UInt16]) { tags.append(Entry(tag:t,type:3,count:v.count,bytes:v.reduce(Data()) { $0+u16($1) })) }
        func long(_ t: UInt16, _ v: [UInt32]) { tags.append(Entry(tag:t,type:4,count:v.count,bytes:v.reduce(Data()) { $0+u32($1) })) }
        func text(_ t: UInt16, _ v: String) { let data = Data((v+"\0").utf8); tags.append(Entry(tag:t,type:2,count:data.count,bytes:data)) }
        func rationals(_ t: UInt16, _ v: [Double], signed: Bool = false) { tags.append(Entry(tag:t,type:signed ? 10:5,count:v.count,bytes:v.reduce(Data()) { $0+rational($1) })) }
        long(254,[0]); long(256,[UInt32(width)]); long(257,[UInt32(height)])
        short(258,[16,16,16]); short(259,[7]); short(262,[34892]); short(274,[1]); short(277,[3]); short(284,[1])
        text(271,"Photons"); text(272,"Photons Linear Panorama"); text(305,"Photons shift panorama")
        short(339,[1,1,1]); long(322,[UInt32(tile)]); long(323,[UInt32(tile)])
        long(324,offsets); long(325,sizes)
        tags.append(Entry(tag:50706,type:1,count:4,bytes:Data([1,4,0,0])))
        tags.append(Entry(tag:50707,type:1,count:4,bytes:Data([1,3,0,0])))
        text(50708,"Photons Linear Panorama")
        long(50717,[65535,65535,65535]); rationals(50714,[0,0,0])
        rationals(50718,[1,1]); long(50719,[0,0]); long(50720,[UInt32(width),UInt32(height)])
        rationals(50721,[3.2404542,-1.5371385,-0.4985314,-0.9692660,1.8760108,0.0415560,0.0556434,-0.2040259,1.0572252],signed:true)
        rationals(50728,[1,1,1]); rationals(50730,[log2(range)],signed:true)
        short(50778,[21]); long(50829,[0,0,UInt32(height),UInt32(width)])
        // Explicit scene-linear camera profile: readers must not substitute their default
        // contrast/saturation look. ForwardMatrix maps linear sRGB to D50 PCS.
        text(50936,"Photons Scene Linear")
        rationals(50964,[0.4360747,0.3850649,0.1430804,0.2225045,0.7168786,0.0606169,0.0139322,0.0971045,0.7141733],signed:true)
        tags.append(Entry(tag:50940,type:11,count:4,bytes:[Float(0),0,1,1].reduce(Data()) {$0+u32($1.bitPattern)}))
        long(51110,[1]) // DefaultBlackRender: none
        rationals(51109,[0],signed:true)
        if let manifest {
            let metadata=CGImageMetadataCreateMutable()
            CGImageMetadataRegisterNamespaceForPrefix(metadata,"https://photons.app/ns/panorama/1.0/" as CFString,"photonsPano" as CFString,nil)
            CGImageMetadataSetValueWithPath(metadata,nil,"photonsPano:Manifest" as CFString,PanoramaMetadataPacket.string(manifest) as CFString)
            if let xmp=CGImageMetadataCreateXMPData(metadata,nil) as Data? {
                tags.append(Entry(tag:700,type:1,count:xmp.count,bytes:xmp))
            }
        }
        // IFD0 is an actual RGB thumbnail. The lossless linear image lives in a SubIFD.
        let previewScale=min(1,512/Double(max(width,height)))
        let pw=max(1,Int(Double(width)*previewScale)),ph=max(1,Int(Double(height)*previewScale))
        let preview=SDRProjection.image(image.transformed(by:CGAffineTransform(scaleX:previewScale,y:previewScale)))
        var rgba=[UInt8](repeating:0,count:pw*ph*4)
        context.render(preview,toBitmap:&rgba,rowBytes:pw*4,bounds:CGRect(x:0,y:0,width:pw,height:ph),format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!)
        var thumb=Data(count:pw*ph*3)
        thumb.withUnsafeMutableBytes { raw in
            let out=raw.bindMemory(to:UInt8.self)
            for i in 0..<pw*ph {for c in 0..<3 {out[i*3+c]=rgba[i*4+c]}}
        }
        let rootTags:Set<UInt16>=[271,272,305,700,50706,50707,50708,50721,50728,50730,50778,50936,50940,50964,51109,51110]
        var root=tags.filter {rootTags.contains($0.tag)}
        tags.removeAll {rootTags.contains($0.tag)}
        func re(_ tag:UInt16,_ type:UInt16,_ values:[UInt32])->Entry {
            Entry(tag:tag,type:type,count:values.count,bytes:values.reduce(Data()) {$0+(type==3 ? u16(UInt16($1)):u32($1))})
        }
        root += [re(254,4,[1]),re(256,4,[UInt32(pw)]),re(257,4,[UInt32(ph)]),re(258,3,[8,8,8]),re(259,3,[1]),re(262,3,[2]),re(273,4,[0]),re(274,3,[1]),re(277,3,[3]),re(278,4,[UInt32(ph)]),re(279,4,[UInt32(thumb.count)]),re(284,3,[1]),re(330,4,[0]),re(50970,4,[2])]
        root.sort {$0.tag<$1.tag}
        tags.sort { $0.tag < $1.tag }
        func header() -> Data {
            let rawIFD=8+2+root.count*12+4
            let payloadOffset=rawIFD+2+tags.count*12+4
            var payload=Data()
            func ifd(_ entries:[Entry], raw:Bool)->Data {
                var out=u16(UInt16(entries.count))
                for entry in entries {
                    var bytes=entry.bytes
                    if raw && entry.tag==324 {bytes=offsets.reduce(Data()) {$0+u32($1)}}
                    if raw && entry.tag==325 {bytes=sizes.reduce(Data()) {$0+u32($1)}}
                    if !raw && entry.tag==330 {bytes=u32(UInt32(rawIFD))}
                    out += u16(entry.tag)+u16(entry.type)+u32(UInt32(entry.count))
                    if bytes.count<=4 {out += bytes+Data(repeating:0,count:4-bytes.count)}
                    else {
                        out += u32(UInt32(payloadOffset+payload.count));payload += bytes
                        if payload.count%2 != 0 {payload.append(0)}
                    }
                }
                return out+u32(0)
            }
            var first=ifd(root,raw:false)
            let second=ifd(tags,raw:true)
            let thumbOffset=UInt32(payloadOffset+payload.count)
            if let index=root.firstIndex(where:{$0.tag==273}) {
                first.replaceSubrange((2+index*12+8)..<(2+index*12+12),with:u32(thumbOffset))
            }
            return Data([0x49,0x49,42,0])+u32(8)+first+second+payload+thumb
        }
        FileManager.default.createFile(atPath:url.path,contents:nil)
        let file = try FileHandle(forWritingTo:url)
        defer { try? file.close() }
        try file.write(contentsOf:header())
        var pixels = [UInt16](repeating:0,count:tile*tile*4)
        for ty in 0..<ny { for tx in 0..<nx {
            try cancellation.check()
            if tx == 0 { progress(L10n.tr("726b933bf36a" , String(describing: (ty+1)), String(describing: (ny)))) }
            // Both TIFF and CIContext's bitmap rows are top-first. Bounds, however, use Core
            // Image's lower-left origin. Walk bounds from top to bottom without reversing rows.
            let rect = CGRect(x:tx*tile,y:height-(ty+1)*tile,width:tile,height:tile)
            context.render(scaled,toBitmap:&pixels,rowBytes:tile*8,bounds:rect,format:.RGBA16,colorSpace:PanoramaEngine.linearSpace)
            var rgb = [UInt16](repeating:0,count:tile*tile*3)
            for y in 0..<tile { for x in 0..<tile {
                let src = (y*tile+x)*4, dst = (y*tile+x)*3
                rgb[dst] = pixels[src]; rgb[dst+1] = pixels[src+1]; rgb[dst+2] = pixels[src+2]
            }}
            let tables = RawLosslessJPEG.buildTables([rgb],width:tile*3,height:tile,components:3)
            let blob = rgb.withUnsafeBufferPointer { RawLosslessJPEG.encode($0,width:tile*3,height:tile,components:3,tables:tables) }
            let position = try file.offset()
            guard position+UInt64(blob.count)<UInt64(UInt32.max) else { throw PanoramaFailure(L10n.tr("45b5f91bb4eb")) }
            offsets[ty*nx+tx] = UInt32(position); sizes[ty*nx+tx] = UInt32(blob.count)
            try file.write(contentsOf:Data(blob))
        }}
        try file.seek(toOffset:0); try file.write(contentsOf:header()); try file.synchronize()
    }
}
