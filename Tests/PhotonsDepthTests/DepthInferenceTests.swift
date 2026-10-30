import CoreML
import CoreVideo
import XCTest
@testable import PhotonsDepth

/// Model-driven coverage of 120a. The xctest bundle carries no `.mlmodelc`, so these tests look for
/// a compiled model where the build scripts put it (or `PHOTONS_DEPTH_MODEL`) and `XCTSkip` when the
/// machine has none — the contract (geometry from the description, deterministic pixels) is only
/// meaningful with the real weights.
final class DepthInferenceTests: XCTestCase {
    private static let modelName = "DepthAnythingV2SmallF16"

    private func compiledModelURL() throws -> URL {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let path = ProcessInfo.processInfo.environment["PHOTONS_DEPTH_MODEL"] {
            candidates.append(URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
        }
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)
        let name = "\(Self.modelName).mlmodelc"
        candidates += [
            cwd.appendingPathComponent(".build/depth-model/\(name)"),
            cwd.appendingPathComponent(".build/debug/\(name)"),
            cwd.appendingPathComponent(".build/Photons.app/Contents/Resources/\(name)"),
        ]
        guard let url = candidates.first(where: { fm.fileExists(atPath: $0.path) }) else {
            throw XCTSkip("""
                no \(Self.modelName).mlmodelc on this machine — run scripts/depth-model.sh, or set \
                PHOTONS_DEPTH_MODEL; cache-key/ceiling tests still ran
                """)
        }
        return url
    }

    /// A small BGRA gradient — deliberately not the model's input size, so `infer` has to resize.
    private func makeGradient(width: Int, height: Int) throws -> CVPixelBuffer {
        let buffer = try PixelBufferResize.makePixelBuffer(width: width, height: height,
                                                          pixelFormat: kCVPixelFormatType_32BGRA)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = CVPixelBufferGetBaseAddress(buffer)!
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                let v = UInt8((x * 255) / max(1, width - 1))
                let o = x * 4
                row[o] = UInt8(255 - v); row[o + 1] = v; row[o + 2] = UInt8((y * 255) / max(1, height - 1))
                row[o + 3] = 255
            }
        }
        return buffer
    }

    func testModelDescribesItsOwnInputGeometry() throws {
        let url = try compiledModelURL()
        let model = try DepthModel(modelURL: url)

        // Read the same description independently: the class may not substitute a constant.
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        let raw = try MLModel(contentsOf: url, configuration: configuration)
        let description = raw.modelDescription
        let input = try XCTUnwrap(description.inputDescriptionsByName.values.first?.imageConstraint,
                                  "the shipped model is an image model")
        XCTAssertEqual(model.inputWidth, input.pixelsWide)
        XCTAssertEqual(model.inputHeight, input.pixelsHigh)
        // `DepthModel` accepts an image output (what Apple's package ships) *and* a multi-array
        // output (what our own re-exports return), so the assertion is "the output geometry travels
        // from the description either way", not "it is an image".
        let outputImage = description.outputDescriptionsByName.values.first?.imageConstraint
        let outputArray = description.outputDescriptionsByName.values.first?.multiArrayConstraint
        if let outputImage {
            XCTAssertEqual(model.outputWidth, outputImage.pixelsWide)
            XCTAssertEqual(model.outputHeight, outputImage.pixelsHigh)
        } else {
            let array = try XCTUnwrap(outputArray, "the shipped model has an image or array output")
            let shape = array.shape.map { $0.intValue }
            let layout = try XCTUnwrap(DepthModel.ArrayLayout(shape: shape))
            XCTAssertEqual(model.outputWidth, layout.width)
            XCTAssertEqual(model.outputHeight, layout.height)
        }
        XCTAssertGreaterThan(model.inputWidth, 0)
        XCTAssertGreaterThan(model.inputHeight, 0)
        // The description is not the model card's 518×396; pinning the real numbers here would make
        // a re-converted model fail a test that has nothing to do with correctness.
        XCTAssertEqual(model.inputWidth, input.pixelsWide,
                       "input width must travel from MLModelDescription, not from a literal")
    }

    func testInferenceIsDeterministic() throws {
        let url = try compiledModelURL()
        let model = try DepthModel(modelURL: url)
        let buffer = try makeGradient(width: 96, height: 64)

        let first = try model.infer(pixelBuffer: buffer)
        let second = try model.infer(pixelBuffer: buffer)
        XCTAssertEqual(first.width, second.width)
        XCTAssertEqual(first.height, second.height)
        XCTAssertEqual(first.values.count, first.width * first.height)
        XCTAssertEqual(first.values.map { $0.bitPattern }, second.values.map { $0.bitPattern },
                       "the same pixel buffer must produce the same depth map, sample for sample")
    }
}
