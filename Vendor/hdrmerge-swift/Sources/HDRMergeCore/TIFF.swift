//
//  TIFF.swift
//  hdrmerge-swift
//
//  Minimal big/little-endian TIFF reader, enough for DNG.
//  This file is part of a GPLv3 port of HDRMerge (© 2012 Javier Celaya).
//

import Foundation

public enum TIFFError: Error, CustomStringConvertible {
    case notTIFF
    case bigTIFFUnsupported
    case truncated(String)
    case badIFD(Int)
    case missingTag(UInt16)

    public var description: String {
        switch self {
        case .notTIFF: return "not a TIFF file"
        case .bigTIFFUnsupported: return "BigTIFF (version 43) is not supported yet"
        case .truncated(let what): return "truncated file while reading \(what)"
        case .badIFD(let off): return "invalid IFD offset \(off)"
        case .missingTag(let t): return String(format: "missing required tag 0x%04X", t)
        }
    }
}

/// TIFF field types (TIFF 6.0 + DNG extensions).
public enum TIFFType: UInt16 {
    case byte = 1, ascii = 2, short = 3, long = 4, rational = 5
    case sbyte = 6, undef = 7, sshort = 8, slong = 9, srational = 10
    case float = 11, double = 12, ifd = 13

    var size: Int {
        switch self {
        case .byte, .ascii, .sbyte, .undef: return 1
        case .short, .sshort: return 2
        case .long, .slong, .float, .ifd: return 4
        case .rational, .srational, .double: return 8
        }
    }
}

/// One IFD entry with its value bytes already resolved (inline or out-of-line).
public struct TIFFEntry {
    public let tag: UInt16
    public let type: TIFFType
    public let count: Int
    /// Raw value bytes, host ordered for numeric types (we normalise on read).
    public let raw: [UInt8]
    let littleEndian: Bool

    public var ascii: String {
        String(bytes: raw.prefix(while: { $0 != 0 }), encoding: .utf8) ?? ""
    }

    public var ints: [Int] {
        switch type {
        case .byte, .undef, .sbyte: return raw.map { Int($0) }
        case .short, .sshort: return stride(from: 0, to: raw.count - 1, by: 2).map {
            Int(read16(raw, $0, littleEndian))
        }
        case .long, .slong, .ifd: return stride(from: 0, to: raw.count - 3, by: 4).map {
            Int(read32(raw, $0, littleEndian))
        }
        default: return []
        }
    }

    public var doubles: [Double] {
        switch type {
        case .byte, .undef, .short, .long, .ifd:
            return ints.map(Double.init)
        case .rational:
            return stride(from: 0, to: raw.count - 7, by: 8).map {
                let n = read32(raw, $0, littleEndian), d = read32(raw, $0 + 4, littleEndian)
                return d == 0 ? 0 : Double(n) / Double(d)
            }
        case .srational:
            return stride(from: 0, to: raw.count - 7, by: 8).map {
                let n = Int32(bitPattern: read32(raw, $0, littleEndian))
                let d = Int32(bitPattern: read32(raw, $0 + 4, littleEndian))
                return d == 0 ? 0 : Double(n) / Double(d)
            }
        case .float:
            return stride(from: 0, to: raw.count - 3, by: 4).map {
                Float(bitPattern: read32(raw, $0, littleEndian)).isFinite
                    ? Double(Float(bitPattern: read32(raw, $0, littleEndian))) : 0
            }
        case .double:
            return stride(from: 0, to: raw.count - 7, by: 8).map {
                Double(bitPattern: UInt64(read32(raw, $0, littleEndian))
                    | UInt64(read32(raw, $0 + 4, littleEndian)) << 32)
            }
        default: return []
        }
    }

    public var firstInt: Int? { ints.first }
    public var firstDouble: Double? { doubles.first }
}

@inline(__always) func read16(_ b: [UInt8], _ o: Int, _ le: Bool) -> UInt16 {
    le ? UInt16(b[o]) | UInt16(b[o + 1]) << 8 : UInt16(b[o]) << 8 | UInt16(b[o + 1])
}
@inline(__always) func read32(_ b: [UInt8], _ o: Int, _ le: Bool) -> UInt32 {
    le ? UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
       : UInt32(b[o]) << 24 | UInt32(b[o + 1]) << 16 | UInt32(b[o + 2]) << 8 | UInt32(b[o + 3])
}

public typealias IFD = [UInt16: TIFFEntry]

/// Classic TIFF container. `ifd(at:)` parses on demand; results are cached.
public final class TIFFFile {
    public let bytes: [UInt8]
    public let littleEndian: Bool
    private var cache: [Int: IFD] = [:]

    public init(data: Data) throws {
        self.bytes = [UInt8](data)
        guard bytes.count >= 8 else { throw TIFFError.notTIFF }
        if bytes[0] == 0x49 && bytes[1] == 0x49 { littleEndian = true }
        else if bytes[0] == 0x4D && bytes[1] == 0x4D { littleEndian = false }
        else { throw TIFFError.notTIFF }
        let magic = u16(2)
        if magic == 43 { throw TIFFError.bigTIFFUnsupported }
        guard magic == 42 else { throw TIFFError.notTIFF }
    }

    public var firstIFDOffset: Int { Int(u32(4)) }

    @inline(__always) func u16(_ o: Int) -> UInt16 {
        precondition(o + 2 <= bytes.count, "read past EOF")
        return read16(bytes, o, littleEndian)
    }
    @inline(__always) func u32(_ o: Int) -> UInt32 {
        precondition(o + 4 <= bytes.count, "read past EOF")
        return read32(bytes, o, littleEndian)
    }

    public func ifd(at offset: Int) throws -> IFD {
        if let c = cache[offset] { return c }
        guard offset > 0, offset + 2 <= bytes.count else { throw TIFFError.badIFD(offset) }
        let n = Int(u16(offset))
        guard offset + 2 + n * 12 <= bytes.count else { throw TIFFError.truncated("IFD entries") }
        var result: IFD = [:]
        result.reserveCapacity(n)
        for i in 0..<n {
            let e = offset + 2 + i * 12
            let tag = u16(e)
            let typeRaw = u16(e + 2)
            let count = Int(u32(e + 4))
            guard let type = TIFFType(rawValue: typeRaw) else { continue }
            let size = type.size * count
            let data: [UInt8]
            if size <= 4 {
                data = Array(bytes[(e + 8)..<(e + 8 + size)])
            } else {
                let off = Int(u32(e + 8))
                guard off >= 0, off + size <= bytes.count else { throw TIFFError.truncated("tag \(tag)") }
                data = Array(bytes[off..<(off + size)])
            }
            result[tag] = TIFFEntry(tag: tag, type: type, count: count, raw: data,
                                    littleEndian: littleEndian)
        }
        cache[offset] = result
        return result
    }

    /// Next IFD in the chain (0 == end).
    public func nextIFDOffset(after offset: Int) -> Int {
        let n = Int(u16(offset))
        let p = offset + 2 + n * 12
        guard p + 4 <= bytes.count else { return 0 }
        return Int(u32(p))
    }

    /// All IFDs reachable from IFD0: the chain plus every SubIFD, recursively.
    public func allIFDs() throws -> [(offset: Int, entries: IFD)] {
        var out: [(Int, IFD)] = []
        var seen = Set<Int>()
        func visit(_ off: Int, depth: Int) throws {
            guard off > 0, !seen.contains(off), depth < 8 else { return }
            seen.insert(off)
            let entries = try ifd(at: off)
            out.append((off, entries))
            for sub in entries[330]?.ints.prefix(16) ?? [] where sub > 0 {
                try visit(sub, depth: depth + 1)
            }
        }
        try visit(firstIFDOffset, depth: 0)
        var next = nextIFDOffset(after: firstIFDOffset)
        var guardCount = 0
        while next > 0 && guardCount < 8 {
            try visit(next, depth: 0)
            next = nextIFDOffset(after: next)
            guardCount += 1
        }
        return out
    }
}
