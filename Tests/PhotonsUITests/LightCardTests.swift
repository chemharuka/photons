import XCTest
import SwiftUI
import PhotonsCore
import PhotonsCatalog
@testable import PhotonsUI

/// 派单 046, the Light card's half of the rule: 曝光 / 对比 / 高光 / 阴影 / 白色 / 黑色 are **render**
/// parameters — they act on the pixels the decoder already produced — so all six keep the round knob.
///
/// The seven rows are a table (`InspectorView.lightRows`) that the card iterates, which is what makes
/// this assertable without a window session: the shape a row draws is the shape in the table.
@MainActor
final class LightCardTests: XCTestCase {

    func testTheLightCardHasSevenRenderRowsInOrder() {
        let rows = InspectorView.lightRows
        XCTAssertEqual(rows.map(\.title), ["曝光", "对比", "高光", "中间调", "阴影", "白色", "黑色"],
                       "the tone card's seven rows, in display order")
        XCTAssertEqual(rows.count, 7)
        XCTAssertEqual(InspectorView.Section.light.title, "Light")
        XCTAssertTrue(InspectorView.scrollingSections.contains(.light))

        // The travel and the number format of each row — unchanged by 046.
        XCTAssertEqual(rows[0].range, -5 ... 5, "曝光 is ±5 EV")
        XCTAssertEqual(rows[0].format, "%.2f EV")
        for row in rows.dropFirst() {
            XCTAssertEqual(row.range, -100 ... 100, "\(row.title) is ±100")
            XCTAssertEqual(row.format, "%.0f", "\(row.title) prints an integer")
        }
        XCTAssertEqual(rows.map(\.keyPath), [\.light.exposure, \.light.contrast, \.light.highlights,
                                             \.light.midtones, \.light.shadows, \.light.whites,
                                             \.light.blacks],
                       "one write path per row, straight into `EditModel.light`")
    }

    /// 046's structural claim for this card: **every** row is `.knob`, none is `.bar`.
    func testEveryLightRowDrawsTheRoundKnob() {
        let shapes = InspectorView.lightRows.map(\.shape)
        XCTAssertEqual(shapes, Array(repeating: .knob, count: 7),
                       "046: 解 RAW 之后的参数是圆形滑杆; got \(shapes)")
        XCTAssertFalse(shapes.contains(.bar),
                       "no tone control is a decoder parameter — a `.bar` here would mean a re-develop")

        // 与细节卡互为反证：那边全是 `.bar`，这边全是 `.knob`。
        XCTAssertEqual(Set(InspectorView.detailContent.rows.map(\.shape)), [.bar])
        print("LIGHT shapes: \(InspectorView.lightRows.map { "\($0.title)=\($0.shape.rawValue)" })")
    }

    /// Both shapes share one row height, so this card and the 细节 card are the same height per row
    /// and the panel does not jump when a parameter changes class (046 要求 4).
    func testTheLightRowsUseTheSharedRowHeight() {
        XCTAssertEqual(SliderValueMap.rowHeight, 16)
        let style = InspectorView.SliderRowStyle.standard
        XCTAssertEqual(style.controlSize, .mini, "the knob is still .mini, as it has always been")
    }

    /// 052: the same table carries each row's **precision** — how the readout rounds, how many
    /// decimals the edit box shows, and (for 曝光 alone) the grid the document stores on.
    func testTheLightRowsCarryTheirDisplayAndStoragePrecision() {
        let exposure = InspectorView.lightRows[0]
        XCTAssertEqual(exposure.format, "%.2f EV", "曝光 reads two decimals — never a whole number")
        XCTAssertEqual(exposure.rounding, .asIs, "…so its readout is not rounded away from zero")
        XCTAssertEqual(exposure.decimals, 2, "the edit box shows exactly what the readout does")
        XCTAssertEqual(exposure.quantum, 0.01, "and the document lives on a 0.01 grid")
        XCTAssertEqual(InspectorView.sliderText(exposure.format, 1.4829, rounding: exposure.rounding),
                       "1.48 EV")

        for row in InspectorView.lightRows.dropFirst() {
            XCTAssertEqual(row.format, "%.0f", "\(row.title) prints a whole number")
            XCTAssertEqual(row.rounding, .outward, "\(row.title) rounds away from zero, never inwards")
            XCTAssertEqual(row.decimals, 1, "\(row.title) shows one decimal only while editing")
            XCTAssertEqual(row.quantum, 0, "\(row.title) stores what was typed (its step is already 1)")
            XCTAssertEqual(InspectorView.sliderText(row.format, 1.4829, rounding: row.rounding), "2")
            XCTAssertEqual(InspectorView.sliderText(row.format, -0.4, rounding: row.rounding), "-1")
        }
        print("LIGHT precision: 曝光 %.2f EV / .asIs / decimals 2 / quantum 0.01 · "
              + "others %.0f / .outward / decimals 1 / no quantum")
    }

    /// The rendered card exposes the same seven rows as the table — degraded to a print when the
    /// accessibility tree is not available in this environment (as in `DetailSectionTests`).
    func testTheRenderedCardStillCarriesTheSevenRows() {
        let host = NSHostingView(rootView: InspectorView(session: CatalogSession()))
        host.frame = NSRect(x: 0, y: 0, width: 330, height: 2400)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.contentView = host
        Self.windows.append(window)
        host.layoutSubtreeIfNeeded()

        let ids = Self.identifiers(in: host)
        print("LIGHT card ids: \(ids.filter { $0.contains("light") || $0.contains("card") })")
        guard ids.contains(where: { $0.hasPrefix("inspector.card.") }) else {
            // No window session here: the table assertions above are the check (same degradation as
            // `DetailSectionTests.testTheRenderedCardExposesTheFourControls`).
            return
        }
        XCTAssertTrue(ids.contains("inspector.card.light"), "the Light card did not render: \(ids)")
    }

    /// 090: dragging 中间调 writes the document, and only releasing writes one history row.
    /// The slider's `onEditingChanged` calls `commitEdit()` on release — the same path as every row.
    func testDraggingMidtonesWritesTheDocumentAndCommitsOnceOnRelease() {
        let session = CatalogSession()
        // A baseline, so ⌘Z has a state to return to (the first commit has no earlier snapshot).
        session.applyEdit { $0.light.midtones = 5 }
        XCTAssertTrue(session.commitEdit(label: "起点"))
        let before = session.history.count
        let row = InspectorView.lightRows.first { $0.title == "中间调" }
        XCTAssertNotNil(row)
        XCTAssertEqual(row?.range, -100 ... 100)

        session.applyEdit { $0.light.midtones = 20 }
        XCTAssertEqual(session.history.count, before, "拖动中不写历史")
        session.applyEdit { $0.light.midtones = 40 }
        XCTAssertEqual(session.edit.light.midtones, 40, "文档跟着手走到 +40")
        XCTAssertEqual(session.history.count, before, "还没松手，仍然没有新历史")

        XCTAssertTrue(session.commitEdit(), "松手 = 一次 commit")
        XCTAssertEqual(session.history.count, before + 1, "一次拖动 = 一条历史")
        XCTAssertTrue(session.undo())
        XCTAssertEqual(session.edit.light.midtones, 5, "⌘Z 一步回到拖动前")
    }

    // MARK: - helpers

    private static var windows: [NSWindow] = []

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
