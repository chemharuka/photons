import Foundation
import CoreGraphics
import PhotonsCore

// MARK: - output sharpening
//
// Output sharpening is the *last* thing that happens to the pixels, after the resample, and it is
// deliberately not part of `EditModel`: a slider in the document is "creative" sharpening that must
// be visible on screen, while this is the export-time counterpart (the thing that survives JPEG
// quantisation). Keeping it in the preset means a document rendered for the screen and for a 24 MP
// JPEG differ only in the preset, which is what D12 asks for.
public struct OutputSharpening: Sendable, Codable, Equatable {
    /// Unsharp-mask strength. 0 = off; 0.6 is "mild"; above ~1.5 halos are visible at 100 %.
    public var amount: Double
    /// Gaussian radius in output pixels. Below ~0.7 it only touches the finest detail.
    public var radius: Double

    public init(amount: Double = 0.6, radius: Double = 0.8) {
        self.amount = amount
        self.radius = radius
    }

    public var isEnabled: Bool { amount > 0 && radius > 0 }
}

// MARK: - new export sections (099)

/// What to do when the target file already exists. `rename` is the default: overwriting destroys a
/// file, skipping silently exports fewer photos, and only a new name can be undone.
public enum ExportConflict: String, Codable, Sendable, CaseIterable {
    case overwrite
    case skip
    case rename

    public var displayName: String {
        switch self {
        case .overwrite: return "覆盖"
        case .skip: return "跳过"
        case .rename: return "重命名"
        }
    }
}

/// How the output size is chosen. `longEdge` keeps the old ceiling; `percent` scales the cropped
/// picture's long edge by a percentage; `none` exports at the crop's own size.
public enum ExportSizingMode: String, Codable, Sendable, CaseIterable {
    case longEdge
    case percent
    case none

    public var displayName: String {
        switch self {
        case .longEdge: return "长边"
        case .percent: return "百分比"
        case .none: return "原尺寸"
        }
    }
}

/// How much metadata the exported copy carries.
public enum ExportMetadataLevel: String, Codable, Sendable, CaseIterable {
    case all
    case copyright
    case none

    public var displayName: String {
        switch self {
        case .all: return "全部"
        case .copyright: return "仅版权"
        case .none: return "无"
        }
    }
}

// MARK: - errors

public enum ExportPresetError: LocalizedError {
    case unknownFormat(String)
    case badQuality(Double)
    case badBitDepth(Int)
    case badLongEdge(Int)
    case badPercent(Int)
    case badSharpeningRadius(Double)
    case hdrRequiresHEIC(String)
    case badHDRHeadroom(Double)
    case emptyNameTemplate
    case unreadable(URL, String)

    public var errorDescription: String? {
        switch self {
        case .unknownFormat(let f):
            return "unknown export format '\(f)' (jpeg, heic, tiff, png, avif)"
        case .badQuality(let q):
            return "quality must be 0…1, got \(q)"
        case .badBitDepth(let b):
            return "bit depth must be 8 or 16, got \(b)"
        case .badLongEdge(let px):
            return "longEdge must be a positive pixel count, got \(px)"
        case .badPercent(let p):
            return "percent must be 10…100, got \(p)"
        case .badSharpeningRadius(let r):
            return "output sharpening radius must be 0.3…3, got \(r)"
        case .hdrRequiresHEIC(let f):
            return "HDR export needs HEIC (gain maps live in the HEIF container), got \(f)"
        case .badHDRHeadroom(let h):
            return "HDR manual headroom must be ≥ 1.05, got \(h)"
        case .emptyNameTemplate:
            return "nameTemplate is empty — the files would all be called '.jpg'"
        case .unreadable(let url, let why):
            return "could not read the preset at \(url.path): \(why)"
        }
    }
}

// MARK: - HDR export (100)

/// HDR export = a normal SDR HEIC plus a **gain map** auxiliary image that lets a reader reconstruct
/// the extended-range picture. Only HEIC can carry one, so `ExportPreset.validated()` rejects it on
/// every other format instead of silently writing an SDR file.
///
/// The structure mirrors the two working spellings of ISO 21496-1 / Apple's HDR gain map:
/// ISO RGB (per-channel ratio, `HDRToneMap/1.0` XMP inside `ISOGainMap`) and Apple monochrome
/// (`HDRGainMap/1.0` + MakerNote 33/48). `mono` is the ISO single-channel spelling. The reason there
/// are three and not one is that a reader's decoder is chosen by the auxiliary type and the
/// metadata namespace, not by preference.
public struct HDRExport: Sendable, Codable, Equatable {

    public enum GainMap: String, Sendable, Codable, CaseIterable {
        /// ISO 21496-1 RGB ratio (ImageIO writes it as `ISOGainMap` + `HDRToneMap/1.0` XMP).
        case iso
        /// Apple's `HDRGainMap` namespace + MakerNote 33/48 (a Rec.709-shaped monochrome ratio,
        /// exactly what toGainMapHDR's `-g` writes).
        case apple
        /// ISO single-channel luminance ratio (`L8`).
        case mono

        public var displayName: String {
            switch self {
            case .iso: return "ISO RGB"
            case .apple: return "Apple"
            case .mono: return "ISO mono"
            }
        }
    }

    /// `auto` measures the picture; `manual` fixes the ratio the map is normalized by (1.05…64).
    public enum Headroom: Sendable, Equatable {
        case auto
        case manual(Double)
    }

    public var enabled: Bool
    public var gainMap: GainMap
    /// Half-size gain map (`-H` in toGainMapHDR). The SDR base is never resized.
    public var halfSize: Bool
    public var headroom: Headroom

    public init(enabled: Bool = true, gainMap: GainMap = .iso, halfSize: Bool = false,
                headroom: Headroom = .auto) {
        self.enabled = enabled
        self.gainMap = gainMap
        self.halfSize = halfSize
        self.headroom = headroom
    }
}

extension HDRExport.Headroom: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self), s.lowercased() == "auto" {
            self = .auto
            return
        }
        self = .manual(try c.decode(Double.self))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .auto: try c.encode("auto")
        case .manual(let value): try c.encode(value)
        }
    }
}

// MARK: - preset

/// A named set of export settings: what the UI will show as a row and what `--preset file.json`
/// holds. `Codable` on purpose — a preset is a file a user can edit, version and share.
///
/// Decoding is tolerant in one direction only: a **missing** key takes its default (an old preset
/// keeps working when a field is added), while an **unknown** format is an error (a typo must not
/// silently export JPEG). Encoder output is `.sortedKeys`; keys added in 099 are omitted while they
/// hold their default, so an old preset re-encodes byte-for-byte and a new one stays diffable.
public struct ExportPreset: Sendable, Equatable {

    /// Optional human label ("Web 2000px"). Never used for naming.
    public var name: String?
    public var format: ExportFormat
    /// Long edge of the output in pixels, or `nil` for "the picture's own size" (scale 1).
    /// Never upscales: a 3000 px picture stays 3000 px with `longEdge = 6000`.
    public var longEdge: Int?
    /// Lossy quality 0…1. Ignored by TIFF/PNG (they are lossless).
    public var quality: Double
    /// 8 or 16 bits per channel. Coerced to 8 for formats that cannot carry 16 (JPEG, AVIF).
    public var bitDepth: Int
    public var colorSpace: OutputPrimaries
    /// 100 — HEIC + gain map. `nil`/disabled = the exact pre-HDR export path.
    public var hdr: HDRExport?
    /// Embed `crs:`/`photons:` XMP into the exported copy (a sidecar when the container cannot
    /// carry it). Off by default: a JPEG for the web should not carry a 4 KB metadata blob unless
    /// the user asked for it.
    public var writeXMP: Bool
    /// `nil` = off. Applied after the resample, to the final pixels.
    public var sharpen: OutputSharpening?
    /// `{name}` `{date}` `{seq}` `{rating}`; see `ExportNaming`.
    public var nameTemplate: String
    /// Which size rule `longEdge`/`percent` obey. `longEdge` keeps presets written before 099.
    public var sizingMode: ExportSizingMode
    /// Percent of the cropped picture's long edge, 10…100. Only used by `.percent`.
    public var percent: Int?
    /// Relative output folder under the destination. `""` = write straight into it; supports
    /// `{date}` (`yyyy-MM-dd`) and `{camera}`.
    public var subfolder: String
    /// What to do when the target name already exists on disk or in this batch.
    public var conflict: ExportConflict
    /// `all` = the full develop packet; `copyright` = author/copyright only; `none` = no XMP.
    public var metadataLevel: ExportMetadataLevel

    public init(name: String? = nil,
                format: ExportFormat = .jpeg,
                longEdge: Int? = nil,
                quality: Double = 0.92,
                bitDepth: Int = 8,
                colorSpace: OutputPrimaries = .sRGB,
                hdr: HDRExport? = nil,
                writeXMP: Bool = false,
                sharpen: OutputSharpening? = nil,
                nameTemplate: String = "{name}",
                sizingMode: ExportSizingMode = .longEdge,
                percent: Int? = nil,
                subfolder: String = "",
                conflict: ExportConflict = .rename,
                metadataLevel: ExportMetadataLevel = .all) {
        self.name = name
        self.format = format
        self.longEdge = longEdge
        self.quality = quality
        self.bitDepth = bitDepth
        self.colorSpace = colorSpace
        self.hdr = hdr
        self.writeXMP = writeXMP
        self.sharpen = sharpen
        self.nameTemplate = nameTemplate
        self.sizingMode = sizingMode
        self.percent = percent
        self.subfolder = subfolder
        self.conflict = conflict
        self.metadataLevel = metadataLevel
    }

    // MARK: derived

    /// What the encoder is actually allowed to write. JPEG/AVIF cannot carry 16 bits per channel, so
    /// a preset that asks for it is downgraded here instead of failing per image (the alternative
    /// would be a batch that exports 19 of 20 files and then complains about the twentieth).
    public var effectiveBitDepth: Int {
        bitDepth == 16 && format.supports16Bit ? 16 : 8
    }

    public var exportOptions: ExportOptions {
        ExportOptions(format: format, quality: quality, bitDepth: effectiveBitDepth,
                      hdr: hdr?.enabled == true ? hdr : nil)
    }

    /// True when this preset asks for the HDR path (HEIC + gain map).
    public var isHDR: Bool { hdr?.enabled == true && format == .heic }

    /// Scale to render at. `longEdge` is the historical ceiling; `percent` is the same picture at a
    /// fraction of its long edge; `none` is whatever the crop already is.
    public func renderScale(content: ImageSize) -> Double {
        switch sizingMode {
        case .longEdge:
            return ExportSizing.scale(content: content, longEdge: longEdge)
        case .percent:
            return ExportSizing.scale(content: content, percent: percent ?? 100)
        case .none:
            return 1
        }
    }

    /// No XMP at all when the metadata level says so, even if the flag is still set on disk.
    public var effectiveWriteXMP: Bool {
        metadataLevel == .none ? false : writeXMP
    }

    /// One line the sheet and the CLI can both print: format · bit depth · colour space · size ·
    /// conflict policy. Deliberately fixed vocabulary (099's bottom summary is asserted verbatim).
    public var summary: String {
        let size: String
        switch sizingMode {
        case .longEdge: size = longEdge.map { "长边 \($0)" } ?? "原尺寸"
        case .percent: size = "长边 \(percent ?? 100)%"
        case .none: size = "原尺寸"
        }
        var parts = [format.rawValue.uppercased(),
                     "\(effectiveBitDepth) 位",
                     colorSpace.displayName,
                     size,
                     conflict.displayName]
        // 100 + 099 的并集：HDR 打开时摘要多一段，关掉时逐字与 099 的断言相同。
        if let hdr, hdr.enabled, format == .heic {
            parts.append("HDR " + hdr.gainMap.displayName + (hdr.halfSize ? " 半尺寸" : ""))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: validation

    public func validated() throws -> ExportPreset {
        guard (0...1).contains(quality) else { throw ExportPresetError.badQuality(quality) }
        guard bitDepth == 8 || bitDepth == 16 else { throw ExportPresetError.badBitDepth(bitDepth) }
        guard !nameTemplate.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ExportPresetError.emptyNameTemplate
        }
        if let longEdge, longEdge <= 0 { throw ExportPresetError.badLongEdge(longEdge) }
        if let percent, !(10...100).contains(percent) { throw ExportPresetError.badPercent(percent) }
        if let sharpen, !(0.3...3.0).contains(sharpen.radius) {
            throw ExportPresetError.badSharpeningRadius(sharpen.radius)
        }
        if let hdr, hdr.enabled {
            guard format == .heic else {
                throw ExportPresetError.hdrRequiresHEIC(format.rawValue)
            }
            if case .manual(let h) = hdr.headroom, h < 1.05 {
                throw ExportPresetError.badHDRHeadroom(h)
            }
        }
        return self
    }

    // MARK: files

    public static func load(from url: URL) throws -> ExportPreset {
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            throw ExportPresetError.unreadable(url, error.localizedDescription)
        }
        do {
            return try JSONDecoder().decode(ExportPreset.self, from: data).validated()
        } catch let e as ExportPresetError {
            throw e
        } catch {
            throw ExportPresetError.unreadable(url, "\(error)")
        }
    }

    public func data() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data().write(to: url, options: .atomic)
    }
}

// MARK: - Codable (tolerant on read, complete on write)

extension ExportPreset: Codable {

    enum CodingKeys: String, CodingKey {
        case name, format, longEdge, quality, bitDepth, colorSpace, hdr, writeXMP, sharpen, nameTemplate
        case sizingMode, percent, subfolder, conflict, metadataLevel
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawFormat = try c.decodeIfPresent(String.self, forKey: .format) ?? ExportFormat.jpeg.rawValue
        guard let format = ExportFormat(presetName: rawFormat) else {
            throw ExportPresetError.unknownFormat(rawFormat)
        }
        let rawSpace = try c.decodeIfPresent(String.self, forKey: .colorSpace)
            ?? OutputPrimaries.sRGB.rawValue
        self.name = try c.decodeIfPresent(String.self, forKey: .name)
        self.format = format
        self.longEdge = try c.decodeIfPresent(Int.self, forKey: .longEdge)
        self.quality = try c.decodeIfPresent(Double.self, forKey: .quality) ?? 0.92
        self.bitDepth = try c.decodeIfPresent(Int.self, forKey: .bitDepth) ?? 8
        self.colorSpace = OutputPrimaries(presetName: rawSpace) ?? .sRGB
        self.hdr = try c.decodeIfPresent(HDRExport.self, forKey: .hdr)
        self.writeXMP = try c.decodeIfPresent(Bool.self, forKey: .writeXMP) ?? false
        self.sharpen = try c.decodeIfPresent(OutputSharpening.self, forKey: .sharpen)
        self.nameTemplate = try c.decodeIfPresent(String.self, forKey: .nameTemplate) ?? "{name}"
        self.sizingMode = try c.decodeIfPresent(String.self, forKey: .sizingMode)
            .flatMap(ExportSizingMode.init(rawValue:)) ?? .longEdge
        self.percent = try c.decodeIfPresent(Int.self, forKey: .percent)
        self.subfolder = try c.decodeIfPresent(String.self, forKey: .subfolder) ?? ""
        self.conflict = try c.decodeIfPresent(String.self, forKey: .conflict)
            .flatMap(ExportConflict.init(rawValue:)) ?? .rename
        self.metadataLevel = try c.decodeIfPresent(String.self, forKey: .metadataLevel)
            .flatMap(ExportMetadataLevel.init(rawValue:)) ?? .all
    }

    /// New-in-099 keys are written only when they are not the default. That is what makes a preset
    /// saved before 099 re-encode to exactly the same bytes: decoding it takes the defaults, and
    /// encoding omits them again.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encode(format.rawValue, forKey: .format)
        try c.encodeIfPresent(longEdge, forKey: .longEdge)
        try c.encode(quality, forKey: .quality)
        try c.encode(bitDepth, forKey: .bitDepth)
        try c.encode(colorSpace.rawValue, forKey: .colorSpace)
        // Encoded only when present, so a preset written before 100 is byte-identical (`git diff`
        // clean in tests that round-trip the old fixture).
        try c.encodeIfPresent(hdr, forKey: .hdr)
        try c.encode(writeXMP, forKey: .writeXMP)
        try c.encodeIfPresent(sharpen, forKey: .sharpen)
        try c.encode(nameTemplate, forKey: .nameTemplate)
        if sizingMode != .longEdge { try c.encode(sizingMode.rawValue, forKey: .sizingMode) }
        try c.encodeIfPresent(percent, forKey: .percent)
        if !subfolder.isEmpty { try c.encode(subfolder, forKey: .subfolder) }
        if conflict != .rename { try c.encode(conflict.rawValue, forKey: .conflict) }
        if metadataLevel != .all { try c.encode(metadataLevel.rawValue, forKey: .metadataLevel) }
    }
}

// MARK: - spelling tolerance

extension ExportFormat {
    /// Accepts the spellings a user (or another app's preset file) will actually write.
    public init?(presetName: String) {
        switch presetName.lowercased() {
        case "jpeg", "jpg": self = .jpeg
        case "heic", "heif": self = .heic
        case "tiff", "tif": self = .tiff
        case "png": self = .png
        case "avif", "av1": self = .avif
        default: return nil
        }
    }
}

extension OutputPrimaries {
    public init?(presetName: String) {
        switch presetName.lowercased().replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "") {
        case "srgb": self = .sRGB
        case "displayp3", "p3": self = .displayP3
        default: return nil
        }
    }
}

// MARK: - sizing

public enum ExportSizing {
    /// The render `scale` that turns `content` (the crop at 1:1) into a picture whose long edge is
    /// `longEdge`. Capped at 1: upscaling a RAW beyond its own pixels invents detail, and a preset
    /// asking for 8000 px on a 6000 px file is a preset, not a licence to interpolate.
    public static func scale(content: ImageSize, longEdge: Int?) -> Double {
        guard let longEdge, longEdge > 0 else { return 1 }
        let current = max(content.width, content.height)
        guard current > 0, current > longEdge else { return 1 }
        return Double(longEdge) / Double(current)
    }

    /// Percent of the current long edge. Never above 1: `validated()` caps percent at 100, and a
    /// stray 150 must not turn into an upscale here.
    public static func scale(content: ImageSize, percent: Int) -> Double {
        guard percent > 0 else { return 1 }
        return min(1, Double(percent) / 100)
    }

    /// The integer size the renderer will produce for `content` at `scale` — the same rounding
    /// `RenderGraph.plan` uses, so the expectation and the file must agree.
    public static func outputSize(content: ImageSize, scale: Double) -> ImageSize {
        let s = max(0.01, scale)
        return ImageSize(width: max(1, Int((Double(content.width) * s).rounded())),
                         height: max(1, Int((Double(content.height) * s).rounded())))
    }
}

// MARK: - naming

/// Filename templates. Four tokens, no expressions: `{name}` (source basename), `{date}`
/// (`yyyyMMdd`, UTC, empty when the catalog has no capture time), `{seq}` (1-based, 4 digits) and
/// `{rating}` (0–5). An unknown `{token}` is left verbatim — silently deleting it would turn
/// `{camera}_{name}` into two files called `_L1030402`.
public enum ExportNaming {

    public static let knownTokens = ["name", "date", "seq", "rating"]

    public static func baseName(template: String, item: ExportItem, sequence: Int) -> String {
        var out = ""
        var i = template.startIndex
        while i < template.endIndex {
            let ch = template[i]
            if ch == "{" , let close = template[i...].firstIndex(of: "}") {
                let token = String(template[template.index(after: i)..<close])
                switch token {
                case "name": out += item.name
                case "date": out += dateStamp(item.captureDate)
                case "seq": out += String(format: "%04d", sequence)
                case "rating": out += String(item.rating)
                default: out += "{" + token + "}"
                }
                i = template.index(after: close)
            } else {
                out.append(ch)
                i = template.index(after: i)
            }
        }
        return sanitize(out)
    }

    static func dateStamp(_ date: Date?) -> String {
        guard let date else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyyMMdd"
        return f.string(from: date)
    }

    // MARK: subfolders (099)

    /// Resolves `{date}` (`yyyy-MM-dd`, UTC, capture date or `now`) and `{camera}` (the model part
    /// of the catalog's `make|model` key) into a relative folder path. Slashes in the template are
    /// real separators; every other component is sanitised like a filename, and `.`/`..` are dropped
    /// so a preset cannot walk out of the destination directory.
    public static func subfolder(template: String, item: ExportItem,
                                 now: Date = Date()) -> String {
        guard !template.isEmpty else { return "" }
        var out = ""
        var i = template.startIndex
        while i < template.endIndex {
            let ch = template[i]
            if ch == "{", let close = template[i...].firstIndex(of: "}") {
                let token = String(template[template.index(after: i)..<close])
                switch token {
                case "date": out += folderDateStamp(item.captureDate ?? now)
                case "camera": out += cameraShorthand(item.cameraKey)
                default: out += "{" + token + "}"
                }
                i = template.index(after: close)
            } else {
                out.append(ch)
                i = template.index(after: i)
            }
        }
        let parts = out.split(separator: "/").compactMap { component -> String? in
            let raw = String(component).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty, raw != ".", raw != ".." else { return nil }
            let safe = sanitizeComponent(raw)
            return safe.isEmpty ? nil : safe
        }
        return parts.joined(separator: "/")
    }

    static func folderDateStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// `leica|sl3` → `sl3`; a key without a model keeps the whole key. The result still goes through
    /// `sanitizeComponent`, so a model with spaces or slashes cannot become a path.
    public static func cameraShorthand(_ key: String?) -> String {
        guard let key = key?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else { return "camera" }
        let model = key.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            .last.map(String.init) ?? key
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "camera" : trimmed
    }

    /// Like `sanitize`, but an empty result stays empty (a folder component that vanished is
    /// dropped instead of becoming a directory called `export`).
    static func sanitizeComponent(_ raw: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|\0")
        var s = ""
        for scalar in raw.unicodeScalars {
            if bad.contains(scalar) { s.append("-") }
            else if CharacterSet.whitespacesAndNewlines.contains(scalar) { s.append("_") }
            else { s.append(Character(scalar)) }
        }
        while s.hasPrefix(".") { s.removeFirst() }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// A filename, not a path: separators and the characters Windows/macOS disagree about become
    /// `-`, whitespace becomes `_`, leading dots are stripped (a hidden file would disappear from
    /// the user's export folder), and an empty result falls back to `export`.
    static func sanitize(_ raw: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|\0")
        var s = ""
        for scalar in raw.unicodeScalars {
            if bad.contains(scalar) { s.append("-") }
            else if CharacterSet.whitespacesAndNewlines.contains(scalar) { s.append("_") }
            else { s.append(Character(scalar)) }
        }
        while s.hasPrefix(".") { s.removeFirst() }
        s = s.trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? "export" : s
    }
}
