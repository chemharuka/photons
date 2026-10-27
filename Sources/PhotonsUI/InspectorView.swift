import AppKit
import SwiftUI
import PhotonsCatalog
import PhotonsCore

/// The inspector: SwiftUI inside `NSHostingView`, bound to the one `CatalogSession`.
///
/// §2b item 5 keeps the big surfaces matte and uses glass only for small widget containers. The
/// panel is a *leaf*: it holds no document state of its own, and every slider writes through
/// `CatalogSession.applyEdit` — the only mutation point, which is what bumps `editRevision` and
/// wakes the loupe's debounced renderer (50 ms, single-flight).
///
/// The drag/release split matters: `onEditingChanged` fires once when the drag ends, and that is
/// exactly one `EditHistory` snapshot. Committing per tick would make ⌘Z undo 1/100 EV at a time.
///
/// 派单 047 adds three interactions to **every** row of the panel, and all three live in the two
/// builders below (`sliderRow` / `card`), never in a card: a card that drew its own row would get a
/// different behaviour set, which is exactly the bug the single builder exists to prevent.
///
///   1. **The number is a field** (`SliderNumberField`): click it (or Tab to it), type, `↵` commits,
///      `Esc` cancels, losing focus commits. `SliderValueInput` is the parser; a rejected string
///      beeps, puts the old number back and writes **nothing**. An accepted one takes the drag's own
///      path (`applyEdit` through the binding, then the gesture-end commit) — one input, one snapshot.
///   2. **Double-click a parameter's name** → that field back to its own default (`PanelResets.field`,
///      read from `EditModel.neutral`, never a literal `0`).
///   3. **Double-click a card's title** → the whole card back in **one** snapshot (`PanelResets.group`),
///      so ⌘Z takes the group back in one press rather than N.
public struct InspectorView: View {

    /// The cards, in display order (派单 009 A).
    ///
    /// `body` builds the stack from `allCases`, so this list **is** the view hierarchy — there is no
    /// second, hand-maintained ordering to drift out of step with what is on screen. The tests assert
    /// it (`InspectorView.sectionTitles`) and the rendered order of the card identifiers.
    public enum Section: String, CaseIterable, Identifiable, Hashable {
        /// Histogram first: it is the read-out of the picture the rest of the panel edits.
        case histogram
        /// 白平衡 is its own section, between the histogram and Light (派单 009 A): it is a *decode*
        /// setting (006), not a tone control, and burying it under six sliders misrepresented that.
        case whiteBalance
        case light
        case color
        /// 派单 031: 降噪 / 色彩降噪 / 细节 / 锐化 — four **decoder** amounts, next to Color because they
        /// are the same panel in Lightroom, and below the tone controls because they act on the
        /// decoded pixels rather than on the render.
        case detail
        case presets
        case masks
        case decode

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .histogram: return "直方图"
            case .whiteBalance: return "白平衡"
            case .light: return "Light"
            case .color: return "Color"
            case .detail: return "细节"
            case .presets: return "预设"
            case .masks: return "蒙版"
            case .decode: return "Decode"
            }
        }
    }

    /// `["直方图", "白平衡", "Light", …]` — the order the cards appear in, from the one list above.
    public static var sectionTitles: [String] { Section.allCases.map(\.title) }

    /// The cards that live **inside** the scroll view: everything except the pinned histogram.
    ///
    /// Still derived from `allCases` (one list, one order), so excluding a card here cannot silently
    /// disagree with the enum — and `.histogram` is rendered exactly once, from `pinnedColumn`.
    public static var scrollingSections: [Section] { Section.allCases.filter { $0 != .histogram } }

    /// The pinned block's title. 「信息」, not 「调整」 — the block reports the photo (file name,
    /// shooting parameters, equipment); it is not a control, and calling it 调整 made the panel promise
    /// edits where it only ever printed facts.
    public static let infoTitle = "信息"

    @Bindable public var session: CatalogSession
    /// The canvas, for the eyedropper and for the Auto preset's grey-world input (派单 009 C).
    /// Optional: the inspector is also built without a loupe (tests, previews, the grid side).
    public let loupe: LoupeController?

    /// The value under the thumb while a white-balance drag is in progress (派单 006).
    ///
    /// Not a document write: a Kelvin change means a **re-decode** (~762 ms full size), so a tick
    /// must never reach the model. The draft dies on release, where the value is quantized and
    /// committed once — one decode, one history snapshot.
    @State private var draftTemperature: Double?
    @State private var draftTint: Double?

    /// The exposure row of the anchor photo (派单 014). Read handle + last read, both view state:
    /// the catalog stays the source of truth and nothing here is ever written back.
    @State private var metadataReader = InspectorMetadataReader()
    @State private var photoMetadata: AssetMetadata?

    /// The preset the user picked last. View state on purpose: it only breaks ties between presets
    /// with identical numbers (`闪光灯 == 日光`), and a tie is not a fact about the document.
    @State private var lastPresetID: String?
    /// One line under the sliders: what the dropper did, or why it did nothing.
    @State private var hint: String?
    @State private var eyedropperArmed = false

    public init(session: CatalogSession, loupe: LoupeController? = nil) {
        self.session = session
        self.loupe = loupe
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            pinnedColumn
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(Self.scrollingSections) { section in
                        sectionView(section)
                            .accessibilityIdentifier("inspector.card.\(section.rawValue)")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 14)
            }
            .frame(maxHeight: .infinity)
        }
        .padding(.top, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.clear)
        .task(id: metadataKey) { reloadMetadata() }
    }

    /// The top of the panel: 信息 + 直方图, outside the `ScrollView`, so neither can be dragged away.
    ///
    /// The two blocks are the panel's *reference*: what this photo is, and what its tones are. The
    /// controls below them are read against those numbers, so scrolling the reference off the top is
    /// how a slider ends up being dragged blind. They keep their own height in a short window too —
    /// `fixedSize(vertical:)` gives the column its ideal height and `layoutPriority` hands the
    /// remainder to the scroll view, so a shrinking window takes space from the sliders, never from
    /// the histogram (which would otherwise collapse to a strip).
    private var pinnedColumn: some View {
        VStack(spacing: 10) {
            infoCard
                .accessibilityIdentifier("inspector.card.info")
            sectionView(.histogram)
                .accessibilityIdentifier("inspector.card.histogram")
        }
        .padding(.horizontal, 12)
        .fixedSize(horizontal: false, vertical: true)
        .layoutPriority(1)
    }

    @ViewBuilder
    private func sectionView(_ section: Section) -> some View {
        switch section {
        case .histogram:
            // The loupe is handed in so the card can read the pointer's pixel: the canvas owns the one
            // mouse position, and the row under the plot is one of its two consumers.
            card(Section.histogram.title) { HistogramCard(session: session, loupe: loupe) }
        case .whiteBalance:
            whiteBalanceCard
        case .light:
            lightCard
        case .color:
            colorCard
        case .detail:
            detailCard
        case .presets:
            PresetPanel(session: session)
        case .masks:
            MaskListPanel(session: session)
        case .decode:
            decodeCard
        }
    }

    /// 「信息」, four rows (派单 022, second version):
    ///
    /// ```
    /// L100000.dng                60 MP                 9000×6000   ← one line, three columns
    /// Leica SL3                                                  ← camera
    /// Vario-Elmarit-SL 24-90                                     ← lens
    /// ISO 100     50 mm     f/2.8     1/250s                     ← the four exposure slots
    /// ```
    ///
    /// + `MissingFileNotice` when the original moved (below the four rows: it reports the file,
    /// not the photo). The first row carries **values only** and no labels — the user's words were
    /// 「不要写中文 就 L100000.dng   60 MP   9000×6000」. Rows 2 and 3 are the two halves the
    /// equipment line used to join, unchanged in wording; both stay marquees so a long lens name
    /// still truncates with `…` and scrolls on hover.
    ///
    /// The card is the point: the two pinned blocks are one visual unit, and the container's own
    /// horizontal inset is what puts the rows at exactly the card content width
    /// (`330 − 2·12 − 2·16 = 274` at the default panel).
    private var infoCard: some View {
        card(Self.infoTitle) {
            VStack(alignment: .leading, spacing: 2) {
                // 派单 049: 像素数量 / 尺寸 follow the canvas on screen — the crop tool's live draft
                // while it is open, else the document's geometry. Computed once per refresh (a crop
                // tick, ⌘Z, a photo switch), not per frame; `metrics` is pure arithmetic.
                let spec = specMetrics
                InspectorPhotoInfo.PhotoSpecRow(filename: session.anchorAsset?.filename ?? "未选择照片",
                                                pixelCount: spec.pixelCount,
                                                pixelDimensions: spec.pixelDimensions)
                // Two rows, not one: 相机 and 镜头 are different facts, and the joined line was the
                // longest in the card (`Leica SL3 · Vario-Elmarit-SL 1:2.8-4/24-90 ASPH.`).
                MarqueeText(text: camera)
                MarqueeText(text: lens)
                InspectorPhotoInfo.InspectorParameterRow(tokens: parameterTokens)
                if let notice = InspectorPhotoInfo.missingNotice(isMissing: session.anchorAsset?.isMissing ?? false) {
                    MissingFileNotice(text: notice)
                        .accessibilityIdentifier("inspector.info.missing")
                }
            }
        }
    }

    /// 「像素数量 / 尺寸」 — the **canvas** on screen (派单 049): the asset's stored size run through
    /// the crop, so the two numbers agree with the picture, the export and the histogram.
    private var specMetrics: InspectorPhotoInfo.PhotoInfoMetrics {
        InspectorPhotoInfo.metrics(storedWidth: session.anchorAsset?.width,
                                   storedHeight: session.anchorAsset?.height,
                                   geometry: canvasGeometry,
                                   source: ingestedSource)
    }

    /// The geometry the canvas is showing: the crop tool's live draft while it is open (a drag writes
    /// no document until 应用), otherwise the anchor photo's own document.
    private var canvasGeometry: GeometryGroup? {
        if let draft = session.cropToolDraft, draft.assetID == session.anchorAsset?.id {
            return draft.geometry
        }
        // `session.edit` is only this photo's document once the session says it loaded it; before
        // that it is the previous photo's, and its crop must not lend itself to this row.
        guard let id = session.anchorAsset?.id, session.loadedEditAssetID == id else { return nil }
        return session.edit.geometry
    }

    /// The **upright** frame the renderer ingested for this photo (`RenderGraph.sourceSize`), the
    /// frame the crop is measured in. `nil` until the first frame lands — the row then falls back to
    /// the catalog's stored dimensions, i.e. to what it printed before 049.
    private var ingestedSource: ImageSize? {
        guard let frame = session.ingestedSourceFrame,
              frame.assetID == session.anchorAsset?.id else { return nil }
        return frame.size
    }

    // MARK: shooting information (派单 014)

    private var parameterTokens: InspectorPhotoInfo.ParameterTokens {
        InspectorPhotoInfo.tokens(iso: photoMetadata?.iso,
                                  focalLength: photoMetadata?.focalLength,
                                  aperture: photoMetadata?.aperture,
                                  shutter: photoMetadata?.shutter)
    }

    /// Two rows, each one bare name — 派单 022:「信息栏目前不需要任何 · 符号」. No joining, no
    /// splitting of the old `equipment` string: the two halves come straight from the same pair of
    /// functions `equipment` is built on (`cameraName` / `nonEmpty`), so the wording cannot drift.
    private var camera: String {
        InspectorPhotoInfo.camera(make: session.anchorAsset?.cameraMake,
                                  model: session.anchorAsset?.cameraModel)
    }

    private var lens: String {
        InspectorPhotoInfo.lens(session.anchorAsset?.lens)
    }

    private var metadataKey: String {
        "\(session.libraryURL?.path ?? "-")|\(session.anchorAsset?.id ?? "-")"
    }

    /// One row read per anchor change. `CatalogSession` exposes no metadata accessor on purpose, so
    /// the reader keeps a single extra read-only handle for the library instead of reopening it.
    private func reloadMetadata() {
        let assetID = session.anchorAsset?.id
        guard assetID != nil else { photoMetadata = nil; return }
        photoMetadata = metadataReader.metadata(library: session.libraryURL, assetID: assetID)
    }

    // The undo/redo strip that used to sit under the title is gone: an editor's history belongs in
    // the dedicated 历史 area (still to come), not as two lines of grey text above the sliders.
    // ⌘Z / ⇧⌘Z themselves are untouched — the menu items still carry the labels.

    // MARK: cards

    /// Light: tone only. 色温/色调 moved out (派单 009 A) — they are a decode setting, and keeping a
    /// second entry here would be two controls for one fact.
    ///
    /// 047: the title resets the whole card (`PanelResets.group(.light)` — one snapshot, and the two
    /// absolute levels back to `nil`), each name resets its own field.
    private var lightCard: some View {
        card(Section.light.title, reset: { resetGroup(.light) }) {
            ForEach(Self.lightRows, id: \.title) { row in
                sliderRow(row.title, binding(row.keyPath), row.range, row.format,
                          shape: row.shape,
                          editable: row.editable,
                          onReset: { resets.field(row.keyPath, label: row.title) }) { editing in
                    // Drag end = one edit action = one history snapshot (never per tick).
                    if !editing { session.commitEdit() }
                }
            }
        }
    }

    /// 白平衡 (派单 009): preset menu, the two absolute sliders, and the dropper.
    ///
    /// The whole section is one idea — *what is neutral?* — and its three controls are three answers:
    /// a known illuminant (menu), a number (sliders), or a sample (dropper). All three end in the same
    /// place: one `commitWhiteBalance` → one history snapshot → one development.
    private var whiteBalanceCard: some View {
        card(Section.whiteBalance.title, reset: { resetWhiteBalance() }) {
            presetRow
            divider
            ForEach(Self.whiteBalanceRows, id: \.title) { row in
                whiteBalanceRow(row)
            }
            dropperRow
            if let hint {
                Text(hint)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(3)
            }
        }
    }

    private var colorCard: some View {
        card(Section.color.title, reset: { resetGroup(.color) }) {
            ForEach(Self.colorRows, id: \.title) { row in
                sliderRow(row.title, binding(row.keyPath), row.range, row.format,
                          shape: row.shape,
                          editable: row.editable,
                          onReset: { resets.field(row.keyPath, label: row.title) }) { editing in
                    if !editing { session.commitEdit() }
                }
            }
        }
    }

    /// 细节 (派单 031, 数值口径 040): 降噪 / 色彩降噪 / 细节 / 锐化, all four assigned to `CIRAWFilter`.
    ///
    /// Three rules make this card different from the tone sliders, and all three come from the same
    /// fact — **a tick here is a development, not a render**:
    ///
    ///  1. **The number is a slider position, 0…100.** `value / 100` is what gets assigned; the
    ///     *default* position is the body's own baseline × 100 (Leica 0/50/0/50, R5 sharpness 100,
    ///     Sony ARW luminance NR 38), and a slider sitting there assigns **nothing**. That is what keeps
    ///     an untouched document byte-identical, and why a resting colour-NR slider must not push a
    ///     0.0 into Apple's 0.5.
    ///  2. **Drag = preview rung, release = full size.** The thumb writes the document on every tick
    ///     (the canvas has to follow it), and the loupe rebuilds from the 0.5 rung while the slider is
    ///     held; 200 ms after the hand stops it develops full size and replaces the frame. One drag is
    ///     still **one** `EditHistory` snapshot, taken on release.
    ///  3. **Four sliders, no prose.** 040 removed the 「解码参数 · v9 · 基线 0.50」 line under them: the
    ///     card is four rows of the *same* control every other card uses, and the decoder's own numbers
    ///     live in the Decode card.
    private var detailCard: some View {
        let baseline = detailBaselineValue
        return card(Section.detail.title, reset: { resetGroup(.detail) }) {
            ForEach(Self.detailContent.rows, id: \.axis) { row in
                sliderRow(row.title,
                          detailBinding(row.axis, baseline: baseline),
                          row.range,
                          row.format,
                          shape: row.shape,
                          editable: row.editable,
                          accessibilityID: "inspector.detail.\(row.axis.rawValue)",
                          onReset: { resets.detail(row.axis) }) { editing in
                    if editing { beginDetailDrag() } else { commitDetail(title: row.title) }
                }
            }
        }
    }

    /// 派单 040: the card prints **nothing** under its sliders.
    ///
    /// The constant is the machine-readable form of that sentence (`nil` = no footer), and the panel
    /// test also walks the rendered card for any 基线 / 解码 / v9 label: a line that came back as view
    /// text would be caught there, not here.
    public static let detailFooterText: String? = nil

    /// The 细节 card's four rows, as data — what the view iterates, in order, with the travel and the
    /// number format each row draws.
    ///
    /// 040's「下面解码参数什么的不用展示」is the reason this is a list of rows and not a view that also
    /// knows how to print a note: the card's entire text is these four titles plus a number per row,
    /// so a test can hold the whole surface (`DetailSectionTests.testTheCardPrintsNoDecoderProse`).
    public static let detailContent = DetailCardContent.standard

    /// The decoder's own four values, read once per development. `.measured` until the first one
    /// lands, so the panel can put the sliders on their defaults before there is a buffer to ask.
    private var detailBaselineValue: DetailBaseline {
        loupe?.currentDetailBaseline ?? .measured
    }

    /// Live write-through: every tick moves the document (the canvas follows the thumb), but nothing
    /// is committed until the drag ends. A position equal to the default clears the field instead of
    /// storing the number — see `DetailSettings.setPosition`.
    private func detailBinding(_ axis: DetailAxis, baseline: DetailBaseline) -> Binding<Double> {
        Binding(get: { session.edit.detailSettings.position(axis, in: baseline) },
                set: { newValue in
                    session.applyEdit { $0.detailSettings.setPosition(newValue, axis, in: baseline) }
                })
    }

    /// Drag start: the loupe rebuilds from the preview rung only (派单 031).
    private func beginDetailDrag() {
        loupe?.beginDetailAdjustment()
    }

    /// One drag (or one typed value) = one quantized write = one history snapshot = one full-size
    /// development. The loupe's settle timer does the last part 200 ms after the hand stops.
    private func commitDetail(title: String) {
        session.applyEdit { $0.detailSettings = $0.detailSettings.quantized() }
        session.commitEdit(label: title)
        loupe?.endDetailAdjustment()
    }

    /// Double-click: back to **this body's default position** — not to 0. On a Leica that is 50 for
    /// colour NR and sharpness, on an R5 it is 100 for sharpness; resetting to 0 would switch Apple's
    /// default off instead of restoring it. One snapshot, one development.
    ///
    /// 047: the body of this verb moved to `PanelResets.detail(_:)` so the panel and the tests run the
    /// same code; the card's `onReset:` calls it.
    private var decodeCard: some View {
        card(Section.decode.title) {
            VStack(alignment: .leading, spacing: 4) {
                Text(session.capabilities?.summary ?? "尚未解码")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text("boost / gamut").font(.system(size: 9)).foregroundStyle(.tertiary)
                    Spacer()
                    Text("0 / off").font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                HStack {
                    Text("display headroom").font(.system(size: 9)).foregroundStyle(.tertiary)
                    Spacer()
                    Text("1.000 · EDR off").font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: building blocks

    /// A card: its title, and its rows.
    ///
    /// `reset` is 派单 047's group verb: when it is given, **double-clicking the title** puts the whole
    /// card back to its defaults in one snapshot (`PanelResets.group(_:)`). `nil` leaves the title a
    /// plain title — the histogram, 信息, 预设 and 蒙版 cards have no "default" to go back to.
    private func card<Content: View>(_ title: String,
                                     reset: (() -> Void)? = nil,
                                     @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.primary)
                .modifier(ResetOnDoubleClick(action: reset, help: Self.resetGroupHelp))
            content()
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
    }

    /// A **render** row (曝光 / 对比 / 自然饱和 …): what 046 calls a `.knob` parameter, because a tone
    /// or color control does not re-develop the RAW.
    ///
    /// 047 kept the rule and deleted the helper's reason to exist: the Light and Color cards now both
    /// iterate a `ToneRow` table, so the shape comes from the row (`row.shape`), not from a literal
    /// here. Two cards, one table type — a row cannot be born without a shape, a default and a reset.

    // MARK: the Light card's rows (046: all six are render parameters → .knob)

    /// One tone row: what the row draws, which shape it draws, and what its default is.
    ///
    /// A table rather than six inline calls because the **shape rule is per parameter class**, and a
    /// test has to be able to hold the six rows' shapes without an accessibility tree
    /// (`LightCardTests`). `keyPath` keeps the write path single-sourced — the card iterates this.
    ///
    /// 047 adds the two facts every row needs and no card may answer differently:
    ///
    ///   · `editable` — the number is a text field. It is in the table so 「每根滑杆都能输入」is a
    ///     failing test on a table, not a discovery on screen;
    ///   · `defaultValue` — derived from `EditModel.neutral`, i.e. from the group's own default
    ///     initializer. A reset must never be a literal `0`: 曝光 0 and 色彩降噪 50 are both "default",
    ///     and only the model knows which is which.
    public struct ToneRow: Equatable {
        public var title: String
        public var range: ClosedRange<Double>
        public var format: String
        public var shape: SliderShape
        public var keyPath: WritableKeyPath<EditModel, Double>
        /// 047: every row in this panel takes a typed number (no card opts out).
        public var editable: Bool = true

        /// The field's own default, read from the neutral document — never a hard-coded number.
        public var defaultValue: Double { EditModel.neutral[keyPath: keyPath] }
    }

    /// 曝光 / 对比 / 高光 / 阴影 / 白色 / 黑色 — the six tone controls, in display order.
    ///
    /// All six are **render** parameters: they act on the decoded pixels and never re-develop the
    /// RAW, so per 046 they keep the round knob. The day one of them moves into `DecodeInputs`, its
    /// `shape` here turns `.bar` and nothing else about the row changes.
    public static let lightRows: [ToneRow] = [
        ToneRow(title: "曝光", range: -5 ... 5, format: "%.2f EV", shape: .knob, keyPath: \.light.exposure),
        ToneRow(title: "对比", range: -100 ... 100, format: "%.0f", shape: .knob, keyPath: \.light.contrast),
        ToneRow(title: "高光", range: -100 ... 100, format: "%.0f", shape: .knob, keyPath: \.light.highlights),
        ToneRow(title: "阴影", range: -100 ... 100, format: "%.0f", shape: .knob, keyPath: \.light.shadows),
        ToneRow(title: "白色", range: -100 ... 100, format: "%.0f", shape: .knob, keyPath: \.light.whites),
        ToneRow(title: "黑色", range: -100 ... 100, format: "%.0f", shape: .knob, keyPath: \.light.blacks),
    ]

    /// 自然饱和 / 饱和 — the Color card's two rows, the same table shape as Light.
    ///
    /// 047 put them in a table for the same reason 046 did with Light's: the card's behaviour (shape,
    /// typeable number, per-parameter reset) is then a value a test can hold, and the two cards cannot
    /// drift apart. Both are render parameters, so both are `.knob`.
    public static let colorRows: [ToneRow] = [
        ToneRow(title: "自然饱和", range: -100 ... 100, format: "%.0f", shape: .knob,
                keyPath: \.color.vibrance),
        ToneRow(title: "饱和", range: -100 ... 100, format: "%.0f", shape: .knob,
                keyPath: \.color.saturation),
    ]

    // MARK: the one row shape (派单 040)

    /// Every row in this panel is `label + number + Slider` in this style — the tone cards, the white
    /// balance card and the 细节 card alike.
    ///
    /// 040's ask was 「拖动条的样式还是和其他保持一致」, and the reason the 细节 card did not look like
    /// the rest was that it drew its own row: a second label ("基线 0.50"), a `TextField` where the
    /// others print a readout, its own `Slider` with a step. So the fix was not "restyle the detail
    /// card", it was **one builder** — and this enum is its only knob. Adding a second case is how a
    /// variant would come back, which is why the test asserts `allCases == [.standard]`.
    enum SliderRowStyle: String, CaseIterable {
        case standard

        var labelSize: CGFloat { 10 }
        var labelWeight: Font.Weight { .medium }
        var readoutSize: CGFloat { 10 }
        var rowSpacing: CGFloat { 1 }
        var headSpacing: CGFloat { 6 }
        /// The tone rows have always been `.mini`; the detail rows now are too.
        var controlSize: ControlSize { .mini }
    }

    /// A row: title (double-click = that field's default), the number, and the slider.
    ///
    /// Three of 047's contracts live here, and nowhere else, so every card gets them:
    ///
    ///   · **`editable`** — the number is a `SliderNumberField`: click it, type, `↵`/blur commits, `Esc`
    ///     cancels, junk beeps and writes nothing. A typed value takes the *drag's* path — the binding
    ///     write, then `onEditingChanged(false)` — so one input is one history entry, exactly like one
    ///     drag. (The old 细节-only `TextField(value:format:)` wrote a value the row then had to commit
    ///     by a second route; it also rounded `0.5` to `1` on the way in.)
    ///   · **`onReset`** is **required**: a row cannot be built without the thing a double-click on its
    ///     name should do. It is the card's job to say *what* the default is (`ToneRow.defaultValue`,
    ///     `DetailAxis`'s body baseline, as-shot for 色温/色调), and `PanelResets`' job to write it.
    ///   · **the number's format** is the row's own (`%.2f EV`, `%.0f`, …) for display; while editing it
    ///     shows the clean number, so what the user types back is what the document holds.
    ///
    /// `shape` is 派单 046's only visual switch: `.bar` for the decoder parameters (降噪 / 色彩降噪 /
    /// 细节 / 锐化), `.knob` for everything that acts on the already-decoded render (Light, Color,
    /// 白平衡). 055 made them **one control**: both are `NSSlider`, and `.bar` only swaps the knob's
    /// drawing for a 10×16 pt bubble plus `focusRingType = .none` (`BubbleSlider`). Both draw the
    /// **same row**: label, number, double-click reset and the `onEditingChanged` contract are this
    /// function's, not the control's, so a shape can never grow a different behaviour.
    ///
    /// There is deliberately **no `step:` parameter**. SwiftUI's `Slider` draws tick marks the moment
    /// it is handed one, and 046 forbids ticks on every slider; any quantization belongs to the model
    /// (`DetailSettings.setPosition` rounds to 1 unit), which is why the knob is built from the
    /// `step`-free initializer and `BubbleSlider` keeps `numberOfTickMarks` at 0.
    private func sliderRow(_ title: String,
                           _ value: Binding<Double>,
                           _ range: ClosedRange<Double>,
                           _ format: String,
                           shape: SliderShape = .knob,
                           style: SliderRowStyle = .standard,
                           editable: Bool = true,
                           accessibilityID: String? = nil,
                           onReset: @escaping () -> Void,
                           onEditingChanged: @escaping (Bool) -> Void) -> some View {
        VStack(alignment: .leading, spacing: style.rowSpacing) {
            HStack(spacing: style.headSpacing) {
                Text(title)
                    .font(.system(size: style.labelSize, weight: style.labelWeight))
                    .foregroundStyle(.secondary)
                    .modifier(ResetOnDoubleClick(action: onReset, help: Self.resetParameterHelp))
                Spacer(minLength: 4)
                if editable {
                    SliderNumberField(value: value.wrappedValue,
                                      range: range,
                                      format: format,
                                      fontSize: style.readoutSize,
                                      accessibilityID: accessibilityID,
                                      onCommit: { typed in
                                          // The drag's own path, in the drag's own order: write through
                                          // the binding, then the gesture-end commit. One typed value =
                                          // one `applyEdit` + one `commitEdit` = one history entry.
                                          value.wrappedValue = typed
                                          onEditingChanged(false)
                                      })
                } else {
                    Text(Self.sliderText(format, value.wrappedValue))
                        .font(.system(size: style.readoutSize, design: .monospaced))
                        .foregroundStyle(.primary)
                }
            }
            switch shape {
            case .bar:
                // 055: decoder parameter — the *same* NSSlider as `.knob`, with only its knob drawn as
                // a 10×16 pt rounded bubble and the focus ring switched off. No step, no ticks (046).
                BubbleSlider(value: value, range: range, onEditingChanged: onEditingChanged)
                    .frame(height: SliderValueMap.rowHeight)
            case .knob:
                // Render parameter: the system slider, **without** `step:` — a step draws ticks.
                Slider(value: value, in: range, onEditingChanged: onEditingChanged)
                    .controlSize(style.controlSize)
                    .frame(height: SliderValueMap.rowHeight)
            }
        }
    }

    /// One slider's readout, with the negative zero taken out.
    ///
    /// `String(format: "%.0f", -0.4)` is `"-0"`, so a control parked a hair below zero read `-0`
    /// while it was, for every practical purpose, at zero (the same for `"%.2f"` → `"-0.00"`).
    /// Anything whose formatted form is zero must come out unsigned: the panel says `0`, never `-0`.
    static func sliderText(_ format: String, _ value: Double) -> String {
        let text = String(format: format, value)
        let digits = text.drop { $0 == "-" }
        if !digits.isEmpty, digits.allSatisfy({ $0 == "0" || $0 == "." }) {
            return String(digits)
        }
        return text
    }

    /// A slider binding that writes through the session, so every tick is observed by the loupe.
    private func binding(_ keyPath: WritableKeyPath<EditModel, Double>) -> Binding<Double> {
        Binding(get: { session.edit[keyPath: keyPath] },
                set: { newValue in
                    session.applyEdit { $0[keyPath: keyPath] = newValue }
                })
    }

    // MARK: white balance (派单 006 / 009)

    /// One white-balance row: the axis it drives, its travel and its number format.
    ///
    /// 047: the card iterates this instead of calling `whiteBalanceRow` twice, so the two rows carry
    /// the same three interactions as every other row in the panel — and a test can hold the table
    /// (`PanelEditingTests`) rather than a rendered tree.
    public struct WhiteBalanceRow: Equatable {
        public var title: String
        public var isTemperature: Bool
        public var range: ClosedRange<Double>
        public var format: String
        /// 047: typeable, like every other row (no card opts out).
        public var editable: Bool = true
    }

    /// 色温 / 色调, in display order — Kelvin first, as the decoder takes them.
    public static let whiteBalanceRows: [WhiteBalanceRow] = [
        WhiteBalanceRow(title: "色温", isTemperature: true,
                        range: WhiteBalance.temperatureRange, format: "%.0f K"),
        WhiteBalanceRow(title: "色调", isTemperature: false,
                        range: WhiteBalance.tintRange, format: "%+.0f"),
    ]

    /// The file's own white balance, as the decode reported it. `nil` until the first development
    /// lands (`session.capabilities`), which is why the row can say "as shot" without a number.
    private var asShotWhiteBalance: WhiteBalance {
        session.capabilities?.asShotWhiteBalance ?? .asShot
    }

    /// The document's pair, which is what the menu and the dropper reason about.
    private var documentWhiteBalance: WhiteBalance { session.edit.light.whiteBalance }

    private var commands: WhiteBalanceCommands {
        WhiteBalanceCommands(session: session,
                             asShot: loupe?.asShotWhiteBalance
                                 ?? session.capabilities?.asShotWhiteBalance)
    }

    /// The menu (派单 009 B).
    ///
    /// Selection is *derived* from the document, never stored: a dragged pair matches no preset and
    /// the picker therefore lands on `自定义`, which is exactly the honesty the task asks for. The
    /// `lastPresetID` tie-break only decides between two presets that carry the same numbers.
    private var presetRow: some View {
        HStack(spacing: 6) {
            Text("预设")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Picker("预设", selection: Binding(
                get: { WhiteBalancePresets.match(documentWhiteBalance,
                                                 preferred: lastPresetID)?.id ?? WhiteBalanceCommands.customID },
                set: { id in applyPreset(id) })) {
                ForEach(WhiteBalancePresets.all) { preset in
                    Text(menuTitle(for: preset)).tag(preset.id)
                }
                Text("自定义").tag(WhiteBalanceCommands.customID)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.mini)
            .frame(maxWidth: 150)
        }
    }

    /// `原照设置 · 5872 K` for as shot (the number is the file's, the state is the word), plain names
    /// for everything else.
    private func menuTitle(for preset: WhiteBalancePreset) -> String {
        guard preset.kind == .asShot else { return preset.name }
        guard let t = asShotWhiteBalance.temperature else { return preset.name }
        return String(format: "%@ · %.0f K", preset.name, t)
    }

    /// 色温 / 色调: absolute Kelvin and tint, in the decoder's coordinates (派单 006).
    ///
    /// Two rules the other rows do not have, both because this is a *decode* control:
    ///
    ///  · **The number shown is the file's** while the document is as shot (`nil`), read from the
    ///    decode, not the nominal 6500 the panel used to print for every photo. An explicit value
    ///    wins as soon as one exists; "as shot" next to the title is the state, not a hint.
    ///  · **Drag ≠ decode.** A tick only moves `@State`; release quantizes (25 K / 1 tint) and
    ///    writes the document once. Committing per tick would queue a ~762 ms development per pixel
    ///    of slider travel, and the pixels could never keep up with the thumb anyway.
    ///
    /// 047 makes the two rows one table (`whiteBalanceRows`) and gives them the panel's three common
    /// interactions: the number is typeable (`commitWhiteBalanceValue` — the same quantization and the
    /// same as-shot fold as a drag release), double-clicking the name puts **that axis** back to as
    /// shot, and double-clicking the card's title puts both back (`PanelResets.group(.whiteBalance)`).
    private func whiteBalanceRow(_ row: WhiteBalanceRow) -> some View {
        let isTemperature = row.isTemperature
        let stored = isTemperature ? session.edit.light.temperature : session.edit.light.tint
        let draft = isTemperature ? draftTemperature : draftTint
        let shot = isTemperature ? asShotWhiteBalance.temperature : asShotWhiteBalance.tint
        // Only a fallback for "no decode yet": the file's value, never a claim about the photo.
        let shown = draft ?? stored ?? shot ?? (isTemperature ? 6500 : 0)

        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(row.title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .modifier(ResetOnDoubleClick(
                        action: { resets.whiteBalanceField(isTemperature: isTemperature) },
                        help: Self.resetParameterHelp))
                if stored == nil {
                    Text("as shot")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 4)
                SliderNumberField(value: shown,
                                  range: row.range,
                                  format: row.format,
                                  fontSize: 10,
                                  width: 52,
                                  accessibilityID: "inspector.whiteBalance.\(row.title)",
                                  onCommit: { typed in
                                      commitWhiteBalanceValue(typed, isTemperature: isTemperature)
                                  })
            }
            // 046: 色温/色调 **会重新解码 RAW**（写 `CIRAWFilter` 的 temperature/tint），所以按规则
            // 用长条形；曝光/对比那些只跑渲染的才是圆球。两者的 label / 数值 / 抬起才提交的语义完全相同。
            // 055: 长条形与圆球现在是同一个控件（`NSSlider`），这里只是拖动点画成气泡。
            BubbleSlider(value: Binding(get: { shown },
                                        set: { newValue in
                                            if isTemperature { draftTemperature = newValue }
                                            else { draftTint = newValue }
                                        }),
                         range: row.range) { editing in
                // Release = quantize + one document write = one development (`commitWhiteBalance`).
                if !editing { commitWhiteBalance(isTemperature: isTemperature) }
            }
            .frame(height: 16)
        }
    }

    /// The dropper (派单 009 C): arm, then the next canvas click samples the **decode buffer**.
    private var dropperRow: some View {
        HStack(spacing: 6) {
            Button {
                toggleEyedropper()
            } label: {
                Image(systemName: "eyedropper")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .disabled(loupe == nil)
            .help("吸管：点击画布上的中性灰取样（Esc 取消）")
            .accessibilityIdentifier("inspector.whiteBalance.eyedropper")
            .foregroundStyle(eyedropperArmed ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))

            Text(eyedropperArmed ? "点击画布取样 · Esc 取消" : "吸管")
                .font(.system(size: 10))
                .foregroundStyle(eyedropperArmed ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            Spacer(minLength: 4)
        }
    }

    // MARK: actions

    private func toggleEyedropper() {
        guard let loupe else { return }
        if eyedropperArmed {
            loupe.cancelEyedropper()
            eyedropperArmed = false
            hint = nil
            return
        }
        eyedropperArmed = true
        hint = "点击画布上的中性灰取样…"
        loupe.armEyedropper { outcome in applyDropper(outcome) }
    }

    /// The dropper's answer: solve, write once, report the numbers it acted on.
    private func applyDropper(_ outcome: LoupeController.DropperOutcome) {
        switch outcome {
        case .sampled(let sample):
            eyedropperArmed = false
            guard let solve = commands.applyDropper(sample.rgb) else {
                hint = "吸管：取样点几乎无颜色信息，未写入"
                return
            }
            lastPresetID = nil
            hint = String(format: "吸管 %@ · %@ · 取样前 RGB %@%@",
                          sample.text, solve.whiteBalance.summary, sample.rgb.text,
                          solve.clamped ? " · 已到量程边界（近似）" : "")
        case .outsideImage, .notReady:
            // No document write, and the tool stays armed on a miss (the loupe keeps it armed too).
            eyedropperArmed = loupe?.isEyedropperArmed ?? false
            hint = outcome.hint
        }
    }

    private func applyPreset(_ id: String) {
        guard id != WhiteBalanceCommands.customID else { return }
        guard let preset = WhiteBalancePresets.preset(id: id) else { return }
        switch preset.kind {
        case .asShot:
            commands.resetToAsShot()
            lastPresetID = preset.id
            hint = "原照设置 · 交给解码器（不写温度/色调）"
        case .fixed:
            guard let wb = preset.whiteBalance else { return }
            commands.commit(wb, label: "预设 \(preset.name)")
            lastPresetID = preset.id
            hint = "\(preset.name) · \(preset.valueText)"
        case .auto:
            guard let average = loupe?.averageSceneRGB() else {
                hint = "自动白平衡：画面尚未就绪，未写入"
                return
            }
            guard let solve = commands.applyAuto(average) else {
                hint = "自动白平衡：画面没有可用的颜色信息，未写入"
                return
            }
            lastPresetID = preset.id
            hint = String(format: "自动（灰世界）· %@ · 画面均值 RGB %@%@",
                          solve.whiteBalance.summary, average.text,
                          solve.clamped ? " · 已到量程边界（近似）" : "")
        }
    }

    /// The one place a white-balance drag becomes a document change.
    ///
    /// Quantization is the contract (`WhiteBalance.quantized()`: 25 K, 1 tint), and so is the
    /// round-trip home: a value within half a step of the file's as-shot becomes `nil` again, because
    /// pinning `5875` for a 5871.6 K shot would re-decode to *slightly different* pixels — the
    /// decoder's as-shot state is not reproducible by assigning the number it reports.
    private func commitWhiteBalance(isTemperature: Bool) {
        defer {
            if isTemperature { draftTemperature = nil } else { draftTint = nil }
        }
        guard let draft = isTemperature ? draftTemperature : draftTint else { return }
        commitWhiteBalanceValue(draft, isTemperature: isTemperature)
    }

    /// The one place a white-balance *number* becomes a document change — shared by a drag's release
    /// and by a typed value (047), so both quantize (25 K / 1), both fold a value that lands on the
    /// file's own back to `nil` (assigning the reported Kelvin is not a no-op: 派单 006 measured
    /// 0.15–0.40 % of samples moving), and both write exactly one snapshot.
    private func commitWhiteBalanceValue(_ value: Double, isTemperature: Bool) {
        var wb = WhiteBalance(temperature: isTemperature ? value : session.edit.light.temperature,
                              tint: isTemperature ? session.edit.light.tint : value).quantized()
        let shot = asShotWhiteBalance
        if isTemperature, let v = wb.temperature, let s = shot.temperature,
           abs(v - s) <= WhiteBalance.temperatureStep / 2 {
            wb.temperature = nil
        }
        if !isTemperature, let v = wb.tint, let s = shot.tint, abs(v - s) <= WhiteBalance.tintStep / 2 {
            wb.tint = nil
        }
        commands.commit(wb, label: isTemperature ? "色温" : "色调")
        lastPresetID = nil
        hint = nil
    }

    // MARK: 派单 047: the panel's resets

    /// The panel's reset verbs, as one value (the `WhiteBalanceCommands` pattern): the view calls them
    /// on a double-click, the tests call them directly — the same code either way.
    private var resets: PanelResets { PanelResets(session: session, loupe: loupe) }

    private static let resetParameterHelp = "双击复位此参数"
    private static let resetGroupHelp = "双击整组复位"

    /// Double-click on a card's title: the whole card back to its defaults, in one snapshot.
    private func resetGroup(_ group: PanelResets.Group) {
        resets.group(group)
    }

    /// Double-click on 「白平衡」.
    ///
    /// 白平衡 is the one group whose default is not a number in `EditModel.neutral`: its default is *the
    /// file's own balance*, i.e. `nil` on both axes (the user's call, 2026-10-27), which is also a new
    /// development. The slider draft and the menu's selection go with it.
    private func resetWhiteBalance() {
        draftTemperature = nil
        draftTint = nil
        guard resets.group(.whiteBalance) else { return }
        lastPresetID = WhiteBalancePresets.asShot.id
        hint = "原照设置 · 交给解码器（不写温度/色调）"
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 1)
    }
}

/// What the 细节 card draws, in order (派单 040).
///
/// Four rows and nothing else: the card used to end with a line of decoder prose (「解码参数 · v9 ·
/// 0 = 系统默认」) and a second label per row (「基线 0.50」). Both are gone, and making the rows data
/// is what lets a test hold the card's entire text surface instead of a screenshot.
public struct DetailCardContent: Equatable, Sendable {

    public struct Row: Equatable, Sendable {
        public var axis: DetailAxis
        /// The row's label — also the undo label for one drag.
        public var title: String
        /// The slider's travel (0…100 for all four).
        public var range: ClosedRange<Double>
        /// The number's format: integers, no percent sign.
        public var format: String
        /// The quantization the **model** applies (1 unit = 0.01 of a `CIRAWFilter` amount).
        ///
        /// 046: this is never handed to a `Slider` — a `step:` makes SwiftUI draw tick marks, and no
        /// slider in this panel has them. `DetailSettings.setPosition` is what rounds.
        public var step: Double
        /// 046: a decoder parameter, so the row draws the **bar** — not the round knob.
        public var shape: SliderShape
        /// 047: typeable, like every other row (no card opts out).
        public var editable: Bool = true
    }

    public var rows: [Row]

    public init(rows: [Row]) { self.rows = rows }

    /// The shipped card: the four axes of `DetailAxis.panelOrder`, one travel, one format, one shape.
    public static let standard = DetailCardContent(
        rows: DetailAxis.panelOrder.map {
            Row(axis: $0, title: $0.title, range: DetailSettings.range,
                format: DetailSettings.format, step: DetailSettings.step, shape: .bar)
        })
}

/// Double-click on a row's label = back to that slider's default (派单 040 / 047).
///
/// A `nil` action leaves the label a plain label. Every row of a *parameter* card passes one (047 made
/// the parameter required in `sliderRow`, so a new card cannot forget it): for a tone or color row the
/// default is the field's own value in `EditModel.neutral`, for a 细节 row it is the *body's* baseline
/// position (50 on a Leica for colour NR — never a nominal 0), for 色温/色调 it is as shot.
///
/// The card titles use it too, with `help` pointing at the group verb instead of the parameter one.
private struct ResetOnDoubleClick: ViewModifier {
    let action: (() -> Void)?
    var help: String = "双击复位此参数"

    func body(content: Content) -> some View {
        if let action {
            content
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { action() }
                .help(help)
        } else {
            content
        }
    }
}

// MARK: - 派单 047: typing a number into a row

/// What a row's number accepts, and what a typed value means.
///
/// Kept out of the view for the same reason `SliderRowStyle` and `DetailCardContent` are values: the
/// rules are the contract, and a rule a test can call is a rule that cannot rot silently. `swift test`
/// has no window session (the accessibility tree is empty, SwiftUI makes no `NSTextField` to poke), so
/// the keystroke *wiring* is pinned on `SliderNumberField`'s source in `PanelEditingTests` while
/// everything below is asserted directly.
enum SliderValueInput {

    /// The two outcomes a submitted string can have.
    enum Outcome: Equatable {
        /// A number, already clamped into the row's travel — write it, then commit (one snapshot).
        case value(Double)
        /// Not a number: beep, put the old number back, write **nothing** (no edit, no history).
        case rejected
    }

    /// `12`, `-3`, `0.5`, `.5`, `-0.25`, `007` are numbers; `abc`, `""`, `  `, `--3`, `+3`, `1,5`,
    /// `1.2.3`, `nan`, `inf` are not.
    ///
    /// The rule is the task's, literally: digits, an optional leading sign, an optional decimal point —
    /// nothing else. It is deliberately **not** `Double(text)`: that accepts `+3`, `1e5` and `nan`, and
    /// a row that silently turned `nan` into a document value would poison a cache key.
    static func parse(_ text: String) -> Double? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        var seenDot = false
        var digits = 0
        for (offset, ch) in t.enumerated() {
            switch ch {
            case "-" where offset == 0 && t.count > 1:
                continue
            case "." where !seenDot:
                seenDot = true
            case "0"..."9":
                digits += 1
            default:
                return nil
            }
        }
        guard digits > 0, let v = Double(t), v.isFinite else { return nil }
        return v
    }

    /// The number as the field shows it **while editing**: no unit, no leading `+`, no padding, and no
    /// `format` — `%.0f` would turn a typed `0.5` into `0` on the way back in (047 forbids exactly that
    /// truncation: typed `0.5` must read back as `0.5`).
    static func editingText(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        if value == 0 { return "0" }                                  // also −0
        if value == value.rounded(), abs(value) < 1e9 { return String(format: "%.0f", value) }
        return String(format: "%.6g", value)
    }

    /// A submitted string, in the row's own travel.
    ///
    /// Out-of-range numbers are **clamped**, not rejected: a slider's travel is a fact about the
    /// control, and refusing `12` in a ±5 EV row would leave the user with a beep and no explanation.
    static func resolve(_ text: String, in range: ClosedRange<Double>) -> Outcome {
        guard let v = parse(text) else { return .rejected }
        return .value(min(max(v, range.lowerBound), range.upperBound))
    }
}

/// One row's number: a readout that turns into a text field (派单 047).
///
/// Always a `TextField` — a `Text` plus an `onTapGesture` would give the mouse an entry and the keyboard
/// none (`Tab` reaches a control, not a label). What changes on focus is the *text*: the row's own
/// format while resting (`5872 K`, `+0.50 EV`), the clean number while editing (`5872`, `-0.50`), so the
/// user types what the document will hold.
///
/// The three exits are the task's three: `↵` commits, `Esc` cancels (old value back, no write), losing
/// focus commits. A rejected string beeps **and** restores — and because `onCommit` is never called, no
/// `applyEdit` and no `commitEdit` happen, which is the "非法输入不写历史" contract.
struct SliderNumberField: View {
    let value: Double
    let range: ClosedRange<Double>
    let format: String
    var fontSize: CGFloat = 10
    var width: CGFloat = 40
    var accessibilityID: String?
    /// Write + commit: the row's own path, so a typed value is one history entry exactly like a drag.
    let onCommit: (Double) -> Void

    @State private var text: String = ""
    @State private var editing = false
    @FocusState private var focused: Bool

    private var display: String { InspectorView.sliderText(format, value) }

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .multilineTextAlignment(.trailing)
            .font(.system(size: fontSize, design: .monospaced))
            .foregroundStyle(editing ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
            .frame(width: width)
            .focused($focused)
            .onAppear { text = display }
            .onChange(of: value) { _, _ in if !editing { text = display } }
            .onChange(of: focused) { _, isFocused in
                if isFocused { begin() } else if editing { commit() }
            }
            .onSubmit { commit(); focused = false }
            .onExitCommand { cancel() }
            .accessibilityIdentifier(accessibilityID ?? "")
            .help("点击数值可键盘输入：↵ 提交 · Esc 取消 · 失焦提交")
    }

    /// Focus gained: swap the formatted readout for the clean number.
    private func begin() {
        guard !editing else { return }
        editing = true
        text = SliderValueInput.editingText(value)
    }

    /// `↵` or blur: write it (which commits once), or beep and put the old number back.
    private func commit() {
        guard editing else { return }
        switch SliderValueInput.resolve(text, in: range) {
        case .value(let typed):
            editing = false
            text = InspectorView.sliderText(format, typed)   // what the model is about to hold
            onCommit(typed)
        case .rejected:
            NSSound.beep()
            editing = false
            text = display
        }
    }

    /// `Esc`: nothing written, not even a beep — the user asked to leave.
    private func cancel() {
        editing = false
        text = display
        focused = false
    }
}

// MARK: - the section's verbs

/// Everything the white-balance section can *do*, without SwiftUI (派单 009).
///
/// Three properties, and each one is a contract the tests hold:
///
///   1. **One write = one history snapshot.** `commitEdit` is called exactly once per user act, so
///      ⌘Z takes a preset or a dropper away in one press (the same rule the sliders follow).
///   2. **One write = one development.** The pair lands in `light.temperature/tint`, which since 006
///      is the *decoder's* input and part of the rung identity — so the loupe develops again instead
///      of re-tinting a stale buffer in S1 (identity there).
///   3. **As shot is `nil`, not a number.** Nothing here invents 6500 K: 原照设置 clears both fields,
///      which is the state that leaves `CIRAWFilter` alone.
@MainActor
public struct WhiteBalanceCommands {

    /// The picker's tag for "no preset matches" — a state, not a menu action.
    public static let customID = "custom"

    public let session: CatalogSession
    /// The file's as-shot pair, when the caller has a decode to ask (the loupe's resident buffer).
    /// Preferred over `session.capabilities` because it is the pair *this* buffer was made with.
    public let asShot: WhiteBalance?

    public init(session: CatalogSession, asShot: WhiteBalance? = nil) {
        self.session = session
        self.asShot = asShot
    }

    /// Write a pair (quantized), one history snapshot, with a label for the undo strip.
    ///
    /// Unlike the slider release this does **not** fold a value that lands within half a step of the
    /// file's as shot back to `nil`: a preset or a dropper sample is a stated intent ("this is the
    /// illuminant"), and silently turning 日光 into "as shot" on a 5500 K file would make the menu
    /// contradict the click. The slider keeps the fold, because there the user's thumb — not a
    /// preset — produced the number.
    @discardableResult
    public func commit(_ whiteBalance: WhiteBalance, label: String) -> WhiteBalance {
        let wb = whiteBalance.quantized()
        session.applyEdit { model in
            model.light.temperature = wb.temperature
            model.light.tint = wb.tint
        }
        session.commitEdit(label: label)
        return wb
    }

    /// 原照设置: both fields `nil`, one snapshot. An already-as-shot document is left alone
    /// (`EditHistory.commit` refuses an unchanged snapshot), so no phantom history entry appears.
    @discardableResult
    public func resetToAsShot() -> Bool {
        guard !session.edit.light.whiteBalance.isAsShot else { return false }
        session.applyEdit { model in
            model.light.temperature = nil
            model.light.tint = nil
        }
        session.commitEdit(label: "原照设置")
        return true
    }

    /// The eyedropper's whole document effect: solve the sample, write it once (派单 009 C).
    ///
    /// `nil` when the sample carries no colour (near-black, or a channel at zero) — in that case the
    /// document is **not** touched, which is the difference between "the dropper refused" and "the
    /// dropper wrote a guess". The caller prints the hint either way.
    @discardableResult
    public func applyDropper(_ sample: RGBSample, label: String = "吸管白平衡") -> WhiteBalanceSolve? {
        guard let solve = WhiteBalanceSolver.neutral(for: sample, reference: reference) else { return nil }
        commit(solve.whiteBalance, label: label)
        return solve
    }

    /// 自动: the same solve against the picture's mean colour (grey-world).
    @discardableResult
    public func applyAuto(_ average: RGBSample, label: String = "自动白平衡") -> WhiteBalanceSolve? {
        guard let solve = WhiteBalanceSolver.auto(forAverage: average, reference: reference) else {
            return nil
        }
        commit(solve.whiteBalance, label: label)
        return solve
    }

    /// The illuminant the buffer on screen was decoded under — the baseline the solve is relative to.
    ///
    /// The document's own pair when it has one, otherwise the file's as shot (派单 006's `nil`). The
    /// `6500 / 0` fallback inside `Reference` only fires before the first development, where there is
    /// no buffer to sample anyway.
    public var reference: WhiteBalanceSolver.Reference {
        let current = session.edit.light.whiteBalance
        if !current.isAsShot { return WhiteBalanceSolver.Reference(current) }
        return WhiteBalanceSolver.Reference(asShot ?? session.capabilities?.asShotWhiteBalance ?? .asShot)
    }
}

// MARK: - 派单 047: the panel's resets

/// Everything a double-click on a name or a card title *does*, without SwiftUI.
///
/// Same shape and same reason as `WhiteBalanceCommands`: the panel and the tests call one
/// implementation, so "复位" cannot mean one thing on screen and another in a test.
///
/// Three properties, and each is a contract the tests hold:
///
///   1. **A default is a field's own default, never a literal.** Tone and color fields are read out of
///      `EditModel.neutral` (the group's default initializer), 细节 fields go back to `nil` — "stop at
///      this body's baseline position", which is `0/50/0/50` on a Leica and not 0 — and 色温/色调 go
///      back to `nil`, i.e. as shot. Hard-coding `0` anywhere here would switch Apple's colour noise
///      reduction off (031) or claim an illuminant the file never had (006).
///   2. **One act = one snapshot.** `group(_:)` writes every field inside **one** `applyEdit` and ends
///      with **one** `commitEdit`, so ⌘Z takes the whole card back in one press. Committing per field
///      would give a double-click six history entries — the failure `PanelResetTests` keeps a negative
///      control for.
///   3. **Nothing changed = nothing written.** Every verb returns `false` and writes no snapshot when
///      the document is already at the default, so a stray double-click cannot truncate the redo branch.
@MainActor
public struct PanelResets {

    /// The cards that have a "default" to go back to.
    ///
    /// 蒙版 is deliberately absent: a mask is a *list*, not a group of numbers, so there is no whole-card
    /// default (047's table says the same). Its individual parameters are resettable in its own panel.
    public enum Group: String, CaseIterable, Sendable {
        case whiteBalance
        case light
        case color
        case detail

        /// The card title this group is — the name the user double-clicked, and the undo label.
        public var title: String {
            switch self {
            case .whiteBalance: return InspectorView.Section.whiteBalance.title
            case .light: return InspectorView.Section.light.title
            case .color: return InspectorView.Section.color.title
            case .detail: return InspectorView.Section.detail.title
            }
        }
    }

    public let session: CatalogSession
    /// The loupe, when there is one: a 细节 reset also ends the preview-rung adjustment, so the frame
    /// develops full size at the settle (031's rule, which the single-parameter reset already followed).
    public let loupe: LoupeController?

    public init(session: CatalogSession, loupe: LoupeController? = nil) {
        self.session = session
        self.loupe = loupe
    }

    // MARK: one parameter

    /// Double-click on a row's name: that field back to its own default. One snapshot; `false` when it
    /// was already there.
    @discardableResult
    public func field(_ keyPath: WritableKeyPath<EditModel, Double>, label: String) -> Bool {
        let fallback = EditModel.neutral[keyPath: keyPath]
        guard session.edit[keyPath: keyPath] != fallback else { return false }
        session.applyEdit { $0[keyPath: keyPath] = fallback }
        return session.commitEdit(label: label)
    }

    /// Double-click on 降噪 / 色彩降噪 / 细节 / 锐化: back to **this body's default position**.
    ///
    /// `nil` is the only honest spelling of that position: the number differs per body (Leica 50, R5
    /// sharpness 100, Sony luminance NR 38), so the document stores "untouched" and the decoder keeps
    /// Apple's own amount. One snapshot, and the loupe is told the adjustment is over.
    @discardableResult
    public func detail(_ axis: DetailAxis) -> Bool {
        guard session.edit.detailSettings[axis] != nil else { return false }
        session.applyEdit { $0.detailSettings[axis] = nil }
        let committed = session.commitEdit(label: axis.title)
        loupe?.endDetailAdjustment()
        return committed
    }

    /// Double-click on 色温 or 色调: **that axis** back to as shot (`nil`). The other axis keeps whatever
    /// it holds — a document is allowed to pin Kelvin and follow the file's tint.
    @discardableResult
    public func whiteBalanceField(isTemperature: Bool) -> Bool {
        let current = session.edit.light.whiteBalance
        let stored = isTemperature ? current.temperature : current.tint
        guard stored != nil else { return false }
        let next = isTemperature ? WhiteBalance(temperature: nil, tint: current.tint)
                                 : WhiteBalance(temperature: current.temperature, tint: nil)
        session.applyEdit { model in
            model.light.temperature = next.temperature
            model.light.tint = next.tint
        }
        return session.commitEdit(label: isTemperature ? "色温" : "色调")
    }

    // MARK: a whole card

    /// Double-click on a card's title: the whole card back to its defaults in **one** snapshot.
    @discardableResult
    public func group(_ group: Group) -> Bool {
        switch group {
        case .whiteBalance:
            // 原照设置: both fields `nil` = "leave the decoder's own balance alone". This is the one
            // group whose default is the *file's*, not the document's, and it re-develops the RAW.
            return WhiteBalanceCommands(session: session, asShot: loupe?.asShotWhiteBalance)
                .resetToAsShot()

        case .light:
            // The card's own scope, taken from the card's own table (`lightRows`) plus the two absolute
            // levels — so adding a seventh slider to Light resets it without touching this function.
            let rows = InspectorView.lightRows
            let neutral = EditModel.neutral
            let levels = LightGroup.identity
            let changed = rows.contains {
                session.edit[keyPath: $0.keyPath] != neutral[keyPath: $0.keyPath]
            } || session.edit.light.blackLevel != levels.blackLevel
              || session.edit.light.whiteLevel != levels.whiteLevel
            guard changed else { return false }
            session.applyEdit { model in
                for row in rows { model[keyPath: row.keyPath] = neutral[keyPath: row.keyPath] }
                // 030: "the sliders' mapping is in force again" is `nil`, not 0 / 1.
                model.light.blackLevel = levels.blackLevel
                model.light.whiteLevel = levels.whiteLevel
            }
            // 白平衡 is *not* in this group: it is its own card and its own double-click. One
            // `applyEdit` + one `commitEdit` = one snapshot, which is the whole point.
            return session.commitEdit(label: group.title)

        case .color:
            guard session.edit.color != ColorGroup.identity else { return false }
            session.applyEdit { $0.color = .identity }
            return session.commitEdit(label: group.title)

        case .detail:
            // All four `nil` = 停在机身的基线位置 (0/50/0/50 on a Leica) — *not* 0, which would turn
            // Apple's colour noise reduction off and move the pixels.
            guard !session.edit.detailSettings.isIdentity else { return false }
            session.applyEdit { $0.detailSettings = .identity }
            let committed = session.commitEdit(label: group.title)
            loupe?.endDetailAdjustment()
            return committed
        }
    }
}
