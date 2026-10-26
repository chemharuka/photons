import XCTest
import AppKit
import SwiftUI
@testable import PhotonsUI

/// The inspector's pinned top: 「信息」 + 直方图 above the scroll view, everything else below it.
///
/// What is pinned here, and why each assertion is the one that matters:
///
///   · **The title is 信息.** The block reports the photo (file name, shooting parameters, equipment);
///     it is not a control. `Text` in a `NSHostingView` has no AppKit view to read back and the
///     accessibility tree is empty under `swift test` (SwiftUI draws into layers and AX needs a live
///     window session), so the string is pinned at its two sources: the one constant the card is
///     titled with, and the source line that titles it. A second literal creeping in is exactly the
///     drift that check exists to catch.
///   · **The two blocks do not move when the window shrinks** (800 → 420 pt): every AppKit leaf of the
///     pinned region has the same frame in both. The leaves are the real ones SwiftUI laid out —
///     `MarqueeRowView` (the info rows) and `HistogramCardView` (the plot) — not constants read back
///     from constants.
///   · **The histogram is not squeezed.** Its plot is 104 pt of card at 420 as at 800 (ratio 1.00 ≥
///     0.99); a `VStack` that lets both children flex would have taken it from the plot first, which is
///     the failure mode this whole layout exists to prevent.
///   · **The settings below really do scroll.** The scroll viewport is what absorbs the height that is
///     gone (800 − 259 = 541 vs 420 − 259 = 161), and scrolling the document moves the cards inside it
///     while the pinned leaves stay exactly where they were. A view that is only *below* the pinned
///     block is not the same thing as a view that scrolls, so the offset is moved rather than argued.
///   · **The histogram is rendered once.** One `HistogramCardView` in the tree, not two — it moved out
///     of the `ForEach` rather than being duplicated by it.
@MainActor
final class InspectorPinnedHeaderTests: XCTestCase {

    private static let inspectorWidth: CGFloat = 330
    /// `330 − 2·12 (panel inset) − 2·16 (card inset)` — the width every card's content gets.
    private var cardContentWidth: CGFloat {
        Self.inspectorWidth - 2 * 12 - 2 * WorkspaceLayout.cardInsetH
    }
    /// The plot's own height (`HistogramCard.intrinsicContentSize`), which the pinning must not shrink.
    private static let plotHeight: CGFloat = 104

    // MARK: - what a hosted panel looks like at one window height

    private struct Panel {
        let height: CGFloat
        let host: NSHostingView<InspectorView>
        let window: NSWindow
        /// The three marquee rows of the 信息 card: file name (row 1), camera, lens (派单 022).
        let infoRows: [NSRect]
        let histogramPlot: NSRect
        let histogramCards: Int
        let scrollViewport: NSRect
        let scrollDocument: NSRect
        let maskProbe: NSRect

        var infoBlockBottom: CGFloat { infoRows.map(\.maxY).max() ?? 0 }
    }

    private func host(height: CGFloat) throws -> Panel {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: InspectorView(session: CatalogSession()))
        host.frame = NSRect(x: 0, y: 0, width: Self.inspectorWidth, height: height)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        host.layoutSubtreeIfNeeded()

        let rows = Self.views(of: "MarqueeRowView", in: host)
            .map { $0.convert($0.bounds, to: host) }
        let histograms = Self.views(of: "HistogramCardView", in: host)
        let scrolls = Self.views(of: "HostingScrollView", in: host)
        let documents = Self.views(of: "DocumentView", in: host)
        let probes = Self.views(of: "MaskPanelProbe", in: host)
        let histogramPlot = try XCTUnwrap(histograms.first.map { $0.convert($0.bounds, to: host) },
                                          "the histogram plot is not in the tree")
        let scrollViewport = try XCTUnwrap(scrolls.first.map { $0.convert($0.bounds, to: host) },
                                           "the scroll viewport is not in the tree")
        let scrollDocument = try XCTUnwrap(documents.first.map { $0.convert($0.bounds, to: host) },
                                           "the scroll document is not in the tree")
        // The 蒙版 card's own probe (it already ships one) is the deepest known leaf of the scroll
        // content — a named anchor inside the scrolling half, not a heuristic pick.
        let maskProbe = try XCTUnwrap(probes.first.map { $0.convert($0.bounds, to: host) },
                                      "the mask panel probe is not in the tree")

        return Panel(height: height, host: host, window: window,
                     infoRows: rows,
                     histogramPlot: histogramPlot,
                     histogramCards: histograms.count,
                     scrollViewport: scrollViewport,
                     scrollDocument: scrollDocument,
                     maskProbe: maskProbe)
    }

    private static func views(of className: String, in root: NSView) -> [NSView] {
        var found: [NSView] = []
        if String(describing: type(of: root)) == className { found.append(root) }
        for sub in root.subviews { found += views(of: className, in: sub) }
        return found
    }

    // MARK: - (a) the title

    func testThePinnedTitleIsInformationNotAdjustment() throws {
        XCTAssertEqual(InspectorView.infoTitle, "信息",
                       "the pinned block reports the photo; 调整 promised edits it never made")
        XCTAssertNotEqual(InspectorView.infoTitle, "调整")

        // Where the string comes from, read from the one file that renders it: SwiftUI `Text` has no
        // AppKit view and no AX node under `swift test`, so this is the honest place to pin it.
        let source = try String(contentsOf: Self.inspectorSource, encoding: .utf8)
        XCTAssertTrue(source.contains("card(Self.infoTitle)"),
                      "the 信息 block must be titled from the one constant, not a second literal")
        XCTAssertFalse(source.contains("Text(\"调整\")"),
                       "the old 调整 title is still in the inspector")
        print("PINNED title: 「\(InspectorView.infoTitle)」 (old literal 「调整」 absent: "
              + "\(!source.contains("Text(\"调整\")")))")
    }

    private static var inspectorSource: URL {
        // Tests/PhotonsUITests/<this file> → package root → Sources/PhotonsUI/InspectorView.swift
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/PhotonsUI/InspectorView.swift")
    }

    // MARK: - (b) the pinned blocks do not move with the window

    func testPinnedBlocksKeepTheSamePositionAndHeightAtBothWindowHeights() throws {
        let tall = try host(height: 800)
        let short = try host(height: 420)
        defer { tall.window.contentView = nil; short.window.contentView = nil }

        // 派单 022 把「相机 · 镜头」一行拆成两行，所以 marquee 从 2 变 3（文件名 / 相机 / 镜头）。
        // 第 1 行里的两个数值格是普通 Text，不产生 marquee。
        XCTAssertEqual(tall.infoRows.count, 3, "file name + camera + lens are the three marquees")
        XCTAssertEqual(short.infoRows.count, 3)
        XCTAssertEqual(tall.infoRows.count, short.infoRows.count)

        // The 信息 block: every row at the same y, the same height, the same width.
        for (index, row) in tall.infoRows.enumerated() {
            let other = short.infoRows[index]
            XCTAssertEqual(other.minY, row.minY, accuracy: 0.001,
                           "信息 row \(index) moved with the window: \(row.minY) → \(other.minY)")
            XCTAssertEqual(other.height, row.height, accuracy: 0.001,
                           "信息 row \(index) changed height: \(row.height) → \(other.height)")
        }
        // The 直方图 block: the plot, same y, same height.
        XCTAssertEqual(short.histogramPlot.minY, tall.histogramPlot.minY, accuracy: 0.001,
                       "the histogram moved with the window: "
                       + "\(tall.histogramPlot.minY) → \(short.histogramPlot.minY)")
        XCTAssertEqual(short.histogramPlot.height, tall.histogramPlot.height, accuracy: 0.001)
        // And both blocks are inside the panel, in the order 信息 then 直方图 (10 pt between them).
        XCTAssertLessThan(tall.infoBlockBottom, tall.histogramPlot.minY)
        XCTAssertEqual(short.histogramPlot.minY - short.infoBlockBottom,
                       tall.histogramPlot.minY - tall.infoBlockBottom, accuracy: 0.001,
                       "the gap between the two pinned blocks must not breathe either")

        print(String(format: "PINNED frames (window 800 → 420), host coords, y from top: "
                     + "信息 rows %@ → %@ · 直方图 plot (y %.1f, h %.1f) → (y %.1f, h %.1f)",
                     "\(tall.infoRows.map { String(format: "(y %.1f, h %.1f)", $0.minY, $0.height) })",
                     "\(short.infoRows.map { String(format: "(y %.1f, h %.1f)", $0.minY, $0.height) })",
                     tall.histogramPlot.minY, tall.histogramPlot.height,
                     short.histogramPlot.minY, short.histogramPlot.height))
    }

    // MARK: - (c) the histogram is not squeezed by the shorter window

    func testTheHistogramKeepsItsHeightWhenTheWindowShrinks() throws {
        let tall = try host(height: 800)
        let short = try host(height: 420)
        defer { tall.window.contentView = nil; short.window.contentView = nil }

        XCTAssertEqual(short.histogramPlot.height, Self.plotHeight, accuracy: 0.001,
                       "the plot must be its own 104 pt at 420 pt of window")
        XCTAssertGreaterThanOrEqual(short.histogramPlot.height, tall.histogramPlot.height * 0.99,
                                    "the histogram was compressed: "
                                    + "\(tall.histogramPlot.height) → \(short.histogramPlot.height)")
        // Its width is the card content width at both heights: the panel is not re-flowed either.
        // 派单 022: row 0 shares its line with `60 MP` / `9000×6000`, so it is the left column of
        // that line — it still starts at the content's left edge and stays inside it; 相机 and 镜头
        // are alone and take the whole content width.
        let contentMinX: CGFloat = 12 + WorkspaceLayout.cardInsetH
        for panel in [tall, short] {
            XCTAssertEqual(panel.histogramPlot.width, cardContentWidth, accuracy: 0.5,
                           "plot width \(panel.histogramPlot.width) ≠ card content \(cardContentWidth)")
            XCTAssertEqual(panel.infoRows[0].minX, contentMinX, accuracy: 0.5,
                           "the file name column starts at \(panel.infoRows[0].minX), not \(contentMinX)")
            XCTAssertLessThanOrEqual(panel.infoRows[0].maxX, contentMinX + cardContentWidth + 0.5)
            for row in panel.infoRows.dropFirst() {
                XCTAssertEqual(row.width, cardContentWidth, accuracy: 0.5,
                               "信息 row width \(row.width) ≠ card content \(cardContentWidth)")
            }
        }
        print(String(format: "PLOT height: 800 → %.1f pt, 420 → %.1f pt (ratio %.3f), width %.1f pt",
                     tall.histogramPlot.height, short.histogramPlot.height,
                     short.histogramPlot.height / tall.histogramPlot.height,
                     short.histogramPlot.width))
    }

    // MARK: - (d) the settings below are the scrollable half

    func testTheScrollRegionTakesTheRemainingHeightAndMovesWhenScrolled() throws {
        let tall = try host(height: 800)
        let short = try host(height: 420)
        defer { tall.window.contentView = nil; short.window.contentView = nil }

        // The pinned block occupies the same top band in both windows; the scroll viewport is what
        // the missing 380 pt comes out of. `pinnedBottom + 10` is the pinned column's own bottom
        // margin, and the viewport starts right under it.
        XCTAssertEqual(short.scrollViewport.minY, tall.scrollViewport.minY, accuracy: 0.001,
                       "the viewport must start under the pinned blocks at any height")
        XCTAssertEqual(tall.scrollViewport.height + tall.scrollViewport.minY, 800, accuracy: 0.5)
        XCTAssertEqual(short.scrollViewport.height + short.scrollViewport.minY, 420, accuracy: 0.5)
        XCTAssertLessThan(short.scrollViewport.height, tall.scrollViewport.height)
        XCTAssertGreaterThan(short.scrollDocument.height, short.scrollViewport.height,
                             "the 蒙版 card is below the fold at 420 — the region really is scrollable")

        // Move the scroll offset: the settings move, the pinned blocks do not. This is the assertion
        // that separates "below the pinned block" from "scrolls".
        let scrollView = try XCTUnwrap(Self.views(of: "HostingScrollView", in: short.host).first
                                       as? NSScrollView, "the hosting scroll view is not an NSScrollView")
        let offset: CGFloat = 200
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: offset))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        short.host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))

        let scrolledProbe = try XCTUnwrap(Self.views(of: "MaskPanelProbe", in: short.host).first
                                            .map { $0.convert($0.bounds, to: short.host) })
        let scrolledRows = Self.views(of: "MarqueeRowView", in: short.host)
            .map { $0.convert($0.bounds, to: short.host) }
        let scrolledPlot = try XCTUnwrap(Self.views(of: "HistogramCardView", in: short.host).first
                                           .map { $0.convert($0.bounds, to: short.host) })

        XCTAssertEqual(short.maskProbe.minY - scrolledProbe.minY, offset, accuracy: 0.5,
                       "the scroll offset did not move the settings: "
                       + "\(short.maskProbe.minY) → \(scrolledProbe.minY) for \(offset) pt")
        XCTAssertEqual(scrolledPlot.minY, short.histogramPlot.minY, accuracy: 0.001,
                       "the histogram scrolled with the settings")
        XCTAssertEqual(scrolledRows.map(\.minY), short.infoRows.map(\.minY),
                       "the 信息 rows scrolled with the settings")

        print(String(format: "SCROLL viewport y %.1f h %.1f (800) vs y %.1f h %.1f (420); "
                     + "document h %.1f; 蒙版 probe y %.1f → %.1f at offset %.0f; "
                     + "pinned y %.1f / %.1f unchanged",
                     tall.scrollViewport.minY, tall.scrollViewport.height,
                     short.scrollViewport.minY, short.scrollViewport.height,
                     short.scrollDocument.height,
                     short.maskProbe.minY, scrolledProbe.minY, offset,
                     scrolledRows.first?.minY ?? -1, scrolledPlot.minY))
    }

    // MARK: - one histogram, and the section list still says where everything is

    func testTheHistogramIsRenderedOnceAndOutOfTheScrollingList() throws {
        let panel = try host(height: 800)
        defer { panel.window.contentView = nil }
        XCTAssertEqual(panel.histogramCards, 1, "the histogram is rendered twice")

        // The scrolling half is derived from `allCases`, so it cannot disagree with the enum.
        XCTAssertFalse(InspectorView.scrollingSections.contains(.histogram))
        XCTAssertEqual(InspectorView.scrollingSections,
                       InspectorView.Section.allCases.filter { $0 != .histogram })
        // The enum (and therefore the smoke's card order) is untouched: 直方图 still leads it.
        XCTAssertEqual(Array(InspectorView.sectionTitles.prefix(3)), ["直方图", "白平衡", "Light"])
        print("SECTIONS scrolling \(InspectorView.scrollingSections.map(\.title)) · "
              + "titles \(InspectorView.sectionTitles) · histogram cards in tree \(panel.histogramCards)")
    }
}
