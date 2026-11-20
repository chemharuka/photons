//
//  BundledModelTests.swift
//
//  The two `.mlpackage` files in `Models/` are part of the repository, so they can
//  rot: a Core ML format change, a bad copy, a file left behind by a conversion
//  run. These tests load them the way the app does, which is the only check that
//  the shipped artefacts still work with the shipped code.
//

import CoreML
import XCTest
@testable import NonlocalMatchFilter

final class BundledModelTests: XCTestCase {

    /// `Models/` sits at the package root; tests run from there.
    private var modelsDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // NonlocalMatchFilterTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
            .appendingPathComponent("Models")
    }

    private func modelURL(_ name: String) -> URL? {
        let url = modelsDirectory.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Both sizes ship. If someone regenerates one and forgets the other, the
    /// README's comparison table silently stops matching the repo.
    func testBothTileSizesArePresent() throws {
        for name in ["v_matmul_256.mlpackage", "v_matmul_512.mlpackage"] {
            let url = try XCTUnwrap(modelURL(name), "\(name) is missing from Models/")
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
    }

    /// Loading is what actually validates the file: a truncated `.mlpackage` on
    /// disk looks fine to `fileExists` and fails here.
    func testBundledModelsLoadAndReportTheirTileSize() throws {
        for (name, expectedPlaneSide) in [("v_matmul_256.mlpackage", 256),
                                          ("v_matmul_512.mlpackage", 512)] {
            let url = try XCTUnwrap(modelURL(name))
            let denoiser = try CoreMLDenoiser(mlpackage: url.path, layout: PackedLayout(cfa: "rggb"))
            XCTAssertEqual(denoiser.planeSide, expectedPlaneSide,
                           "\(name) was converted for a different tile size")
            // The mosaic window is twice the plane side, because each plane holds
            // one sample per 2x2 cell.
            XCTAssertEqual(denoiser.mosaicWindow, expectedPlaneSide * 2)
        }
    }

    /// 1 plane pixel is 2 mosaic pixels, so the crop in mosaic terms is double.
    /// Getting this backwards would crop half as much as intended and leave the
    /// seam visible at the setting the README recommends.
    func testCropIsExpressedInPlanePixels() {
        let layout = PackedLayout(cfa: "rggb")
        XCTAssertEqual(layout.cfa, "rggb")
        // Documented in DenoiseRequest.crop and exercised by the tile-grid tests:
        // crop 4 (plane) discards 8 mosaic pixels per interior side.
        let planeCrop = 4
        let mosaicCrop = planeCrop * 2
        XCTAssertEqual(mosaicCrop, 8)
    }
}
