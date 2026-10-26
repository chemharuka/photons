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
    private var lightCard: some View {
        card(Section.light.title) {
            row("曝光", \.light.exposure, -5 ... 5, "%.2f EV")
            row("对比", \.light.contrast, -100 ... 100, "%.0f")
            row("高光", \.light.highlights, -100 ... 100, "%.0f")
            row("阴影", \.light.shadows, -100 ... 100, "%.0f")
            row("白色", \.light.whites, -100 ... 100, "%.0f")
            row("黑色", \.light.blacks, -100 ... 100, "%.0f")
        }
    }

    /// 白平衡 (派单 009): preset menu, the two absolute sliders, and the dropper.
    ///
    /// The whole section is one idea — *what is neutral?* — and its three controls are three answers:
    /// a known illuminant (menu), a number (sliders), or a sample (dropper). All three end in the same
    /// place: one `commitWhiteBalance` → one history snapshot → one development.
    private var whiteBalanceCard: some View {
        card(Section.whiteBalance.title) {
            presetRow
            divider
            whiteBalanceRow("色温", isTemperature: true)
            whiteBalanceRow("色调", isTemperature: false)
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
        card(Section.color.title) {
            row("自然饱和", \.color.vibrance, -100 ... 100, "%.0f")
            row("饱和", \.color.saturation, -100 ... 100, "%.0f")
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
        return card(Section.detail.title) {
            ForEach(Self.detailContent.rows, id: \.axis) { row in
                // 047: **no `step:`** — SwiftUI draws tick marks along any `Slider` that has one, and
                // the owner wants these four to look like every other slider in the inspector. The
                // snapping is not lost: `DetailSettings.setPosition` quantizes to `step` (1 unit) on
                // the way in, so the document still only ever holds whole numbers.
                sliderRow(row.title,
                          detailBinding(row.axis, baseline: baseline),
                          row.range,
                          row.format,
                          step: nil,
                          editable: true,
                          accessibilityID: "inspector.detail.\(row.axis.rawValue)",
                          onReset: { resetDetail(row.axis) },
                          onSubmit: { commitDetail(title: row.title) }) { editing in
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
    private func resetDetail(_ axis: DetailAxis) {
        guard session.edit.detailSettings[axis] != nil else { return }
        session.applyEdit { $0.detailSettings[axis] = nil }
        session.commitEdit(label: "复位")
        loupe?.endDetailAdjustment()
    }

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

    private func card<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.primary)
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

    private func row(_ title: String, _ keyPath: WritableKeyPath<EditModel, Double>,
                     _ range: ClosedRange<Double>, _ format: String) -> some View {
        sliderRow(title, binding(keyPath), range, format) { editing in
            // Drag end = one edit action = one history snapshot (never per tick).
            if !editing { session.commitEdit() }
        }
    }

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

    /// A row: title (double-click resets when `onReset` is given), the number, and the slider.
    ///
    /// `editable` is the one difference the task asks for: the 细节 card has a number you can type
    /// (`onSubmit` writes and commits, so a typed value is one history entry and one development),
    /// the tone cards print theirs. Everything else — fonts, spacing, `controlSize`, the `Slider`
    /// itself — comes from `SliderRowStyle`.
    private func sliderRow(_ title: String,
                           _ value: Binding<Double>,
                           _ range: ClosedRange<Double>,
                           _ format: String,
                           step: Double? = nil,
                           style: SliderRowStyle = .standard,
                           editable: Bool = false,
                           accessibilityID: String? = nil,
                           onReset: (() -> Void)? = nil,
                           onSubmit: (() -> Void)? = nil,
                           onEditingChanged: @escaping (Bool) -> Void) -> some View {
        VStack(alignment: .leading, spacing: style.rowSpacing) {
            HStack(spacing: style.headSpacing) {
                Text(title)
                    .font(.system(size: style.labelSize, weight: style.labelWeight))
                    .foregroundStyle(.secondary)
                    .modifier(ResetOnDoubleClick(action: onReset))
                Spacer(minLength: 4)
                if editable {
                    TextField("", value: value, format: .number.precision(.fractionLength(0)))
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                        .font(.system(size: style.readoutSize, design: .monospaced))
                        .foregroundStyle(.primary)
                        .frame(width: 40)
                        .onSubmit { onSubmit?() }
                        .accessibilityIdentifier(accessibilityID ?? "")
                } else {
                    Text(Self.sliderText(format, value.wrappedValue))
                        .font(.system(size: style.readoutSize, design: .monospaced))
                        .foregroundStyle(.primary)
                }
            }
            if let step {
                Slider(value: value, in: range, step: step, onEditingChanged: onEditingChanged)
                    .controlSize(style.controlSize)
            } else {
                Slider(value: value, in: range, onEditingChanged: onEditingChanged)
                    .controlSize(style.controlSize)
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
    private func whiteBalanceRow(_ title: String, isTemperature: Bool) -> some View {
        let stored = isTemperature ? session.edit.light.temperature : session.edit.light.tint
        let draft = isTemperature ? draftTemperature : draftTint
        let shot = isTemperature ? asShotWhiteBalance.temperature : asShotWhiteBalance.tint
        // Only a fallback for "no decode yet": the file's value, never a claim about the photo.
        let shown = draft ?? stored ?? shot ?? (isTemperature ? 6500 : 0)
        let range = isTemperature ? WhiteBalance.temperatureRange : WhiteBalance.tintRange
        let format = isTemperature ? "%.0f K" : "%+.0f"

        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                if stored == nil {
                    Text("as shot")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 4)
                Text(Self.sliderText(format, shown))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.primary)
            }
            Slider(value: Binding(get: { shown },
                                  set: { newValue in
                                      if isTemperature { draftTemperature = newValue }
                                      else { draftTint = newValue }
                                  }),
                   in: range) { editing in
                // Release = quantize + one document write = one development (`commitWhiteBalance`).
                if !editing { commitWhiteBalance(isTemperature: isTemperature) }
            }
            .controlSize(.mini)
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
        var wb = WhiteBalance(temperature: isTemperature ? draft : session.edit.light.temperature,
                              tint: isTemperature ? session.edit.light.tint : draft).quantized()
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
        /// The slider's step (1 unit = 0.01 of a `CIRAWFilter` amount).
        public var step: Double
    }

    public var rows: [Row]

    public init(rows: [Row]) { self.rows = rows }

    /// The shipped card: the four axes of `DetailAxis.panelOrder`, one travel, one format.
    public static let standard = DetailCardContent(
        rows: DetailAxis.panelOrder.map {
            Row(axis: $0, title: $0.title, range: DetailSettings.range,
                format: DetailSettings.format, step: DetailSettings.step)
        })
}

/// Double-click on a row's label = back to that slider's default (派单 040).
///
/// A `nil` action leaves the label a plain label, so the tone rows keep exactly the behaviour they
/// had; the 细节 rows pass one and get 「双击复位为默认位置」, which for them is the *body's* baseline
/// (50 on a Leica for colour NR), never a nominal 0.
private struct ResetOnDoubleClick: ViewModifier {
    let action: (() -> Void)?

    func body(content: Content) -> some View {
        if let action {
            content
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { action() }
                .help("双击复位为默认位置")
        } else {
            content
        }
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
