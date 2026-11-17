import XCTest
import AppKit
import SwiftUI
@testable import PhotonsPanorama
@testable import PhotonsUI

@MainActor
final class LensInfoSettingsTests: XCTestCase {
    private func profile(name: String) -> LCCLensProfile {
        let grid = LCCMeasurementGrid(x: [-10, 10], y: [8, -8], channels: ["R", "G", "B"],
            values: LCCMeasurementGrid.pack([Float](repeating: 0.2, count: 12)), standardError: nil, space: "apple-linear-srgb-6500K-v1")
        let capture = LCCProfileCapture(id: UUID(), filename: "white.tif", orientation: .landscape,
            shiftX: 0, shiftY: 0, sensorWidth: 36, sensorHeight: 24, pixelWidth: 80, pixelHeight: 60,
            iso: 64, exposureSeconds: 1, capturedAt: nil, grid: grid, thumbnail: nil)
        return LCCLensProfile(id: UUID(), name: name, camera: "Test back", aperture: 11, notes: "", createdAt: Date(), captures: [capture])
    }
    private func waitForLibrary(_ model: LCCProfileLibraryModel) async throws {
        let deadline = Date().addingTimeInterval(10)
        while (model.busy || model.loadingProfile) && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(model.busy); XCTAssertFalse(model.loadingProfile); XCTAssertNil(model.error)
    }

    func testSharedSelectionUpdatesAndLatestRefreshWins() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lens-info-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LCCProfileStore(directory: root), first = profile(name: "A"), second = profile(name: "B")
        try store.save(first); try store.save(second)
        let model = LCCProfileLibraryModel(store: store, installBundledProfile: false)
        model.refresh(select: first.id); model.refresh(select: second.id)
        try await waitForLibrary(model)
        XCTAssertEqual(model.profiles.map(\.id), [first.id, second.id])
        XCTAssertEqual(model.selected, second.id); XCTAssertEqual(model.profile?.id, second.id)
        model.selected = first.id
        try await waitForLibrary(model)
        XCTAssertEqual(model.profile?.id, first.id)
        var edited = first; edited.name = "Renamed"
        try store.save(edited); model.refresh()
        try await waitForLibrary(model)
        XCTAssertEqual(model.profile?.name, "Renamed")
        XCTAssertEqual(model.profiles.first { $0.id == first.id }?.name, "Renamed")
        try FileManager.default.removeItem(at: store.url(for: first.id)); model.refresh()
        try await waitForLibrary(model)
        XCTAssertEqual(model.selected, second.id)
        XCTAssertEqual(model.profile?.id, second.id)
    }

    func testConfigurationManagerIsIndependentAndReusesOneWindow() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lens-manager-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LCCProfileStore(directory: root), selected = profile(name: "Selected lens")
        try store.save(selected)
        let model = LCCProfileLibraryModel(store: store, installBundledProfile: false)
        let controller = LCCProfileLibraryWindowController(model: model)
        let window = try XCTUnwrap(controller.window)
        TestWindows.adopt(window); defer { controller.close() }
        controller.open(select: selected.id)
        try await waitForLibrary(model)
        XCTAssertTrue(controller.model === model)
        XCTAssertEqual(window.title, "管理配置文件")
        XCTAssertNotNil(window.contentView as? NSHostingView<LCCProfileLibraryView>, "The manager must not host the correction workspace/tabs")
        XCTAssertEqual(model.profile?.id, selected.id)
        let number = window.windowNumber
        controller.open(select: selected.id)
        try await waitForLibrary(model)
        XCTAssertEqual(controller.window?.windowNumber, number)
    }

    func testKeepingBothImportsSelectsNewCalibrationAndUpdatesSharedCatalog() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lens-import-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LCCProfileStore(directory: root), original = profile(name: "Same lens and sensor")
        try store.save(original)
        let model = LCCProfileLibraryModel(store: store, installBundledProfile: false)
        model.refresh(select: original.id); try await waitForLibrary(model)
        var imported = original; imported.notes = "A separate calibration"; imported.cameraBody = .alpa12STC
        model.saveImportedProfile(imported, keepingBoth: true)
        try await waitForLibrary(model)
        XCTAssertEqual(model.profiles.count, 2)
        XCTAssertNotEqual(model.selected, original.id)
        XCTAssertEqual(model.profile?.notes, imported.notes)
        XCTAssertEqual(model.profile?.cameraBody, .alpa12STC)
        XCTAssertEqual(try store.load(original.id), original)
    }

    func testEmptyLibraryDoesNotStayLoadingAndDistortionIsUnavailable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lens-empty-\(UUID())")
        let model = LCCProfileLibraryModel(store: .init(directory: root), installBundledProfile: false)
        model.refresh(select: UUID())
        try await waitForLibrary(model)
        XCTAssertTrue(model.profiles.isEmpty); XCTAssertNil(model.selected); XCTAssertNil(model.profile)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        XCTAssertTrue(LensCorrectionFeature.lcc.isAvailable)
        XCTAssertFalse(LensCorrectionFeature.distortion.isAvailable)
    }

    func testRecordedProfileWaitsForCatalogWithoutOverridingManualChoice() {
        let saved = profile(name: "Recorded lens")
        let correction = LCCWindowModel(urls: [])
        correction.useRecordedProfile(saved.id)
        correction.resolveRecordedProfile(in: [])
        correction.resolveRecordedProfile(in: [LCCProfileSummary(saved)])
        XCTAssertEqual(correction.profileID, saved.id.uuidString)
        correction.useRecordedProfile(saved.id)
        correction.selectProfile("manually-selected")
        correction.resolveRecordedProfile(in: [LCCProfileSummary(saved)])
        XCTAssertEqual(correction.profileID, "manually-selected")
    }

    func testLensSettingsAndManagerLayouts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lens-layout-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LCCProfileStore(directory: root), sample = profile(name: "Rodenstock 43 mm · LCC")
        try store.save(sample)
        let model = LCCProfileLibraryModel(store: store, installBundledProfile: false)
        model.refresh(select: sample.id); try await waitForLibrary(model)
        let views: [(String, AnyView, NSSize)] = [
            ("settings", AnyView(SettingsView(generalTab: .lenses, lensLibrary: model)), NSSize(width: 760, height: 550)),
            ("manager", AnyView(LCCProfileLibraryView(model: model)), NSSize(width: 980, height: 720))
        ]
        for (name, view, size) in views {
            let host = NSHostingView(rootView: view.frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: StudioTheme.raised)))
            host.frame = NSRect(origin: .zero, size: size)
            let window = TestWindows.make(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua); window.contentView = host
            defer { window.close() }
            try await Task.sleep(nanoseconds: 250_000_000); host.layoutSubtreeIfNeeded()
            XCTAssertLessThanOrEqual(host.fittingSize.width, size.width + 1)
            if ProcessInfo.processInfo.environment["PHOTONS_LENS_INFO_SNAPSHOTS"] == "1" {
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/photons-lens-info-\(name).png"))
            }
        }
    }
}
