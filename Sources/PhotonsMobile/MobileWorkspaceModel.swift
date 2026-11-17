#if os(iOS)
import SwiftUI
import UIKit
import PhotonsCore
import PhotonsCatalog
import PhotonsPanorama

@MainActor
final class MobileWorkspaceModel: ObservableObject {
    @Published var photos: [MobilePhoto] = []
    @Published var selected: Set<String> = []
    @Published var active: MobilePhoto?
    @Published var edit = EditModel.neutral
    @Published var history = EditHistory()
    @Published var frame: MobileFrame?
    @Published var thumbnails: [String: MobileFrame] = [:]
    @Published var previewErrors: [String: String] = [:]
    @Published var plan: PanoramaPlan?
    @Published var manifest: PanoramaManifest?
    @Published var lccPositionNote: String?
    @Published var profiles: [LCCProfileSummary] = []
    @Published var busy = false
    @Published var rendering = false
    @Published var selectionLoading = false
    @Published var status = ""
    @Published var progress: Double?
    @Published var error: String?
    @Published var output: URL?
    @Published var showGrid = true
    @Published var hdr = UserDefaults.standard.object(forKey: "photons.mobile.hdr") as? Bool ?? true
    let engine: MobileEngine
    init() {
        // Generated UI-test examples stay separate from the user's working library.
        let sampleLibrary = ProcessInfo.processInfo.arguments.contains("--demo")
            ? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Generated Samples.photonslibrary") : nil
        engine = MobileEngine(libraryURL: sampleLibrary)
    }
    private var job: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var thumbnailTask: Task<Void, Never>?
    private var selectionTask: Task<Void, Never>?
    private var cancellation = PanoramaCancellation()
    private var generation = 0
    private var selectionRevision = 0

    var selectedPhotos: [MobilePhoto] { photos.filter { selected.contains($0.id) } }
    var canExport: Bool { plan != nil || active != nil }
    func start() async {
        do {
            photos = try await engine.photos(); profiles = try await engine.profiles()
            if ProcessInfo.processInfo.arguments.contains("--boston"), !MobileSamples.boston.isEmpty {
                importPhotos(MobileSamples.boston)
            } else if ProcessInfo.processInfo.arguments.contains("--demo"), photos.isEmpty {
                let urls = try await Task.detached { try MobileSamples.create() }.value
                importPhotos(urls)
            } else { warmThumbnails() }
        } catch { self.error = error.localizedDescription }
    }
    func reload() async throws { photos = try await engine.photos(); profiles = try await engine.profiles() }
    func warmThumbnails() {
        thumbnailTask?.cancel()
        let list = photos, hdr = hdr
        thumbnailTask = Task {
            for (index,photo) in list.enumerated() {
                if Task.isCancelled { break }
                do {
                    let value = try await engine.thumbnail(photo, hdr: hdr)
                    guard !Task.isCancelled else { break }
                    thumbnails[photo.id] = value; previewErrors.removeValue(forKey: photo.id)
                    if active?.id == photo.id && showGrid && plan == nil { frame = value }
                } catch is CancellationError { break }
                catch { previewErrors[photo.id] = error.localizedDescription }
                if !busy { status = "Preparing previews \(index + 1) of \(list.count)"; progress = Double(index + 1) / Double(max(1,list.count)) }
                await Task.yield()
            }
            if !Task.isCancelled && !busy { status = ""; progress = nil }
        }
    }
    func select(_ photo: MobilePhoto, open: Bool = false) {
        previewTask?.cancel(); selectionTask?.cancel(); generation += 1
        selectionRevision += 1
        let ticket = selectionRevision
        selectionLoading = true; rendering = false
        edit = .neutral; history = EditHistory()
        active = photo; frame = thumbnails[photo.id]; plan = nil; manifest = nil; lccPositionNote = nil
        if open { selected = [photo.id]; showGrid = false }
        selectionTask = Task {
            do {
                let values = try await engine.edit(photo.id)
                let stack = try await engine.history(photo.id)
                guard !Task.isCancelled, ticket == selectionRevision else { return }
                selectionLoading = false
                edit = values; history = stack
                if !showGrid { render() }
            } catch { if !Task.isCancelled { selectionLoading = false; self.error = error.localizedDescription } }
        }
    }
    func toggleSelection(_ photo: MobilePhoto) {
        if selected.contains(photo.id) { selected.remove(photo.id) } else { selected.insert(photo.id) }
        select(photo)
    }
    func render() {
        guard !selectionLoading, let photo = active, plan == nil else { return }
        previewTask?.cancel(); generation += 1
        let ticket = generation, values = edit, hdr = hdr
        rendering = true
        previewTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(120))
                let result = try await engine.frame(photo, edit: values, hdr: hdr)
                guard !Task.isCancelled, ticket == generation else { return }
                frame = result; rendering = false
            } catch is CancellationError { }
            catch { if ticket == generation { rendering = false; self.error = error.localizedDescription } }
        }
    }
    func update(_ path: WritableKeyPath<EditModel, Double>, _ value: Double) { edit[keyPath: path] = value; render() }
    func mutate(_ label: String, _ mutation: (inout EditModel) -> Void) { mutation(&edit); commit(label); render() }
    func commit(_ label: String) {
        guard !selectionLoading, let photo = active else { return }
        history.commit(edit, label: label, coalesce: false)
        let values = edit, stack = history
        Task {
            do {
                try await engine.save(values, history: stack, id: photo.id)
                let thumb = try await engine.thumbnail(photo, hdr: hdr)
                thumbnails[photo.id] = thumb
            } catch { self.error = error.localizedDescription }
        }
    }
    func undo() { if let value = history.undo() { restore(value) } }
    func redo() { if let value = history.redo() { restore(value) } }
    func jump(_ seq: Int) { if let value = history.jump(to: seq) { restore(value) } }
    private func restore(_ value: EditModel) {
        edit = value; render()
        guard let id = active?.id else { return }
        let stack = history
        Task {
            do {
                try await engine.save(value, history: stack, id: id)
                if let photo = photos.first(where: { $0.id == id }) { thumbnails[id] = try await engine.thumbnail(photo, hdr: hdr) }
            } catch { self.error = error.localizedDescription }
        }
    }
    func reset() {
        guard let id = active?.id else { return }
        Task {
            do { let original = try await engine.importedEdit(id); mutate("Restore imported settings") { $0 = original } }
            catch { self.error = error.localizedDescription }
        }
    }
    func toggleHDR() {
        hdr.toggle(); UserDefaults.standard.set(hdr, forKey: "photons.mobile.hdr")
        if let plan {
            previewTask?.cancel(); generation += 1
            let ticket = generation, hdr = hdr
            previewTask = Task {
                do {
                    let result = try await engine.frame(plan, hdr: hdr)
                    guard !Task.isCancelled, ticket == generation else { return }
                    frame = result
                } catch { if !Task.isCancelled, ticket == generation { self.error = error.localizedDescription } }
            }
        } else { render() }
        warmThumbnails()
    }
    func setRating(_ rating: Int) {
        guard let photo = active else { return }
        Task {
            do { try await engine.rating(rating, id: photo.id); try await reload() }
            catch { self.error = error.localizedDescription }
        }
    }
    private var report: @Sendable (String, Double?) -> Void {
        { [weak self] text,fraction in Task { @MainActor in self?.status = text; self?.progress = fraction } }
    }
    private func run(_ title: String, work: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        thumbnailTask?.cancel(); previewTask?.cancel(); generation += 1; rendering = false
        busy = true; status = title; progress = nil; cancellation = PanoramaCancellation()
        job = Task {
            do { try await work() }
            catch is CancellationError { status = "Cancelled" }
            catch { self.error = error.localizedDescription }
            busy = false; progress = nil
            if !Task.isCancelled { status = "" }
        }
    }
    func cancel() { cancellation.cancel(); job?.cancel(); status = "Cancelling…" }
    func importPhotos(_ urls: [URL]) {
        run("Importing") {
            let summary = try await self.engine.importPhotos(urls, skipDuplicates: UserDefaults.standard.object(forKey: "photons.mobile.skipDuplicates") as? Bool ?? true, progress: self.report)
            try await self.reload()
            if summary.failed > 0 { self.error = "\(summary.failed) file(s) could not be imported. Imported photos have been retained." }
            self.warmThumbnails()
        }
    }
    func importProfile(_ url: URL) {
        run("Importing lens profile") { try await self.engine.importProfile(url); self.profiles = try await self.engine.profiles() }
    }
    func stitch(options: PanoramaOptions, positions: [Int: CGPoint], sensor: SensorSize?, registrationMode: PanoramaRegistrationMode = .shift) {
        let sources = selectedPhotos
        run("Aligning panorama") {
            let result = try await self.engine.analyze(sources, options: options, positions: positions, sensor: sensor, registrationMode: registrationMode,
                                                       cancellation: self.cancellation, progress: self.report)
            self.plan = result; self.manifest = nil; self.lccPositionNote = nil; self.frame = try await self.engine.frame(result, hdr: self.hdr); self.showGrid = false
        }
    }
    func correct(flat: URL?, profileID: UUID?, position: CGPoint?, refine: Bool,
                 body: PanoramaCameraBody, orientation: PanoramaBodyOrientation) {
        guard let photo = active else { return }
        run("LCC correction") {
            let result = try await self.engine.correct(photo, flat: flat, profileID: profileID, position: position, refine: refine,
                body: body, orientation: orientation, cancellation: self.cancellation, progress: self.report)
            self.plan = result.0; self.manifest = result.1; self.frame = try await self.engine.frame(result.0, hdr: self.hdr); self.showGrid = false
        }
    }
    func correctPanorama(profileID: UUID, offset: CGPoint?, body: PanoramaCameraBody, orientation: PanoramaBodyOrientation, cropToCoverage: Bool = false) {
        guard let plan else { return }
        run("Correcting panorama") {
            self.plan = try await self.engine.correctPanorama(plan, profileID: profileID, offset: offset, body: body,
                orientation: orientation, cropToCoverage: cropToCoverage, cancellation: self.cancellation, progress: self.report)
            self.manifest = nil
            self.lccPositionNote = offset == nil ? "Scene-based LCC placement is an estimate. Check the source positions and, if necessary, specify a measured reference before exporting." : nil
            if let updated = self.plan { self.frame = try await self.engine.frame(updated, hdr: self.hdr) }
        }
    }
    func setLCCCrop(_ enabled: Bool) {
        guard let plan else { return }
        run("Updating corrected-area crop") {
            let updated = try await self.engine.setLCCCrop(plan, enabled: enabled, cancellation: self.cancellation)
            self.plan = updated; self.manifest = nil
            self.frame = try await self.engine.frame(updated, hdr: self.hdr)
        }
    }
    func createProfile(name: String, frames: [LCCCreationFrame], sensor: SensorSize) {
        run("Creating lens profile") {
            try await self.engine.createProfile(name: name, frames: frames, sensor: sensor, cancellation: self.cancellation, progress: self.report)
            self.profiles = try await self.engine.profiles()
        }
    }
    func export(_ settings: MobileExportSettings) {
        let photo = active, edit = edit, plan = plan, manifest = manifest
        run("Exporting") {
            self.output = try await self.engine.export(photo: photo, edit: edit, plan: plan, manifest: manifest,
                settings: settings, cancellation: self.cancellation, progress: self.report)
            try await self.reload(); self.warmThumbnails()
        }
    }
    func memoryWarning() {
        previewTask?.cancel(); thumbnailTask?.cancel(); thumbnails.removeAll()
        Task { await engine.releaseWorkingMemory() }
    }
}
#endif
