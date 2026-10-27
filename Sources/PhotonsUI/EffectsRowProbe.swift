import AppKit
import SwiftUI

/// One 效果 row's frame, for the layout tests at 300 / 330 / 364 pt.
///
/// The card is drawn by `SliderRow` — the panel's **one** row view (040) — so there is no view of the
/// card's own to measure. A test that re-declared the row to measure it would keep passing after the
/// shipped row changed, which is the bug 040 removed; so the probe is attached to the row with
/// `.background(EffectsRowProbeHost(rowID:))`, which gives it exactly the row's frame and cannot
/// change that frame (a background is sized by its content, never the other way round). `CropRowProbe`
/// in the 裁切 card is the same pattern for the same reason.
///
/// `hitTest` returns `nil` and the view draws nothing: it exists to be found by class in the AppKit
/// tree and asked for `convert(bounds, to: host)`, which is what 「不截断」 is measured on (a row that
/// overflows its card has a frame outside the card, not a shorter one).
final class EffectsRowProbe: NSView {

    private(set) var rowID: String = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = false
    }

    required init?(coder: NSCoder) { fatalError("EffectsRowProbe is created in code") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isOpaque: Bool { false }

    func update(_ id: String) {
        rowID = id
    }
}

struct EffectsRowProbeHost: NSViewRepresentable {

    let rowID: String

    func makeNSView(context: Context) -> EffectsRowProbe {
        let probe = EffectsRowProbe()
        probe.update(rowID)
        return probe
    }

    func updateNSView(_ probe: EffectsRowProbe, context: Context) {
        probe.update(rowID)
    }
}
