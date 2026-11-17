#if os(iOS)
import Foundation
import CoreImage
import ImageIO
import CryptoKit
import PhotonsCore
import PhotonsCatalog
import PhotonsPanorama
import PhotonsExport
import PhotonsJobs
import PhotonsFileAccess
import os

struct MobilePhoto: Identifiable, Sendable {
    var id: String
    var name: String
    var url: URL
    var rating: Int
    var width: Int
    var height: Int
}
struct MobileFrame: @unchecked Sendable {
    var image: CGImage
    var histogram: Histogram?
}
struct MobileExportSettings: Sendable {
    var format = "heic"
    var hdr = true
    var longEdge = 4096
    var quality = 0.92
    var preset: ExportPreset {
        let f = ExportFormat(rawValue: format) ?? .heic
        return ExportPreset(format: f, longEdge: longEdge > 0 ? longEdge : nil,
                            quality: quality, bitDepth: f == .tiff || f == .png ? 16 : 8,
                            hdrKind: hdr ? f.defaultHDRKind : .none,
                            watermarkText: "")
    }
}

/// All expensive work and mutable GPU objects are confined to one actor. The platform UI never
/// implements image arithmetic. This is an in-process executor, not macOS helper-process isolation.
actor MobileEngine {
    let libraryURL: URL
    private var catalog: Catalog?
    private var graph: RenderGraph?
    private var sourceSizes: [URL: ImageSize] = [:]
    private var graphKey = ""
    private var graphSize = ImageSize(width: 1, height: 1)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let previewContext = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!, .cacheIntermediates: false])
    private var cachedFrames: [String: MobileFrame] = [:]
    private var cacheOrder: [String] = []

    init(libraryURL: URL? = nil) {
        self.libraryURL = libraryURL ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("iPad Preview.photonslibrary", isDirectory: true)
    }
    private func database() throws -> Catalog {
        if let catalog { return catalog }
        // Use the shared layout rather than assuming the database filename when opening older libraries.
        let layout = LibraryLayout(packageURL: libraryURL)
        let db = FileManager.default.fileExists(atPath: layout.databaseURL.path)
            ? try Catalog.open(at: libraryURL) : try Catalog.create(at: libraryURL)
        catalog = db
        return db
    }
    func photos() throws -> [MobilePhoto] {
        let db = try database()
        return try db.assets().map { a in
            MobilePhoto(id: a.id, name: a.filename, url: try db.fileURL(for: a), rating: a.rating,
                        width: a.width ?? 0, height: a.height ?? 0)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    func importPhotos(_ urls: [URL], skipDuplicates: Bool,
                      progress: @Sendable @escaping (String, Double?) -> Void) throws -> ImportSummary {
        let grants = urls.map(FileAccess.init)
        defer { withExtendedLifetime(grants) {} }
        let service = ImportService(catalog: try database())
        service.shouldCancel = { Task.isCancelled }
        return try service.run(sources: urls, options: .init(mode: .copy, skipDuplicates: skipDuplicates),
                               onFile: { n,total in progress("Importing \(n) of \(total)", Double(n) / Double(max(1,total))) })
    }
    func edit(_ id: String) throws -> EditModel { try database().develop(forAsset: id) }
    func history(_ id: String) throws -> EditHistory {
        try database().editHistory(forAsset: id, maxDepth: UserDefaults.standard.integer(forKey: "photons.historyDepth").nonzeroOr20)
    }
    func save(_ edit: EditModel, history: EditHistory, id: String) throws {
        _ = try database().saveDevelop(edit, history: history, forAsset: id)
    }
    func rating(_ rating: Int, id: String) throws { try database().setRating(rating, forAsset: id) }
    func importedEdit(_ id: String) throws -> EditModel { try database().importedDevelop(forAsset: id) ?? .neutral }
    func releaseWorkingMemory() { graph = nil; graphKey = ""; cachedFrames.removeAll(); cacheOrder.removeAll(); context.clearCaches() }

    private func renderKey(_ photo: MobilePhoto, _ edit: EditModel, hdr: Bool, edge: Int) throws -> String {
        let data = try JSONEncoder().encode(edit)
        return SHA256.hash(data: Data("ipad-v2:\(photo.id):\(hdr):\(edge):".utf8) + data)
            .map { String(format: "%02x", $0) }.joined()
    }
    func frame(_ photo: MobilePhoto, edit: EditModel, hdr: Bool, edge: Int = 1600) throws -> MobileFrame {
        try Task.checkCancellation()
        let key = try renderKey(photo, edit, hdr: hdr, edge: edge)
        if let hit = cachedFrames[key] { return hit }
        let pixels = try render(photo.url, edit: edit, edge: edge, hdr: hdr, histogram: true, linear: true)
        guard let display = pixels.display else { throw MobileError.message("The renderer returned no image.") }
        let image = try displayImage(display, hdr: hdr)
        let frame = MobileFrame(image: image, histogram: pixels.histogram)
        cachedFrames[key] = frame; cacheOrder.append(key)
        while cacheOrder.count > 8 { cachedFrames.removeValue(forKey: cacheOrder.removeFirst()) }
        return frame
    }
    /// Grid thumbnails and their histogram are persisted together. Selecting an unchanged photo
    /// never recomputes its histogram just to populate the inspector.
    func thumbnail(_ photo: MobilePhoto, hdr: Bool) throws -> MobileFrame {
        let edit = try self.edit(photo.id), key = try renderKey(photo, edit, hdr: hdr, edge: 320)
        let dir = libraryURL.appendingPathComponent("MobilePreviews", isDirectory: true)
        let cached = dir.appendingPathComponent(key + ".preview")
        if let data = try? Data(contentsOf: cached), let record = try? PropertyListDecoder().decode(MobileCachedPreview.self,from: data),
           let frame = try? record.frame() {
            return frame
        }
        let frame = try frame(photo, edit: edit, hdr: hdr, edge: 320)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let record = try? MobileCachedPreview(frame) {
            let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
            try? encoder.encode(record).write(to: cached,options: .atomic)
        }
        return frame
    }
    private func render(_ url: URL, edit: EditModel, edge: Int, hdr: Bool, histogram: Bool,
                        linear: Bool = false) throws -> RenderResult {
        let size = try sourceSizes[url] ?? ImageSourceDecoder.size(at: url)
        sourceSizes[url] = size
        let scale = edge > 0 ? min(1, Float(edge) / Float(max(size.width, size.height))) : 1
        let inputs = edit.decodeInputs
        let key = url.path + inputs.key + ":\(scale)"
        if graphKey != key || graph == nil {
            graph = nil
            let image: LinearImage
            let input: RenderInput
            if ImageSourceDecoder.isRAW(url) {
                let result = try RAWDecoder().decodeDetailed(url, options: .init(decoderVersion: inputs.decoderVersion,
                    scale: scale, whiteBalance: inputs.whiteBalance, detail: inputs.detail))
                image = result.image
                input = RenderInput(image: image, identity: key, sourceURL: url, lensProfile: result.lensProfile,
                                    whiteBalance: inputs.whiteBalance, asShotPair: result.asShotWhiteBalance)
            } else {
                image = try ImageSourceDecoder.decodeRaster(url, scale: scale)
                input = RenderInput(image: image, identity: key, sourceURL: url)
            }
            graphSize = ImageSize(width: image.uprightSize.width, height: image.uprightSize.height)
            graph = try RenderGraph(input: input, cacheBudgetBytes: 160_000_000)
            graphKey = key
        }
        try Task.checkCancellation()
        return try graph!.render(edit, options: RenderOptions(
            display: .init(primaries: .displayP3, bitDepth: 16, headroom: hdr ? 16 : 1,
                           linearOutput: linear, sdrProof: !hdr),
            wantsPixels: true, collectHistogram: histogram, histogramSampleLongEdge: 192))
    }
    private func displayImage(_ display: DisplayImage, hdr: Bool) throws -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
        let data = display.rgba.withUnsafeBytes { Data($0) }
        let image = CIImage(bitmapData: data, bytesPerRow: display.width * 8,
                            size: CGSize(width: display.width, height: display.height), format: .RGBAh, colorSpace: space)
        return try previewImage(image,hdr: hdr)
    }
    /// UIKit needs content headroom as well as floating-point pixels to recognize generated HDR.
    /// The stable SDR shoulder is applied in output P3, matching the shared display/histogram path.
    private func previewImage(_ linear: CIImage, hdr: Bool) throws -> CGImage {
        let image = hdr ? linear : SDRProjection.image(linear)
        let space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
        guard let cg = previewContext.createCGImage(image,from: image.extent,format: .RGBAh,colorSpace: space),
              let provider = cg.dataProvider else {
            throw MobileError.message("Could not create the preview.")
        }
        var peak: Float = 1
        if hdr {
            let maximum = image.applyingFilter("CIAreaMaximum",parameters: ["inputExtent": CIVector(cgRect: image.extent)])
            var sample = [Float](repeating: 0,count: 4)
            previewContext.render(maximum,toBitmap: &sample,rowBytes: 16,bounds: CGRect(x: 0,y: 0,width: 1,height: 1),format: .RGBAf,colorSpace: space)
            peak = max(1,sample[0],sample[1],sample[2])
            if !peak.isFinite { peak = 1 }
        }
        guard let tagged = CGImage(headroom: peak,width: cg.width,height: cg.height,bitsPerComponent: cg.bitsPerComponent,
            bitsPerPixel: cg.bitsPerPixel,bytesPerRow: cg.bytesPerRow,space: space,bitmapInfo: cg.bitmapInfo,
            provider: provider,decode: nil,shouldInterpolate: true,intent: .defaultIntent) else {
            throw MobileError.message("Could not tag the preview's dynamic range.")
        }
        return tagged
    }
    func frame(_ plan: PanoramaPlan, hdr: Bool) throws -> MobileFrame {
        guard let preview = plan.preview else { throw MobileError.message("No composite preview was produced.") }
        let linear = CIImage(cgImage: preview)
        let image = try previewImage(linear,hdr: hdr)
        let scale = min(1,192 / max(linear.extent.width, linear.extent.height))
        let small = linear.transformed(by: CGAffineTransform(scaleX: scale,y: scale))
        let w = max(1,Int(small.extent.width)), h = max(1,Int(small.extent.height))
        var pixels = [Float16](repeating: 0,count: w*h*4)
        context.render(small,toBitmap: &pixels,rowBytes: w*8,bounds: CGRect(x: 0,y: 0,width: w,height: h),
                       format: .RGBAh,colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020))
        let snapshot = HistogramSnapshot(sample: LinearSample(width: w,height: h,rgba: pixels),
                                         canvas: ImageSize(width: Int(plan.outputSize.width),height: Int(plan.outputSize.height)))
        return MobileFrame(image: image,histogram: snapshot.histogram(hdr: hdr,headroom: hdr ? 16 : 1))
    }
    func profiles() throws -> [LCCProfileSummary] {
        let store = LCCProfileStore(); try store.installBundledProfile(); return store.catalog().profiles
    }
    func importProfile(_ url: URL) throws {
        let lease = FileAccess(url); defer { withExtendedLifetime(lease) {} }
        let profile = try LCCProfileCodec.decode(Data(contentsOf: url))
        _ = try LCCProfileStore().importProfile(profile, keepingBoth: true)
    }
    func sourceInfo(_ photos: [MobilePhoto]) throws -> [PanoramaSource] { try photos.map { try PanoramaSource(url: $0.url) } }
    func analyze(_ photos: [MobilePhoto], options: PanoramaOptions, positions: [Int: CGPoint],
                 sensor: SensorSize?, registrationMode: PanoramaRegistrationMode = .shift, cancellation: PanoramaCancellation,
                 progress: @Sendable @escaping (String, Double?) -> Void) throws -> PanoramaPlan {
        releaseWorkingMemory()
        return try PanoramaEngine().analyze(urls: photos.map(\.url), options: options, knownPositions: positions,
            sensorOverride: sensor, registrationMode: registrationMode, cancellation: cancellation, progress: { progress($0, nil) })
    }
    func correct(_ photo: MobilePhoto, flat: URL?, profileID: UUID?, position: CGPoint?, refine: Bool,
                 body: PanoramaCameraBody, orientation: PanoramaBodyOrientation,
                 cancellation: PanoramaCancellation,
                 progress: @Sendable @escaping (String, Double?) -> Void) throws -> (PanoramaPlan, PanoramaManifest?) {
        releaseWorkingMemory()
        let scene = try PanoramaSource(url: photo.url)
        if let flat {
            guard scene.isRAW, ImageSourceDecoder.isRAW(flat) else { throw MobileError.message("Traditional LCC requires a Bayer RAW photograph and its matching RAW flat. Use a lens profile for rendered photographs.") }
            let lease = FileAccess(flat); defer { withExtendedLifetime(lease) {} }
            return (try LCCCorrectionEngine.traditional(scene: scene, flatURL: flat, cancellation: cancellation,
                                                       progress: { progress($0, nil) }), nil)
        }
        guard let profileID else { throw MobileError.message("Choose a lens profile first.") }
        let profile = try LCCProfileStore().load(profileID)
        if let manifest = try PanoramaManifest.read(from: photo.url), manifest.frames.count > 1 {
            let result = try LCCCorrectionEngine.postProcess(scene: scene, manifest: manifest, profile: profile,
                offset: position.flatMap { manifest.offset(pictureCenter: $0) }, cameraBody: body,
                cancellation: cancellation, progress: { progress($0, nil) })
            return (result.plan, result.manifest)
        }
        return (try LCCCorrectionEngine.single(scene: scene, profile: profile, position: position, refine: refine,
            body: body, orientation: orientation, cancellation: cancellation, progress: { progress($0, nil) }).plan, nil)
    }
    /// Rebuild only seams on the frozen, possibly LCC-corrected source previews.
    func setPanoramaDeghosting(_ plan: PanoramaPlan, enabled: Bool, cancellation: PanoramaCancellation) throws -> PanoramaPlan {
        var options = plan.options; options.avoidMotion = enabled
        return try PanoramaEngine().update(plan, options: options, cancellation: cancellation)
    }
    func correctPanorama(_ plan: PanoramaPlan, profileID: UUID, offset: CGPoint?, body: PanoramaCameraBody,
                         orientation: PanoramaBodyOrientation, cropToCoverage: Bool = false, cancellation: PanoramaCancellation,
                         progress: @Sendable @escaping (String, Double?) -> Void) throws -> PanoramaPlan {
        guard plan.registrationMode != .perspective else { throw MobileError.message(PanoramaRegistrationMode.perspectiveLCCNotice) }
        guard let sensor = plan.sources.first?.sensor else { throw MobileError.message("Sensor dimensions are required for LCC.") }
        let engine = PanoramaEngine(), profile = try LCCProfileStore().load(profileID)
        let fields = try LCCCorrectionEngine.fields(profile, cancellation: cancellation)
        let prepared = try engine.prepareLCCImages(plan, cancellation: cancellation, progress: { progress($0, nil) })
        let origin = try offset ?? LCCPositionSolver.solve(plan: prepared, fields: fields, sensor: sensor,
            cameraBody: body, bodyOrientation: orientation, cancellation: cancellation, progress: { progress($0, nil) }).offsetMM
        return try engine.applyingLCC(prepared, profile: profile, fields: fields, offsetMM: origin,
            sensor: sensor, crop: cropToCoverage, cancellation: cancellation, cameraBody: body, bodyOrientation: orientation)
    }
    /// Reuse the measured coverage and corrected preview pixels; changing the crop does not decode RAWs or solve LCC again.
    func setLCCCrop(_ original: PanoramaPlan, enabled: Bool, cancellation: PanoramaCancellation) throws -> PanoramaPlan {
        guard var state = original.lccState else { throw MobileError.message("Apply LCC before cropping to its corrected area.") }
        if enabled && state.suggestedCropRect == nil {
            throw MobileError.message("The lens profile does not cover a rectangular area that can be safely cropped.")
        }
        var plan = original
        state.cropRect = enabled ? state.suggestedCropRect : nil
        plan.lccState = state
        return try PanoramaEngine().update(plan, options: plan.options, cancellation: cancellation)
    }
    func createProfile(name: String, frames: [LCCCreationFrame], sensor: SensorSize,
                       cancellation: PanoramaCancellation, progress: @Sendable @escaping (String, Double?) -> Void) throws {
        let profile = try LCCProfileBuilder.create(name: name, aperture: nil, notes: "User-created iPad profile",
            frames: frames, sensorLongEdge: max(sensor.width, sensor.height), sensorShortEdge: min(sensor.width, sensor.height),
            cancellation: cancellation, progress: { progress($0, nil) })
        _ = try LCCProfileStore().save(profile)
    }
    func export(photo: MobilePhoto?, edit: EditModel, plan: PanoramaPlan?, manifest: PanoramaManifest?,
                settings: MobileExportSettings, cancellation: PanoramaCancellation,
                progress: @Sendable @escaping (String, Double?) -> Void) throws -> URL {
        releaseWorkingMemory()
        try cancellation.check()
        // Query the app's current limit, rather than assuming an iPad can use all physical RAM.
        // Linear DNG encodes tiles; the decoded inputs still have to fit, and raster formats also
        // need a full output buffer. This is an estimate, not a guarantee against a later memory warning.
        let sizes = plan?.sources.map(\.size) ?? photo.map { [CGSize(width: $0.width,height: $0.height)] } ?? []
        if plan == nil, let photo {
            // Catalog dimensions can describe a RAW's embedded thumbnail, so they cannot be
            // used to budget an original-resolution decode after a thumbnail cache hit.
            sourceSizes[photo.url] = try sourceSizes[photo.url] ?? ImageSourceDecoder.size(at: photo.url)
        }
        let resolvedSizes: [CGSize]
        if plan == nil, let photo, let size = sourceSizes[photo.url] { resolvedSizes = [CGSize(width: size.width,height: size.height)] }
        else { resolvedSizes = sizes }
        let canvas = plan?.outputSize ?? resolvedSizes.first ?? .zero
        let scale = settings.longEdge > 0 ? min(1,Double(settings.longEdge)/max(1,canvas.width,canvas.height)) : 1
        let decodedBytes = resolvedSizes.reduce(0.0) { $0 + $1.width*$1.height*scale*scale*8 }
        let largestSource = resolvedSizes.map { $0.width*$0.height }.max() ?? 0
        let outputBytes = canvas.width*canvas.height*scale*scale*(settings.format == "dng" && plan != nil ? 0 : 40)
        let estimate = decodedBytes + largestSource*(plan?.lccState == nil ? 8 : 16) + outputBytes + 256_000_000
        #if targetEnvironment(simulator)
        let available = Double(ProcessInfo.processInfo.physicalMemory)*0.45
        #else
        let available = Double(os_proc_available_memory())*0.8
        #endif
        guard estimate < available else {
            throw MobileError.message("This export needs more memory than is currently available. Choose a smaller long edge, or export fewer source photos. The output size has not been reduced automatically.")
        }
        let dir = libraryURL.deletingLastPathComponent().appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = plan.map { $0.sources.count > 1 ? PanoramaManifest.defaultName($0.sources.map(\.url)) : $0.sources[0].url.deletingPathExtension().lastPathComponent + "_lcc" }
            ?? photo?.url.deletingPathExtension().lastPathComponent ?? "Photo"
        let output = OutputNameAllocator().reserve(base: base, ext: settings.format == "dng" ? "dng" : settings.preset.format.fileExtension,
                                                       in: dir, policy: .rename)
        guard let output else { throw MobileError.message("Could not reserve an output filename.") }
        let temporary = dir.appendingPathComponent(".\(UUID().uuidString).\(output.pathExtension)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        progress("Rendering", 0.1)
        let preset = settings.preset
        if let plan {
            let scene = try PanoramaEngine().renderComposite(plan, cancellation: cancellation, outputLongEdge: settings.longEdge > 0 ? settings.longEdge : nil,
                                                             progress: { progress($0, nil) })
            let packet = try (manifest ?? PanoramaManifest(plan: plan)).encoded()
            if settings.format == "dng" {
                try LinearDNGWriter.write(image: scene, context: context, to: temporary, manifest: packet,
                                          cancellation: cancellation, progress: { progress($0, nil) })
            } else {
                let rendered = try PanoramaPixelRenderer.render(scene: scene, preset: preset, progress: progress)
                try writeRendered(rendered, to: temporary, preset: preset, packet: packet)
            }
        } else if let photo {
            let result = try render(photo.url, edit: edit, edge: settings.longEdge, hdr: settings.hdr,
                                    histogram: false, linear: settings.hdr || settings.format == "dng")
            guard let display = result.display else { throw MobileError.message("The renderer returned no pixels.") }
            let linear = LinearPixels(width: display.width, height: display.height, rgba: display.rgba, primaries: .displayP3)
            let packet = try PanoramaManifest.read(from: photo.url)?.encoded()
            if settings.format == "dng" {
                let data = display.rgba.withUnsafeBytes { Data($0) }
                let image = CIImage(bitmapData: data, bytesPerRow: display.width * 8, size: CGSize(width: display.width, height: display.height),
                                    format: .RGBAh, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3))
                var item = ExportItem(id: photo.id, name: photo.name, edit: edit, sourceURL: photo.url)
                item.panoramaMetadata = packet
                let adjusted = try PanoramaExportMetadata.data(for: item, source: nil, trimX: 1, trimY: 1, sourceSize: sourceSizes[photo.url])
                try LinearDNGWriter.write(image: image, context: context, to: temporary, manifest: adjusted, cancellation: cancellation,
                                          progress: { progress($0, nil) })
            } else {
                let rendered = settings.hdr ? linear.displaySDR(bitDepth: preset.effectiveBitDepth, toneMap: .global) : display
                try writeRendered(rendered, to: temporary, preset: preset, packet: packet, photo: photo, edit: edit)
            }
        } else { throw MobileError.message("Select a photo first.") }
        try cancellation.check()
        try FileManager.default.moveItem(at: temporary, to: output)
        progress("Importing output", 0.95)
        let imported = try importPhotos([output], skipDuplicates: true, progress: { _,_ in })
        guard imported.failed == 0 else { throw MobileError.message("Saved \(output.lastPathComponent) in Documents/Exports, but automatic library import failed. You can import the saved file again.") }
        progress("Export complete", 1)
        releaseWorkingMemory()
        return output
    }
    private func writeRendered(_ original: DisplayImage, to url: URL, preset: ExportPreset,
                               packet: Data?, photo: MobilePhoto? = nil, edit: EditModel? = nil) throws {
        var image = original
        if preset.hdrKind == .gainMap, preset.hdr?.halfSize == true {
            let crop = GainMapSizing.plan(image.size, halfSize: true).crop
            if crop.isNeeded { image = GainMapSizing.crop(image, crop) }
        }
        let source = SourceMetadata.read(from: photo?.url)
        var item = ExportItem(id: photo?.id ?? "panorama", name: photo?.name ?? "Panorama", edit: edit, sourceURL: photo?.url)
        item.panoramaMetadata = packet
        var metadata = ExportMetadataContext(source: source, edit: edit, embedXMP: edit != nil)
        metadata.panoramaData = try PanoramaExportMetadata.data(for: item, source: source,
            trimX: Double(image.width) / Double(original.width), trimY: Double(image.height) / Double(original.height),
            sourceSize: photo.flatMap { sourceSizes[$0.url] })
        try Exporter.write(image, to: url, options: preset.exportOptions, metadata: metadata)
    }
}
/// Losslessly compressed half-float thumbnails preserve highlight data across app launches.
/// Dimensions and histogram travel in the same atomic cache entry; old JPEG entries use a different key.
private struct MobileCachedPreview: Codable {
    var width: Int
    var height: Int
    var rowBytes: Int
    var bitmapInfo: UInt32
    var headroom: Float
    var histogram: Histogram?
    var pixels: Data
    init(_ frame: MobileFrame) throws {
        let image = frame.image
        guard let bytes = image.dataProvider?.data else { throw MobileError.message("Missing preview pixels.") }
        width = image.width; height = image.height; rowBytes = image.bytesPerRow
        bitmapInfo = image.bitmapInfo.rawValue; headroom = image.contentHeadroom; histogram = frame.histogram
        pixels = try (bytes as NSData).compressed(using: .lzfse) as Data
    }
    func frame() throws -> MobileFrame {
        guard (1...320).contains(width), (1...320).contains(height), rowBytes >= width*8, rowBytes <= 4096 else {
            throw MobileError.message("Invalid preview dimensions.")
        }
        let bytes = try (pixels as NSData).decompressed(using: .lzfse) as Data
        guard bytes.count == rowBytes*height, let provider = CGDataProvider(data: bytes as CFData),
              let image = CGImage(headroom: headroom,width: width,height: height,bitsPerComponent: 16,bitsPerPixel: 64,
                bytesPerRow: rowBytes,space: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!,
                bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),provider: provider,decode: nil,shouldInterpolate: true,intent: .defaultIntent) else {
            throw MobileError.message("Invalid cached preview.")
        }
        return MobileFrame(image: image,histogram: histogram)
    }
}
enum MobileError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}
private extension Int { var nonzeroOr20: Int { [10,20,50,100].contains(self) ? self : 20 } }
#endif
