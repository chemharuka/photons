import XCTest
import AppKit
import CoreImage
import Metal
import PhotonsCatalog
import PhotonsCore
import PhotonsExport
@testable import PhotonsUI

/// 241 — the HD thumbnail must reach the grid, the browser list and the filmstrip **upright**.
///
/// The fixture is four quadrants the eye (and a test) cannot confuse:
/// TL red, TR green, BL blue, BR white. It goes through the **same** encoder the HD producer uses
/// (`HDREncoding.write`) and is then read back through the shipped decode path.
///
/// The orientation boundary is the Core Image → Metal read-back: `CIContext.render(_:to:)` writes
/// the image with row 0 at the **bottom** (Core Image is y-up, Metal rows are y-down), so
/// `ThumbnailHDRDecoder` reverses the rows once when it builds the `CGImage`. Everything downstream
/// (the `CAMetalLayer` upload and its pass-through shader) assumes CGImage's row order: row 0 = top.
///
/// 238 removed the row flip inside `HDREncoding` (the export was upside down); that flip had been
/// cancelling this read-back flip for HD thumbnails since 227, which is why the grid only turned
/// upside down after 238 landed.
final class ThumbnailOrientationTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-thumb-orientation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - fixture

    /// A square PQ HEIC with the four quadrants: TL red, TR green, BL blue, BR white.
    private func quadrantHEIC(side: Int = 128) throws -> (url: URL, data: Data) {
        var rgba = [Float16](repeating: 0, count: side * side * 4)
        for y in 0..<side {
            for x in 0..<side {
                let top = y < side / 2
                let left = x < side / 2
                let rgb: (Float, Float, Float)
                switch (top, left) {
                case (true, true): rgb = (1, 0, 0)       // TL red
                case (true, false): rgb = (0, 1, 0)      // TR green
                case (false, true): rgb = (0, 0, 1)      // BL blue
                case (false, false): rgb = (1, 1, 1)     // BR white
                }
                let i = (y * side + x) * 4
                rgba[i] = Float16(rgb.0)
                rgba[i + 1] = Float16(rgb.1)
                rgba[i + 2] = Float16(rgb.2)
                rgba[i + 3] = 1
            }
        }
        let linear = LinearPixels(width: side, height: side, rgba: rgba, primaries: .displayP3)
        let image = DisplayImage(width: side, height: side, rgba: rgba,
                                 primaries: .displayP3, bitDepth: 16, linear: linear)
        let url = root.appendingPathComponent("quadrants.heic")
        let options = ExportOptions(format: .heic, quality: 0.75, bitDepth: 10,
                                    hdr: HDRExport(enabled: true, kind: .pq))
        try HDREncoding.write(image, to: url, options: options)
        return (url, try Data(contentsOf: url))
    }

    // MARK: - read-back helpers

    /// One pixel of a half-float RGBA image, addressed in **CGImage row order** (row 0 = top).
    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> (Float, Float, Float) {
        guard let data = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else {
            throw XCTSkip("no readable pixel buffer")
        }
        let offset = y * image.bytesPerRow + x * 8
        let halves = UnsafeRawPointer(bytes + offset).assumingMemoryBound(to: UInt16.self)
        return (Float(Float16(bitPattern: halves[0])),
                Float(Float16(bitPattern: halves[1])),
                Float(Float16(bitPattern: halves[2])))
    }

    /// One pixel of a rendered `rgba16Float` texture (row 0 = top of the drawable).
    private func pixel(_ texture: MTLTexture, x: Int, y: Int) -> (Float, Float, Float) {
        var half = [UInt16](repeating: 0, count: 4)
        half.withUnsafeMutableBytes { buffer in
            texture.getBytes(buffer.baseAddress!, bytesPerRow: 8,
                             from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
        }
        return (Float(Float16(bitPattern: half[0])),
                Float(Float16(bitPattern: half[1])),
                Float(Float16(bitPattern: half[2])))
    }

    private func assertUpright(_ sample: (Int, Int) throws -> (Float, Float, Float),
                               width: Int, height: Int,
                               _ label: String,
                               file: StaticString = #filePath, line: UInt = #line) throws {
        let tl = try sample(width / 4, height / 4)
        let tr = try sample(width * 3 / 4, height / 4)
        let bl = try sample(width / 4, height * 3 / 4)
        let br = try sample(width * 3 / 4, height * 3 / 4)
        print("241 \(label): TL \(tl) TR \(tr) BL \(bl) BR \(br)")

        XCTAssertGreaterThan(tl.0, 0.5, "\(label): TL must be red", file: file, line: line)
        XCTAssertLessThan(tl.1, 0.3, "\(label): TL must not be green", file: file, line: line)
        XCTAssertLessThan(tl.2, 0.3, "\(label): TL must not be blue", file: file, line: line)

        XCTAssertGreaterThan(tr.1, 0.5, "\(label): TR must be green", file: file, line: line)
        XCTAssertLessThan(tr.0, 0.3, "\(label): TR must not be red", file: file, line: line)
        XCTAssertLessThan(tr.2, 0.3, "\(label): TR must not be blue", file: file, line: line)

        XCTAssertGreaterThan(bl.2, 0.5, "\(label): BL must be blue", file: file, line: line)
        XCTAssertLessThan(bl.0, 0.3, "\(label): BL must not be red", file: file, line: line)
        XCTAssertLessThan(bl.1, 0.3, "\(label): BL must not be green", file: file, line: line)

        XCTAssertGreaterThan(br.0, 0.6, "\(label): BR must be white", file: file, line: line)
        XCTAssertGreaterThan(br.1, 0.6, "\(label): BR must be white", file: file, line: line)
        XCTAssertGreaterThan(br.2, 0.6, "\(label): BR must be white", file: file, line: line)
    }

    // MARK: - 1. decode path

    /// The `CGImage` handed to the cell must be top-row-first. If the row reversal in
    /// `ThumbnailHDRDecoder.makeCGImage` is removed, TL reads blue and BR reads white: this goes red.
    func testHDDecodeReturnsTopRowFirstPixels() throws {
        let fixture = try quadrantHEIC()
        let side = 128
        let image = try XCTUnwrap(ThumbnailProvider.decodeHD(
            fixture.data, display: ImageSize(width: side, height: side)))
        try assertUpright({ try self.pixel(image, x: $0, y: $1) },
                          width: side, height: side, "decodeHD")
    }

    /// **Reverse gate.** The texture read-back and Core Image's own `createCGImage` must agree.
    /// Re-introducing the old behaviour (no row reversal after `render(to:)`) flips one of them and
    /// this assertion fails, without needing to read the implementation.
    func testTextureReadbackAgreesWithCoreImageReference() throws {
        let fixture = try quadrantHEIC()
        let side = 128
        let extP3 = try XCTUnwrap(CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3))
        let source = try XCTUnwrap(ThumbnailHDRDecoder.sourceImage(fixture.data))
        let context = CIContext(options: [.workingColorSpace: extP3,
                                          .workingFormat: CIFormat.RGBAh,
                                          .outputColorSpace: extP3])
        let reference = try XCTUnwrap(context.createCGImage(
            source, from: source.extent, format: .RGBAh, colorSpace: extP3))

        let decoded = try XCTUnwrap(ThumbnailProvider.decodeHD(
            fixture.data, display: ImageSize(width: side, height: side)))
        for (x, y) in [(side / 4, side / 4), (side * 3 / 4, side / 4),
                       (side / 4, side * 3 / 4), (side * 3 / 4, side * 3 / 4)] {
            let a = try pixel(decoded, x: x, y: y)
            let b = try pixel(reference, x: x, y: y)
            XCTAssertEqual(a.0, b.0, accuracy: 0.2, "read-back vs createCGImage R at \(x),\(y)")
            XCTAssertEqual(a.1, b.1, accuracy: 0.2, "read-back vs createCGImage G at \(x),\(y)")
            XCTAssertEqual(a.2, b.2, accuracy: 0.2, "read-back vs createCGImage B at \(x),\(y)")
        }
    }

    // MARK: - 2. the three views

    /// Grid cell, browser-list row and filmstrip cell each get the same payload at their own
    /// display pixels; all three must show the same upright quadrants.
    @MainActor
    func testGridListAndFilmstripAllShowUprightQuadrants() throws {
        guard ThumbnailMetalRenderer.shared.isAvailable else {
            throw XCTSkip("no Metal device")
        }
        let fixture = try quadrantHEIC()
        let sizes = [ImageSize(width: 326, height: 242),   // grid
                     ImageSize(width: 68, height: 68),     // browser list
                     ImageSize(width: 180, height: 120)]   // filmstrip (90×60 pt @2×)
        let labels = ["grid", "list", "filmstrip"]

        for (size, label) in zip(sizes, labels) {
            let image = try XCTUnwrap(ThumbnailProvider.decodeHD(fixture.data, display: size))
            let view = ThumbnailEDRView(cornerRadius: 0)
            view.frame = NSRect(x: 0, y: 0, width: size.width, height: size.height)
            view.image = image
            view.layoutSubtreeIfNeeded()
            let texture = try XCTUnwrap(view.renderForTesting(width: size.width, height: size.height),
                                        "\(label) produced a texture")
            try assertUpright({ self.pixel(texture, x: $0, y: $1) },
                              width: size.width, height: size.height, label)
        }
    }

    // MARK: - 3. old cache

    /// §3.3 — files written before this fix can be upside down. The key version moves, so every one
    /// of them is unreachable (the LRU reclaims it) instead of being served under a new build.
    func testCacheKeyVersionInvalidatesPreFixHDFiles() {
        let key = ThumbKey.hd(contentHash: "abc", document: .neutral)
        XCTAssertEqual(ThumbSpec.hd.schemaVersion, 2)
        XCTAssertTrue(key.keyString.contains("sv2"))
        XCTAssertFalse(key.keyString.contains("sv1"))
    }
}
