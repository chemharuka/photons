import XCTest
import AppKit
import SwiftUI
import PhotonsCatalog
@testable import PhotonsUI

/// 派单 014: the inspector's shooting-information block.
///
/// Three claims, each with a number instead of an adjective:
///   · the strings — full line, every missing-slot combination, and the four equipment cases;
///   · the width — every `MarqueeText` row is the card content width, not its text width;
///   · the march — head + `…` at rest, a linear pass that stops exactly at `-(textWidth − width)`
///     and stays there, and no movement at all when the text already fits.
final class InspectorMetadataTests: XCTestCase {

    private let inspectorWidth: CGFloat = 330
    /// `330 − 2·12 (scroll inset) − 2·16 (card inset)`, the width every card's content gets.
    private var cardContentWidth: CGFloat { cardContentWidth(forPanelWidth: inspectorWidth) }

    /// The same subtraction for any inspector width (300…364 at run time; 330 / 274 / 244 are the
    /// three the publicity shots use).
    private func cardContentWidth(forPanelWidth width: CGFloat) -> CGFloat {
        width - 2 * 12 - 2 * WorkspaceLayout.cardInsetH
    }

    // MARK: format rules

    /// The row is four *tokens*, laid out by `InspectorParameterRow` in equal-width slots — ISO
    /// flush left, shutter flush right, focal length and aperture centred. Nothing is space-padded
    /// any more, so a token must never carry its own surrounding whitespace.
    func testParameterTokensAreUnpaddedAndOrdered() {
        let t = InspectorPhotoInfo.tokens(iso: 100, focalLength: 24, aperture: 2.8, shutter: "1/250")
        XCTAssertEqual(t.iso, "ISO 100")
        XCTAssertEqual(t.focal, "24 mm")
        XCTAssertEqual(t.aperture, "f/2.8")
        XCTAssertEqual(t.shutter, "1/250s")
        for token in t.all {
            XCTAssertEqual(token, token.trimmingCharacters(in: .whitespaces),
                           "\(token) must not carry padding — the slots do the aligning")
        }
    }

    func testParametersLineJoinsTheTokensForAccessibility() {
        XCTAssertEqual(
            InspectorPhotoInfo.parameters(iso: 100, focalLength: 24, aperture: 2.8, shutter: "1/250"),
            "ISO 100 · 24 mm · f/2.8 · 1/250s")
        XCTAssertEqual(
            InspectorPhotoInfo.parameters(iso: 3200, focalLength: 24.5, aperture: 1.4, shutter: "2"),
            "ISO 3200 · 24.5 mm · f/1.4 · 2s")
    }

    /// The four slots are equal width (`maxWidth: .infinity` each), so the shutter column cannot move
    /// when the values change — that is the whole reason the padded string went away.
    func testParameterRowGivesEveryFieldTheSameSlotWidth() {
        let a = InspectorPhotoInfo.tokens(iso: 100, focalLength: 24, aperture: 2.8, shutter: "1/250")
        let b = InspectorPhotoInfo.tokens(iso: 102_400, focalLength: 8000, aperture: 32, shutter: "1/8000")
        XCTAssertEqual(a.all.count, 4)
        XCTAssertEqual(b.all.count, 4)
        // The widest possible row still fits the card content width at 10 pt monospaced.
        let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        let widest = b.all.reduce(CGFloat.zero) { $0 + ($1 as NSString).size(withAttributes: [.font: font]).width }
        XCTAssertLessThan(widest, cardContentWidth,
                          "the widest row (\(widest) pt) must fit \(cardContentWidth) pt")
    }

    func testParametersLineKeepsAllFourSlotsWhenTheFileIsSilent() {
        XCTAssertEqual(InspectorPhotoInfo.parameters(iso: nil, focalLength: nil, aperture: nil, shutter: nil),
                       "ISO — · — mm · f/— · —")
        // One missing slot does not shorten the line: same separators, same order.
        XCTAssertEqual(InspectorPhotoInfo.parameters(iso: 100, focalLength: nil, aperture: 2.8, shutter: nil),
                       "ISO 100 · — mm · f/2.8 · —")
        XCTAssertEqual(InspectorPhotoInfo.parameters(iso: nil, focalLength: 35, aperture: nil, shutter: "1/125"),
                       "ISO — · 35 mm · f/— · 1/125s")
    }

    func testShutterAcceptsBothSpellings() {
        XCTAssertEqual(InspectorPhotoInfo.shutter("1/250"), "1/250s")
        XCTAssertEqual(InspectorPhotoInfo.shutter("1/250s"), "1/250s")
        XCTAssertEqual(InspectorPhotoInfo.shutter("  2 "), "2s")
        XCTAssertNil(InspectorPhotoInfo.shutter("   "))
        XCTAssertNil(InspectorPhotoInfo.shutter(nil))
    }

    /// The four cases the user pinned, character for character (separator ` · `, placeholders
    /// `未知相机` / `未知镜头`).
    func testEquipmentLineFourCases() {
        // both
        XCTAssertEqual(InspectorPhotoInfo.equipment(make: "Leica Camera AG", model: "Leica SL3",
                                                    lens: "Sigma 20-60 DG"),
                       "Leica SL3 · Sigma 20-60 DG")
        // camera only
        XCTAssertEqual(InspectorPhotoInfo.equipment(make: "Leica Camera AG", model: "Leica SL3", lens: nil),
                       "Leica SL3 · 未知镜头")
        // lens only
        XCTAssertEqual(InspectorPhotoInfo.equipment(make: nil, model: nil, lens: "Sigma 20-60 DG"),
                       "未知相机 · Sigma 20-60 DG")
        // neither: one word, no separator, no second placeholder
        XCTAssertEqual(InspectorPhotoInfo.equipment(make: nil, model: nil, lens: nil), "未知相机")
        XCTAssertEqual(InspectorPhotoInfo.equipment(make: "  ", model: nil, lens: "   "), "未知相机")
    }

    /// The make is a fallback, never a prefix: `Leica Camera AG · Leica SL3` is too long for 274 pt.
    func testCameraPrefersTheModelAndFallsBackToTheMake() {
        XCTAssertEqual(InspectorPhotoInfo.cameraName(make: "Leica Camera AG", model: "Leica SL3"), "Leica SL3")
        XCTAssertEqual(InspectorPhotoInfo.cameraName(make: "Leica Camera AG", model: nil), "Leica Camera AG")
        XCTAssertNil(InspectorPhotoInfo.cameraName(make: nil, model: "   "))
    }

    // MARK: width

    /// The rows come out of a real `NSHostingView` at the default 330 pt inspector, so this is the
    /// width SwiftUI actually handed them — not a constant read back from a constant.
    ///
    /// The count moves 2 → 3 because 派单 022 splits the one equipment marquee into two (相机 /
    /// 镜头): the file name, the camera and the lens are now three marquees. The new pixel-count
    /// and dimension cells are plain `Text` and add no marquee — their geometry is proven by the
    /// probes in `testFirstRowIsNameLeftPixelsCentreDimensionsRight`, not here.
    ///
    /// The width claim has to be split for the same reason: the file name shares its line with the
    /// two value cells, so it is the *left column* (its `minX` is still the content's left edge,
    /// its width is what is left before `60 MP`), while 相机 and 镜头 still span the whole content.
    @MainActor
    func testInfoRowsTakeExactlyTheCardContentWidth() throws {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: InspectorView(session: CatalogSession()))
        host.frame = NSRect(x: 0, y: 0, width: inspectorWidth, height: 800)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()

        let rows = Self.marqueeRows(in: host)
        XCTAssertEqual(rows.count, 3, "file name + camera + lens are marquees; the two value cells and the exposure row are not")
        guard rows.count == 3 else { return }

        let frames = rows.map { $0.convert($0.bounds, to: host) }
        // 12 (panel inset) + 16 (card inset): where every card's content starts.
        let contentMinX: CGFloat = 12 + WorkspaceLayout.cardInsetH
        for (index, frame) in frames.enumerated() {
            XCTAssertEqual(frame.minX, contentMinX, accuracy: 0.5,
                           "row \(index) starts at \(frame.minX), not at the content's \(contentMinX)")
            XCTAssertLessThanOrEqual(frame.maxX, contentMinX + cardContentWidth + 0.5,
                                     "row \(index) runs past the card content")
            XCTAssertEqual(rows[index].lineHeight, 14, accuracy: 0.001, "one rhythm for all rows")
        }
        // 相机 and 镜头 are alone on their lines, so they take the full content width.
        for index in [1, 2] {
            XCTAssertEqual(frames[index].width, cardContentWidth, accuracy: 0.5,
                           "row \(index) width \(frames[index].width) ≠ card content \(cardContentWidth)")
        }
        XCTAssertLessThan(frames[0].width, cardContentWidth,
                          "the file name shares its line with 60 MP and 9000×6000")
        print("MARQUEE width: inspector \(inspectorWidth) → card content \(cardContentWidth) pt; "
              + "rows \(frames.map { String(format: "%.1f", $0.width) })")
        window.contentView = nil
    }

    // MARK: 四行：文件名/像素数/尺寸 · 相机 · 镜头 · 参数 (派单 022)

    /// The two formatters, branch by branch — the table the user pinned.
    func testPixelCountAndDimensionsFormatting() {
        let cases: [(width: Int?, height: Int?, megapixels: String, dimensions: String)] = [
            (9000, 6000, "54 MP", "9000×6000"),
            (6000, 4000, "24 MP", "6000×4000"),
            (2000, 1000, "2 MP", "2000×1000"),
            (1000, 900, "0.9 MP", "1000×900"),
            (nil, nil, "—", "—"),
            (nil, 6000, "—", "—"),
            (9000, nil, "—", "—"),
        ]
        for c in cases {
            let size = "\(c.width.map(String.init) ?? "nil")×\(c.height.map(String.init) ?? "nil")"
            XCTAssertEqual(InspectorPhotoInfo.pixelCount(width: c.width, height: c.height), c.megapixels,
                           "pixel count of \(size)")
            XCTAssertEqual(InspectorPhotoInfo.pixelDimensions(width: c.width, height: c.height), c.dimensions,
                           "dimensions of \(size)")
        }

        // The two shapes the user spelled out: one space before `MP`, no space around the `×`,
        // and the multiplication sign is U+00D7 (not the letter x, not `*`).
        XCTAssertEqual(InspectorPhotoInfo.pixelCount(width: 5500, height: 4400), "24 MP",
                       "24.2 MP rounds to the nearest megapixel")
        XCTAssertTrue(InspectorPhotoInfo.pixelCount(width: 9000, height: 6000).hasSuffix(" MP"))
        XCTAssertFalse(InspectorPhotoInfo.pixelCount(width: 9000, height: 6000).contains("54MP"))
        XCTAssertEqual(InspectorPhotoInfo.pixelDimensions(width: 9000, height: 6000).unicodeScalars
                        .filter { $0.value == 0x00D7 }.count, 1)
        XCTAssertFalse(InspectorPhotoInfo.pixelDimensions(width: 9000, height: 6000).contains(" "))

        // No label anywhere on the row: only digits, the `×`, `MP` and the dash are allowed.
        let allowed = Set("0123456789. ×MP—")
        for text in [InspectorPhotoInfo.pixelCount(width: 9000, height: 6000),
                     InspectorPhotoInfo.pixelDimensions(width: 9000, height: 6000),
                     InspectorPhotoInfo.pixelCount(width: 1000, height: 900),
                     InspectorPhotoInfo.pixelCount(width: nil, height: nil)] {
            XCTAssertTrue(text.allSatisfy { allowed.contains($0) }, "「\(text)」 carries a label")
        }

        // Branches the table does not list but the code has to answer: exactly one megapixel stays
        // an integer (`1 MP`), and `round()` at a half goes away from zero (`2.5` → `3 MP`).
        XCTAssertEqual(InspectorPhotoInfo.pixelCount(width: 1000, height: 1000), "1 MP")
        XCTAssertEqual(InspectorPhotoInfo.pixelCount(width: 2000, height: 1250), "3 MP")

        print("SPEC format: "
              + [(9000, 6000), (6000, 4000), (2000, 1000), (1000, 900), (1000, 1000)]
                .map { "\($0.0)×\($0.1) → \(InspectorPhotoInfo.pixelCount(width: $0.0, height: $0.1))"
                       + " / \(InspectorPhotoInfo.pixelDimensions(width: $0.0, height: $0.1))" }
                .joined(separator: " · ")
              + " · nil → \(InspectorPhotoInfo.pixelCount(width: nil, height: nil))"
              + " / \(InspectorPhotoInfo.pixelDimensions(width: nil, height: nil))")
    }

    /// 拆行不改文案: 相机 and 镜头 are exactly the two halves the old single `equipment` row printed,
    /// and neither carries the `·` the join used (派单 022:「信息栏目前不需要任何 · 符号」).
    func testCameraAndLensAreTheEquipmentHalvesWithoutASeparator() {
        XCTAssertEqual(InspectorPhotoInfo.camera(make: "Leica Camera AG", model: "Leica SL3"), "Leica SL3")
        XCTAssertEqual(InspectorPhotoInfo.lens("Vario-Elmarit-SL 24-90"), "Vario-Elmarit-SL 24-90")
        // The old line is now the join of the two rows, word for word.
        XCTAssertEqual(InspectorPhotoInfo.equipment(make: "Leica Camera AG", model: "Leica SL3",
                                                    lens: "Vario-Elmarit-SL 24-90"),
                       "\(InspectorPhotoInfo.camera(make: "Leica Camera AG", model: "Leica SL3"))"
                       + " · "
                       + "\(InspectorPhotoInfo.lens("Vario-Elmarit-SL 24-90"))")

        // The fallbacks are the existing constants, not new words.
        XCTAssertEqual(InspectorPhotoInfo.camera(make: "Leica Camera AG", model: nil), "Leica Camera AG")
        XCTAssertEqual(InspectorPhotoInfo.camera(make: nil, model: "  "), InspectorPhotoInfo.unknownCamera)
        XCTAssertEqual(InspectorPhotoInfo.lens(nil), InspectorPhotoInfo.unknownLens)
        XCTAssertEqual(InspectorPhotoInfo.lens("   "), InspectorPhotoInfo.unknownLens)

        for row in [InspectorPhotoInfo.camera(make: "Leica Camera AG", model: "Leica SL3"),
                    InspectorPhotoInfo.camera(make: nil, model: nil),
                    InspectorPhotoInfo.lens("Vario-Elmarit-SL 24-90"),
                    InspectorPhotoInfo.lens(nil)] {
            XCTAssertFalse(row.contains("·"), "「\(row)」 is a bare name, with no separator")
        }
    }

    /// 第 1 行是一行三列, but the two value columns are **right-packed**: `9000×6000` ends on the
    /// content's right edge, `54 MP` ends exactly `columnGap` before that column's left edge, and
    /// the file name gets everything that is left.
    ///
    /// This is the assertion that goes red when the middle column is centred again: centring puts
    /// `54 MP`'s right edge near the content's mid-line instead of at `尺寸列左边缘 − gap`, and the
    /// name's width follows it down (113 pt instead of 169 pt at 330).
    ///
    /// The values are bounded in width (六位数封顶: `999999×999999` = `999998 MP`), which is what
    /// makes right-packing safe: the worst string either column can print still leaves the name a
    /// real column at the narrowest legal panel. Nothing reserves that worst case in the layout —
    /// reserving it would cost the name 56 pt, the exact amount centring wasted — so the guard is
    /// asserted here instead, on the measured widths.
    @MainActor
    func testFirstRowHugsTheRightEdgeAndGivesTheRestToTheFileName() throws {
        let (session, asset) = try makeSession(width: 9000, height: 6000,
                                               make: "Leica Camera AG", model: "Leica SL3",
                                               lens: "Vario-Elmarit-SL 24-90")
        let font = NSFont.systemFont(ofSize: InspectorPhotoInfo.PhotoSpecRow.fontSize)
        let gap = InspectorPhotoInfo.PhotoSpecRow.columnGap
        // The two worst strings either column can print, measured with the real font.
        let worstCount = MarqueeLayout.width(of: "999998 MP", font: font)
        let worstDims = MarqueeLayout.width(of: "999999×999999", font: font)
        // 300 is `WorkspaceLayout.inspectorWidthMin` — the narrowest panel the app allows.
        let narrowest = cardContentWidth(forPanelWidth: WorkspaceLayout.inspectorWidthMin)
        XCTAssertGreaterThan(narrowest - worstCount - worstDims - 2 * gap, 60,
                             "a 6×6 worst case leaves the file name almost nothing "
                             + "(\(narrowest - worstCount - worstDims - 2 * gap) pt at the narrowest panel)")

        for panelWidth in [330.0, 274.0, 244.0] as [CGFloat] {
            let panel = try host(session, width: panelWidth)
            defer { panel.window.contentView = nil }

            // The four rows, in order: 文件名 / 54 MP / 9000×6000 (one line), 相机, 镜头, then the
            // existing four-slot parameter row (pinned by `testParameterTokensAreUnpaddedAndOrdered`).
            XCTAssertEqual(panel.marquees.map(\.text),
                           [asset.filename, "Leica SL3", "Vario-Elmarit-SL 24-90"],
                           "row 1 carries the file name, row 2 the camera, row 3 the lens")
            XCTAssertEqual(panel.probes[InspectorPhotoInfo.SpecColumn.pixelCount.rawValue]?.text, "54 MP")
            XCTAssertEqual(panel.probes[InspectorPhotoInfo.SpecColumn.pixelDimensions.rawValue]?.text, "9000×6000")

            let contentWidth = cardContentWidth(forPanelWidth: panelWidth)
            let contentMinX: CGFloat = 12 + WorkspaceLayout.cardInsetH
            let contentMaxX = contentMinX + contentWidth
            let name = panel.marquees[0].frame
            let count = try XCTUnwrap(panel.probes[InspectorPhotoInfo.SpecColumn.pixelCount.rawValue])
            let dims = try XCTUnwrap(panel.probes[InspectorPhotoInfo.SpecColumn.pixelDimensions.rawValue])

            // 尺寸 flush right on the content edge, 像素数 one gap before that column's left edge.
            XCTAssertEqual(dims.maxX, contentMaxX, accuracy: 0.5,
                           "9000×6000 maxX \(dims.maxX) ≠ content maxX \(contentMaxX)")
            XCTAssertEqual(count.maxX, dims.minX - gap, accuracy: 0.5,
                           "60 MP maxX \(count.maxX) ≠ 尺寸's minX \(dims.minX) − gap \(gap)")
            // It hugs the right instead of sitting in the middle: the old centring put maxX near
            // the mid-line, which is where this assertion fails if anyone restores `bounds.midX`.
            XCTAssertGreaterThan(count.maxX, contentMinX + contentWidth / 2 + gap,
                                 "60 MP still sits in the middle of the row")
            // The file name gets exactly the room left before 60 MP — this is the width claim, and
            // it is absolute: `content − gap − 54 MP − gap − 9000×6000`, both values measured with
            // the row's own font. Centring `54 MP` hands back 113.5 pt here instead of 168.5, so
            // this is the assertion that fails if the middle column is ever centred again.
            let expectedNameWidth = contentWidth - 2 * gap
                - MarqueeLayout.width(of: "54 MP", font: font)
                - MarqueeLayout.width(of: "9000×6000", font: font)
            XCTAssertEqual(name.minX, contentMinX, accuracy: 0.5,
                           "file name minX \(name.minX) ≠ content minX \(contentMinX)")
            XCTAssertEqual(name.width, expectedNameWidth, accuracy: 1,
                           "file name column \(name.width) pt ≠ the room left before 60 MP "
                           + "(\(expectedNameWidth) pt) at panel \(panelWidth)")
            // No overlap on the line: the marquee's own frame ends before the value columns.
            XCTAssertLessThanOrEqual(name.maxX, count.minX - gap + 0.01,
                                     "the name runs into 60 MP")
            XCTAssertLessThanOrEqual(count.maxX, dims.minX - gap + 0.01,
                                     "60 MP runs into 9000×6000")
            // Neither value is elided: SwiftUI gave each its whole measured width.
            XCTAssertEqual(count.width, MarqueeLayout.width(of: "54 MP", font: font), accuracy: 1,
                           "54 MP is not drawn at its natural width (\(count.width) pt)")
            XCTAssertEqual(dims.width, MarqueeLayout.width(of: "9000×6000", font: font), accuracy: 1,
                           "9000×6000 is not drawn at its natural width (\(dims.width) pt)")
            XCTAssertLessThanOrEqual(count.width, worstCount + 0.01,
                                     "54 MP is wider than the 6-digit bound")
            XCTAssertLessThanOrEqual(dims.width, worstDims + 0.01,
                                     "9000×6000 is wider than the 6-digit bound")
            // One baseline: the values sit on the name's line, not above or below it.
            for cell in [count, dims] {
                XCTAssertEqual(cell.minY, name.minY, accuracy: 1,
                               "a value left the name's line (minY \(cell.minY) vs \(name.minY))")
                XCTAssertEqual(cell.height, 12, accuracy: 1, "value cell height moved: \(cell.height)")
            }
            // No `·` in any of the four rows' visible text (派单 022).
            for text in panel.marquees.map(\.text) + [count.text, dims.text] {
                XCTAssertFalse(text.contains("·"), "「\(text)」 carries a separator")
            }

            print(String(format: "SPEC row1 @%.0f: content %.0f..%.0f (%.0f pt) · "
                         + "name x%.1f w%.1f · count x%.1f w%.1f maxX%.1f · "
                         + "dims x%.1f w%.1f maxX%.1f · y%.1f h%.1f",
                         panelWidth, contentMinX, contentMaxX, contentWidth,
                         name.minX, name.width,
                         count.minX, count.width, count.maxX,
                         dims.minX, dims.width, dims.maxX,
                         name.minY, name.height))
            print(String(format: "SPEC rows @%.0f: name y%.1f h%.1f · camera y%.1f h%.1f · "
                         + "lens y%.1f h%.1f",
                         panelWidth, panel.marquees[0].frame.minY, panel.marquees[0].frame.height,
                         panel.marquees[1].frame.minY, panel.marquees[1].frame.height,
                         panel.marquees[2].frame.minY, panel.marquees[2].frame.height))
        }
    }

    /// How many characters the file name keeps at each inspector width — the number the change is
    /// for. `L100000.dng` (11 characters) must fit whole; a 40-character name must keep more of
    /// itself than it did when `54 MP` was centred (18 / 9 / 3 characters at 330 / 274 / 244).
    @MainActor
    func testFileNameKeepsMoreCharactersAtEveryWidth() throws {
        let font = NSFont.systemFont(ofSize: InspectorPhotoInfo.PhotoSpecRow.fontSize)
        let gap = InspectorPhotoInfo.PhotoSpecRow.columnGap
        let long = "2026-10-27_L1000123_Leica_SL3_ISO100.dng"
        XCTAssertEqual(long.count, 40, "the long case is meant to be a twice-the-column name")

        // The name column the row hands the marquee: content − gap − 54 MP − gap − 9000×6000.
        func nameColumn(_ panelWidth: CGFloat) -> CGFloat {
            cardContentWidth(forPanelWidth: panelWidth) - 2 * gap
                - MarqueeLayout.width(of: "54 MP", font: font)
                - MarqueeLayout.width(of: "9000×6000", font: font)
        }
        // Baseline, measured before the change with the middle column centred: 18 / 9 / 3 of 40.
        let baseline = [330.0: 18, 274.0: 9, 244.0: 3]

        for panelWidth in [330.0, 274.0, 244.0] as [CGFloat] {
            let width = nameColumn(panelWidth)
            for text in ["L100000.dng", long] {
                let row = MarqueeRowView(text: text, font: font, lineHeight: 14)
                row.frame = NSRect(x: 0, y: 0, width: width, height: 14)
                row.layout()
                print(String(format: "SPEC trunc @%.0f: name column %.1f pt · textWidth %.1f · "
                             + "overflow %.1f · keeps %d/%d chars → 「%@」",
                             panelWidth, width, row.textWidth,
                             row.textWidth - width, row.truncatedText.count, text.count,
                             row.truncatedText))
                if text == "L100000.dng" {
                    XCTAssertFalse(row.isOverflowing, "L100000.dng does not fit in \(width) pt")
                    XCTAssertEqual(row.truncatedText, text, "a short name was cut: \(row.truncatedText)")
                } else {
                    XCTAssertTrue(row.isOverflowing, "the 40-character name fits — nothing to test")
                    XCTAssertTrue(row.truncatedText.hasSuffix("…"), "no tail ellipsis")
                    XCTAssertGreaterThan(row.truncatedText.count, baseline[panelWidth] ?? 0,
                                         "the name kept no more characters than when 60 MP was "
                                         + "centred (\(baseline[panelWidth] ?? 0) of 40)")
                }
            }
        }
    }

    /// 缺值不塌行: no width/height → `—`, no camera/lens → 未知相机 / 未知镜头, no photo → 未选择照片,
    /// and every row keeps the height and the y it has with values.
    @MainActor
    func testMissingValuesPrintDashesAndKeepTheRowHeights() throws {
        let (full, _) = try makeSession(width: 9000, height: 6000,
                                        make: "Leica Camera AG", model: "Leica SL3",
                                        lens: "Vario-Elmarit-SL 24-90")
        let (bare, asset) = try makeSession(width: nil, height: nil, make: nil, model: nil, lens: nil)
        let withValues = try host(full)
        let withNothing = try host(bare)
        let empty = try host(CatalogSession())
        defer {
            for panel in [withValues, withNothing, empty] { panel.window.contentView = nil }
        }

        XCTAssertEqual(withNothing.marquees.map(\.text), [asset.filename, "未知相机", "未知镜头"])
        XCTAssertEqual(withNothing.probes[InspectorPhotoInfo.SpecColumn.pixelCount.rawValue]?.text, "—")
        XCTAssertEqual(withNothing.probes[InspectorPhotoInfo.SpecColumn.pixelDimensions.rawValue]?.text, "—")

        XCTAssertEqual(empty.marquees.first?.text, "未选择照片")
        XCTAssertEqual(empty.probes[InspectorPhotoInfo.SpecColumn.pixelCount.rawValue]?.text, "—")
        XCTAssertEqual(empty.probes[InspectorPhotoInfo.SpecColumn.pixelDimensions.rawValue]?.text, "—")

        for column in [InspectorPhotoInfo.SpecColumn.pixelCount, .pixelDimensions] {
            let filled = try XCTUnwrap(withValues.probes[column.rawValue])
            for other in [try XCTUnwrap(withNothing.probes[column.rawValue]),
                          try XCTUnwrap(empty.probes[column.rawValue])] {
                XCTAssertEqual(other.height, filled.height, accuracy: 0.5,
                               "the \(column.rawValue) cell collapsed without a value")
                XCTAssertEqual(other.minY, filled.minY, accuracy: 0.5,
                               "the \(column.rawValue) cell moved without a value")
            }
        }
        for index in 0 ..< 3 {
            XCTAssertEqual(withNothing.marquees[index].frame.minY, withValues.marquees[index].frame.minY,
                           accuracy: 0.5, "row \(index) moved when a value went missing")
            XCTAssertEqual(withNothing.marquees[index].frame.height, withValues.marquees[index].frame.height,
                           accuracy: 0.5, "row \(index) changed height when a value went missing")
            XCTAssertEqual(empty.marquees[index].frame.minY, withValues.marquees[index].frame.minY,
                           accuracy: 0.5, "row \(index) moved with no photo selected")
        }
        print("SPEC missing: nil size → — / —, no camera/lens → 未知相机 / 未知镜头, rows keep 14 pt")
    }

    // MARK: overflow / marquee

    func testLongTextTruncatesAndPlaysOnceToTheEnd() throws {
        let font = NSFont.systemFont(ofSize: 10)
        let long = "Vario-Elmarit-SL 1:2.8-4/24-90 ASPH. Leica Camera AG Wetzlar Germany"
        let row = MarqueeRowView(text: long, font: font, lineHeight: 14)
        row.frame = NSRect(x: 0, y: 0, width: cardContentWidth, height: 14)
        row.layout()

        XCTAssertTrue(row.isOverflowing)
        XCTAssertEqual(row.offset, 0, "at rest the row shows the head")
        XCTAssertTrue(row.truncatedText.hasSuffix("…"), "tail ellipsis at rest: \(row.truncatedText)")
        XCTAssertLessThan(row.truncatedText.count, long.count)

        let overflow = row.textWidth - cardContentWidth
        XCTAssertEqual(overflow, MarqueeLayout.overflow(textWidth: row.textWidth, width: cardContentWidth),
                       accuracy: 0.001)
        XCTAssertEqual(row.duration, MarqueeLayout.duration(overflow: overflow), accuracy: 0.0001)
        print("MARQUEE overflow: textWidth \(String(format: "%.1f", row.textWidth)) pt, width \(cardContentWidth) pt, "
              + "overflow \(String(format: "%.1f", overflow)) pt, duration \(String(format: "%.3f", row.duration)) s, "
              + "chars at rest \(row.truncatedText.count) of \(long.count)")

        // Hover: one pass, linear.
        row.setHovering(true)
        XCTAssertEqual(row.playCount, 1)
        XCTAssertTrue(row.isPlaying)

        row.advance(to: row.duration / 2)
        XCTAssertEqual(row.offset, -overflow / 2, accuracy: 0.5, "half the time is half the distance")

        row.advance(to: row.duration)
        XCTAssertEqual(row.offset, -overflow, accuracy: 0.001,
                       "end offset is exactly -(textWidth - width) = \(-(overflow))")
        XCTAssertFalse(row.isPlaying, "the timer stops at the end")
        let endOffset = row.offset

        // Only once: half a second later it is still parked on the last character.
        row.advance(to: row.duration + 0.5)
        XCTAssertEqual(row.offset, endOffset, accuracy: 0.001)
        XCTAssertFalse(row.isPlaying)
        XCTAssertEqual(row.playCount, 1)
        print("MARQUEE end: offset \(String(format: "%.1f", endOffset)) pt, expected \(String(format: "%.1f", -overflow)) pt, "
              + "playCount \(row.playCount), idle after +0.5 s offset \(String(format: "%.1f", row.offset)) pt")

        // Hover off: straight back to the head, and the ellipsis returns.
        row.setHovering(false)
        XCTAssertEqual(row.offset, 0)
        XCTAssertFalse(row.isPlaying)
        XCTAssertTrue(row.truncatedText.hasSuffix("…"))
    }

    func testShortTextNeverMovesAndNeverGetsAnEllipsis() {
        let font = NSFont.systemFont(ofSize: 10)
        let short = "ISO 100 · 24 mm · f/2.8 · 1/250s"
        let row = MarqueeRowView(text: short, font: font, lineHeight: 14)
        row.frame = NSRect(x: 0, y: 0, width: cardContentWidth, height: 14)
        row.layout()

        XCTAssertFalse(row.isOverflowing)
        XCTAssertEqual(row.truncatedText, short, "no ellipsis when it fits")
        XCTAssertEqual(row.duration, 0)

        row.setHovering(true)
        XCTAssertEqual(row.playCount, 0, "nothing to play")
        XCTAssertFalse(row.isPlaying)
        XCTAssertEqual(row.offset, 0)

        row.advance(to: 2.0)
        XCTAssertEqual(row.offset, 0)
        row.setHovering(false)
        XCTAssertEqual(row.offset, 0)
        print("MARQUEE fit: textWidth \(String(format: "%.1f", row.textWidth)) pt ≤ \(cardContentWidth) pt, "
              + "offset 0, no ellipsis")
    }

    /// The duration formula the report quotes, at both clamps.
    func testDurationClampsToFourTenthsAndThreeSeconds() {
        XCTAssertEqual(MarqueeLayout.duration(overflow: 6), 0.4, accuracy: 0.0001)     // 0.1 s → floor
        XCTAssertEqual(MarqueeLayout.duration(overflow: 60), 1.0, accuracy: 0.0001)    // 60 pt/s
        XCTAssertEqual(MarqueeLayout.duration(overflow: 600), 3.0, accuracy: 0.0001)   // 10 s → ceiling
        XCTAssertEqual(MarqueeLayout.duration(overflow: 0), 0, accuracy: 0.0001)
    }

    // MARK: fixture library (派单 022)

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-inspector-spec-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    /// One real library with one photo in it, so the inspector reads a *database's* filename and
    /// width/height instead of a constant handed to the view.
    ///
    /// The row is written with SQL rather than through `ImportService`: there is no public
    /// "set the dimensions" API, and importing a 54 MP original just to read `54 MP` back would
    /// make the test about the importer. Everything else is the real path — `Catalog.create`,
    /// `ensureRoot`, `CatalogSession.open`, `selectOnly` — so the value the panel prints comes out
    /// of `assets.width`/`assets.height` exactly as in the app.
    @MainActor
    private func makeSession(width: Int?, height: Int?,
                             make: String?, model: String?, lens: String?) throws -> (CatalogSession, Asset) {
        _ = NSApplication.shared
        let folder = workDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let package = folder.appendingPathComponent("Spec.\(LibraryLayout.packageExtension)")
        let catalog = try Catalog.create(at: package)
        let src = folder.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let root = try catalog.ensureRoot(for: src, mode: .reference)

        let name = "L100000.dng"
        // The original sits where the row says it does: 「原文件已移动」 is not what this is about.
        try Data([0x00]).write(to: src.appendingPathComponent(name))

        func sqlText(_ value: String?) -> String {
            value.map { "'" + $0.replacingOccurrences(of: "'", with: "''") + "'" } ?? "NULL"
        }

        let id = UUID().uuidString
        try catalog.dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO assets (id, source_root_id, rel_path, filename, ext, kind, size, mtime,
                                    content_hash, width, height, camera_make, camera_model, lens,
                                    imported_at, missing)
                VALUES ('\(id)', '\(root.id)', '\(name)', '\(name)', 'dng', 'raw', 1, 0,
                        '\(UUID().uuidString)',
                        \(width.map(String.init) ?? "NULL"), \(height.map(String.init) ?? "NULL"),
                        \(sqlText(make)), \(sqlText(model)), \(sqlText(lens)),
                        '2026-10-26T00:00:00Z', 0)
                """)
        }

        let session = CatalogSession()
        try session.open(package)
        session.selectOnly(id)
        return (session, try XCTUnwrap(try catalog.asset(id: id)))
    }

    /// One published line/cell: its text, and the frame SwiftUI gave it in the host's coordinates.
    private struct Cell {
        let text: String
        let frame: NSRect
        var minX: CGFloat { frame.minX }
        var midX: CGFloat { frame.midX }
        var maxX: CGFloat { frame.maxX }
        var minY: CGFloat { frame.minY }
        var width: CGFloat { frame.width }
        var height: CGFloat { frame.height }
    }

    /// What one hosted panel published: the marquee rows in tree order, and the two value cells as
    /// `InspectorSpecRowProbe` sees them.
    private struct SpecPanel {
        let window: NSWindow
        let marquees: [Cell]
        let probes: [String: Cell]
    }

    @MainActor
    private func host(_ session: CatalogSession, width: CGFloat? = nil) throws -> SpecPanel {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: InspectorView(session: session))
        host.frame = NSRect(x: 0, y: 0, width: width ?? inspectorWidth, height: 800)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.45))
        host.layoutSubtreeIfNeeded()

        let marquees = Self.marqueeRows(in: host)
            .map { Cell(text: $0.text, frame: $0.convert($0.bounds, to: host)) }
        var probes: [String: Cell] = [:]
        for probe in Self.specProbes(in: host) {
            probes[probe.id] = Cell(text: probe.text, frame: probe.convert(probe.bounds, to: host))
        }
        return SpecPanel(window: window, marquees: marquees, probes: probes)
    }

    @MainActor
    private static func specProbes(in view: NSView) -> [InspectorSpecRowProbe] {
        var found: [InspectorSpecRowProbe] = []
        if let probe = view as? InspectorSpecRowProbe { found.append(probe) }
        for sub in view.subviews { found += specProbes(in: sub) }
        return found
    }

    // MARK: helpers

    @MainActor
    private static func marqueeRows(in view: NSView) -> [MarqueeRowView] {
        var found: [MarqueeRowView] = []
        if let row = view as? MarqueeRowView { found.append(row) }
        for sub in view.subviews { found += marqueeRows(in: sub) }
        return found
    }

    /// The panel adds the unit exactly once, and it normalises legacy rows on the way (a library
    /// imported before `ShutterFormat` has `55924/44739201` in the shutter column).
    func testShutterRowNormalisesLegacyRatiosAndAddsOneUnit() {
        XCTAssertEqual(InspectorPhotoInfo.shutter("55924/44739201"), "1/800s")
        XCTAssertEqual(InspectorPhotoInfo.shutter("31667/39583751"), "1/1250s")
        XCTAssertEqual(InspectorPhotoInfo.shutter("1/250"), "1/250s")
        XCTAssertEqual(InspectorPhotoInfo.shutter("2"), "2s")
        XCTAssertNil(InspectorPhotoInfo.shutter(""))
        XCTAssertNil(InspectorPhotoInfo.shutter(nil))
    }
}
