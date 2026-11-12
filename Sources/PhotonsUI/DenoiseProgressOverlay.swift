import AppKit

// MARK: - 387 · 「降噪中」 的居中卡片
//
// The user's second-round spec (2026-11-12, 「第二轮修订」) is three lines and nothing else:
//
//     降噪中
//     1000×1000      ← the **pixels of the photo being denoised**, 宽×高, `×` is U+00D7
//     0:34           ← elapsed, 分:秒 (minutes never padded, seconds two digits, no hours)
//
// and the box is a **fixed size**. That last word is the whole ticket: an autolayout/intrinsic-size
// card grows a few points when the dimensions read `12345×67890` instead of `1×1`, and the user asked
// for a box that does not move. So the rect is `boxSize`, computed here, and the text is drawn into
// it — never the other way round. There is no `fittingSize`, no `sizeToFit`, no
// `intrinsicContentSize` anywhere in this file, and ②'s acceptance measures exactly that.
//
// Two more rules the user stated, both load-bearing:
//
//   · **no invented progress** — no tile count, no remaining-time estimate, no percentage, no bar.
//     Chunking belongs to `AnselDenoise` (its own wording: 「分块操作完全由AnselDenoise去操作」), and a
//     number this app made up would be a lie dressed as a progress report. ⑨ is the negative gate.
//   · **pixels and time only**. The pixel line is the photo's stored `width`/`height`; when they are
//     not known yet the line is **empty**, not `0×0` — and the card still has three lines (⑩).
//
// The view itself is the same contract as `HighlightOverlayView` / `CropToolOverlayView`: transparent,
// `hitTest → nil` (the canvas owns every click), pure `draw(_:)` — no `NSTextField` subviews, which is
// what keeps a 0.5 s tick from laying out anything.
final class DenoiseProgressOverlay: NSView {

    // MARK: what is on screen

    /// `hidden` is the resting state: nothing drawn, nothing to read. `running` means the box is up
    /// **for the photo on screen right now** — the decision is `LoupeController.refreshDenoiseHUD`'s,
    /// not this view's, because only the controller knows which photo the single-photo view is showing.
    enum State: Equatable {
        case hidden
        case running
    }

    /// One laid-down frame of the card. Read by the acceptance instead of pixels, because a
    /// screenshot cannot say 「the box did not change width when the digits did」 with a number.
    struct Laydown: Equatable {
        /// Always three entries, in this order: `["降噪中", "1000×1000", "0:34"]`. The second is `""`
        /// when the photo's dimensions are unknown.
        var lines: [String]
        /// The **box'** centre in the overlay's own points (`bounds`' centre, after the clamp): equal
        /// to the photo's centre whenever the photo is big enough to hold the box.
        var center: CGPoint
        /// The box itself, in the overlay's own points. Its `size` is always `boxSize` — that is ②.
        var bounds: CGRect
    }

    /// **The one size.** 180 × 74, for every string this card can ever hold.
    static let boxSize = CGSize(width: 180, height: 74)
    /// The card's corner radius (the user asked for a rounded card; 10 pt reads as one at this size).
    static let cornerRadius: CGFloat = 10
    /// How far the box is kept inside the canvas — 「不许画到窗口外」.
    static let edgeInset: CGFloat = 8

    var state: State = .hidden {
        didSet { if state != oldValue { needsDisplay = true } }
    }

    var lastLaydown: Laydown? {
        didSet { if lastLaydown != oldValue { needsDisplay = true } }
    }

    override var isOpaque: Bool { false }
    override var isFlipped: Bool { true }

    /// Never a hit target: a click on the middle of the picture still belongs to the canvas (⑥).
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // MARK: the three lines (pure, so ③ ⑨ ⑩ ⑪ are arithmetic and not a screenshot)

    /// `宽×高`, or `""` when either number is unknown — **never** `0×0`. `×` is U+00D7 (MULTIPLICATION
    /// SIGN), not the letter `x`: ③ checks the code point, because at 11 pt they are hard to tell apart
    /// on screen and only one of them is right.
    static func pixelText(width: Int?, height: Int?) -> String {
        guard let width, let height, width > 0, height > 0 else { return "" }
        return "\(width)×\(height)"
    }

    /// `分:秒` — minutes unpadded, seconds two digits, **no hours**: 3665 s is `61:05` (§2.4, ⑪).
    static func elapsedText(_ seconds: Double) -> String {
        let total = seconds.isFinite ? max(0, Int(seconds)) : 0
        return "\(total / 60):" + String(format: "%02d", total % 60)
    }

    /// The three lines, in the user's order. One function so the order cannot drift between the
    /// drawing and the acceptance.
    static func lines(width: Int?, height: Int?, elapsed: Double) -> [String] {
        ["降噪中", pixelText(width: width, height: height), elapsedText(elapsed)]
    }

    /// The title line. Exposed because ① asserts 「不带省略号」 on the literal.
    static let title = "降噪中"

    // MARK: the box' rect

    /// Centre the fixed box on `center`, then keep it inside `containerBounds.insetBy(8, 8)`.
    ///
    /// A photo smaller than the box (a 40 × 30 rect, ⑤) is why the clamp exists at all: the box is
    /// **not** shrunk to fit — it stays 180 × 74 and slides until it is legal. When the clamp bites,
    /// `center` is the box' own centre, so `bounds.midX/midY == center` always holds.
    static func laydown(lines: [String], center: CGPoint, containerBounds: CGRect) -> Laydown {
        let box = clamp(CGRect(x: center.x - boxSize.width / 2,
                               y: center.y - boxSize.height / 2,
                               width: boxSize.width, height: boxSize.height),
                        into: containerBounds.insetBy(dx: edgeInset, dy: edgeInset))
        return Laydown(lines: lines,
                       center: CGPoint(x: box.midX, y: box.midY),
                       bounds: box)
    }

    /// Slide (never resize) `box` inside `host`, right/bottom edge first so a box that is *larger*
    /// than the host still keeps its top-left corner on the canvas.
    static func clamp(_ box: CGRect, into host: CGRect) -> CGRect {
        guard host.width > 0, host.height > 0 else { return box }
        var out = box
        if out.maxX > host.maxX { out.origin.x = host.maxX - out.width }
        if out.minX < host.minX { out.origin.x = host.minX }
        if out.maxY > host.maxY { out.origin.y = host.maxY - out.height }
        if out.minY < host.minY { out.origin.y = host.minY }
        return out
    }

    // MARK: drawing

    /// The type the three lines are drawn with: one place, because ② changes the strings and must not
    /// change the box.
    static let titleFont = NSFont.systemFont(ofSize: 15, weight: .semibold)
    static let detailFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    override func draw(_ dirtyRect: NSRect) {
        guard state == .running, let laydown = lastLaydown,
              bounds.width > 1, bounds.height > 1, laydown.lines.count == 3 else { return }

        // Semantic colours only: this card is chrome, not a document fact, so it follows the
        // appearance instead of hard-coding an rgb (the wash in `HighlightWarning` has the opposite
        // requirement and says why).
        let card = NSBezierPath(roundedRect: laydown.bounds,
                                xRadius: Self.cornerRadius, yRadius: Self.cornerRadius)
        NSColor.controlBackgroundColor.withAlphaComponent(0.82).setFill()
        card.fill()
        NSColor.separatorColor.setStroke()
        card.lineWidth = 1
        card.stroke()

        // Fixed slots inside the fixed box: title, pixels, elapsed. The second line is empty when the
        // dimensions are unknown, which draws nothing — the card keeps its size either way.
        let slot = laydown.bounds.insetBy(dx: 8, dy: 0)
        draw(line: laydown.lines[0], font: Self.titleFont, color: .labelColor,
             y: laydown.bounds.minY + 14, height: 20, in: slot)
        draw(line: laydown.lines[1], font: Self.detailFont, color: .secondaryLabelColor,
             y: laydown.bounds.minY + 37, height: 15, in: slot)
        draw(line: laydown.lines[2], font: Self.detailFont, color: .secondaryLabelColor,
             y: laydown.bounds.minY + 54, height: 15, in: slot)
    }

    private func draw(line: String, font: NSFont, color: NSColor,
                      y: CGFloat, height: CGFloat, in slot: CGRect) {
        guard !line.isEmpty else { return }
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: color, .paragraphStyle: style,
        ]
        (line as NSString).draw(in: CGRect(x: slot.minX, y: y, width: slot.width, height: height),
                                withAttributes: attributes)
    }
}
