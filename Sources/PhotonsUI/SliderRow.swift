import SwiftUI

/// **The panel's one slider row** — label + number + `Slider`, for every card in the inspector:
/// the tone cards, 白平衡, 细节, 黑电平 and 蒙版.
///
/// 040's ask was 「拖动条的样式还是和其他保持一致」, and the reason a card did not look like the rest
/// was that it drew its own row (a second label, a `TextField` where the others print a readout, its
/// own `Slider` with a step). The fix was not "restyle that card", it was **one builder** — this
/// view. It began life as `InspectorView.sliderRow` and moved here, unchanged, when 蒙版 needed the
/// same row: a `private` method of one card's view cannot be the panel's row, and a second copy of
/// it is exactly the drift 040 removed.
///
/// Everything a row promises lives here and nowhere else, so every card gets it:
///
///   · **the name** — double-click = that parameter's default (`onReset`, **required**; a row cannot
///     be built without the thing a double-click on its name should do). The card's job is to say
///     *what* the default is, `PanelResets`' job to write it.
///   · **the number** — a `SliderNumberField`: click it, type, `↵`/Tab commits, `Esc` **or a click
///     elsewhere cancels and restores the old value** (2026-10-28: a stray click must not write a
///     half-typed number), junk
///     beeps and writes nothing. A typed value takes the *drag's* path (the binding write, then
///     `onEditingChanged(false)`), so one input is one history entry, exactly like one drag.
///   · **the slider** — `InspectorView.shapeSlider`, the panel's only `Slider`: 16 pt high, `.mini`,
///     and a tint that comes from `SliderShape.accent` (blue = render, yellow = raw/decode,
///     red = linear domain). No `step:` — SwiftUI draws tick marks the moment it is handed one (046).
///   · **the style** — `InspectorView.SliderRowStyle`: label 10 pt medium, readout 10 pt monospaced,
///     1 pt between the head and the track. A card cannot grow a second set of numbers.
struct SliderRow: View {

    /// The row's label — also the accessibility name of its controls.
    let title: String
    /// The document value, written live (every tick) and on a typed value.
    let value: Binding<Double>
    /// The slider's travel; a typed number is clamped into it (`SliderValueInput.resolve`).
    let range: ClosedRange<Double>
    /// The resting readout's format (`%.2f EV`, `%.0f`, `%.0f%%`, …).
    let format: String
    /// 046/071: which domain the parameter lives in — the accent colour, and nothing else.
    var shape: SliderShape = .knob
    var style: InspectorView.SliderRowStyle = .standard
    /// 052: decimals while editing; `0` is 047's clean number.
    var decimals: Int = 0
    /// 052: how the resting readout rounds.
    var rounding: InspectorView.SliderRounding = .asIs
    /// 047: typeable (no card opts out).
    var editable: Bool = true
    /// 细节's 解码模型 rule: `false` = inert and visibly grey (the value is untouched).
    var enabled: Bool = true
    /// The number field's identifier (`inspector.whiteBalance.色温`, `inspector.mask.羽化`).
    var accessibilityID: String?
    /// The row's own identifier prefix. 细节's rows have used `inspector.detail.row` since 040; the
    /// mask panel says `inspector.mask.row` because two cards can hold a row called 曝光.
    var rowIdentifierPrefix: String = "inspector.detail.row"
    /// 040/047: double-click on the name = this parameter's default. **Required** — see above.
    let onReset: () -> Void
    /// The slider's press/release pair (`true` down, `false` up). Drag end is where a card commits.
    let onEditingChanged: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: style.rowSpacing) {
            HStack(spacing: style.headSpacing) {
                Text(title)
                    .font(.system(size: style.labelSize, weight: style.labelWeight))
                    .foregroundStyle(.secondary)
                    .modifier(ResetOnDoubleClick(action: onReset,
                                                 help: InspectorView.resetParameterHelp))
                Spacer(minLength: 4)
                if editable {
                    SliderNumberField(value: value.wrappedValue,
                                      range: range,
                                      format: format,
                                      decimals: decimals,
                                      rounding: rounding,
                                      fontSize: style.readoutSize,
                                      accessibilityID: accessibilityID,
                                      onCommit: { typed in
                                          // The drag's own path, in the drag's own order: write
                                          // through the binding, then the gesture-end commit. One
                                          // typed value = one `applyEdit` + one `commitEdit`.
                                          value.wrappedValue = typed
                                          onEditingChanged(false)
                                      })
                } else {
                    Text(InspectorView.sliderText(format, value.wrappedValue, rounding: rounding))
                        .font(.system(size: style.readoutSize, design: .monospaced))
                        .foregroundStyle(.primary)
                }
            }
            // The readback probe sits **inside** the disabled scope, so what it reports is SwiftUI's
            // own resolved `isEnabled` — not the local `enabled` flag echoed back (see
            // `DetailRowEnabledProbe`: macOS 27's `Slider` is drawn by SwiftUI, so there is no
            // `NSControl.isEnabled` to ask).
            .background(DetailRowEnabledProbe(title: title))
            // 060: **one** `Slider` for every shape, built by `shapeSlider` — the accent colour is the
            // only difference, and it lives in exactly one place.
            InspectorView.shapeSlider(value, in: range, shape: shape,
                                      controlSize: style.controlSize,
                                      onEditingChanged: onEditingChanged)
        }
        // `enabled: false` is the 解码模型 rule: the rows are **inert and visibly grey** rather than
        // live controls that quietly do nothing. The value is untouched — `.disabled` stops input, it
        // does not write.
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.42)
        .accessibilityIdentifier("\(rowIdentifierPrefix).\(title)")
    }
}
