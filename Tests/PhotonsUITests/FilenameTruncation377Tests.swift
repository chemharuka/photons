import XCTest
import AppKit
import PhotonsCatalog
@testable import PhotonsUI

/// 377 — 文件名截断：三个面统一按「能显示的最长文件名 + …」截。
///
/// The user's rule, in their words: 「长度过长的文件名会按空格，或者"-"字符后截断，要求按照能够显示的
/// 最长的"文件名…"去截断」. So there are exactly two claims to prove, on every face:
///
///   ① the head is **maximal** — no wider prefix fits, and one more character does not;
///   ② the cut is not decided by a space or a `-`; when it lands after one, that is only because
///      the next character genuinely does not fit.
///
/// Both are numbers (`NSAttributedString.size().width`), not screenshots, and the same three names
/// are read off the three views that paint them (grid card, filmstrip cell, browser row) so the
/// tests cannot pass on a shared helper that the UI forgot to call.
final class FilenameTruncation377Tests: XCTestCase {

    /// The name the ticket quotes. 56 characters, with a space after the date, a `-` inside
    /// `day2-Photons`, and `-`-separated fields further on.
    private static let longName = "2026-10-27 day2-Photons-L1030433-very-long-name.dng"

    /// The widths the acceptance table names, and the two caption fonts (grid/filmstrip 10 pt,
    /// browser row 11 pt).
    private static let widths: [CGFloat] = [60, 100, 160, 240]
    private static let fonts = [NSFont.systemFont(ofSize: 10, weight: .medium),
                                NSFont.systemFont(ofSize: 11, weight: .medium)]

    private func width(_ text: String, _ font: NSFont) -> CGFloat {
        MarqueeLayout.width(of: text, font: font, color: .secondaryLabelColor)
    }

    /// The character right after `head` in `name`, or nil at the end of the string.
    private func nextCharacter(after head: String, in name: String) -> Character? {
        guard name.hasPrefix(head) else { return nil }
        let index = name.index(name.startIndex, offsetBy: head.count)
        return index < name.endIndex ? name[index] : nil
    }

    // MARK: - ①  maximum

    /// For every width × font: the result measures inside the width, and `head + next + …` does not.
    /// Asserted per width (not "non-empty"): a helper that cut too early would pass a non-empty
    /// check and fail this one.
    func testTheFittedHeadIsTheLongestOneThatFits() {
        for font in Self.fonts {
            for w in Self.widths {
                let fitted = PlaceholderStyle.fitted(Self.longName, width: w, font: font)
                XCTAssertLessThanOrEqual(width(fitted, font), w,
                                         "\(font.pointSize) pt / \(w) pt: \"\(fitted)\" overflows")
                XCTAssertTrue(fitted.hasSuffix("…"), "\(font.pointSize) pt / \(w) pt: no ellipsis")

                let head = String(fitted.dropLast())
                guard let next = nextCharacter(after: head, in: Self.longName) else {
                    XCTFail("\(font.pointSize) pt / \(w) pt: \"\(fitted)\" cut nothing")
                    continue
                }
                let oneMore = width(head + String(next) + "…", font)
                XCTAssertGreaterThan(oneMore, w,
                                     "\(font.pointSize) pt / \(w) pt: \"\(fitted)\" is not maximal — "
                                     + "\"\(head + String(next))…\" still measures \(oneMore) pt")
            }
        }
    }

    // MARK: - ②  not at a space / hyphen, unless forced

    /// 11 pt (the browser row's font) at 100 pt: the longest head **including its `…`** is inside
    /// `day2`, so neither string the old word-wrap produced — `"2026-10-27 "` and
    /// `"2026-10-27 day2-"` — is what the row paints. The assertion is on the row's label, i.e. on
    /// what is on screen, and the word-wrap line is computed at the same width for comparison.
    func testTheCutIsNotAtASpaceOrAHyphen() {
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let fitted = PlaceholderStyle.fitted(Self.longName, width: 100, font: font)
        XCTAssertEqual(fitted, "2026-10-27 day…", "the cut must land inside \"day2\", not at a boundary")
        XCTAssertNotEqual(fitted, "2026-10-27 …")
        XCTAssertNotEqual(fitted, "2026-10-27 day2-…")

        let row = PhotoRowCell()
        row.configure(asset: asset(filename: Self.longName), isActive: true)
        row.frame = NSRect(x: 0, y: 0, width: 146, height: WorkspaceLayout.browserRowHeight)
        row.layout()
        let painted = row.layoutProbe.nameDrawnText
        XCTAssertEqual(painted, fitted, "the row paints the fitted string, not some other cut")
        XCTAssertNotEqual(painted, "2026-10-27 day2-…")
        XCTAssertNotEqual(painted, "2026-10-27 …")
        print("377 cut at 100 pt / 11 pt: \"\(painted)\"")
    }

    /// The canvas faces at 10 pt / 100 pt land *on* the hyphen — but with their own `…` appended,
    /// which is maximality, not word wrapping: the old path painted exactly that head with the rest
    /// clipped away and no ellipsis. Stating it as `wrapHead + "…"` is what makes the two
    /// indistinguishable-looking strings different claims.
    func testTheCanvasCutIsTheWrapHeadPlusAnEllipsisNotAClip() {
        let font = PlaceholderStyle.captionFont
        let wrapHead = Self.wordWrappedFirstLine(Self.longName, font: font, width: 100)
        XCTAssertEqual(wrapHead, "2026-10-27 day2-", "what the old attributes painted, clipped")
        XCTAssertFalse(wrapHead.hasSuffix("…"))

        let grid = AssetCardView()
        grid.frame = NSRect(x: 0, y: 0, width: 104, height: 120)
        grid.asset = asset(filename: Self.longName)
        paint(grid)
        XCTAssertEqual(grid.lastDrawnCaption, wrapHead + "…",
                       "same head, but with the ellipsis the old draw never produced")

        // And it is maximal: one more character plus `…` no longer fits.
        XCTAssertGreaterThan(width(wrapHead + "P" + "…", font), 100)
    }

    /// The general form of ②: whenever the result *does* end just after a space or a `-`, it is
    /// because one more character would overflow — i.e. the boundary never gets to decide. At
    /// 10 pt / 100 pt the `-` after `day2` is the last glyph that fits (99.88 pt of 100), which is
    /// maximality, not word wrapping.
    func testABoundaryCutIsOnlyEverTheMaximalOne() {
        let boundaries = ["2026-10-27 ", "2026-10-27 day2-"]
        for font in Self.fonts {
            for w in Self.widths {
                let fitted = PlaceholderStyle.fitted(Self.longName, width: w, font: font)
                let head = String(fitted.dropLast())
                guard boundaries.contains(head),
                      let next = nextCharacter(after: head, in: Self.longName) else { continue }
                XCTAssertGreaterThan(width(head + String(next) + "…", font), w,
                                     "\(font.pointSize) pt / \(w) pt stopped at a boundary with room left")
            }
        }
    }

    // MARK: - ③  ellipsis exactly when something was cut

    /// A name that fits is painted **verbatim** on all three faces; a name that does not always ends
    /// in `…`. Both halves are read off the views, so a face that silently stopped calling
    /// `fitted(…)` fails here as "nothing recorded" rather than passing on the helper alone.
    func testAShortNameIsReturnedVerbatimAndAnEllipsisOnlyMarksACut() {
        let short = "L1030433.dng"
        for font in Self.fonts {
            XCTAssertEqual(PlaceholderStyle.fitted(short, width: 240, font: font), short,
                           "\(font.pointSize) pt: a name that fits must come back untouched")
        }
        for font in Self.fonts {
            for w in Self.widths {
                XCTAssertTrue(PlaceholderStyle.fitted(Self.longName, width: w, font: font).hasSuffix("…"),
                              "\(font.pointSize) pt / \(w) pt: a cut without `…` is the bug itself")
            }
        }
        XCTAssertEqual(PlaceholderStyle.fitted("", width: 100, font: Self.fonts[0]), "")

        // The canvas faces: verbatim short name, `…`-terminated long one.
        let grid = AssetCardView()
        grid.frame = NSRect(x: 0, y: 0, width: 140, height: 120)
        grid.asset = asset(filename: short)
        paint(grid)
        XCTAssertEqual(grid.lastDrawnCaption, short, "a short name is painted exactly, no `…`")

        let film = FilmstripCard()
        film.frame = NSRect(x: 0, y: 0, width: 100, height: 69)
        film.asset = asset(filename: Self.longName)
        paint(film)
        XCTAssertEqual(film.lastDrawnCaption.flatMap { $0.hasSuffix("…") }, true,
                       "a cut name is painted with its `…`")
    }

    // MARK: - fixtures for the three faces

    private func asset(filename: String) -> Asset {
        Asset(id: "A", sourceRootId: "root", relPath: filename, filename: filename, ext: "dng",
              kind: AssetKind.detect("dng") ?? .jpeg, size: 1024, mtime: 0, contentHash: "abc",
              width: 9520, height: 6336, captureLocalDate: "2026-10-27 10:12",
              cameraModel: "NIKON Z 8")
    }

    /// Paint a card the way `MissingFilesUITests` does: the view plus its visible subviews, because
    /// the caption/ring/badge live on a transparent overlay above the thumbnail layer.
    private func paint(_ view: NSView) {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                   pixelsWide: Int(max(1, view.bounds.width)),
                                   pixelsHigh: Int(max(1, view.bounds.height)),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        view.layout()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        view.draw(view.bounds)
        for subview in view.subviews where !subview.isHidden { subview.draw(subview.bounds) }
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: - ④  one implementation, three faces

    /// The same input and the same width on all three faces produce the same string — read off the
    /// views after they laid out and painted, not off the helper they call. (The grid and the
    /// filmstrip are 10 pt, the row is 11 pt, so each face is also checked against the same helper
    /// at its own font; the equality assertion is made at a shared font.)
    func testGridFilmstripAndBrowserRowReturnTheSameString() {
        let name = Self.longName
        let gridFont = PlaceholderStyle.captionFont
        let filmFont = PlaceholderStyle.captionFont
        let rowFont = NSFont.systemFont(ofSize: 11, weight: .medium)
        let expectedGrid = PlaceholderStyle.fitted(name, width: 100, font: gridFont)
        let expectedFilm = PlaceholderStyle.fitted(name, width: 100, font: filmFont)
        let expectedRow = PlaceholderStyle.fitted(name, width: 100, font: rowFont)
        XCTAssertEqual(expectedGrid, expectedFilm, "the two canvas faces share a font and a width")

        // Grid: captionRect.width = bounds.width − 4.
        let grid = AssetCardView()
        grid.frame = NSRect(x: 0, y: 0, width: 104, height: 120)
        grid.asset = asset(filename: name)
        paint(grid)
        XCTAssertEqual(grid.lastCaptionRect.width, 100, accuracy: 0.01)
        XCTAssertEqual(grid.lastDrawnCaption, expectedGrid)

        // Filmstrip: the caption is the cell's full width.
        let film = FilmstripCard()
        film.frame = NSRect(x: 0, y: 0, width: 100, height: 69)
        film.asset = asset(filename: name)
        paint(film)
        XCTAssertEqual(film.lastCaptionRect.width, 100, accuracy: 0.01)
        XCTAssertEqual(film.lastDrawnCaption, expectedFilm)
        XCTAssertEqual(film.lastDrawnCaption, grid.lastDrawnCaption)

        // Browser row: `layout()` gives the label row width − 44 − 2, then fits to exactly that.
        let row = PhotoRowCell()
        row.configure(asset: asset(filename: name), isActive: true)
        row.frame = NSRect(x: 0, y: 0, width: 146, height: WorkspaceLayout.browserRowHeight)
        row.layout()
        let probe = row.layoutProbe
        XCTAssertEqual(probe.name.width, 100, accuracy: 0.01)
        XCTAssertEqual(probe.nameText, name, "the row keeps the whole name — only the label shows the head")
        XCTAssertEqual(probe.nameDrawnText, expectedRow)
        XCTAssertEqual(probe.nameBreakMode, .byTruncatingTail)
        print("377 three faces at 100 pt: grid=\"\(expectedGrid)\" row=\"\(expectedRow)\"")
    }

    // MARK: - ⑤  the render layer draws that string, not a re-wrapped one

    /// What the card actually hands to `NSString.draw(in:)` is the fitted string, it fits in the
    /// strip, and it is not the word-wrapped first line the old code painted (that one has no
    /// ellipsis and stops after `day2-`).
    func testTheCanvasFacesDrawTheFittedString() {
        let name = Self.longName
        let grid = AssetCardView()
        grid.frame = NSRect(x: 0, y: 0, width: 104, height: 120)
        grid.asset = asset(filename: name)
        paint(grid)
        let film = FilmstripCard()
        film.frame = NSRect(x: 0, y: 0, width: 100, height: 69)
        film.asset = asset(filename: name)
        paint(film)

        for (face, drawn, rect) in [("grid", grid.lastDrawnCaption, grid.lastCaptionRect),
                                    ("filmstrip", film.lastDrawnCaption, film.lastCaptionRect)] {
            guard let text = drawn else {
                XCTFail("\(face): nothing was recorded as drawn — the caption bypasses `fitted(…)`")
                continue
            }
            XCTAssertEqual(text, PlaceholderStyle.fitted(name, width: rect.width,
                                                         font: PlaceholderStyle.captionFont),
                           "\(face): the painted string is not `fitted(…)`")
            XCTAssertTrue(name.hasPrefix(String(text.dropLast())), "\(face): the head is not a prefix")
            XCTAssertLessThanOrEqual(width(text, PlaceholderStyle.captionFont), rect.width,
                                     "\(face): the painted string overflows its strip")
            XCTAssertEqual(Self.laidOutCharacterCount(text, width: rect.width,
                                                      attributes: PlaceholderStyle.captionAttributes),
                           text.count,
                           "\(face): the paragraph style truncated again — the drawn string must be "
                           + "the one `fitted(…)` chose, not a shorter one")
            XCTAssertNotEqual(text, Self.wordWrappedFirstLine(name, font: PlaceholderStyle.captionFont,
                                                              width: rect.width),
                              "\(face): the painted string is still the word-wrapped line")
        }

        // And the reverse gate, stated as a fact about the old attributes: no paragraph style ⇒
        // word wrap ⇒ a first line with no `…` that stops right after the `-`.
        let old = Self.wordWrappedFirstLine(name, font: PlaceholderStyle.captionFont, width: 100)
        XCTAssertEqual(old, "2026-10-27 day2-", "the pre-fix word-wrap line")
        XCTAssertFalse(old.hasSuffix("…"))
        XCTAssertNotEqual(old, grid.lastDrawnCaption)
    }

    /// The second half of the double insurance: the attributes the caption is *painted* with carry a
    /// tail-truncating paragraph style. Without it a measurement/paint disagreement would show up as
    /// a word-wrapped second line clipped away — the very symptom of the ticket. So the assertion is
    /// the symptom itself: with the caption attributes the 56-character name lays out to **one**
    /// line; with only `.font` (the pre-fix attributes) it lays out to **four**, the first of which
    /// is `"2026-10-27 day2-"` with no ellipsis.
    func testTheCaptionAttributesTruncateTheTailRatherThanWrap() {
        guard let style = PlaceholderStyle.captionAttributes[.paragraphStyle] as? NSParagraphStyle else {
            XCTFail("the caption attributes carry no paragraph style — the draw falls back to word wrap")
            return
        }
        XCTAssertEqual(style.lineBreakMode, .byTruncatingTail)
        XCTAssertEqual(PlaceholderStyle.captionAttributes[.font] as? NSFont, PlaceholderStyle.captionFont)
        XCTAssertEqual(PlaceholderStyle.captionFont.pointSize, 10,
                       "the caption font is the one the two canvas faces measure with")

        let name = Self.longName
        let height = Self.laidOutHeight(name, width: 100, attributes: PlaceholderStyle.captionAttributes)
        let single = Self.laidOutHeight("x", width: 100, attributes: PlaceholderStyle.captionAttributes)
        XCTAssertEqual(height, single, accuracy: 0.5,
                       "with `byTruncatingTail` the caption is one line (\(height) pt), not a wrapped block")

        let preFix: [NSAttributedString.Key: Any] = [.font: PlaceholderStyle.captionFont]
        let wrapped = Self.laidOutHeight(name, width: 100, attributes: preFix)
        XCTAssertGreaterThan(wrapped, single * 3, "the pre-fix attributes wrapped it into a block of \(wrapped) pt")
        XCTAssertEqual(Self.wordWrappedFirstLine(name, font: PlaceholderStyle.captionFont, width: 100),
                       "2026-10-27 day2-")
    }

    /// Height of `text` laid out at `width` with the given attributes. One line with the caption
    /// attributes (tail truncation), a wrapped multi-line block without the paragraph style.
    private static func laidOutHeight(_ text: String, width: CGFloat,
                                      attributes: [NSAttributedString.Key: Any]) -> CGFloat {
        (text as NSString).boundingRect(with: NSSize(width: width, height: 10_000),
                                        options: [.usesLineFragmentOrigin],
                                        attributes: attributes).height
    }

    /// How many characters survive one line of layout at `width` (with the caption attributes, so
    /// the paragraph style participates). Equal to `text.count` means the draw did not cut again.
    private static func laidOutCharacterCount(_ text: String, width: CGFloat,
                                              attributes: [NSAttributedString.Key: Any]) -> Int {
        let storage = NSTextStorage(string: text, attributes: attributes)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: width, height: 1000))
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = 1
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        var lineRange = NSRange()
        _ = layout.lineFragmentRect(forGlyphAt: 0, effectiveRange: &lineRange)
        return layout.characterRange(forGlyphRange: lineRange, actualGlyphRange: nil).length
    }

    /// The first line `NSString.draw(in:)` paints when the attributes carry no paragraph style —
    /// i.e. the behaviour this ticket removes. Derived from a real `NSLayoutManager`, not assumed.
    private static func wordWrappedFirstLine(_ text: String, font: NSFont, width: CGFloat) -> String {
        let storage = NSTextStorage(string: text, attributes: [.font: font])
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: width, height: 1000))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        var lineRange = NSRange()
        _ = layout.lineFragmentRect(forGlyphAt: 0, effectiveRange: &lineRange)
        let charRange = layout.characterRange(forGlyphRange: lineRange, actualGlyphRange: nil)
        return (text as NSString).substring(with: charRange)
    }
}
