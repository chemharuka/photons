import XCTest
@testable import PhotonsCore
import CryptoKit
import Metal

/// 029 — lateral chromatic aberration, engine side (paths A/B/C of §4.2).
///
/// What this file pins, in the order the task states them:
///
///   · the uniform block the Swift side writes is the one the `.metal` side reads (7 × float4 = 112);
///   · α = 0 is byte-identical to the pre-029 graph — the hashes below were recorded **before** the
///     CA code existed, so they are evidence, not a self-fulfilling recording;
///   · the pure-CA path is the identity copy with red and blue resampled: green's channel hash is
///     unchanged, pixel for pixel, and the centre of the frame is untouched;
///   · a red/blue edge moves by exactly α · radius, measured sub-pixel;
///   · the general path (CA on top of a crop) keeps green too — it samples the *same* `px` the CA-off
///     frame samples;
///   · the key only grows when α ≠ 0, and a change of α misses S0 and everything below it.
///
/// Millisecond numbers are printed on every run and asserted only under `PHOTONS_BENCH=1`, the same
/// rule the other frame-budget tests follow.
final class ChromaticAberrationTests: XCTestCase {

    // MARK: - fixtures

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)          // Tests/PhotonsCoreTests/ChromaticAberrationTests.swift
            .deletingLastPathComponent()         // Tests/PhotonsCoreTests
            .deletingLastPathComponent()         // Tests
            .deletingLastPathComponent()         // repo root
    }

    private var benchmarks: Bool { ProcessInfo.processInfo.environment["PHOTONS_BENCH"] == "1" }

    /// The pixels these frames had **before** 029 (recorded on the unmodified tree). If either moves,
    /// the CA work changed a document that has CA switched off — the one thing it must not do.
    private enum Pristine {
        static let ramp2731 = "9adb04036e39411e9b5e2dae41f3cbe0626a996faa86b3df2de7908a158d0a37"
        static let ramp2731Green = "0d3480ca2bc7954c944224f5342f7f07d55c667e38c591efd888de17bc3e9a70"
        static let ramp1201 = "0a1d9cbf39b5e8dc0dd7df95ee2a4af17cd0913c7ba629f342b526540f9b6459"
        static let ramp1201Green = "1e0dab44b68b21e03028a7aefd9bfa78c6dfa54360fc073cfe9a7c25a7a95b16"
    }

    /// A smooth, non-repeating gradient. A radial rescale changes red and blue everywhere on it, so
    /// "only R/B moved" is a meaningful statement rather than an artefact of a flat region.
    private func rampImage(width: Int, height: Int) -> LinearImage {
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let o = (y * width + x) * 4
                let v = Float(0.08 + 0.60 * Double(x) / Double(max(width - 1, 1)))
                rgba[o] = Float16(v)
                rgba[o + 1] = Float16(v * 0.94)
                rgba[o + 2] = Float16(v * 0.87)
                rgba[o + 3] = 1
            }
        }
        return LinearImage(width: width, height: height, rgba: rgba,
                           colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic")
    }

    /// A hard vertical edge at `edgeX` in all three channels: the frame whose corner displacement can
    /// be measured to a fraction of a pixel.
    private func stepImage(width: Int, height: Int, edgeX: Int) -> LinearImage {
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let o = (y * width + x) * 4
                let v: Float = x >= edgeX ? 1 : 0
                rgba[o] = Float16(v)
                rgba[o + 1] = Float16(v)
                rgba[o + 2] = Float16(v)
                rgba[o + 3] = 1
            }
        }
        return LinearImage(width: width, height: height, rgba: rgba,
                           colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic")
    }

    private func flatImage(_ value: Float, width: Int, height: Int) -> LinearImage {
        var rgba = [Float16](repeating: Float16(value), count: width * height * 4)
        for i in stride(from: 3, to: rgba.count, by: 4) { rgba[i] = 1 }
        return LinearImage(width: width, height: height, rgba: rgba,
                           colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic")
    }

    private func graph(_ image: LinearImage) throws -> RenderGraph {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        return try RenderGraph(input: RenderInput(image: image, identity: "ca-\(image.width)x\(image.height)"))
    }

    private func render(_ graph: RenderGraph, _ edit: EditModel) throws -> DisplayImage {
        let result = try graph.render(edit, options: RenderOptions(scale: 1, useCache: false,
                                                                  wantsPixels: true))
        return try XCTUnwrap(result.display)
    }

    private func ca(_ red: Double, _ blue: Double) -> EditModel {
        var edit = EditModel.neutral
        edit.optics.caRed = red
        edit.optics.caBlue = blue
        return edit
    }

    // MARK: - the two sides of the uniform

    /// The Swift mirror and the `.metal` struct must be the same bytes. A mismatch does not throw —
    /// it reads the wrong uniform — so the number is asserted on both sides, and the `.metal` file is
    /// parsed rather than trusted.
    func testS0ParamsIsSevenFloat4OnBothSides() throws {
        XCTAssertEqual(MemoryLayout<S0Params>.stride, 112, "S0Params must stay 7 × float4 (was 96)")
        XCTAssertEqual(MemoryLayout<S0Params>.size, 112)
        XCTAssertEqual(MemoryLayout<S0Params>.alignment, 16)
        XCTAssertEqual(MemoryLayout<S0Params>.stride / MemoryLayout<SIMD4<Float>>.stride, 7)
        // Field offsets, in the order the `.metal` struct declares them: `g` (the CA ratios) last.
        XCTAssertEqual(MemoryLayout<S0Params>.offset(of: \.a), 0)
        XCTAssertEqual(MemoryLayout<S0Params>.offset(of: \.b), 16)
        XCTAssertEqual(MemoryLayout<S0Params>.offset(of: \.c), 32)
        XCTAssertEqual(MemoryLayout<S0Params>.offset(of: \.d), 48)
        XCTAssertEqual(MemoryLayout<S0Params>.offset(of: \.e), 64)
        XCTAssertEqual(MemoryLayout<S0Params>.offset(of: \.f), 80)
        XCTAssertEqual(MemoryLayout<S0Params>.offset(of: \.g), 96)

        let url = Self.repoRoot.appendingPathComponent("Sources/PhotonsCore/Kernels/s0_geometry.metal")
        let source = try String(contentsOf: url, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "struct S0Params {"))
        let end = try XCTUnwrap(source.range(of: "};", range: start.upperBound..<source.endIndex))
        let block = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertEqual(block.components(separatedBy: "float4").count - 1, 7,
                       "the kernel struct must declare 7 float4 fields:\n\(block)")
        XCTAssertTrue(block.contains("float4 g;"), "the CA field is missing from the kernel")
        XCTAssertTrue(block.contains("pureCA"), "e.z must be documented as pureCA in the kernel")
        XCTAssertTrue(source.contains("112"), "the kernel must state the shared stride (112 = 7 × 16)")
    }

    // MARK: - α = 0 changes nothing

    /// Path A: with both sliders at zero the frame is the pre-029 frame, byte for byte, and the
    /// geometry key is the pre-029 key.
    func testZeroCALeavesPixelsAndKeysByteExact() throws {
        let sizes = [(2731, 1501, Pristine.ramp2731, Pristine.ramp2731Green),
                     (1201, 1201, Pristine.ramp1201, Pristine.ramp1201Green)]
        for (w, h, allHash, expectedGreen) in sizes {
            let g = try graph(rampImage(width: w, height: h))
            let px = try render(g, EditModel.neutral)
            XCTAssertEqual(px.sha256(), allHash, "\(w)x\(h): a CA-off document moved")
            XCTAssertEqual(greenHash(px), expectedGreen, "\(w)x\(h): green moved")
        }

        // The key: the pre-029 material, comma for comma, then the two conditional tokens.
        //
        // `pv=2` since 派单 030 (the curve moved to S1.7 and changed the meaning of a document's
        // pixels, so the process version bumped). Nothing about this material's *shape* changed —
        // the version is the only token that moved.
        let neutral = EditModel.neutral
        let material = neutral.keyMaterial(.geometry)
        XCTAssertEqual(material, "pv=2;crop=0.00000,0.00000,1.00000,1.00000;rot=0.00000;flip=00")
        XCTAssertFalse(material.contains("car="))
        XCTAssertFalse(material.contains("cab="))

        var redOnly = neutral
        redOnly.optics.caRed = 0.002
        XCTAssertEqual(redOnly.keyMaterial(.geometry), material + ";car=0.00200")

        var both = redOnly
        both.optics.caBlue = -0.0015
        XCTAssertEqual(both.keyMaterial(.geometry), material + ";car=0.00200;cab=-0.00150")

        // Only non-zero is appended: setting a slider back to zero is the old document again.
        var backToZero = both
        backToZero.optics = .identity
        XCTAssertEqual(backToZero.keyMaterial(.geometry), material)
        XCTAssertEqual(both.changedStages(from: neutral), [.geometry])
        XCTAssertEqual(neutral.changedStages(from: neutral), [])
    }

    /// An older document has no `optics` key at all; it must read as "no correction" and keep the
    /// pre-029 key, which is why `schemaVersion` is not bumped.
    func testMissingOpticsDecodesToIdentityAndRoundTrips() throws {
        let json = Data(#"{ "light": { "exposure": 0.5 } }"#.utf8)
        let model = try JSONDecoder().decode(EditModel.self, from: json)
        XCTAssertEqual(model.optics, .identity)
        XCTAssertTrue(model.optics.isIdentity)
        XCTAssertEqual(model.schemaVersion, EditModel.currentSchemaVersion)
        XCTAssertEqual(model.keyMaterial(.geometry), EditModel.neutral.keyMaterial(.geometry))

        var edited = model
        edited.optics = OpticsGroup(caRed: 0.00125, caBlue: -0.0004)
        let back = try JSONDecoder().decode(EditModel.self, from: JSONEncoder().encode(edited))
        XCTAssertEqual(back, edited)
        XCTAssertEqual(OpticsGroup.fullScale, 0.005)
        XCTAssertEqual(edited.optics.cornerPixels(halfDiagonal: 1000), 1.25, accuracy: 1e-12)
    }

    // MARK: - path B: pure CA

    /// G3 — the whole point of the fast path. Green is a texel copy, so its channel hash is the one
    /// the CA-off frame had; red and blue are the only channels that move, and the frame's centre
    /// (the optical axis, where `px − center` is 0) does not move at all.
    func testPureCAPathKeepsGreenBitExact() throws {
        let sizes = [(2731, 1501, Pristine.ramp2731Green), (1201, 1201, Pristine.ramp1201Green)]
        for (w, h, green) in sizes {
            let g = try graph(rampImage(width: w, height: h))
            let off = try g.render(EditModel.neutral,
                                   options: RenderOptions(scale: 1, useCache: false, wantsPixels: true))
            let on = try g.render(ca(0.002, -0.0015),
                                  options: RenderOptions(scale: 1, useCache: false, wantsPixels: true))
            let offPx = try XCTUnwrap(off.display)
            let onPx = try XCTUnwrap(on.display)

            XCTAssertFalse(off.trace.s0PureCA, "α = 0 must stay the identity copy")
            XCTAssertTrue(on.trace.s0PureCA, "full frame + no rotation + α ≠ 0 must take the pure path")

            XCTAssertEqual(greenHash(onPx), greenHash(offPx), "\(w)x\(h): green changed")
            XCTAssertEqual(greenHash(onPx), green, "\(w)x\(h): green is no longer the pre-029 bytes")
            XCTAssertNotEqual(onPx.sha256(), offPx.sha256(), "\(w)x\(h): CA did nothing")

            // Only R and B: strip them and the frames are identical.
            XCTAssertNotEqual(redBlueHash(onPx), redBlueHash(offPx))

            // The centre pixel: zero radius, so R and B are the same sample as green's. Exactly one
            // pixel is at the axis (`srcSize * 0.5` lands on its centre for these odd sizes); its
            // neighbours are 1 px away and therefore legitimately resampled.
            let cx = w / 2, cy = h / 2
            let o = (cy * w + cx) * 4
            for c in 0..<4 {
                XCTAssertEqual(onPx.rgba[o + c], offPx.rgba[o + c],
                               "the axis pixel (\(cx),\(cy)) moved in channel \(c)")
            }

            // And the corners *did* move — a fast path that quietly did nothing would pass the
            // green assertions above. A block, not one texel: the ramp is shallow, so a single
            // corner texel can land inside one half-float step.
            XCTAssertNotEqual(blockHash(onPx, x: 0, y: 0, size: 16),
                              blockHash(offPx, x: 0, y: 0, size: 16),
                              "the top-left corner did not move")
            XCTAssertNotEqual(blockHash(onPx, x: w - 16, y: h - 16, size: 16),
                              blockHash(offPx, x: w - 16, y: h - 16, size: 16),
                              "the bottom-right corner did not move")
        }
    }

    // MARK: - G4: the displacement is α · radius

    /// A hard edge at a known radius moves by `α · r` when the channel is resampled at `r · (1 + α)`.
    ///
    /// Measured, not interpolated across a jump: the edge is placed so that each channel has **one
    /// pixel** that straddles it, and that pixel's linear value *is* the source sample position
    /// (`value = s − 999`), so inverting the sRGB curve recovers `s` to a thousandth of a pixel. The
    /// implied scale `(s − axis)/(px − axis)` is then `1 + α` — no half-pixel guesswork.
    func testOffsetIsAlphaTimesRadius() throws {
        let w = 1201, h = 1201, edgeX = 1000
        let axis = Double(w) * 0.5                  // 600.5 — a pixel centre, the optical axis
        let caRed = 0.0013, caBlue = -0.0009        // chosen so each channel gets a straddling pixel
        let g = try graph(stepImage(width: w, height: h, edgeX: edgeX))
        let on = try render(g, ca(caRed, caBlue))
        let row = h / 2

        /// sRGB decode of one display code, in `Double`.
        func linear(_ v: Float16) -> Double {
            let x = Double(Float(v))
            return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
        }

        /// The source **sample coordinate** `u` (the coordinate the kernel hands to `sample_bilinear`)
        /// that the pixel at `px` was taken from, recovered from its own value.
        ///
        /// `sample_bilinear` computes `p = u − 0.5` and blends texels `⌊p⌋` and `⌊p⌋+1`, so for a step
        /// at texels 999/1000 the value *is* `p − 999 = u − 999.5`.
        func samplePosition(_ image: DisplayImage, channel: Int, near: Int) throws -> (u: Double, px: Double) {
            for i in (near - 3)...(near + 3) {
                let v = linear(image.rgba[(row * w + i) * 4 + channel])
                if v > 0.05 && v < 0.95 {
                    return (999.5 + v, Double(i) + 0.5)
                }
            }
            throw XCTSkip("no straddling pixel in the window for channel \(channel)")
        }

        let red = try samplePosition(on, channel: 0, near: edgeX - 2)
        let blue = try samplePosition(on, channel: 2, near: edgeX - 1)

        // u = axis + (px − axis) · (1 + α), exactly.
        let measuredRed = (red.u - axis) / (red.px - axis) - 1
        let measuredBlue = (blue.u - axis) / (blue.px - axis) - 1
        XCTAssertEqual(measuredRed, caRed, accuracy: 3e-5,
                       "red: implied α \(measuredRed) at u = \(red.u), px = \(red.px)")
        XCTAssertEqual(measuredBlue, caBlue, accuracy: 3e-5,
                       "blue: implied α \(measuredBlue) at u = \(blue.u), px = \(blue.px)")

        // G4 as the spec states it: the corner displacement is |α| · halfDiagonal (±0.5 px).
        let halfDiagonal = (axis * axis * 2).squareRoot()
        print(String(format: "CA OFFSET: implied α_R %.6f (set %.6f) at u %.3f px %.1f | "
                     + "implied α_B %.6f (set %.6f) at u %.3f px %.1f | corner %.3f px at halfDiagonal %.1f",
                     measuredRed, caRed, red.u, red.px,
                     measuredBlue, caBlue, blue.u, blue.px,
                     abs(measuredRed) * halfDiagonal, halfDiagonal))
        XCTAssertEqual(abs(measuredRed) * halfDiagonal, caRed * halfDiagonal, accuracy: 0.02,
                       "corner displacement at the half diagonal")

        // Green is the reference channel: its sampling coordinate is an integer texel index for every
        // pixel, so the edge is a hard 0/1 jump with no blend (the display code for linear 1 is
        // 0.9995 because of the transfer function's float arithmetic, hence the 1 % window).
        for i in (edgeX - 3)...(edgeX + 2) {
            let v = linear(on.rgba[(row * w + i) * 4 + 1])
            XCTAssertTrue(v < 0.01 || v > 0.99, "green is not a hard edge at x = \(i) (v = \(v))")
        }
    }

    // MARK: - path C: CA on top of a crop

    /// The general path must keep green for the same reason path B does — it samples the pixel the
    /// CA-off kernel sampled — and it must still move red and blue.
    func testGeneralPathKeepsGreenAndMovesOnlyRB() throws {
        var edit = ca(0.002, -0.0015)
        edit.geometry.crop = NormalizedRect(x: 0.1, y: 0.1, width: 0.6, height: 0.5)
        var off = edit
        off.optics = .identity

        let g = try graph(rampImage(width: 1201, height: 1201))
        let offResult = try g.render(off, options: RenderOptions(scale: 1, useCache: false, wantsPixels: true))
        let onResult = try g.render(edit, options: RenderOptions(scale: 1, useCache: false, wantsPixels: true))
        let offPx = try XCTUnwrap(offResult.display)
        let onPx = try XCTUnwrap(onResult.display)

        XCTAssertFalse(onResult.trace.s0PureCA, "a cropped CA frame is the general path, not the fast one")
        XCTAssertFalse(offResult.trace.s0PureCA)
        XCTAssertTrue(offResult.trace.executed.contains(.geometry),
                      "both frames must actually run S0")
        XCTAssertEqual(greenHash(onPx), greenHash(offPx), "green moved on the general path")
        XCTAssertNotEqual(redBlueHash(onPx), redBlueHash(offPx), "red/blue did not move")
    }

    // MARK: - G7: the key chain

    /// α changes → S0 misses and the whole chain below it misses; α does not change → a full hit. S4
    /// is never cached (its texture is handed out), so a hit means "every stage except `.display`".
    func testCAChangeMissesGeometryAndEverythingBelow() throws {
        let g = try graph(rampImage(width: 401, height: 301))
        let opts = RenderOptions(scale: 1, useCache: true, wantsPixels: false)

        let first = try g.render(EditModel.neutral, options: opts)
        if let t = first.output { g.recycle(output: t) }
        let again = try g.render(EditModel.neutral, options: opts)
        if let t = again.output { g.recycle(output: t) }
        XCTAssertEqual(again.trace.executed, [.display], "an unchanged document must be a full hit")
        XCTAssertTrue(again.trace.skipped.contains(.geometry))

        let withCA = try g.render(ca(0.001, 0), options: opts)
        if let t = withCA.output { g.recycle(output: t) }
        XCTAssertEqual(Set(withCA.trace.executed), Set(RenderStage.allCases),
                       "a CA change must re-run the chain (S0 is where the sampling moved)")
        XCTAssertNotEqual(first.keys.geometry, withCA.keys.geometry)
        XCTAssertNotEqual(first.keys.display, withCA.keys.display)
        // The token is conditional, so a nudge to a *different* α is a different key, and α = 0 is
        // the old one again.
        XCTAssertTrue(withCA.keys.geometry != first.keys.geometry)
        var other = ca(0.001, 0)
        other.optics.caBlue = 0.0005
        let otherResult = try g.render(other, options: opts)
        if let t = otherResult.output { g.recycle(output: t) }
        XCTAssertNotEqual(otherResult.keys.geometry, withCA.keys.geometry)

        // Back to α = 0: the pre-029 key comes back (the cache slot now holds the CA frame, so this
        // re-runs — what a full hit means here is that the *key* is the old one).
        let back = try g.render(EditModel.neutral, options: opts)
        if let t = back.output { g.recycle(output: t) }
        XCTAssertEqual(back.keys.geometry, first.keys.geometry)
        let backAgain = try g.render(EditModel.neutral, options: opts)
        if let t = backAgain.output { g.recycle(output: t) }
        XCTAssertEqual(backAgain.trace.executed, [.display])
    }

    // MARK: - G2 / G8: the bench

    /// 4.10 Mpx, full S0→S4, cache off. The delta between the two p50s **is** S0's extra cost — every
    /// other pass does exactly the same work in both frames.
    func testCABench4Mpx() throws {
        let image = flatImage(0.3, width: 2731, height: 1501)      // 4.0965 Mpx ≈ 4.10 Mpx
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }

        func measure(_ edit: EditModel) throws -> (p50: Double, p95: Double) {
            let g = try RenderGraph(input: RenderInput(image: image, identity: "ca-bench-4mpx"))
            var times: [Double] = []
            for _ in 0..<25 {
                let r = try g.render(edit, options: RenderOptions(scale: 1, useCache: false,
                                                                  wantsPixels: false))
                if let t = r.output { g.recycle(output: t) }
                times.append(r.trace.gpuMilliseconds)
            }
            times.sort()
            return (times[times.count / 2], times[min(times.count - 1, Int(Double(times.count) * 0.95))])
        }

        let off = try measure(EditModel.neutral)
        let on = try measure(ca(0.002, -0.0015))
        let delta = on.p50 - off.p50
        print(String(format: "BENCH CA 4.10 Mpx: off p50 %.2f p95 %.2f ms | on p50 %.2f p95 %.2f ms"
                     + " | S0 increment %.2f ms (%.0f%%)",
                     off.p50, off.p95, on.p50, on.p95, delta, 100 * delta / max(off.p50, 1e-6)))

        if benchmarks {
            XCTAssertLessThan(off.p95, 16.7, "4.10 Mpx frame budget (p95)")
            XCTAssertLessThan(on.p95, 16.7, "4.10 Mpx frame budget (p95, CA on)")
            XCTAssertLessThan(delta, max(off.p50, 1.0), "S0 +CA may not double the frame")
        }
    }

    /// 60 MP (9504 × 6336) at scale 1: the export frame. Same measurement, fewer iterations — a frame
    /// here is a 480 MB texture and the point is the increment, not a distribution.
    func testCABench60MP() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let w = 9504, h = 6336
        let image = flatImage(0.3, width: w, height: h)

        func measure(_ edit: EditModel) throws -> (p50: Double, p95: Double) {
            let g = try RenderGraph(input: RenderInput(image: image, identity: "ca-bench-60mp"))
            var times: [Double] = []
            for _ in 0..<6 {
                let r = try g.render(edit, options: RenderOptions(scale: 1, useCache: false,
                                                                  wantsPixels: false))
                if let t = r.output { g.recycle(output: t) }
                times.append(r.trace.gpuMilliseconds)
            }
            times.sort()
            return (times[times.count / 2], times.last ?? 0)
        }

        let off = try measure(EditModel.neutral)
        let on = try measure(ca(0.002, -0.0015))
        let delta = on.p50 - off.p50
        print(String(format: "BENCH CA 60 MP: off p50 %.2f p95 %.2f ms | on p50 %.2f p95 %.2f ms"
                     + " | S0 increment %.2f ms (%.0f%%)",
                     off.p50, off.p95, on.p50, on.p95, delta, 100 * delta / max(off.p50, 1e-6)))

        if benchmarks {
            XCTAssertLessThan(delta, 15.0, "S0 +CA at 60 MP must stay inside 15 ms")
            XCTAssertLessThan(on.p95 - off.p95, 30.0, "total increment at 60 MP must stay inside 30 ms")
        }
    }

    // MARK: - hashing helpers

    private func greenHash(_ image: DisplayImage) -> String {
        channelHash(image, channels: [1])
    }

    private func redBlueHash(_ image: DisplayImage) -> String {
        channelHash(image, channels: [0, 2])
    }

    /// Hash of an `size × size` block: enough texels that a sub-half-float-step change still shows.
    private func blockHash(_ image: DisplayImage, x: Int, y: Int, size: Int) -> String {
        var bytes = [UInt8]()
        for row in y..<(y + size) {
            let start = (row * image.width + x) * 4
            for i in 0..<(size * 4) {
                let bits = image.rgba[start + i].bitPattern
                bytes.append(UInt8(bits & 0xFF))
                bytes.append(UInt8(bits >> 8))
            }
        }
        return SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
    }

    private func channelHash(_ image: DisplayImage, channels: [Int]) -> String {
        var bytes = [UInt8]()
        bytes.reserveCapacity(image.rgba.count / 2)
        for i in stride(from: 0, to: image.rgba.count, by: 4) {
            for c in channels {
                let bits = image.rgba[i + c].bitPattern
                bytes.append(UInt8(bits & 0xFF))
                bytes.append(UInt8(bits >> 8))
            }
        }
        return SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
    }
}
