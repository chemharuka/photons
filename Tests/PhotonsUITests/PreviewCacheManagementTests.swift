import XCTest
import AppKit
import SwiftUI
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

@MainActor
final class PreviewCacheManagementTests: XCTestCase {
    func testQueuedPreparationStopsWhenUserClearsPreviews() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("preview-preparation-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = try ThumbnailCache(root: root.appendingPathComponent("thumbs"))
        let provider = ThumbnailProvider(cache: cache)
        let asset = Asset(id: "photo", sourceRootId: "root", relPath: "photo.dng", filename: "photo.dng",
                          ext: "dng", kind: .raw, size: 1, mtime: 0, contentHash: "photo", width: 100, height: 80)
        let task = BackgroundTask("Prepare")
        var finished = false
        let preparation = PreviewPreparation(task: task, provider: provider,
                                             entries: [(asset, root.appendingPathComponent("photo.dng"))]) { finished = true }
        try PreviewCacheStorage.clear(in: root)
        preparation.start()
        XCTAssertTrue(finished)
        XCTAssertEqual(task.state, .cancelled)
        XCTAssertEqual(provider.service.stats().requests, 0)
    }

    func testOfflinePhotoReusesDiskAndClearInvalidatesProviderMemory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("preview-offline-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = try ThumbnailCache(root: root.appendingPathComponent("thumbs"))
        let asset = Asset(id: "photo", sourceRootId: "root", relPath: "photo.dng", filename: "photo.dng",
                          ext: "dng", kind: .raw, size: 1, mtime: 0, contentHash: "photo", width: 100, height: 80)
        let key = ThumbKey.preview(contentHash: asset.contentHash, tier: .t256)
        let bitmap = try XCTUnwrap(CGContext(data: nil, width: 10, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        bitmap.setFillColor(CGColor(gray: 0.5, alpha: 1)); bitmap.fill(CGRect(x: 0, y: 0, width: 10, height: 8))
        try cache.store(image: XCTUnwrap(bitmap.makeImage()), for: key)
        let provider = ThumbnailProvider(cache: cache)
        let delivered = expectation(description: "offline preview")
        _ = provider.request(index: 0, asset: asset, fileURL: nil, tier: .t256) { _, _, image in
            XCTAssertNotNil(image); delivered.fulfill()
        }
        wait(for: [delivered], timeout: 5)
        XCTAssertEqual(provider.service.stats().missGenerated, 0)
        XCTAssertNotNil(provider.memoryImage(for: key))
        try PreviewCacheStorage.clear(in: root)
        XCTAssertNil(provider.memoryImage(for: key))
        XCTAssertNil(provider.placeholderImage(contentHash: asset.contentHash))
    }

    func testSettingsAndSliderRenderInRealHostingViews() throws {
        let settings = NSHostingView(rootView: PreviewCacheSettingsView().padding(24).frame(width: 510, height: 450, alignment: .topLeading).background(Color(nsColor: StudioTheme.raised)))
        let sliders = NSHostingView(rootView: VStack(spacing: 16) {
            ForEach(SliderShape.allCases, id: \.self) { shape in
                InspectorView.shapeSlider(.constant(50), in: 0...100, shape: shape, onEditingChanged: { _ in })
            }
        }.padding(24).frame(width: 320, height: 150).background(Color(nsColor: StudioTheme.raised)))
        for (view, name, size) in [(settings as NSView, "cache-settings", NSSize(width: 510, height: 450)),
                                   (sliders as NSView, "adjustment-sliders", NSSize(width: 320, height: 150))] {
            view.frame = NSRect(origin: .zero, size: size)
            let window = TestWindows.make(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = view
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
            view.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            XCTAssertGreaterThan(rep.pixelsWide, 0)
            if ProcessInfo.processInfo.environment["PHOTONS_UI_POLISH_SNAPSHOTS"] == "1" {
                try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/photons-\(name).png"))
            }
            window.close()
        }
    }
}
