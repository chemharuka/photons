import XCTest
import PhotonsExport

/// 163 §1.2 / §1.4 — the ImageIO facts the JPEG/AVIF writers are built on.
///
/// These are intentionally measurements, not expectations: the probe writes real files and reads them
/// back through ImageIO/Core Image. If a future OS changes one of these answers the test fails and the
/// writer must be revisited (rather than silently falling back to SDR).
@available(macOS 15.0, *)
final class HDRProbeTests: XCTestCase {

    func testJPEGAcceptsISOAndAppleGainMapsButNotMultiImage() {
        let probe = HDRProbe.run()
        XCTAssertTrue(probe.jpegISOAccepted, "ImageIO's JPEG writer must accept ISOGainMap")
        XCTAssertEqual(probe.jpegISOHeadroom ?? 0, 4, accuracy: 0.2,
                       "JPEG ISO gain map must read back its headroom")
        XCTAssertTrue(probe.jpegAppleAccepted,
                      "Core Image's JPEG representation must accept hdrGainMapImage")
        XCTAssertEqual(probe.jpegAppleHeadroom ?? 0, 4, accuracy: 0.2,
                       "JPEG Apple gain map must read back its headroom")
        XCTAssertFalse(probe.jpegPropertiesExposeAux,
                       "kCGImagePropertyImages/AuxiliaryData is absent; aux is read via the aux API")
        XCTAssertFalse(probe.jpegMultiImage,
                       "ImageIO cannot create a two-image JPEG destination (no MPF route)")
    }

    func testAVIFWritesTenBitAndAnISOGainMap() {
        let probe = HDRProbe.run()
        XCTAssertEqual(probe.avif10Depth, 10, "AVIF's writer really stores 10-bit primaries")
        XCTAssertTrue(probe.avifISOAccepted, "ImageIO's AVIF writer must accept ISOGainMap")
        XCTAssertEqual(probe.avifISOHeadroom ?? 0, 4, accuracy: 0.2,
                       "AVIF ISO gain map must read back its headroom")
        XCTAssertTrue(probe.avifAppleAccepted, "the aux is stored…")
        XCTAssertLessThan(probe.avifAppleHeadroom ?? 1, 1.05,
                          "…but Apple's spelling is not decoded as HDR in AVIF")
        XCTAssertFalse(probe.avifMultiImage,
                       "ImageIO cannot create a two-image AVIF destination")
    }
}
