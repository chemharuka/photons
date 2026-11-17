import XCTest
import AppKit
import SwiftUI
import PhotonsPanorama
@testable import PhotonsUI

@MainActor
final class CameraBodySettingsTests: XCTestCase {
    func testDraftSupportsRenameIndependentDirectionsAndDisabledAmounts() throws {
        var draft = CameraBodyDraft()
        draft.name = "自建后背机身"
        draft.enabled = [.left, .up]
        draft.amounts = [.left: 12.5, .right: 23, .up: 30, .down: 100]
        let first = try draft.body()
        XCTAssertEqual(first.defaultTravel, .init(left: 12.5, right: 0, up: 30, down: 0))
        draft.name = "新名称"
        XCTAssertEqual(try draft.body().id, first.id)
        XCTAssertEqual(try draft.body().name, "新名称")
        draft.amounts[.left] = 0
        XCTAssertThrowsError(try draft.body())
        draft.amounts[.left] = .infinity
        XCTAssertThrowsError(try draft.body())
        draft.enabled = []
        XCTAssertEqual(try draft.body().defaultTravel, .init(left: 0, right: 0, up: 0, down: 0))
    }

    func testEditingExistingProfileRetainsDirectionAndID() throws {
        let profile = try CameraBodyProfile(name: "Vertical", travel: .init(left: 0, right: 0, up: 45, down: 25))
        let draft = CameraBodyDraft(profile: profile)
        XCTAssertEqual(draft.enabled, [.up, .down])
        XCTAssertFalse(draft.isNew)
        XCTAssertEqual(try draft.body(), .custom(profile))
    }

    func testLibraryPublishesEditsWithoutMutatingTaskSnapshot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("camera-body-ui-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = CameraBodyLibrary(store: .init(directory: root))
        var draft = CameraBodyDraft(); draft.name = "Body"
        let frozen = try draft.body()
        try library.save(frozen)
        XCTAssertTrue(library.containsSnapshot(frozen))
        draft.name = "Renamed"; draft.enabled = [.up]; draft.amounts[.up] = 35
        let updated = try draft.body()
        try library.save(updated)
        XCTAssertFalse(library.containsSnapshot(frozen), "The picker must offer the old definition as a current-task snapshot")
        XCTAssertEqual(library.custom, [updated])
        XCTAssertEqual(CameraBodyLibrary(store: .init(directory: root)).custom, [updated])
        try library.delete(updated)
        XCTAssertEqual(library.bodies, PanoramaCameraBody.allCases)
        XCTAssertEqual(frozen.name, "Body")
        XCTAssertEqual(frozen.defaultTravel.up, 0)
    }

    func testSettingsEditorAndCustomPickerRenderWithoutOverflow() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("camera-body-ui-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = CameraBodyLibrary(store: .init(directory: root))
        let profile = try CameraBodyProfile(name: "我的移轴机身", travel: .init(left: 12, right: 18, up: 25, down: 0))
        try library.save(.custom(profile))
        let views: [(String, AnyView, CGFloat)] = [
            ("settings-window", AnyView(SettingsView(generalTab: .cameraBodies, cameraBodyLibrary: library)), 760),
            ("settings", AnyView(CameraBodySettingsView(library: library).padding(24)), 531),
            ("editor", AnyView(CameraBodyEditor(draft: .init(profile: profile), library: library, saved: { _ in })), 448),
            ("picker", AnyView(VStack {
                CameraBodyPicker(selection: .constant(.custom(profile)), library: library)
                PanoramaBodyOrientationPicker(cameraBody: .custom(profile), selection: .constant(.degrees0))
            }.padding(20)), 340)
        ]
        for (name, content, width) in views {
            let host = NSHostingView(rootView: content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color(nsColor: StudioTheme.raised)))
            host.frame = NSRect(x: 0, y: 0, width: width, height: name == "settings-window" ? 550 : (name == "picker" ? 160 : 450))
            let window = TestWindows.make(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua); window.contentView = host
            defer { window.close() }
            RunLoop.main.run(until: Date().addingTimeInterval(0.25)); host.layoutSubtreeIfNeeded()
            XCTAssertLessThanOrEqual(host.fittingSize.width, width + 1)
            if ProcessInfo.processInfo.environment["PHOTONS_CAMERA_BODY_SNAPSHOTS"] == "1" {
                let image = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: image)
                try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/photons-camera-body-\(name).png"))
            }
        }
    }
}
