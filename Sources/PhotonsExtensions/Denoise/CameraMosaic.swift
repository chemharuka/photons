import Foundation

/// Black-subtracted camera samples. No white balance, demosaic or colour conversion has run.
/// Supports little-endian Bayer DNG and the uncompressed CFV 100C 3FR layout. Unknown layouts
/// fail explicitly; a developed RGB image must never masquerade as camera samples.
public struct CameraMosaic {
    public let width:Int, height:Int
    public var samples:[Float]
    /// Fraction of original saturated samples in each proxy CFA site; full-resolution uses samples directly.
    public var clipping:[Float]? = nil
    public let pattern:[Int] // R=0, first green=1, B=2, second green=3
    public let orientation:Int
    private var metadata:[UInt16:TIFFEntry]
    public var neutral:[Double] { metadata[50728]?.numbers ?? [1,1,1] }

    // Module fixture initializer: the production reader always obtains this information from RAW.
    init(width:Int,height:Int,samples:[Float],pattern:[Int],orientation:Int=1,neutral:[Double],matrix:[Double]) {
        self.width=width;self.height=height;self.samples=samples;self.pattern=pattern;self.orientation=orientation
        func entry(_ values:[Double],signed:Bool)->TIFFEntry {
            TIFFEntry(type:signed ? 10:5,count:values.count,value:values.flatMap {
                DNGRawWriter.u32(UInt32(bitPattern:Int32(($0*1_000_000).rounded())))+DNGRawWriter.u32(1_000_000)
            })
        }
        let model=Array("Photons Test Camera\0".utf8)
        metadata=[271:TIFFEntry(type:2,count:8,value:Array("Photons\0".utf8)),272:TIFFEntry(type:2,count:model.count,value:model),
                  50708:TIFFEntry(type:2,count:model.count,value:model),50721:entry(matrix,signed:true),50728:entry(neutral,signed:false),
                  50778:TIFFEntry(type:3,count:1,value:[21,0])]
    }
    public init(url:URL,visibleWidth:Int,visibleHeight:Int,maxDimension:Int?=nil) throws {
        let data=try Data(contentsOf:url,options:.alwaysMapped),source=try SourceDNG(data:data)
        let tags=source.ifd0.merging(source.raw) {_,new in new}
        let w=Int(tags[256]?.firstUInt32 ?? 0),h=Int(tags[257]?.firstUInt32 ?? 0)
        guard w>0,h>0,w*h<=250_000_000,tags[258]?.firstUInt32==16,tags[277]?.firstUInt32==1 else {throw Self.failure("需要 16 位 Bayer RAW")}
        let is3FR=url.pathExtension.lowercased()=="3fr"
        var cfa=tags[33422]?.value.map(Int.init) ?? []
        if is3FR,cfa.isEmpty {
            let model=String(bytes:tags[272]?.value ?? [],encoding:.utf8) ?? ""
            guard model.contains("CFV 100C"),tags[259]?.firstUInt32==1 else {throw Self.failure("此 3FR 型号/压缩格式尚未支持原始通道 LCC")}
            cfa=[0,1,1,2]
        }
        guard (is3FR || tags[33421]?.numbers == [2,2]),cfa.count==4,cfa.filter({$0==0}).count==1,cfa.filter({$0==2}).count==1,cfa.filter({$0==1}).count==2,
              tags[50721]?.count==9 else {throw Self.failure("RAW 缺少受支持的 Bayer 排列或相机色彩矩阵")}
        if let i=cfa.lastIndex(of:1) {cfa[i]=3}
        for tag:UInt16 in [50712,50715,50716,51008,51009,51022] where tags[tag] != nil {
            throw Self.failure("此 RAW 含额外的线性化或像素校准，暂不支持原始通道 LCC")
        }
        let crop=tags[50719]?.numbers ?? [0,0],size=tags[50720]?.numbers ?? [Double(w),Double(h)]
        guard crop.count==2,size.count==2 else {throw Self.failure("RAW 裁切信息无效")}
        // Apple/LibRaw include a four-pixel demosaic margin around Hasselblad DefaultCrop.
        let active=tags[50829]?.numbers ?? [0,0,Double(h),Double(w)]
        guard active.count==4 else {throw Self.failure("RAW ActiveArea 无效")}
        let left=Int(active[1]+crop[0])-(visibleWidth-Int(size[0]))/2,top=Int(active[0]+crop[1])-(visibleHeight-Int(size[1]))/2
        guard left>=0,top>=0,visibleWidth>0,visibleHeight>0,left+visibleWidth<=w,top+visibleHeight<=h,
              visibleWidth%2==0,visibleHeight%2==0 else {throw Self.failure("RAW 有效区域与系统解码尺寸不一致")}
        let black=tags[50714]?.numbers ?? [0],white=tags[50717]?.numbers.first ?? 65535
        guard black.count==1 || black.count==4,black.allSatisfy({$0.isFinite && $0<white}),white<=65535 else {throw Self.failure("RAW 黑白电平无效")}
        let mosaic=try source.readMosaic(data:data)
        let factor=max(1,maxDimension.map {Int(ceil(Double(max(visibleWidth,visibleHeight))/Double($0)))} ?? 1)
        width=(visibleWidth/2+factor-1)/factor*2;height=(visibleHeight/2+factor-1)/factor*2
        pattern=(0..<4).map {cfa[((top+$0/2)%2)*2+(left+$0%2)%2]}
        orientation=Int(tags[274]?.firstUInt32 ?? 1)
        metadata=tags.filter { [271,272,50708,50721,50722,50723,50724,50727,50728,50778,50779,50964,50965].contains($0.key) }
        if metadata[50778]==nil {metadata[50778]=TIFFEntry(type:3,count:1,value:[21,0])}
        samples=[Float](repeating:0,count:width*height)
        if factor>1 {clipping=[Float](repeating:0,count:width*height)}
        for by in 0..<height/2 {for bx in 0..<width/2 {for site in 0..<4 {
            var sum=0.0,count=0,clipped=0
            for dy in 0..<factor {let y=(by*factor+dy)*2+site/2;guard y<visibleHeight else {continue}
                for dx in 0..<factor {let x=(bx*factor+dx)*2+site%2;guard x<visibleWidth else {continue}
                    let b=black.count==1 ? black[0]:black[((top+y)%2)*2+(left+x)%2]
                    let sample=Double(mosaic.samples[(top+y)*w+left+x])
                    sum += (sample-b)/(white-b);count += 1;if sample>=white-4 {clipped += 1}
                }
            }
            let destination=(by*2+site/2)*width+bx*2+site%2
            samples[destination]=Float(sum/Double(max(1,count)))
            if factor>1 {clipping?[destination]=Float(clipped)/Float(max(1,count))}
        }}}
    }
    private static func failure(_ message:String)->NSError {NSError(domain:"Photons.CameraMosaic",code:1,userInfo:[NSLocalizedDescriptionKey:message])}

    /// A temporary CFA DNG for Apple's demosaic and calibrated WB/colour matrix. Quantization is
    /// global and reversible in exposure: spatial gains are supplied as OpcodeList2 and therefore
    /// remain floating point inside the RAW processor, before demosaic and colour conversion.
    public func dng(samples values:[Float]?=nil,neutral:[Double]?=nil,gainOpcode:Data?=nil)->(data:Data,exposure:Double) {
        let values=values ?? samples
        let peak=Double(values.max() ?? 1),range=max(1,peak*1.001)
        var tags=metadata
        func put(_ t:UInt16,_ type:UInt16,_ count:Int,_ b:[UInt8]) {tags[t]=TIFFEntry(type:type,count:count,value:b)}
        func short(_ t:UInt16,_ v:[UInt16]) {put(t,3,v.count,v.flatMap(DNGRawWriter.u16))}
        func long(_ t:UInt16,_ v:[UInt32]) {put(t,4,v.count,v.flatMap(DNGRawWriter.u32))}
        func rational(_ t:UInt16,_ v:[Double]) {put(t,5,v.count,v.flatMap {DNGRawWriter.u32(UInt32(($0*1_000_000).rounded()))+DNGRawWriter.u32(1_000_000)})}
        long(254,[0]);long(256,[UInt32(width)]);long(257,[UInt32(height)]);short(258,[16]);short(259,[1]);short(262,[32803])
        short(274,[UInt16(orientation)]);short(277,[1]);short(284,[1]);short(339,[1]);long(273,[0]);long(278,[UInt32(height)]);long(279,[UInt32(width*height*2)])
        short(33421,[2,2]);put(33422,1,4,pattern.map {UInt8($0==3 ? 1:$0)})
        put(50706,1,4,[1,4,0,0]);put(50707,1,4,[1,3,0,0]);put(50710,1,3,[0,1,2]);short(50711,[1])
        short(50713,[1,1]);rational(50714,[0]);long(50717,[65535]);rational(50718,[1,1]);long(50719,[0,0]);long(50720,[UInt32(width),UInt32(height)])
        long(50829,[0,0,UInt32(height),UInt32(width)])
        if let neutral {rational(50728,neutral)}
        if let gainOpcode {put(51009,7,gainOpcode.count,Array(gainOpcode))}
        let sorted=tags.keys.sorted(),base=8+2+sorted.count*12+4
        let extra=sorted.reduce(0) {n,t in n+(tags[t]!.value.count>4 ? (tags[t]!.value.count+1)/2*2:0)}
        long(273,[UInt32(base+extra)])
        var output=Data([0x49,0x49,42,0,8,0,0,0]);output.append(contentsOf:DNGRawWriter.u16(UInt16(sorted.count)))
        var payload=Data()
        for t in sorted {let e=tags[t]!;output.append(contentsOf:DNGRawWriter.u16(t)+DNGRawWriter.u16(e.type)+DNGRawWriter.u32(UInt32(e.count)))
            if e.value.count<=4 {output.append(contentsOf:e.value+[UInt8](repeating:0,count:4-e.value.count))}
            else {output.append(contentsOf:DNGRawWriter.u32(UInt32(base+payload.count)));payload.append(contentsOf:e.value);if payload.count%2 != 0 {payload.append(0)}}
        }
        output.append(contentsOf:[0,0,0,0]);output.append(payload)
        var encoded=[UInt16](repeating:0,count:values.count)
        for i in values.indices {encoded[i]=UInt16(max(0,min(65535,(Double(values[i])/range*65535).rounded()))).littleEndian}
        encoded.withUnsafeBytes {output.append(contentsOf:$0)}
        return (output,log2(range))
    }
}

extension TIFFEntry {
    var numbers:[Double] {
        let data=Data(value),step=TIFFReader.componentSize(type)
        guard step>0,value.count>=count*step else {return []}
        return (0..<count).map {i in
            let p=i*step
            switch type {
            case 1:return Double(value[p])
            case 3:return Double(TIFFReader.u16(data,p) ?? 0)
            case 4:return Double(TIFFReader.u32(data,p) ?? 0)
            case 5,10:
                let a=TIFFReader.u32(data,p) ?? 0,b=TIFFReader.u32(data,p+4) ?? 1
                return type==10 ? Double(Int32(bitPattern:a))/Double(max(1,b)):Double(a)/Double(max(1,b))
            default:return .nan
            }
        }
    }
}
