import XCTest
import Metal
import simd
@testable import PhotonsCore
@testable import PhotonsUI

/// 544 — the panel's headroom is a **present-time bound**, not an S4 exit clamp.
///
/// Before this task S4 wrote `encode(min(v, headroom))`, so the canvas texture was both display
/// encoded *and* clipped at whatever the screen happened to report. A one-ulp headroom drift made
/// `CanvasFrameCache` refuse its own entry (`entry.value.headroom.bitPattern == requestedHeadroom`),
/// and the cache was cleared on every `setDisplayHeadroom`. The fix moves the `min` into
/// `present.metal` — after the inverse OETF, where the value is linear again — and leaves the
/// texture as a property of the picture.
///
/// What this file holds, in order:
///
///   1. **Pixel equivalence**: the old pipeline (`S4 clamp → OETF → present decode`) and the new one
///      (`S4 up to the ceiling → OETF → present decode → min`) write the same final linear values,
///      ≤ 1 half-float ULP apart, on the same high-light fixture.
///   2. **Cache/display decoupling**: two photos, twenty returns, ±1 ulp of headroom each time —
///      `count` stays 2, `hits` grows, and no lookup is attributed to `.displayChanged`.
///   3. **A real change applies immediately**: 1.0 → 1.5 re-presents the *same* texture and the
///      highlights above 1.0 reappear, without the cache losing a row. This is the reverse gate for
///      the `min` in `present_transfer`: delete it and the 1.0 pass already shows > 1.
///   4. **The SDR fallback is untouched**: bgra8 still clamps encoded values at 1, byte for byte.
final class HeadroomClampAtPresent544Tests: XCTestCase {

    private let liveHeadroom = 1.5

    // MARK: - ① old vs new, on the same high-light fixture

    func testScreenFinalLinearValuesArePixelIdenticalToThePre544Pipeline() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
        let presenter = try CanvasPresenter(device: device)
        let fixture = try highLightFixture(device, width: 64, height: 16)

        let old = try renderS4(device, source: fixture, presentationExit: false,
                               headroom: liveHeadroom, oldKernel: true)
        let new = try renderS4(device, source: fixture, presentationExit: true,
                               headroom: liveHeadroom, oldKernel: false)
        XCTAssertNotEqual(Self.hash(old), Self.hash(new),
                          "the S4 textures must differ — otherwise this test proves nothing")

        let oldFinal = try present(device, presenter, old, headroom: .infinity)
        let newFinal = try present(device, presenter, new, headroom: liveHeadroom)

        let bound = Float(Float16(liveHeadroom))
        var maximum = 0.0
        var unclampedDifferences = 0
        var clampedOffHeadroom = 0
        var clampedPixels = 0
        for index in stride(from: 0, to: oldFinal.count, by: 4) {
            for c in 0..<3 {
                let a = oldFinal[index + c]
                let b = newFinal[index + c]
                maximum = max(maximum, abs(Double(a) - Double(b)))
                if b >= bound {
                    // Above the live reading: the new pass stops exactly at the reading.
                    clampedPixels += 1
                    if b != bound { clampedOffHeadroom += 1 }
                    if a > b + Float.ulpOfOne { clampedOffHeadroom += 1 }
                } else if a != b {
                    // At or below it: old and new must be the same bits.
                    unclampedDifferences += 1
                }
            }
        }
        print(String(format: "[544] pixel equivalence: max |old − new| = %.9f at the clamp "
                     + "(%.3f half-ULP); %d clamped samples sit at %.4f; %d unclamped samples differ",
                     maximum, maximum / Self.halfULP(at: liveHeadroom), clampedPixels,
                     Double(bound), unclampedDifferences))
        XCTAssertEqual(unclampedDifferences, 0,
                       "every pixel at or below headroom must be bit-identical; "
                       + "\(unclampedDifferences) moved")
        XCTAssertEqual(clampedOffHeadroom, 0,
                       "every pixel above headroom must land exactly on the live reading "
                       + "(\(clampedOffHeadroom) did not)")
        XCTAssertGreaterThan(clampedPixels, 0, "the fixture must reach above headroom")
    }

    // MARK: - ② two photos, twenty returns, headroom drift ±1 ulp

    func testHeadroomDriftKeepsBothEntriesAndKeepsHitting() throws {
        let cache = try emptyCache()
        let a = try key(photo: "544-drift-a")
        let b = try key(photo: "544-drift-b")
        XCTAssertTrue(cache.store(try dummyFrame(), key: a))
        XCTAssertTrue(cache.store(try dummyFrame(), key: b))
        XCTAssertEqual(cache.count, 2)

        let hitsBefore = cache.hits
        let missesBefore = cache.misses
        let displayMissesBefore = cache.missReasons[.displayChanged]
        var counts: [Int] = []

        for turn in 0..<20 {
            let photo = turn % 2 == 0 ? a : b
            // Deterministic ±1-ulp drift, the way a live screen reading moves between two polls.
            let headroom = turn % 3 == 0 ? Double(1).nextUp : Double(1).nextDown
            XCTAssertNotNil(cache.lookup(photo, headroom: headroom,
                                         primaries: .displayP3, decodeScale: 1),
                            "turn \(turn): headroom \(headroom) must be the same canvas")
            counts.append(cache.count)
        }

        XCTAssertEqual(Set(counts), [2], "the table must stay at two rows for all twenty returns")
        XCTAssertEqual(cache.hits, hitsBefore + 20, "every return must be a hit")
        XCTAssertEqual(cache.misses, missesBefore, "no lookup may miss on a headroom drift")
        XCTAssertEqual(cache.missReasons[.displayChanged], displayMissesBefore,
                       "a headroom drift is not a display miss (the old code cleared the table)")
        print("[544] cache drift: count \(cache.count) · hits +\(cache.hits - hitsBefore) "
              + "· misses +\(cache.misses - missesBefore) · displayChanged +"
              + "\(cache.missReasons[.displayChanged] - displayMissesBefore)")
    }

    // MARK: - ③ the live reading takes effect without throwing the entry away

    func testARealHeadroomChangeAppliesOnTheNextPresentWithoutClearingTheCache() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
        let presenter = try CanvasPresenter(device: device)
        let fixture = try highLightFixture(device, width: 64, height: 16)
        // The picture as the canvas cache stores it: S4's presentation exit, no panel clamp.
        let texture = try renderS4(device, source: fixture, presentationExit: true,
                                   headroom: liveHeadroom, oldKernel: false)

        let reference = try present(device, presenter, texture, headroom: .infinity)
        var overOne = 0
        for pixel in 0..<(fixture.width * fixture.height) {
            if (0..<3).contains(where: { Double(reference[pixel * 4 + $0]) > 1.0 }) { overOne += 1 }
        }
        XCTAssertGreaterThan(overOne, 0, "the fixture must carry highlights above 1.0")

        let clamped = try present(device, presenter, texture, headroom: 1.0)
        var overOneAtOne = 0
        for pixel in 0..<(fixture.width * fixture.height) {
            if (0..<3).contains(where: { Double(clamped[pixel * 4 + $0]) > 1.0 }) { overOneAtOne += 1 }
        }
        XCTAssertEqual(overOneAtOne, 0,
                       "headroom 1.0 must clamp every highlight to 1.0 — if present has no `min`, "
                       + "this is already \(overOneAtOne)")

        let brightened = try present(device, presenter, texture, headroom: liveHeadroom)
        var overOneAtFifteen = 0
        for pixel in 0..<(fixture.width * fixture.height) {
            if (0..<3).contains(where: { Double(brightened[pixel * 4 + $0]) > 1.0 }) {
                overOneAtFifteen += 1
            }
        }
        XCTAssertEqual(overOneAtFifteen, overOne,
                       "headroom 1.5 must bring back exactly the fixture's >1.0 pixels")

        // The same texture, the same cache rows: only the present-time reading moved.
        let cache = try emptyCache()
        XCTAssertTrue(cache.store(try dummyFrame(headroom: 1.0), key: try key(photo: "544-live-a")))
        XCTAssertTrue(cache.store(try dummyFrame(headroom: 1.0), key: try key(photo: "544-live-b")))
        let countBefore = cache.count
        let hitsBefore = cache.hits
        XCTAssertNotNil(cache.lookup(try key(photo: "544-live-a"), headroom: 1.0,
                                     primaries: .displayP3, decodeScale: 1))
        XCTAssertNotNil(cache.lookup(try key(photo: "544-live-a"), headroom: liveHeadroom,
                                     primaries: .displayP3, decodeScale: 1))
        XCTAssertEqual(cache.count, countBefore, "1.0 → 1.5 must not clear or replace a row")
        XCTAssertEqual(cache.hits, hitsBefore + 2)

        print("[544] live change: >1.0 pixels 1.0 → \(overOneAtOne) · 1.5 → \(overOneAtFifteen) "
              + "(reference \(overOne)) · cache count \(cache.count)")
    }

    // MARK: - ④ bgra8 fallback: clamp at 1, byte-identical

    func testSDRFallbackStillClampsAtOneAndMatchesPre544() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
        let presenter = try CanvasPresenter(device: device)
        let fixture = try highLightFixture(device, width: 64, height: 16)
        let old = try renderS4(device, source: fixture, presentationExit: false,
                               headroom: liveHeadroom, oldKernel: true)
        let new = try renderS4(device, source: fixture, presentationExit: true,
                               headroom: liveHeadroom, oldKernel: false)
        let old8 = try presentSDR(device, presenter, old)
        let new8 = try presentSDR(device, presenter, new)
        XCTAssertEqual(old8, new8, "the bgra8 fallback must not move when the clamp moves")

        var brightest = 0
        for i in stride(from: 0, to: new8.count, by: 4) {
            brightest = max(brightest, Int(new8[i]), Int(new8[i + 1]), Int(new8[i + 2]))
        }
        XCTAssertLessThanOrEqual(brightest, 255)
        XCTAssertEqual(brightest, 255,
                       "the high-light fixture must reach SDR white, so the clamp is load-bearing")
        print("[544] SDR fallback: \(old8.count / 4) pixels byte-identical · max code \(brightest)")
    }

    // MARK: - ⑤ the canvas exit, end to end: the flag reaches S4

    func testACanvasRenderLeavesTheHeadroomToThePresenter() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
        let presenter = try CanvasPresenter(device: device)
        let size = ImageSize(width: 64, height: 16)
        var rgba = [Float16](repeating: 0, count: size.width * size.height * 4)
        for pixel in 0..<(size.width * size.height) {
            let v = Float16(4.0)
            rgba[pixel * 4] = v; rgba[pixel * 4 + 1] = v; rgba[pixel * 4 + 2] = v
            rgba[pixel * 4 + 3] = 1
        }
        let image = LinearImage(width: size.width, height: size.height, rgba: rgba,
                                colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic")
        let graph = try RenderGraph(input: RenderInput(image: image, identity: "544-canvas-exit"))

        // A presentation render: canvas-sized, no CPU pixels → 544's flag says "present will clamp".
        var document = EditModel.neutral
        document.light.exposure = 1
        let result = try graph.render(document, options: RenderOptions(
            canvas: size, scale: 1,
            display: DisplayOptions(primaries: .sRGB, bitDepth: 16, headroom: 1,
                                    highlightCeiling: 16),
            useCache: false, wantsPixels: false))
        let output = try XCTUnwrap(result.output)
        defer { graph.recycle(output: output) }
        let encoded = Self.readRGBA16(output)
        let encodedPeak = encoded.max() ?? 0
        XCTAssertGreaterThan(encodedPeak, 1.0,
                             "a canvas frame rendered at headroom 1 must still carry >1.0 encoded "
                             + "when the picture does — otherwise S4 clamped it early")

        let atOne = try present(device, presenter, output, headroom: 1.0)
        let atFour = try present(device, presenter, output, headroom: 4.0)
        XCTAssertLessThanOrEqual(atOne.max() ?? 0, 1.0 + Float.ulpOfOne,
                                 "the presenter's live headroom 1.0 must bound the frame")
        XCTAssertGreaterThan(atFour.max() ?? 0, 1.0,
                             "the same texture at headroom 4.0 must show the highlights")
        print("[544] canvas exit: S4 encoded peak "
              + String(format: "%.4f", encodedPeak)
              + " · present 1.0 → \(atOne.max() ?? 0) · 4.0 → \(atFour.max() ?? 0)")
    }

    // MARK: - S4 fixtures

    /// One high-light ramp: two SDR blocks, then four above 1.0 (1.2, 2.0, 3.0, 4.0). Equal blocks so
    /// a pixel count is a block.
    private func highLightFixture(_ device: MTLDevice, width: Int, height: Int) throws -> MTLTexture {
        let values: [Float] = [0.02, 0.5, 0.9, 1.2, 2.0, 3.0, 4.0]
        let texture = try makeTexture(device, width, height, .rgba16Float, [.shaderRead])
        var row = [UInt16](repeating: 0, count: width * 4)
        for x in 0..<width {
            let block = min(values.count - 1, x * values.count / width)
            let v = Float16(values[block])
            row[x * 4] = v.bitPattern
            row[x * 4 + 1] = v.bitPattern
            row[x * 4 + 2] = v.bitPattern
            row[x * 4 + 3] = Float16(1).bitPattern
        }
        for y in 0..<height {
            row.withUnsafeBytes {
                texture.replace(region: MTLRegionMake2D(0, y, width, 1), mipmapLevel: 0,
                                withBytes: $0.baseAddress!, bytesPerRow: width * 8)
            }
        }
        return texture
    }

    /// The shipped `s4_display` (new) or an inline copy of its pre-544 body (old), identity matrix.
    private func renderS4(_ device: MTLDevice, source: MTLTexture, presentationExit: Bool,
                          headroom: Double, oldKernel: Bool) throws -> MTLTexture {
        let library: MTLLibrary
        let functionName: String
        if oldKernel {
            library = try device.makeLibrary(source: Self.pre544S4Source, options: nil)
            functionName = "s4_display_pre544"
        } else {
            let url = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/PhotonsCore/Kernels/s4_display.metal")
            library = try device.makeLibrary(source: String(contentsOf: url, encoding: .utf8),
                                             options: nil)
            functionName = "s4_display"
        }
        let pipeline = try device.makeComputePipelineState(
            function: try XCTUnwrap(library.makeFunction(name: functionName)))
        let output = try makeTexture(device, source.width, source.height, .rgba16Float,
                                     [.shaderRead, .shaderWrite])
        var params = ScratchDisplayParams(
            m: matrix_identity_float4x4,
            a: SIMD4<Float>(1, Float(headroom), 0, presentationExit ? 1 : 0))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let buffer = try XCTUnwrap(queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(buffer.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(output, index: 1)
        encoder.setBytes(&params, length: MemoryLayout<ScratchDisplayParams>.stride, index: 0)
        let threads = MTLSize(width: source.width, height: source.height, depth: 1)
        encoder.dispatchThreads(threads, threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
        encoder.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
        XCTAssertNil(buffer.error)
        return output
    }

    private struct ScratchDisplayParams {
        var m: simd_float4x4
        var a: SIMD4<Float>
    }

    /// `s4_display` exactly as it stood before 544: matrix → ceiling → `min(v, headroom)` → OETF.
    private static let pre544S4Source = """
    #include <metal_stdlib>
    using namespace metal;
    struct P544 { float4x4 m; float4 a; };
    static inline float srgb_encode544(float v) {
        return v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1.0 / 2.4) - 0.055;
    }
    kernel void s4_display_pre544(texture2d<float, access::read> src [[texture(0)]],
                                  texture2d<float, access::write> dst [[texture(1)]],
                                  constant P544 &p [[buffer(0)]],
                                  uint2 gid [[thread_position_in_grid]]) {
        float4 c = src.read(gid);
        float3 v = max(c.rgb, 0.0);
        if (p.a.x < 0.5) { v = (p.m * float4(v, 0.0)).xyz; }
        v = max(v, 0.0);
        if (p.a.z > 0.0) { v = min(v, p.a.z); }
        v = min(v, max(p.a.y, 0.0));
        dst.write(float4(srgb_encode544(v.x), srgb_encode544(v.y), srgb_encode544(v.z), 1.0), gid);
    }
    """

    // MARK: - present helpers

    private func present(_ device: MTLDevice, _ presenter: CanvasPresenter, _ texture: MTLTexture,
                         headroom: Double) throws -> [Float] {
        let target = try makeTexture(device, texture.width, texture.height, .rgba16Float,
                                     [.shaderRead, .renderTarget])
        let request = PresentRequest(
            picture: texture,
            photoRect: ImageRect(x: 0, y: 0, width: texture.width, height: texture.height),
            window: .whole, canvas: ImageSize(width: texture.width, height: texture.height))
        XCTAssertTrue(presenter.render(request, into: target, linearize: true, headroom: headroom),
                      presenter.lastFailure ?? "present failed")
        return Self.readRGBA16(target)
    }

    private func presentSDR(_ device: MTLDevice, _ presenter: CanvasPresenter,
                            _ texture: MTLTexture) throws -> [UInt8] {
        let target = try makeTexture(device, texture.width, texture.height, .bgra8Unorm,
                                     [.shaderRead, .renderTarget])
        let request = PresentRequest(
            picture: texture,
            photoRect: ImageRect(x: 0, y: 0, width: texture.width, height: texture.height),
            window: .whole, canvas: ImageSize(width: texture.width, height: texture.height))
        // The live reading is deliberately > 1: the SDR branch must ignore it and keep `min(v, 1)`.
        XCTAssertTrue(presenter.render(request, into: target, linearize: false, headroom: 1.5),
                      presenter.lastFailure ?? "present failed")
        return Self.readBytes(target)
    }

    // MARK: - cache fixtures

    private func emptyCache() throws -> CanvasFrameCache {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        CanvasFrameCache.browsingCapacity = 10
        CanvasFrameCache.editingCapacity = 3
        return CanvasFrameCache()
    }

    private func key(photo: String) throws -> CanvasFrameCache.Key {
        CanvasFrameCache.Key(photo: photo, decodeInputs: "d", editDigest: "digest",
                             geometry: "", cameraState: "fit",
                             viewport: ImageSize(width: 64, height: 16), mode: "edited",
                             fitScale: 0.9, canvasRole: "document", cropIsActive: false,
                             highlightWarning: false, headroom: 1)
    }

    private func dummyFrame(headroom: Double = 1) throws -> LoupeController.FrameResult {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let size = ImageSize(width: 16, height: 16)
        let texture = try makeTexture(device, size.width, size.height, .rgba16Float, [.shaderRead])
        let rect = ImageRect(x: 0, y: 0, width: size.width, height: size.height)
        return LoupeController.FrameResult(
            texture: texture, canvas: size, content: size, photoRect: rect, presentRect: rect,
            outputWindow: nil, decodeScale: 1, decodeMilliseconds: 0, renderMilliseconds: 0,
            usedCachedDecode: true, capabilities: nil, primaries: .displayP3,
            editRevision: 0, edit: .neutral, displayHash: nil, zoom: 1, headroom: headroom,
            window: size, clipped: nil, sceneLinearSample: nil, mode: .edited,
            trace: RenderTrace(), whiteBalanceGain: SIMD3<Double>(1, 1, 1),
            frameInCanvas: size, frameOrigin: SIMD2<Float>(0, 0), expandedCanvas: nil,
            neverUpscalesContent: false)
    }

    // MARK: - texture helpers

    private func makeTexture(_ device: MTLDevice, _ width: Int, _ height: Int,
                             _ format: MTLPixelFormat, _ usage: MTLTextureUsage) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: width, height: height, mipmapped: false)
        descriptor.usage = usage
        descriptor.storageMode = .shared
        return try XCTUnwrap(device.makeTexture(descriptor: descriptor))
    }

    private static func readRGBA16(_ texture: MTLTexture) -> [Float] {
        var raw = [UInt16](repeating: 0, count: texture.width * texture.height * 4)
        raw.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!, bytesPerRow: texture.width * 8,
                             from: MTLRegionMake2D(0, 0, texture.width, texture.height),
                             mipmapLevel: 0)
        }
        return raw.map { Float(Float16(bitPattern: $0)) }
    }

    private static func readBytes(_ texture: MTLTexture) -> [UInt8] {
        let bytesPerRow = texture.width * 4
        var raw = [UInt8](repeating: 0, count: bytesPerRow * texture.height)
        raw.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!, bytesPerRow: bytesPerRow,
                             from: MTLRegionMake2D(0, 0, texture.width, texture.height),
                             mipmapLevel: 0)
        }
        return raw
    }

    private static func hash(_ texture: MTLTexture) -> [UInt16] {
        var raw = [UInt16](repeating: 0, count: texture.width * texture.height * 4)
        raw.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!, bytesPerRow: texture.width * 8,
                             from: MTLRegionMake2D(0, 0, texture.width, texture.height),
                             mipmapLevel: 0)
        }
        return raw
    }

    /// The spacing of a half float at `value` — the precision the readback texture actually carries.
    private static func halfULP(at value: Double) -> Double {
        let v = Float16(Float(max(value, 0)))
        let next = Float16(v).nextUp
        return max(Double(next) - Double(v), Double.leastNormalMagnitude)
    }
}
