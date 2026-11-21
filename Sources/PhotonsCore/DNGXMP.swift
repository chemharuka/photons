import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Edit settings embedded in a **DNG's own XMP** (`photons:document`), so a lost library is not a
/// lost edit.
///
/// Why this exists at all: ImageIO cannot write DNG (`com.adobe.raw-image` is read-only — 22 writable
/// destinations, none of them raw), so this speaks TIFF itself. DNG is TIFF: the XMP packet lives in
/// IFD0 tag 700.
///
/// The write never moves a pixel. Two strategies, both append-only:
///
/// 1. **Slot reuse** — the existing packet already has room (XMP packets are padded): overwrite it in
///    place and fix the entry's count. File size does not change.
/// 2. **Append** — otherwise the new packet goes at EOF, followed by a **copy of IFD0** carrying the
///    updated tag, and the 8-byte header's "IFD0 offset" is pointed at the copy. Every other offset in
///    the file (SubIFDs, Exif/GPS IFDs, tile/strip data) still refers to where it always was, so the
///    image is byte-identical. Each such write costs ~1 KB.
///
/// Foreign properties are never dropped: the packet is **merged**, not replaced. A Lightroom `crs:*`
/// that is already there survives (「互不相干」不等于「我们清空对方」).
///
/// `undo` restores the header pointer from a small journal, which is what makes writing to an original
/// recoverable without keeping a 60 MB copy (the library stores references, not copies).
public enum DNGXMP {

    /// Our one property. Nothing else is read back.
    public static let property = "photons:document"
    public static let namespace = "https://photons.app/ns/1"

    public enum Failure: Error, CustomStringConvertible {
        case notTIFF(String)
        case unsupportedLayout(String)
        case packetTooLarge(Int)
        case writeFailed(String)

        public var description: String {
            switch self {
            case .notTIFF(let why): return "not a TIFF/DNG: \(why)"
            case .unsupportedLayout(let why): return "unsupported DNG layout: \(why)"
            case .packetTooLarge(let n): return "XMP packet is \(n) bytes — larger than one IFD value can address"
            case .writeFailed(let why): return "could not write XMP: \(why)"
            }
        }
    }

    /// What a write did, for the caller's log line and the tests.
    public struct Outcome: Equatable {
        /// `true` when the packet fitted in the existing slot (file size unchanged).
        public var reusedSlot: Bool
        /// Bytes appended to the file.
        public var appendedBytes: Int
    }

    // MARK: - read

    /// The document string stored in `url`, or `nil` when the file has no `photons:document`.
    public static func documentString(at url: URL) throws -> String? {
        try documentString(in: Data(contentsOf: url, options: .mappedIfSafe))
    }

    public static func documentString(in data: Data) throws -> String? {
        let file = try TIFFFile(data)
        guard let entry = file.entries(of: 700, in: file.ifd0) else { return nil }
        let packet = try file.payload(entry)
        guard let text = String(data: packet, encoding: .utf8) else { return nil }
        return extractDocument(from: text)
    }

    // MARK: - write

    @discardableResult
    public static func writeDocument(_ document: String, to url: URL,
                                     journal: DNGXMPJournal = .standard) throws -> Outcome {
        var file = try TIFFFile(Data(contentsOf: url))
        try journal.remember(header: file.headerBytes, ifd0: file.ifd0, for: url)

        let existing = file.entries(of: 700, in: file.ifd0).map { try? file.payload($0) } ?? nil
        let packet = merged(existing: existing.flatMap { $0 }, document: document)

        // 1. Slot reuse: the old packet had at least as much room, so nothing moves. A document that
        //    grew a few bytes is paid for out of the packet's own trailing padding (XMP pads with
        //    spaces after `<?xpacket end="w"?>`), not with a fresh ~18 KB append.
        if let entry = file.entries(of: 700, in: file.ifd0),
           let fitted = Self.trimmed(packet, toFit: Int(entry.count)) {
            try file.overwritePayload(entry, with: fitted)
            try file.persist(to: url)
            return Outcome(reusedSlot: true, appendedBytes: 0)
        }

        // 2. Append packet + a copy of IFD0 that points at it.
        let before = file.data.count
        try file.appendPacketAndRewriteIFD(packet)
        try file.persist(to: url)
        return Outcome(reusedSlot: false, appendedBytes: file.data.count - before)
    }

    /// Removes `photons:document` (and only that property) from the file's XMP.
    @discardableResult
    public static func removeDocument(at url: URL) throws -> Outcome {
        var file = try TIFFFile(Data(contentsOf: url))
        guard let entry = file.entries(of: 700, in: file.ifd0),
              let packet = try? file.payload(entry),
              let text = String(data: packet, encoding: .utf8),
              let stripped = removingDocument(from: text) else {
            return Outcome(reusedSlot: true, appendedBytes: 0)
        }
        let newPacket = Data(stripped.utf8)
        if entry.count >= newPacket.count {
            try file.overwritePayload(entry, with: newPacket)
        } else {
            try file.appendPacketAndRewriteIFD(newPacket)
        }
        try file.persist(to: url)
        return Outcome(reusedSlot: entry.count >= newPacket.count, appendedBytes: 0)
    }

    /// `‹original›.xmp` — Adobe's generic sidecar suffix, extension preserved (`IMG_1234.CR3` ⇒
    /// `IMG_1234.CR3.xmp`).
    public static func sidecarURL(for source: URL) -> URL {
        source.appendingPathExtension("xmp")
    }

    public struct SidecarOutcome: Equatable {
        public var wrote: Bool
        public var bytes: Int
    }

    /// The document in a source's sidecar, if one exists. Used only by the explicit read door.
    public static func sidecarDocument(at source: URL) throws -> String? {
        let url = sidecarURL(for: source)
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return extractDocument(from: text)
    }

    /// Write the edit to `sidecarURL(for:)`. Fast: one small UTF-8 file, no decode.
    ///
    /// The packet is **merged** with any existing sidecar, so another program's properties survive.
    /// Unchanged documents do not touch the file (保存 is idempotent on disk too).
    @discardableResult
    public static func writeSidecar(document: String, for source: URL) throws -> SidecarOutcome {
        let url = sidecarURL(for: source)
        let existingData = try? Data(contentsOf: url)
        let existingText = existingData.flatMap { String(data: $0, encoding: .utf8) }
        if let existingText, extractDocument(from: existingText) == document {
            return SidecarOutcome(wrote: false, bytes: 0)
        }
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            guard fm.isWritableFile(atPath: url.path) else {
                throw Failure.writeFailed("\(url.lastPathComponent) 是只读文件，未写入")
            }
        } else {
            let directory = url.deletingLastPathComponent()
            guard fm.isWritableFile(atPath: directory.path) else {
                throw Failure.writeFailed("\(directory.lastPathComponent) 目录不可写，未写入 \(url.lastPathComponent)")
            }
        }
        let packet = merged(existing: existingData, document: document)
        do {
            try packet.write(to: url, options: .atomic)
        } catch {
            throw Failure.writeFailed("\(url.lastPathComponent): \(error.localizedDescription)")
        }
        return SidecarOutcome(wrote: true, bytes: packet.count)
    }

    /// Puts the header's IFD0 pointer back where the first write found it, which makes everything this
    /// type appended unreachable. The file's image is exactly the original again.
    public static func undo(at url: URL, journal: DNGXMPJournal = .standard) throws {
        guard let record = journal.record(for: url) else {
            throw Failure.writeFailed("no journal entry for \(url.lastPathComponent)")
        }
        guard let header = Data(base64Encoded: record.headerBase64) else {
            throw Failure.writeFailed("journal entry for \(url.lastPathComponent) is corrupt")
        }
        var file = try TIFFFile(Data(contentsOf: url))
        file.restoreHeader(header)
        try file.persist(to: url)
        journal.forget(url)
    }

    // MARK: - packet text

    /// `merged` inserts or replaces **our** property and leaves every other byte of the packet alone.
    static func merged(existing: Data?, document: String) -> Data {
        let escaped = xmlEscape(document)
        if let existing, var text = String(data: existing, encoding: .utf8) {
            if let open = text.range(of: "<\(property)>"),
               let close = text.range(of: "</\(property)>", range: open.upperBound..<text.endIndex) {
                text.replaceSubrange(open.upperBound..<close.lowerBound, with: escaped)
                return Data(text.utf8)
            }
            if let rdfEnd = text.range(of: "</rdf:RDF>") {
                let declaration = text.contains("xmlns:photons=") ? "" : " xmlns:photons=\"\(namespace)\""
                let block = "<rdf:Description rdf:about=\"\"\(declaration)>"
                    + "<\(property)>\(escaped)</\(property)></rdf:Description>\n"
                text.insert(contentsOf: block, at: rdfEnd.lowerBound)
                return Data(text.utf8)
            }
        }
        let fresh = """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about="" xmlns:photons="\(namespace)"><\(property)>\(escaped)</\(property)></rdf:Description>
        </rdf:RDF></x:xmpmeta>
        <?xpacket end="w"?>
        """
        return Data(fresh.utf8)
    }

    static func extractDocument(from packet: String) -> String? {
        if let open = packet.range(of: "<\(property)>"),
           let close = packet.range(of: "</\(property)>", range: open.upperBound..<packet.endIndex) {
            return xmlUnescape(String(packet[open.upperBound..<close.lowerBound]))
        }
        return nil
    }

    static func removingDocument(from packet: String) -> String? {
        guard let open = packet.range(of: "<\(property)>"),
              let close = packet.range(of: "</\(property)>", range: open.upperBound..<packet.endIndex) else {
            return nil
        }
        var text = packet
        text.removeSubrange(open.lowerBound..<close.upperBound)
        return text
    }

    /// `packet`, or `packet` with trailing spaces removed so it fits `limit` — `nil` when it still
    /// does not fit. Trailing spaces are the padding XMP itself writes, so removing them is free.
    static func trimmed(_ packet: Data, toFit limit: Int) -> Data? {
        if packet.count <= limit { return packet }
        var p = packet
        while p.count > limit, p.last == 0x20 { p.removeLast() }
        return p.count <= limit ? p : nil
    }

    static func xmlEscape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count + 16)
        for ch in s {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default: out.append(ch)
            }
        }
        return out
    }

    static func xmlUnescape(_ s: String) -> String {
        guard s.contains("&") else { return s }
        return s.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

// MARK: - journal

/// Small record of the header each file had before we first touched it. Enough to undo without a copy.
public struct DNGXMPJournal {

    public static let standard = DNGXMPJournal()

    public let directory: URL

    public init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.directory = base.appendingPathComponent("Photons/xmp-journal", isDirectory: true)
        }
    }

    struct Record: Codable { var headerBase64: String; var ifd0: UInt32 }

    func url(for file: URL) -> URL {
        // Stable per path; a moved file simply starts a new record, which is the honest answer.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325            // FNV-1a, no dependency
        for byte in file.path.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
        return directory.appendingPathComponent(String(format: "%016llx.json", hash))
    }

    func remember(header: Data, ifd0: UInt32, for file: URL) throws {
        let target = url(for: file)
        guard !FileManager.default.fileExists(atPath: target.path) else { return }  // first write only
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let record = Record(headerBase64: header.base64EncodedString(), ifd0: ifd0)
        try JSONEncoder().encode(record).write(to: target)
    }

    func record(for file: URL) -> Record? {
        guard let data = try? Data(contentsOf: url(for: file)) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    func forget(_ file: URL) {
        try? FileManager.default.removeItem(at: url(for: file))
    }
}

// MARK: - file metadata

/// What an **atomic replace** loses: a new inode means a fresh birth time, fresh permission bits, and
/// no extended attributes or ACL. Captured before an atomic write and put back afterwards.
///
/// Date Added (`ATTR_CMN_ADDEDTIME`) is deliberately **not** here: it is a kernel/Spotlight property
/// that has no public setter, so the only way to keep it is not to change the inode — which is exactly
/// why the slot-reuse path writes in place.
struct DNGFileMetadata {

    var creationDate: Date?
    var permissions: NSNumber?
    var extendedAttributes: [String: Data]
    var aclText: String?

    static func capture(at url: URL) -> DNGFileMetadata {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return DNGFileMetadata(
            creationDate: attributes?[.creationDate] as? Date,
            permissions: attributes?[.posixPermissions] as? NSNumber,
            extendedAttributes: captureExtendedAttributes(at: url.path),
            aclText: captureACL(at: url.path))
    }

    /// Best effort, in the brief's order: creation date → permissions → extended attributes → ACL.
    /// Returns the names that could not be put back; the caller logs them once and still reports the
    /// save as successful (metadata restoration is not allowed to turn a good write into a failure).
    func restore(to url: URL) -> [String] {
        var failures: [String] = []

        if let creationDate {
            var values = URLResourceValues()
            values.creationDate = creationDate
            var mutable = url
            do { try mutable.setResourceValues(values) } catch { failures.append("创建日期") }
        }

        if let permissions {
            do {
                try FileManager.default.setAttributes([.posixPermissions: permissions],
                                                      ofItemAtPath: url.path)
            } catch {
                failures.append("权限位")
            }
        }

        for (name, value) in extendedAttributes {
            let result = value.withUnsafeBytes { bytes in
                setxattr(url.path, name, bytes.baseAddress, value.count, 0, 0)
            }
            if result != 0 { failures.append("扩展属性 \(name)") }
        }
        // The fresh inode may have picked up a default attribute; "consistent" also means no extras.
        for name in Self.extendedAttributeNames(at: url.path) where extendedAttributes[name] == nil {
            if removexattr(url.path, name, 0) == 0 {
                // removed
            } else {
                failures.append("多余扩展属性 \(name)")
            }
        }

        if let aclText {
            if let acl = acl_from_text(aclText) {
                let result = acl_set_file(url.path, ACL_TYPE_EXTENDED, acl)
                acl_free(UnsafeMutableRawPointer(acl))
                if result != 0 { failures.append("ACL") }
            } else {
                failures.append("ACL")
            }
        }

        return failures
    }

    private static func captureExtendedAttributes(at path: String) -> [String: Data] {
        var values: [String: Data] = [:]
        for name in extendedAttributeNames(at: path) {
            let length = getxattr(path, name, nil, 0, 0, 0)
            guard length >= 0 else { continue }
            var bytes = [UInt8](repeating: 0, count: length)
            let read = getxattr(path, name, &bytes, length, 0, 0)
            guard read == length else { continue }
            values[name] = Data(bytes)
        }
        return values
    }

    private static func extendedAttributeNames(at path: String) -> [String] {
        let size = listxattr(path, nil, 0, 0)
        guard size > 0 else { return [] }
        var buffer = [CChar](repeating: 0, count: size)
        guard listxattr(path, &buffer, size, 0) == size else { return [] }

        var names: [String] = []
        var current = ""
        for byte in buffer {
            if byte == 0 {
                if !current.isEmpty { names.append(current); current = "" }
            } else {
                current.append(Character(UnicodeScalar(UInt8(bitPattern: byte))))
            }
        }
        return names
    }

    private static func captureACL(at path: String) -> String? {
        guard let acl = acl_get_file(path, ACL_TYPE_EXTENDED) else { return nil }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard let text = acl_to_text(acl, nil) else { return nil }
        defer { acl_free(UnsafeMutableRawPointer(text)) }
        let value = String(cString: text)
        return value.isEmpty ? nil : value
    }
}

// MARK: - TIFF

/// The minimum of TIFF that this job needs: header, IFD0's entries, and the bytes an entry points at.
struct TIFFFile {

    enum EntryValue { case inline([UInt8]), offset(UInt32, count: UInt32) }

    struct Entry {
        var tag: UInt16
        var type: UInt16
        var count: UInt32
        var raw: [UInt8]          // the 4 value bytes as they sit in the file
    }

    private(set) var data: Data
    private(set) var littleEndian: Bool
    private(set) var ifd0: UInt32
    var headerBytes: Data { data.prefix(8) }

    /// Byte ranges changed by the mutators. An in-place save writes only these — a slot-reuse save
    /// touches the ~18 KB XMP packet, not the whole 68 MB DNG.
    private(set) var dirtyRanges: [Range<Int>] = []

    mutating func markDirty(_ range: Range<Int>) {
        guard !range.isEmpty else { return }
        dirtyRanges.append(range)
    }

    init(_ data: Data) throws {
        self.data = data
        self.littleEndian = true
        self.ifd0 = 0
        guard data.count >= 8 else { throw DNGXMP.Failure.notTIFF("file is \(data.count) bytes") }
        let b0 = data[data.startIndex], b1 = data[data.startIndex + 1]
        if b0 == 0x49 && b1 == 0x49 { littleEndian = true }
        else if b0 == 0x4D && b1 == 0x4D { littleEndian = false }
        else { throw DNGXMP.Failure.notTIFF("byte order \(String(format: "%02x%02x", b0, b1))") }
        guard u16(2) == 42 else { throw DNGXMP.Failure.notTIFF("magic \(u16(2))") }
        ifd0 = u32(4)
        guard Int(ifd0) + 2 <= data.count else { throw DNGXMP.Failure.unsupportedLayout("IFD0 at \(ifd0)") }
    }

    // scalars
    func u16(_ at: Int) -> UInt16 {
        let i = data.startIndex + at
        let lo = UInt16(data[i]), hi = UInt16(data[i + 1])
        return littleEndian ? (lo | hi << 8) : (lo << 8 | hi)
    }

    func u32(_ at: Int) -> UInt32 {
        let i = data.startIndex + at
        let bytes = (0..<4).map { UInt32(data[i + $0]) }
        return littleEndian
            ? (bytes[0] | bytes[1] << 8 | bytes[2] << 16 | bytes[3] << 24)
            : (bytes[0] << 24 | bytes[1] << 16 | bytes[2] << 8 | bytes[3])
    }

    mutating func putU16(_ v: UInt16, at: Int) {
        let i = data.startIndex + at
        if littleEndian { data[i] = UInt8(v & 0xff); data[i + 1] = UInt8(v >> 8) }
        else { data[i] = UInt8(v >> 8); data[i + 1] = UInt8(v & 0xff) }
        markDirty(at..<(at + 2))
    }

    mutating func putU32(_ v: UInt32, at: Int) {
        let i = data.startIndex + at
        if littleEndian {
            for k in 0..<4 { data[i + k] = UInt8((v >> (8 * UInt32(k))) & 0xff) }
        } else {
            for k in 0..<4 { data[i + k] = UInt8((v >> (8 * UInt32(3 - k))) & 0xff) }
        }
        markDirty(at..<(at + 4))
    }

    func u32Bytes(_ v: UInt32) -> [UInt8] {
        littleEndian
            ? [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)]
            : [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
    }

    var entryCount: Int { Int(u16(Int(ifd0))) }

    func entries(of tag: UInt16, in ifd: UInt32) -> Entry? {
        let base = Int(ifd)
        guard base + 2 <= data.count else { return nil }
        let n = Int(u16(base))
        for i in 0..<n {
            let at = base + 2 + 12 * i
            guard at + 12 <= data.count else { return nil }
            let t = u16(at)
            if t == tag {
                return Entry(tag: t, type: u16(at + 2), count: u32(at + 4),
                             raw: (0..<4).map { data[data.startIndex + at + 8 + $0] })
            }
        }
        return nil
    }

    /// Every entry of IFD0, in file order (they are already sorted by tag).
    func allEntries() -> [Entry] { allEntries(in: ifd0) }

    /// Every entry of any directory, in file order.
    func allEntries(in ifd: UInt32) -> [Entry] {
        let base = Int(ifd)
        guard base + 2 <= data.count else { return [] }
        let n = Int(u16(base))
        return (0..<n).compactMap { i in
            let at = base + 2 + 12 * i
            guard at + 12 <= data.count else { return nil }
            return Entry(tag: u16(at), type: u16(at + 2), count: u32(at + 4),
                         raw: (0..<4).map { data[data.startIndex + at + 8 + $0] })
        }
    }

    func `next`() -> UInt32 { nextIFD(after: ifd0) }

    /// The next-IFD pointer of any directory (0 = end of the chain).
    func nextIFD(after ifd: UInt32) -> UInt32 {
        let base = Int(ifd)
        guard base + 2 <= data.count else { return 0 }
        let at = base + 2 + 12 * Int(u16(base))
        guard at + 4 <= data.count else { return 0 }
        return u32(at)
    }

    /// The SubIFD directories a directory lists (tag 330), in file order.
    func subIFDOffsets(in ifd: UInt32) -> [UInt32] {
        guard let e = entries(of: 330, in: ifd), let bytes = try? payload(e) else { return [] }
        var out: [UInt32] = []
        out.reserveCapacity(bytes.count / 4)
        var i = bytes.startIndex
        while i + 4 <= bytes.endIndex {
            if littleEndian {
                out.append(UInt32(bytes[i]) | UInt32(bytes[i + 1]) << 8
                           | UInt32(bytes[i + 2]) << 16 | UInt32(bytes[i + 3]) << 24)
            } else {
                out.append(UInt32(bytes[i]) << 24 | UInt32(bytes[i + 1]) << 16
                           | UInt32(bytes[i + 2]) << 8 | UInt32(bytes[i + 3]))
            }
            i += 4
        }
        return out
    }

    /// The bytes an entry's value lives in.
    func payload(_ e: Entry) throws -> Data {
        let size = TIFFFile.typeSize(e.type) * Int(e.count)
        if size <= 4 {
            return Data(e.raw.prefix(size))
        }
        let offset = Int(UInt32(littleEndian
            ? (UInt32(e.raw[0]) | UInt32(e.raw[1]) << 8 | UInt32(e.raw[2]) << 16 | UInt32(e.raw[3]) << 24)
            : (UInt32(e.raw[0]) << 24 | UInt32(e.raw[1]) << 16 | UInt32(e.raw[2]) << 8 | UInt32(e.raw[3]))))
        guard offset + size <= data.count else {
            throw DNGXMP.Failure.unsupportedLayout("tag \(e.tag) payload \(offset)+\(size) past EOF")
        }
        return data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + size))
    }

    /// The value of a scalar SHORT/LONG entry, decoded in the file's own byte order.
    func scalarValue(_ e: Entry) -> UInt32? {
        switch e.type {
        case 3, 8:
            guard e.raw.count >= 2 else { return nil }
            let value = littleEndian
                ? UInt16(e.raw[0]) | UInt16(e.raw[1]) << 8
                : UInt16(e.raw[0]) << 8 | UInt16(e.raw[1])
            return UInt32(value)
        case 4, 9, 13:
            guard e.raw.count >= 4 else { return nil }
            return littleEndian
                ? UInt32(e.raw[0]) | UInt32(e.raw[1]) << 8 | UInt32(e.raw[2]) << 16 | UInt32(e.raw[3]) << 24
                : UInt32(e.raw[0]) << 24 | UInt32(e.raw[1]) << 16 | UInt32(e.raw[2]) << 8 | UInt32(e.raw[3])
        default:
            return nil
        }
    }

    static func typeSize(_ type: UInt16) -> Int {
        switch type {
        case 1, 2, 6, 7: return 1          // BYTE, ASCII, SBYTE, UNDEFINED
        case 3, 8: return 2                // SHORT, SSHORT
        case 4, 9, 11, 13: return 4        // LONG, SLONG, FLOAT, IFD
        case 5, 10, 12: return 8           // RATIONAL, SRATIONAL, DOUBLE
        default: return 1
        }
    }

    // MARK: mutations

    /// Writes `packet` over the existing tag-700 payload in place and records the new length.
    mutating func overwritePayload(_ entry: Entry, with packet: Data) throws {
        guard let position = entryPosition(tag: 700, in: ifd0) else {
            throw DNGXMP.Failure.unsupportedLayout("tag 700 vanished")
        }
        try writePayload(entry, at: position, packet: packet)
    }

    func entryPosition(tag: UInt16, in ifd: UInt32) -> Int? {
        let base = Int(ifd)
        guard base + 2 <= data.count else { return nil }
        let n = Int(u16(base))
        for i in 0..<n {
            let at = base + 2 + 12 * i
            guard at + 12 <= data.count else { return nil }
            if u16(at) == tag { return at }
        }
        return nil
    }

    /// Replaces the inline 4-byte value of a LONG/SHORT entry (an offset or a count).
    mutating func setEntryValue(_ value: UInt32, tag: UInt16, in ifd: UInt32) throws {
        guard let position = entryPosition(tag: tag, in: ifd) else {
            throw DNGXMP.Failure.unsupportedLayout("tag \(tag) is missing from IFD \(ifd)")
        }
        let type = u16(position + 2)
        switch type {
        case 3, 8:                          // SHORT
            guard value <= UInt32(UInt16.max) else {
                throw DNGXMP.Failure.unsupportedLayout("tag \(tag) is SHORT but the value is \(value)")
            }
            putU16(UInt16(value), at: position + 8)
        case 4, 9, 13:                      // LONG, SLONG, IFD
            putU32(value, at: position + 8)
        default:
            throw DNGXMP.Failure.unsupportedLayout("tag \(tag) has type \(type), not a scalar integer")
        }
    }

    /// Overwrites `bytes` at `offset`, then zero-fills up to `limit` bytes. Used by the thumbnail
    /// replacement, where a shorter JPEG is padded so the slot's old length is not left with stale
    /// bytes from the previous picture.
    mutating func overwriteBytes(at offset: Int, with bytes: Data, zeroFillTo limit: Int) throws {
        let total = max(bytes.count, limit)
        guard offset >= 0, offset + total <= data.count else {
            throw DNGXMP.Failure.unsupportedLayout("write \(total) bytes at \(offset) past EOF \(data.count)")
        }
        let base = data.startIndex + offset
        for k in 0..<total {
            data[base + k] = k < bytes.count ? bytes[bytes.startIndex + k] : 0
        }
        markDirty(offset..<(offset + total))
    }

    /// Appends `block` at EOF, keeping the file even-aligned. Returns the byte offset it landed at.
    mutating func appendBlock(_ block: Data) -> Int {
        if data.count % 2 != 0 { data.append(0) }
        let offset = data.count
        data.append(block)
        if data.count % 2 != 0 { data.append(0) }
        return offset
    }

    private func entryPosition(tag: UInt16) -> Int? { entryPosition(tag: tag, in: ifd0) }

    private mutating func writePayload(_ entry: Entry, at position: Int, packet: Data) throws {
        let size = TIFFFile.typeSize(entry.type) * Int(entry.count)
        if size <= 4 {
            guard packet.count <= 4 else {
                throw DNGXMP.Failure.unsupportedLayout("inline tag 700 cannot grow past 4 bytes")
            }
            // Inline: value bytes then the new count, both in IFD0 itself.
            for k in 0..<4 { data[data.startIndex + position + 8 + k] = k < packet.count ? packet[packet.startIndex + k] : 0 }
            markDirty((position + 8)..<(position + 12))
            putU32(UInt32(packet.count), at: position + 4)
            return
        }
        let offset = payloadOffset(entry)
        for k in 0..<size {
            data[data.startIndex + offset + k] = k < packet.count ? packet[packet.startIndex + k] : 0x20
        }
        markDirty(offset..<(offset + size))
        // **Do not shrink the entry.** Writing the new length back would throw away the packet's
        // padding, so the very next edit that grows the document by one byte would need a fresh
        // append (~18 KB) instead of using the room it already had. Keeping the count is what makes
        // the slack do its job; the packet's own `<?xpacket end="w"?>` still marks where it ends.
    }

    private func payloadOffset(_ e: Entry) -> Int {
        if littleEndian {
            return Int(UInt32(e.raw[0]) | UInt32(e.raw[1]) << 8 | UInt32(e.raw[2]) << 16 | UInt32(e.raw[3]) << 24)
        }
        return Int(UInt32(e.raw[0]) << 24 | UInt32(e.raw[1]) << 16 | UInt32(e.raw[2]) << 8 | UInt32(e.raw[3]))
    }

    /// Slack appended to every new packet. XMP is padded this way on purpose (Adobe's own packets end
    /// with a run of spaces): a slot with room absorbs the next handful of edits without touching the
    /// file again, which is what keeps twenty drags from adding twenty kilobytes.
    static let packetSlack = 1024

    /// Appends the packet, then a copy of IFD0 whose tag 700 points at it, then retargets the header.
    mutating func appendPacketAndRewriteIFD(_ rawPacket: Data) throws {
        var packet = rawPacket
        packet.append(contentsOf: [UInt8](repeating: 0x20, count: TIFFFile.packetSlack))
        guard packet.count <= Int(UInt32.max) else { throw DNGXMP.Failure.packetTooLarge(packet.count) }
        if data.count % 2 != 0 { data.append(0) }
        let packetOffset = data.count
        data.append(packet)
        if data.count % 2 != 0 { data.append(0) }
        let newIFD = UInt32(data.count)

        var entries = allEntries()
        let replacement = Entry(tag: 700, type: 7 /* UNDEFINED */, count: UInt32(packet.count),
                                raw: u32Bytes(UInt32(packetOffset)))
        if let index = entries.firstIndex(where: { $0.tag == 700 }) {
            entries[index] = replacement
        } else {
            entries.append(replacement)
        }
        entries.sort { $0.tag < $1.tag }

        var ifd = [UInt8]()
        ifd.reserveCapacity(2 + 12 * entries.count + 4)
        if littleEndian { ifd += [UInt8(entries.count & 0xff), UInt8((entries.count >> 8) & 0xff)] }
        else { ifd += [UInt8((entries.count >> 8) & 0xff), UInt8(entries.count & 0xff)] }
        for e in entries {
            ifd += littleEndian ? [UInt8(e.tag & 0xff), UInt8(e.tag >> 8)] : [UInt8(e.tag >> 8), UInt8(e.tag & 0xff)]
            ifd += littleEndian ? [UInt8(e.type & 0xff), UInt8(e.type >> 8)] : [UInt8(e.type >> 8), UInt8(e.type & 0xff)]
            ifd += u32Bytes(e.count)
            ifd += e.raw
        }
        ifd += u32Bytes(`next`())
        data.append(contentsOf: ifd)

        putU32(newIFD, at: 4)
        ifd0 = newIFD
    }

    mutating func restoreHeader(_ header: Data) {
        guard header.count == 8 else { return }
        for k in 0..<8 { data[data.startIndex + k] = header[header.startIndex + k] }
        markDirty(0..<8)
        ifd0 = u32(4)
    }

    /// Two write strategies, chosen by whether the bytes grew:
    ///
    /// - **Same length** (slot reuse, thumbnail replacement, undo): write only the changed ranges
    ///   straight into the existing file. The inode does not move, so birth time, Date Added, extended
    ///   attributes and ACL are untouched — and a 68 MB DNG gets a few KB of writes, not a full copy.
    /// - **Grew** (packet/thumbnail appended): keep `.atomic`. The inode necessarily changes; birth
    ///   time, permissions, extended attributes and ACL are then restored. Date Added cannot be.
    func persist(to url: URL) throws {
        // A read-only original must fail with one sentence and leave zero bytes changed. `.atomic`
        // would happily replace a writable-directory file even when the file itself is read-only, so
        // the check has to be here, before any work.
        guard FileManager.default.isWritableFile(atPath: url.path) else {
            throw DNGXMP.Failure.writeFailed("\(url.lastPathComponent) 是只读文件，未写入")
        }

        let onDiskSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int
        if let onDiskSize, onDiskSize == data.count {
            try writeInPlace(to: url)
            return
        }

        let metadata = DNGFileMetadata.capture(at: url)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw DNGXMP.Failure.writeFailed("\(url.lastPathComponent): \(error.localizedDescription)")
        }

        let failures = metadata.restore(to: url)
        if !failures.isEmpty {
            // One warning, not one per attribute, and never a thrown error: the image and the XMP are
            // already written; a metadata restore is best effort.
            NSLog("photons: 保存已成功，但元数据未能全部还原（\(url.lastPathComponent)）：\(failures.joined(separator: "、"))")
        }
    }

    private func writeInPlace(to url: URL) throws {
        let ranges = Self.coalesced(dirtyRanges, within: 0..<data.count)
        guard !ranges.isEmpty else { return }
        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            for range in ranges {
                let lower = data.startIndex + range.lowerBound
                let upper = data.startIndex + range.upperBound
                try handle.seek(toOffset: UInt64(range.lowerBound))
                try handle.write(contentsOf: Data(data[lower..<upper]))
            }
            try handle.synchronize()
        } catch {
            throw DNGXMP.Failure.writeFailed("\(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Sorts and merges overlapping/adjacent ranges so a save is a handful of writes.
    static func coalesced(_ ranges: [Range<Int>], within bounds: Range<Int>) -> [Range<Int>] {
        let clipped = ranges
            .map { max($0.lowerBound, bounds.lowerBound)..<min($0.upperBound, bounds.upperBound) }
            .filter { !$0.isEmpty }
            .sorted { $0.lowerBound < $1.lowerBound }
        var out: [Range<Int>] = []
        for range in clipped {
            if let last = out.last, range.lowerBound <= last.upperBound {
                out[out.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                out.append(range)
            }
        }
        return out
    }
}
