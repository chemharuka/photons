import XCTest
import AppKit
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// ⑦ — 裁切框会出画布边缘，进入左侧和上方.
///
/// The clip is one function, `CropToolController.clampToView`, and it lives in the **model**: the
/// overlay draws `draft.crop` and nothing else, so a view-level clamp would fix the drawing and leave
/// the *committed* crop outside the picture. Two other clamps exist and neither replaces this one:
///
///   · `CropRect.clamped()` (`0…1²`) is the crop-rect model's own bound — a rect of the frame can
///     never be bigger than the frame;
///   · `LoupeFraming.limitedCenter` (½ coverage) is what keeps the *camera* from walking off the
///     photograph when a pan or an anchored zoom pushes it out. It says nothing about the frame:
///     the frame can be perfectly legal in the document and still be drawn off the canvas, which is
///     exactly the report.
///
/// This file adds the third one — the **on-screen** bound — and measures it in the same space the
/// overlay draws in, at the sizes the user named: 拉直 9° / 45°, 竖屏, 1:1 / 2:1 + 平移顶到角落, the
/// minimum window, and a photo switch that leaves a crop behind.
@MainActor
final class CropFrameClampTests: XCTestCase {

    private var workDir: URL!

    /// A canvas the controller can believe in: 900×600 points, used as the projection's viewport so
    /// every number below is in points (scale 1) rather than device pixels.
    private static let canvas = (width: 900.0, height: 600.0)

    private struct Case {
        var name: String
        var source: ImageSize
        var state: LoupeViewState
        var straighten: Double
        var lock: AspectLock
        var crop: CropRect = .full
    }

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-crop-clamp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    // MARK: - the measurement

    private struct Measured {
        var frame: NSRect
        var canvas: NSRect
        var photo: NSRect
        var crop: CropRect
        /// Every frame corner, mapped back to the **source** — the inverse-mapping sample the ⑦.4
        /// note asks for (an AABB of the rotated corners would be bigger than the photo).
        var samples: [(x: Double, y: Double)]
        var pixelRatio: Double
    }

    private func measure(_ c: Case, clamped: Bool = true) throws -> Measured {
        let (session, _) = try CropUITestSupport.makeSession(in: workDir,
                                                             width: c.source.width,
                                                             height: c.source.height)
        let controller = CropToolController(session: session)
        XCTAssertTrue(controller.begin())
        controller.clampsFrameToView = clamped
        controller.draft = CropToolController.Draft(crop: c.crop, straighten: c.straighten, lock: c.lock)

        let framing = LoupeFraming(viewport: ImageSize(width: Int(Self.canvas.width),
                                                       height: Int(Self.canvas.height)),
                                   sourceWidth: Double(c.source.width),
                                   sourceHeight: Double(c.source.height),
                                   crop: .full,
                                   straightenDegrees: c.straighten)
        let mapping = framing.mapping(of: c.state)
        _ = controller.clampToView(mapping: mapping, source: c.source)

        let layout = controller.layout(mapping: mapping, source: c.source, pointScale: 1)
        let xs = layout.corners.map(\.x), ys = layout.corners.map(\.y)
        let frame = NSRect(x: xs.min() ?? 0, y: ys.min() ?? 0,
                           width: (xs.max() ?? 0) - (xs.min() ?? 0),
                           height: (ys.max() ?? 0) - (ys.min() ?? 0))
        let a = mapping.frameView(frameX: 0, frameY: 0)
        let b = mapping.frameView(frameX: Double(c.source.width), frameY: Double(c.source.height))
        let photo = NSRect(x: min(a.x, b.x), y: min(a.y, b.y),
                           width: abs(b.x - a.x), height: abs(b.y - a.y))
        let samples = layout.corners.map { mapping.sourcePoint(viewX: Double($0.x), viewY: Double($0.y)) }
        let draft = controller.draft.crop
        let ratio = (draft.width * Double(c.source.width))
            / max(draft.height * Double(c.source.height), 1e-9)
        return Measured(frame: frame, canvas: NSRect(x: 0, y: 0,
                                                     width: Self.canvas.width,
                                                     height: Self.canvas.height),
                        photo: photo, crop: draft, samples: samples, pixelRatio: ratio)
    }

    /// The three criteria, in one place so the anti-proof can show them going red without a second
    /// copy of the arithmetic.
    private func criteria(_ m: Measured, source: ImageSize, ratio expected: Double?)
        -> (insideCanvas: Bool, insidePhoto: Bool, ratio: Bool) {
        let insideCanvas = m.frame.minX >= m.canvas.minX - 0.5
            && m.frame.minY >= m.canvas.minY - 0.5
            && m.frame.maxX <= m.canvas.maxX + 0.5
            && m.frame.maxY <= m.canvas.maxY + 0.5
        let insidePhoto = m.samples.allSatisfy {
            $0.x >= -0.5 && $0.x <= Double(source.width) + 0.5
                && $0.y >= -0.5 && $0.y <= Double(source.height) + 0.5
        }
        let ratio: Bool
        if let expected {
            ratio = abs(m.pixelRatio - expected) / expected <= 0.005
        } else {
            ratio = true
        }
        return (insideCanvas, insidePhoto, ratio)
    }

    private func report(_ c: Case, _ m: Measured, source: ImageSize, expected: Double?) {
        let crit = criteria(m, source: source, ratio: expected)
        print("⑦ \(c.name) · frame \(NSStringFromRect(m.frame)) · canvas \(NSStringFromRect(m.canvas)) · "
              + "photo \(NSStringFromRect(m.photo)) · crop "
              + String(format: "l %.4f t %.4f r %.4f b %.4f", m.crop.left, m.crop.top,
                       m.crop.right, m.crop.bottom)
              + String(format: " · ratio %.4f · 框⊆画布 %@ · 框⊆照片 %@ · 比例 %@",
                       m.pixelRatio, crit.insideCanvas ? "✓" : "✗",
                       crit.insidePhoto ? "✓" : "✗", crit.ratio ? "✓" : "✗"))
    }

    // MARK: - the matrix

    func testTheFrameStaysOnTheCanvasAndOnThePhoto() throws {
        let landscape = ImageSize(width: 3000, height: 2000)
        let portrait = ImageSize(width: 800, height: 1200)
        let centred = LoupeViewState(mode: .actual, zoom: 1, centerX: 1500, centerY: 1000)
        let corner = LoupeViewState(mode: .actual, zoom: 1, centerX: 400, centerY: 300)
        let corner2 = LoupeViewState(mode: .actual, zoom: 2, centerX: 300, centerY: 240)

        let cases: [Case] = [
            Case(name: "fit · 拉直 0°", source: landscape, state: .fit, straighten: 0, lock: .original),
            Case(name: "fit · 拉直 9°", source: landscape, state: .fit, straighten: 9, lock: .original),
            Case(name: "fit · 拉直 45°", source: landscape, state: .fit, straighten: 45, lock: .original),
            Case(name: "1:1 居中 · 拉直 9°", source: landscape, state: centred, straighten: 9,
                 lock: .original),
            Case(name: "1:1 平移顶到左上角", source: landscape, state: corner, straighten: 0,
                 lock: .original),
            Case(name: "1:1 平移顶到左上角 · 拉直 9°", source: landscape, state: corner,
                 straighten: 9, lock: .original),
            Case(name: "2:1 平移顶到角落", source: landscape, state: corner2, straighten: 0,
                 lock: .original),
            Case(name: "竖屏 800×1200 · 1:1 · 拉直 9°", source: portrait, state: .fit,
                 straighten: 9, lock: .original),
            Case(name: "竖屏 · 1:1 平移顶角", source: portrait,
                 state: LoupeViewState(mode: .actual, zoom: 1, centerX: 120, centerY: 90),
                 straighten: 0, lock: .original),
            Case(name: "16:9 锁定 + 拉直 9°", source: landscape, state: .fit, straighten: 9,
                 lock: .sixteenNine),
            Case(name: "1:1 锁定 + 平移顶角", source: landscape, state: corner, straighten: 0,
                 lock: .square, crop: CropRect(left: 0.1, top: 0.1, right: 0.9, bottom: 0.9)),
        ]

        for c in cases {
            let m = try measure(c)
            let expected: Double? = c.lock.ratio
            report(c, m, source: c.source, expected: expected)
            let crit = criteria(m, source: c.source, ratio: expected)
            XCTAssertTrue(crit.insideCanvas, "⑦ \\(c.name): the frame left the canvas — \\(m.frame)")
            XCTAssertTrue(crit.insidePhoto, "⑦ \\(c.name): a frame corner sampled outside the photo")
            XCTAssertTrue(crit.ratio, "⑦ \\(c.name): the pixel ratio moved to \\(m.pixelRatio)")
        }
    }

    /// The anti-proof: with `clampsFrameToView = false` the *same* criteria are red. Each case is run
    /// twice through the same function, so the assertion cannot be passing for a reason of its own.
    func testWithoutTheClampTheFrameLeavesTheCanvas() throws {
        let source = ImageSize(width: 3000, height: 2000)
        let corner = LoupeViewState(mode: .actual, zoom: 2, centerX: 300, centerY: 240)
        let c = Case(name: "2:1 平移顶到角落", source: source, state: corner, straighten: 9,
                     lock: .original)

        let clamped = try measure(c, clamped: true)
        let unclamped = try measure(c, clamped: false)
        let a = criteria(clamped, source: source, ratio: nil)
        let b = criteria(unclamped, source: source, ratio: nil)
        print("⑦ anti-proof · with clamp frame \(NSStringFromRect(clamped.frame)) "
              + "⊆canvas \(a.insideCanvas) ⊆photo \(a.insidePhoto)")
        print("⑦ anti-proof · without clamp frame \(NSStringFromRect(unclamped.frame)) "
              + "⊆canvas \(b.insideCanvas) ⊆photo \(b.insidePhoto)")

        XCTAssertTrue(a.insideCanvas && a.insidePhoto, "⑦: the shipped path keeps the frame legal")
        XCTAssertFalse(b.insideCanvas, "⑦ anti-proof: without the clamp the frame must leave the canvas")
    }

    /// A photo switch leaves a crop behind: a portrait's clamped rect applied to a landscape frame.
    /// The clamp is run again on the new frame, so the leftover state cannot survive it.
    func testSwitchingToAnotherAspectReclampsTheLeftoverCrop() throws {
        let portrait = ImageSize(width: 800, height: 1200)
        let landscape = ImageSize(width: 3000, height: 2000)
        var c = Case(name: "竖屏 1:1 顶角", source: portrait, state: .fit, straighten: 0,
                     lock: .original)
        let first = try measure(c)
        print("⑦ switch · portrait crop "
              + String(format: "l %.4f t %.4f r %.4f b %.4f", first.crop.left, first.crop.top,
                       first.crop.right, first.crop.bottom))

        // The same rect, on the other photo, at the same camera.
        c = Case(name: "同 rect 换到横屏", source: landscape,
                 state: LoupeViewState(mode: .actual, zoom: 2, centerX: 300, centerY: 240),
                 straighten: 0, lock: .original, crop: first.crop)
        let second = try measure(c)
        report(c, second, source: landscape, expected: nil)
        let crit = criteria(second, source: landscape, ratio: nil)
        XCTAssertTrue(crit.insideCanvas, "⑦ switch: the leftover rect is pulled onto the canvas")
        XCTAssertTrue(crit.insidePhoto, "⑦ switch: …and onto the new photo")
    }
}
