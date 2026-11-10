import XCTest
import AppKit
import CoreGraphics
import ImageIO
import Metal
import QuartzCore
import PhotonsCatalog
@testable import PhotonsCore
@testable import PhotonsUI

/// **364 — the stand-in and the frame are drawn on one grid: document-canvas pixels.**
///
/// 344b made the low-res whole-picture backdrop the canvas' own render and fixed the *region*
/// (`canvasOriginPixels` → 0.00 / 0.00), but the stand-in was still installed on a rectangle derived
/// from the crop's **photo** pixels: the photograph's size at the canvas' origin — a second spelling
/// of a place the canvas already names. Measured at `(+40, −25) + 9°` it was 303.67 / 299.21 px off
/// at 1× and 1214.69 / 1196.85 px at 4×, i.e. exactly 4× the same translation (a constant
/// source-space offset, not a scale error) — the report's 「换个方向切图时首帧排布不对」.
///
/// The convention, spelled once in `CropGeometry.documentPointInCanvas`: **canvas pixels, origin at
/// the canvas' top-left corner**, which for a keystoned document is the AABB of the warped picture.
/// `documentOrigin` is folded in there, once; the camera (`FrameTransform.s1ToS3` / `s3ToS5`), the
/// crop frame, the guide lines and the stand-in's rectangle all read it and none of them adds or
/// subtracts the origin again.
///
/// Four claims, each with its own number:
///
///   ① **the markers land on the canvas projection.** Two source markers at 1× and 4× under
///      `(+40, −25) + 9°` sit within 0.5 px of where the camera puts the same canvas point.
///   ② **they do not drift with the keystone.** The same measurement over the four keystones the
///      acceptance names, at 0° and 9°.
///   ③ **the guide lines agree with the crop frame** (354's own trap, re-measured here because it is
///      the same walk): an endpoint at a crop-frame corner and the corner `CropTool.layout` draws are
///      the same screen point.
///   ④ **two reverse gates**, so ① and ② are measurements and not tautologies.
@MainActor
final class StandInOrigin364Tests: XCTestCase {

    /// The viewport the loupe's projection is built for, and the two markers the acceptance names.
    private static let viewport = ImageSize(width: 640, height: 400)
    private static let markers: [(x: Double, y: Double)] = [(450, 300), (1350, 900)]
    private static let keystones: [(name: String, v: Double, h: Double)] = [
        ("(0,0)", 0, 0), ("(+40,0)", 40, 0), ("(0,−40)", 0, -40), ("(+40,−25)", 40, -25),
    ]
    private static let angles: [Double] = [0, 9]

    private var workDir: URL!
    private var windows: [NSWindow] = []
    private var editors = 0

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-364-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        DocumentCanvasConvention364.foldsDocumentOriginIntoCanvas = true
        DocumentCanvasConvention364.standInRectUsesPhotoPixels = false
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
        workDir = nil
    }

    // MARK: - fixtures and plumbing

    private func rawFixture() throws -> URL {
        let candidates = [
            ProcessInfo.processInfo.environment["PHOTONS_TEST_RAW"],
            NSString(string: "~/Desktop/test/L1030433.dng").expandingTildeInPath,
        ].compactMap { $0 }
        for c in candidates where FileManager.default.isReadableFile(atPath: c) {
            return URL(fileURLWithPath: c)
        }
        throw XCTSkip("no RAW fixture; set PHOTONS_TEST_RAW")
    }

    private func pump(_ seconds: TimeInterval = 0.005) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func makeEditor(files: [URL]) throws -> (EditorWindowController, [Asset]) {
        _ = NSApplication.shared
        editors += 1
        let package = workDir.appendingPathComponent("StandIn364-\(editors).\(LibraryLayout.packageExtension)")
        let catalog = try Catalog.create(at: package)
        let source = workDir.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let root = try catalog.ensureRoot(for: source, mode: .reference)
        var ids: [String] = []
        for (index, file) in files.enumerated() {
            let name = "standin\(index).dng"
            let destination = source.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: file)
            let size = try pixelSize(of: file)
            let bytes = (try FileManager.default.attributesOfItem(atPath: file.path)[.size]
                as? NSNumber)?.intValue ?? 1
            let id = UUID().uuidString
            ids.append(id)
            try catalog.dbQueue.write { db in
                try db.execute(sql: """
                    INSERT INTO assets (id, source_root_id, rel_path, filename, ext, kind, size, mtime,
                                        content_hash, width, height, camera_make, camera_model, lens,
                                        imported_at, missing)
                    VALUES ('\(id)', '\(root.id)', '\(name)', '\(name)', 'dng', 'raw', \(bytes), 0,
                            '\(UUID().uuidString)',
                            \(size.width), \(size.height),
                            'Leica Camera AG', 'Leica SL3', 'Vario-Elmarit-SL 24-90',
                            '2026-11-10T00:00:00Z', 0)
                    """)
            }
        }
        let assets = try ids.map { try XCTUnwrap(try catalog.asset(id: $0)) }
        let editor = EditorWindowController(size: NSSize(width: 1200, height: 800))
        windows.append(editor.window!)
        try editor.openLibrary(at: package)
        let cache = try XCTUnwrap(editor.session.thumbnailCache, "the library has no thumbnail cache")
        for asset in assets { try seedPreview(asset, cache: cache) }
        TestWindows.show(editor.window)
        editor.window?.contentView?.layoutSubtreeIfNeeded()
        editor.rootView.needsLayout = true
        editor.rootView.layoutSubtreeIfNeeded()
        pump(0.05)
        return (editor, assets)
    }

    private func seedPreview(_ asset: Asset, cache: ThumbnailCache) throws {
        let width = 256, height = 170
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
                                              bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.72, green: 0.45, blue: 0.22, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let data = try XCTUnwrap(NSBitmapImageRep(cgImage: image)
            .representation(using: .jpeg, properties: [.compressionFactor: 0.8]))
        try cache.store(data, for: .preview(contentHash: asset.contentHash, tier: .t256))
    }

    private func pixelSize(of url: URL) throws -> ImageSize {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        return ImageSize(width: try XCTUnwrap(properties[kCGImagePropertyPixelWidth] as? Int),
                         height: try XCTUnwrap(properties[kCGImagePropertyPixelHeight] as? Int))
    }

    /// One loupe open on the fixture, with the geometry handed in. `pump` only — no renders are
    /// waited for: every number below is geometry, and the stand-in's rectangle is what the install
    /// path computes synchronously (`firstFramePlaceholderContentRect`).
    private func openLoupe(_ keystone: (v: Double, h: Double), angle: Double)
        throws -> (LoupeController, EditorWindowController) {
        let url = try rawFixture()
        let (editor, assets) = try makeEditor(files: [url])
        let loupe = editor.rootView.loupeController
        editor.session.selectOnly(assets[0].id)
        pump(0.05)
        editor.session.mode = .loupe
        editor.rootView.showModule(for: .loupe)
        editor.session.applyEdit { model in
            model.geometry.perspectiveVertical = keystone.v
            model.geometry.perspectiveHorizontal = keystone.h
            model.geometry.rotationDegrees = angle
        }
        loupe.scheduleRender()
        pump(0.2)
        return (loupe, editor)
    }

    // MARK: - the measurement

    /// The marker's place on the stand-in, in **device pixels**, versus the camera's projection of the
    /// same source marker. Both are read off the shipped objects: the rectangle is
    /// `LoupeController.firstFramePlaceholderContentRect` (what the install path uses, in points) and
    /// the projection is `LoupeMapping.viewPoint` (`s1ToS3` then `s3ToS5`). The marker's own position
    /// *inside* the rectangle is its canvas-normalized position — the stand-in's bitmap is the canvas
    /// render (344b: `(+40,−25)+9°` is a 2097 × 1570 file, i.e. the canvas' 4:3, not the 3:2 photo).
    private struct MarkerReading {
        let zoom: Double
        let marker: (x: Double, y: Double)
        let cameraX: Double, cameraY: Double
        let standInX: Double, standInY: Double
        var delta: Double { max(abs(cameraX - standInX), abs(cameraY - standInY)) }
    }

    private func readings(loupe: LoupeController, editor: EditorWindowController)
        throws -> (readings: [MarkerReading], canvasWidth: Double, canvasHeight: Double) {
        let viewport = loupe.viewportPixels
        let framing = try XCTUnwrap(loupe.framing(viewport: viewport), "no framing")
        let source = ImageSize(width: Int(framing.sourceWidth.rounded()),
                               height: Int(framing.sourceHeight.rounded()))
        let geometry = CropGeometry(geometry: editor.session.edit.geometry, source: source)
        let backing = max(1, loupe.backingScale)
        // The stand-in's bitmap is the **export canvas** (the crop frame at 1:1 — a keystoned
        // document's 2097 × 1570 file), so a marker's place *in the bitmap* is its export-canvas
        // coordinate: the document-canvas point minus the canvas inset, over the frame's own extent.
        // The extent is the continuous one (`photoQuadExtent` at a keystone, the crop's pixel size
        // otherwise): dividing by the whole-pixel canvas instead would add the renderer's own `ceil`
        // (0.46 px on 10397) × the zoom — 1.8 px at 4×, which is not a placement error.
        let inset = geometry.canvasInset(.document)
        let frameWidth = geometry.hasKeystoneQuad
            ? geometry.photoQuadExtent.width : Double(geometry.frameSize.width)
        let frameHeight = geometry.hasKeystoneQuad
            ? geometry.photoQuadExtent.height : Double(geometry.frameSize.height)
        var out: [MarkerReading] = []
        for zoom in [1.0, 4.0] {
            let state = LoupeViewState(mode: .actual, zoom: zoom,
                                       centerX: framing.sourceWidth / 2,
                                       centerY: framing.sourceHeight / 2)
            let mapping = framing.mapping(of: state)
            let rect = loupe.placeholderContentRectForTesting(state: state)  // points
            for marker in Self.markers {
                let u = marker.x / framing.sourceWidth, v = marker.y / framing.sourceHeight
                // the marker in the canvas' own grid, then read in the bitmap's own grid
                let canvasPoint = geometry.documentPointInCanvas(normalizedX: u, v)
                let cu = (canvasPoint.x - inset.x) / frameWidth
                let cv = (canvasPoint.y - inset.y) / frameHeight
                let standInX = (rect.minX + cu * rect.width) * backing
                let standInY = (rect.minY + cv * rect.height) * backing
                let camera = mapping.viewPoint(sourceX: marker.x, sourceY: marker.y)
                out.append(MarkerReading(zoom: zoom, marker: marker,
                                         cameraX: camera.x, cameraY: camera.y,
                                         standInX: standInX, standInY: standInY))
            }
        }
        return (out, Double(geometry.canvas(.document).width),
                Double(geometry.canvas(.document).height))
    }

    // MARK: - ① ② the markers

    /// ① the acceptance's geometry, with the 344b numbers printed beside it; ② the four keystones the
    /// acceptance names at 0° and 9°, so a fix that only holds the one document is red here.
    func testTheMarkersLandOnTheDocumentCanvasAtEveryKeystone() throws {
        var worst = 0.0
        var rows = 0
        var printed = 0
        for keystone in Self.keystones {
            for angle in Self.angles {
                let (loupe, editor) = try openLoupe((keystone.v, keystone.h), angle: angle)
                let measured = try readings(loupe: loupe, editor: editor)
                for reading in measured.readings {
                    rows += 1
                    worst = max(worst, reading.delta)
                    XCTAssertLessThanOrEqual(reading.delta, 0.5,
                                             "\(keystone.name) @\(angle)° \(reading.zoom)× marker "
                                             + "(\(reading.marker.x),\(reading.marker.y)): the stand-in puts "
                                             + "it \(reading.delta) px from the canvas projection")
                    // The acceptance's table: every geometry at 1×, plus the headline one at 4×.
                    let headline = keystone.v == 40 && keystone.h == -25 && angle == 9
                    if abs(reading.zoom - 1.0) < 0.001 || headline {
                        printed += 1
                        print(String(format: "364 ① %@ @%.0f° %.0f× marker (%.0f,%.0f) · camera %.2f,%.2f · stand-in %.2f,%.2f · Δ %.3f px",
                                     keystone.name, angle, reading.zoom,
                                     reading.marker.x, reading.marker.y,
                                     reading.cameraX, reading.cameraY,
                                     reading.standInX, reading.standInY, reading.delta))
                    }
                }
                for window in windows { window.orderOut(nil) }
                windows.removeAll()
                _ = loupe   // the loupe is only read above; the editor is released with the window
            }
        }
        print(String(format: "364 ① ② worst marker Δ %.3f px over %d readings (%d printed)",
                     worst, rows, printed))
        XCTAssertGreaterThan(rows, 0)
        XCTAssertLessThanOrEqual(worst, 0.5)
    }

    // MARK: - ④ the guide lines

    /// **354's own trap, re-measured through this task's entry.** The guide lines and the crop frame
    /// are drawn by two different surfaces: `GuideLineProjection.screenPoint` from a **source** pixel,
    /// `CropTool.layout` from the crop **rect's** corners. The gate is the round trip between them, and
    /// it is the honest one — the crop frame of a straightened document lives in frame space, so its
    /// corner is not the picture's corner (`CropTool`'s non-keystone branch draws exactly that, by
    /// design). So: take the corner the frame is drawn at, walk it back through the one camera and the
    /// one measurement inverse (`documentPoint` → `photoNormalized`, which puts `documentOrigin` back),
    /// and ask where the guide lines put that source pixel. ≤ 0.5 px means one map, both ways.
    func testTheGuideLinesEndOnTheCropFramesCorners() throws {
        let size = ImageSize(width: 1200, height: 1200)
        let viewport = ImageSize(width: 1200, height: 1200)
        var worst = 0.0
        for keystone in Self.keystones {
            for angle in Self.angles {
                let perspective = PerspectiveMap(vertical: keystone.v, horizontal: keystone.h)
                let framing = LoupeFraming(viewport: viewport,
                                           sourceWidth: Double(size.width),
                                           sourceHeight: Double(size.height),
                                           crop: .full, straightenDegrees: angle,
                                           flipH: false, flipV: false,
                                           perspective: perspective.hasWarp ? perspective : nil,
                                           canvasRole: .document)
                let mapping = framing.mapping(of: .fit)
                let layout = CropTool.layout(crop: .full, source: size, mapping: mapping,
                                             pointScale: 1, showsGrid: false)
                let projection = GuideLineProjection(source: size,
                                                     perspective: perspective.hasWarp ? perspective : nil,
                                                     straightenDegrees: angle, mapping: mapping)
                let geometry = CropGeometry(
                    geometry: GeometryGroup(crop: .full, rotationDegrees: angle,
                                            perspectiveVertical: perspective.vertical,
                                            perspectiveHorizontal: perspective.horizontal,
                                            cropSpace: .source),
                    source: size)
                for (index, drawn) in layout.corners.enumerated() {
                    let document = try XCTUnwrap(
                        mapping.documentPoint(viewX: Double(drawn.x), viewY: Double(drawn.y)),
                        "the frame's corner has no canvas point — §④ needs a camera")
                    let photo = geometry.photoNormalized(documentX: document.x, document.y)
                    let endpoint = projection.screenPoint(CGPoint(x: photo.x * Double(size.width),
                                                                  y: photo.y * Double(size.height)))
                    let delta = max(abs(endpoint.x - Double(drawn.x)),
                                    abs(endpoint.y - Double(drawn.y)))
                    worst = max(worst, delta)
                    XCTAssertLessThanOrEqual(delta, 0.5,
                                             "\(keystone.name) @\(angle)° corner \(index): the guide line "
                                             + "endpoint is \(delta) px from the frame's corner")
                }
            }
        }
        print(String(format: "364 ③ guide endpoint vs crop-frame corner · worst %.3f px", worst))
    }

    // MARK: - ④ reverse gates

    /// **Gate ① — the convention.** `documentPointInCanvas` stops folding `documentOrigin` in, which is
    /// the pre-364 spelling: it then answers photo pixels while the camera answers canvas pixels. The
    /// marker must move by an origin-sized distance, and the number is printed rather than asserted
    /// loosely — the same 0.5 px gate feeding a real disagreement.
    func testGateOneTheCanvasStillNeedsTheDocumentOrigin() throws {
        let (loupe, editor) = try openLoupe((40, -25), angle: 9)
        let shipped = try readings(loupe: loupe, editor: editor)
        DocumentCanvasConvention364.foldsDocumentOriginIntoCanvas = false
        defer { DocumentCanvasConvention364.foldsDocumentOriginIntoCanvas = true }
        let broken = try readings(loupe: loupe, editor: editor)
        for (index, reading) in broken.readings.enumerated() where abs(reading.zoom - 1.0) < 0.001 {
            print(String(format: "364 gate ① 1× marker (%.0f,%.0f) · shipped Δ %.2f px · without the origin Δ %.2f px · moved %.2f px",
                         reading.marker.x, reading.marker.y, shipped.readings[index].delta,
                         reading.delta, reading.delta - shipped.readings[index].delta))
            XCTAssertLessThanOrEqual(shipped.readings[index].delta, 0.5,
                                     "the shipped entry must be the one that lands")
            XCTAssertGreaterThan(reading.delta, 100,
                                 "gate ①: dropping the origin from the entry must move the marker by "
                                 + "the origin, not by \(reading.delta) px")
        }
    }

    /// **Gate ② — the stand-in's rectangle.** A second spelling of the same rectangle (the crop's
    /// photo pixels at the canvas' origin, which is what 344b shipped) is red on every document whose
    /// canvas is not the photograph — and, deliberately, green on `(0,0)`, where the two spellings
    /// coincide. That is the shape the acceptance's 「四组不漂」 asks for.
    func testGateTwoTheStandInRectangleIsTheCanvasNotThePhotograph() throws {
        var red: [String] = []
        DocumentCanvasConvention364.standInRectUsesPhotoPixels = true
        defer { DocumentCanvasConvention364.standInRectUsesPhotoPixels = false }
        // 0°: the only difference left is the keystone's — a straighten moves the canvas on its own
        // (the stand-in then covers the turned picture's AABB, not the photograph's rect), which is
        // 307's rule and not this task's.
        for keystone in Self.keystones {
            let (loupe, editor) = try openLoupe((keystone.v, keystone.h), angle: 0)
            let measured = try readings(loupe: loupe, editor: editor)
            let worst = measured.readings.map(\.delta).max() ?? 0
            print(String(format: "364 gate ② %@ @0° · photo-pixel rectangle Δ %.2f px", keystone.name, worst))
            if worst > 0.5 { red.append(keystone.name) }
            for window in windows { window.orderOut(nil) }
            windows.removeAll()
            _ = loupe
        }
        XCTAssertEqual(red.sorted(), ["(+40,0)", "(+40,−25)", "(0,−40)"].sorted(),
                       "gate ②: the photo-pixel rectangle is only right where the canvas *is* the "
                       + "photograph — red on \(red)")
    }
}
