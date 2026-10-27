import AppKit
import PhotonsCatalog

/// How the 15 dimensions and their canonical values read on screen.
///
/// The catalog speaks canonical strings (`"03"`, `"leica|sl3"`, `"1/800"`, `"1.2"`, `"1"`); the bar is
/// the only layer that knows how to say them out loud. Kept apart from `FilterBarView` so the same
/// words can be used by the slot titles, the checklist rows and the tests without a second copy.
enum FilterDisplay {

    /// Short enough to sit in a 34 pt popup: 星级 / 旗标 / 相机 / 镜头 / 后缀 / 月 / 日 …
    static func title(_ dimension: FilterDimension) -> String {
        switch dimension {
        case .month: return "月"
        case .day: return "日"
        case .ext: return "后缀"
        case .rating: return "星级"
        case .flag: return "旗标"
        case .color: return "色标"
        case .camera: return "相机"
        case .serial: return "序列号"
        case .lens: return "镜头"
        case .focal: return "焦距"
        case .shutter: return "快门"
        case .aperture: return "光圈"
        case .iso: return "ISO"
        case .flash: return "闪光灯"
        case .gps: return "GPS"
        }
    }

    /// The checklist entry in the dimension picker — what the 15-row list prints.
    static func longTitle(_ dimension: FilterDimension) -> String {
        switch dimension {
        case .ext: return "文件后缀"
        case .shutter: return "快门速度"
        case .gps: return "GPS 数据"
        case .focal: return "焦距"
        default: return title(dimension)
        }
    }

    static func value(_ dimension: FilterDimension, _ value: String,
                      cameraLabels: [String: String] = [:]) -> String {
        switch dimension {
        case .month:
            return "\(Int(value) ?? 0) 月"
        case .day:
            return "\(Int(value) ?? 0) 日"
        case .ext:
            return value.uppercased()
        case .rating:
            return value == "0" ? "未评级" : "\(value)★"
        case .flag:
            switch value {
            case "pick": return "留用"
            case "reject": return "排除"
            case FilterValue.none: return "未标记"
            default: return value
            }
        case .color:
            if value == FilterValue.none { return "无" }
            return ColorLabel.normalized(value)?.displayName ?? value
        case .camera:
            // The key is `make|model`, lowercased; the model is what the user recognises.
            return cameraLabels[value] ?? value.replacingOccurrences(of: "|", with: " ")
        case .serial, .lens, .shutter, .iso:
            return value
        case .focal:
            return "\(value) mm"
        case .aperture:
            // 8.0 reads f/8, 2.8 reads f/2.8 — the same convention the inspector uses.
            if let d = Double(value), d == d.rounded() { return "f/\(Int(d))" }
            return "f/\(value)"
        case .flash, .gps:
            return value == FilterValue.yes ? "有" : "无"
        }
    }

    /// The slot control's own title, in three states (051).
    ///
    /// Nothing ticked → 「全部星级」. Exactly one value → 「星级 5★」, because the value *is* the answer.
    /// Two or more → 「部分星级」: spelling out 「星级 1★、2★、5★」 spends 200 pt to say "some" and pushes
    /// the other slots off the bar, which is the failure 050 just fixed from the other end.
    ///
    /// **Boolean dimensions keep the enumeration.** 闪光灯 and GPS only ever offer 有/无, so 「部分闪光灯」
    /// would read like a bug: one tick there is still a complete answer, and 050's chips are gone, so
    /// the bar is the only place that says which one.
    static func slotTitle(_ slot: FilterSlot, cameraLabels: [String: String] = [:]) -> String {
        let name = title(slot.dimension)
        guard !slot.values.isEmpty else { return "全部\(name)" }
        if Self.isBoolean(slot.dimension) || slot.values.count == 1 {
            let shown = slot.values
                .map { value(slot.dimension, $0, cameraLabels: cameraLabels) }
                .joined(separator: "、")
            return "\(name) \(shown)"
        }
        return "部分\(name)"
    }

    /// 有/无 dimensions — the two whose facet list is a fixed pair rather than a ladder.
    static func isBoolean(_ dimension: FilterDimension) -> Bool {
        dimension == .flash || dimension == .gps
    }
}

// MARK: - checklist popover (036)

/// One row of a checklist popover.
///
/// `toggle` is a tick box (dimension or value), `action` a plain accent row that runs something
/// without a state (「全部不选」 / 「全部星级」), `note` a disabled explanation (「本库无此数据」).
struct FilterChecklistRow {
    enum Kind { case toggle, action, note }

    let title: String
    let checked: Bool
    let enabled: Bool
    let kind: Kind
    /// What the bar reads back when the row is clicked: a `FilterDimension` raw value, a canonical
    /// value string, or "" for the action/note rows.
    let tag: String

    init(title: String, checked: Bool = false, enabled: Bool = true,
         kind: Kind = .toggle, tag: String = "") {
        self.title = title
        self.checked = checked
        self.enabled = enabled
        self.kind = kind
        self.tag = tag
    }
}

/// The popover's root: flipped, focusable, and the place `Esc` is caught.
final class FilterChecklistRootView: NSView {
    var onCancel: (() -> Void)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func cancelOperation(_ sender: Any?) { onCancel?() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {                 // Esc
            onCancel?()
            return
        }
        super.keyDown(with: event)
    }
}

/// What the popover actually hosts — a plain, **non-flipped** view that owns nothing but its child.
///
/// `NSPopover` frames its `contentViewController`'s view itself: it places that view inside the
/// popover frame at the frame's own border inset (13 pt as of macOS 27.2). Writing a frame on that
/// view therefore fights AppKit — `layoutRows` used to set `origin = .zero`, which moved the whole
/// checklist 13 pt left and 13 pt down *the moment a row was clicked* (the first show was fine
/// because AppKit had already placed it). Keeping the popover's view a dumb container and pinning
/// the flipped checklist inside it means no sheet of ours can ever own the popover's geometry:
/// whatever `contentSize` says, the container is that size and the checklist fills it edge to edge.
final class FilterChecklistContainerView: NSView {}

/// One row of the checklist, drawn by hand so 「置灰」 is a decision rather than an AppKit mood.
///
/// A stock checkbox renders a *disabled but ticked* row as an empty white square (no checkmark, no
/// dimming in this appearance), which would make a full bar look as if nothing were ticked. Drawing
/// the box, the tick and the title here keeps three states legible at once: ticked, ticked-but-greyed
/// (five slots already), and not-available (greyed, click inert). It is still an `NSButton`, so the
/// action, `Tab` and space all behave normally.
///
/// The title is placed from the **ink** box CoreText reports (038): `NSString.draw(in:)` centres the
/// *line fragment*, which leaves CJK ink a hair above the row's centre and made the text read as
/// sitting high. `CTLineGetBoundsWithOptions(.useGlyphPathBounds)` says where the glyphs really are,
/// so the baseline can be put under the ink's own middle.
final class FilterChecklistRowButton: NSButton {

    var row = FilterChecklistRow(title: "") {
        didSet {
            title = row.title
            isEnabled = row.enabled
            toolTip = row.title
            needsDisplay = true
        }
    }

    /// 038 geometry, in the row's own coordinates: the tick box hugs the row's left edge (the row
    /// itself starts at `padding`), the title follows after `boxTextGap`, and at least
    /// `trailingInset` stays clear on the right.
    static let boxSide: CGFloat = 12
    static let boxTextGap: CGFloat = 8
    static let trailingInset: CGFloat = 12
    /// 046: the single left column. The tick box's left edge **and** the action/note rows' text both
    /// start here, so "全部不选" is left-aligned with the boxes above it instead of sitting 2 pt
    /// inside them (the owner's 「选择框往右一些，让『全都不选』和选择框左对齐」). One constant, because
    /// two numbers that must agree are two numbers that will drift.
    static let columnX: CGFloat = 2

    private static let textFont = NSFont.systemFont(ofSize: 11)

    override var isFlipped: Bool { true }

    /// Where the tick box is drawn — also what the layout tests read to check the 10 pt margin.
    var boxRect: NSRect {
        NSRect(x: Self.columnX, y: (bounds.height - Self.boxSide) / 2,
               width: Self.boxSide, height: Self.boxSide)
    }

    /// Where the title starts, in row coordinates.
    var textOriginX: CGFloat {
        // 046: an action row's text starts on the column itself, not 2 pt inside it.
        row.kind == .toggle ? boxRect.maxX + Self.boxTextGap : boxRect.minX
    }

    override func draw(_ dirtyRect: NSRect) {
        let dim: CGFloat = row.enabled ? 1 : 0.4
        let box = boxRect

        if row.kind == .toggle {
            let path = NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3)
            if row.checked {
                NSColor.controlAccentColor.withAlphaComponent(0.95 * dim).setFill()
                path.fill()
                let tick = NSBezierPath()
                tick.move(to: NSPoint(x: box.minX + 2.8, y: box.midY))
                tick.line(to: NSPoint(x: box.midX - 0.4, y: box.maxY - 3.2))
                tick.line(to: NSPoint(x: box.maxX - 2.2, y: box.minY + 3.2))
                tick.lineWidth = 1.6
                tick.lineCapStyle = .round
                tick.lineJoinStyle = .round
                NSColor.white.withAlphaComponent(dim).setStroke()
                tick.stroke()
            } else {
                NSColor.secondaryLabelColor.withAlphaComponent(0.75 * dim).setStroke()
                path.lineWidth = 1
                path.stroke()
            }
        }

        let color: NSColor
        switch row.kind {
        case .action: color = row.enabled ? .controlAccentColor : .disabledControlTextColor
        case .note: color = .disabledControlTextColor
        case .toggle: color = row.enabled ? .labelColor : .disabledControlTextColor
        }
        let textX = textOriginX
        let width = max(0, bounds.maxX - textX - Self.trailingInset)
        guard width > 1, !row.title.isEmpty else { return }
        let attributed = NSAttributedString(string: row.title, attributes: [
            .font: Self.textFont, .foregroundColor: color,
        ])
        Self.drawInkCentred(attributed, x: textX, width: width, height: bounds.height)
    }

    /// Draw `string` with its **ink** centred on `height / 2`, left edge on `x`, truncated to `width`.
    ///
    /// The context is flipped here (row views are), so the baseline is derived in that space: the ink
    /// CoreText reports is y-up around the baseline, and `baselineY = height/2 + ink.midY` is exactly
    /// the place that puts the ink's middle on the row's middle.
    private static func drawInkCentred(_ string: NSAttributedString, x: CGFloat,
                                       width: CGFloat, height: CGFloat) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let line = CTLineCreateWithAttributedString(string)
        let ellipsis = CTLineCreateWithAttributedString(
            NSAttributedString(string: "…", attributes: string.attributes(at: 0, effectiveRange: nil)))
        let drawn = CTLineCreateTruncatedLine(line, Double(width), .end, ellipsis) ?? line
        let ink = CTLineGetBoundsWithOptions(drawn, .useGlyphPathBounds)
        guard ink.height > 0 else { return }

        ctx.saveGState()
        ctx.textMatrix = .identity
        // Flip back to y-up around the baseline so `CTLineDraw` puts glyphs above it.
        ctx.translateBy(x: x, y: height / 2 + ink.midY)
        ctx.scaleBy(x: 1, y: -1)
        CTLineDraw(drawn, ctx)
        ctx.restoreGState()
    }
}

/// A vertical checklist with real `NSButton` rows — 15 dimensions, or one slot's values.
///
/// This exists because `NSMenu` closes as soon as an item is chosen and that cannot be configured
/// away. `NSPopover(behavior: .transient)` is AppKit's own answer to “点选项不关、点外面才关”: the
/// window server dismisses it on the next click outside, and nothing here closes it on a selection.
/// Rows are buttons, so `Tab`/space work; `Esc` arrives at the root view's `cancelOperation`.
final class FilterChecklistController: NSViewController {

    static let width: CGFloat = 236
    static let rowHeight: CGFloat = 22
    /// 038: the content padding. The tick box's left edge lands on this too, so the box and the
    /// first/last row agree on one margin instead of two (8 + 2 before this task).
    static let padding: CGFloat = 10

    private(set) var rows: [FilterChecklistRow] = []
    var onSelect: ((FilterChecklistRow) -> Void)?
    var onCancel: (() -> Void)?

    private var buttons: [FilterChecklistRowButton] = []
    private var buttonKinds: [FilterChecklistRow.Kind] = []
    /// The popover's own view — plain, non-flipped, and never given a frame by us while hosted.
    private let container = FilterChecklistContainerView()
    /// The flipped checklist, pinned to all four edges of `container`.
    private let root = FilterChecklistRootView()

    init() { super.init(nibName: nil, bundle: nil) }

    required init?(coder: NSCoder) { fatalError("no nibs in this app") }

    override func loadView() {
        root.onCancel = { [weak self] in self?.onCancel?() }
        root.autoresizingMask = [.width, .height]
        container.addSubview(root)
        root.frame = container.bounds
        view = container
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // Rows stay Tab-reachable; taking first responder here is what lets Esc be seen before the
        // popover has focus somewhere of its own. The checklist — not the container — is what
        // `cancelOperation` lives on.
        view.window?.makeFirstResponder(root)
    }

    var requiredSize: NSSize {
        NSSize(width: Self.width,
               height: Self.padding * 2 + CGFloat(max(1, rows.count)) * Self.rowHeight)
    }

    /// The flipped checklist, as the layout tests measure it.
    var checklistRoot: NSView { root }

    /// Re-render from a snapshot. When the shape is unchanged the existing buttons are updated **in
    /// place**, so the click that caused the update never destroys the button it came from.
    func reload(_ next: [FilterChecklistRow]) {
        let sameShape = next.count == buttons.count && next.map(\.kind) == buttonKinds
        rows = next
        guard sameShape else {
            rebuild()
            return
        }
        for (index, row) in next.enumerated() where buttons.indices.contains(index) {
            buttons[index].row = row
        }
        layoutRows()
    }

    private func rebuild() {
        for button in buttons { button.removeFromSuperview() }
        buttons = rows.enumerated().map { makeButton(for: $0.element, tag: $0.offset) }
        buttonKinds = rows.map(\.kind)
        for button in buttons { root.addSubview(button) }
        layoutRows()
    }

    private func makeButton(for row: FilterChecklistRow, tag: Int) -> FilterChecklistRowButton {
        let button = FilterChecklistRowButton(title: row.title, target: self,
                                             action: #selector(rowClicked(_:)))
        button.isBordered = false
        button.alignment = .left
        button.focusRingType = .none
        button.tag = tag
        button.row = row
        return button
    }

    /// Size and place the rows — and nothing else.
    ///
    /// This function used to write `root.frame` (which is the *popover's* content view) to
    /// `(origin: .zero, size: requiredSize)`. When the popover was already on screen, that dropped
    /// the content out of the frame's 13 pt inset and everything read as shoved to the lower left.
    /// Now: `preferredContentSize` states the size we want, the container is whatever the popover
    /// makes it, and the checklist is pinned edge to edge inside — so a reload can only re-place
    /// rows, never the popover's geometry.
    private func layoutRows() {
        let target = requiredSize
        preferredContentSize = target
        // Unhosted (a unit test, or a reload before the popover shows): give the container the size
        // it will have. While hosted, AppKit owns this frame and any write would be undone — worse,
        // it would be undone *after* our rows were laid out for the wrong width.
        if container.window == nil && container.superview == nil {
            container.frame = NSRect(origin: .zero, size: target)
        }
        root.frame = container.bounds
        let rowWidth = max(0, root.bounds.width - Self.padding * 2)
        for (index, button) in buttons.enumerated() {
            button.frame = NSRect(x: Self.padding,
                                  y: Self.padding + CGFloat(index) * Self.rowHeight,
                                  width: rowWidth,
                                  height: Self.rowHeight)
        }
        root.needsDisplay = true
    }

    @objc private func rowClicked(_ sender: NSButton) {
        guard rows.indices.contains(sender.tag) else { return }
        onSelect?(rows[sender.tag])
    }
}

/// The grid's filter strip (026 v2, reshaped by 036): **one** small icon button that picks dimensions,
/// then up to five slots.
///
/// ```
/// [ ⧩ ]  [全部星级]  [全部旗标]  [相机 LEICA SL3]  …
/// ```
///
/// * the button is a fixed 24 × 24 SF Symbol (`line.horizontal.3.decrease.circle`, the owner's pick
///   from the contact sheet; `line.horizontal.3.decrease` then `⋯` are the fallbacks) and never
///   widens with text, so nothing can be truncated. `toolTip` and the accessibility label say
///   「选择筛选维度」 either way.
/// * clicking it opens an `NSPopover` (`behavior = .transient`) holding a 15-row tick list, slot
///   numbers as prefixes, 「全部不选」 last. **Choosing a row keeps the popover open** — a dimension
///   is ticked (appended in click order, at most five) or unticked (later slots close the gap), and
///   only a click outside dismisses it. `NSMenu` cannot be made to behave this way; that is why this
///   is a popover and not a menu.
/// * 「全部不选」 empties every slot and **stays open**, so the next five clicks number 1…5 again.
///   When five are ticked the remaining ten rows are **disabled** (greyed), while a ticked row can
///   still be unticked.
/// * each slot's right-hand control is a button opening the same kind of checklist for that slot's
///   values (also multi-select, also stays open). Values inside one slot OR, slots AND.
/// * the only control to the right of the slots is 「清除全部」 — plain grey text, no border, no icon
///   (050). The removable-condition pills that used to sit there are gone with the owner's words
///   「右侧就不要出现蓝色的单独关闭筛选条件的选项了，只保留清除全部四个字」; dropping one condition
///   now happens in the slot's own checklist. `CatalogFilter.chips()` still exists — it is query
///   vocabulary and the log's summary — the bar simply no longer draws it.
///
/// The bar owns **no** filter state: every control reads `filter` and writes back through `onChange`.
/// That is what keeps "切换照片时筛选不变" true without bookkeeping — the filter lives in the session.
public final class FilterBarView: NSView, NSPopoverDelegate {

    public static let height: CGFloat = 28

    // Geometry, also read by the layout tests.
    static let leading: CGFloat = 10
    /// 036: a fixed square — the button is an icon, its width no longer depends on a word.
    static let dimensionButtonWidth: CGFloat = 24
    static let dimensionButtonHeight: CGFloat = 24
    static let slotGap: CGFloat = 4
    static let popupMinWidth: CGFloat = 34
    static let popupMaxWidth: CGFloat = 120

    /// 050: 「清除全部」 — the only control right of the slots. Width = measured ink + 8 pt, so a
    /// system font that measures wider than expected can never clip the word.
    static let clearTitle = "清除全部"
    static let clearFont = NSFont.systemFont(ofSize: 10.5)
    /// How far the button's right edge sits from the bar's right edge.
    static let clearTrailingInset: CGFloat = 12

    static func clearWidth(_ title: String = clearTitle) -> CGFloat {
        ceil((title as NSString).size(withAttributes: [.font: clearFont]).width) + 8
    }

    /// SF Symbols tried in order, as the owner chose from the contact sheet: the funnel-and-circle
    /// filter glyph first, then its ring-less sibling, then `⋯`. `NSImage(systemSymbolName:)` returns
    /// `nil` on a system that does not ship one, which is exactly how the fallback is selected.
    static let dimensionSymbolCandidates = [
        "line.horizontal.3.decrease.circle",   // 15 × 15 native, 16 × 16 @13 pt on macOS 27.2
        "line.horizontal.3.decrease",          // 16 × 10 — no circle
    ]

    /// The first symbol this machine actually has, tinted for `contentTintColor`. 13 pt renders the
    /// chosen glyph at 16 × 16, inside the 24 × 24 box.
    static func dimensionSymbolImage(pointSize: CGFloat = 13) -> NSImage? {
        for name in dimensionSymbolCandidates {
            guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: "选择筛选维度")
            else { continue }
            let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
            let image = symbol.withSymbolConfiguration(config) ?? symbol
            image.isTemplate = true
            return image
        }
        return nil
    }

    public var onChange: ((CatalogFilter) -> Void)?
    public var onClearAll: (() -> Void)?

    /// Where the slot checklists get their values: the catalog, through the session. Asked once per
    /// dimension per `update`, and answered with 「本库无此数据」 (an empty list) when the dimension
    /// has nothing — never with an invented vocabulary.
    public var facetProvider: ((FilterDimension) -> [String])?
    public var cameraLabels: [String: String] = [:]

    private let dimensionButton = NSButton(title: "", target: nil, action: nil)
    private let dimensionPopover = NSPopover()
    private let dimensionChecklist = FilterChecklistController()
    private var dimensionPopoverOpen = false

    private var slotButtons: [NSButton] = []
    private let slotPopover = NSPopover()
    private let slotChecklist = FilterChecklistController()
    private var openSlotIndex: Int?

    private let clearButton = NSButton(title: "", target: nil, action: nil)

    private var filter = CatalogFilter.none
    private var facetCache: [FilterDimension: [String]] = [:]
    /// True while the controls are being synced from the model, so a control's action cannot loop.
    private var isSyncing = false

    public override var isFlipped: Bool { true }

    public init() {
        super.init(frame: .zero)
        wantsLayer = true

        dimensionButton.bezelStyle = .rounded
        dimensionButton.controlSize = .small
        dimensionButton.isBordered = true
        // `.scaleNone`: the symbol is already sized for the box (16 pt in 24 pt). Letting AppKit scale it
        // to the rounded bezel's content rect shrinks it to ~11 pt, which reads as a smudge.
        dimensionButton.imageScaling = .scaleNone
        dimensionButton.contentTintColor = .secondaryLabelColor
        dimensionButton.target = self
        dimensionButton.action = #selector(dimensionButtonTapped)
        dimensionButton.toolTip = "选择筛选维度"
        dimensionButton.setAccessibilityLabel("选择筛选维度")
        if let symbol = Self.dimensionSymbolImage() {
            dimensionButton.image = symbol
            dimensionButton.imagePosition = .imageOnly
            dimensionButton.title = ""
        } else {
            // No symbol on this system: the same 24 × 24 box with a ⋯ — never a clipped word.
            dimensionButton.image = nil
            dimensionButton.imagePosition = .noImage
            dimensionButton.title = "⋯"
            dimensionButton.font = .systemFont(ofSize: 11, weight: .semibold)
        }
        addSubview(dimensionButton)

        for index in 0..<CatalogFilter.slotCapacity {
            let button = NSButton(title: "", target: self, action: #selector(slotButtonTapped(_:)))
            button.controlSize = .small
            button.font = .systemFont(ofSize: 10.5)
            button.bezelStyle = .rounded
            button.cell?.lineBreakMode = .byTruncatingTail
            button.tag = index
            button.isHidden = true
            slotButtons.append(button)
            addSubview(button)
        }

        clearButton.controlSize = .small
        clearButton.bezelStyle = .inline
        clearButton.isBordered = false
        clearButton.font = Self.clearFont
        clearButton.isHidden = true
        clearButton.target = self
        clearButton.action = #selector(clearAllTapped)
        // 050: grey text, no border, no icon, **no accent**. The tint *and* the attributed title are
        // set, because AppKit's default for a plain button's label is the accent colour: one of those
        // two would be enough for us and both are needed to be sure nothing paints it blue.
        clearButton.contentTintColor = .secondaryLabelColor
        clearButton.attributedTitle = NSAttributedString(string: Self.clearTitle, attributes: [
            .font: Self.clearFont,
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        clearButton.setAccessibilityLabel(Self.clearTitle)
        addSubview(clearButton)

        configurePopovers()
    }

    public required init?(coder: NSCoder) { fatalError("no nibs in this app") }

    /// Both popovers share the same recipe: transient (a click outside closes it, a click inside does
    /// not), one checklist controller, and this view as the delegate so `popoverDidClose` can sync the
    /// flags when the system dismisses them.
    private func configurePopovers() {
        for popover in [dimensionPopover, slotPopover] {
            popover.behavior = .transient
            popover.animates = true
            popover.delegate = self
        }
        dimensionPopover.contentViewController = dimensionChecklist
        dimensionChecklist.onSelect = { [weak self] row in self?.handleDimensionRow(row) }
        dimensionChecklist.onCancel = { [weak self] in self?.dismissDimensionPopover() }

        slotPopover.contentViewController = slotChecklist
        slotChecklist.onSelect = { [weak self] row in self?.handleSlotRow(row) }
        slotChecklist.onCancel = { [weak self] in self?.dismissSlotPopover() }
    }

    // MARK: model → bar

    public func update(filter: CatalogFilter, cameraKeys: [String]) {
        update(filter: filter, cameraKeys: cameraKeys, cameraLabels: [:])
    }

    /// `cameraKeys` is kept for the pre-026 call sites (`AssetGridController` passed it); the slot
    /// checklist reads its own list through `facetProvider`, so the parameter now only documents the
    /// library's cameras for callers that do not supply labels.
    public func update(filter: CatalogFilter, cameraKeys: [String], cameraLabels: [String: String]) {
        isSyncing = true
        self.filter = filter
        self.cameraLabels = cameraLabels.isEmpty ? self.cameraLabels : cameraLabels
        facetCache = [:]
        rebuildSlotButtons()
        isSyncing = false
        refreshOpenChecklists()
        clearButton.isHidden = !filter.isActive
        needsLayout = true
        needsDisplay = true
    }

    private func rebuildSlotButtons() {
        for (index, button) in slotButtons.enumerated() {
            guard filter.slots.indices.contains(index) else {
                button.isHidden = true
                button.title = ""
                continue
            }
            let slot = filter.slots[index]
            button.isHidden = false
            button.title = FilterDisplay.slotTitle(slot, cameraLabels: cameraLabels)
            button.toolTip = "选择\(FilterDisplay.title(slot.dimension))的值（可多选）"
            button.setAccessibilityLabel(button.toolTip ?? "")
        }
    }

    /// An open checklist is a live view of the model: a tick updates the slots *and* the row states
    /// (numbers, ticks, the ten greyed rows) without the popover going away.
    private func refreshOpenChecklists() {
        if dimensionPopoverOpen {
            dimensionChecklist.reload(dimensionChecklistRows())
            dimensionPopover.contentSize = dimensionChecklist.requiredSize
        }
        if let index = openSlotIndex {
            guard filter.slots.indices.contains(index) else {
                dismissSlotPopover()
                return
            }
            slotChecklist.reload(slotChecklistRows(at: index))
            slotPopover.contentSize = slotChecklist.requiredSize
        }
    }

    private func facetValues(_ dimension: FilterDimension) -> [String] {
        if let cached = facetCache[dimension] { return cached }
        let values = facetProvider?(dimension) ?? []
        facetCache[dimension] = values
        return values
    }

    // MARK: the two checklists, as snapshots

    /// The 15 dimensions (slot number as prefix, tick when active) + 「全部不选」.
    func dimensionChecklistRows() -> [FilterChecklistRow] {
        let full = filter.slots.count >= CatalogFilter.slotCapacity
        var rows = FilterDimension.allCases.map { dimension -> FilterChecklistRow in
            let slotIndex = filter.slots.firstIndex { $0.dimension == dimension }
            let prefix = slotIndex.map { "\($0 + 1)  " } ?? "    "
            return FilterChecklistRow(title: prefix + FilterDisplay.longTitle(dimension),
                                      checked: slotIndex != nil,
                                      enabled: slotIndex != nil || !full,
                                      kind: .toggle,
                                      tag: dimension.rawValue)
        }
        rows.append(FilterChecklistRow(title: "全部不选",
                                       enabled: !filter.slots.isEmpty,
                                       kind: .action))
        return rows
    }

    /// One slot's values: 「全部xxx」 (clears this slot) first, then the catalog's own ladder — or a
    /// single disabled 「本库无此数据」 when the library has nothing for that dimension.
    func slotChecklistRows(at index: Int) -> [FilterChecklistRow] {
        guard filter.slots.indices.contains(index) else { return [] }
        let slot = filter.slots[index]
        // 051: the accent row at the top of a slot's list is an **action**, so it says what it does.
        // It used to repeat the selection (「星级 1★、2★、5★」) in blue, which read as a value and made
        // the list's first line longer than the button that opened it.
        var rows = [FilterChecklistRow(title: slot.values.isEmpty
                                        ? "全部\(FilterDisplay.title(slot.dimension))"
                                        : "取消选择",
                                       enabled: !slot.values.isEmpty,
                                       kind: .action)]
        let values = facetValues(slot.dimension)
        if values.isEmpty {
            rows.append(FilterChecklistRow(title: "本库无此数据", enabled: false, kind: .note))
        } else {
            rows += values.map { value in
                FilterChecklistRow(title: FilterDisplay.value(slot.dimension, value,
                                                              cameraLabels: cameraLabels),
                                   checked: slot.values.contains(value),
                                   kind: .toggle,
                                   tag: value)
            }
        }
        return rows
    }

    // MARK: controls → model

    @objc private func dimensionButtonTapped() {
        guard !isSyncing else { return }
        if dimensionPopoverOpen {
            dismissDimensionPopover()
        } else {
            showDimensionPopover()
        }
    }

    func showDimensionPopover() {
        dimensionChecklist.reload(dimensionChecklistRows())
        dimensionPopover.contentSize = dimensionChecklist.requiredSize
        dimensionPopoverOpen = true
        // Without a window (unit tests, a detached view) there is nothing to anchor to; the model
        // state above is still the truth the bar reports, and `performDimensionRow` still drives it.
        guard dimensionButton.window != nil else { return }
        dimensionPopover.show(relativeTo: dimensionButton.bounds,
                              of: dimensionButton,
                              preferredEdge: .maxY)
    }

    func dismissDimensionPopover() {
        dimensionPopoverOpen = false
        if dimensionPopover.isShown { dimensionPopover.performClose(nil) }
    }

    /// A dimension row: tick/untick a slot, or 「全部不选」. **Never closes the popover** — that is the
    /// whole point of 036, and it is what `.transient` + a live reload buys us.
    private func handleDimensionRow(_ row: FilterChecklistRow) {
        guard !isSyncing, row.enabled else { return }
        switch row.kind {
        case .action:
            clearSlotDimensions()
        case .toggle:
            guard let dimension = FilterDimension(rawValue: row.tag) else { return }
            chooseDimension(dimension)
        case .note:
            return
        }
    }

    /// One dimension click — the checklist row's action, and the seam the UI tests drive.
    public func chooseDimension(_ dimension: FilterDimension) {
        let next = filter.togglingDimension(dimension)
        guard next != filter else { return }
        onChange?(next)
    }

    @objc private func slotButtonTapped(_ sender: NSButton) {
        guard !isSyncing else { return }
        let index = sender.tag
        if openSlotIndex == index {
            dismissSlotPopover()
        } else {
            showSlotPopover(at: index)
        }
    }

    func showSlotPopover(at index: Int) {
        guard filter.slots.indices.contains(index),
              slotButtons.indices.contains(index), !slotButtons[index].isHidden else { return }
        dismissSlotPopover()
        slotChecklist.reload(slotChecklistRows(at: index))
        slotPopover.contentSize = slotChecklist.requiredSize
        openSlotIndex = index
        guard slotButtons[index].window != nil else { return }
        slotPopover.show(relativeTo: slotButtons[index].bounds,
                         of: slotButtons[index],
                         preferredEdge: .maxY)
    }

    func dismissSlotPopover() {
        openSlotIndex = nil
        if slotPopover.isShown { slotPopover.performClose(nil) }
    }

    /// A value row: tick/untick inside the open slot, or 「全部xxx」 to empty it. Stays open.
    private func handleSlotRow(_ row: FilterChecklistRow) {
        guard !isSyncing, let index = openSlotIndex,
              filter.slots.indices.contains(index), row.enabled else { return }
        switch row.kind {
        case .action:
            let next = filter.settingValues([], atSlot: index)
            guard next != filter else { return }
            onChange?(next)
        case .toggle:
            let next = filter.togglingValue(row.tag, atSlot: index)
            guard next != filter else { return }
            onChange?(next)
        case .note:
            return
        }
    }

    @objc private func clearAllTapped() { onClearAll?() }

    // MARK: popover dismissal

    /// The system's transient dismissal (a click outside, Esc in the popover window) lands here, so
    /// the flags cannot drift out of step with what is on screen.
    public func popoverDidClose(_ notification: Notification) {
        guard let popover = notification.object as? NSPopover else { return }
        if popover === dimensionPopover { dimensionPopoverOpen = false }
        if popover === slotPopover { openSlotIndex = nil }
    }

    // MARK: geometry

    public override func layout() {
        super.layout()
        let h = bounds.height
        let mid = max(0, (h - 22) / 2)

        var x = Self.leading
        // 036: a 24 × 24 icon, centred in the 28 pt strip; its width never depends on its label.
        dimensionButton.frame = NSRect(x: x, y: max(0, (h - Self.dimensionButtonHeight) / 2),
                                      width: Self.dimensionButtonWidth,
                                      height: Self.dimensionButtonHeight)
        x += Self.dimensionButtonWidth + 6

        // 050: nothing is reserved for removable pills any more — there are none. The only slice taken
        // out of the slots' share is 「清除全部」's own width at the far right (+4 pt of breathing room,
        // the same allowance the old hard-coded 54 pt budget made), and every point after that goes to
        // the slot popups. That is the whole trade the owner asked for: the slot's title already spells
        // out the values it holds, so the second row of feedback buys nothing and its width is better
        // spent on the entry.
        let clearWidth = filter.isActive ? Self.clearWidth() : 0
        let clearReserve = clearWidth > 0 ? clearWidth + 4 : 0
        let available = max(0, bounds.width - x - 8 - clearReserve)

        let slotCount = min(filter.slots.count, CatalogFilter.slotCapacity)
        var popupWidth = Self.popupMaxWidth
        var visible = slotCount
        if slotCount > 0 {
            popupWidth = min(Self.popupMaxWidth,
                             max(Self.popupMinWidth, available / CGFloat(slotCount) - Self.slotGap))
            // Only when even a 34 pt popup does not fit is a whole slot dropped — 24 + 34 + gap is
            // the narrowest a slot can be and still be a button you can hit.
            while visible > 0 && CGFloat(visible) * (popupWidth + Self.slotGap) > available + 0.5 {
                visible -= 1
                popupWidth = min(Self.popupMaxWidth,
                                 max(Self.popupMinWidth, available / CGFloat(max(1, visible)) - Self.slotGap))
            }
        }

        for (index, button) in slotButtons.enumerated() {
            guard index < visible, filter.slots.indices.contains(index) else {
                button.isHidden = true
                button.frame = .zero
                continue
            }
            button.isHidden = false
            button.frame = NSRect(x: x, y: mid, width: popupWidth, height: 22)
            x += popupWidth + Self.slotGap
        }

        // 「清除全部」 is pinned to the right edge: `maxX == bounds.width - clearTrailingInset` at every
        // bar width, however many slots are drawn and however wide they ended up.
        clearButton.isHidden = !filter.isActive
        clearButton.frame = filter.isActive
            ? NSRect(x: bounds.width - clearWidth - Self.clearTrailingInset,
                     y: mid + 3, width: clearWidth, height: 16)
            : .zero
    }

    public override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.withAlphaComponent(0.55).setFill()
        bounds.fill()
        NSColor.labelColor.withAlphaComponent(0.10).setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        // 050: nothing else is painted. The accent-tinted pill row lived here; the bar is now the
        // strip, its buttons, and the grey 「清除全部」 word.
    }

    // MARK: test seams (the UI tests drive the same actions a click does)

    // MARK: 「清除全部」 seams (050)

    public var clearButtonFrame: NSRect { clearButton.frame }

    /// What the button says — the owner's four words, nothing appended.
    public var clearButtonTitle: String { clearButton.title }

    public var isClearButtonHidden: Bool { clearButton.isHidden }

    public var clearButtonIsBordered: Bool { clearButton.isBordered }

    public var clearButtonTintColor: NSColor? { clearButton.contentTintColor }

    /// The colour the title is actually drawn in. `nil` when the button carries no attributed title
    /// (i.e. AppKit would pick its own — and its own default for a plain button is the accent).
    public var clearButtonTextColor: NSColor? {
        let attributed = clearButton.attributedTitle
        guard attributed.length > 0 else { return nil }
        return attributed.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
    }

    public var clearButtonFont: NSFont? {
        let attributed = clearButton.attributedTitle
        guard attributed.length > 0 else { return clearButton.font }
        return attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont ?? clearButton.font
    }

    public var clearButtonAccessibilityLabel: String? { clearButton.accessibilityLabel() }

    /// Press 「清除全部」 through the button's own target/action — the same call AppKit makes when the
    /// user clicks it, so a test exercises the production path rather than a private shortcut.
    public func performClearAllClick() { clearButton.performClick(nil) }

    /// The slots' dimensions, left to right.
    public var slotDimensions: [FilterDimension] { filter.slots.map(\.dimension) }

    public func slotValues(at index: Int) -> [String] {
        filter.slots.indices.contains(index) ? filter.slots[index].values : []
    }

    /// The slot control's title — what the user reads in the bar.
    public func slotTitle(at index: Int) -> String? {
        guard filter.slots.indices.contains(index) else { return nil }
        return FilterDisplay.slotTitle(filter.slots[index], cameraLabels: cameraLabels)
    }

    public func slotPopupFrame(at index: Int) -> NSRect? {
        guard slotButtons.indices.contains(index), !slotButtons[index].isHidden else { return nil }
        return slotButtons[index].frame
    }

    public var slotVisibleCount: Int {
        slotButtons.filter { !$0.isHidden }.count
    }

    public var dimensionButtonFrame: NSRect { dimensionButton.frame }

    /// The icon actually installed — non-`nil` means this machine ships the SF Symbol.
    public var dimensionButtonImage: NSImage? { dimensionButton.image }

    /// Empty when the icon path was used; `⋯` only when no symbol existed.
    public var dimensionButtonTitle: String { dimensionButton.title }

    public var dimensionButtonToolTip: String? { dimensionButton.toolTip }

    public var dimensionButtonAccessibilityLabel: String? { dimensionButton.accessibilityLabel() }

    // MARK: dimension checklist seams

    /// The dimension checklist as it would draw: `(title, checked, enabled)`, 15 dimensions then
    /// 「全部不选」. (Named `…MenuRows` because 026's tests read it; there is no `NSMenu` any more.)
    public var dimensionMenuRows: [(title: String, checked: Bool, enabled: Bool)] {
        dimensionChecklistRows().map { ($0.title, $0.checked, $0.enabled) }
    }

    public var isDimensionPopoverOpen: Bool { dimensionPopoverOpen }

    /// The live popover and the checklist's own root — what the layout tests measure, so a size that
    /// drifts apart between `contentSize`, `preferredContentSize` and the root's frame is visible
    /// from a test rather than only from the screen.
    var dimensionPopoverForLayoutTests: NSPopover { dimensionPopover }
    var dimensionChecklistForLayoutTests: FilterChecklistController { dimensionChecklist }
    var slotPopoverForLayoutTests: NSPopover { slotPopover }
    var slotChecklistForLayoutTests: FilterChecklistController { slotChecklist }

    /// Open it the way the button does. Without a window the logical state is still tracked, which is
    /// what the tests assert on; in the app this is the same `.transient` popover the user sees.
    public func openDimensionPopover() { showDimensionPopover() }

    public func closeDimensionPopover() { dismissDimensionPopover() }

    /// Click a dimension-checklist row by index — the same handler the row's `NSButton` runs, so
    /// "does the popover stay open" is answered by the production path, not by a test-only shortcut.
    public func performDimensionRow(at index: Int) {
        let rows = dimensionChecklistRows()
        guard rows.indices.contains(index) else { return }
        handleDimensionRow(rows[index])
    }

    /// 「全部不选」 — the checklist's last row, and the seam the UI tests use for it.
    public func clearSlotDimensions() {
        guard !filter.slots.isEmpty else { return }
        onChange?(filter.clearingSlots())
    }

    // MARK: slot checklist seams

    /// The rows a slot's checklist currently holds (「全部xxx」, then values or 「本库无此数据」) — so a
    /// test can see the empty-state row instead of just an empty array.
    public func slotMenuTitles(at index: Int) -> [String] {
        slotChecklistRows(at: index).map(\.title)
    }

    /// A slot's checklist rows as it would draw them: `(title, checked, enabled)`.
    public func slotChecklistRowModels(at index: Int) -> [(title: String, checked: Bool, enabled: Bool)] {
        slotChecklistRows(at: index).map { ($0.title, $0.checked, $0.enabled) }
    }

    public var openSlotPopoverIndex: Int? { openSlotIndex }

    public func isSlotPopoverOpen(at index: Int) -> Bool { openSlotIndex == index }

    public func openSlotPopover(at index: Int) { showSlotPopover(at: index) }

    public func closeSlotPopover() { dismissSlotPopover() }

    /// Click a row of the open slot checklist by index (summary row 0, values after it).
    public func performSlotRow(at index: Int) {
        guard let slot = openSlotIndex else { return }
        let rows = slotChecklistRows(at: slot)
        guard rows.indices.contains(index) else { return }
        handleSlotRow(rows[index])
    }

    /// Choose values for a slot without going through the checklist (a checklist tick is one value at
    /// a time; a test usually wants the end state).
    public func setSlotValues(_ values: [String], at index: Int) {
        let next = filter.settingValues(values, atSlot: index)
        guard next != filter else { return }
        onChange?(next)
    }

    public func clearSlotValues(at index: Int) {
        setSlotValues([], at: index)
    }

    /// The catalog values a slot's checklist is offering right now (empty = 「本库无此数据」).
    public func facetValuesForMenu(at index: Int) -> [String] {
        guard filter.slots.indices.contains(index) else { return [] }
        return facetValues(filter.slots[index].dimension)
    }
}
