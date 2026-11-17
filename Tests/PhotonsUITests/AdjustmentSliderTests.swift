import XCTest
import AppKit
import SwiftUI
@testable import PhotonsUI

@MainActor
final class AdjustmentSliderTests: XCTestCase {
    func testKeyboardAndAccessibilityKeepEditTransactionsAndStep() {
        let slider = AdjustmentNSSlider(frame: NSRect(x: 0, y: 0, width: 200, height: 16))
        slider.minValue = -4; slider.maxValue = 4; slider.doubleValue = 0; slider.valueStep = 0.05
        var edits: [Bool] = []
        slider.editingChanged = { edits.append($0) }
        let right = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                     windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                                     isARepeat: false, keyCode: 124)!
        slider.keyDown(with: right)
        XCTAssertEqual(slider.doubleValue, 0.05, accuracy: 0.0001)
        XCTAssertEqual(edits, [true, false])
        XCTAssertTrue(slider.accessibilityPerformDecrement())
        XCTAssertEqual(slider.doubleValue, 0, accuracy: 0.0001)
        XCTAssertEqual(edits, [true, false, true, false])
        slider.isEnabled = false
        XCTAssertFalse(slider.accessibilityPerformIncrement())
        XCTAssertEqual(slider.doubleValue, 0)
    }

    func testHandleIsWideRoundedRectangle() throws {
        let cell = AdjustmentSliderCell()
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 40,
                                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        cell.drawKnob(NSRect(x: 10, y: 10, width: 20, height: 20))
        NSGraphicsContext.restoreGraphicsState()
        // Symmetric rows and columns around (20,20): wider than tall, with solid shoulders.
        XCTAssertGreaterThan(rep.colorAt(x: 14, y: 17)?.alphaComponent ?? 0, 0.9)
        XCTAssertGreaterThan(rep.colorAt(x: 25, y: 22)?.alphaComponent ?? 0, 0.9)
        XCTAssertLessThan(rep.colorAt(x: 20, y: 13)?.alphaComponent ?? 1, 0.05)
        XCTAssertLessThan(rep.colorAt(x: 12, y: 20)?.alphaComponent ?? 1, 0.1, "Allow the half-point outline's antialiased fringe")
    }
}
