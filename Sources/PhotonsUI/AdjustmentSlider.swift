import AppKit
import SwiftUI

/// Native tracking and accessibility, with a compact Capture One style handle.
final class AdjustmentSliderCell: NSSliderCell {
    var accent: NSColor = .controlAccentColor

    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let track = NSRect(x: rect.minX, y: rect.midY - 1.5, width: rect.width, height: 3)
        NSColor.secondaryLabelColor.withAlphaComponent(isEnabled ? 0.35 : 0.15).setFill()
        NSBezierPath(roundedRect: track, xRadius: 1.5, yRadius: 1.5).fill()
        let fraction = CGFloat((doubleValue - minValue) / max(maxValue - minValue, .leastNonzeroMagnitude))
        let selected = NSRect(x: track.minX, y: track.minY,
                              width: track.width * min(1, max(0, fraction)), height: track.height)
        accent.withAlphaComponent(isEnabled ? 1 : 0.3).setFill()
        NSBezierPath(roundedRect: selected, xRadius: 1.5, yRadius: 1.5).fill()
    }

    override func drawKnob(_ knobRect: NSRect) {
        let rect = NSRect(x: knobRect.midX - 7, y: knobRect.midY - 5, width: 14, height: 10)
        let path = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
        NSColor(calibratedWhite: isHighlighted ? 0.8 : 0.66, alpha: isEnabled ? 1 : 0.45).setFill()
        path.fill()
        NSColor.black.withAlphaComponent(0.22).setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }
}

final class AdjustmentNSSlider: NSSlider {
    var editingChanged: (Bool) -> Void = { _ in }
    var valueStep: Double?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        cell = AdjustmentSliderCell()
        isContinuous = true
    }
    required init?(coder: NSCoder) { super.init(coder: coder); cell = AdjustmentSliderCell() }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        editingChanged(true)
        defer { editingChanged(false) }
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        guard isEnabled, [123, 124, 125, 126].contains(Int(event.keyCode)) else {
            super.keyDown(with: event); return
        }
        nudge(event.keyCode == 123 || event.keyCode == 125 ? -1 : 1)
    }

    private func nudge(_ direction: Double) {
        editingChanged(true)
        doubleValue = min(maxValue, max(minValue, doubleValue + direction * (valueStep ?? (maxValue - minValue) / 100)))
        sendAction(action, to: target)
        editingChanged(false)
    }

    override func accessibilityPerformIncrement() -> Bool { guard isEnabled else { return false }; nudge(1); return true }
    override func accessibilityPerformDecrement() -> Bool { guard isEnabled else { return false }; nudge(-1); return true }
}

struct AdjustmentSlider: NSViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double?
    var accent: Color?
    var onEditingChanged: (Bool) -> Void
    @Environment(\.isEnabled) private var isEnabled

    init(value: Binding<Double>, in range: ClosedRange<Double>, step: Double? = nil,
         accent: Color? = nil, onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        _value = value; self.range = range; self.step = step; self.accent = accent
        self.onEditingChanged = onEditingChanged
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: AdjustmentNSSlider, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 120, height: SliderValueMap.rowHeight)
    }
    func makeNSView(context: Context) -> AdjustmentNSSlider {
        let slider = AdjustmentNSSlider(frame: .zero)
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.changed(_:))
        slider.controlSize = .mini
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return slider
    }
    func updateNSView(_ slider: AdjustmentNSSlider, context: Context) {
        context.coordinator.parent = self
        slider.minValue = range.lowerBound; slider.maxValue = range.upperBound
        slider.doubleValue = SliderValueMap.clamp(value, range)
        slider.isEnabled = isEnabled; slider.valueStep = step
        slider.editingChanged = onEditingChanged
        (slider.cell as? AdjustmentSliderCell)?.accent = accent.map { NSColor($0) } ?? .controlAccentColor
        slider.needsDisplay = true
    }
    final class Coordinator: NSObject {
        var parent: AdjustmentSlider
        init(_ parent: AdjustmentSlider) { self.parent = parent }
        @objc func changed(_ sender: NSSlider) {
            var value = sender.doubleValue
            if let step = parent.step, step > 0 {
                value = parent.range.lowerBound + ((value - parent.range.lowerBound) / step).rounded() * step
            }
            parent.value = SliderValueMap.clamp(value, parent.range)
        }
    }
}
