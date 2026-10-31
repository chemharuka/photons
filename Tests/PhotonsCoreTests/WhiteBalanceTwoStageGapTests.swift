import XCTest
import Metal
@testable import PhotonsCore

/// 194 §2 — **how far the drag's approximation is from the decoder's answer.**
///
/// Two-stage white balance has one approximation in it and this file is the measurement of that one:
/// the drag draws the buffer on screen through an S1 gain (`WhiteBalanceEstimate`) because a decode is
/// ~0.5 s, while the settled frame is what `CIRAWFilter.neutralTemperature`/`neutralTint` produce.
/// Before the contract is rewritten (`WhiteBalancePreviewParityTests`) the size of the difference has
/// to be a number, not an opinion:
///
///   · **A** = decode **at** the pair, S1 identity — the truth (`photonsctl render --wb <pair>`);
///   · **B** = decode as shot, the pair as an S1 gain — the drag.
///
/// Five pairs: as shot, 6500 K, 3200 K, and ±30 tint on 6500 K. For each one the file prints
/// `max|Δ|` in 8-bit display codes and ΔE00 averaged over three tonal bands (shadows / mid-tones /
/// highlights, banded by the **truth**'s luma), because "2 codes" means nothing if it is all in the
/// toe and nothing if it is all in a flat sky.
///
/// The measurement runs on the user's own RAW when it is present (`PHOTONS_WB_RAW`, else
/// `~/Desktop/test/L1030433.dng`) and skips otherwise. Nothing here asserts a tolerance: 194 §3 is
/// where the number becomes a contract, and it is the number this file prints.
final class WhiteBalanceTwoStageGapTests: XCTestCase {

    private static let defaultRAW = "~/Desktop/test/L1030433.dng"
    private static let decodeScale: Float = 0.25

    private static let pairs: [(String, WhiteBalance)] = [
        ("as shot", .asShot),
        ("6500 K", WhiteBalance(temperature: 6500, tint: 0)),
        ("3200 K", WhiteBalance(temperature: 3200, tint: 0)),
        ("6500 K / +30", WhiteBalance(temperature: 6500, tint: 30)),
        ("6500 K / −30", WhiteBalance(temperature: 6500, tint: -30)),
    ]

    private func fixtureURL() throws -> URL {
        let env = ProcessInfo.processInfo.environment["PHOTONS_WB_RAW"]
        let path = NSString(string: env ?? Self.defaultRAW).expandingTildeInPath
        guard FileManager.default.isReadableFile(atPath: path) else {
            throw XCTSkip("missing fixture \(path)")
        }
        return URL(fileURLWithPath: path)
    }

    private func decode(_ url: URL, _ wb: WhiteBalance) throws -> LinearImage {
        try RAWDecoder().decode(url, options: DecodeOptions(scale: Self.decodeScale,
                                                            whiteBalance: wb))
    }

    private func render(_ image: LinearImage, buffer: WhiteBalance, document wb: WhiteBalance,
                        identity: String) throws -> DisplayImage {
        let graph = try RenderGraph(input: RenderInput(image: image, identity: identity,
                                                       whiteBalance: buffer))
        var edit = EditModel.neutral
        edit.light.temperature = wb.temperature
        edit.light.tint = wb.tint
        let options = RenderOptions(scale: 1,
                                    display: DisplayOptions(primaries: .sRGB, bitDepth: 8),
                                    useCache: false, wantsPixels: true)
        return try XCTUnwrap(graph.render(edit, options: options).display)
    }

    func testPreviewGainVersusDecoderTruth() throws {
        let url = try fixtureURL()
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }

        // One as-shot decode serves every pair's B side; each A side is its own development, which is
        // exactly the cost the settled frame pays (`0.5 s` on 25 MP, `--scale` here).
        let asShot = try decode(url, .asShot)
        print(String(format: "WB gap: %@ @ scale %.2f → %d×%d",
                     url.lastPathComponent, Double(Self.decodeScale),
                     asShot.width, asShot.height))

        for (name, pair) in Self.pairs {
            let truth = try render(try decode(url, pair), buffer: pair, document: pair,
                                   identity: "A-\(name)")
            let approximation = try render(asShot, buffer: .asShot, document: pair,
                                           identity: "B-\(name)")
            let g = try RenderGraph(input: RenderInput(image: asShot, identity: "probe-\(name)"))
                .whiteBalanceGain(from: .asShot, to: pair)
            let report = Self.compare(truth, approximation)
            print(String(format: "WB gap %-12@ max|Δ| %3d code · mean|Δ| %6.3f · "
                         + "ΔE00 shadows %5.2f mid %5.2f highlights %5.2f",
                         name as NSString,
                         report.maxCode, report.meanCode,
                         report.deltaE.shadows, report.deltaE.mid, report.deltaE.highlights)
                + String(format: " · mean RGB truth %.3f %.3f %.3f · gain %.3f %.3f %.3f",
                         report.meanA.0, report.meanA.1, report.meanA.2,
                         report.meanB.0, report.meanB.1, report.meanB.2)
                + String(format: " · S1 gain %.4f %.4f %.4f", g.r, g.g, g.b))
            XCTAssertTrue(report.maxCode >= 0)
        }
        print("WB gap: done — the tolerance in WhiteBalancePreviewParityTests is these numbers.")
    }

    // MARK: - comparison

    struct Report {
        let maxCode: Int
        let meanCode: Double
        let deltaE: (shadows: Double, mid: Double, highlights: Double)
        /// Whole-frame mean channel values of both frames — a gain that is merely *scaled* wrong shows
        /// up here as one channel ratio, while a hue-only difference cancels out of these means.
        let meanA: (Double, Double, Double)
        let meanB: (Double, Double, Double)
    }

    /// 8-bit codes for one pixel (what a screen shows) and the CIELAB of the same pixel.
    private static func code(_ v: Float16) -> Int {
        Int((min(max(Double(v), 0), 1) * 255).rounded())
    }

    static func compare(_ a: DisplayImage, _ b: DisplayImage) -> Report {
        precondition(a.width == b.width && a.height == b.height)
        var maxCode = 0
        var sumCode = 0.0
        var sumA = (0.0, 0.0, 0.0), sumB = (0.0, 0.0, 0.0)
        var bands: [[Double]] = [[], [], []]      // shadows, mid, highlights
        var counts = [0, 0, 0]
        let n = a.width * a.height
        for i in 0..<n {
            let o = i * 4
            var luma = 0.0
            var labA = (0.0, 0.0, 0.0)
            var labB = (0.0, 0.0, 0.0)
            var d = 0
            for c in 0..<3 {
                let ca = code(a.rgba[o + c]), cb = code(b.rgba[o + c])
                d = max(d, abs(ca - cb))
                sumCode += Double(abs(ca - cb))
            }
            maxCode = max(maxCode, d)
            sumA.0 += Double(a.rgba[o]); sumA.1 += Double(a.rgba[o + 1]); sumA.2 += Double(a.rgba[o + 2])
            sumB.0 += Double(b.rgba[o]); sumB.1 += Double(b.rgba[o + 1]); sumB.2 += Double(b.rgba[o + 2])
            luma += 0.2126 * Double(a.rgba[o]) + 0.7152 * Double(a.rgba[o + 1])
                + 0.0722 * Double(a.rgba[o + 2])
            labA = lab(Double(a.rgba[o]), Double(a.rgba[o + 1]), Double(a.rgba[o + 2]))
            labB = lab(Double(b.rgba[o]), Double(b.rgba[o + 1]), Double(b.rgba[o + 2]))
            let band = luma < 0.18 ? 0 : (luma < 0.6 ? 1 : 2)
            counts[band] += 1
            bands[band].append(deltaE00(labA, labB))
        }
        func mean(_ xs: [Double]) -> Double {
            xs.isEmpty ? 0 : xs.reduce(0, +) / Double(xs.count)
        }
        return Report(maxCode: maxCode,
                      meanCode: sumCode / Double(n * 3),
                      deltaE: (mean(bands[0]), mean(bands[1]), mean(bands[2])),
                      meanA: (sumA.0 / Double(n), sumA.1 / Double(n), sumA.2 / Double(n)),
                      meanB: (sumB.0 / Double(n), sumB.1 / Double(n), sumB.2 / Double(n)))
    }

    // MARK: - sRGB (display encoded) → CIELAB

    /// The frame's pixels are display-encoded sRGB (`bitDepth: 8` above), so the codec is the inverse
    /// OETF and the matrix is sRGB→XYZ. ΔE00 is then a statement about the picture a person sees, which
    /// is the only domain in which "is the jump visible" means anything.
    static func lab(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        func linear(_ v: Double) -> Double {
            let c = min(max(v, 0), 1)
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let lr = linear(r), lg = linear(g), lb = linear(b)
        let x = 0.4124564 * lr + 0.3575761 * lg + 0.1804375 * lb
        let y = 0.2126729 * lr + 0.7151522 * lg + 0.0721750 * lb
        let z = 0.0193339 * lr + 0.1191920 * lg + 0.9503041 * lb
        func f(_ t: Double) -> Double {
            let e = 216.0 / 24389.0, k = 24389.0 / 27.0
            return t > e ? pow(t, 1.0 / 3.0) : (k * t + 16) / 116
        }
        let fx = f(x / 0.95047), fy = f(y / 1.0), fz = f(z / 1.08883)
        return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    /// CIEDE2000 (Sharma et al. 2005, kL = kC = kH = 1).
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
        func hue(_ b: Double, _ a: Double) -> Double {
            if a == 0 && b == 0 { return 0 }
            let h = atan2(b, a) / rad
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
