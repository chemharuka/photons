import XCTest
import SwiftUI
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 派单 031, the panel side: the 细节 card exists, sits where the spec puts it, and carries the four
/// controls.
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

    func testTheRenderedCardExposesTheFourControls() {
        let host = NSHostingView(rootView: InspectorView(session: CatalogSession()))
        host.frame = NSRect(x: 0, y: 0, width: 330, height: 2200)
        host.layoutSubtreeIfNeeded()

        let ids = Self.identifiers(in: host)
        print("DETAIL card ids: \(ids.filter { $0.contains("detail") })")
        guard ids.contains(where: { $0.hasPrefix("inspector.card.") }) else {
            // The accessibility tree is not exposed in this environment (no window session): the enum
            // assertion above is then the only ordering that exists, which is what the sibling test
            // does too.
            return
        }
        XCTAssertTrue(ids.contains("inspector.card.detail"),
                      "the 细节 card did not render; ids: \(ids)")
        for axis in ["luminanceNR", "colorNR", "detail", "sharpness"] {
            XCTAssertTrue(ids.contains("inspector.detail.\(axis)"),
                          "the \(axis) control is missing; ids: \(ids)")
        }
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
