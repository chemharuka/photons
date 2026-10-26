import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Compression
import PhotonsCore

// MARK: - XMP export: EditModel → CGImageMetadata (crs:) + photons: private namespace
//
// Spec: docs/xmp-mapping.md (tables A/B, §4 write paths, §5 round-trip list).
// Decisions this file encodes (docs/architecture-decisions.md D7/D9):
//   · the database is the only truth; XMP is a derived artifact and is never read back by the
//     render path — `XMPWriter` has no inverse, `XMPReadback` exists for tests and for the one-shot
//     Lightroom importer that does not live in this target;
//   · `crs:` is the interoperable, best-effort copy for Lightroom; `photons:settings` is our own
//     lossless backup (base64(zlib(EditModel JSON)));
//   · R1: a field equal to its `EditModel` default writes **no** key. The only exceptions are
//     `crs:Version`, `crs:ProcessVersion` and `crs:WhiteBalance`, which declare compatibility.
//     Because a merge into an existing packet must not resurrect a stale value, every key we own is
//     written when non-default and *removed* when default (see `setOrRemove`).

public enum XMPNamespace {
    /// Exact to the character, including the trailing slash (docs/xmp-mapping.md B11).
    public static let crs = "http://ns.adobe.com/camera-raw-settings/1.0/"
    public static let photons = "https://photons.app/ns/edit/1.0/"
    public static let dc = "http://purl.org/dc/elements/1.1/"

    public static let crsPrefix = "crs"
    public static let photonsPrefix = "photons"

    /// Target ACR version, written as a compile-time constant. Deliberately *not* the system RAW
    /// decoder version (RawCamera.bundle reports 9.51.0); that number has nothing to do with ACR.
    public static let crsVersion = "18.5.1"
    /// Adobe algorithm-generation string. ≥ "11.0" is what makes Lightroom honour the `*2012`
    /// keys; we only declare it and never read it back (docs/xmp-mapping.md §3 B6).
    public static let processVersion = "15.4"
}

// MARK: - context

/// As-shot white balance, when the catalog knows it (M2 and later).
///
/// `crs:Temperature/Tint` are absolute and camera-profile relative; our `light.temperature`/`tint`
/// are **absolute Kelvin/tint in the decoder's own coordinates** since 派单 006 (`nil` = as shot), and
/// they are anchored at the same place Lightroom anchors: the file's as-shot neutral. So the mapping
/// is the identity on the anchor — `crs = ours ?? asShot` — and the old "shift of the neutral point,
/// not a ratio" rule (`crs = asShot + (ours − 6500)`) collapses to it, because the `− 6500` term
/// existed only to undo the nominal value our model used to carry.
public struct WhiteBalanceAnchor: Sendable, Equatable {
    public var temperature: Double
    public var tint: Double

    public init(temperature: Double, tint: Double = 0) {
        self.temperature = temperature
        self.tint = tint
    }
}

public struct XMPWriteContext: Sendable {
    public var asShot: WhiteBalanceAnchor?
    /// The container's own EXIF orientation (1…8). Flips are composed onto it and written as
    /// `tiff:Orientation`; when both flips are default we never touch the tag.
    public var exifOrientation: Int?
    /// `photons:settings` is the lossless backup; only suppressed by callers that want a
    /// human-readable `crs:`-only packet.
    public var includeSettingsBlob: Bool
    /// Above this many bytes the blob is not pushed into a container (docs/xmp-mapping.md X-15).
    public var embeddedBlobLimit: Int

    public init(asShot: WhiteBalanceAnchor? = nil,
                exifOrientation: Int? = nil,
                includeSettingsBlob: Bool = true,
                embeddedBlobLimit: Int = 64 * 1024) {
        self.asShot = asShot
        self.exifOrientation = exifOrientation
        self.includeSettingsBlob = includeSettingsBlob
        self.embeddedBlobLimit = embeddedBlobLimit
    }
}

// MARK: - report

/// What an export actually did. Grouped by field name so a batch summary stays one line
/// ("skipped 3 fields: masks[0].id ×2, …").
public struct XMPExportReport: Sendable {
    /// Paths written, in the order they were written. `crs:` and `photons:` keys both appear.
    public var written: [String] = []
    /// Unmappable leaves that had a value, keyed by their `EditModel` path.
    public var unmapped: [String: Int] = [:]
    /// Human-readable caveats ("WB stays as-shot in Lightroom", "curve thinned 22 → 16 points").
    public var notes: [String] = []

    public init() {}

    public var unmappedCount: Int { unmapped.values.reduce(0, +) }

    public mutating func skip(_ field: String) {
        unmapped[field, default: 0] += 1
    }

    public var unmappedText: String {
        guard !unmapped.isEmpty else { return "0" }
        let parts = unmapped.sorted { $0.key < $1.key }.map { "\($0.key) ×\($0.value)" }
        return "\(unmappedCount) (\(parts.joined(separator: ", ")))"
    }

    public mutating func merge(_ other: XMPExportReport) {
        written.append(contentsOf: other.written)
        for (k, v) in other.unmapped { unmapped[k, default: 0] += v }
        notes.append(contentsOf: other.notes)
    }
}

// MARK: - errors

public enum XMPExportError: LocalizedError {
    case namespaceRegistration(String)
    case setValueFailed(String)
    case xmpSerializationFailed
    case unreadableXMP(URL)
    case unsupportedContainer(String)
    case embedFailed(URL, String)
    case writeFailed(URL, String)

    public var errorDescription: String? {
        switch self {
        case .namespaceRegistration(let p): return "could not register the '\(p)' XMP namespace"
        case .setValueFailed(let path): return "could not write XMP path \(path)"
        case .xmpSerializationFailed: return "CGImageMetadataCreateXMPData returned nothing"
        case .unreadableXMP(let u): return "not a readable XMP packet: \(u.path)"
        case .unsupportedContainer(let ext):
            return "'\(ext)' cannot carry XMP natively — write a sidecar instead"
        case .embedFailed(let u, let why): return "could not embed XMP into \(u.path): \(why)"
        case .writeFailed(let u, let why): return "could not write \(u.path): \(why)"
        }
    }
}

// MARK: - orientation algebra

/// `tiff:Orientation` is a dihedral-group element: (quarter turns clockwise applied to the stored
/// pixels, then an optional horizontal mirror). Value ↔ element per EXIF:
/// 1 (0,no) 2 (0,mirror) 3 (180,no) 4 (180,mirror) 5 (90,mirror) 6 (90,no) 7 (270,mirror) 8 (270,no).
/// Flips are applied to the *upright* image, so the new tag is `flip ∘ stored` — composition with a
/// fixed left operand is injective, which is what makes the four flip combinations reversible.
public struct XMPOrientation: Sendable, Equatable {
    public var quarterTurns: Int      // 0…3, clockwise
    public var mirrored: Bool         // horizontal mirror applied after the rotation

    public init(quarterTurns: Int, mirrored: Bool) {
        self.quarterTurns = ((quarterTurns % 4) + 4) % 4
        self.mirrored = mirrored
    }

    public static func from(value: Int) -> XMPOrientation {
        switch value {
        case 2: return XMPOrientation(quarterTurns: 0, mirrored: true)
        case 3: return XMPOrientation(quarterTurns: 2, mirrored: false)
        case 4: return XMPOrientation(quarterTurns: 2, mirrored: true)
        case 5: return XMPOrientation(quarterTurns: 1, mirrored: true)
        case 6: return XMPOrientation(quarterTurns: 1, mirrored: false)
        case 7: return XMPOrientation(quarterTurns: 3, mirrored: true)
        case 8: return XMPOrientation(quarterTurns: 3, mirrored: false)
        default: return XMPOrientation(quarterTurns: 0, mirrored: false)
        }
    }

    public var value: Int {
        switch (quarterTurns, mirrored) {
        case (0, false): return 1
        case (0, true): return 2
        case (2, false): return 3
        case (2, true): return 4
        case (1, true): return 5
        case (1, false): return 6
        case (3, true): return 7
        default: return 8          // (3, false)
        }
    }

    /// `self ∘ other`: apply `other` first. Uses `M·R^k = R^-k·M`, i.e. a mirrored right operand
    /// negates the rotation.
    public func composed(with other: XMPOrientation) -> XMPOrientation {
        if other.mirrored {
            return XMPOrientation(quarterTurns: quarterTurns - other.quarterTurns,
                                  mirrored: !mirrored)
        }
        return XMPOrientation(quarterTurns: quarterTurns + other.quarterTurns, mirrored: mirrored)
    }

    public var inverse: XMPOrientation {
        mirrored ? XMPOrientation(quarterTurns: -quarterTurns, mirrored: true)
                 : XMPOrientation(quarterTurns: -quarterTurns, mirrored: false)
    }

    /// The flip a pipeline would have to apply to the upright image to turn `base` into `self`.
    public func flips(from base: XMPOrientation) -> (horizontal: Bool, vertical: Bool) {
        let f = composed(with: base.inverse)     // F = self ∘ base⁻¹
        switch (f.quarterTurns, f.mirrored) {
        case (0, false): return (false, false)
        case (0, true): return (true, false)     // mirror horizontal only
        case (2, false): return (true, true)     // R180 = flip both
        case (2, true): return (false, true)     // mirror vertical only
        default: return (false, false)           // 90°/270° cannot come from flips alone
        }
    }

    public static func composed(exif: Int, flipHorizontal: Bool, flipVertical: Bool) -> Int {
        let base = XMPOrientation.from(value: exif)
        let flip: XMPOrientation
        switch (flipHorizontal, flipVertical) {
        case (false, false): return base.value
        case (true, false): flip = XMPOrientation(quarterTurns: 0, mirrored: true)
        case (false, true): flip = XMPOrientation(quarterTurns: 2, mirrored: true)
        case (true, true): flip = XMPOrientation(quarterTurns: 2, mirrored: false)
        }
        return flip.composed(with: base).value
    }
}

// MARK: - curve quantisation

/// LR curves are `"x, y"` strings on a 0…255 integer grid, x strictly increasing, ≤ 16 points
/// (docs/xmp-mapping.md §1.4). Anything else is rejected by Lightroom, so we normalise before
/// writing and report what was dropped.
public enum XMPCurve {
    public struct Normalized: Sendable, Equatable {
        public var points: [(x: Int, y: Int)]
        public var dropped: Int
        public var strings: [String] { points.map { "\($0.x), \($0.y)" } }

        /// Tuple arrays cannot synthesise `Equatable`; compare element-wise.
        public static func == (a: Normalized, b: Normalized) -> Bool {
            a.dropped == b.dropped && a.points.count == b.points.count
                && zip(a.points, b.points).allSatisfy { $0.x == $1.x && $0.y == $1.y }
        }
    }

    public static func normalize(_ raw: [CurvePoint], limit: Int = 16) -> Normalized {
        // Sort by x, then collapse quantised duplicates (last y wins: the newest hand edit).
        let sorted = raw.map { (x: clamp01($0.x), y: clamp01($0.y)) }.sorted { $0.x < $1.x }
        var grid: [(x: Int, y: Int)] = []
        for p in sorted {
            let qx = Int((p.x * 255).rounded())
            let qy = Int((p.y * 255).rounded())
            if let last = grid.last, last.x == qx {
                grid[grid.count - 1] = (qx, qy)
            } else {
                grid.append((qx, qy))
            }
        }
        if grid.isEmpty { grid = [(0, 0), (255, 255)] }
        let dropped = raw.count - grid.count
        guard grid.count > limit else { return Normalized(points: grid, dropped: dropped) }

        // Thin evenly but always keep the first and last control point.
        var thinned: [(x: Int, y: Int)] = []
        for i in 0..<limit {
            let pos = Double(i) * Double(grid.count - 1) / Double(limit - 1)
            thinned.append(grid[Int(pos.rounded())])
        }
        var seen: Set<Int> = []
        thinned = thinned.filter { seen.insert($0.x).inserted }
        return Normalized(points: thinned, dropped: raw.count - thinned.count)
    }

    private static func clamp01(_ v: Double) -> Double { min(max(v, 0), 1) }
}

// MARK: - writer

public enum XMPWriter {

    // MARK: metadata construction

    /// Build a metadata object for `edit`: a mutable copy of `existing` (never an empty replacement —
    /// that would drop exif/iptc/other people's `crs:`), with our keys merged in.
    public static func makeMetadata(for edit: EditModel,
                                    existing: CGImageMetadata? = nil,
                                    context: XMPWriteContext = XMPWriteContext())
        throws -> (metadata: CGImageMetadata, report: XMPExportReport) {
        let mutable = try mutableCopy(of: existing)
        let report = try apply(edit, to: mutable, context: context)
        return (mutable, report)
    }

    public static func mutableCopy(of existing: CGImageMetadata?) throws -> CGMutableImageMetadata {
        let mutable: CGMutableImageMetadata
        if let existing {
            guard let copy = CGImageMetadataCreateMutableCopy(existing) else {
                throw XMPExportError.xmpSerializationFailed
            }
            mutable = copy
        } else {
            mutable = CGImageMetadataCreateMutable()
        }
        try registerNamespaces(mutable)
        return mutable
    }

    public static func registerNamespaces(_ metadata: CGMutableImageMetadata) throws {
        var err: Unmanaged<CFError>?
        if !CGImageMetadataRegisterNamespaceForPrefix(metadata, XMPNamespace.crs as CFString,
                                                      XMPNamespace.crsPrefix as CFString, &err) {
            throw XMPExportError.namespaceRegistration(XMPNamespace.crsPrefix)
        }
        err = nil
        if !CGImageMetadataRegisterNamespaceForPrefix(metadata, XMPNamespace.photons as CFString,
                                                      XMPNamespace.photonsPrefix as CFString, &err) {
            throw XMPExportError.namespaceRegistration(XMPNamespace.photonsPrefix)
        }
    }

    /// The pure mapping function: `EditModel` → tags. This is the only thing that knows the table.
    @discardableResult
    public static func apply(_ edit: EditModel,
                             to metadata: CGMutableImageMetadata,
                             context: XMPWriteContext = XMPWriteContext()) throws -> XMPExportReport {
        var report = XMPExportReport()
        let g = edit.geometry, l = edit.light, c = edit.color
        let d = edit.detail, e = edit.effects

        // MARK: 1.1 declarations (always written, R1 exceptions)

        try write(metadata, "crs:Version", str(XMPNamespace.crsVersion), &report)
        try write(metadata, "crs:ProcessVersion", str(XMPNamespace.processVersion), &report)

        let anchored = context.asShot.map { (anchor: WhiteBalanceAnchor) in
            (temperature: l.temperature ?? anchor.temperature,
             tint: l.tint ?? anchor.tint)
        }
        // "As Shot" is the document saying "whatever the file says" — not "6500 K".
        let followsAsShot = l.temperature == nil && l.tint == nil
        try write(metadata, "crs:WhiteBalance", str(followsAsShot ? "As Shot" : "Custom"), &report)

        // MARK: 1.2 geometry

        let crop = g.crop.clamped()
        let hasCrop = g.crop != .full
        try write(metadata, "crs:HasCrop", hasCrop ? (kCFBooleanTrue as CFTypeRef) : nil, &report)
        // Left/Top are fractions already; Right/Bottom are *edges* (x+width), not widths.
        try write(metadata, "crs:CropLeft", hasCrop ? number(crop.x) : nil, &report)
        try write(metadata, "crs:CropTop", hasCrop ? number(crop.y) : nil, &report)
        try write(metadata, "crs:CropRight", hasCrop ? number(round6(crop.x + crop.width)) : nil, &report)
        try write(metadata, "crs:CropBottom", hasCrop ? number(round6(crop.y + crop.height)) : nil, &report)
        // Our rotation turns the picture clockwise, Lightroom turns the crop box clockwise → negate.
        try write(metadata, "crs:CropAngle", g.rotationDegrees == 0 ? nil : number(-g.rotationDegrees), &report)

        // Flips compose with the container's own orientation. Default flips must not touch
        // tiff:Orientation — the camera's tag is not ours to rewrite.
        if g.flipHorizontal || g.flipVertical {
            let orientation = XMPOrientation.composed(exif: context.exifOrientation ?? 1,
                                                      flipHorizontal: g.flipHorizontal,
                                                      flipVertical: g.flipVertical)
            try write(metadata, "tiff:Orientation", number(Double(orientation)), &report)
            report.notes.append("flips are baked into tiff:Orientation=\(orientation) "
                                + "(lossy: it also carries the camera's own orientation)")
        }

        // MARK: 1.3 light

        try write(metadata, "crs:Exposure2012", zeroOrNil(l.exposure), &report)
        try write(metadata, "crs:Contrast2012", zeroOrNil(l.contrast), &report)
        try write(metadata, "crs:Highlights2012", zeroOrNil(l.highlights), &report)
        try write(metadata, "crs:Shadows2012", zeroOrNil(l.shadows), &report)
        try write(metadata, "crs:Whites2012", zeroOrNil(l.whites), &report)
        try write(metadata, "crs:Blacks2012", zeroOrNil(l.blacks), &report)
        if let anchor = anchored {
            try write(metadata, "crs:Temperature", number(anchor.temperature), &report)
            try write(metadata, "crs:Tint", number(anchor.tint), &report)
            report.notes.append(followsAsShot
                                ? "WB = the file's as-shot set point"
                                : "WB is absolute Kelvin/tint, anchored on the as-shot set point")
        } else {
            try write(metadata, "crs:Temperature", nil, &report)
            try write(metadata, "crs:Tint", nil, &report)
            if !followsAsShot {
                report.notes.append("no as-shot WB known: crs:Temperature/Tint omitted, "
                                    + "Lightroom keeps as-shot")
            }
        }
        // ✕ highlightRecovery: a linear-domain soft shoulder above ~0.8; no crs: key means that.
        if l.highlightRecovery != 0 { report.skip("light.highlightRecovery") }

        // MARK: 1.4 curve

        try writeCurve(metadata, points: edit.curve.white, path: "crs:ToneCurvePV2012", &report)
        try writeCurve(metadata, points: edit.curve.red, path: "crs:ToneCurvePV2012Red", &report)
        try writeCurve(metadata, points: edit.curve.green, path: "crs:ToneCurvePV2012Green", &report)
        try writeCurve(metadata, points: edit.curve.blue, path: "crs:ToneCurvePV2012Blue", &report)
        let anyCurve = [edit.curve.white, edit.curve.red, edit.curve.green, edit.curve.blue]
            .contains { $0 != CurvePoint.linear }
        try write(metadata, "crs:ToneCurveName2012", anyCurve ? str("Custom") : nil, &report)

        // MARK: 1.5 color

        try write(metadata, "crs:Vibrance", zeroOrNil(c.vibrance), &report)
        try write(metadata, "crs:Saturation", zeroOrNil(c.saturation), &report)
        let bandNames = ["Red", "Orange", "Yellow", "Green", "Aqua", "Blue", "Purple", "Magenta"]
        for (i, name) in bandNames.enumerated() {
            let band = c.bands[i]
            try write(metadata, "crs:HueAdjustment\(name)", zeroOrNil(band.hue), &report)
            try write(metadata, "crs:SaturationAdjustment\(name)", zeroOrNil(band.saturation), &report)
            try write(metadata, "crs:LuminanceAdjustment\(name)", zeroOrNil(band.luminance), &report)
        }

        // MARK: 1.6 detail

        try write(metadata, "crs:Sharpness", zeroOrNil(d.sharpening), &report)
        try write(metadata, "crs:SharpenRadius", d.sharpeningRadius == 1 ? nil : number(d.sharpeningRadius), &report)
        try write(metadata, "crs:LuminanceSmoothing", zeroOrNil(d.noiseLuminance), &report)
        try write(metadata, "crs:ColorNoiseReduction", zeroOrNil(d.noiseColor), &report)
        // One bool becomes four keys: "lens correction was applied", not "same transform as ours".
        try write(metadata, "crs:LensProfileEnable", d.lensCorrections ? number(1) : nil, &report)
        try write(metadata, "crs:LensProfileSetup", d.lensCorrections ? str("LensProfile") : nil, &report)
        try write(metadata, "crs:LensProfileDistortionScale", d.lensCorrections ? number(100) : nil, &report)
        try write(metadata, "crs:LensProfileVignettingScale", d.lensCorrections ? number(100) : nil, &report)

        // MARK: 1.7 effects

        try write(metadata, "crs:PostCropVignetteAmount", zeroOrNil(e.vignetteAmount), &report)
        try write(metadata, "crs:PostCropVignetteMidpoint", e.vignetteMidpoint == 50 ? nil : number(e.vignetteMidpoint), &report)
        try write(metadata, "crs:PostCropVignetteFeather", e.vignetteFeather == 50 ? nil : number(e.vignetteFeather), &report)
        try write(metadata, "crs:PostCropVignetteRoundness", zeroOrNil(e.vignetteRoundness), &report)
        try write(metadata, "crs:GrainAmount", zeroOrNil(e.grain), &report)

        // MARK: 1.8 masks — nothing maps; allocate for M4 and count the leaves we dropped.

        if !edit.masks.isEmpty {
            for _ in edit.masks {
                report.skip("masks[i].id")
                report.skip("masks[i].kind")
                report.skip("masks[i].params")
            }
            report.notes.append("masks not migrated: our mask model has no Lightroom equivalent (M4)")
        }

        // MARK: photons: — the lossless half

        try write(metadata, "photons:schemaVersion", number(Double(edit.schemaVersion)), &report)
        try write(metadata, "photons:processVersion", number(Double(edit.processVersion)), &report)
        report.skip("schemaVersion")            // int lives in photons:, crs: has no such concept
        // As shot has no number to write: `crs:WhiteBalance = "As Shot"` records the state, and a
        // nominal 6500 here would be the lie 派单 006 removed.
        if let t = l.temperature {
            try write(metadata, "photons:temperature", number(t), &report)
        } else {
            report.skip("light.temperature (as shot)")
        }
        if let i = l.tint {
            try write(metadata, "photons:tint", number(i), &report)
        } else {
            report.skip("light.tint (as shot)")
        }
        try write(metadata, "photons:highlightRecovery", number(l.highlightRecovery), &report)
        if context.includeSettingsBlob {
            let blob = try settingsBlob(edit)
            try write(metadata, "photons:settings", str(blob.base64EncodedString()), &report)
            if blob.count > context.embeddedBlobLimit {
                report.notes.append("photons:settings is \(blob.count) B — keep this one in a sidecar")
            }
        }
        return report
    }

    // MARK: key plumbing

    /// Write a value, or remove the key when it is `nil`. Removal is what makes R1 hold when a new
    /// `EditModel` replaces an older one in the same packet: a default value must not inherit the
    /// previous export's number.
    static func write(_ metadata: CGMutableImageMetadata, _ path: String, _ value: CFTypeRef?,
                      _ report: inout XMPExportReport) throws {
        if let value {
            guard CGImageMetadataSetValueWithPath(metadata, nil, path as CFString, value) else {
                throw XMPExportError.setValueFailed(path)
            }
            report.written.append(path)
        } else if CGImageMetadataCopyTagWithPath(metadata, nil, path as CFString) != nil {
            _ = CGImageMetadataRemoveTagWithPath(metadata, nil, path as CFString)
        }
    }

    /// Curves are an `rdf:Seq` of `"x, y"` strings — never one space-separated string
    /// (docs/xmp-mapping.md §4.3). Identity must leave the key absent (R1).
    private static func writeCurve(_ metadata: CGMutableImageMetadata, points: [CurvePoint],
                                   path: String, _ report: inout XMPExportReport) throws {
        guard points != CurvePoint.linear else {
            try write(metadata, path, nil, &report)
            return
        }
        let normalized = XMPCurve.normalize(points)
        if normalized.dropped > 0 {
            report.notes.append("\(path): \(normalized.dropped) point(s) dropped "
                                + "(sorted, de-duplicated, thinned to \(normalized.points.count))")
        }
        let values = normalized.strings as CFArray
        let name = String(path.dropFirst(XMPNamespace.crsPrefix.count + 1))
        guard let tag = CGImageMetadataTagCreate(XMPNamespace.crs as CFString,
                                                 XMPNamespace.crsPrefix as CFString,
                                                 name as CFString,
                                                 .arrayOrdered, values),
              CGImageMetadataSetTagWithPath(metadata, nil, path as CFString, tag) else {
            throw XMPExportError.setValueFailed(path)
        }
        report.written.append(path)
    }

    // MARK: serialisation

    /// `CGImageMetadata` → an XMP packet wrapped in `<?xpacket?>` bookkeeping, with padding so a
    /// later in-place edit (Lightroom) does not have to rewrite the whole file.
    public static func packet(for edit: EditModel,
                              existing: CGImageMetadata? = nil,
                              context: XMPWriteContext = XMPWriteContext(),
                              padding: Int = 2048) throws -> (data: Data, report: XMPExportReport) {
        let (metadata, report) = try makeMetadata(for: edit, existing: existing, context: context)
        let core = try xmpData(metadata)
        return (wrap(core, padding: padding), report)
    }

    public static func xmpData(_ metadata: CGImageMetadata) throws -> Data {
        guard let data = CGImageMetadataCreateXMPData(metadata, nil) else {
            throw XMPExportError.xmpSerializationFailed
        }
        return data as Data
    }

    public static func wrap(_ xmp: Data, padding: Int = 2048) -> Data {
        var out = Data("<?xpacket begin=\"\u{FEFF}\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?>\n".utf8)
        out.append(xmp)
        out.append(Data("\n".utf8))
        if padding > 0 { out.append(Data(repeating: 0x20, count: padding)) }
        out.append(Data("<?xpacket end=\"w\"?>\n".utf8))
        return out
    }

    // MARK: sidecar

    /// Write `<dir>/<relPath>.xmp`. An existing packet is merged (we overwrite only our own keys);
    /// an unreadable one is backed up as `.bak-<stamp>` first.
    @discardableResult
    public static func writeSidecar(for edit: EditModel, to url: URL,
                                    context: XMPWriteContext = XMPWriteContext()) throws -> XMPExportReport {
        var existing: CGImageMetadata?
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path),
           let old = try? Data(contentsOf: url) {
            if let parsed = CGImageMetadataCreateFromXMPData(old as CFData) {
                existing = parsed
            } else if !old.isEmpty {
                let stamp = ISO8601Stamp.now()
                let backup = url.deletingLastPathComponent()
                    .appendingPathComponent(url.lastPathComponent + ".bak-" + stamp)
                try? fm.copyItem(at: url, to: backup)
            }
        }
        let (data, report) = try packet(for: edit, existing: existing, context: context)
        try writeAtomically(data, to: url)
        return report
    }

    public static func writeAtomically(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        do {
            guard fm.createFile(atPath: tmp.path, contents: nil) else {
                throw XMPExportError.writeFailed(url, "cannot create a temporary file")
            }
            let handle = try FileHandle(forWritingTo: tmp)
            try handle.write(contentsOf: data)
            try handle.synchronize()          // fsync before the rename, not after
            try handle.close()
            if fm.fileExists(atPath: url.path) {
                _ = try fm.replaceItemAt(url, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: url)
            }
        } catch let e as XMPExportError {
            try? fm.removeItem(at: tmp)
            throw e
        } catch {
            try? fm.removeItem(at: tmp)
            throw XMPExportError.writeFailed(url, error.localizedDescription)
        }
    }

    // MARK: container embedding

    public static let embeddableExtensions: Set<String> = ["jpg", "jpeg", "heic", "heif", "tif", "tiff", "png"]

    public static func canEmbed(_ url: URL) -> Bool {
        embeddableExtensions.contains(url.pathExtension.lowercased())
    }

    /// Path A of docs/xmp-mapping.md §4.2: mutable-copy the container's own metadata, set our keys,
    /// write a new file, then replace. The original is only touched when this is called explicitly.
    ///
    /// JPEG/HEIC/TIFF go through `CGImageDestinationCopyImageSource`, which copies the compressed
    /// image data instead of re-encoding it. PNG has no such path — ImageIO drops the packet there —
    /// so PNG alone is decoded and re-encoded.
    @discardableResult
    public static func embed(_ edit: EditModel, into url: URL,
                             context: XMPWriteContext = XMPWriteContext()) throws -> XMPExportReport {
        let ext = url.pathExtension.lowercased()
        guard embeddableExtensions.contains(ext) else {
            throw XMPExportError.unsupportedContainer(ext.isEmpty ? "<none>" : ext)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else {
            throw XMPExportError.embedFailed(url, "not a readable image")
        }
        let type = (CGImageSourceGetType(source) as String?) ?? UTType(filenameExtension: ext)?.identifier
        guard let type else { throw XMPExportError.embedFailed(url, "unknown image type") }

        var context = context
        if context.exifOrientation == nil,
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let orientation = props[kCGImagePropertyOrientation] as? Int {
            context.exifOrientation = orientation
        }

        // Never build an empty metadata object: the mutable copy is what keeps exif/iptc and
        // other people's crs: keys alive (docs/xmp-mapping.md §4.2 path A).
        let existing = CGImageSourceCopyMetadataAtIndex(source, 0, nil)
        let metadata = try mutableCopy(of: existing)
        var report = try apply(edit, to: metadata, context: context)

        let dir = url.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).xmp-tmp-\(UUID().uuidString).\(ext)")

        do {
            if ext == "png" {
                try writePNG(source: source, type: type as CFString, metadata: metadata, to: tmp, original: url)
            } else {
                try copyImageSource(source: source, type: type as CFString,
                                    metadata: metadata, to: tmp, original: url)
            }
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            if let e = error as? XMPExportError { throw e }
            throw XMPExportError.embedFailed(url, error.localizedDescription)
        }
        report.written.append("→ \(url.lastPathComponent)")
        return report
    }

    private static func copyImageSource(source: CGImageSource, type: CFString,
                                        metadata: CGImageMetadata, to tmp: URL,
                                        original: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL, type, 1, nil) else {
            throw XMPExportError.embedFailed(original, "cannot open a destination")
        }
        let options: [CFString: Any] = [kCGImageDestinationMetadata: metadata]
        var err: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(dest, source, options as CFDictionary, &err) else {
            let why = err.map { ($0.takeRetainedValue() as Error).localizedDescription } ?? "copy failed"
            throw XMPExportError.embedFailed(original, why)
        }
    }

    private static func writePNG(source: CGImageSource, type: CFString,
                                 metadata: CGImageMetadata, to tmp: URL, original: URL) throws {
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw XMPExportError.embedFailed(original, "cannot decode the image")
        }
        guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL, type, 1, nil) else {
            throw XMPExportError.embedFailed(original, "cannot open a destination")
        }
        CGImageDestinationAddImageAndMetadata(dest, image, metadata, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw XMPExportError.embedFailed(original, "finalize failed")
        }
    }

    // MARK: photons:settings payload

    /// `base64(zlib(JSON))` — deterministic because the encoder sorts keys.
    public static func settingsBlob(_ edit: EditModel) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = try encoder.encode(edit)
        return (try? compress(json)) ?? json
    }

    public static func settings(from blob: Data) -> EditModel? {
        let json = (try? decompress(blob)) ?? blob
        return try? JSONDecoder().decode(EditModel.self, from: json)
    }

    static func compress(_ data: Data) throws -> Data {
        let capacity = max(64, data.count + data.count / 2 + 64)
        var out = Data(count: capacity)
        let written = out.withUnsafeMutableBytes { dst -> Int in
            data.withUnsafeBytes { src -> Int in
                compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                          src.bindMemory(to: UInt8.self).baseAddress!, data.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { throw XMPExportError.xmpSerializationFailed }
        out.removeSubrange(written..<out.count)
        return out
    }

    static func decompress(_ data: Data) throws -> Data {
        // Grow until the buffer fits: zlib tells us nothing about the original size.
        var capacity = max(64, data.count * 8)
        for _ in 0..<8 {
            var out = Data(count: capacity)
            let written = out.withUnsafeMutableBytes { dst -> Int in
                data.withUnsafeBytes { src -> Int in
                    compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                              src.bindMemory(to: UInt8.self).baseAddress!, data.count,
                                              nil, COMPRESSION_ZLIB)
                }
            }
            if written > 0 && written < capacity {
                out.removeSubrange(written..<out.count)
                return out
            }
            capacity *= 4
        }
        throw XMPExportError.xmpSerializationFailed
    }

    // MARK: small helpers

    static func number(_ v: Double) -> CFNumber { NSNumber(value: v) }
    static func str(_ s: String) -> CFString { s as CFString }
    static func zeroOrNil(_ v: Double) -> CFNumber? { v == 0 ? nil : number(v) }
    static func round6(_ v: Double) -> Double { (v * 1_000_000).rounded() / 1_000_000 }
}

// MARK: - readback (tests + the one-shot importer; never used by the render path)

public enum XMPReadback {

    public static func tag(_ metadata: CGImageMetadata, _ path: String) -> CGImageMetadataTag? {
        CGImageMetadataCopyTagWithPath(metadata, nil, path as CFString)
    }

    /// Pitfall 2 (docs/xmp-mapping.md §4.3): a number can come back as CFNumber *or* as
    /// CFString("3.500000"). Never `CFNumberGetValue` a value you have not type-checked, and never
    /// compare formatted strings. A `,` decimal separator is rejected rather than silently parsed
    /// as two values (B10).
    public static func double(_ tag: CGImageMetadataTag?) -> Double? {
        guard let value = tag.flatMap(CGImageMetadataTagCopyValue) else { return nil }
        if CFGetTypeID(value) == CFNumberGetTypeID() {
            return (value as? NSNumber)?.doubleValue
        }
        if CFGetTypeID(value) == CFStringGetTypeID(), let s = value as? String {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            // Reject a comma decimal outright (B10): a locale that writes "0,5" must never be read
            // as 0. `Double(_:)` parses with C-locale rules regardless of LC_NUMERIC, which is
            // exactly the "force POSIX locale" the spec asks for — and it rejects junk instead of
            // silently truncating like `strtod` would.
            guard !trimmed.isEmpty, !trimmed.contains(",") else { return nil }
            return Double(trimmed)
        }
        if CFGetTypeID(value) == CFBooleanGetTypeID() {
            return (value as? NSNumber)?.doubleValue
        }
        return nil
    }

    public static func double(_ metadata: CGImageMetadata, _ path: String) -> Double? {
        double(tag(metadata, path))
    }

    public static func string(_ tag: CGImageMetadataTag?) -> String? {
        guard let value = tag.flatMap(CGImageMetadataTagCopyValue) else { return nil }
        return value as? String
    }

    public static func string(_ metadata: CGImageMetadata, _ path: String) -> String? {
        string(tag(metadata, path))
    }

    public static func bool(_ metadata: CGImageMetadata, _ path: String) -> Bool? {
        guard let value = tag(metadata, path).flatMap(CGImageMetadataTagCopyValue) else { return nil }
        if CFGetTypeID(value) == CFBooleanGetTypeID() { return (value as? NSNumber)?.boolValue }
        if let s = value as? String {
            return ["true", "1", "True"].contains(s)
        }
        if CFGetTypeID(value) == CFNumberGetTypeID() { return (value as? NSNumber)?.boolValue }
        return nil
    }

    /// Pitfall 1: `dc:subject`/`title`/`creator` read back as an array of **child tags**, not of
    /// strings. Unwrap one level of tags; also tolerate a plain string array.
    public static func strings(_ tag: CGImageMetadataTag?) -> [String]? {
        guard let value = tag.flatMap(CGImageMetadataTagCopyValue) else { return nil }
        if let array = value as? [Any] {
            // Pitfall 1: each element is a *child tag*, not a string. `as?` cannot be used on a CF
            // type (the compiler treats it as unconditional), so discriminate by CFTypeID.
            return array.compactMap { element -> String? in
                let anyObject = element as AnyObject
                if CFGetTypeID(anyObject) == CGImageMetadataTagGetTypeID() {
                    // Safe: the type id check above proved this is a CGImageMetadataTag.
                    let child = unsafeBitCast(anyObject, to: CGImageMetadataTag.self)
                    return CGImageMetadataTagCopyValue(child) as? String
                }
                return element as? String
            }
        }
        if let single = value as? String { return [single] }
        return nil
    }

    public static func strings(_ metadata: CGImageMetadata, _ path: String) -> [String]? {
        strings(tag(metadata, path))
    }

    /// Our `photons:settings` backup, decoded back into a document.
    public static func settings(_ metadata: CGImageMetadata) -> EditModel? {
        guard let blob = string(metadata, "photons:settings"),
              let data = Data(base64Encoded: blob) else { return nil }
        return XMPWriter.settings(from: data)
    }

    public static func metadata(of url: URL) -> CGImageMetadata? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCopyMetadataAtIndex(source, 0, nil)
    }

    public static func metadata(fromXMP url: URL) -> CGImageMetadata? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return CGImageMetadataCreateFromXMPData(data as CFData)
    }

    /// Every path in the packet, for "the key must not exist" assertions.
    public static func paths(_ metadata: CGImageMetadata) -> [String] {
        var out: [String] = []
        CGImageMetadataEnumerateTagsUsingBlock(metadata, nil, nil) { path, _ in
            out.append(path as String)
            return true
        }
        return out.sorted()
    }
}

// MARK: - timestamps for backups

enum ISO8601Stamp {
    static func now() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss"
        return f.string(from: Date())
    }
}
