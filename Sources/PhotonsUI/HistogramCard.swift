import AppKit
import SwiftUI
import PhotonsCore

// MARK: - the histogram card
//
// Four series (R, G, B, luma) drawn from the bins `RenderGraph.measureHistogram` measured, the three
// clipping numbers under them (过白 / 削顶 / 削底), **one** readout row, and one click target: 过白
// toggles the highlight warning on the canvas.
//
// **The per-channel percentages row is gone** (2026-10-26): 「不再展示过白的 RGB 比例，把这个位置换成鼠标
// 指针位置处像素的 RGB 值」. **The brightness row is gone as well** (023, 2026-10-26): 「不需要亮度信息了，
// 只要 RGB 值，而且样式和鼠标悬停在直方图上的 RGB 像素个数指示保持一致」. So there is exactly **one** row
// under the clipping numbers — one slot, one height, one question at a time:
//
//   · pointer on the **picture** → `R 245 G 128 B 64`, that pixel's three channels of the **picture's own
//     light** (the measurement's scene-linear sample, not S4's clamped frame — 2026-10-27): an sRGB code
//     0–255 at or below white, and `+x.x` stops for a channel above it, painted in the clipping colour
//     (`ClippingMark`, `#FF00C7`) for that segment alone;
//   · pointer on the **plot**    → `R 1284 G 1291 B 1206`, that bin's R/G/B sample counts;
//   · anywhere else              → `R G B` **without numbers** — the letters are permanently on screen
//     (2026-10-27), only the values need a pointer. The same slot, the same height.
//
// **Both rows share one three-column grid** (2026-10-27). 过白 / 削顶 / 削底 no longer flow left to right:
// each label starts at the x of the channel letter below it (`channelColumnStarts`), so the columns are a
// function of the fonts and the card's width only — never of a percentage's width, a value's length or
// where the pointer is.
//
// Both contents are laid out by the same `paintGroups` in the same face and colour (`numberFont` +
// `HistogramCardReadability.readoutColor`), so the pixel reading and the counts indicator are the *same*
// indicator with different digits — 「样式…保持一致」 as an identity the tests compare, not as a promise.
// The percentages are still *measured* (`clipHighTextByChannel`) and still printed by the CLI and
// `--ui-smoke`'s identity check — they are simply not painted and not spoken.
//
// **The plot has two segments** (2026-10-26, split 50/50 on 2026-10-27 / 068): 0…1 on a linear code
// axis for the left **half**, then the **4-stop** exponential tail (`HistogramAxis`,
// `Histogram.maxStops`) for the right half. The split is a proportion, not a fixed point width, so
// every card width gets the same 50/50 — the owner's 「左侧 50% 是 sdr，右侧 50% 是 hdr」 — and the
// tail's stops are `plot.width / 8` apart (50 pt on a 400 pt card, 30.5 pt on the inspector's 244 pt).
// Everything right of the dashed orange tick is light this panel cannot show: the tick is the display
// ceiling (`log2(headroom)` stops above white) and it comes from the *measurement's* own headroom, not
// from whatever screen the window is on by the time the card redraws — so the plot and its ceiling
// always describe the same screen. On an SDR screen the tick sits exactly on the SDR/tail boundary,
// which is the honest picture: no headroom at all.
//
// Decisions worth writing down:
//
//   · **The numbers come from `Histogram`, never from a second measurement.** The card formats
//     `HistogramChannel.clippedHigh` / `clippedCeiling` / `clippedLow` — the same values the CLI
//     prints and the tests assert — so "what the card says" and "what Core measured" cannot drift,
//     and `--ui-smoke` checks the identity by reformatting the measurement.
//   · **The histogram is of the picture, not of the frame** (005, 2026-10-26). `LoupeController`
//     measures the whole photo once per edit (`RenderGraph.measureHistogram`: a whole-picture render
//     at thumbnail scale, counted before S4) and hands the payload to the session; a frame render no
//     longer measures anything, so panning and zooming cannot move a bin. That is why 「采样 N px」 is
//     the same number at fit, at 1:1 and at 400 %, and why the plot can show light above 1.0 on an
//     SDR panel.
//   · **A stale plot is the design.** The measurement is debounced ~120 ms behind an edit and no
//     gesture triggers one, so `histogram` is always "the last measurement of the document that is on
//     screen", and it never goes nil mid-gesture (which is why `LoupeController.recordMeasurements`
//     publishes only non-nil).
//   · **The region is the picture, always.** There is no ROI any more: the measurement renders the
//     whole picture at its own thumbnail scale, so a `fit` frame's matte bars cannot reach bin 0 and a
//     1:1 window cannot measure only the window.
//   · **The deleted caption line is now the pointer's reading** (010, 2026-10-26). The owner removed the
//     painted 「采样 N px · 直方图 256+256 档」 line; the space it left carries a hover readout instead
//     — the code (0–255) or the tail's stop (`+1.00 档 (2.0×)`, per "＋1 档 = 2×") on the left, and
//     that bin's R/G/B counts on the right, in the *same* 9.5 pt semibold digits as 过白/削顶. It is
//     driven by a tracking area over the plot only, and mouse-out clears it (nothing is painted).
//
// The card is AppKit rather than SwiftUI because it has to be *measurable*: the smoke reads the
// histogram it drew, the bin count of the path it built, the axis split and ceiling tick it laid
// out, the exact strings and rects of both readout rows, then clicks 过白 through `mouseDown` — none
// of which a SwiftUI `Canvas` exposes.

public final class HistogramCardView: NSView {

    /// What the card is showing. Set from the frame the loupe presented (`nil` before the first).
    public var histogram: Histogram? {
        didSet {
            guard histogram != oldValue else { return }
            // A new measurement moves the counts under the pointer, so the row follows it: the bin is
            // the same bin, its numbers are not.
            refreshReadoutRow()
            needsDisplay = true
            updateAccessibilityHelp()
        }
    }

    /// The canvas overlay state, so the 过白 number can read as on/off (it is the same toggle).
    public var showsHighlightWarning: Bool = false {
        didSet { if showsHighlightWarning != oldValue { needsDisplay = true } }
    }

    /// What a click on 过白 does. The card itself changes nothing — the session owns the flag.
    public var onToggleHighlightWarning: (() -> Void)?

    // MARK: what the smoke reads back

    /// Channels whose path was actually built in the last `draw` (4 when there is a histogram).
    public private(set) var lastDrawnSeries = 0
    /// Bins the last path was built from, **both segments** (256 + 256 = 512 today).
    public private(set) var lastDrawnBins = 0
    /// How many of those were tail bins (0 without a histogram).
    public private(set) var lastDrawnHDRBins = 0
    /// The axis the last `draw` laid out: the 30 pt-per-stop rule and the SDR/tail split are asserted
    /// from this, not from pixels.
    public private(set) var lastAxis: HistogramAxis?
    /// Where the display-ceiling tick was painted, and what it means in stops above white.
    public private(set) var lastCeilingMarkerX: CGFloat = .nan
    public private(set) var lastCeilingStops: Double = 0
    /// The clipping percentages exactly as painted, in the luma channel (what the numbers mean).
    public private(set) var clipHighText = "—"
    public private(set) var clipLowText = "—"
    public private(set) var clipCeilingText = "—"
    public private(set) var clipHighTextByChannel: [String] = ["—", "—", "—", "—"]
    /// Where 过白 was painted, in view coordinates — so a synthetic click can aim at it.
    public private(set) var clipHighHitRect: NSRect = .zero
    public private(set) var clipLowHitRect: NSRect = .zero
    /// The clipping row's three labels (过白 / 削顶 / 削底) and three percentages, as painted.
    ///
    /// These exist because the two text rows are laid out from **one** grid (2026-10-27): a label's
    /// `minX` and the channel letter under it are the same column start, and that is asserted off the
    /// paint rather than off the arithmetic that produced it.
    public private(set) var clipLabelRects: [NSRect] = []
    public private(set) var clipNumberRects: [NSRect] = []
    /// The three column starts (R, G, B) the last `draw` laid **both** rows out from.
    public private(set) var readoutColumnStarts: [CGFloat] = []

    // MARK: the card's one number font (2026-10-26)
    //
    // 过白 / 削顶 / 削底 and the hover readout are the *same* size and weight by the owner's request
    // ("lastNoteColor 的字体要更大，和过白/等保持一致"). One constant, used by both call sites, so
    // "the same" is an identity the tests can assert (`hoverNumberFont == clipNumberFont`) rather
    // than two literals that happen to agree today.
    /// The row's **size**, and the only place it is written down (2026-10-27).
    ///
    /// The coloured `R`/`G`/`B` letters used to be 8 pt bold beside 9.5 pt digits, and the owner saw it:
    /// 「彩色的 RGB 三个字母大小，调整大一些和数值的 px 一致」. Two independent literals is how they
    /// drifted, so the size is one constant and both faces are built from it — the digits semibold, the
    /// letters bold (a label, not a digit), same point size, same cap height.
    public static let readoutFontSize: CGFloat = 9.5
    public static let numberFont = NSFont.monospacedDigitSystemFont(ofSize: readoutFontSize,
                                                                  weight: .semibold)
    public static var hoverNumberFont: NSFont { numberFont }
    public static var clipNumberFont: NSFont { numberFont }

    // MARK: the one row at the bottom of the card (018 → 023, revised 2026-10-26)
    //
    // One row, two contents, one rule for each:
    //
    //   · **the pixel's channels** — `R 245 G 128 B 64`, the pixel under the pointer's three channels
    //     (SDR code 0–255, or `+x.x` stops for a channel above display white);
    //   · **the bin's counts** — `R 1284 G 1291 B 1206`, that bin's R/G/B sample counts.
    //
    // 023 deleted the second row (the pixel's brightness) and the `.image` state with it: 「不需要亮度信息
    // 了，只要 RGB 值」. The two remaining contents cannot be true at once (one pointer), so they share
    // **one slot** — `channelRowRect == readoutRowRect` — and the row therefore never jumps by a line.
    //
    // The *percentages* row the card used to paint here is gone too: 「不再展示过白的 RGB 比例，把这个位置换成
    // 鼠标指针位置处像素的 RGB 值」. `clipHighTextByChannel` is still measured (it is what the CLI and the
    // 过白 identity check read) but it is no longer painted and no longer speaks in accessibility.

    /// The bin the pointer is over the plot at, `nil` when it is not over the plot.
    public private(set) var hoverReading: HistogramHoverReading?
    /// The pixel the pointer is over the picture at, as published by the loupe (`PointerReadoutTarget`).
    public private(set) var pointerPixel: PointerPixel?
    /// What the one row is showing when the pointer is over the **plot** — `.histogram` — or `.idle`.
    ///
    /// 023 removed the `.image` case: the pixel's brightness is not shown any more (「不需要亮度信息了」), and
    /// the pixel's *channels* are the channel row's content, painted in this same slot from
    /// `pointerPixel`. So the readout state only ever describes the plot half of the row.
    public private(set) var readoutState: HistogramReadoutRow = .idle

    /// The one row's slot — **the same rect whether it paints the cursor's RGB, the bin's counts, or
    /// nothing at all**, and the same rect as `readoutRowRect` (one row, two contents).
    public private(set) var channelRowRect: NSRect = .zero
    /// The three values the channel row painted (`["245", "128", "+0.6"]`), `[]` when it is blank.
    public private(set) var channelRowValues: [String] = []
    /// The channel row as one string — `R 245 G 128 B 64`, or `""` when nothing is painted. No `%`
    /// can appear in it: that is the owner's 「不再展示过白的 RGB 比例」 as a string the tests read.
    public private(set) var channelRowText = ""
    /// How wide the channel row's paint really is (`0` when blank) — the layout fit is asserted from
    /// this rather than from a stored string width.
    public private(set) var channelRowWidth: CGFloat = 0

    /// The slot the row occupies — **the same rect in both states and when idle**, which is the owner's
    /// 「保留这行的高度不要乱动」 as a number the tests can compare with `accuracy: 0`. It is the *same*
    /// rect as `channelRowRect`: 023 left the card with one row, not two.
    public private(set) var readoutRowRect: NSRect = .zero
    /// What was actually painted inside the row by the **counts** half (`.zero` for `.idle`, and `.zero`
    /// when the row is painting the pixel's channels instead).
    public private(set) var readoutContentRect: NSRect = .zero

    // The three groups, as painted, for both contents of the row: the letters' rects (their `minX` is
    // what 「三个字母位置恒定」 means), the values' rects (left-aligned one space after the letter), and
    // the **colours the letters were painted with** — a readback of the paint, not of the constant.
    public private(set) var channelLetterRects: [NSRect] = []
    public private(set) var channelValueRects: [NSRect] = []
    public private(set) var channelLetterColors: [NSColor] = []
    public private(set) var readoutLetterRects: [NSRect] = []
    public private(set) var readoutValueRects: [NSRect] = []
    public private(set) var readoutLetterColors: [NSColor] = []

    /// The face and colour each half's **values** were painted with, read back from the paint.
    ///
    /// This is the pair 023 is about: 「样式和鼠标悬停在直方图上的 RGB 像素个数指示保持一致」. The test
    /// compares the two states' pairs to each other *and* to `numberFont` / `readoutColor(isDark:)`,
    /// so "the same" is an identity read off the paint rather than two literals that happen to agree.
    public private(set) var channelValueFont: NSFont = HistogramCardView.numberFont
    public private(set) var channelValueColor: NSColor = .labelColor
    /// The colours the channel row painted each **value** with, in R/G/B order — the paint's own
    /// readback, so "the over-white segment is the clipping colour and its neighbours are not" is
    /// asserted off the draw rather than off the constant (2026-10-27).
    public private(set) var channelValueColors: [NSColor] = []
    /// Which channels were above white when the row was painted (`pixel.overWhiteChannels`).
    public private(set) var channelOverWhite: [Bool] = []
    public private(set) var readoutValueFont: NSFont = HistogramCardView.numberFont
    public private(set) var readoutValueColor: NSColor = .labelColor
    /// The counts half's per-group value colours — always the neutral `readoutColor`: a count is a
    /// number of pixels, never light, so nothing there can be above white.
    public private(set) var readoutValueColors: [NSColor] = []

    /// The values the counts half painted, per group (`["1284", "1291", "1206"]`); `[]` when the row is
    /// painting the pixel's channels or nothing at all.
    public private(set) var readoutValueTexts: [String] = []
    /// How many `draw`s painted anything in the row from the **counts** half (`.idle` paints nothing:
    /// this does not move, and the pixel half is counted by its own rects, not here).
    public private(set) var readoutPaintCount = 0

    /// The one row's fixed height, from the face it is painted in — a font constant, never a function
    /// of the text, which is what makes `.idle` occupy the same height as a reading.
    public static let readoutRowHeight: CGFloat = {
        let font = HistogramCardView.numberFont
        let size = ("0" as NSString).size(withAttributes: [.font: font])
        return (size.height).rounded(.up)
    }()

    /// The same height under the channel row's old name. 023 collapsed the two rows into one, so there is
    /// one height; the alias stays because the pixel row's readback (`channelRowRect.height`) and the
    /// `--ui-smoke` legibility check are written against it.
    public static let channelRowHeight: CGFloat = readoutRowHeight

    /// The channel letters' face: **the same size as the values** (2026-10-27), bold so a letter still
    /// reads as a label rather than a digit. One size constant (`readoutFontSize`), two weights — the
    /// owner's 「字母…和数值的 px 一致」 is about size, and the tests compare the two faces' point size and
    /// cap height, not their weight.
    public static let channelLetterFont = NSFont.monospacedDigitSystemFont(ofSize: readoutFontSize,
                                                                         weight: .bold)

    // MARK: the readout grid — one set of columns for both text rows (2026-10-27)
    //
    // 过白 / 削顶 / 削底 used to **flow**: each label started 12 pt after the previous number's `maxX`,
    // so every label's x was a function of the string before it («12.3%» is wider than «0.0%», so 削顶
    // moved when 过白's share grew). The owner's ask:
    //
    // > 「过白 削顶 削底 去对齐 RGB」 / 「RGB 位置不动」 / 「列位置与百分比、数值宽度无关」
    //
    // So both text rows are now laid out from **one** three-column grid, and the grid is a function of
    // the fonts and of the widest string each column can hold — never of today's numbers:
    //
    //     colR = 0                 colG = colR + wR + gap        colB = colG + wG + gap
    //
    // A column is as wide as the **wider of its two rows**, so neither row can push the other:
    //
    //     row 1:  过白 + [3 pt] + [dot 11 pt] + 12.3%     → label slot + widest percentage
    //     row 2:  R + [1 space] + 245                     → letter + space + widest value
    //
    // The dot's 11 pt is reserved on every column whether or not the overlay paints it, so flicking the
    // highlight warning on moves no digit. `HistogramChannelRowTests` asserts the alignment off the
    // painted rects at four card widths, and that the letters' rects are byte-identical across three
    // different measurements.

    /// The clipping row's label face (9 pt medium). A constant because the column arithmetic has to
    /// measure it, and the row's labels are the widest thing in a column.
    public static let clipLabelFont = NSFont.systemFont(ofSize: 9, weight: .medium)

    /// The gap between two columns. It is compressed (never to less than 0) when a card is too narrow to
    /// hold the grid at this spacing, so a narrow inspector keeps the column *order* instead of
    /// overlapping two groups; at 244 pt — the shipped minimum — it stays 12.
    public static let channelColumnGap: CGFloat = 12

    /// The widest string `HistogramCardFormat.percent(_:)` can print. `<0.1%` and `99.9%` are both five
    /// full-width glyphs, `100%` is four, `—` is one: this is the worst case, not today's value.
    public static let widestPercentText = "<0.1%"

    /// The widest channel value the pixel row prints: a three-digit code (`255`) or `+x.x` stops
    /// (`+2.3`, four glyphs — `+` and `.` are full-width in this face).
    public static let widestChannelValueText = "+2.3"

    /// What a clipping label owns inside its column: the widest of the three labels, its 3 pt gap, and
    /// the 11 pt the highlight-warning dot occupies (2 pt gap + 5 pt dot). The *percentage* starts here,
    /// on every column, so a dash and a `100%` sit at the same x.
    public static let clipLabelSlot: CGFloat = {
        let widest = ["过白", "削顶", "削底"]
            .map { ($0 as NSString).size(withAttributes: [.font: clipLabelFont]).width }
            .max() ?? 0
        return widest + 3 + 11
    }()

    /// One width per column, in R/G/B order — the worst case of the two rows that share it. Pure: the
    /// fonts and two fixed strings, so no measurement of the document can change a column.
    public static let channelColumnWidths: [CGFloat] = {
        let space = (" " as NSString).size(withAttributes: [.font: numberFont]).width
        let value = (widestChannelValueText as NSString)
            .size(withAttributes: [.font: numberFont]).width
        let percent = (widestPercentText as NSString)
            .size(withAttributes: [.font: numberFont]).width
        return channelLetters.map { letter in
            let glyph = (letter as NSString).size(withAttributes: [.font: channelLetterFont]).width
            return max(glyph + space + value, clipLabelSlot + percent)
        }
    }()

    /// Where the three columns start on a card `width` wide — `colR` at the content's left edge, then one
    /// column and one gap each. **The only place either text row gets an x from.**
    public static func channelColumnStarts(in width: CGFloat) -> [CGFloat] {
        let widths = channelColumnWidths
        guard widths.count > 1 else { return [0] }
        let slack = width - widths.reduce(0, +)
        let gap = min(channelColumnGap, max(0, slack / CGFloat(widths.count - 1)))
        var x: CGFloat = 0
        return widths.map { columnWidth in
            defer { x += columnWidth + gap }
            return x
        }
    }

    /// Exactly the strings the **counts** half of the row painted. Empty when nothing is painted — that
    /// emptiness *is* "the row is idle", and it is also the state while the row shows the pixel's channels.
    public private(set) var hoverCountText = ""
    public private(set) var hoverCountRect: NSRect = .zero
    /// The union of the letters and the values: what the row occupies *with counts*. `.zero` when idle.
    public private(set) var hoverReadoutRect: NSRect = .zero
    /// How many `draw`s painted a reading — the countable half of "idle paints nothing".
    public private(set) var hoverPaintCount = 0
    /// The colour the reading was last painted with (contrast is recomputed from this, not stored). Both
    /// halves of the row use it: the counts and the pixel's channels are the same indicator (023).
    public private(set) var lastHoverColor: NSColor = .labelColor

    /// The row as one string from the counts half; `nil` while idle (and while the row shows the pixel's
    /// channels — those are read back as `channelRowText`).
    public var hoverRowText: String? { readoutState.text }
    /// Where that line was painted — `.zero` while idle.
    public var hoverRowRect: NSRect { readoutContentRect }

    /// Worst-case WCAG ratio of the readout colour on the card's own backdrop band.
    public var hoverContrast: Double {
        HistogramCardReadability.worstContrast(of: lastHoverColor, isDark: lastAppearanceIsDark)
    }

    // MARK: what the smoke reads back about the two *legibility* labels (2026-10-26)

    /// The percentages' colour, still resolved per appearance on every `draw`.
    ///
    /// 023 moved the pixel row's values to `readoutColor` (they have to match the counts indicator), so
    /// this neutral is no longer painted on the row; it stays because it is the colour whose WCAG ratio
    /// `HistogramLegibilityTests` and `--ui-smoke` measure — dropping the assignment would leave those
    /// checks measuring a stale value from the previous draw instead of this one.
    public private(set) var lastPercentColor: NSColor = .labelColor
    /// Which appearance those colours were resolved for (`effectiveAppearance` in `draw`).
    public private(set) var lastAppearanceIsDark = false

    /// Worst-case WCAG ratio of the channel values on the card's own backdrop.
    public var percentContrast: Double {
        HistogramCardReadability.worstContrast(of: lastPercentColor, isDark: lastAppearanceIsDark)
    }

    /// The card's own title is the inspector's (`card("直方图")`), so nothing is drawn twice: the
    /// plot starts at the top edge of this view.
    ///
    /// **Why these are static and why there is a `contentHeight`** (2026-10-27): the card used to pin
    /// `104` while it stacked **two** text rows under the plot (the pixel's brightness was the second).
    /// 023 merged them into one slot, and the freed line was given back as bottom inset — so the card
    /// kept 14 pt of nothing under its last row, which is what the owner saw (「直方图卡片底部空太多了…
    /// 可以窄一些」). The height is now *derived*: top inset + plot + the 5 pt gap + the clipping row +
    /// the one readout row, i.e. exactly where the ink stops, 90 pt. Nothing about the plot, the gap or
    /// either text row moved — only the slack under the last row is gone (`HistogramCardHeightTests`
    /// measures the gap from a real draw, so re-adding slack has to argue with a number).
    private static let plotInsetTop: CGFloat = 0
    private static let plotHeight: CGFloat = 58
    private static let clipRowHeight: CGFloat = 15
    /// The 5 pt between the plot's bottom edge and the clipping row (`drawClipRows`).
    private static let clipRowGap: CGFloat = 5

    /// The card's whole content: everything down to the bottom of the one readout row, and no more.
    /// This is the intrinsic height *and* the SwiftUI frame, so the two cannot disagree.
    public static let contentHeight: CGFloat = plotInsetTop + plotHeight + clipRowGap
        + clipRowHeight + readoutRowHeight

    public override var isFlipped: Bool { true }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.contentHeight)
    }

    public init() {
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityIdentifier("histogram-card")
        setAccessibilityLabel("直方图")
        setAccessibilityRole(.group)
        updateAccessibilityHelp()
    }

    /// VoiceOver still hears how the x axis is binned. The painted caption that used to carry this
    /// sentence was removed at the owner's request (2026-10-26) — it was "采样 N px · 直方图 256+N 档",
    /// and the owner does not want that line on screen — so the binning is now spoken, not painted.
    ///
    /// The **one** row is described; the per-channel **percentages** are deliberately not, because they
    /// are no longer on screen (「不再展示过白的 RGB 比例」) and a screen reader that announced them would be
    /// reading a line the eye cannot see. Neither is the pixel's brightness: 023 deleted it.
    private func updateAccessibilityHelp() {
        let bins = histogram?.binCount ?? 256
        let tail = histogram?.hdrBinCount ?? Histogram.hdrBinCount
        setAccessibilityHelp("直方图：R/G/B/亮度四组曲线；横轴 \(bins) 档 SDR 码值 + \(tail) 档高光尾。下面一行随鼠标变化：鼠标在画面上时是鼠标处像素的 R/G/B 三通道值（画面本身的光，不是屏幕渲染后的值：SDR 区为 0–255 码值，超白通道为 +x.x 档并画成削顶品红），鼠标在直方图上时是那一箱的 R/G/B 样本数，其他位置为空但行高不变。")
    }

    public required init?(coder: NSCoder) { fatalError("no nibs in this app") }

    // MARK: the toggle (one code path for a click and for the smoke)

    /// Same as clicking 过白: what the smoke calls to flip the warning without synthesising a click.
    public func toggleHighlightWarning() {
        showsHighlightWarning.toggle()
        onToggleHighlightWarning?()
    }

    public override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if clipHighHitRect.contains(point), event.clickCount == 1 {
            toggleHighlightWarning()
            return
        }
        super.mouseDown(with: event)
    }

    /// The pointer says "this is a control" over the number, and nothing anywhere else.
    public override func resetCursorRects() {
        if !clipHighHitRect.isEmpty { addCursorRect(clipHighHitRect, cursor: .pointingHand) }
    }

    // MARK: the pointer's reading (010)
    //
    // The readout is driven by a **tracking area over the plot only** (not the whole card, not the
    // clip rows), so "inside the plot" is the definition of "there is something to read" and leaving
    // it is what clears the line. `.inVisibleRect` is deliberately *not* used: it would make the
    // tracked rect the whole view and hovering the 过白 row would invent a reading for a bin nobody
    // pointed at. `updateTrackingAreas` instead rebuilds the rect from `bounds` on every call —
    // remove first, add second, always exactly one area — because SwiftUI re-lays the card out
    // whenever the inspector resizes, and stacking areas would deliver the same move N times.

    private var hoverTrackingArea: NSTrackingArea?

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
            self.hoverTrackingArea = nil
        }
        let plot = NSRect(x: 0, y: Self.plotInsetTop, width: bounds.width, height: Self.plotHeight)
        guard plot.width > 1, plot.height > 1 else { return }
        let area = NSTrackingArea(rect: plot,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    /// A tracking area with `.mouseMoved` is only delivered while the window accepts move events;
    /// nothing in this app depends on the flag being false, and the readout depends on it being true.
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
    }

    /// The plot rect the axis is laid out in *right now* (the same arithmetic `draw` uses), or `nil`
    /// when the card is too small to have one.
    private var liveAxis: HistogramAxis? {
        guard bounds.width > 80, bounds.height > 60 else { return nil }
        return HistogramAxis(plot: NSRect(x: 0, y: Self.plotInsetTop, width: bounds.width,
                                          height: Self.plotHeight))
    }

    public override func mouseMoved(with event: NSEvent) {
        updateHoverReadout(at: convert(event.locationInWindow, from: nil))
    }

    public override func mouseEntered(with event: NSEvent) {
        updateHoverReadout(at: convert(event.locationInWindow, from: nil))
    }

    /// Off the plot (or off the card, which `.activeInKeyWindow` reports the same way) → nothing.
    public override func mouseExited(with event: NSEvent) {
        clearHoverReadout()
    }

    /// Read the bin under `point` (view coordinates) and repaint. Public so the smoke can drive the
    /// readout without a live cursor — it is the same call `mouseMoved` makes.
    public func updateHoverReadout(at point: CGPoint) {
        guard let axis = liveAxis, axis.plot.contains(point) else {
            clearHoverReadout()
            return
        }
        let reading = axis.hoverReading(atX: point.x, sdrBins: histogram?.binCount ?? 256)
        guard reading != hoverReading else { return }
        hoverReading = reading
        refreshReadoutRow()
        needsDisplay = true
    }

    /// Drop the plot's reading: the row goes back to whatever else can fill it — the picture's pixel if
    /// the pointer is on the canvas, otherwise idle — and the readback rects go to `.zero` when it is
    /// idle (what the smoke counts as "cleared").
    public func clearHoverReadout() {
        guard hoverReading != nil else { return }
        hoverReading = nil
        refreshReadoutRow()
        needsDisplay = true
    }

    /// The loupe's pointer moved onto a pixel of the picture (`PointerReadoutTarget`).
    ///
    /// The whole pixel is kept, not a pre-formatted string: the row's *format* is the card's business
    /// (one place decides the digits, the group starts and the y). 023: the pixel's channels are the
    /// content the row paints while the pointer is on the picture — the pixel's brightness is not shown.
    public func showPointerReadout(_ pixel: PointerPixel) {
        guard pointerPixel != pixel else { return }
        pointerPixel = pixel
        refreshReadoutRow()
        needsDisplay = true
    }

    /// The pointer left the picture: idle (and the row keeps its height).
    public func clearPointerReadout() {
        guard pointerPixel != nil else { return }
        pointerPixel = nil
        refreshReadoutRow()
        needsDisplay = true
    }

    /// The one place that decides which state the **row's counts half** is in.
    ///
    /// 023: the pixel has no state here any more — its channels are painted by the channel half of the
    /// same row, straight from `pointerPixel`. So this is the plot's state and nothing else; the plot
    /// still wins over the picture if a caller ever sets both (one pointer, and "this bin" is the more
    /// specific statement).
    private func refreshReadoutRow() {
        if let reading = hoverReading {
            let counts = PointerPixel.counts(histogram, bin: reading.bin, isTail: reading.isTail)
            readoutState = .histogram(counts: counts ?? .zero)
        } else {
            readoutState = .idle
        }
    }

    // MARK: drawing

    public override func draw(_ dirtyRect: NSRect) {
        let bounds = self.bounds
        guard bounds.width > 80, bounds.height > 60 else { return }

        // The appearance resolves once, here: the row's two contents paint with colours derived from it,
        // and neither may read a stale value from the other's last draw.
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        lastAppearanceIsDark = dark
        lastPercentColor = HistogramCardReadability.percentColor(isDark: dark)
        let readoutColor = HistogramCardReadability.readoutColor(isDark: dark)
        lastHoverColor = readoutColor

        let plot = NSRect(x: 0, y: Self.plotInsetTop, width: bounds.width, height: Self.plotHeight)
        let axis = HistogramAxis(plot: plot)
        lastAxis = axis
        lastCeilingMarkerX = .nan
        lastCeilingStops = 0
        drawAxis(axis)

        // The 4-series plot. RGB are filled, luma is the outline over them: the additive stack is
        // how a histogram reads as "where are my colours", and the luma line is the one number a
        // levels adjustment is actually aiming at. Both segments are drawn as **one** path per
        // series, so the curve crosses the SDR/tail boundary without a seam.
        lastDrawnSeries = 0
        lastDrawnBins = 0
        lastDrawnHDRBins = 0
        if let histogram {
            let bins = histogram.binCount
            let series: [(channel: Histogram.Channel, color: NSColor)] = [
                (.red, NSColor(srgbRed: 0.95, green: 0.20, blue: 0.24, alpha: 0.55)),
                (.green, NSColor(srgbRed: 0.24, green: 0.80, blue: 0.36, alpha: 0.55)),
                (.blue, NSColor(srgbRed: 0.28, green: 0.45, blue: 1.00, alpha: 0.55)),
            ]
            for (channel, color) in series {
                let c = histogram[channel]
                let points = HistogramCardFormat.points(c, binCount: bins, axis: axis,
                                                        peak: HistogramCardFormat.scalePeak(c))
                guard points.count > 2 else { continue }
                let path = NSBezierPath()
                path.move(to: points[0])
                for p in points.dropFirst() { path.line(to: p) }
                path.close()
                color.setFill()
                path.fill()
                lastDrawnSeries += 1
                lastDrawnBins = max(lastDrawnBins, points.count - 2)
                lastDrawnHDRBins = max(lastDrawnHDRBins, c.hdrBins.count)
            }
            let luma = histogram.luma
            let lumaPoints = HistogramCardFormat.points(luma, binCount: bins, axis: axis,
                                                       peak: HistogramCardFormat.scalePeak(luma))
            if lumaPoints.count > 2 {
                let outline = NSBezierPath()
                outline.move(to: lumaPoints[0])
                for p in lumaPoints.dropFirst() { outline.line(to: p) }
                outline.lineWidth = 1.2
                NSColor.labelColor.withAlphaComponent(0.85).setStroke()
                outline.stroke()
                lastDrawnSeries += 1
                lastDrawnBins = max(lastDrawnBins, lumaPoints.count - 2)
                lastDrawnHDRBins = max(lastDrawnHDRBins, luma.hdrBins.count)
            }
            // The 0.999 / 0.001 thresholds as tick marks: they are what the numbers below mean.
            drawThresholdTicks(in: axis)
            // The stop grid's numbers and the ceiling tick go on top of the curves — they are the
            // axis, and an axis must stay readable over a filled plot.
            drawStopLabels(axis)
            drawCeilingTick(axis, histogram: histogram)
        } else {
            drawStopLabels(axis)
            drawText("还没有可测的帧", at: CGPoint(x: plot.minX + 6, y: plot.midY - 6),
                     font: .systemFont(ofSize: 9), color: .tertiaryLabelColor)
        }

        drawClipRows(below: plot, histogram: histogram, in: bounds)
        // One row, one slot (023). Both halves are told where it is, so neither can drift from the other:
        // the pixel's channels when the pointer is on the picture, the bin's counts when it is on the plot.
        let row = rowSlot(below: plot, in: bounds)
        channelRowRect = row
        readoutRowRect = row
        drawPixelRow(in: row, color: readoutColor)
        drawCountsRow(in: row, color: readoutColor)
        _ = dirtyRect
    }

    /// Where the card's one row sits: directly under the clipping numbers, a function of the card's own
    /// geometry only (never of the state), at the font's fixed height.
    ///
    /// 023 removed the brightness row that used to be under this one. That row's height is **gone**
    /// (2026-10-27): the card is `contentHeight` — plot + gap + clipping row + this row — so the slot's
    /// bottom edge *is* the card's bottom edge, and the empty line the second row used to occupy is no
    /// longer inside the card at all (「底部空太多了」). The plot, the 5 pt gap and the clipping row are
    /// untouched; only the slack under this row was removed. No state can move it, and there is no
    /// second slot left empty where the brightness used to be.
    private func rowSlot(below plot: NSRect, in bounds: NSRect) -> NSRect {
        NSRect(x: bounds.minX, y: plot.maxY + Self.clipRowGap + Self.clipRowHeight,
               width: bounds.width, height: Self.readoutRowHeight)
    }

    /// The two-segment surface: a flat SDR bed, a tinted tail, the quarter-tone guides inside the
    /// SDR part only, and the display-white boundary between them.
    private func drawAxis(_ axis: HistogramAxis) {
        let plot = axis.plot
        NSColor.labelColor.withAlphaComponent(0.06).setFill()
        NSBezierPath(roundedRect: plot, xRadius: 4, yRadius: 4).fill()

        // The tail is a different kind of axis (exponential, and mostly outside the panel), so it is
        // drawn as a different surface — clipped to the card's own rounded rect so it does not draw
        // square corners over the bed.
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: plot, xRadius: 4, yRadius: 4).addClip()
        NSColor.systemOrange.withAlphaComponent(0.055).setFill()
        NSRect(x: axis.sdrMaxX, y: plot.minY, width: axis.hdrWidth, height: plot.height).fill()
        NSGraphicsContext.restoreGraphicsState()

        // Quarter-tone guides, as in every raw editor — inside the code segment, where they mean
        // "a quarter of the way from black to white".
        NSColor.labelColor.withAlphaComponent(0.08).setStroke()
        for i in 1..<4 {
            let x = plot.minX + axis.sdrWidth * CGFloat(i) / 4
            let line = NSBezierPath()
            line.move(to: CGPoint(x: x, y: plot.minY))
            line.line(to: CGPoint(x: x, y: plot.maxY))
            line.lineWidth = 1
            line.stroke()
        }

        // Display white: the boundary the two scales meet at.
        NSColor.labelColor.withAlphaComponent(0.30).setStroke()
        let split = NSBezierPath()
        split.move(to: CGPoint(x: axis.sdrMaxX, y: plot.minY))
        split.line(to: CGPoint(x: axis.sdrMaxX, y: plot.maxY))
        split.lineWidth = 1
        split.stroke()

        // One line per stop of the tail.
        NSColor.labelColor.withAlphaComponent(0.07).setStroke()
        for stop in 1..<axis.stops {
            let x = axis.x(stopsAboveWhite: Double(stop))
            let line = NSBezierPath()
            line.move(to: CGPoint(x: x, y: plot.minY))
            line.line(to: CGPoint(x: x, y: plot.maxY))
            line.lineWidth = 1
            line.stroke()
        }
    }

    /// `+1 … +4` along the top of the tail: what the 30 pt steps mean. Skipped when the card is too
    /// narrow for the numbers to be legible (they would collide with each other).
    private func drawStopLabels(_ axis: HistogramAxis) {
        guard axis.stopWidth >= 16 else { return }
        let font = NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font,
                                                         .foregroundColor: NSColor.secondaryLabelColor]
        for stop in 1...axis.stops {
            let text = "+\(stop)"
            let size = (text as NSString).size(withAttributes: attributes)
            let centre = axis.x(stopsAboveWhite: Double(stop))
            let x = min(max(centre - size.width / 2, axis.plot.minX), axis.plot.maxX - size.width - 1)
            (text as NSString).draw(at: CGPoint(x: x, y: axis.plot.minY + 1), withAttributes: attributes)
        }
    }

    /// The display ceiling: `log2(headroom)` stops above white, dashed, with the headroom spelled out.
    ///
    /// This is what the extra range is *for* — a picture that ends left of the tick is fully visible,
    /// one that runs past it is losing detail to the panel. On an SDR screen the tick lands on the
    /// SDR/tail boundary, which is the whole truth about that screen.
    private func drawCeilingTick(_ axis: HistogramAxis, histogram: Histogram) {
        let headroom = max(histogram.headroom, 1)
        let stops = log2(headroom)
        let x = axis.x(ceiling: headroom)
        lastCeilingMarkerX = x
        lastCeilingStops = stops

        let path = NSBezierPath()
        path.move(to: CGPoint(x: x, y: axis.plot.minY))
        path.line(to: CGPoint(x: x, y: axis.plot.maxY))
        path.lineWidth = 1
        path.setLineDash([3, 2], count: 2, phase: 0)
        NSColor.systemOrange.withAlphaComponent(0.9).setStroke()
        path.stroke()

        let text = String(format: "屏 %.2f×", headroom)
        let font = NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font,
                                                         .foregroundColor: NSColor.systemOrange]
        let size = (text as NSString).size(withAttributes: attributes)
        var labelX = x + 3
        if labelX + size.width > axis.plot.maxX - 1 { labelX = axis.plot.maxX - size.width - 1 }
        if labelX < axis.plot.minX + 1 { labelX = axis.plot.minX + 1 }
        let labelY = axis.plot.maxY - size.height - 1
        // A chip behind the number: the tick is drawn over the distribution, and an orange 8 pt label
        // on top of a filled curve is unreadable exactly where it matters (a spiky highlight).
        NSColor.labelColor.withAlphaComponent(0.14).setFill()
        NSBezierPath(roundedRect: NSRect(x: labelX - 1.5, y: labelY - 0.5,
                                        width: size.width + 3, height: size.height + 1),
                     xRadius: 2, yRadius: 2).fill()
        (text as NSString).draw(at: CGPoint(x: labelX, y: labelY), withAttributes: attributes)
    }

    /// Marks the two clipping thresholds on the x axis: `0.999` is one 8-bit code below white, so
    /// the tick sits at the very edge — drawn anyway, because "why is 1 % clipped" has to be visible.
    private func drawThresholdTicks(in axis: HistogramAxis) {
        let plot = axis.plot
        let highX = plot.minX + CGFloat(Histogram.clipHighThreshold) * axis.sdrWidth
        let lowX = plot.minX + CGFloat(Histogram.clipLowThreshold) * axis.sdrWidth
        NSColor.systemOrange.withAlphaComponent(0.7).setStroke()
        for x in [lowX, highX] {
            let line = NSBezierPath()
            line.move(to: CGPoint(x: min(max(x, plot.minX), plot.maxX), y: plot.minY))
            line.line(to: CGPoint(x: min(max(x, plot.minX), plot.maxX), y: plot.minY + 6))
            line.lineWidth = 1
            line.stroke()
        }
    }

    /// 过白 / 削顶 / 削底 plus the per-channel breakdown.
    ///
    /// 过白 (>SDR white) doubles as the highlight-warning switch, and it says so (an orange dot when
    /// the overlay is on). 削顶 is the *other* number now that the plot has a tail: it counts pixels
    /// at or above the ceiling the measurement was taken for, i.e. the detail *this* screen would
    /// throw away (with `headroom = 1` that is light above white, so an SDR screen sees the familiar
    /// pair of numbers). The bins themselves do not depend on the panel — that is the whole point of
    /// measuring before S4 — so 削顶 is the one number that moves when the display does.
    private func drawClipRows(below plot: NSRect, histogram: Histogram?, in bounds: NSRect) {
        let y = plot.maxY + 5
        let labelFont = Self.clipLabelFont
        let numberFont = Self.numberFont
        // The grid both text rows are laid out from (2026-10-27) — read back, so a test can compare the
        // labels' `minX`s with the channel letters' without repeating the arithmetic.
        let starts = Self.channelColumnStarts(in: bounds.width)
        readoutColumnStarts = starts

        clipHighText = HistogramCardFormat.clipHigh(histogram, .luma)
        clipCeilingText = HistogramCardFormat.clipCeiling(histogram, .luma)
        clipLowText = HistogramCardFormat.clipLow(histogram, .luma)
        clipHighTextByChannel = [Histogram.Channel.red, .green, .blue, .luma].map {
            HistogramCardFormat.clipHigh(histogram, $0)
        }

        // **Aligned, not flowed.** 过白 starts in column R, 削顶 in column G, 削底 in column B — the same
        // three x's the `R`/`G`/`B` letters below sit on, so the two rows read as one table and the
        // numbers' widths cannot push anything sideways. Each percentage starts at
        // `columnStart + clipLabelSlot`, a fixed slot, so a `—` and a `100%` land on the same pixel.
        let highLabel = drawText("过白", at: CGPoint(x: starts[0], y: y), font: labelFont,
                                 color: .secondaryLabelColor)
        if showsHighlightWarning {
            NSColor.systemOrange.setFill()
            NSBezierPath(ovalIn: NSRect(x: highLabel.maxX + 2, y: y + 2, width: 5, height: 5)).fill()
        }
        let highNumber = drawText(clipHighText, at: CGPoint(x: starts[0] + Self.clipLabelSlot, y: y),
                                  font: numberFont,
                                  color: showsHighlightWarning ? .systemOrange : .labelColor)
        // The hit area is padded: a 9.5 pt number is a mean target, and a 14 pt box is not.
        clipHighHitRect = NSRect(x: highLabel.minX, y: y - 2,
                                 width: highNumber.maxX - highLabel.minX, height: 14)

        let ceilLabel = drawText("削顶", at: CGPoint(x: starts[1], y: y),
                                 font: labelFont, color: .secondaryLabelColor)
        let ceilNumber = drawText(clipCeilingText,
                                  at: CGPoint(x: starts[1] + Self.clipLabelSlot, y: y),
                                  font: numberFont,
                                  color: clipCeilingText == "0.0%" ? .labelColor : .systemRed)

        let lowLabel = drawText("削底", at: CGPoint(x: starts[2], y: y),
                                font: labelFont, color: .secondaryLabelColor)
        let lowNumber = drawText(clipLowText, at: CGPoint(x: starts[2] + Self.clipLabelSlot, y: y),
                                 font: numberFont, color: .labelColor)
        clipLowHitRect = NSRect(x: lowLabel.minX, y: y - 2,
                                width: lowNumber.maxX - lowLabel.minX, height: 14)

        clipLabelRects = [highLabel, ceilLabel, lowLabel]
        clipNumberRects = [highNumber, ceilNumber, lowNumber]

        // **The percentages are not painted.** The per-channel 过白 shares used to live on the row
        // below this one; the owner replaced that row with the pixel under the pointer
        // (「不再展示过白的 RGB 比例，把这个位置换成鼠标指针位置处像素的 RGB 值」), so
        // `clipHighTextByChannel` stops here: it is still measured (the CLI and the 过白 identity check
        // read it) and is deliberately *not* drawn and *not* spoken.
    }

    // MARK: the row's pixel half — the pixel under the pointer (2026-10-26, revised by 023)

    /// `R 245 G 128 B 64` — the three channels of the pixel the pointer is on.
    ///
    /// Four rules, all of them the owner's:
    ///
    ///   · **the three letters never go away** (2026-10-27): 「RGB 这三个字母一直保留，鼠标移开了只是不展示
    ///     像素/亮度，还保留 RGB」. They are painted in their channel colours at the grid's columns on every
    ///     draw, pointer or not, so the row is never a blank line and the clipping row above it always has
    ///     something to line up with;
    ///   · **the values need a pixel**: with none under the pointer the numbers are dropped (no `—`), and
    ///     the slot keeps its height;
    ///   · **blank while the pointer is on the plot**, because a hover points at a *bin*, not at a pixel —
    ///     the counts half of the same row answers there, and it paints the letters itself (one half
    ///     paints the row, never both: two identical draws would composite the glyph edges twice);
    ///   · each channel is a code (`0…255`) or, above display white, `+x.x` stops — so one row can mix
    ///     (`R 255 G +0.8 B 120`), which is what a channel-clipped highlight actually looks like.
    ///
    /// 023 also pinned the *style*: 「样式和鼠标悬停在直方图上的 RGB 像素个数指示保持一致」, so the values are
    /// painted in `Self.numberFont` + the counts indicator's `readoutColor` — the same face and colour
    /// `paintCounts` uses. Only the letters keep their channel colours.
    private func drawPixelRow(in row: NSRect, color: NSColor) {
        channelRowText = ""
        channelRowValues = []
        channelRowWidth = 0
        channelLetterRects = []
        channelValueRects = []
        channelLetterColors = []
        channelValueColors = []
        channelOverWhite = []

        // The counts half owns the slot while the pointer is on the plot, letters included.
        guard hoverReading == nil else { return }

        guard let pixel = pointerPixel else {
            // **Letters, no numbers.** The row's left half stays on screen (`R G B`, each in its channel
            // colour, at the grid's three columns); only the values are gone.
            channelLetterRects = paintChannelLetters(atY: row.minY)
            channelLetterColors = Array(Self.channelNameColors.prefix(Self.channelLetters.count))
            return
        }

        let values = pixel.channelTexts
        // **Per channel, not per pixel** (2026-10-27): only the segment whose channel the picture holds
        // above white gets the clipping ink — `R 255 G +2.3 B 8` paints one magenta number, and the
        // letters keep their channel colours. A code is never over white, so nothing else can be
        // recoloured by accident, and the layout does not move (same font, same strings, same x's).
        let inks = pixel.channels.map { $0.isOverWhite ? Self.overWhiteColor : color }
        let painted = paintGroups(values, atY: row.minY,
                                  letterFont: Self.channelLetterFont,
                                  letterColors: Self.channelNameColors,
                                  valueFont: Self.numberFont,
                                  valueColor: color,
                                  valueColors: inks)
        channelRowValues = values
        channelRowText = HistogramCardFormat.grouped(values)
        channelLetterRects = painted.letters
        channelValueRects = painted.values
        channelLetterColors = painted.colors
        channelValueColors = painted.valueColors
        channelOverWhite = pixel.overWhiteChannels
        channelValueFont = Self.numberFont
        channelValueColor = color
        if let last = painted.values.last { channelRowWidth = last.maxX - bounds.minX }
    }

    /// The three channel letters on the grid's columns — the row's constant half (2026-10-27).
    ///
    /// Same face, same colours, same x as `paintGroups` gives them when there *are* values: that is what
    /// makes a letter's frame identical whether or not a pixel is under the pointer.
    private func paintChannelLetters(atY y: CGFloat) -> [NSRect] {
        let starts = Self.channelColumnStarts(in: bounds.width)
        guard !starts.isEmpty else { return [] }
        return Self.channelLetters.enumerated().map { index, letter in
            drawText(letter, at: CGPoint(x: starts[index % starts.count], y: y),
                     font: Self.channelLetterFont,
                     color: Self.channelNameColors[index % Self.channelNameColors.count])
        }
    }

    /// The ink the over-white segments are painted with — **the clipping colour, one constant**.
    ///
    /// `#FF00C7`, the same magenta the canvas wash paints (see `ClippingMark`): the digit and the wash
    /// mark the same fact (light this panel cannot show), so they are the same ink rather than two reds
    /// that nearly match. Deliberately not `NSColor.systemRed` — a semantic system colour follows the
    /// appearance, and this one has to be the wash's colour in both.
    public static var overWhiteColor: NSColor { ClippingMark.color }

    /// The channel letters, in row order. One constant, shared with the counts row and the plot's own
    /// legend: `R` is red in both rows because it is red in the curves.
    static let channelLetters = HistogramCardFormat.channelLetters

    /// The three letters' colours: the same three the R/G/B curves are tinted with (`series` in `draw`),
    /// so a red `R` next to a red curve. Public because the tests compare the colour that was *painted*
    /// against this constant rather than re-typing the literals.
    public static let channelNameColors: [NSColor] = [
        NSColor(srgbRed: 0.95, green: 0.25, blue: 0.28, alpha: 1),
        NSColor(srgbRed: 0.22, green: 0.72, blue: 0.34, alpha: 1),
        NSColor(srgbRed: 0.30, green: 0.48, blue: 0.98, alpha: 1),
    ]

    /// What one row of three groups painted.
    private struct PaintedGroups {
        var letters: [NSRect] = []
        var values: [NSRect] = []
        var colors: [NSColor] = []
        /// One colour per **value**, in group order — `valueColor` unless the caller passed a per-group
        /// ink (`valueColors`), which is how the over-white segments get the clipping colour and nothing
        /// else does.
        var valueColors: [NSColor] = []
    }

    /// One row of `letter value` groups, laid out the owner's way (2026-10-26, second pass):
    /// 「RGB 三个字母要带颜色，数字要靠近字母，例如 `R 2      G 40      B 1023`」.
    ///
    ///   · **the letters are coloured** (`letterColors`: `R` red, `G` green, `B` blue), in both rows;
    ///   · each group's letter starts at the **grid's** column for it (`channelColumnStarts`) — not at a
    ///     third of the row. The grid is what the clipping row above aligns to, so the letters' x is a
    ///     function of the fonts and the card's width only: `R`, `G` and `B` sit at the same three x for
    ///     every value, every count and every measurement (2026-10-27);
    ///   · the value is **one space** after its letter and left-aligned there — the number hugs the
    ///     letter instead of floating at a field's right edge (「数字要靠近字母」);
    ///   · a value wider than its column **runs past the column's edge**: nothing is truncated and the
    ///     font never shrinks. A count or a code that outgrows its column is allowed to reach into the
    ///     next one (this is what replaced the five-character right-aligned field).
    private func paintGroups(_ values: [String], atY y: CGFloat,
                             letterFont: NSFont, letterColors: [NSColor],
                             valueFont: NSFont, valueColor: NSColor,
                             valueColors: [NSColor]? = nil) -> PaintedGroups {
        guard !values.isEmpty else { return PaintedGroups() }
        let starts = Self.channelColumnStarts(in: bounds.width)
        guard !starts.isEmpty else { return PaintedGroups() }
        let spaceWidth = (" " as NSString).size(withAttributes: [.font: valueFont]).width
        var painted = PaintedGroups()
        for (index, text) in values.enumerated() {
            let color = letterColors[index % letterColors.count]
            // The value's ink: the caller's per-group colour when it named one, else the row's. Colour
            // is the only thing this can change — the string, the font and the x's are the same either
            // way, which is what keeps a magenta `+2.3` from moving its neighbours.
            let ink = (valueColors?.count == values.count) ? valueColors![index] : valueColor
            let letterRect = drawText(Self.channelLetters[index % Self.channelLetters.count],
                                      at: CGPoint(x: starts[index % starts.count], y: y),
                                      font: letterFont, color: color)
            let valueRect = drawText(text, at: CGPoint(x: letterRect.maxX + spaceWidth, y: y),
                                     font: valueFont, color: ink)
            painted.letters.append(letterRect)
            painted.values.append(valueRect)
            painted.colors.append(color)
            painted.valueColors.append(ink)
        }
        return painted
    }

    // MARK: the row's counts half (018 → 023: one slot, two contents, one height)
    //
    // This is the space the owner deleted as a grey caption line (「采样 N px · 直方图 256+256 档」), and it is now
    // the pointer's reading — one line, and a height that is the *same* number in every state
    // (「保留这行的高度不要乱动」):
    //
    //     .histogram((r, g, b))   the pointer is on the plot    → that bin's counts, nothing else
    //     .idle                   anywhere else                 → nothing painted, same height
    //
    // 023 deleted the third state (`.image`, the pixel's brightness, one bare number at the row's left
    // edge): 「不需要亮度信息了，只要 RGB 值」. The pixel is still read — its *channels* are the other half
    // of this same row (`drawPixelRow`), in the same slot.
    //
    // The counts are the same three groups as the pixel half (`paintGroups`): coloured letters **at the
    // grid's three columns** (the same x as the clipping row's 过白/削顶/削底), one space between a letter
    // and its count, no truncation. The face is
    // `Self.numberFont` — the same 9.5 pt semibold monospaced digits as 过白/削顶/削底, by the owner's
    // request; the colour is an opaque `HistogramCardReadability.readoutColor`, which is what makes
    // ≥ 4.5 : 1 a measured fact rather than a hope. **The pixel half paints in exactly this pair** — that
    // is 023's 「样式…保持一致」.

    private func drawCountsRow(in row: NSRect, color: NSColor) {
        hoverCountText = ""
        hoverCountRect = .zero
        hoverReadoutRect = .zero
        readoutContentRect = .zero
        readoutLetterRects = []
        readoutValueRects = []
        readoutLetterColors = []
        readoutValueTexts = []
        readoutValueColors = []
        // Re-derived from the live state every draw: a new measurement or a new bin can never leave the
        // previous one's numbers on screen.
        refreshReadoutRow()

        switch readoutState {
        case .idle:
            return
        case .histogram(let counts):
            paintCounts(counts, atY: row.minY, color: color)
        }
    }

    /// The `R 1284 G 1291 B 1206` half of the row — three groups, `paintGroups`' layout.
    private func paintCounts(_ counts: HistogramBinCounts, atY y: CGFloat, color: NSColor) {
        let values = ["\(max(counts.red, 0))", "\(max(counts.green, 0))", "\(max(counts.blue, 0))"]
        let painted = paintGroups(values, atY: y,
                                  letterFont: Self.channelLetterFont,
                                  letterColors: Self.channelNameColors,
                                  valueFont: Self.numberFont, valueColor: color)
        readoutLetterRects = painted.letters
        readoutValueRects = painted.values
        readoutLetterColors = painted.colors
        readoutValueTexts = values
        readoutValueColors = painted.valueColors
        readoutValueFont = Self.numberFont
        readoutValueColor = color
        hoverCountText = HistogramCardFormat.readoutCounts(counts)
        guard let firstValue = painted.values.first, let lastValue = painted.values.last,
              let firstLetter = painted.letters.first, let lastLetter = painted.letters.last else {
            return
        }
        hoverCountRect = firstValue.union(lastValue)
        hoverReadoutRect = hoverCountRect.union(firstLetter).union(lastLetter)
        readoutContentRect = hoverReadoutRect
        hoverPaintCount += 1
        readoutPaintCount += 1
    }

    @discardableResult
    private func drawText(_ text: String, at point: CGPoint, font: NSFont,
                          color: NSColor) -> NSRect {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: point, withAttributes: attributes)
        return NSRect(origin: point, size: size)
    }
}

// MARK: - the pointer's reading lands here

/// The card is the loupe's `PointerReadoutTarget`: `LoupeCanvasView` tracks the pointer once, and the
/// loupe pushes the pixel under it to whoever is showing readings. Declared here rather than on the
/// class so the conformance is visible next to the two methods it means (`showPointerReadout` /
/// `clearPointerReadout`, which are ordinary public API — the smoke and the tests drive them directly).
extension HistogramCardView: PointerReadoutTarget {}

// MARK: - the two labels that had to become readable
//
// The complaint (2026-10-26): the per-channel percentages were "grey, not obvious" and the
// sample/bin caption "even blacker, invisible". Both were *semantic* label colours, and those are
// alpha tints of black/white — 26 % and 10 % — so they read as texture, not as text:
//
// | | aqua (over #ECECEC) | darkAqua (over #1E1E1E) |
// |---|---|---|
// | `.tertiaryLabelColor` (percentages) | **1.86 : 1** | **2.26 : 1** |
// | `.quaternaryLabelColor` (caption)   | **1.24 : 1** | **1.34 : 1** |
//
// WCAG 2.1 SC 1.4.3 wants 4.5 : 1 for text this size, so neither was near it. The fix is a pair of
// **opaque** colours resolved per appearance, and the arithmetic that proves them is here rather
// than in a comment: the unit test and `--ui-smoke` both recompute the ratio from the colours the
// card actually drew with.
//
// The card paints nothing of its own behind these labels. It is an `NSView` inside the inspector's
// `card(_:)`, whose fill is `.regularMaterial` over `NSColor.windowBackgroundColor` (set on the
// window by `EditorWindowController`). A material can only lift a backdrop toward white, so the
// backdrop's grey level is *bounded* by the window background on one side and white on the other.
// The colours below therefore have to clear 4.5 : 1 at the **worst** end of that band — the darker
// one in aqua, the lighter one in darkAqua — not at the middle of it, which is why the numbers here
// (9.9 and 6.1 in aqua) look stronger than the 4.5 they promise.
public enum HistogramCardReadability {

    /// WCAG 2.1 SC 1.4.3, normal-size text. The card's labels are 8–8.5 pt, so this is the floor.
    public static let minimumRatio: Double = 4.5

    /// The sRGB grey levels the card's backdrop can resolve to, per appearance.
    ///
    /// aqua: `windowBackgroundColor` `#ECECEC` (0.925) up to the material's white.
    /// darkAqua: `#1E1E1E` (0.117) up to the material's own grey, `#333333` (0.200).
    public static func backdropGreys(isDark: Bool) -> (low: Double, high: Double) {
        isDark ? (0.117, 0.200) : (0.925, 1.000)
    }

    // MARK: the colours

    /// The R/G/B percentages: a strong neutral, one step below the card's primary numbers.
    public static func percentColor(isDark: Bool) -> NSColor {
        isDark ? NSColor(srgbRed: 0.82, green: 0.82, blue: 0.83, alpha: 1)
               : NSColor(srgbRed: 0.22, green: 0.22, blue: 0.23, alpha: 1)
    }

    /// The hover readout (010): a neutral that is *quieter* than the percentages but still opaque and
    /// still ≥ 4.5 : 1 at the worst end of the band (measured: 6.1 : 1 in aqua, 6.3 : 1 in darkAqua).
    /// `.secondaryLabelColor` would have been the obvious choice and is not: it is a 50 % tint, so
    /// over this backdrop it lands near 4 : 1 — under the floor the card promises. Being opaque is
    /// also what keeps a filled plot from showing through the glyphs.
    public static func readoutColor(isDark: Bool) -> NSColor {
        isDark ? NSColor(srgbRed: 0.72, green: 0.72, blue: 0.73, alpha: 1)
               : NSColor(srgbRed: 0.34, green: 0.34, blue: 0.35, alpha: 1)
    }

    // MARK: the fonts (unchanged sizes — nothing here may shrink)

    /// 8.5 pt, monospaced digits: the size the percentages already had. They are a column of numbers
    /// under each other's channel letters, so the digits must not jitter as the value changes.
    public static var percentFont: NSFont {
        .monospacedDigitSystemFont(ofSize: 8.5, weight: .regular)
    }

    // MARK: the arithmetic (WCAG 2.1, sRGB-linearised)

    /// One sRGB channel, linearised.
    public static func linear(_ component: CGFloat) -> Double {
        let v = Double(component)
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    /// WCAG relative luminance of an sRGB colour (alpha is the caller's problem: these colours are
    /// opaque by construction, and the *old* ones are composited by the test before measuring).
    public static func relativeLuminance(of color: NSColor) -> Double {
        guard let srgb = color.usingColorSpace(.sRGB) else { return .nan }
        return 0.2126 * linear(srgb.redComponent)
            + 0.7152 * linear(srgb.greenComponent)
            + 0.0722 * linear(srgb.blueComponent)
    }

    /// Contrast ratio of `color` against a neutral backdrop of the given sRGB grey level.
    public static func contrast(of color: NSColor, overGrey grey: Double) -> Double {
        let a = relativeLuminance(of: color) + 0.05
        let b = linear(CGFloat(grey)) + 0.05
        return max(a, b) / min(a, b)
    }

    /// The ratio that has to hold: the worst end of the backdrop band for this appearance.
    public static func worstContrast(of color: NSColor, isDark: Bool) -> Double {
        let band = backdropGreys(isDark: isDark)
        return [band.low, band.high].map { contrast(of: color, overGrey: $0) }.min() ?? 0
    }
}

// MARK: - SwiftUI host
//
// The inspector is SwiftUI; the card is AppKit. `NSViewRepresentable` is the seam, and it carries
// nothing but three values: the histogram, the overlay flag, and the toggle — no state lives in the
// adapter, so a SwiftUI re-render cannot lose the numbers.

public struct HistogramCard: View {
    @Bindable var session: CatalogSession
    /// Where the pointer is, for the bottom row. The loupe owns the one mouse position; the card is a
    /// *consumer* of it (`PointerReadoutTarget`), so the pixel the canvas reads and the row prints are
    /// the same pixel. Optional: the card is also built without a loupe (previews, the inspector tests).
    public let loupe: LoupeController?

    public init(session: CatalogSession, loupe: LoupeController? = nil) {
        self.session = session
        self.loupe = loupe
    }

    public var body: some View {
        HistogramCardHost(histogram: session.lastHistogram,
                          showsHighlightWarning: session.highlightWarning,
                          loupe: loupe,
                          onToggle: { session.toggleHighlightWarning() })
            .frame(height: HistogramCardView.contentHeight)
    }
}

private struct HistogramCardHost: NSViewRepresentable {
    var histogram: Histogram?
    var showsHighlightWarning: Bool
    var loupe: LoupeController?
    var onToggle: () -> Void

    func makeNSView(context: Context) -> HistogramCardView {
        let view = HistogramCardView()
        view.histogram = histogram
        view.showsHighlightWarning = showsHighlightWarning
        view.onToggleHighlightWarning = onToggle
        // The card registers itself as the pointer's reader; the loupe holds it weakly and pushes the
        // reading it already has (a pointer that is already over the picture when the card appears).
        loupe?.pointerReadoutTarget = view
        return view
    }

    func updateNSView(_ view: HistogramCardView, context: Context) {
        view.histogram = histogram
        view.showsHighlightWarning = showsHighlightWarning
        view.onToggleHighlightWarning = onToggle
        if loupe?.pointerReadoutTarget !== view { loupe?.pointerReadoutTarget = view }
        view.needsDisplay = true
    }
}
