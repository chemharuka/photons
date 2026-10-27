import Foundation
import PhotonsCore
import PhotonsExport
import PhotonsCatalog
import ImageIO

// MARK: - photonsctl export batch
//
//   photonsctl export batch <pkg> --out <dir> --preset <preset.json>
//                          [--ids id… | --rating N] [--limit N] [--concurrency 2] [--json]
//
// One row per asset, rendered through the same graph as the screen (D12: export = scale 1,
// headroom 1) and encoded by `Exporter`. Everything export-shaped lives in `PhotonsExport`; this
// file is the plumbing between a catalog and that engine.
//
// `--preset` and `--concurrency` are not in `Args.valueFlags` (main.swift), so they are read off
// `CommandLine.arguments` the same way `develop.swift` reads `--asset`. That keeps this milestone's
// footprint on `main.swift` to the subcommand registration.

func exportFlag(_ name: String) -> String? {
    let argv = Array(CommandLine.arguments.dropFirst())
    var i = 0
    while i < argv.count {
        let token = argv[i]
        if token == name, i + 1 < argv.count { return argv[i + 1] }
        if token.hasPrefix(name + "=") { return String(token.dropFirst(name.count + 1)) }
        i += 1
    }
    return nil
}

func exportDate(_ iso: String?) -> Date? {
    guard let iso, !iso.isEmpty else { return nil }
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    if let d = f.date(from: iso) { return d }
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.date(from: iso)
}

func cmdExport(_ a: Args) throws {
    guard let sub = a.positional.first else { die("export needs a subcommand: batch") }
    switch sub {
    case "batch": try cmdExportBatch(a)
    default: die("unknown export verb '\(sub)' (batch)")
    }
}

func cmdExportBatch(_ a: Args) throws {
    guard a.positional.count >= 2 else {
        die("export batch <pkg> --out <dir> --preset <file.json> "
            + "[--ids id… | --rating N] [--limit N] [--json]")
    }
    guard let outPath = a.value("--out") else { die("export batch needs --out <dir>") }
    guard let presetPath = exportFlag("--preset") else {
        die("export batch needs --preset <file.json>  (a saved ExportPreset; see docs)")
    }
    let presetURL = URL(fileURLWithPath: (presetPath as NSString).expandingTildeInPath)
    guard FileManager.default.fileExists(atPath: presetURL.path) else {
        die("no such preset: \(presetURL.path)")
    }
    let preset = try ExportPreset.load(from: presetURL)
    let outDir = URL(fileURLWithPath: (outPath as NSString).expandingTildeInPath)
    let catalog = openLibrary(a, index: 1)

    // MARK: selection — the same filter the other CLI verbs use, so "rating ≥ 3" means one thing.
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
        filter.cameraKey = a.value("--camera")
        filter.limit = a.value("--limit").flatMap(Int.init) ?? 200
        assets = try catalog.assets(filter)
    }
    guard !assets.isEmpty else { die("no assets matched") }

    // MARK: items — the document is the catalog's, never a side file.
    var nativeSizes: [String: ImageSize] = [:]
    var items: [ExportItem] = []
    for asset in assets {
        let url = try catalog.fileURL(for: asset)
        if let w = asset.width, let h = asset.height, w > 0, h > 0 {
            nativeSizes[asset.id] = ImageSize(width: w, height: h)
        }
        items.append(ExportItem(id: asset.id,
                                name: (asset.filename as NSString).deletingPathExtension,
                                captureDate: exportDate(asset.captureTime),
                                rating: asset.rating,
                                edit: try catalog.develop(forAsset: asset.id),
                                sourceURL: url))
    }

    let decodedSoFar = catalog.developDecodeFailures
    if decodedSoFar > 0 {
        err("warning: \(decodedSoFar) develop blob(s) did not decode; those assets export as .neutral")
    }

    // MARK: the renderer — one decode + one render per asset, at the preset's scale.
    let renderer: (ExportItem, ExportPreset) throws -> DisplayImage = { item, preset in
        guard let url = item.sourceURL else {
            throw ExportError.encodeFailed("\(item.name): no source file")
        }
        let edit = item.edit ?? .neutral
        let decoder = try RAWDecoder()
        let native: ImageSize
        if let known = nativeSizes[item.id] {
            native = known
        } else {
            let probe = try decoder.probe(url)
            native = ImageSize(width: probe.nativeWidth, height: probe.nativeHeight)
        }
        // Long edge applies to the *cropped* picture, which is what the file will contain.
        let content = CropMath.outputSize(edit.geometry.renderCrop(source: native), in: native)
        let scale = preset.renderScale(content: content)
        let decodeScale = decodeScaleLadder(scale)
        let decoded = try decoder.decode(url, options: DecodeOptions(scale: decodeScale))

        let identity = "export|\(item.id)|v\(decoded.decoderVersion)"
            + String(format: "|s%.4f", decodeScale)
        // 2026-10-28 (P1b) — the same one-shot pool policy the window's export uses (`UIExportRenderer`):
        // nothing retained between frames, no stage cache for a frame that can never hit one, and
        // everything handed back when the image is done, so a 60 Mpx batch runs at one export's
        // working set instead of accumulating one per image.
        let graph = try RenderGraph(input: RenderInput(image: decoded, identity: identity,
                                                      sourceURL: url),
                                    textureRetention: .none)
        defer { graph.releaseAllTextures() }
        let display = DisplayOptions(primaries: preset.colorSpace,
                                     bitDepth: preset.effectiveBitDepth,
                                     headroom: 1)
        let options = RenderOptions(canvas: nil,
                                    scale: scale / Double(decodeScale),
                                    display: display,
                                    useCache: false,
                                    wantsPixels: true)
        let result = try graph.render(edit, options: options)
        guard let pixels = result.display else {
            throw BatchExportError.noPixels(item.name)
        }
        return pixels
    }

    // M5's ceiling is two: the flag exists to *lower* it (serial for debugging), never to raise it.
    // `BatchExporter` itself accepts up to 8 so a later UI can make a different call.
    let concurrency = min(max(exportFlag("--concurrency").flatMap(Int.init)
                             ?? BatchExporter.defaultConcurrency, 1), 2)
    let t0 = CFAbsoluteTimeGetCurrent()
    let report = BatchExporter.run(items: items, preset: preset, outputDirectory: outDir,
                                   concurrency: concurrency, render: renderer)
    let wall = CFAbsoluteTimeGetCurrent() - t0

    // MARK: report
    let written = report.written
    let failures = report.failures
    let perImage = written.isEmpty ? 0 : wall / Double(written.count)

    if a.has("--json") {
        note(jsonLine([
            "assets": items.count,
            "written": written.count,
            "failed": failures.count,
            "seconds": (wall * 1000).rounded() / 1000,
            "perImage": (perImage * 1000).rounded() / 1000,
            "p50": (report.p50 * 1000).rounded() / 1000,
            "p95": (report.p95 * 1000).rounded() / 1000,
            "concurrency": report.requestedConcurrency,
            "peakConcurrency": report.peakConcurrency,
            "bytes": report.bytes,
            "preset": [
                "format": preset.format.rawValue,
                "longEdge": preset.longEdge ?? 0,
                "quality": preset.quality,
                "bitDepth": preset.effectiveBitDepth,
                "colorSpace": preset.colorSpace.rawValue,
                "writeXMP": preset.writeXMP,
                "sharpen": preset.sharpen?.amount ?? 0,
                "nameTemplate": preset.nameTemplate,
            ] as [String: Any],
            "files": written.map { $0.fileURL?.path ?? "" },
            "failures": failures.map { "\($0.sourceName): \($0.error ?? "unknown")" },
        ]))
    } else {
        note("export     \(items.count) asset\(items.count == 1 ? "" : "s") → "
             + "\(written.count) file\(written.count == 1 ? "" : "s")"
             + (failures.isEmpty ? "" : ", \(failures.count) failed")
             + String(format: "  in %.2f s (%.2f s/image)", wall, perImage))
        note("preset     \(preset.summary)")
        note(String(format: "timing     p50 %.2f s  p95 %.2f s  peak %d of %d worker%@",
                    report.p50, report.p95, report.peakConcurrency, report.requestedConcurrency,
                    report.requestedConcurrency == 1 ? "" : "s"))
        note("output     \(outDir.path)  \(String(format: "%.1f MB", Double(report.bytes) / 1e6))")
        for outcome in written where !outcome.warnings.isEmpty {
            for warning in outcome.warnings {
                err("warning    \(outcome.sourceName): \(warning)")
            }
        }
        for failure in failures {
            err("failed     \(failure.sourceName): \(failure.error ?? "unknown")")
        }
    }
    if !failures.isEmpty { exit(2) }
}
