import XCTest
import AppKit
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 169 §2b — 「在裁切界面点击其他图片切换时，裁切框也不会出现，只有切换到调整后再切回裁切才出现」.
///
/// Staying in 裁切 (no tab switch), clicking the next photo must arm a fresh frame for **that**
/// photo in the same turn: visible overlay, non-empty frame, on the canvas, measuring the new
/// photo's own source frame. Three switches in a row, all three the same.
@MainActor
final class CropPhotoSwitchKeepsTheFrameTests: XCTestCase {

    private var workDir: URL!

    private struct Library {
        let package: URL
        let catalog: Catalog
        /// `(id, stored width, stored height, filename)` — three different shapes, so a tool that
        /// kept the previous photo's context cannot pass by accident.
        let assets: [(id: String, width: Int, height: Int, name: String)]
    }

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-crop-photo-switch-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    private func makeLibrary() throws -> Library {
        _ = NSApplication.shared
        let folder = workDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let package = folder.appendingPathComponent("Spec.\(LibraryLayout.packageExtension)")
        let catalog = try Catalog.create(at: package)
        let src = folder.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let root = try catalog.ensureRoot(for: src, mode: .reference)

        let rows = [("L1030433.dng", 3000, 2000),
                    ("L1030434.dng", 2000, 3000),
                    ("L1030435.dng", 2400, 1600)]
        var assets: [(id: String, width: Int, height: Int, name: String)] = []
        for (name, width, height) in rows {
            try Data([0x00]).write(to: src.appendingPathComponent(name))
            let id = UUID().uuidString
            try catalog.dbQueue.write { db in
                try db.execute(sql: """
                    INSERT INTO assets (id, source_root_id, rel_path, filename, ext, kind, size, mtime,
                                        content_hash, width, height, camera_make, camera_model, lens,
                                        imported_at, missing)
                    VALUES ('\(id)', '\(root.id)', '\(name)', '\(name)', 'dng', 'raw', 1, 0,
                            '\(UUID().uuidString)', \(width), \(height),
                            'Leica Camera AG', 'Leica SL3', 'Vario-Elmarit-SL 24-90',
                            '2026-10-27T00:00:00Z', 0)
                    """)
            }
            assets.append((id, width, height, name))
        }
        return Library(package: package, catalog: catalog, assets: assets)
    }

    private func makeLoupe(_ library: Library) throws -> (LoupeController, CatalogSession, NSWindow) {
        let session = CatalogSession()
        try session.open(library.package)
        session.selectOnly(library.assets[0].id)
        session.mode = .loupe
        session.loadEditForAnchor()

        let loupe = LoupeController(session: session)
        loupe.autoRenderEnabled = false
        loupe.collectsHistogram = false
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 1100, height: 760),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = loupe.view
        window.orderFront(nil)
        loupe.view.layoutSubtreeIfNeeded()
        CropUITestSupport.pump(0.05)

        let deadline = Date().addingTimeInterval(2)
        while session.anchorAsset == nil, Date() < deadline { CropUITestSupport.pump(0.01) }
        return (loupe, session, window)
    }

    private func canvasRect(_ loupe: LoupeController) -> CGRect {
        let viewport = loupe.viewportPixels
        let scale = loupe.backingScale
        return CGRect(x: 0, y: 0,
                      width: Double(viewport.width) / scale,
                      height: Double(viewport.height) / scale)
    }

    private func bounds(_ corners: [CGPoint]) -> CGRect {
        let xs = corners.map(\.x), ys = corners.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return .zero }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    func testSwitchingPhotosInsideCropModeArmsTheNewFrame() throws {
        let library = try makeLibrary()
        let (loupe, session, window) = try makeLoupe(library)
        defer { window.orderOut(nil) }

        // Stay in 裁切: the workspace opens the tool once, and no tab switch happens below.
        XCTAssertTrue(loupe.setCropWorkspaceActive(true), "the 裁切 workspace did not open the tool")
        CropUITestSupport.pump(0.05)
        XCTAssertTrue(loupe.isCropToolActive)

        var expectedAspect: Double?
        for (index, asset) in library.assets.enumerated() {
            if index > 0 {
                session.selectOnly(asset.id)
                CropUITestSupport.pump(0.08)
            }
            let step = "photo \(index + 1) \(asset.name)"

            // The context is the **new** photo, not the previous one.
            XCTAssertEqual(loupe.cropSourceSize, ImageSize(width: asset.width, height: asset.height),
                           "\(step): the tool is still measuring the previous photo")

            XCTAssertTrue(loupe.isCropToolActive,
                          "\(step): switching photos closed 裁切 mode")
            XCTAssertTrue(loupe.isCropOverlayOnScreenForTesting,
                          "\(step): the crop overlay stayed hidden after the switch")

            let layout = try XCTUnwrap(loupe.cropOverlayLayoutForTesting,
                                       "\(step): the overlay is drawing nothing")
            XCTAssertEqual(layout.corners.count, 4, "\(step): the frame is not a quad")
            let frame = bounds(layout.corners)
            let canvas = canvasRect(loupe)
            print(String(format: "169 photo-switch · %@ · frame %@ · canvas %@ · source %dx%d",
                         step, NSStringFromRect(frame), NSStringFromRect(canvas),
                         loupe.cropSourceSize.width, loupe.cropSourceSize.height))
            XCTAssertGreaterThan(frame.width, 1, "\(step): the frame has no width")
            XCTAssertGreaterThan(frame.height, 1, "\(step): the frame has no height")
            XCTAssertTrue(CropCanvasClamp.contains(frame, in: canvas, tolerance: 0.5),
                          "\(step): the frame is not on the canvas — \(frame) vs \(canvas)")

            let aspect = frame.width / frame.height
            XCTAssertEqual(aspect, Double(asset.width) / Double(asset.height), accuracy: 1e-6,
                           "\(step): the frame does not describe this photo's own aspect")
            if let expectedAspect {
                // Each photo has a different shape, so the aspect must have moved with it.
                XCTAssertNotEqual(aspect, expectedAspect, accuracy: 1e-9,
                                  "\(step): the frame kept the previous photo's aspect")
            }
            expectedAspect = aspect
        }
    }
}
