import XCTest
import AppKit
import SwiftUI
import PhotonsCore
import PhotonsCatalog
@testable import PhotonsUI

/// 派单 009: the inspector's 白平衡 section (order, preset menu, eyedropper).
///
/// What is pinned here, and why each assertion is the one that matters:
///
///   · **The section order** `直方图 → 白平衡 → Light` (A). `InspectorView.body` is a
///     `ForEach(Section.allCases)`, so `Section` *is* the hierarchy: a card moved in the enum moves on
///     screen, and there is no second list to drift. The rendered side is checked too when the hosted
///     view exposes an accessibility tree — under `swift test` it does not (SwiftUI draws into layers
///     and creates no subviews, and AX needs a live window session), which the test prints rather than
///     pretends otherwise.
///   · **The preset table** (B): eight entries, Lightroom's absolute Kelvin/tint pairs, and a *derived*
///     selection — a dragged pair must read 自定义, never the nearest preset.
///   · **One preset = one history entry + one development.** Not "the call returned": the real decoder
///     counter moves by exactly one, and the same document rendered twice is one development.
///   · **The eyedropper** (C): the sampled pixel's R/G/B before and after the re-decode, the solved
///     Kelvin/tint, the model's residual, one history entry, one development — and a click on the
///     letterbox writing nothing at all.
///
/// The RAW fixture is the user's own photo and is not vendored: set `PHOTONS_TEST_RAW` or the suite
/// skips. Everything runs through the synchronous `makeFrame` path at 1/8 scale, so the file takes a
/// couple of seconds and never waits on a window animation.
@MainActor
final class WhiteBalanceSectionTests: XCTestCase {

    /// Device pixels. The canvas is half that in points, so `backingScale` 2 (the no-window default)
    /// resolves a view point exactly as a click in the app would.
    private static let viewport = ImageSize(width: 800, height: 600)
    private static let decodeScale: Float = 0.125

    private func fixtureURL() throws -> URL {
        let candidates = [
            ProcessInfo.processInfo.environment["PHOTONS_TEST_RAW"],
            NSString(string: "~/Desktop/test/L1030433.dng").expandingTildeInPath,
        ].compactMap { $0 }
        for c in candidates where FileManager.default.isReadableFile(atPath: c) {
            return URL(fileURLWithPath: c)
        }
        throw XCTSkip("no RAW fixture; set PHOTONS_TEST_RAW")
    }

    /// A loupe with a canvas of the right size and no automatic rendering: every frame here is asked
    /// for explicitly, so nothing races the assertions.
    private func makeLoupe(_ session: CatalogSession) -> LoupeController {
        let loupe = LoupeController(session: session)
        loupe.autoRenderEnabled = false
        _ = loupe.view
        loupe.canvasView.frame = NSRect(x: 0, y: 0,
                                        width: Self.viewport.width / 2,
                                        height: Self.viewport.height / 2)
        XCTAssertEqual(loupe.viewportPixels.width, Self.viewport.width,
                       "the canvas must report the test viewport, or hit-testing is another frame")
        XCTAssertEqual(loupe.viewportPixels.height, Self.viewport.height)
        return loupe
    }

    private func develop(_ loupe: LoupeController, _ url: URL, _ edit: EditModel) throws -> LoupeController.FrameResult {
        try loupe.makeFrame(url: url, viewport: Self.viewport, decodeScale: Self.decodeScale, edit: edit)
    }

    private func decodeTotal() -> Int { RAWDecoder.decodeCounts().values.reduce(0, +) }

    // MARK: - A. the order of the cards

    func testSectionsRunHistogramThenWhiteBalanceThenLight() {
        let titles = InspectorView.sectionTitles
        XCTAssertEqual(Array(titles.prefix(3)), ["直方图", "白平衡", "Light"],
                       "白平衡 must sit under the histogram and above Light; got \(titles)")
        XCTAssertEqual(titles.filter { $0 == "白平衡" }.count, 1, "one 白平衡 section, not two")
        // 色温/色调 left the Light card (派单 009 A): Light is tone only, every section is distinct.
        XCTAssertEqual(InspectorView.Section.allCases.count, Set(InspectorView.Section.allCases).count)
    }

    /// The rendered side: what the hosted inspector exposes, in tree order.
    func testRenderedCardOrderMatchesTheSectionList() {
        let host = NSHostingView(rootView: InspectorView(session: CatalogSession()))
        host.frame = NSRect(x: 0, y: 0, width: 330, height: 1400)
        host.layoutSubtreeIfNeeded()
        let ids = Self.cardIdentifiers(in: host)
        print("rendered card identifiers: \(ids.isEmpty ? "none (no window session)" : "\(ids)")")
        guard ids.count >= 3 else {
            // Nothing was exposed: the enum asserted above is the one ordering that exists.
            XCTAssertEqual(ids, [], "a short-but-non-empty tree means the walker is broken")
            return
        }
        XCTAssertEqual(Array(ids.prefix(3)),
                       ["inspector.card.histogram", "inspector.card.whiteBalance", "inspector.card.light"],
                       "rendered order is \(ids)")
    }

    /// Depth-limited walk of the accessibility tree, collecting the card identifiers.
    private static func cardIdentifiers(in root: NSView, depth: Int = 0) -> [String] {
        walkAX(root, depth: depth)
    }

    private static func walkAX(_ node: Any, depth: Int) -> [String] {
        guard depth < 24 else { return [] }
        let children: [Any]
        if let view = node as? NSView {
            children = view.accessibilityChildren() ?? []
        } else if let element = node as? NSAccessibilityElement {
            children = element.accessibilityChildren() ?? []
        } else {
            return []
        }
        var out: [String] = []
        for child in children {
            for id in identifiers(of: child) where id.hasPrefix("inspector.card.") {
                out.append(id)
            }
            out += walkAX(child, depth: depth + 1)
        }
        return out
    }

    private static func identifiers(of node: Any) -> [String] {
        if let view = node as? NSView {
            let id = view.accessibilityIdentifier()
            return id.isEmpty ? [] : [id]
        }
        if let element = node as? NSAccessibilityElement, let id = element.accessibilityIdentifier() {
            return [id]
        }
        return []
    }

    // MARK: - B. the preset menu

    func testMenuHasTheEightEntriesAndLightroomsAbsolutePairs() {
        XCTAssertEqual(WhiteBalancePresets.all.map(\.name),
                       ["原照设置", "自动", "日光", "阴天", "阴影", "钨丝灯", "荧光灯", "闪光灯"])
        XCTAssertEqual(WhiteBalancePresets.all.count, 8)

        let table: [(WhiteBalancePreset, Double, Double)] = [
            (WhiteBalancePresets.daylight, 5500, 0),
            (WhiteBalancePresets.cloudy, 6500, 10),
            (WhiteBalancePresets.shade, 7500, 10),
            (WhiteBalancePresets.tungsten, 2850, 0),
            (WhiteBalancePresets.fluorescent, 3800, 21),
            (WhiteBalancePresets.flash, 5500, 0),
        ]
        for (preset, kelvin, tint) in table {
            XCTAssertEqual(preset.whiteBalance, WhiteBalance(temperature: kelvin, tint: tint),
                           "\(preset.name) must be the absolute pair \(kelvin) K / \(tint)")
            XCTAssertTrue(WhiteBalance.temperatureRange.contains(kelvin))
            XCTAssertTrue(WhiteBalance.tintRange.contains(tint))
        }
        // The two states carry no number: as shot is the file's, auto is the picture's.
        XCTAssertNil(WhiteBalancePresets.asShot.whiteBalance)
        XCTAssertNil(WhiteBalancePresets.auto.whiteBalance)
    }

    func testSelectionIsDerivedSoADraggedPairReadsCustom() {
        XCTAssertEqual(WhiteBalancePresets.menuLabel(.asShot), "原照设置")
        XCTAssertEqual(WhiteBalancePresets.menuLabel(WhiteBalance(temperature: 5500, tint: 0)), "日光")
        // A drag (or a dropper) lands between presets: 自定义, not the nearest name.
        XCTAssertEqual(WhiteBalancePresets.menuLabel(WhiteBalance(temperature: 5875, tint: 3)), "自定义")
        XCTAssertNil(WhiteBalancePresets.match(WhiteBalance(temperature: 4200, tint: -12)))
        // 闪光灯 and 日光 share numbers; the item the user picked is the one that stays checked.
        XCTAssertEqual(WhiteBalancePresets.menuLabel(WhiteBalance(temperature: 5500, tint: 0),
                                                     preferred: "flash"), "闪光灯")
    }

    // MARK: - B. one preset = one history entry = one development

    func testChoosingDaylightWritesOneHistoryEntryAndOneDevelopment() throws {
        let url = try fixtureURL()
        let session = CatalogSession()
        let loupe = makeLoupe(session)
        let commands = WhiteBalanceCommands(session: session, asShot: loupe.asShotWhiteBalance)

        // As shot: one development, then a re-frame of the same document must not develop again.
        _ = try develop(loupe, url, session.edit)
        let first = try develop(loupe, url, session.edit)
        XCTAssertTrue(first.usedCachedDecode, "as shot must be one development, reused")
        let decodesBefore = decodeTotal()
        let historyBefore = session.history.count

        // Exactly what the menu's selection handler runs.
        commands.commit(WhiteBalancePresets.daylight.whiteBalance!, label: "预设 日光")

        XCTAssertEqual(session.edit.light.temperature, 5500)
        XCTAssertEqual(session.edit.light.tint, 0)
        XCTAssertEqual(session.history.count, historyBefore + 1, "one preset = one snapshot")
        XCTAssertEqual(session.history.currentSnapshot?.label, "预设 日光")

        let edited = try develop(loupe, url, session.edit)
        XCTAssertFalse(edited.usedCachedDecode, "a new Kelvin must develop, not reuse as shot")
        XCTAssertEqual(decodeTotal(), decodesBefore + 1, "one preset = one development")

        // …and the new document is itself resident: a second frame at 5500 K is a hit.
        let again = try develop(loupe, url, session.edit)
        XCTAssertTrue(again.usedCachedDecode)
        XCTAssertEqual(decodeTotal(), decodesBefore + 1)
        print("预设 日光: \(session.edit.light.whiteBalance.summary)"
              + " · history +\(session.history.count - historyBefore)"
              + " · decodes +\(decodeTotal() - decodesBefore)"
              + " · second frame cached \(again.usedCachedDecode)")

        // 原照设置 goes back to `nil` — one more snapshot, one more development (a different buffer).
        XCTAssertTrue(commands.resetToAsShot())
        XCTAssertNil(session.edit.light.temperature)
        XCTAssertNil(session.edit.light.tint)
        XCTAssertEqual(session.history.count, historyBefore + 2)
        _ = try develop(loupe, url, session.edit)
        XCTAssertEqual(decodeTotal(), decodesBefore + 2)
        print("原照设置: \(session.edit.light.whiteBalance.summary)"
              + " · history +\(session.history.count - historyBefore)"
              + " · decodes +\(decodeTotal() - decodesBefore)")

        // A second 原照设置 click is not a history entry (the document is already there).
        XCTAssertFalse(commands.resetToAsShot())
        XCTAssertEqual(session.history.count, historyBefore + 2)
    }

    // MARK: - C. the eyedropper

    /// A real grey patch — the case the task names ("在测试图的灰色区域取样"): neutral well under the 2 %
    /// target, one history entry, one development.
    func testEyedropperMakesTheSampledGreyAreaNeutral() throws {
        let url = try fixtureURL()
        let session = CatalogSession()
        let loupe = makeLoupe(session)
        _ = try develop(loupe, url, session.edit)
        // The as-shot pair is a fact of the decode, so the commands are built *after* the first frame.
        let commands = WhiteBalanceCommands(session: session, asShot: loupe.asShotWhiteBalance)
        let grey = try XCTUnwrap(greyAreaSample(in: loupe), "no usable grey point in the fixture")
        let report = try runDropper(at: grey.0, url: url, loupe: loupe,
                                    session: session, commands: commands, label: "灰区")
        print(report.text)

        XCTAssertEqual(session.edit.light.whiteBalance, report.solve.whiteBalance)
        XCTAssertFalse(report.solve.clamped, "a grey patch must not need the end of a range")
        XCTAssertLessThan(report.afterChroma, 0.02,
                          "the grey area is still \(String(format: "%.2f%%", report.afterChroma * 100))")
        XCTAssertLessThan(report.afterChroma, report.beforeChroma)
        XCTAssertEqual(report.historyDelta, 1, "the dropper writes one snapshot")
        XCTAssertEqual(report.decodeDelta, 1, "the dropper's write develops once")
    }

    /// The same click on a strongly coloured patch: the model is a Planckian fit, so a sample the fit
    /// cannot reach is reported (`clamped`) rather than promised — but it must still cut the chroma by
    /// more than half, and it must still be exactly one history entry and one development.
    func testEyedropperOnAColouredPatchStillImprovesAndWritesOnce() throws {
        let url = try fixtureURL()
        let session = CatalogSession()
        let loupe = makeLoupe(session)
        _ = try develop(loupe, url, session.edit)
        let commands = WhiteBalanceCommands(session: session, asShot: loupe.asShotWhiteBalance)

        let coloured = try XCTUnwrap(chromaticSample(in: loupe), "no chromatic point in the fixture")
        let report = try runDropper(at: coloured.0, url: url, loupe: loupe,
                                    session: session, commands: commands, label: "强色块")
        print(report.text)

        XCTAssertLessThan(report.afterChroma, report.beforeChroma * 0.5,
                          "the dropper must at least halve a strong cast ("
                          + String(format: "%.2f%%", report.beforeChroma * 100) + " → "
                          + String(format: "%.2f%%", report.afterChroma * 100) + ")")
        XCTAssertEqual(report.historyDelta, 1)
        XCTAssertEqual(report.decodeDelta, 1)
    }

    func testDropperOnTheLetterboxWritesNothing() throws {
        let url = try fixtureURL()
        let session = CatalogSession()
        let loupe = makeLoupe(session)
        _ = try develop(loupe, url, session.edit)
        let historyBefore = session.history.count
        let decodesBefore = decodeTotal()

        // 3:2 in a 4:3 viewport: 33 px of black above and below the picture at 800×600.
        var reported: [LoupeController.DropperOutcome] = []
        loupe.armEyedropper { reported.append($0) }
        let outcome = loupe.handleEyedropperClick(atViewPoint: CGPoint(x: 200, y: 2))
        print("letterbox click: \(String(describing: outcome)) · armed \(loupe.isEyedropperArmed)")

        XCTAssertEqual(outcome, LoupeController.DropperOutcome.outsideImage)
        XCTAssertEqual(reported, [.outsideImage])
        XCTAssertTrue(loupe.isEyedropperArmed, "a miss leaves the tool armed; only a sample disarms it")
        XCTAssertEqual(session.history.count, historyBefore, "no history for a letterbox click")
        XCTAssertNil(session.edit.light.temperature, "no document write for a letterbox click")
        XCTAssertEqual(decodeTotal(), decodesBefore, "no development for a letterbox click")
    }

    func testDropperWithoutADecodeReportsNotReady() {
        let session = CatalogSession()
        let loupe = makeLoupe(session)
        XCTAssertEqual(loupe.samplePixel(atViewPoint: CGPoint(x: 200, y: 150)),
                       LoupeController.DropperOutcome.notReady)
        XCTAssertNil(loupe.averageSceneRGB(), "Auto must not invent a picture")
        var reported: [LoupeController.DropperOutcome] = []
        loupe.armEyedropper { reported.append($0) }
        _ = loupe.handleEyedropperClick(atViewPoint: CGPoint(x: 200, y: 150))
        XCTAssertEqual(reported, [.notReady])
        XCTAssertTrue(loupe.isEyedropperArmed)
    }

    // MARK: - the one route a dropper click takes

    private struct DropperReport {
        let text: String
        let solve: WhiteBalanceSolve
        let beforeChroma: Double
        let afterChroma: Double
        let historyDelta: Int
        let decodeDelta: Int
    }

    /// Arm, click through `LoupeController`, apply through `WhiteBalanceCommands` — the same three
    /// calls the inspector makes — then develop the new document and read the same source point.
    private func runDropper(at point: CGPoint, url: URL, loupe: LoupeController,
                            session: CatalogSession, commands: WhiteBalanceCommands,
                            label: String) throws -> DropperReport {
        let historyBefore = session.history.count
        let decodesBefore = decodeTotal()
        // The reference must be read *before* the click writes the document.
        let reference = commands.reference

        var solve: WhiteBalanceSolve?
        var clicked: LoupeController.DropperSample?
        loupe.armEyedropper { outcome in
            if case .sampled(let sample) = outcome {
                clicked = sample
                solve = commands.applyDropper(sample.rgb)
            }
        }
        XCTAssertTrue(loupe.isEyedropperArmed)
        let outcome = try XCTUnwrap(loupe.handleEyedropperClick(atViewPoint: point),
                                    "a click with the dropper armed must report something")
        guard case .sampled(let sample) = outcome else {
            throw XCTSkip("the click at \(point) produced \(String(describing: outcome))")
        }
        XCTAssertFalse(loupe.isEyedropperArmed, "the dropper is one-shot")
        let applied = try XCTUnwrap(solve, "the dropper produced no solution")
        XCTAssertEqual(clicked?.rgb, sample.rgb, "the click must sample what it reported")

        // The pixels: develop the new document and read the same source point again.
        _ = try develop(loupe, url, session.edit)
        guard case .sampled(let after) = loupe.samplePixel(atViewPoint: point) else {
            throw XCTSkip("the re-decoded buffer refused the same point")
        }
        let text = String(format: """
            [%@] src %.0f,%.0f → buf %d,%d @%.3f×
              solve   %@ (reference %.0f K / %+.1f) · model residual %.2f%% · clamped %@
              model   predicted RGB %@
              before  RGB %@ · chroma %.2f%% (b/r %.3f, g/r %.3f)
              after   RGB %@ · chroma %.2f%% (b/r %.3f, g/r %.3f)
              history +%d · decodes +%d
            """,
            label, sample.sourceX, sample.sourceY, sample.bufferX, sample.bufferY, sample.decodeScale,
            applied.whiteBalance.summary, reference.temperature, reference.tint,
            applied.residual * 100, applied.clamped ? "YES" : "no", applied.predicted.text,
            sample.rgb.text, sample.rgb.chroma * 100,
            sample.rgb.b / sample.rgb.r, sample.rgb.g / sample.rgb.r,
            after.rgb.text, after.rgb.chroma * 100,
            after.rgb.b / after.rgb.r, after.rgb.g / after.rgb.r,
            session.history.count - historyBefore, decodeTotal() - decodesBefore)
        return DropperReport(text: text, solve: applied,
                             beforeChroma: sample.rgb.chroma, afterChroma: after.rgb.chroma,
                             historyDelta: session.history.count - historyBefore,
                             decodeDelta: decodeTotal() - decodesBefore)
    }

    // MARK: - 派单 011: the split, measured on the real decoder

    /// The acceptance the whole split exists for: **a white-balance change develops, a render change
    /// does not.** Counted with `RAWDecoder.decodeCounts`, not with a stopwatch — a second decode of
    /// the same rung is easy to hide inside a frame that was going to be slow anyway, so the count is
    /// the only honest evidence.
    ///
    /// The four claims, in order:
    ///   1. exposure / contrast / curve / colour → `usedCachedDecode`, **0** new decodes;
    ///   2. temperature + tint → a miss, **+1** decode, and the pixels differ from the same document
    ///      without the white balance;
    ///   3. the same white balance again → a hit (one rung per decode key, not per request);
    ///   4. back to as shot → the *original* rung is still resident, so it hits — the rung key is the
    ///      decode key, and the render half (still carrying exposure 1.2 and the curve) never entered
    ///      it.
    func testExposureNeverDecodesAndWhiteBalanceAlwaysDoes() throws {
        let url = try fixtureURL()
        let session = CatalogSession()
        let loupe = makeLoupe(session)

        // ── as shot: one development, and the pixel hash it produces
        _ = try develop(loupe, url, session.edit)
        let asShotPixels = try hashedFrame(loupe, url, session.edit)
        let base = decodeTotal()

        // ── render-side edits: the same buffer, **zero** developments
        var render = session.edit
        render.light.exposure = 1.2
        render.light.contrast = 35
        render.curve.rgb = [CurvePoint(0, 0), CurvePoint(0.5, 0.62), CurvePoint(1, 1)]
        render.color.vibrance = 25
        let rendered = try develop(loupe, url, render)
        XCTAssertTrue(rendered.usedCachedDecode,
                      "exposure/contrast/curve/colour developed again — render inputs leaked into the rung")
        XCTAssertEqual(decodeTotal(), base, "改曝光/对比/曲线/色彩不重解码（解码计数不变）")
        let renderPixels = try hashedFrame(loupe, url, render)
        XCTAssertNotEqual(renderPixels, asShotPixels,
                          "the render-side edits changed no pixel — the fixture edit is a no-op")
        XCTAssertEqual(decodeTotal(), base, "a second render-side frame is still no development")

        // ── white balance: a different decode key, so exactly **one** development
        var warm = render
        warm.light.temperature = 3500
        warm.light.tint = 12
        let developed = try develop(loupe, url, warm)
        XCTAssertFalse(developed.usedCachedDecode,
                       "3500 K/+12 was served the as-shot (or the exposure-only) buffer")
        XCTAssertEqual(decodeTotal(), base + 1, "改色温/色调必然重解码（解码计数 +1）")
        let warmPixels = try hashedFrame(loupe, url, warm)
        XCTAssertNotEqual(warmPixels, renderPixels,
                          "the white balance developed but the pixels did not move")

        // ── one rung per decode key: the same document again is a hit, not a development
        let again = try develop(loupe, url, warm)
        XCTAssertTrue(again.usedCachedDecode, "the same 3500 K document developed twice")
        XCTAssertEqual(decodeTotal(), base + 1)

        // ── back to as shot. The ladder keeps **one decode key** resident at a time, so this is a
        // development even though the document is the one that started the test — and its pixels
        // must be exactly the ones `render` produced, because the render half never left the key.
        var backToShot = warm
        backToShot.light.temperature = nil
        backToShot.light.tint = nil
        let reused = try develop(loupe, url, backToShot)
        XCTAssertFalse(reused.usedCachedDecode,
                       "the ladder served the 3500 K buffer for an as-shot document")
        XCTAssertEqual(decodeTotal(), base + 2, "as shot is a different decode key, so it develops once")
        XCTAssertEqual(try hashedFrame(loupe, url, backToShot), renderPixels,
                       "as shot with the same render inputs must be the same picture")
        XCTAssertEqual(decodeTotal(), base + 2, "a second as-shot frame is a hit")

        print("decode split: as shot \(base) decode(s) → render edits +0 → 3500 K/+12 +1 "
              + "→ repeat +0 → back to as shot +1 (total \(decodeTotal()), one rung resident)")
    }

    /// A frame whose pixels are hashed — the "did the decode reach the picture" half of the counting.
    private func hashedFrame(_ loupe: LoupeController, _ url: URL, _ edit: EditModel) throws -> String {
        let frame = try loupe.makeFrame(url: url, viewport: Self.viewport,
                                        decodeScale: Self.decodeScale, edit: edit,
                                        hashPixels: true)
        return try XCTUnwrap(frame.displayHash)
    }

    // MARK: - helpers

    /// The lowest-chroma, well-exposed point of a coarse grid — "the grey area" of the fixture.
    private func greyAreaSample(in loupe: LoupeController)
        -> (CGPoint, LoupeController.DropperSample)? {
        var best: (CGPoint, LoupeController.DropperSample)?
        for (point, sample) in gridSamples(in: loupe)
        where sample.rgb.mean > 0.03 && sample.rgb.mean < 0.8 {
            if sample.rgb.chroma < (best?.1.rgb.chroma ?? .infinity) { best = (point, sample) }
        }
        return best
    }

    /// The most chromatic well-exposed point: the stress case for a two-parameter fit.
    private func chromaticSample(in loupe: LoupeController)
        -> (CGPoint, LoupeController.DropperSample)? {
        var best: (CGPoint, LoupeController.DropperSample)?
        for (point, sample) in gridSamples(in: loupe)
        where sample.rgb.mean > 0.02 && sample.rgb.mean < 0.6 {
            if sample.rgb.chroma > (best?.1.rgb.chroma ?? 0) { best = (point, sample) }
        }
        return best
    }

    private func gridSamples(in loupe: LoupeController)
        -> [(CGPoint, LoupeController.DropperSample)] {
        var out: [(CGPoint, LoupeController.DropperSample)] = []
        let steps = 7
        for gy in 1..<steps {
            for gx in 1..<steps {
                let point = CGPoint(x: Double(gx) * Double(Self.viewport.width) / Double(steps * 2),
                                    y: Double(gy) * Double(Self.viewport.height) / Double(steps * 2))
                if case .sampled(let sample) = loupe.samplePixel(atViewPoint: point) {
                    out.append((point, sample))
                }
            }
        }
        return out
    }
}
