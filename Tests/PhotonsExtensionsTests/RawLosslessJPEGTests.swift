import XCTest
@testable import PhotonsExtensions

/// `RawLosslessJPEG` — the SOF3 encoder the DNG writer needs, proved three ways and with a
/// deliberate mention of the failure mode that shipped once.
///
///  ① **Byte-identical to the reference encoder.** The fixture is produced by an independent Python
///     implementation (`raw-denoise-survey/pipeline/ljpeg.py`) with the same fixed Huffman tables.
///     A different bit anywhere — a canonical-code order, a pad bit, a stuffing byte — shows up here.
///  ② **The SOS selector is `Td << 4`.** This is the bug that produced an all-black DNG that both
///     "rendered successfully" and decoded *correctly* under libraw: libraw indexes Huffman tables by
///     component and ignores the selector, Core Image honours it. With `[c, c]` the second component
///     is decoded with table 0 and every sample ends up zero. The assertion below is deliberately on
///     the raw bytes, because no round-trip through our own decoder can catch it (our decoder would
///     use the selector too, i.e. it would fail loudly — but a *decoder that ignores it* would pass).
///  ③ **Round-trip through an independent decoder in this file.** Random full-range data, a constant
///     tile (every difference zero, one Huffman symbol), and a worst case that is all `0xFF` bytes
///     after packing (to exercise JPEG's byte stuffing).
final class RawLosslessJPEGTests: XCTestCase {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // RawLosslessJPEGTests.swift → PhotonsCoreTests
            .deletingLastPathComponent()   // → Tests
            .deletingLastPathComponent()   // → repo root
    }

    // MARK: ① golden bytes

    private struct Golden: Decodable {
        let width: Int
        let height: Int
        let components: Int
        let precision: Int
        let tables: [[[Int]]]        // [table][category] = [category, code, length]
        let expected_base64: String
    }

    func testEncodesExactlyTheReferenceBytes() throws {
        let url = Self.repoRoot.appendingPathComponent("Tests/Fixtures/rawljpeg_golden.json")
        let golden = try JSONDecoder().decode(Golden.self, from: Data(contentsOf: url))

        let tables = golden.tables.map { rows -> RawLosslessJPEG.HuffmanTable in
            var code = [UInt32](repeating: 0, count: 17)
            var length = [UInt8](repeating: 0, count: 17)
            for row in rows {
                code[row[0]] = UInt32(row[1])
                length[row[0]] = UInt8(row[2])
            }
            return RawLosslessJPEG.HuffmanTable(code: code, length: length)
        }

        // Same deterministic sample as the fixture generator: (x*37 + y*11) % 4096 + 512
        let w = golden.width, h = golden.height
        var tile = [UInt16](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                tile[y * w + x] = UInt16((x * 37 + y * 11) % 4096 + 512)
            }
        }

        let produced = tile.withUnsafeBufferPointer {
            RawLosslessJPEG.encode($0, width: w, height: h,
                                   components: golden.components, tables: tables,
                                   precision: golden.precision)
        }
        let expected = [UInt8](Data(base64Encoded: golden.expected_base64)!)

        XCTAssertEqual(produced.count, expected.count, "长度不同：\(produced.count) vs \(expected.count)")
        if produced != expected {
            let firstDiff = zip(produced, expected).enumerated().first { $0.element.0 != $0.element.1 }
            XCTFail("字节不一致，首个差异 @\(firstDiff?.offset ?? -1)："
                    + "\(String(format: "%02X", firstDiff?.element.0 ?? 0)) vs "
                    + "\(String(format: "%02X", firstDiff?.element.1 ?? 0))")
        }
    }

    // MARK: ② selector nibble

    func testSOSCarriesTheTableInTheHighNibble() {
        let table = RawLosslessJPEG.canonicalTable(fromHistogram: [Int](repeating: 1, count: 17))
        var tile = [UInt16](repeating: 1000, count: 16 * 8)
        tile[5] = 1200
        let bytes = tile.withUnsafeBufferPointer {
            RawLosslessJPEG.encode($0, width: 16, height: 8, components: 2, tables: [table, table])
        }
        guard let sos = bytes.indices.dropFirst().first(where: { bytes[$0] == 0xDA && bytes[$0 - 1] == 0xFF })
        else {
            return XCTFail("没有 SOS 段")
        }
        // SOS 布局: FF DA len_hi len_lo Ns (id0, sel0) (id1, sel1) Ss Se AhAl
        // `sos` 指向 0xDA，所以 len 在 +1/+2，Ns 在 +3。
        XCTAssertEqual(bytes[sos + 3], 2, "Ns 必须是 2")
        XCTAssertEqual(bytes[sos + 4], 0, "组件 0 的 id")
        XCTAssertEqual(bytes[sos + 5], 0x00, "组件 0 的选择子：Td 0 / Ta 0")
        XCTAssertEqual(bytes[sos + 6], 1, "组件 1 的 id")
        XCTAssertEqual(bytes[sos + 7], 0x10, "组件 1 的选择子必须是 Td 1 / Ta 0（写成 0x01 就是全黑那次）")
    }

    // MARK: ③ round-trip

    private func roundTrip(_ tile: [UInt16], width: Int, height: Int,
                           tables: [RawLosslessJPEG.HuffmanTable]) throws {
        let bytes = tile.withUnsafeBufferPointer {
            RawLosslessJPEG.encode($0, width: width, height: height,
                                   components: tables.count, tables: tables)
        }
        let decoded = try SOF3Decoder.decode(bytes, width: width, height: height,
                                             components: tables.count)
        XCTAssertEqual(decoded, tile)
    }

    func testRoundTripsRandomFullRangeData() throws {
        var rng = SplitMix64(seed: 0xA11CE)
        let w = 64, h = 32
        var tile = [UInt16](repeating: 0, count: w * h)
        for i in tile.indices { tile[i] = UInt16(truncatingIfNeeded: rng.next()) }
        let tables = RawLosslessJPEG.buildTables([tile], width: w, height: h, components: 2)
        try roundTrip(tile, width: w, height: h, tables: tables)
    }

    func testRoundTripsAConstantTile() throws {
        let w = 32, h = 32
        let tile = [UInt16](repeating: 512, count: w * h)          // every difference is zero
        let tables = RawLosslessJPEG.buildTables([tile], width: w, height: h, components: 2)
        try roundTrip(tile, width: w, height: h, tables: tables)
    }

    func testRoundTripsAStuffingWorstCase() throws {
        // Alternating 0 and 65535 makes every difference the extreme category; the packed stream
        // ends up full of 0xFF bytes, which is exactly what the 0x00 stuffing has to survive.
        let w = 64, h = 16
        var tile = [UInt16](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                tile[y * w + x] = (x + y) % 2 == 0 ? 0 : 65535
            }
        }
        let tables = RawLosslessJPEG.buildTables([tile], width: w, height: h, components: 2)
        try roundTrip(tile, width: w, height: h, tables: tables)
    }

    func testBuiltTablesAreValidPrefixCodes() {
        var rng = SplitMix64(seed: 7)
        var tile = [UInt16](repeating: 0, count: 128 * 128)
        for i in tile.indices { tile[i] = UInt16(truncatingIfNeeded: rng.next()) & 0x3FFF }
        let tables = RawLosslessJPEG.buildTables([tile], width: 128, height: 128, components: 2)
        for table in tables {
            let kraft = (0...16).reduce(0.0) { $0 + pow(2.0, -Double(table.length[$1])) }
            XCTAssertLessThanOrEqual(kraft, 1.0 + 1e-9, "Huffman 表超订，Kraft=\(kraft)")
            for c in 0...16 {
                XCTAssertGreaterThan(table.length[c], 0, "类别 \(c) 必须码长非零")
                XCTAssertLessThanOrEqual(table.length[c], 16)
                XCTAssertLessThan(UInt32(table.code[c]), UInt32(1) << UInt32(table.length[c]),
                                  "类别 \(c) 的码字装不进码长")
            }
        }
    }
}

// MARK: - test-only decoder

/// Minimal SOF3 decoder, written from the spec rather than from the encoder so the round-trip test
/// is not circular in the parts that matter (Huffman order, padding, stuffing).
private enum SOF3Decoder {
    struct BitReader {
        let bytes: [UInt8]
        var i = 0
        var acc: UInt32 = 0
        var bits = 0

        mutating func bit() -> Int {
            if bits == 0 {
                var b = bytes[i]
                i += 1
                if b == 0xFF { i += 1 }              // skip the stuffing byte
                acc = UInt32(b)
                bits = 8
            }
            bits -= 1
            return Int((acc >> UInt32(bits)) & 1)
        }

        mutating func read(_ n: Int) -> Int {
            var v = 0
            for _ in 0..<n { v = (v << 1) | bit() }
            return v
        }
    }

    static func decode(_ data: [UInt8], width: Int, height: Int, components: Int) throws -> [UInt16] {
        var i = 2                                  // skip SOI
        var tables: [[(length: Int, code: Int, symbol: Int)]] = []
        var sosStart = 0

        while i < data.count - 1 {
            guard data[i] == 0xFF else { throw NSError(domain: "sof3", code: 1) }
            let marker = data[i + 1]
            let length = Int(data[i + 2]) << 8 | Int(data[i + 3])
            if marker == 0xC4 {                     // DHT
                var p = i + 4
                while p < i + 2 + length {
                    let tableClass = Int(data[p]) & 0xF0
                    let id = Int(data[p]) & 0x0F
                    var counts = [Int]()
                    for l in 0..<16 { counts.append(Int(data[p + 1 + l])) }
                    var symbols = [Int]()
                    let total = counts.reduce(0, +)
                    for s in 0..<total { symbols.append(Int(data[p + 17 + s])) }
                    p += 17 + total
                    precondition(tableClass == 0, "只支持 DC 表")
                    var code = 0
                    var symbolIndex = 0
                    var entries: [(Int, Int, Int)] = []
                    for l in 1...16 {
                        for _ in 0..<counts[l - 1] {
                            entries.append((l, code, symbols[symbolIndex]))
                            symbolIndex += 1
                            code += 1
                        }
                        code <<= 1
                    }
                    while tables.count <= id { tables.append([]) }
                    tables[id] = entries
                }
            } else if marker == 0xDA {              // SOS
                sosStart = i + 2 + length
                break
            }
            i += 2 + length
        }
        precondition(sosStart > 0, "没有 SOS")

        var reader = BitReader(bytes: data, i: sosStart)
        var out = [UInt16](repeating: 0, count: width * height)
        let xc = width / components
        let mask: Int32 = (1 << 16) - 1

        for y in 0..<height {
            let row = y * width
            for x in 0..<xc {
                for c in 0..<components {
                    var category = 0
                    var code = 0
                    outer: for l in 1...16 {
                        code = (code << 1) | reader.bit()
                        for entry in tables[c] where entry.length == l && entry.code == code {
                            category = entry.symbol
                            break outer
                        }
                    }
                    var d: Int32 = 0
                    if category > 0 {
                        let extra = Int32(reader.read(category))
                        let threshold = Int32(1) << Int32(category - 1)
                        d = extra >= threshold ? extra : extra - (Int32(1) << Int32(category)) + 1
                    }
                    let predicted: Int32 = x > 0
                        ? Int32(out[row + (x - 1) * components + c])
                        : (y > 0 ? Int32(out[row - width + c]) : 1 << 15)
                    out[row + x * components + c] = UInt16(truncatingIfNeeded: (predicted + d) & mask)
                }
            }
        }
        return out
    }
}

/// Deterministic RNG so a failing round-trip is reproducible.
private struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
