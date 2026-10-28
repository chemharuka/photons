import AppKit
import SwiftUI

/// One 色差 row's frame, for the card's tests — the `EffectsRowProbe`/`ColorGradingProbe` pattern, for the
/// same reason: the row is drawn by `SliderRow` (the panel's one row view, 040), so the card has no view
/// of its own to measure, and measuring a re-declared row would keep passing after the shipped row
/// changed. A `.background(…)` gives the probe exactly the row's frame and cannot change it.
///
/// It exists because 色差 R / 色差 B are the **first rows in the 细节 card that commit on release as
/// render rows** — the four decoder rows above them go through the preview rung (`beginDetailDrag` /
/// `commitDetail`) and are greyed per decoder version. The layout test has to see each row's own frame
/// to say 「两根行都在卡里、都没有压在别的行上、三个宽度都不截断」.
///
/// Inert in production (nothing is drawn, `hitTest` answers `nil`).
final class ChromaticAberrationProbe: NSView {

    /// The 校正 card's own frame, probed from the card's `.background` so the layout test can say
    /// 「行在卡里」 (096: the rows moved here from 细节).
    static let cardID = "校正卡"
    /// The 细节 card's frame — the negative control: the two rows must be **outside** it.
    static let detailCardID = "细节卡"

    private(set) var rowID: String = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = false
    }

    required init?(coder: NSCoder) { fatalError("ChromaticAberrationProbe is created in code") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isOpaque: Bool { false }

    func update(_ id: String) { rowID = id }
}

struct ChromaticAberrationProbeHost: NSViewRepresentable {

    let rowID: String

    func makeNSView(context: Context) -> ChromaticAberrationProbe {
        let probe = ChromaticAberrationProbe()
        probe.update(rowID)
        return probe
    }

    func updateNSView(_ probe: ChromaticAberrationProbe, context: Context) {
        probe.update(rowID)
    }
}
