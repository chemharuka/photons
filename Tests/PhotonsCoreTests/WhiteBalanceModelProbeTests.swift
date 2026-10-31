import XCTest
@testable import PhotonsCore

/// 195 — **the model against the decoder, in scene-linear light, without the pipeline.**
///
/// The display-domain gap test answers "how many codes is the preview from the frame". This one
/// answers *why*, which is the only way to tell a wrong estimate from a dropped cross term:
///
///   · **fit** — the free 3×3 that best maps the as-shot decode onto the pair's decode (the ceiling;
///     if *this* is not small, no matrix can be, and the difference is not linear);
///   · **model** — `matrix(pair) · matrix(as-shot pair)⁻¹`, what the runtime multiplies by;
///   · **model, anchored at 6500** — the same product with the nominal 6500 K as the reference, i.e.
///     what the pipeline used while the as-shot pair was not known. 194's `gain(for:)` did the same.
///
/// Gated on `PHOTONS_WB_MODEL_PROBE` because it decodes each file once per pair.
final class WhiteBalanceModelProbeTests: XCTestCase {

    private static let files = ["~/Desktop/test/L1030433.dng", "~/Desktop/US/DJI_air3_2250_D.dng"]
    private static let pairs: [(String, WhiteBalance)] = [
        ("6500 K", WhiteBalance(temperature: 6500, tint: 0)),
        ("3200 K", WhiteBalance(temperature: 3200, tint: 0)),
        ("6500 / +30", WhiteBalance(temperature: 6500, tint: 30)),
        ("6500 / −30", WhiteBalance(temperature: 6500, tint: -30)),
    ]

    func testModelVersusDecoderInSceneLinear() throws {
        guard ProcessInfo.processInfo.environment["PHOTONS_WB_MODEL_PROBE"] != nil else {
            throw XCTSkip("diagnostic only")
        }
        let decoder = try RAWDecoder()
        let toWorking = ColorPrimaries.conversion(from: .decoded, to: .working)
        for path in Self.files {
            let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
            guard FileManager.default.isReadableFile(atPath: url.path) else { continue }
            let outcome = try decoder.decodeDetailed(url, options: DecodeOptions(scale: 0.25,
                                                                                whiteBalance: .asShot))
            let asShotPair = outcome.capabilities.asShotWhiteBalance
            let x = Self.samples(outcome.image, toWorking: toWorking)
            print(String(format: "195 probe: %@ · as shot pair %@ · decoded neutral %@",
                         url.lastPathComponent as NSString, asShotPair.summary as NSString,
                         Self.neutrality(outcome.image)))
            for (name, pair) in Self.pairs {
                let y = try decoder.decode(url, options: DecodeOptions(scale: 0.25, whiteBalance: pair))
                let yw = Self.samples(y, toWorking: toWorking)
                let n = min(x.count, yw.count)
                var ne = NormalEquations()
                var kept: [(SIMD3<Double>, SIMD3<Double>)] = []
                kept.reserveCapacity(4_000)
                for k in 0..<n {
                    let xv = x[k], yv = yw[k]
                    guard xv.x > 0, xv.y > 0, xv.z > 0, yv.x > 0, yv.y > 0, yv.z > 0 else { continue }
                    let luma = ColorPrimaries.working.luminance(of: xv)
                    guard luma > 0.004, luma < 1.5 else { continue }
                    ne.add(x: xv, y: yv, weight: 1.0 / max(luma, 0.02))
                    if kept.count < 4_000 { kept.append((xv, yv)) }
                }
                guard let fit = ne.solveFree() else { continue }

                let anchored = WhiteBalanceEstimate.matrix(temperature: pair.temperature ?? 6500,
                                                           tint: pair.tint ?? 0)
                    * WhiteBalanceEstimate.matrix(temperature: asShotPair.temperature ?? 6500,
                                                  tint: asShotPair.tint ?? 0).inverted()
                let nominal = WhiteBalanceEstimate.matrix(temperature: pair.temperature ?? 6500,
                                                          tint: pair.tint ?? 0)
                    * WhiteBalanceEstimate.matrix(
                        temperature: WhiteBalanceSolver.nominalTemperature, tint: 0).inverted()

                func score(_ m: Matrix3) -> (Double, (Double, Double, Double)) {
                    var bands: [[Double]] = [[], [], []]
                    for (xv, yv) in kept {
                        let p = m * xv
                        let luma = ColorPrimaries.working.luminance(of: yv)
                        let band = luma < 0.18 ? 0 : (luma < 0.6 ? 1 : 2)
                        bands[band].append(Self.deltaE00(Self.lab(p), Self.lab(yv)))
                    }
                    func mean(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count) }
                    return ((mean(bands[0]) + mean(bands[1]) + mean(bands[2])) / 3,
                            (mean(bands[0]), mean(bands[1]), mean(bands[2])))
                }

                let fitScore = score(fit)
                let anchoredScore = score(anchored)
                let nominalScore = score(nominal)
                func row(_ label: String, _ s: (Double, (Double, Double, Double)), _ m: Matrix3) -> String {
                    String(format: "195 probe: %-22@ %-10@ ΔE00 暗 %5.2f 中 %5.2f 高 %5.2f · diag %.3f/%.3f/%.3f",
                           "\(url.lastPathComponent) \(name)" as NSString, label as NSString,
                           s.1.0, s.1.1, s.1.2, m[0, 0], m[1, 1], m[2, 2])
                }
                print(row("fit (ceiling)", fitScore, fit))
                print(row("model@asShot", anchoredScore, anchored))
                print(row("model@6500", nominalScore, nominal))
            }
        }
    }

    // MARK: - helpers

    struct NormalEquations {
        var a = [Double](repeating: 0, count: 9)
        var b = [Double](repeating: 0, count: 9)

        mutating func add(x: SIMD3<Double>, y: SIMD3<Double>, weight w: Double) {
            let v = [x.x, x.y, x.z], t = [y.x, y.y, y.z]
            for i in 0..<3 {
                for j in 0..<3 { a[i * 3 + j] += w * v[i] * v[j] }
                for j in 0..<3 { b[i * 3 + j] += w * v[j] * t[i] }
            }
        }

        func solveFree() -> Matrix3? {
            var values: [Double] = []
            for i in 0..<3 {
                var m = [[Double]](repeating: [Double](repeating: 0, count: 4), count: 3)
                for r in 0..<3 {
                    for c in 0..<3 { m[r][c] = a[r * 3 + c] }
                    m[r][3] = b[i * 3 + r]
                }
                guard let s = Self.solve(m), s.count == 3 else { return nil }
                values.append(contentsOf: s)
            }
            return Matrix3(rowMajor: values)
        }

        static func solve(_ input: [[Double]]) -> [Double]? {
            var m = input
            let n = m.count
            for col in 0..<n {
                var pivot = col
                for r in (col + 1)..<n where abs(m[r][col]) > abs(m[pivot][col]) { pivot = r }
                guard abs(m[pivot][col]) > 1e-12 else { return nil }
                if pivot != col { m.swapAt(pivot, col) }
                let scale = m[col][col]
                for c in col..<(n + 1) { m[col][c] /= scale }
                for r in 0..<n where r != col {
                    let f = m[r][col]
                    if f == 0 { continue }
                    for c in col..<(n + 1) { m[r][c] -= f * m[col][c] }
                }
            }
            return (0..<n).map { m[$0][n] }
        }
    }

    static func samples(_ image: LinearImage, toWorking p: Matrix3) -> [SIMD3<Double>] {
        var out: [SIMD3<Double>] = []
        out.reserveCapacity(image.width * image.height / 9 + 1)
        for y in stride(from: 0, to: image.height, by: 3) {
            for x in stride(from: 0, to: image.width, by: 3) {
                let o = (y * image.width + x) * 4
                if image.rgba[o + 3] < 0.5 { continue }
                out.append(p * SIMD3(Double(image.rgba[o]), Double(image.rgba[o + 1]),
                                     Double(image.rgba[o + 2])))
            }
        }
        return out
    }

    /// How neutral the decoded buffer's own white is: the chroma of its grey-world mean, in percent.
    static func neutrality(_ image: LinearImage) -> String {
        var sum = SIMD3<Double>(0, 0, 0)
        var n = 0.0
        for y in stride(from: 0, to: image.height, by: 7) {
            for x in stride(from: 0, to: image.width, by: 7) {
                let o = (y * image.width + x) * 4
                let r = Double(image.rgba[o]), g = Double(image.rgba[o + 1]), b = Double(image.rgba[o + 2])
                guard r > 0.004, g > 0.004, b > 0.004, r + g + b < 2.4 else { continue }
                sum += SIMD3(r, g, b)
                n += 1
            }
        }
        guard n > 0 else { return "n/a" }
        let m = sum / n
        let mean = (m.x + m.y + m.z) / 3
        return String(format: "%.4f/%.4f/%.4f (chroma %.1f%%)", m.x, m.y, m.z,
                      (max(m.x, max(m.y, m.z)) - min(m.x, min(m.y, m.z))) / mean * 100)
    }

    static func lab(_ v: SIMD3<Double>) -> (Double, Double, Double) {
        let xyz = ColorPrimaries.working.toXYZ * v
        func f(_ t: Double) -> Double {
            let e = 216.0 / 24389.0, k = 24389.0 / 27.0
            return t > e ? pow(max(t, 0), 1.0 / 3.0) : (k * t + 16) / 116
        }
        let fx = f(xyz.x / 0.95047), fy = f(xyz.y), fz = f(xyz.z / 1.08883)
        return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    static func deltaE00(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Double {
        let (l1, a1, b1) = a, (l2, a2, b2) = b
        let rad = Double.pi / 180
        let c1 = (a1 * a1 + b1 * b1).squareRoot()
        let c2 = (a2 * a2 + b2 * b2).squareRoot()
        let cBar = (c1 + c2) / 2
        let cBar7 = pow(cBar, 7)
        let g = 0.5 * (1 - (cBar7 / (cBar7 + pow(25, 7))).squareRoot())
        let a1p = (1 + g) * a1, a2p = (1 + g) * a2
        let c1p = (a1p * a1p + b1 * b1).squareRoot()
        let c2p = (a2p * a2p + b2 * b2).squareRoot()
        func hue(_ bb: Double, _ aa: Double) -> Double {
            if aa == 0 && bb == 0 { return 0 }
            let h = atan2(bb, aa) / rad
            return h < 0 ? h + 360 : h
        }
        let h1p = hue(b1, a1p), h2p = hue(b2, a2p)
        let dLp = l2 - l1
        let dCp = c2p - c1p
        var dhp = h2p - h1p
        if c1p * c2p == 0 { dhp = 0 }
        else if dhp > 180 { dhp -= 360 }
        else if dhp < -180 { dhp += 360 }
        let dHp = 2 * (c1p * c2p).squareRoot() * sin(dhp * rad / 2)
        let lBarP = (l1 + l2) / 2
        let cBarP = (c1p + c2p) / 2
        var hBarP = h1p + h2p
        if c1p * c2p != 0 {
            if abs(h1p - h2p) <= 180 { hBarP = (h1p + h2p) / 2 }
            else if h1p + h2p < 360 { hBarP = (h1p + h2p + 360) / 2 }
            else { hBarP = (h1p + h2p - 360) / 2 }
        }
        let t = 1 - 0.17 * cos((hBarP - 30) * rad) + 0.24 * cos(2 * hBarP * rad)
            + 0.32 * cos((3 * hBarP + 6) * rad) - 0.20 * cos((4 * hBarP - 63) * rad)
        let dTheta = 30 * exp(-pow((hBarP - 275) / 25, 2))
        let cBarP7 = pow(cBarP, 7)
        let rc = 2 * (cBarP7 / (cBarP7 + pow(25, 7))).squareRoot()
        let sl = 1 + (0.015 * pow(lBarP - 50, 2)) / (20 + pow(lBarP - 50, 2)).squareRoot()
        let sc = 1 + 0.045 * cBarP
        let sh = 1 + 0.015 * cBarP * t
        let rt = -sin(2 * dTheta * rad) * rc
        let l = dLp / sl, c = dCp / sc, h = dHp / sh
        return (l * l + c * c + h * h + rt * c * h).squareRoot()
    }
}
