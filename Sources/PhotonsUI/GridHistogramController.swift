import AppKit
import PhotonsCore
import PhotonsCatalog

/// Grid selection publishes a small cached value, independently of the loupe's render lifecycle.
@MainActor
public final class GridHistogramController {
    private weak var session: CatalogSession?
    private let headroom: @MainActor () -> Double
    private let bridge = ObservationBridge()
    private var observers: [NSObjectProtocol] = []
    private var provider: ThumbnailProvider?
    private var requested: HistogramCacheKey?
    private var generation = 0
    private var libraryCache: ThumbnailCache?
    private var backfillCount = -1
    private var editGeneration = 0

    public init(session: CatalogSession, headroom: @escaping @MainActor () -> Double = { DisplayHeadroom.current(for: NSScreen.main).headroom }) {
        self.session = session; self.headroom = headroom
        bridge.observe({ [weak session] in
            _ = session?.anchorID; _ = session?.loadedEditAssetID; _ = session?.mode
            _ = session?.editRevision; _ = session?.thumbnailCache; _ = session?.assets.count
        }, { [weak self] in self?.modelChanged() })
        for name in [Notification.Name.photonsHistogramCached, .photonsPreferencesDidChange, .highlightCeilingDidChange,
                     .NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification,
                     NSApplication.didBecomeActiveNotification, NSWindow.didChangeScreenNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] notification in MainActor.assumeIsolated {
                    guard let self else { return }
                    if notification.name == .highlightCeilingDidChange { self.modelChanged(); return }
                    if notification.name == .photonsHistogramCached {
                        guard let cache = notification.object as? HistogramCache,
                              cache === self.provider?.histograms.cache,
                              let key = notification.userInfo?["key"] as? HistogramCacheKey,
                              key.content == self.session?.anchorAsset?.contentHash else { return }
                    }
                    self.refresh(allowRequest: false)
                    self.provider?.histograms.resumeBackfill()
                }
            })
        }
        modelChanged()
    }
    deinit {
        bridge.cancel()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    private func modelChanged() {
        guard let session else { return }
        if libraryCache !== session.thumbnailCache {
            libraryCache = session.thumbnailCache
            provider = session.thumbnailCache.map { ThumbnailProvider.shared(for: $0) }
            backfillCount = -1; requested = nil; generation += 1
        }
        if backfillCount != session.assets.count {
            backfillCount = session.assets.count
            provider?.histograms.backfillExistingPreviews(session.assets)
        }
        provider?.histograms.resumeBackfill()
        requested = nil; generation += 1
        editGeneration += 1
        let revision = editGeneration
        // Cached selections show immediately. Misses/edits settle before any preview work starts.
        refresh(allowRequest: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.editGeneration == revision else { return }
            self.refresh()
        }
    }

    public func refresh(allowRequest: Bool = true) {
        guard let session, session.mode == .grid, let asset = session.anchorAsset,
              session.loadedEditAssetID == asset.id, let provider else { return }
        let document = session.edit
        let key = HistogramCacheKey(thumbnail: ThumbnailProvider.hdJPEGKey(for: asset, document: document))
        if requested != nil && requested != key { requested = nil; generation += 1 }
        if let hit = provider.histograms.cache.cached(key) {
            session.recordHistogram(hit.histogram(hdr: ProcessingPreferences.hdrPreview, headroom: headroom()))
            return
        }
        guard allowRequest, requested != key else { return }
        requested = key; generation += 1
        let ticket = generation
        provider.histograms.request(asset: asset, source: session.fileURL(for: asset), document: document) {
            [weak self, weak session] snapshot in
            guard let self, let session, ticket == self.generation else { return }
            if snapshot != nil { self.requested = nil }
            guard
                  session.mode == .grid, session.anchorID == asset.id,
                  self.provider === provider,
                  HistogramCacheKey(thumbnail: ThumbnailProvider.hdJPEGKey(for: asset, document: session.edit)) == key
            else { return }
            if let snapshot {
                session.recordHistogram(snapshot.histogram(hdr: ProcessingPreferences.hdrPreview, headroom: self.headroom()))
            }
        }
    }
}
