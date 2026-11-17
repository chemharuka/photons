import XCTest
import CoreImage
import ImageIO
import PhotonsCore
@testable import PhotonsExport

final class SocialMediaSliceTests: XCTestCase {
    func testMatchesOriginalPythonGeometryFixtures() throws {
        // Values produced by the original slicer.py, not recomputed by the Swift implementation.
        let fixtures: [(Int, Int, Double, Int, Int, Int, Int, Int)] = [
            (18344,11638,68.6,3,6174,3917,1413,41), (21210,8706,79.5,4,9540,3916,1230,42),
            (21189,20335,68,2,4080,3916,960,42), (18279,21463,90,2,3066,3600,1467,200),
            (3000,4000,90,1,2700,3600,150,200), (6000,4000,90,2,5400,3600,300,200),
            (100,30000,90,1,12,3600,1494,200), (5001,4000,81.6,2,4896,3916,552,42)
        ]
        for (w,h,fill,count,pw,ph,x,y) in fixtures {
            var settings = SliceSettings()
            let size = ImageSize(width: w, height: h)
            settings.fill = min(90, try SliceLayout.maximumFill(size: size, settings: settings))
            XCTAssertEqual(settings.fill, fill)
            let layout = try SliceLayout.plan(size: size, settings: settings)
            XCTAssertEqual(layout.count, count)
            XCTAssertEqual(layout.photoWidth, pw); XCTAssertEqual(layout.photoHeight, ph)
            XCTAssertEqual(layout.x, x); XCTAssertEqual(layout.y, y)
        }
        for edge in SliceSettings.resolutions {
            for landscape in [false, true] {
                var settings = SliceSettings()
                settings.width = landscape ? edge : edge * 3 / 4
                settings.height = landscape ? edge * 3 / 4 : edge
                let size = ImageSize(width: 21210, height: 8706)
                settings.fill = min(90, try SliceLayout.maximumFill(size: size, settings: settings))
                let before = try SliceLayout.plan(size: size, settings: settings)
                settings.fill = 10
                let after = try SliceLayout.plan(size: size, settings: settings)
                XCTAssertEqual(before.count, after.count)
                XCTAssertGreaterThan(before.x, 0); XCTAssertGreaterThan(before.y, 0)
                XCTAssertLessThanOrEqual(abs(before.x * 2 + before.photoWidth - before.canvasWidth), 1)
                XCTAssertLessThanOrEqual(abs(before.y * 2 + before.photoHeight - before.tileHeight), 1)
            }
        }
    }

    func testInvalidAndExcessiveGeometryIsRejected() throws {
        var settings = SliceSettings()
        // ImageSize itself normalizes zero to one; oversized sources still fail before allocation.
        XCTAssertThrowsError(try SliceLayout.plan(size: .init(width: 800_000_001, height: 1), settings: settings))
        XCTAssertThrowsError(try SliceLayout.plan(size: .init(width: 100_000, height: 100), settings: settings))
        settings.width = 1900
        XCTAssertThrowsError(try settings.validate())
        settings = SliceSettings(); settings.fill = .nan
        XCTAssertThrowsError(try settings.validate())
        settings.fill = 98
        XCTAssertThrowsError(try SliceLayout.plan(size: .init(width: 1000, height: 1000), settings: settings))
    }

    private func frame(width: Int = 240, height: Int = 120) -> DisplayImage {
        var pixels = [Float16](repeating: 1, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                // A hotspot confined to the first tile; the last tile has no HDR pixels.
                // The central gray band and the white border must match across every slice.
                let v: Float16 = x < width / 4 && y < height / 4 ? 4 : 0.4
                let o = (y * width + x) * 4
                pixels[o] = v; pixels[o+1] = v; pixels[o+2] = v
            }
        }
        return LinearPixels(width: width, height: height, rgba: pixels, primaries: .sRGB)
            .displaySDR(bitDepth: 8, toneMap: .global)
    }

    func testReassembledTilesMatchWholeFrameInBothCompanions() throws {
        let layout = SliceLayout(count: 4, tileWidth: 60, tileHeight: 80,
                                 photoWidth: 213, photoHeight: 62, x: 13, y: 9)
        var settings = SliceSettings(); settings.resampling = .nearest
        let group = try PreparedSlices(photo: frame(width: 213, height: 62), layout: layout, settings: settings)
        for index in 0..<4 {
            let tile = try group.tile(at: index)
            for y in 0..<80 {
                for x in 0..<60 {
                    let globalX = index * 60 + x, o = (y * 60 + x) * 4
                    let inside = globalX >= 13 && globalX < 226 && y >= 9 && y < 71
                    for c in 0..<4 {
                        let source = inside ? ((y - 9) * 213 + globalX - 13) * 4 + c : 0
                        XCTAssertEqual(tile.rgba[o+c], inside ? group.photo.rgba[source] : 1)
                        XCTAssertEqual(tile.linear!.rgba[o+c], inside ? group.photo.linear!.rgba[source] : 1)
                    }
                }
            }
        }
        XCTAssertThrowsError(try group.tile(at: 4))
    }

    func testEveryResamplerPreservesHDRAndDimensions() throws {
        for method in SliceResampling.allCases {
            let image = try SlicePixels.resize(frame(), width: 121, height: 61, method: method)
            XCTAssertEqual(image.width, 121); XCTAssertEqual(image.height, 61)
            XCTAssertGreaterThan(GainMapHEIC.peak(of: try XCTUnwrap(image.linear)), 3)
            XCTAssertTrue(image.rgba.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 })
        }
    }

    func testSharpeningPrecedesTheSharedSDRProjection() throws {
        var settings = SliceSettings(); settings.resampling = .lanczosSharp
        let layout = SliceLayout(count: 3, tileWidth: 64, tileHeight: 96,
                                 photoWidth: 176, photoHeight: 88, x: 8, y: 4)
        let group = try PreparedSlices(photo: frame(), layout: layout, settings: settings)
        let linear = try XCTUnwrap(group.photo.linear)
        let expectedBase = linear.displaySDR(bitDepth: 8, toneMap: .global)
        XCTAssertEqual(group.photo.rgba, expectedBase.rgba)
        XCTAssertLessThan(group.headroom, 16, "Sharpening must not manufacture a near-zero SDR denominator")
    }

    func testHDRFilesShareMetadataWhiteAndSeamLuminanceIncludingDarkTile() throws {
        guard #available(macOS 15, *) else { throw XCTSkip("ISO gain map requires macOS 15") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("photons-slices-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("pano.jpg")
        var settings = SliceSettings()
        settings.width = 1800; settings.height = 2400; settings.fill = 75; settings.quality = 100
        settings.resampling = .bilinear
        let layout = try SliceLayout.plan(size: .init(width: 240, height: 120), settings: settings)
        let group = try PreparedSlices(photo: frame(), layout: layout, settings: settings)
        let destination = SocialMediaSliceExporter.outputDirectory(source: source)
        let files = try SocialMediaSliceExporter.write(group: group, source: source, settings: settings, to: destination)
        XCTAssertEqual(files.count, 3)
        var metadata: [String] = [], whites: [Float] = [], grays: [Float] = [], seams: [(Float, Float)] = []
        for file in files {
            let src = try XCTUnwrap(CGImageSourceCreateWithURL(file as CFURL, nil))
            let info = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any])
            XCTAssertEqual(info[kCGImagePropertyPixelWidth as String] as? Int, 1800)
            XCTAssertEqual(info[kCGImagePropertyPixelHeight as String] as? Int, 2400)
            let aux = try XCTUnwrap(CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, kCGImageAuxiliaryDataTypeISOGainMap) as? [String: Any])
            let raw = try XCTUnwrap(aux[kCGImageAuxiliaryDataInfoMetadata as String])
            let packet = try XCTUnwrap(CGImageMetadataCreateXMPData(raw as! CGImageMetadata, nil))
            metadata.append(try XCTUnwrap(String(data: packet as Data, encoding: .utf8)))
            XCTAssertEqual(try XCTUnwrap(GainMapHEIC.readHeadroom(at: file)), group.headroom, accuracy: 0.01)
            let ci = try XCTUnwrap(CIImage(contentsOf: file, options: [.expandToHDR: true]))
            whites.append(sample(ci, x: 900, y: 20))
            grays.append(sample(ci, x: 900, y: 1200))
            seams.append((sample(ci, x: 0, y: 1200), sample(ci, x: 1799, y: 1200)))
        }
        XCTAssertEqual(Set(metadata).count, 1, "Every HDR parameter must be identical, even on the dark last tile")
        for white in whites { XCTAssertEqual(white, 1, accuracy: 0.025) }
        for gray in grays { XCTAssertEqual(gray, grays[0], accuracy: 0.015) }
        for i in 0..<(seams.count - 1) { XCTAssertEqual(seams[i].1, seams[i+1].0, accuracy: 0.015) }
        let manifest = try JSONDecoder().decode(SliceManifest.self, from: Data(contentsOf: destination.appendingPathComponent("slices.json")))
        XCTAssertEqual(manifest.hdr?.headroom, group.headroom)
        XCTAssertEqual(manifest.hdr?.referenceWhite, 1)
        XCTAssertEqual(manifest.hdr?.halfSize, false)
    }

    private func sample(_ image: CIImage, x: Int, y: Int) -> Float {
        var pixel = [Float](repeating: 0, count: 4)
        CIContext().render(image, toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x: x, y: y, width: 1, height: 1),
                           format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
        return pixel[0]
    }

    func testSDRReplacementPreservesOtherFilesAndCancellationKeepsPreviousGroup() throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("photons-slices-\(UUID())")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }
        let source = directory.appendingPathComponent("pano.jpg")
        let sourceData = Data("source remains untouched".utf8)
        try sourceData.write(to: source)
        var settings = SliceSettings()
        settings.dynamicRange = .sdr; settings.width = 1800; settings.height = 2400; settings.fill = 75; settings.resampling = .bilinear
        let destination = SocialMediaSliceExporter.outputDirectory(source: source)
        func group(_ settings: SliceSettings) throws -> PreparedSlices {
            try PreparedSlices(photo: frame(), layout: SliceLayout.plan(size: .init(width: 240, height: 120), settings: settings), settings: settings)
        }
        let first = try group(settings)
        let files = try SocialMediaSliceExporter.write(group: first, source: source, settings: settings, to: destination)
        let io = try XCTUnwrap(CGImageSourceCreateWithURL(files[0] as CFURL, nil))
        if #available(macOS 15, *) {
            XCTAssertNil(CGImageSourceCopyAuxiliaryDataInfoAtIndex(io, 0, kCGImageAuxiliaryDataTypeISOGainMap))
        }
        let keep = destination.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: keep)
        // A previous Python manifest with a path-traversal entry cannot delete outside the group.
        try JSONSerialization.data(withJSONObject: ["files": files.map(\.lastPathComponent) + ["../pano.jpg"]])
            .write(to: destination.appendingPathComponent("slices.json"))
        settings.width = 2400; settings.height = 1800; settings.fill = 70
        let second = try group(settings)
        _ = try SocialMediaSliceExporter.write(group: second, source: source, settings: settings, to: destination, replace: true)
        XCTAssertFalse(fm.fileExists(atPath: files[2].path))
        XCTAssertEqual(try Data(contentsOf: keep), Data("keep".utf8))
        let before = try snapshot(destination)
        XCTAssertThrowsError(try SocialMediaSliceExporter.write(group: second, source: source, settings: settings, to: destination))
        let token = CancellationToken()
        XCTAssertThrowsError(try SocialMediaSliceExporter.write(group: second, source: source, settings: settings,
            to: destination, replace: true, cancellation: token, progress: { _, _ in token.cancel() })) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(try snapshot(destination), before)
        XCTAssertEqual(try Data(contentsOf: source), sourceData)
        XCTAssertFalse(try fm.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".pano_slicer_") })
    }

    private func snapshot(_ directory: URL) throws -> [String: Data] {
        try Dictionary(uniqueKeysWithValues: FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
    }
}
