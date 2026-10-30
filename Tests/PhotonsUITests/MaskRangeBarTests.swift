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
        let lowDrag = MaskRangeBarGeometry.begin(
            atX: MaskRangeBarGeometry.xPosition(forValue: 0.20, width: width),
            width: width, shape: start)!
        XCTAssertEqual(lowDrag.hit, .lowHandle)
        let lowMoved = MaskRangeBarGeometry.shape(
            for: lowDrag, atX: MaskRangeBarGeometry.xPosition(forValue: 0.30, width: width),
            width: width)
        XCTAssertEqual(lowMoved.low, 0.30, accuracy: 0.005, "low handle follows the hand")
        XCTAssertEqual(lowMoved.high, start.high, "the other end is verbatim")
        XCTAssertEqual(lowMoved.lowFeather, start.lowFeather)
        XCTAssertEqual(lowMoved.highFeather, start.highFeather)

        let highDrag = MaskRangeBarGeometry.begin(
            atX: MaskRangeBarGeometry.xPosition(forValue: 0.80, width: width),
            width: width, shape: start)!
        XCTAssertEqual(highDrag.hit, .highHandle)
        let highMoved = MaskRangeBarGeometry.shape(
            for: highDrag, atX: MaskRangeBarGeometry.xPosition(forValue: 0.70, width: width),
            width: width)
        XCTAssertEqual(highMoved.high, 0.70, accuracy: 0.005, "high handle follows the hand")
        XCTAssertEqual(highMoved.low, start.low, "the other end is verbatim")
        print("RANGE handles · low 0.20→\(lowMoved.low) · high 0.80→\(highMoved.high)")
    }

    // ⑩ the body drag keeps the width (clamping is not re-normalisation)

    func testDraggingTheBodyKeepsTheWidth() {
        let start = LuminanceRangeShape(low: 0.20, high: 0.60,
                                        lowFeather: 0.10, highFeather: 0.10)
        let drag = MaskRangeBarGeometry.begin(
            atX: MaskRangeBarGeometry.xPosition(forValue: 0.40, width: width),
            width: width, shape: start)!
        XCTAssertEqual(drag.hit, .body)
        let moved = MaskRangeBarGeometry.shape(
            for: drag, atX: MaskRangeBarGeometry.xPosition(forValue: 0.50, width: width),
            width: width)
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
        let tooWide = LuminanceRangeShape(low: -0.10, high: LuminanceRangeShape.hdrMax,
                                          lowFeather: 0.10, highFeather: 0.10)
        let clamped = MaskRangeBarGeometry.translated(tooWide, by: 0.05)
        XCTAssertEqual(clamped.low, 0)
        XCTAssertEqual(clamped.high, LuminanceRangeShape.hdrMax)
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
            atX: MaskRangeBarGeometry.xPosition(forValue: start.low, width: width),
            width: width, shape: start))

        for x in stride(from: MaskRangeBarGeometry.xPosition(forValue: start.low, width: width),
                        through: MaskRangeBarGeometry.xPosition(forValue: 0.20, width: width),
                        by: 1) {
            let next = MaskRangeBarGeometry.shape(for: drag, atX: x, width: width)
            session.setMaskComponentShape(mask.id, component: component, shape: .luminanceRange(next),
                                          commit: false, label: "亮度范围条")
        }
        XCTAssertEqual(session.history.count, before,
                       "commit:false during the drag must not grow the stack")

        let final = MaskRangeBarGeometry.shape(
            for: drag, atX: MaskRangeBarGeometry.xPosition(forValue: 0.20, width: width),
            width: width)
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
            atX: MaskRangeBarGeometry.xPosition(forValue: picked.low, width: width),
            width: width, shape: picked))
        let moved = MaskRangeBarGeometry.shape(
            for: drag, atX: MaskRangeBarGeometry.xPosition(forValue: 0.30, width: width),
            width: width)
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

    // MARK: - 167: the axis is the HDR domain

    /// The ticks the owner named — `0 127 255 +2 +4` — sit at their own OKLab `L` on the
    /// `0…hdrMax` axis (the intermediate codes/stops are covered by the same table).
    func testAxisTicksSitAtTheirOKLabCoordinates() {
        let ticks = MaskRangeBarGeometry.axisTicks
        func value(_ label: String) -> Double {
            ticks.first { $0.label == label }?.value ?? .nan
        }
        XCTAssertEqual(value("0"), 0, accuracy: 1e-12)
        XCTAssertEqual(value("127"), OKLabMetric.fromSRGB(127.0 / 255, 127.0 / 255, 127.0 / 255).L,
                       accuracy: 1e-12)
        XCTAssertEqual(value("255"), 1, accuracy: 1e-6)
        XCTAssertEqual(value("+2"), cbrt(4.0), accuracy: 1e-12)
        XCTAssertEqual(value("+4"), LuminanceRangeShape.hdrMax, accuracy: 1e-12)

        // The bar maps a value to `value / hdrMax` of its width, so those ticks are where the axis
        // says they are — not a second, hand-placed scale.
        XCTAssertEqual(MaskRangeBarGeometry.xPosition(forValue: value("127"), width: width),
                       value("127") / LuminanceRangeShape.hdrMax * width, accuracy: 1e-12)
        XCTAssertEqual(MaskRangeBarGeometry.xPosition(forValue: value("+4"), width: width),
                       width, accuracy: 1e-12)
        print("RANGE axis · 0@0 · 127@\(value("127")) · 255@1 · +2@\(value("+2")) · +4@\(value("+4"))")
    }

    /// Dragging past the right edge clamps at `L_MAX`, and the value mapping is the inverse of the
    /// position mapping (so the top of the bar really is +4 EV, not 1.0).
    func testDraggingToTheTopStopsAtTheAxisMaximum() {
        let start = LuminanceRangeShape(low: 0, high: 2.0,
                                        lowFeather: 0.10, highFeather: 0.10)
        let drag = MaskRangeBarGeometry.begin(
            atX: MaskRangeBarGeometry.xPosition(forValue: 2.0, width: width),
            width: width, shape: start)!
        XCTAssertEqual(drag.hit, .highHandle)
        let moved = MaskRangeBarGeometry.shape(for: drag, atX: width * 2, width: width)
        XCTAssertEqual(moved.high, LuminanceRangeShape.hdrMax, accuracy: 1e-12,
                       "the handle stops at +4 EV; it must not run past the axis")
        XCTAssertEqual(MaskRangeBarGeometry.value(atX: width * 2, width: width),
                       LuminanceRangeShape.hdrMax, accuracy: 1e-12)
        print("RANGE top · high \(moved.high) == hdrMax \(LuminanceRangeShape.hdrMax)")
    }

    /// Double-click resets an end to the Core default: `low → 0`, `high → L_MAX` (a reset to 1.0
    /// would mean "only up to the white point" after 167).
    func testDoubleClickResetsToTheHDREnds() {
        let shape = LuminanceRangeShape(low: 0.5, high: 1.5,
                                        lowFeather: 0.2, highFeather: 0.3)
        let low = MaskRangeBarGeometry.resetting(.lowHandle, in: shape)
        XCTAssertEqual(low.low, 0, accuracy: 1e-12)
        XCTAssertEqual(low.high, 1.5, accuracy: 1e-12, "the other end is untouched")
        let high = MaskRangeBarGeometry.resetting(.highHandle, in: shape)
        XCTAssertEqual(high.low, 0.5, accuracy: 1e-12)
        XCTAssertEqual(high.high, LuminanceRangeShape.hdrMax, accuracy: 1e-12)
        XCTAssertEqual(high.lowFeather, 0.2, accuracy: 1e-12)
        XCTAssertEqual(high.highFeather, 0.3, accuracy: 1e-12)
        print("RANGE reset · low → 0 · high → \(high.high)")
    }
}
