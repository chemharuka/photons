import Foundation
import CoreImage
import ImageIO
import CryptoKit
import PhotonsImageCodecs

/// Apple's RAW decoder can return a solid error image for large strip-based linear DNGs.
/// Repack the same 16-bit samples into lossless JPEG tiles in a disposable compatibility cache.
/// The original, its metadata, and the catalog's identity never change.
public enum LinearDNGCompatibility {
    private static let lock = NSLock()
    public static let recipeVersion = "linear-dng-tiles-1"

    public static func filter(for url: URL, initial: CIRAWFilter) throws -> CIRAWFilter {
        guard url.pathExtension.lowercased()=="dng",
              let source=CGImageSourceCreateWithURL(url as CFURL,nil),
              let properties=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
              let w=properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let h=properties[kCGImagePropertyPixelHeight] as? NSNumber else {return initial}
        let area=w.doubleValue*h.doubleValue,native=initial.nativeSize.width*initial.nativeSize.height
        guard area>0,native<area*0.5 else {return initial}
        let compatible=try cachedURL(for:url)
        guard let filter=CIRAWFilter(imageURL:compatible),filter.nativeSize.width*filter.nativeSize.height>area*0.9 else {
            throw DecodeError.badDimensions(initial.nativeSize)
        }
        return filter
    }

    public static func cachedURL(for url:URL) throws -> URL {
        lock.lock();defer {lock.unlock()}
        let attributes=try url.resourceValues(forKeys:[.fileSizeKey,.contentModificationDateKey])
        let identity="\(recipeVersion)|\(url.standardizedFileURL.path)|\(attributes.fileSize ?? 0)|\(attributes.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        let digest=SHA256.hash(data:Data(identity.utf8)).map {String(format:"%02x",$0)}.joined()
        let root=FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0].appendingPathComponent("Photons/LinearDNG",isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let result=root.appendingPathComponent(digest+".dng")
        if FileManager.default.fileExists(atPath:result.path) {
            try? FileManager.default.setAttributes([.modificationDate:Date()],ofItemAtPath:result.path)
            return result
        }
        let staging=root.appendingPathComponent(UUID().uuidString+".partial")
        defer {if FileManager.default.fileExists(atPath:staging.path) {try? FileManager.default.removeItem(at:staging)}}
        try retile(url,to:staging)
        do {try FileManager.default.moveItem(at:staging,to:result)}
        catch {if !FileManager.default.fileExists(atPath:result.path) {throw error}}
        // Trim old conversions above 4 GiB; do not evict files used in the last 24 hours.
        let files=(try? FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:[.fileSizeKey,.contentModificationDateKey])) ?? []
        let old=files.filter {$0.pathExtension=="dng" && $0 != result}.sorted {
            ((try? $0.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                < ((try? $1.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
        var size=files.reduce(0) {$0+((try? $1.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0)}
        for file in old where size>4*1024*1024*1024 {
            let modified=(try? file.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? Date()
            guard modified.timeIntervalSinceNow < -86400 else {continue}
            let bytes=(try? file.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0
            if (try? FileManager.default.removeItem(at:file)) != nil {size -= bytes}
        }
        return result
    }

    struct Tag {var type:UInt16;var count:Int;var data:Data}
    static func retile(_ source:URL,to destination:URL) throws {
        let input=try Data(contentsOf:source,options:.mappedIfSafe)
        func fail() -> DecodeError { .unsupportedFile(source) }
        guard input.count>=8,input[0]==0x49,input[1]==0x49 else {throw fail()}
        func integer(_ offset:Int,_ bytes:Int)throws -> Int {
            guard offset>=0,offset<=input.count-bytes else {throw fail()}
            var value=0;for i in 0..<bytes {value |= Int(input[offset+i]) << (8*i)};return value
        }
        guard try integer(2,2)==42 else {throw fail()}
        let lengths=[0,1,1,2,4,8,1,1,2,4,8,4,8,4]
        func tags(_ offset:Int)throws->[Int:Tag] {
            let n=try integer(offset,2);guard n<=512 else {throw fail()}
            var result:[Int:Tag]=[:]
            for i in 0..<n {
                let entry=offset+2+i*12,tag=try integer(entry,2),type=try integer(entry+2,2),count=try integer(entry+4,4)
                guard type>0,type<lengths.count else {continue}
                let length=count*lengths[type]
                guard length<=32*1024*1024 else {throw fail()}
                let start=length<=4 ? entry+8:try integer(entry+8,4)
                guard start>=0,start<=input.count-length else {throw fail()}
                result[tag]=Tag(type:UInt16(type),count:count,data:input.subdata(in:start..<start+length))
            };return result
        }
        func numbers(_ tag:Tag?) -> [Int] {
            guard let tag,tag.type==3 || tag.type==4 || tag.type==13 else {return []}
            let bytes=tag.type==3 ? 2:4
            return (0..<tag.count).map {i in (0..<bytes).reduce(0) {$0 | Int(tag.data[i*bytes+$1]) << (8*$1)}}
        }
        let root=try tags(integer(4,4))
        var raw=root
        if numbers(raw[262]).first != 34892 {
            var found=false
            for pointer in numbers(root[330]) {
                let candidate=try tags(pointer)
                if numbers(candidate[262]).first==34892,numbers(candidate[254]).first ?? 0 == 0 {raw=candidate;found=true;break}
            }
            guard found else {throw fail()}
        }
        guard numbers(raw[259]).first==1,numbers(raw[277]).first==3,
              numbers(raw[258])==[16,16,16],numbers(raw[284]).first ?? 1 == 1,
              let width=numbers(raw[256]).first,let height=numbers(raw[257]).first,
              width>0,height>0,width*height<600_000_000 else {throw fail()}
        let rows=numbers(raw[278]).first ?? height,offsets=numbers(raw[273]),counts=numbers(raw[279])
        guard rows>0,offsets.count==(height+rows-1)/rows,counts.count==offsets.count else {throw fail()}
        for i in offsets.indices {
            let count=min(rows,height-i*rows)*width*6
            guard counts[i]>=count,offsets[i]>=0,offsets[i]<=input.count-count else {throw fail()}
        }
        func u16(_ value:UInt16)->Data {var v=value.littleEndian;return Data(bytes:&v,count:2)}
        func u32(_ value:UInt32)->Data {var v=value.littleEndian;return Data(bytes:&v,count:4)}
        func shorts(_ values:[UInt16])->Tag {Tag(type:3,count:values.count,data:values.reduce(Data()) {$0+u16($1)})}
        func longs(_ values:[UInt32])->Tag {Tag(type:4,count:values.count,data:values.reduce(Data()) {$0+u32($1)})}
        var output=root.merging(raw) {_,new in new}.filter {
            // All DNG calibration/profile/opcode tags keep their exact bytes. Container-specific
            // private maker data and pointers to other IFDs do not belong to this decode cache.
            ($0.key>=50706 && $0.key<=52544 && ![50740,50827,50828].contains($0.key)) || [271,272,274].contains($0.key)
        }
        output[50706]=Tag(type:1,count:4,data:Data([1,4,0,0]));output[50707]=Tag(type:1,count:4,data:Data([1,3,0,0]))
        output[254]=longs([0]);output[256]=longs([UInt32(width)]);output[257]=longs([UInt32(height)])
        output[258]=shorts([16,16,16]);output[259]=shorts([7]);output[262]=shorts([34892]);output[277]=shorts([3]);output[284]=shorts([1])
        if output[50717]==nil {output[50717]=longs([65535,65535,65535])}
        let tile=256,nx=(width+tile-1)/tile,ny=(height+tile-1)/tile
        output[322]=longs([UInt32(tile)]);output[323]=longs([UInt32(tile)])
        output[324]=longs([UInt32](repeating:0,count:nx*ny));output[325]=output[324]
        func header()->Data {
            var payload=Data(),entries=Data();let start=8+2+output.count*12+4
            for (tag,value) in output.sorted(by:{$0.key<$1.key}) {
                entries += u16(UInt16(tag))+u16(value.type)+u32(UInt32(value.count))
                if value.data.count<=4 {entries += value.data+Data(repeating:0,count:4-value.data.count)}
                else {entries += u32(UInt32(start+payload.count));payload += value.data;if payload.count%2 != 0 {payload.append(0)}}
            }
            return Data([0x49,0x49,42,0])+u32(8)+u16(UInt16(output.count))+entries+u32(0)+payload
        }
        FileManager.default.createFile(atPath:destination.path,contents:nil)
        let file=try FileHandle(forWritingTo:destination);defer {try? file.close()}
        try file.write(contentsOf:header())
        var tileOffsets:[UInt32]=[],tileCounts:[UInt32]=[]
        try input.withUnsafeBytes { bytes in
            let base=bytes.baseAddress!
            for ty in 0..<ny {for tx in 0..<nx {
                var rgb=[UInt16](repeating:0,count:tile*tile*3)
                rgb.withUnsafeMutableBytes { target in
                    for y in 0..<min(tile,height-ty*tile) {
                        let row=ty*tile+y,start=offsets[row/rows]+(row%rows)*width*6+tx*tile*6
                        memcpy(target.baseAddress!+y*tile*6,base+start,min(tile,width-tx*tile)*6)
                    }
                }
                let tables=RawLosslessJPEG.buildTables([rgb],width:tile*3,height:tile,components:3)
                let blob=rgb.withUnsafeBufferPointer {RawLosslessJPEG.encode($0,width:tile*3,height:tile,components:3,tables:tables)}
                let position=try file.offset()
                guard position+UInt64(blob.count)<UInt64(UInt32.max) else {throw fail()}
                tileOffsets.append(UInt32(position));tileCounts.append(UInt32(blob.count));try file.write(contentsOf:Data(blob))
            }}
        }
        output[324]=longs(tileOffsets);output[325]=longs(tileCounts)
        try file.seek(toOffset:0);try file.write(contentsOf:header());try file.synchronize()
    }
}
