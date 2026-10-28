import Foundation

/// One plane of a DNG `WarpRectilinear` opcode (DNG 1.4, §OpcodeList3).
///
/// The radial map is
///
///     r' = r · (kr0 + kr1·r + kr2·r² + kr3·r³)
///
/// with the tangential terms `kt0`/`kt1` (not applied today — every file measured on this machine
/// has both at zero; see `s0_geometry.metal`).
public struct LensWarpPlane: Equatable, Sendable {
    public let kr0: Double
    public let kr1: Double
    public let kr2: Double
    public let kr3: Double
    public let kt0: Double
    public let kt1: Double

    public init(kr0: Double, kr1: Double, kr2: Double, kr3: Double,
                kt0: Double = 0, kt1: Double = 0) {
        self.kr0 = kr0
        self.kr1 = kr1
        self.kr2 = kr2
        self.kr3 = kr3
        self.kt0 = kt0
        self.kt1 = kt1
    }

    public static let identity = LensWarpPlane(kr0: 1, kr1: 0, kr2: 0, kr3: 0)

    public func isWithin(_ other: LensWarpPlane, tolerance: Double = 1e-9) -> Bool {
        abs(kr0 - other.kr0) <= tolerance
            && abs(kr1 - other.kr1) <= tolerance
            && abs(kr2 - other.kr2) <= tolerance
            && abs(kr3 - other.kr3) <= tolerance
            && abs(kt0 - other.kt0) <= tolerance
            && abs(kt1 - other.kt1) <= tolerance
    }
}

/// The `WarpRectilinear` payload of a DNG's `OpcodeList3`: one plane (Apple's case, one warp shared
/// by R/G/B) or three (a per-channel warp, which is what the Leica SL3 writes).
///
/// This is a **decode-time file fact**, not an edit parameter: it is read once from the file, and
/// `RAWDecoder` turns Apple's own lens correction off exactly when the file carries more than one
/// distinct plane — Apple only ever applies plane 1 (green) to all three channels, so leaving it on
/// would make our per-plane warp double-correct green and still leave red/blue mis-registered.
public struct LensProfile: Equatable, Sendable {
    public let planes: [LensWarpPlane]
    public let centerX: Double
    public let centerY: Double

    public init(planes: [LensWarpPlane], centerX: Double = 0.5, centerY: Double = 0.5) {
        self.planes = planes
        self.centerX = centerX
        self.centerY = centerY
    }

    /// 「RGB 不一样」 — the file carries lateral-chromatic-aberration data, so the three channels need
    /// three different radial warps. Compared coefficient by coefficient with a 1e-9 tolerance so a
    /// float round trip in a writer cannot be mistaken for a different plane.
    public var hasPerPlaneDifference: Bool {
        guard planes.count > 1, let first = planes.first else { return false }
        for plane in planes.dropFirst() where !plane.isWithin(first) {
            return true
        }
        return false
    }

    /// The one spelling of this profile's contribution to a decode / render key.
    ///
    /// `lens=apple` when Apple's single-warp correction is the one that ran; `lens=ours:…` when the
    /// three planes differ and `s0_geometry_lens` applies them per channel. The compact text uses
    /// each plane's `kr0` (the coefficient that decides the scale), because that is the part a stale
    /// cache would get visibly wrong.
    public var recipeComponent: String {
        guard hasPerPlaneDifference else { return "lens=apple" }
        let ks = planes.map { String(format: "%.9f", $0.kr0) }.joined(separator: ",")
        return "lens=ours:\(ks)"
    }

    /// Read the first supported `WarpRectilinear` opcode from a DNG.
    ///
    /// Everything hard-coded here is a measured fact about the files on this machine:
    ///
    ///   · `OpcodeList3` is tag **51022** (`0xC74E`) in the files that carry it. The DNG tag that is
    ///     often quoted for it, 51010, is accepted too — some writers do use it — but the SL3 files
    ///     put the opcode under 51022, and reading only 51010 finds nothing.
    ///   · `OpcodeList1`/`OpcodeList2` are 51008/51009; they are **not** read (their `MapPolynomial`
    ///     entries are unrelated).
    ///   · The opcode payload is **big-endian even when the TIFF header is `II`** (little-endian).
    ///     All integers and doubles below are read big-endian unconditionally.
    ///   · Both IFD0 and SubIFDs are walked (the SL3 writes the list in a SubIFD), following tag 330
    ///     and the Exif IFD pointer 34665.
    ///
    /// Anything unreadable, an unknown opcode, a plane count other than 1/3, or a truncated payload
    /// returns `nil`. A parser that guesses is worse than the Apple default it leaves in place.
    public static func read(from url: URL) -> LensProfile? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count >= 8 else {
            return nil
        }
        return parse(data)
    }

    /// The pure-data form, so the parser can be tested without a file on disk.
    static func parse(_ data: Data) -> LensProfile? {
        guard data.count >= 8 else { return nil }
        let little: Bool
        switch (data[0], data[1]) {
        case (0x49, 0x49): little = true      // "II"
        case (0x4D, 0x4D): little = false     // "MM"
        default: return nil
        }
        func u16(_ o: Int) -> UInt16? {
            guard o >= 0, o + 2 <= data.count else { return nil }
            let a = UInt16(data[o]), b = UInt16(data[o + 1])
            return little ? (a | b << 8) : (a << 8 | b)
        }
        func u32(_ o: Int) -> UInt32? {
            guard o >= 0, o + 4 <= data.count else { return nil }
            let v = (UInt32(data[o]) << 24) | (UInt32(data[o + 1]) << 16)
                | (UInt32(data[o + 2]) << 8) | UInt32(data[o + 3])
            return little ? v.byteSwapped : v
        }
        guard let magic = u16(2), magic == 42, let ifd0 = u32(4) else { return nil }

        // Walk IFD0, its SubIFDs and its Exif IFD. Depth/visited guards keep a malformed file from
        // looping or recursing forever; the lists we want are at most three levels down.
        var pending: [(offset: UInt32, depth: Int)] = [(ifd0, 0)]
        var visited = Set<UInt32>()
        var payloads: [(offset: UInt32, length: UInt32)] = []
        while let node = pending.popLast() {
            guard node.depth <= 6, visited.insert(node.offset).inserted else { continue }
            let base = Int(node.offset)
            guard let count = u16(base), count <= 4096 else { continue }
            for i in 0..<Int(count) {
                let entry = base + 2 + i * 12
                guard let tag = u16(entry), let type = u16(entry + 2),
                      let n = u32(entry + 4), let value = u32(entry + 8) else { break }
                switch tag {
                case 330, 34665:      // SubIFDs, ExifIFD
                    // These are LONG/IFD arrays; a count of 1 still stores the offset in `value`.
                    let offsets = (type == 3 || type == 4 || type == 13)
                        ? (0..<Int(min(n, 64))).compactMap { u32(Int(value) + $0 * 4) }
                        : []
                    for o in offsets { pending.append((o, node.depth + 1)) }
                case 51022, 51010:    // OpcodeList3 (both spellings seen in the wild)
                    guard let size = u32(entry + 8) else { break }
                    // `value` is the byte offset whenever count > 4; these lists always are.
                    if n > 4 { payloads.append((value, n)) } else { _ = size }
                default:
                    break
                }
            }
        }
        for (offset, length) in payloads {
            if let profile = parseOpcodeList(data, offset: Int(offset), length: Int(length)) {
                return profile
            }
        }
        return nil
    }

    private static func parseOpcodeList(_ data: Data, offset: Int, length: Int) -> LensProfile? {
        guard offset >= 0, length >= 0, offset <= data.count, offset + length <= data.count else {
            return nil
        }
        func be32(_ o: Int) -> UInt32? {
            guard o >= 0, o + 4 <= data.count else { return nil }
            return (UInt32(data[o]) << 24) | (UInt32(data[o + 1]) << 16)
                | (UInt32(data[o + 2]) << 8) | UInt32(data[o + 3])
        }
        func be64(_ o: Int) -> UInt64? {
            guard o >= 0, o + 8 <= data.count else { return nil }
            var v: UInt64 = 0
            for i in 0..<8 { v = (v << 8) | UInt64(data[o + i]) }
            return v
        }
        func beDouble(_ o: Int) -> Double? {
            be64(o).map { Double(bitPattern: $0) }
        }

        let end = offset + length
        guard let opcodeCount = be32(offset), opcodeCount > 0, opcodeCount <= 64 else { return nil }
        var p = offset + 4
        for _ in 0..<Int(opcodeCount) {
            guard p + 16 <= end, let id = be32(p), let paramBytes = be32(p + 12) else { return nil }
            let payload = p + 16
            guard payload + Int(paramBytes) <= end else { return nil }
            if id == 1 {   // WarpRectilinear
                return parseWarpRectilinear(data, payload: payload, paramBytes: Int(paramBytes),
                                            be32: be32, beDouble: beDouble)
            }
            p = payload + Int(paramBytes)
        }
        return nil
    }

    private static func parseWarpRectilinear(_ data: Data, payload: Int, paramBytes: Int,
                                             be32: (Int) -> UInt32?,
                                             beDouble: (Int) -> Double?) -> LensProfile? {
        guard paramBytes >= 4, let planes = be32(payload), planes == 1 || planes == 3 else {
            return nil
        }
        let needed = 4 + Int(planes) * 6 * 8 + 2 * 8
        guard paramBytes >= needed else { return nil }
        var q = payload + 4
        var warps: [LensWarpPlane] = []
        for _ in 0..<Int(planes) {
            guard let kr0 = beDouble(q), let kr1 = beDouble(q + 8),
                  let kr2 = beDouble(q + 16), let kr3 = beDouble(q + 24),
                  let kt0 = beDouble(q + 32), let kt1 = beDouble(q + 40) else { return nil }
            warps.append(LensWarpPlane(kr0: kr0, kr1: kr1, kr2: kr2, kr3: kr3,
                                       kt0: kt0, kt1: kt1))
            q += 48
        }
        guard let cx = beDouble(q), let cy = beDouble(q + 8) else { return nil }
        return LensProfile(planes: warps, centerX: cx, centerY: cy)
    }
}
