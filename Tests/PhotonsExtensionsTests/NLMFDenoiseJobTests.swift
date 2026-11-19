//
//  NLMFDenoiseJobTests.swift
//
//  What is worth asserting about the wiring, and why each check exists.
//
//  The model itself needs ~90 s of GPU work, so no test here runs a denoise. What
//  they pin down is the part that silently rots: the settings the app ships, the
//  bundle path the model is expected at, and the availability gate that decides
//  whether the menu entry is live.
//

import XCTest
import NonlocalMatchFilter
@testable import PhotonsExtensions

final class NLMFDenoiseJobTests: XCTestCase {

    // MARK: - Shipped settings

    /// These three values are the measured configuration, not defaults inherited
    /// from the library. If someone changes one, they should have to change a test
    /// and say why — an accidental drift here reads to users as "the denoiser
    /// changed".
    ///
    ///  - `strength 0.70`: at 1.0 the network plastifies fine texture.
    ///  - `crop 4` (plane px = 8 mosaic px): a tile edge is a seam, and grids
    ///    anchored differently disagree there at 9x the interior rate at 0–1 px.
    ///  - checkerboard sampling: halves the noise-estimate cost for 3.6 % on `a`.
    func testShippedOptionsAreTheMeasuredOnes() {
        let job = NLMFDenoiseJob()
        let options = job.options(modelURL: URL(fileURLWithPath: "/tmp/model.mlpackage"))

        XCTAssertEqual(options.strength, 0.70, accuracy: 1e-9)
        XCTAssertEqual(options.crop, 4, "crop is in plane pixels; 4 = 8 mosaic pixels")
        XCTAssertTrue(options.measureNoise, "the shipped defaults are wrong by ~1.8x at high ISO")
        XCTAssertTrue(options.checkerboardNoise, "halves the estimate cost; on by product decision")
    }

    /// Only the 256 model ships. The 512 one is real and measured but 14 % slower
    /// for a 0.06/255 quality difference, which does not justify 72 MB of bundle.
    func testOnlyThe256VariantShips() {
        XCTAssertEqual(NLMFDenoiseJob.Variant.allCases, [.t256])
        XCTAssertEqual(NLMFDenoiseJob.Variant.t256.planeSide, 256)
        XCTAssertEqual(NLMFDenoiseJob.Variant.t256.rawValue, "v_matmul_256.mlpackage")
    }

    /// The tile size and the model file must agree: the spatial shape is baked into
    /// the traced graph, so a mismatch is not a tuning issue, it fails to load.
    func testTileSizeMatchesTheFileName() {
        for variant in NLMFDenoiseJob.Variant.allCases {
            XCTAssertTrue(variant.rawValue.contains("\(variant.planeSide)"),
                          "\(variant.rawValue) does not name its plane side")
        }
    }

    // MARK: - Resolution

    /// An explicit path wins outright, so a caller (and a test) can point at a
    /// model anywhere without touching the bundle.
    func testExplicitModelURLWins() {
        let explicit = URL(fileURLWithPath: "/tmp/somewhere/model.mlpackage")
        let job = NLMFDenoiseJob(modelURL: explicit)
        XCTAssertEqual(job.searchedModelURLs(environment: [:]), [explicit])
    }

    /// The environment override comes before the bundle, which is what makes the
    /// whole thing debuggable without rebuilding the app.
    func testEnvironmentOverrideComesBeforeTheBundle() {
        let job = NLMFDenoiseJob()
        let urls = job.searchedModelURLs(
            environment: [NLMFDenoiseJob.environmentKey: "/tmp/override.mlpackage"],
            bundle: .main)
        XCTAssertEqual(urls.first?.path, "/tmp/override.mlpackage")
    }

    /// Order matters beyond the override: the bundle path is the one the tooltip
    /// shows when the file is missing, so it has to be the same list the lookup
    /// walks.
    func testBundleCandidateIsTheLastResort() {
        let job = NLMFDenoiseJob()
        let urls = job.searchedModelURLs(environment: [:], bundle: .main)
        if let bundlePath = NLMFDenoiseJob.expectedModelPath(variant: .t256, bundle: .main) {
            XCTAssertEqual(urls.last, bundlePath)
        }
    }

    /// Availability is a file-existence check, not a "can I run a minute of GPU
    /// work" check — the point is to grey out the menu entry, so it must be cheap
    /// and it must not load the model.
    func testAvailabilityFollowsFileExistence() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let missing = tmp.appendingPathComponent("absent.mlpackage")
        XCTAssertFalse(NLMFDenoiseJob(modelURL: missing).isAvailable(environment: [:]))

        // A directory with the right name is enough for `isAvailable`: this check
        // answers "was it shipped", not "is it loadable". Loading is the
        // pipeline's job, and the upstream package tests that against the real
        // artefacts.
        let present = tmp.appendingPathComponent("present.mlpackage", isDirectory: true)
        try FileManager.default.createDirectory(at: present, withIntermediateDirectories: true)
        XCTAssertTrue(NLMFDenoiseJob(modelURL: present).isAvailable(environment: [:]))
    }

    /// A missing model is a packaging fault, so the message must name the path that
    /// was searched rather than telling the user to download something.
    func testMissingModelMessageNamesTheExpectedPath() {
        let path = "/Applications/Photons.app/Contents/Resources/Models/v_matmul_256.mlpackage"
        let described = NLMFDenoiseJobError.modelMissing(expected: path).description
        XCTAssertTrue(described.contains(path),
                      "the tooltip has to say where it looked: \(described)")
    }

    // MARK: - The shipped artefact is really there

    /// The model must be reachable through the *target* bundle, which is where
    /// SwiftPM puts `.copy(...)` resources.
    ///
    /// This is the check that catches the failure mode this file was written after
    /// hitting: looking in `Bundle.main` finds nothing, because the model lives in
    /// `Photons_PhotonsExtensions.bundle`. The feature then reports itself
    /// unavailable in a fully built app, which looks like a packaging problem and
    /// is actually a bundle-lookup problem.
    func testModelIsPresentInTheTargetBundle() throws {
        let job = NLMFDenoiseJob()
        let resolved = try XCTUnwrap(
            job.resolvedModel(environment: [:]),
            "no model found; looked in: \(job.searchedModelURLs(environment: [:]).map(\.path))")
        XCTAssertTrue(resolved.path.contains("Photons_PhotonsExtensions.bundle"),
                      "resolved outside the target bundle: \(resolved.path)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: resolved.path))
    }

    /// Existence is not loadability: a truncated or half-copied `.mlpackage` passes
    /// `fileExists` and fails here. This loads the real 63 MB artefact through the
    /// same entry point the app uses.
    func testShippedModelActuallyLoads() throws {
        let job = NLMFDenoiseJob()
        let url = try XCTUnwrap(job.resolvedModel(environment: [:]))

        // Loading is the only step that reads the graph; running a denoise would
        // cost a minute of GPU, and the upstream package tests the pipeline
        // against this same artefact.
        let denoiser = try CoreMLDenoiser(mlpackage: url.path,
                                         layout: PackedLayout(cfa: "rggb"))
        XCTAssertEqual(denoiser.planeSide, 256,
                       "the bundled graph was converted for a different tile size")
        // One sample per 2x2 cell, so the mosaic window is twice the plane side.
        XCTAssertEqual(denoiser.mosaicWindow, 512)
    }
}
