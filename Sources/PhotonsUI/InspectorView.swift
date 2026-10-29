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
///
/// 派单 052 adds two facts about that number, and both are per-row data in `ToneRow` so no card can
/// answer differently:
///
///   · **the first keystroke after focus starts the buffer over** (`NumberFieldState.judgeFirstEdit`,
///     asked from the field editor's pre-change callback in `NumberField.swift`) — clicking in and
///     typing `1.5` must not land inside the `1.5` that was already there (`1.1.5`). A first keystroke
///     that *replaces* a text selection is left alone: that is "改一位".
///   · **the readout is not the document.** 曝光 reads `%.2f EV` and stores on a 0.01 grid; the other
///     continuous rows read as integers rounded **away** from zero (`ceil` up, `floor` down — never
///     smaller than the truth) and store what was typed. `ToneRow.rounding` / `.decimals` / `.quantum`
///     are those three answers.
public struct InspectorView: View {

    /// The cards, in display order (派单 009 A).
    ///
    /// `body` builds the stack from `allCases` filtered by the selected **workspace** (派单 073:
    /// `sections(in:)`), so this list **is** the view hierarchy — there is no second, hand-maintained
    /// ordering to drift out of step with what is on screen. A workspace decides *membership*, never
    /// order and never contents: a card that is not in this enum cannot be shown. The tests assert it
    /// (`InspectorView.sectionTitles`, `cardTitles(in:)`) and the rendered order of the card identifiers.
    public enum Section: String, CaseIterable, Identifiable, Hashable {
        /// Histogram first: it is the read-out of the picture the rest of the panel edits.
        case histogram
        /// 白平衡 is its own section, between the histogram and Light (派单 009 A): it is a *decode*
        /// setting (006), not a tone control, and burying it under six sliders misrepresented that.
        case whiteBalance
        /// 派单 071: 黑电平 — the additive linear black trim. Its own card, **directly under 白平衡**
        /// (owner's order, 2026-10-27: 「黑电平移动到白平衡下方」) and **not** a seventh row of Light:
        /// it is the panel's only linear-domain parameter, and 046's row-shape rule is per parameter
        /// class, so a card of its own is what lets it carry the red accent without pretending the six
        /// tone sliders changed colour.
        case blackLevel
        case light
        case color
        /// 派单 076: **HSL** — the eight colour bands, on OKLCh, in the 色彩 workspace.
        ///
        /// Its own card rather than six more rows under Color: the bands are a *selector plus three
        /// sliders*, not a list of independent parameters, and the 色彩 workspace (073) exists to give
        /// them a home of their own. It is the same 24 document numbers Lightroom's HSL panel writes.
        case hsl
        /// 2026-10-28 (P0 色彩分级) — **色彩分级**: 阴影 / 中间调 / 高光, each 色相 + 饱和 + 亮度.
        ///
        /// Directly after HSL, which is the pipeline's own order (`RenderStage.order` is … `.hsl,
        /// .grade, .vignette`): the per-hue bands first, then the per-luminance wheels, then the
        /// effects. Its own card rather than three more rows under Color or nine under HSL for 076's
        /// reason: it is a different partition of the picture (luminance, not hue), its own stage, its
        /// own group and its own double-click — a reset here must not undo a band drag and vice versa.
        ///
        case colorGrading
        /// 2026-10-28 — **黑白** (S3.4): the switch and the eight 黑白混合 rows.
        ///
        /// The user put it **below 色彩分级** in the 色彩 workspace («黑白卡片放在颜色分级下方»), so the
        /// workspace reads HSL → 色彩分级 → 黑白: the two colour-partition cards first, then the switch
        /// that throws the colour away. It is its own card rather than eight more rows under Color for
        /// 076's reason — one switch plus eight dedicated rows is a panel of its own, and a double-click
        /// on Color must not undo work done here. (`RenderStage.order` still runs S3.4 before S3.6/3.8;
        /// the panel's reading order and the pipeline's execution order are separate facts.)
        case blackAndWhite
        /// 派单 051: 曲线 — **above 细节** (2026-10-28, user: 「曲线移动到在细节上方」). The tone controls
        /// shape the picture, so they come before the decoder's amounts; the order inside the panel is
        /// the user's, and the pipeline's own order is a separate fact (`RenderStage.order`).
        case curve
        /// 派单 031: 降噪 / 色彩降噪 / 细节 / 锐化 — four **decoder** amounts, next to Color because they
        /// are the same panel in Lightroom, and below the curve because they act on the decoded pixels
        /// the curve then reprofiles.
        case detail
        /// 2026-10-28 (096): **校正** — 色差 R / 色差 B, moved out of 细节 and placed between
        /// 细节 and 效果 (the user's ask: 「色散从细节中移出，单独放置到校正卡片中，校正卡片目前放在
        /// 「细节」「效果」的中间」). The rows are S0 render parameters, not decoder amounts, so they read
        /// as their own card rather than as a tail of 细节.
        case correction
        /// 2026-10-28: **效果** — 暗角 (S3c) + 颗粒 (S3.7), Lightroom's Effects card.
        ///
        /// After 曲线, and the position is the pipeline's own order rather than a preference:
        /// Light → Color → 细节/解码 → 曲线 → 效果 are the render stages in execution order, and the last
        /// two act on the finished picture (S1.7 bends the scene-linear signal, S3c/S3.7 the
        /// display-referred frame).
        ///
        /// **081 (2026-10-28): the 预设 card is gone.** It was never a parameter card — it wrote the
        /// others — and the user replaced it with a top-level 预设 menu plus the copy sheet's
        /// 保存为预设… (「预设卡片删掉，系统顶部菜单栏出现预设」). Deleting the case rather than hiding it
        /// keeps `Section` the single card list: a card that cannot be shown does not exist.
        case effects
        /// 2026-10-27: 裁切 — the 变换 workspace's **first** card.
        ///
        /// It is a `Section` like every other card (「`Section` 仍然是唯一的卡片清单」), and it is the
        /// only one the 变换 workspace claims. Its position in `allCases` is before 蒙版 for one
        /// reason: 蒙版 has to stay the last card of the enum (`DecoderModelCardTests` holds that, and
        /// the panel's own order says the same), while 裁切 belongs to a workspace of its own and is
        /// therefore invisible in 调整 either way.
        case crop
        /// 087: 变换 — the 变换 workspace's second card (转动 / 旋转 / 镜像), after 裁切.
        /// 093: the card title is 「变换」; `CropSection.angle` keeps its `angle` rawValue.
        case angle
        case masks
        /// 派单 077: 历史记录 — the edit timeline (one row per committed state). The last card, and the
        /// only one that is a *reading* rather than a control: it can jump, and delete the newest row
        /// of a class, and it can never write the document.
        case history

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .histogram: return "直方图"
            case .whiteBalance: return "白平衡"
            case .light: return "Light"
            case .blackLevel: return "黑电平"
            case .color: return "Color"
            case .blackAndWhite: return "黑白"
            case .hsl: return "HSL"
            case .colorGrading: return "色彩分级"
            case .detail: return "细节"
            case .correction: return "校正"
            case .curve: return "曲线"
            case .effects: return "效果"
            case .crop: return "裁切"
            case .angle: return "变换"
            case .masks: return "蒙版"
            // 077: the timeline. Own card, last in the panel order (it reads the *result* of the cards
            // above it, so it belongs under them).
            case .history: return "历史记录"
            }
        }
    }

    /// `["直方图", "白平衡", "Light", …]` — the order the cards appear in, from the one list above.
    public static var sectionTitles: [String] { Section.allCases.map(\.title) }

    /// The cards that live **inside** the scroll view: everything except the pinned histogram.
    ///
    /// Still derived from `allCases` (one list, one order), so excluding a card here cannot silently
    /// disagree with the enum — and `.histogram` is rendered exactly once, from `pinnedColumn`.
    ///
    /// Since 派单 073 this is the **catalogue**, not the visible set: the scroll area shows
    /// `sections(in: workspace)`, a filter of this list. `scrollingSections` stays the full list on
    /// purpose — it answers 「哪些卡会滚动」 (all of them do, in the workspace that owns them), and the
    /// tests that pin a card to the scrolling half (`LightCardTests`, `CurvePanelTests`, …) keep meaning
    /// what they meant.
    public static var scrollingSections: [Section] { Section.allCases.filter { $0 != .histogram } }

    /// **The cards one workspace renders, in panel order** (派单 073).
    ///
    /// `InspectorWorkspace.cards` is the only membership table; the order here is `allCases`', so a
    /// workspace can include or drop a card but never move one. `.histogram` cannot enter this list at
    /// all (`scrollingSections` does not contain it), which is what keeps the histogram pinned above
    /// the switcher in every workspace, empty ones included.
    public static func sections(in workspace: InspectorWorkspace) -> [Section] {
        let included = Set(workspace.cards)
        return scrollingSections.filter { included.contains($0) }
    }

    /// The titles `sections(in:)` draws — what a test can compare against a rendered panel. `[]` for a
    /// workspace whose features do not exist yet (变换 / 色彩 / 历史记录), by design.
    public static func cardTitles(in workspace: InspectorWorkspace) -> [String] {
        sections(in: workspace).map(\.title)
    }

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
    /// 118: the canvas is showing a simulated white balance (dragging, or released and waiting for
    /// the real decode). Kept here rather than read from the loupe on every body pass: the loupe
    /// calls `onWhiteBalancePreviewSettled` when the real frame lands.
    @State private var whiteBalancePreviewing = false

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
    /// The 自动黑电平 icon's hover state: the only thing about it that changes on pointer-over
    /// (no frame, no fill — see `autoBlackLevelButton`).
    @State private var autoBlackHovered = false

    /// **Which cards are on screen** (派单 073).
    ///
    /// View state, like `hint`: the workspace is not a document fact, so it is not in `EditModel`, not in
    /// `EditHistory`, and selecting one writes neither (`InspectorWorkspaceTests` asserts
    /// `editRevision` and `history.count` do not move). Held as a tiny `@Observable` object rather than
    /// a plain `@State` value so a hosted panel can be switched in a test — see `InspectorWorkspaceState`.
    @State private var workspaces: InspectorWorkspaceState

    public init(session: CatalogSession, loupe: LoupeController? = nil,
                workspaces: InspectorWorkspaceState? = nil) {
        self.session = session
        self.loupe = loupe
        // A caller may hand in the state (a test, or a host that wants to remember the workspace); the
        // default is a fresh one, i.e. 调整.
        _workspaces = State(initialValue: workspaces ?? InspectorWorkspaceState())
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            pinnedColumn
            workspaceSwitcher
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(visibleSections) { section in
                        sectionView(section)
                            .accessibilityIdentifier("inspector.card.\(section.rawValue)")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 14)
                // 派单 073: the readback seam and the scroll anchor in one — the probe *is* the
                // document's bounds, so it also reports the card list the panel built.
                .background(alignment: .topLeading) {
                    InspectorCardsProbeHost(workspace: workspaces.selection, sections: visibleSections)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .padding(.top, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.clear)
        .task(id: metadataKey) { reloadMetadata() }
        // 082/086 — entering 变换 opens 裁切 mode (the frame is part of the workspace, not a button),
        // and leaving it cancels the draft (082). Idempotent, so the workspace root's own wiring and
        // this one cannot fight.
        .task { loupe?.setCropWorkspaceActive(workspaces.selection.showsCropCard) }
        .onChange(of: workspaces.selection) { _, workspace in
            loupe?.setCropWorkspaceActive(workspace.showsCropCard)
        }
    }

    /// The cards of the selected workspace, in panel order (派单 073).
    ///
    /// One filter over the one list — **not** an `if` wrapped around each card. A card that belongs to
    /// no workspace would simply never appear, which is why `InspectorWorkspaceTests` asserts the union
    /// of the table covers `scrollingSections` exactly.
    private var visibleSections: [Section] { Self.sections(in: workspaces.selection) }

    /// The icon row: immediately under the histogram card, immediately above the scroll area, outside it
    /// (so it cannot be scrolled away, and so the histogram is never the last pinned thing on screen).
    ///
    /// 20 pt of buttons inside the panel's own 10 pt rhythm — the whole switcher costs 20 pt of panel,
    /// and `layoutPriority(1)` + `fixedSize` keep it from being the thing a short window eats.
    private var workspaceSwitcher: some View {
        InspectorWorkspaceTabs(selection: Binding(get: { workspaces.selection },
                                                 set: { workspaces.select($0) }))
            .padding(.horizontal, 12)
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(1)
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
        case .blackLevel:
            blackLevelCard
        case .color:
            colorCard
        case .blackAndWhite:
            blackAndWhiteCard
        case .hsl:
            hslCard
        case .colorGrading:
            colorGradingCard
        case .detail:
            detailCard
        case .correction:
            correctionCard
        case .curve:
            curveCard
        case .effects:
            effectsCard
        case .crop:
            // 2026-10-27 / 086: 变换工作区的第一张卡 —— 宽高比 / 角度 / 旋转 / 镜像，底部九宫格 +
            // 应用取消；进入工作区即进入裁切模式，卡头没有按钮。卡本身在 `TransformPanel.swift`
            // （同一套行样式，`sliderRow` 一字未改）。
            cropTransformCard
        case .angle:
            // 087: 变换工作区的第二张卡 —— 转动 / 旋转 / 镜像，放在裁切卡之后。
            angleTransformCard
        case .masks:
            MaskListPanel(session: session)
        case .history:
            // 077: the timeline draws its own header and card chrome (the mask list does the same):
            // it needs a count line, and it is not a parameter card with a reset.
            HistoryPanel(session: session)
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
                sliderRow(row.title, binding(row.keyPath, quantum: row.quantum), row.range, row.format,
                          shape: row.shape,
                          decimals: row.decimals,
                          rounding: row.rounding,
                          editable: row.editable,
                          onReset: { resets.field(row.keyPath, label: row.title) }) { editing in
                    // Drag end = one edit action = one history snapshot (never per tick).
                    if !editing { session.commitEdit() }
                }
            }
        }
    }

    /// 派单 071: 黑电平 — one row: the additive linear black trim (±0.01, 1/1000 steps).
    ///
    /// The panel's only `.linear` row (red `#FF375F`): the colour convention 071 set is
    /// **blue = default / yellow = raw/decode / red = linear domain**, and this is the first
    /// parameter that is arithmetic on the scene-linear buffer rather than a render control.
    ///
    /// Everything else is 047/048's row contract, unchanged — the name is the field's reset, the
    /// number is a `SliderNumberField` (type an integer −10…+10, `↵` commits, `Esc` cancels, junk
    /// writes nothing), and double-clicking the card title resets it in one snapshot.
    ///
    /// **The slider's unit is not the document's.** The document stores `slider / 1000` as a Double
    /// (−7 → −0.007), because a 1/1000 trim has to be able to say `0.002`; the row shows the integer.
    /// `blackLevelBinding` is the only translation in the panel, and `LightGroup`'s two mapping
    /// functions are what it translates with — so the number on screen, the number in the key
    /// material and the number the kernel adds are one value.
    private var blackLevelCard: some View {
        InspectorCardShell(title: Section.blackLevel.title,
                           reset: { resets.field(\.light.blackOffset, label: Section.blackLevel.title) },
                           accessory: { autoBlackLevelButton }) {
            ForEach(Self.blackLevelRows, id: \.title) { row in
                sliderRow(row.title, blackLevelBinding(row), row.range, row.format,
                          shape: row.shape,
                          decimals: row.decimals,
                          rounding: row.rounding,
                          editable: row.editable,
                          accessibilityID: "inspector.blackLevel.offset",
                          onReset: { resets.field(row.keyPath, label: row.title) }) { editing in
                    // Drag end = one edit action = one history snapshot (never per tick).
                    if !editing { session.commitEdit() }
                }
            }
        }
    }

    /// 「黑电平」标题行右侧的自动按钮（同一个无框族）：14 pt 的裸 `wand.and.stars`，没有底、没有边、
    /// 没有胶囊，hover 只把图标从 secondary 提到 primary。它落在数值框的正上方、与数值框右缘对齐 ——
    /// 卡头本身就在数值行上方，`Spacer` 把它推到这个卡的右缘。命中区 ≥ 18×18；`−2` 的尾距抵掉
    /// `NSTextField` 单元格向两侧各溢出的 2 pt，让图标的右缘与「数值框」的实际右缘落在同一条线上。
    private var autoBlackLevelButton: some View {
        Button {
            // The action writes through the session and asks for its own development; the row's
            // observed value follows the document, so there is no `@State` copy to update here.
            _ = loupe?.autoBlackOffset()
        } label: {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 14))
                .foregroundStyle(autoBlackHovered ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .frame(width: 20, height: 18)
                .contentShape(Rectangle())
                .background(BlackLevelAutoProbeHost())
        }
        .buttonStyle(.plain)
        .padding(.trailing, -2)
        .onHover { autoBlackHovered = $0 }
        .help("自动黑电平：把解码后的线性数据拉到非负")
        .accessibilityLabel("自动黑电平")
        .accessibilityIdentifier("inspector.blackLevel.auto")
    }

    /// 071: the 黑电平 card's one row, as data like every other row table.
    ///
    /// A `ToneRow` with one thing spelled out: `range` and the number the row shows are the
    /// **slider's** units (integers −10…+10), while `keyPath` is the document's field
    /// (`light.blackOffset`, −0.01…+0.01). `LightGroup.blackOffset(fromSlider:)` and
    /// `blackOffsetSliderPosition` are the conversion — see `blackLevelBinding`.
    ///
    /// The row is named 偏移 and the card 黑电平: the card is the control the user asked for
    /// (「加一个黑电平滑块」), the row is what the number is. Printing 黑电平 twice in a one-row card
    /// is the only alternative, and it reads like a bug.
    public static let blackLevelRows: [ToneRow] = [
        ToneRow(title: "偏移", range: LightGroup.blackOffsetSliderRange, format: "%.1f",
                shape: .linear, keyPath: \.light.blackOffset, decimals: 1, rounding: .asIs),
    ]

    /// 071: slider position ↔ document value. Position lives on a **0.1** grid (−10.0…+10.0, so the
    /// document's 1/1000 tick can be resolved to 1/10 000 of linear light — the owner's 「不是只能
    /// 取整数」); there is no `step:` (046), so the model does the snapping.
    private func blackLevelBinding(_ row: ToneRow) -> Binding<Double> {
        Binding(get: { LightGroup.blackOffsetSliderPosition(of: session.edit.light) },
                set: { position in
                    let offset = LightGroup.blackOffset(fromSlider: position)
                    session.applyEdit { $0[keyPath: row.keyPath] = offset }
                })
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
                sliderRow(row.title, binding(row.keyPath, quantum: row.quantum), row.range, row.format,
                          shape: row.shape,
                          decimals: row.decimals,
                          rounding: row.rounding,
                          editable: row.editable,
                          onReset: { resets.field(row.keyPath, label: row.title) }) { editing in
                    if !editing { session.commitEdit() }
                }
            }
        }
    }

    // MARK: 黑白 (S3.4, 2026-10-28)

    /// **黑白** — S3.4's two controls: the switch, and the eight 黑白混合 rows that decide how bright
    /// each hue lands in the grey.
    ///
    /// ```text
    /// ☑ 黑白                      S3.4's link exists only while this is on
    /// 红     −100…100             how much light 红 deposits in the print
    /// 橙 … 品红                   …one row per band, Lightroom's order
    /// ```
    ///
    /// Three rules, all inherited rather than re-implemented — that is the point of the card being
    /// built out of `sliderRow` and `bwRows`:
    ///
    ///   1. **关掉开关 = 八行置灰、不归零.** `enabled: on` is 细节's 解码模型 rule (`SliderRow`
    ///      `.disabled` + 0.42 opacity): the rows stop taking input and say so, and **no value is
    ///      written** — the mixes are inert while the switch is off (`HSLBand.mix` is rendered only
    ///      under `ColorGroup.blackAndWhite`), so switching back restores exactly what the user set.
    ///      Zeroing them here would make a toggle a destructive edit, and ⌘Z could not tell the two
    ///      apart.
    ///   2. **红 = 线性域.** The row's shape is `.linear` (`#FF375F`), because a mix is
    ///      `grey · 2^(m/100)` — **±1 stop of linear light** (`HSLBands.mixStopsPerFull`, and the
    ///      kernel's own note in `s3_4_bw.metal`), the number that says how much light a hue deposits
    ///      in the print. That is 071's third class: arithmetic on **linear** light, the same domain
    ///      黑电平's red names. It is *not* the HSL card's 亮度, which is ±1 stop of OKLab **perceptual**
    ///      lightness (`L · 2^(m/100)`, 8× the light) and is therefore blue; and it is not 黄, because
    ///      nothing here re-develops the RAW. One panel, two stops, two colours — the accent says which.
    ///   3. **一根滑杆 = 一条历史.** The drag writes every tick (`applyEdit`) and commits once on
    ///      release (`if !editing { session.commitEdit() }`); a typed number takes the same path; a
    ///      double-click on a name is `PanelResets.blackAndWhiteField(_:)` (one snapshot).
    ///
    /// The switch itself is **not** a `SliderRow`: a flag is not a number, and a two-position slider is
    /// a switch pretending to be a ruler. It is the panel's existing switch row (蒙版's 反转): a
    /// `.checkbox` `Toggle`, mini, 10 pt label. One click = one snapshot (`coalesce: false`), so 开/关
    /// cannot fold into the drag before it.
    private var blackAndWhiteCard: some View {
        let on = session.edit.color.blackAndWhite
        return card(Section.blackAndWhite.title, reset: { resetGroup(.blackAndWhite) }) {
            blackAndWhiteSwitchRow(isOn: on)
            ForEach(Self.bwRows, id: \.index) { row in
                sliderRow(row.title, bwMixBinding(row.index), row.range, row.format,
                          shape: row.shape,
                          decimals: row.decimals,
                          rounding: row.rounding,
                          editable: row.editable,
                          enabled: on,
                          accessibilityID: "inspector.blackAndWhite.\(row.title)",
                          onReset: { resets.blackAndWhiteField(row.index) }) { editing in
                    if !editing { session.commitEdit() }
                }
                .background(BlackAndWhiteProbeHost(rowID: row.title))
            }
        }
        // The card's own frame, for the layout test at the three widths (`BlackAndWhiteProbe.cardID`) —
        // a background, so it inherits the card's size and cannot change it.
        .background(BlackAndWhiteProbeHost(rowID: BlackAndWhiteProbe.cardID))
    }

    /// The card's first row: 「黑白」, drawn like every other switch in the panel (蒙版's 反转).
    ///
    /// The label lives *inside* the `Toggle`, so the checkbox and the word are one control (and one
    /// accessibility element) rather than a stray `Text` beside a box — 「点黑白」 means the switch,
    /// not the checkbox alone. The row takes the card's full width so it lines up with the eight heads
    /// below it; the layout test measures that frame at all three widths.
    private func blackAndWhiteSwitchRow(isOn: Bool) -> some View {
        Toggle(isOn: Binding(get: { session.edit.color.blackAndWhite },
                             set: { on in _ = resets.blackAndWhite(on) })) {
            Text(Section.blackAndWhite.title)
                .font(.system(size: SliderRowStyle.standard.labelSize,
                              weight: SliderRowStyle.standard.labelWeight))
                .foregroundStyle(.secondary)
        }
        .toggleStyle(.checkbox)
        .controlSize(.mini)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help("黑白：S3.4 把彩色转成单色。关掉只是停用下面的混合——八个值都留着，重新打开就回来")
        .accessibilityIdentifier("inspector.blackAndWhite.switch")
        .background(BlackAndWhiteProbeHost(rowID: BlackAndWhiteProbe.switchID, isOn: isOn))
    }

    /// One 黑白混合 row: which band it drives, and the numbers the row draws.
    ///
    /// A table for the same reason `ToneRow` is one: 「八根滑杆、每根 ±100、每根能输入、每根双击回 0」
    /// is then a value a test can hold, and the card cannot grow a ninth row (or lose a band) without
    /// the table saying so. The band `index` is here rather than a key path because the target is
    /// `color.bands[index].mix`, and the index is table state.
    public struct BWMixRow: Equatable {
        /// `0…7`, Lightroom's order: 红 橙 黄 绿 青 蓝 紫 品红.
        public var index: Int
        /// The row's label — the band's own name (`HSLBands.bandNames`), and the undo label.
        public var title: String
        public var range: ClosedRange<Double> = BWMixRow.travel
        /// The resting readout: whole units, like every other row that is not 曝光.
        public var format: String = "%.0f"
        /// 红 = 线性域 (see the card's note above): a mix is ±1 stop of **linear** light.
        public var shape: SliderShape = .linear
        /// 047: typeable, like every other row (no card opts out).
        public var editable: Bool = true
        /// 052: no decimals while editing — the number on screen is the number in the document.
        public var decimals: Int = 0
        /// 052: whole numbers, rounded away from zero, so a readout never reads smaller than the model.
        public var rounding: SliderRounding = .outward
        /// The document's grid: **1 unit**. The readout is an integer, so the stored mix is the number
        /// the user read — nothing downstream wants a 0.37 of a stop it cannot show.
        public var quantum: Double = 1

        /// ±100 — Lightroom's B&W mixer travel, and the unit `HSLBands.mix` defines (±100 = ±1 stop).
        public static let travel: ClosedRange<Double> = -100...100

        /// The field's default, from the model rather than a literal: `HSLBand()` is all zeros, i.e.
        /// "this hue deposits exactly its own lightness in the grey".
        public var defaultValue: Double { HSLBand().mix }
    }

    /// The eight rows, in draw order — one per band of `ColorGroup.bands`, named by the same table the
    /// HSL selector uses. `bwRows.count` is the card's slider count (the switch is the ninth row).
    public static let bwRows: [BWMixRow] = (0..<ColorGroup.bandCount).map { i in
        BWMixRow(index: i, title: HSLBands.bandNames[i])
    }

    /// The card's row count as one number: **1 switch + 8 mixes = 9**. Derived from the table, never a
    /// second literal, so `LayoutContractTests`' expectation moves with the card or not at all.
    public static var blackAndWhiteRowCount: Int { 1 + bwRows.count }

    /// `color.bands[band].mix` as a slider binding — the HSL card's closure pattern, for the same
    /// reason (`i` is table state, so there is no `WritableKeyPath`). The read side is the document's
    /// own value, so the number on screen is the number S3.4 is handed.
    private func bwMixBinding(_ band: Int) -> Binding<Double> {
        Binding(get: {
            guard session.edit.color.bands.indices.contains(band) else { return 0 }
            return session.edit.color.bands[band].mix
        }, set: { value in
            let stored = Self.quantized(value, quantum: 1)
            session.applyEdit { model in
                guard model.color.bands.indices.contains(band) else { return }
                model.color.bands[band].mix = stored
            }
        })
    }

    /// 派单 076 — **HSL**: eight band selectors, and the selected band's three sliders.
    ///
    /// The card is one idea in two rows: *which colour am I talking about* (the eight buttons, each
    /// drawn in the colour it names), and *what should happen to it* (色相 / 饱和 / 亮度, in the
    /// `HSLAxis` table). Everything about a row — typeable number, blue knob, double-click reset — is
    /// 047's contract, inherited from `sliderRow` rather than re-implemented here; the only thing this
    /// card adds is that a row's *target* is `color.bands[selected]`.
    ///
    /// **Blue** on purpose: `.knob` is the panel's "acts on the already-decoded render" class (060),
    /// which is exactly what S3.6 does — it runs in the display-referred domain, after the tone map.
    /// Yellow would claim a decode parameter and red a scene-linear one; neither is true.
    ///
    /// Selection is **view state** (`InspectorWorkspaceState.hslBand`): picking 绿 writes no document,
    /// takes no snapshot and moves no revision. The three sliders write through `applyEdit` on drag and
    /// commit once on release, like every other row.
    private var hslCard: some View {
        // 101: the ninth cell (全局) is index `ColorGroup.bandCount`; the eight bands keep 0…7.
        let band = min(max(workspaces.hslBand, 0), ColorGroup.bandCount)
        return card(Section.hsl.title, reset: { resets.hsl() }) {
            VStack(alignment: .leading, spacing: 6) {
                HSLBandStrip(selection: band) { workspaces.selectBand($0) }
                ForEach(HSLAxis.allCases, id: \.rawValue) { axis in
                    sliderRow(axis.title, hslBinding(axis, band: band), HSLAxis.range, "%.0f",
                              shape: .knob,
                              decimals: 0,
                              rounding: .outward,
                              editable: true,
                              accessibilityID: "inspector.hsl.\(axis.rawValue)",
                              onReset: { resets.hslField(band, axis) }) { editing in
                        if !editing { session.commitEdit() }
                    }
                }
            }
        }
    }

    /// `color.bands[band].hue/saturation/luminance` as a slider binding; band 8 is `color.global`
    /// (101, 「全局」), the same three axes across every hue.
    ///
    /// A closure, not a key path: the band index is view state, and `\EditModel.color.bands[i].hue`
    /// cannot be written as a `WritableKeyPath`. The read side is the document's own value (no draft
    /// copy), so the number on screen is the number the kernel is handed.
    private func hslBinding(_ axis: HSLAxis, band: Int) -> Binding<Double> {
        Binding(get: {
            let value: HSLBand?
            if band == ColorGroup.bandCount {
                value = session.edit.color.global
            } else if session.edit.color.bands.indices.contains(band) {
                value = session.edit.color.bands[band]
            } else {
                value = nil
            }
            switch axis {
            case .hue: return value?.hue ?? 0
            case .saturation: return value?.saturation ?? 0
            case .luminance: return value?.luminance ?? 0
            }
        }, set: { value in
            session.applyEdit { model in
                if band == ColorGroup.bandCount {
                    switch axis {
                    case .hue: model.color.global.hue = value
                    case .saturation: model.color.global.saturation = value
                    case .luminance: model.color.global.luminance = value
                    }
                    return
                }
                guard model.color.bands.indices.contains(band) else { return }
                switch axis {
                case .hue: model.color.bands[band].hue = value
                case .saturation: model.color.bands[band].saturation = value
                case .luminance: model.color.bands[band].luminance = value
                }
            }
        })
    }

    /// 2026-10-28 (P0 色彩分级) — **色彩分级**: three wheels, 阴影 / 中间调 / 高光, each 色相 + 饱和 + 亮度.
    ///
    /// ```text
    /// 阴影      色相   −100…100      ±30° of OKLCh hue
    ///           饱和                  chroma × (1 + s/100)
    ///           亮度                  ±1 stop of linear light
    /// 中间调    色相 / 饱和 / 亮度    …the same three, for the band between the two windows
    /// 高光      色相 / 饱和 / 亮度    …and for everything above −1.2 EV
    /// ```
    ///
    /// The rows are the `gradeRows` table (3 regions × 3 axes). A caption row above each wheel is a
    /// plain `Text`: the card is *three wheels*, and a list of nine sliders with no seams would make the
    /// user read the region off the row title every time.
    ///
    /// ## Why three rows and not a circular picker
    ///
    /// Lightroom and darktable both draw a **disc** (hue as an angle, saturation as a radius: Lr's
    /// wheels, darktable's `colorbalance rgb` hue/chroma pad). This card draws two sliders and a gain
    /// instead, and the reasons are this panel's own furniture, not a shortcut:
    ///
    ///  1. **Every parameter in this panel is a `SliderRow`** (040/046/047/052): a typeable number, a
    ///     double-click reset, an accessibility identifier and a probe a test can measure. A disc has no
    ///     read-out, no keyboard input, no reset target and no accessibility tree — it would be the one
    ///     control in the panel that cannot be typed into or read by VoiceOver.
    ///  2. **Precision.** At the narrowest panel (244 pt of card content) a 40-pt disc is ≈ 19° per
    ///     point and ≈ 2.5 % of chroma per point — you cannot enter 「色相 +7」, and the two things a
    ///     grade is for (a small hue rotation, a small chroma change) are exactly the small ones. The
    ///     slider's travel is 0.3° and 1 % per unit, and `↵` types an exact number.
    ///  3. **The model stores a hue *offset*, not an angle** (`GradeWheel.hue` documents why): a disc
    ///     would have to draw a "centre = no shift" dot at its own middle, which is not what a colour
    ///     wheel looks like and would invite reading it as an absolute hue.
    ///  4. **Two axes, two numbers, two history rows.** A disc writes a pair, so a drag would be one
    ///     field that cannot say which of the two moved — and the timeline's 「色相 0 → +12」 row
    ///     (077) would become 「一对坐标」.
    ///  5. Nothing is lost: the disc *is* these two numbers, and a future picker can be added **above**
    ///     these rows as a shortcut that writes them (a swatch, like the HSL card's band strip), without
    ///     this card or the document changing at all.
    private var colorGradingCard: some View {
        card(Section.colorGrading.title, reset: { resetGroup(.colorGrading) }) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(GradeRegion.allCases) { region in
                    Text(region.title)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, region == .shadows ? 0 : 4)
                        .accessibilityIdentifier("inspector.colorGrading.section.\(region.rawValue)")
                    ForEach(Self.gradeRows.filter { $0.region == region }) { row in
                        sliderRow(row.title, gradeBinding(row), row.range, row.format,
                                  shape: row.shape,
                                  decimals: row.decimals,
                                  rounding: row.rounding,
                                  editable: row.editable,
                                  accessibilityID: "inspector.colorGrading.\(row.fieldKey)",
                                  onReset: { resets.colorGradingField(row) }) { editing in
                            if !editing { session.commitEdit(label: Self.gradeLabel(row)) }
                        }
                        .background(ColorGradingProbeHost(rowID: row.fieldKey))
                    }
                }
            }
        }
        .background(ColorGradingProbeHost(rowID: ColorGradingProbe.cardID))
    }

    /// The nine rows, in draw order: 阴影 → 中间调 → 高光, each 色相 → 饱和 → 亮度. Derived from the two
    /// enums, so the card and every test iterate the same list.
    public static let gradeRows: [GradeRow] = GradeRegion.allCases.flatMap { region in
        GradeAxis.allCases.map { axis in
            GradeRow(region: region, axis: axis, title: axis.title)
        }
    }

    /// The card's row count as one number — **9 = 3 wheels × 3 axes**, derived, never a second literal.
    public static var colorGradingRowCount: Int { gradeRows.count }

    /// The undo label for one drag: 「色彩分级 阴影」. **One wheel, one row** — a drag of 色相 and then
    /// 饱和 of the same wheel folds into it (`EditField.gestureClass` makes the wheel the class), and a
    /// different wheel is a different label, hence a different row.
    static func gradeLabel(_ row: GradeRow) -> String {
        "\(Section.colorGrading.title) \(row.region.title)"
    }

    /// One row's number, read and written through the document: `colorGrading.shadows.hue`.
    ///
    /// A closure rather than a key path because the pair (region, axis) is table state — the same reason
    /// the HSL card's binding takes a band index. The read side is the document's own value, so the
    /// number on screen is the number S3.8 is handed.
    private func gradeBinding(_ row: GradeRow) -> Binding<Double> {
        Binding(get: {
            session.edit[keyPath: row.region.wheel][row.axis]
        }, set: { value in
            let stored = Self.quantized(value, quantum: row.quantum)
            session.applyEdit { model in
                model[keyPath: row.region.wheel][row.axis] = stored
            }
        })
    }

    /// 派单 031 / 040 + 解码模型 (owner, 2026-10-27): 降噪 / 色彩降噪 / 细节 / 锐化, all four assigned to
    /// `CIRAWFilter`, under a row that says **which decoder** produces the pixels.
    ///
    /// Three rules make this card different from the tone sliders, and all three come from the same
    /// fact — **a tick here is a development, not a render**:
    ///
    ///  1. **The number is a slider position, and the travel is per axis (042).** 细节 is **0…30**
    ///     and `position / 10` is the `detailAmount` it assigns (Apple's 0…3, `CIRAWFilter.h:148-154`);
    ///     the other three are **0…100** and `position / 100` is their amount (0…1,
    ///     `h:115-138`). The *default* position is the body's own baseline on that axis, in that
    ///     axis' units (Leica 0/50/0/50, R5 sharpness 100, Sony ARW luminance NR 38), and a slider
    ///     sitting there assigns **nothing**. That is what keeps an untouched document
    ///     byte-identical, and why a resting colour-NR slider must not push a 0.0 into Apple's 0.5.
    ///  2. **Drag = preview rung, release = full size.** The thumb writes the document on every tick
    ///     (the canvas has to follow it), and the loupe rebuilds from the 0.5 rung while the slider is
    ///     held; 200 ms after the hand stops it develops full size and replaces the frame. One drag is
    ///     still **one** `EditHistory` snapshot, taken on release.
    ///  3. **The card opens with 解码模型** — the file's own version list (default `8`). Which rows are
    ///     greyed comes from `session.capabilities.detailAxes`: Apple's per-instance flags, read off
    ///     the filter that made the pixels on screen (`isColorNoiseReductionSupported` /
    ///     `isDetailSupported` / `isLuminanceNoiseReductionSupported` / `isSharpnessSupported`,
    ///     `CIRAWFilter.h:121/129/137/153`). On this machine's `9.dng` that is exactly **two** rows
    ///     inert — 色彩降噪 and 细节 (both move zero samples) — while 降噪 and 锐化 stay live (0.021 /
    ///     0.510 maxΔ). Before the first frame `DetailAxes.forDecoderVersion` stands in, so a v9
    ///     document opens correctly and a v8 one is live. Greyed is **not zeroed**: the *displayed*
    ///     position of an inert row is still the document's number or the body's baseline — what
    ///     changes under a version switch is the document itself, because
    ///     `PanelResets.decoderVersion` puts all four back on their defaults as part of the same edit
    ///     (a v9 document never carries a 色彩降噪 amount the new decoder cannot honour).
    ///
    /// **096 (2026-10-28): the card no longer ends with the two 色差 rows.** They moved to their own
    /// 校正 card, between this card and 效果 (the user's ask); the decoder rows above are unchanged.
    private var detailCard: some View {
        let baseline = detailBaselineValue
        let caps = session.capabilities
        let chosen = chosenDecoderSpelling(offered: caps?.supportedVersions ?? [])
        let axes = Self.detailAxes(capabilities: caps,
                                   requested: chosen,
                                   document: session.edit.decoderVersion)
        return card(Section.detail.title, reset: { resetGroup(.detail) }) {
            decoderModelRow(chosen: chosen, offered: caps?.supportedVersions ?? [],
                            effective: caps?.effectiveVersion)
            divider
            ForEach(Self.detailContent.rows, id: \.axis) { row in
                sliderRow(row.title,
                          detailBinding(row.axis, baseline: baseline),
                          row.range,
                          row.format,
                          shape: row.shape,
                          editable: row.editable,
                          enabled: axes.isEnabled(row.axis),
                          accessibilityID: "inspector.detail.\(row.axis.rawValue)",
                          onReset: { resets.detail(row.axis) }) { editing in
                    if editing { beginDetailDrag() } else { commitDetail(title: row.title) }
                }
            }
        }
        // 096: the 色差 rows moved to `correctionCard`; this frame probe is the negative control for
        // the CA layout test (「两根行不在这张卡里」), not the rows' own card anchor.
        .background(ChromaticAberrationProbeHost(rowID: ChromaticAberrationProbe.detailCardID))
    }

    /// 2026-10-28 (096) — **校正**: the two 色差 rows on their own card, between 细节 and 效果.
    ///
    /// Nothing but the two rows: no divider, no sub-heading (the user's ask is 「校正卡片包括 色差 R、
    /// 色差 B」). The rows themselves are unchanged — `caRows` / `caSliderRow` are moved here verbatim,
    /// so the slider travel, the `.linear` accent, one history row on release and the S0 re-render all
    /// stay as they were on 细节.
    private var correctionCard: some View {
        card(Section.correction.title, reset: { resetGroup(.correction) }) {
            ForEach(Self.caRows, id: \.title) { row in
                caSliderRow(row)
            }
            // 116 — 镜头暗角校正. Linear domain (red), because it multiplies scene light at the end of
            // the linear chain; the numbers are the same fields the 效果 card used to draw.
            divider
            ForEach(Self.vignetteRows, id: \.title) { row in
                correctionSliderRow(row)
            }
        }
        .background(ChromaticAberrationProbeHost(rowID: ChromaticAberrationProbe.cardID))
    }

    /// 2026-10-28 (078 B8 / 096) — **色差**: the two lateral-CA rows, now in the 校正 card.
    ///
    /// ```text
    /// 色差 R   −100…100   S0: red's radial ratio α_R (> 0 = the red image is larger, pull it in)
    /// 色差 B   −100…100   S0: blue's, the same convention
    /// ```
    ///
    /// **Why they have a card of their own (096).** 029 put CA in S0 and left it with no UI at all;
    /// 078 B8 drew the two rows at the end of 细节. The user then moved them out: 「色散从细节中移出，
    /// 单独放置到校正卡片中，校正卡片目前放在「细节」「效果」的中间」. The rows are S0 render work
    /// rather than decoder amounts, so 校正 is the card's only content.
    ///
    /// **The two rows are not decoder rows, and the card says so by behaviour, not by a note:** they
    /// commit on release like every render row (`if !editing { session.commitEdit(…) }`), they are
    /// never greyed by `axes`, and their travel is the slider's −100…+100 rather than α's ±0.005 —
    /// the number on screen is `OpticsGroup.sliderPosition(forAlpha:)` and the document holds
    /// `OpticsGroup.alpha(fromSlider:)`, one conversion in one place (the 071 黑电平 rule). A tick
    /// re-runs S0 and everything below it; that is why the card has no decoder rows above them — the
    /// 校正 card is a re-*render* only.
    ///
    /// The colour is `.linear` (red `#FF375F`) — 071's third class, "arithmetic on the scene-linear
    /// buffer". S0 samples the decoded linear image radially; it is the same class as the 黑电平 trim
    /// and not a display-domain render control (Light's six rows).
    public static let caRows: [ToneRow] = [
        ToneRow(title: "色差 R", range: OpticsGroup.sliderRange, format: "%.0f",
                shape: .linear, keyPath: \.optics.caRed),
        ToneRow(title: "色差 B", range: OpticsGroup.sliderRange, format: "%.0f",
                shape: .linear, keyPath: \.optics.caBlue),
    ]

    /// One 色差 row: the panel's row, the slider↔α translation, and the frame probe.
    ///
    /// `row.keyPath` is the document field the row *owns*; the binding writes it as
    /// `alpha(fromSlider:)` of the position the thumb (or a typed number) produced, so the readout,
    /// the key material and the kernel's uniform carry one value.
    private func caSliderRow(_ row: ToneRow) -> some View {
        sliderRow(row.title, caBinding(row), row.range, row.format,
                  shape: row.shape,
                  decimals: row.decimals,
                  rounding: row.rounding,
                  editable: row.editable,
                  accessibilityID: "inspector.detail.\(row.title)",
                  onReset: { resets.field(row.keyPath, label: row.title) }) { editing in
            // A render row: one drag = one history row, taken on release.
            if !editing { session.commitEdit(label: row.title) }
        }
        .background(ChromaticAberrationProbeHost(rowID: row.title))
    }

    /// 色差's slider position ↔ document α. The row's `range` and its readout are the **slider's**
    /// units (integers −100…+100); `row.keyPath` is `optics.caRed` / `optics.caBlue` (±0.005), and
    /// `OpticsGroup`'s two mapping functions are the only conversion — the same split 黑电平's
    /// `blackLevelBinding` makes, and the reason a typed `5` stores `0.00025` while the row says `5`.
    private func caBinding(_ row: ToneRow) -> Binding<Double> {
        Binding(get: { OpticsGroup.sliderPosition(forAlpha: session.edit[keyPath: row.keyPath]) },
                set: { position in
                    let alpha = OpticsGroup.alpha(fromSlider: position)
                    session.applyEdit { $0[keyPath: row.keyPath] = alpha }
                })
    }

    /// 「解码模型」 — **the file's own version list**, one item per `supportedDecoderVersions` entry.
    ///
    /// Why a list and not V8/V9: on this machine's SL3 DNG the list is
    /// `6.dng, 7, 7.dng, 8, 8.dng, 9.dng`, and `8` and `8.dng` are *different decodes*
    /// (`08193a35…` vs `a15055fa…`, and the four detail axes swap validity between them). A two-way
    /// V8/V9 switch would hide both facts, so the label keeps the spelling and only annotates the
    /// container: `8`, `8 (DNG)`, `9 (DNG)`.
    ///
    /// The line underneath is the **read-back**, never the request: `session.capabilities.effectiveVersion`
    /// is what the filter reported *after* the assignment, so a version this file cannot honour says
    /// `已退回 v8` instead of the panel claiming something that did not run.
    private func decoderModelRow(chosen: String, offered: [String], effective: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: SliderRowStyle.standard.headSpacing) {
                Text("解码模型")
                    .font(.system(size: SliderRowStyle.standard.labelSize,
                                  weight: SliderRowStyle.standard.labelWeight))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Picker("解码模型", selection: Binding(get: { chosen },
                                                     set: { spelling in
                                                         resets.decoderVersion(spelling, offered: offered)
                                                     })) {
                    ForEach(Self.decoderChoices(chosen: chosen, offered: offered), id: \.self) { spelling in
                        Text(Self.decoderVersionLabel(spelling)).tag(spelling)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.mini)
                .frame(width: 96, alignment: .trailing)
                .accessibilityIdentifier("inspector.detail.decoderModel")
            }
            if let note = Self.decoderModelNote(requested: session.edit.decoderVersion,
                                                effective: effective) {
                Text(note)
                    .font(.system(size: 9))
                    .foregroundStyle(Self.decoderModelWasDowngraded(requested: session.edit.decoderVersion,
                                                                   effective: effective)
                                     ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("inspector.detail.decoderModel.effective")
            }
        }
    }

    /// 派单 051: 曲线 — the S1.7 HDR curve, visible and draggable for the first time.
    ///
    /// The card is deliberately thin: `CurvePanel` owns every interaction and the arithmetic behind
    /// it, and the two things the card adds are 047's conventions — **double-click the title = 全部复位
    /// in one snapshot** (`PanelResets.curve()`), and the undo label is the card's own title.
    ///
    /// The two buttons in the panel's corner do the narrower of the same two verbs (`复位本通道` /
    /// `全部复位`), so the title and the button cannot mean different things.
    private var curveCard: some View {
        card(Section.curve.title, reset: { resets.curve() }) {
            CurvePanel(session: session)
        }
    }

    /// 2026-10-28 — **效果**: 暗角, 纹理 / 清晰度 / 去雾 and 颗粒 — Lightroom's Effects card, and the
    /// Presence triple 078 P0-6 was missing.
    ///
    /// ```text
    /// 暗角        −100…100       S3c: negative darkens the corners
    /// 暗角中点      0…100         where the falloff starts
    /// 暗角羽化      0…100         how soft the transition is
    /// 暗角圆度   −100…100         square → circular
    /// ─────────────────────────
    /// 纹理       −100…100       S3.8: the guided-filter residual in the 2…8 px band
    /// 清晰度     −100…100       S3.8: the same residual at a few percent of the frame
    /// 去雾       −100…100       S3.8: dark channel prior; negative adds the veil back
    /// ─────────────────────────
    /// 颗粒数量      0…100         S3.7: the grain's standard deviation, 0 = no grain
    /// 颗粒大小      0…100         the cell, in frame fractions
    /// 颗粒粗糙度    0…100         how much of the finer octave is mixed in
    /// 种子          0…999         the hash's only free variable
    /// ```
    ///
    /// **One card, not two.** The three blocks are the pipeline's S3c, S3.8 and S3.7 and could have
    /// been split, but the ask was Lightroom's Effects *card*, and the user resets the card as one
    /// thing — one double-click on 「效果」 puts all eleven numbers back in **one** snapshot. The
    /// `divider`s between the blocks are the only thing the split is worth: they say "three stages"
    /// without making the user find a second card for a look that is one decision (frames are usually
    /// vignetted, their detail shaped *and* grained).
    ///
    /// **The card stores nothing.** Every number comes from and goes to `effects` through
    /// `effectsRows`' key paths — there is no second copy of a value here, no draft, no local mirror
    /// of a default: the row range *is* the kernel's range and the row default *is*
    /// `EditModel.neutral[keyPath:]`. A drag writes the document on every tick and commits one history
    /// entry on release, like every other render card (`if !editing { session.commitEdit() }`).
    private var effectsCard: some View {
        card(Section.effects.title, reset: { resetGroup(.effects) }) {
            // 116 — 暗角 moved to 校正 (it is a lens correction, not an effect).
            ForEach(Self.detailFXRows, id: \.title) { row in
                effectsSliderRow(row)
            }
            divider
            ForEach(Self.grainRows, id: \.title) { row in
                effectsSliderRow(row)
            }
        }
        // The card's own frame, for the layout test at 300 / 330 / 364 (`EffectsRowProbe.cardID`) —
        // a background, so it inherits the card's size and cannot change it.
        .background(EffectsRowProbeHost(rowID: EffectsRowProbe.cardID))
    }

    /// One 校正-card render row (116's vignette block): the panel's `sliderRow`, **without** the effects
    /// card's frame probe — that probe is the effects card's layout contract (`EffectsRowProbe` counts
    /// its rows), and a second card drawing the same probe would make the count lie.
    private func correctionSliderRow(_ row: ToneRow) -> some View {
        sliderRow(row.title, binding(row.keyPath, quantum: row.quantum), row.range, row.format,
                  shape: row.shape,
                  decimals: row.decimals,
                  rounding: row.rounding,
                  editable: row.editable,
                  accessibilityID: "inspector.correction.\(row.title)",
                  onReset: { resets.field(row.keyPath, label: row.title) }) { editing in
            if !editing { session.commitEdit() }
        }
    }

    /// One 效果 row: the panel's own `sliderRow`, plus the frame probe the layout tests measure. The
    /// probe is a background so it cannot change the row's size (`CropRowProbe`'s pattern).
    private func effectsSliderRow(_ row: ToneRow) -> some View {
        sliderRow(row.title, binding(row.keyPath, quantum: row.quantum), row.range, row.format,
                  shape: row.shape,
                  decimals: row.decimals,
                  rounding: row.rounding,
                  editable: row.editable,
                  accessibilityID: "inspector.effects.\(row.title)",
                  onReset: { resets.field(row.keyPath, label: row.title) }) { editing in
            if !editing { session.commitEdit() }
        }
        .background(EffectsRowProbeHost(rowID: row.title))
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
    /// knows how to print a note: the card's decoder half is these four titles plus a number per row,
    /// so a test can hold the whole surface (`DetailSectionTests.testTheCardPrintsNoDecoderProse`).
    /// Since 096 `caRows` (色差 R / 色差 B) no longer belong to this card; they have their own 校正
    /// card and are still not part of this table.
    public static let detailContent = DetailCardContent.standard

    /// **Which item is on screen.** The document's own spelling, else the file's default choice
    /// (`8` when the file offers it — the D2′ default, which is also what `nil` decodes to).
    ///
    /// `offered` is empty until the first development lands (the list arrives with
    /// `DecoderCapabilities.supportedVersions`), in which case `8` is shown and the note stays silent.
    private func chosenDecoderSpelling(offered: [String]) -> String {
        if let stored = session.edit.decoderVersion { return stored }
        return Self.defaultDecoderSpelling(offered: offered)
    }

    /// What the picker lists: the file's own versions in the file's own order, with the current
    /// spelling guaranteed present (a document from another body may name one this file lacks — it must
    /// still be visible, because *that* is what the read-back is about to report).
    public static func decoderChoices(chosen: String, offered: [String]) -> [String] {
        var list = offered
        if list.isEmpty { list = [chosen] }
        if !list.contains(chosen) { list.insert(chosen, at: 0) }
        return list
    }

    /// The menu label: the spelling, with the container called out — `8` and `8 (DNG)` are different
    /// decodes and the user has to be able to tell which one is selected.
    public static func decoderVersionLabel(_ spelling: String) -> String {
        spelling.hasSuffix(".dng") ? String(spelling.dropLast(4)) + " (DNG)" : spelling
    }

    /// The default choice for a file: **`8` when it is offered** (the version every document used
    /// before this row existed). Otherwise the nearest version on the older side, else the oldest —
    /// and with no list at all, `8`. On such a file the document stays `nil`, so Apple's own default
    /// runs and the read-back line is the only thing that claims a version.
    public static func defaultDecoderSpelling(offered: [String]) -> String {
        if offered.isEmpty || offered.contains("8") { return "8" }
        func number(_ s: String) -> Int { Int(s.prefix(while: { $0.isNumber })) ?? 0 }
        let sorted = offered.sorted { number($0) < number($1) }
        return sorted.last(where: { number($0) < 8 }) ?? sorted.first ?? "8"
    }

    /// The card's four rows: **capabilities first**, the version table only as a fallback.
    ///
    /// ① `capabilities.detailAxes` when there is one — that is Apple's own per-instance answer, read
    /// off the filter that produced the pixels on screen, and the *same field* the develop's veto
    /// consumes. Nothing else in the app may re-derive it.
    ///
    /// ② Otherwise the coarse `DetailAxes.forDecoderVersion` table, keyed by the spelling that is
    /// most likely to run: the document's request (there is no read-back before the first frame), else
    /// the picker's choice, else v8. This is only the placeholder for the window in which a v9
    /// document has not developed yet, and for a `DecoderCapabilities` built without a filter.
    public static func detailAxes(capabilities: DecoderCapabilities?,
                                  requested: String?,
                                  document: String?) -> DetailAxes {
        if let caps = capabilities { return caps.detailAxes }
        return detailAxes(effective: nil, requested: requested ?? document, document: document)
    }

    /// The table-only form, kept for the pre-first-frame path and for tests that want to ask what the
    /// fallback says without minting a `DecoderCapabilities`.
    ///
    /// `effective` wins when there is one (that is what the pixels were made with); before the first
    /// frame the document's request stands in, so a v9 document opens with 色彩降噪 / 细节 already
    /// inert (and 降噪 / 锐化 live); with neither, everything is live (the v8 default).
    public static func detailAxes(effective: String?, requested: String?, document: String?) -> DetailAxes {
        if let effective { return DetailAxes.forDecoderVersion(effective) }
        if let requested { return DetailAxes.forDecoderVersion(requested) }
        if let document { return DetailAxes.forDecoderVersion(document) }
        return .all
    }

    /// The line under 「解码模型」: the version that **actually** shaped the frame, never the request.
    public static func decoderModelNote(requested: String?, effective: String?) -> String? {
        guard let effective else {
            return requested == nil ? nil : "正在切换解码器…"
        }
        if let requested, requested != effective {
            return "已退回 v\(effective)"
        }
        return "实际 v\(effective)"
    }

    /// True when the request did not survive the read-back — the note is then drawn in orange.
    public static func decoderModelWasDowngraded(requested: String?, effective: String?) -> Bool {
        guard let requested, let effective else { return false }
        return requested != effective
    }

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
    /// default off instead of restoring it. One snapshot, one development. The verb itself lives in
    /// `PanelResets.detail(_:)`, so the panel and the tests run the same code.
    // MARK: building blocks

    /// A card: its title, and its rows.
    ///
    /// `reset` is 派单 047's group verb: when it is given, **double-clicking the title** puts the whole
    /// card back to its defaults in one snapshot (`PanelResets.group(_:)`). `nil` leaves the title a
    /// plain title — the histogram, 信息 and 蒙版 cards have no "default" to go back to.
    ///
    /// The chrome itself lives in `InspectorCardShell`, because one card (裁切, `TransformPanel.swift`)
    /// carries an **accessory in its header** — the ruler button that enters 裁切 mode — and a second
    /// copy of the glass/hairline/inset chain is exactly how two cards start to look different.
    private func card<Content: View>(_ title: String,
                                     reset: (() -> Void)? = nil,
                                     @ViewBuilder _ content: @escaping () -> Content) -> some View {
        InspectorCardShell(title: title, reset: reset, accessory: { EmptyView() }) {
            content()
        }
    }

    /// A **render** row (曝光 / 对比 / 自然饱和 …): what 046 calls a `.knob` parameter, because a tone
    /// or color control does not re-develop the RAW.
    ///
    /// 047 kept the rule and deleted the helper's reason to exist: the Light and Color cards now both
    /// iterate a `ToneRow` table, so the shape comes from the row (`row.shape`), not from a literal
    /// here. Two cards, one table type — a row cannot be born without a shape, a default and a reset.

    // MARK: the Light card's rows (046: all seven are render parameters → .knob)

    /// One tone row: what the row draws, which shape it draws, and what its default is.
    ///
    /// A table rather than seven inline calls because the **shape rule is per parameter class**, and a
    /// test has to be able to hold the seven rows' shapes without an accessibility tree
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
        /// 052: how many decimals the field shows **while editing** (`1.48` for 曝光, `1.5` for a
        /// tone row, `0` = the clean number 047 prints — never `2.0`).
        public var decimals: Int = 0
        /// 052: how the resting readout rounds. `.outward` is the panel's rule (`ceil` up, `floor`
        /// down: a readout never reads smaller than the document), `.asIs` is for 曝光, which keeps
        /// its two decimals — the one row whose number is fine enough to print.
        public var rounding: SliderRounding = .outward
        /// 052: the grid the **document** stores on (`0` = store exactly what was typed). 曝光 is
        /// 0.01 — `edit.light.exposure * 100` is an integer — the others keep their own quantization
        /// (整数行 stay integers because their step is 1; 细节 / 白平衡 quantize in the model).
        public var quantum: Double = 0

        /// The field's own default, read from the neutral document — never a hard-coded number.
        public var defaultValue: Double { EditModel.neutral[keyPath: keyPath] }
    }

    /// 曝光 / 对比 / 高光 / 中间调 / 阴影 / 白色 / 黑色 — the seven tone controls, in display order.
    ///
    /// All seven are **render** parameters: they act on the decoded pixels and never re-develop the
    /// RAW, so per 046 they keep the round knob. The day one of them moves into `DecodeInputs`, its
    /// `shape` here turns `.bar` and nothing else about the row changes.
    ///
    /// 085 added 中间调 between 高光 and 阴影: the three S2 windows are the user's order, not the old
    /// two-window layout's. `midtones` is already in `EditModel.changedStages` / `HistoryDirty`, so
    /// this row needs no new wiring — it is a `ToneRow` like the other six.
    ///
    /// 052: 曝光 is the one row that prints decimals (`%.2f EV`) and stores on a 0.01 grid; the other
    /// six read as whole numbers rounded away from zero and store what was typed (their 1 step is 1,
    /// so a drag is already whole).
    public static let lightRows: [ToneRow] = [
        ToneRow(title: "曝光", range: -5 ... 5, format: "%.2f EV", shape: .knob, keyPath: \.light.exposure,
                decimals: 2, rounding: .asIs, quantum: 0.01),
        ToneRow(title: "对比", range: -100 ... 100, format: "%.0f", shape: .knob, keyPath: \.light.contrast,
                decimals: 1),
        ToneRow(title: "高光", range: -100 ... 100, format: "%.0f", shape: .knob, keyPath: \.light.highlights,
                decimals: 1),
        ToneRow(title: "中间调", range: -100 ... 100, format: "%.0f", shape: .knob, keyPath: \.light.midtones,
                decimals: 1),
        ToneRow(title: "阴影", range: -100 ... 100, format: "%.0f", shape: .knob, keyPath: \.light.shadows,
                decimals: 1),
        ToneRow(title: "白色", range: -100 ... 100, format: "%.0f", shape: .knob, keyPath: \.light.whites,
                decimals: 1),
        ToneRow(title: "黑色", range: -100 ... 100, format: "%.0f", shape: .knob, keyPath: \.light.blacks,
                decimals: 1),
    ]

    /// 自然饱和 / 饱和 — the Color card's two rows, the same table shape as Light.
    ///
    /// 047 put them in a table for the same reason 046 did with Light's: the card's behaviour (shape,
    /// typeable number, per-parameter reset) is then a value a test can hold, and the two cards cannot
    /// drift apart. Both are render parameters, so both are `.knob`.
    public static let colorRows: [ToneRow] = [
        ToneRow(title: "自然饱和", range: -100 ... 100, format: "%.0f", shape: .knob,
                keyPath: \.color.vibrance, decimals: 1),
        ToneRow(title: "饱和", range: -100 ... 100, format: "%.0f", shape: .knob,
                keyPath: \.color.saturation, decimals: 1),
    ]

    /// 2026-10-28 — the 效果 card's 暗角 block: **S3c's four uniforms, in the kernel's own order**
    /// (`s3_vignette.metal`: amount, midpoint, feather, roundness), with the kernel's own travels.
    ///
    /// Nothing is added that the shader does not read: 高光对比 / 颜色优先 / 样式 are Lightroom's
    /// extra vignette keys and this kernel has no uniform for them, so no row exists for them — a
    /// slider that writes a number nothing consumes is the defect `optics`' own comment warns about
    /// (a parameter in a group `keyMaterial` does not branch on renders nothing, silently).
    ///
    /// All four are `.knob`: S3c runs in the display-referred domain on the already-decoded frame, so
    /// 060's yellow would claim a decode parameter and 071's red a scene-linear one.
    public static let vignetteRows: [ToneRow] = [
        ToneRow(title: "暗角", range: -100 ... 100, format: "%.0f", shape: .linear,
                keyPath: \.effects.vignetteAmount),
        ToneRow(title: "暗角中点", range: 0 ... 100, format: "%.0f", shape: .linear,
                keyPath: \.effects.vignetteMidpoint),
        ToneRow(title: "暗角羽化", range: 0 ... 100, format: "%.0f", shape: .linear,
                keyPath: \.effects.vignetteFeather),
        ToneRow(title: "暗角圆度", range: -100 ... 100, format: "%.0f", shape: .linear,
                keyPath: \.effects.vignetteRoundness),
    ]

    /// 2026-10-28 — the 效果 card's 颗粒 block: S3.7's four numbers (`s3_7_grain.metal`).
    ///
    /// 颗粒数量 is the pre-existing `effects.grain` field (Lightroom's `crs:GrainAmount`), which was
    /// stored and not rendered until S3.7; the three beside it are the schema-7 fields. The seed is a
    /// **whole-number grid** (`quantum: 1`) because the kernel hashes `grainSeedValue`, the rounded
    /// integer — a document holding 3.7 hashes 4, and letting the field store 3.7 would be a number the
    /// key and the pixels both silently disagree with.
    public static let grainRows: [ToneRow] = [
        ToneRow(title: "颗粒数量", range: 0 ... 100, format: "%.0f", shape: .knob,
                keyPath: \.effects.grain),
        ToneRow(title: "颗粒大小", range: 0 ... 100, format: "%.0f", shape: .knob,
                keyPath: \.effects.grainSize),
        ToneRow(title: "颗粒粗糙度", range: 0 ... 100, format: "%.0f", shape: .knob,
                keyPath: \.effects.grainRoughness),
        ToneRow(title: "种子", range: 0 ... 999, format: "%.0f", shape: .knob,
                keyPath: \.effects.grainSeed, quantum: 1),
    ]

    /// 2026-10-28 (P0-6) — the 效果 card's **纹理 / 清晰度 / 去雾** block: S3.8's three numbers
    /// (`s3_8_detail_fx.metal`), Lightroom's Presence triple, in the panel's order.
    ///
    /// The travels are the kernel's: −100…100 for all three. 0 means the band is not touched — and when
    /// all three are 0 the stage is not encoded at all, so the frame is the pre-S3.8 frame byte for
    /// byte. `effects.detailFXRows` is what the card iterates, so a row that is drawn but not in the
    /// table (or the reverse) cannot exist.
    public static let detailFXRows: [ToneRow] = [
        ToneRow(title: "纹理", range: -100 ... 100, format: "%.0f", shape: .knob,
                keyPath: \.effects.texture),
        ToneRow(title: "清晰度", range: -100 ... 100, format: "%.0f", shape: .knob,
                keyPath: \.effects.clarity),
        ToneRow(title: "去雾", range: -100 ... 100, format: "%.0f", shape: .knob,
                keyPath: \.effects.dehaze),
    ]

    /// The card's eleven rows in draw order — the three blocks and the dividers between them. One
    /// list, so a test can hold 「十一根滑杆」 and the card cannot draw a row the table does not have.
    public static var effectsRows: [ToneRow] { detailFXRows + grainRows }

    /// The 校正 card's rows in draw order: the two CA ratios (S0) and the four vignette rows (116 —
    /// linear-domain lens-vignetting correction), all drawn red.
    public static var correctionRows: [ToneRow] { caRows + vignetteRows }

    /// 052: how a resting readout turns a document value into the digits beside the slider.
    ///
    /// The panel's rule is **outward**: a positive number reads up (`ceil`), a negative one reads
    /// down (`floor`), so the number on screen is never smaller than the number in the document —
    /// `1.4829` reads `2`, `-0.4` reads `-1`, and an exact `2` still reads `2`. 曝光 is the one
    /// exception (`.asIs`): its readout prints two decimals (`1.48 EV`) instead of rounding at all.
    public enum SliderRounding: String, Equatable, Sendable {
        /// Print the value the format asks for (`%.2f EV` → `1.48 EV`). 曝光's rule.
        case asIs
        /// Whole numbers, rounded away from zero (`ceil` up, `floor` down). Every other row.
        case outward

        /// The number the format is handed. `−0` comes back as `0`: the panel never prints `-0`.
        public func apply(_ value: Double) -> Double {
            switch self {
            case .asIs:
                return value
            case .outward:
                guard value.isFinite else { return 0 }
                if value > 0 { return value.rounded(.up) }
                if value < 0 { return value.rounded(.down) }
                return 0
            }
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
    /// `shape` is 派单 046's parameter-class switch, and since **060 it is only the accent colour**:
    /// `.bar` for the decoder parameters (降噪 / 色彩降噪 / 细节 / 锐化, plus 色温/色调) draws
    /// **yellow**, `.linear` (the 黑电平 trim, 071) draws `#FF375F`, and `.knob` for everything that
    /// acts on the already-decoded render (Light, Color) takes no tint at all, i.e. the system accent —
    /// blue unless the user changed it. The three colours are `SliderShape.accent`, and only there. 060 deleted
    /// 055's bubble control: both shapes are **one** `Slider`, one row, one behaviour, so a shape can
    /// never grow a different feel, focus state or accessibility story again; the colour is the only
    /// thing that differs, and it is the thing the user asked to be able to see.
    ///
    /// There is deliberately **no `step:` parameter**. SwiftUI's `Slider` draws tick marks the moment
    /// it is handed one, and 046 forbids ticks on every slider; any quantization belongs to the model
    /// (`DetailSettings.setPosition` rounds to 1 unit).
    /// The row itself is `SliderRow` (`SliderRow.swift`), and this is only the cards' door to it:
    /// 蒙版 needed the same row, and a `private` method of this view cannot be the panel's row. There
    /// is still exactly one row view, one `Slider` (`shapeSlider`) and one set of numbers
    /// (`SliderRowStyle`) — a card that called `SliderRow` directly would get the same thing.
    ///
    /// `internal`, not `private`: the 裁切 card (`TransformPanel.swift`) is the panel's second caller
    /// and must draw the **same** row — a card that built its own label/number/slider chain is exactly
    /// the 040 bug (「细节卡的样式和其他不一致」) coming back under a new name.
    func sliderRow(_ title: String,
                           _ value: Binding<Double>,
                           _ range: ClosedRange<Double>,
                           _ format: String,
                           shape: SliderShape = .knob,
                           style: SliderRowStyle = .standard,
                           decimals: Int = 0,
                           rounding: SliderRounding = .asIs,
                           editable: Bool = true,
                           enabled: Bool = true,
                           accessibilityID: String? = nil,
                           onReset: @escaping () -> Void,
                           onEditingChanged: @escaping (Bool) -> Void) -> some View {
        SliderRow(title: title, value: value, range: range, format: format, shape: shape,
                  style: style, decimals: decimals, rounding: rounding, editable: editable,
                  enabled: enabled, accessibilityID: accessibilityID, onReset: onReset,
                  onEditingChanged: onEditingChanged)
    }

    /// 060: the panel's **only** slider view — `.mini`, 16 pt high, and the accent colour that says
    /// which domain a parameter lives in: `.bar` → yellow (raw/decode), `.linear` → `#FF375F`
    /// (linear-domain arithmetic, 071), `.knob` → no tint at all (the system accent, blue unless the
    /// user changed it). The colours themselves are `SliderShape.accent` — one definition, in one
    /// place, so a third category could not grow a second palette.
    ///
    /// It is a function, not a copy-pasted modifier chain, because the colour test has to render **this
    /// view** to sample a pixel: a test that re-declares `.tint(…)` on its own copy would keep passing
    /// after the panel's tint was deleted, which is exactly the counter-proof 060 asks for.
    ///
    /// No `step:` — SwiftUI draws tick marks the moment it is handed one (046), on all three shapes.
    static func shapeSlider(_ value: Binding<Double>,
                            in range: ClosedRange<Double>,
                            shape: SliderShape,
                            controlSize: ControlSize = .mini,
                            onEditingChanged: @escaping (Bool) -> Void) -> some View {
        Slider(value: value, in: range, onEditingChanged: onEditingChanged)
            .controlSize(controlSize)
            .frame(height: SliderValueMap.rowHeight)
            .tint(shape.accent)
    }

    /// One slider's readout, with the negative zero taken out.
    ///
    /// `String(format: "%.0f", -0.4)` is `"-0"`, so a control parked a hair below zero read `-0`
    /// while it was, for every practical purpose, at zero (the same for `"%.2f"` → `"-0.00"`).
    /// Anything whose formatted form is zero must come out unsigned: the panel says `0`, never `-0`.
    ///
    /// 052: `rounding` decides what the format is handed — `.outward` for the panel's whole-number
    /// rows (曝光 passes `.asIs` and keeps its two decimals).
    static func sliderText(_ format: String, _ value: Double,
                           rounding: SliderRounding = .asIs) -> String {
        let text = String(format: format, rounding.apply(value))
        let digits = text.drop { $0 == "-" }
        if !digits.isEmpty, digits.allSatisfy({ $0 == "0" || $0 == "." }) {
            return String(digits)
        }
        return text
    }

    /// 052: the value a row writes into the **document**, on the row's own grid.
    ///
    /// 曝光 is the row this exists for: the readout says `1.48 EV`, so `edit.light.exposure` has to
    /// be `1.48` and never `1.48293…` — dragging must not put a number nobody can read into a
    /// cache key. `quantum == 0` means the row has no grid of its own (it stores what was typed;
    /// 细节 and 白平衡 quantize inside the model, as they always have).
    static func quantized(_ value: Double, quantum: Double) -> Double {
        guard quantum > 0, value.isFinite else { return value }
        let scale = (1 / quantum).rounded()
        guard scale >= 1, abs(scale * quantum - 1) < 1e-9 else {
            return (value / quantum).rounded() * quantum
        }
        return (value * scale).rounded() / scale
    }

    /// A slider binding that writes through the session, so every tick is observed by the loupe.
    private func binding(_ keyPath: WritableKeyPath<EditModel, Double>,
                         quantum: Double = 0) -> Binding<Double> {
        Binding(get: { session.edit[keyPath: keyPath] },
                set: { newValue in
                    let stored = Self.quantized(newValue, quantum: quantum)
                    session.applyEdit { $0[keyPath: keyPath] = stored }
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
        /// 060/071: 色温/色调 写 `CIRAWFilter`（= 重新解码），所以它们是「解 RAW 参数」→ `.bar` → 黄。
        /// 类别归 `SliderShape` 一处表达，行视图照着上色，不写死一个颜色。
        public var shape: SliderShape = .bar
    }

    /// 118: the line 「as shot」 / 「模拟预览」 lives on. One height for both states is what keeps the
    /// row from jumping when a drag starts: only the text and its type size change, never the box.
    public static let whiteBalanceStatusHeight: CGFloat = 10
    public static let asShotStatusFontSize: CGFloat = 8
    public static let previewStatusFontSize: CGFloat = 9

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
                // 118: the same slot as 「as shot」. Same height, same baseline, same place: the preview
                // label replaces the state word while the canvas is a simulation, then the real frame
                // arriving puts the state word back.
                WhiteBalanceStatusLabel(kind: whiteBalancePreviewing ? .simulated
                                                                     : (stored == nil ? .asShot : nil))
                    .accessibilityIdentifier("inspector.whiteBalance.status.\(row.title)")
                Spacer(minLength: 4)
                SliderNumberField(value: shown,
                                  range: row.range,
                                  format: row.format,
                                  fontSize: 10,
                                  width: 52,
                                  accessibilityID: "inspector.whiteBalance.\(row.title)",
                                  onCommit: { typed in
                                      let revisionBefore = session.editRevision
                                      commitWhiteBalanceValue(typed, isTemperature: isTemperature)
                                      if whiteBalancePreviewing {
                                          loupe?.releaseWhiteBalancePreview(
                                              awaiting: session.editRevision != revisionBefore
                                                  ? session.editRevision : nil)
                                      }
                                  })
            }
            // 046/060: 色温/色调 **会重新解码 RAW**（写 `CIRAWFilter` 的 temperature/tint），所以是
            // 「解 RAW 参数」→ 黄色强调色（071 把 060 的橙改成了黄）；曝光/对比那些只跑渲染的滑杆
            // 跟随系统强调色（默认蓝），线性域的「黑电平」是红 #FF375F。
            // label / 数值 / 抬起才提交的语义与 `sliderRow` 完全相同，滑杆也是同一个 `shapeSlider`
            // （`row.shape` 是 `.bar`，颜色因此也是同一处给的）。
            Self.shapeSlider(Binding(get: { shown },
                                     set: { newValue in
                                         if isTemperature { draftTemperature = newValue }
                                         else { draftTint = newValue }
                                         previewWhiteBalance(isTemperature: isTemperature, value: newValue)
                                     }),
                             in: row.range,
                             shape: row.shape) { editing in
                if editing {
                    beginWhiteBalancePreview()
                } else {
                    // Release = quantize + one document write = one development (`commitWhiteBalance`),
                    // and the simulated preview survives until that frame lands.
                    commitWhiteBalance(isTemperature: isTemperature)
                }
            }
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
        guard let draft = isTemperature ? draftTemperature : draftTint else {
            // A click that moved nothing has no write and therefore no real frame to wait for.
            loupe?.releaseWhiteBalancePreview(awaiting: nil)
            return
        }
        let revisionBefore = session.editRevision
        commitWhiteBalanceValue(draft, isTemperature: isTemperature)
        let changed = session.editRevision != revisionBefore
        // 118: the simulation stays on screen, old frame × gain, until the decode carrying the new
        // pair lands. A release that wrote nothing ends it now.
        if whiteBalancePreviewing || loupe?.isWhiteBalancePreviewActive == true {
            loupe?.releaseWhiteBalancePreview(awaiting: changed ? session.editRevision : nil)
        }
    }

    /// 118 — the drag's two view-state calls, so the slider body reads as one gesture.
    private func beginWhiteBalancePreview() {
        guard let loupe else { return }
        whiteBalancePreviewing = true
        loupe.onWhiteBalancePreviewSettled = { whiteBalancePreviewing = false }
        loupe.beginWhiteBalancePreview()
    }

    private func previewWhiteBalance(isTemperature: Bool, value: Double) {
        guard let loupe else { return }
        if !whiteBalancePreviewing { beginWhiteBalancePreview() }
        // The axis not under the hand keeps the document's value (`nil` = as shot); only the dragged
        // axis reads the new `@State`, which is what the pixels before the decode are a prediction of.
        let stored = session.edit.light.whiteBalance
        let temperature = isTemperature ? value : (draftTemperature ?? stored.temperature)
        let tint = isTemperature ? (draftTint ?? stored.tint) : value
        loupe.updateWhiteBalancePreview(temperature: temperature, tint: tint)
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
    /// The panel's reset verbs (047), reachable from the crop card's four sections as well as from
    /// this file's own cards: one implementation, so 「双击复位」 cannot mean two things.
    var resets: PanelResets { PanelResets(session: session, loupe: loupe) }


    /// The two tooltips: `SliderRow`、蒙版与 `InspectorCardShell` 都用它们，所以是面板的，不是某张卡的。
    /// `internal`（不是 `private`）：`InspectorCardShell` 在文件作用域，裁切卡的头部件要用同一套标题行。
    static let resetParameterHelp = "双击复位此参数"
    static let resetGroupHelp = "双击整组复位"

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

/// 118 — the word in the white-balance row's status slot.
///
/// The two states are one view with one fixed height, so 「模拟预览」 lands on the exact frame 「as shot」
/// occupied (and the row cannot grow while the hand moves). The type sizes differ by the task's own
/// spec: 9 pt secondary for the simulation, 8 pt tertiary for the state.
struct WhiteBalanceStatusLabel: View {

    enum Kind: Equatable {
        case asShot
        case simulated

        var text: String {
            switch self {
            case .asShot: return "as shot"
            case .simulated: return "模拟预览"
            }
        }

        var fontSize: CGFloat {
            switch self {
            case .asShot: return InspectorView.asShotStatusFontSize
            case .simulated: return InspectorView.previewStatusFontSize
            }
        }

        var style: AnyShapeStyle {
            switch self {
            case .asShot: return AnyShapeStyle(.tertiary)
            case .simulated: return AnyShapeStyle(.secondary)
            }
        }
    }

    let kind: Kind?

    var body: some View {
        if let kind {
            Text(kind.text)
                .font(.system(size: kind.fontSize))
                .foregroundStyle(kind.style)
                .frame(height: InspectorView.whiteBalanceStatusHeight)
                .accessibilityIdentifier("inspector.whiteBalance.statusText.\(kind.text)")
        } else {
            EmptyView()
        }
    }
}

/// What the 细节 card's **decoder** rows draw, in order (派单 040).
///
/// Four rows and nothing else: the card used to end with a line of decoder prose (「解码参数 · v9 ·
/// 0 = 系统默认」) and a second label per row (「基线 0.50」). Both are gone, and making the rows data
/// is what lets a test hold the card's entire text surface instead of a screenshot.
///
/// 2026-10-28 (078 B8 / 096): 色差 R / 色差 B are **not** in this table and must not be: these four
/// are a re-*develop* (`DetailAxis`, `CIRAWFilter`, greyed per decoder version), while 色差 is a
/// re-*render* on S0. Since 096 they live on their own 校正 card (`InspectorView.caRows`).
public struct DetailCardContent: Equatable, Sendable {

    public struct Row: Equatable, Sendable {
        public var axis: DetailAxis
        /// The row's label — also the undo label for one drag.
        public var title: String
        /// The slider's travel, from the axis itself: 细节 **0…30** (amount 0…3), the other three
        /// 0…100 (amount 0…1). 042 — one travel per axis, per Apple's `CIRAWFilter.h`.
        public var range: ClosedRange<Double>
        /// The number's format: integers, no percent sign.
        public var format: String
        /// The quantization the **model** applies (1 position unit = **0.1** of `detailAmount`,
        /// 0.01 of the other three).
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

    /// The shipped card: the four axes of `DetailAxis.panelOrder`, each row's travel / number format /
    /// step taken from **its own axis** (042: 细节 0…30 → amount 0…3, the other three 0…100 → 0…1),
    /// one shape.
    public static let standard = DetailCardContent(
        rows: DetailAxis.panelOrder.map {
            Row(axis: $0, title: $0.title, range: $0.range,
                format: $0.format, step: $0.step, shape: .bar)
        })
}

/// The panel's **card chrome**: glass, hairline, insets, and a title row with an optional accessory.
///
/// One definition, used by both `InspectorView.card(_:reset:_:)` (accessory = `EmptyView`) and the
/// 裁切 card (`TransformPanel.swift`, also `EmptyView` since 086 removed its header button).
/// A second copy of this chain — the four paddings, the material, the 9 pt corner, the 8 % hairline —
/// is how two cards in the same column start to look like two different panels.
///
/// The title keeps 047's double-click verb (`ResetOnDoubleClick`) when a `reset` is given, so a card
/// with an accessory cannot accidentally lose the group reset.
struct InspectorCardShell<Accessory: View, Content: View>: View {

    let title: String
    var reset: (() -> Void)?

    private let accessory: () -> Accessory
    private let content: () -> Content

    init(title: String,
         reset: (() -> Void)? = nil,
         @ViewBuilder accessory: @escaping () -> Accessory,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.reset = reset
        self.accessory = accessory
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.primary)
                    .modifier(ResetOnDoubleClick(action: reset, help: InspectorView.resetGroupHelp))
                Spacer(minLength: 0)
                accessory()
            }
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
}

/// Double-click on a row's label = back to that slider's default (派单 040 / 047).
///
/// A `nil` action leaves the label a plain label. Every row of a *parameter* card passes one (047 made
/// the parameter required in `sliderRow`, so a new card cannot forget it): for a tone or color row the
/// default is the field's own value in `EditModel.neutral`, for a 细节 row it is the *body's* baseline
/// position (50 on a Leica for colour NR — never a nominal 0), for 色温/色调 it is as shot.
///
/// The card titles use it too, with `help` pointing at the group verb instead of the parameter one.
///
/// Internal, not `private`: `SliderRow` (its own file) and 蒙版's card title install the same gesture,
/// so the modifier that means 「双击…复位」 lives in one place for the whole panel.
struct ResetOnDoubleClick: ViewModifier {
    let action: (() -> Void)?
    var help: String = InspectorView.resetParameterHelp

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
/// rules are the contract, and a rule a test can call is a rule that cannot rot silently.
///
/// 057 changed what "cannot rot" means here: `swift test` *can* have a window session (a test builds a
/// real `NSWindow`, focuses a real `NSTextField` and drives its field editor), so the keystroke
/// **wiring** is no longer read off the source — `NumberFieldTypingTests` drives real AppKit callbacks
/// through it. The rules below are still asserted directly, because they are still pure functions.
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

    /// 052: the same clean number, but at most `decimals` places — 曝光's box shows `1.48`, never
    /// `1.4829`, while a whole number stays whole (`2`, not `2.00`: the panel's integer rows must not
    /// grow a `.0` just because the user clicked into them).
    ///
    /// `decimals == 0` means "no cap" and is the plain 047 form: a `%.0f` row may hold `0.5` (047's
    /// contract — the field must not truncate what the document legitimately holds), so nothing is
    /// rounded away that the user did not ask to round.
    static func editingText(_ value: Double, decimals: Int) -> String {
        guard decimals > 0 else { return editingText(value) }
        guard value.isFinite else { return "0" }
        if value == 0 { return "0" }
        if value == value.rounded(), abs(value) < 1e9 { return String(format: "%.0f", value) }
        let text = String(format: "%.\(decimals)f", value)
        let digits = text.drop { $0 == "-" }
        if !digits.isEmpty, digits.allSatisfy({ $0 == "0" || $0 == "." }) { return "0" }
        return text
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

/// 派单 052: what a keystroke means to a number field that has just been focused.
///
/// The question the field asks is not "which key was this" but "did the user select something
/// first". A first keystroke that **replaces** a selection is a local edit (「只想改一位」); one that
/// merely inserts has to start from an empty buffer (「我以为自己在从头输入」— the bug 052 names:
/// clicking into `1.5` and typing `1.5` used to give `1.1.5`).
///
/// SwiftUI gives a `TextField` no key events and no selection, but it does hand back both strings,
/// and a change that removes nothing can only be an insertion. That is all this rule needs — no
/// click counting, no `onTapGesture`, no key monitor.
enum FirstKeystroke: Equatable {
    /// Nothing was selected: show exactly what was just typed (empty after a Backspace).
    case clear(typed: String)
    /// Something was selected before the key: the field's own replacement is what the user asked for.
    case inPlace

    /// The whole verdict, as a pure function of the buffer before and after one keystroke.
    static func decide(from old: String, to new: String) -> FirstKeystroke {
        // No change is no keystroke: a digit typed over the very same digit must not empty anything.
        guard old != new else { return .inPlace }
        let o = Array(old), n = Array(new)
        var prefix = 0
        while prefix < o.count, prefix < n.count, o[prefix] == n[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < o.count - prefix, suffix < n.count - prefix,
              o[o.count - 1 - suffix] == n[n.count - 1 - suffix] { suffix += 1 }
        let removed = o.count - prefix - suffix
        let inserted = String(n[prefix ..< max(prefix, n.count - suffix)])
        // A removal means the keystroke landed on a selection; an insertion means it only extended
        // the buffer we are about to throw away.
        if removed > 0, !inserted.isEmpty { return .inPlace }
        return .clear(typed: inserted)
    }
}

/// 052: a row's number while it is being typed — the buffer, and the one rule above.
///
/// The view holds this, the tests hold this: `begin` is focus, `end` is any of 047's three exits, and
/// the buffer is whatever the field editor really holds (`record`). Keeping the decision here (and not
/// in the view) is what makes 「第一次按键先清空」 a test instead of a screenshot.
///
/// 057 moved *where the decision is taken*, not what it decides: `judgeFirstEdit` is asked by the field
/// editor, before the character lands. `typed(from:to:)` is 052's string-diff form of the same rule —
/// it can only run after the change, and it is no longer the field's live path (a `TextField` binding
/// cannot repaint the character it just accepted). It is kept, and still driven directly by
/// `PanelEditingTests`, as the record of what 052 decided; the wiring is pinned by
/// `NumberFieldTypingTests`, through AppKit.
struct NumberFieldState: Equatable {
    /// What the field shows.
    private(set) var text: String = ""
    /// The field is the first responder's target: `↵`/`Esc`/blur mean something.
    private(set) var editing = false
    /// Focus arrived and nothing has been typed yet — the buffer is still the readout it replaced.
    private(set) var pendingClear = false
    /// The buffer as focus left it. A change whose `old` is not this one is not a keystroke at all
    /// (it is the field's own `begin`), so the rule must not read it as one.
    private(set) var origin: String = ""

    /// Focus gained: the resting readout becomes the clean editing text, and the next keystroke
    /// starts the buffer over.
    mutating func begin(_ editingText: String) {
        text = editingText
        origin = editingText
        pendingClear = true
        editing = true
    }

    /// One keystroke (or a paste) landed. Returns what the rule decided, or `nil` for an ordinary
    /// keystroke (the rule is spent); `text` is left holding the buffer the field should show.
    @discardableResult
    mutating func typed(from old: String, to new: String) -> FirstKeystroke? {
        guard old != new else { return nil }        // nothing landed: the rule is not spent
        let isFirst = editing && pendingClear && old == origin
        pendingClear = false
        guard isFirst else {
            text = new
            return nil
        }
        switch FirstKeystroke.decide(from: old, to: new) {
        case .clear(let typed):
            text = typed
            return .clear(typed: typed)
        case .inPlace:
            text = new
            return .inPlace
        }
    }

    /// 057: what the string-diff rule above cannot see, because it runs *after* the character has
    /// landed — the range the field editor is about to change, and the text replacing it.
    ///
    /// `true` means the affected range must become **the whole buffer**: a first insertion into a
    /// readout the user means to retype (`1.48` + `5` → `5`). `false` means the user's own range
    /// stands: a chosen selection ("只想改一位"), or a Backspace. The rule is spent either way — it is
    /// 「第一次按键」, not 「每一次按键」.
    mutating func judgeFirstEdit(affectedRange: NSRange, replacement: String) -> Bool {
        let armed = pendingClear
        pendingClear = false
        return armed && !replacement.isEmpty && affectedRange.length == 0
    }

    /// 057: the buffer the field editor actually holds, recorded after a change landed. This is what
    /// `submission(in:)` judges, so a commit can never read a string the user is not looking at.
    mutating func record(_ buffer: String) {
        text = buffer
    }

    /// One of the three exits: the field stops editing and shows `text` (the row's readout, or the
    /// old value after a cancel).
    mutating func end(_ text: String) {
        self.text = text
        origin = text
        editing = false
        pendingClear = false
    }

    /// What `↵` (or a blur) does with the buffer — 052's one addition to 047's three exits.
    enum Submission: Equatable {
        /// A number: write it, then commit (one history entry, exactly like a drag).
        case value(Double)
        /// The buffer is **empty**: the user cleared it and left. Keep the old value, write nothing,
        /// do not beep — `Esc`'s outcome, not the junk string's.
        case cancelled
        /// Not a number: beep, restore, write nothing (047's "非法输入不写历史").
        case rejected
    }

    /// The exit decision, as a pure function of the buffer.
    func submission(in range: ClosedRange<Double>) -> Submission {
        if text.trimmingCharacters(in: .whitespaces).isEmpty { return .cancelled }
        switch SliderValueInput.resolve(text, in: range) {
        case .value(let typed): return .value(typed)
        case .rejected: return .rejected
        }
    }
}

/// One row's number: a readout that turns into a text field (派单 047, 精度 052, 接线 057).
///
/// Always a real field — a `Text` plus an `onTapGesture` would give the mouse an entry and the keyboard
/// none (`Tab` reaches a control, not a label). What changes on focus is the *text*: the row's own
/// format while resting (`1.48 EV`), the clean number while editing (`1.48`), so the user types what
/// the document will hold.
///
/// The three exits are the task's three: `↵` commits, `Esc` cancels (old value back, no write), losing
/// focus commits. A rejected string beeps **and** restores — and because `onCommit` is never called, no
/// `applyEdit` and no `commitEdit` happen, which is the "非法输入不写历史" contract.
///
/// 057: the field itself is an `NSTextField` (`NumberFieldView` → `NumberTextField`), because
/// 「第一次按键先清空」 has to rewrite the affected **range** before the character lands — see
/// `NumberField.swift`. This view is only the row's data: value, travel, format, and the row's own
/// write path.
struct SliderNumberField: View {
    let value: Double
    let range: ClosedRange<Double>
    let format: String
    /// 052: decimals while editing (`2` for 曝光, `1` for a tone row, `0` = 047's clean number).
    var decimals: Int = 0
    /// 052: how the resting readout rounds (`.asIs` keeps 曝光's `1.48`; `.outward` is whole numbers).
    var rounding: InspectorView.SliderRounding = .asIs
    var fontSize: CGFloat = 10
    var width: CGFloat = 40
    var accessibilityID: String?
    /// Write + commit: the row's own path, so a typed value is one history entry exactly like a drag.
    let onCommit: (Double) -> Void

    var body: some View {
        // 057: no `@State`, no `Binding`, no `@FocusState` — the text lives in the `NSTextField`, and
        // the field editor is the only thing that knows where the caret is when a key arrives.
        NumberFieldView(row: NumberFieldRow(value: value, range: range, format: format,
                                            decimals: decimals, rounding: rounding),
                        fontSize: fontSize,
                        accessibilityID: accessibilityID,
                        onCommit: onCommit)
            .frame(width: width, height: fontSize + 4)
            .accessibilityIdentifier(accessibilityID ?? "")
            .help("点击数值可键盘输入：↵ 提交 · Esc 取消 · 点别处取消并退回原值")
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
        session.commitEdit(label: label, coalesce: false)
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
        session.commitEdit(label: "原照设置", coalesce: false)
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
        /// 2026-10-28: 黑白 — S3.4's switch and its eight 黑白混合 numbers, one double-click.
        case blackAndWhite
        case detail
        /// 2026-10-28 (096): 校正 — 色差 R / 色差 B, one double-click.
        case correction
        /// 2026-10-28: 效果 — 暗角 + 颗粒, eight numbers, one double-click.
        case effects
        /// 2026-10-28 (P0 色彩分级): 色彩分级 — the nine wheel numbers, one double-click.
        case colorGrading

        /// The card title this group is — the name the user double-clicked, and the undo label.
        public var title: String {
            switch self {
            case .whiteBalance: return InspectorView.Section.whiteBalance.title
            case .light: return InspectorView.Section.light.title
            case .color: return InspectorView.Section.color.title
            case .blackAndWhite: return InspectorView.Section.blackAndWhite.title
            case .detail: return InspectorView.Section.detail.title
            case .correction: return InspectorView.Section.correction.title
            case .effects: return InspectorView.Section.effects.title
            case .colorGrading: return InspectorView.Section.colorGrading.title
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

    // MARK: the decoder model (细节 card, owner 2026-10-27)

    /// Pick one item of the file's own version list, as **one** document edit and **one** history entry.
    ///
    /// `"8"` (when the file offers it) is stored as **`nil`** — "ask for nothing", which is the D2′
    /// default and the byte-identical pre-change decode; anything else is stored verbatim. That keeps
    /// "the default is v8" true without inventing an assignment that Apple's own default does not make.
    ///
    /// This is a **decode** input (`EditModel.decodeInputs` carries it, and — since the rung identity
    /// gained its `ver=` component — the ladder, the queue and `isCurrentPhoto` all see it as a
    /// different buffer), so the pick alone re-develops: no slider has to be touched afterwards.
    ///
    /// **The four amounts are forced back to this version's defaults** — `detailSettings = .identity`,
    /// i.e. all four sliders at the body's own baseline, which assigns nothing to `CIRAWFilter`:
    ///
    ///   · a version change is the coarsest decode input, and `v9` does not honour 色彩降噪 / 细节 at
    ///     all (`isColorNoiseReductionSupported` / `isDetailSupported` are false on that instance). The
    ///     old behaviour carried the numbers across the switch and then relied on `applyDetail`'s veto
    ///     to leave them unwritten — the panel showed 70 on a slider that could no longer do anything,
    ///     and the first thing the user did with it was "why did my colour NR stop working";
    ///   · the defaults are the *body's*, not zero (`nil` = 50 for colour NR on a Leica, 100 for
    ///     sharpness on an R5), so "back to default" must be `.identity`, never a literal;
    ///   · it is written in the **same** `applyEdit` as the version, so one ⌘Z takes back both halves.
    ///
    /// `false` when the version is already the document's, so a picker reporting its own state cannot
    /// mint empty snapshots (and cannot silently reset four sliders either).
    @discardableResult
    public func decoderVersion(_ spelling: String, offered: [String]) -> Bool {
        let stored: String? = (spelling == "8" && (offered.isEmpty || offered.contains("8"))) ? nil : spelling
        guard stored != session.edit.decoderVersion else { return false }
        session.applyEdit {
            $0.decoderVersion = stored
            // The same edit, not a second one: 版本 + 四轴 = 一条历史 (see the type's own note above).
            $0.detailSettings = .identity
        }
        // 077: 换解码版本是**一个命令**，不参与"同参数连续拖动"的合并。
        return session.commitEdit(label: "解码模型", coalesce: false)
    }

    // MARK: one parameter

    /// Double-click on a row's name: that field back to its own default. One snapshot; `false` when it
    /// was already there.
    @discardableResult
    public func field(_ keyPath: WritableKeyPath<EditModel, Double>, label: String) -> Bool {
        let fallback = EditModel.neutral[keyPath: keyPath]
        guard session.edit[keyPath: keyPath] != fallback else { return false }
        session.applyEdit { $0[keyPath: keyPath] = fallback }
        // 077: 双击复位是一个命令（默认值那一下），不折进它前面那次拖动。
        return session.commitEdit(label: label, coalesce: false)
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
        let committed = session.commitEdit(label: axis.title, coalesce: false)
        loupe?.endDetailAdjustment()
        return committed
    }

    // MARK: 黑白 (S3.4, 2026-10-28)

    /// The 黑白 switch, as **one** document edit and **one** history entry.
    ///
    /// `coalesce: false` for 077's reason (`decoderVersion`, the double-click resets): a switch is a
    /// discrete command, so 开 → 关 → 开 must be three rows, not one folded into the drag before it.
    /// Like those verbs it writes nothing when the document is already there, so a `Toggle` that
    /// reports its own state cannot mint an empty snapshot.
    ///
    /// **It does not touch the eight mixes.** Switching back to colour leaves them in the document
    /// (they encode nothing while the switch is off, and `EditModel.keyMaterial(.bw)` is what keeps a
    /// cached colour frame unaware of them), which is exactly what makes 「关掉置灰、不归零，重新打开
    /// 值就回来」 true.
    @discardableResult
    public func blackAndWhite(_ on: Bool) -> Bool {
        guard session.edit.color.blackAndWhite != on else { return false }
        session.applyEdit { $0.color.blackAndWhite = on }
        return session.commitEdit(label: InspectorView.Section.blackAndWhite.title, coalesce: false)
    }

    /// Double-click on one 黑白混合 row's name: **that** band's mix back to 0, one snapshot.
    ///
    /// The band index is table state, so it is an argument here rather than something this type could
    /// look up (the same rule as `hslField`): the row the user double-clicked is the row the panel drew.
    /// 0 is the field's own default — `HSLBand()` is all zeros, i.e. "this hue deposits exactly its own
    /// lightness", so the grey is the plain OKLab lightness again at that hue.
    ///
    /// This verb does **not** consult the switch. The card already makes an off row inert
    /// (`SliderRow.enabled` → `.disabled`), so「能双击的标签」and「活着的滑杆」are the same set; a verb
    /// that also refused while the switch is off would put the same rule in two places and let them
    /// disagree after a change to either. What it does write is exactly one band's mix: the other seven
    /// bands, the switch, and the three HSL axes keep what they hold.
    @discardableResult
    public func blackAndWhiteField(_ band: Int) -> Bool {
        guard session.edit.color.bands.indices.contains(band),
              session.edit.color.bands[band].mix != 0 else { return false }
        session.applyEdit { model in
            guard model.color.bands.indices.contains(band) else { return }
            model.color.bands[band].mix = 0
        }
        // The undo label is the row's own title (the band's name), like every other card's row.
        return session.commitEdit(label: HSLBands.bandNames[band], coalesce: false)
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
        return session.commitEdit(label: isTemperature ? "色温" : "色调", coalesce: false)
    }

    // MARK: a whole card

    /// 派单 051: 双击曲线卡标题 = **四张表一起**回恒等 — one snapshot.
    ///
    /// Not a `Group` case: `Group` is the enum `PanelResetTests` holds to exactly four cards
    /// (白平衡/Light/Color/细节), and the curve is its own kind of default — "四张 4096 点表逐字节回到
    /// `i/(N−1)`", which is what lets the kernel take its copy branch again (`CurveLUT.isIdentity`).
    /// Adding a case there would change the meaning of an existing list to make room for a verb that
    /// is not a field group.
    ///
    /// The guard is `CurveLUT.isIdentity` and not "已经等于 identity": a curve that is not literally
    /// `CurvePoint.linear` but whose tables are the identity has nothing to write, and writing it would
    /// put a snapshot in the history that ⌘Z would undo into the same picture.
    @discardableResult
    public func curve() -> Bool {
        guard !CurveLUT.isIdentity(session.edit.curve) else { return false }
        session.applyEdit { $0.curve = .identity }
        return session.commitEdit(label: InspectorView.Section.curve.title, coalesce: false)
    }

    /// Double-click on a card's title: the whole card back to its defaults in **one** snapshot.
    @discardableResult
    public func hsl() -> Bool {
        guard session.edit.color.hasBands || session.edit.color.hasGlobal else { return false }
        session.applyEdit {
            $0.color.bands = ColorGroup.identityBands
            $0.color.global = HSLBand()
        }
        return session.commitEdit(label: InspectorView.Section.hsl.title)
    }

    /// Double-click on one of the HSL card's three rows: **that** band's field back to 0 (its own
    /// default — `HSLBand()` is all zeros, which is "this band does nothing"), one snapshot. Band 8 is
    /// 全局 (101), the same three fields on `color.global`.
    ///
    /// The band index is view state, so it is an argument here rather than something this type could
    /// look up: the row the user double-clicked is the row the panel drew.
    @discardableResult
    public func hslField(_ band: Int, _ axis: HSLAxis) -> Bool {
        let isGlobal = band == ColorGroup.bandCount
        guard isGlobal || session.edit.color.bands.indices.contains(band) else { return false }
        let current = isGlobal ? session.edit.color.global : session.edit.color.bands[band]
        let already: Bool
        switch axis {
        case .hue: already = current.hue == 0
        case .saturation: already = current.saturation == 0
        case .luminance: already = current.luminance == 0
        }
        guard !already else { return false }
        session.applyEdit { model in
            if isGlobal {
                switch axis {
                case .hue: model.color.global.hue = 0
                case .saturation: model.color.global.saturation = 0
                case .luminance: model.color.global.luminance = 0
                }
                return
            }
            guard model.color.bands.indices.contains(band) else { return }
            switch axis {
            case .hue: model.color.bands[band].hue = 0
            case .saturation: model.color.bands[band].saturation = 0
            case .luminance: model.color.bands[band].luminance = 0
            }
        }
        return session.commitEdit(label: axis.title)
    }

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
            // The card's own scope, taken from the card's own table (`lightRows`) — so adding a
            // seventh slider to Light resets it without touching this function. (The two absolute
            // levels it used to clear are gone with schema 11.)
            let rows = InspectorView.lightRows
            let neutral = EditModel.neutral
            let changed = rows.contains {
                session.edit[keyPath: $0.keyPath] != neutral[keyPath: $0.keyPath]
            }
            guard changed else { return false }
            session.applyEdit { model in
                for row in rows { model[keyPath: row.keyPath] = neutral[keyPath: row.keyPath] }
            }
            // 白平衡 is *not* in this group: it is its own card and its own double-click. One
            // `applyEdit` + one `commitEdit` = one snapshot, which is the whole point.
            return session.commitEdit(label: group.title, coalesce: false)

        case .color:
            // 076: **vibrance and saturation only.** The eight bands are the HSL card's (S3.6), with
            // their own title reset (`resets.hsl()`); letting this verb write them would make a
            // double-click on Color undo work done on another card.
            guard session.edit.color.vibrance != 0 || session.edit.color.saturation != 0 else {
                return false
            }
            session.applyEdit { model in
                model.color.vibrance = 0
                model.color.saturation = 0
            }
            // 077: 双击复位是命令，不参与合并。
            return session.commitEdit(label: group.title, coalesce: false)

        case .blackAndWhite:
            // 2026-10-28: the card's **own** two things — the switch and the eight mixes — back to
            // `ColorGroup.identity` in one snapshot: 黑白 off, eight zeros. vibrance/saturation belong
            // to Color and the three HSL axes to the HSL card, so a double-click here must not undo
            // work done on either (076's rule for `.color`, read the other way round).
            guard session.edit.color.blackAndWhite || session.edit.color.hasMix else { return false }
            session.applyEdit { model in
                model.color.blackAndWhite = false
                for i in 0..<min(model.color.bands.count, ColorGroup.bandCount) {
                    model.color.bands[i].mix = 0
                }
            }
            return session.commitEdit(label: group.title, coalesce: false)

        case .detail:
            // All four `nil` = 停在机身的基线位置 (0/50/0/50 on a Leica) — *not* 0, which would turn
            // Apple's colour noise reduction off and move the pixels. The card's first row is the
            // 解码模型, so the same double-click also takes it back to **V8** (the default): a reset
            // that left the card on V9 would restore four sliders and then grey them out again.
            //
            // 2026-10-28 (096): 色差已搬到校正卡 — this card's title no longer touches `optics`.
            let changed = !session.edit.detailSettings.isIdentity || session.edit.decoderVersion != nil
            guard changed else { return false }
            session.applyEdit {
                $0.detailSettings = .identity
                $0.decoderVersion = nil
            }
            let committed = session.commitEdit(label: group.title, coalesce: false)
            loupe?.endDetailAdjustment()
            return committed

        case .correction:
            // 096: 色差 R / 色差 B back to `OpticsGroup.identity` in **one** snapshot — the card is one
            // thing on screen, so one double-click is one ⌘Z. `false` when both are already 0, so a
            // stray double-click cannot mint an empty snapshot (or truncate the redo branch).
            guard !session.edit.optics.isIdentity else { return false }
            session.applyEdit { $0.optics = .identity }
            return session.commitEdit(label: group.title, coalesce: false)

        case .effects:
            // 2026-10-28: the whole card — 暗角's four numbers **and** 颗粒's four — back to
            // `EffectsGroup.identity` in one snapshot. The card is one thing on screen, so one
            // double-click is one ⌘Z; the reference is the group's own default initializer (grain
            // amount 0, size 25, roughness 50, seed 0), never a literal, which is what keeps
            // 「默认不是 0」 true for the three rows whose default is not.
            guard session.edit.effects != EffectsGroup.identity else { return false }
            session.applyEdit { $0.effects = .identity }
            return session.commitEdit(label: group.title, coalesce: false)

        case .colorGrading:
            // 2026-10-28 (P0 色彩分级): the card's own nine numbers, back to `ColorGradingGroup.identity`
            // (all zeros) in one snapshot. Nothing else is touched — not `color.vibrance` (Color's), not
            // the bands (HSL's) — which is 076's rule for `.color` read from the other side: a
            // double-click on this card must not undo work done on another one.
            //
            // The padded `guard` is what keeps a stray double-click from minting an empty snapshot (and
            // truncating a redo branch): nothing changed, nothing written.
            guard !session.edit.colorGrading.isIdentity else { return false }
            session.applyEdit { $0.colorGrading = .identity }
            return session.commitEdit(label: group.title, coalesce: false)
        }
    }

    // MARK: 082 — 裁切卡的四个分区复位

    /// One **section** of the 裁切 card back to its default: **one** document edit, **one** history
    /// row, and the crop tool's draft re-seeded so the frame on screen is the frame just written.
    ///
    /// The user asked for exactly this shape: 「每个分区小标题双击 = 该分区复位（比例/角度/旋转/镜像
    /// 各一条历史）」. The four sections are not four kinds of state: 角度 and 旋转 read/write the
    /// **document's** geometry (`rotationDegrees`, `quarterTurns`) while the slider's live value is the
    /// draft's copy, so a reset that only touched the draft would show 0° and leave the picture
    /// straight — the wrong half. It is written once and the draft follows it.
    ///
    /// `nil` (no change) writes nothing, so a double-click on a section that is already at its default
    /// cannot mint an empty snapshot or truncate the redo branch.
    @discardableResult
    public func cropSection(_ section: CropSection) -> Bool {
        switch section {
        case .crop:
            // 比例 / 裁切框: the whole frame, no constraint. The draft's lock follows (`setLock`), so
            // the popup and the frame agree the moment the row redraws.
            return cropGeometryVerb(label: section.title) { geometry in
                guard geometry.cropRect != .full || geometry.aspectLock != .original else { return false }
                geometry.cropRect = .full
                geometry.aspectLock = .original
                return true
            }

        case .angle:
            // 滑块角度 / 实际角度: the straighten back to 0. `quarterTurns` and both flips keep what
            // they hold — 旋转 and 镜像 are their own sections (076's rule, read here).
            return cropGeometryVerb(label: section.title) { geometry in
                guard geometry.straightenDegrees != 0 else { return false }
                geometry.rotationDegrees = 0
                return true
            }

        case .rotation:
            // 旋转: back to 0° **by turning the rect back with it** — `GeometryGroup.turn` is the only
            // place that knows a quarter turn also rewrites the crop rect and inverts the lock, so
            // this verb calls it instead of assigning `quarterTurns = 0` (which would silently re-crop
            // the picture). All of it inside the one `applyEdit` = one row.
            let turns = GeometryGroup.normalizedQuarterTurns(session.edit.geometry.quarterTurns)
            guard turns != 0 else { return false }
            return cropGeometryVerb(label: section.title) { geometry in
                // `turn(clockwise: false)` steps the count back by one (it is `+3 mod 4`), so one
                // counter-clockwise turn per turn taken lands on 0 — not `4 − turns` of them, which
                // would land on `2·turns` mod 4 (measured: 1 turn → 2).
                for _ in 0..<turns {
                    geometry.turn(clockwise: false)
                }
                return true
            }

        case .mirror:
            return cropGeometryVerb(label: section.title) { geometry in
                guard geometry.flipHorizontal || geometry.flipVertical else { return false }
                geometry.flipHorizontal = false
                geometry.flipVertical = false
                return true
            }
        }
    }

    /// 双击卡标题 = **整卡复位**: 裁切 / 角度 / 旋转 / 镜像 一起回默认，**一条**历史（·⌘Z 一次）。
    ///
    /// Not a `Group` case: `Group` is the parameter cards' enum, and this verb's default is a whole
    /// `GeometryGroup` — crop full, angle 0, no turn, no flips — which is `GeometryGroup.identity`
    /// itself, the document's own default initializer and never a literal.
    @discardableResult
    public func cropGeometry() -> Bool {
        guard session.edit.geometry != .identity else { return false }
        return cropGeometryVerb(label: InspectorView.Section.crop.title) { geometry in
            let changed = geometry != .identity
            geometry = .identity
            return changed
        }
    }

    /// The one writer both crop resets go through: close the tool session (072/077's rule for a
    /// discrete geometry action inside a crop session), write, commit **one** row, reopen, and hand
    /// the new document back to the draft.
    private func cropGeometryVerb(label: String,
                                  _ mutate: (inout GeometryGroup) -> Bool) -> Bool {
        let inSession = session.isToolSessionActive
        if inSession { session.endToolSession(label: "裁切与旋转") }
        var changed = false
        session.applyEdit { model in changed = mutate(&model.geometry) }
        let committed = changed ? session.commitEdit(label: label, coalesce: false) : false
        if inSession { session.beginToolSession("裁切", label: "裁切与旋转") }
        if changed {
            loupe?.afterCropGeometryReset()
        }
        return committed
    }

    // MARK: 色彩分级 (S3.8, 2026-10-28)

    /// Double-click on one of the card's nine rows: **that** number back to its own default (0, i.e. "this
    /// axis of this wheel does nothing"), one snapshot, `coalesce: false` — a reset is a discrete command,
    /// not the continuation of the drag before it (the same rule `blackAndWhiteField` follows).
    ///
    /// `row` is a table value, so the row a test resets is the row the card drew.
    @discardableResult
    public func colorGradingField(_ row: GradeRow) -> Bool {
        guard session.edit[keyPath: row.region.wheel][row.axis] != row.defaultValue else { return false }
        session.applyEdit { model in
            model[keyPath: row.region.wheel][row.axis] = row.defaultValue
        }
        return session.commitEdit(label: row.title, coalesce: false)
    }
}

// MARK: - 072 §E — the inspector is inert while 裁切 mode owns the canvas

/// The inspector's hosting view, gated at the **event layer**.
///
/// The user's report was not 「侧栏要变灰」 but 「同时拖侧栏与裁切框时，侧栏被调节」: the panel kept taking
/// drags while the crop frame was being dragged, so one hand's gesture was split between two controls
/// and the document changed under a crop the user had not applied. Greying the rows would not fix that
/// (a greyed slider still swallows the press; a greyed row still says "right panel"), so the gate is
/// where the event enters the panel: while `isEditingGated`, `hitTest` answers `nil` for the whole
/// subtree, which means no AppKit control and no SwiftUI row inside it can be pressed, dragged, typed
/// into, scrolled or focused. Nothing about the panel's *content* changes, and the moment the tool
/// closes the same view is live again (one property, flipped by `LoupeController.onCropModeChange`).
///
/// 缩放控制条 is **not** in here: it lives on the canvas (`ZoomGlassSlider`), which is why §E4 can keep
/// it live without weakening §E1.
///
/// 2026-10-27 — the *decision* of when to gate moved to `WorkspaceRootView.updateInspectorGate()`,
/// because it now has two inputs: the crop mode and the workspace. 变换 is exempt (that card **is** the
/// crop tool's controls — 宽高比, 角度, 应用/取消), every other workspace is gated
/// exactly as §E1 measured. This class only implements one bool.
public final class InspectorHostingView: NSHostingView<InspectorView> {

    /// True while 裁切 mode is on. Set from the workspace, which owns both halves.
    public var isEditingGated: Bool = false {
        didSet {
            guard isEditingGated != oldValue else { return }
            // A press that was already in flight when the tool opened must not finish inside the
            // panel: drop first responder and let AppKit rebuild the cursor rects.
            if isEditingGated, let window, window.firstResponder === self {
                window.makeFirstResponder(nil)
            }
            window?.invalidateCursorRects(for: self)
        }
    }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isEditingGated else { return nil }
        return super.hitTest(point)
    }
}

// 「自动黑电平」图标的框探针搬到 `BlackLevelAutoProbe.swift`：
// 060 的 SliderStyleTests 禁止本文件出现 AppKit 包装视图（面板里只许 SwiftUI Slider），
// 而探针必须是真的 NSView —— 与 ChromaticAberrationProbe / EffectsRowProbe 同一处理。

// MARK: - the enabled read-back probe

/// Reports the `isEnabled` SwiftUI actually resolved for one slider row.
///
/// Why a probe and not a control: on macOS 27 a SwiftUI `Slider` is drawn by SwiftUI itself — there is
/// no AppKit slider in the subview tree (055/060 measured it, `SliderStyleTests` records the same) — and
/// the accessibility tree is empty in a test run, so "is this row live?" has no AppKit property to
/// read. A child of the row that reads `@Environment(\.isEnabled)` **is** the answer: `.disabled(!enabled)`
/// is what writes that environment value, so a bug that dropped the modifier reads back `true` here.
///
/// Inert in production (a zero-size clear rectangle); the log is only ever read by the tests.
struct DetailRowEnabledProbe: View {
    let title: String
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear { DetailRowEnabledLog.shared.record(title: title, isEnabled: isEnabled) }
            .onChange(of: isEnabled) { _, new in
                DetailRowEnabledLog.shared.record(title: title, isEnabled: new)
            }
    }
}

/// Where `DetailRowEnabledProbe` reports to. A tiny lock-guarded table, keyed by the row's title.
public final class DetailRowEnabledLog: @unchecked Sendable {
    public static let shared = DetailRowEnabledLog()
    private let lock = NSLock()
    private var values: [String: Bool] = [:]

    public func record(title: String, isEnabled: Bool) {
        lock.lock(); values[title] = isEnabled; lock.unlock()
    }
    public func reset() {
        lock.lock(); values.removeAll(); lock.unlock()
    }
    public func value(_ title: String) -> Bool? {
        lock.lock(); defer { lock.unlock() }; return values[title]
    }
    public var snapshot: [String: Bool] {
        lock.lock(); defer { lock.unlock() }; return values
    }
}
