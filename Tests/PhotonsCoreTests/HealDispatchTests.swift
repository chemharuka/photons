import XCTest
import Metal
import simd
import PhotonsCore

/// 257 C2 — the per-spot bbox dispatch must be the **pre-257 whole-canvas dispatch**, pixel for
/// pixel. `RenderOptions.healFullCanvasDispatch` keeps the old grid as a first-class hook; the same
/// kernel with the same uniform runs both, so the comparison is about `thread_position_in_grid`
/// and not about two copies of the arithmetic.
final class HealDispatchTests: XCTestCase {

    private func makeGraph(_ image: LinearImage, identity: String) throws -> RenderGraph {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        return try RenderGraph(input: RenderInput(image: image, identity: identity))
    }

    private static func hash01(_ x: Int, _ y: Int) -> Double {
        var h = UInt32(truncatingIfNeeded: x &* 73_856_093) &+ UInt32(truncatingIfNeeded: y &* 19_349_663)
        h = (h ^ (h >> 13)) &* 2_654_435_761
        h ^= h >> 16
        return Double(h % 1000) / 1000.0
    }

    private func picture(_ width: Int, _ height: Int) -> LinearImage {
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                // A smooth ramp + hash texture: a flat field would make a byte-for-byte claim weak,
                // and a pure hash would make the source offset's edge clamp hard to see.
                let v = 0.12 + 0.55 * (Double(x) + 0.5) / Double(width)
                    + 0.18 * (Double(y) + 0.5) / Double(height)
                    + 0.06 * Self.hash01(x, y)
                let o = (y * width + x) * 4
                rgba[o] = Float16(min(v, 0.98))
                rgba[o + 1] = Float16(min(v * 0.9 + 0.05, 0.98))
                rgba[o + 2] = Float16(min(v * 0.8 + 0.1, 0.98))
                rgba[o + 3] = 1
            }
        }
        return LinearImage(width: width, height: height, rgba: rgba,
                           colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic-heal-dispatch")
    }

    private struct Layout {
        let name: String
        let center: NormalizedPoint
        let radius: Double
        let offset: NormalizedPoint
    }

    private static let layouts: [Layout] = [
        Layout(name: "small r=0.02 centre", center: NormalizedPoint(0.5, 0.5),
               radius: 0.02, offset: NormalizedPoint(0.04, 0)),
        Layout(name: "big r=0.35 centre", center: NormalizedPoint(0.5, 0.5),
               radius: 0.35, offset: NormalizedPoint(0.12, 0.03)),
        Layout(name: "edge centre=0.995", center: NormalizedPoint(0.995, 0.5),
               radius: 0.06, offset: NormalizedPoint(-0.08, 0.01)),
        Layout(name: "source out of canvas", center: NormalizedPoint(0.45, 0.45),
               radius: 0.05, offset: NormalizedPoint(1.6, 0.9)),
    ]

    private func spots(_ n: Int, _ layout: Layout, size: ImageSize) -> [HealSpot] {
        guard n > 0 else { return [] }
        return (0..<n).map { i in
            let angle = 2 * Double.pi * Double(i) / Double(max(n, 1))
            // Keep the layout's character (centre / edge / source) while not stacking all n spots on
            // one centre: overlapping and disjoint spots both have to match the old dispatch.
            let spread = layout.name.contains("edge") ? 0.0 : 0.18
            let cx = min(max(layout.center.x + spread * cos(angle), 0.01), 0.995)
            let cy = min(max(layout.center.y + spread * sin(angle), 0.01), 0.99)
            return HealSpot(id: "h-\(layout.name)-\(i)",
                            center: NormalizedPoint(cx, cy),
                            radius: layout.radius,
                            sourceOffset: layout.offset,
                            mode: .heal, feather: i.isMultiple(of: 2) ? 0.0 : 0.35,
                            opacity: 1)
        }
    }

    func testBBoxDispatchIsTheFullCanvasDispatchPixelForPixel() throws {
        let size = ImageSize(width: 320, height: 240)
        let graph = try makeGraph(picture(size.width, size.height), identity: "heal-dispatch")

        for layout in Self.layouts {
            for n in [1, 3, 8] {
                var doc = EditModel.neutral
                doc.healSpots = spots(n, layout, size: size)
                let bbox = try XCTUnwrap(graph.render(doc, options: (
                    { var o = RenderOptions(scale: 1, useCache: false, wantsPixels: true)
                      o.healFullCanvasDispatch = false
                      return o })()).display)
                let full = try XCTUnwrap(graph.render(doc, options: (
                    { var o = RenderOptions(scale: 1, useCache: false, wantsPixels: true)
                      o.healFullCanvasDispatch = true
                      return o })()).display)

                print("dispatch \(layout.name) n=\(n): bbox \(bbox.sha256().prefix(16))… / "
                      + "full canvas \(full.sha256().prefix(16))…")

                XCTAssertEqual(bbox.sha256(), full.sha256(),
                               "\(layout.name), \(n) spot: bbox dispatch must be the full-canvas dispatch")
                XCTAssertEqual(bbox.rgba, full.rgba,
                               "\(layout.name), \(n) spot: every Float16 byte, not only the digest")
            }
        }
    }

    func testZeroSpotsDoNotEncodeThePassAndMatchTheNeutralDocument() throws {
        let size = ImageSize(width: 320, height: 240)
        let graph = try makeGraph(picture(size.width, size.height), identity: "heal-dispatch-empty")
        let neutral = try XCTUnwrap(graph.render(EditModel.neutral,
                                                 options: RenderOptions(scale: 1, useCache: false,
                                                                        wantsPixels: true)).display)
        var doc = EditModel.neutral
        doc.healSpots = []
        let empty = try graph.render(doc, options: RenderOptions(scale: 1, useCache: false,
                                                                 wantsPixels: true))
        let pixels = try XCTUnwrap(empty.display)
        print("dispatch n=0: \(pixels.sha256().prefix(16))…, heal executed "
              + "\(empty.trace.executed.contains(.heal))")
        XCTAssertFalse(empty.trace.executed.contains(.heal), "空 spot 列表不编码 S1.9")
        XCTAssertEqual(pixels.sha256(), neutral.sha256(), "0 spot 与中性文档逐字节相同")
    }

    func testTheTwoDispatchesAgreeOnAWindowRenderToo() throws {
        // A 1:1 window is the other way the dispatch origin can be wrong: the bbox is in *canvas*
        // coordinates, and the window render's canvas is the whole frame minus the window origin.
        let size = ImageSize(width: 320, height: 240)
        let graph = try makeGraph(picture(size.width, size.height), identity: "heal-dispatch-window")
        var doc = EditModel.neutral
        doc.healSpots = spots(3, Self.layouts[0], size: size)
        let rect = ImageRect(x: 40, y: 30, width: 220, height: 170)
        func render(_ full: Bool) throws -> DisplayImage {
            var o = RenderOptions(scale: 1, outputWindow: rect, useCache: false, wantsPixels: true)
            o.healFullCanvasDispatch = full
            return try XCTUnwrap(graph.render(doc, options: o).display)
        }
        let bbox = try render(false), full = try render(true)
        print("dispatch window: bbox \(bbox.sha256().prefix(16))… / full canvas \(full.sha256().prefix(16))…")
        XCTAssertEqual(bbox.sha256(), full.sha256())
        XCTAssertEqual(bbox.rgba, full.rgba)
    }
}
