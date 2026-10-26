import XCTest
import AppKit
import PhotonsCatalog
@testable import PhotonsUI

/// The left browser's row holds the thumbnail square and the three text lines (name / 机身 · 日期 /
/// stars). This file is about one number in that row: **where the text block sits vertically**.
///
/// The bug it guards is a 3 pt one. `layout()` used to place each line at an absolute offset from
/// `bounds.height` (`46 − 31`, `46 − 45`, `46 − 17`), so on the shipped 46 pt row the block occupied
/// y 1…39 — centre 20 — while the 34 pt square was centred at 23. The text sat 3 pt low, with 7 pt
/// of slack above it and 1 pt below, which is what "位置稍微偏下" is. The constants also made the
/// cell as tall as its magic number: at a 60 pt row the block landed 4 pt low, at 32 pt `meta` fell
/// clean out of the row (y −13…−1).
///
/// So the assertions here are geometry, not screenshots: a cell is given a frame, laid out once,
/// and the frames it produced are compared with the square's. The offscreen cell is the same code
/// path the table uses (PhotoRowCell draws its own subviews; no window is involved).
final class BrowserRowLayoutTests: XCTestCase {

    /// Rows the geometry must hold on: the shipped 46, plus two the layout has no business knowing
    /// about — a shorter style (32) and a taller one (60) — because "no magic 46" is only true if a
    /// different height still centres.
    private let rowHeights: [CGFloat] = [WorkspaceLayout.browserRowHeight, 32, 60]
    private let rowWidth: CGFloat = 240
    /// Where the text column starts, and the 2 pt gutter on the right (`layout()`).
    private let textX: CGFloat = 44
    private let rightGutter: CGFloat = 2

    private func asset(filename: String = "A.dng",
                       camera: String? = "NIKON Z 8",
                       date: String? = "2026-10-27 10:12") -> Asset {
        Asset(id: "A",
              sourceRootId: "root",
              relPath: "A.dng",
              filename: filename,
              ext: "dng",
              kind: AssetKind.detect("dng") ?? .jpeg,
              size: 1024,
              mtime: 0,
              contentHash: "abc",
              width: 9520,
              height: 6336,
              captureLocalDate: date,
              cameraModel: camera)
    }

    @discardableResult
    private func layOut(rowHeight: CGFloat,
                        width: CGFloat? = nil,
                        filename: String = "A.dng") -> PhotoRowCell.LayoutProbe {
        let cell = PhotoRowCell()
        cell.configure(asset: asset(filename: filename), isActive: true)
        cell.frame = NSRect(x: 0, y: 0, width: width ?? rowWidth, height: rowHeight)
        cell.layout()
        return cell.layoutProbe
    }

    /// The three lines as one block. `meta` is the bottom line, `stars` the top one (the order the
    /// cell has always stacked them — only the block's position is under test here).
    private func textBlock(_ p: PhotoRowCell.LayoutProbe) -> NSRect {
        NSRect(x: p.name.minX,
               y: min(p.name.minY, p.meta.minY, p.stars.minY),
               width: p.name.width,
               height: max(p.name.maxY, p.meta.maxY, p.stars.maxY)
                       - min(p.name.minY, p.meta.minY, p.stars.minY))
    }

    /// 1 — the text block and the thumbnail square share a vertical centre, on every row height.
    /// ≤ 0.5 pt is the spec's tolerance; the arithmetic lands on 0 because both are derived from
    /// `bounds.height`, but the test does not assume that.
    func testTheTextBlockSharesTheSquareVCentreOnEveryRowHeight() {
        for h in rowHeights {
            let p = layOut(rowHeight: h)
            let block = textBlock(p)
            XCTAssertEqual(block.midY, p.swatch.midY, accuracy: 0.5,
                           "row \(h): text block centre \(block.midY) vs square centre \(p.swatch.midY)")
            XCTAssertEqual(block.midY, p.swatch.midY, accuracy: 0.5,
                           "row \(h): and the square is the thing the eye lines the text up with")
        }
    }

    /// The pre-fix number, stated as a regression: on 46 pt the block used to sit at 20 against a
    /// 23 pt square centre. It must now be *above* 22.5 and *below* 23.5 — i.e. on the centre, not
    /// "3 pt low with 7 pt of slack on top and 1 pt underneath".
    func testTheShippedRowIsNoLongerThreePointsLow() {
        let p = layOut(rowHeight: WorkspaceLayout.browserRowHeight)
        let block = textBlock(p)
        XCTAssertEqual(block.midY, 23, accuracy: 0.5)
        XCTAssertGreaterThan(block.minY, 1, "the block used to start 1 pt off the bottom edge")
        // Symmetric slack is what makes the block look centred rather than merely be centred.
        let topSlack = WorkspaceLayout.browserRowHeight - block.maxY
        XCTAssertEqual(topSlack, block.minY, accuracy: 0.01,
                       "top slack \(topSlack) vs bottom slack \(block.minY)")
    }

    /// 2 + 3 — the three lines neither overlap nor leave the row. Names run bottom → top:
    /// meta, name, stars.
    func testTheThreeLinesDoNotOverlapAndStayInsideTheRow() {
        // Frames are sums of the same heights, so "adjacent" can differ by a couple of ulps
        // (10.378378378378377 vs …379 on a 32 pt row). 1e-6 pt is a millionth of a pixel — far
        // below anything the eye or the compositor can see — and it is what keeps this assertion
        // about overlap rather than about IEEE 754.
        let eps: CGFloat = 1e-6
        for h in rowHeights {
            let p = layOut(rowHeight: h)
            XCTAssertGreaterThanOrEqual(p.name.minY + eps, p.meta.maxY, "row \(h): name overlaps meta")
            XCTAssertGreaterThanOrEqual(p.stars.minY + eps, p.name.maxY, "row \(h): stars overlap name")
            XCTAssertGreaterThan(p.name.height, 0, "row \(h): name has no height")
            XCTAssertGreaterThan(p.meta.height, 0, "row \(h): meta has no height")
            XCTAssertGreaterThan(p.stars.height, 0, "row \(h): stars has no height")
            for (label, r) in [("name", p.name), ("meta", p.meta), ("stars", p.stars)] {
                XCTAssertGreaterThanOrEqual(r.minY, 0, "row \(h): \(label) hangs below the row")
                XCTAssertLessThanOrEqual(r.maxY, h, "row \(h): \(label) is pushed out of the row")
                XCTAssertGreaterThanOrEqual(r.minX, 0, "row \(h): \(label) starts left of the row")
                XCTAssertLessThanOrEqual(r.maxX, rowWidth, "row \(h): \(label) runs off the row")
            }
            // The 34 pt square only fits a row that is at least that tall; its side is not this
            // change's business (`thumbnailSide` stays 34, x stays 2), so it is only checked where
            // the geometry can hold it.
            if h >= BrowserPaneController.thumbnailSide {
                XCTAssertGreaterThanOrEqual(p.swatch.minY, 0, "row \(h): square hangs below the row")
                XCTAssertLessThanOrEqual(p.swatch.maxY, h, "row \(h): square is out of the row")
            }
        }
    }

    /// The lines are stacked edge to edge, so there is no dead gap for the eye to read as a
    /// misalignment, and no 1 pt overlap (the old `stars` frame started 1 pt inside `name`).
    func testTheLinesAreStackedEdgeToEdge() {
        for h in rowHeights {
            let p = layOut(rowHeight: h)
            XCTAssertEqual(p.name.minY, p.meta.maxY, accuracy: 0.01, "row \(h): gap under name")
            XCTAssertEqual(p.stars.minY, p.name.maxY, accuracy: 0.01, "row \(h): gap under stars")
        }
    }

    /// The line heights the cell documents, on any row tall enough to hold them: name 15, meta 12,
    /// stars 10 (11 / 9 / 8 pt fonts). A taller row grows the slack around the block — never the
    /// lines — so the type size never rides on the row height.
    func testTheLineHeightsAreUnchangedOnRowsTallEnoughToHoldThem() {
        for h in [WorkspaceLayout.browserRowHeight, 60, 74] as [CGFloat] {
            let p = layOut(rowHeight: h)
            XCTAssertEqual(p.name.height, PhotoRowCell.nameLineHeight, accuracy: 0.01, "row \(h)")
            XCTAssertEqual(p.meta.height, PhotoRowCell.metaLineHeight, accuracy: 0.01, "row \(h)")
            XCTAssertEqual(p.stars.height, PhotoRowCell.starsLineHeight, accuracy: 0.01, "row \(h)")
            XCTAssertEqual(PhotoRowCell.textBlockHeight, 37, accuracy: 0.01,
                           "15 + 12 + 10 — the block the row centres")
        }
    }

    /// A row shorter than the 37 pt block (a compact style, a degenerate test frame) shrinks the
    /// three lines in proportion instead of hanging `meta` outside the row — which is exactly what
    /// the old absolute offsets did at 32 pt (meta sat at y −13…−1).
    func testACompactRowGivesUpLineHeightRatherThanLeavingTheRow() {
        let h: CGFloat = 32
        let p = layOut(rowHeight: h)
        XCTAssertEqual(textBlock(p).height, h, accuracy: 0.01,
                       "a row this short is filled by the block, not overrun by it")
        XCTAssertEqual(textBlock(p).midY, h / 2, accuracy: 0.5)
        XCTAssertLessThan(p.name.height, PhotoRowCell.nameLineHeight)
        XCTAssertGreaterThan(p.name.height, 12, "still a readable line for an 11 pt label")
    }

    /// 3 (cont.) — there is no 46 in the layout. Every part of the row is centred on `bounds.height`,
    /// so growing the row by Δ moves each part by exactly Δ/2 and changes no height: the text block
    /// stays 37 pt and the square stays 34. A magic absolute offset would move a line by the full Δ
    /// and keep the block's centre where it was — the original bug in its purest form (on 60 pt the
    /// old code put the block centre at 34 instead of 30).
    func testTheRowHeightIsTheOnlyInputToTheVerticalLayout() {
        let short: CGFloat = 60
        let tall: CGFloat = 74
        let a = layOut(rowHeight: short)
        let b = layOut(rowHeight: tall)
        let shift = (tall - short) / 2
        for (label, r1, r2) in [("name", a.name, b.name),
                                ("meta", a.meta, b.meta),
                                ("stars", a.stars, b.stars),
                                ("swatch", a.swatch, b.swatch),
                                ("pill", a.pill, b.pill)] {
            XCTAssertEqual(r2.minY - r1.minY, shift, accuracy: 0.01,
                           "\(label) did not ride half of the extra \(tall - short) pt of row")
            XCTAssertEqual(r2.height, r1.height, accuracy: 0.01, "\(label) changed size with the row")
            XCTAssertEqual(r2.minX, r1.minX, accuracy: 0.01, "\(label) moved sideways")
        }
        XCTAssertEqual(textBlock(b).height, textBlock(a).height, accuracy: 0.01,
                       "the text block is the same 37 pt on both rows")
        XCTAssertEqual(textBlock(b).midY, tall / 2, accuracy: 0.5)
        XCTAssertEqual(textBlock(a).midY, short / 2, accuracy: 0.5)
    }

    /// 4 — a long name still truncates in the middle, in the column `layout()` reserves for it
    /// (row width − 44 − 2), so the two ends of "day2-…-0001.dng" stay distinguishable.
    func testALongNameStillTruncatesInTheColumnReservedForIt() {
        let long = String(repeating: "x", count: 56) + ".dng"
        XCTAssertEqual(long.count, 60)
        let p = layOut(rowHeight: WorkspaceLayout.browserRowHeight, filename: long)
        XCTAssertEqual(p.nameText, long, "the row must receive the whole name, not a pre-cut one")
        XCTAssertEqual(p.name.minX, textX, accuracy: 0.01)
        XCTAssertEqual(p.name.width, rowWidth - textX - rightGutter, accuracy: 0.01,
                       "the name column is the row minus its 44 pt gutter and 2 pt margin")
        XCTAssertEqual(p.nameBreakMode, .byTruncatingMiddle)
        XCTAssertGreaterThan(p.nameUnclippedWidth, p.name.width,
                             "60 characters at 11 pt must not fit — otherwise nothing truncates")
        // A narrow row keeps a usable column rather than collapsing to zero.
        let narrow = layOut(rowHeight: WorkspaceLayout.browserRowHeight, width: 50, filename: long)
        XCTAssertEqual(narrow.name.width, 10, accuracy: 0.01, "the 10 pt floor for the name column")
    }

    /// The thumbnail side is untouched: 34 pt at x = 2, centred, at every row height — the list and
    /// the grid agree on the tier that implies (`BrowserListThumbnailTests`).
    func testTheThumbnailSquareIsWhereItWas() {
        for h in rowHeights {
            let p = layOut(rowHeight: h)
            XCTAssertEqual(p.swatch.minX, 2, accuracy: 0.01, "row \(h)")
            XCTAssertEqual(p.swatch.width, 34, accuracy: 0.01, "row \(h)")
            XCTAssertEqual(p.swatch.height, 34, accuracy: 0.01, "row \(h)")
            XCTAssertEqual(p.swatch.midY, h / 2, accuracy: 0.5, "row \(h): the square is centred")
        }
    }

    /// 5 — 「原文件已移动」 still rides the bottom of the square: 12 pt tall, its top edge 1 pt above
    /// the square's bottom edge. Its position is derived from the square, so centring the text did
    /// not move it.
    func testTheMissingFilePillStillRidesTheBottomOfTheSquare() {
        for h in [WorkspaceLayout.browserRowHeight, 60] as [CGFloat] {
            let p = layOut(rowHeight: h)
            XCTAssertEqual(p.pill.minX, p.swatch.minX, accuracy: 0.01, "row \(h)")
            XCTAssertEqual(p.pill.width, p.swatch.width, accuracy: 0.01, "row \(h)")
            XCTAssertEqual(p.pill.height, 12, accuracy: 0.01, "row \(h)")
            XCTAssertEqual(p.pill.maxY, p.swatch.maxY - 1, accuracy: 0.01, "row \(h)")
        }
    }
}
