import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import PhotonsCore

// MARK: - 111 · PQ / HLG output
//
// The S4 exit gives us extended-range **linear** pixels in the preset's primaries. Writing PQ or HLG
// is then a colour-space conversion, not a hand-written ST 2084 / BT.2100 curve: Core Image maps the
// linear source to the same family's PQ/HLG space (Rec.709_PQ, DisplayP3_PQ, Rec.2100_PQ; the HLG
// column is analogous) and we let ImageIO pack the result. The pairing is toGainMapHDR's table
// (`main.swift:78-100`); a P3 base never silently becomes Rec.2100. The curve constants therefore
// live in exactly one place (CoreGraphics' colour management), and a future change to the target
// space is a one-line edit here.
//
// Outputs:
//   · HEIC / AVIF — RGBA16 handed to ImageIO, which stores the 10-bit HEVC/AV1 primary item
//     (measured: asking for 16 reads back 10; the container has no 16-bit mode).
//   · TIFF / PNG  — RGBA16, read back as 16.
public enum HDREncoding {

    /// The linear source space matching the renderer's primaries. `CIImage` must be told what the
    /// half-float samples mean, otherwise Core Image assumes linear sRGB and a P3/Rec.2020 export is
    /// converted through the wrong matrix.
    public static func linearColorSpace(for primaries: OutputPrimaries) -> CGColorSpace? {
        switch primaries {
        case .sRGB: return CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        case .displayP3: return CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        case .rec2020: return CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)
        }
    }

    /// Rec.2020 with the requested transfer function. `nil` for every non-PQ/HLG kind.
    ///
    /// 163 §1.5 — the curve's **primaries come from the base family**, exactly like toGainMapHDR's
    /// `main.swift:78-100` table:
    ///
    /// | base              | SDR space                 | PQ                  | HLG                  |
    /// |-------------------|---------------------------|---------------------|----------------------|
    /// | sRGB / Rec.709    | `itur_709`                | `itur_709_PQ`       | `itur_709_HLG`       |
    /// | Display P3        | `displayP3`               | `displayP3_PQ`      | `displayP3_HLG`      |
    /// | Rec.2020          | `itur_2020_sRGBGamma`     | `itur_2100_PQ`      | `itur_2100_HLG`      |
    ///
    /// A P3 base never silently becomes Rec.2100; that was the pre-163 behaviour this replaces.
    public static func targetColorSpace(for primaries: OutputPrimaries,
                                        kind: HDRKind) -> CGColorSpace? {
        switch (primaries, kind) {
        case (.sRGB, .pq): return CGColorSpace(name: CGColorSpace.itur_709_PQ)
        case (.sRGB, .hlg): return CGColorSpace(name: CGColorSpace.itur_709_HLG)
        case (.displayP3, .pq): return CGColorSpace(name: CGColorSpace.displayP3_PQ)
        case (.displayP3, .hlg): return CGColorSpace(name: CGColorSpace.displayP3_HLG)
        case (.rec2020, .pq): return CGColorSpace(name: CGColorSpace.itur_2100_PQ)
        case (.rec2020, .hlg): return CGColorSpace(name: CGColorSpace.itur_2100_HLG)
        case (_, .none), (_, .gainMap): return nil
        }
    }

    /// The SDR base a gain map / PQ / HLG export is tagged with. Plain SDR exports keep the historic
    /// `Exporter.colorSpace(for:)` tags (byte identity); only the HDR pair uses this table.
    public static func sdrColorSpace(for primaries: OutputPrimaries) -> CGColorSpace? {
        switch primaries {
        case .sRGB: return CGColorSpace(name: CGColorSpace.itur_709)
        case .displayP3: return CGColorSpace(name: CGColorSpace.displayP3)
        case .rec2020: return CGColorSpace(name: CGColorSpace.itur_2020_sRGBGamma)
        }
    }

    /// The linear counterpart of the SDR family space (the ISO gain map's `colr`/aux colour space).
    public static func linearSDRColorSpace(for primaries: OutputPrimaries) -> CGColorSpace? {
        switch primaries {
        case .sRGB: return CGColorSpace(name: CGColorSpace.linearSRGB)
        case .displayP3: return CGColorSpace(name: CGColorSpace.linearDisplayP3)
        case .rec2020: return CGColorSpace(name: CGColorSpace.linearITUR_2020)
        }
    }

    /// Convert `image`'s linear companion to a PQ/HLG-tagged `CGImage`.
    ///
    /// The linear samples are handed over as half floats (no clamp), so highlights above display
    /// white survive into the PQ code space instead of being flattened at 1.0.
    ///
    /// **HLG is encoded here, not by ColorSync.** The absolute-luminance convention has to be the
    /// same as PQ's: SDR white (linear 1.0) is 203 nits, and HLG's 1000-nit ceiling is therefore
    /// 4.926× (+2.303 EV). `HLGCurve` is the single place those numbers live. Letting Core Image
    /// own the `extendedLinear → *_HLG` step made the file's absolute mapping a property of the
    /// OS's colour tables instead of this code; a change there turns into "the HLG export is
    /// brighter than the PQ one" with no pixel change on our side. Encoding the BT.2100 curve
    /// directly makes the file's codes a function of the pixels only. PQ stays on the Core Image
    /// path (its numbers are the accepted baseline).
    public static func cgImage(for image: DisplayImage, kind: HDRKind) throws -> CGImage {
        guard kind == .hlg || kind == .pq else {
            throw ExportError.encodeFailed("\(kind.rawValue) is not a PQ/HLG kind")
        }
        guard let linear = image.linear else {
            throw ExportError.encodeFailed(
                "\(kind.displayName) export needs the linear render (s4_display_linear)")
        }
        guard linear.width == image.width, linear.height == image.height else {
            throw ExportError.encodeFailed(
                "linear render is \(linear.width)×\(linear.height) but the SDR base is "
                + "\(image.width)×\(image.height)")
        }
        guard let source = linearColorSpace(for: image.primaries) else {
            throw ExportError.encodeFailed(
                "linear color space unavailable: \(image.primaries.displayName)")
        }
        guard let target = targetColorSpace(for: image.primaries, kind: kind) else {
            throw ExportError.encodeFailed("\(kind.displayName) color space unavailable")
        }
        if kind == .hlg {
            return try hlgCGImage(linear, colorSpace: target)
        }

        // 238 — no row flip. `CIImage(bitmapData:)` maps row 0 to row 0 of the CGImage it later
        // produces, exactly like the raw `CGImage` providers below, and DisplayImage is stored
        // top-row-first. The flip that used to live here was based on the opposite assumption and
        // made every PQ container (PNG/TIFF/HEIC/AVIF) upside down while SDR/HLG/gain map stayed
        // upright. `ExportOrientationTests` pins all paths to the SDR row order.
        let w = image.width, h = image.height
        let data = linear.rgba.withUnsafeBufferPointer { Data(buffer: $0) }
        let ci = CIImage(bitmapData: data, bytesPerRow: w * 8,
                         size: CGSize(width: w, height: h), format: .RGBAh, colorSpace: source)
        // Pin both working and output space: letting Core Image pick a working space would route a
        // P3 picture through linear sRGB before the Rec.2020 conversion.
        let context = CIContext(options: [.workingColorSpace: source, .outputColorSpace: target])
        guard let out = context.createCGImage(ci, from: ci.extent, format: .RGBA16,
                                              colorSpace: target) else {
            throw ExportError.encodeFailed("Core Image could not convert to \(kind.displayName)")
        }
        return out
    }

    /// BT.2100 HLG, quantified for **photo** export: diffuse white is 203 nits on a 1000-nit
    /// display, so linear 1.0 lands on signal ≈0.75 and the 4.926× ceiling (+2.303 EV) on 1.0.
    ///
    /// The constants are ARIB STD-B67's OETF. `referenceWhite` exists only so the regression suite
    /// can build a deliberately wrong encode (1000 instead of 203) and prove the gate catches it.
    enum HLGCurve {
        static let referenceWhiteNits = 203.0
        static let peakNits = 1000.0
        /// BT.2100 system gamma for a 1000-nit reference display.
        static let systemGamma = 1.2
        private static let a = 0.17883277
        private static let b = 0.28466892
        private static let c = 0.55991073

        /// Absolute linear (SDR white = 1.0) → HLG signal 0…1.
        static func signal(forLinear value: Double,
                           referenceWhite: Double = referenceWhiteNits,
                           peak: Double = peakNits) -> Double {
            guard value > 0, peak > 0, referenceWhite > 0 else { return 0 }
            let nits = value * referenceWhite
            let scene = pow(min(nits / peak, 1), 1.0 / systemGamma)
            if scene <= 1.0 / 12.0 { return (3.0 * scene).squareRoot() }
            return a * log(12.0 * scene - b) + c
        }
    }

    /// RGBA16 with the BT.2100 HLG signal already in the samples; ImageIO only packs it.
    private static func hlgCGImage(_ linear: LinearPixels,
                                   colorSpace: CGColorSpace) throws -> CGImage {
        let w = linear.width, h = linear.height
        var words = [UInt16](repeating: 0, count: w * h * 4)
        for i in stride(from: 0, to: words.count, by: 4) {
            let alpha = Double(min(max(Float(linear.rgba[i + 3]), 0), 1))
            for c in 0..<3 {
                let signal = HLGCurve.signal(forLinear: Double(Float(linear.rgba[i + c])))
                // premultipliedLast: the exporter's frames are opaque, but keep the semantics.
                let code = min(max((signal * alpha * 65535.0).rounded(), 0), 65535)
                words[i + c] = UInt16(code)
            }
            words[i + 3] = UInt16((alpha * 65535.0).rounded())
        }
        // DisplayImage is top-row first, which is also CGImage's row order — no flip here.
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                                | CGBitmapInfo.byteOrder16Little.rawValue)
        guard let provider = CGDataProvider(
                data: Data(words.withUnsafeBufferPointer { Data(buffer: $0) }) as CFData),
              let cg = CGImage(width: w, height: h, bitsPerComponent: 16, bitsPerPixel: 64,
                               bytesPerRow: w * 8, space: colorSpace, bitmapInfo: info,
                               provider: provider, decode: nil, shouldInterpolate: false,
                               intent: .defaultIntent) else {
            throw ExportError.bitmapContextFailed
        }
        return cg
    }

    /// Write a PQ/HLG file. Returns non-fatal notes (empty on the normal path).
    @discardableResult
    public static func write(_ image: DisplayImage, to url: URL, options: ExportOptions,
                             metadata: ExportMetadataContext = ExportMetadataContext())
        throws -> [String] {
        guard let kind = options.hdr?.kind, kind == .hlg || kind == .pq else {
            throw ExportError.encodeFailed("not a PQ/HLG export")
        }
        let cg = try cgImage(for: image, kind: kind)

        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, options.format.utType.identifier as CFString, 1, nil) else {
            throw ExportError.destinationFailed(url)
        }
        var properties = metadata.properties(outputWidth: image.width, outputHeight: image.height,
                                             format: options.format)
        if options.format.supportsQuality {
            // AVIF's HDR path rejects quality 1.0 (`CGImageDestinationFinalize` returns false);
            // 0.99 is still visually lossless and keeps the file writable.
            let quality = options.format == .avif ? min(options.quality, 0.99) : options.quality
            properties[kCGImageDestinationLossyCompressionQuality] = quality
        }
        if let xmp = metadata.xmpMetadata(outputWidth: image.width,
                                          outputHeight: image.height) {
            CGImageDestinationAddImageAndMetadata(dest, cg, xmp, properties as CFDictionary)
        } else {
            CGImageDestinationAddImage(dest, cg, properties as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else {
            throw ExportError.finalizeFailed(url)
        }
        // The PNG writer always emits its own EXIF block; `.none` means none (107).
        if metadata.level == .none && options.format == .png {
            try Exporter.stripMetadata(at: url)
        }
        return []
    }
}
