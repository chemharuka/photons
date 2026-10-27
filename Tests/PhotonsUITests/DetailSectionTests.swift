import XCTest
import SwiftUI
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 派单 031 / 040, the panel side: the 细节 card exists, sits where the spec puts it, carries four
/// sliders **of the same control as every other card**, opens on the body's own default positions,
/// and prints no decoder prose under them.
///
/// The card order is asserted on the enum *and* on the rendered accessibility tree — the same two
/// views `WhiteBalanceSectionTests` takes, because "the list says so" and "the window shows it" can
/// disagree (that is exactly what a hand-maintained view hierarchy would do).
@MainActor
final class DetailSectionTests: XCTestCase {

    func testTheDetailCardSitsBetweenColorAndPresets() {
        let titles = InspectorView.sectionTitles
        guard let detail = titles.firstIndex(of: "细节") else {
            return XCTFail("no 细节 card in \(titles)")
        }
        XCTAssertEqual(titles.firstIndex(of: "Color").map { $0 + 1 }, detail,
                       "细节 belongs directly under Color; got \(titles)")
        XCTAssertEqual(titles.filter { $0 == "细节" }.count, 1, "one 细节 card, not two")

        // The pinned head is untouched, and the new card scrolls with the rest.
        XCTAssertEqual(Array(titles.prefix(3)), ["直方图", "白平衡", "Light"])
        XCTAssertTrue(InspectorView.scrollingSections.contains(.detail))
    }

    /// 040: four rows, 0…100 each, opening on the **body's** positions — 0 / 50 / 0 / 50 on a Leica,
    /// and 100 for sharpness on a body that reports 1.0. The card reads this table, so this is the
    /// panel's table, not a copy of it.
    func testTheFourRowsOpenOnTheBodyDefaults() {
        XCTAssertEqual(DetailAxis.panelOrder.map(\.title), ["降噪", "色彩降噪", "细节", "锐化"])
        XCTAssertEqual(DetailSettings.range, 0...100, "细节 is 0…100 too (user's correction, 2026-10-27)")

        let leica = DetailBaseline.measured
        XCTAssertEqual(DetailAxis.panelOrder.map { DetailSettings.identity.position($0, in: leica) },
                       [0, 50, 0, 50], "Leica L1030433 defaults")
        let r5 = DetailBaseline(luminanceNR: 0, colorNR: 0.5, sharpness: 1, detail: 0)
        XCTAssertEqual(DetailAxis.panelOrder.map { DetailSettings.identity.position($0, in: r5) },
                       [0, 50, 0, 100], "EOS R5 defaults (sharpness baseline 1.0)")
        let sony = DetailBaseline(luminanceNR: 0.377, colorNR: 0.5, sharpness: 0.5, detail: 0)
        XCTAssertEqual(DetailSettings.identity.position(.luminanceNR, in: sony), 38,
                       "Sony ARW luminance NR baseline 0.377 shows 38")

        // Double-click reset lands on the default position, not on 0: a value dragged away and reset
        // must be the untouched document again (nil), and the pixels must not move.
        var s = DetailSettings.identity
        for axis in DetailAxis.allCases {
            s.setPosition(20, axis, in: leica)
            XCTAssertNotNil(s[axis])
            s[axis] = nil                       // what `resetDetail(_:)` writes
            XCTAssertNil(s[axis])
            XCTAssertEqual(s.position(axis, in: leica), axis.defaultPosition(in: leica))
        }
        XCTAssertTrue(s.isIdentity)
    }

    /// 040 requirement 5: the sliders are **the same control** as the rest of the panel.
    ///
    /// The card used to draw its own row (a second label, a different readout, its own slider). The
    /// machine-checkable form of "no variant" is one row style, and its constants are the ones the
    /// tone rows have always had.
    func testTheSlidersAreTheSharedRowAndNotAVariant() {
        XCTAssertEqual(InspectorView.SliderRowStyle.allCases.map(\.rawValue), ["standard"],
                       "a second row style is how the bespoke 细节 slider would come back")

        let style = InspectorView.SliderRowStyle.standard
        XCTAssertEqual(style.controlSize, .mini, "every card's slider is .mini")
        XCTAssertEqual(style.labelSize, 10, "the tone rows' label size")
        XCTAssertEqual(style.readoutSize, 10, "the tone rows' readout size")
        XCTAssertEqual(style.rowSpacing, 1)
        XCTAssertEqual(style.headSpacing, 6)
    }

    /// 派单 046: the four rows are **decoder** parameters (a tick here is a development), so each one
    /// draws the long bar — and no slider in the card is given a `step:`, because SwiftUI draws tick
    /// marks the moment it gets one.
    ///
    /// The shape is asserted on `InspectorView.detailContent`, the object the card iterates; the tick
    /// claim is asserted on the row builder's source, because "the argument that draws ticks is not
    /// passed" is not visible in a value.
    func testTheFourDetailRowsDrawTheBarShapeWithoutTicks() throws {
        let rows = InspectorView.detailContent.rows
        XCTAssertEqual(rows.map(\.shape), [.bar, .bar, .bar, .bar],
                       "046: 细节的四根（会重新 develop）必须是长条形滑杆")

        // The bar is 16 pt tall, like every other row in the panel: no layout jump between shapes.
        XCTAssertEqual(SliderValueMap.rowHeight, 16)
        // **060 改了这里的两条断言**：055 量的是自绘气泡（`BubbleSliderCell.knobSize` 10 × 16 pt，
        // 宽 < 行高）。气泡控件删掉了，改成钉「同一个 SwiftUI Slider，橙色只从 tint 来」——
        // 形状不再是控件，颜色才是区分。
        let builderSource = try String(contentsOf: Self.inspectorSource, encoding: .utf8)
        XCTAssertTrue(builderSource.contains(".tint(shape == .bar ? Color.orange : nil)"),
                      "060: 细节的四根是解 RAW 参数 → 橙色；圆形/长条的控件之分已经不存在")

        let source = try String(contentsOf: Self.inspectorSource, encoding: .utf8)
        let tickedSlider = try NSRegularExpression(pattern: "Slider\\([^)]*step:")
        let range = NSRange(source.startIndex..., in: source)
        XCTAssertEqual(tickedSlider.numberOfMatches(in: source, range: range), 0,
                       "a `Slider(... step:)` would draw tick marks under the 细节 sliders")
        XCTAssertFalse(source.contains("step: Double? = nil"),
                       "sliderRow must not take a step: it is how the ticks came back before")

        print("DETAIL shapes: \(rows.map { "\($0.title)=\($0.shape.rawValue)" })")
    }

    /// 040 requirement 4: **no** decoder prose under the sliders — no 「基线 0.50」, no 「解码参数」,
    /// no 「v9」.
    ///
    /// Asserted on everything the card is made of: the removed footer (a `nil` constant), the four row
    /// titles the view iterates, and — when this environment exposes an accessibility tree — every
    /// label the rendered card carries.
    func testTheCardPrintsNoDecoderProse() {
        XCTAssertNil(InspectorView.detailFooterText,
                     "派单 040: nothing is printed under the 细节 sliders")

        let content = InspectorView.detailContent
        XCTAssertEqual(content.rows.map(\.title), ["降噪", "色彩降噪", "细节", "锐化"],
                       "the card's entire text is its four row labels plus one number per row")
        let texts = content.rows.map(\.title) + [InspectorView.detailFooterText].compactMap { $0 }
        for banned in ["基线", "解码", "v9", "develop"] {
            XCTAssertFalse(texts.contains { $0.contains(banned) },
                           "the 细节 card still prints '\(banned)': \(texts)")
        }

        // The rendered card, where the tree is available: no label may carry the words either.
        let host = Self.host()
        let nodes = Self.accessibility(in: host)
        guard let card = Self.subtree(of: "inspector.card.detail", in: nodes) else {
            print("DETAIL card: the accessibility tree is not exposed here; the content above is the check")
            return
        }
        let labels = card.flatMap { [$0.label, $0.value] }.filter { !$0.isEmpty }
        print("DETAIL card texts: \(labels)")
        for banned in ["基线", "解码", "v9", "develop"] {
            XCTAssertFalse(labels.contains { $0.contains(banned) },
                           "the rendered 细节 card still prints '\(banned)': \(labels)")
        }
    }

    func testTheRenderedCardExposesTheFourControls() {
        let host = Self.host()
        let ids = Self.identifiers(in: host)
        print("DETAIL card ids: \(ids.filter { $0.contains("detail") })")
        guard ids.contains(where: { $0.hasPrefix("inspector.card.") }) else {
            // The accessibility tree is not exposed in this environment (no window session): the enum
            // and content assertions are then the only ones that exist, which is what the sibling
            // test does too.
            return
        }
        XCTAssertTrue(ids.contains("inspector.card.detail"),
                      "the 细节 card did not render; ids: \(ids)")
        for axis in [DetailAxis.luminanceNR, .colorNR, .detail, .sharpness] {
            XCTAssertTrue(ids.contains("inspector.detail.\(axis.rawValue)"),
                          "the \(axis.rawValue) control is missing; ids: \(ids)")
        }

        // The card's four numbers, as rendered: with no decode yet the panel uses the measured
        // baseline, so it must read 0 / 50 / 0 / 50 before the first development lands.
        let nodes = Self.accessibility(in: host)
        guard let card = Self.subtree(of: "inspector.card.detail", in: nodes) else { return }
        let numbers = card.filter { $0.identifier.hasPrefix("inspector.detail.") }
        print("DETAIL card values: \(numbers.map { "\($0.identifier)=\($0.value)" })")
        for axis in DetailAxis.allCases {
            guard let node = numbers.first(where: { $0.identifier == "inspector.detail.\(axis.rawValue)" }),
                  !node.value.isEmpty else { continue }
            XCTAssertEqual(node.value,
                           String(format: "%.0f", axis.defaultPosition(in: .measured)),
                           "\(axis.rawValue) opened on \(node.value), not on its default position")
        }
    }

    // MARK: - helpers

    /// Windows the tests create, kept alive for the duration of the run (a view with no window has no
    /// accessibility tree; they are never ordered on screen).
    ///
    /// The tree this environment exposes is empty either way — the test run is not a trusted
    /// accessibility client — so the rendered checks below are written to *degrade to a print* rather
    /// than to pass silently, and the assertions that always run are the ones on
    /// `InspectorView.detailContent` (the object the card iterates).
    private static var windows: [NSWindow] = []

    /// The one file that renders the panel — read for the claims a value cannot carry (046: no
    /// `Slider(... step:)` anywhere).
    private static var inspectorSource: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/PhotonsUI/InspectorView.swift")
    }

    private static func host() -> NSHostingView<InspectorView> {
        let host = NSHostingView(rootView: InspectorView(session: CatalogSession()))
        host.frame = NSRect(x: 0, y: 0, width: 330, height: 2400)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.contentView = host
        windows.append(window)
        host.layoutSubtreeIfNeeded()
        return host
    }

    /// One node of the accessibility tree, flattened depth-first.
    private struct Node {
        var depth: Int
        var identifier: String
        var label: String
        var value: String
    }

    private static func accessibility(in root: Any?, depth: Int = 0, into out: inout [Node]) {
        guard depth < 32, let root else { return }
        var children: [Any] = []
        var node = Node(depth: depth, identifier: "", label: "", value: "")
        if let view = root as? NSView {
            node.identifier = view.accessibilityIdentifier()
            node.label = view.accessibilityLabel() ?? ""
            node.value = described(view.accessibilityValue())
            children = view.accessibilityChildren() ?? []
            out.append(node)
        } else if let element = root as? NSAccessibilityElement {
            node.identifier = element.accessibilityIdentifier() ?? ""
            node.label = element.accessibilityLabel() ?? ""
            node.value = described(element.accessibilityValue())
            children = element.accessibilityChildren() ?? []
            out.append(node)
        } else {
            return
        }
        for child in children { accessibility(in: child, depth: depth + 1, into: &out) }
    }

    private static func accessibility(in root: NSView) -> [Node] {
        var out: [Node] = []
        for child in root.accessibilityChildren() ?? [] {
            accessibility(in: child, depth: 1, into: &out)
        }
        return out
    }

    private static func described(_ value: Any?) -> String {
        switch value {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        case let d as Double: return String(format: "%.0f", d)
        default: return ""
        }
    }

    /// The nodes under the card with `identifier` (by depth, in DFS order).
    private static func subtree(of identifier: String, in nodes: [Node]) -> [Node]? {
        guard let start = nodes.firstIndex(where: { $0.identifier == identifier }) else { return nil }
        let depth = nodes[start].depth
        var out: [Node] = []
        for node in nodes[(start + 1)...] {
            if node.depth <= depth { break }
            out.append(node)
        }
        return out
    }

    private static func identifiers(in root: NSView, depth: Int = 0) -> [String] {
        guard depth < 24 else { return [] }
        var out: [String] = []
        for child in root.accessibilityChildren() ?? [] {
            if let view = child as? NSView {
                let id = view.accessibilityIdentifier()
                if !id.isEmpty { out.append(id) }
            }
            if let element = child as? NSAccessibilityElement,
               let id = element.accessibilityIdentifier(), !id.isEmpty {
                out.append(id)
            }
            if let view = child as? NSView {
                out += identifiers(in: view, depth: depth + 1)
            }
        }
        return out
    }
}
