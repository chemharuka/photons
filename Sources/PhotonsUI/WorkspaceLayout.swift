import Foundation
import CoreGraphics
import AppKit

/// Every frame in the workspace comes from one resolver — the discipline `local/research/ui-stack.md`
/// credits for the shell that survived four rounds of redesign (Phos `WorkspaceLayout.resolve`).
///
/// The numbers are the layout contract of docs/tasks/004-ui-skeleton.md §2b:
///
/// | element | value |
/// |---|---|
/// | top tool container | 36 pt, buttons 28 pt, shared centre line with the traffic lights |
/// | browser (sources + photo rows) | 212 pt default, 196…260, row height 46 pt |
/// | filmstrip (second browser) | 83 pt tall (one row), 111 × 69 pt cells |
/// | inspector | 330 pt default, 300…364 |
/// | safe editing area | at least 560 × 420 |
///
/// Nothing here touches AppKit, so the resolver is unit-tested against three window widths rather
/// than eyeballed.
public enum BrowserMode: String, Sendable, CaseIterable {
    /// Photo rows live in the left browser (`⌃⌘A`).
    case list
    /// Photo rows live in the bottom strip (`⌃⌘B`); the left browser keeps the sources.
    case filmstrip
}

public struct WorkspaceGeometry: Equatable, Sendable {
    public var window: CGSize
    public var topBar: CGRect
    public var browser: CGRect
    public var browserDivider: CGRect
    public var canvas: CGRect
    public var inspector: CGRect
    public var inspectorDivider: CGRect
    public var filmstrip: CGRect?
    /// X where tool content may start (right of the traffic lights).
    public var toolContentLeading: CGFloat
    /// The area the loupe must never shrink below.
    public var safeCanvas: CGSize
}

public enum WorkspaceLayout {
    // MARK: contract constants

    public static let topBarHeight: CGFloat = 36
    /// Distance from the window's top edge to the tool container, so its centre sits on the
    /// traffic lights' line (12 + 36/2 = 30 pt from the top).
    public static let topBarInset: CGFloat = 12
    /// Hit box of a top-bar button; the button itself paints 26–28 pt high inside it.
    public static let toolButtonHit: CGFloat = 28
    public static let toolButtonPaddingH: CGFloat = 9
    public static let toolButtonHeight: CGFloat = 26
    public static let toolCornerRadius: CGFloat = 7
    public static let toolSeparatorHeight: CGFloat = 18

    public static let trafficLightsWidth: CGFloat = 78

    public static let browserWidthDefault: CGFloat = 212
    public static let browserWidthMin: CGFloat = 196
    public static let browserWidthMax: CGFloat = 260
    public static let browserRowHeight: CGFloat = 46

    /// Height of the bottom strip: `8 + 69 + 6 = 83`, i.e. **one** row, not two.
    ///
    /// The old 122 was `8 + 50 + 8 + 50 + 6` — exactly two 50 pt cells plus one 8 pt gap. That is
    /// what produced the two rows: `NSCollectionViewFlowLayout` with `scrollDirection = .horizontal`
    /// fills a **column** top-to-bottom and only then moves right (the "lines" run vertically), so
    /// the number of rows is the packing of the available height, not a property of the scroll
    /// direction. `.horizontal` was set all along; the height budget was what allowed a second row.
    /// Keep `filmstripHeight == insetTop + filmstripCell.height + insetBottom`: `FilmstripController`
    /// derives the applied item height from the live container, so a taller strip grows the cell
    /// instead of silently wrapping into a second column.
    public static let filmstripHeight: CGFloat = 83
    /// Cell: image area 57 pt (`69 − 12` caption) = the old 38 pt × 1.5, width 111 = 74 × 1.5.
    public static let filmstripCell = CGSize(width: 111, height: 69)
    /// Fixed filename caption inside a cell; the image area is `filmstripCell.height − this`.
    public static let filmstripCaptionHeight: CGFloat = 12
    public static let filmstripInsetTop: CGFloat = 8
    public static let filmstripInsetBottom: CGFloat = 6
    public static let filmstripInsetH: CGFloat = 16
    /// Gap between cells in a column *and* between columns (the flow layout has one knob for each;
    /// the strip uses the same value so the two-row budget stays arithmetic, not hope).
    public static let filmstripSpacing: CGFloat = 8

    /// Item height for a strip of `containerHeight`, so one column can only ever hold one item.
    /// A no-op at the contract height (`83 − 8 − 6 = 69 = filmstripCell.height`); the point is that
    /// a future `filmstripHeight` change cannot reintroduce a second row by accident.
    public static func filmstripItemHeight(for containerHeight: CGFloat) -> CGFloat {
        max(1, containerHeight - filmstripInsetTop - filmstripInsetBottom)
    }

    /// Cells a `.horizontal` flow column holds at `containerHeight`. `cellHeight` defaults to what
    /// `FilmstripController` applies (derived from the container, so 1); passing the old 50 pt cell
    /// at the old 122 pt strip returns **2** — the two rows, reproduced as arithmetic.
    public static func filmstripItemsPerColumn(containerHeight: CGFloat, cellHeight: CGFloat? = nil) -> Int {
        let available = containerHeight - filmstripInsetTop - filmstripInsetBottom
        let cell = cellHeight ?? filmstripItemHeight(for: containerHeight)
        guard cell > 0, available > 0 else { return 0 }
        var used: CGFloat = 0
        var count = 0
        while used + cell <= available + 0.001 {
            used += cell + filmstripSpacing
            count += 1
        }
        return count
    }

    public static let inspectorWidthDefault: CGFloat = 330
    public static let inspectorWidthMin: CGFloat = 300
    public static let inspectorWidthMax: CGFloat = 364

    public static let minimumSafeCanvas = CGSize(width: 560, height: 420)
    public static let minimumWindowSize = CGSize(width: 1200, height: 780)

    /// Matte panel/card radii (§2b item 5).
    public static let cardCornerRadius: CGFloat = 9
    public static let panelCornerRadius: CGFloat = 10
    public static let cardInsetH: CGFloat = 16
    public static let cardInsetV: CGFloat = 10

    public static let dividerThickness: CGFloat = 1

    // MARK: resolve

    public static func clampBrowserWidth(_ w: CGFloat) -> CGFloat {
        min(max(w, browserWidthMin), browserWidthMax)
    }

    public static func clampInspectorWidth(_ w: CGFloat) -> CGFloat {
        min(max(w, inspectorWidthMin), inspectorWidthMax)
    }

    /// The whole window: top bar, browser | canvas | inspector, optional bottom filmstrip.
    ///
    /// Widths are clamped to their contract ranges *and then* shrunk further if the canvas would
    /// drop under 560 pt (the inspector gives up width first — it is the panel with the least
    /// content in M3).
    ///
    /// `trafficLightCentreY` is measured from the live window (the system owns that position); the
    /// tool container is centred on it, which is the "same row as the traffic lights" rule. The
    /// measured value on this system is 30 pt from the top, and that is what the default yields.
    public static func resolve(window size: CGSize,
                              mode: BrowserMode = .list,
                              browserWidth: CGFloat = browserWidthDefault,
                              inspectorWidth: CGFloat = inspectorWidthDefault,
                              trafficLightCentreY: CGFloat? = nil) -> WorkspaceGeometry {
        let w = max(size.width, minimumWindowSize.width)
        let h = max(size.height, minimumWindowSize.height)

        // Window size is clamped to the contract minimum first, so the canvas floor (560 pt) is met
        // by construction at 1200 pt: 1200 − 260 − 364 − 2 = 574. No panel shrinking needed, and none
        // is pretended: the drag ranges already stop at 260 / 364.
        let bw = clampBrowserWidth(browserWidth)
        let iw = clampInspectorWidth(inspectorWidth)

        let strip: CGFloat = mode == .filmstrip ? filmstripHeight : 0
        let toolbarY = max(0, (trafficLightCentreY ?? (topBarInset + topBarHeight / 2)) - topBarHeight / 2)
        let topBar = CGRect(x: 0, y: toolbarY, width: w, height: topBarHeight)
        let bodyTop = topBar.maxY
        let bodyBottom = h - strip
        let bodyHeight = max(1, bodyBottom - bodyTop)

        let browser = CGRect(x: 0, y: bodyTop, width: bw, height: bodyHeight)
        let browserDivider = CGRect(x: bw, y: bodyTop, width: dividerThickness, height: bodyHeight)
        let canvasX = bw + dividerThickness
        let canvasW = max(1, w - canvasX - iw - dividerThickness)
        let canvas = CGRect(x: canvasX, y: bodyTop, width: canvasW, height: bodyHeight)
        let inspectorDivider = CGRect(x: canvas.maxX, y: bodyTop,
                                      width: dividerThickness, height: bodyHeight)
        let inspector = CGRect(x: canvas.maxX + dividerThickness, y: bodyTop,
                               width: iw, height: max(1, h - bodyTop))
        let filmstrip = mode == .filmstrip
            ? CGRect(x: 0, y: bodyBottom, width: canvas.maxX + dividerThickness, height: strip)
            : nil

        return WorkspaceGeometry(window: CGSize(width: w, height: h),
                                 topBar: topBar,
                                 browser: browser,
                                 browserDivider: browserDivider,
                                 canvas: canvas,
                                 inspector: inspector,
                                 inspectorDivider: inspectorDivider,
                                 filmstrip: filmstrip,
                                 toolContentLeading: trafficLightsWidth + 10,
                                 safeCanvas: minimumSafeCanvas)
    }
}

/// Photo-grid metrics, also pure and also tested: the UI reads the columns it drew from the same
/// function the layout used, so "assert the layout" is meaningful instead of tautological.
public struct GridMetrics: Equatable, Sendable {
    public var columns: Int
    public var itemSize: CGSize
    public var rowHeight: CGFloat
    public var inset: CGFloat
    public var spacing: CGFloat
}

public enum GridLayout {
    /// Smallest card that still shows a readable filename.
    public static let minItemWidth: CGFloat = 150
    public static let spacing: CGFloat = 12
    public static let inset: CGFloat = 16
    /// Filename + stars under the swatch.
    public static let labelHeight: CGFloat = 22
    /// Card aspect (width / height of the swatch), matching the placeholder cards.
    public static let swatchAspect: CGFloat = 1.35

    public static func metrics(forWidth width: CGFloat) -> GridMetrics {
        let usable = max(minItemWidth, width - inset * 2)
        let columns = max(1, Int((usable + spacing) / (minItemWidth + spacing)))
        let itemWidth = (usable - CGFloat(columns - 1) * spacing) / CGFloat(columns)
        let itemHeight = (itemWidth / swatchAspect).rounded() + labelHeight
        return GridMetrics(columns: columns,
                           itemSize: CGSize(width: floor(itemWidth), height: itemHeight),
                           rowHeight: itemHeight + spacing,
                           inset: inset,
                           spacing: spacing)
    }
}

/// A top-left origin view for the hand-laid-out panes (AppKit's default is bottom-left).
public final class FlippedView: NSView {
    public override var isFlipped: Bool { true }
}
