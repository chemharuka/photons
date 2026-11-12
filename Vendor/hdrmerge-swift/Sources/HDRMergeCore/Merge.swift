//
//  Merge.swift
//  hdrmerge-swift
//
//  Align (Ward median-threshold bitmaps), select, feather and compose a set of
//  CFA raw exposures into one radiance-linear mosaic.  Algorithmic port of
//  Image.cpp / ImageStack.cpp from HDRMerge (© 2012 Javier Celaya, GPLv3).
//
//  Deliberate simplifications, documented in PORTING.md:
//    * exposure ratio is estimated by least squares on the overlap (HDRMerge's
//      own fallback path). For linear sensor data this is the exact answer;
//      the spline response fit only matters for non-linear (tone-mapped) raw.
//    * the mask fattening filter is a square structuring element, not a disk.
//

import Foundation

public struct MergeOptions {
    public var featherRadius: Int
    public var customWhiteLevel: Int?
    /// Reserve `headroom × input white level` as the top of the output container.
    /// 1 = upstream behaviour (peak is normalised to white). 4 packs the input's
    /// scale unchanged into a 16-bit container (65535/4 = 16383) and uses the
    /// spare top two stops for recovered highlights.
    public var headroom: Double

    public init(featherRadius: Int = 3, customWhiteLevel: Int? = nil, headroom: Double = 1) {
        self.featherRadius = featherRadius
        self.customWhiteLevel = customWhiteLevel
        self.headroom = headroom
    }
}

public enum MergeError: Error, CustomStringConvertible {
    case noFrames
    case geometryMismatch(String)
    case nothingToMerge

    public var description: String {
        switch self {
        case .noFrames: return "no input frames"
        case .geometryMismatch(let s): return "frames are not mergeable: \(s)"
        case .nothingToMerge: return "no overlapping area between frames"
        }
    }
}

public struct MergedImage {
    public var width: Int
    public var height: Int
    /// Mosaic samples in DNG code units (black already added back).
    public var values: [Float]
    public var black: Double
    public var white: Int
    public var cfaPattern: [UInt8]
    public var cfaRows: Int
    public var cfaCols: Int
    /// `CFAPlaneColor` to write out: carried from the source so a 4-plane sensor keeps its fourth
    /// plane instead of being flattened to RGB.
    public var cfaPlaneColor: [UInt8]
    /// Placement of each input frame inside the merged canvas, in input order.
    public var offsets: [(x: Int, y: Int)]
    /// 1-based index into `offsets` of the frame used as reference (brightest).
    public var referenceIndex: Int
    public var report: [String]

    public init(width: Int, height: Int, values: [Float], black: Double, white: Int,
                cfaPattern: [UInt8], cfaRows: Int, cfaCols: Int,
                cfaPlaneColor: [UInt8] = [0, 1, 2],
                offsets: [(x: Int, y: Int)], referenceIndex: Int, report: [String]) {
        self.width = width; self.height = height; self.values = values
        self.black = black; self.white = white
        self.cfaPattern = cfaPattern; self.cfaRows = cfaRows; self.cfaCols = cfaCols
        self.cfaPlaneColor = cfaPlaneColor
        self.offsets = offsets; self.referenceIndex = referenceIndex; self.report = report
    }
}

/// One black-subtracted frame in active-area coordinates.
struct Plane {
    var width: Int
    var height: Int
    var pixels: [UInt16]
    var dx: Int = 0
    var dy: Int = 0
    /// CFA phase of *this* frame, in photo coordinates. Frames are sorted by brightness, so the
    /// colour lookup can no longer assume it matches the first input's phase.
    var cfaPattern: [UInt8] = [0, 1, 1, 2]
    var cfaRows: Int = 2
    var cfaCols: Int = 2
    /// Number of distinct planes in `CFAPlaneColor` (3 for Bayer RGGB, 4 for RGBW / dual-green
    /// sensors that name G and G2 separately).
    var colorCount: Int = 3

    /// Colour index at photo coordinates — same indexing as `RawFrame.colorAt`.
    @inline(__always) func colorAt(_ x: Int, _ y: Int) -> Int {
        Int(cfaPattern[(y % cfaRows) * cfaCols + (x % cfaCols)])
    }

    @inline(__always) func contains(_ x: Int, _ y: Int) -> Bool {
        x >= dx && x < dx + width && y >= dy && y < dy + height
    }
    @inline(__always) func at(_ x: Int, _ y: Int) -> UInt16 {
        pixels[(y - dy) * width + (x - dx)]
    }
    struct Scale {
        var pixels: [UInt16]
        var width: Int
        var height: Int
    }
    func prescaled(levels: Int) -> [Scale] {
        var out: [Scale] = []
        var cur = Scale(pixels: pixels, width: width, height: height)
        for _ in 0..<levels {
            let w = cur.width >> 1, h = cur.height >> 1
            if w < 2 || h < 2 { break }
            var dst = [UInt16](repeating: 0, count: w * h)
            for y in 0..<h {
                let r0 = (2 * y) * cur.width, r1 = (2 * y + 1) * cur.width
                for x in 0..<w {
                    let c = 2 * x
                    let a = UInt32(cur.pixels[r0 + c]), b = UInt32(cur.pixels[r0 + c + 1])
                    let d = UInt32(cur.pixels[r1 + c]), e2 = UInt32(cur.pixels[r1 + c + 1])
                    dst[y * w + x] = UInt16((a + b + d + e2) >> 2)
                }
            }
            cur = Scale(pixels: dst, width: w, height: h)
            out.append(cur)
        }
        return out
    }
}

// MARK: - Bitmaps

struct Bitmap {
    var bits: [UInt8]
    var width: Int
    var height: Int

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        bits = [UInt8](repeating: 0, count: width * height)
    }

    init(pixels: [UInt16], width: Int, height: Int, threshold: UInt16, exclusive: Bool) {
        self.width = width
        self.height = height
        bits = [UInt8](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            bits[i] = pixels[i] > threshold ? 1 : 0
        }
    }

    static func exclusion(pixels: [UInt16], width: Int, height: Int,
                          threshold: UInt16, tolerance: UInt16) -> Bitmap {
        var b = Bitmap(width: width, height: height)
        let lo = threshold &- tolerance
        let hi = threshold &+ tolerance
        for i in 0..<(width * height) {
            let v = pixels[i]
            b.bits[i] = (v <= lo || v > hi) ? 1 : 0
        }
        return b
    }

    func shifted(_ sx: Int, _ sy: Int) -> Bitmap {
        var out = Bitmap(width: width, height: height)
        for y in 0..<height {
            let sy2 = y - sy
            if sy2 < 0 || sy2 >= height { continue }
            for x in 0..<width {
                let sx2 = x - sx
                if sx2 < 0 || sx2 >= width { continue }
                out.bits[y * width + x] = bits[sy2 * width + sx2]
            }
        }
        return out
    }

    func xorCount(_ other: Bitmap, with a: Bitmap, and b: Bitmap) -> (mismatch: Int, valid: Int) {
        var c = 0
        var v = 0
        let n = bits.count
        for i in 0..<n where a.bits[i] != 0 && b.bits[i] != 0 {
            v += 1
            if bits[i] != other.bits[i] { c += 1 }
        }
        return (c, v)
    }
}

// MARK: - Histogram helpers

struct Histogram {
    var bins: [Int]
    var count: Int

    init(_ pixels: [UInt16]) {
        bins = [Int](repeating: 0, count: 65536)
        count = pixels.count
        for v in pixels { bins[Int(v)] += 1 }
    }

    func percentile(_ frac: Double) -> UInt16 {
        guard count > 0 else { return 0 }
        let limit = Int((Double(count) * frac).rounded(.down))
        var acc = bins[0]
        var v = 0
        while acc < limit && v < 65535 {
            v += 1
            acc += bins[v]
        }
        return UInt16(v)
    }

    func fraction(_ value: UInt16) -> Double {
        guard count > 0 else { return 0 }
        var acc = 0
        for i in 0...Int(value) { acc += bins[i] }
        return Double(acc) / Double(count)
    }
}

// MARK: - Merge

public enum HDRMergeCore {
    public static func merge(frames: [RawFrame], options: MergeOptions = MergeOptions()) throws -> MergedImage {
        guard !frames.isEmpty else { throw MergeError.noFrames }
        let first = frames[0]
        for f in frames.dropFirst() {
            // Compare the *photo* geometry, not the stored array: two cameras (or the same camera
            // before/after a firmware change) can store different margin sizes around the same
            // picture rectangle.
            guard f.cropWidth == first.cropWidth, f.cropHeight == first.cropHeight,
                  f.cfaPattern == first.cfaPattern, f.cfaRows == first.cfaRows,
                  f.cfaCols == first.cfaCols else {
                throw MergeError.geometryMismatch("\(f.url.lastPathComponent) differs from \(first.url.lastPathComponent)")
            }
            if f.cropX % first.cfaCols != first.cropX % first.cfaCols
                || f.cropY % first.cfaRows != first.cropY % first.cfaRows {
                throw MergeError.geometryMismatch("\(f.url.lastPathComponent) crop offset \(f.cropX),\(f.cropY) has a different CFA phase than \(first.cropX),\(first.cropY)")
            }
        }

        var report: [String] = []
        let white = options.customWhiteLevel ?? first.whiteLevel

        // 1. Black-subtracted planes, in input order. `sample`/`blackAt` are photo-relative, so
        //    the sensor margins never enter the mosaic.
        var planes: [Plane] = frames.map { f in
            var px = [UInt16](repeating: 0, count: f.cropWidth * f.cropHeight)
            for y in 0..<f.cropHeight {
                for x in 0..<f.cropWidth {
                    let v = Int(f.sample(x, y)) - Int(f.blackAt(x, y))
                    px[y * f.cropWidth + x] = UInt16(max(0, v))
                }
            }
            return Plane(width: f.cropWidth, height: f.cropHeight, pixels: px,
                         cfaPattern: f.photoCFAPattern, cfaRows: f.cfaRows, cfaCols: f.cfaCols,
                         colorCount: f.cfaPlaneColor.count)
        }

        // 2. Sort brightest → darkest (HDRMerge's "most to least exposed").
        let brightness = planes.map { p -> Double in
            p.pixels.reduce(0.0) { $0 + Double($1) } / Double(p.pixels.count)
        }
        let order = (0..<planes.count).sorted { brightness[$0] > brightness[$1] }
        planes = order.map { planes[$0] }

        // 3. Saturation level from the brightest frame, per CFA colour.
        //
        // `planes[0]` is the brightest frame after the sort above, so the colour lookup has to
        // use *that* frame's CFA phase, not `first`'s (which is the first in input order). When
        // the bracket is not sorted darkest-first on the command line the two differ, and reading
        // the histogram through the wrong phase swaps R/B — the white level then comes from the
        // wrong channel pair.
        let brightest = planes[0]
        let nColors = max(4, brightest.colorCount)
        var hist = [[Int]](repeating: [Int](repeating: 0, count: 65536), count: nColors)
        let pw = brightest.width, ph = brightest.height
        for y in 0..<ph {
            for x in 0..<pw {
                hist[brightest.colorAt(x, y)][Int(brightest.pixels[y * pw + x])] += 1
            }
        }
        let minCount = max(1, pw * ph / 10000)
        var maxPerColor = [Int](repeating: 0, count: nColors)
        for c in 0..<nColors {
            for v in stride(from: 65535, through: 0, by: -1) where hist[c][v] > minCount {
                maxPerColor[c] = v
                break
            }
        }
        let brightestMax = maxPerColor.max() ?? 0
        var satThreshold = white
        if brightestMax > 0 { satThreshold = min(satThreshold, brightestMax) }
        if options.customWhiteLevel == nil { satThreshold = Int(Double(satThreshold) * 0.99) }
        let sat = UInt16(min(max(satThreshold, 1), 65535))
        report.append("white level \(white), saturation threshold \(sat)")

        // 4. Align: chain each frame to the next darker one, then accumulate.
        if planes.count > 1 {
            let levels = 6
            let scales = planes.map { $0.prescaled(levels: levels) }
            let halfLight = Histogram(planes[0].pixels).fraction(sat) / 2.0
            var chain = [(dx: Int, dy: Int)](repeating: (0, 0), count: planes.count - 1)
            for i in 0..<(planes.count - 1) {
                chain[i] = alignPair(ref: planes[i + 1], alt: planes[i],
                                     refScales: scales[i + 1], altScales: scales[i],
                                     levelCount: levels, halfLight: halfLight, sat: sat)
            }
            var placement = [(x: Int, y: Int)](repeating: (0, 0), count: planes.count)
            for i in stride(from: planes.count - 2, through: 0, by: -1) {
                placement[i] = (placement[i + 1].x + chain[i].dx,
                                placement[i + 1].y + chain[i].dy)
            }
            for i in 0..<planes.count {
                planes[i].dx = placement[i].x
                planes[i].dy = placement[i].y
                report.append("frame \(i) offset \(placement[i].x),\(placement[i].y)")
            }
        }

        // 5. Crop to the common area.
        var minX = Int.min, maxX = Int.max, minY = Int.min, maxY = Int.max
        for p in planes {
            minX = max(minX, p.dx); maxX = min(maxX, p.dx + p.width)
            minY = max(minY, p.dy); maxY = min(maxY, p.dy + p.height)
        }
        guard maxX > minX, maxY > minY else { throw MergeError.nothingToMerge }
        let cw = maxX - minX, ch = maxY - minY
        for i in 0..<planes.count {
            planes[i].dx -= minX
            planes[i].dy -= minY
        }

        // 6. Exposure ratios (brighter / darker) by least squares on the overlap.
        var scale = [Double](repeating: 1, count: planes.count)
        for i in stride(from: planes.count - 2, through: 0, by: -1) {
            var num = 0.0, den = 0.0
            let a = planes[i], b = planes[i + 1]
            for y in 0..<ch {
                for x in 0..<cw {
                    guard a.contains(x, y), b.contains(x, y) else { continue }
                    let v = Double(a.at(x, y)), nv = Double(b.at(x, y))
                    guard nv > 0, v < Double(sat) else { continue }
                    num += v * nv
                    den += nv * nv
                }
            }
            let k = den > 0 ? num / den : 1
            scale[i] = scale[i + 1] * (k > 0.01 ? k : 1)
            report.append(String(format: "frame %d exposure ratio %.3f", i, k))
        }

        // 7. Layer selection (brightest unsaturated layer wins).
        var layerMask = [UInt8](repeating: 0, count: cw * ch)
        for y in 0..<ch {
            for x in 0..<cw {
                var chosen = planes.count - 1
                for i in 0..<(planes.count - 1) {
                    guard planes[i].contains(x, y) else { continue }
                    if maxAround(planes[i], x, y) < sat { chosen = i; break }
                }
                layerMask[y * cw + x] = UInt8(chosen)
            }
        }

        // 8. Feather: fatten then blur the layer index field.
        let radius = max(1, options.featherRadius)
        var floatMask = layerMask.map { Float($0) }
        floatMask = maxFilter(floatMask, width: cw, height: ch, radius: radius)
        floatMask = boxBlur(floatMask, width: cw, height: ch, radius: radius)

        // 9. Compose.
        let black = first.blackLevel.max() ?? 0
        var out = [Float](repeating: 0, count: cw * ch)
        var peak: Float = 0
        let lastIndex = Float(planes.count - 1)
        for y in 0..<ch {
            for x in 0..<cw {
                var p = min(max(floatMask[y * cw + x], 0), lastIndex)
                var j = Int(p)
                if j >= planes.count { j = planes.count - 1; p = lastIndex }
                var frac = Double(p) - Double(j)
                var v: Double
                if planes[j].contains(x, y) {
                    v = Double(planes[j].at(x, y)) / scale[j]
                } else {
                    v = 0
                    frac = 1
                }
                var vv = 0.0
                if frac > 0.0001 && j < planes.count - 1 && planes[j + 1].contains(x, y) {
                    vv = Double(planes[j + 1].at(x, y)) / scale[j + 1]
                } else {
                    frac = 0
                }
                v -= frac * (v - vv)
                let f = Float(v)
                out[y * cw + x] = f
                if f > peak { peak = f }
            }
        }

        // 10. Rescale and restore the black level.
        //   headroom == 1  -> normalise the peak to the white level (upstream)
        //   headroom >  1  -> keep the input scale and use the top of the
        //                     container for `headroom × white` of headroom
        let inWhite = Double(first.whiteLevel)
        let outWhite: Double = options.headroom > 1 ? 65535 : Double(white)
        let mult: Double
        if options.headroom > 1 {
            let span = (inWhite - black) * options.headroom
            mult = span > 0 ? (outWhite - black) / span : 1
        } else {
            mult = peak > 0 ? (Double(white) - black) / Double(peak) : 1
        }
        report.append(String(format: "peak %.1f, black %.1f, white %d, mult %.4f", Double(peak), black, white, mult))
        for i in 0..<out.count {
            out[i] = Float(Double(out[i]) * mult + black)
        }

        return MergedImage(width: cw, height: ch, values: out,
                           black: black, white: Int(outWhite),
                           cfaPattern: first.photoCFAPattern,
                           cfaRows: first.cfaRows, cfaCols: first.cfaCols,
                           cfaPlaneColor: first.cfaPlaneColor,
                           offsets: planes.map { ($0.dx, $0.dy) },
                           referenceIndex: 1,
                           report: report)
    }

    @inline(__always)
    static func maxAround(_ p: Plane, _ x: Int, _ y: Int) -> UInt16 {
        var m: UInt16 = 0
        for yy in (y - 1)...(y + 1) where yy >= p.dy && yy < p.dy + p.height {
            for xx in (x - 1)...(x + 1) where xx >= p.dx && xx < p.dx + p.width {
                let v = p.pixels[(yy - p.dy) * p.width + (xx - p.dx)]
                if v > m { m = v }
            }
        }
        return m
    }

    // MARK: alignment

    static func alignPair(ref: Plane, alt: Plane,
                          refScales: [Plane.Scale], altScales: [Plane.Scale],
                          levelCount: Int, halfLight: Double, sat: UInt16) -> (dx: Int, dy: Int) {
        var dx = 0, dy = 0
        let tolerance = 1.0 / 16
        for s in stride(from: levelCount - 1, through: 0, by: -1) {
            guard s < refScales.count, s < altScales.count else { continue }
            let rs = refScales[s], as_ = altScales[s]
            let w = min(rs.width, as_.width), h = min(rs.height, as_.height)
            guard w > 4, h > 4 else { continue }

            let h1 = Histogram(Array(rs.pixels[0..<(w * h)]))
            let h2 = Histogram(Array(as_.pixels[0..<(w * h)]))
            let mth1 = h1.percentile(halfLight), mth2 = h2.percentile(halfLight)
            let tol1 = UInt16(Double(mth1) * tolerance), tol2 = UInt16(Double(mth2) * tolerance)

            let mtb1 = Bitmap(pixels: Array(rs.pixels[0..<(w * h)]), width: w, height: h,
                              threshold: mth1, exclusive: false)
            let mtb2 = Bitmap(pixels: Array(as_.pixels[0..<(w * h)]), width: w, height: h,
                              threshold: mth2, exclusive: false)
            let excl1 = Bitmap.exclusion(pixels: Array(rs.pixels[0..<(w * h)]), width: w, height: h,
                                         threshold: mth1, tolerance: tol1)
            let excl2 = Bitmap.exclusion(pixels: Array(as_.pixels[0..<(w * h)]), width: w, height: h,
                                         threshold: mth2, tolerance: tol2)

            // Baseline: keep the offset inherited from the coarser level.
            let zeroShift = mtb2.shifted(dx, dy)
            let zeroExcl = excl2.shifted(dx, dy)
            let base = mtb1.xorCount(zeroShift, with: excl1, and: zeroExcl)
            var best = (dx, dy), bestError = base.mismatch
            let valid = base.valid
            for i in -1...1 {
                for j in -1...1 where !(i == 0 && j == 0) {
                    let cx = dx + i, cy = dy + j
                    let sMtb = mtb2.shifted(cx, cy)
                    let sExcl = excl2.shifted(cx, cy)
                    let r = mtb1.xorCount(sMtb, with: excl1, and: sExcl)
                    if r.mismatch < bestError {
                        bestError = r.mismatch
                        best = (cx, cy)
                    }
                }
            }
            // Refuse to move on noise: a sub-pixel misalignment improves the XOR
            // count by only a fraction of a percent, and accepting it here gets
            // amplified by the x2 at every finer level.
            if bestError >= base.mismatch - max(1, valid / 200) {
                best = (dx, dy)
                bestError = base.mismatch
            }
            if ProcessInfo.processInfo.environment["HDRMERGE_DEBUG"] != nil {
                FileHandle.standardError.write(Data("level \(s) \(w)x\(h) best \(best.0),\(best.1) err \(bestError) valid \(valid)\n".utf8))
            }
            dx = best.0 << 1
            dy = best.1 << 1
        }
        return (dx, dy)
    }

    // MARK: filters

    static func maxFilter(_ src: [Float], width: Int, height: Int, radius: Int) -> [Float] {
        var tmp = [Float](repeating: 0, count: src.count)
        for y in 0..<height {
            for x in 0..<width {
                var m: Float = 0
                for i in max(0, x - radius)...min(width - 1, x + radius) {
                    m = max(m, src[y * width + i])
                }
                tmp[y * width + x] = m
            }
        }
        var out = [Float](repeating: 0, count: src.count)
        for y in 0..<height {
            for x in 0..<width {
                var m: Float = 0
                for j in max(0, y - radius)...min(height - 1, y + radius) {
                    m = max(m, tmp[j * width + x])
                }
                out[y * width + x] = m
            }
        }
        return out
    }

    static func boxBlur(_ src: [Float], width: Int, height: Int, radius: Int) -> [Float] {
        guard radius > 0 else { return src }
        var tmp = [Float](repeating: 0, count: src.count)
        let win = Float(2 * radius + 1)
        for y in 0..<height {
            var acc: Float = 0
            for x in -radius...radius {
                acc += src[y * width + min(max(x, 0), width - 1)]
            }
            for x in 0..<width {
                tmp[y * width + x] = acc / win
                let outIdx = min(max(x - radius, 0), width - 1)
                let inIdx = min(max(x + radius + 1, 0), width - 1)
                acc += src[y * width + inIdx] - src[y * width + outIdx]
            }
        }
        var out = [Float](repeating: 0, count: src.count)
        for x in 0..<width {
            var acc: Float = 0
            for y in -radius...radius {
                acc += tmp[min(max(y, 0), height - 1) * width + x]
            }
            for y in 0..<height {
                out[y * width + x] = acc / win
                let outIdx = min(max(y - radius, 0), height - 1)
                let inIdx = min(max(y + radius + 1, 0), height - 1)
                acc += tmp[inIdx * width + x] - tmp[outIdx * width + x]
            }
        }
        return out
    }
}
