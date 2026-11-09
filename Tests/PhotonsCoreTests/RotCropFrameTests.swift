import XCTest
import Metal
import PhotonsCore

/// 301 — 拉直/旋转 + 裁切：**输出画布 = 旋转后的裁切框本身**（方案 A，帧优先）。
///
/// The old contract (162) made the canvas the AABB of the rotated crop; every straightened document
/// therefore carried a tilted black ring around the picture (measured 25.4 % at 9° on a full-frame
/// crop). 301 reverses it: the crop frame *is* the canvas, so the picture support edge and the crop
/// frame's four corners are the same rectangle.
///
/// Fixtures are synthetic (480×320 linear ramp) so no RAW file is needed and every number is
/// reproducible. `black` is `r + g + b ≤ 1e-3` — the same test the diagnosis used.
final class RotCropFrameTests: XCTestCase {

    private let source = ImageSize(width: 480, height: 320)

    // MARK: - fixtures

    private func makeGraph(identity: String) throws -> RenderGraph {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        return try RenderGraph(input: RenderInput(image: rampImage(source.width, source.height),
                                                  identity: identity))
    }

    /// A linear ramp. Every channel is `0.2 … 0.9`, neutral (`r = g = b`), so the exit matrix and the
    /// tone curve cannot create a false "black" and the picture is never mistaken for background.
    private func rampImage(_ width: Int, _ height: Int) -> LinearImage {
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let t = 0.6 * Double(x) / Double(max(width - 1, 1))
                    + 0.4 * Double(y) / Double(max(height - 1, 1))
                let v = Float16(0.2 + 0.7 * t)
                let o = (y * width + x) * 4
                rgba[o] = v
                rgba[o + 1] = v
                rgba[o + 2] = v
                rgba[o + 3] = 1
            }
        }
        return LinearImage(width: width, height: height, rgba: rgba,
                           colorSpace: "sRGB", decoderVersion: "301-rot-crop")
    }

    private func render(_ edit: EditModel, identity: String) throws
        -> (canvas: ImageSize, display: DisplayImage) {
        let graph = try makeGraph(identity: identity)
        let result = try graph.render(edit, options: RenderOptions(scale: 1, useCache: false,
                                                                  wantsPixels: true))
        return (result.canvas, try XCTUnwrap(result.display))
    }

    private func document(crop: CropRect, degrees: Double, quarterTurns: Int = 0) -> EditModel {
        var edit = EditModel.neutral
        // 314 — `EditModel.neutral` now carries the shipped default sharpen (50 / 2.0). These cases
        // assert that the four right angles are **byte-identical**, which sharpening cannot preserve
        // (it is not invariant under resampling); the geometry claim is measured with it off.
        edit.sharpen = SharpenGroup(amount: 0, radius: 2.0, detail: 25, masking: 0)
        edit.geometry.crop = crop.normalizedRect
        edit.geometry.rotationDegrees = degrees
        edit.geometry.quarterTurns = quarterTurns
        edit.geometry.aspectLock = .original
        return edit
    }

    private func luma(_ image: DisplayImage, _ x: Int, _ y: Int) -> Double {
        let o = (y * image.width + x) * 4
        return Double(image.rgba[o]) + Double(image.rgba[o + 1]) + Double(image.rgba[o + 2])
    }

    private func blackFraction(_ image: DisplayImage) -> Double {
        var black = 0
        for y in 0..<image.height {
            for x in 0..<image.width where luma(image, x, y) <= 1e-3 { black += 1 }
        }
        return Double(black) / Double(image.width * image.height)
    }

    /// The picture's support rectangle: the first/last row and column that carry a photograph texel.
    private func supportBounds(_ image: DisplayImage) -> (minX: Int, maxX: Int, minY: Int, maxY: Int) {
        var minX = image.width, maxX = -1, minY = image.height, maxY = -1
        for y in 0..<image.height {
            for x in 0..<image.width where luma(image, x, y) > 1e-3 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        return (minX, maxX, minY, maxY)
    }

    // MARK: - 1. full-frame (inscribed) crop is black-free at every angle

    func testStraightenedFullFrameCropHasNoBlackAtAnyAngle() throws {
        for degrees in [0.0, 3.0, 9.0, 15.0, 45.0] {
            // 301's `clampsToRotatedFrame == true`: a full-frame request becomes the largest crop
            // that is inscribed in the turned photograph, so no output texel can miss the picture.
            let drawn = CropMath.clampedToRotatedFrame(.full, in: source, degrees: degrees,
                                                       keepsInsideRotatedFrame: true)
            if degrees != 0 {
                XCTAssertTrue(CropMath.fitsInsideRotatedFrame(drawn, in: source, degrees: degrees),
                              "θ=\(degrees): the drawn frame must be inside the turned picture")
            }
            let edit = document(crop: drawn, degrees: degrees)
            let (canvas, display) = try render(edit, identity: "301-full-\(degrees)")
            XCTAssertEqual(canvas, CropMath.frameSize(drawn, in: source, allowsOutsideSource: true),
                           "θ=\(degrees): the canvas must be the crop frame itself")
            let black = blackFraction(display)
            print(String(format: "301 · full θ=%.0f° · canvas %d×%d · black %.3f %%",
                         degrees, canvas.width, canvas.height, black * 100))
            XCTAssertLessThanOrEqual(black, 0.0005,
                                     "θ=\(degrees): the output canvas still carries a black ring")
        }
    }

    // MARK: - 2. an inset crop inside the turned frame is clean too

    func testInsetCropIsAlsoCleanWhenItIsInsideTheTurnedFrame() throws {
        let inset = CropRect(left: 0.10, top: 0.10, right: 0.90, bottom: 0.90)
        for degrees in [9.0, 15.0] {
            let drawn = CropMath.clampedToRotatedFrame(inset, in: source, degrees: degrees,
                                                       keepsInsideRotatedFrame: true)
            XCTAssertTrue(CropMath.fitsInsideRotatedFrame(drawn, in: source, degrees: degrees),
                          "θ=\(degrees): the drawn inset frame is not inside the turned picture")
            let edit = document(crop: drawn, degrees: degrees)
            let (canvas, display) = try render(edit, identity: "301-inset-\(degrees)")
            XCTAssertEqual(canvas, CropMath.frameSize(drawn, in: source, allowsOutsideSource: true))
            let black = blackFraction(display)
            print(String(format: "301 · inset 10%% θ=%.0f° · canvas %d×%d · black %.3f %%",
                         degrees, canvas.width, canvas.height, black * 100))
            XCTAssertLessThanOrEqual(black, 0.0005,
                                     "θ=\(degrees): an inscribed crop was painted black")
        }
    }

    // MARK: - 3. the crop frame's four corners and the picture support are one rectangle

    func testTheCropFrameAndTheRenderedSupportCoincide() throws {
        for degrees in [0.0, 9.0, 15.0, 45.0] {
            let drawn = CropMath.clampedToRotatedFrame(.full, in: source, degrees: degrees,
                                                       keepsInsideRotatedFrame: true)
            let edit = document(crop: drawn, degrees: degrees)
            let (canvas, display) = try render(edit, identity: "301-corners-\(degrees)")
            let frame = CropMath.frameSize(drawn, in: source, allowsOutsideSource: true)
            XCTAssertEqual(canvas, frame, "θ=\(degrees): the canvas and the crop frame disagree")

            // `CropTool.layout` draws the crop in frame space; with the 301 contract that space **is**
            // the output canvas, so its four corners are the canvas' four corners. (The app's overlay
            // and this projection are the same statement: `mapping.framePoint(layout corner)` lands
            // on `0…frameSize` because the mapping's crop origin is the drawn crop.)
            let overlay = [(0.0, 0.0), (Double(frame.width), 0.0),
                           (Double(frame.width), Double(frame.height)),
                           (0.0, Double(frame.height))]
            let support = supportBounds(display)
            let rendered = [(support.minX, support.minY),
                            (support.maxX + 1, support.minY),
                            (support.maxX + 1, support.maxY + 1),
                            (support.minX, support.maxY + 1)]
            for (index, corner) in overlay.enumerated() {
                let got = rendered[index]
                XCTAssertLessThanOrEqual(abs(Double(got.0) - corner.0), 1.0,
                                         "θ=\(degrees): crop corner \(index) x is \(got.0), frame \(corner.0)")
                XCTAssertLessThanOrEqual(abs(Double(got.1) - corner.1), 1.0,
                                         "θ=\(degrees): crop corner \(index) y is \(got.1), frame \(corner.1)")
            }
            print("301 · corners θ=\(Int(degrees))° · frame \(frame.keyString) · support \(rendered)")
        }
    }

    // MARK: - 4. right angles are byte-identical (the contract must not touch them)

    func testRightAnglesAreByteIdentical() throws {
        // SHA-256 of `DisplayImage.rgba` from the **pre-301** code (captured with only the Sources
        // reverted; the fixture and the render options are identical). This is the "right angles do
        // not move" guard: at `straightenDegrees == 0` the changed branches are not on the path.
        let expected: [String: String] = [
            "turns=0/full": "50108481b67dde9c588cd03b5a42fc2629767d7a51c8acd0ba589cb22695d9c4",
            "turns=0/inset": "baccdb535a16647be2669291c683b99cca4f7f285f9bdf7b8e175b4fb9858fa7",
            "turns=1/full": "5aa171ef8049a106f20d42af149e2672a7dd9d0d2d3d47905745d3bb0ecd8882",
            "turns=1/inset": "4c2d0f38e3dc08d6820ce350b4b07c02616db4394e7e7f7285cecc502cca4fdd",
            "turns=2/full": "21c1d39cd54788d53107346065b58df262ddc92fd68ae04418aec268f29440f7",
            "turns=2/inset": "38867f240103fab6b7d842f3d9ff0e330a06fd5b9b8409df77d19905116fb4b0",
            "turns=3/full": "f99822fb54c0252f1909af6c2f974736831d9e31106f9fbda6018a6df490f68e",
            "turns=3/inset": "417d5702c31a777bb06dc6b8b1a33fb9a9e23c6177820759427e5a3a76768b1a",
        ]
        let crops: [(String, CropRect)] = [
            ("full", .full),
            ("inset", CropRect(left: 0.10, top: 0.10, right: 0.90, bottom: 0.90)),
        ]
        for turns in 0...3 {
            for (name, crop) in crops {
                let edit = document(crop: crop, degrees: 0, quarterTurns: turns)
                let (_, display) = try render(edit, identity: "301-right-\(turns)-\(name)")
                let key = "turns=\(turns)/\(name)"
                let sha = display.sha256()
                print("301 · right angle \(key) · \(sha)")
                if let want = expected[key] {
                    XCTAssertEqual(sha, want, "\(key): a right angle changed bytes")
                }
            }
        }
    }
}
