#if os(iOS)
import PhotonsLocalization
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
    var fullSize: ImageSize? = nil
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
    private var photoCache = MobilePreviewMemoryCache(budget: 96 * 1024 * 1024)
    private var thumbnailCache = MobilePreviewMemoryCache(budget: 16 * 1024 * 1024)
    private var detailCache = MobilePreviewMemoryCache(budget: 48 * 1024 * 1024)
    private var detailPanoramaPreview: CGImage?
    private var panoramaPreview: CGImage?
    private var panoramaPair: MobilePreviewPair?
    private var sourceSignatures: [URL: String] = [:]
    private(set) var renderCount = 0
    private(set) var panoramaPreviewCount = 0
    private var previewDirectory: URL { libraryURL.appendingPathComponent("MobilePreviews",isDirectory: true) }

    struct CacheUsage: Sendable {
        var diskBytes: Int = 0
        var files: Int = 0
        var memoryBytes: Int = 0
    }
    func cacheUsage() throws -> CacheUsage {
        var result = CacheUsage(memoryBytes: photoCache.bytes + thumbnailCache.bytes + detailCache.bytes + (panoramaPair?.bytes ?? 0))
        guard FileManager.default.fileExists(atPath: previewDirectory.path) else { return result }
        for url in try FileManager.default.contentsOfDirectory(at: previewDirectory,includingPropertiesForKeys: [.fileSizeKey,.isRegularFileKey]) {
            let values = try url.resourceValues(forKeys: [.fileSizeKey,.isRegularFileKey])
            if values.isRegularFile == true { result.diskBytes += values.fileSize ?? 0; result.files += 1 }
        }
        return result
    }
    func clearPreviewCache() throws {
        releaseWorkingMemory()
        if FileManager.default.fileExists(atPath: previewDirectory.path) {
            try FileManager.default.removeItem(at: previewDirectory)
        }
    }

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
    func importPhotos(_ urls: [URL], skipDuplicates: Bool, folder: UUID? = nil,
                      progress: @Sendable @escaping (String, Double?) -> Void) throws -> ImportSummary {
        let grants = urls.map(FileAccess.init)
        defer { withExtendedLifetime(grants) {} }
        guard !urls.contains(where: { $0.pathExtension.lowercased() == "photonslibrary" }) else {
            throw MobileError.message(L10n.tr("ipad.425098113457"))
        }
        if let folder, !(try folderIndex()).folders.contains(where: { $0.id == folder }) { throw MobileError.message(L10n.tr("ipad.ccbf07f84d31")) }
        let previous = folder == nil ? Set<String>() : Set(try photos().map(\.id))
        let service = ImportService(catalog: try database())
        service.shouldCancel = { Task.isCancelled }
        let summary = try service.run(sources: urls, options: .init(mode: .copy, skipDuplicates: skipDuplicates),
                               onFile: { n,total in progress(L10n.tr("ipad.3b4dffa48409", String(describing: (n)), String(describing: (total))), Double(n) / Double(max(1,total))) })
        if let folder { try movePhotos(Set(try photos().map(\.id)).subtracting(previous),to: folder) }
        return summary
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
    func releaseWorkingMemory() {
        graph = nil; graphKey = ""; photoCache.clear(); thumbnailCache.clear(); detailCache.clear(); detailPanoramaPreview = nil
        panoramaPreview = nil; panoramaPair = nil; context.clearCaches(); previewContext.clearCaches()
    }

    private func sourceSignature(_ url: URL) throws -> String {
        // URL resource values may themselves be cached; stat the source on every lookup.
        let values = try FileManager.default.attributesOfItem(atPath: url.path)
        let signature = "\(url.path):\((values[.size] as? NSNumber)?.int64Value ?? 0):\((values[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        if let previous = sourceSignatures[url], previous != signature { sourceSizes.removeValue(forKey: url) }
        sourceSignatures[url] = signature; return signature
    }
    private func renderKey(_ photo: MobilePhoto, _ edit: EditModel, edge: Int) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(edit), source = try sourceSignature(photo.url)
        // Persisted display pixels must follow shared decoder and render algorithm upgrades,
        // even when the source file and the user's edit values are unchanged.
        let generation = "\(DecodeRecipe.current):\(StageAlgorithmVersion.graphVersion)"
        return SHA256.hash(data: Data("ipad-v3-pair:\(generation):\(photo.id):\(source):\(edge):".utf8) + data)
            .map { String(format: "%02x", $0) }.joined()
    }
    func frame(_ photo: MobilePhoto, edit: EditModel, hdr: Bool, edge: Int = 1600) throws -> MobileFrame {
        try Task.checkCancellation()
        let key = try renderKey(photo, edit, edge: edge), thumbnail = edge > 0 && edge <= 320
        if let hit = thumbnail ? thumbnailCache.get(key) : photoCache.get(key) { return hit.frame(hdr: hdr) }
        if edge > 0 && edge <= 2048, let pair = readPreview(key) {
            if thumbnail { thumbnailCache.put(pair,key: key) } else { photoCache.put(pair,key: key) }
            return pair.frame(hdr: hdr)
        }
        // Render scene-linear pixels once. Both display variants and both histogram modes derive
        // from that same result, so a mode toggle never decodes/develops the photograph again.
        let pixels = try render(photo.url, edit: edit, edge: edge, hdr: true, histogram: true, linear: true)
        guard let display = pixels.display else { throw MobileError.message(L10n.tr("ipad.fa4fb4d75cac")) }
        let fullSize = CropGeometry(geometry: edit.geometry,source: try sourceSizes[photo.url] ?? ImageSourceDecoder.size(at: photo.url)).canvas
        let snapshot = pixels.histogramSample.map { HistogramSnapshot(sample: $0,canvas: fullSize) }
        let pair = try makePair(display,snapshot: snapshot,fullSize: fullSize)
        if thumbnail { thumbnailCache.put(pair,key: key) } else { photoCache.put(pair,key: key) }
        if edge > 0 && edge <= 2048 { writePreview(pair,key: key) }
        return pair.frame(hdr: hdr)
    }
    /// Grid thumbnails and their histogram are persisted together. Selecting an unchanged photo
    /// never recomputes its histogram just to populate the inspector.
    func thumbnail(_ photo: MobilePhoto, hdr: Bool) throws -> MobileFrame {
        try frame(photo,edit: self.edit(photo.id),hdr: hdr,edge: 320)
    }
    private func readPreview(_ key: String) -> MobilePreviewPair? {
        let url = previewDirectory.appendingPathComponent(key + ".pair")
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 80*1024*1024,
              let data = try? Data(contentsOf: url), let record = try? PropertyListDecoder().decode(MobileCachedPair.self,from: data),
              let pair = try? record.pair() else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()],ofItemAtPath: url.path)
        return pair
    }
    private func writePreview(_ pair: MobilePreviewPair,key: String) {
        do {
            try FileManager.default.createDirectory(at: previewDirectory,withIntermediateDirectories: true)
            let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
            try encoder.encode(MobileCachedPair(pair)).write(to: previewDirectory.appendingPathComponent(key + ".pair"),options: .atomic)
            let files = try FileManager.default.contentsOfDirectory(at: previewDirectory,includingPropertiesForKeys: [.fileSizeKey,.contentModificationDateKey])
            let records = files.compactMap { url -> (URL,Int,Date)? in
                guard let values = try? url.resourceValues(forKeys: [.fileSizeKey,.contentModificationDateKey]) else { return nil }
                return (url,values.fileSize ?? 0,values.contentModificationDate ?? .distantPast)
            }.sorted { $0.2 < $1.2 }
            var bytes = records.reduce(0) { $0+$1.1 }
            for (url,size,_) in records where bytes > 512*1024*1024 { try FileManager.default.removeItem(at: url); bytes -= size }
        } catch { /* A disposable cache must not make photograph rendering fail. */ }
    }
    private func render(_ url: URL, edit: EditModel, edge: Int, hdr: Bool, histogram: Bool,
                        linear: Bool = false, detail: MobileDetailRequest? = nil) throws -> RenderResult {
        let signature = try sourceSignature(url)
        let size = try sourceSizes[url] ?? ImageSourceDecoder.size(at: url)
        sourceSizes[url] = size
        let scale = edge > 0 ? min(1, Float(edge) / Float(max(size.width, size.height))) : 1
        let inputs = edit.decodeInputs
        let key = signature + inputs.key + ":\(scale)"
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
        let outputSize = CropGeometry(geometry: edit.geometry,source: graphSize).canvas
        let window = detail.map { request in
            // Neighbourhood operators need pixels beyond the visible rectangle. The halo is
            // outside the viewport, so its own edge clamp cannot become a visible seam.
            let bounds = CGRect(x: 0,y: 0,width: outputSize.width,height: outputSize.height)
            let visible = CGRect(x: request.rect.minX * bounds.width,y: request.rect.minY * bounds.height,
                                 width: request.rect.width * bounds.width,height: request.rect.height * bounds.height)
            let padded = visible.insetBy(dx: -64,dy: -64).integral.intersection(bounds)
            return ImageRect(x: Int(padded.minX),y: Int(padded.minY),width: max(1,Int(padded.width)),height: max(1,Int(padded.height)))
        }
        renderCount += 1
        return try graph!.render(edit, options: RenderOptions(
            outputWindow: window,
            display: .init(primaries: .displayP3, bitDepth: 16, headroom: hdr ? 16 : 1,
                           linearOutput: linear, sdrProof: !hdr),
            wantsPixels: true, collectHistogram: histogram, histogramSampleLongEdge: 192))
    }
    func detail(_ photo: MobilePhoto, edit: EditModel, hdr: Bool, request: MobileDetailRequest) throws -> MobileDetailFrame {
        try Task.checkCancellation()
        let key = try renderKey(photo,edit,edge: -1) + ":\(request.rect):\(request.scale)"
        if let pair = detailCache.get(key), let rect = pair.rect { return MobileDetailFrame(image: pair.frame(hdr: hdr).image,rect: rect) }
        let size = try ImageSourceDecoder.size(at: photo.url)
        let scale = min(1,max(0.1,request.scale))
        #if targetEnvironment(simulator)
        let available = Double(ProcessInfo.processInfo.physicalMemory) * 0.45
        #else
        let available = Double(os_proc_available_memory()) * 0.65
        #endif
        guard Double(size.pixelCount) * scale * scale * 24 < available else {
            throw MobileError.message(L10n.tr("ipad.ac87115610b9"))
        }
        let result = try render(photo.url,edit: edit,edge: max(1,Int(Double(max(size.width,size.height))*scale)),
                                hdr: true,histogram: false,linear: true,detail: request)
        try Task.checkCancellation()
        guard let pixels = result.display else { throw MobileError.message(L10n.tr("ipad.ff89b23fe243")) }
        let full = CropGeometry(geometry: edit.geometry,source: graphSize).canvas
        let rect = CGRect(x: Double(result.window.x)/Double(full.width),y: Double(result.window.y)/Double(full.height),
                          width: Double(result.window.width)/Double(full.width),height: Double(result.window.height)/Double(full.height))
        var pair = try makePair(pixels,snapshot: nil,fullSize: nil); pair.rect = rect
        detailCache.put(pair,key: key)
        return MobileDetailFrame(image: pair.frame(hdr: hdr).image,rect: rect)
    }
    func detail(_ plan: PanoramaPlan,hdr: Bool,request: MobileDetailRequest) throws -> MobileDetailFrame {
        try Task.checkCancellation()
        if detailPanoramaPreview !== plan.preview { detailCache.clear(); detailPanoramaPreview = plan.preview }
        let key = "panorama:\(request.rect):\(request.scale)"
        if let pair = detailCache.get(key), let rect = pair.rect { return MobileDetailFrame(image: pair.frame(hdr: hdr).image,rect: rect) }
        let edge = max(1,Int(max(plan.outputSize.width,plan.outputSize.height)*min(1,max(0.1,request.scale))))
        let scene = try PanoramaEngine().renderComposite(plan,outputLongEdge: edge)
        try Task.checkCancellation()
        let r = request.rect
        // Core Image uses bottom-left coordinates; the viewport uses top-left.
        let crop = CGRect(x: r.minX*scene.extent.width,y: (1-r.maxY)*scene.extent.height,
                          width: r.width*scene.extent.width,height: r.height*scene.extent.height).integral.intersection(scene.extent)
        guard !crop.isEmpty else { throw MobileError.message(L10n.tr("ipad.8953b228e9cf")) }
        let image = scene.cropped(to: crop).transformed(by: .init(translationX: -crop.minX,y: -crop.minY))
        let rect = CGRect(x: crop.minX/scene.extent.width,y: 1-crop.maxY/scene.extent.height,width: crop.width/scene.extent.width,height: crop.height/scene.extent.height)
        var pair = try makePair(image,snapshot: nil,fullSize: nil); pair.rect = rect; detailCache.put(pair,key: key)
        return MobileDetailFrame(image: pair.frame(hdr: hdr).image,rect: rect)
    }
    private func makePair(_ display: DisplayImage,snapshot: HistogramSnapshot?,fullSize: ImageSize?) throws -> MobilePreviewPair {
        let space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
        let data = display.rgba.withUnsafeBytes { Data($0) }
        let image = CIImage(bitmapData: data, bytesPerRow: display.width * 8,
                            size: CGSize(width: display.width, height: display.height), format: .RGBAh, colorSpace: space)
        return try makePair(image,snapshot: snapshot,fullSize: fullSize)
    }
    private func makePair(_ image: CIImage,snapshot: HistogramSnapshot?,fullSize: ImageSize?) throws -> MobilePreviewPair {
        try MobilePreviewPair(
            hdr: MobileFrame(image: previewImage(image,hdr: true),histogram: snapshot?.histogram(hdr: true,headroom: 16),fullSize: fullSize),
            sdr: MobileFrame(image: previewImage(image,hdr: false),histogram: snapshot?.histogram(hdr: false,headroom: 1),fullSize: fullSize))
    }
    /// UIKit needs content headroom as well as floating-point pixels to recognize generated HDR.
    /// The stable SDR shoulder is applied in output P3, matching the shared display/histogram path.
    private func previewImage(_ linear: CIImage, hdr: Bool) throws -> CGImage {
        let image = hdr ? linear : SDRProjection.image(linear)
        let space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
        guard let cg = previewContext.createCGImage(image,from: image.extent,format: .RGBAh,colorSpace: space),
              let provider = cg.dataProvider else {
            throw MobileError.message(L10n.tr("ipad.9d1d128ebb9f"))
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
            throw MobileError.message(L10n.tr("ipad.db99213268e0"))
        }
        return tagged
    }
    func frame(_ plan: PanoramaPlan, hdr: Bool) throws -> MobileFrame {
        guard let preview = plan.preview else { throw MobileError.message(L10n.tr("ipad.31c7603f6bac")) }
        if panoramaPreview === preview, let pair = panoramaPair { return pair.frame(hdr: hdr) }
        let linear = CIImage(cgImage: preview)
        let scale = min(1,192 / max(linear.extent.width, linear.extent.height))
        let small = linear.transformed(by: CGAffineTransform(scaleX: scale,y: scale))
        let w = max(1,Int(small.extent.width)), h = max(1,Int(small.extent.height))
        var pixels = [Float16](repeating: 0,count: w*h*4)
        context.render(small,toBitmap: &pixels,rowBytes: w*8,bounds: CGRect(x: 0,y: 0,width: w,height: h),
                       format: .RGBAh,colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020))
        let snapshot = HistogramSnapshot(sample: LinearSample(width: w,height: h,rgba: pixels),
                                         canvas: ImageSize(width: Int(plan.outputSize.width),height: Int(plan.outputSize.height)))
        let pair = try makePair(linear,snapshot: snapshot,fullSize: ImageSize(width: Int(plan.outputSize.width),height: Int(plan.outputSize.height)))
        panoramaPreview = preview; panoramaPair = pair; panoramaPreviewCount += 1
        return pair.frame(hdr: hdr)
    }
    func profiles() throws -> [LCCProfileSummary] {
        let store = LCCProfileStore(); try store.installBundledProfile(); return store.catalog().profiles
    }
    func profile(_ id: UUID) throws -> LCCLensProfile { try LCCProfileStore().load(id) }
    func importProfile(_ url: URL) throws {
        let lease = FileAccess(url); defer { withExtendedLifetime(lease) {} }
        let profile = try LCCProfileCodec.decode(Data(contentsOf: url))
        _ = try LCCProfileStore().importProfile(profile, keepingBoth: true)
    }
    func sourceInfo(_ photos: [MobilePhoto]) throws -> [PanoramaSource] { try photos.map { try PanoramaSource(url: $0.url) } }
    func analyze(_ photos: [MobilePhoto], options: PanoramaOptions, positions: [Int: CGPoint],
                 sensor: SensorSize?, registrationMode: PanoramaRegistrationMode = .shift,
                 tone: PanoramaToneSettings = .panoramaDefault, cancellation: PanoramaCancellation,
                 progress: @Sendable @escaping (String, Double?) -> Void) throws -> PanoramaPlan {
        releaseWorkingMemory()
        let engine = PanoramaEngine()
        let plan = try engine.analyze(urls: photos.map(\.url), options: options, knownPositions: positions,
            sensorOverride: sensor, registrationMode: registrationMode, cancellation: cancellation, progress: { progress($0, nil) })
        return try engine.applyingTone(plan,settings: tone,cancellation: cancellation)
    }
    func adjustPanoramaTone(_ plan: PanoramaPlan, settings: PanoramaToneSettings) throws -> PanoramaPlan {
        try Task.checkCancellation()
        return try PanoramaEngine().applyingTone(plan,settings: settings,cancellation: .init(isCancelled: { Task.isCancelled }))
    }
    func correct(_ photo: MobilePhoto, flat: URL?, profileID: UUID?, position: CGPoint?, refine: Bool,
                 body: PanoramaCameraBody, orientation: PanoramaBodyOrientation,
                 cancellation: PanoramaCancellation,
                 progress: @Sendable @escaping (String, Double?) -> Void) throws -> (PanoramaPlan, PanoramaManifest?) {
        releaseWorkingMemory()
        let scene = try PanoramaSource(url: photo.url)
        if let flat {
            guard scene.isRAW, ImageSourceDecoder.isRAW(flat) else { throw MobileError.message(L10n.tr("ipad.e5b9fa63daa2")) }
            let lease = FileAccess(flat); defer { withExtendedLifetime(lease) {} }
            return (try LCCCorrectionEngine.traditional(scene: scene, flatURL: flat, cancellation: cancellation,
                                                       progress: { progress($0, nil) }), nil)
        }
        guard let profileID else { throw MobileError.message(L10n.tr("ipad.02a8ea1eb9fc")) }
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
    func correctPanorama(_ plan: PanoramaPlan, profileID: UUID, offset: CGPoint?, body: PanoramaCameraBody,
                         orientation: PanoramaBodyOrientation, cropToCoverage: Bool = false, cancellation: PanoramaCancellation,
                         progress: @Sendable @escaping (String, Double?) -> Void) throws -> PanoramaPlan {
        guard plan.registrationMode != .perspective else { throw MobileError.message(PanoramaRegistrationMode.perspectiveLCCNotice) }
        guard let sensor = plan.sources.first?.sensor else { throw MobileError.message(L10n.tr("ipad.e9baccefa276")) }
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
        guard var state = original.lccState else { throw MobileError.message(L10n.tr("ipad.75892278f586")) }
        if enabled && state.suggestedCropRect == nil {
            throw MobileError.message(L10n.tr("ipad.cce675d2aa5a"))
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
            throw MobileError.message(L10n.tr("ipad.7bafa62b2133"))
        }
        let dir = libraryURL.deletingLastPathComponent().appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = plan.map { $0.sources.count > 1 ? PanoramaManifest.defaultName($0.sources.map(\.url)) : $0.sources[0].url.deletingPathExtension().lastPathComponent + "_lcc" }
            ?? photo?.url.deletingPathExtension().lastPathComponent ?? L10n.tr("7b50017ae47e")
        let output = OutputNameAllocator().reserve(base: base, ext: settings.format == "dng" ? "dng" : settings.preset.format.fileExtension,
                                                       in: dir, policy: .rename)
        guard let output else { throw MobileError.message(L10n.tr("ipad.5ecbcaf30161")) }
        let temporary = dir.appendingPathComponent(".\(UUID().uuidString).\(output.pathExtension)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        progress(L10n.tr("ipad.e2fe353986e6"), 0.1)
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
            guard let display = result.display else { throw MobileError.message(L10n.tr("ipad.581ba110257c")) }
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
        } else { throw MobileError.message(L10n.tr("ipad.c162e32895fb")) }
        try cancellation.check()
        try FileManager.default.moveItem(at: temporary, to: output)
        progress(L10n.tr("ipad.68cf9d755003"), 0.95)
        let imported = try importPhotos([output], skipDuplicates: true, progress: { _,_ in })
        guard imported.failed == 0 else { throw MobileError.message(L10n.tr("ipad.152205333949", String(describing: (output.lastPathComponent)))) }
        progress(L10n.tr("3e6886d17a1c"), 1)
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
        var item = ExportItem(id: photo?.id ?? "panorama", name: photo?.name ?? L10n.tr("ipad.2be61912014b"), edit: edit, sourceURL: photo?.url)
        item.panoramaMetadata = packet
        var metadata = ExportMetadataContext(source: source, edit: edit, embedXMP: edit != nil)
        metadata.panoramaData = try PanoramaExportMetadata.data(for: item, source: source,
            trimX: Double(image.width) / Double(original.width), trimY: Double(image.height) / Double(original.height),
            sourceSize: photo.flatMap { sourceSizes[$0.url] })
        try Exporter.write(image, to: url, options: preset.exportOptions, metadata: metadata)
    }
}
enum MobileError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}
private extension Int { var nonzeroOr20: Int { [10,20,50,100].contains(self) ? self : 20 } }
#endif
