//
//  DNG.swift
//  hdrmerge-swift
//
//  Reads a DNG/CFA container down to plain, un-demosaiced sensor samples plus
//  the metadata the merge needs. No demosaic, no colour processing — that is
//  the whole point: the output of this tool is a Bayer mosaic again.
//
//  Part of a GPLv3 port of HDRMerge (© 2012 Javier Celaya).
//

import Foundation

public enum DNGError: Error, CustomStringConvertible {
    case noCFAImage
    case linearRawUnsupported
    case unsupportedCompression(Int)
    case inconsistentGeometry(String)

    public var description: String {
        switch self {
        case .noCFAImage:
            return "no CFA (PhotometricInterpretation=32803) image found — this looks like a demosaiced/linear DNG"
        case .linearRawUnsupported:
            return "linear DNG (PhotometricInterpretation=34892) has no Bayer mosaic to merge"
        case .unsupportedCompression(let c):
            return "unsupported compression \(c) (supported: 1 = none, 7 = lossless JPEG)"
        case .inconsistentGeometry(let s):
            return "inconsistent DNG geometry: \(s)"
        }
    }
}

public struct RawFrame {
    public let url: URL
    /// Full stored sensor array (margins included).
    public let fullWidth: Int
    public let fullHeight: Int
    /// Valid photo area inside the stored array (ActiveArea).
    public let activeTop: Int
    public let activeLeft: Int
    public let activeWidth: Int
    public let activeHeight: Int
    /// Final crop requested by DefaultCropOrigin/Size, relative to ActiveArea.
    public let cropX: Int
    public let cropY: Int
    public let cropWidth: Int
    public let cropHeight: Int

    public let cfaRows: Int
    public let cfaCols: Int
    /// 0 = R, 1 = G, 2 = B, 3 = G2 (values are indices into CFAPlaneColor).
    public let cfaPattern: [UInt8]
    /// `CFAPlaneColor` as stored: RGB for a plain Bayer sensor, RGBW or RG1G2B for sensors that
    /// declare a fourth plane. Length is the number of colour planes the mosaic can address, so
    /// nothing downstream may assume 3.
    public let cfaPlaneColor: [UInt8]
    /// `CFALayout` (50711): 1 = rectangular, 2 = staggered, 3 = staggered-4, 4 = staggered-9.
    /// Only 1 is mergeable; the others interleave rows and need a different plane model.
    public let cfaLayout: Int
    /// Per-CFA-cell black level.
    public let blackLevel: [Double]
    public let whiteLevel: Int

    public let pixels: [UInt16]

    public let make: String
    public let model: String
    public let exposureTime: Double
    public let iso: Double
    public let asShotNeutral: [Double]
    public let colorMatrix1: [Double]?
    public let colorMatrix2: [Double]?
    /// Verbatim bytes of ColorMatrix1/2 and UniqueCameraModel, to avoid re-encoding.
    public let rawMeta: [(tag: UInt16, type: UInt16, count: Int, data: [UInt8])]
    public let calibrationIlluminant1: Int
    public let calibrationIlluminant2: Int
    /// Scalar EXIF tags copied verbatim from the source's Exif IFD.
    public let exifTags: [(tag: UInt16, type: UInt16, count: Int, data: [UInt8])]
    /// GPS IFD entries, copied verbatim so 34853 stays valid.
    public let gpsTags: [(tag: UInt16, type: UInt16, count: Int, data: [UInt8])]
    /// All other IFD0 tags from the source, to be copied verbatim.
    public let extraIFD0: [(tag: UInt16, type: UInt16, count: Int, data: [UInt8])]
    public let dateTime: String
    public let orientation: Int

    /// The **photo** size: DefaultCropSize inside ActiveArea. This is smaller than the stored
    /// array whenever the sensor has dummy/optical-black margins, and it is what the merge must
    /// work on — merging the margins in produces the classic 0/16383 band along the right edge.
    public var width: Int { cropWidth }
    public var height: Int { cropHeight }

    /// Pixel offset of the photo rectangle from the start of the active area.
    public var photoLeft: Int { cropX }
    public var photoTop: Int { cropY }

    /// Colour index of the sample at (x, y) in **photo** coordinates.
    @inline(__always)
    public func colorAt(_ x: Int, _ y: Int) -> Int {
        // The CFA phase is a property of the sensor grid, so the crop offset must be added back
        // in: cropping an RGGB pattern by an odd number of pixels would otherwise invert it.
        Int(cfaPattern[((y + cropY) % cfaRows) * cfaCols + ((x + cropX) % cfaCols)])
    }

    @inline(__always)
    public func blackAt(_ x: Int, _ y: Int) -> Double {
        blackLevel[((y + cropY) % cfaRows) * cfaCols + ((x + cropX) % cfaCols)]
    }

    /// Raw sample at **photo** coordinates (active area + crop applied).
    @inline(__always)
    public func sample(_ x: Int, _ y: Int) -> UInt16 {
        pixels[(y + cropY + activeTop) * fullWidth + (x + cropX + activeLeft)]
    }

    /// `cfaPattern` re-phased so that index (0,0) is the colour of the *photo* rectangle's
    /// top-left sample. A crop offset that is not a multiple of the CFA repeat has to be rotated
    /// out, otherwise the written DNG claims the wrong Bayer phase.
    public var photoCFAPattern: [UInt8] {
        CFA.rotate(cfaPattern, rows: cfaRows, cols: cfaCols, byX: cropX, byY: cropY)
    }
}

public enum CFA {
    /// Rotate a CFA pattern so that the new index (0,0) corresponds to old index (byY, byX).
    /// A shift by an *even* number of pixels in a 2×2 pattern is a no-op; an odd one swaps the
    /// colours and turns RGGB into GBRG, which is the classic "everything is magenta" bug.
    public static func rotate(_ pattern: [UInt8], rows: Int, cols: Int,
                              byX: Int, byY: Int) -> [UInt8] {
        let sx = ((byX % cols) + cols) % cols
        let sy = ((byY % rows) + rows) % rows
        guard sx != 0 || sy != 0, pattern.count >= rows * cols else { return pattern }
        var out = [UInt8](repeating: 0, count: rows * cols)
        for y in 0..<rows {
            for x in 0..<cols {
                out[y * cols + x] = pattern[((y + sy) % rows) * cols + ((x + sx) % cols)]
            }
        }
        return out
    }
}

public enum DNGReader {
    public static func read(url: URL) throws -> RawFrame {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let tiff = try TIFFFile(data: data)

        // Find the CFA image plane.
        let ifds = try tiff.allIFDs()
        var rawIFD: IFD?
        var sawLinear = false
        for (_, e) in ifds {
            let photo = e[262]?.firstInt ?? 0
            if photo == 34892 { sawLinear = true }
            if photo == 32803 {
                // Prefer the largest CFA plane (camera DNGs sometimes carry thumbnails first).
                let w = e[256]?.firstInt ?? 0
                let cur = rawIFD?[256]?.firstInt ?? -1
                if w > cur { rawIFD = e }
            }
        }
        guard let e = rawIFD else {
            throw sawLinear ? DNGError.linearRawUnsupported : DNGError.noCFAImage
        }

        let width = e[256]?.firstInt ?? 0
        let height = e[257]?.firstInt ?? 0
        guard width > 0, height > 0 else {
            throw DNGError.inconsistentGeometry("zero image size")
        }
        guard (e[277]?.firstInt ?? 1) == 1 else {
            throw DNGError.inconsistentGeometry("CFA plane must have SamplesPerPixel = 1")
        }
        let compression = e[259]?.firstInt ?? 1
        let bits = e[258]?.firstInt ?? 16

        let cfaDims = e[33421]?.ints ?? [2, 2]
        let cfaRows = cfaDims.first ?? 2
        let cfaCols = cfaDims.count > 1 ? cfaDims[1] : 2
        let pattern: [UInt8]
        if let raw = e[33422]?.raw, raw.count >= cfaRows * cfaCols {
            pattern = Array(raw[0..<(cfaRows * cfaCols)])
        } else {
            pattern = [UInt8](repeating: 1, count: cfaRows * cfaCols)
        }

        // CFAPlaneColor names the colour of each index in CFAPattern. Its length is the number of
        // planes the mosaic addresses — 3 for Bayer, 4 for RGBW / RG1G2B sensors — so read it
        // instead of assuming RGB. A pattern index outside it is a broken file.
        let planeColor = e[50710]?.raw.map { UInt8($0) } ?? [0, 1, 2]
        // CFALayout: 1 = rectangular (all that the merge can handle). Staggered layouts (2/3/4)
        // interleave rows and would need a different plane model, so refuse them explicitly
        // rather than merge the wrong pixels.
        let layout = e[50711]?.firstInt ?? 1
        guard layout == 1 else {
            throw DNGError.inconsistentGeometry("CFALayout \(layout) (staggered CFA) is not supported")
        }
        if let maxIndex = pattern.map({ Int($0) }).max(), maxIndex >= planeColor.count {
            throw DNGError.inconsistentGeometry(
                "CFAPattern references plane \(maxIndex) but CFAPlaneColor has \(planeColor.count) entries")
        }

        let blackRep = e[50713]?.ints ?? [1, 1]
        let blackVals = e[50714]?.doubles ?? [0]
        var black = [Double](repeating: blackVals.first ?? 0, count: cfaRows * cfaCols)
        if blackVals.count == cfaRows * cfaCols {
            black = blackVals
        } else if blackVals.count == 1 {
            black = [Double](repeating: blackVals[0], count: cfaRows * cfaCols)
        } else if blackVals.count > 1 {
            // Multiple values with BlackLevelRepeatDim smaller than the CFA: expand by rows.
            _ = blackRep
            for i in 0..<black.count { black[i] = blackVals[min(i, blackVals.count - 1)] }
        }
        let white = e[50717]?.firstInt ?? ((1 << bits) - 1)

        let active = e[50829]?.ints ?? []
        let activeTop: Int, activeLeft: Int, activeWidth: Int, activeHeight: Int
        if active.count >= 4 {
            activeTop = active[0]; activeLeft = active[1]
            activeHeight = active[2] - active[0]
            activeWidth = active[3] - active[1]
        } else {
            activeTop = 0; activeLeft = 0; activeWidth = width; activeHeight = height
        }
        guard activeWidth > 0, activeHeight > 0 else {
            throw DNGError.inconsistentGeometry("empty ActiveArea")
        }

        // DefaultCropOrigin/Size are RATIONAL in most camera DNGs (Leica writes type 5), and
        // `ints` has no rational case, so they have to be read as doubles. They are the
        // authoritative photo rectangle: the stored array and even ActiveArea can be larger
        // (Leica SL3: 9536×6344 stored, ActiveArea covers all of it, photo is 9520×6336 at 4,4),
        // and the surplus columns carry sensor dummy data — 0/16383 alternation — which must
        // never reach the mosaic.
        func intPair(_ entry: TIFFEntry?) -> [Int]? {
            guard let entry else { return nil }
            let v = entry.doubles.map { Int($0.rounded()) }
            return v.isEmpty ? nil : v
        }
        let cropOrigin = intPair(e[50719]) ?? [0, 0]
        let cropSize = intPair(e[50720]) ?? []
        var cropX = cropOrigin.first ?? 0
        var cropY = cropOrigin.count > 1 ? cropOrigin[1] : 0
        var cropW = cropSize.first ?? activeWidth
        var cropH = cropSize.count > 1 ? cropSize[1] : activeHeight
        // Reject a crop that does not fit the active area instead of producing garbage.
        if cropW <= 0 || cropH <= 0 || cropX < 0 || cropY < 0
            || cropX + cropW > activeWidth || cropY + cropH > activeHeight {
            cropX = 0; cropY = 0; cropW = activeWidth; cropH = activeHeight
        }

        let pixels = try decodePixels(tiff: tiff, ifd: e,
                                     width: width, height: height,
                                     compression: compression)

        // Metadata: IFD0 first, then the Exif sub-IFD, then the raw plane itself.
        let mainIFD = (try? tiff.ifd(at: tiff.firstIFDOffset)) ?? [:]
        var metaIFDs: [IFD] = [mainIFD, e]
        if let exifOff = mainIFD[34665]?.firstInt, exifOff > 0,
           let exif = try? tiff.ifd(at: exifOff) {
            metaIFDs.insert(exif, at: 1)
        }
        func metaDouble(_ tag: UInt16) -> Double {
            for ifd in metaIFDs {
                if let v = ifd[tag]?.firstDouble, v > 0 { return v }
            }
            return 0
        }
        let make = metaIFDs.compactMap { $0[271]?.ascii }.first { !$0.isEmpty } ?? ""
        let model = metaIFDs.compactMap { $0[272]?.ascii }.first { !$0.isEmpty } ?? ""
        // Whitelisted scalar EXIF tags (no offsets, so they stay valid when moved).
        let scalarExif: Set<UInt16> = []
        // Copy every Exif tag except the ones we regenerate and offset-bearing pointers.
        let skipExif: Set<UInt16> = [34665, 37500]   // ExifIFD pointer, MakerNote
        var exifTags: [(tag: UInt16, type: UInt16, count: Int, data: [UInt8])] = []
        for ifd in metaIFDs {
            for (tag, e) in ifd where (scalarExif.isEmpty || scalarExif.contains(tag)) && !skipExif.contains(tag) {
                if exifTags.contains(where: { $0.tag == tag }) { continue }
                exifTags.append((tag, e.type.rawValue, e.count, e.raw))
            }
        }
        let orientation = metaIFDs.compactMap { $0[274]?.firstInt }.first ?? 1
        let exposureTime = metaDouble(33434)
        let iso = metaDouble(34855)
        var neutral = [Double]()
        for ifd in metaIFDs where neutral.isEmpty {
            if let v = ifd[50728]?.doubles, v.count >= 3, v[1] != 0 { neutral = v }
        }

        return RawFrame(url: url,
                        fullWidth: width, fullHeight: height,
                        activeTop: activeTop, activeLeft: activeLeft,
                        activeWidth: activeWidth, activeHeight: activeHeight,
                        cropX: cropX, cropY: cropY,
                        cropWidth: cropW, cropHeight: cropH,
                        cfaRows: cfaRows, cfaCols: cfaCols, cfaPattern: pattern,
                        cfaPlaneColor: planeColor, cfaLayout: layout,
                        blackLevel: black, whiteLevel: white,
                        pixels: pixels,
                        make: make, model: model,
                        exposureTime: exposureTime, iso: iso,
                        asShotNeutral: neutral.isEmpty ? [1, 1, 1] : neutral,                        colorMatrix1: metaIFDs.compactMap { $0[50721]?.doubles }.first { $0.count == 9 },
                        colorMatrix2: metaIFDs.compactMap { $0[50722]?.doubles }.first { $0.count == 9 },
                        rawMeta: metaIFDs.compactMap { ifd in
                            [UInt16(50708), UInt16(50721), UInt16(50722)].compactMap { t in
                                guard let e = ifd[t] else { return nil }
                                return (t, e.type.rawValue, e.count, e.raw)
                            }
                        }.first { !$0.isEmpty } ?? [],
                        calibrationIlluminant1: metaIFDs.compactMap { $0[50778]?.firstInt }.first ?? 21,
                        calibrationIlluminant2: metaIFDs.compactMap { $0[50779]?.firstInt }.first ?? 21,
                        exifTags: exifTags.sorted { $0.tag < $1.tag },
                        gpsTags: (mainIFD[34853]?.firstInt).flatMap { off -> [(UInt16, UInt16, Int, [UInt8])]? in
                            guard off > 0, let ifd = try? tiff.ifd(at: off) else { return nil }
                            return ifd.keys.sorted().map { t -> (UInt16, UInt16, Int, [UInt8]) in
                                let e = ifd[t]!
                                return (t, e.type.rawValue, e.count, e.raw)
                            }
                        } ?? [],
                        extraIFD0: mainIFD.compactMap { (t, e) in
                            let ours: Set<UInt16> = [254, 256, 257, 258, 259, 262, 271, 272, 273, 274,
                                                     277, 278, 279, 284, 305, 306, 330, 339, 34665, 34853,
                                                     33421, 33422, 50706, 50707, 50708, 50710, 50711, 50713,
                                                     50714, 50717, 50719, 50720, 50721, 50722, 50728]
                            guard !ours.contains(t) else { return nil }
                            return (t, e.type.rawValue, e.count, e.raw)
                        }.sorted { $0.tag < $1.tag },
                        dateTime: metaIFDs.compactMap { $0[306]?.ascii }.first { !$0.isEmpty } ?? "",
                        orientation: orientation)
    }

    static func decodePixels(tiff: TIFFFile, ifd e: IFD,
                             width: Int, height: Int, compression: Int) throws -> [UInt16] {
        var out = [UInt16](repeating: 0, count: width * height)

        if let tileOffsets = e[324]?.ints, let tileCounts = e[325]?.ints {
            let tw = e[322]?.firstInt ?? 0
            let th = e[323]?.firstInt ?? 0
            guard tw > 0, th > 0 else { throw DNGError.inconsistentGeometry("tiles without TileWidth/Length") }
            let across = (width + tw - 1) / tw
            let down = (height + th - 1) / th
            guard tileOffsets.count >= across * down else {
                throw DNGError.inconsistentGeometry("too few tiles (\(tileOffsets.count) < \(across * down))")
            }
            for ty in 0..<down {
                for tx in 0..<across {
                    let idx = ty * across + tx
                    let off = tileOffsets[idx]
                    let len = tileCounts[idx]
                    let w = min(tw, width - tx * tw)
                    let h = min(th, height - ty * th)
                    try decodeBlock(into: &out, dstWidth: width, dstX: tx * tw, dstY: ty * th,
                                    blockW: w, blockH: h,
                                    bytes: tiff.bytes, offset: off, length: len,
                                    compression: compression)
                }
            }
        } else if let stripOffsets = e[273]?.ints, let stripCounts = e[279]?.ints {
            let rowsPerStrip = e[278]?.firstInt ?? height
            for (i, off) in stripOffsets.enumerated() {
                let y0 = i * rowsPerStrip
                let h = min(rowsPerStrip, height - y0)
                guard h > 0 else { break }
                try decodeBlock(into: &out, dstWidth: width, dstX: 0, dstY: y0,
                                blockW: width, blockH: h,
                                bytes: tiff.bytes, offset: off, length: stripCounts[i],
                                compression: compression)
            }
        } else {
            throw DNGError.inconsistentGeometry("no strip or tile offsets")
        }
        return out
    }

    static func decodeBlock(into dst: inout [UInt16], dstWidth: Int, dstX: Int, dstY: Int,
                            blockW: Int, blockH: Int,
                            bytes: [UInt8], offset: Int, length: Int,
                            compression: Int) throws {
        switch compression {
        case 1:
            // Uncompressed, little-endian samples, contiguous rows.
            let stride = blockW * 2
            guard offset + stride * blockH <= bytes.count else {
                throw DNGError.inconsistentGeometry("strip data past EOF")
            }
            for y in 0..<blockH {
                let src = offset + y * stride
                let d = (dstY + y) * dstWidth + dstX
                for x in 0..<blockW {
                    dst[d + x] = UInt16(bytes[src + 2 * x]) | UInt16(bytes[src + 2 * x + 1]) << 8
                }
            }
        case 7:
            let slice = Array(bytes[offset..<min(offset + length, bytes.count)])
            let img = try LosslessJPEG.decode(slice)
            let n = img.components
            let ch = min(img.height, blockH)
            for y in 0..<ch {
                let d = (dstY + y) * dstWidth + dstX
                let src = y * img.width
                for x in 0..<img.width {
                    for c in 0..<n {
                        let px = x * n + c
                        if px < blockW { dst[d + px] = img.planes[c][src + x] }
                    }
                }
            }
        default:
            throw DNGError.unsupportedCompression(compression)
        }
    }

    public static func writePGM(_ frame: RawFrame, to url: URL) throws {
        var out = Data("P5\n\(frame.fullWidth) \(frame.fullHeight)\n65535\n".utf8)
        var buf = [UInt8](repeating: 0, count: frame.pixels.count * 2)
        for (i, v) in frame.pixels.enumerated() {
            buf[2 * i] = UInt8(v >> 8)
            buf[2 * i + 1] = UInt8(v & 0xFF)
        }
        out.append(contentsOf: buf)
        try out.write(to: url)
    }
}
