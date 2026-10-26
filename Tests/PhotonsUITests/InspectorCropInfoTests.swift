import XCTest
import AppKit
import SwiftUI
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 派单 049 — 裁切后信息栏的 「像素数量 / 尺寸」 = **画布**的大小.
///
/// The user, 2026-10-27:「裁剪后右上角信息栏中的像素大小也要改，这个视为画布的大小」. So the two value
/// cells of the first row come from the crop's output grid —
/// `CropMath.outputSize(geometry.renderCrop(source:), in: source)`, the same call the export and the
/// histogram make — while a photo with no crop prints, character for character, what it printed
/// before this task.
///
/// Five claims, each with a measured number:
///   1. no crop → `60 MP / 9520×6336`, from the asset's own row (unchanged by 049);
///   2. half crop → `15 MP / 4760×3168`, the number `CropMath` returns (not a hand-computed one);
///   3. a transposed (EXIF 5…8) frame → the axes swap, the megapixels do not;
///   4. `crop = (0, 0, 1, 1)` and `crop = nil` → the same three values;
///   5. ⌘Z (and the crop tool's live draft) → the row follows, and comes back.
final class InspectorCropInfoTests: XCTestCase {

    private let inspectorWidth: CGFloat = 330
    /// The Leica SL3 file the user pinned: `L1030433.dng`, 60.3 Mpx.
    private let storedWidth = 9520
    private let storedHeight = 6336

    /// The middle half of the frame — the crop every number below is about.
    private let halfCrop = NormalizedRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
    private var fullCrop: NormalizedRect { NormalizedRect(x: 0, y: 0, width: 1, height: 1) }
    private var stored: ImageSize { ImageSize(width: storedWidth, height: storedHeight) }
    /// The upright frame of a file whose EXIF orientation is 6: the stored row is landscape, the
    /// ingested frame is portrait, which is what a rotated photo's canvas is.
    private var rotated: ImageSize { ImageSize(width: storedHeight, height: storedWidth) }

    // MARK: 1 — no crop is byte-identical

    /// 049 rule 2. `9520 × 6336 = 60.3 Mpx` → `60 MP`, and the row keeps the catalog's own
    /// dimensions. The three values the panel prints are the three it printed before the change.
    @MainActor
    func testNoCropPrintsTheAssetSizeByteForByte() throws {
        let (session, asset) = try makeSession(width: storedWidth, height: storedHeight)
        let panel = try host(session)
        defer { panel.window.contentView = nil }

        XCTAssertEqual(panel.probes[InspectorPhotoInfo.SpecColumn.pixelCount.rawValue]?.text, "60 MP")
        XCTAssertEqual(panel.probes[InspectorPhotoInfo.SpecColumn.pixelDimensions.rawValue]?.text, "9520×6336")
        // Same as the pre-049 formatting of the asset's own row — literally the same call.
        XCTAssertEqual(panel.probes[InspectorPhotoInfo.SpecColumn.pixelCount.rawValue]?.text,
                       InspectorPhotoInfo.pixelCount(width: asset.width, height: asset.height))
        XCTAssertEqual(panel.probes[InspectorPhotoInfo.SpecColumn.pixelDimensions.rawValue]?.text,
                       InspectorPhotoInfo.pixelDimensions(width: asset.width, height: asset.height))

        let metrics = InspectorPhotoInfo.metrics(storedWidth: asset.width, storedHeight: asset.height,
                                                  geometry: .identity)
        XCTAssertFalse(metrics.isCroppedCanvas, "a document with no crop is not a cropped canvas")
        XCTAssertEqual(metrics.canvas, stored)
        print("049 no-crop: \(metrics.pixelCount) / \(metrics.pixelDimensions) · canvas \(metrics.canvas!)")
    }

    // MARK: 4 — a whole-frame crop is the no-crop row

    /// 049 rule 4, and the reason 「有没有裁切」 cannot be `crop != nil`: `(0, 0, 1, 1)` is a crop rect
    /// by every type in the codebase yet an identity by geometry. All three values must match the
    /// `nil` row exactly, or a file saved with a whole-frame crop would drift by a rounding pixel
    /// the day it is opened.
    func testFullCanvasCropIsTheNoCropRow() {
        let plain = InspectorPhotoInfo.metrics(storedWidth: storedWidth, storedHeight: storedHeight,
                                               geometry: GeometryGroup(crop: .full))
        let wholeRect = InspectorPhotoInfo.metrics(storedWidth: storedWidth, storedHeight: storedHeight,
                                                   geometry: GeometryGroup(crop: fullCrop))
        let noDocument = InspectorPhotoInfo.metrics(storedWidth: storedWidth, storedHeight: storedHeight,
                                                    geometry: nil)

        XCTAssertEqual(wholeRect, plain, "(0,0,1,1) must be the same three values as .full")
        XCTAssertEqual(noDocument, plain, "no document must print the asset's own row")
        XCTAssertEqual(plain.pixelCount, "60 MP")
        XCTAssertEqual(plain.pixelDimensions, "9520×6336")
        XCTAssertFalse(plain.isCroppedCanvas)

        // The same with a flip or a straighten: neither moves the output grid (S0 keeps the crop as
        // the frame), so the row must not move either.
        for geometry in [GeometryGroup(crop: .full, rotationDegrees: 12),
                         GeometryGroup(crop: .full, flipHorizontal: true, flipVertical: true)] {
            XCTAssertEqual(InspectorPhotoInfo.metrics(storedWidth: storedWidth, storedHeight: storedHeight,
                                                      geometry: geometry),
                           plain, "\(geometry) does not change the grid")
        }
        print("049 full-canvas == no-crop: \(plain.pixelCount) / \(plain.pixelDimensions) "
              + "(rect \(wholeRect.canvas!), full \(plain.canvas!))")
    }

    // MARK: 2 + 5 — the crop, the refresh and ⌘Z

    /// 049 rules 1 and 3. The panel is hosted **once**: the crop is applied to the document under it,
    /// so the assertions after each step prove the row refreshed from the session rather than from a
    /// snapshot taken at `makeNSView` time. The expected pixels are `CropMath.outputSize` on the same
    /// geometry the document carries — measured, not hand-computed.
    @MainActor
    func testCropPrintsTheCropOutputAndUndoRestoresTheAssetSize() throws {
        let (session, asset) = try makeSession(width: storedWidth, height: storedHeight)
        let panel = try host(session)
        defer { panel.window.contentView = nil }

        func count() -> String? { panel.text(.pixelCount) }
        func dims() -> String? { panel.text(.pixelDimensions) }

        XCTAssertEqual(count(), "60 MP")
        XCTAssertEqual(dims(), "9520×6336")

        session.applyEdit { $0.geometry.crop = self.halfCrop }
        pump(panel.window)
        let expected = CropMath.outputSize(session.edit.geometry.renderCrop(source: stored), in: stored)
        XCTAssertEqual(expected, ImageSize(width: 4760, height: 3168),
                       "the fixture's half crop is \(expected.width)×\(expected.height)")
        XCTAssertEqual(dims(), InspectorPhotoInfo.pixelDimensions(width: expected.width, height: expected.height))
        XCTAssertEqual(count(), InspectorPhotoInfo.pixelCount(width: expected.width, height: expected.height))
        XCTAssertEqual(dims(), "4760×3168")
        XCTAssertEqual(count(), "15 MP")
        // Same grid the histogram and the export would use for this document.
        XCTAssertEqual(InspectorPhotoInfo.metrics(storedWidth: asset.width, storedHeight: asset.height,
                                                  geometry: session.edit.geometry, source: stored).canvas,
                       expected)

        // ⌘Z: the snapshot below is the uncropped document, so the row goes back to the asset's size.
        session.commitEdit(label: "裁切与旋转")
        XCTAssertTrue(session.canUndo)
        XCTAssertTrue(session.undo())
        pump(panel.window)
        XCTAssertTrue(session.edit.geometry.crop == .full, "undo put the whole frame back")
        XCTAssertEqual(count(), "60 MP")
        XCTAssertEqual(dims(), "9520×6336")
        print("049 crop: \(expected.width)×\(expected.height) → \(count() ?? "-") / \(dims() ?? "-") · "
              + "after ⌘Z \(count() ?? "-") / \(dims() ?? "-") (CropMath: \(expected))")
    }

    // MARK: 3 — a rotated frame swaps the axes

    /// 049 rule 5. A portrait file's stored row is landscape and the renderer ingests the transposed
    /// frame; the crop is measured on **that** frame, so the same half crop prints `3168×4760` while
    /// the megapixels stay put. Verified against `CropMath` on the same transposed source.
    @MainActor
    func testRotatedFrameSwapsTheAxesAndKeepsTheMegapixels() throws {
        let (session, asset) = try makeSession(width: storedWidth, height: storedHeight)
        session.ingestedSourceFrame = (asset.id, rotated)
        session.applyEdit { $0.geometry.crop = self.halfCrop }
        let panel = try host(session)
        defer { panel.window.contentView = nil }

        let expected = CropMath.outputSize(session.edit.geometry.renderCrop(source: rotated), in: rotated)
        XCTAssertEqual(expected, ImageSize(width: 3168, height: 4760))
        XCTAssertEqual(panel.probes[InspectorPhotoInfo.SpecColumn.pixelDimensions.rawValue]?.text,
                       InspectorPhotoInfo.pixelDimensions(width: expected.width, height: expected.height))
        XCTAssertEqual(panel.probes[InspectorPhotoInfo.SpecColumn.pixelDimensions.rawValue]?.text, "3168×4760")
        XCTAssertEqual(panel.probes[InspectorPhotoInfo.SpecColumn.pixelCount.rawValue]?.text, "15 MP")

        // The landscape reading of the same crop is the transposed string, and the MP count is the
        // same number either way — that is what 「W×H 换序、MP 不变」 means.
        let landscape = CropMath.outputSize(session.edit.geometry.renderCrop(source: stored), in: stored)
        XCTAssertEqual(ImageSize(width: landscape.height, height: landscape.width), expected,
                       "the rotated grid is the landscape grid with the axes exchanged")
        XCTAssertEqual(InspectorPhotoInfo.pixelCount(width: landscape.width, height: landscape.height),
                       InspectorPhotoInfo.pixelCount(width: expected.width, height: expected.height))
        print("049 rotated: stored \(stored.width)×\(stored.height) · upright \(rotated.width)×\(rotated.height) · "
              + "half crop → \(expected.width)×\(expected.height) / \(panel.probes[InspectorPhotoInfo.SpecColumn.pixelCount.rawValue]?.text ?? "-")"
              + " (landscape reading \(landscape.width)×\(landscape.height))")
    }

    // MARK: 3 — the drag: the live draft, with no document write

    /// 049 rule 3 at the *drag*: 裁切 mode edits a draft and writes the document only at 应用, so the
    /// row follows `session.cropToolDraft` — the one value `CropToolController` publishes per draft
    /// change. Setting it here is exactly what a drag tick does (one property write, no `applyEdit`,
    /// no history). Clearing it is what 取消 / 离开 does, and the row must fall back to the document.
    @MainActor
    func testTheRowFollowsTheLiveCropDraftAndFallsBack() throws {
        let (session, asset) = try makeSession(width: storedWidth, height: storedHeight)
        let panel = try host(session)
        defer { panel.window.contentView = nil }

        func count() -> String? { panel.text(.pixelCount) }
        func dims() -> String? { panel.text(.pixelDimensions) }

        XCTAssertEqual(count(), "60 MP")
        session.cropToolDraft = (asset.id, GeometryGroup(crop: halfCrop))
        pump(panel.window)
        XCTAssertEqual(dims(), "4760×3168", "the row did not follow the draft")
        XCTAssertEqual(count(), "15 MP")
        XCTAssertTrue(session.edit.geometry.crop == .full, "a draft tick must not write the document")

        // 取消 / 应用 / 离开: the tool clears it, the document is what the row reads again.
        session.cropToolDraft = nil
        pump(panel.window)
        XCTAssertEqual(dims(), "9520×6336")
        XCTAssertEqual(count(), "60 MP")

        // A draft published for another photo must not be borrowed by this row.
        session.cropToolDraft = ("some-other-asset", GeometryGroup(crop: halfCrop))
        pump(panel.window)
        XCTAssertEqual(count(), "60 MP")
        session.cropToolDraft = nil
        print("049 live draft: 15 MP / 4760×3168 while the tool is on, 60 MP / 9520×6336 after it closes")
    }

    // MARK: 6 — 反证: the row must read the document

    /// The anti-proof, as a test rather than as a promise: **if the megapixels were the asset's own**
    /// (`InspectorPhotoInfo.pixelCount(width: asset.width, height: asset.height)`, i.e. the pre-049
    /// code), every assertion below is red — `60 MP` where the canvas is `15 MP`, and a
    /// `isCroppedCanvas` that never becomes true.
    func testTheAntiProofMegapixelsCannotIgnoreTheGeometry() {
        let cropped = InspectorPhotoInfo.metrics(storedWidth: storedWidth, storedHeight: storedHeight,
                                                 geometry: GeometryGroup(crop: halfCrop), source: stored)
        let plain = InspectorPhotoInfo.metrics(storedWidth: storedWidth, storedHeight: storedHeight,
                                               geometry: GeometryGroup(crop: .full), source: stored)
        let assetOnly = InspectorPhotoInfo.pixelCount(width: storedWidth, height: storedHeight)

        XCTAssertEqual(assetOnly, "60 MP")
        XCTAssertEqual(plain.pixelCount, assetOnly, "no crop → the asset's own number")
        XCTAssertNotEqual(cropped.pixelCount, assetOnly,
                          "a half crop cannot still be \(assetOnly) — that is the bug this task fixes")
        XCTAssertEqual(cropped.pixelCount, "15 MP")
        XCTAssertNotEqual(cropped.pixelDimensions, plain.pixelDimensions)
        XCTAssertTrue(cropped.isCroppedCanvas)
        XCTAssertEqual(cropped.canvas, ImageSize(width: 4760, height: 3168))
        print("049 anti-proof: asset-only \(assetOnly) vs crop \(cropped.pixelCount) / \(cropped.pixelDimensions)")
    }

    /// A crop too small to be a megapixel still prints as a number, in the existing format.
    func testASmallCropKeepsTheFormat() {
        // 1/10 of each edge of the 60 Mpx frame = 952×634 → 0.60 Mpx.
        let tiny = NormalizedRect(x: 0.45, y: 0.45, width: 0.1, height: 0.1)
        let metrics = InspectorPhotoInfo.metrics(storedWidth: storedWidth, storedHeight: storedHeight,
                                                 geometry: GeometryGroup(crop: tiny), source: stored)
        let pixels = CropMath.outputSize(GeometryGroup(crop: tiny).renderCrop(source: stored), in: stored)
        XCTAssertEqual(metrics.pixelDimensions, "\(pixels.width)×\(pixels.height)")
        XCTAssertEqual(metrics.pixelCount, "0.6 MP")
        XCTAssertTrue(metrics.pixelCount.hasSuffix(" MP"))
        XCTAssertFalse(metrics.pixelDimensions.contains(" "))
    }

    // MARK: fixture library

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-inspector-crop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    /// One real library with one photo in it — the same shape `InspectorMetadataTests` uses, so the
    /// row reads a *database's* filename and dimensions instead of a constant handed to the view.
    @MainActor
    private func makeSession(width: Int?, height: Int?) throws -> (CatalogSession, Asset) {
        _ = NSApplication.shared
        let folder = workDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let package = folder.appendingPathComponent("Spec.\(LibraryLayout.packageExtension)")
        let catalog = try Catalog.create(at: package)
        let src = folder.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let root = try catalog.ensureRoot(for: src, mode: .reference)

        let name = "L1030433.dng"
        try Data([0x00]).write(to: src.appendingPathComponent(name))

        let id = UUID().uuidString
        try catalog.dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO assets (id, source_root_id, rel_path, filename, ext, kind, size, mtime,
                                    content_hash, width, height, camera_make, camera_model, lens,
                                    imported_at, missing)
                VALUES ('\(id)', '\(root.id)', '\(name)', '\(name)', 'dng', 'raw', 1, 0,
                        '\(UUID().uuidString)',
                        \(width.map(String.init) ?? "NULL"), \(height.map(String.init) ?? "NULL"),
                        'Leica Camera AG', 'Leica SL3', 'Vario-Elmarit-SL 24-90',
                        '2026-10-27T00:00:00Z', 0)
                """)
        }

        let session = CatalogSession()
        try session.open(package)
        session.selectOnly(id)
        return (session, try XCTUnwrap(try catalog.asset(id: id)))
    }

    /// One published cell: its text, and the frame SwiftUI gave it.
    private struct Cell {
        let text: String
        let frame: NSRect
    }

    private struct SpecPanel {
        let window: NSWindow
        let host: NSView
        let probes: [String: Cell]

        /// The cells as they are **now** — the probe NSViews are looked up again after every pump, so
        /// a rebuilt row cannot leave a stale string in the test's own dictionary.
        @MainActor
        func text(_ column: InspectorPhotoInfo.SpecColumn) -> String? {
            InspectorCropInfoTests.specProbes(in: host).first { $0.id == column.rawValue }?.text
        }
    }

    @MainActor
    private func host(_ session: CatalogSession) throws -> SpecPanel {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: InspectorView(session: session))
        host.frame = NSRect(x: 0, y: 0, width: inspectorWidth, height: 800)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = host
        pump(window)

        var probes: [String: Cell] = [:]
        for probe in Self.specProbes(in: host) {
            probes[probe.id] = Cell(text: probe.text, frame: probe.convert(probe.bounds, to: host))
        }
        return SpecPanel(window: window, host: host, probes: probes)
    }

    /// Let SwiftUI run the invalidation it was handed and lay the panel out again. Not a frame-rate
    /// wait: every assertion after it is about a *value*, and the row is one `Text` per cell.
    @MainActor
    private func pump(_ window: NSWindow) {
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    @MainActor
    private static func specProbes(in view: NSView) -> [InspectorSpecRowProbe] {
        var found: [InspectorSpecRowProbe] = []
        if let probe = view as? InspectorSpecRowProbe { found.append(probe) }
        for sub in view.subviews { found += specProbes(in: sub) }
        return found
    }
}
