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
    /// 491 — the camera is quantized before it enters the key (zoom 1e-3, centre 0.1 px). Off makes
    /// 「同一视图两次构造键相等」red: two readings of one view can differ in the last ulp and would
    /// otherwise be two keys and a guaranteed miss.
    public nonisolated(unsafe) static var quantizesCanvasCamera = true
    /// 491 — the document digest names only fields that reach the pixels. Off makes 「同一文档两次
    /// 构造键相等」red for a document whose *selection cursor* moved (a point-colour swatch).
    public nonisolated(unsafe) static var canonicalizesCanvasEditDigest = true
    /// 542 — a coarser resident canvas may answer a sharper request when the ladder no longer holds
    /// the photo (B → A evicts A's rung, so the prediction becomes 1.0). Off restores the exact-rung
    /// rule and makes the return-to-A test red.
    public nonisolated(unsafe) static var acceptsCoarserRung = true
    /// 542 — the floor for that tolerance: `entryScale / requestedScale` must be at least this.
    /// 0.5 accepts 「0.5 的缓存帧回答 1.0 的请求」; 0.25 vs 1.0 is visibly blurry and must miss so the
    /// 533 stand-in (or the fresh frame) is used instead of pretending.
    public nonisolated(unsafe) static var coarserRungFloor = 0.5

    public enum Regime: String, Sendable {
        case browsing
        case editing
    }

    /// 458 — why a lookup missed. 「没存」and「存了但没读上」were indistinguishable before this;
    /// a miss now names the component that moved.
    public enum MissReason: String, CaseIterable, Sendable, Hashable {
        /// No entry names this photo at all (a first visit, or the table was just released).
        case noEntryForPhoto
        /// The entry is the right canvas, but the display renders it in another primaries. **Headroom
        /// is not a reason any more** (544): the panel's bound is applied by the present pass, so one
        /// texture serves every headroom. Never served on a primaries move: clearing the table is the
        /// honest answer.
        case displayChanged
        /// `decodeInputs` (white balance/detail/decoder), `editDigest` or `geometry` moved.
        case documentChanged
        /// `LoupeViewState` (mode/zoom/centre) moved.
        case cameraChanged
        /// The canvas, fit multiplier, role, crop/warning flag or highlight ceiling moved.
        case canvasChanged
        /// The entry was rendered from another rung than the one this job predicts.
        case decodeScaleChanged
        /// 542 — the entry is **coarser** than the requested rung but still usable (same canvas, at
        /// least `coarserRungFloor` of the requested scale). Counted on the **hit**, not on a miss:
        /// 「命中一次记一次，不许静默」. The frame goes on screen immediately and the fresh render
        /// still runs, so this also names how often the user was served the older rung first.
        case coarserRung
    }

    /// One counter per `MissReason`. A struct (not a dictionary) so the diagnostics line has a
    /// stable spelling and a test can subscript it by case.
    public struct MissReasons: Equatable, Sendable {
        private var counts: [MissReason: Int] = [:]

        public init() {}

        public subscript(reason: MissReason) -> Int {
            get { counts[reason] ?? 0 }
            set { counts[reason] = newValue }
        }

        public var total: Int { counts.values.reduce(0, +) }

        mutating func record(_ reason: MissReason) { counts[reason, default: 0] += 1 }
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
        /// The live display headroom when the frame was rendered.
        ///
        /// 458 — kept for the 434 key-completeness contract. 544 — **not** part of `softIdentity` and
        /// no longer compared by `lookup`: the panel's bound moved to the present pass, so two
        /// headrooms are the same canvas.
        public let headroom: Double
        /// The rung the frame was rendered from. Not in the dispatch list, but two rungs of the same
        /// photo are two different resamplings of the canvas and must never alias.
        ///
        /// 458 — same soft-key treatment as `headroom`: the caller predicts, the entry knows.
        public let decodeScale: Double
        /// `OutputPrimaries.rawValue` — the presenter's storage decides the S4 matrix.
        ///
        /// 458 — same soft-key treatment as `headroom`: checked against the entry, not spelled.
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

        /// 439 — the same key, projected from the one place the identity facts are computed.
        ///
        /// 491 — the camera is **quantized** on the way in. `LoupeViewState` is rebuilt while a photo
        /// switches and two readings of "the same view" can differ in the last ulp; spelling that
        /// difference with `%.17g` made two keys and a guaranteed miss even though the canvas was not
        /// moved. 1e-3 of zoom and 0.1 source pixel are below anything the renderer can resolve.
        ///
        /// `quantizeCamera` is opt-in: the golden key test pins the literal spelling of the facts
        /// path, and only the canvas cache wants the snap. `LoupeController.canvasFrameCacheKey` is
        /// the one caller that turns it on.
        public init(facts: LoupeFrameFacts, quantizeCamera: Bool = false) {
            self.init(photo: facts.photo, decodeInputs: facts.decodeInputs,
                      editDigest: facts.editDigest, geometry: facts.geometry,
                      cameraState: quantizeCamera ? Self.quantizedCamera(facts.camera) : facts.camera,
                      viewport: facts.viewport, mode: facts.mode, fitScale: facts.fitScale,
                      canvasRole: facts.canvasRole, cropIsActive: facts.cropIsActive,
                      highlightWarning: facts.highlightWarning, headroom: facts.headroom,
                      decodeScale: facts.decodeScale, primaries: facts.primaries,
                      highlightCeiling: facts.ceiling)
        }

        /// `mode|z=…|cx=…|cy=…` with the three numbers snapped: zoom to 1e-3, centre to 0.1 px.
        /// Anything that does not have that exact shape is kept verbatim (a caller's own spelling).
        static func quantizedCamera(_ token: String) -> String {
            guard quantizesCanvasCamera else { return token }
            let parts = token.split(separator: "|", omittingEmptySubsequences: false)
            guard parts.count == 4 else { return token }
            func value(_ part: Substring) -> Double? {
                let pieces = part.split(separator: "=", maxSplits: 1,
                                        omittingEmptySubsequences: false)
                guard pieces.count == 2 else { return nil }
                return Double(pieces[1])
            }
            guard let zoom = value(parts[1]), let cx = value(parts[2]), let cy = value(parts[3]),
                  zoom.isFinite, cx.isFinite, cy.isFinite else { return token }
            let z = (zoom / 0.001).rounded() * 0.001
            // `-1e-12` snaps to `-0.0`, whose `%.1f` is `-0.0`: normalise both zeros to one spelling.
            var x = (cx / 0.1).rounded() * 0.1
            var y = (cy / 0.1).rounded() * 0.1
            if x == 0 { x = 0 }
            if y == 0 { y = 0 }
            return "\(parts[0])|z=\(String(format: "%.3f", z))"
                + "|cx=\(String(format: "%.1f", x))|cy=\(String(format: "%.1f", y))"
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

        /// 458 — **the soft key**: everything that names *which canvas* it is, minus the display/rung
        /// facts that are verified against the entry instead of spelled twice.
        ///
        /// `primaries` is the live display reading at lookup time, but the stored entry carries the
        /// value the GPU actually rendered under; `lookup` compares them with the entry. The rung is
        /// the same argument: the caller predicts, the entry knows.
        ///
        /// 544 — `headroom` is no longer a display fact at all: the panel's bound is applied when the
        /// texture is presented, so a 1-ulp screen reading cannot make a canvas miss. The trailing
        /// `hm=present` token retires entries written before the clamp moved (their pixels were
        /// clamped at the old reading and mean something else).
        public var softIdentity: String {
            "\(photo)|\(decodeInputs)|\(editDigest)|\(geometry.isEmpty ? "-" : geometry)"
                + "|\(cameraState)|\(viewport.width)x\(viewport.height)|\(mode)"
                + "|fit=\(Self.number(fitScale))|role=\(canvasRole)"
                + "|crop=\(cropIsActive ? 1 : 0)|warn=\(highlightWarning ? 1 : 0)"
                + "|ceil=\(Self.number(highlightCeiling))|hm=present"
        }
    }

    /// 491 — the document with every field the renderer does not read at the pixels removed.
    ///
    /// `Histogram.editDigest` encodes the whole `EditModel`, including two things that never reach a
    /// texel: `PointColorSet.active` (which swatch the sliders edit — 「选择不改变图像」, its own
    /// documentation says so) and `forwardCompatVersion` (the notice's number). Spelling those in the
    /// canvas key made "pick another swatch, switch away and back" a `.documentChanged` miss.
    public static func pixelCanonicalEdit(_ edit: EditModel) -> EditModel {
        guard canonicalizesCanvasEditDigest else { return edit }
        var out = edit
        out.forwardCompatVersion = nil
        // 555 — the **policy** is not a pixel fact, but `resolvedDecoderVersion` is: it names the
        // spelling that produced this buffer. Neutralise only the policy, exactly as the ticket asks;
        // two documents that resolve to the same spelling then share a canvas digest, while a macOS
        // upgrade that resolves differently still misses (the buffer really is different).
        out.decoderVersionPolicy = .auto
        if var point = out.color.point {
            point.active = nil
            out.color.point = point
        }
        return out
    }

    /// `Histogram.editDigest(pixelCanonicalEdit(edit))` — one spelling, used by the writer, the
    /// reader and the edit-landed hook so the three can never disagree.
    public static func pixelEditDigest(_ edit: EditModel) -> String {
        Histogram.editDigest(pixelCanonicalEdit(edit))
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
    /// 458 — misses by component.
    public private(set) var missReasons = MissReasons()
    /// 458 — set by `invalidateForDisplayChange` (now a **primaries** move only, 544); the next
    /// lookup attributes its miss to the display move even though the table is already empty.
    private var displayChangePending = false
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

    /// 458 — the display-agnostic peek: the same canvas whatever headroom/primaries/rung it was
    /// stored under. Diagnostic only, like `cachedCanvas(for:)`.
    public func cachedCanvas(matching key: Key) -> CachedCanvas? {
        entries.first { $0.key.softIdentity == key.softIdentity }?.value
    }

    /// `hits` means 「这次上屏早于解码」, not 「省了一次解码」 (口径修正 2026-11-19 18:1x): a hit is
    /// presented immediately and the scheduled render still runs.
    ///
    /// 458 — matching is **soft key + hard display/rung check**. The caller passes the display facts
    /// it is about to present under; the entry must have been rendered under exactly those values
    /// (exact for the primaries and rung). 544 — **headroom is ignored**: it is a present-time bound,
    /// not a property of the texture, so a drifting screen reading keeps the entry. A miss is counted,
    /// the component that moved is named, and the entry is left alone (the next store replaces it).
    ///
    /// 542 — an **exact** rung is still preferred, but a coarser one under the same `softIdentity` is
    /// accepted when it is at least `coarserRungFloor` of the requested scale. Returning to a photo
    /// evicts its rung from the one-photo decode ladder, so the caller predicts the full rung even
    /// though the screen frame it cached was the 0.5 preview: that frame is still the right picture
    /// and is presented now, then upgraded by the full rung that follows (535's write rule). The hit
    /// is not silent — it is recorded in `missReasons[.coarserRung]`.
    public func lookup(_ key: Key, headroom: Double? = nil,
                       primaries: OutputPrimaries? = nil,
                       decodeScale: Double? = nil) -> CachedCanvas? {
        currentPhoto = key.photo
        let requestedPrimaries = primaries
            ?? OutputPrimaries(rawValue: key.primaries) ?? .displayP3
        let requestedScale = Float(decodeScale ?? key.decodeScale)

        let matching = entries.indices.filter { entries[$0].key.softIdentity == key.softIdentity }
        if let first = matching.first {
            // Exact: same display facts and the rung the caller predicted.
            if let index = matching.first(where: {
                entries[$0].value.primaries == requestedPrimaries
                    && entries[$0].value.decodeScale == requestedScale
            }) {
                displayChangePending = false
                hits += 1
                let entry = entries.remove(at: index)
                entries.append(entry)                  // most recently used is last
                return entry.value
            }
            // 542 — coarser but usable: the sharpest entry at or below the request, never below the
            // floor. (One entry per soft identity today; the `max` keeps the rule honest if that
            // ever changes.)
            if Self.acceptsCoarserRung, requestedScale > 0,
               let index = coarserCandidate(matching, requested: requestedScale,
                                            primaries: requestedPrimaries) {
                displayChangePending = false
                hits += 1
                missReasons.record(.coarserRung)
                let entry = entries.remove(at: index)
                entries.append(entry)
                return entry.value
            }
            let entry = entries[first]
            let displayMatches = entry.value.primaries == requestedPrimaries
            let scaleMatches = entry.value.decodeScale == requestedScale
            misses += 1
            if !displayMatches { missReasons.record(.displayChanged) }
            if !scaleMatches { missReasons.record(.decodeScaleChanged) }
            return nil
        }

        misses += 1
        if displayChangePending {
            displayChangePending = false
            missReasons.record(.displayChanged)
        } else if let closest = entries.first(where: { $0.key.photo == key.photo }) {
            missReasons.record(Self.missReason(entryKey: closest.key, requested: key))
        } else {
            missReasons.record(.noEntryForPhoto)
        }
        return nil
    }

    /// 542 — the best same-canvas entry that is no sharper than the request and no coarser than
    /// `coarserRungFloor` of it. `nil` when only a blurrier (or a different-display) entry exists.
    private func coarserCandidate(_ indices: [Int], requested: Float,
                                  primaries: OutputPrimaries) -> Int? {
        var best: Int?
        for index in indices {
            let entry = entries[index]
            guard entry.value.primaries == primaries else { continue }
            let scale = entry.value.decodeScale
            guard scale <= requested,
                  Double(scale) >= Double(requested) * Self.coarserRungFloor else { continue }
            if let current = best {
                if scale > entries[current].value.decodeScale { best = index }
            } else {
                best = index
            }
        }
        return best
    }

    /// Which component of a same-photo key moved. The display/rung components never reach here: they
    /// are excluded from `softIdentity` and checked against the entry instead.
    private static func missReason(entryKey: Key, requested: Key) -> MissReason {
        if entryKey.decodeInputs != requested.decodeInputs
            || entryKey.editDigest != requested.editDigest
            || entryKey.geometry != requested.geometry {
            return .documentChanged
        }
        if entryKey.cameraState != requested.cameraState { return .cameraChanged }
        return .canvasChanged
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
        // 491 — the real frame that follows a cache hit is the **same canvas**: the key already says
        // every pixel input matched, so replacing the copy would only pay a second 32 MB blit and
        // turn 「每张一次」into one store per visit. Keep the copy; the settled counter still advances.
        if entries.contains(where: { $0.key == key }) {
            displayChangePending = false
            return true
        }
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
        // 458 — one canvas has one entry. Replacing by the **soft** identity evicts a variant stored
        // under a display reading that was never notified (a silent EDR/primaries move): the new
        // frame's display facts are the only ones that may be served from now on.
        //
        // 535 — the same replacement is how a preview rung gives way to the full rung of the same
        // camera (the screen frame is written first, the sharper one later). That is **one** logical
        // canvas, not two entries, so `stores` counts the entry's creation and not each blit.
        let replacingExisting = entries.contains { $0.key.softIdentity == key.softIdentity }
        if let existing = entries.firstIndex(where: { $0.key.softIdentity == key.softIdentity }) {
            entries.remove(at: existing)
        }
        entries.append(Entry(key: key, value: value))
        if !replacingExisting { stores += 1 }
        displayChangePending = false
        enforceCapacity()
        return true
    }

    /// The whole table goes (the loupe closed, another library opened). Counters survive: "how many
    /// hits did this session see" is a session fact, not a fact about the picture on screen.
    public func cleanup() {
        entries.removeAll()
        currentPhoto = nil
        displayChangePending = false
    }

    /// 458 — primaries moved: **clear, do not approximate**. A tolerance match between the stored
    /// matrix's pixels and the live display's primaries is exactly how a canvas rendered for one
    /// display gets served on another; an empty table costs one development, a wrong pixel costs the
    /// user's trust.
    ///
    /// 544 — **headroom is not a reason to call this any more.** The panel's bound is applied by the
    /// present pass from the live reading, so one texture serves every headroom.
    public func invalidateForDisplayChange() {
        // Only a table that actually held something was invalidated; a cold start's first lookup is
        // 「no entry for this photo」, not a display move.
        let hadEntries = !entries.isEmpty
        entries.removeAll()
        currentPhoto = nil
        displayChangePending = hadEntries || displayChangePending
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
        // **`.shared`, not `.private`** (437). The cache exists to put a frame on screen *early*, and
        // the pointer's readout reads whatever frame is presented — `LoupeController.sample(texture:)`
        // does one `getBytes` of a texel, and that is a CPU read a **private** texture does not have:
        // AGX dereferenced unmapped memory inside `-[AGXG13XFamilyTexture getBytes:…]` and the process
        // died with SIGSEGV on the first mouse move after a cache hit. Apple silicon's memory is
        // unified, so shared costs nothing but the flag here, and the blit below is still the copy.
        descriptor.storageMode = .shared
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
