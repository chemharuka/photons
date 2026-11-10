import XCTest
import Metal
@testable import PhotonsCore

/// 323 — 「拖动最高亮度后，没有触发直方图和画面的重算」, measured at the stage cache.
///
/// **What the probe found (the numbers are in `testTheCacheServedTheOldCeilingBeforeItWasInTheKey`'s
/// header and in `Stage.swift`'s field note).** 320 made the ceiling a `DisplayOptions` field and
/// spelled it into `DisplayOptions.keyString`, which reaches the key chain in the **display** link —
/// but the clamp that reads `highlightCeiling` runs at the end of S2 (`s2_tone_map.metal`, both
/// branches) and inside the three display-referred tail guards (S3.7 grain, S3.8 detail, S3.10
/// sharpen). Those links are seeded by the **tone map**, which knew nothing about the ceiling, so on a
/// warmed graph they were cache hits and the pixels kept the old top:
///
/// | render (same graph, `useCache: true`) | peak | stages skipped |
/// |---|---|---|
/// | 2.3 EV, first | 4.9219 | — |
/// | 2.3 EV, again | 4.9219 | (all but S4) |
/// | **4.0 EV, after 2.3** | **4.9219** ← the bug | `s0 s1 s1.7 s3-vignette s2 s3-color s3.10` |
/// | 4.0 EV, fresh graph | 16.0000 | — |
/// | 4.0 EV, `useCache: false` | 16.0000 | — |
///
/// So the ceiling was **in the wrong link**: it was in the encode's key and not in the clamp's. The fix
/// is `DisplayOptions.ceilingKeyString` (one spelling, `ceil=%.4f`) added to the tone-map link, which
/// every stage from S2 down is seeded by. S0/S1/S1.7 keep hitting — the ceiling is not a scene-linear
/// fact — and the cache is still a cache: the same ceiling twice is still a hit.
final class CeilingRerenderTests: XCTestCase {

    private let defaultLinear = HighlightCeiling.defaultLinear       // 4.924577653378805
    private let fourEV = HighlightCeiling.linear(ev: 4)              // 16

    // MARK: - fixtures

    private func graph(_ image: LinearImage, _ id: String) throws -> RenderGraph {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        return try RenderGraph(input: RenderInput(image: image, identity: id))
    }

    private func blocks(values: [Float] = [0.05, 0.25, 0.5, 1.0],
                        width: Int = 400, height: Int = 100) -> LinearImage {
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let b = min(values.count - 1, x * values.count / width)
                let v = Float16(values[b])
                let o = (y * width + x) * 4
                rgba[o] = v; rgba[o + 1] = v; rgba[o + 2] = v; rgba[o + 3] = 1
            }
        }
        return LinearImage(width: width, height: height, rgba: rgba,
                           colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic")
    }

    private func peak(_ img: DisplayImage) -> Double {
        var p = 0.0
        for o in stride(from: 0, to: img.rgba.count, by: 4) {
            for c in 0..<3 { p = max(p, Double(img.rgba[o + c])) }
        }
        return p
    }

    private func topBin(_ h: Histogram) -> Int {
        let bins = h.luma.hdrBins
        for i in stride(from: bins.count - 1, through: 0, by: -1) where bins[i] > 0 { return i }
        return -1
    }

    private func exposed(_ ev: Double) -> EditModel {
        var edit = EditModel.neutral
        edit.light.exposure = ev
        return edit
    }

    private func display(_ ceiling: Double) -> DisplayOptions {
        DisplayOptions(primaries: .sRGB, bitDepth: 16, headroom: 16,
                       linearOutput: true, highlightCeiling: ceiling)
    }

    // MARK: - ① the key, and ② the frame that follows it on one graph

    /// The acceptance, in the order the brief asks for it: the two key strings (verbatim, in the
    /// print), then the peak of the **next render** at each ceiling on a graph that has already
    /// rendered the other one — the exact situation the user was in.
    func testTheKeyAndTheCachedFrameFollowTheCeiling() throws {
        let g = try graph(blocks(), "323-key")
        let edit = exposed(5)

        let d23 = display(defaultLinear)
        let d40 = display(fourEV)
        print("323 key +2.3 EV = \(d23.keyString)")
        print("323 key +4.0 EV = \(d40.keyString)")

        var peaks: [Double] = []
        var keys: [String] = []
        var toneMapRuns: [Int] = []
        var toneMapHits: [Int] = []

        func frame(_ d: DisplayOptions) throws -> RenderResult {
            let r = try g.render(edit, options: RenderOptions(scale: 1, display: d,
                                                              useCache: true, wantsPixels: true))
            peaks.append(peak(try XCTUnwrap(r.display)))
            keys.append(r.keys.display)
            toneMapRuns.append(g.stageRuns[.toneMap] ?? 0)
            toneMapHits.append(g.stageHits[.toneMap] ?? 0)
            return r
        }

        let a1 = try frame(d23)          // 0: +2.3, cold
        let a2 = try frame(d23)          // 1: +2.3, cache hit
        let b1 = try frame(d40)          // 2: +4.0 — the render that used to be 4.9219
        let b2 = try frame(d40)          // 3: +4.0, cache hit

        print(String(format: "323 peaks · +2.3 %.4f, +2.3 again %.4f, +4.0 %.4f, +4.0 again %.4f",
                     peaks[0], peaks[1], peaks[2], peaks[3]))
        print("323 tone-map runs \(toneMapRuns) · hits \(toneMapHits)")
        print("323 display key +2.3 = \(keys[0])")
        print("323 display key +4.0 = \(keys[2])")
        print("323 +4.0 trace: " + b1.trace.summary)

        // ① the keys are different strings, byte for byte.
        XCTAssertNotEqual(d23.keyString, d40.keyString)
        XCTAssertTrue(d23.keyString.contains("ceil=4.9246"), d23.keyString)
        XCTAssertTrue(d40.keyString.contains("ceil=16.0000"), d40.keyString)
        XCTAssertFalse(d23.keyString.contains("ceiling"), "one spelling: ceil=, not ceiling=")
        XCTAssertNotEqual(keys[0], keys[2], "the frame's own key must move with the ceiling")

        // ② the picture is recomputed: 4.9219 → 16.0 on the warmed graph.
        XCTAssertEqual(peaks[0], defaultLinear, accuracy: defaultLinear * 0.02)
        XCTAssertEqual(peaks[2], fourEV, accuracy: fourEV * 0.02,
                       "the +4 EV frame must render, not come out of the cache")
        XCTAssertEqual(peaks[3], fourEV, accuracy: fourEV * 0.02)
        XCTAssertNotEqual(keys[2], a1.keys.display)

        // ④ the cache still works: an unchanged ceiling is a hit, and S2 is not re-run for it.
        XCTAssertEqual(peaks[1], peaks[0], accuracy: 1e-12, "the same ceiling is the same picture")
        XCTAssertEqual(toneMapRuns[1], toneMapRuns[0], "an unchanged ceiling must not re-run S2")
        XCTAssertEqual(toneMapHits[1], toneMapHits[0] + 1, "it must be a *hit* (+1)")
        XCTAssertEqual(toneMapRuns[2], toneMapRuns[1] + 1, "a changed ceiling must re-run S2")
        XCTAssertEqual(b2.trace.cacheHits, a2.trace.cacheHits,
                       "+4 EV twice is the same number of cache hits as +2.3 twice")
    }

    // MARK: - ③ the plot: the bins the ceiling produces, and the key they are filed under

    func testTheBinsAndTheirKeyFollowTheCeiling() throws {
        let g = try graph(blocks(), "323-bins")
        let edit = exposed(5)

        let h23 = try g.measureHistogram(edit, bins: 256, headroom: 16, ceiling: defaultLinear)
        let h40 = try g.measureHistogram(edit, bins: 256, headroom: 16, ceiling: fourEV)

        let key23 = Histogram.cacheKey(rungIdentity: "r", editDigest: "d", bins: 256,
                                       ceiling: defaultLinear)
        let key40 = Histogram.cacheKey(rungIdentity: "r", editDigest: "d", bins: 256,
                                       ceiling: fourEV)
        print("323 bins · top hdr bin \(topBin(h23)) / \(topBin(h40))")
        print("323 histogram key \(key23)  ||  \(key40)")

        XCTAssertEqual(topBin(h23), 147, accuracy: 1, "the default ceiling's tail ends at 2.3 EV")
        XCTAssertEqual(topBin(h40), 255, "and +4 EV's at the axis' end")
        XCTAssertNotEqual(key23, key40, "the plot's key must move with the ceiling")
        XCTAssertTrue(key23.hasPrefix("hist|v1|r|d|256|ceil="), key23)
        XCTAssertTrue(key40.hasSuffix("ceil=16.0000"), key40)
        XCTAssertNotEqual(h23.binsDigest(), h40.binsDigest(), "the bins are not the same plot")
    }

    // MARK: - the goldens: pixels unchanged, keys changed

    /// 3b — the reference frame at `exposure = 0` is below any ceiling the row can name, so the
    /// pixels cannot move: the ceiling is **key material only** for it. The digests are the same
    /// bytes and the reported peak is 0.78 — which is why the recorded goldens' `stageKeys` /
    /// `fileSHA256` change while their pixels do not.
    func testAnExposureZeroPhotoIsByteIdenticalUnderTheCeiling() throws {
        let path = NSString(string: "~/Desktop/test/L1030433.dng").expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else { throw XCTSkip("no RAW fixture") }
        let image = try RAWDecoder().decode(URL(fileURLWithPath: path),
                                            options: DecodeOptions(decoderVersion: nil, scale: 0.0625))
        let g = try graph(image, "323-golden")
        var base = DisplayOptions(primaries: .sRGB, bitDepth: 16, headroom: 16)
        base.linearOutput = true

        func digest(_ ceiling: Double) throws -> (sha: String, peak: Double) {
            var d = base
            d.highlightCeiling = ceiling
            let r = try g.render(.neutral, options: RenderOptions(
                scale: 1, display: d, useCache: false, wantsPixels: true))
            let img = try XCTUnwrap(r.display)
            return (img.sha256(), peak(img))
        }

        let shipped = try digest(defaultLinear)
        let wide = try digest(fourEV)
        print(String(format: "323 golden · exp 0 peak %.4f · %@ / %@",
                     shipped.peak, String(shipped.sha.prefix(16)), String(wide.sha.prefix(16))))
        XCTAssertEqual(shipped.sha, wide.sha, "the ceiling may not move a pixel below itself")
        XCTAssertEqual(shipped.peak, 0.78, accuracy: 0.01, "the reference frame's peak")
    }
}
