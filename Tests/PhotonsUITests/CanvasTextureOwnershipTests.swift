import XCTest
import Metal
import PhotonsCore
@testable import PhotonsUI

/// 440 — 「这张纹理归谁」是 `OwnedCanvasTexture.owner` 的一个事实，不是调用方的一个 `if`。
///
/// Three things are asserted here, each about a number the pool can report:
///
///   ① a `.cacheCopy` is refused (the pool counters do not move, `refusedRecycles` +1) — this is
///      438's black canvas, now impossible to express by accident;
///   ② a `.graph(g)` really returns to **that** graph's idle list;
///   ③ a synchronously rendered frame says `.graph`, and after `present` the graph has recycled
///      nothing foreign (438's invariant).
@MainActor
final class CanvasTextureOwnershipTests: XCTestCase {

    private let canvas = ImageSize(width: 64, height: 64)

    /// `recycle(on:)` hops onto the render queue (the pool's idle table has no lock and belongs
    /// there), so a test that asserts on pool counters must drain that queue first.
    private let poolQueue = DispatchQueue(label: "photons.test.owned-canvas")

    private func metal() throws -> MTLDevice {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        return device
    }

    private func texture(_ device: MTLDevice) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: canvas.width, height: canvas.height, mipmapped: false)
        descriptor.usage = [.shaderRead, .renderTarget]
        descriptor.storageMode = .private
        return try XCTUnwrap(device.makeTexture(descriptor: descriptor))
    }

    private func graph(_ device: MTLDevice) throws -> RenderGraph {
        var rgba = [Float16](repeating: Float16(0.5), count: canvas.width * canvas.height * 4)
        for i in stride(from: 3, to: rgba.count, by: 4) { rgba[i] = 1 }
        let image = LinearImage(width: canvas.width, height: canvas.height, rgba: rgba,
                                colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic")
        return try RenderGraph(input: RenderInput(image: image, identity: "ownership-440"))
    }

    private func options() -> RenderOptions {
        RenderOptions(canvas: canvas, scale: 1,
                      display: DisplayOptions(primaries: .displayP3, bitDepth: 8, headroom: 1),
                      useCache: false, wantsPixels: false)
    }

    // MARK: - ① cache copy is refused

    func testCacheCopyRecycleLeavesThePoolAloneAndIsCounted() throws {
        let device = try metal()
        let graph = try graph(device)
        let texture = try texture(device)
        let idle = graph.idleTextureCount
        let reuses = graph.textureReuses
        let refused = OwnedCanvasTexture.refusedRecycles

        OwnedCanvasTexture(texture: texture, owner: .cacheCopy).recycle(on: poolQueue)
        poolQueue.sync {}

        XCTAssertEqual(graph.idleTextureCount, idle, "a cache copy must not enter a pool")
        XCTAssertEqual(graph.textureReuses, reuses)
        XCTAssertEqual(OwnedCanvasTexture.refusedRecycles, refused + 1)
        XCTAssertEqual(graph.foreignTextureRecycles, 0)
    }

    // MARK: - ② graph-owned recycle returns to its pool

    func testGraphOwnedRecycleReturnsToItsPool() throws {
        let device = try metal()
        let graph = try graph(device)
        let result = try graph.render(.neutral, options: options())
        let texture = try XCTUnwrap(result.output)
        // The pool keeps at most two canvases; start from an empty idle list so the assertion is
        // about this recycle and not about the budget evicting an older texture.
        graph.releaseIdleTextures()
        let idle = graph.idleTextureCount

        let owned = OwnedCanvasTexture(texture: texture, owner: .graph(graph))
        XCTAssertTrue(owned.isGraphOwned)
        owned.recycle(on: poolQueue)
        poolQueue.sync {}

        XCTAssertEqual(graph.idleTextureCount, idle + 1)
        XCTAssertEqual(graph.foreignTextureRecycles, 0)
    }

    // MARK: - ③ a rendered frame says .graph; present never hands a foreign texture back

    func testSynchronousFrameIsGraphOwnedAndPresentIsForeignFree() throws {
        let url = try rawFixture()
        let loupe = LoupeController(session: CatalogSession())
        loupe.autoRenderEnabled = false
        _ = loupe.view

        let frame = try loupe.makeFrame(url: url, viewport: canvas, decodeScale: 0.5,
                                        edit: .neutral, state: .fit)
        guard case .graph(let graph) = frame.owner else {
            return XCTFail("a synchronously rendered frame must be .graph-owned, got \(frame.owner)")
        }
        XCTAssertTrue(OwnedCanvasTexture(texture: frame.texture, owner: frame.owner).isGraphOwned)

        loupe.presentForTesting(frame)
        XCTAssertEqual(graph.foreignTextureRecycles, 0,
                       "present must never recycle a texture the graph did not issue")
    }

    private func rawFixture() throws -> URL {
        if let env = ProcessInfo.processInfo.environment["PHOTONS_TEST_RAW"], !env.isEmpty {
            let url = URL(fileURLWithPath: NSString(string: env).expandingTildeInPath)
            if FileManager.default.isReadableFile(atPath: url.path) { return url }
        }
        let fallback = URL(fileURLWithPath: NSString(string: "~/Desktop/test/L1030433.dng")
            .expandingTildeInPath)
        guard FileManager.default.isReadableFile(atPath: fallback.path) else {
            throw XCTSkip("no RAW fixture; set PHOTONS_TEST_RAW")
        }
        return fallback
    }
}
