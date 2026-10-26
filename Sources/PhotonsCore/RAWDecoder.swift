import Foundation
import CoreImage
import CoreGraphics
import ImageIO
import Metal

public struct DecodeOptions: Sendable {
    /// Decoder version requested from the system RAW pipeline, e.g. `"8"`, `"9"`, `"9.dng"`.
    /// `nil` means "whatever Apple defaults to for this file" (measured to be v8 today).
    ///
    /// A request the body does not whitelist is **not** an error: the filter silently keeps its old
    /// value, so `RAWDecoder` reads the version back and reports the effective one
    /// (`DecoderCapabilities`, docs/architecture-decisions.md §11.1 / D2′).
    public var decoderVersion: String?
    public var exposureEV: Float
    public var scale: Float
    public var draft: Bool
    public var colorSpace: LinearColorSpace

    public init(decoderVersion: String? = nil,
                exposureEV: Float = 0,
                scale: Float = 1,
                draft: Bool = false,
                colorSpace: LinearColorSpace = .extendedLinearSRGB) {
        self.decoderVersion = decoderVersion
        self.exposureEV = exposureEV
        self.scale = scale
        self.draft = draft
        self.colorSpace = colorSpace
    }
}

/// The only working spaces the pipeline is allowed to use: unbounded linear light.
///
/// `CGColorSpace(name:)` takes the *CFString constant* value, not a friendly name —
/// passing "extendedLinearSRGB" silently returns nil. Hence this enum.
public enum LinearColorSpace: String, Sendable, CaseIterable {
    case extendedLinearSRGB
    case extendedLinearDisplayP3

    public var cgColorSpace: CGColorSpace? {
        switch self {
        case .extendedLinearSRGB: return CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        case .extendedLinearDisplayP3: return CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        }
    }
}

public enum DecodeError: LocalizedError {
    case unsupportedFile(URL)
    case noMetalDevice
    case unavailableColorSpace(String)
    case unsupportedVersion(requested: String, available: [String])
    case renderFailed
    case badDimensions(CGSize)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFile(let u): return "not a decodable RAW/JPEG: \(u.lastPathComponent)"
        case .noMetalDevice: return "no Metal device"
        case .unavailableColorSpace(let n): return "color space not available: \(n)"
        case .unsupportedVersion(let r, let a): return "decoder version '\(r)' not offered by this file; available: \(a.joined(separator: ", "))"
        case .renderFailed: return "CIRAWFilter produced no image (or the version was rejected)"
        case .badDimensions(let s): return "unusable dimensions \(s)"
        }
    }
}

/// What the system RAW pipeline reports about one file.
public struct RAWProbe: Sendable {
    public let supportedVersions: [String]
    public let defaultVersion: String
    public let nativeWidth: Int
    public let nativeHeight: Int
    public let make: String?
    public let model: String?
    public let iso: Int?
    /// §11.3: lens correction is a **per-file** fact, never a per-camera one — the EOS R5 + Sigma
    /// 50/1.4 CR3 body reports the switch as unavailable while RW2/RAF from the same era honour it.
    /// So this is `isLensCorrectionSupported` *and* a successful toggle-and-read-back on this very
    /// file; a body that claims support but keeps the old value must read `false` here, because a
    /// UI toggle that cannot change pixels is a lie.
    public let lensCorrectionSupported: Bool
    /// The value `isLensCorrectionEnabled` came back with, after the probe restored it.
    public let lensCorrectionEnabled: Bool
}

public final class RAWDecoder {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let ciContext: CIContext
    private let colorSpace: CGColorSpace
    private let colorSpaceID: LinearColorSpace

    public init(colorSpace: LinearColorSpace = .extendedLinearSRGB) throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw DecodeError.noMetalDevice }
        guard let queue = device.makeCommandQueue() else { throw DecodeError.noMetalDevice }
        guard let cs = colorSpace.cgColorSpace else { throw DecodeError.unavailableColorSpace(colorSpace.rawValue) }
        self.device = device
        self.queue = queue
        self.colorSpace = cs
        self.colorSpaceID = colorSpace
        self.ciContext = CIContext(mtlDevice: device, options: [
            .workingColorSpace: cs,
            .outputColorSpace: cs,
            .cacheIntermediates: false,
        ])
    }

    public var deviceName: String { device.name }

    // MARK: - decode accounting

    /// Real decodes this process has performed, by decode scale.
    ///
    /// The ladder's whole promise is a **count** — "one photo, one development per rung, no matter
    /// how often the camera moves between fit and 1:1" — and a timing cannot prove a count: a second
    /// decode of the same rung is cheap to hide inside a frame that was going to be slow anyway.
    /// `DecodeLadderTests` asserts on this and nothing else.
    private static let countLock = NSLock()
    private static var counts: [Float: Int] = [:]

    public static func decodeCounts() -> [Float: Int] {
        countLock.lock(); defer { countLock.unlock() }
        return counts
    }

    public static func resetDecodeCounts() {
        countLock.lock(); defer { countLock.unlock() }
        counts.removeAll()
    }

    static func recordDecode(scale: Float) {
        countLock.lock(); defer { countLock.unlock() }
        counts[scale, default: 0] += 1
    }

    // MARK: - version helpers

    public static func versionString(_ v: CIRAWDecoderVersion) -> String { v.rawValue }

    public static func availableVersions(for url: URL) throws -> [String] {
        guard let filter = CIRAWFilter(imageURL: url) else { throw DecodeError.unsupportedFile(url) }
        return filter.supportedDecoderVersions.map { versionString($0) }
    }

    public func probe(_ url: URL) throws -> RAWProbe {
        guard let filter = CIRAWFilter(imageURL: url) else { throw DecodeError.unsupportedFile(url) }
        let versions = filter.supportedDecoderVersions.map { Self.versionString($0) }
        let props = filter.properties
        let tiff = (props[kCGImagePropertyTIFFDictionary as String] as? [String: Any])
            ?? (props["{TIFF}"] as? [String: Any])
        let exif = (props[kCGImagePropertyExifDictionary as String] as? [String: Any])
            ?? (props["{Exif}"] as? [String: Any])
        var iso: Int?
        if let arr = exif?[kCGImagePropertyExifISOSpeedRatings as String] as? [Int] { iso = arr.first }
        else if let arr = exif?[kCGImagePropertyExifISOSpeedRatings as String] as? [Any] { iso = (arr.first as? NSNumber)?.intValue }

        return RAWProbe(supportedVersions: versions,
                        defaultVersion: Self.versionString(filter.decoderVersion),
                        nativeWidth: Int(filter.nativeSize.width),
                        nativeHeight: Int(filter.nativeSize.height),
                        make: tiff?[kCGImagePropertyTIFFMake as String] as? String,
                        model: tiff?[kCGImagePropertyTIFFModel as String] as? String,
                        iso: iso,
                        lensCorrectionSupported: Self.probeLensCorrection(filter),
                        lensCorrectionEnabled: filter.isLensCorrectionEnabled)
    }

    /// Toggle-and-read-back, on this file only (§11.3).
    ///
    /// `isLensCorrectionSupported` alone is not enough: the flag is a claim, and a claim that does
    /// not survive assignment would put a dead switch in the inspector. We flip the value, read it
    /// back, and restore — the restore matters because the same `CIRAWFilter` is about to be used
    /// for the capabilities of the file, and a left-on correction silently changes pixels.
    static func probeLensCorrection(_ filter: CIRAWFilter) -> Bool {
        guard filter.isLensCorrectionSupported else { return false }
        let original = filter.isLensCorrectionEnabled
        filter.isLensCorrectionEnabled = !original
        let toggled = filter.isLensCorrectionEnabled
        filter.isLensCorrectionEnabled = original
        return toggled == !original && filter.isLensCorrectionEnabled == original
    }

    // MARK: - decode

    /// A decoded buffer plus the decoder facts that shaped it.
    ///
    /// The pixel hash alone cannot tell you that a v9 request silently became v8; `capabilities`
    /// can, and the UI has to say so (§11.1: 69 bodies offer v9, 941 do not).
    public struct DecodeOutcome: Sendable {
        public let image: LinearImage
        public let capabilities: DecoderCapabilities
    }

    /// Test hook: `resolve` is what a read-back proves. Kept here so the decode path and the test
    /// cannot drift apart.
    public static func resolveVersion(_ requested: String?, offered: [String],
                                      filterDefault: String) -> (effective: String, downgraded: Bool) {
        DecoderCapabilities.resolve(requested: requested, offered: offered, filterDefault: filterDefault)
    }

    public func decode(_ url: URL, options: DecodeOptions = DecodeOptions()) throws -> LinearImage {
        try decodeDetailed(url, options: options).image
    }

    public func decodeDetailed(_ url: URL, options: DecodeOptions = DecodeOptions()) throws -> DecodeOutcome {
        guard let filter = CIRAWFilter(imageURL: url) else { throw DecodeError.unsupportedFile(url) }

        let offered = filter.supportedDecoderVersions.map { Self.versionString($0) }
        let filterDefault = Self.versionString(filter.decoderVersion)

        // ── 前置 ① D2′: v8 default + read-back assert ────────────────────────────────────────
        // Assign, then read back. A body that does not whitelist the request keeps the old value
        // (measurably: v9 on an SL3 stays v8), so the read-back — not the assignment — is the
        // truth. On a mismatch we pin the D2′ default and report `effectiveVersion`.
        var effective = filterDefault
        if let wanted = options.decoderVersion {
            guard DecoderCapabilities.knownVersions.contains(wanted) else {
                throw DecodeError.unsupportedVersion(requested: wanted, available: offered)
            }
            filter.decoderVersion = CIRAWDecoderVersion(rawValue: wanted)
            effective = Self.versionString(filter.decoderVersion)
            if effective != wanted {
                // Downgrade explicitly, then re-read: reporting the *requested* version here is
                // exactly the bug the read-back exists to catch.
                filter.decoderVersion = CIRAWDecoderVersion(
                    rawValue: DecoderCapabilities.preferredDefault(offered: offered, filterDefault: filterDefault))
                effective = Self.versionString(filter.decoderVersion)
            }
        }

        // ── 前置 ② explicit linear ──────────────────────────────────────────────────────────
        // §11.4: with the default boost/gamut-mapping, +1 EV is *not* a factor of two (measured
        // 2.03–2.66); with both off it is 2.0063. §11.8: the same two switches decide whether the
        // EDR headroom survives at all (1.018 → 1.695 on the same file), so this is also the
        // data-side precondition for EDR.
        filter.boostAmount = 0
        filter.isGamutMappingEnabled = false

        filter.isDraftModeEnabled = options.draft
        filter.scaleFactor = options.scale
        filter.exposure = options.exposureEV

        guard let output = filter.outputImage else { throw DecodeError.renderFailed }
        let extent = output.extent.integral
        let w = Int(extent.width), h = Int(extent.height)
        guard w > 0, h > 0 else { throw DecodeError.badDimensions(extent.size) }

        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
                                                           width: w, height: h, mipmapped: false)
        desc.usage = [.shaderRead, .shaderWrite, .renderTarget]
        // .shared so we can read back without a blit; revisited in M1 with a private
        // texture + MTLBuffer copy once the cache format is settled.
        desc.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: desc) else { throw DecodeError.renderFailed }

        guard let cb = queue.makeCommandBuffer() else { throw DecodeError.renderFailed }
        Self.recordDecode(scale: options.scale)
        ciContext.render(output, to: texture, commandBuffer: cb,
                         bounds: CGRect(x: 0, y: 0, width: w, height: h),
                         colorSpace: colorSpace)
        cb.commit()
        cb.waitUntilCompleted()

        // ── readback ────────────────────────────────────────────────────────────────────────
        // Straight into the `Float16` storage: an `rgba16Float` texture and `Float16` share a bit
        // pattern, so the `[UInt16]` staging array and the 460 MB `raw.map { Float16(bitPattern:) }`
        // pass it fed are both unnecessary. Measured on a 60 MP frame, the whole tail (readback +
        // conversion + row flip) went from 344–451 ms to 83 ms, byte for byte (every sample equal;
        // digests below `DecodeTests` unchanged).
        var rgba = [Float16](repeating: 0, count: w * h * 4)
        rgba.withUnsafeMutableBytes { buf in
            texture.getBytes(buf.baseAddress!,
                             bytesPerRow: w * 4 * MemoryLayout<Float16>.size,
                             from: MTLRegionMake2D(0, 0, w, h),
                             mipmapLevel: 0)
        }
        // ── row order ───────────────────────────────────────────────────────────────────────
        // `CIContext.render(to: MTLTexture)` writes the picture **bottom-up** in Metal's memory
        // order: a marker in the image's top-left row lands in the *last* row of the buffer
        // (measured — local/probes/orient/readbackconvention.swift, and the same probe shows a
        // 60 MP SL3 decode is the vertical mirror of the file's own embedded preview and of
        // `CIContext.createCGImage`). `LinearImage`'s contract is row 0 = top, so the flip is
        // undone here, once, instead of asking every consumer to remember it. Before this line
        // every render of every file was up-down mirrored — which reads as "rotated 180°" the
        // moment a picture contains signage (L1030433), and is why it looked file-specific.
        Self.flipRows(&rgba, width: w, height: h)

        // **`CIRAWFilter` already honours the container's EXIF orientation.** Measured on
        // `L1030409.dng` (tag 8, stored 9536×6344): the filter reports `orientation == 8` *and*
        // hands back an upright 6336×9520 image, so the buffer we just copied has row 0 at the top
        // of the *upright* picture. Recording the tag here and letting `oriented()` rotate again
        // double-rotates exactly the photos that are not `.up` (L1030405/409 in the demo library):
        // they render 90° wrong and landscape-shaped. So the buffer is `.up` by construction;
        // `sourceOrientation(of:)` stays for metadata and for the preview path, which *does* need
        // the transform (ImageIO's thumbnail is created with `WithTransform: false`).
        let image = LinearImage(width: w, height: h, rgba: rgba,
                                colorSpace: colorSpaceID.rawValue, decoderVersion: effective,
                                orientation: .up)
        let capabilities = DecoderCapabilities(requestedVersion: options.decoderVersion,
                                               effectiveVersion: effective,
                                               defaultVersion: filterDefault)
        return DecodeOutcome(image: image, capabilities: capabilities)
    }

    /// Reverse the row order of a row-major RGBA buffer in place (vertical mirror of the *rows*).
    ///
    /// Eight bytes at a time, in place: `rowBytes` is `8 × width` for `Float16` RGBA, so a row is
    /// always a whole number of words and no tail case exists. Measured on a 60 MP frame, three
    /// formulations of the same permutation:
    ///
    ///   · elementwise `swapAt` (the original)          152–185 ms — 120 M bounds-checked swaps
    ///   · row → scratch buffer → row, `copyMemory`      261–284 ms — moves 3× the bytes, slower
    ///   · word-wise in place (this)                      33–65 ms  — 1× read + 1× write
    ///
    /// All three produce the same permutation, which is why this stays inside the `v2` decode recipe
    /// and does not mint a `v3` (§3.2): `DecodeLadderTests.testRowFlipIsTheReferencePermutation`
    /// pins it against the elementwise formulation, every sample.
    static func flipRows(_ rgba: inout [Float16], width: Int, height: Int) {
        guard width > 0, height > 1 else { return }
        let rowBytes = width * 4 * MemoryLayout<Float16>.size
        rgba.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            var y = 0
            while y < height / 2 {
                let top = base + y * rowBytes
                let bottom = base + (height - 1 - y) * rowBytes
                let a = top.assumingMemoryBound(to: UInt64.self)
                let b = bottom.assumingMemoryBound(to: UInt64.self)
                for i in 0..<(rowBytes / 8) {
                    let t = a[i]
                    a[i] = b[i]
                    b[i] = t
                }
                y += 1
            }
        }
    }

    // MARK: - orientation of a source file

    /// The one reader both paths use: preview (`PreviewImage.swift`) and decode (here).
    ///
    /// Order of authority, and why:
    /// 1. **HEIF `irot`** — an HEIC carries its display rotation in the container box, and ImageIO
    ///    reports `kCGImagePropertyOrientation` as 1 (or absent) for those files, so the box is the
    ///    only honest source (§11.5). A *real* EXIF tag still wins when it says something other
    ///    than "normal", because that is what every other viewer reads.
    /// 2. **EXIF/TIFF tag** via `kCGImagePropertyOrientation` — JPEG, TIFF, and RAW bodies that
    ///    write one (`CIRAWFilter` reads it too: on this machine `filter.orientation` agrees).
    /// 3. **`CIRAWFilter.orientation`** — for RAW containers ImageIO's property dictionary may omit
    ///    the tag while the RAW pipeline parsed it.
    /// Anything unreadable is `.up`: a guess would be worse than the common case.
    public static func sourceOrientation(of url: URL) -> ImageOrientation {
        let exif = imageIOOrientation(of: url)
        if let irot = heifContainerOrientation(of: url), exif == nil || exif == ImageOrientation.up.rawValue {
            return irot
        }
        if let exif { return ImageOrientation(exifOrDefault: exif) }
        if let filter = CIRAWFilter(imageURL: url) {
            let o = Int(filter.orientation.rawValue)
            if o != ImageOrientation.up.rawValue { return ImageOrientation(exif: o) ?? .up }
        }
        return .up
    }

    static func imageIOOrientation(of url: URL) -> Int? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        else { return nil }
        return (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue
    }

    /// `irot` from an ISO-BMFF container, as an EXIF orientation. `nil` for non-HEIF files and for
    /// containers without the box.
    static func heifContainerOrientation(of url: URL) -> ImageOrientation? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        guard let angle = heifRotationAngle(in: data) else { return nil }
        return ImageOrientation(heifRotationQuarterTurnsCCW: angle)
    }

    /// Walks `ftyp`-rooted boxes looking for `irot`; returns its angle in 90° **counter-clockwise**
    /// quarter turns (0…3), which is what the box stores.
    ///
    /// Extracted from the file reader so it can be tested against synthesized boxes — no HEIC with
    /// a non-zero `irot` exists on this machine to test against, and a parser nobody tested is a
    /// parser that does not work.
    public static func heifRotationAngle(in data: Data) -> Int? {
        guard data.count >= 16 else { return nil }
        let bytes = [UInt8](data)
        guard bytes[4] == 0x66, bytes[5] == 0x74, bytes[6] == 0x79, bytes[7] == 0x70 else { return nil } // "ftyp"
        // Only still-image brands; a QuickTime .mov also starts with ftyp and has no irot.
        let brandWindow = bytes[8..<min(bytes.count, 32)]
        let brands = String(decoding: brandWindow, as: UTF8.self)
        let still: [String] = ["heic", "heix", "heim", "heis", "hevc", "hevx", "mif1", "msf1", "avif", "avis"]
        guard still.contains(where: { brands.contains($0) }) else { return nil }
        return findIrot(bytes, start: 0, end: bytes.count, depth: 0)
    }

    private static func be32(_ b: [UInt8], _ o: Int) -> Int {
        (Int(b[o]) << 24) | (Int(b[o + 1]) << 16) | (Int(b[o + 2]) << 8) | Int(b[o + 3])
    }

    private static func findIrot(_ b: [UInt8], start: Int, end: Int, depth: Int) -> Int? {
        guard depth < 8 else { return nil }
        var o = start
        while o + 8 <= end {
            let size = be32(b, o)
            let type = String(decoding: b[(o + 4)..<(o + 8)], as: UTF8.self)
            let boxEnd = size == 0 ? end : min(o + size, end)
            guard boxEnd > o + 8 || (size == 0) else { return nil }   // corrupt size: stop, do not loop
            switch type {
            case "irot":
                // FullBox in ISO/IEC 23008-12 (`version/flags` then one byte holding the angle);
                // Apple writes a 9-byte box with the single byte alone. The angle lives in the
                // last payload byte either way (`unsigned int(6) reserved; unsigned int(2) angle`).
                if let last = b[o + 8..<boxEnd].last { return Int(last) & 0x03 }
                return nil
            case "meta":   // FullBox: 4 bytes of version/flags before the children
                if let r = findIrot(b, start: o + 12, end: boxEnd, depth: depth + 1) { return r }
            case "iprp", "ipco", "moov", "trak", "mdia", "minf", "stbl":
                if let r = findIrot(b, start: o + 8, end: boxEnd, depth: depth + 1) { return r }
            default:
                break
            }
            if size == 0 { return nil }
            o = boxEnd
        }
        return nil
    }
}

// MARK: - the decode ladder

/// One developed buffer, with the decoder facts that shaped it.
///
/// `capabilities` travels with the pixels because a v9 request can silently become v8
/// (`DecoderCapabilities`); a rung that lost its capabilities in the cache would make the second
/// frame of a photo claim a different decoder than the first.
public struct DecodeRung: Sendable {
    /// The `DecodeOptions.scale` this buffer was developed at (0.5 = the preview rung, 1 = full).
    public let scale: Float
    public let image: LinearImage
    public let capabilities: DecoderCapabilities
    /// Wall-clock cost of the decode that produced it. Only meaningful for a fresh decode; a rung
    /// that came out of the ladder reports the cost it was born with, which is what makes "the
    /// preview was 250 ms, the full was 950 ms" measurable after the fact.
    public let milliseconds: Double

    public init(scale: Float, image: LinearImage, capabilities: DecoderCapabilities,
                milliseconds: Double) {
        self.scale = scale
        self.image = image
        self.capabilities = capabilities
        self.milliseconds = milliseconds
    }
}

/// What a camera request has to ask the ladder for, in presentation order.
///
/// `preview` is the rung that can go on screen *now* — normally the 0.5 buffer the fit view already
/// developed. `target` is the rung the request actually needs. One entry means "the target is
/// already resident, this frame costs a render and nothing else".
public struct DecodeLadderPlan: Equatable, Sendable {
    public let preview: Float?
    public let target: Float

    public init(preview: Float?, target: Float) {
        self.preview = preview
        self.target = target
    }

    /// Rungs to fetch and present, in order. The last one is always the target.
    public var rungs: [Float] { preview.map { [$0, target] } ?? [target] }

    /// True when the frame can be produced without touching ImageIO at all.
    public var isResident: Bool { preview == nil }
}

/// The decoded buffers of **the photo the loupe is showing**, keyed by rung.
///
/// Why this type exists at all (§11.10, D12): the loupe used to keep a single `(key, buffer)` slot,
/// so entering 1:1 tiled on a full 60 MP development (941 ms on the reference file) and — worse —
/// the two rungs evicted each other, so `fit → 1:1 → fit → 1:1` developed the same file *three*
/// times. Keying by `(identity, scale)` and keeping one identity resident makes the second visit to
/// either rung a render-only frame, and the counter test proves it.
///
/// Memory: a full 60 MP rung is ~482 MB and the preview rung ~120 MB, so the *higher* rung releases
/// every lower rung of the same photo the moment it lands. A `RenderGraph` can render any zoom from
/// the biggest buffer (that is what `outputWindow` is), which means the preview rung is only ever
/// needed while the full one is still being developed — and the steady-state footprint stays what
/// it was before this type existed (one buffer, not two).
///
/// **Two queues, one lock.** Since Q29 the rungs are *written* from the decode queue (a development
/// that just finished) while they are *read* from the render queue (the next frame), so every member
/// below is guarded by `lock`. The one rule that keeps the lock harmless: it is never held across a
/// development — `rung(identity:scale:decode:)` asks its question, drops the lock, develops, and
/// re-enters to store. A decode under a lock would serialise the two queues again, which is exactly
/// the defect this file's `DecodeQueue` exists to remove.
public final class DecodeLadder {
    /// The rung a fit frame can afford to show first: half the linear size, ~quarter the pixels.
    public static let previewScale: Float = 0.5
    /// The rung 1:1 (and everything above it) is rendered from. One source pixel, one buffer pixel.
    public static let fullScale: Float = 1

    private let lock = NSLock()
    private var identity: String?
    private var rungs: [Float: DecodeRung] = [:]

    /// Rungs this ladder has developed, and how many requests it answered from the cache. Exposed
    /// for the tests and for the bench; not part of any key.
    private var decodeCount = 0
    private var hitCount = 0
    /// How many rungs the *last* `store` released because a bigger one replaced them.
    private var releaseCount = 0

    public private(set) var decodes: Int {
        get { locked { decodeCount } }
        set { locked { decodeCount = newValue } }
    }
    public private(set) var hits: Int {
        get { locked { hitCount } }
        set { locked { hitCount = newValue } }
    }
    public private(set) var released: Int {
        get { locked { releaseCount } }
        set { locked { releaseCount = newValue } }
    }

    public init() {}

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    /// The rungs currently in memory, smallest first. Debugging/diagnostics only.
    public var residentScales: [Float] { locked { rungs.keys.sorted() } }

    public var best: DecodeRung? {
        locked { rungs.values.max { $0.scale < $1.scale } }
    }

    /// The resident rung at exactly `scale`, or `nil`. Never returns a different rung: a 0.5 buffer
    /// must never be mistaken for a 1.0 one (that is the bug class this type exists to close).
    public func resident(identity: String, scale: Float) -> DecodeRung? {
        locked { identity == self.identity ? rungs[scale] : nil }
    }

    /// The largest resident rung that is not bigger than `scale` — the best thing that can be shown
    /// while the wanted rung is being developed.
    public func best(identity: String, atOrBelow scale: Float) -> DecodeRung? {
        locked {
            guard identity == self.identity else { return nil }
            return rungs.values.filter { $0.scale <= scale }.max { $0.scale < $1.scale }
        }
    }

    /// What the loupe must do for a `target` rung: show `preview` first if it can, then `target`.
    ///
    /// `preview` is `nil` exactly when the target is resident, which is the case that matters for
    /// the second and every later visit to a camera position.
    public func plan(identity: String, target: Float) -> DecodeLadderPlan {
        locked {
            if identity == self.identity, rungs[target] != nil {
                return DecodeLadderPlan(preview: nil, target: target)
            }
            // Nothing smaller to show, or the only thing we have *is* the target: one rung.
            guard target > Self.previewScale else {
                return DecodeLadderPlan(preview: nil, target: target)
            }
            let residentPreview = identity == self.identity
                ? rungs.values.filter { $0.scale <= target }.max { $0.scale < $1.scale }?.scale
                : nil
            return DecodeLadderPlan(preview: residentPreview ?? Self.previewScale, target: target)
        }
    }

    /// Answer a request for one rung, developing it with `decode` on a miss.
    ///
    /// The decode closure is the caller's because only the caller knows the URL and the options;
    /// the *policy* (what a hit is, when a bigger rung releases a smaller one) lives here so the
    /// counter and the memory rule cannot drift from the code path that uses them.
    ///
    /// The lock is **not** held across `decode`: this call is only used by paths that develop inline
    /// (a test, `--ui-smoke`, an import preview). The loupe's own frames go through
    /// `resident`/`best` + `DecodeQueue`, precisely so that a development never sits inside a lock
    /// that a frame needs.
    public func rung(identity: String, scale: Float,
                     decode: () throws -> DecodeRung) rethrows -> (rung: DecodeRung, cached: Bool) {
        if let hit = resident(identity: identity, scale: scale) {
            locked { hitCount += 1 }
            return (hit, true)
        }
        let fresh = try decode()
        locked { decodeCount += 1 }
        store(fresh, identity: identity)
        return (fresh, false)
    }

    /// Put a developed rung in memory, dropping every smaller rung of the same photo.
    public func store(_ rung: DecodeRung, identity: String) {
        locked {
            if identity != self.identity {
                // A different photo: nothing here can be reused, and holding it would be the memory
                // leak the single-slot cache never had.
                rungs.removeAll()
                self.identity = identity
            }
            rungs[rung.scale] = rung
            releaseCount = 0
            for scale in rungs.keys where scale < rung.scale {
                rungs.removeValue(forKey: scale)
                releaseCount += 1
            }
        }
    }

    /// Forget everything (a new photo, or a decode recipe change).
    public func reset() {
        locked {
            rungs.removeAll()
            identity = nil
            releaseCount = 0
        }
    }
}

