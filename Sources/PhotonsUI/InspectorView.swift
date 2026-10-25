import SwiftUI
import PhotonsCatalog
import PhotonsCore

/// The inspector: SwiftUI inside `NSHostingView`, bound to the one `CatalogSession`.
///
/// §2b item 5 keeps the big surfaces matte and uses glass only for small widget containers. The
/// panel is a *leaf*: it holds no state of its own, and every slider writes through
/// `CatalogSession.applyEdit` — the only mutation point, which is what bumps `editRevision` and
/// wakes the loupe's debounced renderer (50 ms, single-flight).
///
/// The drag/release split matters: `onEditingChanged` fires once when the drag ends, and that is
/// exactly one `EditHistory` snapshot. Committing per tick would make ⌘Z undo 1/100 EV at a time.
public struct InspectorView: View {
    @Bindable public var session: CatalogSession

    public init(session: CatalogSession) {
        self.session = session
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            historyStrip
            ScrollView {
                VStack(spacing: 10) {
                    card("直方图") {
                        HistogramCard(session: session)
                    }
                    lightCard
                    colorCard
                    PresetPanel(session: session)
                    MaskListPanel(session: session)
                    decodeCard
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 14)
            }
        }
        .padding(.top, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.clear)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("调整")
                .font(.system(size: 12, weight: .bold))
            Text(session.anchorAsset?.filename ?? "未选择照片")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 16)
    }

    /// The undo stack, visible: label of the step ⌘Z would take back, and whether ⇧⌘Z has a future.
    private var historyStrip: some View {
        HStack(spacing: 8) {
            Text(session.undoLabel.map { "⌘Z \($0)" } ?? "⌘Z —")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(session.canUndo ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(session.redoLabel.map { "⇧⌘Z \($0)" } ?? "⇧⌘Z —")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(session.canRedo ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
    }

    // MARK: cards

    private var lightCard: some View {
        card("Light") {
            row("曝光", \.light.exposure, -5 ... 5, "%.2f EV")
            row("对比", \.light.contrast, -100 ... 100, "%.0f")
            row("高光", \.light.highlights, -100 ... 100, "%.0f")
            row("阴影", \.light.shadows, -100 ... 100, "%.0f")
            row("白色", \.light.whites, -100 ... 100, "%.0f")
            row("黑色", \.light.blacks, -100 ... 100, "%.0f")
            divider
            row("色温", \.light.temperature, 2000 ... 12000, "%.0f K")
            row("色调", \.light.tint, -150 ... 150, "%.0f")
        }
    }

    private var colorCard: some View {
        card("Color") {
            row("自然饱和", \.color.vibrance, -100 ... 100, "%.0f")
            row("饱和", \.color.saturation, -100 ... 100, "%.0f")
        }
    }

    private var decodeCard: some View {
        card("Decode") {
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
        let value = binding(keyPath)
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(String(format: format, value.wrappedValue))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.primary)
            }
            Slider(value: value, in: range) { editing in
                // Drag end = one edit action = one history snapshot (never per tick).
                if !editing { session.commitEdit() }
            }
            .controlSize(.mini)
        }
    }

    /// A slider binding that writes through the session, so every tick is observed by the loupe.
    private func binding(_ keyPath: WritableKeyPath<EditModel, Double>) -> Binding<Double> {
        Binding(get: { session.edit[keyPath: keyPath] },
                set: { newValue in
                    session.applyEdit { $0[keyPath: keyPath] = newValue }
                })
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 1)
    }
}
