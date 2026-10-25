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
public struct MaskListPanel: View {
    @Bindable public var session: CatalogSession

    /// The name being typed. View state, deliberately: a keystroke must not grow the undo stack, so
    /// the document is written once — on ⏎ or the ✓ — and this is only what the field shows.
    @State private var nameDraft: String = ""

    public init(session: CatalogSession) {
        self.session = session
    }

    private var masks: [Mask] { session.edit.masks }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            list
            divider
            tools
            if let mask = selectedMask {
                maskSection(mask)
                adjustmentsSection(mask)
                // The brush numbers belong to a brush mask; a gradient's own parameters are below.
                if selectedIsBrush { dividers }
                shapeSection
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
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 6) {
            Text("蒙版")
                .font(.system(size: 11, weight: .bold))
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

            ForEach(MaskLevelParameter.allCases, id: \.rawValue) { parameter in
                sliderRow(parameter.label,
                          value: parameter.isPercent ? parameter.value(mask) * 100
                                                     : parameter.value(mask),
                          range: parameter.isPercent ? 0 ... 100 : parameter.range,
                          format: parameter.isPercent ? "%.0f%%" : parameter.format,
                          set: { value in
                              session.setMaskLevel(mask.id, parameter,
                                                   parameter.isPercent ? value / 100 : value)
                          },
                          commit: { session.commitEdit(label: "蒙版\(parameter.label)") })
                    .help(parameter.help)
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
                ForEach(MaskAdjustmentParameter.allCases, id: \.rawValue) { parameter in
                    sliderRow(parameter.label,
                              value: mask.adjustments[keyPath: parameter.keyPath],
                              range: parameter.range,
                              format: parameter.format,
                              set: { value in
                                  session.setMaskAdjustment(mask.id, parameter, value)
                              },
                              commit: { session.commitEdit(label: "局部\(parameter.label)") })
                        .help(parameter.help)
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
    private var parameterLabels: [String] {
        MaskLevelParameter.allCases.map(\.label) + ["反转", "混合"]
            + MaskAdjustmentParameter.allCases.map(\.label)
    }

    /// The rows that belong to the shape the mask actually holds.
    ///
    /// Not a picker: a mask's shape is what was drawn, and changing its *kind* would silently throw
    /// away the gesture that made it. So this section only ever edits parameters — the midpoint of a
    /// ramp, the radius of an ellipse, a tolerance — and every write goes through
    /// `setMaskComponentShape`, with one commit per slider gesture (the same drag/release rule the
    /// Light card follows, so ⌘Z is one step and not one per tick).
    @ViewBuilder private var shapeSection: some View {
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
                shapeParameters(shape: entry.component.shape)
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

    @ViewBuilder private func shapeParameters(shape: MaskShape) -> some View {
        switch shape {
        case .linearGradient(let g):
            sliderRow("中点", value: g.midpoint, range: 0.05 ... 0.95, format: "%.2f", set: { value in
                writeShape(.linearGradient(LinearGradientShape(start: g.start, end: g.end,
                                                               midpoint: value)))
            }, commit: { session.commitEdit(label: "渐变中点") })
        case .radialGradient(let g):
            sliderRow("半径", value: max(g.radius.x, g.radius.y), range: 0.02 ... 1.2, format: "%.3f",
                      set: { value in
                          writeShape(.radialGradient(RadialGradientShape(
                              center: g.center,
                              radius: NormalizedPoint(value, value), angle: g.angle)))
                      }, commit: { session.commitEdit(label: "椭圆半径") })
            sliderRow("角度", value: g.angle, range: -180 ... 180, format: "%.0f°", set: { value in
                writeShape(.radialGradient(RadialGradientShape(center: g.center,
                                                               radius: g.radius, angle: value)))
            }, commit: { session.commitEdit(label: "椭圆角度") })
        case .colorRange(let c):
            HStack(spacing: 5) {
                ForEach(Array(c.samples.prefix(4).enumerated()), id: \.offset) { _, sample in
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
            sliderRow("容差", value: c.tolerance, range: 0.02 ... 1.0, format: "%.2f", set: { value in
                writeShape(.colorRange(ColorRangeShape(samples: c.samples, tolerance: value,
                                                       smoothness: c.smoothness)))
            }, commit: { session.commitEdit(label: "颜色容差") })
        case .luminanceRange(let l):
            sliderRow("下限", value: l.low, range: 0 ... 1, format: "%.2f", set: { value in
                writeShape(.luminanceRange(LuminanceRangeShape(low: min(value, l.high), high: l.high,
                                                               lowFeather: l.lowFeather,
                                                               highFeather: l.highFeather)))
            }, commit: { session.commitEdit(label: "亮度下限") })
            sliderRow("上限", value: l.high, range: 0 ... 1, format: "%.2f", set: { value in
                writeShape(.luminanceRange(LuminanceRangeShape(low: l.low, high: max(value, l.low),
                                                               lowFeather: l.lowFeather,
                                                               highFeather: l.highFeather)))
            }, commit: { session.commitEdit(label: "亮度上限") })
        case .semantic(let s):
            sliderRow("软边", value: s.softEdge, range: 0 ... 0.6, format: "%.2f", set: { value in
                var next = s
                next.softEdge = value
                writeShape(.semantic(next))
            }, commit: { session.commitEdit(label: "语义软边") })
        case .brush, .unsupported:
            EmptyView()
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
        case .semantic(let s):
            return "\(s.kind.displayName) · \(s.rasterDigest == nil ? "未生成" : "已生成")"
        case .brush(let b):
            return String(format: "size %.3f", b.size)
        case .unsupported(let kind, _):
            return "未知 \(kind)"
        }
    }

    /// One document slider: label + live number on top, the control underneath, and **one commit on
    /// mouse-up** (`onEditingChanged` fires once when the drag ends). `set` runs for every tick and
    /// must not commit — that is what keeps ⌘Z at gesture granularity.
    private func sliderRow(_ title: String, value: Double, range: ClosedRange<Double>,
                           format: String, set: @escaping (Double) -> Void,
                           commit: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(String(format: format, value))
                    .font(.system(size: 10, design: .monospaced))
            }
            Slider(value: Binding(get: { value }, set: set), in: range) { editing in
                // Drag end = one snapshot, exactly like the Light card.
                if !editing { commit() }
            }
            .controlSize(.mini)
        }
    }

    private func writeShape(_ shape: MaskShape) {
        guard let mask = selectedMask, let entry = selectedComponent else { return }
        session.setMaskComponentShape(mask.id, component: entry.index, shape: shape,
                                      commit: false, label: "")
    }

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

    private var dividers: some View {
        VStack(alignment: .leading, spacing: 4) {
            slider("大小", value: brushSizeBinding, range: 0.01 ... 0.5, format: "%.3f")
            slider("硬度", value: brushHardnessBinding, range: 0 ... 1, format: "%.2f")
            slider("流量", value: brushFlowBinding, range: 0.05 ... 1, format: "%.2f")
        }
    }

    /// A **view-state** slider (the brush). No commit hook on purpose: these numbers are captured by
    /// each stroke, so moving them must not rewrite the picture or the undo stack.
    private func slider(_ title: String, value: Binding<Double>,
                        range: ClosedRange<Double>, format: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(String(format: format, value.wrappedValue))
                    .font(.system(size: 10, design: .monospaced))
            }
            Slider(value: value, in: range)
                .controlSize(.mini)
        }
    }

    // MARK: bindings (every one writes through the session)

    private var toolBinding: Binding<MaskTool> {
        Binding(get: { session.maskTool }, set: { session.maskTool = $0 })
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

