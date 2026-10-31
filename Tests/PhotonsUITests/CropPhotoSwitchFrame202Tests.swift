import XCTest
import AppKit
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 202 ④ — **switching photos inside 裁切 must never lay out a frame that is not the new photo's.**
///
/// The report: 「裁剪模式下切换照片，裁剪框先占据部分画面（刚好是 1/4 面积的左上角）然后再恢复到全画面」.
/// That shape is a rect belonging to the **previous** photo projected through the **new** photo's
/// framing: the anchor and `cropSourceSize` move several turns before the observation that re-seeds
/// the draft runs, so the turns in between draw A's rect as a small patch of B's canvas.
///
/// This probe reads the overlay's own layout log (`cropOverlayLayoutFrames` — one entry per frame the
/// overlay is handed, tagged with the photo the draft belonged to), so 「逐帧」 means frames, not wall
/// clock. It switches three times (an already-cropped photo, an uncropped landscape, an uncropped
/// portrait) and prints every frame.
@MainActor
final class CropPhotoSwitchFrame202Tests: XCTestCase {

    private var workDir: URL!

    private struct Library {
        let package: URL
        let assets: [(id: String, width: Int, height: Int, name: String)]
    }

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-crop-202d-\(UUID().uuidString)", isDirectory: true)
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
        return Library(package: package, assets: assets)
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

    func testSwitchingPhotosNeverLaysOutAQuarterFrame() throws {
        let library = try makeLibrary()
        let (loupe, session, window) = try makeLoupe(library)
        defer { window.orderOut(nil) }
        let viewport = loupe.viewportPixels
        let canvas = CGRect(x: 0, y: 0, width: Double(viewport.width),
                            height: Double(viewport.height))

        // The second photo is **already cropped** — its first frame must show that rect.
        let croppedB = CropRect(left: 0.10, top: 0.12, right: 0.55, bottom: 0.62)
        session.selectOnly(library.assets[1].id)
        session.loadEditForAnchor()
        session.applyEdit { $0.geometry.crop = croppedB.normalizedRect }
        session.commitEdit(label: "probe crop", coalesce: false)
        session.selectOnly(library.assets[0].id)
        CropUITestSupport.pump(0.05)

        // ④a — **the stale resident buffer must not describe the new photo.** A real frame of photo 1
        // leaves `decoded` holding A's pixel grid; between the switch and B's first frame the
        // projection used to be built from it, so B's rect was projected through A's 3000 × 2000 grid
        // onto a 2200 × 1520 canvas — a small patch in the corner. `framing()` now ignores a buffer
        // that belongs to another photo.
        let srcFolder = library.package.deletingLastPathComponent()
            .appendingPathComponent("src", isDirectory: true)
        let rawA = srcFolder.appendingPathComponent(library.assets[0].name)
        session.selectOnly(library.assets[0].id)
        CropUITestSupport.pump(0.05)
        _ = try? loupe.makeFrame(url: rawA, viewport: loupe.viewportPixels, decodeScale: 0.5,
                                 edit: session.edit, state: .fit)
        session.selectOnly(library.assets[1].id)
        CropUITestSupport.pump(0.05)
        let projected = try XCTUnwrap(loupe.framing())
        print(String(format: "202 ④ · after switching 3000×2000 → 2000×3000 the projection is %.0f×%.0f",
                     projected.sourceWidth, projected.sourceHeight))
        XCTAssertEqual(projected.sourceWidth, 2000, accuracy: 1,
                       "the projection still describes the previous photo's buffer")
        XCTAssertEqual(projected.sourceHeight, 3000, accuracy: 1,
                       "the projection still describes the previous photo's buffer")
        session.selectOnly(library.assets[0].id)
        CropUITestSupport.pump(0.05)

        XCTAssertTrue(loupe.setCropWorkspaceActive(true))
        CropUITestSupport.pump(0.08)
        XCTAssertTrue(loupe.isCropToolActive)

        var sequences: [(id: String, size: ImageSize, frames: [LoupeController.CropOverlayLayoutFrame])] = []
        for asset in [library.assets[1], library.assets[2], library.assets[0]] {
            let start = loupe.cropOverlayLayoutFrames.count
            session.selectOnly(asset.id)
            for _ in 0..<8 { CropUITestSupport.pump(0.004) }
            CropUITestSupport.pump(0.08)
            let frames = Array(loupe.cropOverlayLayoutFrames.dropFirst(start))
            sequences.append((asset.id, ImageSize(width: asset.width, height: asset.height), frames))
            print("202 ④ ·—— switching to \(asset.name) · \(frames.count) frames")
            for (i, f) in frames.enumerated() {
                let corners = f.corners.map {
                    String(format: "(%.3f, %.3f, %.3f, %.3f)",
                           $0.minX / canvas.width, $0.minY / canvas.height,
                           $0.width / canvas.width, $0.height / canvas.height)
                } ?? "nil"
                print("202 ④ · frame \(i) · photo \(f.photoID.map { String($0.prefix(4)) } ?? "nil") · "
                      + String(format: "draft l %.3f t %.3f r %.3f b %.3f · corners/canvas %@",
                               f.crop.left, f.crop.top, f.crop.right, f.crop.bottom, corners))
            }
        }

        // The frame the overlay draws is a rect of the *picture on the canvas*; in pixels its shape is
        // the crop's own shape, whoever drew it. A rect belonging to another photo, or a default
        // 0.5 × 0.5 square, cannot have it.
        let scale = loupe.backingScale
        for (index, entry) in sequences.enumerated() {
            let frames = entry.frames
            XCTAssertFalse(frames.isEmpty, "switch \(index + 1): the overlay was never laid out")
            let expected: CropRect = index == 0 ? croppedB : .full
            let source = CGSize(width: Double(entry.size.width), height: Double(entry.size.height))
            let expectedAspect = (expected.width * source.width) / (expected.height * source.height)
            for (i, f) in frames.enumerated() {
                XCTAssertEqual(f.photoID, entry.id,
                               "switch \(index + 1) frame \(i): laid out the previous photo's draft")
                guard let r = f.corners else { continue }
                let px = CGRect(x: r.minX * scale, y: r.minY * scale,
                                width: r.width * scale, height: r.height * scale)
                let quarter = CGRect(x: 0, y: 0, width: canvas.width / 2, height: canvas.height / 2)
                XCTAssertFalse(abs(px.minX - quarter.minX) < 2 && abs(px.minY - quarter.minY) < 2
                               && abs(px.width - quarter.width) < 2
                               && abs(px.height - quarter.height) < 2,
                               "switch \(index + 1) frame \(i): the default quarter frame was drawn")
                XCTAssertEqual(px.width / px.height, expectedAspect, accuracy: expectedAspect * 0.01,
                               "switch \(index + 1) frame \(i): the frame's shape is not the photo's "
                               + "crop — \(px)")
            }
        }
    }
}
