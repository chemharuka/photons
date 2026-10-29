import XCTest
import AppKit
import Metal
import PhotonsCore
@testable import PhotonsUI

/// 143b — the preview must **be** the settled frame, not a display-domain approximation of it.
///
/// The old 118/143 drag multiplied the frame already on the canvas by a gain in the present pass,
/// while release rendered through S1…S4. Two domains, two answers: about 37 codes apart on the
/// sample this task was filed against. These tests pin the replacement:
///
///   1. a drag tick renders the resident scene-linear buffer through the normal `RenderGraph`, so
///      preview and settled frames agree to ≤ 1 code and use the same S1 gain triple;
///   2. the preview's trace really executed the render stages (S1 and the tone map among them) and
///      matches the settled frame's stage list — no silent "multiply the old present";
///   3. a drag stays inside p50 ≤ 8 ms / p95 ≤ 16 ms at the 0.25 rung (≈ 4.1 Mpx).
///
/// The fixtures are the user's own files; the suite skips when they are absent.
@MainActor
final class WhiteBalancePreviewParityTests: XCTestCase {

    private struct Sample {
        let name: String
        let path: String
    }

    private static let samples = [
        Sample(name: "L1030433", path: "~/Desktop/test/L1030433.dng"),
        Sample(name: "L1030437", path: "~/Desktop/test/L1030437.dng"),
        Sample(name: "DJI_air3_2250_D", path: "~/Desktop/US/DJI_air3_2250_D.dng"),
    ]

    private static let pairs: [(Double, Double)] = [(6500, 0), (7500, 10), (5000, -10)]
    private static let viewport = ImageSize(width: 800, height: 600)
    private static let decodeScale: Float = 0.125

    private func fixtures() throws -> [(Sample, URL)] {
        var found: [(Sample, URL)] = []
        for sample in Self.samples {
            let path = NSString(string: sample.path).expandingTildeInPath
            guard FileManager.default.isReadableFile(atPath: path) else {
                throw XCTSkip("missing fixture \(sample.path)")
            }
            found.append((sample, URL(fileURLWithPath: path)))
        }
        return found
    }

    private func makeLoupe() -> LoupeController {
        let loupe = LoupeController(session: CatalogSession())
        loupe.autoRenderEnabled = false
        _ = loupe.view
        loupe.canvasView.frame = NSRect(x: 0, y: 0,
                                        width: Self.viewport.width / 2,
                                        height: Self.viewport.height / 2)
        return loupe
    }

    private func develop(_ loupe: LoupeController, _ url: URL, _ edit: EditModel,
                         viewport: ImageSize, scale: Float,
                         useCache: Bool = true) throws -> LoupeController.FrameResult {
        try loupe.makeFrame(url: url, viewport: viewport, decodeScale: scale,
                            edit: edit, hashPixels: false, useCache: useCache)
    }

    private func settledEdit(_ edit: EditModel, _ pair: (Double, Double)) -> EditModel {
        var out = edit
        let target = WhiteBalance(temperature: pair.0, tint: pair.1).clamped()
        out.light.temperature = target.temperature
        out.light.tint = target.tint
        return out
    }

    // MARK: - 1. preview == settled frame, ≤ 1 code, same gain triple

    func testPreviewEqualsSettledFrame() throws {
        let fixtures = try fixtures()
        var worst = 0
        for (sample, url) in fixtures {
            let session = CatalogSession()
            let loupe = makeLoupe()
            _ = try develop(loupe, url, session.edit, viewport: Self.viewport, scale: Self.decodeScale)

            for pair in Self.pairs {
                let target = WhiteBalance(temperature: pair.0, tint: pair.1).clamped()
                let preview = try loupe.renderWhiteBalancePreview(target,
                                                                 viewport: Self.viewport)
                let settled = try develop(loupe, url, settledEdit(session.edit, pair),
                                           viewport: Self.viewport, scale: Self.decodeScale)

                XCTAssertEqual(preview.whiteBalanceGain, settled.whiteBalanceGain,
                               "\(sample.name) \(pair): preview and settled used different S1 "
                               + "gains — preview \(preview.whiteBalanceGain), "
                               + "settled \(settled.whiteBalanceGain)")
                let delta = Self.maxCodeDelta(preview.texture, settled.texture)
                worst = max(worst, delta)
                XCTAssertLessThanOrEqual(delta, 1,
                    "\(sample.name) \(pair): preview and settled differ by \(delta) codes "
                    + "(mean \(String(format: "%.2f", Self.meanCodeDelta(preview.texture, settled.texture)))"
                    + ") — the drag is not the frame that follows it")
                print(String(format: "WB parity %@ (%@): max|Δ| %d code · mean|Δ| %.3f · "
                             + "gain [%.9f %.9f %.9f]",
                             sample.name, WhiteBalance(temperature: pair.0, tint: pair.1).summary,
                             delta, Self.meanCodeDelta(preview.texture, settled.texture),
                             preview.whiteBalanceGain.x, preview.whiteBalanceGain.y,
                             preview.whiteBalanceGain.z))
            }
        }
        print("WB parity: 3 samples × 3 pairs · worst max|Δ| \(worst) code (budget 1)")
        XCTAssertLessThanOrEqual(worst, 1)
    }

    // MARK: - 2. the preview really re-runs S1…S4

    func testPreviewReRunsTheRenderGraph() throws {
        let fixtures = try fixtures()
        for (sample, url) in fixtures {
            let session = CatalogSession()
            let loupe = makeLoupe()
            _ = try develop(loupe, url, session.edit, viewport: Self.viewport, scale: Self.decodeScale)
            let pair = Self.pairs[1]
            let target = WhiteBalance(temperature: pair.0, tint: pair.1).clamped()
            let preview = try loupe.renderWhiteBalancePreview(target,
                                                             viewport: Self.viewport)
            let settled = try develop(loupe, url, settledEdit(session.edit, pair),
                                      viewport: Self.viewport, scale: Self.decodeScale,
                                      useCache: false)

            XCTAssertFalse(preview.trace.executed.isEmpty,
                           "\(sample.name): the preview executed no stages — it is not a render")
            XCTAssertTrue(preview.trace.executed.contains(.sceneLinear),
                          "\(sample.name): the preview did not run S1")
            XCTAssertTrue(preview.trace.executed.contains(.toneMap),
                          "\(sample.name): the preview did not run the tone map")
            XCTAssertEqual(preview.trace.executed, settled.trace.executed,
                           "\(sample.name): preview stages \(preview.trace.csv) ≠ settled "
                           + "\(settled.trace.csv)")
            print("WB preview stages \(sample.name): \(preview.trace.csv)")
        }
    }

    // MARK: - 3. drag latency at the 0.25 rung (≈ 4.1 Mpx)

    func testDragLatency() throws {
        guard let sample = Self.samples.first else { throw XCTSkip("no samples") }
        let url = URL(fileURLWithPath: NSString(string: sample.path).expandingTildeInPath)
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw XCTSkip("missing fixture \(sample.path)")
        }

        // The 0.25 rung of a 60.3 Mpx frame is 2380 × 1584 ≈ 3.77 Mpx (the task calls it 4.1 Mpx).
        let scale: Float = 0.25
        let full = ImageSize(width: Int((9520.0 * 0.25).rounded()),
                             height: Int((6336.0 * 0.25).rounded()))
        let session = CatalogSession()
        let loupe = makeLoupe()
        loupe.canvasView.frame = NSRect(x: 0, y: 0,
                                        width: full.width / 2, height: full.height / 2)
        _ = try develop(loupe, url, session.edit, viewport: full, scale: scale)

        loupe.beginWhiteBalancePreview()
        loupe.resetWhiteBalancePreviewLatencies()
        let deadline = Date().addingTimeInterval(120)
        for tick in 1...200 {
            // Every tick is a new pair: S1 must miss on each one. A repeated Kelvin would be a cache
            // hit and would measure the cache, not the drag.
            let kelvin = 3000 + Double(tick) * 30
            let tint = Double(tick % 21) - 10
            loupe.updateWhiteBalancePreview(temperature: kelvin, tint: tint)
            while loupe.isRenderingWhiteBalancePreview, Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.002))
            }
        }

        let p = loupe.whiteBalancePreviewLatencyPercentiles()
        XCTAssertEqual(p.count, 200, "200 drags must produce 200 measured frames")
        XCTAssertLessThanOrEqual(p.p50, 8, "drag p50 \(p.p50) ms exceeds 8 ms")
        XCTAssertLessThanOrEqual(p.p95, 16, "drag p95 \(p.p95) ms exceeds 16 ms")

        let preview = try loupe.renderWhiteBalancePreview(
            WhiteBalance(temperature: 6500, tint: 0), viewport: full)
        print(String(format: "WB drag latency %.2f Mpx: p50 %.2f ms · p95 %.2f ms · n %d",
                     Double(full.width * full.height) / 1e6, p.p50, p.p95, p.count))
        print("WB drag executed: \(preview.trace.executed.map(\.rawValue).joined(separator: " "))")
    }

    // MARK: - pixel maths

    /// 8-bit display codes, the budget the task states. The frame texture stores display-encoded
    /// light, so an 8-bit rendering is `round(clamp(v, 0, 1) · 255)`.
    private static func code(_ texture: MTLTexture) -> [UInt8] {
        let w = texture.width, h = texture.height
        var raw = [UInt16](repeating: 0, count: w * h * 4)
        raw.withUnsafeMutableBytes { buf in
            texture.getBytes(buf.baseAddress!, bytesPerRow: w * 4 * MemoryLayout<UInt16>.size,
                             from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        }
        var out = [UInt8](repeating: 0, count: w * h * 3)
        for i in 0..<(w * h) {
            for c in 0..<3 {
                let v = Double(Float(Float16(bitPattern: raw[i * 4 + c])))
                out[i * 3 + c] = UInt8(min(max((v * 255).rounded(), 0), 255))
            }
        }
        return out
    }

    private static func maxCodeDelta(_ a: MTLTexture, _ b: MTLTexture) -> Int {
        XCTAssertEqual(a.width, b.width)
        XCTAssertEqual(a.height, b.height)
        let ca = code(a), cb = code(b)
        var worst = 0
        for i in 0..<min(ca.count, cb.count) {
            worst = max(worst, abs(Int(ca[i]) - Int(cb[i])))
        }
        return worst
    }

    private static func meanCodeDelta(_ a: MTLTexture, _ b: MTLTexture) -> Double {
        let ca = code(a), cb = code(b)
        guard !ca.isEmpty else { return 0 }
        var sum = 0
        for i in 0..<min(ca.count, cb.count) { sum += abs(Int(ca[i]) - Int(cb[i])) }
        return Double(sum) / Double(min(ca.count, cb.count))
    }
}
