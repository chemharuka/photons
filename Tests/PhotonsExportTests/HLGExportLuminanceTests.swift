import XCTest
import CoreGraphics
import CoreImage
import ImageIO
import PhotonsCore
@testable import PhotonsExport

/// 227 — an HLG export must land on the **same absolute luminance** as the PQ export of the same
/// linear frame, in every container and in every primaries family.
///
/// The measurement never tone maps: the file is read back as raw codes in **its own** colour space
/// and each code is decoded with its own curve.
///
///   · PQ  — `nits = 10000 · EOTF_ST2084(code)` (absolute by definition).
///   · HLG — `scene = invOETF_ARIB(code)`, `nits = 1000 · scene^1.2` (BT.2100 OOTF, 1000-nit
///     reference display). SDR white is 203 nits, so linear 1.0 is signal ≈0.75 and the curve
///     saturates at 1000 nits = 4.926× (+2.303 EV). That ceiling is BT.2100/Apple behaviour, not a
///     bug; above it HLG stays at 1.0 while PQ keeps climbing.
final class HLGExportLuminanceTests: XCTestCase {

    // MARK: - curves (measurement only; production constants live in HDREncoding.HLGCurve)

    private func pqNits(_ e: Double) -> Double {
        let m1 = 0.1593017578125, m2 = 78.84375
        let c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875
        let p = pow(e, 1.0 / m2)
        let num = max(p - c1, 0)
        let den = c2 - c3 * p
        guard den > 0 else { return .infinity }
        return 10000.0 * pow(num / den, 1.0 / m1)
    }

    private func hlgSceneLinear(_ e: Double) -> Double {
        let a = 0.17883277, b = 0.28466892, c = 0.55991073
        if e <= 0.5 { return e * e / 3.0 }
        return (exp((e - c) / a) + b) / 12.0
    }

    private func hlgNits(_ e: Double) -> Double {
        1000.0 * pow(max(hlgSceneLinear(e), 0), 1.2)
    }

    // MARK: - ramp

    /// 15 neutral-grey steps from 2^-6 to ≈2^+2.32 (the last two sit above HLG's 4.926× ceiling).
    /// Each step is a 32×32 flat block so a lossy container can be sampled without codec ringing.
    static let steps = 15
    static let block = 32

    private func linearValue(_ step: Int) -> Double {
        pow(2.0, -6.0 + 8.32 * Double(step) / Double(Self.steps - 1))
    }

    private func ramp(primaries: OutputPrimaries) -> DisplayImage {
        let w = Self.steps * Self.block, h = Self.block
        var display = [Float16](repeating: 1, count: w * h * 4)
        var linear = [Float16](repeating: 1, count: w * h * 4)
        for x in 0..<w {
            let v = Float16(linearValue(x / Self.block))
            for y in 0..<h {
                let o = (y * w + x) * 4
                display[o] = v; display[o + 1] = v; display[o + 2] = v; display[o + 3] = 1
                linear[o] = v; linear[o + 1] = v; linear[o + 2] = v; linear[o + 3] = 1
            }
        }
        let base = DisplayImage(width: w, height: h, rgba: display, primaries: primaries, bitDepth: 8)
        return base.withLinear(LinearPixels(width: w, height: h, rgba: linear, primaries: primaries))
    }

    // MARK: - export / read back

    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hlg-luminance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func export(_ image: DisplayImage, format: ExportFormat, kind: HDRKind,
                        primaries: OutputPrimaries, to url: URL,
                        referenceWhite: Double? = nil) throws {
        if let referenceWhite {
            // Reverse-gate path: build the same 16-bit HLG file, but with an injected (wrong)
            // reference white. No production default is touched.
            try writeHLG(image, to: url, primaries: primaries, referenceWhite: referenceWhite)
            return
        }
        // The application's surface: a validated preset, then `preset.exportOptions`.
        var preset = ExportPreset(format: format, quality: 1.0,
                                  bitDepth: format.supports16Bit ? 16 : 10,
                                  colorSpace: primaries, hdrKind: kind)
        preset = try preset.validated()
        XCTAssertEqual(preset.effectiveBitDepth, format.hdrTransferBitDepth(for: kind))
        try Exporter.write(image, to: url, options: preset.exportOptions,
                           metadata: ExportMetadataContext(level: .none))
    }

    /// A PQ/HLG PNG written outside `HDREncoding` — used only by the reverse gate.
    private func writeHLG(_ image: DisplayImage, to url: URL, primaries: OutputPrimaries,
                          referenceWhite: Double) throws {
        let linear = try XCTUnwrap(image.linear)
        let w = linear.width, h = linear.height
        var words = [UInt16](repeating: 0, count: w * h * 4)
        for i in stride(from: 0, to: words.count, by: 4) {
            for c in 0..<3 {
                let s = HDREncoding.HLGCurve.signal(
                    forLinear: Double(Float(linear.rgba[i + c])), referenceWhite: referenceWhite)
                words[i + c] = UInt16(min(max((s * 65535.0).rounded(), 0), 65535))
            }
            words[i + 3] = UInt16((Double(min(max(Float(linear.rgba[i + 3]), 0), 1)) * 65535.0).rounded())
        }
        let space = try XCTUnwrap(HDREncoding.targetColorSpace(for: primaries, kind: .hlg))
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                                | CGBitmapInfo.byteOrder16Little.rawValue)
        let provider = try XCTUnwrap(CGDataProvider(
            data: Data(words.withUnsafeBufferPointer { Data(buffer: $0) }) as CFData))
        let cg = try XCTUnwrap(CGImage(width: w, height: h, bitsPerComponent: 16, bitsPerPixel: 64,
                                       bytesPerRow: w * 8, space: space, bitmapInfo: info,
                                       provider: provider, decode: nil, shouldInterpolate: false,
                                       intent: .defaultIntent))
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, ExportFormat.png.utType.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, cg, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }

    /// Raw 16-bit codes, drawn in the file's own colour space (identity — no colour management).
    private func codes(_ url: URL) throws -> (w: Int, h: Int, space: String, buf: [UInt16]) {
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let cg = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
        let cs = try XCTUnwrap(cg.colorSpace, "no colour space in \(url.lastPathComponent)")
        let w = cg.width, h = cg.height
        var buf = [UInt16](repeating: 0, count: w * h * 4)
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrder16Little.rawValue
        try buf.withUnsafeMutableBytes { raw in
            let ctx = try XCTUnwrap(CGContext(data: raw.baseAddress, width: w, height: h,
                                              bitsPerComponent: 16, bytesPerRow: w * 8,
                                              space: cs, bitmapInfo: info))
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return (w, h, cs.name as String? ?? "?", buf)
    }

    /// Median of the block's interior (lossy containers only; flat blocks make this safe).
    private func sample(_ c: (w: Int, h: Int, space: String, buf: [UInt16]), step: Int) -> Double {
        var values: [Double] = []
        for y in 4..<(Self.block - 4) {
            for x in (step * Self.block + 4)..<((step + 1) * Self.block - 4) {
                values.append(Double(c.buf[(y * c.w + x) * 4]) / 65535.0)
            }
        }
        values.sort()
        return values[values.count / 2]
    }

    /// The single pixel of a 1×1 anchor file.
    private func firstPixel(_ c: (w: Int, h: Int, space: String, buf: [UInt16])) -> Double {
        Double(c.buf[0]) / 65535.0
    }

    private let cases: [(ExportFormat, OutputPrimaries)] = [
        (.png, .sRGB), (.png, .displayP3), (.png, .rec2020),
        (.tiff, .sRGB), (.tiff, .displayP3), (.tiff, .rec2020),
        (.heic, .sRGB), (.heic, .displayP3), (.heic, .rec2020),
        (.avif, .sRGB), (.avif, .displayP3), (.avif, .rec2020),
    ]

    // MARK: - 1. parity across containers and primaries

    func testEveryContainerCarriesTheSameAbsoluteLuminanceAsPQ() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }

        for (format, primaries) in cases {
            let image = ramp(primaries: primaries)
            let name = "\(format.rawValue)-\(primaries.rawValue)"
            let pqURL = dir.appendingPathComponent("pq-\(name).\(format.fileExtension)")
            let hlgURL = dir.appendingPathComponent("hlg-\(name).\(format.fileExtension)")
            try export(image, format: format, kind: .pq, primaries: primaries, to: pqURL)
            try export(image, format: format, kind: .hlg, primaries: primaries, to: hlgURL)

            let pq = try codes(pqURL)
            let hlg = try codes(hlgURL)
            // AVIF is a 10-bit **lossy** AV1 item: a 1-code error is ~4 codes in PQ signal at the
            // dark end, where the PQ curve is steepest. Measured worst case on this OS is 4%.

            // ±2 has to cover AVIF's 10-bit lossy quantiser; the 4.9× reference-white bug is
            // nowhere near this window, so the gate is still decisive. Every lossless/HEVC row
            // is measured at ≤0.6%.
            let tolerance = format == .avif ? 0.05 : 0.02
            for step in 0..<Self.steps where linearValue(step) <= 4.926 {
                let linear = linearValue(step)
                let pqN = pqNits(sample(pq, step: step))
                let hlgN = hlgNits(sample(hlg, step: step))
                let want = linear * 203.0
                XCTAssertGreaterThan(pqN, 0, "\(name) step \(step): PQ decoded to 0")
                XCTAssertEqual(hlgN / pqN, 1.0, accuracy: tolerance,
                               String(format: "%@ step %d (linear %.4f): HLG %.1f nits vs PQ %.1f nits",
                                      name, step, linear, hlgN, pqN))
                // Above the two darkest steps a 10-bit code is small enough to anchor each curve
                // separately, so "both wrong by the same factor" cannot pass either.
                if linear >= 0.05 {
                    XCTAssertEqual(hlgN, want, accuracy: want * 0.02,
                                   String(format: "%@ step %d: HLG %.1f nits, want %.1f",
                                          name, step, hlgN, want))
                    XCTAssertEqual(pqN, want, accuracy: want * tolerance,
                                   String(format: "%@ step %d: PQ %.1f nits, want %.1f",
                                          name, step, pqN, want))
                }
            }
        }
    }

    // MARK: - 2. absolute anchors (stops "both wrong by the same factor" from passing)

    func testSDRWhiteSitsAt203NitsInBothFiles() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }

        // linear 1.0 is SDR white. The 15-step ramp's 11th value is 0.9612×, which is the row the
        // probe table calls out (195 nits / signal 0.743); both are asserted so the anchor is
        // unambiguous.
        for (linear, wantPQ, wantHLG) in [(1.0, 203.0, 0.750), (0.9612, 195.1, 0.7433)] {
            let w = 1, h = 1
            var display = [Float16](repeating: 1, count: 4)
            var pixels = [Float16](repeating: 1, count: 4)
            for c in 0..<3 { display[c] = Float16(min(linear, 1)); pixels[c] = Float16(linear) }
            let base = DisplayImage(width: w, height: h, rgba: display,
                                    primaries: .displayP3, bitDepth: 8)
            let image = base.withLinear(LinearPixels(width: w, height: h, rgba: pixels,
                                                     primaries: .displayP3))
            let pqURL = dir.appendingPathComponent("white-pq-\(linear).png")
            let hlgURL = dir.appendingPathComponent("white-hlg-\(linear).png")
            try export(image, format: .png, kind: .pq, primaries: .displayP3, to: pqURL)
            try export(image, format: .png, kind: .hlg, primaries: .displayP3, to: hlgURL)
            let pqSig = firstPixel(try codes(pqURL))
            let hlgSig = firstPixel(try codes(hlgURL))
            XCTAssertEqual(pqNits(pqSig), wantPQ, accuracy: 2.0,
                           "linear \(linear): PQ SDR white")
            XCTAssertEqual(hlgSig, wantHLG, accuracy: 0.01,
                           "linear \(linear): HLG SDR white signal")
            XCTAssertEqual(hlgNits(hlgSig), wantPQ, accuracy: 2.0,
                           "linear \(linear): HLG SDR white in nits")
        }
    }

    // MARK: - 3. the HLG ceiling is inherent, not a clip bug

    func testHLGStopsAt1000NitsWhilePQKeepsRising() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }

        // 4.926× is the HLG top; 8.0 is a full stop above it.
        let values = [4.926, 8.0]
        var hlgSignals: [Double] = []
        for (index, linear) in values.enumerated() {
            let w = 1, h = 1
            var pixels = [Float16](repeating: 1, count: 4)
            for c in 0..<3 { pixels[c] = Float16(linear) }
            let base = DisplayImage(width: w, height: h, rgba: [1, 1, 1, 1],
                                    primaries: .displayP3, bitDepth: 8)
            let image = base.withLinear(LinearPixels(width: w, height: h, rgba: pixels,
                                                     primaries: .displayP3))
            let pqURL = dir.appendingPathComponent("cap-pq-\(index).png")
            let hlgURL = dir.appendingPathComponent("cap-hlg-\(index).png")
            try export(image, format: .png, kind: .pq, primaries: .displayP3, to: pqURL)
            try export(image, format: .png, kind: .hlg, primaries: .displayP3, to: hlgURL)
            let pqN = pqNits(firstPixel(try codes(pqURL)))
            let hlgSig = firstPixel(try codes(hlgURL))
            hlgSignals.append(hlgSig)
            XCTAssertEqual(hlgSig, 1.0, accuracy: 1.0 / 65535.0 * 2,
                           "HLG must be at full signal at \(linear)×")
            if index == 0 { XCTAssertEqual(pqN, 1000.0, accuracy: 2.0) }
            else { XCTAssertGreaterThan(pqN, 1500.0, "PQ must not clamp at the HLG ceiling") }
        }
        XCTAssertEqual(hlgSignals[0], hlgSignals[1], accuracy: 1.0 / 65535.0 * 2,
                       "HLG above its ceiling must stay flat, not keep rising")
    }

    // MARK: - 4. reverse gate: 1000-nit white is not 203-nit white

    /// The gate the green rows rely on: encode the same ramp with `referenceWhite = 1000` (the
    /// "less 203/1000" mistake) and the parity assertion must fail by ≈4.926×.
    func testReferenceWhiteOf1000NitsFailsTheParityGate() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }

        let image = ramp(primaries: .displayP3)
        let pqURL = dir.appendingPathComponent("gate-pq.png")
        let wrongURL = dir.appendingPathComponent("gate-hlg-wrong.png")
        try export(image, format: .png, kind: .pq, primaries: .displayP3, to: pqURL)
        try export(image, format: .png, kind: .hlg, primaries: .displayP3, to: wrongURL,
                   referenceWhite: 1000.0)

        let pq = try codes(pqURL)
        let wrong = try codes(wrongURL)
        // Step 6 (linear 0.185, ≈37.6 nits) is comfortably inside the unclipped range.
        let pqN = pqNits(sample(pq, step: 6))
        let wrongN = hlgNits(sample(wrong, step: 6))
        let ratio = wrongN / pqN
        XCTAssertEqual(ratio, 4.926, accuracy: 0.15,
                       "a 1000-nit reference white must be ~4.9× too bright")
        // This is the assertion the green suite makes; it must be false for the wrong file.
        XCTAssertFalse(abs(ratio - 1.0) <= 0.02,
                       "the parity gate would have accepted a 1000-nit white")
    }
}
