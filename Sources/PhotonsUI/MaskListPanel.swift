import SwiftUI
import PhotonsCore

/// The mask panel: what exists, which one is selected, what a drag on the canvas means, and every
/// number the selected mask owns — the three brush numbers (Q22), the mask-level parameters
/// (`opacity` / `invert` / `feather` / `refine` / the component's blend mode) and the whole
/// `LocalAdjustments` set (Q28).
///
/// A leaf view like the rest of the inspector: it holds **no** copy of anything. Selecting a mask,
/// arming the brush, toggling the overlay and dragging any slider all write straight into
/// `CatalogSession` — the same object the canvas and the loupe read — which is what keeps the three
/// surfaces from drifting apart.
///
/// Two deliberate choices, both about history granularity:
///   · brush size / hardness / flow are **view state**, not document state. Each stroke stores its
///     own `radius`/`feather`/`flow` when it is painted (§2), so moving these sliders must never
///     rewrite a stroke already on the photo — and must not grow the undo stack.
///   · 显示蒙版 is view state too: it repaints the last pass and nothing else, so ⌘Z after toggling
///     it does not turn the overlay off (`MaskViewState`).
///
/// A third rule arrived with the parameters: every **document** slider is one snapshot per gesture,
/// never one per tick. The drag writes through `writeMask(commit: false)` — `applyEdit`, so the
/// revision moves and the loupe's 50 ms debounce turns a hundred ticks into a few frames — and the
/// mouse-up calls `commitEdit` once. Committing per tick would make ⌘Z walk back 1/100 EV at a time.
///
/// **The rows are the panel's rows, not this card's.** Every number here goes through `SliderRow`
/// (the same view the tone cards, 白平衡, 细节 and 黑电平 draw), and every parameter is a row of a
/// table (`MaskSliderRow` / `MaskShapeSliderRow`). So the three interactions the rest of the panel
/// promises — double-click a name to reset it, click the number to type it (`↵` commits, `Esc`
/// cancels, out of range clamps), the same label/number/track style — are properties of the row view
/// rather than things this file remembered to do. The card's own title takes the group gesture
/// (`PanelResets.maskCard(_:)`: this mask's parameter surface, one snapshot).
public struct MaskListPanel: View {
    @Bindable public var session: CatalogSession
    /// The canvas the eyedropper arms. `nil` in tests / previews: the picker buttons are then
    /// disabled, exactly like the white-balance dropper without a loupe.
    public let loupe: LoupeController?

    /// The name being typed. View state, deliberately: a keystroke must not grow the undo stack, so
    /// the document is written once — on ⏎ or the ✓ — and this is only what the field shows.
    @State private var nameDraft: String = ""
    /// Which mask picker this panel armed. View state, like the brush and the overlay: not in the
    /// document, not in history, not in a key. The loupe owns the actual armed flag (Esc clears it
    /// without a SwiftUI event), so this only remembers *what* the next click means.
    @State private var armedEyedropper: MaskEyedropperKind?

    public init(session: CatalogSession, loupe: LoupeController? = nil) {
        self.session = session
        self.loupe = loupe
    }

    private var masks: [Mask] { session.edit.masks }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            list
            divider
            tools
            healSection
            if let mask = selectedMask {
                maskSection(mask)
                // 2026-10-30（用户）：「亮度选择 / 色彩选择这些应该放在更加上方的位置」。
                // 形状与它的选择控件（吸管、亮度范围条、颜色样本与范围）原来排在**最下面**，
                // 用户以为功能没做。现在紧跟名称/类型，在 反转 / 混合 / 调整 之前：
                // 先选「选哪块画面」，再调「这块画面对它做什么」。
                shapeSection(for: mask)
                // The brush numbers belong to a brush mask; a gradient's own parameters are below.
                if selectedIsBrush { dividers }
                adjustmentsSection(mask)
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
        // The readback seam `--ui-smoke` uses to prove these controls are in the live view tree
        // (SwiftUI sliders are not `NSSlider`s a test can count). 1 × 1 pt, never a hit target.
        .background(
            MaskPanelProbeHost(rows: parameterLabels,
                               listOrder: masks.map(\.name),
                               selectedName: selectedMask?.name ?? "")
                .frame(width: 1, height: 1)
        )
        // 139 — the picker is a mode on the canvas, so leaving the mask (or the photo) must not leave
        // it armed for a click that now means something else. Esc is handled by the canvas itself.
        .onChange(of: session.selectedMaskID) { _, _ in cancelMaskEyedropper() }
        .onChange(of: session.anchorID) { _, _ in cancelMaskEyedropper() }
        .onDisappear { cancelMaskEyedropper() }
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 6) {
            // 双击卡片标题 = 整张卡复位（其它卡一样）：这张卡没有「整组」的 `PanelResets.Group`
            // 分支（蒙版是列表），默认是**这一张蒙版**的参数面（见 `PanelResets.maskCard(_:)`）。
            Text("蒙版")
                .font(.system(size: 11, weight: .bold))
                .modifier(ResetOnDoubleClick(
                    action: { if let id = session.selectedMaskID { resets.maskCard(id) } },
                    help: InspectorView.resetGroupHelp))
            Text("\(masks.count)/\(Mask.maxCount)")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 4)
            newMaskMenu
            Button {
                if let id = session.selectedMaskID { session.deleteMask(id) }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .controlSize(.mini)
            .disabled(session.selectedMaskID == nil)
            .help("删除选中的蒙版")
        }
    }

    /// 新建 — one menu, six shapes (005/M4's whole union, not just the brush).
    ///
    /// 线性/径向 arm a drag instead of creating immediately: the mask is born with the geometry the
    /// user draws and lands in the document on mouse-up, so ⌘Z takes the whole thing back in one
    /// press. 语义 opens the submenu of kinds the OS can answer.
    private var newMaskMenu: some View {
        Menu {
            ForEach(MaskCreationKind.allCases, id: \.rawValue) { kind in
                if kind == .semantic {
                    Menu(kind.label) {
                        ForEach(SemanticKind.allCases, id: \.rawValue) { semantic in
                            Button(semantic.displayName) {
                                session.createMask(.semantic, semanticKind: semantic)
                            }
                        }
                    }
                } else {
                    Button {
                        session.createMask(kind)
                    } label: {
                        Label(kind.label, systemImage: kind.symbol)
                    }
                }
            }
        } label: {
            Image(systemName: "plus")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .controlSize(.mini)
        .disabled(masks.count >= Mask.maxCount || session.anchorAsset == nil)
        .help("新建蒙版：画笔 / 线性 / 径向 / 颜色范围 / 亮度范围 / 语义")
    }

    // MARK: the list

    @ViewBuilder private var list: some View {
        if masks.isEmpty {
            Text("还没有蒙版。新建一个，然后在画面里拖动画笔。")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(spacing: 1) {
                ForEach(masks, id: \.id) { mask in
                    row(mask)
                }
            }
        }
    }

    private func row(_ mask: Mask) -> some View {
        let selected = session.selectedMaskID == mask.id
        return HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(selected ? Color.accentColor : Color.clear)
                .frame(width: 3, height: 13)
            Text(mask.name)
                .font(.system(size: 10, weight: selected ? .semibold : .regular))
                .foregroundStyle(mask.isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                .lineLimit(1)
            Spacer(minLength: 4)
            // "径向渐变 · 局部 2 项": what it is, and how much of it is doing something. A mask with
            // no adjustments is S1.6's identity branch, and the row says "0 项" instead of implying
            // it changes pixels.
            Text(MaskRowSummary.text(mask))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Button {
                session.setMaskEnabled(mask.id, !mask.isEnabled)
            } label: {
                Image(systemName: mask.isEnabled ? "eye" : "eye.slash")
            }
            .buttonStyle(.borderless)
            .controlSize(.mini)
            .help(mask.isEnabled ? "停用" : "启用")
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 3)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(selected ? Color.primary.opacity(0.06) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { session.selectMask(mask.id) }
    }

    // MARK: mask-level parameters

    /// 不透明度 / 羽化 / 精修 / 反转 / 混合 — the mask's own fields (005/M4 §2), plus the rename field
    /// and the ▲▼ that move it in the list.
    ///
    /// The blend picker edits the **active** component's `op`. Core ignores the first component's op
    /// ("The first component's `op` is ignored"), so the picker is disabled while the selected mask
    /// holds a single component: a control that writes a field nothing reads is worse than no control.
    private func maskSection(_ mask: Mask) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Text("蒙版级")
                    .font(.system(size: 10, weight: .bold))
                Spacer(minLength: 4)
                Button {
                    session.moveMask(mask.id, by: -1)
                } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.borderless)
                .controlSize(.mini)
                .disabled(!session.canMoveMask(mask.id, by: -1))
                .help("上移（列表与 develop_json 的数组顺序）")
                Button {
                    session.moveMask(mask.id, by: 1)
                } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.borderless)
                .controlSize(.mini)
                .disabled(!session.canMoveMask(mask.id, by: 1))
                .help("下移（列表与 develop_json 的数组顺序）")
            }

            HStack(spacing: 4) {
                TextField("名称", text: $nameDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 10))
                    .controlSize(.mini)
                    .onSubmit { commitRename(mask) }
                Button {
                    commitRename(mask)
                } label: {
                    Image(systemName: "checkmark")
                }
                .buttonStyle(.borderless)
                .controlSize(.mini)
                .disabled(nameDraft == mask.name)
                .help("重命名（⏎ 亦可）：改名不进任何键，不重渲，但会进一次历史——Core 的语义比较按值比 masks，名字在内")
            }
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Color.primary.opacity(0.05)))
            .onChange(of: mask.name) { _, next in nameDraft = next }
            .onAppear { nameDraft = mask.name }

            ForEach(MaskSliderRow.level) { row in
                maskRow(row, for: mask)
                    .help(row.help)
            }

            Toggle(isOn: invertBinding(mask)) {
                Text("反转")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .toggleStyle(.checkbox)
            .controlSize(.mini)
            .help("作用在合成后的选区上：1 − a。覆盖面积会翻过来（蒙版内变外）")

            HStack(spacing: 5) {
                Text("混合")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Picker("", selection: combineBinding(mask)) {
                    ForEach(CombineOp.allCases, id: \.rawValue) { op in
                        Text(op.displayName).tag(op)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.mini)
                .fixedSize()
                .disabled(mask.components.count < 2)
                .help(mask.components.count < 2
                      ? "只有一个组件时 Core 忽略 op（第一个组件的运算没有左值）——再加一个组件才生效"
                      : (mask.components.last?.op.help ?? ""))
            }
        }
    }

    // MARK: local adjustments

    /// 局部调整: `amount` plus the ten sliders, straight from `LocalAdjustments`.
    ///
    /// Order and ranges are `MaskAdjustmentParameter`'s (Core's numbers, cited there). The section is
    /// always visible — a disclosure that hides them would also hide the fact that a mask with no
    /// adjustments renders nothing, which is the identity branch S1.6 relies on.
    private func adjustmentsSection(_ mask: Mask) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Text("局部调整")
                    .font(.system(size: 10, weight: .bold))
                Spacer(minLength: 4)
                Text("\(MaskRowSummary.adjustmentCount(mask)) 项")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(MaskSliderRow.adjustments) { row in
                    maskRow(row, for: mask)
                        .help(row.help)
                }
            }
        }
    }

    // MARK: the selected shape's own parameters

    private var selectedMask: Mask? { masks.first { $0.id == session.selectedMaskID } }

    private var selectedComponent: (index: Int, component: MaskComponent)? {
        guard let mask = selectedMask, let index = mask.components.indices.last else { return nil }
        return (index, mask.components[index])
    }

    /// True when the selected mask's active component is a brush — the only case the size / hardness
    /// / flow rows describe.
    private var selectedIsBrush: Bool {
        guard let entry = selectedComponent else { return false }
        if case .brush = entry.component.shape { return true }
        return false
    }

    /// The rows this panel built, in order — what the smoke reads back to prove the controls exist.
    ///
    /// Read off the same table the card iterates (`MaskSliderRow`), so the smoke's list cannot drift
    /// from the rows on screen.
    private var parameterLabels: [String] {
        MaskSliderRow.level.map(\.title) + ["反转", "混合"] + MaskSliderRow.adjustments.map(\.title)
    }

    /// The rows that belong to the shape the mask actually holds.
    ///
    /// Not a picker: a mask's shape is what was drawn, and changing its *kind* would silently throw
    /// away the gesture that made it. So this section only ever edits parameters — the midpoint of a
    /// ramp, the radius of an ellipse, a tolerance — and every write goes through
    /// `setMaskComponentShape`, with one commit per slider gesture (the same drag/release rule the
    /// Light card follows, so ⌘Z is one step and not one per tick).
    @ViewBuilder private func shapeSection(for mask: Mask) -> some View {
        if let entry = selectedComponent, let kind = MaskCreationKind.of(entry.component.shape) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Image(systemName: kind.symbol)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Text(kind.label)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Text(shapeDetail(entry.component.shape))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                shapeParameters(for: mask, component: entry.index, shape: entry.component.shape)
                if kind.isAdjustable {
                    Toggle(isOn: adjustBinding) {
                        Text("拖动画面调整形状")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .toggleStyle(.checkbox)
                    .controlSize(.mini)
                    .help("选中线/径向蒙版时，画布上的拖拽改形状（起点↔终点、中心→半径），不再平移画面")
                }
            }
        }
    }

    /// The selected shape's own rows, from its table (`MaskShapeSliderRow.rows(for:)`): the same row
    /// view, the same three interactions and the same numbers the section always had — it just comes
    /// from data now, so 「每一根都有双击复位」 is a property of the table (`MaskSliderRowTests` walks it).
    ///
    /// The colour swatches above 容差 are the one thing here that is not a row: they report what a
    /// mask was sampled from, they are not a control.
    @ViewBuilder private func shapeParameters(for mask: Mask, component: Int,
                                              shape: MaskShape) -> some View {
        if case .luminanceRange(let l0) = shape {
            maskEyedropperRow(.luminance)
            // 2026-10-30（用户）：「新增功能放在最底下了」—— 范围条原来排在 下限/上限 数字行**下面**，
            // 看起来像是附属物。它是这两个数字的可视化入口，应该紧跟吸管、在数字行**上面**：
            // 先看范围（图形），再微调数值。
            MaskRangeBar(shape: l0) { next, commit in
                session.setMaskComponentShape(
                    mask.id, component: component, shape: .luminanceRange(next),
                    commit: commit, label: "亮度范围条", coalesce: false)
            }
        }
        if case .depthRange = shape, !session.depthAvailable {
            // 120b — a missing measurement is not "everything selected". Say it in the section, not
            // only in a tooltip: the mask currently covers 0.
            Text("这张还没算深度：深度蒙版覆盖为 0（先运行深度，或换一张已算过的照片）")
                .font(.system(size: 9))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("inspector.mask.depthUnavailable")
        }
        if case .colorRange(let c) = shape {
            maskEyedropperRow(.colour)
            sampleSwatches(c)
            colourRangePreview(c)
            Text("样本与选择范围是并集：加样本扩大覆盖，减小选择范围收缩")
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        ForEach(MaskShapeSliderRow.rows(for: shape), id: \.title) { row in
            shapeRow(row, for: mask, component: component, shape: shape)
        }
    }

    // MARK: 139 — pickers and the colour band

    private func maskEyedropperRow(_ kind: MaskEyedropperKind) -> some View {
        MaskEyedropperRow(
            kind: kind,
            isArmed: armedEyedropper == kind && (loupe?.isEyedropperArmed ?? false),
            enabled: loupe != nil) {
                toggleMaskEyedropper(kind)
            }
    }

    /// Arm one picker. A second click on the same button disarms; picking stays armed so several
    /// colour samples can be added in a row (the cap is eight, not one). The loupe owns Esc.
    private func toggleMaskEyedropper(_ kind: MaskEyedropperKind) {
        guard let loupe else { return }
        if loupe.isEyedropperArmed, armedEyedropper == kind {
            cancelMaskEyedropper()
            return
        }
        loupe.cancelEyedropper()
        armedEyedropper = kind
        loupe.armEyedropper(staysArmed: true) { outcome, option in
            guard case .sampled(let sample) = outcome else { return }   // miss: stay armed
            guard let maskID = session.selectedMaskID,
                  let mask = session.edit.masks.first(where: { $0.id == maskID }),
                  let component = mask.components.indices.last else { return }
            switch kind {
            case .luminance:
                session.pickMaskLuminance(maskID, component: component,
                                          at: MaskEyedropper.luminance(from: sample.rgb),
                                          moveNearerEdge: option)
            case .colour:
                session.pickMaskColour(maskID, component: component,
                                       sampleSRGB: MaskEyedropper.colour(from: sample.rgb))
            }
        }
    }

    private func cancelMaskEyedropper() {
        guard armedEyedropper != nil || loupe?.isEyedropperArmed == true else { return }
        armedEyedropper = nil
        loupe?.cancelEyedropper()
    }

    /// The 「当前样本色 → 中性」 band: left end is the newest sample, right end the neutral the range
    /// fades towards. It reports `tolerance`/`smoothness`; it is not a second control.
    private func colourRangePreview(_ c: ColorRangeShape) -> some View {
        let sample = c.samples.last ?? [0.5, 0.5, 0.5]
        let start = Color(.sRGB,
                          red: sample.count > 0 ? sample[0] : 0.5,
                          green: sample.count > 1 ? sample[1] : 0.5,
                          blue: sample.count > 2 ? sample[2] : 0.5)
        return RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(LinearGradient(colors: [start, Color(.sRGB, red: 0.5, green: 0.5, blue: 0.5)],
                                 startPoint: .leading, endPoint: .trailing))
            .frame(height: 8)
            .overlay(RoundedRectangle(cornerRadius: 2)
                .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
            .accessibilityIdentifier("mask.color.rangePreview")
            .help("选择范围：样本色 → 中性；容差越大，带越宽")
    }

    /// What a colour-range mask was sampled from: up to eight swatches, and how many samples it holds.
    private func sampleSwatches(_ c: ColorRangeShape) -> some View {
        HStack(spacing: 5) {
            ForEach(Array(c.samples.prefix(ColorRangeShape.maxSamples).enumerated()), id: \.offset) { _, sample in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color(.sRGB,
                                red: sample.count > 0 ? sample[0] : 0.5,
                                green: sample.count > 1 ? sample[1] : 0.5,
                                blue: sample.count > 2 ? sample[2] : 0.5))
                    .frame(width: 14, height: 10)
                    .overlay(RoundedRectangle(cornerRadius: 2)
                        .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
            }
            Spacer(minLength: 4)
            Text("\(c.samples.count) 个样本")
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
    }

    /// One line of numbers under the shape's name: what a drag just produced, in the document's own
    /// units (so "0.31" is 31 % of the short edge, not a mystery).
    private func shapeDetail(_ shape: MaskShape) -> String {
        switch shape {
        case .linearGradient(let g):
            return String(format: "%.2f,%.2f → %.2f,%.2f", g.start.x, g.start.y, g.end.x, g.end.y)
        case .radialGradient(let g):
            return String(format: "c %.2f,%.2f r %.3f", g.center.x, g.center.y,
                          max(g.radius.x, g.radius.y))
        case .colorRange(let c):
            return String(format: "tol %.2f", c.tolerance)
        case .luminanceRange(let l):
            return String(format: "%.2f – %.2f", l.low, l.high)
        case .depthRange(let d):
            return String(format: "%.2f – %.2f", d.far, d.near)
        case .semantic(let s):
            return "\(s.kind.displayName) · \(s.rasterDigest == nil ? "未生成" : "已生成")"
        case .brush(let b):
            return String(format: "size %.3f", b.size)
        case .unsupported(let kind, _):
            return "未知 \(kind)"
        }
    }

    /// One document row of this card: the panel's row view (`SliderRow`), plus this card's write path.
    ///
    /// Three of 047's contracts now come from the row itself — the name's double-click (`onReset`),
    /// the typeable number (`↵` commits, `Esc` cancels, out-of-range clamps), the label/number/slider
    /// style — and the two that are the card's job stay here: one write per tick (so the pixels
    /// follow the thumb) and **one** `commitEdit` on mouse-up (so ⌘Z is one step).
    private func maskRow(_ row: MaskSliderRow, for mask: Mask) -> some View {
        SliderRow(title: row.title,
                  value: Binding(get: { row.display(mask) },
                                 set: { value in
                                     row.write(value, into: session, maskID: mask.id, commit: false)
                                 }),
                  range: row.range,
                  format: row.format,
                  shape: row.shape,
                  decimals: row.decimals,
                  rounding: row.rounding,
                  accessibilityID: "inspector.mask.\(row.title)",
                  rowIdentifierPrefix: "inspector.mask.row",
                  onReset: { resets.mask(row, in: mask) },
                  onEditingChanged: { editing in
                      if !editing { session.commitEdit(label: row.label) }
                  })
    }

    /// One row of the selected shape (中点 / 半径 / 角度 / 容差 / 下限 / 上限 / 软边).
    ///
    /// Same row view, same interaction; the only difference from `maskRow` is that the value is a
    /// field of the component's `MaskShape`, so the write rebuilds the shape through the row's own
    /// `apply` (which is what keeps the geometry the row does not own).
    private func shapeRow(_ row: MaskShapeSliderRow, for mask: Mask, component: Int,
                          shape: MaskShape) -> some View {
        SliderRow(title: row.title,
                  value: Binding(get: { row.read(shape) },
                                 set: { value in
                                     session.setMaskComponentShape(
                                         mask.id, component: component,
                                         shape: row.apply(shape, value), commit: false, label: "")
                                 }),
                  range: row.range,
                  format: row.format,
                  shape: row.shape,
                  decimals: row.decimals,
                  rounding: row.rounding,
                  accessibilityID: "inspector.mask.\(row.title)",
                  rowIdentifierPrefix: "inspector.mask.row",
                  onReset: { resets.maskShape(row, in: mask, component: component) },
                  onEditingChanged: { editing in
                      if !editing { session.commitEdit(label: row.label) }
                  })
    }

    /// A **view-state** row (the brush). No commit hook on purpose: these numbers are captured by each
    /// stroke, so moving them must not rewrite the picture or grow the undo stack — and their
    /// double-click puts them back on the session's own defaults without a snapshot for the same
    /// reason. It is still the same row: same label, same typeable number, same slider.
    private func brushRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>,
                          format: String, decimals: Int, reset: @escaping () -> Void) -> some View {
        SliderRow(title: title,
                  value: value,
                  range: range,
                  format: format,
                  decimals: decimals,
                  accessibilityID: "inspector.mask.\(title)",
                  rowIdentifierPrefix: "inspector.mask.row",
                  onReset: reset,
                  onEditingChanged: { _ in })
    }

    /// The card's reset verbs — the same object the other cards call, so 「复位」 cannot mean one thing
    /// here and another in `PanelResets`' tests.
    private var resets: PanelResets { PanelResets(session: session) }

    // MARK: tools + brush

    private var tools: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Picker("", selection: toolBinding) {
                    Text("浏览").tag(MaskTool.off)
                    Text("画笔").tag(MaskTool.brush)
                    Text("擦除").tag(MaskTool.erase)
                }
                .pickerStyle(.segmented)
                .controlSize(.mini)
                .labelsHidden()
                .disabled(session.selectedMaskID == nil)
            }
            Toggle(isOn: showBinding) {
                Text("显示蒙版")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .toggleStyle(.checkbox)
            .controlSize(.mini)
            .disabled(session.selectedMaskID == nil)
            .help("红色叠加来自蒙版自己的选区图（S1.5 atlas），不是第二次求值；不产生历史")
        }
    }

    // MARK: 修复画笔 (078 P0-1)

    /// The tool button, the list, and two numbers per spot — nothing else.
    ///
    /// What is deliberately **not** here, so the next reader does not go looking: a drag handle on the
    /// canvas, a hand-placed source point, and a "remove" (content-aware) mode. Spot removal's first
    /// version is clone + heal with the default source one radius to the right; the kernel and the
    /// model already carry the fields the rest would need (`HealSpot.sourceOffset` is editable in the
    /// document, just not by a handle yet).
    private var healSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button {
                    session.healTool.toggle()
                    // One canvas gesture at a time: arming the spot tool disarms the brush.
                    if session.healTool { session.maskTool = .off }
                } label: {
                    Label("修复", systemImage: "bandage")
                        .font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .tint(session.healTool ? Color.accentColor : Color.secondary)
                .accessibilityIdentifier("inspector.heal.tool")
                .help("点画布 = 在点击处加一个修复点；源点自动搜索，关掉自动取源则取右边一个半径")

                Text("\(session.edit.healSpots.count)/\(HealSpot.maxCount)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 4)
                Picker("", selection: healModeBinding) {
                    ForEach(HealMode.allCases, id: \.rawValue) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .controlSize(.mini)
                .labelsHidden()
                .frame(width: 86)
            }
            Toggle("自动取源", isOn: Binding(get: { session.autoHealSource },
                                            set: { session.autoHealSource = $0 }))
                .toggleStyle(.checkbox)
                .font(.system(size: 10))
                .controlSize(.mini)
                .accessibilityIdentifier("inspector.heal.autoSource")
                .help("搜索缺陷周围 2–4 个半径的环形带，取边界最像的一块做源；关掉 = 老行为（右移一个半径）")
            if let source = session.lastHealSource {
                Text(healSourceStatus(source))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .accessibilityIdentifier("inspector.heal.sourceStatus")
            }
            ForEach(session.edit.healSpots) { spot in
                healRow(spot)
            }
        }
    }

    private func healRow(_ spot: HealSpot) -> some View {
        HStack(spacing: 6) {
            Text(spot.mode.label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 26, alignment: .leading)
            Slider(value: Binding(get: { spot.radius },
                                  set: { session.setHealRadius($0, for: spot.id, commit: false) }),
                   in: 0.002 ... 0.2,
                   onEditingChanged: { editing in
                       if !editing { session.commitEdit(label: "修复 半径") }
                   })
            .controlSize(.mini)
            Text(String(format: "%.3f", spot.radius))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
            Button {
                session.deleteHealSpot(spot.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .controlSize(.mini)
            .accessibilityIdentifier("inspector.heal.delete.\(spot.id)")
            .help("删除这个修复点")
        }
        .accessibilityIdentifier("inspector.heal.row.\(spot.id)")
    }

    /// One line of truth about where the last new spot's source came from — the search never
    /// silently falls back, so the panel says which answer the user actually got.
    private func healSourceStatus(_ source: HealSourceResult) -> String {
        switch source.status {
        case .found:
            return String(format: "源：自动（%.1f 个半径）", source.distanceInRadii)
        case .noCandidateAccepted:
            return "源：带内无可用源，用默认"
        case .searchSkipped:
            return "源：默认"
        }
    }

    private var healModeBinding: Binding<HealMode> {
        Binding(get: { session.healMode },
                set: { mode in
                    session.healMode = mode
                    // A mode picked in the panel applies to the spot the panel is pointed at too —
                    // otherwise the segmented control would look like it did nothing on an existing
                    // spot.
                    if let id = session.selectedHealSpotID ?? session.edit.healSpots.last?.id {
                        session.setHealMode(mode, for: id)
                    }
                })
    }

    private var dividers: some View {
        VStack(alignment: .leading, spacing: 4) {
            brushRow("大小", value: brushSizeBinding, range: 0.01 ... 0.5, format: "%.3f",
                     decimals: 3, reset: { session.brushSize = CatalogSession.defaultBrushSize })
            brushRow("硬度", value: brushHardnessBinding, range: 0 ... 1, format: "%.2f",
                     decimals: 2, reset: { session.brushHardness = CatalogSession.defaultBrushHardness })
            brushRow("流量", value: brushFlowBinding, range: 0.05 ... 1, format: "%.2f",
                     decimals: 2, reset: { session.brushFlow = CatalogSession.defaultBrushFlow })
        }
    }

    // MARK: bindings (every one writes through the session)

    private var toolBinding: Binding<MaskTool> {
        Binding(get: { session.maskTool },
                set: { tool in
                    session.maskTool = tool
                    // Arming a brush disarms the spot tool — one canvas gesture at a time.
                    if tool.isPainting { session.healTool = false }
                })
    }

    private var showBinding: Binding<Bool> {
        Binding(get: { session.isShowingSelectedMask },
                set: { _ in session.toggleShowSelectedMask() })
    }

    private var brushSizeBinding: Binding<Double> {
        Binding(get: { session.brushSize }, set: { session.brushSize = $0 })
    }

    private var brushHardnessBinding: Binding<Double> {
        Binding(get: { session.brushHardness }, set: { session.brushHardness = $0 })
    }

    private var brushFlowBinding: Binding<Double> {
        Binding(get: { session.brushFlow }, set: { session.brushFlow = $0 })
    }

    /// "Dragging on the canvas adjusts the selected gradient" — view state, never a document field.
    private var adjustBinding: Binding<Bool> {
        Binding(get: { session.adjustShapeOnDrag }, set: { session.adjustShapeOnDrag = $0 })
    }

    /// A checkbox is one click = one gesture = one snapshot (no drag, so no debounce needed).
    private func invertBinding(_ mask: Mask) -> Binding<Bool> {
        Binding(get: { mask.invert }, set: { session.setMaskInverted(mask.id, $0) })
    }

    /// The selected mask's **last** component is the one the shape section edits, so it is the one
    /// the blend picker reads and writes (the first component's op is ignored by Core).
    private func combineBinding(_ mask: Mask) -> Binding<CombineOp> {
        let component = max(0, mask.components.count - 1)
        return Binding(get: { mask.components[safe: component]?.op ?? .add },
                       set: { session.setMaskCombineOp(mask.id, component: component, $0) })
    }

    private func commitRename(_ mask: Mask) {
        guard nameDraft != mask.name else { return }
        if !session.renameMask(mask.id, to: nameDraft) { nameDraft = mask.name }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 1)
    }
}

// MARK: - the readback seam
//
// The inspector is SwiftUI; its `Slider`s are drawn by SwiftUI and are not `NSSlider`s a harness can
// count, and a screenshot cannot tell a slider from a label. So the panel publishes what it built
// through one invisible AppKit view — the same seam `HistogramCard` uses for the histogram it drew
// (`lastDrawnSeries`). The smoke walks the window's view tree, finds this, and asserts on the rows.

public final class MaskPanelProbe: NSView {
    /// Parameter rows the panel built, in draw order ("不透明度" … "饱和").
    public private(set) var rows: [String] = []
    /// The list rows' text, in list order — proves a move reordered the *panel*, not only the model.
    public private(set) var listOrder: [String] = []
    /// The selected mask's document name (what the rename field committed to).
    public private(set) var selectedName: String = ""

    /// Never a hit target and never drawn: it exists to be read.
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }
    public override var isOpaque: Bool { false }

    public func publish(rows: [String], listOrder: [String], selectedName: String) {
        self.rows = rows
        self.listOrder = listOrder
        self.selectedName = selectedName
    }
}

struct MaskPanelProbeHost: NSViewRepresentable {
    var rows: [String]
    var listOrder: [String]
    var selectedName: String

    func makeNSView(context: Context) -> MaskPanelProbe {
        let probe = MaskPanelProbe()
        probe.publish(rows: rows, listOrder: listOrder, selectedName: selectedName)
        return probe
    }

    func updateNSView(_ probe: MaskPanelProbe, context: Context) {
        probe.publish(rows: rows, listOrder: listOrder, selectedName: selectedName)
    }
}

