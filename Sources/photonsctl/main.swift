import Foundation
import PhotonsCore
import PhotonsExport
import PhotonsCatalog
import PhotonsDepth
import CoreVideo
import CryptoKit
import CoreGraphics
import CoreML
import ImageIO

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
    "--ids", "--tier", "--strategy", "--roi", "--bins", "--headroom", "--wb",
    "--repeat", "--album", "--tone-map", "--tone-map-headroom", "--model", "--units",
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

/// `--wb 3500/+30`, `--wb 3500`, `--wb as-shot` (派单 006). Unparseable input is a hard error: a
/// silently ignored white balance would make `hash`/`decode` report the as-shot pixels under a
/// "3500 K" label, which is the exact class of lie this change removes.
func whiteBalanceOption(_ a: Args) -> WhiteBalance {
    guard let raw = a.value("--wb") else { return .asShot }
    let s = raw.lowercased().trimmingCharacters(in: .whitespaces)
    if s == "as-shot" || s == "asshot" || s == "as shot" || s == "shot" { return .asShot }
    let parts = s.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count <= 2 else { die("bad --wb '\(raw)' (want K/tint, K, or as-shot)") }
    guard let k = Double(parts[0]) else { die("bad --wb temperature '\(parts[0])'") }
    var tint: Double?
    if parts.count == 2 {
        guard let t = Double(parts[1]) else { die("bad --wb tint '\(parts[1])'") }
        tint = t
    }
    return WhiteBalance(temperature: k, tint: tint).quantized()
}

func decodeOptions(_ a: Args) -> DecodeOptions {
    var o = DecodeOptions()
    o.decoderVersion = a.value("--version")
    if let v = a.value("--ev") { o.exposureEV = Float(v) ?? 0 }
    if let v = a.value("--scale") { o.scale = Float(v) ?? 1 }
    o.draft = a.has("--draft")
    o.whiteBalance = whiteBalanceOption(a)
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
    // 派单 006 A: the file's own white balance — what the inspector shows while the document is
    // as shot, instead of the nominal 6500 K the panel used to print.
    note("asShotWB        \(WhiteBalance(temperature: probe.asShotTemperature, tint: probe.asShotTint).summary)")
    note("fileSHA256      \(try! FileDigest.sha256(of: url))")
}

func cmdHash(_ a: Args) throws {
    let url = requireRaw(a)
    let opts = decodeOptions(a)
    let img = try makeDecoder().decode(url, options: opts)
    // Machine-readable single line: scripts diff this.
    print("\(img.sha256())  \(img.width)x\(img.height) v\(img.decoderVersion) ev\(a.value("--ev") ?? "0") scale\(a.value("--scale") ?? "1")\(a.has("--draft") ? " draft" : "") wb(\(opts.whiteBalance.summary))")
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
                             colorSpace: opts.colorSpace.rawValue,
                             whiteBalance: opts.whiteBalance,
                             lens: LensProfile.read(from: url)?.recipeComponent)
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

// MARK: - 120a: depth (Depth Anything V2 Small)

/// Peak resident size of this process. macOS reports `ru_maxrss` in bytes.
func peakResidentBytes() -> Int64 {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Int64(usage.ru_maxrss)
}

/// Set when `--model` pointed at an `.mlpackage`; removed when the command finishes.
var depthModelTemporaryDirectory: URL?

/// `--model` is either a compiled `.mlmodelc` or the shipped `.mlpackage`; the latter is compiled
/// into a throwaway directory with the same `coremlcompiler` `scripts/depth-model.sh` calls.
func compileDepthPackage(_ url: URL) throws -> URL {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("photons-depth-model-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["coremlcompiler", "compile", url.path, tmp.path]
    do { try process.run() } catch { die("cannot run xcrun coremlcompiler: \(error)") }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        die("coremlcompiler failed (\(process.terminationStatus)) for \(url.path)")
    }
    let compiled = tmp.appendingPathComponent(
        url.deletingPathExtension().lastPathComponent + ".mlmodelc")
    guard FileManager.default.fileExists(atPath: compiled.path) else {
        die("coremlcompiler produced no \(compiled.lastPathComponent)")
    }
    note("compiled    \(url.lastPathComponent) -> \(compiled.path)")
    depthModelTemporaryDirectory = tmp
    return compiled
}

/// The model the CLI should use: `--model`, else the app bundle, else the two places the build
/// scripts put it. Nothing is downloaded or guessed.
func resolveDepthModelURL(_ a: Args) -> URL {
    let fm = FileManager.default
    if let raw = a.value("--model") {
        let url = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
        guard fm.fileExists(atPath: url.path) else { die("no such model: \(url.path)") }
        if url.pathExtension == "mlpackage" {
            do { return try compileDepthPackage(url) } catch { die("\(error)") }
        }
        return url
    }
    let cwd = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
    // Do **not** resolve the executable's symlinks: `.build/debug` is a symlink into
    // `.build/out/Products/Debug`, and the model sits beside `.build`, not beside the product.
    let executable = URL(fileURLWithPath: CommandLine.arguments[0], relativeTo: cwd)
        .standardizedFileURL
    let debugDir = executable.deletingLastPathComponent()
    let buildDir = debugDir.deletingLastPathComponent()
    let name = "\(DepthModel.modelName).mlmodelc"
    let candidates = [
        Bundle.main.url(forResource: DepthModel.modelName, withExtension: "mlmodelc"),
        Optional(debugDir.appendingPathComponent(name)),
        Optional(buildDir.appendingPathComponent("depth-model/\(name)")),
        Optional(buildDir.appendingPathComponent("Photons.app/Contents/Resources/\(name)")),
        Optional(cwd.appendingPathComponent(".build/depth-model/\(name)")),
        Optional(cwd.appendingPathComponent(".build/Photons.app/Contents/Resources/\(name)")),
    ].compactMap { $0 }
    if let hit = candidates.first(where: { fm.fileExists(atPath: $0.path) }) { return hit }
    die("""
    depth model not found: \(name) (looked in the bundle, .build/debug and .build/depth-model).
      build the app:        make app
      or the model alone:   scripts/depth-model.sh
      or pass a path:       --model <…/\(DepthModel.modelName).mlmodelc|.mlpackage>
    """)
}

/// The decoded scene-linear buffer as the 8-bit sRGB picture the model was trained on. A 12-bit
/// lookup table applies the sRGB OETF once per code; `Histogram.srgbEncode` is the one definition.
func depthPixelBuffer(_ image: LinearImage) throws -> CVPixelBuffer {
    let buffer = try PixelBufferResize.makePixelBuffer(width: image.width, height: image.height,
                                                      pixelFormat: kCVPixelFormatType_32BGRA)
    var lut = [UInt8](repeating: 0, count: 4097)
    for i in 0...4096 {
        lut[i] = UInt8(clamping: Int((Histogram.srgbEncode(Float(i) / 4096) * 255).rounded()))
    }
    func code(_ linear: Float) -> UInt8 {
        guard linear.isFinite else { return 0 }
        return lut[Int((min(max(linear, 0), 1) * 4096).rounded())]
    }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let base = CVPixelBufferGetBaseAddress(buffer) else {
        throw DepthError.inferenceFailed("cannot lock the BGRA copy of the decode")
    }
    let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
    let width = image.width
    for y in 0..<image.height {
        let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
        let source = y * width * 4
        for x in 0..<width {
            let i = source + x * 4, o = x * 4
            row[o] = code(Float(image.rgba[i + 2]))
            row[o + 1] = code(Float(image.rgba[i + 1]))
            row[o + 2] = code(Float(image.rgba[i]))
            row[o + 3] = 255
        }
    }
    return buffer
}

/// A human-readable 8-bit grey TIFF: after `normalised()` larger (nearer) is brighter, so the
/// foreground comes out white and the sky black.
func writeDepthTIFF(_ map: DepthMap, to url: URL) throws {
    let stretched = map.normalised() ?? map
    var bytes = [UInt8](repeating: 0, count: map.width * map.height)
    for i in 0..<bytes.count {
        let value = Float(stretched.values[i])
        bytes[i] = UInt8(clamping: Int((min(max(value, 0), 1) * 255).rounded()))
    }
    guard let provider = CGDataProvider(data: Data(bytes) as CFData),
          let image = CGImage(width: map.width, height: map.height, bitsPerComponent: 8,
                              bitsPerPixel: 8, bytesPerRow: map.width,
                              space: CGColorSpaceCreateDeviceGray(),
                              bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider,
                              decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    else { die("cannot build the depth TIFF image") }

    let tmp = url.appendingPathExtension("tmp")
    try? FileManager.default.removeItem(at: tmp)
    guard let destination = CGImageDestinationCreateWithURL(tmp as CFURL, "public.tiff" as CFString,
                                                           1, nil) else {
        die("cannot create \(tmp.path)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { die("cannot write \(tmp.path)") }
    try? FileManager.default.removeItem(at: url)
    try FileManager.default.moveItem(at: tmp, to: url)
}

func cmdDepth(_ a: Args) throws {
    let url = requireRaw(a)
    guard let scale = Float(a.value("--scale") ?? "1"), scale > 0 else {
        die("bad --scale '\(a.value("--scale") ?? "")' (want > 0, e.g. 0.25)")
    }
    let modelURL = resolveDepthModelURL(a)
    defer {
        if let tmp = depthModelTemporaryDirectory { try? FileManager.default.removeItem(at: tmp) }
    }
    // 2026-10-30 — 1036×784 wants the GPU, not the ANE (192 ms vs 1244 ms). `--units` exists so the
    // three paths can be re-measured on any machine without a rebuild.
    let unitsName = a.value("--units") ?? "gpu"
    let units: MLComputeUnits
    switch unitsName {
    case "all", "auto": units = .all
    case "cpu": units = .cpuOnly
    case "gpu": units = .cpuAndGPU
    case "ane": units = .cpuAndNeuralEngine
    default: die("bad --units '\(unitsName)' (want all|cpu|gpu|ane)")
    }
    let model: DepthModel
    do {
        model = try DepthModel(modelURL: modelURL, computeUnits: units)
    } catch {
        die("\(error)")
    }
    note("model       \(modelURL.lastPathComponent)  input \(model.inputWidth)×\(model.inputHeight)  units \(unitsName)")

    let opts = decodeOptions(a)
    let decoder = makeDecoder()
    let decodeStart = CFAbsoluteTimeGetCurrent()
    let decoded = try decoder.decode(url, options: opts).oriented()
    note(String(format: "decode      %.2f s  %d×%d (scale %.3f)",
                CFAbsoluteTimeGetCurrent() - decodeStart, decoded.width, decoded.height,
                opts.scale))

    let convertStart = CFAbsoluteTimeGetCurrent()
    let buffer = try depthPixelBuffer(decoded)
    note(String(format: "encode      %.2f s  linear -> BGRA8", CFAbsoluteTimeGetCurrent() - convertStart))

    var cold = 0.0
    var hot: [Double] = []
    var map: DepthMap?
    for run in 0...5 {
        let start = CFAbsoluteTimeGetCurrent()
        let produced = try model.infer(pixelBuffer: buffer)
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        if run == 0 {
            cold = elapsed
            map = produced
        } else {
            hot.append(elapsed)
        }
    }
    guard let depth = map else { die("depth inference produced nothing") }
    note(String(format: "infer cold  %.1f ms", cold * 1000))
    note(String(format: "infer hot   p50 %.1f ms  (min %.1f, max %.1f, n=%d)",
                median(hot) * 1000, (hot.min() ?? 0) * 1000, (hot.max() ?? 0) * 1000, hot.count))
    note("depth       \(depth.width)×\(depth.height)")

    let finite = depth.values.map { Float($0) }.filter { $0.isFinite }.sorted()
    if let low = finite.first, let high = finite.last {
        note(String(format: "range       min %.4f  max %.4f  p50 %.4f",
                    low, high, percentile(finite.map { Double($0) }, 0.5)))
    }
    note(String(format: "peakRSS     %.1f MB", Double(peakResidentBytes()) / 1e6))

    if let out = a.value("--out") {
        let path = URL(fileURLWithPath: (out as NSString).expandingTildeInPath)
        try writeDepthTIFF(depth, to: path)
        note("wrote       \(path.path)  (near = bright)")
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
    /// 133 — only written when the render used a tone map, so a golden recorded on the historical
    /// hard-clamp path still decodes (and re-encodes) exactly as before.
    var toneMap: String?
    var toneMapHeadroom: Float?
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
    // The S4 ceiling by hand: the way to see the exponential tail and the display tick populated
    // without an EDR screen (the card itself always uses the screen's own headroom).
    if let h = a.value("--headroom").flatMap(Double.init) { d.headroom = min(max(h, 1), 16) }
    return d
}

/// 133 — `--tone-map none|global`. `nil` is the historical S4 hard clamp, so every existing
/// golden and recorded baseline stays byte-identical; `global` is `SDRToneMap` (the same
/// `CIToneMapHeadroom` roll-off the export uses) and is the right choice for measurement renders.
func toneMapOption(_ a: Args) -> SDRToneMap? {
    let raw = (a.value("--tone-map") ?? "none").lowercased()
    switch raw {
    case "none":
        if a.value("--tone-map-headroom") != nil {
            die("--tone-map-headroom needs --tone-map global")
        }
        return nil
    case "global":
        var map = SDRToneMap.global
        if let rawHeadroom = a.value("--tone-map-headroom") {
            guard let h = Float(rawHeadroom), h.isFinite, h >= 1 else {
                die("bad --tone-map-headroom '\(rawHeadroom)' (want ≥ 1, e.g. 6)")
            }
            map = SDRToneMap(measurementRatio: map.measurementRatio, maxHeadroom: h)
        }
        return map
    default:
        die("bad --tone-map '\(raw)' (want none | global)")
    }
}

func goldenToneMap(_ rec: RenderGolden, args: Args) -> SDRToneMap? {
    let recorded = rec.toneMap ?? "none"
    guard recorded == "none" || recorded == "global" else {
        die("golden recorded an unknown tone-map '\(recorded)'")
    }
    if let requested = args.value("--tone-map"), requested.lowercased() != recorded {
        die("golden was recorded with --tone-map \(recorded); "
            + "pass --tone-map \(recorded) or re-record")
    }
    guard recorded == "global" else { return nil }
    let map = SDRToneMap(maxHeadroom: rec.toneMapHeadroom ?? SDRToneMap.global.maxHeadroom)
    if let raw = args.value("--tone-map-headroom"), let h = Float(raw), h != map.maxHeadroom {
        die("golden was recorded with --tone-map-headroom \(map.maxHeadroom); "
            + "pass \(map.maxHeadroom) or re-record")
    }
    return map
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
                     version: String, whiteBalance: WhiteBalance = .asShot,
                     quiet: Bool = false) throws -> (LinearImage, String) {
    let key = DecodeCacheKey(fileSHA256: fileHash, decoderVersion: version, exposureEV: 0,
                             scale: decodeScale, draft: false, colorSpace: "extendedLinearSRGB",
                             whiteBalance: whiteBalance,
                             lens: LensProfile.read(from: url)?.recipeComponent)
    let decoder = makeDecoder()
    let opts = DecodeOptions(decoderVersion: a.value("--version"), scale: decodeScale,
                             whiteBalance: whiteBalance)

    if let dirPath = a.value("--cache-dir") {
        let store = try LinearImageStore(directory: URL(fileURLWithPath: (dirPath as NSString).expandingTildeInPath))
        if let hit = try store.load(key) {
            if !quiet { note(String(format: "decode     cache hit (scale %.3f, %d×%d)", decodeScale, hit.width, hit.height)) }
            return (hit, key.digest)
        }
        let t0 = CFAbsoluteTimeGetCurrent()
        let img = try decoder.decode(url, options: opts)
        try store.save(img, key: key)
        if !quiet {
            note(String(format: "decode     %.2f s (scale %.3f, %d×%d, stored)", CFAbsoluteTimeGetCurrent() - t0,
                        decodeScale, img.width, img.height))
        }
        return (img, key.digest)
    }

    let t0 = CFAbsoluteTimeGetCurrent()
    let img = try decoder.decode(url, options: opts)
    if !quiet {
        note(String(format: "decode     %.2f s (scale %.3f, %d×%d)", CFAbsoluteTimeGetCurrent() - t0,
                    decodeScale, img.width, img.height))
    }
    return (img, key.digest)
}

/// The white balance a render develops with: `--wb` when given, else the first document's
/// (`nil` = as shot), so `--edit edit-3500.json` really is a 3500 K development (派单 006).
func renderWhiteBalance(_ a: Args, edits: [EditModel]) -> WhiteBalance {
    if a.value("--wb") != nil { return whiteBalanceOption(a) }
    return edits.first?.light.whiteBalance ?? .asShot
}

func cmdRender(_ a: Args) throws {
    let url = requireRaw(a)
    guard let outPath = a.value("--out") else { die("render needs --out <file>") }
    let outURL = URL(fileURLWithPath: (outPath as NSString).expandingTildeInPath)
    let scale = a.value("--scale").flatMap(Double.init) ?? 1
    let display = displayOptions(a)
    let toneMap = toneMapOption(a)
    var (edits, names) = try loadEdits(a)
    let trace = a.has("--trace-stages")

    let probe = try makeDecoder().probe(url)
    let version = a.value("--version") ?? probe.defaultVersion
    let fileHash = try FileDigest.sha256(of: url)
    let decodeScale = a.value("--decode-scale").flatMap(Float.init) ?? decodeScaleLadder(scale)
    // 143: the decode is always the as-shot balance; a document's (Kelvin, tint) is an S1 gain. A
    // `--wb` override therefore has to reach the **documents**, not the decoder — patching only the
    // cache key would render the edit's own pair.
    let wb = renderWhiteBalance(a, edits: edits)
    if a.value("--wb") != nil {
        for i in edits.indices {
            edits[i].light.temperature = wb.temperature
            edits[i].light.tint = wb.tint
        }
    }
    if a.value("--wb") == nil, edits.count > 1,
       edits.contains(where: { $0.light.whiteBalance != wb }) {
        err("warning: one decode serves every --edit; their own white balances render independently")
    }
    let (decoded, identity) = try decodeForRender(a, url: url, decodeScale: decodeScale,
                                                  fileHash: fileHash, version: version,
                                                  whiteBalance: wb)
    note("source     \(url.lastPathComponent) v\(decoded.decoderVersion) → render v\(version)")
    note("wb         \(wb.summary)\(a.value("--wb") == nil ? " (from the document)" : " (--wb)")")

    // `--scale` is relative to the *full-resolution* crop; the render works on the decoded buffer,
    // which is already at `decodeScale`, so the pass scale is the remainder.
    let renderScale = scale / Double(decodeScale)

    let graph = try RenderGraph(input: RenderInput(image: decoded, identity: identity, sourceURL: url))
    guard let goldenMode = a.value("--golden") else {
        try renderAll(a, graph: graph, edits: edits, names: names, outURL: outURL,
                      scale: scale, renderScale: renderScale, display: display,
                      toneMap: toneMap, trace: trace,
                      raw: url, rawHash: fileHash, decoderVersion: version)
        return
    }
    guard ["record", "check"].contains(goldenMode) else { die("--golden needs record|check") }
    try renderAll(a, graph: graph, edits: edits, names: names, outURL: outURL,
                  scale: scale, renderScale: renderScale, display: display,
                  toneMap: toneMap, trace: trace,
                  raw: url, rawHash: fileHash, decoderVersion: version, goldenMode: goldenMode)
}

func renderAll(_ a: Args, graph: RenderGraph, edits: [EditModel], names: [String], outURL: URL,
               scale: Double, renderScale: Double, display: DisplayOptions,
               toneMap: SDRToneMap?, trace: Bool,
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

        let ex = exportOptions(a, url: outFile)
        let goldenURL = dir.appendingPathComponent(
            String(format: "render-%@-s%.2f.json", name, scale))

        // Check reproduces the tone map recorded with the golden; a mismatch with an explicit
        // flag is an error rather than a silent second baseline under the same filename.
        var effectiveToneMap = toneMap
        var checked: RenderGolden?
        if let mode = goldenMode, mode == "check" {
            guard FileManager.default.fileExists(atPath: goldenURL.path) else {
                die("no golden at \(goldenURL.path) — run with --golden record")
            }
            let rec = try JSONDecoder().decode(RenderGolden.self, from: Data(contentsOf: goldenURL))
            effectiveToneMap = goldenToneMap(rec, args: a)
            checked = rec
        }

        let opts = RenderOptions(canvas: nil, scale: renderScale, display: display,
                                 useCache: true, wantsPixels: true)
        let result: RenderResult
        let pixels: DisplayImage
        if let map = effectiveToneMap {
            // 133 — the same two-step the export uses: `s4_display_linear`, then the global roll-off
            // and one OETF. The linear pass has its own cache key, so the hard-clamp path is untouched.
            var linearDisplay = display
            linearDisplay.linearOutput = true
            let linearResult = try graph.render(edit, options: RenderOptions(
                canvas: nil, scale: renderScale, display: linearDisplay,
                useCache: true, wantsPixels: true))
            guard let frame = linearResult.display else { die("render returned no pixels") }
            result = linearResult
            pixels = LinearPixels(frame).displaySDR(bitDepth: display.bitDepth, toneMap: map)
        } else {
            result = try graph.render(edit, options: opts)
            guard let rendered = result.display else { die("render returned no pixels") }
            pixels = rendered
        }

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
        if mode == "record" {
            let rec = RenderGolden(raw: raw.lastPathComponent, rawSHA256: rawHash,
                                   decoderVersion: decoderVersion, edit: name, scale: scale,
                                   width: pixels.width, height: pixels.height,
                                   pixelSHA256: pixels.sha256(), fileSHA256: fileDigest,
                                   stageKeys: result.keys.shortTrace,
                                   osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                                   createdAt: ISO8601DateFormatter().string(from: Date()),
                                   note: "Recorded by photonsctl render. Apple's decoder output can change across OS releases; re-record on major OS bumps and keep the old file as history.",
                                   toneMap: effectiveToneMap == nil ? nil : "global",
                                   toneMapHeadroom: effectiveToneMap?.maxHeadroom)
            try JSONEncoder.pretty.encode(rec).write(to: goldenURL, options: .atomic)
            note("golden     recorded \(goldenURL.lastPathComponent)")
            continue
        }
        guard let rec = checked else { die("golden check lost its record") }
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
                                                  fileHash: fileHash, version: version,
                                                  whiteBalance: renderWhiteBalance(a, edits: edits))

    let graph = try RenderGraph(input: RenderInput(image: decoded, identity: identity, sourceURL: url))
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

// MARK: - xmp export (docs/xmp-mapping.md; D7: XMP is a derived artifact, never the truth)

func editForAsset(_ asset: Asset) -> EditModel {
    // `develop_json` is the document truth (D9). A row written before the schema existed holds
    // "{}", which decodes to `EditModel.neutral` by design.
    guard let data = asset.developJson.data(using: .utf8),
          let model = try? JSONDecoder().decode(EditModel.self, from: data) else {
        return .neutral
    }
    return model
}

func cmdXMP(_ a: Args) throws {
    guard let sub = a.positional.first, sub == "export" else {
        die("xmp needs a subcommand: export")
    }
    guard a.positional.count >= 2 else {
        die("xmp export <pkg> --out <dir> [--ids id…|--rating N] [--embed] [--json]")
    }
    guard let outPath = a.value("--out") else { die("xmp export needs --out <dir>") }
    let outDir = URL(fileURLWithPath: (outPath as NSString).expandingTildeInPath)
    let catalog = openLibrary(a, index: 1)

    var assets: [Asset] = []
    let ids = a.all("--ids")
    if !ids.isEmpty {
        for id in ids {
            guard let asset = try catalog.asset(id: id) else { die("no asset with id \(id)") }
            assets.append(asset)
        }
    } else {
        var filter = AssetFilter()
        filter.ratingAtLeast = a.value("--rating").flatMap(Int.init)
        filter.limit = a.value("--limit").flatMap(Int.init) ?? 500
        assets = try catalog.assets(filter)
    }
    guard !assets.isEmpty else { die("no assets matched") }

    var total = XMPExportReport()
    var sidecars = 0, embedded = 0, failed = 0
    var failures: [String] = []
    let wantsEmbed = a.has("--embed")

    for asset in assets {
        let edit = editForAsset(asset)
        let file = try? catalog.fileURL(for: asset)
        var context = XMPWriteContext()
        // The container's own EXIF orientation is what our flips must compose onto.
        context.exifOrientation = try? catalog.metadata(assetId: asset.id)?.orientation

        // Sidecar: mirror the catalog's relative path so two same-named files never collide.
        let rel = (asset.relPath as NSString).deletingPathExtension
        let sidecar = outDir.appendingPathComponent(rel).appendingPathExtension("xmp")
        do {
            let report = try XMPWriter.writeSidecar(for: edit, to: sidecar, context: context)
            total.merge(report)
            sidecars += 1
        } catch {
            failed += 1
            failures.append("\(asset.relPath): \(error.localizedDescription)")
        }

        // Containers are opt-in: the default export never touches an original.
        guard wantsEmbed, let file else { continue }
        guard XMPWriter.canEmbed(file) else {
            total.notes.append("\(asset.filename): \(asset.ext) cannot carry XMP — sidecar only")
            continue
        }
        do {
            var embedContext = context
            embedContext.exifOrientation = nil      // embed() reads it from the file
            let report = try XMPWriter.embed(edit, into: file, context: embedContext)
            // Same document, second output: the unmappable fields were already counted with the
            // sidecar, so only the paths and caveats of the container write are added here.
            total.written.append(contentsOf: report.written)
            total.notes.append(contentsOf: report.notes)
            embedded += 1
        } catch {
            failed += 1
            failures.append("\(asset.relPath): \(error.localizedDescription)")
        }
    }

    let skipped = total.unmapped.sorted { $0.key < $1.key }
    if a.has("--json") {
        note(jsonLine([
            "assets": assets.count,
            "files": sidecars + embedded,
            "sidecars": sidecars,
            "embedded": embedded,
            "failed": failed,
            "skippedFields": total.unmapped,
            "skippedTotal": total.unmappedCount,
            "failures": failures,
        ]))
    } else {
        let breakdown = skipped.isEmpty ? "none"
            : skipped.map { "\($0.key) ×\($0.value)" }.joined(separator: ", ")
        note("xmp        wrote \(sidecars + embedded) file\(sidecars + embedded == 1 ? "" : "s")"
             + " (\(sidecars) sidecar\(sidecars == 1 ? "" : "s"), \(embedded) embedded)"
             + "  skipped \(total.unmappedCount) unmappable field\(total.unmappedCount == 1 ? "" : "s")"
             + "  [\(breakdown)]"
             + (failed > 0 ? "  failed \(failed)" : ""))
        if !a.has("--quiet") {
            for note_ in Set(total.notes).sorted() { note("           · " + note_) }
        }
        for f in failures { err("failed     " + f) }
    }
    if failed > 0 { exit(2) }
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
      photonsctl histogram <raw> [--edit <json>] [--roi x,y,w,h] [--bins 256] [--json|--csv]
      photonsctl detail <raw> [--version V] [--scale F]   # 派单 031 降噪/细节解码参数实测
      photonsctl depth  <raw> [--scale F] [--out map.tiff] [--model path] [--units gpu|ane|cpu|all]
                                                                        # 120: 深度图（近 = 亮）

      photonsctl library create  <pkg.photonslibrary>
      photonsctl library import  <pkg> <src…> [--mode copy|reference] [--root id] [--rename T] [--json]
      photonsctl library rescan  <pkg> [--json]
      photonsctl library assets  <pkg> [--rating N] [--camera key] [--since YYYY-MM-DD] [--limit N] [--json]
      photonsctl library stats   <pkg> [--json]
      photonsctl library verify  <pkg> [--rehash] [--json]
      photonsctl library copy-settings  <pkg> --asset <id> [--out file.json]
      photonsctl library paste-settings <pkg> --asset <id> --from <file.json|->
      photonsctl preset list    <pkg> [--json]
      photonsctl preset save    <pkg> <name> --asset <id> [--groups light,curve] [--default]
      photonsctl preset apply   <pkg> <name> --asset <id> [--label L]
      photonsctl preset delete  <pkg> <name>
      photonsctl preset rename  <pkg> <old> <new>
      photonsctl preset default <pkg> <name> | --none
      photonsctl xmp export <pkg> --out <dir> [--ids id…|--rating N] [--embed] [--json]
      photonsctl export batch <pkg> --out <dir> --preset <file.json> [--ids id…|--rating N] [--json]
      photonsctl thumbs <pkg> --out <dir> [--tier grid|filmstrip|full] [--limit N] [--strategy auto|filter|thumbnail] [--reset] [--json]
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
      --tone-map       none | global         (default none; use global for measurement renders)
      --tone-map-headroom F  global tone map -R (≥1, default 6; needs --tone-map global)
      --cache-dir      keep decoded linear buffers on disk between runs

    decode options:
      --version   decoder version string, e.g. 8 / 8.dng / 9 / 9.dng (default: file's own default)
      --ev        exposure in stops applied by the system RAW pipeline
      --scale     decode scale factor (1 = full resolution)
      --draft     enable the system's draft (low quality) path
    """)
    exit(0)
}

func cmdProbeHDR(_ a: Args) throws {
    guard #available(macOS 15.0, *) else { die("probe-hdr needs macOS 15 (ISO gain map API)") }
    let result = HDRProbe.run(keepFiles: a.has("--keep"))
    for line in result.lines { note(line) }
    if let dir = result.outputDirectory { note("files        \(dir.path)") }
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
    case "histogram": try cmdHistogram(rest)
    case "detail":    try cmdDetail(rest)
    case "depth":     try cmdDepth(rest)
    case "library":  try cmdLibrary(rest)
    case "preset":   try cmdPreset(rest)
    case "xmp":      try cmdXMP(rest)
    case "export":   try cmdExport(rest)
    case "probe-hdr": try cmdProbeHDR(rest)
    case "thumbs":   try cmdThumbs(rest)
    case "fixtures": try cmdFixtures(rest)
    default:       die("unknown command '\(cmd)' (try: photonsctl)")
    }
} catch let e as DecodeError {
    die(e.errorDescription ?? "\(e)")
} catch let e as CatalogError {
    die(e.errorDescription ?? "\(e)")
} catch let e as AlbumError {
    // 相册的错误是给用户看的（重名、空名、已删），不是域错误 dump。
    die(e.errorDescription ?? "\(e)")
} catch {
    die("\(error)")
}
