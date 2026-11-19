import Foundation
import Metal
import PhotonsCore

// MARK: - 434 — the window canvas cache

/// **The canvas frame, kept for a while** (434).
///
/// The user's wording (2026-11-19):
///
/// > 当前修改区域（即窗口画布）的缓存在未有继续编辑前，保留最多 10 张不同照片的窗口缓存。
/// > 开始对照片编辑后，保留最新的三张窗口缓存（含当前正在编辑的），这样多张照片对比时不用一直等重新解 raw 渲染
///
/// This is deliberately **not** a second decode cache. A full-size decode rung is ≈ 483 MB; ten of
/// them is 4.8 GB, which the machine does not have. A canvas frame is the canvas' pixels in
/// `rgba16Float` — 2560 × 1600 is 32.8 MB, ten is ≈ 328 MB — and that is what the user calls
/// 「窗口画布」.
///
/// ### Ownership is the load-bearing rule
///
/// `present` recycles the outgoing frame's texture into the `RenderGraph` pool, and the pool **reuses**
/// that memory for the next render. A cache that kept a reference to `FrameResult.texture` would
/// therefore see its pixels overwritten by an unrelated frame, so every entry here owns a **copy**
/// made with one GPU blit. 32 MB is ≈ 0.2–0.5 ms on the GPU, against 0.5–5 s for a development.
///
/// ### Two regimes
///
///   · **browsing** (default): 10 entries, LRU;
///   · **editing**: 3 entries, entered the first time a document write lands in this session.
///
/// The regime never goes back to browsing by itself. Otherwise 「编辑一下 3、过 10 秒回 10、再编辑」
/// would make the capacity itself a moving target, and every move is an eviction — the exact churn the
/// user asked us not to add. Once edited, this session keeps three.
///
/// The **current photo** is never the eviction victim: what the user is looking at is the one entry
/// they are certain to want on the next switch back.
///
/// All state is main-thread only; the GPU copy is synchronous on the same thread.
public final class CanvasFrameCache {

    // MARK: reverse gates (the acceptance's counter-proofs)

    /// ⑧a — 10 is the browsing capacity. A test may set 9 to make A① red.
    public nonisolated(unsafe) static var browsingCapacity = 10
    /// The editing capacity. 3 is the user's number.
    public nonisolated(unsafe) static var editingCapacity = 3
    /// ⑧b — an edit landing deletes that photo's stale-digest entries. Off makes A⑤ red.
    public nonisolated(unsafe) static var invalidatesOnEdit = true
    /// ⑧d — the current photo's entry is protected from LRU eviction. Off makes A③ red.
    public nonisolated(unsafe) static var protectsCurrentPhoto = true

    public enum Regime: String, Sendable {
        case browsing
        case editing
    }

    /// What a cached canvas is *of*.
    ///
    /// Every component is a fact that reaches the pixels. Equality of `Key` is the claim "these two
    /// present requests must produce byte-for-byte identical canvas pixels"; a component missing here
    /// is a picture from the wrong document/photo/camera drawn as if it were right.
    public struct Key: Equatable, Sendable {
        /// The photo: `contentHash|assetID`, or a harness' frame-source identity.
        public let photo: String
        /// `DecodeInputs.key` — white balance, detail, decoder version.
        public let decodeInputs: String
        /// `Histogram.editDigest(edit)` — the renderer-side document.
        public let editDigest: String
        /// `EditModel.geometryFingerprint` — the spelled geometry (crop/rotation/flip/…).
        public let geometry: String
        /// `LoupeViewState` spelled: mode, zoom, centre.
        public let cameraState: String
        /// The canvas, in device pixels.
        public let viewport: ImageSize
        /// `.edited` / `.original` / `.compare(axis,fraction)`.
        public let mode: String
        /// The crop workspace's fit multiplier.
        public let fitScale: Double
        /// `CanvasRole.rawValue` (`document` / `export`).
        public let canvasRole: String
        /// Whether the crop tool is on (162/258 `neverUpscalesContent`).
        public let cropIsActive: Bool
        /// The clipping-warning grid is drawn into the frame's pixels.
        public let highlightWarning: Bool
        /// S4's ceiling (`DisplayOptions.headroom`).
        public let headroom: Double
        /// The rung the frame was rendered from. Not in the dispatch list, but two rungs of the same
        /// photo are two different resamplings of the canvas and must never alias.
        public let decodeScale: Double
        /// `OutputPrimaries.rawValue` — the presenter's storage decides the S4 matrix.
        public let primaries: String
        /// 320/323 — the highlight ceiling the renderer clamps at (a preference, not a document field).
        public let highlightCeiling: Double

        public init(photo: String, decodeInputs: String, editDigest: String, geometry: String,
                    cameraState: String, viewport: ImageSize, mode: String, fitScale: Double,
                    canvasRole: String, cropIsActive: Bool, highlightWarning: Bool,
                    headroom: Double, decodeScale: Double = 1,
                    primaries: String = OutputPrimaries.displayP3.rawValue,
                    highlightCeiling: Double = HighlightCeiling.current) {
            self.photo = photo
            self.decodeInputs = decodeInputs
            self.editDigest = editDigest
            self.geometry = geometry
            self.cameraState = cameraState
            self.viewport = viewport
            self.mode = mode
            self.fitScale = fitScale
            self.canvasRole = canvasRole
            self.cropIsActive = cropIsActive
            self.highlightWarning = highlightWarning
            self.headroom = headroom
            self.decodeScale = decodeScale
            self.primaries = primaries
            self.highlightCeiling = highlightCeiling
        }

        /// The whole identity in one string. Doubles use `%.17g`: a shortened format would let two
        /// distinct cameras share a key, which is the "old picture" bug this type exists to prevent.
        public var identity: String {
            "\(photo)|\(decodeInputs)|\(editDigest)|\(geometry.isEmpty ? "-" : geometry)"
                + "|\(cameraState)|\(viewport.width)x\(viewport.height)|\(mode)"
                + "|fit=\(Self.number(fitScale))|role=\(canvasRole)"
                + "|crop=\(cropIsActive ? 1 : 0)|warn=\(highlightWarning ? 1 : 0)"
                + "|hr=\(Self.number(headroom))|s=\(Self.number(decodeScale))"
                + "|prim=\(primaries)|ceil=\(Self.number(highlightCeiling))"
        }

        private static func number(_ value: Double) -> String {
            String(format: "%.17g", value.isFinite ? value : 0)
        }
    }

    /// One cached canvas: the texture this type owns plus everything `present` needs to draw it.
    public struct CachedCanvas {
        /// A **copy** of the frame's texture. Never `FrameResult.texture` itself: that one belongs to
        /// the render graph's pool and is reused by later renders.
        public let texture: MTLTexture
        public let canvas: ImageSize
        public let content: ImageSize
        public let photoRect: ImageRect
        public let presentRect: ImageRect
        public let outputWindow: ImageRect?
        public let zoom: Double
        public let decodeScale: Float
        public let primaries: OutputPrimaries
        public let mode: LoupeFrameMode
        public let edit: EditModel
        public let editRevision: Int
        public let headroom: Double
        public let window: ImageSize

        public var pixelSize: ImageSize { ImageSize(width: texture.width, height: texture.height) }
        /// `rgba16Float`: 8 bytes per pixel.
        public var byteCount: Int { texture.width * texture.height * 8 }

        /// The value the one present path takes. Fields no cached frame has (histogram-derived grids,
        /// the hashes, the compare fibres) stay `nil`: the cache is a canvas, not a measurement.
        func frameResult() -> LoupeController.FrameResult {
            LoupeController.FrameResult(
                texture: texture, canvas: canvas, content: content,
                photoRect: photoRect, presentRect: presentRect, outputWindow: outputWindow,
                decodeScale: decodeScale, decodeMilliseconds: 0, renderMilliseconds: 0,
                usedCachedDecode: true, capabilities: nil, primaries: primaries,
                editRevision: editRevision, edit: edit, displayHash: nil,
                zoom: zoom, headroom: headroom, window: window,
                clipped: nil, sceneLinearSample: nil, mode: mode,
                trace: RenderTrace(), whiteBalanceGain: SIMD3<Double>(1, 1, 1),
                frameInCanvas: canvas, frameOrigin: SIMD2<Float>(0, 0),
                expandedCanvas: nil, neverUpscalesContent: false)
        }
    }

    private struct Entry {
        let key: Key
        let value: CachedCanvas
    }

    private var entries: [Entry] = []          // oldest first
    private var currentPhoto: String?
    private let device: MTLDevice?
    private let queue: MTLCommandQueue?

    public private(set) var regime: Regime = .browsing
    public private(set) var hits = 0
    public private(set) var misses = 0
    public private(set) var stores = 0
    public private(set) var evictions = 0
    /// Wall time of the last GPU blit (main thread, including the wait).
    public private(set) var lastBlitMilliseconds: Double = 0

    public init(device: MTLDevice? = nil) {
        let d = device ?? MTLCreateSystemDefaultDevice()
        self.device = d
        self.queue = d?.makeCommandQueue()
    }

    // MARK: asking

    public var capacity: Int {
        regime == .browsing ? Self.browsingCapacity : Self.editingCapacity
    }

    public var count: Int { entries.count }

    public var bytes: Int { entries.reduce(0) { $0 + $1.value.byteCount } }

    public var diagnostics: (capacity: Int, count: Int, bytes: Int, hits: Int, misses: Int,
                             stores: Int, evictions: Int) {
        (capacity, count, bytes, hits, misses, stores, evictions)
    }

    public var isIdle: Bool { true }

    public func contains(_ key: Key) -> Bool {
        entries.contains { $0.key == key }
    }

    /// Read an entry without touching hit/miss/recency — the diagnostic peek tests use.
    public func cachedCanvas(for key: Key) -> CachedCanvas? {
        entries.first { $0.key == key }?.value
    }

    /// `hits` means 「这次上屏早于解码」, not 「省了一次解码」 (口径修正 2026-11-19 18:1x): a hit is
    /// presented immediately and the scheduled render still runs.
    public func lookup(_ key: Key) -> CachedCanvas? {
        currentPhoto = key.photo
        guard let index = entries.firstIndex(where: { $0.key == key }) else {
            misses += 1
            return nil
        }
        hits += 1
        let entry = entries.remove(at: index)
        entries.append(entry)                  // most recently used is last
        return entry.value
    }

    // MARK: writing

    /// An edit landed for `photo`. Its old-digest entries are dead weight (the key can never match
    /// again), and the first edit of the session moves the capacity to 3 for good.
    public func noteEditLanded(photo: String, digest: String) {
        if regime == .browsing { regime = .editing }
        if Self.invalidatesOnEdit {
            entries.removeAll { $0.key.photo == photo && $0.key.editDigest != digest }
        }
        enforceCapacity()
    }

    /// Store a frame. `frame` is only read: the pixels are blitted into a texture this type owns.
    @discardableResult
    func store(_ frame: LoupeController.FrameResult, key: Key) -> Bool {
        guard let copy = copyTexture(frame.texture) else { return false }
        let value = CachedCanvas(texture: copy, canvas: frame.canvas, content: frame.content,
                                 photoRect: frame.photoRect, presentRect: frame.presentRect,
                                 outputWindow: frame.outputWindow, zoom: frame.zoom,
                                 decodeScale: frame.decodeScale, primaries: frame.primaries,
                                 mode: frame.mode, edit: frame.edit,
                                 editRevision: frame.editRevision, headroom: frame.headroom,
                                 window: frame.window)
        // `lookup` names the photo on screen; a store that arrives without one (a direct test
        // seed) names itself.
        if currentPhoto == nil { currentPhoto = key.photo }
        if let existing = entries.firstIndex(where: { $0.key == key }) {
            entries.remove(at: existing)
        }
        entries.append(Entry(key: key, value: value))
        stores += 1
        enforceCapacity()
        return true
    }

    /// The whole table goes (the loupe closed, another library opened). Counters survive: "how many
    /// hits did this session see" is a session fact, not a fact about the picture on screen.
    public func cleanup() {
        entries.removeAll()
        currentPhoto = nil
    }

    private func enforceCapacity() {
        while entries.count > capacity {
            let victim = entries.firstIndex {
                !(Self.protectsCurrentPhoto && $0.key.photo == currentPhoto)
            } ?? 0
            entries.remove(at: victim)
            evictions += 1
        }
    }

    // MARK: the copy

    private func copyTexture(_ source: MTLTexture) -> MTLTexture? {
        guard let device, let queue else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: source.pixelFormat, width: source.width, height: source.height,
            mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .private
        guard let destination = device.makeTexture(descriptor: descriptor),
              let commandBuffer = queue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder() else { return nil }
        let started = CFAbsoluteTimeGetCurrent()
        blit.copy(from: source, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: source.width, height: source.height, depth: 1),
                  to: destination, destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        lastBlitMilliseconds = (CFAbsoluteTimeGetCurrent() - started) * 1000
        return commandBuffer.status == .completed ? destination : nil
    }
}
