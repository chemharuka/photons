import PhotonsCore

/// 325 — **复制清单的每一项，都对着调整栏的某一行（或某个 block）；对照只此一份。**
///
/// The user's rule (325 §0): 「复制界面，各调整的名称严格按照现在UI上的来……以后修改调整栏的布局时，
/// 不会漏掉调整复制界面」. The panel's rows have lived in one table per card since 125
/// (`InspectorView.PanelCardSpec`); the copy sheet had a second, hand-written table of names
/// (`EditSnapshotChild.title`) that nobody compared row by row — which is how 「高光恢复」 survived a
/// year after the slider was gone, and why 白 / 黑 / 自然饱和度 / 饱和度 had drifted.
///
/// So this file holds the **pairing** and nothing else: no names, no sections, no row counts. A
/// selector names a document field (or a block); everything drawn for the item — its label, its card,
/// its tooltip's list of rows — is read back out of `PanelCardSpec`. Consequences, all of them tested
/// (`CopySheetCoverageTests`):
///
///   · adding a row to a spec card without a copy item turns the coverage test red (that is the
///     ticket's actual ask: a layout edit cannot silently skip the clipboard);
///   · renaming a panel row renames the copy item — there is no second string to forget;
///   · a child that names a row the panel no longer draws (the old `.highlightRecovery`) is red too,
///     because it resolves to nothing.
///
/// 校准 is the one spec card with **no** items: its seven numbers are one look (a hue without its
/// saturation is a different picture, see `EditSnapshot.filtered`), so the card row itself copies all
/// seven and there is nothing to narrow.
enum CopyRowCoverage {

    /// What one copy item covers: one panel row, or one whole block of a spec card.
    enum Selector: Equatable {
        case row(WritableKeyPath<EditModel, Double>)
        case block(InspectorView.PanelCardSpec.BlockGroup)
    }

    /// Where a selector lands on the panel: the card, the block, and the rows it stands for (one row
    /// for `.row`, the block's own rows — in draw order — for `.block`).
    ///
    /// `section` is the **clipboard's** spelling of the panel card, taken from the card's own
    /// rawValue (`InspectorView.Section` and `EditSnapshotSection` name the same six cards). Nothing
    /// here writes a section pair down, so a card renamed on one side is a red test, not a silent
    /// mismatch.
    struct Placement {
        let spec: InspectorView.PanelCardSpec
        let section: EditSnapshotSection
        let block: InspectorView.PanelCardSpec.Block
        let rows: [InspectorView.ToneRow]
    }

    /// **The pairing.** Twenty-two items over the twenty-seven rows of the six spec cards:
    ///
    ///   · Light 7 (曝光 对比 高光 中间调 阴影 白色 黑色) — one item each;
    ///   · Color 2 (自然饱和 饱和) — one item each;
    ///   · 校正 5 (色差 R/B + 暗角 block) — 2 row items + the 3-row 暗角 block;
    ///   · 细节 8 (纹理 清晰度 去噪 去彩噪 + 锐化四参) — one item each;
    ///   · 效果 5 (去雾 + 颗粒 block's 4) — 1 row item + the 4-row 颗粒 block.
    ///
    /// The order is the `allCases` order of the children it names, so the sheet's parameter rows read
    /// in the panel's order without a second sort key.
    static let selectors: [EditSnapshotChild: Selector] = [
        .exposure: .row(\.light.exposure),
        .contrast: .row(\.light.contrast),
        .highlights: .row(\.light.highlights),
        .midtones: .row(\.light.midtones),
        .shadows: .row(\.light.shadows),
        .whites: .row(\.light.whites),
        .blacks: .row(\.light.blacks),

        .vibrance: .row(\.color.vibrance),
        .saturation: .row(\.color.saturation),

        .caRed: .row(\.optics.caRed),
        .caBlue: .row(\.optics.caBlue),
        // 暗角 is one row on the card and three numbers in the payload; the item covers the block,
        // because a vignette with a copied amount and an uncopied feather is another look.
        .vignette: .block(.vignette),

        .texture: .row(\.effects.texture),
        .clarity: .row(\.effects.clarity),
        .nonBayerLuminance: .row(\.effects.nonBayerLuminanceNR),
        .nonBayerColor: .row(\.effects.nonBayerColorNR),
        .sharpenAmount: .row(\.sharpen.amount),
        .sharpenRadius: .row(\.sharpen.radius),
        .sharpenDetail: .row(\.sharpen.detail),
        .sharpenMasking: .row(\.sharpen.masking),

        .dehaze: .row(\.effects.dehaze),
        // Same rule as 暗角: 颗粒数量/大小/粗糙度/种子 are one look.
        .grain: .block(.grain),
    ]

    /// Where `selector` lands, or `nil` when the panel draws nothing for it — the state a stale child
    /// is in, and the reason the coverage test can go red in the reverse direction.
    ///
    /// `specs` is a parameter so a test can hand in a **mutated** panel table (a fake row, a row moved
    /// between cards) and prove the checker notices; the app always passes the shipped table.
    static func placement(of selector: Selector,
                          in specs: [InspectorView.PanelCardSpec] = InspectorView.PanelCardSpec.all)
        -> Placement? {
        switch selector {
        case .row(let keyPath):
            for spec in specs {
                guard let section = EditSnapshotSection(rawValue: spec.section.rawValue) else { continue }
                for block in spec.blocks {
                    if let row = block.rows.first(where: { $0.keyPath == keyPath }) {
                        return Placement(spec: spec, section: section, block: block, rows: [row])
                    }
                }
            }
            return nil
        case .block(let group):
            for spec in specs {
                guard let section = EditSnapshotSection(rawValue: spec.section.rawValue) else { continue }
                if let block = spec.block(group: group), !block.rows.isEmpty {
                    return Placement(spec: spec, section: section, block: block, rows: block.rows)
                }
            }
            return nil
        }
    }
}

extension EditSnapshotChild {

    /// This item's slot on the panel — `nil` for the children of cards whose body is not a `ToneRow`
    /// table (白平衡, 黑电平, 黑白, HSL, 色彩分级, 曲线, 开发, 裁切).
    var panelPlacement: CopyRowCoverage.Placement? {
        guard let selector = CopyRowCoverage.selectors[self] else { return nil }
        return CopyRowCoverage.placement(of: selector)
    }

    /// The panel rows this item copies, in draw order. Empty for a non-spec card (and for a child that
    /// names a row the panel no longer draws — the coverage test fails on that one).
    var panelRows: [InspectorView.ToneRow] { panelPlacement?.rows ?? [] }

    /// **The item's label: the panel's own string** (325).
    ///
    ///   · an item over one row takes that row's `ToneRow.title`, byte for byte — 白色, 黑色,
    ///     自然饱和, 饱和, 色差 R … all of them the panel's words, not the sheet's;
    ///   · an item over a whole block takes the block's name (`BlockGroup.title` — 暗角 / 颗粒), which
    ///     lives beside the rows it covers;
    ///   · a child of a card with no row table keeps `standaloneTitle`, whose strings sit beside the
    ///     body that draws them.
    ///
    /// There is no fourth case and no override: a name that is not derived one of these three ways
    /// cannot be written down.
    var title: String {
        if case .block(let group)? = CopyRowCoverage.selectors[self], let name = group.title {
            return name
        }
        if let row = panelRows.first { return row.title }
        if let standalone = standaloneTitle { return standalone }
        // Unreachable: every case either sits on a spec card or carries a `standaloneTitle`.
        // A child that reaches this line is a child the panel does not draw, which the coverage test
        // reports before anything ships.
        return rawValue
    }
}
