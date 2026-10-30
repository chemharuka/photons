import XCTest
import Metal
import ImageIO
import CoreGraphics
import CoreVideo
import PhotonsCore
@testable import PhotonsExport

/// 100 — HDR export: the linear exit in S4, and the gain-map HEIC writer.
///
/// The tests are numeric, not visual: the acceptance is 「读回 contentHeadroom + 像素数值」, so every
/// assertion here reads the file back (headroom, auxiliary image, reconstructed pixels) instead of
/// trusting the value we passed in. Synthetic `LinearImage`s keep the numbers reproducible and the
/// suite independent of a RAW fixture.
final class HDRGainMapTests: XCTestCase {

    // MARK: - fixtures

    private func makeGraph(_ value: Float, w: Int = 96, h: Int = 64,
                           gray: Bool = false) throws -> RenderGraph {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        var rgba = [Float16](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                // A smooth 0.05 … value ramp: no hard edge for HEIC to ring on, but every level
                // between the SDR ceiling and the peak is represented.
                let t = Float(x) / Float(max(1, w - 1))
                let v = 0.05 + (value - 0.05) * t
                let o = (y * w + x) * 4
                rgba[o] = Float16(v)
                rgba[o + 1] = Float16(gray ? v : v * 0.85)
                rgba[o + 2] = Float16(gray ? v : v * 0.7)
                rgba[o + 3] = 1
            }
        }
        let image = LinearImage(width: w, height: h, rgba: rgba,
                               colorSpace: "extendedLinearSRGB", decoderVersion: "hdr-gainmap-test")
        return try RenderGraph(input: RenderInput(image: image, identity: "hdr-gainmap-test"),
                               textureRetention: .none)
    }

    /// The same document rendered the way the exporter does it: SDR base (headroom 1) plus the
    /// linear exit.
    private func renderPair(value: Float = 4, w: Int = 96, h: Int = 64, gray: Bool = false)
        throws -> (sdr: DisplayImage, linear: LinearPixels) {
        let graph = try makeGraph(value, w: w, h: h, gray: gray)
        defer { graph.releaseAllTextures() }
        let sdr = try XCTUnwrap(try graph.render(.neutral, options: RenderOptions(
            scale: 1, display: DisplayOptions(primaries: .sRGB, bitDepth: 8, headroom: 1),
            useCache: false)).display)
        let linear = try XCTUnwrap(try graph.render(.neutral, options: RenderOptions(
            scale: 1, display: DisplayOptions(primaries: .sRGB, bitDepth: 16, headroom: 1,
                                             linearOutput: true),
            useCache: false)).display)
        XCTAssertEqual(sdr.width, linear.width)
        XCTAssertEqual(sdr.height, linear.height)
        return (sdr, LinearPixels(linear))
    }

    private func tempURL(_ name: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-hdr-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }

    // MARK: - 1. the linear exit (S4)

    func testLinearExitIsLinearAndKeepsValuesAboveOne() throws {
        let (sdr, linear) = try renderPair(value: 4)
        let sdrPeak = GainMapHEIC.peak(of: LinearPixels(sdr))
        let linearPeak = GainMapHEIC.peak(of: linear)

        // The display encoding clamps at headroom = 1 …
        XCTAssertLessThanOrEqual(sdrPeak, 1.0 + 1e-6)
        // … and the linear exit does not.
        XCTAssertGreaterThan(linearPeak, 1.5)
        XCTAssertGreaterThan(GainMapHEIC.peak(of: linear), GainMapHEIC.peak(of: LinearPixels(sdr)))
    }

    func testLinearExitIsTheInverseOETFOfTheSDRBaseBelowWhite() throws {
        let (sdr, linear) = try renderPair(value: 4)
        // Every mid-tone (encoded < 1) must satisfy encoded = sRGB_OETF(linear).
        var worst = 0.0
        var n = 0
        for i in 0..<(sdr.width * sdr.height) {
            for c in 0..<3 {
                let e = Double(sdr.rgba[i * 4 + c])
                guard e > 0.02, e < 0.95 else { continue }
                let l = Double(linear.rgba[i * 4 + c])
                let back = l <= 0.0031308 ? 12.92 * l : 1.055 * pow(l, 1 / 2.4) - 0.055
                worst = max(worst, abs(back - e))
                n += 1
            }
        }
        XCTAssertGreaterThan(n, 100)
        XCTAssertLessThan(worst, 1e-3, "the linear exit must be the same picture without its OETF")
    }

    func testDefaultDisplayKeyIsUnchanged() {
        XCTAssertEqual(DisplayOptions().keyString, "sRGB;bits=8;headroom=1.000")
        XCTAssertEqual(DisplayOptions(primaries: .displayP3, bitDepth: 16, headroom: 2).keyString,
                       "displayP3;bits=16;headroom=2.000")
        XCTAssertEqual(DisplayOptions(linearOutput: true).keyString,
                       "sRGB;bits=8;headroom=1.000;linear=true")
    }

    func testTheSDRRenderIsByteIdenticalWithAndWithoutTheHDRFlag() throws {
        let graph = try makeGraph(4)
        defer { graph.releaseAllTextures() }
        func sdr(_ options: RenderOptions) throws -> DisplayImage {
            try XCTUnwrap(try graph.render(.neutral, options: options).display)
        }
        let plain = try sdr(RenderOptions(scale: 1, display: DisplayOptions(headroom: 1),
                                          useCache: false))
        // What the exporter does with HDR off and on is the *same* SDR render; the linear render is a
        // second pass with a different DisplayOptions. This pins that the first pass cannot move.
        _ = try sdr(RenderOptions(scale: 1, display: DisplayOptions(headroom: 1, linearOutput: true),
                                  useCache: false))
        let again = try sdr(RenderOptions(scale: 1, display: DisplayOptions(headroom: 1),
                                          useCache: false))
        XCTAssertEqual(plain.sha256(), again.sha256())
    }

    // MARK: - 2. the preset

    func testHDRIsHEICOnlyAndRoundTripsThroughThePresetFile() throws {
        let hdr = HDRExport(enabled: true, gainMap: .apple, halfSize: true,
                            headroom: .manual(3.5))
        let preset = ExportPreset(format: .heic, colorSpace: .displayP3, hdr: hdr)
        XCTAssertEqual(try preset.validated(), preset)
        let back = try ExportPreset.load(from: try writePreset(preset))
        XCTAssertEqual(back, preset)

        XCTAssertThrowsError(try ExportPreset(format: .jpeg, hdr: hdr).validated()) { error in
            XCTAssertTrue("\(error)".contains("HEIC"))
        }
        XCTAssertThrowsError(try ExportPreset(format: .heic,
                                             hdr: HDRExport(headroom: .manual(1.0))).validated())
        // A preset written before 100 still decodes: `hdr` is absent, not required.
        let legacy = #"{"format":"jpeg","quality":0.9,"bitDepth":8,"colorSpace":"sRGB","writeXMP":false,"nameTemplate":"{name}"}"#
        let decoded = try JSONDecoder().decode(ExportPreset.self, from: Data(legacy.utf8))
        XCTAssertNil(decoded.hdr)
    }

    private func writePreset(_ preset: ExportPreset) throws -> URL {
        let url = tempURL("preset.json")
        try preset.save(to: url)
        return url
    }

    // MARK: - 3. ISO RGB gain map

    @available(macOS 15.0, *)
    func testISORGainMapIsWrittenAndReconstructsTheHDRPicture() throws {
        let (sdr, linear) = try renderPair(value: 4)
        let url = tempURL("iso.heic")
        let result = try GainMapHEIC.write(sdr: sdr, linear: linear, to: url,
                                           options: HDRGainMapOptions(gainMap: .iso, halfSize: false,
                                                                      quality: 1.0))
        XCTAssertTrue(result.isHDR)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        // ImageIO transcodes the RGB aux to a 4:2:0 HEVC item; what the container carries is the
        // ISO item plus a `tmap` headroom item (the same shape `heif-item-dump.py` shows).
        XCTAssertTrue(hasItemType("tmap", url))
        let aux = try auxInfo(url, type: kCGImageAuxiliaryDataTypeISOGainMap)
        let description = try XCTUnwrap(aux[kCGImageAuxiliaryDataInfoDataDescription] as? [String: Any])
        XCTAssertEqual(intValue(description["Width"]), sdr.width)
        XCTAssertEqual(intValue(description["Height"]), sdr.height)
        XCTAssertEqual(intValue(description["PixelFormat"]),
                       Int(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange))

        // Headroom is read back from the file, and the map really is an RGB ratio.
        let read = try XCTUnwrap(GainMapHEIC.readHeadroom(at: url))
        XCTAssertEqual(read, result.headroom, accuracy: result.headroom * 0.05)

        // ImageIO does not expose the compressed ISO item's bytes (`kCGImageAuxiliaryDataInfoData`
        // is absent for an HEVC-coded aux image), so the pixel maths is checked against the same
        // `GainMapPixels` the writer handed to ImageIO — the file-level check above is headroom +
        // item shape.
        let map = try GainMapPixels(sdr: sdr, linear: linear, headroom: result.headroom,
                                    mode: .iso, halfSize: false)
        let psnr = try reconstructPSNR(url: url, map: map, sdr: sdr, linear: linear,
                                       headroom: result.headroom, apple: false)
        XCTAssertGreaterThanOrEqual(psnr, 40, "ISO RGB reconstruction PSNR \(psnr) dB")
    }

    @available(macOS 15.0, *)
    func testISOHalfSizeMapIsHalfTheDimensions() throws {
        let (sdr, linear) = try renderPair(value: 4)
        let url = tempURL("iso-half.heic")
        let result = try GainMapHEIC.write(sdr: sdr, linear: linear, to: url,
                                           options: HDRGainMapOptions(gainMap: .iso, halfSize: true,
                                                                      quality: 1.0))
        XCTAssertTrue(result.isHDR)
        let aux = try auxInfo(url, type: kCGImageAuxiliaryDataTypeISOGainMap)
        let description = try XCTUnwrap(aux[kCGImageAuxiliaryDataInfoDataDescription] as? [String: Any])
        XCTAssertEqual(intValue(description["Width"]), sdr.width / 2)
        XCTAssertEqual(intValue(description["Height"]), sdr.height / 2)
        let map = try GainMapPixels(sdr: sdr, linear: linear, headroom: result.headroom,
                                    mode: .iso, halfSize: true)
        let psnr = try reconstructPSNR(url: url, map: map, sdr: sdr, linear: linear,
                                       headroom: result.headroom, apple: false)
        XCTAssertGreaterThanOrEqual(psnr, 40, "half-size ISO reconstruction PSNR \(psnr) dB")
    }

    /// 163 §1.1 — the *default* export (no explicit `halfSize`) is a half-size map. The default was
    /// full size before 163; this test reads the written item back so the default cannot drift.
    @available(macOS 15.0, *)
    func testDefaultGainMapIsHalfSizeAndCanStillBeFullSize() throws {
        let (sdr, linear) = try renderPair(value: 4)
        let base = sdr.withLinear(linear)

        let defaults = tempURL("default-half.heic")
        try Exporter.write(base, to: defaults,
                           options: ExportOptions(format: .heic, quality: 1.0, bitDepth: 8,
                                                  hdr: HDRExport(kind: .gainMap, gainMap: .iso)))
        let defaultAux = try auxInfo(defaults, type: kCGImageAuxiliaryDataTypeISOGainMap)
        let defaultDescription = try XCTUnwrap(
            defaultAux[kCGImageAuxiliaryDataInfoDataDescription] as? [String: Any])
        XCTAssertEqual(intValue(defaultDescription["Width"]), (sdr.width + 1) / 2)
        XCTAssertEqual(intValue(defaultDescription["Height"]), (sdr.height + 1) / 2)

        let full = tempURL("explicit-full.heic")
        try Exporter.write(base, to: full,
                           options: ExportOptions(format: .heic, quality: 1.0, bitDepth: 8,
                                                  hdr: HDRExport(kind: .gainMap, gainMap: .iso,
                                                                 halfSize: false)))
        let fullAux = try auxInfo(full, type: kCGImageAuxiliaryDataTypeISOGainMap)
        let fullDescription = try XCTUnwrap(
            fullAux[kCGImageAuxiliaryDataInfoDataDescription] as? [String: Any])
        XCTAssertEqual(intValue(fullDescription["Width"]), sdr.width)
        XCTAssertEqual(intValue(fullDescription["Height"]), sdr.height)
    }

    /// 163 §1.1 — an odd edge rounds **up** (`ceil(base / 2)`), not down. Checked on the pixel buffer
    /// directly because HEIF's 4:2:0 auxiliary item may pad odd sizes.
    func testHalfSizeUsesCeilForOddDimensions() throws {
        let (sdr, linear) = try renderPair(value: 4, w: 95, h: 63)
        let map = try GainMapPixels(sdr: sdr, linear: linear, headroom: 4,
                                    mode: .iso, halfSize: true)
        XCTAssertEqual(map.width, 48)
        XCTAssertEqual(map.height, 32)
        let full = try GainMapPixels(sdr: sdr, linear: linear, headroom: 4,
                                     mode: .iso, halfSize: false)
        XCTAssertEqual(full.width, 95)
        XCTAssertEqual(full.height, 63)
    }

    @available(macOS 15.0, *)
    func testISOMonoMapIsOneComponent() throws {
        let (sdr, linear) = try renderPair(value: 4)
        let url = tempURL("mono.heic")
        _ = try GainMapHEIC.write(sdr: sdr, linear: linear, to: url,
                                  options: HDRGainMapOptions(gainMap: .mono, quality: 1.0))
        let aux = try auxInfo(url, type: kCGImageAuxiliaryDataTypeISOGainMap)
        let description = try XCTUnwrap(aux[kCGImageAuxiliaryDataInfoDataDescription] as? [String: Any])
        // A mono ISO map stays a one-component image (no RGB→YUV conversion).
        XCTAssertEqual(intValue(description["PixelFormat"]), Int(kCVPixelFormatType_OneComponent8))
    }

    // MARK: - 4. Apple gain map

    func testAppleGainMapCarriesHeadroomAndTMap() throws {
        // Apple's map is a **luminance** ratio: on a coloured picture per-channel clipping makes it
        // approximate by construction. A neutral ramp measures the map itself.
        let (sdr, linear) = try renderPair(value: 4, gray: true)
        let url = tempURL("apple.heic")
        let result = try GainMapHEIC.write(sdr: sdr, linear: linear, to: url,
                                           options: HDRGainMapOptions(gainMap: .apple, halfSize: false,
                                                                      quality: 1.0))
        XCTAssertTrue(result.isHDR)
        // toGainMapHDR's `-g` spelling carries the headroom in **MakerNote 33/48**, not in a `tmap`
        // item (measured on its own `bin/toGainMapHDR -g` output: HDRGainMap aux + MakerApple,
        // item table has no `tmap`). We follow the reference implementation, as the spec says.
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(
            try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil)), 0, nil) as? [String: Any])
        let maker = try XCTUnwrap(props[kCGImagePropertyMakerAppleDictionary as String] as? [String: Any])
        XCTAssertNotNil(maker["33"])
        XCTAssertNotNil(maker["48"])

        let aux = try auxInfo(url, type: kCGImageAuxiliaryDataTypeHDRGainMap)
        let description = try XCTUnwrap(aux[kCGImageAuxiliaryDataInfoDataDescription] as? [String: Any])
        XCTAssertEqual(intValue(description["Width"]), sdr.width)

        let read = try XCTUnwrap(GainMapHEIC.readHeadroom(at: url))
        XCTAssertEqual(read, result.headroom, accuracy: result.headroom * 0.05)

        let map = try GainMapPixels(sdr: sdr, linear: linear, headroom: result.headroom,
                                    mode: .apple, halfSize: false)
        let psnr = try reconstructPSNR(url: url, map: map, sdr: sdr, linear: linear,
                                       headroom: result.headroom, apple: true)
        XCTAssertGreaterThanOrEqual(psnr, 40, "Apple reconstruction PSNR \(psnr) dB")
    }

    // MARK: - 5. SDR fallback

    @available(macOS 15.0, *)
    func testAnSDRSourceFallsBackToAPlainHEICWithAWarning() throws {
        // Peak below 1.05: render a normal 0…0.9 picture and ask for a gain map anyway.
        let (sdr, linear) = try renderPair(value: 0.9)
        let url = tempURL("sdr.heic")
        let result = try GainMapHEIC.write(sdr: sdr, linear: linear, to: url)
        XCTAssertFalse(result.isHDR)
        XCTAssertEqual(result.warnings.count, 1)
        XCTAssertTrue(result.warnings[0].contains("below 1.05"))
        XCTAssertTrue(result.warnings[0].contains("SDR"))
        // Same filename, and no auxiliary image to trip a reader that expected HDR.
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNil(CGImageSourceCopyAuxiliaryDataInfoAtIndex(
            try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil)), 0,
            kCGImageAuxiliaryDataTypeISOGainMap))
        XCTAssertNil(GainMapHEIC.readHeadroom(at: url).flatMap { $0 > 1.01 ? $0 : nil })
    }

    func testDisabledHDRIsTheOldEncoderByteForByte() throws {
        let (sdr, _) = try renderPair(value: 4)
        var options = ExportOptions(format: .heic, quality: 0.8, bitDepth: 8)
        let plain = tempURL("plain.heic")
        try Exporter.write(sdr, to: plain, options: options)

        options.hdr = HDRExport(enabled: false)
        let disabled = tempURL("disabled.heic")
        try Exporter.write(sdr.withLinear(nil), to: disabled, options: options)

        XCTAssertEqual(try Data(contentsOf: plain), try Data(contentsOf: disabled))
    }

    // MARK: - helpers

    private func intValue(_ any: Any?) -> Int? {
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String { return Int(s) }
        return nil
    }

    /// The gain-map item as ImageIO hands it back. ISO maps come back as full-range 4:2:0 (`420f`)
    /// even though we supplied `32ARGB`: ImageIO compresses the auxiliary image as an HEVC item.
    /// Apple's map stays `L8`. `BT.2020` non-constant luminance is the matrix the gain-map `colr`
    /// box declares (`nclx` 9/8/9, full range).
    private func yuvGain(_ data: Data, format: Int, x: Int, y: Int, rowBytes: Int,
                         height: Int) -> [Double] {
        if format == Int(kCVPixelFormatType_OneComponent8) {
            let v = Double(data[y * rowBytes + x]) / 255
            return [v, v, v]
        }
        if format == Int(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) {
            let luma = Double(data[y * rowBytes + x]) / 255
            let chromaRow = height * rowBytes + (y / 2) * rowBytes
            let cx = (x / 2) * 2
            let cb = Double(data[chromaRow + cx]) / 255 - 0.5
            let cr = Double(data[chromaRow + cx + 1]) / 255 - 0.5
            let r = luma + 1.4746 * cr
            let b = luma + 1.8814 * cb
            let g = (luma - 0.2627 * r - 0.0593 * b) / 0.6780
            return [max(0, r), max(0, g), max(0, b)]
        }
        let o = y * rowBytes + x * 4
        return [Double(data[o + 1]) / 255, Double(data[o + 2]) / 255, Double(data[o + 3]) / 255]
    }

    private func auxInfo(_ url: URL, type: CFString) throws -> [CFString: Any] {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let info = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, type)
        return try XCTUnwrap(info as? [CFString: Any], "no \(type) auxiliary data")
    }

    /// True when the HEIF item table names an item of `type` (e.g. `tmap`). The `infe` box stores the
    /// four-character type verbatim, so a byte search is what `heif-item-dump.py` does too.
    private func hasItemType(_ type: String, _ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        return data.range(of: Data(type.utf8)) != nil
    }

    /// Reconstruct HDR from the file (base pixels × decoded gain map) and return PSNR against the
    /// linear render the writer was given. Everything is decoded from the file, so this is the
    /// acceptance's 「解开后 HDR 还原图」 measured numerically.
    private func reconstructPSNR(url: URL, map: GainMapPixels, sdr: DisplayImage,
                                 linear: LinearPixels, headroom: Double, apple: Bool) throws -> Double {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let cg = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let base = try pixels(cg)

        let gain = map.data
        let gw = map.width
        let gh = map.height
        let rowBytes = map.rowBytes
        let format = map.channels == 1 ? Int(kCVPixelFormatType_OneComponent8)
                                       : Int(kCVPixelFormatType_32ARGB)

        var sum = 0.0
        var n = 0
        let peak = max(1.0, GainMapHEIC.peak(of: linear))
        for y in 0..<sdr.height {
            let gy = min(gh - 1, y * gh / sdr.height)
            for x in 0..<sdr.width {
                let gx = min(gw - 1, x * gw / sdr.width)
                let i = (y * sdr.width + x) * 4
                let gains = yuvGain(gain, format: format, x: gx, y: gy, rowBytes: rowBytes,
                                    height: gh)
                for c in 0..<3 {
                    let g = gains[c]
                    let baseLinear = GainMapHEIC.srgbToLinear(Float(base[i + c]) / 255)
                    let hdr: Double
                    if apple {
                        let r = g < 0.081 ? g / 4.5 : pow((g + 0.099) / 1.099, 1 / 0.45)
                        hdr = Double(baseLinear) * (1 + r * (headroom - 1))
                    } else {
                        hdr = Double(baseLinear) * pow(2, g * log2(headroom))
                    }
                    let want = Double(linear.rgba[i + c])
                    let d = hdr - want
                    sum += d * d
                    n += 1
                }
            }
        }
        let mse = sum / Double(max(1, n))
        return 10 * log10(peak * peak / max(mse, 1e-12))
    }

    /// The base image as top-down RGBA8 in sRGB. The flip puts buffer row 0 at the picture's top, so
    /// it matches `DisplayImage.rgba`'s layout.
    private func pixels(_ cg: CGImage) throws -> [UInt8] {
        let w = cg.width, h = cg.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        try bytes.withUnsafeMutableBytes { buf in
            let context = try XCTUnwrap(CGContext(data: buf.baseAddress, width: w, height: h,
                                                  bitsPerComponent: 8, bytesPerRow: w * 4,
                                                  space: space,
                                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            // Buffer row 0 must be the picture's top row, matching `DisplayImage.rgba`.
            context.translateBy(x: 0, y: CGFloat(h))
            context.scaleBy(x: 1, y: -1)
            context.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return bytes
    }
}
