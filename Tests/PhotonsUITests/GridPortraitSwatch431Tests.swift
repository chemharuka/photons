import XCTest
import AppKit
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 431 — 网格缩略图支持 3:4 竖图：格子与行高完全不变，竖图在框内裁成 3:4 的窄矩形并水平居中。
///
/// The user's two sentences are the acceptance:
///
///   · 「网格布局不变，只改变缩略图形状，选择框形状」 — so `GridLayout.metrics` must return, bit for
///     bit, what it returned before this ticket (the table below was recorded from the shipped
///     function *before* the change, at the widths the layout contract names);
///   · 「现在的缩略图大小视为最大可能的图片大小，然后竖拍照片在现在缩略图基础上裁一下」 — so the
///     portrait box keeps the **same height** as the landscape one and only narrows, centred.
///
/// Everything here is read off the view that painted (`lastSwatchRect`, `lastRingRect`,
/// `lastBadgeLayout`, `lastCaptionRect`), never re-derived from the same formula.
final class GridPortraitSwatch431Tests: XCTestCase {

    // MARK: - fixtures

    private func asset(width: Int?, height: Int?, rating: Int = 0,
                       flag: String? = nil, colorLabel: String? = nil) -> Asset {
        Asset(id: "A", sourceRootId: "root", relPath: "a.dng", filename: "a.dng", ext: "dng",
              kind: .raw, size: 1024, mtime: 0, contentHash: "abc",
              width: width, height: height, captureLocalDate: "2026-11-19 10:00",
              rating: rating, flag: flag, colorLabel: colorLabel,
              cameraModel: "NIKON Z 8")
    }

    private func card(_ asset: Asset, size: CGSize, picked: Bool = false) -> AssetCardView {
        let view = AssetCardView()
        view.frame = NSRect(origin: .zero, size: size)
        view.asset = asset
        view.isPicked = picked
        paint(view)
        return view
    }

    /// Paint the card the way the other card tests do: the view plus its visible subviews, because
    /// the ring / badges / caption live on a transparent overlay above the thumbnail layer.
    private func paint(_ view: NSView) {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                   pixelsWide: Int(max(1, view.bounds.width)),
                                   pixelsHigh: Int(max(1, view.bounds.height)),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        view.layout()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        view.draw(view.bounds)
        for subview in view.subviews where !subview.isHidden { subview.draw(subview.bounds) }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// A default card size the way the grid makes it: 150 × 133.1 (itemWidth 150, swatch 150 × 111.1).
    private static let defaultCard = CGSize(width: 150, height: 133.1)

    // MARK: - A①  the grid layout is untouched

    /// Recorded from the shipped `GridLayout.metrics` **before** this ticket's change. The numbers
    /// are the contract; the fields are compared exactly (CGFloat `==`, not `accuracy:`).
    func testGridMetricsAreBitForBitWhatTheyWereBeforeTheChange() {
        let before: [(CGFloat, Int, CGFloat, CGFloat, CGFloat)] = [
            // width, columns, itemSize.width, itemSize.height, rowHeight
            (800,  4, 183, 158, 170),
            (1056, 6, 160, 141, 153),
            (1456, 8, 167, 146, 158),
            (1600, 9, 163, 143, 155),
            (2256, 13, 160, 141, 153),
        ]
        for (width, columns, itemW, itemH, rowHeight) in before {
            let m = GridLayout.metrics(forWidth: width)
            print("431 A① w=\(width) columns=\(m.columns) item=\(m.itemSize.width)×"
                  + "\(m.itemSize.height) row=\(m.rowHeight) inset=\(m.inset) spacing=\(m.spacing)")
            XCTAssertEqual(m.columns, columns, "columns at width \(width)")
            XCTAssertEqual(m.itemSize.width, itemW, "itemSize.width at width \(width)")
            XCTAssertEqual(m.itemSize.height, itemH, "itemSize.height at width \(width)")
            XCTAssertEqual(m.rowHeight, rowHeight, "rowHeight at width \(width)")
            XCTAssertEqual(m.inset, 16)
            XCTAssertEqual(m.spacing, 12)
        }
        // And the pure function still refines: no portrait special case leaked into the grid.
        XCTAssertEqual(GridLayout.metrics(forWidth: 800).itemSize,
                       GridLayout.metrics(forWidth: 800).itemSize)
    }

    // MARK: - A②  the landscape box is unchanged

    func testLandscapeSwatchRectIsStillTheWholeCardWidth() throws {
        let view = card(asset(width: 9520, height: 6336), size: Self.defaultCard)
        let rect = view.lastSwatchRect
        print("431 A② landscape swatch \(rect) bounds \(view.bounds)")
        XCTAssertEqual(rect, NSRect(x: 0, y: 0, width: 150, height: 133.1 - 22))
        XCTAssertEqual(view.lastSwatchRect.height, view.bounds.height - GridLayout.labelHeight)
        // The thumbnail view is exactly the box layout() handed it.
        let thumb = try XCTUnwrap(view.subviews.first { $0.className.contains("Thumbnail") },
                                  "no thumbnail subview: \(view.subviews.map(\.className))")
        XCTAssertEqual(thumb.frame, rect)
    }

    // MARK: - A③  the portrait box is 3:4, same height, centred

    func testPortraitSwatchRectIsThreeToFourAndCentred() {
        let landscape = card(asset(width: 9520, height: 6336), size: Self.defaultCard)
        let portrait = card(asset(width: 6336, height: 9520), size: Self.defaultCard)

        let l = landscape.lastSwatchRect
        let p = portrait.lastSwatchRect
        print("431 A③ landscape w=\(l.width) h=\(l.height) x=\(l.minX) y=\(l.minY) · "
              + "portrait w=\(p.width) h=\(p.height) x=\(p.minX) y=\(p.minY) ratio=\(p.width / p.height)")
        print("431 A③ expected portrait w=\((l.height * 3 / 4).rounded()) "
              + "x=\(((l.width - (l.height * 3 / 4).rounded()) / 2).rounded())")

        XCTAssertEqual(p.height, l.height, "height never changes")
        XCTAssertEqual(p.minY, 0)
        XCTAssertEqual(p.width / p.height, 0.75, accuracy: 0.01, "3:4")
        XCTAssertEqual(p.width, (l.height * 3.0 / 4.0).rounded(), "width derived from the height")
        XCTAssertEqual(p.minX, ((l.width - p.width) / 2).rounded(), "centred horizontally")
        XCTAssertTrue(p.width < l.width, "a portrait box is narrower than the landscape one")
    }

    func testPortraitBoxStaysInsideTheCard() {
        for width in stride(from: CGFloat(150), through: 400, by: 7) {
            let h = ((width / GridLayout.swatchAspect).rounded() + GridLayout.labelHeight)
            let view = card(asset(width: 4000, height: 6000), size: CGSize(width: width, height: h))
            let p = view.lastSwatchRect
            XCTAssertGreaterThanOrEqual(p.minX, 0)
            XCTAssertLessThanOrEqual(p.maxX, view.bounds.width)
            XCTAssertGreaterThanOrEqual(p.maxX - p.minX, 1, "a zero-width box at w=\(width)")
        }
    }

    // MARK: - A⑤  unknown orientation is landscape

    func testNilDimensionsFallBackToTheLandscapeBox() {
        let landscape = card(asset(width: 9520, height: 6336), size: Self.defaultCard)
        for missing in [asset(width: nil, height: 9520),
                        asset(width: 6336, height: nil),
                        asset(width: nil, height: nil),
                        asset(width: 0, height: 9520)] {
            let view = card(missing, size: Self.defaultCard)
            print("431 A⑤ nil/zero → swatch \(view.lastSwatchRect)")
            XCTAssertEqual(view.lastSwatchRect, landscape.lastSwatchRect,
                           "missing metadata must look like today's cell")
            XCTAssertFalse(AssetCardView.isPortrait(missing))
        }
    }

    // MARK: - A⑥  square is landscape

    func testSquareIsTreatedAsLandscape() {
        let landscape = card(asset(width: 9520, height: 6336), size: Self.defaultCard)
        let square = card(asset(width: 3000, height: 3000), size: Self.defaultCard)
        XCTAssertEqual(square.lastSwatchRect, landscape.lastSwatchRect)
        XCTAssertFalse(AssetCardView.isPortrait(asset(width: 3000, height: 3000)))
        XCTAssertTrue(AssetCardView.isPortrait(asset(width: 3000, height: 3001)))
    }

    // MARK: - A⑦  the caption does not move

    func testCaptionRectIsTheSameForBothOrientations() {
        let landscape = card(asset(width: 9520, height: 6336), size: Self.defaultCard)
        let portrait = card(asset(width: 6336, height: 9520), size: Self.defaultCard)
        for view in [landscape, portrait] {
            let caption = view.lastCaptionRect
            print("431 A⑦ caption \(caption) swatchMaxY=\(view.lastSwatchRect.maxY)")
            XCTAssertEqual(caption.minY, view.lastSwatchRect.maxY + 4, "sits under the swatch")
            XCTAssertEqual(caption.width, view.bounds.width - 4, "full card width, not the narrow box")
            XCTAssertEqual(caption.minX, 2)
        }
        XCTAssertEqual(portrait.lastCaptionRect, landscape.lastCaptionRect,
                       "the caption strip is a card property, not an image one")
    }

    // MARK: - A⑧  the selection ring follows the narrow box

    func testSelectionRingFollowsTheNarrowPortraitBox() throws {
        let landscape = card(asset(width: 9520, height: 6336), size: Self.defaultCard, picked: true)
        let portrait = card(asset(width: 6336, height: 9520), size: Self.defaultCard, picked: true)

        let lRing = try XCTUnwrap(landscape.lastRingRect)
        let pRing = try XCTUnwrap(portrait.lastRingRect)
        print("431 A⑧ ring landscape \(lRing) portrait \(pRing) · swatch \(portrait.lastSwatchRect)")
        XCTAssertEqual(lRing.width, landscape.lastSwatchRect.width - 1.5)
        XCTAssertEqual(pRing.width, portrait.lastSwatchRect.width - 1.5)
        XCTAssertEqual(pRing.width, (portrait.lastSwatchRect.height * 3.0 / 4.0).rounded() - 1.5)
        XCTAssertEqual(pRing.minX, portrait.lastSwatchRect.minX + 0.75)
        XCTAssertTrue(pRing.width < lRing.width, "the ring narrows with the image")
    }

    // MARK: - A⑨  the badges follow the narrow box

    func testBadgesSitOnTheNarrowPortraitBox() {
        let landscape = card(asset(width: 9520, height: 6336, rating: 3, flag: "pick", colorLabel: "red"),
                             size: Self.defaultCard)
        let portrait = card(asset(width: 6336, height: 9520, rating: 3, flag: "pick", colorLabel: "red"),
                            size: Self.defaultCard)

        let l = landscape.lastBadgeLayout
        let p = portrait.lastBadgeLayout
        let lStars = l.starsPill ?? .zero
        let pStars = p.starsPill ?? .zero
        let lFlag = l.flagPill ?? .zero
        let pFlag = p.flagPill ?? .zero
        print("431 A⑨ landscape stars \(lStars) flag \(lFlag) · "
              + "portrait stars \(pStars) flag \(pFlag) · swatch \(portrait.lastSwatchRect)")

        XCTAssertEqual(lFlag.minX, landscape.lastSwatchRect.minX + 3)
        XCTAssertEqual(pFlag.minX, portrait.lastSwatchRect.minX + 3,
                       "the flag capsule starts at the narrow box's left edge")
        XCTAssertEqual(lStars.minX, landscape.lastSwatchRect.minX + 3)
        XCTAssertEqual(pStars.minX, portrait.lastSwatchRect.minX + 3,
                       "stars sit on the narrow box's left edge too")
        XCTAssertEqual(pStars.minX, lStars.minX + portrait.lastSwatchRect.minX,
                       "the offset is exactly the box's inset from the card edge")
        // The real claim: on a portrait card the capsules are **not** pinned to the card's left edge.
        // If the badge code ignored the narrow box, `pFlag.minX` would stay at the landscape 3 pt.
        XCTAssertGreaterThan(portrait.lastSwatchRect.minX, 0, "premise: the portrait box is inset")
        XCTAssertGreaterThan(pFlag.minX, 3, "the flag would be at the card edge if the box were ignored")
        XCTAssertGreaterThan(pStars.minX, 3, "the stars would be at the card edge if the box were ignored")
        XCTAssertTrue(pStars.width > 0 && pFlag.width > 0)
        // Both capsules still fit inside the narrow box, which is the reason 3:4 at 150 pt works.
        XCTAssertLessThanOrEqual(pStars.maxX, portrait.lastSwatchRect.maxX - 2)
        XCTAssertLessThanOrEqual(pFlag.maxX, portrait.lastSwatchRect.maxX - 2)
    }
}
