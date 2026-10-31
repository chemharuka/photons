import CoreGraphics
import XCTest
import PhotonsCore
import PhotonsUI

/// P5a — the 原图 / 前后对比 state machine, without a loupe, a document or a GPU.
final class LoupeCompareSessionTests: XCTestCase {

    private let bounds = CGRect(x: 0, y: 0, width: 1000, height: 500)

    func testShowOriginalTogglesAndCounts() {
        let session = LoupeCompareSession()
        var changes = 0
        session.onChange = { changes += 1 }

        XCTAssertEqual(session.frameMode, .edited)
        XCTAssertTrue(session.toggleShowOriginal())
        XCTAssertTrue(session.showOriginal)
        XCTAssertEqual(session.frameMode, .original)
        XCTAssertEqual(session.modeChanges, 1)
        XCTAssertEqual(changes, 1)

        // Setting the state it already has is not a change.
        XCTAssertTrue(session.setShowOriginal(true))
        XCTAssertEqual(session.modeChanges, 1)
        XCTAssertEqual(changes, 1)

        XCTAssertFalse(session.setShowOriginal(false))
        XCTAssertFalse(session.showOriginal)
        XCTAssertEqual(session.frameMode, .edited)
        XCTAssertEqual(session.modeChanges, 2)
        XCTAssertEqual(changes, 2)
    }

    func testCompareStartsAtHalfAndRemembers() {
        let session = LoupeCompareSession()

        XCTAssertTrue(session.setCompare(true))
        XCTAssertEqual(session.split, .half)
        XCTAssertEqual(session.frameMode, .compare(.half))
        XCTAssertEqual(session.modeChanges, 1)

        // Already on: no new change.
        XCTAssertTrue(session.setCompare(true))
        XCTAssertEqual(session.modeChanges, 1)

        session.setCompareFraction(0.3)
        XCTAssertEqual(session.split?.fraction ?? 0, 0.3, accuracy: 1e-12)
        XCTAssertEqual(session.splitDrags, 1)
        XCTAssertEqual(session.modeChanges, 2)

        XCTAssertFalse(session.setCompare(false))
        XCTAssertNil(session.split)
        XCTAssertEqual(session.frameMode, .edited)
        XCTAssertEqual(session.modeChanges, 3)

        // Turning it back on remembers the split it was left at.
        XCTAssertTrue(session.setCompare(true))
        XCTAssertEqual(session.split, CompareSplit(axis: .vertical, fraction: 0.3))
        XCTAssertEqual(session.modeChanges, 4)
    }

    func testCompareOffKeepsTheLastSplit() {
        let session = LoupeCompareSession()
        session.setCompare(true)
        session.toggleCompareAxis()
        session.setCompareFraction(0.7)

        let remembered = session.split
        XCTAssertEqual(remembered, CompareSplit(axis: .horizontal, fraction: 0.7))

        session.setCompare(false)
        XCTAssertNil(session.split)
        session.setCompare(true)
        XCTAssertEqual(session.split, remembered)

        // Toggling off when already off writes nothing.
        session.setCompare(false)
        let changes = session.modeChanges
        XCTAssertFalse(session.setCompare(false))
        XCTAssertEqual(session.modeChanges, changes)
        XCTAssertNil(session.split)
    }

    func testAxisToggleKeepsFraction() {
        let session = LoupeCompareSession()
        session.setCompare(true)
        session.setCompareFraction(0.42)

        session.toggleCompareAxis()
        XCTAssertEqual(session.split, CompareSplit(axis: .horizontal, fraction: 0.42))
        XCTAssertEqual(session.splitDrags, 1)

        session.setCompareAxis(.vertical)
        XCTAssertEqual(session.split, CompareSplit(axis: .vertical, fraction: 0.42))

        // The axis it already has is not a change.
        let changes = session.modeChanges
        session.setCompareAxis(.vertical)
        XCTAssertEqual(session.modeChanges, changes)

        // With 对比 off there is no axis to turn.
        session.setCompare(false)
        let offChanges = session.modeChanges
        session.toggleCompareAxis()
        session.setCompareAxis(.horizontal)
        XCTAssertEqual(session.modeChanges, offChanges)
        XCTAssertNil(session.split)
    }

    func testFractionClampsAndIgnoresSubEpsilonMoves() {
        let session = LoupeCompareSession()

        // Nothing to move before 对比 is on.
        session.setCompareFraction(0.3)
        XCTAssertNil(session.split)
        XCTAssertEqual(session.splitDrags, 0)

        session.setCompare(true)
        XCTAssertEqual(session.splitDrags, 0)

        session.setCompareFraction(1.7)
        XCTAssertEqual(session.split?.fraction ?? -1, 1, accuracy: 1e-12)
        XCTAssertEqual(session.splitDrags, 1)

        session.setCompareFraction(-0.2)
        XCTAssertEqual(session.split?.fraction ?? -1, 0, accuracy: 1e-12)
        XCTAssertEqual(session.splitDrags, 2)

        session.setCompareFraction(0.5)
        XCTAssertEqual(session.split?.fraction ?? -1, 0.5, accuracy: 1e-12)
        XCTAssertEqual(session.splitDrags, 3)

        // A move inside the 1e-6 epsilon is not a drag.
        session.setCompareFraction(0.5 + 5e-7)
        XCTAssertEqual(session.split?.fraction ?? -1, 0.5, accuracy: 1e-12)
        XCTAssertEqual(session.splitDrags, 3)

        // A non-finite fraction means the middle, and here that is where the line already is.
        let changes = session.modeChanges
        session.setCompareFraction(.nan)
        XCTAssertEqual(session.split?.fraction ?? -1, 0.5, accuracy: 1e-12)
        XCTAssertEqual(session.splitDrags, 3)
        XCTAssertEqual(session.modeChanges, changes)

        // Any non-finite fraction means the middle, whichever end it started from.
        session.setCompareFraction(0.7)
        XCTAssertEqual(session.split?.fraction ?? -1, 0.7, accuracy: 1e-12)
        XCTAssertEqual(session.splitDrags, 4)
        session.setCompareFraction(.infinity)
        XCTAssertEqual(session.split?.fraction ?? -1, 0.5, accuracy: 1e-12)
        XCTAssertEqual(session.splitDrags, 5)
    }

    func testDragOnlyMovesWhileDragging() {
        let session = LoupeCompareSession()
        session.setCompare(true)
        let canvas = ImageSize(width: 1000, height: 500)

        // The line is at x = 500; a click on it takes the drag.
        XCTAssertTrue(session.beginDrag(atViewPoint: CGPoint(x: 500, y: 250), bounds: bounds,
                                        canvas: canvas, backingScale: 1))
        XCTAssertTrue(session.isDragging)

        session.continueDrag(atViewPoint: CGPoint(x: 250, y: 250), bounds: bounds)
        XCTAssertEqual(session.split?.fraction ?? -1, 0.25, accuracy: 1e-12)
        XCTAssertEqual(session.splitDrags, 1)
        XCTAssertTrue(session.isDragging)

        session.endDrag()
        XCTAssertFalse(session.isDragging)

        // After the hand lets go, moving the pointer writes nothing.
        session.continueDrag(atViewPoint: CGPoint(x: 750, y: 250), bounds: bounds)
        XCTAssertEqual(session.split?.fraction ?? -1, 0.25, accuracy: 1e-12)
        XCTAssertEqual(session.splitDrags, 1)

        // A click away from the line does not start a drag.
        XCTAssertFalse(session.beginDrag(atViewPoint: CGPoint(x: 900, y: 250), bounds: bounds,
                                         canvas: canvas, backingScale: 1))
        XCTAssertFalse(session.isDragging)
    }

    func testDividerHitUsesBackingScale() {
        let session = LoupeCompareSession()
        session.setCompare(true)
        let canvas = ImageSize(width: 2000, height: 1000)
        let wideBounds = CGRect(x: 0, y: 0, width: 2000, height: 1000)

        // At 50 % the line is canvas x = 1000, i.e. view x = 1000.
        XCTAssertTrue(session.dividerHit(atViewPoint: CGPoint(x: 1000, y: 500),
                                         bounds: wideBounds, canvas: canvas, backingScale: 2))
        // 9 pt × 2 = 18 px of travel along a 2000 px axis: 5 px is inside, 30 px is outside.
        XCTAssertTrue(session.dividerHit(atViewPoint: CGPoint(x: 1005, y: 500),
                                         bounds: wideBounds, canvas: canvas, backingScale: 2))
        XCTAssertFalse(session.dividerHit(atViewPoint: CGPoint(x: 1030, y: 500),
                                          bounds: wideBounds, canvas: canvas, backingScale: 2))

        // The grab radius really is scaled: 10 px is outside at 1×, inside at 2×.
        XCTAssertFalse(session.dividerHit(atViewPoint: CGPoint(x: 1010, y: 500),
                                          bounds: wideBounds, canvas: canvas, backingScale: 1))
        XCTAssertTrue(session.dividerHit(atViewPoint: CGPoint(x: 1010, y: 500),
                                         bounds: wideBounds, canvas: canvas, backingScale: 2))

        // 对比 off is never a hit, and neither is an empty canvas.
        session.setCompare(false)
        XCTAssertFalse(session.dividerHit(atViewPoint: CGPoint(x: 1000, y: 500),
                                          bounds: wideBounds, canvas: canvas, backingScale: 2))
        XCTAssertFalse(session.dividerHit(atViewPoint: CGPoint(x: 1000, y: 500),
                                          bounds: wideBounds,
                                          canvas: ImageSize(width: 0, height: 0), backingScale: 2))
    }

    func testFrameModePriorityOriginalWinsOverCompare() {
        let session = LoupeCompareSession()
        session.setCompare(true)
        session.setCompareFraction(0.3)
        XCTAssertEqual(session.frameMode, .compare(CompareSplit(axis: .vertical, fraction: 0.3)))

        session.setShowOriginal(true)
        XCTAssertEqual(session.frameMode, .original)

        session.setShowOriginal(false)
        XCTAssertEqual(session.frameMode, .compare(CompareSplit(axis: .vertical, fraction: 0.3)))

        session.setCompare(false)
        XCTAssertEqual(session.frameMode, .edited)
    }
}
