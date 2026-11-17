import XCTest

final class IPadUITests: XCTestCase {
    @MainActor
    func testGridInspectorSelectionAndPanoramaWorkflow() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--demo"]; app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        let first = app.buttons["photo-Sample-01.tiff"]
        XCTAssertTrue(first.waitForExistence(timeout: 90), app.debugDescription)
        XCTAssertFalse(app.buttons["panorama-tool"].exists)
        app.buttons["toggle-sidebar"].tap()
        XCTAssertTrue(app.buttons["All photographs"].waitForExistence(timeout: 5))
        app.buttons["toggle-sidebar"].tap()
        XCTAssertFalse(app.buttons["All photographs"].exists)
        let width = first.frame.width
        app.scrollViews["photo-grid"].pinch(withScale: width < 230 ? 1.5 : 0.65, velocity: width < 230 ? 1 : -1)
        XCTAssertGreaterThan(abs(first.frame.width - width), width * 0.1)

        first.tap()
        XCTAssertTrue(app.otherElements["RGB histogram"].waitForExistence(timeout: 30))
        first.tap()
        XCTAssertFalse(app.otherElements["RGB histogram"].exists)
        first.press(forDuration: 0.7)
        XCTAssertTrue(app.buttons["finish-selection"].waitForExistence(timeout: 5))
        app.buttons["photo-Sample-02.tiff"].tap()
        XCTAssertTrue(app.buttons["panorama-tool"].waitForExistence(timeout: 5))
        app.buttons["panorama-tool"].tap()
        XCTAssertTrue(app.buttons["choose-panorama-shift"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["panorama-preview"].exists)
        app.buttons["choose-panorama-shift"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["panorama-preview"].waitForExistence(timeout: 90), app.debugDescription)
        let displayMode = app.buttons["panorama-display-mode"], originalMode = app.buttons["panorama-display-mode"].label
        displayMode.tap()
        XCTAssertNotEqual(displayMode.label,originalMode)
        displayMode.tap()
        XCTAssertEqual(displayMode.label,originalMode)
        for angle in [90,180,270,0] {
            let orientation = app.buttons["panorama.body.orientation.\(angle)"]
            XCTAssertTrue(orientation.exists)
            orientation.tap()
            XCTAssertEqual(orientation.value as? String,"Selected")
        }
        let angles = XCTAttachment(screenshot: app.screenshot()); angles.name = "Body orientation diagrams"; angles.lifetime = .keepAlways; add(angles)
        let frame = app.descendants(matching: .any)["shift-frame-0"]
        XCTAssertTrue(frame.exists, app.debugDescription)
        let value = frame.value as? String
        let originalCenter = CGPoint(x: frame.frame.midX,y: frame.frame.midY)
        let start = frame.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 10, dy: -8)))
        XCTAssertNotEqual(frame.value as? String, value)
        XCTAssertEqual(frame.frame.midX-originalCenter.x,10,accuracy: 2)
        XCTAssertEqual(frame.frame.midY-originalCenter.y,-8,accuracy: 2)
        XCTAssertFalse(app.buttons["panorama-export"].isEnabled)
        let revert = app.buttons["revert-panorama-layout"]
        XCTAssertTrue(revert.isEnabled); revert.tap()
        XCTAssertEqual(frame.value as? String,value)
        XCTAssertEqual(frame.frame.midX,originalCenter.x,accuracy: 1)
        XCTAssertEqual(frame.frame.midY,originalCenter.y,accuracy: 1)
        XCTAssertFalse(revert.isEnabled)
        XCTAssertTrue(app.buttons["panorama-export"].isEnabled,"Revert restores the existing aligned preview immediately")
        // Grabbing away from the center must move the same geometric center by the finger delta.
        let corner = frame.coordinate(withNormalizedOffset: CGVector(dx: 0.2,dy: 0.25))
        corner.press(forDuration: 0.1,thenDragTo: corner.withOffset(CGVector(dx: 12,dy: 6)))
        XCTAssertEqual(frame.frame.midX-originalCenter.x,12,accuracy: 2)
        XCTAssertEqual(frame.frame.midY-originalCenter.y,6,accuracy: 2)
        revert.tap()
        XCTAssertEqual(frame.value as? String,value)
        let controls = app.scrollViews["panorama-controls"]
        func scrollControls() {
            // The diagram intentionally consumes drags over frames; scroll through the gutter.
            let start = controls.coordinate(withNormalizedOffset: CGVector(dx: 0.98,dy: 0.85))
            start.press(forDuration: 0.05,thenDragTo: controls.coordinate(withNormalizedOffset: CGVector(dx: 0.98,dy: 0.2)))
        }
        scrollControls()
        let crop = app.switches["panorama-crop-lcc"]
        if !crop.isHittable { scrollControls() }
        XCTAssertTrue(crop.exists)
        crop.tap()
        XCTAssertEqual(crop.value as? String,"1")
        XCTAssertFalse(app.buttons["panorama-export"].isEnabled, "A requested LCC crop must be applied before exporting")
        crop.tap()
        XCTAssertEqual(crop.value as? String,"0")
        XCTAssertTrue(app.buttons["panorama-export"].isEnabled)
        let workspace = XCTAttachment(screenshot: app.screenshot()); workspace.name = "Large panorama workspace"; workspace.lifetime = .keepAlways; add(workspace)
        app.buttons["panorama-export"].tap()
        app.buttons["export-size"].tap()
        app.buttons["Full resolution"].tap()
        app.buttons["confirm-export"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Saved ")).firstMatch.waitForExistence(timeout: 90), app.debugDescription)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "iPad panorama workspace"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["settings-button"].tap()
        XCTAssertTrue(app.navigationBars["General"].waitForExistence(timeout: 5))
        app.buttons["Photo library"].firstMatch.tap()
        XCTAssertTrue(app.switches["Skip duplicate imports"].waitForExistence(timeout: 5))
        app.buttons["Lens profiles"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Import lens profile"].waitForExistence(timeout: 5))
        let settings = XCTAttachment(screenshot: app.screenshot()); settings.name = "Full-screen settings tabs"; settings.lifetime = .keepAlways; add(settings)
        app.buttons["close-settings"].tap()
        app.buttons["grid-view"].tap()
        app.buttons["panorama-tool"].tap()
        app.buttons["choose-panorama-perspective"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["panorama-preview"].waitForExistence(timeout: 90), app.debugDescription)
        XCTAssertFalse(app.descendants(matching: .any)["body-shift-diagram"].exists)
        XCTAssertTrue(app.navigationBars["Perspective panorama"].exists)
        app.buttons["close-panorama"].tap()
    }
}
