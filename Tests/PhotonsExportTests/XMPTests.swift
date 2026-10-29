import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import PhotonsExport
import PhotonsCore

/// Round-trip acceptance for docs/xmp-mapping.md §5: write → read back with `CGImageMetadata` →
/// compare field by field. Numeric comparison is `|Δ| ≤ 1e-6` and never string-based (§4.3 pitfall 2).
final class XMPTests: XCTestCase {

    // MARK: - helpers

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-xmp-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    private func reparse(_ edit: EditModel,
                         _ context: XMPWriteContext = XMPWriteContext()) throws
        -> (metadata: CGImageMetadata, report: XMPExportReport) {
        let (metadata, report) = try XMPWriter.makeMetadata(for: edit, context: context)
        let data = try XMPWriter.xmpData(metadata)
        guard let back = CGImageMetadataCreateFromXMPData(data as CFData) else {
            XCTFail("the packet we just serialised does not parse")
            throw XMPExportError.xmpSerializationFailed
        }
        return (back, report)
    }

    private func assertClose(_ actual: Double?, _ expected: Double, _ label: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        guard let actual else {
            XCTFail("\(label): missing", file: file, line: line); return
        }
        XCTAssertEqual(actual, expected, accuracy: 1e-6, label, file: file, line: line)
    }

    private func makeImage(width: Int = 64, height: Int = 48) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                bytes[i] = UInt8(x % 256)
                bytes[i + 1] = UInt8(y % 256)
                bytes[i + 2] = UInt8((x * y) % 256)
                bytes[i + 3] = 255
            }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)!
    }

    @discardableResult
    private func writeContainer(_ url: URL, _ type: UTType) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL,
                                                         type.identifier as CFString, 1, nil) else {
            return false
        }
        var props: [CFString: Any] = [:]
        if type == .jpeg { props[kCGImageDestinationLossyCompressionQuality] = 0.95 }
        CGImageDestinationAddImage(dest, makeImage(), props as CFDictionary)
        return CGImageDestinationFinalize(dest)
    }

    private func cropModel(_ edit: inout EditModel) {
        edit.geometry.crop = NormalizedRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
    }

    private static let bandNames = ["Red", "Orange", "Yellow", "Green", "Aqua", "Blue", "Purple", "Magenta"]

    // MARK: - X-01 / X-02: identity writes no keys (R1)

    func testX01NeutralWritesOnlyDeclarations() throws {
        let (m, report) = try reparse(.neutral)
        let paths = XMPReadback.paths(m)

        // Declarations are the R1 exceptions and must always be present.
        XCTAssertEqual(XMPReadback.string(m, "crs:Version"), "18.5.1")
        XCTAssertEqual(XMPReadback.string(m, "crs:ProcessVersion"), "15.4")
        XCTAssertEqual(XMPReadback.string(m, "crs:WhiteBalance"), "As Shot")

        // Everything at its default must be absent.
        for path in ["crs:Exposure2012", "crs:Contrast2012", "crs:Highlights2012",
                     "crs:Shadows2012", "crs:Whites2012", "crs:Blacks2012",
                     "crs:Temperature", "crs:Tint", "crs:Vibrance", "crs:Saturation",
                     "crs:Sharpness", "crs:SharpenRadius", "crs:LuminanceSmoothing",
                     "crs:ColorNoiseReduction", "crs:LensProfileEnable",
                     "crs:PostCropVignetteAmount", "crs:PostCropVignetteMidpoint",
                     "crs:PostCropVignetteFeather",
                     "crs:GrainAmount", "crs:ToneCurvePV2012", "crs:ToneCurveName2012",
                     "crs:CropLeft", "crs:CropTop", "crs:CropRight", "crs:CropBottom",
                     "crs:CropAngle", "crs:HasCrop", "tiff:Orientation"] {
            XCTAssertNil(XMPReadback.tag(m, path), "\(path) must not exist on a neutral document")
        }
        XCTAssertFalse(paths.contains { $0.hasPrefix("crs:HueAdjustment") })

        // The lossless half still has to be there.
        for path in ["photons:schemaVersion", "photons:processVersion",
                     "photons:highlightRecovery", "photons:settings"] {
            XCTAssertNotNil(XMPReadback.tag(m, path), "\(path) is the backup of record")
        }
        // 派单 006: an as-shot document has **no** temperature to write — `crs:WhiteBalance` carries
        // the state, and a nominal 6500 K here would be the lie this change removed.
        XCTAssertNil(XMPReadback.tag(m, "photons:temperature"), "as shot must not be written as 6500")
        XCTAssertNil(XMPReadback.tag(m, "photons:tint"))
        XCTAssertEqual(XMPReadback.string(m, "crs:WhiteBalance"), "As Shot")
        XCTAssertEqual(report.written.filter { $0.hasPrefix("crs:") }.count, 3)
    }

    func testX02ExplicitZerosAreIdenticalToNeutral() throws {
        var explicit = EditModel.neutral
        explicit.light.exposure = 0.0
        explicit.effects.vignetteAmount = 0.0
        explicit.detail.sharpening = 0
        explicit.curve.white = [CurvePoint(u: 0, v: 0), CurvePoint(u: 1, v: 1)]

        let neutralPacket = try XMPWriter.packet(for: .neutral).data
        let explicitPacket = try XMPWriter.packet(for: explicit).data
        XCTAssertEqual(neutralPacket, explicitPacket,
                       "0 and a missing value must be indistinguishable (R1)")

        // …except for white balance, where the *default* is a state, not a number (派单 006): a
        // pinned tint of 0 is a real setting and must reach the packet.
        var pinned = explicit
        pinned.light.tint = 0
        let (m, _) = try reparse(pinned)
        assertClose(XMPReadback.double(m, "photons:tint"), 0, "photons:tint pinned at 0")
        XCTAssertEqual(XMPReadback.string(m, "crs:WhiteBalance"), "Custom")
    }

    // MARK: - X-03 / X-04: signs and extremes

    func testX03NegativeValuesSurvive() throws {
        var edit = EditModel.neutral
        edit.light.exposure = -5
        edit.light.contrast = -100
        edit.light.tint = -150
        edit.effects.vignetteAmount = -100
        edit.color.bands = Array(repeating: HSLBand(hue: -100, saturation: -100, luminance: -100),
                                 count: ColorGroup.bandCount)

        let (m, _) = try reparse(edit)
        assertClose(XMPReadback.double(m, "crs:Exposure2012"), -5, "Exposure2012")
        assertClose(XMPReadback.double(m, "crs:Contrast2012"), -100, "Contrast2012")
        for name in Self.bandNames {
            assertClose(XMPReadback.double(m, "crs:HueAdjustment\(name)"), -100, "hue \(name)")
            assertClose(XMPReadback.double(m, "crs:SaturationAdjustment\(name)"), -100, "sat \(name)")
            assertClose(XMPReadback.double(m, "crs:LuminanceAdjustment\(name)"), -100, "lum \(name)")
        }
        assertClose(XMPReadback.double(m, "crs:PostCropVignetteAmount"), -100, "vignette")
        // Without an as-shot anchor, crs:Tint is deliberately not written (§1.3).
        XCTAssertNil(XMPReadback.tag(m, "crs:Tint"))
    }

    func testX04ExtremesAndRoundedEdges() throws {
        var edit = EditModel.neutral
        edit.light.exposure = 5
        edit.light.temperature = 12000
        edit.light.tint = 150
        edit.detail.sharpening = 150
        edit.detail.sharpeningRadius = 0.5
        cropModel(&edit)

        let (m, _) = try reparse(edit)
        assertClose(XMPReadback.double(m, "crs:Exposure2012"), 5, "Exposure2012")
        assertClose(XMPReadback.double(m, "crs:Sharpness"), 150, "Sharpness")
        assertClose(XMPReadback.double(m, "crs:SharpenRadius"), 0.5, "SharpenRadius")
        assertClose(XMPReadback.double(m, "photons:temperature"), 12000, "photons:temperature")
        assertClose(XMPReadback.double(m, "crs:CropRight"), 0.4, "CropRight")
        assertClose(XMPReadback.double(m, "crs:CropBottom"), 0.6, "CropBottom")

        edit.detail.sharpeningRadius = 3
        let (m3, _) = try reparse(edit)
        assertClose(XMPReadback.double(m3, "crs:SharpenRadius"), 3, "SharpenRadius 3")

        // Anchored WB is **absolute** now (派单 006): the anchor is where the file's as-shot sits, and
        // an explicit 12000 K / +150 tint is written as exactly that. The old `anchor + (ours − 6500)`
        // shift existed only to undo the nominal 6500 K our model used to carry.
        let anchor = WhiteBalanceAnchor(temperature: 5200, tint: 10)
        let (ma, _) = try reparse(edit, XMPWriteContext(asShot: anchor))
        assertClose(XMPReadback.double(ma, "crs:Temperature"), 12000, "anchored temperature")
        assertClose(XMPReadback.double(ma, "crs:Tint"), 150, "anchored tint")
        XCTAssertEqual(XMPReadback.string(ma, "crs:WhiteBalance"), "Custom")

        // As shot writes the anchor itself, and says so.
        var follows = edit
        follows.light.temperature = nil
        follows.light.tint = nil
        let (ms, _) = try reparse(follows, XMPWriteContext(asShot: anchor))
        assertClose(XMPReadback.double(ms, "crs:Temperature"), 5200, "as-shot temperature")
        assertClose(XMPReadback.double(ms, "crs:Tint"), 10, "as-shot tint")
        XCTAssertEqual(XMPReadback.string(ms, "crs:WhiteBalance"), "As Shot")
    }

    // MARK: - X-05 / X-06: curves

    func testX05CurveQuantizationKeepsSixteenPoints() throws {
        var edit = EditModel.neutral
        var points: [CurvePoint] = []
        for i in 0..<16 {
            let x = Double(i) / 15.0
            points.append(CurvePoint(u: x, v: pow(x, 1.25)))
        }
        edit.curve.white = points

        let (m, _) = try reparse(edit)
        let items = try XCTUnwrap(XMPReadback.strings(m, "crs:ToneCurvePV2012"))
        XCTAssertEqual(items.count, 16, "LR caps curves at 16 points")

        let parsed: [(Double, Double)] = try items.map { item in
            let parts = item.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let xs = try XCTUnwrap(Double(parts[0])), ys = try XCTUnwrap(Double(parts[1]))
            return (xs, ys)
        }
        for (i, p) in parsed.enumerated() {
            let expected = points[i]
            XCTAssertLessThanOrEqual(abs(p.0 - expected.u * 255), 0.5 + 1e-9, "x[\(i)]")
            XCTAssertLessThanOrEqual(abs(p.1 - expected.v * 255), 0.5 + 1e-9, "y[\(i)]")
        }
        XCTAssertEqual(parsed.first!.0, 0)
        XCTAssertEqual(parsed.last!.0, 255)
        XCTAssertEqual(parsed.first!.1, 0)
        XCTAssertEqual(parsed.last!.1, 255)
        XCTAssertEqual(XMPReadback.string(m, "crs:ToneCurveName2012"), "Custom")
        // Identity channels stay absent.
        XCTAssertNil(XMPReadback.tag(m, "crs:ToneCurvePV2012Red"))
    }

    func testX06CurveNormalisationSortsDedupesAndThins() throws {
        // Unsorted, duplicated x, and 20 points: LR could not read this back, so we must repair it.
        var raw: [CurvePoint] = []
        for i in (0..<20).reversed() { raw.append(CurvePoint(u: Double(i) / 19.0, v: Double(i) / 19.0)) }
        raw.insert(CurvePoint(u: 0.5, v: 0.9), at: 3)     // duplicate x, different y

        let normalized = XMPCurve.normalize(raw)
        XCTAssertLessThanOrEqual(normalized.points.count, 16)
        XCTAssertGreaterThan(normalized.dropped, 0)
        let xs = normalized.points.map(\.x)
        XCTAssertEqual(xs, xs.sorted(), "x must be ascending")
        XCTAssertEqual(Set(xs).count, xs.count, "x must be strictly increasing")
        XCTAssertEqual(normalized.points.first?.x, 0)
        XCTAssertEqual(normalized.points.last?.x, 255)

        // Duplicate x collapses to one control point, and the later one wins (the newest edit).
        let dup = XMPCurve.normalize([CurvePoint(u: 0, v: 0), CurvePoint(u: 0.5, v: 0.2),
                                      CurvePoint(u: 0.5, v: 0.9), CurvePoint(u: 1, v: 1)])
        XCTAssertEqual(dup.points.map(\.x), [0, 128, 255])
        XCTAssertEqual(dup.points[1].y, 230)
        XCTAssertEqual(dup.dropped, 1)
    }

    // MARK: - X-07 / X-08: crop geometry

    func testX07CropEdgesAreBoundariesNotWidths() throws {
        var edit = EditModel.neutral
        cropModel(&edit)
        edit.geometry.rotationDegrees = 12.5

        let (m, _) = try reparse(edit)
        assertClose(XMPReadback.double(m, "crs:CropLeft"), 0.1, "CropLeft")
        assertClose(XMPReadback.double(m, "crs:CropTop"), 0.2, "CropTop")
        assertClose(XMPReadback.double(m, "crs:CropRight"), 0.4, "CropRight = x + width")
        assertClose(XMPReadback.double(m, "crs:CropBottom"), 0.6, "CropBottom = y + height")
        assertClose(XMPReadback.double(m, "crs:CropAngle"), -12.5, "CropAngle is negated")
        XCTAssertEqual(XMPReadback.bool(m, "crs:HasCrop"), true)

        for angle in [0.0, 45.0, -45.0] {
            edit.geometry.rotationDegrees = angle
            let (ma, _) = try reparse(edit)
            if angle == 0 {
                XCTAssertNil(XMPReadback.tag(ma, "crs:CropAngle"), "0° writes no key (R1)")
            } else {
                assertClose(XMPReadback.double(ma, "crs:CropAngle"), -angle, "CropAngle \(angle)")
            }
        }
    }

    func testX08FullCropWritesNoCropKeys() throws {
        let (m, _) = try reparse(.neutral)
        for path in ["crs:HasCrop", "crs:CropLeft", "crs:CropTop",
                     "crs:CropRight", "crs:CropBottom", "crs:CropAngle"] {
            XCTAssertNil(XMPReadback.tag(m, path), "\(path) must be absent for a full-frame crop")
        }

        // …and applying a full crop over an older cropped packet removes the stale edges.
        var cropped = EditModel.neutral
        cropModel(&cropped)
        cropped.geometry.rotationDegrees = 5
        let (first, _) = try XMPWriter.makeMetadata(for: cropped)
        let mutable = try XMPWriter.mutableCopy(of: first)
        XCTAssertNotNil(XMPReadback.tag(mutable, "crs:CropLeft"))
        try XMPWriter.apply(.neutral, to: mutable)
        XCTAssertNil(XMPReadback.tag(mutable, "crs:CropLeft"))
        XCTAssertNil(XMPReadback.tag(mutable, "crs:HasCrop"))
        XCTAssertNil(XMPReadback.tag(mutable, "crs:CropAngle"))
    }

    // MARK: - X-09: orientation algebra

    func testX09FlipsComposeWithExifOrientationAndInvert() throws {
        var edit = EditModel.neutral
        let bases = [1, 3, 6, 8]
        var seenByBase: [Int: Set<Int>] = [:]

        for base in bases {
            var values: Set<Int> = []
            for h in [false, true] {
                for v in [false, true] where h || v {
                    edit.geometry.flipHorizontal = h
                    edit.geometry.flipVertical = v
                    let (m, _) = try reparse(edit, XMPWriteContext(exifOrientation: base))
                    let value = Int(try XCTUnwrap(XMPReadback.double(m, "tiff:Orientation")))
                    XCTAssertTrue((1...8).contains(value))
                    values.insert(value)

                    // Invert: the tag must tell us exactly which flips produced it.
                    let flips = XMPOrientation.from(value: value)
                        .flips(from: XMPOrientation.from(value: base))
                    XCTAssertEqual(flips.horizontal, h, "base \(base) → \(value)")
                    XCTAssertEqual(flips.vertical, v, "base \(base) → \(value)")
                }
            }
            XCTAssertEqual(values.count, 3, "the three flip combinations are distinct at base \(base)")
            seenByBase[base] = values
            // The pure-identity flip set must not write the tag at all.
            edit.geometry.flipHorizontal = false
            edit.geometry.flipVertical = false
            let (mi, _) = try reparse(edit, XMPWriteContext(exifOrientation: base))
            XCTAssertNil(XMPReadback.tag(mi, "tiff:Orientation"),
                         "no flips → leave the camera's orientation alone")
        }
        XCTAssertEqual(seenByBase.count, bases.count)
    }

    // MARK: - X-11: number readback (CFNumber vs CFString)

    func testX11NumericThreeFormsReadEqual() throws {
        var metadata = CGImageMetadataCreateMutable()
        try XMPWriter.registerNamespaces(metadata)
        XCTAssertTrue(CGImageMetadataSetValueWithPath(metadata, nil, "photons:a" as CFString,
                                                      NSNumber(value: 0.35)))
        XCTAssertTrue(CGImageMetadataSetValueWithPath(metadata, nil, "photons:b" as CFString,
                                                      "0.35" as CFString))
        XCTAssertTrue(CGImageMetadataSetValueWithPath(metadata, nil, "photons:c" as CFString,
                                                      "0.350000" as CFString))
        XCTAssertTrue(CGImageMetadataSetValueWithPath(metadata, nil, "photons:d" as CFString,
                                                      "0,35" as CFString))

        // The XMP text round trip is where the type can change under us.
        let data = try XMPWriter.xmpData(metadata)
        let back = try XCTUnwrap(CGImageMetadataCreateFromXMPData(data as CFData))

        for path in ["photons:a", "photons:b", "photons:c"] {
            assertClose(XMPReadback.double(back, path), 0.35, path)
        }
        XCTAssertNil(XMPReadback.double(back, "photons:d"),
                     "a comma decimal must be rejected, not parsed as two values")
        XCTAssertNil(XMPReadback.double(back, "photons:absent"))
    }

    // MARK: - X-12: dc:subject nested tag array

    func testX12SubjectReadsBackAsNestedTags() throws {
        var metadata = CGImageMetadataCreateMutable()
        try XMPWriter.registerNamespaces(metadata)
        let keywords = ["alpha", "beta", "gamma"]
        let tag = try XCTUnwrap(CGImageMetadataTagCreate(
            XMPNamespace.dc as CFString, "dc" as CFString, "subject" as CFString,
            .arrayUnordered, keywords as CFArray))
        XCTAssertTrue(CGImageMetadataSetTagWithPath(metadata, nil, "dc:subject" as CFString, tag))

        let back = try XCTUnwrap(CGImageMetadataCreateFromXMPData(try XMPWriter.xmpData(metadata) as CFData))
        XCTAssertEqual(XMPReadback.strings(back, "dc:subject"), keywords)

        // Pitfall 1 in the flesh: the value is an array of tags, not of strings.
        let raw = try XCTUnwrap(XMPReadback.tag(back, "dc:subject").flatMap(CGImageMetadataTagCopyValue))
        let array = try XCTUnwrap(raw as? [Any])
        XCTAssertTrue(array.allSatisfy { $0 is CGImageMetadataTag },
                      "ImageIO returns child tags — reading it as [String] would silently give []")
        XCTAssertNil(XMPReadback.strings(back, "dc:description"))
    }

    // MARK: - X-13: namespace registration and the exact URI

    func testX13NamespaceRegistrationAndExactURI() throws {
        // An unknown prefix is refused outright — this is the regression that guards our own
        // namespace (R2) against a typo in the URI or the prefix.
        let bare = CGImageMetadataCreateMutable()
        XCTAssertFalse(CGImageMetadataSetValueWithPath(bare, nil, "photons:temperature" as CFString,
                                                      NSNumber(value: 6500)),
                       "an unregistered private namespace must not accept a write")
        XCTAssertFalse(CGImageMetadataSetValueWithPath(bare, nil, "zzz:Thing" as CFString,
                                                       NSNumber(value: 1)))

        // Note: on macOS 27 ImageIO ships a *built-in* mapping for `crs`, so the spec's X-13 form
        // ("unregistered crs: write returns false") is not observable here — it succeeds and
        // resolves to the same URI. Registration stays mandatory for `photons:` and harmless for
        // `crs:`, and the serialised URI is what Lightroom actually matches on (B11).
        let metadata = CGImageMetadataCreateMutable()
        try XMPWriter.registerNamespaces(metadata)
        XCTAssertTrue(CGImageMetadataSetValueWithPath(metadata, nil, "photons:temperature" as CFString,
                                                     NSNumber(value: 6500)))
        XCTAssertTrue(CGImageMetadataSetValueWithPath(metadata, nil, "crs:CropLeft" as CFString,
                                                      NSNumber(value: 0.5)))

        let text = String(decoding: try XMPWriter.xmpData(metadata), as: UTF8.self)
        XCTAssertTrue(text.contains("xmlns:crs=\"http://ns.adobe.com/camera-raw-settings/1.0/\""),
                      "the trailing slash is not optional")
        XCTAssertTrue(text.contains("xmlns:photons=\"https://photons.app/ns/edit/1.0/\""))
    }

    // MARK: - R1 as a property, not a coincidence

    func testR1DefaultValuesRemovePreviouslyWrittenKeys() throws {
        var edit = EditModel.neutral
        edit.light.exposure = -2
        edit.light.contrast = 30
        edit.effects.vignetteAmount = 40
        edit.detail.sharpening = 80
        edit.curve.white = [CurvePoint(u: 0, v: 0), CurvePoint(u: 0.5, v: 0.6), CurvePoint(u: 1, v: 1)]

        let (first, _) = try XMPWriter.makeMetadata(for: edit)
        let mutable = try XMPWriter.mutableCopy(of: first)
        for path in ["crs:Exposure2012", "crs:Contrast2012", "crs:PostCropVignetteAmount",
                     "crs:Sharpness", "crs:ToneCurvePV2012"] {
            XCTAssertNotNil(XMPReadback.tag(mutable, path), path)
        }

        try XMPWriter.apply(.neutral, to: mutable)
        for path in ["crs:Exposure2012", "crs:Contrast2012", "crs:PostCropVignetteAmount",
                     "crs:Sharpness", "crs:ToneCurvePV2012", "crs:ToneCurveName2012"] {
            XCTAssertNil(XMPReadback.tag(mutable, path),
                         "\(path) must be removed when the value returns to its default")
        }
    }

    // MARK: - unmappable fields + the lossless backup

    func testUnmappableFieldsAreCountedAndBackedUp() throws {
        var edit = EditModel.neutral
        edit.light.highlightRecovery = 0.8
        // Mask's field set is being reworked for M4 in a parallel change, so this test builds
        // instances only through the initialiser every version has: the accounting in `apply`
        // depends on `masks.count` alone, never on mask fields.
        edit.masks = [Mask(), Mask()]

        let (metadata, report) = try XMPWriter.makeMetadata(for: edit)
        XCTAssertEqual(report.unmapped["light.highlightRecovery"], 1)
        XCTAssertEqual(report.unmapped["masks[i].id"], 2)
        XCTAssertEqual(report.unmapped["masks[i].kind"], 2)
        XCTAssertEqual(report.unmapped["masks[i].params"], 2)
        XCTAssertEqual(report.unmapped["schemaVersion"], 1)
        // 派单 006: as shot has no XMP number, so the two WB fields are reported as skipped — nothing
        // to translate, nothing to lose (the state lives in `crs:WhiteBalance = "As Shot"`).
        XCTAssertEqual(report.unmapped["light.temperature (as shot)"], 1)
        XCTAssertEqual(report.unmapped["light.tint (as shot)"], 1)
        XCTAssertEqual(report.unmappedCount, 10)

        // Unmappable means "no crs: key", and the private namespace carries the value instead.
        XCTAssertNil(XMPReadback.tag(metadata, "crs:HighlightRecovery"))
        XCTAssertNil(XMPReadback.tag(metadata, "crs:Masks"))
        assertClose(XMPReadback.double(metadata, "photons:highlightRecovery"), 0.8,
                    "photons:highlightRecovery")

        // photons:settings is byte-exact: decode it and compare whole documents.
        let restored = try XCTUnwrap(XMPReadback.settings(metadata), "settings blob must decode")
        XCTAssertEqual(restored, edit)
    }

    // MARK: - X-15: a big backup payload

    func testX15LargeSettingsBlobRoundTripsAndWarnsAboutEmbedding() throws {
        var edit = EditModel.neutral
        // Thousands of control points survive in photons:settings even though crs: keeps only 16.
        edit.curve.white = (0..<3000).map { CurvePoint(u: Double($0) / 2999.0, v: pow(Double($0) / 2999.0, 1.3)) }
        edit.curve.red = (0..<3000).map { CurvePoint(u: Double($0) / 2999.0, v: Double($0) / 2999.0 * 0.9) }

        let blob = try XMPWriter.settingsBlob(edit)
        XCTAssertGreaterThan(blob.count, 8 * 1024, "this is meant to be a large payload")

        let url = scratch.appendingPathComponent("big.xmp")
        try XMPWriter.writeSidecar(for: edit, to: url)
        let back = try XCTUnwrap(XMPReadback.metadata(fromXMP: url))
        XCTAssertEqual(XMPReadback.settings(back), edit,
                       "the sidecar carries the full document, not the 16-point projection")

        // Container writes warn instead of silently truncating (docs §5 X-15).
        let (_, tight) = try XMPWriter.makeMetadata(for: edit,
                                                    context: XMPWriteContext(embeddedBlobLimit: 1024))
        XCTAssertTrue(tight.notes.contains { $0.contains("sidecar") },
                      "an oversized payload must be reported, got \(tight.notes)")
    }

    // MARK: - containers (X-14 lives here too)

    func testContainerRoundTripForImageIOFormats() throws {
        var edit = EditModel.neutral
        cropModel(&edit)
        edit.light.exposure = -1.25
        edit.effects.vignetteMidpoint = 62
        edit.geometry.flipHorizontal = true

        for (ext, type) in [("jpeg", UTType.jpeg), ("heic", UTType.heic),
                            ("tiff", UTType.tiff), ("png", UTType.png)] {
            let url = scratch.appendingPathComponent("shot.\(ext)")
            guard writeContainer(url, type) else {
                XCTFail("could not create a \(ext) container on this machine")
                continue
            }
            let report = try XMPWriter.embed(edit, into: url, context: XMPWriteContext(exifOrientation: 1))
            XCTAssertFalse(report.written.isEmpty)

            let back = try XCTUnwrap(XMPReadback.metadata(of: url), "\(ext): no metadata after embed")
            XCTAssertEqual(XMPReadback.string(back, "crs:WhiteBalance"), "As Shot", ext)
            assertClose(XMPReadback.double(back, "crs:CropLeft"), 0.1, "\(ext) CropLeft")
            assertClose(XMPReadback.double(back, "crs:CropRight"), 0.4, "\(ext) CropRight")
            assertClose(XMPReadback.double(back, "crs:Exposure2012"), -1.25, "\(ext) Exposure2012")
            assertClose(XMPReadback.double(back, "crs:PostCropVignetteMidpoint"), 62, "\(ext) vignette")
            // 派单 006: an as-shot document carries no temperature tag; the state is `As Shot`.
            XCTAssertNil(XMPReadback.tag(back, "photons:temperature"), "\(ext) wrote a nominal 6500")

            // HEIC normalises orientation to its own irot box and reports 1 back; JPEG/TIFF/PNG keep
            // the composed tag. Everything else must round-trip in all four containers.
            if ext != "heic" {
                XCTAssertEqual(XMPReadback.double(back, "tiff:Orientation"), 2, "\(ext) flip H on base 1")
            }
            let restored = try XCTUnwrap(XMPReadback.settings(back), "\(ext): settings blob")
            XCTAssertEqual(restored, edit, "\(ext): the lossless backup must survive the container")
        }
    }

    func testEmbedPreservesForeignKeys() throws {
        var edit = EditModel.neutral
        edit.light.exposure = 0.75

        let url = scratch.appendingPathComponent("foreign.jpg")
        XCTAssertTrue(writeContainer(url, .jpeg))

        // Pre-seed the container with somebody else's crs: keys and an xmpMM history.
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let existing = try XCTUnwrap(CGImageSourceCopyMetadataAtIndex(source, 0, nil))
        let seeded = try XCTUnwrap(CGImageMetadataCreateMutableCopy(existing))
        try XMPWriter.registerNamespaces(seeded)
        // 2026-10-28 (P0-6): `crs:Texture` used to be the foreign key here; S3.8 now writes it, so the
        // "somebody else's key" has to be one this document has no field for.
        XCTAssertTrue(CGImageMetadataSetValueWithPath(seeded, nil, "crs:DefringeGreenHue" as CFString,
                                                      NSNumber(value: 17)))
        XCTAssertTrue(CGImageMetadataSetValueWithPath(seeded, nil, "crs:SplitToningShadowHue" as CFString,
                                                      NSNumber(value: 33)))
        var err: Unmanaged<CFError>?
        _ = CGImageMetadataRegisterNamespaceForPrefix(
            seeded, "http://ns.adobe.com/xap/1.0/mm/" as CFString,
            "xmpMM" as CFString, &err)
        XCTAssertTrue(CGImageMetadataSetValueWithPath(seeded, nil, "xmpMM:History" as CFString,
                                                      "kept" as CFString))
        XCTAssertTrue(XMPWriter.canEmbed(url))
        let tmp = scratch.appendingPathComponent("seeded.jpg")
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(tmp as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        let options: [CFString: Any] = [kCGImageDestinationMetadata: seeded]
        XCTAssertTrue(CGImageDestinationCopyImageSource(dest, source, options as CFDictionary, &err))
        try FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: tmp, to: url)

        try XMPWriter.embed(edit, into: url)
        let back = try XCTUnwrap(XMPReadback.metadata(of: url))
        assertClose(XMPReadback.double(back, "crs:DefringeGreenHue"), 17, "crs:DefringeGreenHue survived")
        assertClose(XMPReadback.double(back, "crs:SplitToningShadowHue"), 33, "split toning survived")
        XCTAssertEqual(XMPReadback.string(back, "xmpMM:History"), "kept")
        assertClose(XMPReadback.double(back, "crs:Exposure2012"), 0.75, "our key landed")
    }

    /// 2026-10-28 (P0-6): S3.8's three numbers are Lightroom's own `crs:` keys with the same travel,
    /// so the mapping is the number — and, like every other default, absent at 0.
    func testPresenceTripleMapsToItsOwnCrsKeys() throws {
        var edit = EditModel.neutral
        let neutralKeys = try capturedCrsKeys(edit)
        XCTAssertNil(XMPReadback.tag(neutralKeys, "crs:Texture"), "0 不写键")
        XCTAssertNil(XMPReadback.tag(neutralKeys, "crs:Clarity"))
        XCTAssertNil(XMPReadback.tag(neutralKeys, "crs:Dehaze"))

        edit.effects.texture = 35
        edit.effects.clarity = -20
        edit.effects.dehaze = 70
        let keys = try capturedCrsKeys(edit)
        assertClose(XMPReadback.double(keys, "crs:Texture"), 35, "纹理 → crs:Texture")
        assertClose(XMPReadback.double(keys, "crs:Clarity"), -20, "清晰度 → crs:Clarity")
        assertClose(XMPReadback.double(keys, "crs:Dehaze"), 70, "去雾 → crs:Dehaze")
        // …and the lossless half still round-trips the document.
        let back = try XCTUnwrap(XMPReadback.settings(keys))
        XCTAssertEqual(back.effects.texture, 35)
        XCTAssertEqual(back.effects.clarity, -20)
        XCTAssertEqual(back.effects.dehaze, 70)
    }

    /// The XMP metadata the writer produces for a document, as a `CGImageMetadata`.
    private func capturedCrsKeys(_ edit: EditModel) throws -> CGImageMetadata {
        try XMPWriter.makeMetadata(for: edit).metadata
    }

    // MARK: - sidecar file

    func testSidecarPacketShapeAndMerge() throws {
        var edit = EditModel.neutral
        cropModel(&edit)

        let url = scratch.appendingPathComponent("nested/dir/shot.xmp")
        let report = try XMPWriter.writeSidecar(for: edit, to: url)
        XCTAssertGreaterThan(report.written.count, 0)

        let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("<?xpacket begin=\"\u{FEFF}\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?>"))
        XCTAssertTrue(text.hasSuffix("<?xpacket end=\"w\"?>\n"))
        XCTAssertTrue(text.contains("xmlns:crs=\"http://ns.adobe.com/camera-raw-settings/1.0/\""))

        // Idempotent: same document → byte-identical packet (stable key order, fixed padding).
        let again = scratch.appendingPathComponent("nested/dir/shot-copy.xmp")
        try XMPWriter.writeSidecar(for: edit, to: again)
        XCTAssertEqual(try Data(contentsOf: url), try Data(contentsOf: again))

        // Merging keeps foreign keys: we only ever touch paths we own.
        var metadata = CGImageMetadataCreateMutable()
        try XMPWriter.registerNamespaces(metadata)
        XCTAssertTrue(CGImageMetadataSetValueWithPath(metadata, nil, "crs:DefringeGreenHue" as CFString,
                                                      NSNumber(value: 12)))
        XCTAssertTrue(CGImageMetadataSetValueWithPath(metadata, nil, "photons:futureKey" as CFString,
                                                      "keep me" as CFString))
        let seededData = XMPWriter.wrap(try XMPWriter.xmpData(metadata))
        let seededURL = scratch.appendingPathComponent("nested/dir/seeded.xmp")
        try seededData.write(to: seededURL)

        try XMPWriter.writeSidecar(for: .neutral, to: seededURL)
        let merged = try XCTUnwrap(XMPReadback.metadata(fromXMP: seededURL))
        assertClose(XMPReadback.double(merged, "crs:DefringeGreenHue"), 12, "others' crs: keys survive")
        XCTAssertEqual(XMPReadback.string(merged, "photons:futureKey"), "keep me")
        // 派单 006: `photons:temperature` is absent for as shot, so "our key landed" is asked of a
        // key that always exists.
        XCTAssertNotNil(XMPReadback.tag(merged, "photons:processVersion"), "our key landed")
        XCTAssertNil(XMPReadback.tag(merged, "photons:temperature"), "as shot must not be a number")
        XCTAssertEqual(XMPReadback.string(merged, "crs:WhiteBalance"), "As Shot")

        // An unreadable packet is backed up before being replaced.
        let junkURL = scratch.appendingPathComponent("nested/dir/junk.xmp")
        try Data("not xmp".utf8).write(to: junkURL)
        try XMPWriter.writeSidecar(for: .neutral, to: junkURL)
        let backups = try FileManager.default.contentsOfDirectory(atPath: junkURL.deletingLastPathComponent().path)
            .filter { $0.contains("junk.xmp.bak-") }
        XCTAssertEqual(backups.count, 1, "unreadable sidecars must be backed up, not silently eaten")
    }

    // MARK: - locale (X-10)

    func testLocaleDoesNotChangeDecimalSeparator() throws {
        // The pointer from setlocale() is reused storage — copy it before switching, or the
        // restore silently leaves the process in de_DE and every later strtod sees "0,5".
        guard let raw = setlocale(LC_NUMERIC, nil) else { throw XCTSkip("no LC_NUMERIC") }
        let previous = String(cString: raw)
        guard setlocale(LC_NUMERIC, "de_DE.UTF-8") != nil else {
            throw XCTSkip("de_DE.UTF-8 is not installed on this machine")
        }
        defer { _ = setlocale(LC_NUMERIC, previous) }

        var edit = EditModel.neutral
        edit.light.exposure = 0.35
        edit.light.tint = -0.5
        let packet = try XMPWriter.packet(for: edit).data
        let text = String(decoding: packet, as: UTF8.self)
        XCTAssertFalse(text.contains("0,35"), "XMP is locale-independent; '.' only (B10)")

        let back = try XCTUnwrap(CGImageMetadataCreateFromXMPData(packet as CFData))
        assertClose(XMPReadback.double(back, "crs:Exposure2012"), 0.35, "exposure under de_DE")
    }

    // MARK: - unsupported containers stay sidecar-only

    func testRawContainersAreRefused() throws {
        let url = scratch.appendingPathComponent("shot.dng")
        try Data([0x00]).write(to: url)
        XCTAssertFalse(XMPWriter.canEmbed(url))
        XCTAssertThrowsError(try XMPWriter.embed(.neutral, into: url)) { error in
            guard case XMPExportError.unsupportedContainer = error else {
                return XCTFail("expected unsupportedContainer, got \(error)")
            }
        }
    }
}
