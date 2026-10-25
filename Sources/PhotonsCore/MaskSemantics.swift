import Foundation
import CoreGraphics
import CoreImage
import CoreVideo
import CryptoKit
import Vision

// MARK: - 005e: semantic mattes
//
// docs/tasks/005-masks.md §5. A semantic mask is an *intent* plus a raster the OS produced; the
// bitmap never enters the document (§2). Two routes, tried in this order, per file and per kind:
//
//   1. `CIRAWFilter`'s read-only mattes (`CIRAWFilter.h:202–207`): sky, hair, skin, teeth, glasses
//      and `portraitEffectsMatte` for a person. On this machine's Leica DNG **all of them are nil**
//      (docs/research/apple-raw-stack.md §2), which is exactly why the probe is per file and a nil
//      is a value, not an error.
//   2. Vision: `VNGenerateForegroundInstanceMaskRequest` (macOS 14) for subject/foreground,
//      `VNGeneratePersonSegmentationRequest` for a person. There is no request for sky, hair, skin,
//      teeth or glasses, so those kinds are simply unavailable without a system matte.
//
// When neither route answers, the component contributes **zero coverage** and the stage report
// carries `semanticUnavailable(kind:reason:)` — never an exception, never a guess (§5.1).
//
// Licensing (§5.3): Vision and CoreImage are OS frameworks; no model weights are redistributed, so
// the MIT position is unchanged. Nothing here is derived from ART / RawTherapee / darktable
// (GPL-3.0) or RapidRAW (AGPL-3.0).

/// Why a semantic matte could not be produced. Part of the report, so the UI can say which hint to
/// show instead of a generic failure.
public enum SemanticUnavailableReason: String, Sendable, Codable, CaseIterable {
    /// `CIRAWFilter` opened the file and the matte for this kind was `nil`.
    case noSystemMatte
    /// Vision has no request for this kind (sky, hair, skin, teeth, glasses).
    case noVisionRequest
    /// A Vision request existed but produced nothing usable (no model, no subject, a failure).
    case visionFailed
    /// The system-matte route needs the file, and this graph was built without a source URL.
    case noSourceURL
    /// The route named by `SemanticShape.provider` forbids the fallback (a `systemMatte` mask never
    /// silently becomes a Vision mask — §5.1 is a capability, not a substitution).
    case routeDoesNotAllowFallback

    public var displayName: String {
        switch self {
        case .noSystemMatte: return "this file has no system matte"
        case .noVisionRequest: return "no system model for this kind"
        case .visionFailed: return "the system model found nothing"
        case .noSourceURL: return "no source file"
        case .routeDoesNotAllowFallback: return "the system matte is unavailable for this file"
        }
    }
}

/// A resolved matte, row-major, `values[y * width + x] ∈ 0…1`, row 0 = **top** of the source.
///
/// Resolution is the analysis resolution (≤ `analysisLongEdge`, §5.2's 1024 budget), not the source's:
/// the matte is upsampled bilinearly by the atlas kernel, which is what keeps the model cost off the
/// frame path. `digest` is the SHA-256 of the samples — the value that goes into
/// `SemanticShape.rasterDigest` and that a future OS model change would move (§5.3).
public struct SemanticRaster: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let values: [Float]
    /// Which route produced it — `systemMatte` or `visionForeground`, never the *intent*.
    public let provider: SemanticProvider
    public let modelVersion: String
    public let digest: String

    public init(width: Int, height: Int, values: [Float],
                provider: SemanticProvider, modelVersion: String) {
        self.width = max(1, width)
        self.height = max(1, height)
        self.values = values
        self.provider = provider
        self.modelVersion = modelVersion
        self.digest = SemanticRaster.digest(width: self.width, height: self.height,
                                           values: values, provider: provider,
                                           modelVersion: modelVersion)
    }

    /// Content digest. Includes the dimensions, the provider and the model version: two rasters that
    /// differ in any of those are different selections even if a sample happens to match.
    public static func digest(width: Int, height: Int, values: [Float],
                              provider: SemanticProvider, modelVersion: String) -> String {
        var data = Data()
        withUnsafeBytes(of: UInt32(max(0, width)).littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(max(0, height)).littleEndian) { data.append(contentsOf: $0) }
        data.append(contentsOf: Array(provider.rawValue.utf8))
        data.append(0)
        data.append(contentsOf: Array(modelVersion.utf8))
        data.append(0)
        values.withUnsafeBytes { data.append(contentsOf: $0) }
        var hasher = SHA256()
        hasher.update(data: data)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Nearest sample with clamp-to-edge, for a caller that wants the raw texel.
    public func value(x: Int, y: Int) -> Float {
        let cx = min(max(x, 0), width - 1)
        let cy = min(max(y, 0), height - 1)
        guard values.indices.contains(cy * width + cx) else { return 0 }
        return values[cy * width + cx]
    }

    /// Bilinear sample at normalised `(u, v)` with clamp-to-edge — **the same convention the atlas
    /// kernel's `filter::linear` sampler uses** (texel centres at `(i + 0.5) / n`), so a test can
    /// compare the GPU against this function instead of against an impression.
    public func sample(u: Double, v: Double) -> Double {
        let fx = u * Double(width) - 0.5
        let fy = v * Double(height) - 0.5
        let x0 = Int(fx.rounded(.down)), y0 = Int(fy.rounded(.down))
        let tx = fx - Double(x0), ty = fy - Double(y0)
        let c00 = Double(value(x: x0, y: y0)), c10 = Double(value(x: x0 + 1, y: y0))
        let c01 = Double(value(x: x0, y: y0 + 1)), c11 = Double(value(x: x0 + 1, y: y0 + 1))
        let top = c00 + (c10 - c00) * tx
        let bottom = c01 + (c11 - c01) * tx
        return top + (bottom - top) * ty
    }

    /// §5.2's `softEdge`: `smoothstep(½ − s/2, ½ + s/2, raw)`. Larger = softer edge; `s = 0` is a
    /// hard threshold at 0.5. Mirrored exactly by `semantic_alpha` in `s1_5_mask_atlas.metal`.
    public func coverage(u: Double, v: Double, softEdge: Double) -> Double {
        let raw = min(max(sample(u: u, v: v), 0), 1)
        let s = min(max(softEdge, 0), 1)
        let lo = 0.5 - 0.5 * s
        let hi = max(0.5 + 0.5 * s, lo + 1e-5)
        let t = min(max((raw - lo) / (hi - lo), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// Bilinear resize onto another grid. A `texture2d_array` has one size for every slice, and two
    /// semantic components may resolve at different analysis resolutions (one from a CI matte, one
    /// from Vision), so the graph resamples rather than assuming they agree.
    public func resized(width newWidth: Int, height newHeight: Int) -> [Float] {
        let w = max(1, newWidth), h = max(1, newHeight)
        if w == width && h == height { return values }
        var out = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            let v = (Double(y) + 0.5) / Double(h)
            for x in 0..<w {
                let u = (Double(x) + 0.5) / Double(w)
                out[y * w + x] = Float(sample(u: u, v: v))
            }
        }
        return out
    }

    /// Fraction of samples above zero — the "non-zero area" a test asserts on.
    public var nonZeroFraction: Double {
        guard !values.isEmpty else { return 0 }
        var n = 0
        for v in values where v > 0 { n += 1 }
        return Double(n) / Double(values.count)
    }
}

/// What a provider is handed: the decoded linear buffer (the same pixels the graph renders), an
/// identity to cache on, and the file if the caller knows it.
///
/// The linear buffer is deliberate: `CIRAWFilter` and Vision both want a picture, and re-decoding the
/// RAW to get one would pay the decode twice. `url` is optional because a preview path may hand over
/// a decoded buffer with no file behind it — then only the Vision route is available.
public struct SemanticMatteSource: Sendable {
    public let width: Int
    public let height: Int
    /// Linear scene RGBA half floats, straight from `LinearImage`.
    public let rgba: [Float16]
    /// `RenderInput.identity` (the decode digest). The cache key's first component (§5.2).
    public let contentHash: String
    public let url: URL?

    public init(width: Int, height: Int, rgba: [Float16], contentHash: String, url: URL? = nil) {
        self.width = width
        self.height = height
        self.rgba = rgba
        self.contentHash = contentHash
        self.url = url
    }

    public init(image: LinearImage, contentHash: String, url: URL? = nil) {
        self.init(width: image.width, height: image.height, rgba: image.rgba,
                  contentHash: contentHash, url: url)
    }
}

/// Result of one resolution. `unavailable` is a value, not a thrown error: §5.1 requires a document
/// whose matte the OS cannot produce to keep rendering (with an empty selection and a reason).
public enum SemanticMatteResult: Sendable, Equatable {
    case raster(SemanticRaster)
    case unavailable(SemanticUnavailableReason)

    public var raster: SemanticRaster? {
        if case .raster(let r) = self { return r }
        return nil
    }

    public var reason: SemanticUnavailableReason? {
        if case .unavailable(let r) = self { return r }
        return nil
    }
}

/// One route to a matte. Injected into `RenderGraph` so tests can hand over a synthetic matte
/// without a RAW file, a GPU model or 120 ms of Vision.
public protocol SemanticMatteProvider {
    /// Part of the cache key. Changes when the OS model changes, not when the picture does.
    var modelVersion: String { get }
    func matte(kind: SemanticKind, route: SemanticProvider,
               source: SemanticMatteSource) -> SemanticMatteResult
}

/// In-memory only (§5.2 explicitly says no disk cache: a matte is derived data, and a stale one
/// silently changes a selection).
///
/// Key = `contentHash | kind | modelVersion`, plus the **route**, because the two routes produce
/// different rasters for the same model: a `systemMatte` mask and a `visionForeground` mask at the
/// same kind must not share an entry. Misses are cached too — an unavailable matte costs a Vision
/// timeout on every frame otherwise, and the second call is the one that has to be cheap (§6 005e ③).
public final class SemanticMatteStore {
    private var entries: [String: SemanticMatteResult] = [:]
    /// How many times the provider was actually asked. A test asserts the second call is a hit.
    public private(set) var providerCalls = 0

    public init() {}

    public var entryCount: Int { entries.count }

    public func reset() {
        entries.removeAll()
        providerCalls = 0
    }

    public static func cacheKey(kind: SemanticKind, route: SemanticProvider,
                                modelVersion: String, contentHash: String) -> String {
        "\(contentHash)|\(kind.rawValue)|\(modelVersion)|\(route.rawValue)"
    }

    public func resolve(kind: SemanticKind, route: SemanticProvider,
                        source: SemanticMatteSource,
                        provider: SemanticMatteProvider) -> SemanticMatteResult {
        let key = SemanticMatteStore.cacheKey(kind: kind, route: route,
                                              modelVersion: provider.modelVersion,
                                              contentHash: source.contentHash)
        if let hit = entries[key] { return hit }
        providerCalls += 1
        let result = provider.matte(kind: kind, route: route, source: source)
        entries[key] = result
        return result
    }
}

/// Which route can serve which kind — the capability table of §5.1/§5.2 as data, so the UI's
/// "why is this disabled" answer and the renderer's behaviour cannot drift.
public enum SemanticRoute {
    /// The seven kinds 005e ships.
    public static let kinds: [SemanticKind] = [.sky, .subject, .person, .hair, .skin, .teeth, .glasses]

    /// Kinds `CIRAWFilter` can answer (`CIRAWFilter.h:202–207`).
    public static func systemMatteSupports(_ kind: SemanticKind) -> Bool {
        switch kind {
        case .sky, .hair, .skin, .teeth, .glasses, .person: return true
        case .subject, .foreground: return false
        }
    }

    /// Kinds Vision can answer. Sky/hair/skin/teeth/glasses have no request — §5.2 keeps that
    /// explicit instead of shipping a home-grown model.
    public static func visionSupports(_ kind: SemanticKind) -> Bool {
        switch kind {
        case .subject, .foreground, .person: return true
        case .sky, .hair, .skin, .teeth, .glasses: return false
        }
    }
}

// MARK: - the system provider (CIRAWFilter, then Vision)

/// The production route: `CIRAWFilter`'s per-file mattes first, Vision second, zero coverage third.
public struct SystemSemanticMatteProvider: SemanticMatteProvider {
    /// §5.2's budget: the model runs on a ≤ 1024-long-edge copy, never on the full frame.
    public let analysisLongEdge: Int

    public init(analysisLongEdge: Int = 1024) {
        self.analysisLongEdge = max(64, analysisLongEdge)
    }

    public var modelVersion: String {
        "system|" + ProcessInfo.processInfo.operatingSystemVersionString
            .replacingOccurrences(of: " ", with: "_")
    }

    public func matte(kind: SemanticKind, route: SemanticProvider,
                      source: SemanticMatteSource) -> SemanticMatteResult {
        // ① the system matte, probed per file (§5.1: never cached per camera model).
        if let url = source.url, SemanticRoute.systemMatteSupports(kind) {
            if let raster = SemanticMatteProbe.raster(url: url, kind: kind,
                                                      modelVersion: modelVersion,
                                                      analysisLongEdge: analysisLongEdge) {
                return .raster(raster)
            }
        }
        // A `systemMatte` mask is a promise about *this file's* matte: it does not fall back to a
        // model, because a Vision guess is a different selection than the one the user asked for.
        guard route == .visionForeground else {
            return .unavailable(source.url == nil ? .noSourceURL : .routeDoesNotAllowFallback)
        }
        // ② Vision.
        return VisionMatte.raster(kind: kind, source: source, longEdge: analysisLongEdge,
                                  modelVersion: modelVersion)
    }
}

/// `CIRAWFilter`'s read-only mattes, one file at a time.
public enum SemanticMatteProbe {
    /// Which kinds this file actually carries. Opening the file is the cost (~0.2–1 s for a 66 MB
    /// DNG); the answer is an environment fact and belongs in memory, never in the document.
    public static func availability(url: URL) -> [SemanticKind: Bool] {
        guard let filter = CIRAWFilter(imageURL: url) else { return [:] }
        var out: [SemanticKind: Bool] = [:]
        for kind in SemanticKind.allCases { out[kind] = matteImage(filter, kind) != nil }
        return out
    }

    /// The matte as a raster, or `nil` when this file does not carry it.
    public static func raster(url: URL, kind: SemanticKind, modelVersion: String,
                              analysisLongEdge: Int = 1024) -> SemanticRaster? {
        guard let filter = CIRAWFilter(imageURL: url),
              let image = matteImage(filter, kind) else { return nil }
        return rasterise(image, modelVersion: modelVersion, longEdge: analysisLongEdge)
    }

    /// The six properties of `CIRAWFilter.h:202–207` that a matte can come from. `subject` and the
    /// legacy `foreground` spelling have no CI matte — they are Vision kinds.
    static func matteImage(_ filter: CIRAWFilter, _ kind: SemanticKind) -> CIImage? {
        switch kind {
        case .sky: return filter.semanticSegmentationSkyMatte
        case .hair: return filter.semanticSegmentationHairMatte
        case .skin: return filter.semanticSegmentationSkinMatte
        case .teeth: return filter.semanticSegmentationTeethMatte
        case .glasses: return filter.semanticSegmentationGlassesMatte
        case .person: return filter.portraitEffectsMatte
        case .subject, .foreground: return nil
        }
    }

    /// One reused context: creating a `CIContext` per call costs more than the render.
    private static let context = CIContext(options: [.cacheIntermediates: false])

    /// A single-channel matte, downscaled to the analysis budget and read back as floats.
    ///
    /// Row 0 of the result is the **top** row of the image: `CIContext.render(toBitmap:)` writes the
    /// top of `bounds` first, which is the same convention as the Vision path below and the one the
    /// atlas kernel's `uv` uses. (On this machine every matte is nil, so this orientation is written
    /// from the framework contract rather than measured — see the 005e report.)
    static func rasterise(_ image: CIImage, modelVersion: String, longEdge: Int) -> SemanticRaster? {
        let extent = image.extent
        guard extent.width >= 1, extent.height >= 1, extent.isInfinite == false else { return nil }
        let scale = min(1, Double(longEdge) / Double(max(extent.width, extent.height)))
        let scaled = scale < 1 ? image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                               : image
        let bounds = scaled.extent.integral
        let w = Int(bounds.width), h = Int(bounds.height)
        guard w > 0, h > 0, w * h <= 16_000_000 else { return nil }

        var bytes = [UInt8](repeating: 0, count: w * h)
        bytes.withUnsafeMutableBytes { raw in
            context.render(scaled, toBitmap: raw.baseAddress!, rowBytes: w, bounds: bounds,
                           format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
        }
        let values = bytes.map { Float($0) / 255 }
        return SemanticRaster(width: w, height: h, values: values,
                              provider: .systemMatte, modelVersion: modelVersion)
    }
}

/// The Vision half of §5.2. One request per kind, on an 8-bit sRGB copy at the analysis budget.
enum VisionMatte {
    static func raster(kind: SemanticKind, source: SemanticMatteSource, longEdge: Int,
                       modelVersion: String) -> SemanticMatteResult {
        guard let cg = source.sRGBImage(longEdge: longEdge) else { return .unavailable(.visionFailed) }
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])

        switch kind {
        case .subject, .foreground:
            let request = VNGenerateForegroundInstanceMaskRequest()
            do { try handler.perform([request]) } catch { return .unavailable(.visionFailed) }
            guard let observation = request.results?.first else { return .unavailable(.visionFailed) }
            guard let buffer = try? observation.generateMask(forInstances: observation.allInstances)
            else { return .unavailable(.visionFailed) }
            return raster(from: buffer, modelVersion: modelVersion)

        case .person:
            let request = VNGeneratePersonSegmentationRequest()
            request.qualityLevel = .accurate
            request.outputPixelFormat = kCVPixelFormatType_OneComponent8
            do { try handler.perform([request]) } catch { return .unavailable(.visionFailed) }
            guard let buffer = request.results?.first?.pixelBuffer else {
                return .unavailable(.visionFailed)
            }
            return raster(from: buffer, modelVersion: modelVersion)

        case .sky, .hair, .skin, .teeth, .glasses:
            return .unavailable(.noVisionRequest)
        }
    }

    /// One-component CVPixelBuffer → floats. Row 0 is the top row in every format Vision returns
    /// (measured in `local/src/swift-raw/Zenodeng_Phos`, `Engine.runVision`), so no flip is applied.
    static func raster(from buffer: CVPixelBuffer, modelVersion: String) -> SemanticMatteResult {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        guard w > 1, h > 1, let base = CVPixelBufferGetBaseAddress(buffer) else {
            return .unavailable(.visionFailed)
        }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let format = CVPixelBufferGetPixelFormatType(buffer)
        var values = [Float](repeating: 0, count: w * h)

        switch format {
        case kCVPixelFormatType_OneComponent8:
            let p = base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<h {
                for x in 0..<w { values[y * w + x] = Float(p[y * rowBytes + x]) / 255 }
            }
        case kCVPixelFormatType_OneComponent32Float:
            for y in 0..<h {
                let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float.self)
                for x in 0..<w { values[y * w + x] = row[x] }
            }
        case kCVPixelFormatType_OneComponent16Half:
            for y in 0..<h {
                let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float16.self)
                for x in 0..<w { values[y * w + x] = Float(row[x]) }
            }
        default:
            return .unavailable(.visionFailed)
        }
        return .raster(SemanticRaster(width: w, height: h, values: values,
                                      provider: .visionForeground, modelVersion: modelVersion))
    }
}

// MARK: - linear buffer → the 8-bit sRGB image a Vision request wants

extension SemanticMatteSource {
    /// Bilinear downscale to ≤ `longEdge`, sRGB-encoded 8-bit, opaque. This is the only place the
    /// linear buffer is converted to an encoded space, and it exists because both CI and Vision take
    /// a picture, not a scene-linear float buffer.
    func sRGBImage(longEdge: Int) -> CGImage? {
        guard width > 1, height > 1, rgba.count >= width * height * 4 else { return nil }
        let scale = min(1, Double(longEdge) / Double(max(width, height)))
        let w = max(2, Int((Double(width) * scale).rounded()))
        let h = max(2, Int((Double(height) * scale).rounded()))
        var bytes = [UInt8](repeating: 255, count: w * h * 4)

        for y in 0..<h {
            let v = (Double(y) + 0.5) / Double(h) * Double(height) - 0.5
            for x in 0..<w {
                let u = (Double(x) + 0.5) / Double(w) * Double(width) - 0.5
                let c = sampleLinear(u: u, v: v)
                let o = (y * w + x) * 4
                bytes[o] = SemanticMatteSource.sRGB8(c.0)
                bytes[o + 1] = SemanticMatteSource.sRGB8(c.1)
                bytes[o + 2] = SemanticMatteSource.sRGB8(c.2)
            }
        }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: w * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true,
                       intent: .defaultIntent)
    }

    /// Linear sample with clamp-to-edge; the same texel-centre convention as `SemanticRaster.sample`.
    private func sampleLinear(u: Double, v: Double) -> (Double, Double, Double) {
        let fx = u, fy = v
        let x0 = Int(fx.rounded(.down)), y0 = Int(fy.rounded(.down))
        let tx = fx - Double(x0), ty = fy - Double(y0)
        func at(_ x: Int, _ y: Int) -> (Double, Double, Double) {
            let cx = min(max(x, 0), width - 1), cy = min(max(y, 0), height - 1)
            let o = (cy * width + cx) * 4
            return (Double(rgba[o]), Double(rgba[o + 1]), Double(rgba[o + 2]))
        }
        let c00 = at(x0, y0), c10 = at(x0 + 1, y0), c01 = at(x0, y0 + 1), c11 = at(x0 + 1, y0 + 1)
        func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
        let r = lerp(lerp(c00.0, c10.0, tx), lerp(c01.0, c11.0, tx), ty)
        let g = lerp(lerp(c00.1, c10.1, tx), lerp(c01.1, c11.1, tx), ty)
        let b = lerp(lerp(c00.2, c10.2, tx), lerp(c01.2, c11.2, tx), ty)
        return (r, g, b)
    }

    /// sRGB OETF, the same curve `s4_display` applies (one encode in the codebase).
    static func sRGB8(_ v: Double) -> UInt8 {
        let c = min(max(v, 0), 1)
        let e = c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
        return UInt8(min(max((e * 255).rounded(), 0), 255))
    }
}
