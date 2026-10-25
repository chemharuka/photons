import Foundation
import PhotonsCore
import PhotonsCatalog

// MARK: - M3.5: thumbs (previewImage fast path + content-addressed cache)
//
// `photonsctl thumbs <pkg> --out <dir> [--tier grid|filmstrip|full] [--limit N] [--json]`
//
// Two rounds over the same asset set, with the numbers printed, not estimated
// (docs/tasks/006-thumbnails.md §5, §7):
//   cold — cache miss → embedded camera JPEG → 8-bit sRGB JPEG q0.82 → atomic store
//   hot  — cache hit  → file read + JPEG decode
// The tier is the *requested* size, and the returned size is the *embedded preview's* size when
// the preview is smaller: no upscaling is allowed, and the row says so (`clamped`).

enum ThumbsTierArg: String, CaseIterable {
    case grid, filmstrip, full

    var tier: ThumbTier {
        switch self {
        case .grid: return .t256
        case .filmstrip: return .t512
        case .full: return .t1024
        }
    }
}

struct ThumbSample: Codable {
    var file: String
    var contentHash: String
    var ext: String
    var source: String            // embedded | fallback | none | skipped
    var note: String?
    var sourceW: Int
    var sourceH: Int
    var outW: Int
    var outH: Int
    var coldMs: Double            // 0 when the cold round hit (already warm)
    var hotMs: Double
    var bytes: Int
    var coldHit: Bool
    var hotHit: Bool
}

struct ThumbsReport: Codable {
    var library: String
    var tier: String
    var tierPixels: Int
    var strategy: String
    var assets: Int
    var generated: Int
    var skipped: Int
    var coldHitRatio: Double
    var hotHitRatio: Double
    var coldP50: Double
    var coldP95: Double
    var hotP50: Double
    var hotP95: Double
    var sourceP50: Double
    var sourceP95: Double
    var totalBytes: Int64
    var samples: [ThumbSample]
    var missedReasons: [String: Int]
}

func cmdThumbs(_ a: Args) throws {
    guard a.positional.count >= 1 else {
        die("thumbs <pkg> --out <dir> [--tier grid|filmstrip|full] [--limit N] [--json]")
    }
    guard let outPath = a.value("--out") else { die("thumbs needs --out <dir>") }
    let outDir = URL(fileURLWithPath: (outPath as NSString).expandingTildeInPath)
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

    let tierArg = ThumbsTierArg(rawValue: a.value("--tier") ?? "grid") ?? .grid
    let tier = tierArg.tier
    // Measured on this machine (19 real RAWs, t256/t512/t1024): ImageIO's embedded-thumbnail read
    // is 49–63 ms p50 against 153–162 ms for constructing a `CIRAWFilter` and rendering its
    // full-size preview — 2.6× — so the bench defaults to it, which is the branch 006 §9 leaves
    // open ("若实测 ImageIO 并不更快，就退回 CIRAWFilter.previewImage"). `--strategy auto` still
    // runs the filter-first order that `RAWDecoder.previewImage(_:maxPixelSize:)` uses.
    let strategy = PreviewStrategy(rawValue: a.value("--strategy") ?? "thumbnail") ?? .thumbnail
    let catalog = openLibrary(a, index: 0)

    var filter = AssetFilter()
    filter.limit = a.value("--limit").flatMap(Int.init) ?? 200
    let assets = try catalog.assets(filter)
    guard !assets.isEmpty else { die("no assets matched") }

    let cache = try ThumbnailCache(layout: catalog.layout)
    if a.has("--reset") {
        for asset in assets {
            try? FileManager.default.removeItem(at: cache.url(for: .preview(contentHash: asset.contentHash,
                                                                           tier: tier)))
        }
    }

    let decoder = try? RAWDecoder()
    if decoder == nil { err("warning: no Metal device — preview cannot be produced") }

    var samples: [ThumbSample] = []
    var coldTimes: [Double] = [], hotTimes: [Double] = [], sourceTimes: [Double] = []
    var generated = 0, skipped = 0

    // ── round 1: cold. A miss produces the file; a hit means someone was here first. ──────────
    for asset in assets {
        let key = ThumbKey.preview(contentHash: asset.contentHash, tier: tier)
        var s = ThumbSample(file: asset.filename, contentHash: asset.contentHash, ext: asset.ext,
                            source: "none", note: nil, sourceW: 0, sourceH: 0, outW: 0, outH: 0,
                            coldMs: 0, hotMs: 0, bytes: 0, coldHit: false, hotHit: false)

        let fileURL = try? catalog.fileURL(for: asset)
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else {
            s.source = "skipped"; s.note = "file missing"; skipped += 1
            samples.append(s); continue
        }

        if let existing = cache.data(for: key) {
            s.coldHit = true
            s.bytes = existing.count
            s.source = "cache"
            if let img = ThumbnailCache.decode(existing) {
                s.outW = img.width; s.outH = img.height
                s.sourceW = img.width; s.sourceH = img.height
            }
            samples.append(s); continue
        }

        guard let decoder else {
            s.source = "skipped"; s.note = "no decoder"; skipped += 1
            samples.append(s); continue
        }

        let t0 = CFAbsoluteTimeGetCurrent()
        guard let preview = decoder.preview(fileURL, maxPixelSize: tier.longEdge, strategy: strategy) else {
            s.source = "skipped"; s.note = "no embedded preview"; skipped += 1
            samples.append(s); continue
        }
        let tSource = (CFAbsoluteTimeGetCurrent() - t0) * 1000

        // §1 / §6.1: a preview may not be upscaled, and a DNG's Adobe rendering may not be the
        // large first-screen image. Report the veto instead of writing a too-small file.
        guard ThumbPolicy.previewAllowed(tier: tier, sourceLongEdge: preview.sourceLongEdge,
                                         ext: asset.ext) else {
            s.source = "skipped"
            s.sourceW = Int(preview.sourcePixelSize.width)
            s.sourceH = Int(preview.sourcePixelSize.height)
            let limit = ThumbPolicy.previewTierLimit(ext: asset.ext)
            s.note = preview.sourceLongEdge < tier.longEdge
                ? "would upscale (\(preview.sourceLongEdge)→\(tier.longEdge)): needs graph"
                : "tier above \(asset.ext) preview ceiling \(limit.rawValue): needs graph"
            skipped += 1
            samples.append(s); continue
        }

        guard let jpeg = ThumbnailJPEG.encode(preview.image) else {
            s.source = "skipped"; s.note = "JPEG encode failed"; skipped += 1
            samples.append(s); continue
        }
        do { try cache.store(jpeg, for: key) } catch {
            s.source = "skipped"; s.note = "\(error)"; skipped += 1
            samples.append(s); continue
        }

        let coldMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        coldTimes.append(coldMs)
        sourceTimes.append(tSource)
        generated += 1
        s.source = preview.source.rawValue
        s.sourceW = Int(preview.sourcePixelSize.width)
        s.sourceH = Int(preview.sourcePixelSize.height)
        s.outW = preview.image.width
        s.outH = preview.image.height
        s.coldMs = coldMs
        s.bytes = jpeg.count
        // Written where a human can look at it; the cache is the real product.
        let outName = "\(asset.filename.replacingOccurrences(of: ".", with: "-"))-\(tier.rawValue).jpg"
        try? jpeg.write(to: outDir.appendingPathComponent(outName), options: .atomic)
        samples.append(s)
    }

    let coldStats = cache.stats()

    // ── round 2: hot. Same keys, now from disk. ────────────────────────────────────────────────
    cache.resetStats()
    for i in samples.indices {
        guard samples[i].source != "skipped" else { continue }
        let key = ThumbKey.preview(contentHash: samples[i].contentHash, tier: tier)
        let t0 = CFAbsoluteTimeGetCurrent()
        let img = cache.image(for: key)
        let dt = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        samples[i].hotMs = dt
        samples[i].hotHit = img != nil
        hotTimes.append(dt)
    }
    let hotStats = cache.stats()

    let report = ThumbsReport(
        library: catalog.layout.packageURL.path,
        tier: tier.rawValue, tierPixels: tier.longEdge, strategy: strategy.rawValue,
        assets: assets.count, generated: generated, skipped: skipped,
        coldHitRatio: coldStats.hitRatio, hotHitRatio: hotStats.hitRatio,
        coldP50: median(coldTimes), coldP95: percentile(coldTimes, 0.95),
        hotP50: median(hotTimes), hotP95: percentile(hotTimes, 0.95),
        sourceP50: median(sourceTimes), sourceP95: percentile(sourceTimes, 0.95),
        totalBytes: cache.totalBytes(),
        samples: samples,
        missedReasons: hotStats.missReasons)

    if a.has("--json") {
        // `jsonLine` takes Foundation objects; a Codable struct has to go through JSONEncoder.
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        print(String(data: try enc.encode(report), encoding: .utf8) ?? "{}")
    } else {
        let embedded = samples.filter { $0.source == "embedded" }.count
        let fallback = samples.filter { $0.source == "fallback" }.count
        note("library    \(report.library)")
        note("tier       \(tier.rawValue) (\(tier.longEdge) px long edge)  strategy \(strategy.rawValue)")
        note("cache      \(cache.root.path)")
        note("assets     \(assets.count)  generated \(generated)  skipped \(skipped)"
             + "  embedded \(embedded)  fallback \(fallback)")
        note(String(format: "cold       p50 %.1f ms  p95 %.1f ms  hit %.3f  (source p50 %.1f  p95 %.1f)",
                    report.coldP50, report.coldP95, report.coldHitRatio, report.sourceP50, report.sourceP95))
        note(String(format: "hot        p50 %.1f ms  p95 %.1f ms  hit %.3f",
                    report.hotP50, report.hotP95, report.hotHitRatio))
        note(String(format: "cache size %.2f MB", Double(report.totalBytes) / 1e6))
        if !report.missedReasons.isEmpty {
            let s = report.missedReasons.sorted { $0.key < $1.key }
                .map { "\($0.key) ×\($0.value)" }.joined(separator: ", ")
            note("misses     \(s)")
        }
        note("")
        note("  file                                   source     src px      out px     cold    hot")
        for s in samples {
            let src = "\(s.sourceW)×\(s.sourceH)"
            let out = "\(s.outW)×\(s.outH)"
            let cold = s.coldHit ? "   hit" : String(format: "%5.1f ms", s.coldMs)
            let hot = s.hotHit ? String(format: "%5.1f ms", s.hotMs) : "   miss"
            note("  \(pad(s.file, 38)) \(pad(s.source, 9)) \(pad(src, 11)) \(pad(out, 10)) \(cold)  \(hot)"
                 + (s.note.map { "  · \($0)" } ?? ""))
        }
    }

    // A corrupt entry is a hard failure (#1: only `absent` is an acceptable miss reason).
    if (hotStats.missReasons["corrupt"] ?? 0) > 0 { exit(1) }
}

private func pad(_ s: String, _ n: Int) -> String {
    s.count >= n ? String(s.prefix(n)) : s + String(repeating: " ", count: n - s.count)
}
