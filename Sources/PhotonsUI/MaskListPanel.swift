import SwiftUI
import PhotonsCore

/// The mask panel: what exists, which one is selected, what a drag on the canvas means, and the
/// three brush numbers (Q22, `docs/tasks/005-masks.md` §1/§7).
///
/// A leaf view like the rest of the inspector: it holds **no** copy of anything. Selecting a mask,
/// arming the brush, toggling the overlay and dragging a brush slider all write straight into
/// `CatalogSession` — the same object the canvas and the loupe read — which is what keeps the three
/// surfaces from drifting apart.
///
/// Two deliberate choices, both about history granularity:
///   · brush size / hardness / flow are **view state**, not document state. Each stroke stores its
///     own `radius`/`feather`/`flow` when it is painted (§2), so moving these sliders must never
///     rewrite a stroke already on the photo — and must not grow the undo stack.
///   · 显示蒙版 is view state too: it repaints the last pass and nothing else, so ⌘Z after toggling
///     it does not turn the overlay off (`MaskViewState`).
public struct MaskListPanel: View {
    @Bindable public var session: CatalogSession

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
            if session.selectedMaskID != nil {
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
            Text(strokeSummary(mask))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
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

    /// "2 笔" / "空" / "线性渐变" — enough to tell what a mask *is* at a glance.
    private func strokeSummary(_ mask: Mask) -> String {
        guard let first = mask.components.first else { return "空" }
        if case .brush(let brush) = first.shape {
            return brush.strokes.isEmpty ? "空" : "\(brush.strokes.count) 笔"
        }
        if case .semantic(let semantic) = first.shape {
            return semantic.kind.displayName
        }
        return MaskCreationKind.of(first.shape)?.label ?? first.shape.kind
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
            shapeSlider("中点", value: g.midpoint, range: 0.05 ... 0.95, format: "%.2f", set: { value in
                writeShape(.linearGradient(LinearGradientShape(start: g.start, end: g.end,
                                                               midpoint: value)))
            }, commit: { session.commitEdit(label: "渐变中点") })
        case .radialGradient(let g):
            shapeSlider("半径", value: max(g.radius.x, g.radius.y), range: 0.02 ... 1.2, format: "%.3f",
                        set: { value in
                            writeShape(.radialGradient(RadialGradientShape(
                                center: g.center,
                                radius: NormalizedPoint(value, value), angle: g.angle)))
                        }, commit: { session.commitEdit(label: "椭圆半径") })
            shapeSlider("角度", value: g.angle, range: -180 ... 180, format: "%.0f°", set: { value in
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
            shapeSlider("容差", value: c.tolerance, range: 0.02 ... 1.0, format: "%.2f", set: { value in
                writeShape(.colorRange(ColorRangeShape(samples: c.samples, tolerance: value,
                                                       smoothness: c.smoothness)))
            }, commit: { session.commitEdit(label: "颜色容差") })
        case .luminanceRange(let l):
            shapeSlider("下限", value: l.low, range: 0 ... 1, format: "%.2f", set: { value in
                writeShape(.luminanceRange(LuminanceRangeShape(low: min(value, l.high), high: l.high,
                                                               lowFeather: l.lowFeather,
                                                               highFeather: l.highFeather)))
            }, commit: { session.commitEdit(label: "亮度下限") })
            shapeSlider("上限", value: l.high, range: 0 ... 1, format: "%.2f", set: { value in
                writeShape(.luminanceRange(LuminanceRangeShape(low: l.low, high: max(value, l.low),
                                                               lowFeather: l.lowFeather,
                                                               highFeather: l.highFeather)))
            }, commit: { session.commitEdit(label: "亮度上限") })
        case .semantic(let s):
            shapeSlider("软边", value: s.softEdge, range: 0 ... 0.6, format: "%.2f", set: { value in
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

    private func shapeSlider(_ title: String, value: Double, range: ClosedRange<Double>,
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

    private var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 1)
    }
}
