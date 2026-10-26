import Foundation
import ImageIO
import CoreGraphics

/// Everything M2 needs to know about one file, in the shape of the schema.
public struct PhotoMetadata: Sendable {
    public var width: Int?
    public var height: Int?
    public var captureTime: String?        // ISO8601 UTC
    public var captureLocalDate: String?   // YYYY-MM-DD in the capture's own timezone
    public var captureTimeSource: String   // exif | file | none
    public var cameraMake: String?
    public var cameraModel: String?
    public var cameraKey: String?
    public var lens: String?
    public var rating: Int?
    public var colorLabel: String?
    public var keywords: [String] = []
    public var iso: Int?
    public var focalLength: Double?
    public var aperture: Double?
    public var shutter: String?
    public var orientation: Int?
    public var exifJSON: String = "{}"
    public var xmpBlob: String?
    public var hadEmbeddedXMP = false
}

/// Reads EXIF/IPTC and — critically — **embedded XMP**.
///
/// The XMP path is `CGImageSourceCopyMetadataAtIndex` → `CGImageMetadata`, addressed by
/// `CGImageMetadataCopyTagWithPath`. It is *not* the properties dictionary: `kCGImagePropertyXMPDictionary`
/// does not exist in the SDK, and `{XMP}` is nil even when the file carries a packet (measured on a DNG
/// with a 15,478-byte XMP blob in TIFF tag 700). See docs/architecture-decisions.md §2 correction C.
///
/// Addressing by path also avoids a trap: *enumerating* tags yields child-tag descriptions for array
/// values, which is how a naive reader ends up with keywords literally named
/// `<CGImageMetadataTag 0x…> dc:[0] = test`.
public enum MetadataReader {

    public static func read(_ url: URL, fileModificationDate: Date? = nil) throws -> PhotoMetadata {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw CatalogError.metadataUnreadable(url)
        }
        var meta = PhotoMetadata(captureTimeSource: "none")

        let props = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]) ?? [:]
        meta.width = (props[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue
        meta.height = (props[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue
        meta.orientation = (props[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue

        let tiff = (props[kCGImagePropertyTIFFDictionary as String] as? [String: Any]) ?? [:]
        let exif = (props[kCGImagePropertyExifDictionary as String] as? [String: Any]) ?? [:]

        let md = CGImageSourceCopyMetadataAtIndex(source, 0, nil)
        if let md, let data = CGImageMetadataCreateXMPData(md, nil) as Data?,
           let text = String(data: data, encoding: .utf8), !text.isEmpty {
            meta.xmpBlob = text
            meta.hadEmbeddedXMP = true
        }

        // Camera / lens: XMP first (it survives more conversions), EXIF dictionaries as fallback.
        meta.cameraMake = xmpValue(md, "tiff:Make") ?? (tiff[kCGImagePropertyTIFFMake as String] as? String)
        meta.cameraModel = xmpValue(md, "tiff:Model") ?? (tiff[kCGImagePropertyTIFFModel as String] as? String)
        meta.cameraKey = Asset.cameraKey(make: meta.cameraMake, model: meta.cameraModel)
        meta.lens = xmpValue(md, "exifEX:LensModel") ?? xmpValue(md, "aux:Lens")
            ?? xmpValue(md, "exif:LensModel") ?? (exif[kCGImagePropertyExifLensModel as String] as? String)

        // Ratings and labels only ever come from embedded XMP (policy: sidecars are ignored).
        meta.rating = intXMP(md, "xmp:Rating")
        meta.colorLabel = xmpValue(md, "xmp:Label")

        // Keywords: `dc:subject` is an unordered array — read it as an array, then de-duplicate.
        var seen = Set<String>()
        meta.keywords = xmpArray(md, "dc:subject")
            .flatMap { $0.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) } }
            .filter { !$0.isEmpty && seen.insert($0).inserted }

        // Exposure facts: XMP, then EXIF dictionaries.
        meta.iso = intXMP(md, "exif:PhotographicSensitivity") ?? intXMP(md, "exif:ISOSpeedRatings")
            ?? (exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first?.intValue
            ?? (exif[kCGImagePropertyExifISOSpeedRatings as String] as? NSNumber)?.intValue
        meta.focalLength = doubleXMP(md, "exif:FocalLength")
            ?? (exif[kCGImagePropertyExifFocalLength as String] as? NSNumber)?.doubleValue
        meta.aperture = doubleXMP(md, "exif:FNumber")
            ?? (exif[kCGImagePropertyExifFNumber as String] as? NSNumber)?.doubleValue
        meta.shutter = shutterString(md: md, exif: exif)

        let capture = captureTime(md: md, tiff: tiff, exif: exif, fileURL: url, fileDate: fileModificationDate)
        meta.captureTime = capture.utc
        meta.captureLocalDate = capture.localDate
        meta.captureTimeSource = capture.source

        meta.exifJSON = jsonString(from: props) ?? "{}"
        return meta
    }

    // MARK: - XMP access (by path, never by enumeration)

    private static func xmpValue(_ md: CGImageMetadata?, _ path: String) -> String? {
        guard let md, let tag = CGImageMetadataCopyTagWithPath(md, nil, path as CFString),
              let value = CGImageMetadataTagCopyValue(tag) else { return nil }
        if let s = value as? String { return s.isEmpty ? nil : s }
        if let n = value as? NSNumber { return n.stringValue }
        return nil
    }

    private static func xmpArray(_ md: CGImageMetadata?, _ path: String) -> [String] {
        guard let md, let tag = CGImageMetadataCopyTagWithPath(md, nil, path as CFString),
              let value = CGImageMetadataTagCopyValue(tag) else { return [] }
        if let array = value as? [Any] {
            // Array elements are themselves `CGImageMetadataTag` refs, not strings — unwrap them.
            return array.compactMap { item -> String? in
                if let s = item as? String { return s }
                if let n = item as? NSNumber { return n.stringValue }
                let cf = item as CFTypeRef
                guard CFGetTypeID(cf) == CGImageMetadataTagGetTypeID() else { return nil }
                let child = unsafeBitCast(cf, to: CGImageMetadataTag.self)
                guard let childValue = CGImageMetadataTagCopyValue(child) else { return nil }
                if let s = childValue as? String { return s }
                if let n = childValue as? NSNumber { return n.stringValue }
                return nil
            }
        }
        if let s = value as? String { return [s] }
        return []
    }

    private static func intXMP(_ md: CGImageMetadata?, _ path: String) -> Int? {
        xmpValue(md, path).flatMap { Int($0) ?? Int(Double($0) ?? 0) }
    }

    private static func doubleXMP(_ md: CGImageMetadata?, _ path: String) -> Double? {
        xmpValue(md, path).flatMap { Double($0) }
    }

    /// XMP hands us a *rational string* (`55924/44739201` on a Leica DNG), EXIF hands us a double.
    /// Both go through `ShutterFormat` so the stored value is the standard shutter a photographer
    /// reads (`1/800`), never an improper fraction or a `1/8006` artefact of flooring.
    private static func shutterString(md: CGImageMetadata?, exif: [String: Any]) -> String? {
        if let s = xmpValue(md, "exif:ExposureTime"), let standard = ShutterFormat.standard(from: s) {
            return standard
        }
        if let n = exif[kCGImagePropertyExifExposureTime as String] as? NSNumber {
            return ShutterFormat.standard(seconds: n.doubleValue)
        }
        return nil
    }

    // MARK: - capture time

    private struct Capture {
        var utc: String?
        var localDate: String?
        var source: String
    }

    private static func captureTime(md: CGImageMetadata?, tiff: [String: Any], exif: [String: Any],
                                    fileURL: URL, fileDate: Date?) -> Capture {
        let offsetTag = xmpValue(md, "exif:OffsetTimeOriginal") ?? xmpValue(md, "exif:OffsetTime")

        // 1. photoshop:DateCreated carries its own offset — the best case.
        if let s = xmpValue(md, "photoshop:DateCreated"), let d = parseISO(s) {
            return Capture(utc: ISO8601.string(from: d),
                           localDate: localDateString(d, in: offset(fromISO: s).flatMap { timeZone($0) }),
                           source: "exif")
        }

        // 2. EXIF DateTimeOriginal (+ OffsetTimeOriginal when present), then other EXIF dates.
        let candidates = [xmpValue(md, "exif:DateTimeOriginal"),
                          exif[kCGImagePropertyExifDateTimeOriginal as String] as? String,
                          exif[kCGImagePropertyExifDateTimeDigitized as String] as? String,
                          tiff[kCGImagePropertyTIFFDateTime as String] as? String].compactMap { $0 }
        if let s = candidates.first, let d = parseEXIF(s, offsetString: offsetTag) {
            return Capture(utc: ISO8601.string(from: d),
                           localDate: localDateString(d, in: offsetTag.flatMap { timeZone($0) }),
                           source: "exif")
        }

        // 3. The file itself.
        if let date = fileDate ?? fileModificationDate(fileURL) {
            return Capture(utc: ISO8601.string(from: date), localDate: localDateString(date, in: nil), source: "file")
        }
        return Capture(utc: nil, localDate: nil, source: "none")
    }

    private static func fileModificationDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? nil
    }

    private static func parseISO(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    private static func parseEXIF(_ s: String, offsetString: String?) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        f.timeZone = offsetString.flatMap { timeZone($0) } ?? TimeZone.current
        return f.date(from: s)
    }

    private static func offset(fromISO s: String) -> String? {
        // Trailing "+08:00" / "Z" of an ISO8601 timestamp.
        guard let range = s.range(of: #"[+-]\d{2}:\d{2}$|Z$"#, options: .regularExpression) else { return nil }
        return String(s[range])
    }

    private static func timeZone(_ s: String) -> TimeZone? {
        if s == "Z" { return TimeZone(secondsFromGMT: 0) }
        guard s.count == 6, let sign = s.first, sign == "+" || sign == "-" else { return nil }
        let parts = s.dropFirst().split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        let seconds = (h * 3600 + m * 60) * (sign == "-" ? -1 : 1)
        return TimeZone(secondsFromGMT: seconds)
    }

    private static func localDateString(_ date: Date, in zone: TimeZone?) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = zone ?? TimeZone.current
        return f.string(from: date)
    }

    // MARK: - EXIF blob

    private static func jsonString(from object: Any) -> String? {
        let safe = sanitize(object)
        guard JSONSerialization.isValidJSONObject(safe) else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: safe, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func sanitize(_ value: Any) -> Any {
        switch value {
        case let d as Date: return ISO8601.string(from: d)
        case let d as Data: return d.base64EncodedString()
        case let dict as [String: Any]:
            var out: [String: Any] = [:]
            for (k, v) in dict { out[k] = sanitize(v) }
            return out
        case let arr as [Any]:
            return arr.map { sanitize($0) }
        case let n as NSNumber:
            return n
        case let s as String:
            return s
        default:
            return "\(value)"
        }
    }
}
