import SwiftUI
import PhotonsCatalog
import PhotonsCore

/// The inspector: SwiftUI inside `NSHostingView`, bound to the one `CatalogSession`.
///
/// §2b item 5 keeps the big surfaces matte and uses glass only for small widget containers, and §7
/// of research `ui-stack.md` says to write the panel in SwiftUI *now* — it is not connected to the
/// render loop in M3, so the 120 Hz-slider question (redlamp measured AppKit 34% vs SwiftUI 100% of
/// a core) is not yet being answered, it is being deferred with a measurement still owed in M4.
///
/// Every field writes through to `session.edit`; the values are the document, and the loupe does
/// not follow yet (M3 scope).
public struct InspectorView: View {
    @Bindable public var session: CatalogSession

    public init(session: CatalogSession) {
        self.session = session
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            ScrollView {
                VStack(spacing: 10) {
                    lightCard
                    colorCard
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

    // MARK: cards

    private var lightCard: some View {
        card("Light") {
            row("曝光", $session.edit.light.exposure, -5 ... 5, "%.2f EV")
            row("对比", $session.edit.light.contrast, -100 ... 100, "%.0f")
            row("高光", $session.edit.light.highlights, -100 ... 100, "%.0f")
            row("阴影", $session.edit.light.shadows, -100 ... 100, "%.0f")
            row("白色", $session.edit.light.whites, -100 ... 100, "%.0f")
            row("黑色", $session.edit.light.blacks, -100 ... 100, "%.0f")
            divider
            row("色温", $session.edit.light.temperature, 2000 ... 12000, "%.0f K")
            row("色调", $session.edit.light.tint, -150 ... 150, "%.0f")
        }
    }

    private var colorCard: some View {
        card("Color") {
            row("自然饱和", $session.edit.color.vibrance, -100 ... 100, "%.0f")
            row("饱和", $session.edit.color.saturation, -100 ... 100, "%.0f")
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

    private func row(_ title: String, _ value: Binding<Double>,
                     _ range: ClosedRange<Double>, _ format: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(String(format: format, value.wrappedValue))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.primary)
            }
            Slider(value: value, in: range)
                .controlSize(.mini)
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 1)
    }
}
