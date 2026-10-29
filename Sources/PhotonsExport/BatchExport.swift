import Foundation
import PhotonsCore
import CoreGraphics
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

/// A one-way flag the sheet's 取消 button sets. Checked before each queued item starts; an item
/// already rendering is allowed to finish (so its file is complete, never half written), and the
/// rest come back as `cancelled` outcomes.
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
                                        render: render)
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
