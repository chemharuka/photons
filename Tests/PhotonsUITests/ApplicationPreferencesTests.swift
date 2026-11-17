import XCTest
import AppKit
import Metal
@testable import PhotonsUI

@MainActor
final class ApplicationPreferencesTests: XCTestCase {
    func testPersistenceAndUnknownEnumFallback() {
        let name = "photons.preferences.tests.\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        defer { store.removePersistentDomain(forName: name) }
        let preferences = ApplicationPreferences(defaults: store)
        XCTAssertTrue(preferences.hdrPreview)
        XCTAssertTrue(preferences.denoiseGPU)
        preferences.hdrPreview = false
        preferences.denoiseGPU = false
        preferences.reopenLibrary = false
        preferences.processing = .economical
        preferences.appearance = .light
        let restored = ApplicationPreferences(defaults: store)
        XCTAssertFalse(restored.hdrPreview)
        XCTAssertFalse(restored.denoiseGPU)
        XCTAssertFalse(restored.reopenLibrary)
        XCTAssertEqual(restored.processing, .economical)
        XCTAssertEqual(restored.appearance, .light)
        store.set("future", forKey: ApplicationPreferences.Key.processing)
        store.set("future", forKey: ApplicationPreferences.Key.appearance)
        let future = ApplicationPreferences(defaults: store)
        XCTAssertEqual(future.processing, .automatic)
        XCTAssertEqual(future.appearance, .dark)
    }

    func testPressureAndMemoryBoundConcurrency() {
        let gb: UInt64 = 1_024 * 1_024 * 1_024
        XCTAssertEqual(ProcessingPolicy.automatic.thumbnailConcurrency(processors: 18, memory: 64 * gb,
            lowPower: false, thermal: .nominal), 4)
        XCTAssertEqual(ProcessingPolicy.responsive.thumbnailConcurrency(processors: 18, memory: 8 * gb,
            lowPower: false, thermal: .nominal), 4)
        XCTAssertEqual(ProcessingPolicy.automatic.thumbnailConcurrency(processors: 18, memory: 64 * gb,
            lowPower: true, thermal: .nominal), 1)
        for policy in ProcessingPolicy.allCases {
            XCTAssertEqual(policy.thumbnailConcurrency(processors: 18, memory: 64 * gb,
                lowPower: false, thermal: .serious), 1)
            XCTAssertEqual(policy.thumbnailConcurrency(processors: 1, memory: gb,
                lowPower: false, thermal: .nominal), 1)
        }
    }

    func testSettingsMenuIsBelowAboutAndWorksWithoutEditor() throws {
        _ = NSApplication.shared
        let menu = MainMenu.build()
        let app = try XCTUnwrap(menu.items.first?.submenu)
        let item = try XCTUnwrap(app.items.first { $0.keyEquivalent == "," })
        XCTAssertEqual(app.index(of: item), 1)
        XCTAssertEqual(item.keyEquivalentModifierMask, [.command])
        XCTAssertTrue(item.target === SettingsWindowController.shared)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        let window = try XCTUnwrap(SettingsWindowController.shared.window)
        defer { window.orderOut(nil) }
        XCTAssertTrue(window.isVisible)
        let first = window.windowNumber
        SettingsWindowController.shared.openSettings(nil)
        XCTAssertEqual(SettingsWindowController.shared.window?.windowNumber, first)
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        if let path = ProcessInfo.processInfo.environment["PHOTONS_UI_AUDIT_SHOTS"],
           let view = window.contentView,
           let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(
                to: URL(fileURLWithPath: path).appendingPathComponent("settings.png"))
        }
    }
}
