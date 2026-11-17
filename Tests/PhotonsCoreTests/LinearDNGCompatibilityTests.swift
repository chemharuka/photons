import XCTest
import CoreImage
@testable import PhotonsCore

final class LinearDNGCompatibilityTests:XCTestCase {
    func testLosslessRetilePreservesPixelsIncludingPartialTiles() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root)}
        let source=root.appendingPathComponent("strips.dng"),output=root.appendingPathComponent("tiles.dng")
        try stripFixture().write(to:source)
        try LinearDNGCompatibility.retile(source,to:output)
        let context=CIContext(options:[.cacheIntermediates:false])
        func pixels(_ url:URL)throws->[Float] {
            let filter=try XCTUnwrap(CIRAWFilter(imageURL:url));filter.boostAmount=0;filter.isGamutMappingEnabled=false
            let image=try XCTUnwrap(filter.outputImage)
            XCTAssertEqual(image.extent.size,CGSize(width:288,height:260))
            var values=[Float](repeating:0,count:288*260*4)
            context.render(image,toBitmap:&values,rowBytes:288*16,bounds:image.extent,format:.RGBAf,colorSpace:CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!)
            return values
        }
        let before=try pixels(source),after=try pixels(output)
        XCTAssertEqual(before.count,after.count)
        XCTAssertLessThan(zip(before,after).map {abs($0-$1)}.max()!,0.0001)
        XCTAssertLessThan(try Data(contentsOf:output).count,try Data(contentsOf:source).count)
    }

    func testBostonCaptureOneDNGCompatibility() throws {
        guard let path=ProcessInfo.processInfo.environment["PHOTONS_BOSTON_DIR"] else {throw XCTSkip("External Boston DNG fixtures")}
        for name in ["B0000662_Panorama.dng","B0000635_Panorama.dng"] {
            let source=URL(fileURLWithPath:path).appendingPathComponent(name)
            let before=try source.resourceValues(forKeys:[.fileSizeKey,.contentModificationDateKey])
            let image=try RAWDecoder().decode(source,options:DecodeOptions(scale:0.05))
            XCTAssertGreaterThan(image.width,1000)
            var r=0.0,g=0.0
            for i in stride(from:0,to:image.rgba.count,by:4) {r += Double(image.rgba[i]);g += Double(image.rgba[i+1])}
            XCTAssertGreaterThan(g,0);XCTAssertLessThan(r/g,1.6);XCTAssertGreaterThan(r/g,0.4)
            let cached=try LinearDNGCompatibility.cachedURL(for:source)
            print("DNG COMPATIBILITY",name,"source",before.fileSize ?? 0,"cache",try cached.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0,"decoded",image.width,image.height)
            let after=try source.resourceValues(forKeys:[.fileSizeKey,.contentModificationDateKey])
            XCTAssertEqual(before.fileSize,after.fileSize);XCTAssertEqual(before.contentModificationDate,after.contentModificationDate)
        }
    }

    private func stripFixture()->Data {
        func u16(_ v:UInt16)->Data {var n=v.littleEndian;return Data(bytes:&n,count:2)}
        func u32(_ v:UInt32)->Data {var n=v.littleEndian;return Data(bytes:&n,count:4)}
        var tags:[Int:(Int,Int,Data)]=[:]
        func shorts(_ tag:Int,_ values:[UInt16]) {tags[tag]=(3,values.count,values.reduce(Data()) {$0+u16($1)})}
        func longs(_ tag:Int,_ values:[UInt32]) {tags[tag]=(4,values.count,values.reduce(Data()) {$0+u32($1)})}
        func text(_ tag:Int,_ s:String) {let data=Data((s+"\0").utf8);tags[tag]=(2,data.count,data)}
        longs(254,[0]);longs(256,[288]);longs(257,[260]);shorts(258,[16,16,16]);shorts(259,[1]);shorts(262,[34892])
        shorts(277,[3]);longs(278,[260]);longs(273,[0]);longs(279,[288*260*6]);shorts(284,[1]);shorts(274,[1])
        text(271,"Photons");text(272,"Linear Panorama");text(50708,"Photons Linear Panorama")
        tags[50706]=(1,4,Data([1,4,0,0]));tags[50707]=(1,4,Data([1,3,0,0]));longs(50717,[65535,65535,65535]);shorts(50778,[21])
        tags[50728]=(5,3,[UInt32(1),1,1,1,1,1].reduce(Data()) {$0+u32($1)})
        let matrix=[3.2404542,-1.5371385,-0.4985314,-0.9692660,1.8760108,0.0415560,0.0556434,-0.2040259,1.0572252]
        tags[50721]=(10,9,matrix.reduce(Data()) {$0+u32(UInt32(bitPattern:Int32(($1*1_000_000).rounded())))+u32(1_000_000)})
        func header()->Data {
            var entries=Data(),extra=Data();let end=8+2+tags.count*12+4
            for (tag,t) in tags.sorted(by:{$0.key<$1.key}) {
                entries += u16(UInt16(tag))+u16(UInt16(t.0))+u32(UInt32(t.1))
                if t.2.count<=4 {entries += t.2+Data(repeating:0,count:4-t.2.count)}
                else {entries += u32(UInt32(end+extra.count));extra += t.2;if extra.count%2 != 0 {extra.append(0)}}
            }
            return Data([0x49,0x49,42,0])+u32(8)+u16(UInt16(tags.count))+entries+u32(0)+extra
        }
        longs(273,[UInt32(header().count)])
        var result=header()
        for y in 0..<260 {for x in 0..<288 {
            result += u16(UInt16(1000+x*100))+u16(UInt16(2000+y*100))+u16(UInt16(3000+(x+y)*50))
        }}
        return result
    }
}
