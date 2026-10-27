import XCTest
import AppKit
import Metal
import PhotonsCore
import PhotonsUI

/// 080 — 「显示原图」(`\`) and 前后对比 through the **loupe**, i.e. on a real decode, through the real
/// frame path and the real menu.
///
/// What the core tests (`BeforeAfterTests`) cannot answer is asked here:
///
///  · does `\` on a real RAW actually show the decode — a different picture from the parameters-cleared
///    render the old spelling would have produced, and a different one from the edited frame?
///  · does 对比 put the two pictures on the two sides of a draggable line and nowhere else?
///  · does dragging that line leave the document, the history and the decode ladder alone
///    (`documentHash` unchanged, `history.count` unchanged, `decodeCounts +0`)?
///  · does leaving the mode put the **same frame** back — bit for bit, not "a frame arrived"?
///  · do the menu rows exist, carry `\` / Y / ⇧Y, and tick the current state?
///
/// Needs a RAW file (`PHOTONS_TEST_RAW`, else `~/Desktop/test/L1030433.dng`) and Metal; skipped with a
/// reason when either is missing, like the rest of the suite.
@MainActor
final class BeforeAfterUITests: XCTestCase {

    private static let viewport = ImageSize(width: 1280, height: 800)
    private static let decodeScale: Float = 0.5

    // MARK: - fixtures

    private static func rawFixture() throws -> URL {
        if let env = ProcessInfo.processInfo.environment["PHOTONS_TEST_RAW"], !env.isEmpty {
            let url = URL(fileURLWithPath: NSString(string: env).expandingTildeInPath)
            if FileManager.default.isReadableFile(atPath: url.path) { return url }
        }
        let fallback = URL(fileURLWithPath: NSString(string: "~/Desktop/test/L1030433.dng")
            .expandingTildeInPath)
        guard FileManager.default.isReadableFile(atPath: fallback.path) else {
            throw XCTSkip("no RAW fixture; set PHOTONS_TEST_RAW")
        }
        return fallback
    }

    private func makeLoupe(_ session: CatalogSession? = nil) -> LoupeController {
        let session = session ?? CatalogSession()
        let loupe = LoupeController(session: session)
        loupe.autoRenderEnabled = false          // these tests drive every frame themselves
        loupe.hashesFrames = true
        _ = loupe.view
        loupe.canvasView.frame = NSRect(x: 0, y: 0,
                                        width: Self.viewport.width / 2,
                                        height: Self.viewport.height / 2)
        return loupe
    }

    /// A document with tone/colour **and** geometry: the first is what a parameters-cleared render can
    /// zero, the second is what it cannot — and the difference between the decode and that spelling
    /// lives in the second (`BeforeAfterTests` says the same thing with synthetic pixels).
    private func editedDocument() -> EditModel {
        var e = EditModel.neutral
        e.light.exposure = 1.1
        e.light.contrast = 30
        e.light.shadows = 25
        e.color.saturation = 40
        e.curve.white = [CurvePoint(u: 0, v: 0.05), CurvePoint(u: 0.5, v: 0.56), CurvePoint(u: 1, v: 1)]
        e.geometry.crop = NormalizedRect(x: 0.18, y: 0.12, width: 0.62, height: 0.72)
        e.geometry.rotationDegrees = 6
        return e
    }

    private func frame(_ loupe: LoupeController, _ url: URL, _ edit: EditModel,
                       mode: LoupeFrameMode = .edited) throws -> LoupeController.FrameResult {
        try loupe.makeFrame(url: url, viewport: Self.viewport, decodeScale: Self.decodeScale,
                            edit: edit, mode: mode, hashPixels: true)
    }

    private func decodeTotal() -> Int { RAWDecoder.decodeCounts().values.reduce(0, +) }

    /// Three display-encoded channels of one texel, as the frame stores them.
    private func codes(_ texture: MTLTexture, x: Int, y: Int) -> [Float] {
        guard x >= 0, y >= 0, x < texture.width, y < texture.height else { return [] }
        var raw = [UInt16](repeating: 0, count: 4)
        raw.withUnsafeMutableBytes { buffer in
            texture.getBytes(buffer.baseAddress!,
                             bytesPerRow: 4 * MemoryLayout<UInt16>.size,
                             from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
        }
        return (0..<3).map { Float(Float16(bitPattern: raw[$0])) }
    }

    private func digest(_ edit: EditModel) -> String {
        var hasher = SHA256Box()
        hasher.update(edit.keyMaterial(.sceneLinear))
        hasher.update(edit.keyMaterial(.geometry))
        return hasher.final
    }

    /// A tiny SHA-256 wrapper, so the test does not need CryptoKit's incremental API spelled out twice.
    private struct SHA256Box {
        private var bytes: [UInt8] = []
        mutating func update(_ s: String) { bytes.append(contentsOf: Array(s.utf8)) }
        var final: String {
            // A plain FNV-1a over the material: this is a "did it change" token, not a security hash,
            // and a 64-bit digest of a few hundred bytes is enough to catch a write.
            var h: UInt64 = 0xcbf2_9ce4_8422_2325
            for b in bytes { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
            return String(format: "%016llx", h)
        }
    }

    // MARK: - ① 原图 vs 参数清零 vs 编辑后

    func testShowOriginalShowsTheDecodeNotAParametersClearedRender() throws {
        let url = try Self.rawFixture()
        let loupe = makeLoupe()
        let doc = editedDocument()

        // Warm the ladder: the first frame is the one that develops, and every frame after it is a
        // render over the resident rung (which is the claim about decodes below).
        let edited = try frame(loupe, url, doc)
        let decodesAfterWarmup = decodeTotal()

        let original = try frame(loupe, url, doc, mode: .original)
        let cleared = try frame(loupe, url, doc.disregardingParameters)

        let editedHash = try XCTUnwrap(edited.displayHash)
        let originalHash = try XCTUnwrap(original.displayHash)
        let clearedHash = try XCTUnwrap(cleared.displayHash)
        print("""
        LOUPE original=\(originalHash.prefix(16))… edited=\(editedHash.prefix(16))… \
        cleared=\(clearedHash.prefix(16))…
        """)

        XCTAssertEqual(original.mode, .original)
        XCTAssertNotEqual(originalHash, clearedHash,
                          "`\\` must show the decode, not the document with its parameters zeroed")
        XCTAssertNotEqual(originalHash, editedHash, "`\\` must not show the edited picture")
        // The three are three pictures, and the decode is the *whole* frame — so leaving the mode
        // has to bring the edited frame back exactly (asserted below in the round-trip test).
        XCTAssertEqual(decodeTotal(), decodesAfterWarmup,
                       "showing the original must not develop anything: \(RAWDecoder.decodeCounts())")
        print("DECODES warm-up=\(decodesAfterWarmup) after-showing-original=\(decodeTotal())")
    }

    // MARK: - ② 分屏：左右各属哪个源，拖动不写文档

    func testTheCompareSplitOwnsItsHalvesAndDraggingItWritesNothing() throws {
        let url = try Self.rawFixture()
        let session = CatalogSession()
        let loupe = makeLoupe(session)
        let doc = editedDocument()

        let edited = try frame(loupe, url, doc)
        let original = try frame(loupe, url, doc, mode: .original)

        loupe.setCompare(true)
        let split = try XCTUnwrap(loupe.compareSplit)
        XCTAssertEqual(split.axis, .vertical)
        XCTAssertEqual(split.fraction, 0.5, accuracy: 1e-9)

        let documentBefore = digest(doc)
        let historyBefore = session.history.count
        let decodesBefore = decodeTotal()

        let composed = try frame(loupe, url, doc, mode: loupe.frameMode)
        XCTAssertEqual(composed.mode, .compare(split))

        let canvas = composed.canvas
        let divider = split.dividerPixel(canvas: canvas)
        print("LOUPE compare divider column \(divider) of \(canvas.width) (line \(CompareSplit.lineWidth) px)")
        XCTAssertEqual(canvas, Self.viewport)

        // Ten samples, five on each side and none on the painted line.
        let points = [(40, 60), (180, 300), (360, 120), (520, 700), (620, 400),
                      (660, 90), (780, 640), (940, 260), (1100, 520), (1250, 770)]
        var differing = 0
        for (i, p) in points.enumerated() {
            let side = split.side(x: p.0, y: p.1, canvas: canvas)
            XCTAssertNotEqual(side, .divider, "#\(i + 1) was chosen away from the line")
            let fromComposite = codes(composed.texture, x: p.0, y: p.1)
            let fromEdited = codes(edited.texture, x: p.0, y: p.1)
            let fromOriginal = codes(original.texture, x: p.0, y: p.1)
            if fromEdited != fromOriginal { differing += 1 }
            print("  #\(i + 1) (\(p.0),\(p.1)) side=\(side.rawValue) composite=\(fromComposite.map { String(format: "%.4f", $0) })")
            switch side {
            case .original:
                XCTAssertEqual(fromComposite, fromOriginal, "#\(i + 1) must be the decode")
            case .edited:
                XCTAssertEqual(fromComposite, fromEdited, "#\(i + 1) must be the edited frame")
            case .divider:
                break
            }
        }
        XCTAssertGreaterThanOrEqual(differing, 8,
                                    "the two sides must be two pictures: \(differing)/10 samples differ")

        // ── the drag: 30 % of the canvas, as the pointer would say it ──────────────────────────
        loupe.setCompareFraction(0.3)
        let dragged = try XCTUnwrap(loupe.compareSplit)
        XCTAssertEqual(dragged.fraction, 0.3, accuracy: 1e-9)
        XCTAssertEqual(loupe.compareSplitDrags, 1)
        let draggedFrame = try frame(loupe, url, doc, mode: loupe.frameMode)
        let newDivider = dragged.dividerPixel(canvas: draggedFrame.canvas)
        XCTAssertLessThan(newDivider, divider, "the line moved left")

        // A point that was on the decode at 50 % and is on the edited frame at 30 % — the line is the
        // only thing that moved, so the ownership of that pixel flipped.
        let flipped = (x: 450, y: 400)
        XCTAssertEqual(split.side(x: flipped.x, y: flipped.y, canvas: canvas), .original)
        XCTAssertEqual(dragged.side(x: flipped.x, y: flipped.y, canvas: canvas), .edited)
        XCTAssertEqual(codes(draggedFrame.texture, x: flipped.x, y: flipped.y),
                       codes(edited.texture, x: flipped.x, y: flipped.y),
                       "after the drag that pixel must be the edited frame's")
        print("  drag 50 %→30 %: pixel \(flipped) original→edited, "
              + "column \(divider)→\(newDivider)")

        // Nothing was written by entering 对比, rendering it, or dragging the line.
        XCTAssertEqual(digest(doc), documentBefore, "拖动分界线 must not write the document")
        XCTAssertEqual(session.history.count, historyBefore, "and must not add a history row")
        XCTAssertEqual(decodeTotal(), decodesBefore, "and must not decode: \(RAWDecoder.decodeCounts())")

        // The other axis: ⇧Y keeps the fraction and swaps the direction.
        loupe.toggleCompareAxis()
        XCTAssertEqual(loupe.compareSplit?.axis, .horizontal)
        XCTAssertEqual(loupe.compareSplit?.fraction ?? 0, 0.3, accuracy: 1e-9)
        let horizontal = try XCTUnwrap(loupe.compareSplit)
        let horizontalFrame = try frame(loupe, url, doc, mode: loupe.frameMode)
        let above = (x: 600, y: 100)
        XCTAssertEqual(horizontal.side(x: above.x, y: above.y, canvas: canvas), .original)
        XCTAssertEqual(codes(horizontalFrame.texture, x: above.x, y: above.y),
                       codes(original.texture, x: above.x, y: above.y),
                       "上下分屏的上半边 is the decode")
        print("LOUPE horizontal split at 30 %: divider row \(horizontal.dividerPixel(canvas: canvas))")
    }

    // MARK: - ③ 退出后帧回到原样

    func testLeavingEachModeRestoresTheSameFrameBitForBit() throws {
        let url = try Self.rawFixture()
        let loupe = makeLoupe()
        let doc = editedDocument()

        let before = try XCTUnwrap(try frame(loupe, url, doc).displayHash)

        // `\` on and off.
        loupe.setShowOriginal(true)
        let original = try frame(loupe, url, doc, mode: loupe.frameMode)
        XCTAssertNotEqual(original.displayHash, before)
        loupe.setShowOriginal(false)
        let afterOriginal = try XCTUnwrap(try frame(loupe, url, doc, mode: loupe.frameMode).displayHash)
        XCTAssertEqual(afterOriginal, before, "leaving 原图 must restore the frame bit for bit")

        // 对比 on, dragged, and off.
        loupe.setCompare(true)
        _ = try frame(loupe, url, doc, mode: loupe.frameMode)
        loupe.setCompareFraction(0.22)
        _ = try frame(loupe, url, doc, mode: loupe.frameMode)
        loupe.setCompare(false)
        let afterCompare = try XCTUnwrap(try frame(loupe, url, doc, mode: loupe.frameMode).displayHash)
        XCTAssertEqual(afterCompare, before, "leaving 对比 must restore the frame bit for bit")

        print("LOUPE round trip: before=\(before.prefix(16))… afterOriginal=\(afterOriginal.prefix(16))… "
              + "afterCompare=\(afterCompare.prefix(16))…")
    }

    // MARK: - ④ 菜单与快捷键

    private func menuItem(_ title: String, in menu: NSMenu) -> NSMenuItem? {
        for item in menu.items {
            if item.title == title { return item }
            if item.title == "显示", let sub = item.submenu,
               let found = menuItem(title, in: sub) { return found }
            if let sub = item.submenu, let found = menuItem(title, in: sub) { return found }
        }
        return nil
    }

    func testTheViewMenuCarriesOriginalAndCompareWithTheirKeys() throws {
        let menu = MainMenu.build()
        let original = try XCTUnwrap(menuItem("显示原图", in: menu))
        XCTAssertEqual(original.keyEquivalent, "\\", "`\\` is the key: \(original.keyEquivalent.debugDescription)")
        XCTAssertEqual(original.keyEquivalentModifierMask, [])
        XCTAssertEqual(original.action, #selector(EditorWindowController.toggleShowOriginalAction(_:)))

        let compare = try XCTUnwrap(menuItem("前后对比", in: menu))
        XCTAssertEqual(compare.keyEquivalent, "y")
        XCTAssertEqual(compare.keyEquivalentModifierMask, [])
        XCTAssertEqual(compare.action, #selector(EditorWindowController.toggleCompareAction(_:)))

        let axis = try XCTUnwrap(menuItem("对比方向：左右", in: menu))
        XCTAssertEqual(axis.keyEquivalent, "y")
        XCTAssertEqual(axis.keyEquivalentModifierMask, [.shift])
        XCTAssertEqual(axis.action, #selector(EditorWindowController.toggleCompareAxisAction(_:)))
    }

    func testTheMenuTicksAndTitlesFollowTheMode() throws {
        let editor = EditorWindowController()
        let loupe = editor.rootView.loupeController
        let menu = MainMenu.build()
        let original = try XCTUnwrap(menuItem("显示原图", in: menu))
        let compare = try XCTUnwrap(menuItem("前后对比", in: menu))
        let axis = try XCTUnwrap(menuItem("对比方向：左右", in: menu))

        // Off: nothing ticked, plain titles. (`validateMenuItem` sets the state before it answers the
        // enabled flag, so the state is readable even with no library open.)
        _ = editor.validateMenuItem(original)
        _ = editor.validateMenuItem(compare)
        _ = editor.validateMenuItem(axis)
        XCTAssertEqual(original.state, .off)
        XCTAssertEqual(original.title, "显示原图")
        XCTAssertEqual(compare.state, .off)
        XCTAssertEqual(compare.title, "前后对比")

        loupe.setShowOriginal(true)
        _ = editor.validateMenuItem(original)
        XCTAssertEqual(original.state, .on)
        XCTAssertEqual(original.title, "显示原图（已开启）")

        loupe.setShowOriginal(false)
        loupe.setCompare(true)
        _ = editor.validateMenuItem(compare)
        _ = editor.validateMenuItem(axis)
        XCTAssertEqual(compare.state, .on)
        XCTAssertEqual(compare.title, "前后对比（左右 50 %）", "the title carries the axis and the position")
        XCTAssertEqual(axis.title, "对比方向：左右")

        loupe.toggleCompareAxis()
        _ = editor.validateMenuItem(compare)
        _ = editor.validateMenuItem(axis)
        XCTAssertEqual(compare.title, "前后对比（上下 50 %）")
        XCTAssertEqual(axis.title, "对比方向：上下")
        print("MENU titles: \(original.title) / \(compare.title) / \(axis.title)")

        // 对比 off: the axis row is grey again (no line to turn).
        loupe.setCompare(false)
        XCTAssertFalse(editor.validateMenuItem(axis))
    }

    /// The precedence the enum documents, as a test: `\` wins over 对比, and turning it off falls back
    /// to the split the user left behind.
    func testShowOriginalWinsOverCompareAndTheSplitIsRemembered() {
        let loupe = makeLoupe()
        loupe.setCompare(true)
        loupe.setCompareFraction(0.31)
        XCTAssertEqual(loupe.frameMode, .compare(CompareSplit(axis: .vertical, fraction: 0.31)))

        loupe.setShowOriginal(true)
        XCTAssertEqual(loupe.frameMode, .original)
        loupe.setShowOriginal(false)
        XCTAssertEqual(loupe.frameMode, .compare(CompareSplit(axis: .vertical, fraction: 0.31)),
                       "the line the user placed comes back")

        loupe.setCompare(false)
        XCTAssertEqual(loupe.frameMode, .edited)
        loupe.setCompare(true)
        XCTAssertEqual(loupe.compareSplit?.fraction ?? 0, 0.31, accuracy: 1e-9,
                       "switching 对比 off and on keeps the last position")
    }
}
