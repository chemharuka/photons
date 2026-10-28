import Foundation

/// One plane of a DNG `WarpRectilinear` opcode (DNG 1.6, §"WarpRectilinear").
///
/// The radial map is (spec verbatim, **even powers**):
///
///     f(r) = kr0 + kr1·r² + kr2·r⁴ + kr3·r⁶        r' = f(r)·r
///
/// with `r` normalised so the farthest pixel is 1. The tangential terms `kt0`/`kt1` are not applied
/// today — every file measured on this machine has both at zero; see `s0_geometry.metal`.
///
/// **The exponents are the trap.** Writing the same map as `kr0 + r·(kr1 + r·(kr2 + r·kr3))`
/// (odd powers) agrees with the spec whenever `kr1…kr3` are zero — so a `kr0`-only test cannot see
/// it — while on a real SL3 file (`kr1 ≈ −0.0076`) it shifts the whole picture by ~0.4 % of the
/// radius. Measured against Apple's own warp: odd powers left corr 0.930 / Δs −0.400 %, even powers
/// 0.99958 / Δs −0.000 %. `radialScale(at:)` is the single CPU statement of the spec formula; the
/// Metal copy is pinned to it by `CAWarpTests`.
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

    /// `f(r) = kr0 + kr1·r² + kr2·r⁴ + kr3·r⁶` — the spec's radial factor (see the type doc).
    ///
    /// Exists so the formula has **one** CPU statement: `s0_geometry.metal` repeats it for the GPU, and
    /// `CAWarpTests` asserts the Metal source contains exactly this shape (even powers). Without that
    /// pin an odd-power rewrite passes every `kr0`-only fixture and is wrong on every real file.
    public func radialScale(at r: Double) -> Double {
        let r2 = r * r
        return kr0 + r2 * (kr1 + r2 * (kr2 + r2 * kr3))
    }

    public func isWithin(_ other: LensWarpPlane, tolerance: Double = 1e-9) -> Bool {
        abs(kr0 - other.kr0) <= tolerance
            && abs(kr1 - other.kr1) <= tolerance
            && abs(kr2 - other.kr2) <= tolerance
            && abs(kr3 - other.kr3) <= tolerance
            && abs(kt0 - other.kt0) <= tolerance
            && abs(kt1 - other.kt1) <= tolerance
    }
}

/// Where a `LensProfile` came from. The two sources describe the same kind of radiance mapping, but
/// they are read from different places and (for the RW2 case) need a CPU inverse-fit first.
public enum LensProfileSource: String, Equatable, Sendable {
    /// A DNG `OpcodeList3 / WarpRectilinear` payload (097).
    case dngOpcode3
    /// The 16×int16 block under tag `0x0119` in a Panasonic RW2's IFD0.
    case panasonicRW2
}

/// The Panasonic RW2 distortion block, decoded from IFD0 tag `0x0119`.
///
/// The file stores the **forward** radial map (destination radius from source radius):
///
///     f(r) = (1/z) · (r + a·r³ + b·r⁵ + c·r⁷)          r normalised by the half-diagonal
///
/// with `z = 1 + w5/32768`, `a = w8/32768`, `b = w4/32768`, `c = w11/32768`. The archived notes call
/// `1/z` the "scale" (`scale = 1/z`); this type keeps `z` so the formula has one spelling.
///
/// S0 wants the **inverse** (dest → source) as the same 4-term radial *scale* DNG uses:
/// `source = center + d · (kr0 + kr1·r² + kr2·r⁴ + kr3·r⁶)`. `inverse` is that least-squares fit over
/// `r ∈ [0, 1.05]`; `maxResidual` is its worst radius error against a Newton root. A non-monotonic
/// forward map is rejected at construction (see `readPanasonic`), because no inverse exists.
public struct PanasonicWarp: Equatable, Sendable {
    /// `1 + w5/32768`; the forward map is divided by this.
    public let z: Double
    public let a: Double
    public let b: Double
    public let c: Double
    /// `w12` — the active-area half-diagonal in pixels. It is **not** a constant 2500 (that archived
    /// claim is wrong for every sample measured here); it is recorded for diagnostics.
    public let halfDiagonal: Double
    /// `w7 & 0xf`; only `1` means the camera wrote a usable correction.
    public let flag: Int
    /// The fitted dest→source 4-term scale, shared by R/G/B (Panasonic has no per-channel data here).
    public let inverse: LensWarpPlane
    /// Worst radius error of `inverse` against the Newton root over `r ∈ [0, 1.05]`.
    public let maxResidual: Double

    public var scale: Double { 1 / z }

    /// The forward map: destination radius for a source radius.
    public func forwardRadius(at r: Double) -> Double {
        let r2 = r * r
        return (r + r * r2 * (a + r2 * (b + r2 * c))) / z
    }

    /// `f'(r)`, used by the monotonicity gate and by Newton inversion.
    public func derivative(at r: Double) -> Double {
        let r2 = r * r
        return (1 + r2 * (3 * a + r2 * (5 * b + r2 * 7 * c))) / z
    }

    /// Does the forward map have an inverse on the measured domain?
    public func isStrictlyMonotonic(upTo upper: Double = 1.05, samples: Int = 256) -> Bool {
        guard upper > 0, samples > 0 else { return false }
        for i in 0...samples where derivative(at: upper * Double(i) / Double(samples)) <= 0 {
            return false
        }
        return true
    }

    /// True dest→source radius, by Newton iteration on the monotonic forward map.
    public func inverseRadius(at target: Double) -> Double {
        guard target > 0 else { return 0 }
        var r = target
        for _ in 0..<60 {
            let step = (forwardRadius(at: r) - target) / derivative(at: r)
            r -= step
            if abs(step) < 1e-15 { break }
            if r < 0 { r = 0 }
        }
        return r
    }

    /// Build the warp and fit its inverse. Returns `nil` when the forward map is not strictly
    /// monotonic (no inverse) or the 4-term fit misses the 1e-3 radius budget — a file we cannot
    /// correct honestly is better left to Apple than corrected with a made-up polynomial.
    public init?(z: Double, a: Double, b: Double, c: Double,
                 halfDiagonal: Double, flag: Int) {
        guard flag & 0xf == 1, z > 0, halfDiagonal > 0 else { return nil }
        let probe = PanasonicWarp(unchecked: z, a: a, b: b, c: c,
                                  halfDiagonal: halfDiagonal, flag: flag)
        // Strict monotonicity on the measured domain is the existence condition for the inverse.
        // The archived vendor notes used `scale` directly; a non-monotonic polynomial (which some
        // bad/edited files carry) would make S0 fold the picture back on itself, so reject it.
        guard probe.isStrictlyMonotonic() else { return nil }
        guard let fit = Self.fitInverse(probe) else { return nil }
        self = PanasonicWarp(unchecked: z, a: a, b: b, c: c,
                             halfDiagonal: halfDiagonal, flag: flag,
                             inverse: fit.plane, maxResidual: fit.maxResidual)
    }

    private init(unchecked z: Double, a: Double, b: Double, c: Double,
                 halfDiagonal: Double, flag: Int,
                 inverse: LensWarpPlane = .identity, maxResidual: Double = 0) {
        self.z = z
        self.a = a
        self.b = b
        self.c = c
        self.halfDiagonal = halfDiagonal
        self.flag = flag
        self.inverse = inverse
        self.maxResidual = maxResidual
    }

    /// Least-squares `kr0 + kr1·r² + kr2·r⁴ + kr3·r⁶` for `inverseRadius(r)/r`, sampled at 256
    /// points over `[0, 1.05]`. The basis and the 4-term shape are 097's; only the data source is new.
    private static func fitInverse(_ warp: PanasonicWarp)
        -> (plane: LensWarpPlane, maxResidual: Double)? {
        let upper = 1.05
        let count = 256
        var rhs = [Double](repeating: 0, count: 4)
        var normal = [[Double]](repeating: [Double](repeating: 0, count: 4), count: 4)
        for i in 0..<count {
            let rho = upper * (Double(i) + 0.5) / Double(count)
            let y = warp.inverseRadius(at: rho) / rho
            // Fit in x = rho/1.05 so the normal equations see [0,1] rather than [0,1.05].
            let x2 = (rho / upper) * (rho / upper)
            let basis = [1.0, x2, x2 * x2, x2 * x2 * x2]
            for j in 0..<4 {
                rhs[j] += basis[j] * y
                for k in 0..<4 { normal[j][k] += basis[j] * basis[k] }
            }
        }
        guard let scaled = solve(normal, rhs) else { return nil }
        // Convert x-power coefficients back to rho powers.
        let divisor = (0..<4).map { pow(upper, Double(2 * $0)) }
        let k = (0..<4).map { scaled[$0] / divisor[$0] }
        let plane = LensWarpPlane(kr0: k[0], kr1: k[1], kr2: k[2], kr3: k[3])

        // Residual is measured where it matters: a radius error, not a scale error.
        var worst = 0.0
        for i in 0...256 {
            let rho = upper * Double(i) / 256
            let truth = rho == 0 ? 0 : warp.inverseRadius(at: rho)
            let fitted = rho * plane.radialScale(at: rho)
            worst = max(worst, abs(fitted - truth))
        }
        guard worst <= 1e-3 else { return nil }
        return (plane, worst)
    }

    /// Gaussian elimination with partial pivoting for the 4×4 normal equations.
    private static func solve(_ a: [[Double]], _ b: [Double]) -> [Double]? {
        var m = (0..<4).map { [a[$0][0], a[$0][1], a[$0][2], a[$0][3], b[$0]] }
        for col in 0..<4 {
            let pivot = (col..<4).max { abs(m[$0][col]) < abs(m[$1][col]) }!
            m.swapAt(col, pivot)
            let d = m[col][col]
            guard abs(d) > 1e-15 else { return nil }
            for j in col..<5 { m[col][j] /= d }
            for row in 0..<4 where row != col {
                let f = m[row][col]
                for j in col..<5 { m[row][j] -= f * m[col][j] }
            }
        }
        return (0..<4).map { m[$0][4] }
    }
}

/// The lens correction facts carried by a raw file: one plane (Apple's case, one warp shared by
/// R/G/B), three (a per-channel warp, which is what the Leica SL3 writes), or one fitted Panasonic
/// warp shared by all channels.
///
/// This is a **decode-time file fact**, not an edit parameter: it is read once from the file, and
/// `RAWDecoder` turns Apple's own lens correction off exactly when we have a usable profile of our
/// own — Apple only ever applies plane 1 (green) to all three channels, so leaving it on for a
/// per-plane DNG would make our warp double-correct green and still leave red/blue mis-registered.
public struct LensProfile: Equatable, Sendable {
    public let planes: [LensWarpPlane]
    public let centerX: Double
    public let centerY: Double
    public let source: LensProfileSource
    /// The raw Panasonic coefficients (and their fitted inverse) when `source == .panasonicRW2`.
    public let panasonic: PanasonicWarp?

    public init(planes: [LensWarpPlane], centerX: Double = 0.5, centerY: Double = 0.5,
                source: LensProfileSource = .dngOpcode3, panasonic: PanasonicWarp? = nil) {
        self.planes = planes
        self.centerX = centerX
        self.centerY = centerY
        self.source = source
        self.panasonic = panasonic
    }

    /// Either kind of profile needs S0 to do the warp itself (Apple's correction is off in the
    /// decoder). DNG needs it only when the planes differ; RW2 always does, because its one warp
    /// is the only data the file carries.
    public var requiresOwnWarp: Bool {
        switch source {
        case .dngOpcode3: return hasPerPlaneDifference
        case .panasonicRW2: return panasonic != nil
        }
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
    /// three planes differ and `s0_geometry_lens` applies them per channel; `lens=panasonic:z,a,b,c`
    /// for an RW2 file, where the raw coefficients are the file fact. The compact DNG text uses each
    /// plane's `kr0` (the coefficient that decides the scale), because that is the part a stale cache
    /// would get visibly wrong.
    public var recipeComponent: String {
        if let panasonic {
            return String(format: "lens=panasonic:%.9f,%.9f,%.9f,%.9f",
                          panasonic.z, panasonic.a, panasonic.b, panasonic.c)
        }
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

    /// Read a Panasonic RW2's lens-distortion block (IFD0 tag `0x0119`, `UNDEFINED[32]`, 16×int16 LE).
    ///
    /// Measured facts, not guesses:
    ///
    ///   · The tag sits in **IFD0** (not MakerNote) and is one 16-word block — there is no per-focal-
    ///     length row table to choose from or interpolate.
    ///   · `w12` is the active-area **half-diagonal in pixels** (≈ the full-frame half-diagonal minus
    ///     5–6 px on all three measured samples), so `r` is normalised exactly like DNG's: corner ρ = 1.
    ///   · `w7 & 0xf` is the switch; `0` (and anything but `1`) means "do not correct".
    ///   · `z = 1 + w5/32768`, `a = w8/32768`, `b = w4/32768`, `c = w11/32768`.
    ///
    /// The archived claim that `w12` is always 2500 is false — the three samples give 7211/3606/4892.
    /// The forward map is inverted and fitted to 097's 4-term scale in `PanasonicWarp`; a
    /// non-monotonic map or a fit worse than 1e-3 returns `nil`, so Apple's default stays in place.
    public static func readPanasonic(from url: URL) -> LensProfile? {
        // RW2 only: this tag is not part of DNG, and reading a same-numbered tag out of some other
        // TIFF would be exactly the kind of guess the DNG parser refuses to make.
        guard url.pathExtension.lowercased() == "rw2",
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return nil
        }
        return parsePanasonic(data)
    }

    /// The pure-data form of `readPanasonic`, so the flag/monotonic gates can be tested without a
    /// 57 MB sample on disk.
    static func parsePanasonic(_ data: Data) -> LensProfile? {
        // Panasonic writes little-endian TIFF. Requiring `II` keeps the 16-bit payload interpretation
        // unambiguous (the block itself is not tagged with an endianness of its own).
        guard data.count >= 8, data[0] == 0x49, data[1] == 0x49 else { return nil }
        func u16(_ o: Int) -> UInt16? {
            guard o >= 0, o + 2 <= data.count else { return nil }
            return UInt16(data[o]) | UInt16(data[o + 1]) << 8
        }
        func u32(_ o: Int) -> UInt32? {
            guard o >= 0, o + 4 <= data.count else { return nil }
            return UInt32(data[o]) | UInt32(data[o + 1]) << 8
                | UInt32(data[o + 2]) << 16 | UInt32(data[o + 3]) << 24
        }
        // RW2's TIFF magic is 0x55 ("Panasonic RAW"), not the usual 42; the IFD layout is the same.
        guard let magic = u16(2), magic == 42 || magic == 85,
              let ifd0 = u32(4), ifd0 > 0 else { return nil }
        let base = Int(ifd0)
        guard let count = u16(base), count <= 4096 else { return nil }
        for i in 0..<Int(count) {
            let entry = base + 2 + i * 12
            guard let tag = u16(entry), let type = u16(entry + 2),
                  let n = u32(entry + 4), let value = u32(entry + 8) else { break }
            guard tag == 0x0119 else { continue }
            // UNDEFINED (7) and BYTE (1) are both one byte per element; the block is 32 bytes.
            guard (type == 7 || type == 1), n >= 32 else { return nil }
            let offset = n > 4 ? Int(value) : entry + 8
            guard offset >= 0, offset + 32 <= data.count else { return nil }
            var w = [Int16](repeating: 0, count: 16)
            for j in 0..<16 {
                let o = offset + j * 2
                w[j] = Int16(bitPattern: UInt16(data[o]) | UInt16(data[o + 1]) << 8)
            }
            let flag = Int(w[7] & 0xf)
            guard flag == 1 else { return nil }
            let z = 1 + Double(w[5]) / 32768
            let a = Double(w[8]) / 32768
            let b = Double(w[4]) / 32768
            let c = Double(w[11]) / 32768
            let halfDiagonal = Double(w[12])
            guard let warp = PanasonicWarp(z: z, a: a, b: b, c: c,
                                           halfDiagonal: halfDiagonal, flag: flag) else {
                return nil
            }
            // Panasonic carries no per-channel distortion data (the 0x011b CA block is unread), so
            // the same fitted plane feeds all three channels.
            return LensProfile(planes: [warp.inverse, warp.inverse, warp.inverse],
                               source: .panasonicRW2, panasonic: warp)
        }
        return nil
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
