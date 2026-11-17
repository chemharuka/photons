#if os(iOS)
import PhotonsLocalization
import Foundation
import CoreGraphics
import Compression
import PhotonsCore

struct MobilePreviewPair: @unchecked Sendable {
    var hdr: MobileFrame
    var sdr: MobileFrame
    var rect: CGRect? = nil
    func frame(hdr enabled: Bool) -> MobileFrame { enabled ? hdr : sdr }
    var bytes: Int { hdr.image.bytesPerRow*hdr.image.height + sdr.image.bytesPerRow*sdr.image.height }
}
/// True LRU with byte budgets. Grid warming cannot evict a full-size photo or its opposite mode.
struct MobilePreviewMemoryCache {
    var budget: Int
    private(set) var bytes = 0
    private var entries: [String: MobilePreviewPair] = [:]
    private var order: [String] = []
    mutating func get(_ key: String) -> MobilePreviewPair? {
        guard let pair = entries[key] else { return nil }
        order.removeAll { $0 == key }; order.append(key); return pair
    }
    mutating func put(_ pair: MobilePreviewPair,key: String) {
        if let old = entries.removeValue(forKey: key) { bytes -= old.bytes }
        order.removeAll { $0 == key }
        guard pair.bytes <= budget else { return }
        while bytes + pair.bytes > budget, let oldest = order.first {
            order.removeFirst(); if let old = entries.removeValue(forKey: oldest) { bytes -= old.bytes }
        }
        entries[key] = pair; order.append(key); bytes += pair.bytes
    }
    mutating func clear() { entries.removeAll(); order.removeAll(); bytes = 0 }
}
struct MobileCachedPair: Codable {
    var hdr: MobileCachedPreview
    var sdr: MobileCachedPreview
    init(_ pair: MobilePreviewPair) throws { hdr = try .init(pair.hdr); sdr = try .init(pair.sdr) }
    func pair() throws -> MobilePreviewPair { try .init(hdr: hdr.frame(),sdr: sdr.frame()) }
}
/// Losslessly compressed half-float previews preserve highlight data across app launches.
/// Dimensions and histogram travel in the same atomic cache entry; old JPEG entries use a different key.
struct MobileCachedPreview: Codable {
    var width: Int
    var height: Int
    var rowBytes: Int
    var bitmapInfo: UInt32
    var headroom: Float
    var histogram: Histogram?
    var fullSize: ImageSize?
    var pixels: Data
    init(_ frame: MobileFrame) throws {
        let image = frame.image
        guard let bytes = image.dataProvider?.data else { throw MobileError.message(L10n.tr("ipad.cd6d72bf603e")) }
        width = image.width; height = image.height; rowBytes = image.bytesPerRow
        bitmapInfo = image.bitmapInfo.rawValue; headroom = image.contentHeadroom; histogram = frame.histogram
        fullSize = frame.fullSize
        let input = bytes as Data
        var compressed = Data(count: input.count + 4096)
        let count = compressed.withUnsafeMutableBytes { output in
            input.withUnsafeBytes { source in
                compression_encode_buffer(output.bindMemory(to: UInt8.self).baseAddress!,output.count,
                    source.bindMemory(to: UInt8.self).baseAddress!,source.count,nil,COMPRESSION_LZFSE)
            }
        }
        guard count > 0 else { throw MobileError.message(L10n.tr("ipad.bdef0977f78d")) }
        compressed.count = count; pixels = compressed
    }
    func frame() throws -> MobileFrame {
        guard (1...2048).contains(width), (1...2048).contains(height), rowBytes >= width*8, rowBytes <= width*8+1024, !pixels.isEmpty else {
            throw MobileError.message(L10n.tr("ipad.2207d378b4fa"))
        }
        // Decode into a fixed, validated buffer: corrupt cache data cannot expand without bound.
        var bytes = Data(count: rowBytes*height)
        let count = bytes.withUnsafeMutableBytes { output in
            pixels.withUnsafeBytes { input in
                compression_decode_buffer(output.bindMemory(to: UInt8.self).baseAddress!,output.count,
                    input.bindMemory(to: UInt8.self).baseAddress!,input.count,nil,COMPRESSION_LZFSE)
            }
        }
        guard count == bytes.count else { throw MobileError.message(L10n.tr("ipad.cab1190e041a")) }
        guard bytes.count == rowBytes*height, let provider = CGDataProvider(data: bytes as CFData),
              let image = CGImage(headroom: headroom,width: width,height: height,bitsPerComponent: 16,bitsPerPixel: 64,
                bytesPerRow: rowBytes,space: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!,
                bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),provider: provider,decode: nil,shouldInterpolate: true,intent: .defaultIntent) else {
            throw MobileError.message(L10n.tr("ipad.cab1190e041a"))
        }
        return MobileFrame(image: image,histogram: histogram,fullSize: fullSize)
    }
}

#endif
