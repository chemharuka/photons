import XCTest
import Metal
import simd
import CryptoKit
import PhotonsCore

/// 2026-10-28 (078 P0-1 / B9) — **修复画笔**: S1.9, heal / clone.
///
/// The suite is organised by what can be wrong, in the order it can lie:
///
///  1. **`clone` is a copy, byte for byte.** A red dot on a textured field, cloned from a patch
///     beside it: the target disk and the source disk are the **same bytes** (`sha256` of both,
///     max difference 0). The control — the same document without the spot — differs, so the
///     assertion is not vacuous.
///  2. **`heal` is a copy plus a boundary correction**, measured against the picture it is trying to
///     become: the frame with the blemish healed, compared with the frame of the **clean** image.
///     The acceptance's two numbers: the max deviation drops ≥ 70 %, and the mean of a ring inside
///     the rim differs from a ring outside it by ≤ 2 codes. The second number is *why* the plane is
///     there, and the refutation (`healWithoutBoundaryMatch`) shows it going red.
///  3. **Three spots do not interfere.** Each spot's own region changes; adding a third spot changes
///     **0** pixels of the first two, and adding the first two changes **0** pixels of the third —
///     because every spot samples the input texture, never a neighbour's output.
///  4. **Neutral is structural.** A document with no spot does not visit S1.9, has no `heal` link in
///     the chain, and renders the pre-schema-10 sha — a v9 document and a v10 document with an empty
///     list are the same bytes.
///  5. **The document.** Schema 10 is additive: the key is absent when the list is empty, absent
///     reads as `[]`, a v9 blob re-encodes byte for byte, and the version is not stamped on decode.
///  6. **Cost.** 4.10 Mpx (2560×1600), one spot, the frame in milliseconds — with the frame without
///     any spot beside it, so the pass's own share is readable rather than claimed.
final class HealTests: XCTestCase {

    // MARK: - fixtures

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func makeGraph(_ image: LinearImage, identity: String) throws -> RenderGraph {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        return try RenderGraph(input: RenderInput(image: image, identity: identity))
    }

    /// A deterministic 0…1 hash, so the synthetic pictures are reproducible on any machine and a
    /// "textured" patch really is textured (a flat field would make a byte-for-byte copy claim
    /// vacuous — a copy of a constant is a constant).
    private static func hash01(_ x: Int, _ y: Int) -> Double {
        var h = UInt32(truncatingIfNeeded: x &* 73_856_093) &+ UInt32(truncatingIfNeeded: y &* 19_349_663)
        h = (h ^ (h >> 13)) &* 2_654_435_761
        h ^= h >> 16
        return Double(h % 1000) / 1000.0
    }

    private func picture(_ width: Int, _ height: Int, identity: String,
                         _ body: (Int, Int) -> (Double, Double, Double)) -> LinearImage {
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = body(x, y)
                let o = (y * width + x) * 4
                rgba[o] = Float16(r); rgba[o + 1] = Float16(g)
                rgba[o + 2] = Float16(b); rgba[o + 3] = 1
            }
        }
        return LinearImage(width: width, height: height, rgba: rgba,
                           colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic-heal-\(identity)")
    }

    private func display(_ graph: RenderGraph, _ edit: EditModel,
                         window: ImageRect? = nil, canvas: ImageSize? = nil) throws -> DisplayImage {
        let options = RenderOptions(canvas: canvas, scale: 1, outputWindow: window,
                                    useCache: false, wantsPixels: true)
        return try XCTUnwrap(graph.render(edit, options: options).display)
    }

    private static func code(_ v: Float16) -> Int { Int((Double(v) * 255).rounded()) }

    /// SHA-256 of a byte slice — the same digest `DisplayImage.sha256()` computes over a whole frame,
    /// so a **crop's** hash is comparable with a frame's rather than a second, test-only spelling.
    private static func sha256(_ bytes: [UInt8]) -> String {
        SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
    }

    /// The raw Float16 bytes of a region's three colour channels — what a byte-for-byte claim is
    /// about.
    private static func pixels(_ img: DisplayImage, where predicate: (Int, Int) -> Bool) -> [UInt8] {
        var bytes = [UInt8]()
        for y in 0..<img.height {
            for x in 0..<img.width where predicate(x, y) {
                let o = (y * img.width + x) * 4
                for c in 0..<3 { bytes.append(contentsOf: withUnsafeBytes(of: img.rgba[o + c]) { Array($0) }) }
            }
        }
        return bytes
    }

    private static func translated(_ img: DisplayImage, _ dx: Int,
                                   where predicate: (Int, Int) -> Bool) -> [UInt8] {
        var bytes = [UInt8]()
        for y in 0..<img.height {
            for x in 0..<img.width where predicate(x, y) {
                let o = (y * img.width + x + dx) * 4
                for c in 0..<3 { bytes.append(contentsOf: withUnsafeBytes(of: img.rgba[o + c]) { Array($0) }) }
            }
        }
        return bytes
    }

    // MARK: - the two pictures

    /// 200×120, mid grey with a fine hash texture, and a red dot of radius 12 at (70, 60).
    private static let cloneSize = ImageSize(width: 200, height: 120)
    private static let dotCentre = (x: 70.5, y: 60.5)
    private static let dotRadius = 12.0
    private static let cloneOffsetPx = 45.0

    private func clonePicture() -> LinearImage {
        picture(Self.cloneSize.width, Self.cloneSize.height, identity: "clone") { x, y in
            let dx = Double(x) + 0.5 - Self.dotCentre.x
            let dy = Double(y) + 0.5 - Self.dotCentre.y
            if (dx * dx + dy * dy).squareRoot() < Self.dotRadius {
                return (0.80, 0.04, 0.04)
            }
            let t = 0.22 + 0.30 * Self.hash01(x, y)
            return (t, t, t)
        }
    }

    private func cloneSpot() -> HealSpot {
        HealSpot(id: "h-clone",
                 center: NormalizedPoint(Self.dotCentre.x / Double(Self.cloneSize.width),
                                         Self.dotCentre.y / Double(Self.cloneSize.height)),
                 radius: (Self.dotRadius + 8) / Double(min(Self.cloneSize.width, Self.cloneSize.height)),
                 sourceOffset: NormalizedPoint(Self.cloneOffsetPx
                                                / Double(min(Self.cloneSize.width, Self.cloneSize.height)), 0),
                 mode: .clone, feather: 0, opacity: 1)
    }

    /// 240×160: a linear gradient left → right, with a dark blemish of radius 14 at (90, 80).
    private static let healSize = ImageSize(width: 240, height: 160)
    private static let blemishCentre = (x: 90.5, y: 80.5)
    private static let blemishRadius = 14.0
    private static let healRadiusPx = 26.0
    private static let healOffsetPx = 52.0

    private static func gradient(_ x: Int) -> Double { 0.15 + 0.55 * (Double(x) + 0.5) / 240.0 }

    private func healPicture(blemished: Bool) -> LinearImage {
        picture(Self.healSize.width, Self.healSize.height, identity: "heal") { x, y in
            var v = Self.gradient(x)
            if blemished {
                let dx = Double(x) + 0.5 - Self.blemishCentre.x
                let dy = Double(y) + 0.5 - Self.blemishCentre.y
                if (dx * dx + dy * dy).squareRoot() < Self.blemishRadius { v *= 0.45 }
            }
            return (v, v, v)
        }
    }

    private func healSpot(mode: HealMode = .heal) -> HealSpot {
        HealSpot(id: "h-heal",
                 center: NormalizedPoint(Self.blemishCentre.x / Double(Self.healSize.width),
                                         Self.blemishCentre.y / Double(Self.healSize.height)),
                 radius: Self.healRadiusPx / Double(min(Self.healSize.width, Self.healSize.height)),
                 sourceOffset: NormalizedPoint(Self.healOffsetPx
                                                / Double(min(Self.healSize.width, Self.healSize.height)), 0),
                 mode: mode, feather: 0, opacity: 1)
    }

    /// The largest |Δ| in 8-bit codes between two frames, over the pixels a predicate selects.
    private func maxCodeDifference(_ a: DisplayImage, _ b: DisplayImage,
                                   where predicate: (Int, Int) -> Bool) -> Int {
        var worst = 0
        for y in 0..<min(a.height, b.height) {
            for x in 0..<min(a.width, b.width) where predicate(x, y) {
                let o = (y * a.width + x) * 4
                for c in 0..<3 {
                    worst = max(worst, abs(Self.code(a.rgba[o + c]) - Self.code(b.rgba[o + c])))
                }
            }
        }
        return worst
    }

    // MARK: - 1. clone is a byte-for-byte copy

    func testCloneCopiesTheSourceDiskByteForByte() throws {
        let graph = try makeGraph(clonePicture(), identity: "heal-clone")
        var doc = EditModel.neutral
        doc.healSpots = [cloneSpot()]

        let healed = try display(graph, doc)
        let untouched = try display(graph, EditModel.neutral)

        // The target disk and the source disk, both as **interiors** (t ≤ 0.85), so the comparison is
        // not about the rim's one-pixel boundary.
        let r = Self.dotRadius + 8
        func inside(_ x: Int, _ y: Int) -> Bool {
            let dx = Double(x) + 0.5 - Self.dotCentre.x
            let dy = Double(y) + 0.5 - Self.dotCentre.y
            return (dx * dx + dy * dy).squareRoot() <= r * 0.85
        }
        let dx = Int(Self.cloneOffsetPx)
        let target = Self.pixels(healed, where: inside)
        let source = Self.translated(healed, dx, where: inside)
        var worst = 0
        for y in 0..<healed.height {
            for x in 0..<healed.width where inside(x, y) {
                let o = (y * healed.width + x) * 4
                let q = (y * healed.width + x + dx) * 4
                for c in 0..<3 {
                    worst = max(worst, abs(Self.code(healed.rgba[o + c])
                                            - Self.code(healed.rgba[q + c])))
                }
            }
        }
        let targetSHA = Self.sha256(target), sourceSHA = Self.sha256(source)
        print("clone: target sha \(targetSHA.prefix(16))… / source sha \(sourceSHA.prefix(16))… / "
              + "max |Δ| \(worst) code, \(target.count / 6) pixels")

        XCTAssertEqual(targetSHA, sourceSHA, "克隆必须是逐字节的拷贝，目标区与源区同一个 sha")
        XCTAssertEqual(worst, 0, "逐字节相同 = 最大差 0 码")

        // The control: without the spot the same two regions are *not* the same picture (the red dot
        // is in the target and not in the source), so the assertion above is load-bearing.
        var controlWorst = 0
        for y in 0..<untouched.height {
            for x in 0..<untouched.width where inside(x, y) {
                let o = (y * untouched.width + x) * 4
                let q = (y * untouched.width + x + Int(Self.cloneOffsetPx)) * 4
                for c in 0..<3 {
                    controlWorst = max(controlWorst,
                                       abs(Self.code(untouched.rgba[o + c])
                                           - Self.code(untouched.rgba[q + c])))
                }
            }
        }
        print("clone control: without the spot the same two regions differ by \(controlWorst) code")
        XCTAssertGreaterThan(controlWorst, 40, "没有 spot 时两块必须不同，否则上面的断言是空的")
    }

    // MARK: - 2. heal: the two acceptance numbers

    func testHealReducesTheDeviationAndKeepsTheRimContinuous() throws {
        let graph = try makeGraph(healPicture(blemished: true), identity: "heal-heal")
        let referenceGraph = try makeGraph(healPicture(blemished: false), identity: "heal-clean")

        var doc = EditModel.neutral
        let blemished = try display(graph, doc)
        doc.healSpots = [healSpot()]
        let healed = try display(graph, doc)
        let reference = try display(referenceGraph, EditModel.neutral)

        // The blemish's own disk (t ≤ 0.8 of it), i.e. what the repair is asked to remove.
        func inBlemish(_ x: Int, _ y: Int) -> Bool {
            let dx = Double(x) + 0.5 - Self.blemishCentre.x
            let dy = Double(y) + 0.5 - Self.blemishCentre.y
            return (dx * dx + dy * dy).squareRoot() <= Self.blemishRadius * 0.8
        }
        let before = maxCodeDifference(blemished, reference, where: inBlemish)
        let after = maxCodeDifference(healed, reference, where: inBlemish)
        let reduction = 1.0 - Double(after) / Double(max(before, 1))
        print("heal: max |Δ vs the clean frame — before \(before) code, after \(after) code "
              + "(reduction \(String(format: "%.1f", reduction * 100)) %)")

        XCTAssertGreaterThan(before, 15, "斑点必须先是一个明显的偏差，否则降幅没有意义")
        XCTAssertGreaterThanOrEqual(reduction, 0.70, "修复后与无斑点参考的最大偏差必须降 ≥ 70 %")

        // The rim: the mean of the last fully-covered ring (t ∈ [0.77, 0.92]) against a ring just
        // outside the spot (t ∈ [1.05, 1.2]). The blemish (t ≤ 0.54) is not in either, so this
        // measures the correction and not the removal.
        func meanAt(_ img: DisplayImage, t0: Double, t1: Double) -> Double {
            var sum = 0.0, n = 0
            for y in 0..<img.height {
                for x in 0..<img.width {
                    let dx = Double(x) + 0.5 - Self.blemishCentre.x
                    let dy = Double(y) + 0.5 - Self.blemishCentre.y
                    let t = (dx * dx + dy * dy).squareRoot() / Self.healRadiusPx
                    guard t >= t0, t <= t1 else { continue }
                    let o = (y * img.width + x) * 4
                    sum += Double(img.rgba[o]); n += 1
                }
            }
            return n == 0 ? .nan : sum / Double(n) * 255
        }
        let inner = meanAt(healed, t0: 0.77, t1: 0.92)
        let outer = meanAt(healed, t0: 1.05, t1: 1.2)
        let jump = abs(inner - outer)
        print("heal: rim mean \(String(format: "%.2f", inner)) / outside \(String(format: "%.2f", outer)) "
              + "→ jump \(String(format: "%.2f", jump)) code")
        XCTAssertLessThanOrEqual(jump, 2.0, "边界环内外的均值跳变必须 ≤ 2 码")

        // ── the refutation ─────────────────────────────────────────────────────────────────────────
        // The same document with the boundary plane zeroed — i.e. `heal` behaving as a plain copy.
        // The rim's continuity is the plane's doing, and this is the measurement that says so.
        var options = RenderOptions(scale: 1, useCache: false, wantsPixels: true)
        options.healWithoutBoundaryMatch = true
        let copied = try XCTUnwrap(graph.render(doc, options: options).display)
        let badInner = meanAt(copied, t0: 0.77, t1: 0.92)
        let badJump = abs(badInner - outer)
        let badAfter = maxCodeDifference(copied, reference, where: inBlemish)
        print("refutation (heal = copy): rim mean \(String(format: "%.2f", badInner)) → jump "
              + String(format: "%.2f", badJump) + " code; max |Δ| \(badAfter) code")
        XCTAssertGreaterThan(badJump, 2.0,
                             "反证：去掉边界匹配后「跳变 ≤ 2 码」必须红 —— 否则这条断言在测羽化，不在测算术")
        XCTAssertGreaterThan(badJump, 10.0, "反证的量级：梯度 × 源点偏移，应当是一个几十码的断崖")
    }

    /// A 1:1 window render puts the disk on the same **texels** as the whole-frame render when the
    /// window holds the spot's whole reach (disk **and** source): the spot is an object of the canvas
    /// grid S0 wrote (`RenderGraph.healSpotU` maps `origin − frameOrigin + c·frameSize`), so cropping
    /// the camera around it cannot slide it.
    ///
    /// The second half is the honest limitation, measured rather than discovered: a window that cuts
    /// off the spot's **source** clamps the sampler at the window's own border, so the healed disk
    /// differs from the whole-frame one. It is the same rule `RenderOptions.outputWindow` states for
    /// the mask feather and the guided refine ("a neighbourhood operator clamps at the window's edge
    /// instead of the frame's"), and the size of the effect here is printed.
    func testAWindowPutsTheSpotOnTheSameTexels() throws {
        let graph = try makeGraph(healPicture(blemished: true), identity: "heal-window")
        var doc = EditModel.neutral
        doc.healSpots = [healSpot()]

        let wholeHealed = try display(graph, doc)
        let wholePlain = try display(graph, EditModel.neutral)

        /// How far a 1:1 window render of `document` sits from the **same document's** whole-frame
        /// render, over the window's rect. `RenderOptions.outputWindow` already says a window render is
        /// the whole-frame render "to within a texel of rounding"; measuring the same document both
        /// ways is what makes that rounding the baseline instead of the claim.
        func windowDifference(_ whole: DisplayImage, _ rect: ImageRect, _ document: EditModel) throws -> Int {
            let window = try display(graph, document, window: rect)
            XCTAssertEqual(window.width, rect.width)
            XCTAssertEqual(window.height, rect.height)
            var worst = 0
            for y in 0..<rect.height {
                for x in 0..<rect.width {
                    let a = ((rect.y + y) * whole.width + rect.x + x) * 4
                    let b = (y * window.width + x) * 4
                    for c in 0..<3 {
                        worst = max(worst,
                                    abs(Self.code(whole.rgba[a + c]) - Self.code(window.rgba[b + c])))
                    }
                }
            }
            return worst
        }

        // The spot's whole reach: the disk is x ∈ [64.5, 116.5]; the **source** disk is the same
        // circle shifted by +52 px, x ∈ [116.5, 168.5], y ∈ [54.5, 106.5]. This window holds both (a
        // window that does not clips the source at its own edge — measured below).
        let rect = ImageRect(x: 28, y: 18, width: 168, height: 140)
        let baseline = try windowDifference(wholePlain, rect, EditModel.neutral)
        let generous = try windowDifference(wholeHealed, rect, doc)
        print("window (holds the whole reach): the same crop of the whole frame differs by "
              + "\(generous) code with the spot, \(baseline) code without one — the window path's own "
              + "rounding is the baseline")
        XCTAssertLessThanOrEqual(generous, max(baseline, 1),
                                 "窗口足够大时，S1.9 只是落在同一批像素上：它的差不能超过窗口自身的舍入")

        // A window that clips the source: the sampler clamps at the window's edge.
        let clipped = try windowDifference(wholeHealed, ImageRect(x: 44, y: 36, width: 96, height: 96), doc)
        print("window (clips the source at x = 140): \(clipped) code — the sampler's own edge "
              + "clamp, the same rule the mask feather pays at a window's border")
        XCTAssertLessThanOrEqual(clipped, 12,
                                 "被窗口裁掉的源点只在边界钳制，不该变成一张别的画")
        XCTAssertGreaterThan(clipped, 0,
                             "…but it must not be 0: if it were, the clamp would not be happening and "
                             + "the generous case above would prove nothing about the source")
    }

    // MARK: - 3. three spots do not interfere

    func testThreeSpotsDoNotInterfere() throws {
        // Three blemishes on one gradient, far enough apart that their disks do not overlap; each
        // spot heals its own with the spot to its right as its source.
        let size = ImageSize(width: 360, height: 200)
        let centres = [(x: 70.5, y: 100.5), (x: 180.5, y: 60.5), (x: 290.5, y: 140.5)]
        let radiusPx = 22.0, blemishPx = 11.0, offsetPx = 40.0
        let image = picture(size.width, size.height, identity: "three") { x, y in
            var v = 0.18 + 0.5 * (Double(x) + 0.5) / Double(size.width)
            for c in centres {
                let dx = Double(x) + 0.5 - c.x, dy = Double(y) + 0.5 - c.y
                if (dx * dx + dy * dy).squareRoot() < blemishPx { v *= 0.5 }
            }
            return (v, v, v)
        }
        let shortEdge = Double(min(size.width, size.height))
        func spot(_ i: Int) -> HealSpot {
            HealSpot(id: "h-\(i)",
                     center: NormalizedPoint(centres[i].x / Double(size.width),
                                             centres[i].y / Double(size.height)),
                     radius: radiusPx / shortEdge,
                     sourceOffset: NormalizedPoint(offsetPx / shortEdge, 0),
                     mode: .heal, feather: 0, opacity: 1)
        }
        let graph = try makeGraph(image, identity: "heal-three")

        func render(_ ids: [Int]) throws -> DisplayImage {
            var doc = EditModel.neutral
            doc.healSpots = ids.map(spot)
            return try display(graph, doc)
        }
        let none = try render([])
        let ab = try render([0, 1])
        let abc = try render([0, 1, 2])
        let cOnly = try render([2])

        func inDisk(_ img: DisplayImage, _ i: Int, limit: Double = 0.9) -> (Int, Int) -> Bool {
            let c = centres[i]
            return { x, y in
                let dx = Double(x) + 0.5 - c.x, dy = Double(y) + 0.5 - c.y
                return (dx * dx + dy * dy).squareRoot() <= blemishPx * 2 * limit
            }
        }
        // Each spot changes its own picture.
        for i in 0..<3 {
            XCTAssertGreaterThan(maxCodeDifference(abc, none, where: inDisk(abc, i)), 0,
                                 "spot \(i) 必须改变自己那一片")
        }
        // Adding the third spot changes **0** pixels of the first two …
        let changed12 = maxCodeDifference(abc, ab, where: { x, y in
            inDisk(abc, 0)(x, y) || inDisk(abc, 1)(x, y)
        })
        // … and the first two change **0** pixels of the third's own region.
        let changed3 = maxCodeDifference(abc, cOnly, where: inDisk(abc, 2))
        print("three spots: adding #3 changes \(changed12) code of #1/#2's disks; "
              + "adding #1/#2 changes \(changed3) code of #3's disk")
        XCTAssertEqual(changed12, 0, "第三个 spot 的区域之外 0 变化 —— 各 spot 的源点都取自输入纹理")
        XCTAssertEqual(changed3, 0, "反过来同样：先加的 spot 不改变后加的 spot 那一片")
    }

    // MARK: - 4 & 5. neutral is structural; the document is additive

    func testADocumentWithoutASpotHasNoStageAndTheSamePixels() throws {
        let graph = try makeGraph(clonePicture(), identity: "heal-neutral")
        let empty = try display(graph, EditModel(schemaVersion: 10))
        let preTenth = try display(graph, EditModel(schemaVersion: 9))

        XCTAssertEqual(empty.sha256(), preTenth.sha256(),
                       "无 spot 时 schema 10 与 schema 9 是同一张画：新字段是加法")

        let links = RenderKeyChain.links(identity: "heal-neutral", sourceSize: Self.cloneSize,
                                        canvas: Self.cloneSize, content: Self.cloneSize,
                                        edit: EditModel(), display: DisplayOptions())
        XCTAssertNil(links.heal, "无 spot 时 S1.9 在链里不存在（不是一个中性段）")
        XCTAssertFalse(links.pipeline.contains(.heal))
        XCTAssertEqual(links.pipeline, RenderStage.allCases, "无 spot 的文档走的仍是七段链")

        var doc = EditModel.neutral
        doc.healSpots = [cloneSpot()]
        let withSpot = RenderKeyChain.links(identity: "heal-neutral", sourceSize: Self.cloneSize,
                                            canvas: Self.cloneSize, content: Self.cloneSize,
                                            edit: doc, display: DisplayOptions())
        XCTAssertNotNil(withSpot.heal)
        XCTAssertTrue(withSpot.pipeline.contains(.heal))
        XCTAssertNotEqual(withSpot.curve, links.curve, "S1.9 在曲线之上，所以曲线的 key 必须动")
        XCTAssertEqual(withSpot.toneMap, KeyBuilder(KeyBuilder.digest(of: withSpot.curve))
            .add(doc.keyMaterial(.toneMap)).canonical)

        let result = try graph.render(doc, options: RenderOptions(scale: 1, useCache: false))
        XCTAssertTrue(result.trace.executed.contains(.heal), "有 spot 时 S1.9 必须真的跑")
    }

    func testSchemaTenIsAdditiveAndASpotRoundTrips() throws {
        // A one-spot document round-trips with its numbers.
        var doc = EditModel.neutral
        doc.healSpots = [healSpot()]
        let data = try JSONEncoder().encode(doc)
        let back = try JSONDecoder().decode(EditModel.self, from: data)
        XCTAssertEqual(back.healSpots, doc.healSpots)
        XCTAssertEqual(EditModel.currentSchemaVersion, 12)

        // A document with no spot writes **no** `healSpots` key, and a schema-9 blob re-encodes byte
        // for byte — the schema 7/8/9 rule, read a fourth time.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let neutralJSON = try encoder.encode(EditModel.neutral)
        XCTAssertFalse(String(decoding: neutralJSON, as: UTF8.self).contains("healSpots"),
                       "空列表不写键：v9 文档必须逐字节不变")

        let v9 = """
        {"schemaVersion":9,"processVersion":2,"geometry":{"crop":{"x":0,"y":0,"width":1,"height":1}},"masks":[]}
        """
        var decoderInput = Data(v9.utf8)
        let decoded = try JSONDecoder().decode(EditModel.self, from: decoderInput)
        XCTAssertEqual(decoded.schemaVersion, 9, "解码不盖章：文档保留自己的版本号")
        XCTAssertEqual(decoded.healSpots, [], "缺键读成空列表")
        decoderInput = try encoder.encode(decoded)
        let reDecoded = try JSONDecoder().decode(EditModel.self, from: decoderInput)
        XCTAssertEqual(reDecoded.schemaVersion, 9)
        XCTAssertEqual(reDecoded.healSpots, [])

        // A hand-edited spot is clamped, not refused: a `radius: 9` must not draw a disk the kernel
        // cannot express.
        let wild = """
        {"schemaVersion":10,"healSpots":[{"id":"h-1","center":[0.5,0.5],"radius":9,
          "sourceOffset":[0.1,0],"mode":"heal","feather":4,"opacity":3}]}
        """
        let clamped = try JSONDecoder().decode(EditModel.self, from: Data(wild.utf8))
        XCTAssertEqual(clamped.healSpots.first?.radius, 0.5)
        XCTAssertEqual(clamped.healSpots.first?.feather ?? 99, 0.999)
        XCTAssertEqual(clamped.healSpots.first?.opacity, 1)
    }

    // MARK: - 6. cost

    func testCostOfOneSpotAtFourPointOneMegapixels() throws {
        let size = ImageSize(width: 2560, height: 1600)   // 4.096 Mpx — the acceptance's 4.10 Mpx
        let image = picture(size.width, size.height, identity: "cost") { x, y in
            let v = 0.2 + 0.3 * Self.hash01(x, y)
            return (v, v, v)
        }
        let graph = try makeGraph(image, identity: "heal-cost")
        var doc = EditModel.neutral
        doc.healSpots = [HealSpot(id: "h-cost", center: NormalizedPoint(0.5, 0.5), radius: 0.02,
                                  sourceOffset: NormalizedPoint(0.04, 0),
                                  mode: .heal, feather: 0.35, opacity: 1)]
        let options = RenderOptions(scale: 1, useCache: false, wantsPixels: false)

        func time(_ edit: EditModel, _ rounds: Int) throws -> Double {
            _ = try graph.render(edit, options: options)
            var best = Double.infinity
            for _ in 0..<rounds {
                let t0 = DispatchTime.now().uptimeNanoseconds
                _ = try graph.render(edit, options: options)
                best = min(best, Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
            }
            return best
        }
        let without = try time(EditModel.neutral, 7)
        let with = try time(doc, 7)
        let delta = with - without
        let share = delta > 0 ? String(format: "%.1f ms", delta) : "below this run's noise"
        print("cost 4.10 Mpx: frame with one spot \(String(format: "%.1f", with)) ms "
              + "(best of 7); the same frame without a spot \(String(format: "%.1f", without)) ms — "
              + "S1.9's own share: \(share)")
        XCTAssertLessThan(with, 1000, "4.10 Mpx 一帧必须在秒的量级以内")
        XCTAssertLessThan(with, without * 3 + 20, "一个 spot 的 S1.9 不该让一帧翻倍")
    }
}
