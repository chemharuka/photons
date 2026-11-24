import AppKit
import PhotonsLocalization

/// The display readout: `HDR 显示器 · headroom 1.20× · 1:1`, and — while 「显示原图」 is on — a
/// second `修改前` line directly beneath it.
///
/// It sits *on* the canvas (top-left, over the matte) rather than in a status bar the window does
/// not have yet: the fact belongs to this canvas — it is the surface that is or is not extended-range.
final class LoupeStatusChip: NSView {
    /// One place for the two lines' type and the gap between them. The badge is a *row of the same
    /// readout*, not a second style, so both labels come from `makeLineLabel(_:)`.
    enum Metrics {
        static let fontSize: CGFloat = 10.5
        static let fontWeight: NSFont.Weight = .medium
        static let textColor = NSColor.white.withAlphaComponent(0.9)
        static let padding = CGSize(width: 7, height: 3)
        static let lineSpacing = WorkspaceLayout.statusChipLineSpacing
        static let edgeInset: CGFloat = 10
        static let cornerRadius: CGFloat = 5
    }

    let infoLabel = LoupeStatusChip.makeLineLabel("")
    let originalLabel = LoupeStatusChip.makeLineLabel(Loc.t("修改前"))

    /// 547 — whether the `修改前` line is up. Hidden, not blank: the text stays on the control so a
    /// test can tell "the badge is off" from "the badge exists and says nothing".
    var showsOriginal: Bool = false {
        didSet {
            guard showsOriginal != oldValue else { return }
            originalLabel.isHidden = !showsOriginal
            needsLayout = true
        }
    }

    var text: String {
        get { infoLabel.stringValue }
        set {
            guard infoLabel.stringValue != newValue else { return }
            infoLabel.stringValue = newValue
        }
    }

    var tooltip: String? {
        get { toolTip }
        set { toolTip = newValue }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        layer?.cornerRadius = Metrics.cornerRadius
        originalLabel.isHidden = true
        addSubview(infoLabel)
        addSubview(originalLabel)
    }

    required init?(coder: NSCoder) { fatalError("no nibs in this app") }

    /// The one factory both readout rows use, so font, size, colour and alignment cannot drift.
    static func makeLineLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .monospacedDigitSystemFont(ofSize: Metrics.fontSize, weight: Metrics.fontWeight)
        label.textColor = Metrics.textColor
        label.alignment = .natural
        label.drawsBackground = false
        label.isBordered = false
        label.isEditable = false
        label.isSelectable = false
        return label
    }

    /// Top-left, 10 pt inset, hugging its widest line. The info line is the first row; the badge is
    /// the second, separated by exactly `Metrics.lineSpacing` (the chip is flipped, so "below" is
    /// `+y`). Never participates in the canvas' layout: the viewport must not shrink because the
    /// readout grew a character or a row.
    func layout(in bounds: CGRect) {
        infoLabel.sizeToFit()
        originalLabel.sizeToFit()
        let padding = Metrics.padding
        let infoHeight = infoLabel.frame.height
        let badgeHeight = originalLabel.frame.height
        let height = padding.height * 2 + infoHeight
            + (showsOriginal ? Metrics.lineSpacing + badgeHeight : 0)
        let width = max(infoLabel.frame.width,
                        showsOriginal ? originalLabel.frame.width : 0) + padding.width * 2
        frame = CGRect(x: bounds.minX + Metrics.edgeInset,
                       y: bounds.maxY - height - Metrics.edgeInset,
                       width: width, height: height)
        infoLabel.frame = CGRect(x: padding.width, y: padding.height,
                                 width: infoLabel.frame.width, height: infoHeight)
        originalLabel.frame = CGRect(x: padding.width,
                                     y: infoLabel.frame.maxY + Metrics.lineSpacing,
                                     width: originalLabel.frame.width, height: badgeHeight)
    }

    /// Flipped so its two rows run downward from the chip's top edge — the same order a reader sees,
    /// and the order the frame assertion in 547 describes.
    override var isFlipped: Bool { true }

    /// The readout is a label, never a hit target: clicks belong to the canvas.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
