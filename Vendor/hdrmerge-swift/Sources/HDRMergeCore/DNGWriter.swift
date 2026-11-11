//
//  DNGWriter.swift
//  hdrmerge-swift
//
//  Writes the merged mosaic back out as a CFA DNG (PhotometricInterpretation
//  32803) with floating point or 16-bit integer samples. The Bayer pattern,
//  black/white levels and colour metadata are carried over verbatim, so the
//  result is a drop-in replacement for one of the input frames.
//
//  Structure follows DngFloatWriter.cpp from HDRMerge (GPLv3, © 2012 Javier Celaya).
//

import Foundation

struct TIFFWriteEntry {
    let tag: UInt16
    let type: UInt16
    let count: Int
    let data: [UInt8]
}

enum TIFFWriteType: UInt16 {
    case byte = 1, ascii = 2, short = 3, long = 4, rational = 5
    case sbyte = 6, undef = 7, sshort = 8, slong = 9, srational = 10
    case float = 11, double = 12
}

final class TIFFBuilder {
    var entries: [TIFFWriteEntry] = []

    func add(_ tag: UInt16, _ type: TIFFWriteType, _ data: [UInt8], count: Int) {
        entries.append(TIFFWriteEntry(tag: tag, type: type.rawValue, count: count, data: data))
    }

    func addShorts(_ tag: UInt16, _ values: [UInt16]) {
        var d = [UInt8]()
        for v in values { d.append(UInt8(v & 0xFF)); d.append(UInt8(v >> 8)) }
        add(tag, .short, d, count: values.count)
    }

    func addLongs(_ tag: UInt16, _ values: [UInt32]) {
        var d = [UInt8]()
        for v in values {
            d.append(UInt8(v & 0xFF)); d.append(UInt8((v >> 8) & 0xFF))
            d.append(UInt8((v >> 16) & 0xFF)); d.append(UInt8((v >> 24) & 0xFF))
        }
        add(tag, .long, d, count: values.count)
    }

    func addRationals(_ tag: UInt16, _ values: [(UInt32, UInt32)]) {
        var d = [UInt8]()
        for (n, q) in values {
            for v in [n, q] {
                d.append(UInt8(v & 0xFF)); d.append(UInt8((v >> 8) & 0xFF))
                d.append(UInt8((v >> 16) & 0xFF)); d.append(UInt8((v >> 24) & 0xFF))
            }
        }
        add(tag, .rational, d, count: values.count)
    }

    func addSRationals(_ tag: UInt16, _ values: [Double]) {
        var d = [UInt8]()
        for v in values {
            let scaled = Int32((v * 1_000_000).rounded())
            for raw in [UInt32(bitPattern: scaled), UInt32(1_000_000)] {
                d.append(UInt8(raw & 0xFF)); d.append(UInt8((raw >> 8) & 0xFF))
                d.append(UInt8((raw >> 16) & 0xFF)); d.append(UInt8((raw >> 24) & 0xFF))
            }
        }
        add(tag, .srational, d, count: values.count)
    }

    func addASCII(_ tag: UInt16, _ s: String) {
        var d = Array(s.utf8)
        d.append(0)
        add(tag, .ascii, d, count: d.count)
    }

    func addRaw(_ tag: UInt16, type: UInt16, count: Int, data: [UInt8]) {
        entries.append(TIFFWriteEntry(tag: tag, type: type, count: count, data: data))
    }

    func addBytes(_ tag: UInt16, _ values: [UInt8]) {
        add(tag, .byte, values, count: values.count)
    }

    /// Serialise: header + main IFD + any number of pointer IFDs (Exif, GPS) + pixel data.
    func build(pixelData: [UInt8], extras: [(pointerTag: UInt16, builder: TIFFBuilder)]) -> Data {
        var main = entries
        for extra in extras {
            main.append(TIFFWriteEntry(tag: extra.pointerTag, type: 4, count: 1,
                                       data: [0, 0, 0, 0]))
        }
        main.sort { $0.tag < $1.tag }

        func valuesSize(_ list: [TIFFWriteEntry]) -> Int {
            var total = 0
            for e in list where e.data.count > 4 { total += (e.data.count + 1) & ~1 }
            return total
        }

        let mainIFDSize = 2 + main.count * 12 + 4
        var offsets: [(tag: UInt16, ifd: Int, values: Int, size: Int, entries: [TIFFWriteEntry])] = []
        var cursor = 8 + mainIFDSize + valuesSize(main)
        for extra in extras {
            let list = extra.builder.entries.sorted { $0.tag < $1.tag }
            let size = 2 + list.count * 12 + 4
            offsets.append((extra.pointerTag, cursor, cursor + size, size, list))
            cursor += size + valuesSize(list)
        }
        var pixelOffset = cursor
        if pixelOffset % 4 != 0 { pixelOffset += 4 - pixelOffset % 4 }

        var out = [UInt8](repeating: 0, count: pixelOffset)
        out[0] = 0x49; out[1] = 0x49; out[2] = 42; out[3] = 0
        out[4] = 8; out[5] = 0; out[6] = 0; out[7] = 0

        // Patch the pointer entries with the offsets computed above.
        main = main.map { e in
            guard let hit = offsets.first(where: { $0.tag == e.tag }) else { return e }
            var d = [UInt8](repeating: 0, count: 4)
            let v = UInt32(hit.ifd)
            for b in 0..<4 { d[b] = UInt8((v >> (8 * UInt32(b))) & 0xFF) }
            return TIFFWriteEntry(tag: e.tag, type: 4, count: 1, data: d)
        }

        func writeIFD(_ list: [TIFFWriteEntry], at offset: Int, valuesAt: Int) {
            var c = valuesAt
            out[offset] = UInt8(list.count & 0xFF)
            out[offset + 1] = UInt8((list.count >> 8) & 0xFF)
            for (i, e) in list.enumerated() {
                let p = offset + 2 + i * 12
                out[p] = UInt8(e.tag & 0xFF); out[p + 1] = UInt8(e.tag >> 8)
                out[p + 2] = UInt8(e.type & 0xFF); out[p + 3] = UInt8(e.type >> 8)
                let cnt = UInt32(e.count)
                for b in 0..<4 { out[p + 4 + b] = UInt8((cnt >> (8 * UInt32(b))) & 0xFF) }
                if e.data.count <= 4 {
                    for (b, v) in e.data.enumerated() { out[p + 8 + b] = v }
                } else {
                    let off = UInt32(c)
                    for b in 0..<4 { out[p + 8 + b] = UInt8((off >> (8 * UInt32(b))) & 0xFF) }
                    for (b, v) in e.data.enumerated() { out[c + b] = v }
                    c += (e.data.count + 1) & ~1
                }
            }
            let next = offset + 2 + list.count * 12
            for b in 0..<4 { out[next + b] = 0 }
        }

        writeIFD(main, at: 8, valuesAt: 8 + mainIFDSize)
        for o in offsets {
            writeIFD(o.entries, at: o.ifd, valuesAt: o.values)
        }

        out.append(contentsOf: pixelData)
        return Data(out)
    }
}

public enum DNGWriter {
    /// `bits`: 16 (integer) or 32 (float).
    /// Encode the merged mosaic into DNG bytes. Hosts write the result
    /// atomically; `write(...)` is the convenience wrapper.
    public static func render(_ merged: MergedImage, source: RawFrame, bits: Int) throws -> Data {
        let w = merged.width, h = merged.height
        var pixelData: [UInt8]
        let bytesPerSample = bits == 32 ? 4 : 2
        pixelData = [UInt8](repeating: 0, count: w * h * bytesPerSample)

        if bits == 32 {
            for i in 0..<(w * h) {
                let v = merged.values[i]
                let bits32 = v.bitPattern
                pixelData[4 * i] = UInt8(bits32 & 0xFF)
                pixelData[4 * i + 1] = UInt8((bits32 >> 8) & 0xFF)
                pixelData[4 * i + 2] = UInt8((bits32 >> 16) & 0xFF)
                pixelData[4 * i + 3] = UInt8((bits32 >> 24) & 0xFF)
            }
        } else {
            let maxCode = Double(merged.white)
            for i in 0..<(w * h) {
                let v = UInt16(min(max(Double(merged.values[i]).rounded(), 0), maxCode))
                pixelData[2 * i] = UInt8(v & 0xFF)
                pixelData[2 * i + 1] = UInt8(v >> 8)
            }
        }

        let main = TIFFBuilder()
        main.addLongs(254, [0])                                  // NewSubfileType: full image
        main.addLongs(256, [UInt32(w)])
        main.addLongs(257, [UInt32(h)])
        main.addShorts(258, [UInt16(bits)])
        main.addShorts(259, [1])                                 // Compression: none
        main.addShorts(262, [32803])                             // CFA
        main.addShorts(277, [1])
        main.addShorts(284, [1])
        main.addShorts(339, [bits == 32 ? 3 : 1])                // SampleFormat
        main.addLongs(273, [0])                                  // StripOffsets, patched below
        main.addLongs(278, [UInt32(h)])
        main.addLongs(279, [UInt32(pixelData.count)])
        main.addShorts(33421, [UInt16(merged.cfaRows), UInt16(merged.cfaCols)])
        main.addBytes(33422, merged.cfaPattern)
        main.addBytes(50710, [0, 1, 2])
        main.addShorts(50711, [1])                               // CFALayout: rectangular
        main.addShorts(50713, [UInt8(merged.cfaRows), UInt8(merged.cfaCols)].map { UInt16($0) })
        main.addRationals(50714, merged.cfaPattern.enumerated().map { (i, _) in
            (UInt32(max(0, Int(merged.black.rounded()))), 1)
        })
        main.addLongs(50717, [UInt32(merged.white)])
        main.addBytes(50706, [1, 4, 0, 0])
        main.addBytes(50707, [1, 1, 0, 0])
        if !source.rawMeta.contains(where: { $0.tag == 50708 }) {
            main.addASCII(50708, "\(source.make) \(source.model)".trimmingCharacters(in: .whitespaces))
        }
        main.addLongs(50719, [0, 0])
        main.addLongs(50720, [UInt32(w), UInt32(h)])
        for e in source.rawMeta {
            switch e.tag {
            case 50708: main.addRaw(50708, type: e.type, count: e.count, data: e.data)
            case 50721: main.addRaw(50721, type: e.type, count: e.count, data: e.data)
            case 50722: main.addRaw(50722, type: e.type, count: e.count, data: e.data)
            default: break
            }
        }
        if !source.make.isEmpty { main.addASCII(271, source.make) }
        if !source.model.isEmpty { main.addASCII(272, source.model) }
        if source.asShotNeutral.count >= 3 {
            main.addRationals(50728, source.asShotNeutral.prefix(3).map {
                (UInt32((max(0, $0) * 1_000_000).rounded()), 1_000_000)
            })
        }
        if let cm = source.colorMatrix1, cm.count == 9,
           !source.rawMeta.contains(where: { $0.tag == 50721 }) {
            main.addSRationals(50721, cm)
            main.addShorts(50778, [UInt16(source.calibrationIlluminant1)])
        }
        if let cm = source.colorMatrix2, cm.count == 9,
           !source.rawMeta.contains(where: { $0.tag == 50722 }) {
            main.addSRationals(50722, cm)
            main.addShorts(50779, [UInt16(source.calibrationIlluminant2)])
        }

        main.addShorts(274, [UInt16(max(1, source.orientation))])
        main.addASCII(305, "hdrmerge-swift")
        if !source.dateTime.isEmpty { main.addASCII(306, source.dateTime) }

        for e in source.extraIFD0 {
            main.addRaw(e.tag, type: e.type, count: e.count, data: e.data)
        }

        let exif = TIFFBuilder()
        if source.exposureTime > 0 {
            let num = UInt32((source.exposureTime * 1_000_000).rounded())
            exif.addRationals(33434, [(num, 1_000_000)])
        }
        if source.iso > 0 { exif.addShorts(34855, [UInt16(source.iso.rounded())]) }
        // Everything else the camera wrote (timestamps, lens, exposure program, ...).
        for e in source.exifTags where e.tag != 33434 && e.tag != 34855 && e.tag != 274 {
            exif.addRaw(e.tag, type: e.type, count: e.count, data: e.data)
        }

        let gps = TIFFBuilder()
        for e in source.gpsTags {
            gps.addRaw(e.tag, type: e.type, count: e.count, data: e.data)
        }
        var extras: [(pointerTag: UInt16, builder: TIFFBuilder)] = [(34665, exif)]
        if !source.gpsTags.isEmpty { extras.append((34853, gps)) }
        var data = main.build(pixelData: pixelData, extras: extras)

        // Patch StripOffsets: the pixel block starts right after the IFD data,
        // i.e. at (fileSize - pixelData.count).
        let pixelOffset = UInt32(data.count - pixelData.count)
        let entryCount = Int(data[8]) | Int(data[9]) << 8
        for i in 0..<entryCount {
            let p = 10 + i * 12
            let tag = UInt16(data[p]) | UInt16(data[p + 1]) << 8
            if tag == 273 {
                data[p + 8] = UInt8(pixelOffset & 0xFF)
                data[p + 9] = UInt8((pixelOffset >> 8) & 0xFF)
                data[p + 10] = UInt8((pixelOffset >> 16) & 0xFF)
                data[p + 11] = UInt8((pixelOffset >> 24) & 0xFF)
            }
        }
        return data
    }

    public static func write(_ merged: MergedImage, source: RawFrame,
                             bits: Int, to url: URL) throws {
        try render(merged, source: source, bits: bits).write(to: url)
    }
}
