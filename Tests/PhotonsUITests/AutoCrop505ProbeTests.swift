import XCTest
import AppKit
import Metal
import PhotonsCore
@testable import PhotonsUI

/// 505 §2.1 — **the probe**: does 自动裁剪 eat the keystone?
///
/// A 480×320 ramp is the photograph. The document is written **before** the crop tool opens (the way
/// the eye/timeline sees it), `autoCrop()` writes its answer, and that answer is rendered at the
/// fixture's own resolution: the pixels that sample **outside** the photograph (pure black) are
/// counted, together with the four edges of the rect it wrote and the four corners walked back to
/// photo coordinates.
///
/// Printed, not asserted: these numbers are the ticket's 「改前/改后」 table. The invariants the
/// answer must satisfy live in `AutoCropAfterStraighten505Tests`.
/// `print` lands in XCTest's buffered stdout, which a redirected `swift test` run does not keep; the
/// numbers the report quotes go to stderr so they survive (`XCTAssert` messages carry them too).
private func note(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

@MainActor
final class AutoCrop505ProbeTests: XCTestCase {

    private static let source = ImageSize(width: 480, height: 320)
    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-505-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    func testProbeStrongPerspectivePlusStraighten() throws {
        try probe(name: "强透视 + 强拉直 (+30 / −20 / 8°)") {
            $0.perspectiveVertical = 30
            $0.perspectiveHorizontal = -20
            $0.rotationDegrees = 8
        }
    }

    func testProbeShearOnly() throws {
        try probe(name: "只有引导线 shear (k = −0.052)") { $0.perspectiveShear = -0.052 }
    }

    func testProbePureStraighten() throws {
        try probe(name: "纯拉直 (0 / 0 / 8°)") { $0.rotationDegrees = 8 }
    }

    func testProbeLevelDocument() throws {
        try probe(name: "已水平 (0 / 0 / 0°)") { _ in }
    }

    // MARK: - harness

    private func probe(name: String, document: (inout GeometryGroup) -> Void) throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let directory = workDir.appendingPathComponent("p-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let (session, _) = try CropUITestSupport.makeSession(in: directory,
                                                            width: Self.source.width,
                                                            height: Self.source.height)
        session.applyEdit { document(&$0.geometry) }
        _ = session.commitEdit(label: "505 探针夹具", coalesce: false)
        let tool = CropToolController(session: session)
        XCTAssertTrue(tool.begin(), "505: 进裁切模式")

        let before = session.edit.geometry
        let cropped = tool.autoCrop()
        let after = session.edit.geometry
        let c = after.crop
        note(String(format: "505 探针 · %@ · autoCrop() = %@ · 框 L%.6f T%.6f R%.6f B%.6f · 宽×高 %.6f×%.6f"
                     + " · 面积 %.6f · space %@ · 改前框 L%.6f T%.6f R%.6f B%.6f · 文档 %+.1f/%+.1f/%.1f°",
                     name, cropped ? "true" : "false",
                     c.x, c.y, c.x + c.width, c.y + c.height, c.width, c.height,
                     Double(c.width * c.height),
                     after.cropSpace == .canvas ? "canvas" : "source",
                     before.crop.x, before.crop.y,
                     before.crop.x + before.crop.width, before.crop.y + before.crop.height,
                     after.perspectiveVertical, after.perspectiveHorizontal, after.rotationDegrees))

        // The document as it now stands, rendered on the fixture's own pixels.
        var edit = CropUITestSupport.geometryOnly
        edit.geometry = after
        let graph = try RenderGraph(input: RenderInput(image: ramp(Self.source),
                                                       identity: "505-probe"))
        let display = try XCTUnwrap(try graph.render(edit, options: RenderOptions(
            scale: 1, useCache: false, wantsPixels: true)).display)
        var black = 0
        var xs: [Int] = [], ys: [Int] = []
        var interior = 0
        let band = 3
        for y in 0..<display.height {
            for x in 0..<display.width {
                let o = (y * display.width + x) * 4
                guard display.rgba[o] == 0, display.rgba[o + 1] == 0, display.rgba[o + 2] == 0 else {
                    continue
                }
                black += 1
                xs.append(x); ys.append(y)
                if x >= band, x < display.width - band, y >= band, y < display.height - band {
                    interior += 1
                }
            }
        }
        note(String(format: "505 探针 · %@ · 渲染 %d×%d · 框内纯黑 %d = %.4f %% · 黑像素 bbox x[%d,%d] y[%d,%d]"
                     + " · 距边 ≥%d px 的内部黑像素 %d",
                     name, display.width, display.height, black,
                     Double(black) / Double(max(display.width * display.height, 1)) * 100,
                     xs.min() ?? -1, xs.max() ?? -1, ys.min() ?? -1, ys.max() ?? -1,
                     band, interior))

        // 505 — where the polygon and the renderer could disagree: the quad the crop was solved in,
        // its AABB (the canvas box `[0,1]²` must be this), and the four corners of the answer walked
        // back through the canvas' own `sampling` — a corner outside `[0,1]²` is a black corner.
        let canvas = CropMath.documentCanvas(source: Self.source,
                                             straightenDegrees: after.rotationDegrees,
                                             perspective: after.perspective)
        let quad = [(0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 1.0)].map {
            PerspectiveMap.apply(canvas.forward, x: $0.0, y: $0.1)
        }
        note(String(format: "505 探针 · %@ · 画布 %d×%d · forward(四角) = %@ · AABB x[%.4f,%.4f] y[%.4f,%.4f]",
                     name, canvas.size.width, canvas.size.height,
                     quad.map { String(format: "(%.4f,%.4f)", $0.x, $0.y) }.joined(separator: " "),
                     quad.map(\.x).min() ?? 0, quad.map(\.x).max() ?? 0,
                     quad.map(\.y).min() ?? 0, quad.map(\.y).max() ?? 0))
        let back = [(c.x, c.y), (c.x + c.width, c.y),
                    (c.x + c.width, c.y + c.height), (c.x, c.y + c.height)].map {
            PerspectiveMap.apply(canvas.sampling, x: $0.0, y: $0.1)
        }
        note(String(format: "505 探针 · %@ · 框四角反算照片坐标 = %@",
                     name, back.map { String(format: "(%.5f,%.5f)", $0.x, $0.y) }.joined(separator: " ")))
    }


    /// 505 — why a canvas-space fixture can come back 「no rectangle」: the polygon the controller
    /// would feed, printed with the solver's own answer.
    func testProbeCanvasPolygonSolves() {
        for (v, h, shear, angle) in [(30.0, 0.0, 0.0, 0.0), (0.0, 25.0, 0.0, 0.0),
                                     (30.0, -20.0, 0.0, 8.0), (15.0, -10.0, 0.03, 3.0)] {
            let perspective = PerspectiveMap(vertical: v, horizontal: h, shear: shear, aspect: 1)
            let canvas = CropMath.documentCanvas(source: Self.source, straightenDegrees: angle,
                                                 perspective: perspective)
            var samples: [NormalizedPoint] = []
            let corners = [(0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 1.0)]
            for i in corners.indices {
                let a = corners[i], b = corners[(i + 1) % corners.count]
                for step in 0...16 {
                    let t = Double(step) / 16
                    let p = PerspectiveMap.apply(canvas.forward, x: a.0 + (b.0 - a.0) * t,
                                                 y: a.1 + (b.1 - a.1) * t)
                    samples.append(NormalizedPoint(p.x, p.y))
                }
            }
            let hull = AutoCrop505Hull.simplified(AutoCrop505Hull.hull(samples))
            let rect = AutoCropSolver.maximumRectangle(in: hull)
            let loose = AutoCropSolver.maximumRectangle(in: hull,
                                                        bounds: CropRect(left: -1, top: -1,
                                                                         right: 2, bottom: 2))
            note(String(format: "505 探针 · canvas (+%.0f/%+.0f/sh %.3f/%.0f°) · 画布 %d×%d · 凸包 %d 点"
                        + " · 顶点 %@ → 解 %@ · 不夹 [0,1]² %@",
                        v, h, shear, angle, canvas.size.width, canvas.size.height, hull.count,
                        hull.map { String(format: "(%.5f,%.5f)", $0.x, $0.y) }.joined(separator: " "),
                        rect.map { String(format: "L%.4f T%.4f R%.4f B%.4f", $0.x, $0.y,
                                          $0.x + $0.width, $0.y + $0.height) } ?? "nil",
                        loose.map { String(format: "L%.4f T%.4f R%.4f B%.4f", $0.x, $0.y,
                                           $0.x + $0.width, $0.y + $0.height) } ?? "nil"))
        }
    }


    /// 505 — is the nil caused by the polygon touching `[0,1]²`, or by an **axis-parallel** side?
    func testProbeSolverOnSyntheticTrapezoids() {
        func trap(_ inset: Double, _ degrees: Double) -> [NormalizedPoint] {
            let corners = [(0.0, 0.0), (1.0, 0.0), (1.0 - 0.03, 1.0), (0.03, 1.0)]
            let r = CropGeometry.RotationMatrix(degrees: degrees)
            return corners.map { c in
                let x = (c.0 - 0.5) * (1 - inset) * 2, y = (c.1 - 0.5) * (1 - inset) * 2
                let p = r.apply(x: x, y: y)
                return NormalizedPoint(0.5 + p.x / 2, 0.5 + p.y / 2)
            }
        }
        for (inset, degrees) in [(0.0, 0.0), (0.02, 0.0), (0.0, 1e-4), (0.0, 3.0), (0.0, 90.0)] {
            let polygon = trap(inset, degrees)
            let rect = AutoCropSolver.maximumRectangle(in: polygon)
            note(String(format: "505 合成梯形 inset %.3f rot %.4f° → %@", inset, degrees,
                        rect.map { String(format: "L%.4f T%.4f R%.4f B%.4f 面积 %.4f",
                                          $0.x, $0.y, $0.x + $0.width, $0.y + $0.height,
                                          Double($0.width * $0.height)) } ?? "nil"))
        }
    }

    private func ramp(_ size: ImageSize) -> LinearImage {
        var rgba = [Float16](repeating: 0, count: size.width * size.height * 4)
        for y in 0..<size.height {
            for x in 0..<size.width {
                let t = 0.6 * Double(x) / Double(max(size.width - 1, 1))
                    + 0.4 * Double(y) / Double(max(size.height - 1, 1))
                let v = Float16(0.2 + 0.7 * t)
                let o = (y * size.width + x) * 4
                rgba[o] = v; rgba[o + 1] = v; rgba[o + 2] = v; rgba[o + 3] = 1
            }
        }
        return LinearImage(width: size.width, height: size.height, rgba: rgba,
                           colorSpace: "sRGB", decoderVersion: "505-probe")
    }
}
