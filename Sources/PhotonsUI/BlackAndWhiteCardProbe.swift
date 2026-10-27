import AppKit
import SwiftUI

/// One 黑白 card row's frame (and, for the switch, the state it is drawn with), for the card's tests.
///
/// The card is drawn by `SliderRow` — the panel's **one** row view (040) — so there is no view of the
/// card's own to measure. Measuring a re-declared row would keep passing after the shipped row changed,
/// which is the bug 040 removed; so the probe hangs off the row with `.background(…)`, which gives it
/// exactly the row's frame and cannot change that frame (a background is sized by its content).
/// `EffectsRowProbe` and `CropRowProbe` are the same pattern for the same reason.
///
/// `hitTest` answers `nil` and nothing is drawn: the probe exists to be found by class in the AppKit
/// tree and asked for `convert(bounds, to: host)`. 「命中区正确」 is measured on that frame — the switch's
/// clickable row is the checkbox plus its label (the label is *inside* the `Toggle`, so the whole row is
/// one target), and a row that overflowed its card would have a frame outside the card rather than a
/// shorter one.
///
/// The switch's `isOn` is read back too, because the state a `Toggle` **draws** is the state the
/// document holds only if the card passes the document's own value (`session.edit.color.blackAndWhite`);
/// a card that kept a `@State` mirror would read back the mirror here.
final class BlackAndWhiteProbe: NSView {

    /// The id the card itself is probed under (`blackAndWhiteCard`'s own `.background`): the row probes
    /// measure rows, and the layout test also needs the card's frame to say 「行在卡里」.
    static let cardID = "黑白卡"
    /// The switch row's id — not 「黑白」, which is also the card's title: one string, one meaning.
    static let switchID = "开关"

    private(set) var rowID: String = ""
    /// The switch row's state as SwiftUI drew it; `nil` on the eight slider rows.
    private(set) var isOn: Bool?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = false
    }

    required init?(coder: NSCoder) { fatalError("BlackAndWhiteProbe is created in code") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isOpaque: Bool { false }

    func update(_ id: String, isOn: Bool?) {
        rowID = id
        self.isOn = isOn
    }
}

struct BlackAndWhiteProbeHost: NSViewRepresentable {

    let rowID: String
    var isOn: Bool?

    func makeNSView(context: Context) -> BlackAndWhiteProbe {
        let probe = BlackAndWhiteProbe()
        probe.update(rowID, isOn: isOn)
        return probe
    }

    func updateNSView(_ probe: BlackAndWhiteProbe, context: Context) {
        probe.update(rowID, isOn: isOn)
    }
}
