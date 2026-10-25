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
                dividers
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
            Button {
                session.addMask()
                session.maskTool = .brush
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .controlSize(.mini)
            .disabled(masks.count >= Mask.maxCount || session.anchorAsset == nil)
            .help("新建蒙版")
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

    /// "2 笔" / "空" — enough to tell a painted mask from an empty one at a glance.
    private func strokeSummary(_ mask: Mask) -> String {
        var strokes = 0
        for component in mask.components {
            if case .brush(let brush) = component.shape { strokes += brush.strokes.count }
        }
        return strokes == 0 ? "空" : "\(strokes) 笔"
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

    private var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 1)
    }
}
