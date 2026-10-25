import XCTest
import CoreGraphics
@testable import PhotonsCore

/// Shared fixture discovery. The RAW samples are not vendored (they are real photographs); the
/// suite finds what is on this machine and skips honestly when nothing is.
enum ThumbFixtures {
    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // PhotonsCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
    }

    static var candidates: [URL] {
        let root = repoRoot
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        var out: [URL] = []
        if let env = ProcessInfo.processInfo.environment["PHOTONS_TEST_RAW"] {
            out.append(URL(fileURLWithPath: (env as NSString).expandingTildeInPath))
        }
        for base in [root, cwd] {
            out.append(base.appendingPathComponent("local/out/raw/L1030433.dng"))
            out.append(base.appendingPathComponent("local/probes/sample_leica.dng"))
        }
        out.append(URL(fileURLWithPath: NSString(string: "~/Desktop/test/L1030433.dng").expandingTildeInPath))
        return out.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func dng() -> URL? { candidates.first }

    /// One file per RAW family the grid has to deal with: CR3 / RAF / ARW / RW2 / DNG.
    static func perFamily() -> [URL] {
        let root = repoRoot
        var out: [URL] = []
        let sampleDir = root.appendingPathComponent("local/samples/samples")
        let names = [
            "Canon_EOS_R5_RAW_ISO_100_nocrop_nodual.CR3",
            "DSCF0021.RAF",
            "ILCE-7M4_DSC06674_FullFrame-LossLess-Compressed-Large.ARW",
            "P1126473_96MP.RW2",
        ]
        for n in names {
            let u = sampleDir.appendingPathComponent(n)
            if FileManager.default.fileExists(atPath: u.path) { out.append(u) }
        }
        if let d = dng() { out.append(d) }
        return out
    }

    static func first(withExtension ext: String) -> URL? {
        perFamily().first { $0.pathExtension.lowercased() == ext.lowercased() }
    }
}

/// §7 #4/#6 data side: the P path must be fast, must never upscale, and must say which API the
/// pixels came from.
final class ThumbPreviewSourceTests: XCTestCase {

    private func decoder() throws -> RAWDecoder { try RAWDecoder() }

    func testPreviewHonoursMaxPixelSize() throws {
        let url = try XCTUnwrap(ThumbFixtures.dng(), "no DNG fixture; set PHOTONS_TEST_RAW")
        let d = try decoder()
        for maxPixelSize in [256, 512, 1024] {
            let out = try XCTUnwrap(d.preview(url, maxPixelSize: maxPixelSize),
                                    "no embedded preview in \(url.lastPathComponent)")
            XCTAssertLessThanOrEqual(out.longEdge, maxPixelSize,
                                     "asked for ≤\(maxPixelSize) px, got \(out.longEdge)")
            XCTAssertEqual(out.image.width, Int(out.pixelSize.width))
            XCTAssertEqual(out.image.height, Int(out.pixelSize.height))
            XCTAssertGreaterThanOrEqual(out.sourceLongEdge, out.longEdge, "never upscale the embedded preview")
            print(String(format: "preview %@ max=%d → %d×%d (%@) src %d×%d",
                         url.lastPathComponent, maxPixelSize, Int(out.pixelSize.width),
                         Int(out.pixelSize.height), out.source.rawValue,
                         Int(out.sourcePixelSize.width), Int(out.sourcePixelSize.height)))
        }
    }

    /// §1 "禁止放大": asking for more than the embedded preview has returns the preview's own size.
    func testPreviewDoesNotUpscale() throws {
        let url = try XCTUnwrap(ThumbFixtures.dng(), "no DNG fixture; set PHOTONS_TEST_RAW")
        let out = try XCTUnwrap(try decoder().preview(url, maxPixelSize: 100_000))
        XCTAssertLessThanOrEqual(out.longEdge, out.sourceLongEdge)
        XCTAssertTrue(out.wasClampedToSource)
        print("no-upscale: delivered \(out.longEdge) px from a \(out.sourceLongEdge) px preview")
    }

    /// The label has to be true, not decorative: `.auto` reports `.embedded` exactly when the
    /// filter alone could produce the image, and `.fallback` exactly when it could not.
    func testPreviewSourceLabelIsTruthful() throws {
        let url = try XCTUnwrap(ThumbFixtures.dng(), "no DNG fixture; set PHOTONS_TEST_RAW")
        let d = try decoder()
        let filterOnly = d.preview(url, maxPixelSize: 512, strategy: .filter)
        let thumbOnly = d.preview(url, maxPixelSize: 512, strategy: .thumbnail)
        let auto = d.preview(url, maxPixelSize: 512, strategy: .auto)

        if let filterOnly {
            XCTAssertEqual(filterOnly.source, .embedded)
        }
        if let thumbOnly {
            XCTAssertEqual(thumbOnly.source, .fallback)
        }
        // `.auto` is filter-first: same source as the filter when it works, otherwise the fallback.
        if filterOnly != nil {
            XCTAssertEqual(auto?.source, .embedded, "auto must prefer CIRAWFilter.previewImage")
        } else if thumbOnly != nil {
            XCTAssertEqual(auto?.source, .fallback)
        } else {
            XCTAssertNil(auto)
        }
        print("sources: filter=\(filterOnly?.source.rawValue ?? "nil") "
              + "thumbnail=\(thumbOnly?.source.rawValue ?? "nil") auto=\(auto?.source.rawValue ?? "nil")")
    }

    /// §11.2's sizes, measured on this machine's samples. Not asserted (the samples are not
    /// vendored and differ per user) — printed, because the "禁止放大" budget depends on them.
    func testPrintEmbeddedPreviewSizesPerFamily() throws {
        let files = ThumbFixtures.perFamily()
        try XCTSkipIf(files.isEmpty, "no RAW samples under local/samples/samples")
        let d = try decoder()
        for url in files {
            let out = d.preview(url, maxPixelSize: 512, strategy: .filter)
            print(String(format: "%-40@ src %d×%d  via %@", url.lastPathComponent,
                         Int(out?.sourcePixelSize.width ?? 0), Int(out?.sourcePixelSize.height ?? 0),
                         out?.source.rawValue ?? "none"))
            if let out {
                XCTAssertGreaterThan(out.sourceLongEdge, 0)
                XCTAssertLessThanOrEqual(out.longEdge, 512)
            }
        }
    }

    func testMissingFileReturnsNilRatherThanThrowing() throws {
        let url = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).dng")
        XCTAssertNil(try? decoder().preview(url, maxPixelSize: 256))
        XCTAssertNil(try? decoder().previewImage(url, maxPixelSize: 256))
    }
}

/// §11.3: lens correction is a per-**file** capability. The probe must read the flag, prove the
/// switch really flips, and leave the filter exactly as it found it.
final class LensCapabilityProbeTests: XCTestCase {

    func testProbeReportsPerFileLensCorrection() throws {
        let files = ThumbFixtures.perFamily()
        try XCTSkipIf(files.isEmpty, "no RAW samples under local/samples/samples")
        let decoder = try RAWDecoder()

        var results: [(String, Bool)] = []
        for url in files {
            let probe = try decoder.probe(url)
            let ext = url.pathExtension.lowercased()
            results.append((url.lastPathComponent, probe.lensCorrectionSupported))
            print(String(format: "lens   %-40@ %-4@ supported=%@ enabled=%@  %@/%@",
                         url.lastPathComponent, ext,
                         probe.lensCorrectionSupported ? "true" : "false",
                         probe.lensCorrectionEnabled ? "true" : "false",
                         probe.make ?? "?", probe.model ?? "?"))

            // The one measured fact we can assert: the EOS R5 + Sigma 50/1.4 CR3 does not support
            // it (§11.3). If this ever starts passing as `true`, either the OS gained a profile for
            // that lens or the flag became advisory — both are worth knowing.
            if ext == "cr3" {
                XCTAssertFalse(probe.lensCorrectionSupported,
                    "§11.3 measured the EOS R5/Sigma 50 CR3 as lens-correction-unsupported. "
                    + "A `true` here is not a failure of the code — it means macOS now has a profile "
                    + "for this combination, so the 'per-file, never per-camera' note needs re-measuring.")
            }
            // A `false` on RW2/RAF is the legitimate other outcome: `false` means either the body
            // says unsupported or the toggle did not survive a read-back. The probe is deliberately
            // stricter than the raw flag, so a false here is "we would put a dead switch in the
            // inspector", never a crash.
        }
        XCTAssertFalse(results.isEmpty)
    }

    /// The probe toggles `isLensCorrectionEnabled` to prove it is switchable. If it forgot to
    /// restore, the *pixels* would change — so compare a decode before and after the probe.
    func testProbeLeavesTheFilterUntouched() throws {
        let url = try XCTUnwrap(ThumbFixtures.first(withExtension: "ARW") ?? ThumbFixtures.dng(),
                                "no RAW fixture; set PHOTONS_TEST_RAW")
        let decoder = try RAWDecoder()
        let opts = DecodeOptions(scale: 0.125)
        let before = try decoder.decode(url, options: opts).sha256()
        _ = try decoder.probe(url)
        let after = try decoder.decode(url, options: opts).sha256()
        XCTAssertEqual(before, after,
                       "probing lens correction must not leave it switched on: the probe toggles the "
                       + "flag to prove it flips, and must restore it (or every later decode differs)")
    }
}
