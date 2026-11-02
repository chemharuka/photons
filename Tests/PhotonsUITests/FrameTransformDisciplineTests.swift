import XCTest
import PhotonsCore
@testable import PhotonsUI

/// 261 — the structural guard that keeps the frame chain from growing a second copy of a scale.
///
/// Two questions, in the order they can fail:
///   1. **Does any source file still multiply a coordinate by a scale it should have read from
///      `FrameTransform`?** The scan is a lint, so it is proved non-vacuous by feeding it a
///      deliberately wrong source string and asserting the same regex catches it.
///   2. **Do the consumers actually read the transform?** The loupe's mapping is checked value by
///      value; the renderer's plan is checked by source (it is private and its output is already
///      pinned by the 180-combination matrix).
final class FrameTransformDisciplineTests: XCTestCase {

    // MARK: - ① the source lint

    /// The manual combinations 232/260 proved can be multiplied twice. Each one is a regex over a
    /// **code** line (comments are stripped first) so prose about `origin` cannot trip it.
    private struct Forbidden {
        let name: String
        let pattern: String
        let sample: String
    }

    private static let forbidden: [Forbidden] = [
        .init(name: "× crop", pattern: #"\*\s*crop\b"#,
              sample: "let x = viewX * crop"),
        .init(name: "crop ×", pattern: #"\bcrop\s*\*"#,
              sample: "let x = crop * viewX"),
        .init(name: "× decodeScale", pattern: #"\*\s*decodeScale\b"#,
              sample: "let x = viewX * decodeScale"),
        .init(name: "decodeScale ×", pattern: #"\bdecodeScale\s*\*"#,
              sample: "let x = decodeScale * viewX"),
        .init(name: "+ origin", pattern: #"\+\s*origin\b"#,
              sample: "let x = pictureX + origin"),
        .init(name: "× fitMargin", pattern: #"\*\s*fitMargin\b"#,
              sample: "let z = fit * fitMargin"),
        .init(name: "contentWidth / cropWidth", pattern: #"contentWidth\s*/\s*max\(cropWidth"#,
              sample: "let s = contentWidth / max(cropWidth, 1e-9)"),
    ]

    /// Files that own their arithmetic on purpose. One line each, with the reason — a bare path
    /// would turn the guard into decoration.
    private static let whitelist: [String: String] = [
        "PhotonsCore/CropGeometry.swift":
            "the S1→S2→S3→S4 geometry owner itself",
        "PhotonsCore/CropMath.swift":
            "the crop/aspect/AABB arithmetic the geometry owner calls",
        "PhotonsCore/FrameTransform.swift":
            "the assembly point this guard exists to protect",
        "PhotonsUI/LoupeZoom.swift":
            "LoupeMapping keeps a direct-init fallback for its older tests; the product path "
            + "delegates to FrameTransform and is pinned by testLoupeProjectionReadsTheTransform",
        "PhotonsCore/Masks.swift":
            "the mask atlas' own S3→S4 map (MaskCanvasMapping), pinned by MaskRotationPixelsTests; "
            + "it is not the picture's frame chain",
    ]

    private static var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // PhotonsUITests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repository
            .appendingPathComponent("Sources", isDirectory: true)
    }

    private func swiftSources() throws -> [(path: String, text: String)] {
        let root = Self.sourcesRoot.path
        let enumerator = FileManager.default.enumerator(atPath: root)
        var out: [(String, String)] = []
        while let relative = enumerator?.nextObject() as? String {
            guard relative.hasSuffix(".swift") else { continue }
            let path = root + "/" + relative
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            out.append((relative, text))
        }
        return out
    }

    /// Remove `//` comments while leaving string literals alone enough for this lint (a URL inside a
    /// string is not one of the patterns; a `//` in a string would only make the scan stricter).
    private func codeOnly(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            if let range = line.range(of: "//") { return String(line[..<range.lowerBound]) }
            return String(line)
        }.joined(separator: "\n")
    }

    func testNoSourceReMultipliesAFrameFactor() throws {
        var failures: [String] = []
        for source in try swiftSources() {
            if let reason = Self.whitelist[source.path] {
                _ = reason // the reason is documentation; reading it here keeps it from going stale
                continue
            }
            let code = codeOnly(source.text)
            for rule in Self.forbidden where code.range(of: rule.pattern, options: .regularExpression) != nil {
                failures.append("\(source.path): \(rule.name)")
            }
        }
        XCTAssertEqual(failures, [], """
            261: manual frame factors outside FrameTransform:
            \(failures.joined(separator: "\n"))
            Read `FrameTransform` (s1ToS3 / s3ToS5 / frameRectInS5 / viewPointToSource) instead.
            """)
    }

    /// The lint above must be able to fail. Feed it a deliberately wrong source string and assert
    /// every rule fires — otherwise "the repo happens to be clean" proves nothing.
    func testTheSourceLintCatchesAnInjectedReMultiplication() {
        let broken = """
        func mapping(viewX: Double, origin: Point, fitMargin: Double, decodeScale: Double,
                     crop: CropRect, contentWidth: Double, cropWidth: Double) {
            let a = viewX * crop
            let b = crop * viewX
            let c = viewX * decodeScale
            let d = decodeScale * viewX
            let e = a + origin
            let f = fit * fitMargin
            let g = contentWidth / max(cropWidth, 1e-9)
        }
        """
        for rule in Self.forbidden {
            XCTAssertNotNil(broken.range(of: rule.pattern, options: .regularExpression),
                            "261: the lint rule \(rule.name) did not catch its own sample")
        }
    }

    // MARK: - ② the consumers

    func testLoupeProjectionReadsTheTransform() {
        var edit = EditModel.neutral
        edit.geometry.rotationDegrees = 7
        edit.geometry.crop = CropRect(left: 0.1, top: 0.2, right: 0.8, bottom: 0.9).normalizedRect
        let framing = LoupeFraming(viewport: ImageSize(width: 1400, height: 900),
                                   decoded: ImageSize(width: 3000, height: 2000),
                                   decodeScale: 0.5, edit: edit)
        let state = LoupeViewState(mode: .actual, zoom: 2, centerX: 1200, centerY: 900)
        let mapping = framing.mapping(of: state)
        guard let transform = mapping.transform else {
            return XCTFail("261: LoupeFraming.mapping did not build a FrameTransform")
        }
        for point in [SIMD2<Double>(0, 0), SIMD2(123.5, 456.25), SIMD2(1399, 899)] {
            let got = mapping.sourcePoint(viewX: point.x, viewY: point.y)
            let want = transform.viewPointToSource(point)
            XCTAssertEqual(got.x, want.x, accuracy: 1e-9)
            XCTAssertEqual(got.y, want.y, accuracy: 1e-9)
        }
        let framePoint = SIMD2<Double>(480, 360)
        let framed = mapping.frameView(frameX: framePoint.x, frameY: framePoint.y)
        let wantFrame = transform.unrotatedSourceToView(framePoint)
        XCTAssertEqual(framed.x, wantFrame.x, accuracy: 1e-9)
        XCTAssertEqual(framed.y, wantFrame.y, accuracy: 1e-9)
    }

    func testCropOverlayReadsTheTransformFrameQuad() {
        var edit = EditModel.neutral
        edit.geometry.rotationDegrees = 12
        edit.geometry.crop = CropRect(left: 0.1, top: 0.15, right: 0.75, bottom: 0.8).normalizedRect
        let source = ImageSize(width: 3000, height: 2000)
        let framing = LoupeFraming(viewport: ImageSize(width: 1200, height: 800),
                                   decoded: source, decodeScale: 1, edit: edit)
        let mapping = framing.mapping(of: .fit)
        guard let transform = mapping.transform else {
            return XCTFail("261: no FrameTransform")
        }
        let crop = edit.geometry.renderCrop(source: source)
        let layout = CropTool.layout(crop: crop, source: source, mapping: mapping,
                                     pointScale: 1, showsGrid: false, quadRotationDegrees: 0)
        let quad = transform.frameQuadInS5()
        XCTAssertEqual(layout.corners.count, quad.count)
        for (got, want) in zip(layout.corners, quad) {
            XCTAssertEqual(Double(got.x), want.x, accuracy: 1e-9)
            XCTAssertEqual(Double(got.y), want.y, accuracy: 1e-9)
        }
    }

    /// `plan` is private; its output is already pinned by the 180-combination matrix. What can be
    /// asserted here is that the file still goes through the exit for those numbers.
    func testRenderPlanReadsTheTransform() throws {
        let text = try String(contentsOfFile: Self.sourcesRoot
            .appendingPathComponent("PhotonsCore/RenderGraph.swift").path, encoding: .utf8)
        XCTAssertTrue(text.contains("FrameTransform("),
                      "261: RenderGraph.plan must build the one FrameTransform")
        for field in ["requestedInS5", "contentInS5", "origin"] {
            XCTAssertTrue(text.contains("transform.\(field)"),
                          "261: RenderGraph.plan must read FrameTransform.\(field)")
        }
    }
}
