import Foundation
import CoreImage
import PhotonsCore
import PhotonsCatalog
import PhotonsFileAccess

/// Reuses preview production. A legacy cache is backfilled from its tiny PQ preview; a missing
/// preview joins the existing thumbnail queue, so selecting a photo never starts a second decode.
public final class PreviewHistogramService: @unchecked Sendable {
    public let cache: HistogramCache
    weak var provider: ThumbnailProvider?
    private let thumbnails: ThumbnailCache
    private let queue = DispatchQueue(label: "photons.histograms", qos: .utility)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private struct RequestKey: Hashable { let histogram: HistogramCacheKey; let generation: UInt64 }
    private var pending: [RequestKey: [@MainActor (HistogramSnapshot?) -> Void]] = [:]
    private var backfill: [Asset] = []
    private var backfillIndex = 0
    private var backfillScheduled = false

    init(thumbnails: ThumbnailCache) {
        self.thumbnails = thumbnails
        self.cache = HistogramCache(root: thumbnails.root.deletingLastPathComponent()
            .appendingPathComponent("histograms-v1", isDirectory: true))
    }

    public func request(asset: Asset, source: URL?, document: EditModel,
                        completion: @escaping @MainActor (HistogramSnapshot?) -> Void) {
        let generation = cache.generation
        let thumb = ThumbnailProvider.hdJPEGKey(for: asset, document: document)
        let key = HistogramCacheKey(thumbnail: thumb)
        let requestKey = RequestKey(histogram: key, generation: generation)
        if let hit = cache.cached(key) {
            DispatchQueue.main.async { completion(self.cache.generation == generation ? hit : nil) }; return
        }
        queue.async { [weak self] in
            guard let self, self.cache.generation == generation else {
                DispatchQueue.main.async { completion(nil) }; return
            }
            if let hit = self.cache.load(key) {
                DispatchQueue.main.async { completion(self.cache.generation == generation ? hit : nil) }; return
            }
            if self.pending[requestKey] != nil { self.pending[requestKey]?.append(completion); return }
            self.pending[requestKey] = [completion]
            // Reading an existing preview does not require the original file to be online.
            if let data = self.thumbnails.data(for: thumb) {
                self.complete(requestKey, value: self.measurePreview(data, thumb: thumb, generation: generation)); return
            }
            guard let provider = self.provider, let source else { self.complete(requestKey, value: nil); return }
            provider.rememberDocument(document, for: thumb.digest)
            provider.rememberSourceEdge(ThumbnailProvider.sourceLongEdge(of: asset), for: thumb.digest)
            let access = FileAccessStore.shared.access(to: source)
            _ = provider.service.request(ThumbRequestSpec(key: thumb, source: access.url, isBackgroundWarm: true),
                                         priority: .onScreen) { [weak self] result in
                withExtendedLifetime(access) {}
                guard let self else { return }
                self.queue.async {
                    guard self.cache.generation == generation else { self.complete(requestKey, value: nil); return }
                    let value = self.cache.load(key)
                        ?? result.data.flatMap { self.measurePreview($0, thumb: thumb, generation: generation) }
                    self.complete(requestKey, value: value)
                }
            }
        }
    }

    private func complete(_ key: RequestKey, value: HistogramSnapshot?) {
        let callbacks = pending.removeValue(forKey: key) ?? []
        DispatchQueue.main.async { callbacks.forEach { $0(self.cache.generation == key.generation ? value : nil) } }
    }

    func ensurePreview(key: ThumbKey, data: Data, generation: UInt64) {
        guard cache.generation == generation else { return }
        let histogramKey = HistogramCacheKey(thumbnail: key)
        guard cache.cached(histogramKey) == nil else { return }
        queue.async { [weak self] in
            guard let self, self.cache.generation == generation, self.cache.load(histogramKey) == nil else { return }
            _ = self.measurePreview(data, thumb: key, generation: generation)
        }
    }

    private func measurePreview(_ data: Data, thumb: ThumbKey, generation: UInt64) -> HistogramSnapshot? {
        guard cache.generation == generation else { return nil }
        let key = HistogramCacheKey(thumbnail: thumb)
        if let hit = cache.load(key) { return hit }
        guard let cg = ThumbnailProvider.decodeJPEG(data, display: ImageSize(width: 256, height: 256)),
              let space = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020) else { return nil }
        let image = CIImage(cgImage: cg)
        var rgba = [Float16](repeating: 0, count: cg.width * cg.height * 4)
        rgba.withUnsafeMutableBytes { bytes in
            context.render(image, toBitmap: bytes.baseAddress!, rowBytes: cg.width * 8,
                           bounds: image.extent, format: .RGBAh, colorSpace: space)
        }
        let snapshot = HistogramSnapshot(sample: LinearSample(width: cg.width, height: cg.height, rgba: rgba),
                                         canvas: ImageSize(width: cg.width, height: cg.height))
        guard snapshot.isValid else { return nil }
        cache.store(snapshot, for: key, fromPreview: true, generation: generation)
        return snapshot
    }

    /// Existing libraries are filled incrementally using previews already on disk. No blind RAW
    /// scan of a large library. New imports get their counts when their normal previews are built.
    public func backfillExistingPreviews(_ assets: [Asset]) {
        queue.async { [weak self] in
            guard let self else { return }
            self.backfill = assets; self.backfillIndex = 0
            self.scheduleBackfill()
        }
    }
    public func resumeBackfill() { queue.async { [weak self] in self?.scheduleBackfill() } }

    private func scheduleBackfill() {
        guard !backfillScheduled, backfillIndex < backfill.count,
              !ProcessInfo.processInfo.isLowPowerModeEnabled,
              ProcessInfo.processInfo.thermalState != .serious,
              ProcessInfo.processInfo.thermalState != .critical,
              provider?.service.isPaused != true else { return }
        backfillScheduled = true
        queue.asyncAfter(deadline: .now() + 0.04) { [weak self] in
            guard let self else { return }
            self.backfillScheduled = false
            guard self.backfillIndex < self.backfill.count else { return }
            let asset = self.backfill[self.backfillIndex]; self.backfillIndex += 1
            let thumb = ThumbnailProvider.hdJPEGKey(for: asset)
            let generation = self.cache.generation
            if self.cache.load(HistogramCacheKey(thumbnail: thumb)) == nil,
               let data = self.thumbnails.data(for: thumb) { _ = self.measurePreview(data, thumb: thumb, generation: generation) }
            if self.backfillIndex == self.backfill.count { self.backfill.removeAll(); self.backfillIndex = 0 }
            self.scheduleBackfill()
        }
    }
}
