//
//  main.swift
//  hdrmerge-swift
//
//  Command line front end. GPLv3 — a Swift port of HDRMerge (© 2012 Javier Celaya).
//
//  Two audiences share one binary:
//    * humans — `inspect`, readable stdout;
//    * hosts  — any command with `--json`, which prints exactly one JSON object on
//               stdout and nothing else. See PROTOCOL.md.
//

import Foundation
import HDRMergeCore

enum Command: String {
    case inspect, merge, decode, synth, capabilities
}

func usage() -> String {
    """
    hdrmerge-swift — merge several RAW exposures into one Bayer (CFA) DNG

    usage:
      hdrmerge-swift capabilities [--json]
      hdrmerge-swift inspect [--json] <file.dng>...
      hdrmerge-swift merge -o out.dng [options] [--json] [--] in1.dng in2.dng ...
      hdrmerge-swift decode <in.dng> <out.pgm>
      hdrmerge-swift synth <in.dng> <out.dng> <divisor> [dx dy]   (test aid)

    options for merge:
      -o PATH             output DNG (written atomically)
      -b 16|32            bits per sample (default 16; 32 = float DNG)
      --compress          store samples as SOF3 lossless JPEG (Compression = 7).
                          ~121 MB → ~57 MB on a 60 MP frame. Incompatible with -b 32.
      --headroom N        reserve N× input white as the top of the container
                          (16-bit: 4 keeps the input scale bit-exact, +2 stops)
      --feather N         mask feather radius (default 3)
      --white N           override the white/saturation level
      --metadata-from PATH
                          take EXIF/DNG metadata from this frame instead of the
                          least exposed one
      --json              print one JSON object on stdout (host protocol)
      --progress          NDJSON progress events on stderr

    exit codes: 0 ok, 2 usage, 3 bad input, 4 incompatible frames, 5 write failed
    """
}

// MARK: - argument parsing

struct Parsed {
    var command: Command
    var positional: [String] = []
    var json = false
    var progress = false
    var out = ""
    var bits = 16
    var compress = false
    var headroom = 1.0
    var feather = 3
    var white: Int?
    var metadataFrom: String?
}

func parse(_ argv: [String]) throws -> Parsed {
    guard let first = argv.first else {
        throw CLIError("usage", usage(), exit: .usage)
    }
    guard let cmd = Command(rawValue: first) else {
        throw CLIError("unknown_command", "unknown command '\(first)'\n\n" + usage(), exit: .usage)
    }
    var p = Parsed(command: cmd)
    var i = 1
    var literal = false
    while i < argv.count {
        let a = argv[i]
        if literal || !a.hasPrefix("-") {
            p.positional.append(a)
            i += 1
            continue
        }
        switch a {
        case "--":
            literal = true; i += 1
        case "--json":
            p.json = true; i += 1
        case "--compress":
            p.compress = true; i += 1
        case "--progress":
            p.progress = true; i += 1
        case "-o":
            guard i + 1 < argv.count else { throw CLIError("usage", "-o needs a path", exit: .usage) }
            p.out = argv[i + 1]; i += 2
        case "-b":
            guard i + 1 < argv.count, let v = Int(argv[i + 1]), v == 16 || v == 32 else {
                throw CLIError("usage", "-b takes 16 or 32", exit: .usage)
            }
            p.bits = v; i += 2
        case "--headroom":
            guard i + 1 < argv.count, let v = Double(argv[i + 1]), v >= 1 else {
                throw CLIError("usage", "--headroom takes a number ≥ 1", exit: .usage)
            }
            p.headroom = v; i += 2
        case "--feather":
            guard i + 1 < argv.count, let v = Int(argv[i + 1]), v >= 1 else {
                throw CLIError("usage", "--feather takes a positive integer", exit: .usage)
            }
            p.feather = v; i += 2
        case "--white":
            guard i + 1 < argv.count, let v = Int(argv[i + 1]), v > 0 else {
                throw CLIError("usage", "--white takes a positive integer", exit: .usage)
            }
            p.white = v; i += 2
        case "--metadata-from":
            guard i + 1 < argv.count else {
                throw CLIError("usage", "--metadata-from needs a path", exit: .usage)
            }
            p.metadataFrom = argv[i + 1]; i += 2
        case "-h", "--help":
            throw CLIError("help", usage(), exit: .ok)
        default:
            throw CLIError("usage", "unknown option '\(a)'", exit: .usage)
        }
    }
    return p
}

// MARK: - commands

func runInspect(_ p: Parsed, _ progress: ProgressReporter) throws -> Response {
    guard !p.positional.isEmpty else {
        throw CLIError("usage", "inspect needs at least one file", exit: .usage)
    }
    var frames: [[String: Any]] = []
    var text: [String] = []
    for path in p.positional {
        let url = URL(fileURLWithPath: path)
        let f = try DNGReader.read(url: url)
        progress.event("inspected", ["file": path])
        frames.append(f.jsonSummary)
        let cfa = f.cfaPattern.map { ["R", "G", "B", "G2"][min(Int($0), 3)] }.joined()
        text.append("""
        \(url.lastPathComponent)
          camera        \(f.make) \(f.model)
          raw size      \(f.fullWidth) x \(f.fullHeight)  (active \(f.activeWidth)x\(f.activeHeight) @ \(f.activeLeft),\(f.activeTop))
          CFA           \(f.cfaRows)x\(f.cfaCols)  \(cfa)
          black         \(f.blackLevel.map { String(format: "%.1f", $0) }.joined(separator: ", "))
          white         \(f.whiteLevel)
          exposure      \(f.exposureTime) s   ISO \(f.iso)
          asShotNeutral \(f.asShotNeutral)
        """)
    }
    if !p.json { print(text.joined(separator: "\n")) }
    return Response(ok: true, command: "inspect", payload: ["frames": frames])
}

func runMerge(_ p: Parsed, _ progress: ProgressReporter) throws -> Response {
    guard !p.out.isEmpty else { throw CLIError("usage", "merge needs -o PATH", exit: .usage) }
    guard !p.positional.isEmpty else {
        throw CLIError("usage", "merge needs at least one input file", exit: .usage)
    }
    var frames: [RawFrame] = []
    for (i, path) in p.positional.enumerated() {
        progress.event("decode", ["index": i + 1, "total": p.positional.count, "file": path])
        frames.append(try DNGReader.read(url: URL(fileURLWithPath: path)))
    }

    let opts = MergeOptions(featherRadius: p.feather, customWhiteLevel: p.white, headroom: p.headroom)
    progress.event("merge", ["frames": frames.count])
    let merged = try HDRMergeCore.merge(frames: frames, options: opts)

    // Metadata: the least exposed frame by default (upstream HDRMerge behaviour),
    // or whatever the host asked for.
    let meta: RawFrame
    if let path = p.metadataFrom {
        if let hit = frames.first(where: { $0.url.path == URL(fileURLWithPath: path).path }) {
            meta = hit
        } else {
            meta = try DNGReader.read(url: URL(fileURLWithPath: path))
        }
    } else {
        meta = frames.min { $0.exposureTime * $0.iso < $1.exposureTime * $1.iso } ?? frames[0]
    }

    progress.event("encode", ["bits": p.bits, "compressed": p.compress])
    let compression: DNGWriter.Compression = p.compress ? .lossless : .uncompressed
    let data = try DNGWriter.render(merged, source: meta, bits: p.bits, compression: compression)
    let outURL = URL(fileURLWithPath: p.out)
    do {
        try FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try atomicWrite(data, to: outURL)
    } catch {
        throw CLIError("write_failed", "cannot write \(outURL.path): \(error)", exit: .writeFailed)
    }
    progress.event("done", ["bytes": data.count])

    let payload: [String: Any] = [
        "output": outURL.path,
        "bytes": data.count,
        "width": merged.width,
        "height": merged.height,
        "frames": frames.count,
        "bits": p.bits,
        "compressed": p.compress,
        "headroom": p.headroom,
        "whiteLevel": merged.white,
        "blackLevel": merged.black,
        "cfaPattern": merged.cfaPattern.map { Int($0) },
        "offsets": merged.offsets.map { ["x": $0.x, "y": $0.y] },
        "metadataFrom": meta.url.path,
        "report": merged.report,
    ]
    if !p.json {
        for line in merged.report { print(line) }
        print("merged \(merged.width)x\(merged.height) from \(frames.count) frame(s)")
        print("metadata from \(meta.url.lastPathComponent)")
        print("wrote \(outURL.path) (\(data.count) bytes)")
    }
    return Response(ok: true, command: "merge", payload: payload)
}

func runDecode(_ p: Parsed) throws -> Response {
    guard p.positional.count == 2 else {
        throw CLIError("usage", "decode needs <in.dng> <out.pgm>", exit: .usage)
    }
    let f = try DNGReader.read(url: URL(fileURLWithPath: p.positional[0]))
    try DNGReader.writePGM(f, to: URL(fileURLWithPath: p.positional[1]))
    if !p.json {
        print("wrote \(p.positional[1]) (\(f.fullWidth)x\(f.fullHeight))")
    }
    return Response(ok: true, command: "decode", payload: [
        "output": p.positional[1], "width": f.fullWidth, "height": f.fullHeight,
    ])
}

func runSynth(_ p: Parsed) throws -> Response {
    guard p.positional.count >= 3 else {
        throw CLIError("usage", "synth needs <in.dng> <out.dng> <divisor> [dx dy]", exit: .usage)
    }
    let src = try DNGReader.read(url: URL(fileURLWithPath: p.positional[0]))
    let divisor = Double(p.positional[2]) ?? 1
    let dx = p.positional.count > 4 ? (Int(p.positional[3]) ?? 0) : 0
    let dy = p.positional.count > 4 ? (Int(p.positional[4]) ?? 0) : 0
    let black = src.blackLevel.max() ?? 0
    var values = [Float](repeating: 0, count: src.activeWidth * src.activeHeight)
    for y in 0..<src.activeHeight {
        for x in 0..<src.activeWidth {
            let sx = x - dx, sy = y - dy
            guard sx >= 0, sx < src.activeWidth, sy >= 0, sy < src.activeHeight else { continue }
            let v = (Double(src.sample(sx, sy)) - black) / divisor + black
            values[y * src.activeWidth + x] = Float(min(max(v, 0), Double(src.whiteLevel)))
        }
    }
    let m = MergedImage(width: src.activeWidth, height: src.activeHeight, values: values,
                        black: black, white: src.whiteLevel,
                        cfaPattern: src.cfaPattern, cfaRows: src.cfaRows, cfaCols: src.cfaCols,
                        offsets: [(0, 0)], referenceIndex: 1, report: [])
    let data = try DNGWriter.render(m, source: src, bits: 16)
    try atomicWrite(data, to: URL(fileURLWithPath: p.positional[1]))
    if !p.json {
        print("wrote \(p.positional[1]) (\(src.activeWidth)x\(src.activeHeight), /\(divisor), shift \(dx),\(dy))")
    }
    return Response(ok: true, command: "synth", payload: ["output": p.positional[1]])
}

func runCapabilities() -> Response {
    Response(ok: true, command: "capabilities", payload: [
        "commands": ["inspect", "merge", "decode", "synth", "capabilities"],
        "features": ProtocolInfo.features,
        "defaults": ["bits": 16, "headroom": 1.0, "feather": 3],
        "limits": [
            "inputFormats": ["DNG (CFA), photometric 32803, compression 1 or 7"],
            "maxFrames": 32,
        ],
    ])
}

// MARK: - main

let argv = Array(CommandLine.arguments.dropFirst())
let wantsJSON = argv.contains("--json")

var parsed: Parsed?
do {
    parsed = try parse(argv)
} catch let e as CLIError {
    if wantsJSON && e.exit != .ok {
        Response(ok: false, command: argv.first ?? "", payload: [:],
                 warnings: [], error: (e.code, e.message)).emit()
    } else {
        print(e.message)
    }
    exit(e.exit.rawValue)
} catch {
    print("\(error)")
    exit(ExitCode.internalError.rawValue)
}

guard let p = parsed else { exit(ExitCode.internalError.rawValue) }
let progress = ProgressReporter(enabled: p.progress)

do {
    let response: Response
    switch p.command {
    case .capabilities:
        // Machine and human get the same payload; only the envelope differs.
        response = runCapabilities()
        if !p.json { response.emit() }
    case .inspect: response = try runInspect(p, progress)
    case .merge: response = try runMerge(p, progress)
    case .decode: response = try runDecode(p)
    case .synth: response = try runSynth(p)
    }
    if p.json { response.emit() }
    exit(ExitCode.ok.rawValue)
} catch let e as CLIError {
    progress.log("\(e.code): \(e.message)")
    if p.json {
        Response(ok: false, command: p.command.rawValue, payload: [:],
                 warnings: [], error: (e.code, e.message)).emit()
    } else {
        FileHandle.standardError.write(Data((e.message + "\n").utf8))
    }
    exit(e.exit.rawValue)
} catch {
    let wrapped = CLIError.wrap(error)
    progress.log("\(wrapped.code): \(wrapped.message)")
    if p.json {
        Response(ok: false, command: p.command.rawValue, payload: [:],
                 warnings: [], error: (wrapped.code, wrapped.message)).emit()
    } else {
        FileHandle.standardError.write(Data((wrapped.message + "\n").utf8))
    }
    exit(wrapped.exit.rawValue)
}
