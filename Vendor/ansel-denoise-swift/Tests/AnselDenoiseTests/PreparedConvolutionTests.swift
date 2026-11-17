import XCTest
import Metal
@testable import AnselDenoise

final class PreparedConvolutionTests: XCTestCase {
    func testPreparedWeightsMatchOriginalConvolutionAcrossShapes() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let metal = try MetalConv()
        for (kind, kernel) in [(MetalConv.ConvKind.same3x3, 3), (.point1x1, 1), (.down2x2, 2)] {
            let weights = AnselWeights(name: "test", shape: [3, 2, kernel, kernel],
                values: (0..<(6 * kernel * kernel)).map { Float($0 % 7 - 3) * 0.01 })
            let bias: [Float] = [0.1, -0.05, 0.2]
            let prepared = try metal.prepare(w: weights, b: bias)
            for edge in [16, 32] {
                let values = (0..<(edge * edge * 2)).map { Float($0 % 31) / 31 }
                let input = try metal.makeTensor(width: edge, height: edge, channels: 2, from: values)
                let cmd = try XCTUnwrap(metal.queue.makeCommandBuffer())
                let reference = try metal.conv(input, w: weights, b: bias, kind: kind, cmd: cmd)
                let cached = try metal.conv(input, prepared: prepared, kind: kind, cmd: cmd)
                cmd.commit(); cmd.waitUntilCompleted()
                XCTAssertNil(cmd.error)
                XCTAssertEqual(metal.read(reference), metal.read(cached), "packing must preserve every output bit")
            }
        }
    }

    func testFullModelReusesWeightsForEveryTile() throws {
        guard let url = AnselDenoiseTests.modelURL else { throw XCTSkip("model unavailable") }
        let model = try AnselDenoiseModel(contentsOf: url)
        let gpu = try AnselDenoiseMetal(model: model)
        let mosaic = (0..<(64 * 64)).map { Float($0 % 97) / 194 }
        func render(_ engine: AnselDenoiseMetal) throws -> [Float] {
            try engine.denoise(mosaic: mosaic, width: 64, height: 64, cfa: "rggb",
                a: [0.0012, 0.0008, 0.0016], b: [0.00008, 0.00006, 0.00010])
        }
        let first = try render(gpu)
        let count = gpu.preparedLayerCount
        XCTAssertEqual(count, model.tensorInfos.filter { $0.name.hasSuffix(".weight") }.count)
        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<5 {
            XCTAssertEqual(try render(gpu), first)
            XCTAssertEqual(gpu.preparedLayerCount, count)
        }
        print("DENOISE weight cache: \(count) packed layers reused across 5 tiles; \((CFAbsoluteTimeGetCurrent() - start) * 1000) ms")
        let other = try AnselDenoiseMetal(model: model)
        XCTAssertEqual(try render(other), first)
    }
}
