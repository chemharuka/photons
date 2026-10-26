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
    /// The value under the thumb while a white-balance drag is in progress (派单 006).
    ///
    /// Not a document write: a Kelvin change means a **re-decode** (~762 ms full size), so a tick
    /// must never reach the model. The draft dies on release, where the value is quantized and
    /// committed once — one decode, one history snapshot.
    @State private var draftTemperature: Double?
    @State private var draftTint: Double?

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
            whiteBalanceRow("色温", isTemperature: true)
            whiteBalanceRow("色调", isTemperature: false)
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
                Text(Self.sliderText(format, value.wrappedValue))
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

    // MARK: white balance (派单 006)

    /// The file's own white balance, as the decode reported it. `nil` until the first development
    /// lands (`session.capabilities`), which is why the row can say "as shot" without a number.
    private var asShotWhiteBalance: WhiteBalance {
        session.capabilities?.asShotWhiteBalance ?? .asShot
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
        let shot = asShotWhiteBalance
        var wb = WhiteBalance(temperature: isTemperature ? draft : session.edit.light.temperature,
                              tint: isTemperature ? session.edit.light.tint : draft).quantized()
        if isTemperature, let v = wb.temperature, let s = shot.temperature,
           abs(v - s) <= WhiteBalance.temperatureStep / 2 {
            wb.temperature = nil
        }
        if !isTemperature, let v = wb.tint, let s = shot.tint, abs(v - s) <= WhiteBalance.tintStep / 2 {
            wb.tint = nil
        }
        let next = wb
        session.applyEdit { model in
            model.light.temperature = next.temperature
            model.light.tint = next.tint
        }
        session.commitEdit()
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 1)
    }
}
