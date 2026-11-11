//
//  LosslessJPEG.swift
//  hdrmerge-swift
//
//  ITU T.81 Annex H lossless JPEG (SOF3) decoder — the codec behind
//  DNG Compression = 7 and Canon CR2. Supports the single- and multi-component
//  layouts camera DNGs actually use: components with 1x1 sampling, interleaved
//  sample-by-sample inside each MCU (Panasonic/Leica write RG|GB pairs that way).
//
//  Part of a GPLv3 port of HDRMerge (© 2012 Javier Celaya).
//

import Foundation

public enum LJpegError: Error, CustomStringConvertible {
    case badMarker(UInt8)
    case unsupported(String)
    case truncated
    case badHuffman

    public var description: String {
        switch self {
        case .badMarker(let m): return String(format: "unexpected JPEG marker 0xFF%02X", m)
        case .unsupported(let s): return "unsupported lossless JPEG feature: \(s)"
        case .truncated: return "lossless JPEG data truncated"
        case .badHuffman: return "invalid Huffman code"
        }
    }
}

/// MSB-first bit reader over a JPEG entropy-coded segment.
/// Understands 0xFF00 byte stuffing and stops cleanly at real markers.
struct JPEGBitReader {
    let data: [UInt8]
    var pos: Int
    private var buffer: UInt32 = 0
    private var bits: Int = 0
    private(set) var markerHit = false

    init(_ data: [UInt8], from: Int) {
        self.data = data
        self.pos = from
    }

    private mutating func fill() {
        while bits <= 24 && !markerHit {
            guard pos < data.count else { markerHit = true; break }
            let b = data[pos]
            if b == 0xFF {
                guard pos + 1 < data.count else { markerHit = true; break }
                if data[pos + 1] == 0x00 {
                    buffer = (buffer << 8) | 0xFF
                    bits += 8
                    pos += 2
                } else {
                    markerHit = true
                }
            } else {
                buffer = (buffer << 8) | UInt32(b)
                bits += 8
                pos += 1
            }
        }
    }

    mutating func bit() -> Int {
        if bits == 0 { fill() }
        if bits == 0 { return 0 }
        bits -= 1
        return Int((buffer >> UInt32(bits)) & 1)
    }

    mutating func getBits(_ n: Int) -> Int {
        if n == 0 { return 0 }
        var v = 0
        for _ in 0..<n { v = (v << 1) | bit() }
        return v
    }

    /// Byte-align and consume an RSTn marker if present.
    mutating func restart() -> Bool {
        bits = 0
        buffer = 0
        markerHit = false
        while pos < data.count && data[pos] != 0xFF { pos += 1 }
        guard pos + 1 < data.count else { return false }
        let m = data[pos + 1]
        if m >= 0xD0 && m <= 0xD7 {
            pos += 2
            return true
        }
        return false
    }
}

struct HuffmanTable {
    let symbols: [UInt8]
    var minCode = [Int](repeating: 0, count: 17)
    var maxCode = [Int](repeating: -1, count: 17)
    var valPtr = [Int](repeating: 0, count: 17)

    init(counts: [Int], symbols: [UInt8]) {
        self.symbols = symbols
        var code = 0
        var k = 0
        for len in 1...16 {
            let n = counts[len - 1]
            valPtr[len] = k
            minCode[len] = code
            code += n
            k += n
            maxCode[len] = n > 0 ? code - 1 : -1
            if code > (1 << len) { break }
            code <<= 1
        }
    }

    func decode(_ reader: inout JPEGBitReader) throws -> Int {
        var code = 0
        for len in 1...16 {
            code = (code << 1) | reader.bit()
            if maxCode[len] >= 0 && code <= maxCode[len] {
                let idx = valPtr[len] + code - minCode[len]
                guard idx >= 0 && idx < symbols.count else { throw LJpegError.badHuffman }
                return Int(symbols[idx])
            }
        }
        throw LJpegError.badHuffman
    }
}

public struct LJpegImage {
    /// JPEG frame width in MCUs (per-component plane width).
    public let width: Int
    public let height: Int
    public let components: Int
    /// One plane per component, row-major, `width × height`.
    public let planes: [[UInt16]]
}

public enum LosslessJPEG {
    public static func decode(_ data: [UInt8], offset: Int = 0) throws -> LJpegImage {
        var p = offset

        func nextMarker() throws -> UInt8 {
            while p < data.count && data[p] != 0xFF { p += 1 }
            guard p + 1 < data.count else { throw LJpegError.truncated }
            while p + 1 < data.count && data[p + 1] == 0xFF { p += 1 }
            let m = data[p + 1]
            p += 2
            return m
        }
        func readU16() throws -> Int {
            guard p + 2 <= data.count else { throw LJpegError.truncated }
            let v = Int(data[p]) << 8 | Int(data[p + 1])
            p += 2
            return v
        }

        guard try nextMarker() == 0xD8 else { throw LJpegError.badMarker(0) }

        var dcTables: [Int: HuffmanTable] = [:]
        var precision = 16
        var width = 0, height = 0
        var components = 0
        var sampling: [(h: Int, v: Int)] = []
        var restartInterval = 0

        while true {
            let marker = try nextMarker()
            switch marker {
            case 0xC3:
                let len = try readU16()
                let end = p + len - 2
                precision = Int(data[p]); p += 1
                height = try readU16()
                width = try readU16()
                components = Int(data[p]); p += 1
                sampling = []
                for _ in 0..<components {
                    let hv = data[p + 1]
                    sampling.append((Int(hv >> 4), Int(hv & 0x0F)))
                    p += 3
                }
                p = end
                guard components >= 1, components <= 4 else {
                    throw LJpegError.unsupported("\(components) components")
                }
            case 0xC4:
                let len = try readU16()
                let end = p + len - 2
                while p < end {
                    let tcth = data[p]; p += 1
                    let tc = tcth >> 4, th = Int(tcth & 0x0F)
                    guard tc == 0 else { throw LJpegError.unsupported("AC Huffman table") }
                    var counts = [Int](repeating: 0, count: 16)
                    var total = 0
                    for i in 0..<16 { counts[i] = Int(data[p + i]); total += counts[i] }
                    p += 16
                    let syms = Array(data[p..<(p + total)])
                    p += total
                    dcTables[th] = HuffmanTable(counts: counts, symbols: syms)
                }
            case 0xDD:
                let len = try readU16()
                guard len == 4 else { throw LJpegError.unsupported("DRI length") }
                restartInterval = try readU16()
            case 0xDA:
                let len = try readU16()
                let end = p + len - 2
                let ns = Int(data[p]); p += 1
                guard ns == components else {
                    throw LJpegError.unsupported("non-interleaved scan (\(ns) of \(components) components)")
                }
                var tableIDs: [Int] = []
                for _ in 0..<ns {
                    _ = data[p]              // component selector
                    tableIDs.append(Int(data[p + 1] >> 4))
                    p += 2
                }
                let predictor = Int(data[p])
                let ah = Int(data[p + 2] >> 4)
                let al = Int(data[p + 2] & 0x0F)
                guard ah == 0 else { throw LJpegError.unsupported("successive approximation") }
                guard predictor >= 1 && predictor <= 7 else {
                    throw LJpegError.unsupported("predictor \(predictor)")
                }
                p = end
                guard width > 0, height > 0 else { throw LJpegError.unsupported("missing SOF") }

                let tables: [HuffmanTable] = try tableIDs.map { id in
                    guard let t = dcTables[id] ?? dcTables[0] else {
                        throw LJpegError.unsupported("missing DC Huffman table \(id)")
                    }
                    return t
                }
                for (i, s) in sampling.enumerated() where s.h != 1 || s.v != 1 {
                    throw LJpegError.unsupported("sampling \(s.h)x\(s.v) on component \(i)")
                }

                let planes = try decodeScan(data: data, start: p, tables: tables,
                                            width: width, height: height, components: components,
                                            precision: precision, predictor: predictor,
                                            pointTransform: al, restartInterval: restartInterval)
                return LJpegImage(width: width, height: height, components: components, planes: planes)
            case 0xD9:
                throw LJpegError.unsupported("no scan")
            default:
                if marker >= 0xD0 && marker <= 0xD7 { continue }
                if marker == 0x01 { continue }
                if p + 2 > data.count { throw LJpegError.truncated }
                let len = Int(data[p]) << 8 | Int(data[p + 1])
                p += (len >= 2 ? len : 2)
            }
        }
    }

    private static func decodeScan(data: [UInt8], start: Int, tables: [HuffmanTable],
                                   width: Int, height: Int, components: Int,
                                   precision: Int, predictor: Int, pointTransform: Int,
                                   restartInterval: Int) throws -> [[UInt16]] {
        let mask = (1 << precision) - 1
        let initValue = 1 << max(0, precision - pointTransform - 1)
        var out = [[UInt16]](repeating: [UInt16](repeating: 0, count: width * height), count: components)
        var above = [[Int]](repeating: [Int](repeating: initValue, count: width), count: components)
        var row = [[Int]](repeating: [Int](repeating: initValue, count: width), count: components)
        var reader = JPEGBitReader(data, from: start)
        var sinceRestart = 0

        @inline(__always) func extend(_ v: Int, _ s: Int) -> Int {
            if s == 0 { return 0 }
            return v < (1 << (s - 1)) ? v - (1 << s) + 1 : v
        }

        for y in 0..<height {
            for x in 0..<width {
                if restartInterval > 0 && sinceRestart == restartInterval {
                    sinceRestart = 0
                    _ = reader.restart()
                    for c in 0..<components {
                        for i in 0..<width { above[c][i] = initValue }
                        for i in 0..<width { row[c][i] = initValue }
                    }
                }
                for c in 0..<components {
                    let s = try tables[c].decode(&reader)
                    let diff = s == 0 ? 0 : extend(reader.getBits(s), s)

                    let ra: Int, rb: Int, rc: Int
                    if x == 0 {
                        ra = above[c][0]; rb = above[c][0]; rc = above[c][0]
                    } else {
                        ra = row[c][x - 1]; rb = above[c][x]; rc = above[c][x - 1]
                    }
                    var pred: Int
                    switch predictor {
                    case 1: pred = ra
                    case 2: pred = rb
                    case 3: pred = rc
                    case 4: pred = ra + rb - rc
                    case 5: pred = ra + ((rb - rc) >> 1)
                    case 6: pred = rb + ((ra - rc) >> 1)
                    default: pred = (ra + rb) >> 1
                    }
                    let value = (pred + diff) & mask
                    row[c][x] = value
                    out[c][y * width + x] = UInt16(truncatingIfNeeded: value << pointTransform)
                }
                sinceRestart += 1
            }
            swap(&above, &row)
        }
        return out
    }
}
