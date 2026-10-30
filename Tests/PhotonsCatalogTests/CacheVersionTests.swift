import XCTest
import Foundation
import CoreGraphics
import CryptoKit
import Metal
import PhotonsCore
@testable import PhotonsCatalog

/// P1f (079 §2.7.1) — **the cache key covers the algorithm version, not only the parameters.**
///
/// The failure this file exists to make impossible: `ThumbRecipe.graphVersion` was the literal
/// `"graph-v1"` with a comment asking the next person to bump it when a stage's maths changed. S2's
/// contrast was replaced (a linear-light power with no upper asymptote → `S2Contrast`'s bounded
/// log2-EV bend), S1's blacks became 073C's hybrid EV/level travel, S1.6's contrast started calling
/// the same `tone_contrast` — and the literal stayed put. Every thumbnail with a contrast value on
/// disk was then **stale but servable**: the grid drew the old curve's pixels and nothing anywhere
/// said so.
///
/// Five claims, each one executable:
///   ① the key written by the old arithmetic and the key written by this one are **different
///      strings** (printed, whole, so the difference is legible and not just an inequality);
///   ② the version is **derived** from the per-stage numbers, and the bump is scoped (S2/S1/S1.6
///      moved, S0/S3/the curve did not);
///   ③ a **real old cache directory** — legacy layout, legacy digests, real JPEG bytes — is
///      invalidated and rebuilt: `rebuilt` equals the number of `graph` thumbnails, and the *next*
///      start reports `rebuilt == 0` while serving them as hits;
///   ④ an unchanged document still hits for twenty frames on one graph, and the hot frame stays in
///      its measured budget — the version lives in the key, not in the fast path;
///   ⑤ the **refutation**: build the same chain with the version token removed and the "old key ≠
///      new key" assertion must go red, so ① cannot pass for a reason other than the version.
final class CacheVersionTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-ver-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Absolute millisecond budgets are asserted only under `PHOTONS_BENCH=1` (the same rule the
    /// service tests follow): a red test must mean a regression, not a busy machine. Every number is
    /// printed on every run.
    private var benchmarks: Bool { ProcessInfo.processInfo.environment["PHOTONS_BENCH"] != nil }

    // MARK: - the pre-P1f chain, frozen

    /// The exact text composition `RenderKeyChain.links` performed before the version token existed:
    /// `H("photons-render-v1"|identity|sizes|geometry material)` and then one link per stage, each
    /// seeded by the previous link's digest.
    ///
    /// `stripped(stage)` is the production material with `;alg=N` removed, i.e. *the old material
    /// byte for byte* — P1f changed no parameter spelling, so this is a faithful copy of the old key
    /// rather than a second opinion about it. If the token is ever taken back out of `keyMaterial`,
    /// `stripped` becomes a no-op and ⑤ fails, which is the whole point.
    private func legacyKeys(_ edit: EditModel, identity: String = "p1f-fixture",
                            size: ImageSize = ImageSize(width: 1500, height: 1000))
        -> (geometry: String, sceneLinear: String, curve: String, toneMap: String, color: String,
            vignette: String, display: String) {

        // `algorithmVersion: false` is production's own "pre-P1f material" switch — the frozen text
        // is read from the same place the live one is, so this cannot drift into a second opinion.
        func stripped(_ stage: RenderStage) -> String {
            edit.keyMaterial(stage, algorithmVersion: false)
        }
        let geometry = KeyBuilder("photons-render-v1")
            .add(identity).add(size).add(size).add(size).add(stripped(.geometry)).canonical
        let sceneLinear = KeyBuilder(KeyBuilder.digest(of: geometry)).add(stripped(.sceneLinear)).canonical
        let curve = KeyBuilder(KeyBuilder.digest(of: sceneLinear)).add(stripped(.curve)).canonical
        // 159: contrast sits **after** the tone map, so the "strip the version" chain has the new
        // shape: curve → toneMap → [contrast →] color. It must be the same graph as production with
        // only the `;alg=` tokens removed, or ⑤ would compare two different graphs.
        let toneMap = KeyBuilder(KeyBuilder.digest(of: curve)).add(stripped(.toneMap)).canonical
        var colorSeed = toneMap
        if edit.hasContrastStage || edit.hasLocalContrast {
            colorSeed = KeyBuilder(KeyBuilder.digest(of: toneMap))
                .add("contrast")
                .add(stripped(.contrast))
                .canonical
        }
        let color = KeyBuilder(KeyBuilder.digest(of: colorSeed)).add(stripped(.color)).canonical
        let vignette = KeyBuilder(KeyBuilder.digest(of: color)).add(stripped(.vignette)).canonical
        let display = KeyBuilder(KeyBuilder.digest(of: vignette))
            .add(DisplayOptions().keyString).add(size).canonical
        return (KeyBuilder.digest(of: geometry), KeyBuilder.digest(of: sceneLinear),
                KeyBuilder.digest(of: curve), KeyBuilder.digest(of: toneMap),
                KeyBuilder.digest(of: color), KeyBuilder.digest(of: vignette),
                KeyBuilder.digest(of: display))
    }

    /// The thumbnail recipe digest the old build wrote: `sha256(canonical|decoderRecipe|graph-v1)`.
    private func legacyRecipeDigest(_ developJSON: String) -> String {
        let canonical = ThumbRecipe.canonicalJSON(developJSON) ?? developJSON
        return sha256Hex("\(canonical)|v8/boost0/gamutOff|graph-v1")
    }

    /// A key string exactly as the old build spelled it, and its on-disk file name.
    private func legacyThumbKey(_ contentHash: String, tier: ThumbTier, developJSON: String)
        -> (keyString: String, digest: String) {
        let s = "thumb|v1|\(contentHash)|\(tier.rawValue)|graph|\(legacyRecipeDigest(developJSON))"
        return (s, sha256Hex(s))
    }

    /// A document with a non-zero contrast — the parameter whose *curve* changed under an unchanged
    /// key. Canonical JSON, exactly what a catalog row holds.
    private var contrastDocument: String { #"{"light":{"contrast":35,"exposureEV":0.25}}"# }

    private func contrastEdit() -> EditModel {
        var e = EditModel.neutral
        e.light.contrast = 35
        e.light.exposure = 0.25
        return e
    }

    private func hash(_ i: Int) -> String { String(format: "%064x", i + 1) }

    // MARK: - ① two key strings

    func testTheOldAlgorithmKeyAndTheNewOneAreDifferentStrings() throws {
        // — the stage key (in-memory chain) —
        let edit = contrastEdit()
        let size = ImageSize(width: 1500, height: 1000)
        let old = legacyKeys(edit)
        let new = RenderKeyChain.keys(
            RenderKeyChain.links(identity: "p1f-fixture", sourceSize: size, canvas: size,
                                 content: size, edit: edit, display: DisplayOptions()),
            identity: "p1f-fixture")

        print("P1F toneMap  OLD \(old.toneMap)")
        print("P1F toneMap  NEW \(new.toneMap)")
        print("P1F display  OLD \(old.display)")
        print("P1F display  NEW \(new.display)")
        XCTAssertNotEqual(old.toneMap, new.toneMap,
                          "the contrast stage's key must move when its arithmetic moves")
        XCTAssertNotEqual(old.display, new.display,
                          "and every key below it, because the chain digests the link above")
        // Scoping, stated as the property that has to hold from now on: the token is unconditional,
        // so every stage's key moved **once**, on the day the mechanism arrived — that is the
        // documented one-time migration. What must never happen again is S0 moving because *S2* was
        // bumped, so S2's generation may not appear anywhere in S0's material or S1's:
        XCTAssertEqual(edit.keyMaterial(.geometry).hasSuffix(";alg=1"), true)
        XCTAssertFalse(edit.keyMaterial(.geometry).contains("alg=5"), "S0 does not carry S2's generation")
        XCTAssertFalse(new.toneMap.isEmpty)
        XCTAssertNotEqual(old.geometry, new.geometry,
                          "the unconditional token re-records every key once, S0 included")

        // — the on-disk key (the actual bug: a stale thumbnail that is still servable) —
        let oldThumb = legacyThumbKey(hash(0), tier: .t256, developJSON: contrastDocument)
        let newKey = ThumbKey.graph(contentHash: hash(0), tier: .t256, developJSON: contrastDocument)
        print("P1F thumb    OLD \(oldThumb.keyString)")
        print("P1F thumb    NEW \(newKey.keyString)  → \(newKey.digest)")
        XCTAssertNotEqual(oldThumb.keyString, newKey.keyString,
                          "the same document must not answer the same cache file on both sides of the upgrade")
        XCTAssertNotEqual(oldThumb.digest, newKey.digest)
        XCTAssertFalse(newKey.keyString.contains("graph-v1"),
                       "the hand-maintained literal must be gone, got \(newKey.keyString)")
        XCTAssertNotEqual(ThumbRecipe.recipeDigest(developJSON: contrastDocument),
                          legacyRecipeDigest(contrastDocument),
                          "the recipe digest must carry the derived version, not the old literal")
    }

    // MARK: - ② the version is derived, and scoped

    func testTheVersionIsDerivedFromTheStagesAndTheBumpIsScoped() throws {
        // The stages whose arithmetic moved after `graph-v1` was set (098 moved contrast out of S2,
        // so its generation moved again to 4; 124 moved 高光's white closure above the HDR range).
        XCTAssertEqual(StageAlgorithmVersion.toneMap, 5, "124: 高光 covers the whole HDR range")
        XCTAssertEqual(StageAlgorithmVersion.sceneLinear, 7,
                       "129: the blacks level's dispatch boundary moved to |blacks| = 20")
        XCTAssertEqual(StageAlgorithmVersion.localApply, 4,
                       "159: a mask's contrast left S1.6 for S2.5")
        XCTAssertEqual(StageAlgorithmVersion.contrast, 2,
                       "159: contrast is the display-domain residual operator (S2.5)")
        XCTAssertEqual(StageAlgorithmVersion.maskAtlas, 5,
                       "167: the luminance predicate reads the whole HDR axis, not clamp(light, 0, 1)")
        XCTAssertEqual(StageAlgorithmVersion.vignette, 3,
                       "134: half-diagonal radius, circular contour, midpoint reaches the corner")
        XCTAssertEqual(StageAlgorithmVersion.curve, 2,
                       "137: inverted curves render the descending table instead of the identity")
        // …and the ones that did not, so a bump stays a statement about one stage.
        for stage in [RenderStage.geometry, .color, .grain, .display] {
            XCTAssertEqual(StageAlgorithmVersion.version(of: stage), 1,
                           "\(stage.rawValue) did not change and must not be re-versioned")
        }

        // Every stage is actually in the fingerprint's material — a stage that is missing could be
        // bumped without the file cache noticing.
        let material = StageAlgorithmVersion.material
        for stage in RenderStage.order {
            XCTAssertTrue(material.contains("\(stage.rawValue)=\(StageAlgorithmVersion.version(of: stage))"),
                          "missing from the fingerprint material: \(stage.rawValue)")
        }
        XCTAssertEqual(StageAlgorithmVersion.fingerprint.count, 16)
        XCTAssertTrue(StageAlgorithmVersion.fingerprint.allSatisfy { $0.isHexDigit })

        // The file cache's scalar *is* that fingerprint: no second literal to keep in step.
        XCTAssertEqual(ThumbRecipe.graphVersion, StageAlgorithmVersion.graphVersion)
        XCTAssertTrue(ThumbRecipe.graphVersion.hasPrefix("graph-v2@"))
        XCTAssertNotEqual(ThumbRecipe.graphVersion, "graph-v1")
    }

    /// ③a — a document is not rewritten by an upgrade. The version lives in the *key*, never in
    /// `develop_json`: a bump must not look like an edit (079 §2.7.1), or the catalog would show the
    /// document as modified the day the app updated.
    func testTheVersionNeverEntersTheDocument() throws {
        let json = contrastDocument
        let before = sha256Hex(json)
        let edit = try JSONDecoder().decode(EditModel.self, from: Data(json.utf8))

        // Reading every stage's material and every recipe must not touch the document…
        for stage in RenderStage.order { _ = edit.keyMaterial(stage) }
        _ = ThumbRecipe.recipeDigest(developJSON: json)
        _ = StageAlgorithmVersion.material

        let encoded = try JSONEncoder().encode(edit)
        let text = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(text.contains("alg"), "the algorithm version leaked into the document: \(text)")
        XCTAssertFalse(text.contains(StageAlgorithmVersion.fingerprint))
        XCTAssertEqual(sha256Hex(json), before, "the document hash is a property of the document")

        // …and a document written before P1f decodes to the same *document* after the upgrade: the
        // version is not a field, so nothing can become "modified" because the app updated. Compared
        // canonically (key order is not part of a document — `ThumbRecipe.canonicalJSON` is the same
        // normalisation the key uses).
        let again = try JSONDecoder().decode(EditModel.self, from: encoded)
        XCTAssertEqual(again.light.contrast, edit.light.contrast)
        XCTAssertEqual(again.light.exposure, edit.light.exposure)
        let reencoded = String(decoding: try JSONEncoder().encode(again), as: UTF8.self)
        XCTAssertEqual(ThumbRecipe.canonicalJSON(reencoded), ThumbRecipe.canonicalJSON(text),
                       "re-encoding a document must not grow a version field")
        XCTAssertFalse(reencoded.lowercased().contains("alg"))
    }

    // MARK: - ③ the real old cache directory

    /// A producer that renders nothing: the point here is the key/disk contract, not Metal.
    private final class CountingProducer: ThumbnailProducer, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var calls: [ThumbKey] = []
        var callCount: Int { lock.lock(); defer { lock.unlock() }; return calls.count }

        func produce(_ key: ThumbKey, source: URL) throws -> ThumbPayload {
            lock.lock(); calls.append(key); lock.unlock()
            return ThumbPayload(data: Self.jpeg(seed: key.digest), source: "stub",
                                sourceLongEdge: key.tier.longEdge)
        }

        static func jpeg(seed: String) -> Data {
            let n = 8
            let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            let b = Double(UInt8(seed.prefix(2), radix: 16) ?? 0) / 255
            ctx.setFillColor(CGColor(red: b, green: 0.4, blue: 0.6, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: n, height: n))
            return ThumbnailJPEG.encode(ctx.makeImage()!)!
        }
    }

    /// Write one file at the path the *old* build would have used: `thumbs/xx/yy/<digest>.jpg`,
    /// no namespace directory (the pre-P1f layout).
    private func writeLegacyFile(_ data: Data, digest: String) throws {
        let dir = root.appendingPathComponent(String(digest.prefix(2)), isDirectory: true)
            .appendingPathComponent(String(digest.dropFirst(2).prefix(2)), isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: dir.appendingPathComponent("\(digest).jpg"))
    }

    func testARealOldCacheDirectoryIsRebuiltOnceAndThenHits() throws {
        let assets = (0..<6).map { hash($0) }
        let tier = ThumbTier.t256
        let producer = CountingProducer()

        // — the directory a previous install left behind: real JPEGs, legacy keys, legacy layout —
        for h in assets {
            let graph = legacyThumbKey(h, tier: tier, developJSON: contrastDocument)
            try writeLegacyFile(CountingProducer.jpeg(seed: graph.digest), digest: graph.digest)
            let previewKeyString = "thumb|v1|\(h)|\(tier.rawValue)|preview|-"
            try writeLegacyFile(CountingProducer.jpeg(seed: previewKeyString),
                                digest: sha256Hex(previewKeyString))
        }
        let before = try FileManager.default.contentsOfDirectory(atPath: root.path)
        let tree = try FileManager.default.subpathsOfDirectory(atPath: root.path).filter { $0.hasSuffix(".jpg") }
        print("P1F oldtree  \(before.count) top-level, \(tree.count) jpg: \(before)")
        XCTAssertEqual(tree.count, assets.count * 2, "the old build's tree holds one file per key")
        XCTAssertFalse(before.contains(ThumbNamespace.preview), "a pre-P1f tree has no namespace")
        XCTAssertFalse(before.contains(where: { $0.hasPrefix("g-") }), "…and no generation either")

        // — start 1: the upgrade —
        let cache = try ThumbnailCache(root: root)
        print("P1F sweep    \(cache.versionSweep.summary)")
        XCTAssertTrue(cache.versionSweep.isUpgrade, "an old directory must be recognised as an upgrade")
        XCTAssertNil(cache.versionSweep.previous, "it was written before the stamp existed")
        XCTAssertEqual(cache.versionSweep.current, StageAlgorithmVersion.fingerprint)
        // Everything the old build wrote is gone — the graph files (whose pixels changed) *and* the
        // placeholders (which cannot be told from them by an opaque digest): "invalidated", not
        // "stale for 30 days".
        XCTAssertEqual(cache.versionSweep.removedTotal, assets.count * 2)
        XCTAssertEqual(cache.totalBytes(), 0, "nothing from the old generation may survive")
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.versionMarkerURL.path))

        // The old key is not merely different — it is unresolvable.
        let oldDigest = legacyThumbKey(assets[0], tier: tier, developJSON: contrastDocument).digest
        let dead = root.appendingPathComponent(String(oldDigest.prefix(2)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dead.path))

        let service = ThumbnailService(cache: cache, config: .init(maxConcurrency: 2), producer: producer)
        let specs = assets.map {
            ThumbRequestSpec(key: ThumbKey.graph(contentHash: $0, tier: tier,
                                                 developJSON: contrastDocument),
                             source: URL(fileURLWithPath: "p1f-\($0).CR3"))
        }
        let tickets = service.request(specs)
        XCTAssertTrue(service.waitUntilIdle(timeout: 60))
        let stats = service.stats()
        print("P1F upgrade  rebuilt=\(stats.rebuilt) generated=\(stats.missGenerated) "
              + "hits=\(stats.hits) producer=\(producer.callCount)")

        XCTAssertEqual(stats.rebuilt, assets.count,
                       "rebuilt must be the number of thumbnails the version change invalidated "
                         + "(one per graph thumbnail that was on disk)")
        // A legacy directory loses its placeholders too (an opaque digest cannot tell them from graph
        // files), so `removedTotal` is 2N while `rebuilt` is N: only the graph thumbnails are rebuilds.
        XCTAssertEqual(cache.versionSweep.removedTotal, assets.count * 2)
        XCTAssertEqual(stats.rebuilt, cache.versionSweep.removedTotal - assets.count)
        XCTAssertEqual(stats.missGenerated, assets.count)
        XCTAssertEqual(stats.hits, 0)
        XCTAssertEqual(tickets.compactMap { service.result(for: $0) }.filter { $0.origin == .generated }.count,
                       assets.count)
        // …and they are on disk under the new namespace, which is what makes the next start a hit.
        let ns = root.appendingPathComponent(ThumbNamespace.graph, isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: ns.path))
        XCTAssertEqual(cache.totalBytes() > 0, true)

        // — start 2: the same directory, a fresh process —
        let cache2 = try ThumbnailCache(root: root)
        print("P1F restart  \(cache2.versionSweep.summary)")
        XCTAssertFalse(cache2.versionSweep.isUpgrade, "the stamp is current: this is not an upgrade")
        XCTAssertEqual(cache2.versionSweep.removedTotal, 0)
        let producer2 = CountingProducer()
        let service2 = ThumbnailService(cache: cache2, config: .init(maxConcurrency: 2), producer: producer2)
        _ = service2.request(specs)
        XCTAssertTrue(service2.waitUntilIdle(timeout: 60))
        let stats2 = service2.stats()
        print("P1F restart  rebuilt=\(stats2.rebuilt) hits=\(stats2.hits) producer=\(producer2.callCount)")
        XCTAssertEqual(stats2.rebuilt, 0, "a second start must rebuild nothing")
        XCTAssertEqual(stats2.hits, assets.count, "and must serve every thumbnail from disk")
        XCTAssertEqual(producer2.callCount, 0, "no producer call on a warm cache")
    }

    /// ③b — the *scoped* half of the upgrade: a superseded `g-…` generation is deleted, and the
    /// placeholders in `p/` survive it (a placeholder is decoder output; the grid's first frame must
    /// still have something to draw — §0).
    func testAnUpgradeDeletesTheOldGraphGenerationAndKeepsThePlaceholders() throws {
        let cache = try ThumbnailCache(root: root)
        let h = hash(9)
        let previewKey = ThumbKey.preview(contentHash: h, tier: .t256)
        let graphKey = ThumbKey.graph(contentHash: h, tier: .t256, developJSON: contrastDocument)
        try cache.store(CountingProducer.jpeg(seed: graphKey.digest), for: graphKey)
        // After the graph store, which deletes a placeholder it shadows (§0's one-way transition).
        try cache.store(CountingProducer.jpeg(seed: previewKey.digest), for: previewKey)

        // Simulate the next algorithm generation: move the graph file into an older namespace and
        // stamp the root with that older fingerprint.
        let oldNamespace = root.appendingPathComponent("g-0000000000000000", isDirectory: true)
        try FileManager.default.createDirectory(
            at: oldNamespace.appendingPathComponent(graphKey.shard0, isDirectory: true),
            withIntermediateDirectories: true)
        try FileManager.default.moveItem(
            at: cache.url(for: graphKey),
            to: oldNamespace.appendingPathComponent(graphKey.shard0, isDirectory: true)
                .appendingPathComponent("\(graphKey.digest).jpg"))
        try Data("0000000000000000".utf8).write(to: cache.versionMarkerURL)

        let upgraded = try ThumbnailCache(root: root)
        print("P1F scoped   \(upgraded.versionSweep.summary)")
        XCTAssertTrue(upgraded.versionSweep.isUpgrade)
        XCTAssertEqual(upgraded.versionSweep.previous, "0000000000000000")
        XCTAssertEqual(upgraded.versionSweep.removedGraphFiles, 1, "the old generation's graph file")
        XCTAssertEqual(upgraded.versionSweep.removedLegacyFiles, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldNamespace.path))
        XCTAssertNil(upgraded.data(for: graphKey), "the file the old arithmetic wrote is gone")
        XCTAssertNotNil(upgraded.data(for: previewKey),
                        "a placeholder is not render output: the upgrade must not empty the grid")
    }

    // MARK: - ④ twenty unchanged frames still hit

    private func rampImage(width: Int = 2560, height: Int = 1600) -> LinearImage {
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let o = (y * width + x) * 4
                let v = Float(0.005 + 0.99 * Double(x) / Double(max(width - 1, 1)))
                rgba[o] = Float16(v)
                rgba[o + 1] = Float16(v * 0.94)
                rgba[o + 2] = Float16(v * 0.88)
                rgba[o + 3] = 1
            }
        }
        return LinearImage(width: width, height: height, rgba: rgba,
                           colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic")
    }

    private func hotGraph(_ image: LinearImage, identity: String) throws -> RenderGraph {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        return try RenderGraph(input: RenderInput(image: image, identity: identity),
                               cacheBudgetBytes: 1_500_000_000)
    }

    /// The version is a fact about the *key*, not about the render path: a document that did not
    /// change must still resume from the composite (081), twenty times in a row, at 4.10 Mpx — the
    /// canvas the 0.38 ms hot-frame number was measured on.
    ///
    /// No `wantsPixels`: the number 0.38 ms describes the **frame**, and a readback is a separate cost
    /// (measured here at ~1 s at 4.10 Mpx in a debug build — `readback()` converts 4.1 M plain, so a
    /// debug swift loop dominates it; the release harness in `local/perf` is where the 0.38 ms lives).
    /// Mixing the two would make the gate a measurement of `readback`, not of the cache.
    ///
    /// The comparable instrument is `trace.gpuMilliseconds` of the resumed frame: release p50 measured
    /// 0.37–0.41 ms at 4.10 Mpx on this host against the documented 0.38 ms — no regression. The frame
    /// p50 printed next to it is the XCTest wrapper around the same GPU work, so it drifts with the
    /// machine; the GPU number is the one to compare against the perf harness.
    func testTwentyUnchangedFramesStillHitAfterAVersionBump() throws {
        let image = rampImage()
        var doc = contrastEdit()
        doc.light.highlights = -20
        doc.light.shadows = 15
        let graph = try hotGraph(image, identity: "p1f-hot")
        let options = RenderOptions(scale: 1, useCache: true, wantsPixels: false)

        func frame() throws -> RenderResult {
            let r = try graph.render(doc, options: options)
            if let out = r.output { graph.recycle(output: out) }
            return r
        }

        let cold = try frame()
        XCTAssertGreaterThan(cold.trace.executed.count, 5, "the cold frame must walk the pipeline")
        let full = cold.trace.executed

        var times: [Double] = []
        var gpuTimes: [Double] = []
        var last: RenderResult?
        for i in 0..<20 {
            let t0 = DispatchTime.now()
            let r = try frame()
            times.append(Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e6)
            gpuTimes.append(r.trace.gpuMilliseconds)
            last = r
            XCTAssertEqual(r.trace.executed, [.display],
                           "frame \(i) walked \(r.trace.executed.map(\.short)) — the key moved although "
                             + "the document did not")
        }
        let sorted = times.sorted()
        let p50 = sorted[sorted.count / 2]
        // Which stages the hot frame skipped, not just how long it took: a fast frame that did not
        // skip anything is not a cache hit, and a 1 s number is a readback, not a render (the debug
        // readback at 4.10 Mpx alone measured ~1 s, which is why this frame does not ask for pixels).
        let executedStages = try XCTUnwrap(last).trace.executed
        let skipped = full.filter { !executedStages.contains($0) }
        let executed = executedStages.map { $0.short }.joined(separator: " ")
        let missed = skipped.map { $0.short }.joined(separator: " ")
        let gpuP50 = gpuTimes.sorted()[gpuTimes.count / 2]
        print("P1F hot      cold ran \(full.count) stages; 20 unchanged frames: "
              + "resumes=\(graph.compositeResumes) entries=\(graph.cacheEntryCount) "
              + "hot=[\(executed)] skipped=[\(missed)] "
              + String(format: "frame p50 %.2f ms (min %.2f max %.2f)  gpu p50 %.2f ms",
                       p50, sorted.first ?? 0, sorted.last ?? 0, gpuP50))
        XCTAssertEqual(skipped.count, full.count - 1,
                       "every stage but S4 must be skipped on an unchanged frame")
        XCTAssertEqual(graph.compositeResumes, 20, "every unchanged frame must have used the resume")
        // Gate only under `PHOTONS_BENCH=1` (the same rule the service tests follow): a red test must
        // mean a regression, not a busy machine. 3 ms is ~2× the debug measurement on this host and
        // ~8× the documented 0.38 ms release figure.
        if benchmarks {
            XCTAssertLessThan(p50, 3.0, "the hot frame regressed: p50 \(p50) ms against a 0.38 ms baseline")
        }
    }

    /// …and the resumed frames are the *same picture*: twenty of them, bit for bit, against a cold
    /// render of the same document at 4.10 Mpx. A fast frame that is wrong is the failure mode the
    /// whole mechanism has to exclude.
    func testTheResumedFramesAreBitIdenticalToAColdOne() throws {
        let image = rampImage(width: 1024, height: 640)
        var doc = contrastEdit()
        doc.light.highlights = -20
        let graph = try hotGraph(image, identity: "p1f-identical")
        let options = RenderOptions(scale: 1, useCache: true, wantsPixels: true)

        func frame() throws -> RenderResult {
            let r = try graph.render(doc, options: options)
            if let out = r.output { graph.recycle(output: out) }
            return r
        }

        let cold = try XCTUnwrap(try frame().display).sha256()
        for i in 0..<20 {
            let r = try frame()
            XCTAssertEqual(r.trace.executed, [.display])
            XCTAssertEqual(try XCTUnwrap(r.display).sha256(), cold,
                           "resumed frame \(i) is not bit-identical to the cold render")
        }
        let fresh = try hotGraph(image, identity: "p1f-identical")
        let coldAgain = try fresh.render(doc, options: RenderOptions(scale: 1, useCache: false,
                                                                   wantsPixels: true))
        XCTAssertEqual(try XCTUnwrap(coldAgain.display).sha256(), cold,
                       "the cached frames disagree with a cache-off render")
    }

    // MARK: - ⑤ the refutation

    /// Remove the version from the key material and "the old key is not the new key" must **fail**.
    ///
    /// The check is not a comment: the assertions are run twice, once against the production chain
    /// and once against a chain whose material has the `;alg=` token deleted. The first copy must
    /// pass and the second must fail — that is what proves the inequality in ① is caused by the
    /// version and by nothing else.
    func testRemovingTheVersionFromTheKeyMaterialMakesTheClaimFail() throws {
        let edit = contrastEdit()
        let size = ImageSize(width: 1500, height: 1000)
        let old = legacyKeys(edit)

        // (a) production: the claim holds.
        let live = RenderKeyChain.keys(
            RenderKeyChain.links(identity: "p1f-fixture", sourceSize: size, canvas: size,
                                 content: size, edit: edit, display: DisplayOptions()),
            identity: "p1f-fixture")
        XCTAssertNotEqual(old.toneMap, live.toneMap)
        XCTAssertNotEqual(legacyThumbKey(hash(0), tier: .t256, developJSON: contrastDocument).digest,
                          ThumbKey.graph(contentHash: hash(0), tier: .t256,
                                         developJSON: contrastDocument).digest)

        // (b) the same question with the version taken out of the material: every stage's text is
        // the old text, so the chain reproduces the old key exactly — the claim *cannot* hold.
        let without = RenderKeyChain.keys(
            RenderKeyChain.links(identity: "p1f-fixture", sourceSize: size, canvas: size,
                                 content: size, edit: edit, display: DisplayOptions(),
                                 materialWithoutAlgorithmVersion: true),
            identity: "p1f-fixture")
        XCTAssertEqual(old.toneMap, without.toneMap,
                       "with no version in the material the old and the new key must collide — that is "
                         + "the bug this file exists for")
        XCTAssertEqual(old.display, without.display)

        // And the material really is what changed, not the parameters: the same text plus one token.
        XCTAssertEqual(edit.keyMaterial(.toneMap),
                       edit.keyMaterial(.toneMap, algorithmVersion: false)
                           + StageAlgorithmVersion.token(.toneMap))
        XCTAssertTrue(edit.keyMaterial(.toneMap).hasSuffix(";alg=5"))
        XCTAssertTrue(edit.keyMaterial(.sceneLinear).hasSuffix(";alg=7"))
        XCTAssertTrue(edit.keyMaterial(.geometry).hasSuffix(";alg=1"))
    }
}
