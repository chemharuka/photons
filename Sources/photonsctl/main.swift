import Foundation
import PhotonsCore

// photonsctl — the acceptance harness for M0. Deliberately dependency-free (no
// swift-argument-parser): it must keep building even when the app is mid-refactor.

func err(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }
func die(_ s: String) -> Never { err("error: " + s); exit(1) }
func note(_ s: String) { print(s) }

struct Args {
    var positional: [String] = []
    var values: [String: String] = [:]
    var flags: Set<String> = []
    func value(_ k: String) -> String? { values[k] }
    func has(_ k: String) -> Bool { flags.contains(k) }
}

func parseArgs(_ argv: [String]) -> Args {
    var a = Args()
    var i = 0
    let valueFlags: Set<String> = ["--version", "--ev", "--scale", "--out", "--dir", "--limit-gb"]
    while i < argv.count {
        let t = argv[i]
        if valueFlags.contains(t) {
            guard i + 1 < argv.count else { die("missing value for \(t)") }
            a.values[t] = argv[i + 1]; i += 2
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

    options:
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
    default:       die("unknown command '\(cmd)' (try: photonsctl)")
    }
} catch let e as DecodeError {
    die(e.errorDescription ?? "\(e)")
} catch {
    die("\(error)")
}
