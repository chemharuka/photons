import Foundation
import PhotonsCore
import CoreGraphics
import CoreText
import ImageIO

// MARK: - one item

/// One picture in a batch: everything the exporter needs that is not the pixels themselves.
///
/// `edit` is optional and only consulted when the preset writes XMP — the renderer already received
/// the document. `sourceURL` is only used for reports and XMP orientations, never re-read here.
public struct ExportItem: Sendable {
    public var id: String
    /// Source basename **without** extension — `{name}` in the template.
    public var name: String
    public var captureDate: Date?
    public var rating: Int
    public var edit: EditModel?
    public var sourceURL: URL?
    /// The catalog's `make|model` key, for the `{camera}` subfolder token.
    public var cameraKey: String?
    /// Written by the `copyright` metadata level when the caller knows them.
    public var author: String?
    public var copyright: String?

    public init(id: String, name: String, captureDate: Date? = nil, rating: Int = 0,
                edit: EditModel? = nil, sourceURL: URL? = nil, cameraKey: String? = nil,
                author: String? = nil, copyright: String? = nil) {
        self.id = id
        self.name = name
        self.captureDate = captureDate
        self.rating = rating
        self.edit = edit
        self.sourceURL = sourceURL
        self.cameraKey = cameraKey
        self.author = author
        self.copyright = copyright
    }
}

// MARK: - outcome / report

public struct BatchExportOutcome: Sendable {
    /// Position in the request; the report is sorted by it, so it does not depend on which thread
    /// finished first.
    public var index: Int
    public var id: String
    public var sourceName: String
    public var fileURL: URL?
    public var fileBytes: Int
    public var pixelSize: ImageSize?
    public var seconds: Double
    /// Where the XMP packet went, when the preset asked for one.
    public var xmpURL: URL?
    /// Non-fatal notes (XMP fell back to a sidecar, the preset's long edge was larger than the
    /// picture, …). A warning never turns a written file into a failure.
    public var warnings: [String]
    /// 163 §1.6 — how many pixels the right/bottom edges lost to make a half-size gain map legal.
    /// `.none` for full-size maps and for even sources.
    public var croppedForHalfSize: HalfSizeCrop = .none
    /// Non-nil = this item failed. The batch keeps going.
    public var error: String?
    /// The conflict policy said "skip": no file was written and the name was left alone.
    public var skipped: Bool = false
    /// The batch was cancelled before this item started rendering.
    public var cancelled: Bool = false

    public var isSuccess: Bool { error == nil && fileURL != nil && !skipped && !cancelled }
}

public struct BatchExportReport: Sendable {
    /// One entry per request item, in request order.
    public var outcomes: [BatchExportOutcome]
    public var seconds: Double
    public var requestedConcurrency: Int
    /// What the engine actually reached. Never above `requestedConcurrency`; asserted by a test
    /// because "concurrency 2" is a memory ceiling, not a preference.
    public var peakConcurrency: Int

    public var written: [BatchExportOutcome] { outcomes.filter(\.isSuccess) }
    public var failures: [BatchExportOutcome] {
        outcomes.filter { !$0.isSuccess && !$0.skipped && !$0.cancelled }
    }
    public var skipped: [BatchExportOutcome] { outcomes.filter(\.skipped) }
    public var cancelled: [BatchExportOutcome] { outcomes.filter(\.cancelled) }
    public var skippedCount: Int { skipped.count }
    public var cancelledCount: Int { cancelled.count }
    public var bytes: Int { written.reduce(0) { $0 + $1.fileBytes } }

    /// Per-image wall time of the successful exports.
    public var p50: Double { BatchMath.percentile(written.map(\.seconds), 0.50) }
    public var p95: Double { BatchMath.percentile(written.map(\.seconds), 0.95) }
}

public enum BatchExportError: LocalizedError {
    case emptyBatch
    case primariesMismatch(expected: OutputPrimaries, got: OutputPrimaries)
    case noPixels(String)

    public var errorDescription: String? {
        switch self {
        case .emptyBatch: return "the batch has no items"
        case .primariesMismatch(let expected, let got):
            return "renderer returned \(got.displayName) pixels but the preset asks for "
                + "\(expected.displayName) — retagging would silently shift every colour"
        case .noPixels(let name): return "\(name): the renderer produced no pixels"
        }
    }
}

enum BatchMath {
    /// Nearest-rank percentile. Small n is the normal case here (a batch of 20), so no interpolation.
    static func percentile(_ xs: [Double], _ p: Double) -> Double {
        let s = xs.sorted()
        guard !s.isEmpty else { return 0 }
        let idx = min(s.count - 1, max(0, Int((Double(s.count - 1) * p).rounded())))
        return s[idx]
    }
}

// MARK: - cancellation

/// A one-way flag the sheet's 取消 button sets. Checked before each queued item starts, again after
/// its render returns, and once more immediately before the write (161 §8): an in-flight render may
/// finish, but its pixels are discarded instead of becoming a file. Files already written stay on
/// disk. No partial file is ever left behind.
public final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }
}

// MARK: - engine

/// Batch export: one item at a time per worker, at most `concurrency` in flight, one result per
/// item, and a failure that never takes the batch with it.
///
/// The engine owns everything that is *the same* for every image — the preset, the output directory,
/// the name allocation, the XMP write, the encoding — and nothing that is per-image, which arrives
/// as a closure. That split is what makes it testable without a GPU, a catalog or a RAW file:
/// `render` can return any `DisplayImage`.
public enum BatchExporter {

    public static let defaultConcurrency = 2
    /// A hard ceiling: two is the design point (memory), and no caller gets to exceed 8 by accident.
    public static let maxConcurrency = 8

    /// Runs to completion. Synchronous on purpose — the CLI is the only caller today and it wants a
    /// report, not a stream of callbacks.
    ///
    /// - Parameter render: `(item, preset)` → pixels, rendered at `preset.longEdge` when it is set.
    ///   The engine resamples if the closure ignored the hint (a safety net, not the normal path:
    ///   rendering at the right scale is cheaper and sharper than rendering big and shrinking).
    public static func run(items: [ExportItem],
                           preset: ExportPreset,
                           outputDirectory: URL,
                           concurrency: Int = defaultConcurrency,
                           cancel: CancellationToken? = nil,
                           render: @escaping (ExportItem, ExportPreset) throws -> DisplayImage)
        -> BatchExportReport {

        let started = CFAbsoluteTimeGetCurrent()
        let limit = max(1, min(concurrency, maxConcurrency))
        guard !items.isEmpty else {
            return BatchExportReport(outcomes: [], seconds: 0, requestedConcurrency: limit,
                                     peakConcurrency: 0)
        }
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let collector = Collector(count: items.count)
        let allocator = OutputNameAllocator()
        let queue = OperationQueue()
        queue.name = "photons.batch-export"
        queue.maxConcurrentOperationCount = limit
        queue.qualityOfService = .userInitiated

        for (index, item) in items.enumerated() {
            queue.addOperation {
                if cancel?.isCancelled == true {
                    collector.leave(cancelledOutcome(index: index, item: item))
                    return
                }
                collector.enter()
                let outcome = exportOne(item: item, index: index, preset: preset,
                                        directory: outputDirectory, allocator: allocator,
                                        cancel: cancel, render: render)
                collector.leave(outcome)
            }
        }
        queue.waitUntilAllOperationsAreFinished()

        return BatchExportReport(outcomes: collector.outcomes,
                                 seconds: CFAbsoluteTimeGetCurrent() - started,
                                 requestedConcurrency: limit,
                                 peakConcurrency: collector.peak)
    }

    private static func cancelledOutcome(index: Int, item: ExportItem) -> BatchExportOutcome {
        BatchExportOutcome(index: index, id: item.id, sourceName: item.name, fileURL: nil,
                           fileBytes: 0, pixelSize: nil, seconds: 0, xmpURL: nil,
                           warnings: [], error: nil, skipped: false, cancelled: true)
    }

    // MARK: one image

    private static func exportOne(item: ExportItem,
                                  index: Int,
                                  preset: ExportPreset,
                                  directory: URL,
                                  allocator: OutputNameAllocator,
                                  cancel: CancellationToken? = nil,
                                  render: (ExportItem, ExportPreset) throws -> DisplayImage)
        -> BatchExportOutcome {

        let t0 = CFAbsoluteTimeGetCurrent()
        var warnings: [String] = []
        var outcome = BatchExportOutcome(index: index, id: item.id, sourceName: item.name,
                                         fileURL: nil, fileBytes: 0, pixelSize: nil, seconds: 0,
                                         xmpURL: nil, warnings: warnings, error: nil)
        do {
            // 1. the destination folder, created on demand. A subfolder template cannot escape the
            //    batch's destination: `ExportNaming.subfolder` sanitises every component.
            let folder = ExportNaming.subfolder(template: preset.subfolder, item: item)
            let directory = folder.isEmpty
                ? directory
                : directory.appendingPathComponent(folder, isDirectory: true)
            if !folder.isEmpty {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }

            let rendered = try render(item, preset)
            // 161 §8 — the cancellation the sheet's 取消 button sets can land while this item is
            // already rendering (with concurrency 2 a small batch may have every item in flight).
            // The first check above only stopped *queued* items; without this one the render that
            // was in flight still fell through to the encoder and the user saw files appear after
            // pressing 取消. The pixels are dropped here, before any resample/encode/write.
            if cancel?.isCancelled == true {
                return cancelledOutcome(index: index, item: item)
            }
            if rendered.width <= 0 || rendered.height <= 0 {
                throw BatchExportError.noPixels(item.name)
            }
            guard rendered.primaries == preset.colorSpace else {
                throw BatchExportError.primariesMismatch(expected: preset.colorSpace,
                                                         got: rendered.primaries)
            }

            // 2. size — the preset's rule, applied to the pixels we were handed.
            var image = rendered
            switch preset.sizingMode {
            case .none:
                // 原尺寸: no resize at all. A 099 preset can still carry a `longEdge` beside this mode;
                // honouring it would resize an export the user asked to be full size (111 review).
                break
            case .longEdge:
                if let longEdge = preset.longEdge {
                    let current = max(rendered.width, rendered.height)
                    let target = preset.noUpscale ? min(longEdge, current) : longEdge
                    image = DisplayResample.fitLongEdge(image, to: target,
                                                        allowUpscale: !preset.noUpscale)
                    // 168 §2 — say out loud that 不扩大 clamped the request, so a 4000 request on a
                    // 3000 px picture is not quietly reported as "4000" by the result row.
                    if preset.noUpscale, longEdge > current {
                        warnings.append("长边 \(longEdge) 请求 → 源 \(current)，按不扩大输出 \(current)")
                    }
                    if current > target {
                        warnings.append("renderer returned \(rendered.width)×\(rendered.height); "
                                        + "resampled to \(image.width)×\(image.height)")
                    }
                }
            case .percent:
                if let percent = preset.percent {
                    let current = max(rendered.width, rendered.height)
                    let effective = preset.noUpscale ? min(percent, 100) : percent
                    let longEdge = max(1, Int((Double(current)
                                               * Double(effective) / 100).rounded()))
                    image = DisplayResample.fitLongEdge(image, to: longEdge,
                                                        allowUpscale: !preset.noUpscale)
                    if current > longEdge {
                        warnings.append("renderer returned \(rendered.width)×\(rendered.height); "
                                        + "resampled to \(image.width)×\(image.height)")
                    }
                }
            }
            // 3. output sharpening, at the final pixel size (that is the point of it).
            if let sharpen = preset.sharpen, sharpen.isEnabled {
                image = DisplaySharpen.apply(image, sharpen)
            }

            // 3b. 163 §1.6 — a half-size gain map needs an even base. Trim right/bottom after the
            //     final size/sharpening, so the file, the map and the report all describe one picture.
            if preset.hdrKind == .gainMap, preset.hdr?.halfSize == true {
                let plan = GainMapSizing.plan(image.size, halfSize: true)
                if plan.crop.isNeeded {
                    image = GainMapSizing.crop(image, plan.crop)
                    outcome.croppedForHalfSize = plan.crop
                    warnings.append(plan.crop.exportNote(source: plan.input))
                }
            }

            // 180 — 水印画在最终像素上（编码前）。HDR 增益图导出只画在 SDR 基础图上：
            // `Watermark.apply` 只改 `rgba`，`linear` 原样透传，所以增益图（linear/base 的比值）
            // 在水印像素上是 0 增益 ⇒ 水印待在 SDR 电平里，不会跑到 HDR 头部空间。
            if let plan = Watermark.plan(for: image.size, text: preset.watermarkText,
                                         position: preset.watermarkPosition,
                                         opacity: preset.watermarkOpacity) {
                image = Watermark.apply(image, plan)
            }

            // 4. a name nobody else in this batch (or, under `rename`, on disk) already owns.
            let base = ExportNaming.baseName(template: preset.nameTemplate, item: item,
                                             sequence: index + 1)
            guard let url = allocator.reserve(base: base, ext: preset.format.fileExtension,
                                              in: directory, policy: preset.conflict) else {
                outcome.skipped = true
                outcome.seconds = CFAbsoluteTimeGetCurrent() - t0
                outcome.warnings = warnings
                return outcome
            }

            // 161 §8 — a second read immediately before the write: a cancel that landed between the
            // render check above and here (sharpening / name allocation on a large image) must not
            // add one more file after the user's click. Already-written files stay on disk.
            if cancel?.isCancelled == true {
                return cancelledOutcome(index: index, item: item)
            }

            // 5. encode. Metadata travels with the first encode so the output's EXIF pixel size is
            //    the size we are actually writing (and 16-bit PNG keeps its depth: nothing re-encodes
            //    it afterwards).
            let pngAt16 = preset.format == .png && preset.effectiveBitDepth == 16
            let embedsXMP = preset.metadataLevel == .all && preset.writeXMP
                && item.edit != nil && preset.format.supportsXMPEmbedding && !pngAt16
            let metadata = ExportMetadataContext(level: preset.metadataLevel,
                                                 source: SourceMetadata.read(from: item.sourceURL),
                                                 edit: item.edit,
                                                 author: item.author,
                                                 copyright: item.copyright,
                                                 embedXMP: embedsXMP)
            try Exporter.write(image, to: url, options: preset.exportOptions, metadata: metadata)
            let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0

            // 6. metadata, when the preset asked for it. A failed packet does not discard a written
            //    image. `.none` wins over the stored `writeXMP` flag on purpose. When the encoder
            //    already embedded the packet, the copy *is* the metadata carrier (no second write).
            switch preset.metadataLevel {
            case .none:
                break
            case .copyright:
                do {
                    outcome.xmpURL = try writeCopyright(item: item, to: url, warnings: &warnings)
                } catch {
                    warnings.append("XMP not written: \(error.localizedDescription)")
                }
            case .all:
                if preset.writeXMP {
                    if embedsXMP {
                        outcome.xmpURL = url
                    } else {
                        do {
                            outcome.xmpURL = try writeXMP(item: item, to: url, preset: preset,
                                                          warnings: &warnings)
                        } catch {
                            warnings.append("XMP not written: \(error.localizedDescription)")
                        }
                    }
                }
            }

            outcome.fileURL = url
            outcome.fileBytes = bytes
            outcome.pixelSize = image.size
        } catch {
            // A cancel that interrupted the render itself is not a failure of the picture.
            if cancel?.isCancelled == true {
                return cancelledOutcome(index: index, item: item)
            }
            outcome.error = error.localizedDescription
        }
        outcome.seconds = CFAbsoluteTimeGetCurrent() - t0
        outcome.warnings = warnings
        return outcome
    }

    /// The `copyright` level's packet: `dc:creator` + `dc:rights`, nothing from the develop graph.
    /// Written beside the image (not embedded) on purpose — embedding through ImageIO re-encodes
    /// PNG and would drop the preset's bit depth for a two-field packet.
    private static func writeCopyright(item: ExportItem, to url: URL,
                                       warnings: inout [String]) throws -> URL? {
        let author = item.author?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rights = item.copyright?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard author?.isEmpty == false || rights?.isEmpty == false else {
            warnings.append("metadata level is copyright, but the item has no author/copyright")
            return nil
        }
        let sidecar = url.deletingPathExtension().appendingPathExtension("xmp")
        try XMPWriter.writeAtomically(copyrightPacket(author: author, rights: rights), to: sidecar)
        return sidecar
    }

    private static func copyrightPacket(author: String?, rights: String?) -> Data {
        func escape(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
        }
        var body = ""
        if let author, !author.isEmpty {
            body += "<dc:creator><rdf:Seq><rdf:li>\(escape(author))</rdf:li></rdf:Seq></dc:creator>\n"
        }
        if let rights, !rights.isEmpty {
            body += "<dc:rights><rdf:Alt><rdf:li xml:lang=\"x-default\">\(escape(rights))"
                + "</rdf:li></rdf:Alt></dc:rights>\n"
        }
        let xml = """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/">
        \(body)  </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>

        """
        return Data(xml.utf8)
    }

    /// Embed into the exported copy where ImageIO can carry a packet (JPEG/HEIC/TIFF/PNG), sidecar
    /// otherwise (AVIF). Never touches an original: the file being written is the export.
    ///
    /// PNG is the exception inside the exception: `XMPWriter.embed` has no copy-image-source path
    /// for it and re-encodes through `CGImage`, which drops the 16-bit depth this preset asked for.
    /// A sidecar keeps the pixels; losing them to gain metadata would be a bad trade.
    private static func writeXMP(item: ExportItem, to url: URL, preset: ExportPreset,
                                 warnings: inout [String]) throws -> URL? {
        guard let edit = item.edit else {
            warnings.append("XMP asked for but the item carries no document")
            return nil
        }
        let pngAt16 = preset.format == .png && preset.effectiveBitDepth == 16
        if preset.format.supportsXMPEmbedding && !pngAt16 && XMPWriter.canEmbed(url) {
            try XMPWriter.embed(edit, into: url)
            return url
        }
        let sidecar = url.deletingPathExtension().appendingPathExtension("xmp")
        try XMPWriter.writeSidecar(for: edit, to: sidecar)
        let why = pngAt16 ? "16-bit PNG is re-encoded by ImageIO's embed path"
                          : "\(preset.format.rawValue) cannot carry XMP"
        warnings.append("\(why) — wrote \(sidecar.lastPathComponent)")
        return sidecar
    }

    // MARK: collector

    /// Mutated from the operation queue; every touch is under the lock, and the outcome array is
    /// indexed by request position so the report order never depends on scheduling.
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var slots: [BatchExportOutcome?]
        private var inFlight = 0
        private(set) var peak = 0

        init(count: Int) { slots = Array(repeating: nil, count: count) }

        func enter() {
            lock.lock(); defer { lock.unlock() }
            inFlight += 1
            peak = max(peak, inFlight)
        }

        func leave(_ outcome: BatchExportOutcome) {
            lock.lock(); defer { lock.unlock() }
            slots[outcome.index] = outcome
            inFlight -= 1
        }

        var outcomes: [BatchExportOutcome] {
            lock.lock(); defer { lock.unlock() }
            return slots.enumerated().map { index, slot in
                slot ?? BatchExportOutcome(index: index, id: "", sourceName: "", fileURL: nil,
                                           fileBytes: 0, pixelSize: nil, seconds: 0, xmpURL: nil,
                                           warnings: [], error: "the worker never reported")
            }
        }
    }
}

// MARK: - names

/// Hands out filenames according to the preset's conflict policy. The set is in-memory (one process
/// = one batch) *and* the filesystem is consulted. Lower-cased keys because APFS is case-insensitive
/// by default: `IMG_1.jpg` and `img_1.jpg` are one file there.
final class OutputNameAllocator {
    private let lock = NSLock()
    private let fm = FileManager.default
    private var used: Set<String> = []

    init() {}

    /// `nil` means "skip": the caller must not write anything for this item.
    func reserve(base: String, ext: String, in directory: URL,
                 policy: ExportConflict) -> URL? {
        lock.lock(); defer { lock.unlock() }
        let suffix = ext.isEmpty ? "" : "." + ext
        let first = directory.appendingPathComponent(base + suffix)
        let firstKey = first.standardizedFileURL.path.lowercased()

        switch policy {
        case .overwrite:
            used.insert(firstKey)
            return first
        case .skip:
            guard !used.contains(firstKey), !fm.fileExists(atPath: first.path) else { return nil }
            used.insert(firstKey)
            return first
        case .rename:
            var n = 0
            while n < 10_000 {
                let name = base + (n == 0 ? "" : "-\(n)") + suffix
                let url = directory.appendingPathComponent(name)
                let key = url.standardizedFileURL.path.lowercased()
                if !used.contains(key) && !fm.fileExists(atPath: url.path) {
                    used.insert(key)
                    return url
                }
                n += 1
            }
            let fallback = directory.appendingPathComponent(base + "-" + UUID().uuidString.prefix(8)
                                                            + suffix)
            used.insert(fallback.standardizedFileURL.path.lowercased())
            return fallback
        }
    }
}

// MARK: - resample

/// Area-average downscale: every destination pixel is the mean of the source pixels it covers.
/// Called only when a caller ignored `preset.longEdge`; the CLI renders at the target scale, so the
/// normal path never pays for this.
public enum DisplayResample {

    public static func fitLongEdge(_ image: DisplayImage, to longEdge: Int,
                                   allowUpscale: Bool = false) -> DisplayImage {
        let current = max(image.width, image.height)
        guard longEdge > 0, allowUpscale || current > longEdge else { return image }
        let s = Double(longEdge) / Double(current)
        let tw = max(1, Int((Double(image.width) * s).rounded()))
        let th = max(1, Int((Double(image.height) * s).rounded()))
        guard tw != image.width || th != image.height else { return image }

        let w = image.width, h = image.height
        let src = image.rgba
        var out = [Float16](repeating: 0, count: tw * th * 4)
        for y in 0..<th {
            let y0 = Int(Double(y) * Double(h) / Double(th))
            let y1 = min(h, max(y0 + 1, Int((Double(y + 1) * Double(h) / Double(th)).rounded(.up))))
            for x in 0..<tw {
                let x0 = Int(Double(x) * Double(w) / Double(tw))
                let x1 = min(w, max(x0 + 1, Int((Double(x + 1) * Double(w) / Double(tw)).rounded(.up))))
                var r = 0.0, g = 0.0, b = 0.0, a = 0.0
                for sy in y0..<y1 {
                    var i = (sy * w + x0) * 4
                    for _ in x0..<x1 {
                        r += Double(src[i]); g += Double(src[i + 1])
                        b += Double(src[i + 2]); a += Double(src[i + 3])
                        i += 4
                    }
                }
                let n = Double((y1 - y0) * (x1 - x0))
                let o = (y * tw + x) * 4
                out[o] = clip(r / n); out[o + 1] = clip(g / n)
                out[o + 2] = clip(b / n); out[o + 3] = clip(a / n)
            }
        }
        return DisplayImage(width: tw, height: th, rgba: out,
                            primaries: image.primaries, bitDepth: image.bitDepth)
    }

    private static func clip(_ v: Double) -> Float16 {
        Float16(min(max(v, 0), 4))
    }
}

// MARK: - output sharpening

/// Unsharp mask on display-encoded pixels: `out = c + amount · (c − blur(c))`, clamped to 0…1.
///
/// It runs on what the file will contain — after the resample, after the OETF — because that is the
/// thing JPEG quantisation will soften. The document's own sharpening (detail group) is a different
/// stage inside the graph and is untouched by this.
public enum DisplaySharpen {

    public static func apply(_ image: DisplayImage, _ sharpening: OutputSharpening) -> DisplayImage {
        guard sharpening.isEnabled else { return image }
        let w = image.width, h = image.height
        guard w > 1, h > 1 else { return image }

        let sigma = max(0.3, sharpening.radius)
        let r = max(1, Int((3 * sigma).rounded(.up)))
        var kernel = [Float](repeating: 0, count: 2 * r + 1)
        var sum: Float = 0
        for i in -r...r {
            let v = Float(exp(-Double(i * i) / (2 * sigma * sigma)))
            kernel[i + r] = v
            sum += v
        }
        for i in kernel.indices { kernel[i] /= sum }

        let n = w * h * 4
        var src = [Float](repeating: 0, count: n)
        for i in 0..<n { src[i] = Float(image.rgba[i]) }
        var tmp = [Float](repeating: 0, count: n)

        // Horizontal pass (3 channels: alpha is a mask, not a colour, and blurred alpha on a
        // noneSkipLast bitmap would be meaningless).
        for y in 0..<h {
            let row = y * w
            for x in 0..<w {
                let o = (row + x) * 4
                for c in 0..<3 {
                    var acc: Float = 0
                    for k in -r...r {
                        let xx = min(max(x + k, 0), w - 1)
                        acc += src[(row + xx) * 4 + c] * kernel[k + r]
                    }
                    tmp[o + c] = acc
                }
            }
        }

        var out = image.rgba
        let amount = Float(sharpening.amount)
        for y in 0..<h {
            let row = y * w
            for x in 0..<w {
                let o = (row + x) * 4
                for c in 0..<3 {
                    var acc: Float = 0
                    for k in -r...r {
                        let yy = min(max(y + k, 0), h - 1)
                        acc += tmp[(yy * w + x) * 4 + c] * kernel[k + r]
                    }
                    let original = src[o + c]
                    let v = original + amount * (original - acc)
                    out[o + c] = Float16(min(max(v, 0), 1))
                }
            }
        }
        return DisplayImage(width: w, height: h, rgba: out,
                            primaries: image.primaries, bitDepth: image.bitDepth)
    }
}

// MARK: - watermark (180)

public struct WatermarkPlan: Sendable, Equatable {
    public var text: String
    public var fontSize: Double
    public var padding: Int
    /// 文字最终落到的像素矩形：原点左上、像素单位、半开区间（与 `rgba` 的行序一致）。
    public var textRect: CGRect
    /// 允许改动的最大矩形 = 画布四边各内缩 `padding`。任何被改的像素必须在它里面。
    public var allowedRect: CGRect
    public var opacity: Double            // 0…100
    public var position: WatermarkPosition
}

public enum Watermark {
    /// 规格 §2 写死的两条比例。
    static let fontSizeFraction = 0.03
    static let paddingFraction = 0.02

    /// `nil` = 不画（空文本 / opacity ≤ 0 / 文字放不进内边距矩形）。
    public static func plan(for size: ImageSize, text: String,
                            position: WatermarkPosition = .bottomRight,
                            opacity: Double = 60) -> WatermarkPlan? {
        // 空白字符按空处理：敲一个空格不该让文件出现一个「看不见的水印」。
        guard opacity > 0,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              size.width > 0, size.height > 0 else { return nil }

        let longEdge = Double(max(size.width, size.height))
        let fontSize = max(1, (longEdge * fontSizeFraction).rounded())
        let padding = max(0, Int((longEdge * paddingFraction).rounded()))
        let allowed = CGRect(x: CGFloat(padding), y: CGFloat(padding),
                             width: CGFloat(size.width - 2 * padding),
                             height: CGFloat(size.height - 2 * padding))
        guard allowed.width > 0, allowed.height > 0 else { return nil }

        let line = self.line(text, fontSize: fontSize)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        let textW = Int(ceil(width))
        let textH = max(1, Int(ceil(ascent + descent)))
        guard textW > 0 else { return nil }

        let w = size.width, h = size.height
        let x: Int
        let y: Int
        switch position {
        case .topLeft:
            x = padding
            y = padding
        case .topRight:
            x = w - padding - textW
            y = padding
        case .bottomLeft:
            x = padding
            y = h - padding - textH
        case .bottomRight:
            x = w - padding - textW
            y = h - padding - textH
        }
        guard x >= padding, y >= padding,
              x + textW <= w - padding, y + textH <= h - padding else { return nil }

        return WatermarkPlan(text: text, fontSize: fontSize, padding: padding,
                             textRect: CGRect(x: CGFloat(x), y: CGFloat(y),
                                              width: CGFloat(textW), height: CGFloat(textH)),
                             allowedRect: allowed, opacity: opacity, position: position)
    }

    /// 只改 RGB（白色字按 coverage × opacity 混合），alpha / `linear` / `primaries` / `bitDepth` 原样。
    public static func apply(_ image: DisplayImage, _ plan: WatermarkPlan) -> DisplayImage {
        let w = image.width, h = image.height
        let textW = Int(plan.textRect.width)
        let textH = Int(plan.textRect.height)
        guard w > 0, h > 0, textW > 0, textH > 0 else { return image }

        // 8 位灰度掩膜。buffer 的第 0 行就是图像的顶行：CGBitmapContext 的内存行序自上而下，
        // 与 `rgba` 一致，所以混合时 `canvasY = textRect.y + row` 直接对应，不需要翻。
        var mask = [UInt8](repeating: 0, count: textW * textH)
        let ascentLine = line(plan.text, fontSize: plan.fontSize)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        _ = CTLineGetTypographicBounds(ascentLine, &ascent, &descent, &leading)

        let drew = mask.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: textW, height: textH,
                                          bitsPerComponent: 8, bytesPerRow: textW,
                                          space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
                return false
            }
            // 先清 0，再用白字画；`kCTForegroundColorFromContextAttributeName` 让 CTLineDraw
            // 使用上下文的填充色，而不是每个字形自己的颜色。
            context.setFillColor(gray: 0, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: textW, height: textH))
            context.setFillColor(gray: 1, alpha: 1)
            context.setAllowsAntialiasing(true)
            context.setShouldAntialias(true)
            context.textPosition = CGPoint(x: 0, y: descent)
            CTLineDraw(ascentLine, context)
            return true
        }
        guard drew else { return image }

        var out = image.rgba
        let x0 = Int(plan.textRect.minX)
        let y0 = Int(plan.textRect.minY)
        let opacity = plan.opacity / 100
        for row in 0..<textH {
            let canvasY = y0 + row
            guard canvasY >= 0, canvasY < h else { continue }
            let maskRow = row * textW
            for col in 0..<textW {
                let canvasX = x0 + col
                guard canvasX >= 0, canvasX < w else { continue }
                let coverage = Double(mask[maskRow + col]) / 255
                let a = coverage * opacity
                if a <= 0 { continue }        // 未覆盖的像素必须逐位不变
                let o = (canvasY * w + canvasX) * 4
                for c in 0..<3 {
                    let v = Double(Float(image.rgba[o + c]))
                    let mixed = v * (1 - a) + a    // 白字
                    out[o + c] = Float16(min(max(mixed, 0), 1))
                }
            }
        }
        return DisplayImage(width: w, height: h, rgba: out, primaries: image.primaries,
                            bitDepth: image.bitDepth, linear: image.linear)
    }

    /// 测试要看字形（豆腐块检测、ink bbox），所以这两条留 internal 而不是 private。
    static func font(size: Double) -> CTFont {
        CTFontCreateUIFontForLanguage(.system, CGFloat(size), nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, CGFloat(size), nil)
    }

    static func line(_ text: String, fontSize: Double) -> CTLine {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font(size: fontSize),
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]
        return CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: attributes))
    }
}
