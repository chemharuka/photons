import Foundation
import Compression

/// Compact XMP values keep real panorama seam masks below ImageIO's metadata limits.
/// The uncompressed payload is still the portable JSON manifest; old base64 JSON remains readable.
public enum PanoramaMetadataPacket {
    private static let limit = 32 * 1024 * 1024

    public static func string(_ data: Data) -> String {
        guard !data.isEmpty, data.count <= limit else { return data.base64EncodedString() }
        var compressed = Data(count: data.count + 1024)
        let capacity = compressed.count
        let count = compressed.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard count > 0, count < data.count else { return data.base64EncodedString() }
        compressed.count = count
        // COMPRESSION_ZLIB emits a raw DEFLATE stream, without a zlib wrapper.
        return "deflate:\(data.count):\(compressed.base64EncodedString())"
    }

    public static func data(_ value: String) -> Data? {
        guard value.utf8.count <= limit else { return nil }
        guard value.hasPrefix("deflate:") else { return Data(base64Encoded: value) }
        let fields = value.split(separator: ":", maxSplits: 2)
        guard fields.count == 3, let size = Int(fields[1]), size > 0, size <= limit,
              let input = Data(base64Encoded: String(fields[2])), !input.isEmpty else { return nil }
        // One spare byte distinguishes exactly sized output from truncated/decompression-bomb output.
        var output = Data(count: size + 1)
        let count = output.withUnsafeMutableBytes { dst in
            input.withUnsafeBytes { src in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, size + 1,
                    src.bindMemory(to: UInt8.self).baseAddress!, input.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard count == size else { return nil }
        output.count = count
        return output
    }
}
