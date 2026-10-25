import AppKit

/// The filter strip above the grid: 星级 ≥ N / 旗标 / 色标 / 相机, plus one chip per active facet.
///
/// It owns no state — every control reads `CatalogSession.filter` and writes it back through
/// `onChange`, and clicking a chip asks for that one facet to be dropped. That is what keeps the
/// rule "切换照片时筛选不变" true without any bookkeeping: the filter lives in the session, and
/// nothing in the selection path writes it.
public final class FilterBarView: NSView {

    public static let height: CGFloat = 28

    public var onChange: ((CatalogFilter) -> Void)?
    public var onClearFacet: ((CatalogFilter.Facet) -> Void)?
    public var onClearAll: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "筛选")
    private let starsPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let flagPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let colorPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let cameraPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let clearButton = NSButton(title: "清除全部", target: nil, action: nil)

    /// Chips in facet order; `rect` is in this view's (flipped) coordinates.
    private var chips: [(facet: CatalogFilter.Facet, text: String, rect: NSRect)] = []
    private var filter = CatalogFilter.none
    private var cameraKeys: [String] = []
    /// True while the controls are being synced from the model, so `controlChanged` cannot loop.
    private var isSyncing = false

    public override var isFlipped: Bool { true }

    public init() {
        super.init(frame: .zero)
        wantsLayer = true

        titleLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        titleLabel.textColor = .tertiaryLabelColor

        for popup in [starsPopup, flagPopup, colorPopup, cameraPopup] {
            popup.controlSize = .small
            popup.font = .systemFont(ofSize: 10.5)
            popup.bezelStyle = .rounded
            popup.target = self
            popup.action = #selector(controlChanged)
            addSubview(popup)
        }
        starsPopup.addItems(withTitles: ["全部星级"] + (1...5).map { "≥\($0) 星" })
        flagPopup.addItems(withTitles: ["全部旗标"] + AssetFlag.allCases.map(\.displayName))
        colorPopup.addItems(withTitles: ["全部色标"] + ColorLabel.allCases.map(\.displayName))

        clearButton.controlSize = .small
        clearButton.bezelStyle = .inline
        clearButton.font = .systemFont(ofSize: 10.5)
        clearButton.isBordered = false
        clearButton.target = self
        clearButton.action = #selector(clearAllTapped)
        clearButton.isHidden = true

        addSubview(titleLabel)
        addSubview(clearButton)
    }

    public required init?(coder: NSCoder) { fatalError("no nibs in this app") }

    // MARK: model → bar

    public func update(filter: CatalogFilter, cameraKeys: [String]) {
        self.filter = filter
        isSyncing = true
        let camerasChanged = cameraKeys != self.cameraKeys
        self.cameraKeys = cameraKeys
        if camerasChanged {
            cameraPopup.removeAllItems()
            cameraPopup.addItems(withTitles: ["全部相机"] + cameraKeys.map(Self.cameraTitle))
            cameraPopup.controlSize = .small
            cameraPopup.font = .systemFont(ofSize: 10.5)
        }
        starsPopup.selectItem(at: filter.ratingAtLeast.map { min(5, max(1, $0)) } ?? 0)
        flagPopup.selectItem(at: filter.flag.flatMap { AssetFlag.normalized($0) }
            .flatMap { AssetFlag.allCases.firstIndex(of: $0) }.map { $0 + 1 } ?? 0)
        colorPopup.selectItem(at: filter.colorLabel.flatMap { ColorLabel.normalized($0) }
            .flatMap { ColorLabel.allCases.firstIndex(of: $0) }.map { $0 + 1 } ?? 0)
        cameraPopup.selectItem(at: filter.cameraKey.flatMap { cameraKeys.firstIndex(of: $0) }.map { $0 + 1 } ?? 0)
        isSyncing = false
        clearButton.isHidden = !filter.isActive
        needsLayout = true
        needsDisplay = true
    }

    /// "canon|eos r5" → "Canon EOS R5" is over-reach for a popup; a readable one-liner is enough.
    private static func cameraTitle(_ key: String) -> String {
        key.replacingOccurrences(of: "|", with: " ")
    }

    // MARK: controls → model

    @objc private func controlChanged() {
        guard !isSyncing else { return }
        let starsIndex = starsPopup.indexOfSelectedItem
        let flagIndex = flagPopup.indexOfSelectedItem
        let colorIndex = colorPopup.indexOfSelectedItem
        let cameraIndex = cameraPopup.indexOfSelectedItem
        var next = filter
        next.ratingAtLeast = starsIndex > 0 ? starsIndex : nil
        next.flag = flagIndex > 0 && AssetFlag.allCases.indices.contains(flagIndex - 1)
            ? AssetFlag.allCases[flagIndex - 1].rawValue : nil
        next.colorLabel = colorIndex > 0 && ColorLabel.allCases.indices.contains(colorIndex - 1)
            ? ColorLabel.allCases[colorIndex - 1].rawValue : nil
        next.cameraKey = cameraIndex > 0 && cameraKeys.indices.contains(cameraIndex - 1)
            ? cameraKeys[cameraIndex - 1] : nil
        guard next != filter else { return }
        onChange?(next)
    }

    @objc private func clearAllTapped() { onClearAll?() }

    // MARK: chips

    /// Number of active-facet chips — the smoke asserts it while a filter is on and after clearing.
    public var chipCount: Int { chips.count }

    public func chipText(_ index: Int) -> String? {
        chips.indices.contains(index) ? chips[index].text : nil
    }

    public func chipFacet(_ index: Int) -> CatalogFilter.Facet? {
        chips.indices.contains(index) ? chips[index].facet : nil
    }

    /// Chip frame in this view's coordinates, so a test can click it like a user would.
    public func chipRect(_ index: Int) -> NSRect? {
        chips.indices.contains(index) ? chips[index].rect : nil
    }

    private func rebuildChips() {
        let h: CGFloat = 18
        let y = (bounds.height - h) / 2
        var x = chipsOriginX()
        var out: [(facet: CatalogFilter.Facet, text: String, rect: NSRect)] = []
        for chip in filter.chips {
            let w = Self.chipWidth(chip.text)
            out.append((facet: chip.facet, text: chip.text,
                        rect: NSRect(x: x, y: y, width: w, height: h)))
            x += w + 6
        }
        chips = out
    }

    private static func chipWidth(_ text: String) -> CGFloat {
        let size = (text as NSString).size(withAttributes: [.font: chipFont])
        return ceil(size.width) + 26      // text + "×" + padding
    }

    private static let chipFont = NSFont.systemFont(ofSize: 10, weight: .medium)

    private var popupsWidth: CGFloat {
        [88, 78, 78, 116].reduce(0, +) + 3 * 8
    }

    private func chipsOriginX() -> CGFloat {
        let leading: CGFloat = 12 + 34 /* title */ + 8
        return leading + popupsWidth + 10
    }

    // MARK: geometry

    public override func layout() {
        super.layout()
        rebuildChips()
        let h = bounds.height
        let mid = max(0, (h - 22) / 2)
        var x: CGFloat = 12
        titleLabel.frame = NSRect(x: x, y: mid + 4, width: 34, height: 14)
        x += 34 + 8
        for (popup, width) in zip([starsPopup, flagPopup, colorPopup, cameraPopup], [88, 78, 78, 116] as [CGFloat]) {
            popup.frame = NSRect(x: x, y: mid, width: width, height: 22)
            x += width + 8
        }
        if let last = chips.last {
            clearButton.isHidden = !filter.isActive
            let w = (clearButton.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 10.5)]).width + 8
            clearButton.frame = NSRect(x: min(bounds.width - w - 12, last.rect.maxX + 10),
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

        for chip in chips {
            let path = NSBezierPath(roundedRect: chip.rect, xRadius: 9, yRadius: 9)
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
            text.draw(at: NSPoint(x: chip.rect.minX + 9, y: chip.rect.midY - size.height / 2),
                      withAttributes: attrs)
            let cross = "×" as NSString
            let crossAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            let crossSize = cross.size(withAttributes: crossAttrs)
            cross.draw(at: NSPoint(x: chip.rect.maxX - crossSize.width - 7,
                                   y: chip.rect.midY - crossSize.height / 2),
                       withAttributes: crossAttrs)
        }
    }

    // MARK: chip clicking

    public override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let hit = chips.first(where: { $0.rect.contains(point) }) {
            onClearFacet?(hit.facet)
            return
        }
        super.mouseDown(with: event)
    }
}
