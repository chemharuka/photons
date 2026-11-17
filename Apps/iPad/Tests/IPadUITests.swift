import XCTest

final class IPadUITests: XCTestCase {
    @MainActor
    func testLanguagePreferenceAppliesOnRestartAndCanReturnToEnglish() throws {
        let app = XCUIApplication(); app.launchArguments = ["--demo", "--reset-demo"]
        app.launchEnvironment["PHOTONS_LANGUAGE"] = "en"; app.launch()
        XCTAssertTrue(app.buttons["photo-Sample-01.tiff"].waitForExistence(timeout: 60))
        app.buttons["settings-button"].tap(); app.buttons["interface-language"].tap(); app.buttons["简体中文"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Language changes apply after restarting Photons."].exists)
        app.terminate(); app.launchEnvironment.removeValue(forKey: "PHOTONS_LANGUAGE"); app.launch()
        XCTAssertTrue(app.buttons["photo-Sample-01.tiff"].waitForExistence(timeout: 60))
        app.buttons["settings-button"].tap()
        XCTAssertTrue(app.staticTexts["语言更改将在重新启动 Photons 后生效。"].waitForExistence(timeout: 5))
        app.buttons["interface-language"].tap(); app.buttons["English"].firstMatch.tap()
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["photo-Sample-01.tiff"].waitForExistence(timeout: 60))
        app.buttons["settings-button"].tap()
        XCTAssertTrue(app.staticTexts["Language changes apply after restarting Photons."].waitForExistence(timeout: 5))
    }
    @MainActor
    func testChineseInterfaceCoversBrowsingSettingsAndLensDetails() throws {
        let app = XCUIApplication(); app.launchArguments = ["--demo", "--reset-demo"]
        app.launchEnvironment["PHOTONS_LANGUAGE"] = "zh-Hans"; app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        let first = app.buttons["photo-Sample-01.tiff"]
        XCTAssertTrue(first.waitForExistence(timeout: 60)); first.tap()
        XCTAssertTrue(app.otherElements["RGB 直方图"].waitForExistence(timeout: 15))
        let histogram = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); histogram.name = "Chinese grid and inspector"; histogram.lifetime = .keepAlways; add(histogram)
        first.doubleTap(); app.buttons["zoom-options"].tap()
        XCTAssertTrue(app.buttons["自定义…"].waitForExistence(timeout: 5)); app.buttons["自定义…"].tap()
        XCTAssertTrue(app.navigationBars["自定义倍率"].waitForExistence(timeout: 5))
        app.buttons["取消"].firstMatch.tap()
        app.buttons["settings-button"].tap()
        XCTAssertTrue(app.buttons["interface-language"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["语言更改将在重新启动 Photons 后生效。"].exists)
        let settings = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); settings.name = "Chinese settings"; settings.lifetime = .keepAlways; add(settings)
        app.buttons["镜头配置"].firstMatch.tap()
        app.buttons["lens-profile-43A1CC00-1115-4000-8000-000000000001"].tap()
        XCTAssertTrue(app.staticTexts["标定机身"].waitForExistence(timeout: 10))
        let lens = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); lens.name = "Chinese lens profile"; lens.lifetime = .keepAlways; add(lens)
    }
    @MainActor
    func testLensProfileOpensMetadataCoverageAndCaptureDetails() throws {
        let app = XCUIApplication(); app.launchArguments = ["--demo", "--reset-demo"]; app.launchEnvironment["PHOTONS_LANGUAGE"] = "en"; app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["photo-Sample-01.tiff"].waitForExistence(timeout: 60))
        app.buttons["settings-button"].tap(); app.buttons["Lens profiles"].firstMatch.tap()
        let profile = app.buttons["lens-profile-43A1CC00-1115-4000-8000-000000000001"]
        XCTAssertTrue(profile.waitForExistence(timeout: 10)); profile.tap()
        XCTAssertTrue(app.staticTexts["Calibration body"].waitForExistence(timeout: 10))
        let capture = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "profile-capture-")).firstMatch
        for _ in 0..<6 where !capture.isHittable { app.swipeUp() }
        XCTAssertTrue(capture.exists); capture.tap()
        XCTAssertTrue(app.staticTexts["Sensor size"].waitForExistence(timeout: 5))
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "Lens profile capture details"; shot.lifetime = .keepAlways; add(shot)
    }
    @MainActor
    func testSettingsMeasuresAndClearsPreviewCache() throws {
        let app = XCUIApplication(); app.launchArguments = ["--demo", "--reset-demo"]; app.launchEnvironment["PHOTONS_LANGUAGE"] = "en"; app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["photo-Sample-01.tiff"].waitForExistence(timeout: 60))
        app.buttons["settings-button"].tap()
        let clear = app.buttons["clear-preview-cache"]
        for _ in 0..<3 where !clear.isHittable { app.swipeUp() }
        XCTAssertTrue(clear.waitForExistence(timeout: 10)); clear.tap()
        app.buttons["confirm-clear-cache"].firstMatch.tap()
        let count = app.descendants(matching: .any)["cache-file-count"].firstMatch
        XCTAssertTrue(count.waitForExistence(timeout: 10))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "0"),object: count)],timeout: 10),.completed)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "Preview cache settings"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["close-settings"].tap()
        XCTAssertTrue(app.buttons["photo-Sample-01.tiff"].waitForExistence(timeout: 5))
    }
    @MainActor
    func testHistogramShowsClippingAndTouchReadout() throws {
        let app = XCUIApplication(); app.launchArguments = ["--demo", "--reset-demo"]; app.launchEnvironment["PHOTONS_LANGUAGE"] = "en"; app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        let first = app.buttons["photo-Sample-01.tiff"]
        XCTAssertTrue(first.waitForExistence(timeout: 60)); first.tap()
        let plot = app.descendants(matching: .any)["histogram-plot"].firstMatch
        XCTAssertTrue(plot.waitForExistence(timeout: 15)); plot.tap()
        XCTAssertTrue(app.descendants(matching: .any)["histogram-readout"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["histogram-clipping"].firstMatch.exists)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "iPad histogram details"; shot.lifetime = .keepAlways; add(shot)
    }
    @MainActor
    func testFoldersFilterMoveAndPersist() throws {
        let app = XCUIApplication(); app.launchArguments = ["--demo", "--reset-demo"]; app.launchEnvironment["PHOTONS_LANGUAGE"] = "en"; app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        let first = app.buttons["photo-Sample-01.tiff"]
        XCTAssertTrue(first.waitForExistence(timeout: 60))
        app.buttons["toggle-sidebar"].tap(); app.buttons["new-library-folder"].tap()
        let name = app.textFields["library-folder-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText("Travel")
        app.buttons["save-library-folder"].tap(); XCTAssertTrue(name.waitForNonExistence(timeout: 5))
        first.press(forDuration: 0.7)
        app.buttons["move-to-folder"].tap(); app.buttons["Move to Travel"].tap()
        app.buttons["Travel"].firstMatch.tap()
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["photo-Sample-02.tiff"].exists)
        app.buttons["Unfiled"].firstMatch.tap()
        XCTAssertTrue(app.buttons["photo-Sample-02.tiff"].waitForExistence(timeout: 5))
        XCTAssertFalse(first.exists)
    }
    @MainActor
    func testDoubleTapOpensPhotoAndSwipesNavigate() throws {
        let app = XCUIApplication(); app.launchArguments = ["--demo", "--reset-demo"]; app.launchEnvironment["PHOTONS_LANGUAGE"] = "en"; app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        let first = app.buttons["photo-Sample-01.tiff"]
        XCTAssertTrue(first.waitForExistence(timeout: 60)); first.doubleTap()
        let name = app.staticTexts["current-photo-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10)); XCTAssertEqual(name.label,"Sample-01.tiff")
        let canvas = app.descendants(matching: .any)["photo-canvas"].firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 10)); canvas.swipeLeft()
        XCTAssertTrue(name.wait(for: \.label,toEqual: "Sample-02.tiff",timeout: 10))
        canvas.swipeRight()
        XCTAssertTrue(name.wait(for: \.label,toEqual: "Sample-01.tiff",timeout: 10))
        canvas.swipeRight()
        XCTAssertEqual(name.label,"Sample-01.tiff")
        XCTAssertFalse(app.buttons["previous-photo"].isEnabled)
    }
    @MainActor
    func testDoubleTapTogglesFitAndSelectedMagnification() throws {
        let app = XCUIApplication(); app.launchArguments = ["--demo", "--reset-demo"]; app.launchEnvironment["PHOTONS_LANGUAGE"] = "en"; app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        let first = app.buttons["photo-Sample-01.tiff"]
        XCTAssertTrue(first.waitForExistence(timeout: 60)); first.doubleTap()
        let state = app.staticTexts["zoom-state"]
        XCTAssertTrue(state.waitForExistence(timeout: 10))
        let canvas = app.descendants(matching: .any)["photo-canvas"].firstMatch
        app.buttons["zoom-options"].tap(); app.buttons["200%"].tap()
        XCTAssertEqual(state.label,"Fit")
        canvas.doubleTap()
        XCTAssertTrue(state.wait(for: \.label,toEqual: "200%",timeout: 10))
        canvas.doubleTap()
        XCTAssertTrue(state.wait(for: \.label,toEqual: "Fit",timeout: 10))
        app.buttons["zoom-options"].tap(); app.buttons["50%"].tap()
        canvas.doubleTap()
        XCTAssertTrue(state.wait(for: \.label,toEqual: "50%",timeout: 10))
        canvas.doubleTap()
        XCTAssertTrue(state.wait(for: \.label,toEqual: "Fit",timeout: 10))
        app.buttons["zoom-options"].tap(); app.buttons["Custom…"].tap()
        let input = app.textFields["zoom-custom-input"]
        input.tap(); input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue,count: 3) + "150")
        XCTAssertEqual(input.value as? String,"150")
        app.buttons["zoom-custom-apply"].tap()
        XCTAssertTrue(input.waitForNonExistence(timeout: 5))
        canvas.doubleTap()
        XCTAssertTrue(state.wait(for: \.label,toEqual: "150%",timeout: 10))
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "Custom 150 percent magnification"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["zoom-fit"].tap()
        XCTAssertTrue(state.wait(for: \.label,toEqual: "Fit",timeout: 10))
    }
    @MainActor
    func testGridInspectorToggleDeselectsPhoto() throws {
        let app = XCUIApplication(); app.launchArguments = ["--demo", "--reset-demo"]; app.launchEnvironment["PHOTONS_LANGUAGE"] = "en"; app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        let first = app.buttons["photo-Sample-01.tiff"]
        XCTAssertTrue(first.waitForExistence(timeout: 60))
        func selection(_ value: String) {
            let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@",value),object: first)
            XCTAssertEqual(XCTWaiter.wait(for: [changed],timeout: 5),.completed)
        }
        first.tap()
        selection("Selected")
        XCTAssertTrue(app.otherElements["RGB histogram"].waitForExistence(timeout: 20))
        first.tap()
        selection("Not selected")
        XCTAssertFalse(app.otherElements["RGB histogram"].exists)
        first.tap()
        selection("Selected")
        app.buttons["toggle-inspector"].tap()
        selection("Not selected")
    }
    @MainActor
    func testGridInspectorSelectionAndPanoramaWorkflow() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--demo", "--reset-demo"]; app.launchEnvironment["PHOTONS_LANGUAGE"] = "en"; app.launch()
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
        // Single taps wait for the double-tap recognizer to fail before closing the inspector.
        XCTAssertTrue(app.otherElements["RGB histogram"].waitForNonExistence(timeout: 5))
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
        let exposure = app.sliders["Exposure (EV)"]
        XCTAssertTrue(exposure.waitForExistence(timeout: 5),app.debugDescription)
        exposure.adjust(toNormalizedSliderPosition: 0.625)
        let resetBrightness = app.buttons["reset-panorama-brightness"]
        XCTAssertTrue(resetBrightness.isEnabled)
        let highlights = app.sliders["HDR highlight brightness (stops)"]
        highlights.adjust(toNormalizedSliderPosition: 0.25)
        let ready = NSPredicate(format: "enabled == true")
        XCTAssertTrue(app.buttons["panorama-export"].wait(for: \.isEnabled,toEqual: true,timeout: 15))
        let tone = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); tone.name = "Panorama exposure and HDR brightness"; tone.lifetime = .keepAlways; add(tone)
        resetBrightness.tap()
        XCTAssertFalse(resetBrightness.isEnabled)
        expectation(for: ready,evaluatedWith: app.buttons["panorama-export"])
        waitForExpectations(timeout: 15)
        for angle in [90,180,270,0] {
            let orientation = app.buttons["panorama.body.orientation.\(angle)"]
            XCTAssertTrue(orientation.exists)
            orientation.tap()
            XCTAssertEqual(orientation.value as? String,"Selected")
        }
        let angles = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); angles.name = "Body orientation diagrams"; angles.lifetime = .keepAlways; add(angles)
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
        let workspace = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); workspace.name = "Large panorama workspace"; workspace.lifetime = .keepAlways; add(workspace)
        app.buttons["panorama-export"].tap()
        app.buttons["export-size"].tap()
        app.buttons["Full resolution"].tap()
        app.buttons["confirm-export"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Saved ")).firstMatch.waitForExistence(timeout: 90), app.debugDescription)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "iPad panorama workspace"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["settings-button"].tap()
        XCTAssertTrue(app.navigationBars["General"].waitForExistence(timeout: 5))
        app.buttons["Photo library"].firstMatch.tap()
        XCTAssertTrue(app.switches["Skip duplicate imports"].waitForExistence(timeout: 5))
        app.buttons["Lens profiles"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Import lens profile"].waitForExistence(timeout: 5))
        let settings = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); settings.name = "Full-screen settings tabs"; settings.lifetime = .keepAlways; add(settings)
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
