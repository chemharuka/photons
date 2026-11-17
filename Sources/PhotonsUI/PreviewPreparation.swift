import Foundation
import PhotonsCore
import PhotonsCatalog
import PhotonsLocalization
import PhotonsFileAccess

/// One background request at a time. On-screen cells join/promote the same preview request;
/// the queue also waits while editing has paused thumbnail production.
@MainActor
final class PreviewPreparation {
    let task: BackgroundTask
    private let provider: ThumbnailProvider
    private let cacheGeneration: UInt64
    private let entries: [(Asset, URL)]
    private let finish: () -> Void
    private var ticket: ThumbTicket?
    private var processed = 0
    private var failures = 0

    init(task: BackgroundTask, provider: ThumbnailProvider, entries: [(Asset, URL)], finish: @escaping () -> Void) {
        self.task = task; self.provider = provider; self.entries = entries; self.finish = finish
        self.cacheGeneration = provider.cache.generation
    }

    func start() { task.state = .running; next() }
    func cancel() {
        guard task.active else { return }
        ticket?.cancel(); ticket = nil
        task.state = .cancelled
        task.message = L10n.tr("a37778f17c5f")
        finish()
    }

    private func next() {
        guard task.active else { return }
        guard provider.cache.generation == cacheGeneration else { cancel(); return }
        task.fraction = Double(processed) / Double(entries.count)
        task.message = L10n.tr("previews.progress", String(processed), String(entries.count))
        BackgroundTasks.shared.changed()
        guard processed < entries.count else {
            task.state = failures == 0 ? .finished : .failed
            if failures > 0 { task.message = L10n.tr("previews.failed", String(failures), String(entries.count)) }
            finish(); return
        }
        let (asset, url) = entries[processed]
        task.message += " · " + asset.filename
        let key = ThumbnailProvider.hdJPEGKey(for: asset)
        provider.rememberDocument(ThumbnailProvider.document(from: asset), for: key.digest)
        provider.rememberSourceEdge(ThumbnailProvider.sourceLongEdge(of: asset), for: key.digest)
        let access = FileAccessStore.shared.access(to: url)
        ticket = provider.service.request(ThumbRequestSpec(key: key, source: access.url, isBackgroundWarm: true), priority: .background) {
            [weak self] result in
            withExtendedLifetime(access) {}
            DispatchQueue.main.async {
                guard let self, self.task.active else { return }
                if let data = result.data {
                    self.provider.histograms.ensurePreview(key: key, data: data, generation: self.cacheGeneration)
                }
                else { self.failures += 1 }
                self.processed += 1; self.ticket = nil
                // Yield to selection/scroll work between files.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.next() }
            }
        }
    }
}
