import XCTest
import PhotonsCore
@testable import PhotonsUI

/// 139 ② — the luminance range bar's geometry, and the one-drag-one-history contract it shares with
/// the sliders. The view is a shell over `MaskRangeBarGeometry`; these cases call the same functions
/// the gesture calls, so a broken hit test or a re-normalised body drag is caught without a window.
@MainActor
final class MaskRangeBarTests: XCTestCase {

    private let width: Double = 300

    // ⑨ a handle drag writes its bound

    func testDraggingTheHandleSetsTheBound() {
        let start = LuminanceRangeShape(low: 0.20, high: 0.80,
                                        lowFeather: 0.10, highFeather: 0.10)
        let lowDrag = MaskRangeBarGeometry.begin(atX: 0.20 * width, width: width, shape: start)!
        XCTAssertEqual(lowDrag.hit, .lowHandle)
        let lowMoved = MaskRangeBarGeometry.shape(for: lowDrag, atX: 0.30 * width, width: width)
        XCTAssertEqual(lowMoved.low, 0.30, accuracy: 0.005, "low handle follows the hand")
        XCTAssertEqual(lowMoved.high, start.high, "the other end is verbatim")
        XCTAssertEqual(lowMoved.lowFeather, start.lowFeather)
        XCTAssertEqual(lowMoved.highFeather, start.highFeather)

        let highDrag = MaskRangeBarGeometry.begin(atX: 0.80 * width, width: width, shape: start)!
        XCTAssertEqual(highDrag.hit, .highHandle)
        let highMoved = MaskRangeBarGeometry.shape(for: highDrag, atX: 0.70 * width, width: width)
        XCTAssertEqual(highMoved.high, 0.70, accuracy: 0.005, "high handle follows the hand")
        XCTAssertEqual(highMoved.low, start.low, "the other end is verbatim")
        print("RANGE handles · low 0.20→\(lowMoved.low) · high 0.80→\(highMoved.high)")
    }

    // ⑩ the body drag keeps the width (clamping is not re-normalisation)

    func testDraggingTheBodyKeepsTheWidth() {
        let start = LuminanceRangeShape(low: 0.20, high: 0.60,
                                        lowFeather: 0.10, highFeather: 0.10)
        let drag = MaskRangeBarGeometry.begin(atX: 0.40 * width, width: width, shape: start)!
        XCTAssertEqual(drag.hit, .body)
        let moved = MaskRangeBarGeometry.shape(for: drag, atX: 0.50 * width, width: width)
        XCTAssertEqual(moved.low, 0.30, accuracy: 1e-12)
        XCTAssertEqual(moved.high, 0.70, accuracy: 1e-12)
        XCTAssertEqual(moved.high - moved.low, start.high - start.low,
                       "the width is bit-identical; the body translates, it does not scale")

        // At the left end the body stops against 0 and keeps its width. A shape whose span cannot fit
        // in 0…1 is the one case where the clamp may narrow it — and it must narrow, not be
        // re-normalised back to the old width.
        let atLeft = MaskRangeBarGeometry.translated(start, by: -0.5)
        XCTAssertEqual(atLeft.low, 0)
        XCTAssertEqual(atLeft.high, start.high - start.low)
        let tooWide = LuminanceRangeShape(low: -0.10, high: 1.0,
                                          lowFeather: 0.10, highFeather: 0.10)
        let clamped = MaskRangeBarGeometry.translated(tooWide, by: 0.05)
        XCTAssertEqual(clamped.low, 0)
        XCTAssertEqual(clamped.high, 1)
        XCTAssertLessThan(clamped.high - clamped.low, tooWide.high - tooWide.low,
                          "clamped, not re-normalised to the old width")
        print("RANGE body · 0.20…0.60 → \(moved.low)…\(moved.high) · width "
              + "\(moved.high - moved.low) == \(start.high - start.low)")
    }

    // ⑪ one drag = one history entry

    func testOneDragIsOneHistoryEntry() throws {
        let session = CatalogSession()
        let mask = try XCTUnwrap(session.addMask(kind: .luminanceRange))
        let component = mask.components.count - 1
        let shape = (session.edit.masks.first { $0.id == mask.id })!.components[component].shape
        guard case .luminanceRange(let start) = shape else {
            return XCTFail("addMask(.luminanceRange) made \(shape.kind)")
        }
        let before = session.history.count
        let drag = try XCTUnwrap(MaskRangeBarGeometry.begin(
            atX: start.low * width, width: width, shape: start))

        for x in stride(from: start.low * width, through: 0.20 * width, by: 1) {
            let next = MaskRangeBarGeometry.shape(for: drag, atX: x, width: width)
            session.setMaskComponentShape(mask.id, component: component, shape: .luminanceRange(next),
                                          commit: false, label: "亮度范围条")
        }
        XCTAssertEqual(session.history.count, before,
                       "commit:false during the drag must not grow the stack")

        let final = MaskRangeBarGeometry.shape(for: drag, atX: 0.20 * width, width: width)
        session.setMaskComponentShape(mask.id, component: component, shape: .luminanceRange(final),
                                      commit: true, label: "亮度范围条", coalesce: false)
        XCTAssertEqual(session.history.count, before + 1, "mouse-up commits one snapshot")
        XCTAssertEqual(session.history.currentSnapshot?.label, "亮度范围条")

        XCTAssertTrue(session.undo())
        guard case .luminanceRange(let restored) =
                session.edit.masks.first(where: { $0.id == mask.id })!.components[component].shape else {
            return XCTFail("undo changed the shape kind")
        }
        XCTAssertEqual(restored, start, "⌘Z returns the pre-drag bounds in one step")
        print("RANGE history · drag ticks +0 · release +1 · undo restored \(restored.low)…\(restored.high)")
    }

    // ⑬ the picker, the bar and the row read one document value

    func testThreeEntriesAgreeOnOneValue() throws {
        let session = CatalogSession()
        let mask = try XCTUnwrap(session.addMask(kind: .luminanceRange))
        let component = 0
        let value = 0.62
        XCTAssertTrue(session.pickMaskLuminance(mask.id, component: component, at: value))

        guard case .luminanceRange(let picked) = session.edit.masks
            .first(where: { $0.id == mask.id })!.components[component].shape else {
            return XCTFail("the picker changed the shape kind")
        }
        let handles = MaskRangeBarGeometry.handles(for: picked)
        XCTAssertEqual(handles.low, picked.low, "the bar's handle is the engine's low")
        XCTAssertEqual(handles.high, picked.high, "the bar's handle is the engine's high")

        let rows = MaskShapeSliderRow.rows(for: .luminanceRange(picked))
        let lowRow = try XCTUnwrap(rows.first { $0.title == "下限" })
        let highRow = try XCTUnwrap(rows.first { $0.title == "上限" })
        XCTAssertEqual(lowRow.read(.luminanceRange(picked)), picked.low, accuracy: 1e-12)
        XCTAssertEqual(highRow.read(.luminanceRange(picked)), picked.high, accuracy: 1e-12)

        // Drag the bar's low handle to 0.30 and write it through the same door the view uses.
        let drag = try XCTUnwrap(MaskRangeBarGeometry.begin(
            atX: picked.low * width, width: width, shape: picked))
        let moved = MaskRangeBarGeometry.shape(for: drag, atX: 0.30 * width, width: width)
        session.setMaskComponentShape(mask.id, component: component,
                                      shape: .luminanceRange(moved),
                                      commit: true, label: "亮度范围条", coalesce: false)

        guard case .luminanceRange(let after) = session.edit.masks
            .first(where: { $0.id == mask.id })!.components[component].shape else {
            return XCTFail("the bar changed the shape kind")
        }
        XCTAssertEqual(after.low, 0.30, accuracy: 0.005, "the document holds the dragged bound")
        XCTAssertEqual(lowRow.read(.luminanceRange(after)), after.low, accuracy: 1e-12,
                       "the row reads the same document value — there is no second cache")
        print("RANGE agreement · pick \(picked.low)…\(picked.high) · drag low → \(after.low)")
    }
}
