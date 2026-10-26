import AppKit
import PhotonsCatalog

/// How the 15 dimensions and their canonical values read on screen.
///
/// The catalog speaks canonical strings (`"03"`, `"leica|sl3"`, `"1/800"`, `"1.2"`, `"1"`); the bar is
/// the only layer that knows how to say them out loud. Kept apart from `FilterBarView` so the same
/// words can be used by the chips, the popup titles and the tests without a second copy.
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

    /// The menu entry in the dimension picker — what the 15-item list prints.
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

    /// The popup's own title: 「全部星级」 when nothing is ticked, else 「星级 1★、2★」.
    static func slotTitle(_ slot: FilterSlot, cameraLabels: [String: String] = [:]) -> String {
        guard !slot.values.isEmpty else { return "全部\(title(slot.dimension))" }
        let joined = slot.values
            .map { value(slot.dimension, $0, cameraLabels: cameraLabels) }
            .joined(separator: "、")
        return "\(title(slot.dimension)) \(joined)"
    }
}

/// The grid's filter strip (026 v2): **one** small button that picks dimensions, then up to five slots.
///
/// ```
/// [ ⋯ ]  [全部星级]  [全部旗标]  [相机 LEICA SL3]  …
/// ```
///
/// * the button opens a 15-item check menu; ticking a dimension appends a slot **in click order**,
///   at most five. Unticking removes it and the later slots close the gap. 「全部不选」 empties them
///   all, so the next five clicks number 1…5 again. When five are ticked, the remaining ten are
///   **disabled** (greyed) — the contract allows "disable or ignore", and a grey row explains why
///   nothing happens where a silently dead click would not.
/// * each slot's right-hand control is a pull-down `NSPopUpButton` whose menu items carry checkmarks;
///   the button shows 「全部星级」 or 「星级 1★、2★」. Values inside one slot OR, slots AND.
/// * the chips below are the same conditions made removable; clicking one drops *one value* and the
///   slot stays (a slot is the dimension you are looking at, not a condition).
///
/// The bar owns **no** state: every control reads `filter` and writes back through `onChange`. That is
/// what keeps "切换照片时筛选不变" true without bookkeeping — the filter lives in the session.
public final class FilterBarView: NSView, NSMenuDelegate {

    public static let height: CGFloat = 28

    // Geometry, also read by the layout tests.
    static let leading: CGFloat = 10
    static let dimensionButtonWidth: CGFloat = 22
    static let slotGap: CGFloat = 4
    static let popupMinWidth: CGFloat = 34
    static let popupMaxWidth: CGFloat = 120
    /// Chips may claim at most this share of the bar. A slot's own title already spells out the
    /// values it holds, so when the bar is tight the **entry** wins over the duplicate feedback.
    static let chipBudgetFraction: CGFloat = 0.35

    public var onChange: ((CatalogFilter) -> Void)?
    public var onClearFacet: ((CatalogFilter.Facet) -> Void)?
    public var onRemoveSlotValue: ((Int, String) -> Void)?
    public var onClearAll: (() -> Void)?

    /// Where the slot menus get their values: the catalog, through the session. Asked once per
    /// dimension per `update`, and answered with 「本库无此数据」 (an empty list) when the dimension
    /// has nothing — never with an invented vocabulary.
    public var facetProvider: ((FilterDimension) -> [String])?
    public var cameraLabels: [String: String] = [:]

    private let dimensionButton = NSButton(title: "⋯", target: nil, action: nil)
    private var slotPopups: [NSPopUpButton] = []
    private let clearButton = NSButton(title: "清除全部", target: nil, action: nil)

    /// Chips in draw order. The models are known as soon as `update` runs (a chip exists the moment a
    /// value is ticked); the rects need a layout pass, which is what `chipRect` reports.
    private var chipModels: [CatalogFilter.Chip] = []
    private var chipRects: [NSRect] = []
    private var filter = CatalogFilter.none
    private var facetCache: [FilterDimension: [String]] = [:]
    /// True while the controls are being synced from the model, so a control's action cannot loop.
    private var isSyncing = false
    /// Menus are rebuilt from the model, and rebuilding a menu while AppKit is tracking it is a crash
    /// waiting to happen — a click that changes the filter re-enters `update` from inside the open
    /// menu. So the rebuild is deferred to `menuDidClose`.
    private var openMenuCount = 0
    private var needsRebuildAfterMenu = false

    public override var isFlipped: Bool { true }

    public init() {
        super.init(frame: .zero)
        wantsLayer = true

        dimensionButton.bezelStyle = .rounded
        dimensionButton.controlSize = .small
        dimensionButton.font = .systemFont(ofSize: 10.5, weight: .semibold)
        dimensionButton.target = self
        dimensionButton.action = #selector(dimensionButtonTapped)
        dimensionButton.toolTip = "选择筛选维度（最多 5 个）"
        addSubview(dimensionButton)

        for _ in 0..<CatalogFilter.slotCapacity {
            let popup = NSPopUpButton(frame: .zero, pullsDown: true)
            popup.controlSize = .small
            popup.font = .systemFont(ofSize: 10.5)
            popup.bezelStyle = .rounded
            popup.autoenablesItems = false
            popup.isHidden = true
            popup.target = self
            popup.action = #selector(slotPopupChanged(_:))
            popup.menu?.delegate = self
            slotPopups.append(popup)
            addSubview(popup)
        }

        clearButton.controlSize = .small
        clearButton.bezelStyle = .inline
        clearButton.font = .systemFont(ofSize: 10.5)
        clearButton.isBordered = false
        clearButton.target = self
        clearButton.action = #selector(clearAllTapped)
        clearButton.isHidden = true
        addSubview(clearButton)
    }

    public required init?(coder: NSCoder) { fatalError("no nibs in this app") }

    // MARK: model → bar

    public func update(filter: CatalogFilter, cameraKeys: [String]) {
        update(filter: filter, cameraKeys: cameraKeys, cameraLabels: [:])
    }

    /// `cameraKeys` is kept for the pre-026 call sites (`AssetGridController` passed it); the slot menu
    /// reads its own list through `facetProvider`, so the parameter now only documents the library's
    /// cameras for callers that do not supply labels.
    public func update(filter: CatalogFilter, cameraKeys: [String], cameraLabels: [String: String]) {
        isSyncing = true
        self.filter = filter
        self.cameraLabels = cameraLabels.isEmpty ? self.cameraLabels : cameraLabels
        facetCache = [:]
        chipModels = filter.chips(cameraLabels: self.cameraLabels)
        chipRects = []
        rebuildSlotPopups()
        isSyncing = false
        clearButton.isHidden = !filter.isActive
        needsLayout = true
        needsDisplay = true
    }

    private func rebuildSlotPopups() {
        guard openMenuCount == 0 else {
            needsRebuildAfterMenu = true
            return
        }
        for (index, popup) in slotPopups.enumerated() {
            guard filter.slots.indices.contains(index) else {
                popup.isHidden = true
                popup.menu?.removeAllItems()
                continue
            }
            let slot = filter.slots[index]
            popup.isHidden = false
            popup.menu?.removeAllItems()

            // Pull-down: item 0 is the button's title **and** the "clear this slot" row.
            let summary = NSMenuItem(title: FilterDisplay.slotTitle(slot, cameraLabels: cameraLabels),
                                     action: #selector(slotClearTapped(_:)), keyEquivalent: "")
            summary.target = self
            summary.tag = index
            summary.toolTip = "清空本槽（全部\(FilterDisplay.title(slot.dimension))）"
            popup.menu?.addItem(summary)
            popup.menu?.addItem(.separator())

            let values = facetValues(slot.dimension)
            if values.isEmpty {
                let empty = NSMenuItem(title: "本库无此数据", action: nil, keyEquivalent: "")
                empty.isEnabled = false
                popup.menu?.addItem(empty)
            }
            for value in values {
                let item = NSMenuItem(title: FilterDisplay.value(slot.dimension, value,
                                                                 cameraLabels: cameraLabels),
                                      action: #selector(slotValueToggled(_:)), keyEquivalent: "")
                item.target = self
                item.tag = index
                item.representedObject = value
                item.state = slot.values.contains(value) ? .on : .off
                popup.menu?.addItem(item)
            }
        }
    }

    private func facetValues(_ dimension: FilterDimension) -> [String] {
        if let cached = facetCache[dimension] { return cached }
        let values = facetProvider?(dimension) ?? []
        facetCache[dimension] = values
        return values
    }

    // MARK: controls → model

    @objc private func dimensionButtonTapped() {
        guard !isSyncing else { return }
        let menu = buildDimensionMenu()
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: dimensionButton.bounds.height + 2),
                   in: dimensionButton)
    }

    /// The 15-item check menu: slot numbers as prefixes, a tick per active slot, 「全部不选」 last.
    func buildDimensionMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        let full = filter.slots.count >= CatalogFilter.slotCapacity
        for dimension in FilterDimension.allCases {
            let slotIndex = filter.slots.firstIndex { $0.dimension == dimension }
            let prefix = slotIndex.map { "\($0 + 1)  " } ?? "    "
            let item = NSMenuItem(title: prefix + FilterDisplay.longTitle(dimension),
                                  action: #selector(dimensionItemTapped(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = dimension.rawValue
            item.state = slotIndex == nil ? .off : .on
            item.isEnabled = slotIndex != nil || !full
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let none = NSMenuItem(title: "全部不选", action: #selector(dimensionNoneTapped), keyEquivalent: "")
        none.target = self
        none.isEnabled = !filter.slots.isEmpty
        menu.addItem(none)
        return menu
    }

    @objc private func dimensionItemTapped(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let dimension = FilterDimension(rawValue: raw) else { return }
        chooseDimension(dimension)
    }

    @objc private func dimensionNoneTapped() {
        guard !filter.slots.isEmpty else { return }
        onChange?(filter.clearingSlots())
    }

    /// One dimension click — the menu item's action, and the seam the UI tests drive.
    public func chooseDimension(_ dimension: FilterDimension) {
        let next = filter.togglingDimension(dimension)
        guard next != filter else { return }
        onChange?(next)
    }

    @objc private func slotValueToggled(_ sender: NSMenuItem) {
        guard !isSyncing, let value = sender.representedObject as? String else { return }
        let next = filter.togglingValue(value, atSlot: sender.tag)
        guard next != filter else { return }
        onChange?(next)
    }

    @objc private func slotClearTapped(_ sender: NSMenuItem) {
        guard !isSyncing else { return }
        let next = filter.settingValues([], atSlot: sender.tag)
        guard next != filter else { return }
        onChange?(next)
    }

    /// A pull-down popup's own action: the menu items do the work, this only keeps AppKit from
    /// treating the click as a selection (the title must stay the summary).
    @objc private func slotPopupChanged(_ sender: NSPopUpButton) {
        sender.selectItem(at: 0)
    }

    @objc private func clearAllTapped() { onClearAll?() }

    // MARK: chips

    public var chipCount: Int { chipModels.count }

    public func chipText(_ index: Int) -> String? {
        chipModels.indices.contains(index) ? chipModels[index].text : nil
    }

    /// The legacy facet a chip belongs to — `.rating` for both a pre-026 `ratingAtLeast` chip and a
    /// 星级 slot chip, so an old assertion still reads the thing it meant.
    public func chipFacet(_ index: Int) -> CatalogFilter.Facet? {
        guard chipModels.indices.contains(index) else { return nil }
        switch chipModels[index].origin {
        case .facet(let facet): return facet
        case .slot: return CatalogFilter.Facet(rawValue: chipModels[index].dimension.rawValue)
        }
    }

    /// Chip frame in this view's coordinates, so a test can click it like a user would. `nil` until a
    /// layout pass has placed it (the bar is laid out by its container, never by itself).
    public func chipRect(_ index: Int) -> NSRect? {
        chipRects.indices.contains(index) ? chipRects[index] : nil
    }

    /// Clicking a chip: a legacy facet clears its field, a slot chip drops that one value.
    func clickChip(_ index: Int) {
        guard chipModels.indices.contains(index) else { return }
        switch chipModels[index].origin {
        case .facet(let facet):
            onClearFacet?(facet)
        case .slot(let slot):
            if let value = chipModels[index].value { onRemoveSlotValue?(slot, value) }
        }
    }

    private static let chipFont = NSFont.systemFont(ofSize: 10, weight: .medium)

    private static func chipWidth(_ text: String) -> CGFloat {
        let size = (text as NSString).size(withAttributes: [.font: chipFont])
        return ceil(size.width) + 26      // text + "×" + padding
    }

    private func rebuildChips(originX: CGFloat, budget: CGFloat) {
        let h: CGFloat = 18
        let y = (bounds.height - h) / 2
        var x = originX
        var rects: [NSRect] = []
        for chip in chipModels {
            let w = Self.chipWidth(chip.text)
            // A chip that would leave the bar is not drawn: the visible ones stay clickable and the
            // condition is still removable from its slot menu. (The alternative — pushing them off
            // the right edge — is exactly what this task forbids.)
            guard x + w <= originX + budget + 0.5 else { break }
            rects.append(NSRect(x: x, y: y, width: w, height: h))
            x += w + 6
        }
        chipRects = rects
    }

    // MARK: geometry

    public override func layout() {
        super.layout()
        let h = bounds.height
        let mid = max(0, (h - 22) / 2)

        var x = Self.leading
        dimensionButton.frame = NSRect(x: x, y: mid, width: Self.dimensionButtonWidth, height: 22)
        x += Self.dimensionButtonWidth + 6

        let clearWidth: CGFloat = filter.isActive ? 54 : 0
        let available = max(0, bounds.width - x - 8 - clearWidth)
        let chipTotal = chipModels.reduce(CGFloat(0)) { $0 + Self.chipWidth($1.text) + 6 }
        // Chips are paid for first (they are the result and must stay on screen); the slots get the
        // rest and the popup is what shrinks. A chip row may claim 35 % of the bar at most, and never
        // so much that fewer than two slots are left — a bar with no way to change the dimension is a
        // dead end, while a missing chip is only a missing shortcut.
        let slotFloor = 2 * (Self.dimensionButtonWidth + Self.slotGap + Self.popupMinWidth)
        let chipReserve = min(chipTotal, bounds.width * Self.chipBudgetFraction,
                              max(0, available - slotFloor))
        let usable = max(0, available - chipReserve)

        let slotCount = min(filter.slots.count, CatalogFilter.slotCapacity)
        var popupWidth = Self.popupMaxWidth
        var visible = slotCount
        if slotCount > 0 {
            popupWidth = min(Self.popupMaxWidth,
                             max(Self.popupMinWidth, usable / CGFloat(slotCount) - Self.slotGap))
            // Only when even a 34 pt popup does not fit is a whole slot dropped — 22 + 34 + gap is
            // the narrowest a slot can be and still be a button you can hit.
            while visible > 0 && CGFloat(visible) * (popupWidth + Self.slotGap) > usable + 0.5 {
                visible -= 1
                popupWidth = min(Self.popupMaxWidth,
                                 max(Self.popupMinWidth, usable / CGFloat(max(1, visible)) - Self.slotGap))
            }
        }

        for (index, popup) in slotPopups.enumerated() {
            guard index < visible, filter.slots.indices.contains(index) else {
                popup.isHidden = true
                popup.frame = .zero
                continue
            }
            popup.isHidden = false
            popup.frame = NSRect(x: x, y: mid, width: popupWidth, height: 22)
            x += popupWidth + Self.slotGap
        }
        if visible > 0 { x += 2 }

        let chipRoom = max(0, bounds.width - x - 8 - clearWidth - 6)
        rebuildChips(originX: x, budget: min(chipTotal, chipRoom))

        clearButton.isHidden = !filter.isActive
        if filter.isActive {
            let w = (clearButton.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 10.5)]).width + 8
            let afterChips = chipRects.last.map { $0.maxX + 10 } ?? (x + 4)
            clearButton.frame = NSRect(x: min(bounds.width - w - 12, afterChips),
                                       y: mid + 3, width: w, height: 16)
        } else {
            clearButton.frame = .zero
        }
    }

    public override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.withAlphaComponent(0.55).setFill()
        bounds.fill()
        NSColor.labelColor.withAlphaComponent(0.10).setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()

        for (index, chip) in chipModels.enumerated() {
            guard chipRects.indices.contains(index) else { break }
            let rect = chipRects[index]
            let path = NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9)
            NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
            path.fill()
            NSColor.controlAccentColor.withAlphaComponent(0.45).setStroke()
            path.lineWidth = 1
            path.stroke()

            let text = chip.text as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: Self.chipFont, .foregroundColor: NSColor.labelColor,
            ]
            let size = text.size(withAttributes: attrs)
            text.draw(at: NSPoint(x: rect.minX + 9, y: rect.midY - size.height / 2),
                      withAttributes: attrs)
            let cross = "×" as NSString
            let crossAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            let crossSize = cross.size(withAttributes: crossAttrs)
            cross.draw(at: NSPoint(x: rect.maxX - crossSize.width - 7,
                                   y: rect.midY - crossSize.height / 2),
                       withAttributes: crossAttrs)
        }
    }

    // MARK: chip clicking

    public override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let hit = chipRects.firstIndex(where: { $0.contains(point) }) {
            clickChip(hit)
            return
        }
        super.mouseDown(with: event)
    }

    // MARK: menu tracking

    public func menuWillOpen(_ menu: NSMenu) {
        openMenuCount += 1
    }

    public func menuDidClose(_ menu: NSMenu) {
        openMenuCount = max(0, openMenuCount - 1)
        guard openMenuCount == 0, needsRebuildAfterMenu else { return }
        needsRebuildAfterMenu = false
        rebuildSlotPopups()
        clearButton.isHidden = !filter.isActive
        needsLayout = true
        needsDisplay = true
    }

    // MARK: test seams (the UI tests drive the same actions a click does)

    /// The slots' dimensions, left to right.
    public var slotDimensions: [FilterDimension] { filter.slots.map(\.dimension) }

    public func slotValues(at index: Int) -> [String] {
        filter.slots.indices.contains(index) ? filter.slots[index].values : []
    }

    /// The popup's title text — what the user reads in the bar.
    public func slotTitle(at index: Int) -> String? {
        guard filter.slots.indices.contains(index) else { return nil }
        return FilterDisplay.slotTitle(filter.slots[index], cameraLabels: cameraLabels)
    }

    public func slotPopupFrame(at index: Int) -> NSRect? {
        guard slotPopups.indices.contains(index), !slotPopups[index].isHidden else { return nil }
        return slotPopups[index].frame
    }

    public var slotVisibleCount: Int {
        slotPopups.filter { !$0.isHidden }.count
    }

    public var dimensionButtonFrame: NSRect { dimensionButton.frame }

    /// 「全部不选」 — the menu's last row, and the seam the UI tests use for it.
    public func clearSlotDimensions() {
        guard !filter.slots.isEmpty else { return }
        onChange?(filter.clearingSlots())
    }

    /// The rows a slot's menu currently holds (summary, separator, values) — so a test can see
    /// 「本库无此数据」 instead of just an empty array.
    public func slotMenuTitles(at index: Int) -> [String] {
        guard slotPopups.indices.contains(index), let menu = slotPopups[index].menu else { return [] }
        return menu.items.filter { !$0.isSeparatorItem }.map(\.title)
    }

    /// Menu rows as the picker would draw them: `(title, checked, enabled)`.
    public var dimensionMenuRows: [(title: String, checked: Bool, enabled: Bool)] {
        buildDimensionMenu().items
            .filter { !$0.isSeparatorItem }
            .map { ($0.title, $0.state == .on, $0.isEnabled) }
    }

    /// Choose values for a slot without going through the menu (a menu's checkbox is one value at a
    /// time; a test usually wants the end state).
    public func setSlotValues(_ values: [String], at index: Int) {
        let next = filter.settingValues(values, atSlot: index)
        guard next != filter else { return }
        onChange?(next)
    }

    public func clearSlotValues(at index: Int) {
        setSlotValues([], at: index)
    }

    /// The catalog values a slot's menu is offering right now (empty = 「本库无此数据」).
    public func facetValuesForMenu(at index: Int) -> [String] {
        guard filter.slots.indices.contains(index) else { return [] }
        return facetValues(filter.slots[index].dimension)
    }
}
