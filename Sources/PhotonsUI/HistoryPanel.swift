import AppKit
import SwiftUI
import PhotonsCore

// MARK: - 派单 077: the history workspace

/// The 历史记录 card: the edit timeline, one row per committed state.
///
/// A leaf view like the rest of the inspector — it holds **no copy** of the stack. Every row is a
/// `HistoryRow` read from `CatalogSession.history`, and the three things a row can do all go through
/// the session:
///
///   · **click** the row → `jumpToHistory(seq:)` (move the cursor and re-render once — no snapshot);
///   · **删除** → `deleteHistoryEntry(at:)`, enabled only when `HistoryRow.canDelete` (the model's
///     own `deletable(at:)`, i.e. 「只有最新的该类操作可以单独删除」);
///   · nothing else. This panel cannot edit the document, so it cannot grow the stack.
///
/// `最新` is drawn from `HistoryRow.isNewestOfClass` — the same predicate the delete button uses, so
/// the badge and the button can never disagree about a row.
///
/// **Scrolling**: the rows are a `LazyVStack` inside the inspector's *existing* `ScrollView` — no
/// nested scroll view (a second scrollbar inside a 330 pt panel is a trap), and no eager `VStack`
/// (a 1000-row stack would build 1000 views). `onAppear` counts what SwiftUI actually built, which is
/// what `HistoryPanelProbe.builtRows` reports — the property a test can falsify.
public struct HistoryPanel: View {

    @Bindable public var session: CatalogSession

    /// Rows SwiftUI has actually inserted (LazyVStack builds as the scroll moves). View state: it
    /// exists so the readback seam can prove the list is lazy.
    @State private var builtRowIndexes: Set<Int> = []

    public init(session: CatalogSession) {
        self.session = session
    }

    private var rows: [HistoryRow] { session.historyRows }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if rows.isEmpty {
                Text("还没有编辑")
                    .font(.system(size: HistoryPanelLayout.metaFontSize))
                    .foregroundStyle(.tertiary)
            } else {
                LazyVStack(alignment: .leading, spacing: HistoryPanelLayout.rowSpacing) {
                    ForEach(rows) { row in
                        rowView(row)
                    }
                }
            }
        }
        .padding(.horizontal, WorkspaceLayout.cardInsetH)
        .padding(.vertical, WorkspaceLayout.cardInsetV)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Small widget container: glass here, matte everywhere else (§2b item 5).
        .background(.regularMaterial,
                    in: RoundedRectangle(cornerRadius: WorkspaceLayout.cardCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: WorkspaceLayout.cardCornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        // The readback seam: how many rows exist, how many were built, and whether each row's text
        // fits its column. Its frame **is** the card, which is where the column widths come from.
        .background(alignment: .topLeading) {
            HistoryPanelProbeHost(rows: rows, builtRows: builtRowIndexes.count)
        }
        .accessibilityIdentifier("inspector.card.history")
    }

    /// 「历史记录」 + the row count. The card builder in `InspectorView` does not wrap this one (the
    /// mask card is the same): a timeline needs its own header row, and the count is part of what the
    /// user reads ("我在第 7 步 / 一共 7 步").
    private var header: some View {
        HStack(spacing: 6) {
            Text("历史记录")
                .font(.system(size: 11, weight: .bold))
            Text("\(rows.count)")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
            if let undo = session.undoLabel {
                Text("可撤销 \(undo)")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }

    /// `序号 · 摘要（具体参数 + 旧→新）· 标签/时间`, current row highlighted, newest-of-class badged.
    private func rowView(_ row: HistoryRow) -> some View {
        HStack(alignment: .top, spacing: HistoryPanelLayout.spacing) {
            Text("\(row.seq)")
                .font(.system(size: HistoryPanelLayout.metaFontSize, design: .monospaced))
                .foregroundStyle(row.isCurrent ? .secondary : .tertiary)
                .frame(width: HistoryPanelLayout.seqWidth, alignment: .trailing)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 1) {
                Text(row.summary)
                    .font(.system(size: HistoryPanelLayout.summaryFontSize))
                    .foregroundStyle(row.isCurrent ? .primary : .secondary)
                    // Two lines, then it stays two lines: the panel is 300–364 pt wide and a curve or
                    // mask summary can be long. Wrapping beats an ellipsis (「不截断」).
                    .lineLimit(HistoryPanelLayout.summaryLines)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 4) {
                    Text(row.label)
                        .font(.system(size: HistoryPanelLayout.metaFontSize))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    Text(row.timeText)
                        .font(.system(size: HistoryPanelLayout.metaFontSize, design: .monospaced))
                        .foregroundStyle(.quaternary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            badge(row)
            deleteButton(row)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .background {
            if row.isCurrent {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.accentColor.opacity(0.14))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { session.jumpToHistory(seq: row.seq) }
        .onAppear { builtRowIndexes.insert(row.index) }
        .help(row.isCurrent ? "现在显示的是这一步" : "回到这一步（不新增历史）")
        .accessibilityIdentifier("inspector.history.row.\(row.seq)")
    }

    /// 「最新」 — every field this row moved is still the newest statement about that field. The
    /// column is always reserved, so a badge cannot shift the text of the rows below it.
    private func badge(_ row: HistoryRow) -> some View {
        Text(row.isNewestOfClass ? "最新" : "")
            .font(.system(size: 8, weight: .medium))
            .foregroundStyle(Color.accentColor)
            .frame(width: HistoryPanelLayout.badgeWidth, alignment: .trailing)
            .padding(.top, 1)
            .accessibilityLabel(row.isNewestOfClass ? "最新" : "")
    }

    /// 删除 — only on the newest row of its class. The column is reserved either way (`Color.clear`
    /// rather than a removed view) so the timeline does not re-flow when a row becomes deletable.
    private func deleteButton(_ row: HistoryRow) -> some View {
        Group {
            if row.canDelete {
                Button {
                    session.deleteHistoryEntry(at: row.index)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .semibold))
                        .frame(width: HistoryPanelLayout.deleteWidth,
                               height: HistoryPanelLayout.deleteHitHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help("删除这一条（只允许删除该类最新的一条）")
                .accessibilityLabel("删除第 \(row.seq) 条")
                .accessibilityIdentifier("inspector.history.delete.\(row.seq)")
            } else {
                Color.clear
                    .frame(width: HistoryPanelLayout.deleteWidth,
                           height: HistoryPanelLayout.deleteHitHeight)
            }
        }
        .padding(.top, 1)
    }
}

// MARK: - layout

/// The one place the row's columns are decided.
///
/// Three panel widths matter (`WorkspaceLayout.inspectorWidthMin/Default/Max` = 300 / 330 / 364), and
/// the arithmetic below is what makes 「宽 300/330/364 不截断」 a measurement instead of a hope:
/// the summary column is everything left after the fixed columns, and the row is allowed two lines.
public enum HistoryPanelLayout {
    /// `序号` — four digits of 9 pt mono.
    public static let seqWidth: CGFloat = 22
    /// 「最新」 — always reserved.
    public static let badgeWidth: CGFloat = 26
    /// The delete glyph — always reserved.
    public static let deleteWidth: CGFloat = 16
    public static let deleteHitHeight: CGFloat = 14
    /// Gap between columns (three of them: seq | text | badge | delete).
    public static let spacing: CGFloat = 6
    /// The summary is 10 pt, the label/time line 9 pt.
    public static let summaryFontSize: CGFloat = 10
    public static let metaFontSize: CGFloat = 9
    /// How many lines a summary may take before it would be clipped. Wrapping, never `…`.
    public static let summaryLines: Int = 2
    public static let rowSpacing: CGFloat = 2
    /// The row's own horizontal inset (on top of the card's).
    public static let rowInsetH: CGFloat = 4

    /// The width the rows have inside the card. `cardWidth` is the probe's own frame.
    public static func contentWidth(cardWidth: CGFloat) -> CGFloat {
        max(0, cardWidth - 2 * WorkspaceLayout.cardInsetH - 2 * rowInsetH)
    }

    /// What is left for the summary text.
    public static func summaryColumn(contentWidth: CGFloat) -> CGFloat {
        max(0, contentWidth - seqWidth - badgeWidth - deleteWidth - 3 * spacing)
    }

    /// The summary column at a given **panel** width (the card is `panel − 2·12`).
    public static func summaryColumn(panelWidth: CGFloat) -> CGFloat {
        summaryColumn(contentWidth: contentWidth(cardWidth: panelWidth - 24))
    }
}

// MARK: - readback

/// The history card, as SwiftUI actually built it.
///
/// Reports the four facts a `swift test` cannot otherwise reach: how many rows the stack has, how many
/// of them were **built** (`LazyVStack` builds as the scroll moves — a 1000-row stack must not build
/// 1000 views), the column widths that came out of this panel's own frame, and, per row, whether its
/// summary text fits the column in the lines it is allowed.
///
/// `hitTest` answers `nil`: it is a background, not a hit target.
public final class HistoryPanelProbe: NSView {

    public struct RowFact: Equatable {
        public var index: Int
        public var seq: Int
        public var summary: String
        public var label: String
        public var isCurrent: Bool
        public var isNewest: Bool
        public var canDelete: Bool
        /// The measured width of `summary` at the row's font.
        public var textWidth: CGFloat
        /// Lines the summary needs inside `summaryColumn` (1 for anything that fits).
        public var lines: Int
    }

    public private(set) var rows: [RowFact] = []
    public private(set) var totalRows: Int = 0
    public private(set) var builtRows: Int = 0
    public private(set) var cardWidth: CGFloat = 0
    public private(set) var contentWidth: CGFloat = 0
    public private(set) var summaryColumn: CGFloat = 0
    public private(set) var summaryLines: Int = HistoryPanelLayout.summaryLines

    private var source: [HistoryRow] = []

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = false
    }

    public required init?(coder: NSCoder) {
        fatalError("HistoryPanelProbe is created in code")
    }

    public override func hitTest(_ point: NSPoint) -> NSView? { nil }
    public override var isOpaque: Bool { false }

    func update(rows: [HistoryRow], builtRows: Int) {
        self.source = rows
        self.totalRows = rows.count
        self.builtRows = builtRows
        recompute()
    }

    public override func layout() {
        super.layout()
        recompute()
    }

    private func recompute() {
        cardWidth = bounds.width
        contentWidth = HistoryPanelLayout.contentWidth(cardWidth: cardWidth)
        summaryColumn = HistoryPanelLayout.summaryColumn(contentWidth: contentWidth)
        let font = NSFont.systemFont(ofSize: HistoryPanelLayout.summaryFontSize)
        rows = source.map { row in
            let width = (row.summary as NSString).size(withAttributes: [.font: font]).width
            let lines = summaryColumn <= 0 ? 99 : max(1, Int((width / summaryColumn).rounded(.up)))
            return RowFact(index: row.index, seq: row.seq, summary: row.summary, label: row.label,
                           isCurrent: row.isCurrent, isNewest: row.isNewestOfClass,
                           canDelete: row.canDelete, textWidth: width, lines: lines)
        }
    }
}

struct HistoryPanelProbeHost: NSViewRepresentable {
    var rows: [HistoryRow]
    var builtRows: Int

    func makeNSView(context: Context) -> HistoryPanelProbe {
        let probe = HistoryPanelProbe()
        probe.update(rows: rows, builtRows: builtRows)
        return probe
    }

    func updateNSView(_ probe: HistoryPanelProbe, context: Context) {
        probe.update(rows: rows, builtRows: builtRows)
    }
}
