//
//  TextureBandRestore562Tests.swift
//
//  562 — 窄带织纹恢复。全部用合成图（确定性 RNG），不依赖真实 RAW：
//  DNG 只在需要验证 CFA 交错/量化时写（fixture 当模板，像素无损往返）。
//
//  每个用例对应派单 §3 的一条：
//    (a) 线恢复 ≥85 %、宽带 RMS 变化 ≤2 %
//    (b) 纯噪声：平均权重 ≤0.1、新增 RMS ≤噪声 2 %
//    (c) 窗界无接缝：相邻像素权重差 ≤0.02，输出的二阶差分不高于源的 3 倍
//    (d) source == product 时逐值不变（≤1 DN）
//    (e) 四个 CFA 平面各自的谱线各自恢复，未注入区域 ≤1 DN（不串相位）
//

import XCTest
import NonlocalMatchFilter
@testable import PhotonsExtensions

final class TextureBandRestore562Tests: XCTestCase {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static var fixtureURL: URL {
        repoRoot.appendingPathComponent("Tests/Fixtures/small-rggb.dng")
    }

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-562-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    // MARK: - (a) 一条已知周期/方向的谱线

    func testAKnownLineComesBackWithoutLiftingBroadband() throws {
        let plane = 512
        let f0 = 1.0 / 3.4
        // 90°（竖线）是实拍 L1040080 那一条：Immerkaer 可分离核沿轴严格为 0，
        // 这条用例就是钉住「正则化之后竖线仍能被检测」。
        let theta = 90.0 * Double.pi / 180
        let amplitude = 2e-3
        let sigma = 4e-3

        var source = [Double](repeating: 0.5, count: plane * plane)
        var product = [Double](repeating: 0.5, count: plane * plane)
        var rng = SplitMix64(seed: 562_001)
        for y in 0..<plane {
            for x in 0..<plane {
                let i = y * plane + x
                let line = amplitude * sin(2 * .pi * f0 * (Double(x) * cos(theta) + Double(y) * sin(theta)))
                let noise = sigma * rng.gaussian()
                source[i] = 0.5 + line + noise
                product[i] = 0.5 + noise
            }
        }

        let sourceURL = workDir.appendingPathComponent("a-source.dng")
        let productURL = workDir.appendingPathComponent("a-product.dng")
        try writeMosaic(sourcePlane: source, productPlane: product,
                        plane: plane, sourceURL: sourceURL, productURL: productURL)

        let report = try TextureBandRestore.apply(
            source: sourceURL, product: productURL,
            options: TextureBandRestoreOptions())
        XCTAssertGreaterThan(report.windows, 0, "512² 平面至少一扇窗")
        XCTAssertEqual(report.planes, 4)

        let output = try readPlane(url: productURL, plane: plane, offsetIndex: 0)

        let src = lineStats(source, width: plane, height: plane, f: f0, theta: theta)
        let prod = lineStats(product, width: plane, height: plane, f: f0, theta: theta)
        let out = lineStats(output, width: plane, height: plane, f: f0, theta: theta)

        print("562(a) line amp: source \(src.amp) product \(prod.amp) output \(out.amp)")
        print("562(a) broad rms: source \(src.broad) product \(prod.broad) output \(out.broad)")
        XCTAssertGreaterThan(src.amp, amplitude * 0.9, "合成图自己应当有这条线")
        XCTAssertLessThan(prod.amp, amplitude * 0.15, "产物是「同图 − 线」")
        XCTAssertGreaterThanOrEqual(out.amp, src.amp * 0.85,
                                    "线幅度必须恢复到输入的 85 % 以上（got \(out.amp / src.amp))")
        let broadChange = abs(out.broad - src.broad) / src.broad
        XCTAssertLessThanOrEqual(broadChange, 0.02,
                                 "宽带 RMS 变化 \(broadChange * 100) % 超过 2 %")
        XCTAssertGreaterThan(report.meanWeight, 0.8)
        XCTAssertEqual(report.medianPeriodPlanePx, 3.4, accuracy: 0.6)
    }

    // MARK: - (b) 纯噪声

    func testPureNoiseDoesNotGetABand() {
        let plane = 512
        let sigma = 4e-3
        var source = [Double](repeating: 0.5, count: plane * plane)
        var product = [Double](repeating: 0.5, count: plane * plane)
        var rng = SplitMix64(seed: 562_002)
        for i in source.indices {
            source[i] = 0.5 + sigma * rng.gaussian()
            product[i] = 0.5 + sigma * rng.gaussian()
        }

        var options = TextureBandRestoreOptions()
        options.window = 256
        options.hop = 128
        let result = TextureBandRestore.restorePlane(source: source, product: product,
                                                    width: plane, height: plane,
                                                    options: options)
        let meanWeight = result.windows > 0 ? result.weightSum / Double(result.windows) : 0
        let addedRMS = (result.deltas.reduce(0) { $0 + $1 * $1 } / Double(result.deltas.count)).squareRoot()

        print("562(b) windows \(result.windows) meanWeight \(meanWeight) addedRMS \(addedRMS)")
        XCTAssertLessThanOrEqual(meanWeight, 0.1,
                                 "纯噪声的平均权重 \(meanWeight) 超过 0.1")
        XCTAssertLessThanOrEqual(addedRMS, sigma * 0.02,
                                 "新增 RMS \(addedRMS) 超过噪声的 2 %")
    }

    // MARK: - (c) 窗界无接缝

    func testWindowBoundaryHasNoWeightStep() {
        // 与默认参数一致：1024² 平面、512 窗、50 % 重叠 ⇒ 窗界在 x = 256/512/768。
        // 用户尺寸（60 MP）上也是这一组比例，所以这里量到的权重斜率就是产品行为。
        let plane = 1024
        let f0 = 1.0 / 3.4
        let theta = 30.0 * Double.pi / 180
        let amplitude = 3e-3
        let sigma = 4e-3

        var source = [Double](repeating: 0.5, count: plane * plane)
        var product = [Double](repeating: 0.5, count: plane * plane)
        var rng = SplitMix64(seed: 562_003)
        // 左半有强线、右半纯噪声；中间用 64 px 的余弦过渡，避免在 x=512 人为造一个
        // 宽带台阶——那会掩盖真正要测的窗间接缝。
        func gate(_ x: Int) -> Double {
            if x < plane / 2 - 32 { return 1 }
            if x >= plane / 2 + 32 { return 0 }
            return 0.5 + 0.5 * cos(Double.pi * Double(x - (plane / 2 - 32)) / 64)
        }
        for y in 0..<plane {
            for x in 0..<plane {
                let i = y * plane + x
                let line = amplitude * gate(x)
                    * sin(2 * .pi * f0 * (Double(x) * cos(theta) + Double(y) * sin(theta)))
                source[i] = 0.5 + line + sigma * rng.gaussian()
                product[i] = 0.5 + sigma * rng.gaussian()
            }
        }

        let result = TextureBandRestore.restorePlane(source: source, product: product,
                                                    width: plane, height: plane,
                                                    options: TextureBandRestoreOptions())

        // Hann² 的最外几圈 Hann⁴ 接近 0，图像最外 8 px 没有定义权重（也不进画面）；
        // 这里只量内部，窗与窗的交界（x=256/512/768）全在内部。
        let margin = 8
        var maxStep = 0.0
        var maxAt = (0, 0)
        for y in margin..<(plane - margin) {
            for x in margin..<(plane - margin - 1) {
                let i = y * plane + x
                let s = abs(result.weights[i + 1] - result.weights[i])
                if s > maxStep { maxStep = s; maxAt = (x, y) }
            }
        }
        for y in margin..<(plane - margin - 1) {
            for x in margin..<(plane - margin) {
                let i = y * plane + x
                let s = abs(result.weights[i + plane] - result.weights[i])
                if s > maxStep { maxStep = s; maxAt = (x, y) }
            }
        }
        print("562(c) max adjacent weight step \(maxStep) at \(maxAt)")
        XCTAssertLessThanOrEqual(maxStep, 0.02, "权重在窗界出现了台阶：\(maxStep)")

        // 窗界（x = 256 / 512 / 768）处的二阶差分不能比源自己在同一列更尖。
        #if DEBUG
        func secondDifference(_ values: [Double], columns: ClosedRange<Int>) -> (Double, Int, Int) {
            var worst = 0.0
            var at = (0, 0)
            for y in 8..<(plane - 8) {
                for x in columns {
                    let i = y * plane + x
                    let d = abs(values[i] - 2 * values[i - 1] + values[i - 2])
                    if d > worst { worst = d; at = (x, y) }
                }
            }
            return (worst, at.0, at.1)
        }
        for boundary in [256, 512, 768] {
            let columns = (boundary - 3)...(boundary + 3)
            let out = secondDifference(result.output, columns: columns)
            let src = secondDifference(source, columns: columns)
            print("562(c) second difference @\(boundary): out \(out.0) at \(out.1),\(out.2) source \(src.0)")
            XCTAssertLessThanOrEqual(out.0, max(src.0 * 3, 1e-9),
                                     "窗界 \(boundary) 处的二阶差分出现尖峰")
        }
        #endif
    }

    // MARK: - (d) 幂等 / 无损

    func testSourceEqualsProductIsBitForBitUnchanged() throws {
        let plane = 512
        let f0 = 1.0 / 3.4
        let theta = 15.0 * Double.pi / 180
        var values = [Double](repeating: 0.5, count: plane * plane)
        var rng = SplitMix64(seed: 562_004)
        for y in 0..<plane {
            for x in 0..<plane {
                let i = y * plane + x
                values[i] = 0.5
                    + 2e-3 * sin(2 * .pi * f0 * (Double(x) * cos(theta) + Double(y) * sin(theta)))
                    + 3e-3 * rng.gaussian()
            }
        }

        let sourceURL = workDir.appendingPathComponent("d-source.dng")
        let productURL = workDir.appendingPathComponent("d-product.dng")
        try writeMosaic(sourcePlane: values, productPlane: values,
                        plane: plane, sourceURL: sourceURL, productURL: productURL)

        let before = try Data(contentsOf: productURL, options: .alwaysMapped)
        _ = try TextureBandRestore.apply(source: sourceURL, product: productURL)
        let after = try Data(contentsOf: productURL, options: .alwaysMapped)

        let src = try readPlane(url: sourceURL, plane: plane, offsetIndex: 0)
        let out = try readPlane(url: productURL, plane: plane, offsetIndex: 0)
        let maxDelta = zip(src, out).map { abs($0 - $1) * Double(16383 - 512) }.max() ?? 0
        print("562(d) max delta \(maxDelta) DN, byte-identical \(before == after)")
        XCTAssertLessThanOrEqual(maxDelta, 1.0)
        XCTAssertEqual(before, after, "同值时连字节都不该动")
    }

    // MARK: - (e) CFA 几何：四平面各自不同周期

    func testFourCFAPlanesKeepTheirOwnPeriod() throws {
        let plane = 512
        let periods = [3.4, 4.1, 5.0, 6.2]
        let theta = 25.0 * Double.pi / 180
        let amplitude = 2e-3
        let sigma = 4e-3
        let inset = 64
        let ramp = 32

        var sourcePlanes: [[Double]] = []
        var productPlanes: [[Double]] = []
        var rng = SplitMix64(seed: 562_005)
        for p in 0..<4 {
            var s = [Double](repeating: 0.5, count: plane * plane)
            var d = [Double](repeating: 0.5, count: plane * plane)
            let f = 1.0 / periods[p]
            for y in 0..<plane {
                for x in 0..<plane {
                    let i = y * plane + x
                    let envelope = tukey(x: x, y: y, side: plane, inset: inset, ramp: ramp)
                    let line = amplitude * envelope
                        * sin(2 * .pi * f * (Double(x) * cos(theta) + Double(y) * sin(theta)))
                    let noise = sigma * rng.gaussian()
                    s[i] = 0.5 + line + noise
                    d[i] = 0.5 + noise
                }
            }
            sourcePlanes.append(s)
            productPlanes.append(d)
        }

        let sourceURL = workDir.appendingPathComponent("e-source.dng")
        let productURL = workDir.appendingPathComponent("e-product.dng")
        try writeFourPlanes(sourcePlanes, productPlanes, plane: plane,
                            sourceURL: sourceURL, productURL: productURL)

        _ = try TextureBandRestore.apply(source: sourceURL, product: productURL,
                                         options: TextureBandRestoreOptions())

        for p in 0..<4 {
            let src = try readPlane(url: sourceURL, plane: plane, offsetIndex: p)
            let out = try readPlane(url: productURL, plane: plane, offsetIndex: p)
            let f = 1.0 / periods[p]
            let s = lineStats(src, width: plane, height: plane, f: f, theta: theta)
            let o = lineStats(out, width: plane, height: plane, f: f, theta: theta)
            print("562(e) plane \(p) period \(periods[p]) amp \(o.amp / s.amp)")
            XCTAssertGreaterThanOrEqual(o.amp, s.amp * 0.85,
                                        "plane \(p) 的 \(periods[p]) px 线没有恢复")

            // 未注入区域（tukey 之外）必须逐值不动：线在窗外的泄漏不能改掉画面。
            var maxDN = 0.0
            for y in 0..<plane {
                for x in 0..<plane where envelopeZero(x: x, y: y, side: plane, inset: inset, ramp: ramp) {
                    maxDN = max(maxDN, abs(src[y * plane + x] - out[y * plane + x]) * Double(16383 - 512))
                }
            }
            XCTAssertLessThanOrEqual(maxDN, 1.0 + 1e-6, "plane \(p) 的未注入区域被改动了 \(maxDN) DN")
        }
    }

    // MARK: - 合成 DNG

    private func writeMosaic(sourcePlane: [Double], productPlane: [Double],
                             plane: Int, sourceURL: URL, productURL: URL) throws {
        try writeFourPlanes([sourcePlane, sourcePlane, sourcePlane, sourcePlane],
                            [productPlane, productPlane, productPlane, productPlane],
                            plane: plane, sourceURL: sourceURL, productURL: productURL)
    }

    private func writeFourPlanes(_ sourcePlanes: [[Double]], _ productPlanes: [[Double]],
                                 plane: Int, sourceURL: URL, productURL: URL) throws {
        let fixtureData = try Data(contentsOf: Self.fixtureURL, options: .alwaysMapped)
        let fixture = try PhotonsExtensions.SourceDNG(data: fixtureData)
        let norm = try Normalization(doc: fixture)
        let layout = PackedLayout(cfa: "rggb")
        let width = plane * 2, height = plane * 2

        func mosaic(_ planes: [[Double]]) -> [UInt16] {
            var samples = [UInt16](repeating: 0, count: width * height)
            for (p, (dy, dx)) in layout.offsets.enumerated() {
                let planeW = (width - dx + 1) / 2
                let planeH = (height - dy + 1) / 2
                for r in 0..<planeH {
                    for c in 0..<planeW {
                        let value = planes[p][r * planeW + c]
                        samples[(dy + 2 * r) * width + dx + 2 * c] =
                            norm.denormalize(value, row: dy + 2 * r, col: dx + 2 * c)
                    }
                }
            }
            return samples
        }

        try? FileManager.default.removeItem(at: sourceURL)
        try? FileManager.default.removeItem(at: productURL)
        _ = try PhotonsExtensions.DNGRawWriter.write(samples: mosaic(sourcePlanes), width: width, height: height,
                                   from: Self.fixtureURL, to: sourceURL)
        _ = try PhotonsExtensions.DNGRawWriter.write(samples: mosaic(productPlanes), width: width, height: height,
                                   from: sourceURL, to: productURL)
    }

    private func readPlane(url: URL, plane: Int, offsetIndex: Int) throws -> [Double] {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        let doc = try PhotonsExtensions.SourceDNG(data: data)
        let mosaic = try doc.readMosaic(data: data)
        let norm = try Normalization(doc: doc)
        let layout = PackedLayout(cfa: try cfaString(doc))
        let (dy, dx) = layout.offsets[offsetIndex]
        let planeW = (mosaic.width - dx + 1) / 2
        let planeH = (mosaic.height - dy + 1) / 2
        var out = [Double](repeating: 0, count: planeW * planeH)
        for r in 0..<planeH {
            for c in 0..<planeW {
                out[r * planeW + c] = norm.normalize(mosaic.samples[(dy + 2 * r) * mosaic.width + dx + 2 * c],
                                                     row: dy + 2 * r, col: dx + 2 * c)
            }
        }
        return out
    }

    private func cfaString(_ doc: PhotonsExtensions.SourceDNG) throws -> String {
        let entry = doc.raw[33422] ?? doc.ifd0[33422]
        let values = (entry?.numericValues ?? []).map { Int($0.rounded()) }
        let letters: [Character] = values.map {
            switch $0 {
            case 0: return "r"
            case 1: return "g"
            case 2: return "b"
            default: return "?"
            }
        }
        return String(letters)
    }

    // MARK: - 度量

    private func lineStats(_ values: [Double], width: Int, height: Int,
                           f: Double, theta: Double) -> (amp: Double, broad: Double) {
        // 常数项必须先从数据里减掉：512 不是 3.4 px 的整数倍，0.5 的底噪会漏进
        // 未建模的 DC 方向；竖线（θ=90°）时这个泄漏能大到把幅度算成 2×。
        let mean = values.reduce(0, +) / Double(values.count)
        let cosT = cos(theta), sinT = sin(theta)
        var vc = 0.0, vs = 0.0, cc = 0.0, ss = 0.0, cs = 0.0
        for y in 0..<height {
            for x in 0..<width {
                let phase = 2 * Double.pi * f * (Double(x) * cosT + Double(y) * sinT)
                let c = cos(phase), s = sin(phase)
                let v = values[y * width + x] - mean
                vc += v * c
                vs += v * s
                cc += c * c
                ss += s * s
                cs += c * s
            }
        }
        let det = cc * ss - cs * cs
        guard abs(det) > 1e-12 else { return (0, 0) }
        let a = (vc * ss - vs * cs) / det
        let b = (vs * cc - vc * cs) / det
        var energy = 0.0
        for y in 0..<height {
            for x in 0..<width {
                let phase = 2 * Double.pi * f * (Double(x) * cosT + Double(y) * sinT)
                let fitted = a * cos(phase) + b * sin(phase)
                let d = values[y * width + x] - mean - fitted
                energy += d * d
            }
        }
        return ((a * a + b * b).squareRoot(), (energy / Double(values.count)).squareRoot())
    }

    private func tukey(x: Int, y: Int, side: Int, inset: Int, ramp: Int) -> Double {
        func edge(_ p: Int) -> Double {
            if p < inset || p >= side - inset { return 0 }
            if p < inset + ramp {
                return 0.5 - 0.5 * cos(Double.pi * Double(p - inset) / Double(ramp))
            }
            if p >= side - inset - ramp {
                return 0.5 + 0.5 * cos(Double.pi * Double(p - (side - inset - ramp)) / Double(ramp))
            }
            return 1
        }
        return edge(x) * edge(y)
    }

    private func envelopeZero(x: Int, y: Int, side: Int, inset: Int, ramp: Int) -> Bool {
        x < inset || y < inset || x >= side - inset || y >= side - inset
    }
}

// MARK: - 确定性 RNG

private struct SplitMix64 {
    var state: UInt64
    private var spare: Double?

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    mutating func uniform() -> Double {
        Double(next() >> 11) * (1.0 / 9007199254740992.0)
    }

    mutating func gaussian() -> Double {
        if let spare {
            self.spare = nil
            return spare
        }
        var u = uniform()
        while u <= 1e-12 { u = uniform() }
        let v = uniform()
        let r = (-2 * log(u)).squareRoot()
        let angle = 2 * Double.pi * v
        spare = r * sin(angle)
        return r * cos(angle)
    }
}
