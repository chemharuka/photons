import Foundation
import PhotonsCore
import PhotonsExport
import PhotonsCatalog
import CryptoKit

// photonsctl — the acceptance harness. Deliberately dependency-free (no
// swift-argument-parser): it must keep building even when the app is mid-refactor.

func err(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }
func die(_ s: String) -> Never { err("error: " + s); exit(1) }
func note(_ s: String) { print(s) }

struct Args {
    var positional: [String] = []
    var values: [String: String] = [:]
    var repeated: [String: [String]] = [:]
    var flags: Set<String> = []
    func value(_ k: String) -> String? { values[k] }
    func all(_ k: String) -> [String] { repeated[k] ?? [] }
    func has(_ k: String) -> Bool { flags.contains(k) }
}

let valueFlags: Set<String> = [
    "--version", "--ev", "--scale", "--out", "--dir", "--limit-gb",
    "--edit", "--format", "--space", "--bits", "--quality",
    "--viewport", "--iterations", "--decode-scale", "--golden", "--cache-dir",
    "--mode", "--root", "--rename", "--test-interrupt-after",
    "--count", "--dupes", "--size", "--since", "--camera", "--rating", "--limit",
]

func parseArgs(_ argv: [String]) -> Args {
    var a = Args()
    var i = 0
    while i < argv.count {
        let t = argv[i]
        if valueFlags.contains(t) {
            guard i + 1 < argv.count else { die("missing value for \(t)") }
            a.values[t] = argv[i + 1]
            a.repeated[t, default: []].append(argv[i + 1])
            i += 2
        } else if t.hasPrefix("--") {
            a.flags.insert(t); i += 1
        } else {
            a.positional.append(t); i += 1
        }
    }
    return a
}

func decodeOptions(_ a: Args) -> DecodeOptions {
    var o = DecodeOptions()
    o.decoderVersion = a.value("--version")
    if let v = a.value("--ev") { o.exposureEV = Float(v) ?? 0 }
    if let v = a.value("--scale") { o.scale = Float(v) ?? 1 }
    o.draft = a.has("--draft")
    return o
}

func requireRaw(_ a: Args) -> URL {
    guard let p = a.positional.first else { die("missing <raw> path") }
    let url = URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
    guard FileManager.default.fileExists(atPath: url.path) else { die("no such file: \(url.path)") }
    return url
}

func makeDecoder() -> RAWDecoder {
    do { return try RAWDecoder() } catch { die("decoder unavailable: \(error.localizedDescription)") }
}

func cmdInfo(_ a: Args) {
    let url = requireRaw(a)
    let probe = try! makeDecoder().probe(url)
    note("file            \(url.lastPathComponent)")
    note("camera          \(probe.make ?? "?") / \(probe.model ?? "?")  ISO \(probe.iso.map(String.init) ?? "?")")
    note("nativeSize      \(probe.nativeWidth) x \(probe.nativeHeight)")
    note("defaultVersion  \(probe.defaultVersion)")
    note("versions        \(probe.supportedVersions.joined(separator: ", "))")
    note("fileSHA256      \(try! FileDigest.sha256(of: url))")
}

func cmdHash(_ a: Args) throws {
    let url = requireRaw(a)
    let img = try makeDecoder().decode(url, options: decodeOptions(a))
    // Machine-readable single line: scripts diff this.
    print("\(img.sha256())  \(img.width)x\(img.height) v\(img.decoderVersion) ev\(a.value("--ev") ?? "0") scale\(a.value("--scale") ?? "1")\(a.has("--draft") ? " draft" : "")")
    let st = img.statistics()
    err(String(format: "  max=%.4f mean=%.5f over1.0=%.4f%% bytes=%d",
               st.maxChannel, st.meanLuma, st.overUnityRatio * 100, img.byteCount))
}

func cmdDecode(_ a: Args) throws {
    let url = requireRaw(a)
    guard let out = a.value("--out") else { die("decode needs --out <dir>") }
    let store = try LinearImageStore(directory: URL(fileURLWithPath: (out as NSString).expandingTildeInPath))
    let opts = decodeOptions(a)
    let fileHash = try FileDigest.sha256(of: url)
    let decoder = makeDecoder()

    // Version must be resolved before the key can be built.
    let probe = try decoder.probe(url)
    let version = opts.decoderVersion ?? probe.defaultVersion
    let key = DecodeCacheKey(fileSHA256: fileHash, decoderVersion: version,
                             exposureEV: opts.exposureEV, scale: opts.scale, draft: opts.draft,
                             colorSpace: opts.colorSpace.rawValue)
    if let hit = try store.load(key) {
        note("cache hit  \(store.binURL(for: key).lastPathComponent)")
        note("sha256     \(hit.sha256())")
        return
    }
    let t0 = CFAbsoluteTimeGetCurrent()
    let img = try decoder.decode(url, options: opts)
    let dt = CFAbsoluteTimeGetCurrent() - t0
    try store.save(img, key: key)
    note(String(format: "decoded    %.2f s  %.1f Mpx/s", dt, Double(img.width * img.height) / dt / 1e6))
    note("sha256     \(img.sha256())")
    note("bytes      \(img.byteCount)")
    note("stored     \(store.binURL(for: key).path)")
    note(String(format: "cache now  %.1f MB", Double(store.totalBytes()) / 1e6))
}

struct GoldenRecord: Codable {
    var raw: String
    var rawSHA256: String
    var decoderVersion: String
    var exposureEV: Float
    var scale: Float
    var draft: Bool
    var colorSpace: String
    var width: Int
    var height: Int
    var hash: String
    var osVersion: String
    var createdAt: String
    var note: String?
}

func goldenPath(_ dir: URL, raw: URL, version: String, scale: Float) -> URL {
    let base = raw.deletingPathExtension().lastPathComponent
    return dir.appendingPathComponent("\(base)-v\(version)-s\(scale).json")
}

func cmdGolden(_ a: Args) throws {
    guard let mode = a.positional.first, ["record", "check"].contains(mode) else {
        die("golden needs 'record' or 'check'")
    }
    let url = requireRaw(Args(positional: Array(a.positional.dropFirst()), values: a.values, flags: a.flags))
    let dir = URL(fileURLWithPath: ((a.value("--dir") ?? "Tests/Golden") as NSString).expandingTildeInPath)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let opts = decodeOptions(a)
    let decoder = makeDecoder()
    let probe = try decoder.probe(url)
    let version = opts.decoderVersion ?? probe.defaultVersion
    let img = try decoder.decode(url, options: opts)
    let path = goldenPath(dir, raw: url, version: version, scale: opts.scale)
    let os = ProcessInfo.processInfo.operatingSystemVersionString

    if mode == "record" {
        let rec = GoldenRecord(raw: url.lastPathComponent, rawSHA256: try FileDigest.sha256(of: url),
                               decoderVersion: version, exposureEV: opts.exposureEV, scale: opts.scale,
                               draft: opts.draft, colorSpace: img.colorSpace,
                               width: img.width, height: img.height, hash: img.sha256(),
                               osVersion: os,
                               createdAt: ISO8601DateFormatter().string(from: Date()),
                               note: "Recorded by photonsctl on \(os). Apple's decoder output can change across OS releases; re-record on major OS bumps and keep the old file as history.")
        let data = try JSONEncoder.pretty.encode(rec)
        try data.write(to: path)
        note("recorded   \(path.path)")
        note("hash       \(rec.hash)")
        return
    }

    guard FileManager.default.fileExists(atPath: path.path) else {
        die("no golden at \(path.path) — run: photonsctl golden record ...")
    }
    let rec = try JSONDecoder().decode(GoldenRecord.self, from: Data(contentsOf: path))
    let now = img.sha256()
    let sameOS = rec.osVersion == os
    if now == rec.hash {
        note("PASS  \(url.lastPathComponent) v\(version) s\(opts.scale)  \(now.prefix(16))…")
    } else {
        err("FAIL  \(url.lastPathComponent) v\(version) s\(opts.scale)")
        err("      golden \(rec.hash)")
        err("      actual \(now)")
        err("      golden recorded on \(rec.osVersion) (\(rec.createdAt)); now \(os)")
        if !sameOS { err("      → OS changed. If the new output is intended, re-record with --os-bump.") }
        exit(1)
    }
}

func cmdCache(_ a: Args) throws {
    let dir = URL(fileURLWithPath: ((a.value("--dir") ?? "~/Library/Caches/Photons/linear") as NSString).expandingTildeInPath)
    let store = try LinearImageStore(directory: dir)
    note(String(format: "cache dir   %@", dir.path))
    note(String(format: "total       %.1f MB", Double(store.totalBytes()) / 1e6))
    if a.has("--evict") {
        let gb = Double(a.value("--limit-gb") ?? "20") ?? 20
        store.evict(keepingBytes: Int64(gb * 1e9))
        note(String(format: "after evict %.1f MB (limit %.0f GB)", Double(store.totalBytes()) / 1e6, gb))
    }
}

// MARK: - M1: render / bench

struct RenderGolden: Codable {
    var raw: String
    var rawSHA256: String
    var decoderVersion: String
    var edit: String
    var scale: Double
    var width: Int
    var height: Int
    var pixelSHA256: String
    var fileSHA256: String
    var stageKeys: String
    var osVersion: String
    var createdAt: String
    var note: String?
}

func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func displayOptions(_ a: Args) -> DisplayOptions {
    var d = DisplayOptions()
    if let s = a.value("--space")?.lowercased(), s == "p3" || s == "displayp3" {
        d.primaries = .displayP3
    }
    if let b = a.value("--bits").flatMap(Int.init) { d.bitDepth = b }
    return d
}

func exportOptions(_ a: Args, url: URL) -> ExportOptions {
    var o = ExportOptions.detect(from: url)
    if let f = a.value("--format")?.lowercased() {
        switch f {
        case "jpeg", "jpg": o.format = .jpeg
        case "heic": o.format = .heic
        case "tiff", "tif": o.format = .tiff
        default: break
        }
    }
    if let b = a.value("--bits").flatMap(Int.init) { o.bitDepth = b }
    if let q = a.value("--quality").flatMap(Double.init) { o.quality = q }
    if o.format == .jpeg { o.bitDepth = 8 }
    return o
}

func loadEdits(_ a: Args) throws -> (models: [EditModel], names: [String]) {
    let paths = a.all("--edit")
    if paths.isEmpty { return ([.neutral], ["neutral"]) }
    let urls = paths.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
    let models = try urls.map { try EditModel.load(from: $0) }
    let names = urls.map { $0.deletingPathExtension().lastPathComponent }
    return (models, names)
}

/// Smallest decode scale that still covers `target`. Decoding at a coarser scale than the output
/// would resample pixels twice and lose detail; decoding finer wastes 0.5 s and 480 MB.
func decodeScaleLadder(_ target: Double) -> Float {
    for s in [0.0625, 0.125, 0.25, 0.5, 1.0] where s >= target - 1e-9 { return Float(s) }
    return 1.0
}

func parseSize(_ s: String) -> ImageSize {
    let parts = s.lowercased().split(separator: "x")
    guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]), w > 0, h > 0 else {
        die("bad size '\(s)' (want WxH, e.g. 2560x1600)")
    }
    return ImageSize(width: w, height: h)
}

func median(_ xs: [Double]) -> Double {
    let s = xs.sorted()
    guard !s.isEmpty else { return 0 }
    return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
}

func percentile(_ xs: [Double], _ p: Double) -> Double {
    let s = xs.sorted()
    guard !s.isEmpty else { return 0 }
    let idx = min(s.count - 1, max(0, Int((Double(s.count - 1) * p).rounded())))
    return s[idx]
}

func decodeForRender(_ a: Args, url: URL, decodeScale: Float, fileHash: String,
                     version: String, quiet: Bool = false) throws -> (LinearImage, String) {
    let key = DecodeCacheKey(fileSHA256: fileHash, decoderVersion: version, exposureEV: 0,
                             scale: decodeScale, draft: false, colorSpace: "extendedLinearSRGB")
    let decoder = makeDecoder()

    if let dirPath = a.value("--cache-dir") {
        let store = try LinearImageStore(directory: URL(fileURLWithPath: (dirPath as NSString).expandingTildeInPath))
        if let hit = try store.load(key) {
            if !quiet { note(String(format: "decode     cache hit (scale %.3f, %d×%d)", decodeScale, hit.width, hit.height)) }
            return (hit, key.digest)
        }
        let t0 = CFAbsoluteTimeGetCurrent()
        let img = try decoder.decode(url, options: DecodeOptions(decoderVersion: a.value("--version"), scale: decodeScale))
        try store.save(img, key: key)
        if !quiet {
            note(String(format: "decode     %.2f s (scale %.3f, %d×%d, stored)", CFAbsoluteTimeGetCurrent() - t0,
                        decodeScale, img.width, img.height))
        }
        return (img, key.digest)
    }

    let t0 = CFAbsoluteTimeGetCurrent()
    let img = try decoder.decode(url, options: DecodeOptions(decoderVersion: a.value("--version"), scale: decodeScale))
    if !quiet {
        note(String(format: "decode     %.2f s (scale %.3f, %d×%d)", CFAbsoluteTimeGetCurrent() - t0,
                    decodeScale, img.width, img.height))
    }
    return (img, key.digest)
}

func cmdRender(_ a: Args) throws {
    let url = requireRaw(a)
    guard let outPath = a.value("--out") else { die("render needs --out <file>") }
    let outURL = URL(fileURLWithPath: (outPath as NSString).expandingTildeInPath)
    let scale = a.value("--scale").flatMap(Double.init) ?? 1
    let display = displayOptions(a)
    let (edits, names) = try loadEdits(a)
    let trace = a.has("--trace-stages")

    let probe = try makeDecoder().probe(url)
    let version = a.value("--version") ?? probe.defaultVersion
    let fileHash = try FileDigest.sha256(of: url)
    let decodeScale = a.value("--decode-scale").flatMap(Float.init) ?? decodeScaleLadder(scale)
    let (decoded, identity) = try decodeForRender(a, url: url, decodeScale: decodeScale,
                                                  fileHash: fileHash, version: version)
    note("source     \(url.lastPathComponent) v\(decoded.decoderVersion) → render v\(version)")

    // `--scale` is relative to the *full-resolution* crop; the render works on the decoded buffer,
    // which is already at `decodeScale`, so the pass scale is the remainder.
    let renderScale = scale / Double(decodeScale)

    let graph = try RenderGraph(input: RenderInput(image: decoded, identity: identity))
    guard let goldenMode = a.value("--golden") else {
        try renderAll(a, graph: graph, edits: edits, names: names, outURL: outURL,
                      scale: scale, renderScale: renderScale, display: display, trace: trace,
                      raw: url, rawHash: fileHash, decoderVersion: version)
        return
    }
    guard ["record", "check"].contains(goldenMode) else { die("--golden needs record|check") }
    try renderAll(a, graph: graph, edits: edits, names: names, outURL: outURL,
                  scale: scale, renderScale: renderScale, display: display, trace: trace,
                  raw: url, rawHash: fileHash, decoderVersion: version, goldenMode: goldenMode)
}

func renderAll(_ a: Args, graph: RenderGraph, edits: [EditModel], names: [String], outURL: URL,
               scale: Double, renderScale: Double, display: DisplayOptions, trace: Bool,
               raw: URL, rawHash: String, decoderVersion: String, goldenMode: String? = nil) throws {
    let dir = URL(fileURLWithPath: ((a.value("--dir") ?? "Tests/Golden") as NSString).expandingTildeInPath)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    for (i, edit) in edits.enumerated() {
        let name = names[i]
        var outFile = outURL
        if edits.count > 1 {
            let ext = outURL.pathExtension
            let base = outURL.deletingPathExtension()
            outFile = URL(fileURLWithPath: base.path + "-" + name + (ext.isEmpty ? "" : "." + ext))
        }

        let opts = RenderOptions(canvas: nil, scale: renderScale, display: display,
                                 useCache: true, wantsPixels: true)
        let result = try graph.render(edit, options: opts)
        guard let pixels = result.display else { die("render returned no pixels") }

        let ex = exportOptions(a, url: outFile)
        try Exporter.write(pixels, to: outFile, options: ex)
        let bytes = try Data(contentsOf: outFile)
        let fileDigest = sha256Hex(bytes)

        note("edit       \(name)")
        note("canvas     \(result.canvas.width)×\(result.canvas.height)  content \(result.content.width)×\(result.content.height)"
             + "  \(ex.format.rawValue) \(ex.bitDepth)-bit \(display.primaries.displayName)")
        if trace {
            note(result.trace.summary)
        } else {
            note(String(format: "gpu        %.2f ms", result.trace.gpuMilliseconds))
        }
        note("pixels     \(pixels.sha256())")
        note(String(format: "file       %@ %.1f KB", outFile.path, Double(bytes.count) / 1024))
        note("file sha   \(fileDigest)")

        guard let mode = goldenMode else { continue }
        let goldenURL = dir.appendingPathComponent(
            String(format: "render-%@-s%.2f.json", name, scale))
        if mode == "record" {
            let rec = RenderGolden(raw: raw.lastPathComponent, rawSHA256: rawHash,
                                   decoderVersion: decoderVersion, edit: name, scale: scale,
                                   width: pixels.width, height: pixels.height,
                                   pixelSHA256: pixels.sha256(), fileSHA256: fileDigest,
                                   stageKeys: result.keys.shortTrace,
                                   osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                                   createdAt: ISO8601DateFormatter().string(from: Date()),
                                   note: "Recorded by photonsctl render. Apple's decoder output can change across OS releases; re-record on major OS bumps and keep the old file as history.")
            try JSONEncoder.pretty.encode(rec).write(to: goldenURL, options: .atomic)
            note("golden     recorded \(goldenURL.lastPathComponent)")
            continue
        }
        guard FileManager.default.fileExists(atPath: goldenURL.path) else {
            die("no golden at \(goldenURL.path) — run with --golden record")
        }
        let rec = try JSONDecoder().decode(RenderGolden.self, from: Data(contentsOf: goldenURL))
        if rec.pixelSHA256 == pixels.sha256() && rec.fileSHA256 == fileDigest {
            note("golden     PASS \(goldenURL.lastPathComponent)")
        } else {
            err("golden     FAIL \(goldenURL.lastPathComponent)")
            if rec.pixelSHA256 != pixels.sha256() {
                err("           pixels golden \(rec.pixelSHA256.prefix(16))… actual \(pixels.sha256().prefix(16))…")
            }
            if rec.fileSHA256 != fileDigest {
                err("           file   golden \(rec.fileSHA256.prefix(16))… actual \(fileDigest.prefix(16))…")
            }
            err("           recorded on \(rec.osVersion)")
            exit(1)
        }
    }
}

func cmdBench(_ a: Args) throws {
    let url = requireRaw(a)
    let viewport = parseSize(a.value("--viewport") ?? "2560x1600")
    let iterations = a.value("--iterations").flatMap(Int.init) ?? 60
    let scale = a.value("--scale").flatMap(Double.init) ?? 1
    let display = displayOptions(a)
    let (edits, names) = try loadEdits(a)
    let edit = edits[0]

    let probe = try makeDecoder().probe(url)
    let version = a.value("--version") ?? probe.defaultVersion
    let fileHash = try FileDigest.sha256(of: url)
    let fitScale = min(Double(viewport.width) / Double(probe.nativeWidth),
                       Double(viewport.height) / Double(probe.nativeHeight)) * scale
    let decodeScale = a.value("--decode-scale").flatMap(Float.init) ?? decodeScaleLadder(fitScale)
    let (decoded, identity) = try decodeForRender(a, url: url, decodeScale: decodeScale,
                                                  fileHash: fileHash, version: version)

    let graph = try RenderGraph(input: RenderInput(image: decoded, identity: identity))
    let opts = RenderOptions(canvas: viewport, scale: 1, display: display,
                             useCache: false, wantsPixels: false)

    // Warm up: pipeline creation, first texture allocation, shader cache.
    var planLine = ""
    for _ in 0..<3 {
        let r = try graph.render(edit, options: opts)
        if let t = r.output { graph.recycle(output: t) }
        planLine = "viewport   \(viewport.width)×\(viewport.height)  content \(r.content.width)×\(r.content.height)"
    }

    var samples: [Double] = []
    var gpuSamples: [Double] = []
    for _ in 0..<max(1, iterations) {
        let t0 = CFAbsoluteTimeGetCurrent()
        let r = try graph.render(edit, options: opts)
        samples.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        gpuSamples.append(r.trace.gpuMilliseconds)
        if let t = r.output { graph.recycle(output: t) }
    }

    let mpx = Double(viewport.width * viewport.height) / 1e6
    note("device     \(graph.deviceName)")
    note(planLine + String(format: " (%.2f Mpx)", mpx))
    note(String(format: "decode     scale %.3f → %d×%d", decodeScale, decoded.width, decoded.height))
    note("edit       \(names[0])")
    note("pass       s0→s4, cache off, no CPU readback (the on-screen path)")
    note(String(format: "iterations %d (+3 warmup)", iterations))
    note(String(format: "frame      p50 %.2f ms  p95 %.2f ms  min %.2f  max %.2f",
                median(samples), percentile(samples, 0.95), samples.min() ?? 0, samples.max() ?? 0))
    note(String(format: "gpu only   p50 %.2f ms  p95 %.2f ms", median(gpuSamples), percentile(gpuSamples, 0.95)))
    let budget = 16.7
    let p95 = percentile(samples, 0.95)
    if p95 <= budget {
        note(String(format: "PASS       p95 %.2f ms ≤ %.2f ms (60 fps budget)", p95, budget))
    } else {
        err(String(format: "FAIL       p95 %.2f ms > %.2f ms (60 fps budget)", p95, budget))
        exit(1)
    }
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}

// MARK: - entry

let argv = Array(CommandLine.arguments.dropFirst())
guard let cmd = argv.first else {
    print("""
    photonsctl — Photons acceptance harness

    usage:
      photonsctl info   <raw>
      photonsctl hash   <raw> [--version V] [--ev F] [--scale F] [--draft]
      photonsctl decode <raw> --out <dir> [options]
      photonsctl golden record|check <raw> [--dir Tests/Golden] [options]
      photonsctl cache  [--dir <dir>] [--evict --limit-gb 20]

      photonsctl render <raw> --edit <json> [--edit <json> …] --out <file> [options]
      photonsctl bench  <raw> [--viewport 2560x1600] [--iterations 60] [options]

      photonsctl library create  <pkg.photonslibrary>
      photonsctl library import  <pkg> <src…> [--mode copy|reference] [--root id] [--rename T] [--json]
      photonsctl library rescan  <pkg> [--json]
      photonsctl library assets  <pkg> [--rating N] [--camera key] [--since YYYY-MM-DD] [--limit N] [--json]
      photonsctl library stats   <pkg> [--json]
      photonsctl library verify  <pkg> [--rehash] [--json]
      photonsctl fixtures <dir> [--count 100] [--dupes 10] [--size 320x240]

    render options:
      --scale F        output scale relative to crop pixels (default 1)
      --decode-scale F decoder scale (default: the smallest ladder step covering --scale)
      --format         jpeg | heic | tiff    (default: from the --out extension)
      --space          sRGB | displayP3      (default sRGB)
      --bits           8 | 16                (default 8; jpeg is always 8)
      --quality F      lossy quality 0…1     (default 0.95)
      --trace-stages   print which stages executed and which came from the cache
      --golden         record | check        (baseline in --dir, default Tests/Golden)
      --cache-dir      keep decoded linear buffers on disk between runs

    decode options:
      --version   decoder version string, e.g. 8 / 8.dng / 9 / 9.dng (default: file's own default)
      --ev        exposure in stops applied by the system RAW pipeline
      --scale     decode scale factor (1 = full resolution)
      --draft     enable the system's draft (low quality) path
    """)
    exit(0)
}

let rest = parseArgs(Array(argv.dropFirst()))
do {
    switch cmd {
    case "info":   cmdInfo(rest)
    case "hash":   try cmdHash(rest)
    case "decode": try cmdDecode(rest)
    case "golden": try cmdGolden(parseArgs(Array(argv.dropFirst())))
    case "cache":  try cmdCache(rest)
    case "render":   try cmdRender(rest)
    case "bench":    try cmdBench(rest)
    case "library":  try cmdLibrary(rest)
    case "fixtures": try cmdFixtures(rest)
    default:       die("unknown command '\(cmd)' (try: photonsctl)")
    }
} catch let e as DecodeError {
    die(e.errorDescription ?? "\(e)")
} catch let e as CatalogError {
    die(e.errorDescription ?? "\(e)")
} catch {
    die("\(error)")
}
