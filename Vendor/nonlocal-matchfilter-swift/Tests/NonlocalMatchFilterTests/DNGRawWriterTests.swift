//
//  DNGRawWriterTests.swift
//
//  The writer's contract is "metadata survives, pixels are what you passed in".
//  These tests hold it to that on a synthetic DNG the test builds itself, so the
//  claims do not depend on a camera file being present in the repo:
//
//   - one image in, one image out, byte-identical whether or not the alternate
//     API is used with `nil`;
//   - two images in, two images out: IFD0 is the primary, `330` points at an IFD
//     that is also a lossless-JPEG CFA page, and both decode back to the exact
//     samples they were given;
//   - the preview stays reachable on the IFD chain (IFD0 → IFD1), which is the
//     thing the alternate page must not displace.
//

import XCTest
@testable import NonlocalMatchFilter

final class DNGRawWriterTests: XCTestCase {

    // MARK: - synthetic source DNG

    private struct Entry {
        let tag: UInt16
        let type: UInt16
        let count: Int
        let value: [UInt8]
    }

    private func u16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
    private func u32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }

    /// A minimal *capture-shaped* DNG: IFD0 is the CFA raw in one uncompressed strip, and IFD1 is a
    /// tiny RGB preview. Deliberately no SubIFDs — that is the layout a camera writes, and the one
    /// the writer has to accept.
    private func syntheticDNG(width: Int, height: Int, samples: [UInt16],
                              to url: URL) throws {
        let previewW = 4, previewH = 3
        let preview = [UInt8](repeating: 0x40, count: previewW * previewH * 3)
        let strip = samples.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }

        let ifd0Count = 16
        let ifd1Count = 11
        let head0 = 2 + 12 * ifd0Count + 4
        let head1 = 2 + 12 * ifd1Count + 4
        let offIFD1 = 8 + head0
        let ifd1Payload = 6                      // 258 with three SHORTs, the only >4-byte value
        var dataStart = offIFD1 + head1 + ifd1Payload
        dataStart += (4 - dataStart % 4) % 4
        let stripOffset = dataStart
        let previewOffset = stripOffset + strip.count

        let ifd0: [Entry] = [
            Entry(tag: 254, type: 4, count: 1, value: u32(0)),
            Entry(tag: 256, type: 4, count: 1, value: u32(UInt32(width))),
            Entry(tag: 257, type: 4, count: 1, value: u32(UInt32(height))),
            Entry(tag: 258, type: 3, count: 1, value: u16(16)),
            Entry(tag: 259, type: 3, count: 1, value: u16(1)),
            Entry(tag: 262, type: 3, count: 1, value: u16(32803)),
            Entry(tag: 273, type: 4, count: 1, value: u32(UInt32(stripOffset))),
            Entry(tag: 277, type: 3, count: 1, value: u16(1)),
            Entry(tag: 278, type: 4, count: 1, value: u32(UInt32(height))),
            Entry(tag: 279, type: 4, count: 1, value: u32(UInt32(strip.count))),
            Entry(tag: 284, type: 3, count: 1, value: u16(1)),
            Entry(tag: 339, type: 3, count: 1, value: u16(1)),
            Entry(tag: 33421, type: 3, count: 2, value: u16(2) + u16(2)),
            Entry(tag: 33422, type: 1, count: 4, value: [0, 1, 1, 2]),
            Entry(tag: 50714, type: 3, count: 1, value: u16(0)),
            Entry(tag: 50717, type: 3, count: 1, value: u16(60000)),
        ]
        let ifd1: [Entry] = [
            Entry(tag: 254, type: 4, count: 1, value: u32(1)),
            Entry(tag: 256, type: 4, count: 1, value: u32(UInt32(previewW))),
            Entry(tag: 257, type: 4, count: 1, value: u32(UInt32(previewH))),
            Entry(tag: 258, type: 3, count: 3, value: u16(8) + u16(8) + u16(8)),
            Entry(tag: 259, type: 3, count: 1, value: u16(1)),
            Entry(tag: 262, type: 3, count: 1, value: u16(2)),
            Entry(tag: 273, type: 4, count: 1, value: u32(UInt32(previewOffset))),
            Entry(tag: 277, type: 3, count: 1, value: u16(3)),
            Entry(tag: 278, type: 4, count: 1, value: u32(UInt32(previewH))),
            Entry(tag: 279, type: 4, count: 1, value: u32(UInt32(preview.count))),
            Entry(tag: 284, type: 3, count: 1, value: u16(1)),
        ]

        func writeIFD(_ out: inout Data, _ entries: [Entry], payloadOffset: Int, next: UInt32) {
            out.append(contentsOf: u16(UInt16(entries.count)))
            var payload = Data()
            for e in entries {
                out.append(contentsOf: u16(e.tag))
                out.append(contentsOf: u16(e.type))
                out.append(contentsOf: u32(UInt32(e.count)))
                if e.value.count <= 4 {
                    var inline = e.value
                    while inline.count < 4 { inline.append(0) }
                    out.append(contentsOf: inline)
                } else {
                    out.append(contentsOf: u32(UInt32(payloadOffset + payload.count)))
                    payload.append(contentsOf: e.value)
                    if payload.count % 2 != 0 { payload.append(0) }
                }
            }
            out.append(contentsOf: u32(next))
            out.append(payload)
        }

        var data = Data([0x49, 0x49])
        data.append(contentsOf: u16(42))
        data.append(contentsOf: u32(8))
        writeIFD(&data, ifd0, payloadOffset: 8 + head0, next: UInt32(offIFD1))
        writeIFD(&data, ifd1, payloadOffset: offIFD1 + head1, next: 0)
        while data.count < stripOffset { data.append(0) }
        data.append(contentsOf: strip)
        data.append(contentsOf: preview)
        try data.write(to: url)
    }

    // MARK: - decoding a written page

    /// Decodes one IFD's tiles. Uses the library's SOF3 decoder, which is the read half of the
    /// writer's encoder and is what a DNG reader has to agree with.
    private func decode(_ data: Data, entries: [UInt16: TIFFEntry],
                        width: Int, height: Int) throws -> [UInt16] {
        let tileWidth = Int(try XCTUnwrap(entries[322]?.firstUInt32))
        let tileHeight = Int(try XCTUnwrap(entries[323]?.firstUInt32))
        let offsets = try XCTUnwrap(entries[324]).uint32Array
        let counts = try XCTUnwrap(entries[325]).uint32Array
        let nx = (width + tileWidth - 1) / tileWidth
        let ny = (height + tileHeight - 1) / tileHeight
        var samples = [UInt16](repeating: 0, count: width * height)
        var index = 0
        for ty in 0..<ny {
            for tx in 0..<nx {
                let start = Int(offsets[index]), count = Int(counts[index])
                let pixels = try SOF3.decode([UInt8](data[start..<start + count]),
                                             expectWidth: tileWidth, expectHeight: tileHeight)
                for y in 0..<tileHeight {
                    let dy = ty * tileHeight + y
                    if dy >= height { break }
                    let copyWidth = min(tileWidth, width - tx * tileWidth)
                    for x in 0..<copyWidth {
                        samples[dy * width + tx * tileWidth + x] = pixels[y * tileWidth + x]
                    }
                }
                index += 1
            }
        }
        return samples
    }

    private func tempURL(_ name: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nlmf-writer-\(UUID().uuidString)-\(name)")
    }

    // MARK: - tests

    /// The single-image path must not change: the convenience overload and an explicit `nil`
    /// alternate have to produce the same bytes, and neither may grow a `330`.
    func testSingleImageWriteIsUnchangedByTheAlternateAPI() throws {
        let width = 96, height = 80
        let samples = (0..<(width * height)).map { UInt16(($0 * 37) % 60000) }
        let source = tempURL("src.dng")
        try syntheticDNG(width: width, height: height, samples: samples, to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let a = tempURL("one.dng"), b = tempURL("two.dng")
        defer {
            try? FileManager.default.removeItem(at: a)
            try? FileManager.default.removeItem(at: b)
        }
        let r1 = try DNGRawWriter.write(samples: samples, width: width, height: height,
                                        from: source, to: a)
        let r2 = try DNGRawWriter.write(primary: DNGRawWriter.Layer(samples: samples),
                                        alternate: nil, width: width, height: height,
                                        from: source, to: b)

        XCTAssertEqual(try Data(contentsOf: a), try Data(contentsOf: b))
        XCTAssertFalse(r1.hasAlternate)
        XCTAssertFalse(r2.hasAlternate)
        XCTAssertEqual(r1.alternateTileCount, 0)
        XCTAssertEqual(r1.alternateByteCount, 0)

        let data = try Data(contentsOf: a)
        let ifd0 = try TIFFReader.readIFD(data, at: 8)
        XCTAssertNil(ifd0[330], "a single-image file must not advertise SubIFDs")
        XCTAssertEqual(ifd0[262]?.firstUInt32, 32803)
        XCTAssertEqual(ifd0[259]?.firstUInt32, 7)
        XCTAssertEqual(try decode(data, entries: ifd0, width: width, height: height), samples)

        // The preview is still on the IFD chain, one page after IFD0.
        let next = try XCTUnwrap(TIFFReader.nextIFDOffset(data, after: 8))
        XCTAssertNotEqual(next, 0)
        let ifd1 = try TIFFReader.readIFD(data, at: Int(next))
        XCTAssertNotNil(ifd1[273], "the preview page lost its strips")
        XCTAssertEqual(ifd1[262]?.firstUInt32, 2)
    }

    /// Two mosaics in, two mosaics out: the original at `SubIFDs[0]`, the denoised one at
    /// `SubIFDs[1]`, both bit-exact, with IFD0 holding the preview.
    ///
    /// The order is not cosmetic. ImageIO/CIRAWFilter decode the first `NewSubfileType = 0` raw in
    /// `SubIFDs`, so `SubIFDs[0]` is what every standard reader shows; if the denoised layer came
    /// first, opening the file would silently show the filtered image.
    func testDualWriteKeepsBothMosaicsAndTheirValues() throws {
        let width = 96, height = 80
        let primary = (0..<(width * height)).map { UInt16(($0 * 37) % 60000) }
        // Distinguishable everywhere, and in the same 16-bit range.
        let denoised = primary.map { UInt16(Int($0) / 2 + 100) }
        let source = tempURL("src.dng")
        try syntheticDNG(width: width, height: height, samples: primary, to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let out = tempURL("dual.dng")
        defer { try? FileManager.default.removeItem(at: out) }
        let result = try DNGRawWriter.write(
            primary: DNGRawWriter.Layer(samples: primary),
            alternate: DNGRawWriter.Layer(samples: denoised,
                                          label: "denoised alternate: test strength=1.0"),
            width: width, height: height, from: source, to: out)

        XCTAssertTrue(result.hasAlternate)
        XCTAssertGreaterThan(result.alternateTileCount, 0)
        XCTAssertGreaterThan(result.alternateByteCount, 0)
        XCTAssertGreaterThan(result.byteCount, result.alternateByteCount)

        let data = try Data(contentsOf: out)
        let ifd0 = try TIFFReader.readIFD(data, at: 8)
        // IFD0 is the preview, not a raw.
        XCTAssertEqual(ifd0[254]?.firstUInt32, 1, "IFD0 must be the reduced-resolution page")
        XCTAssertEqual(ifd0[262]?.firstUInt32, 2, "IFD0 must be RGB, i.e. the preview")
        XCTAssertNotNil(ifd0[273], "IFD0 must still carry the preview's strips")
        XCTAssertEqual(TIFFReader.nextIFDOffset(data, after: 8), 0,
                       "the raw pages hang off 330, not off the IFD chain")

        // Exactly two SubIFDs, original first, both CFA/lossless-JPEG at full size.
        let subIFDs = try XCTUnwrap(ifd0[330])
        XCTAssertEqual(subIFDs.count, 2)
        XCTAssertEqual(subIFDs.type, 4)
        let offsets = subIFDs.uint32Array
        XCTAssertEqual(offsets.count, 2)
        let original = try TIFFReader.readIFD(data, at: Int(offsets[0]))
        let alternate = try TIFFReader.readIFD(data, at: Int(offsets[1]))
        // Both pages are subfiletype 0 — order alone decides which one a decoder renders. Two
        // subfiletype-0 raws stay faithful because the alternate repeats only sample-descriptive
        // tags; see DNGRawWriter's documentation for the measurement.
        XCTAssertEqual(original[254]?.firstUInt32, 0, "SubIFDs[0] must be the page readers decode")
        XCTAssertEqual(alternate[254]?.firstUInt32, 0, "the alternate is a raw page, not a preview")
        // Profile/opcode tags describe the development, not the samples: repeating them on the
        // alternate makes ImageIO apply the correction twice (measured, max|diff| 255).
        for tag: UInt16 in [50721, 50722, 50728, 50938, 50939, 50981, 50982, 51022, 51041] {
            XCTAssertNil(alternate[tag], "the alternate must not repeat profile tag \(tag)")
        }
        // The fixture's raw IFD carries only the CFA descriptors plus the levels, so that is what
        // can be asserted here; a real capture's DefaultCrop/ActiveArea travel the same path.
        for tag: UInt16 in [33421, 33422] {
            XCTAssertNotNil(alternate[tag], "the alternate must describe its own samples: \(tag)")
        }
        for page in [original, alternate] {
            XCTAssertEqual(page[262]?.firstUInt32, 32803)
            XCTAssertEqual(page[259]?.firstUInt32, 7)
            XCTAssertEqual(page[258]?.firstUInt32, 16)
            XCTAssertEqual(page[256]?.firstUInt32, UInt32(width))
            XCTAssertEqual(page[257]?.firstUInt32, UInt32(height))
            // CFA pattern has to travel with the page: IFD0 is a preview and cannot supply it.
            XCTAssertEqual(page[33421]?.firstUInt32, 2)
            // No nested sub-IFDs, no EXIF/GPS/XMP on a raw page.
            for tag: UInt16 in [330, 34665, 34853, 700] {
                XCTAssertNil(page[tag], "a raw page must not carry tag \(tag)")
            }
        }
        let description = alternate[270].map { String(decoding: $0.value.dropLast(), as: UTF8.self) }
        XCTAssertEqual(description, "denoised alternate: test strength=1.0")

        // Both pages decode back to exactly the samples that went in, and they differ.
        let decodedOriginal = try decode(data, entries: original, width: width, height: height)
        let decodedAlternate = try decode(data, entries: alternate, width: width, height: height)
        XCTAssertEqual(decodedOriginal, primary)
        XCTAssertEqual(decodedAlternate, denoised)
        XCTAssertGreaterThan(
            zip(decodedOriginal, decodedAlternate).filter { $0 != $1 }.count, width * height / 2)

        // The library's own reader resolves the dual file to the original + the preview, which is
        // exactly what a camera-shaped DNG should look like to it.
        let doc = try SourceDNG(data: data)
        XCTAssertEqual(doc.ifd0[330]?.count, 2)
        XCTAssertNotNil(doc.preview, "IFD0 is the preview in this layout")
        let reread = try doc.readMosaic(data: data)
        XCTAssertEqual(reread.samples, primary, "a second pass must start from the original")
    }

    /// Without a preview page there is no non-raw page to put at IFD0, so the dual layout cannot be
    /// built at all — and silently writing one anyway would flip what readers consider the picture.
    func testDualWriteRefusesASourceWithoutAPreview() throws {
        let width = 32, height = 32
        let primary = [UInt16](repeating: 7, count: width * height)
        // Same synthetic file, stripped of its IFD1 by truncating the chain.
        let source = tempURL("src-nopreview.dng")
        try syntheticDNG(width: width, height: height, samples: primary, to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        var bytes = try Data(contentsOf: source)
        // IFD0's next-IFD pointer is the last 4 bytes of its head: 16 entries at byte 8.
        let nextPointer = 8 + 2 + 12 * 16
        bytes.replaceSubrange(nextPointer..<(nextPointer + 4), with: [0, 0, 0, 0])
        try bytes.write(to: source)

        let out = tempURL("dual-nopreview.dng")
        defer { try? FileManager.default.removeItem(at: out) }
        XCTAssertThrowsError(try DNGRawWriter.write(
            primary: DNGRawWriter.Layer(samples: primary),
            alternate: DNGRawWriter.Layer(samples: primary),
            width: width, height: height, from: source, to: out))
    }

    /// A wrong-sized alternate must be rejected rather than written misaligned.
    func testAlternateWithWrongPixelCountIsRejected() throws {
        let width = 96, height = 80
        let primary = [UInt16](repeating: 1, count: width * height)
        let source = tempURL("src.dng")
        try syntheticDNG(width: width, height: height, samples: primary, to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let out = tempURL("bad.dng")
        defer { try? FileManager.default.removeItem(at: out) }

        XCTAssertThrowsError(try DNGRawWriter.write(
            primary: DNGRawWriter.Layer(samples: primary),
            alternate: DNGRawWriter.Layer(samples: [1, 2, 3]),
            width: width, height: height, from: source, to: out))
    }
}
