// PhotonsDepth — pixel-buffer geometry, so the depth model never hard-codes 518×392.
//
// The model's `MLImageConstraint` is the only source of truth for the input size and pixel format;
// this file turns an arbitrary decoded buffer into exactly that. vImage does the resampling (no
// third-party dependency), with a small manual conversion for the formats vImage cannot scale
// directly. Row 0 is the top row in every buffer that enters or leaves here.
import Accelerate
import CoreVideo
import Foundation

public enum PixelBufferResize {
    /// Allocates an IOSurface-backed buffer, which is what Core ML wants for image features.
    public static func makePixelBuffer(width: Int, height: Int, pixelFormat: OSType) throws -> CVPixelBuffer {
        precondition(width > 0 && height > 0, "pixel buffer needs a positive size")
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        var out: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, pixelFormat,
                                         attributes as CFDictionary, &out)
        guard status == kCVReturnSuccess, let buffer = out else {
            throw DepthError.inferenceFailed("CVPixelBufferCreate(\(width)×\(height)) failed: \(status)")
        }
        return buffer
    }

    /// Scales `source` to exactly `width × height` in `pixelFormat`. Returns a new buffer.
    public static func resize(_ source: CVPixelBuffer, width: Int, height: Int,
                              pixelFormat: OSType) throws -> CVPixelBuffer {
        let srcFormat = CVPixelBufferGetPixelFormatType(source)
        if isFourChannel8(srcFormat) && isFourChannel8(pixelFormat) {
            let dst = try makePixelBuffer(width: width, height: height, pixelFormat: pixelFormat)
            try scaleFourChannel(source, into: dst)
            return dst
        }
        if srcFormat == kCVPixelFormatType_OneComponent8 && pixelFormat == kCVPixelFormatType_OneComponent8 {
            let dst = try makePixelBuffer(width: width, height: height, pixelFormat: pixelFormat)
            try scalePlanar8(source, into: dst)
            return dst
        }
        // Anything else: normalise to BGRA8 at the source size, then let vImage scale.
        let bgra = try asBGRA8(source)
        if isFourChannel8(pixelFormat) {
            let dst = try makePixelBuffer(width: width, height: height, pixelFormat: pixelFormat)
            try scaleFourChannel(bgra, into: dst)
            return dst
        }
        // A one-component destination: scale first, then fold to luma.
        let scaled = try makePixelBuffer(width: width, height: height,
                                         pixelFormat: kCVPixelFormatType_32BGRA)
        try scaleFourChannel(bgra, into: scaled)
        return try gray(from: scaled, pixelFormat: pixelFormat)
    }

    /// A same-size BGRA8 view of `source` (the source itself when it is already BGRA).
    public static func asBGRA8(_ source: CVPixelBuffer) throws -> CVPixelBuffer {
        let format = CVPixelBufferGetPixelFormatType(source)
        if format == kCVPixelFormatType_32BGRA { return source }
        let w = CVPixelBufferGetWidth(source), h = CVPixelBufferGetHeight(source)
        let dst = try makePixelBuffer(width: w, height: h, pixelFormat: kCVPixelFormatType_32BGRA)
        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(dst, [])
        defer {
            CVPixelBufferUnlockBaseAddress(dst, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }
        guard let srcBase = CVPixelBufferGetBaseAddress(source),
              let dstBase = CVPixelBufferGetBaseAddress(dst) else {
            throw DepthError.inferenceFailed("pixel buffer has no base address")
        }
        let srcRow = CVPixelBufferGetBytesPerRow(source)
        let dstRow = CVPixelBufferGetBytesPerRow(dst)

        switch format {
        case kCVPixelFormatType_32ARGB:
            for y in 0..<h {
                let s = srcBase.advanced(by: y * srcRow).assumingMemoryBound(to: UInt8.self)
                let d = dstBase.advanced(by: y * dstRow).assumingMemoryBound(to: UInt8.self)
                for x in 0..<w {
                    let i = x * 4
                    d[i] = s[i + 3]      // B
                    d[i + 1] = s[i + 2]  // G
                    d[i + 2] = s[i + 1]  // R
                    d[i + 3] = s[i]      // A
                }
            }
        case kCVPixelFormatType_OneComponent8:
            for y in 0..<h {
                let s = srcBase.advanced(by: y * srcRow).assumingMemoryBound(to: UInt8.self)
                let d = dstBase.advanced(by: y * dstRow).assumingMemoryBound(to: UInt8.self)
                for x in 0..<w {
                    let v = s[x], i = x * 4
                    d[i] = v; d[i + 1] = v; d[i + 2] = v; d[i + 3] = 255
                }
            }
        case kCVPixelFormatType_OneComponent16Half:
            for y in 0..<h {
                let s = srcBase.advanced(by: y * srcRow).assumingMemoryBound(to: Float16.self)
                let d = dstBase.advanced(by: y * dstRow).assumingMemoryBound(to: UInt8.self)
                for x in 0..<w {
                    let v = UInt8(clamping: Int((min(max(Float(s[x]), 0), 1) * 255).rounded()))
                    let i = x * 4
                    d[i] = v; d[i + 1] = v; d[i + 2] = v; d[i + 3] = 255
                }
            }
        case kCVPixelFormatType_OneComponent32Float:
            for y in 0..<h {
                let s = srcBase.advanced(by: y * srcRow).assumingMemoryBound(to: Float.self)
                let d = dstBase.advanced(by: y * dstRow).assumingMemoryBound(to: UInt8.self)
                for x in 0..<w {
                    let v = UInt8(clamping: Int((min(max(s[x], 0), 1) * 255).rounded()))
                    let i = x * 4
                    d[i] = v; d[i + 1] = v; d[i + 2] = v; d[i + 3] = 255
                }
            }
        default:
            throw DepthError.featureMismatch("unsupported input pixel format \(fourCC(format))")
        }
        return dst
    }

    /// True for the four-byte, eight-bit-per-channel formats vImage scales as `ARGB8888`.
    public static func isFourChannel8(_ format: OSType) -> Bool {
        format == kCVPixelFormatType_32BGRA || format == kCVPixelFormatType_32ARGB
    }

    public static func fourCC(_ format: OSType) -> String {
        let bytes = [UInt8((format >> 24) & 0xff), UInt8((format >> 16) & 0xff),
                     UInt8((format >> 8) & 0xff), UInt8(format & 0xff)]
        let text = String(decoding: bytes, as: UTF8.self)
        return "\(text) (\(format))"
    }

    // MARK: - vImage

    private static func scaleFourChannel(_ src: CVPixelBuffer, into dst: CVPixelBuffer) throws {
        CVPixelBufferLockBaseAddress(src, .readOnly)
        CVPixelBufferLockBaseAddress(dst, [])
        defer {
            CVPixelBufferUnlockBaseAddress(dst, [])
            CVPixelBufferUnlockBaseAddress(src, .readOnly)
        }
        guard let s = CVPixelBufferGetBaseAddress(src), let d = CVPixelBufferGetBaseAddress(dst) else {
            throw DepthError.inferenceFailed("pixel buffer has no base address")
        }
        var source = vImage_Buffer(data: s,
                                   height: vImagePixelCount(CVPixelBufferGetHeight(src)),
                                   width: vImagePixelCount(CVPixelBufferGetWidth(src)),
                                   rowBytes: CVPixelBufferGetBytesPerRow(src))
        var target = vImage_Buffer(data: d,
                                   height: vImagePixelCount(CVPixelBufferGetHeight(dst)),
                                   width: vImagePixelCount(CVPixelBufferGetWidth(dst)),
                                   rowBytes: CVPixelBufferGetBytesPerRow(dst))
        // Channel order is irrelevant to a scale: BGRA is ARGB with the bytes swapped, and vImage
        // treats the buffer as four interleaved channels either way.
        let error = vImageScale_ARGB8888(&source, &target, nil,
                                         vImage_Flags(kvImageHighQualityResampling))
        guard error == kvImageNoError else {
            throw DepthError.inferenceFailed("vImageScale_ARGB8888 failed: \(error)")
        }
    }

    private static func scalePlanar8(_ src: CVPixelBuffer, into dst: CVPixelBuffer) throws {
        CVPixelBufferLockBaseAddress(src, .readOnly)
        CVPixelBufferLockBaseAddress(dst, [])
        defer {
            CVPixelBufferUnlockBaseAddress(dst, [])
            CVPixelBufferUnlockBaseAddress(src, .readOnly)
        }
        guard let s = CVPixelBufferGetBaseAddress(src), let d = CVPixelBufferGetBaseAddress(dst) else {
            throw DepthError.inferenceFailed("pixel buffer has no base address")
        }
        var source = vImage_Buffer(data: s,
                                   height: vImagePixelCount(CVPixelBufferGetHeight(src)),
                                   width: vImagePixelCount(CVPixelBufferGetWidth(src)),
                                   rowBytes: CVPixelBufferGetBytesPerRow(src))
        var target = vImage_Buffer(data: d,
                                   height: vImagePixelCount(CVPixelBufferGetHeight(dst)),
                                   width: vImagePixelCount(CVPixelBufferGetWidth(dst)),
                                   rowBytes: CVPixelBufferGetBytesPerRow(dst))
        let error = vImageScale_Planar8(&source, &target, nil,
                                        vImage_Flags(kvImageHighQualityResampling))
        guard error == kvImageNoError else {
            throw DepthError.inferenceFailed("vImageScale_Planar8 failed: \(error)")
        }
    }

    private static func gray(from bgra: CVPixelBuffer, pixelFormat: OSType) throws -> CVPixelBuffer {
        let w = CVPixelBufferGetWidth(bgra), h = CVPixelBufferGetHeight(bgra)
        let dst = try makePixelBuffer(width: w, height: h, pixelFormat: pixelFormat)
        CVPixelBufferLockBaseAddress(bgra, .readOnly)
        CVPixelBufferLockBaseAddress(dst, [])
        defer {
            CVPixelBufferUnlockBaseAddress(dst, [])
            CVPixelBufferUnlockBaseAddress(bgra, .readOnly)
        }
        guard let s = CVPixelBufferGetBaseAddress(bgra),
              let d = CVPixelBufferGetBaseAddress(dst) else {
            throw DepthError.inferenceFailed("pixel buffer has no base address")
        }
        let srcRow = CVPixelBufferGetBytesPerRow(bgra)
        let dstRow = CVPixelBufferGetBytesPerRow(dst)
        switch pixelFormat {
        case kCVPixelFormatType_OneComponent8:
            for y in 0..<h {
                let row = s.advanced(by: y * srcRow).assumingMemoryBound(to: UInt8.self)
                let out = d.advanced(by: y * dstRow).assumingMemoryBound(to: UInt8.self)
                for x in 0..<w {
                    let i = x * 4
                    out[x] = UInt8((Int(row[i + 2]) * 2126 + Int(row[i + 1]) * 7152
                                    + Int(row[i]) * 722) / 10_000)
                }
            }
        case kCVPixelFormatType_OneComponent16Half:
            for y in 0..<h {
                let row = s.advanced(by: y * srcRow).assumingMemoryBound(to: UInt8.self)
                let out = d.advanced(by: y * dstRow).assumingMemoryBound(to: Float16.self)
                for x in 0..<w {
                    let i = x * 4
                    out[x] = Float16(Float(Int(row[i + 2]) * 2126 + Int(row[i + 1]) * 7152
                                           + Int(row[i]) * 722) / 10_000 / 255)
                }
            }
        case kCVPixelFormatType_OneComponent32Float:
            for y in 0..<h {
                let row = s.advanced(by: y * srcRow).assumingMemoryBound(to: UInt8.self)
                let out = d.advanced(by: y * dstRow).assumingMemoryBound(to: Float.self)
                for x in 0..<w {
                    let i = x * 4
                    out[x] = Float(Int(row[i + 2]) * 2126 + Int(row[i + 1]) * 7152
                                   + Int(row[i]) * 722) / 10_000 / 255
                }
            }
        default:
            throw DepthError.featureMismatch("unsupported output pixel format \(fourCC(pixelFormat))")
        }
        return dst
    }
}
