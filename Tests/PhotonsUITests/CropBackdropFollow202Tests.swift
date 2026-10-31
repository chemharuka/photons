import XCTest
import AppKit
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 202 ③ — **the low-resolution whole picture must be the same document the frame is.**
///
/// The backdrop is a low-res render of 「the whole picture」, and the present pass reads its `[0,1]`
/// as **picture coordinates**: `framePlacement.region` says which part of the picture a window shows,
/// and `PresentWindow.onWholePicture` composes the two. Since 197 the frame job *and* the camera are
/// the whole frame (`cropTool.canvasEdit` → crop `.full`), so `region` is normalised against the
/// whole frame's canvas. The backdrop's own render was still made from `session.edit` — the
/// **document's crop** — so the texture holds the kept rectangle while the sampler believes it holds
/// the picture. Two numbers come out of that:
///
///   · **scale** — the texture's canvas is `canvasSize(crop)` instead of `canvasSize(.full)`;
///   · **shift** — the texture's own centre (uv 0.5) is the *crop's* centre, so it lands at the
///     picture's (0.5, 0.5) instead of at the crop's centre. Centred crop → 0 px (invisible, and
///     why the report only named the off-centre case); off-centre crop → the crop's own margin,
///     i.e. the 「偏贴」.
///
/// Measured here at 5.4° in the report's own crop (`x 0.2–0.6, y 0.1–0.7`) against a centred control
/// of the same size, and asserted through the shipped key (which document the backdrop renders from).
@MainActor
final class CropBackdropFollow202Tests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-crop-202c-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    private static let source = ImageSize(width: 9520, height: 6336)
    private static let canvas = ImageSize(width: 1600, height: 1000)

    /// The report's crop: 40 % × 60 %, hard against the top-left (`x 0.2–0.6, y 0.1–0.7`).
    private static let offCentre = CropRect(left: 0.2, top: 0.1, right: 0.6, bottom: 0.7)
    /// The control: the same *size*, centred.
    private static let centred = CropRect(left: 0.3, top: 0.2, right: 0.7, bottom: 0.8)

    private static let framings: [(String, LoupeViewState)] = [
        ("fit", .fit),
        ("25%", LoupeViewState(mode: .actual, zoom: 0.25, centerX: 4760, centerY: 3168)),
        ("50%", LoupeViewState(mode: .actual, zoom: 0.5, centerX: 4760, centerY: 3168)),
        ("1:1", LoupeViewState(mode: .actual, zoom: 1, centerX: 4760, centerY: 3168)),
    ]

    private func canvasSize(_ crop: CropRect) -> ImageSize {
        CropMath.canvasSize(crop: crop, in: Self.source, straightenDegrees: 5.4,
                            quarterTurns: 0, allowsOutsideSource: true)
    }

    func testTheBackdropIsTheWholeFrame() throws {
        let (session, _) = try CropUITestSupport.makeSession(in: workDir,
                                                             width: Self.source.width,
                                                             height: Self.source.height)
        session.applyEdit { $0.geometry.rotationDegrees = 5.4 }
        session.commitEdit(label: "probe", coalesce: false)
        let loupe = LoupeController(session: session)
        loupe.autoRenderEnabled = false
        XCTAssertTrue(CropUITestSupport.openCropTool(loupe, session, timeout: 2))

        for (label, cropRect) in [("居中", Self.centred), ("非居中", Self.offCentre)] {
            session.applyEdit { $0.geometry.crop = cropRect.normalizedRect }
            let wholeFrame = loupe.cropTool.canvasEdit(from: session.edit)
            let f = LoupeFraming(viewport: Self.canvas, decoded: Self.source, decodeScale: 1,
                                 edit: wholeFrame, fitScale: 0.9)
            // The crop's centre is where its content's uv 0.5 sits in picture coordinates; the present
            // reads uv 0.5 as the picture's middle. Their difference is the shift, in screen pixels.
            let shiftX = (cropRect.centerX - 0.5), shiftY = (cropRect.centerY - 0.5)
            for (name, state) in Self.framings {
                let mapping = f.mapping(of: state)
                let placement = f.framePlacement(of: mapping)
                let pictureW = Double(mapping.contentWidth), pictureH = Double(mapping.contentHeight)
                let docCanvas = canvasSize(cropRect), frameCanvas = canvasSize(.full)
                print(String(format: "202 ③ · %@ · %-4@ · region u[%.4f…%.4f] v[%.4f…%.4f] · "
                             + "texture canvas %@ (whole frame %@) · picture %.1f×%.1f px · "
                             + "crop centre (%.2f, %.2f) → shift %+.1f,%+.1f px",
                             label, name,
                             placement.region.left, placement.region.right,
                             placement.region.top, placement.region.bottom,
                             "\(docCanvas.width)×\(docCanvas.height)",
                             "\(frameCanvas.width)×\(frameCanvas.height)",
                             pictureW, pictureH, cropRect.centerX, cropRect.centerY,
                             shiftX * pictureW, shiftY * pictureH))
            }
        }

        // The backdrop the app renders is the whole frame — the same document `canvasEdit` gives the
        // frame job (197), so its [0,1] really is the picture the `region` speaks about.
        for (_, cropRect) in [("非居中", Self.offCentre), ("居中", Self.centred)] {
            session.applyEdit { $0.geometry.crop = cropRect.normalizedRect }
            XCTAssertEqual(loupe.backdropDigestForTesting,
                           Histogram.editDigest(loupe.cropTool.canvasEdit(from: session.edit)),
                           "the low-res backdrop is still rendered from the document's crop "
                           + "(\(cropRect.left), \(cropRect.top))")
        }

        // The two canvases the two candidates would produce — the scale half of the bug, in pixels.
        let docCanvas = canvasSize(Self.offCentre), frameCanvas = canvasSize(.full)
        print("202 ③ · canvas of the document's crop \(docCanvas) · canvas of the whole frame \(frameCanvas) · "
              + String(format: "%.3f×", Double(docCanvas.width) / Double(frameCanvas.width)))
        XCTAssertNotEqual(docCanvas, frameCanvas, "the probe needs the two canvases to differ")
    }
}
