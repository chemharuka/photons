import AppKit

// MARK: - 387 · 「降噪中」 的居中卡片 ／ 392 · 「HDR 合成」 的居中卡片
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
//
// 392 (2026-11-12) added a second card of exactly this shape —— 「HDR 合成 / 3 张 / 0:34」 —— and the
// user's rule for it was 「继续做」, i.e. **not a second implementation**: the size, the 8 pt clamp, the
// 分:秒 arithmetic and the drawing are all here, in `ProgressCardOverlay`, and a card supplies only
// its three strings. Two copies of that arithmetic is how 「the HDR box moved when the digits changed」
// happens three months from now.
class ProgressCardOverlay: NSView {

    // MARK: what is on screen

    /// `hidden` is the resting state: nothing drawn, nothing to read. `running` means the box is up.
    /// The decision is the **controller's**, not this view's, because only the controller knows which
    /// photo the single-photo view is showing (387) or whether a merge is in flight (392).
    enum State: Equatable {
        case hidden
        case running
    }

    /// One laid-down frame of the card. Read by the acceptance instead of pixels, because a
    /// screenshot cannot say 「the box did not change width when the digits did」 with a number.
    struct Laydown: Equatable {
        /// Always three entries, in the card's own order — `["降噪中", "1000×1000", "0:34"]` for 387,
        /// `["HDR 合成", "3 张", "0:34"]` for 392. A line the card cannot fill yet is `""`.
        var lines: [String]
        /// The **box'** centre in the overlay's own points (`bounds`' centre, after the clamp).
        var center: CGPoint
        /// The box itself, in the overlay's own points. Its `size` is always `boxSize` — that is ②.
        var bounds: CGRect
    }

    /// **The one size.** 180 × 74, for every string either card can ever hold.
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

    /// Never a hit target: a click on the middle of the picture still belongs to the canvas (⑥/⑦).
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // MARK: the lines (pure, so the acceptance is arithmetic and not a screenshot)

    /// The two type sizes. The title is **bigger than the two detail lines** (②), and the detail lines
    /// are monospaced-digit so a ticking clock does not shimmy sideways inside the fixed box.
    static let titleFont = NSFont.systemFont(ofSize: 15, weight: .semibold)
    static let detailFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    /// `分:秒` — minutes unpadded, seconds two digits, **no hours**: 3665 s is `61:05` (§2.4, 387 ⑪).
    /// Shared by both cards so 「HDR 的时间带小时了」 cannot be a one-file bug.
    static func elapsedText(_ seconds: Double) -> String {
        let total = seconds.isFinite ? max(0, Int(seconds)) : 0
        return "\(total / 60):" + String(format: "%02d", total % 60)
    }

    // MARK: the box' rect

    /// Centre the fixed box on `center`, then keep it inside `containerBounds.insetBy(8, 8)`.
    ///
    /// A photo smaller than the box (a 40 × 30 rect, 387 ⑤) is why the clamp exists at all: the box is
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

    // MARK: where the three lines land

    /// The three text rects inside `box`, in draw order: title, line 2, line 3.
    ///
    /// One function, called by `draw(_:)` **and** by the acceptance: ② asks whether the three lines are
    /// centred on the same x, and the only honest place to measure that is the rect the text is
    /// actually drawn into. Fixed y/height per slot — the box never re-flows for its content.
    static func textRects(in box: CGRect) -> [CGRect] {
        let slot = box.insetBy(dx: 8, dy: 0)
        let rows: [(y: CGFloat, height: CGFloat)] = [(14, 20), (37, 15), (54, 15)]
        return rows.map { row in
            CGRect(x: slot.minX, y: box.minY + row.y, width: slot.width, height: row.height)
        }
    }

    // MARK: drawing

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

        // Fixed slots inside the fixed box: title, then the two detail lines. An empty line draws
        // nothing — the card keeps its size either way (387 ⑩).
        let rects = Self.textRects(in: laydown.bounds)
        let fonts = [Self.titleFont, Self.detailFont, Self.detailFont]
        let colors: [NSColor] = [.labelColor, .secondaryLabelColor, .secondaryLabelColor]
        for (index, rect) in rects.enumerated() where index < laydown.lines.count {
            draw(line: laydown.lines[index], font: fonts[index], color: colors[index], in: rect)
        }
    }

    private func draw(line: String, font: NSFont, color: NSColor, in rect: CGRect) {
        guard !line.isEmpty else { return }
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: color, .paragraphStyle: style,
        ]
        (line as NSString).draw(in: rect, withAttributes: attributes)
    }
}

// MARK: - 387 · the denoise card's three strings

/// 「降噪中 / 宽×高 / 分:秒」. Everything else — size, clamp, clock format, drawing — is the base class.
final class DenoiseProgressOverlay: ProgressCardOverlay {

    /// `宽×高`, or `""` when either number is unknown — **never** `0×0`. `×` is U+00D7 (MULTIPLICATION
    /// SIGN), not the letter `x`: ③ checks the code point, because at 11 pt they are hard to tell apart
    /// on screen and only one of them is right.
    static func pixelText(width: Int?, height: Int?) -> String {
        guard let width, let height, width > 0, height > 0 else { return "" }
        return "\(width)×\(height)"
    }

    /// The three lines, in the user's order. One function so the order cannot drift between the
    /// drawing and the acceptance.
    static func lines(width: Int?, height: Int?, elapsed: Double) -> [String] {
        [title, pixelText(width: width, height: height), elapsedText(elapsed)]
    }

    /// The title line. Exposed because ① asserts 「不带省略号」 on the literal.
    static let title = "降噪中"
}
