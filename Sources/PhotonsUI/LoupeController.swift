import AppKit
import QuartzCore
import CryptoKit
import Metal
import PhotonsCore
import PhotonsCatalog

/// The loupe canvas: a plain `NSView` whose backing layer is a `CAMetalLayer`.
///
/// No `NSScrollView`, no layer zooming, no `MTKView` (research `ui-stack.md` F6: every editor that
/// got 1:1 right re-renders at the new scale). M3 renders `fit` only; `zoomToActualSize()` is the
/// interface M3.5 will fill in.
public final class LoupeCanvasView: NSView {
    public override var isOpaque: Bool { true }
    public override var isFlipped: Bool { true }

    public var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    public init() {
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        // The canvas is the matte-black surface the photo sits on, so a fit photo reads as a photo.
        metalLayer.backgroundColor = NSColor.black.cgColor
        metalLayer.isOpaque = true
    }

    public required init?(coder: NSCoder) { fatalError("no nibs in this app") }

    public override func makeBackingLayer() -> CALayer { CAMetalLayer() }

    public override func layout() {
        super.layout()
        metalLayer.frame = bounds
        let scale = window?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        if metalLayer.drawableSize == .zero {
            metalLayer.drawableSize = CGSize(width: max(1, bounds.width * scale),
                                             height: max(1, bounds.height * scale))
        }
    }

    public override var acceptsFirstResponder: Bool { true }

    /// M3.5: switch the render scale to 1:1 and re-render. Deliberately inert in M3.
    public func zoomToActualSize() {}
}

/// Fits the anchor photo through `RenderGraph` and presents the S4 texture.
///
/// The two-frame ladder is the M3 answer to the 0.5–1 s full-resolution decode: first frame at
/// decode scale 0.5 (fast, blurred by the GPU resample to fit), then the full-resolution decode in
/// the background replaces it. `RenderGraph` is the only renderer, so the loupe, the future
/// thumbnails and export differ only by `scale` and `canvas` (D12).
public final class LoupeController: NSViewController {

    public struct FrameResult {
        public let texture: MTLTexture
        public let canvas: ImageSize
        public let content: ImageSize
        public let decodeScale: Float
        public let decodeMilliseconds: Double
        public let renderMilliseconds: Double
        public let usedCachedDecode: Bool
        public let capabilities: DecoderCapabilities?
        public let primaries: OutputPrimaries
        public let editRevision: Int
        /// SHA-256 of the presented pixels, captured before the texture goes back to the pool.
        /// Only computed when `hashesFrames` is on (it costs a 16-bit readback), which is how
        /// `--ui-smoke` asserts "undo returned to the previous pixels" rather than "a frame arrived".
        public let displayHash: String?
    }

    public let canvasView = LoupeCanvasView()

    private let queue = DispatchQueue(label: "photons.loupe.render", qos: .userInitiated)
    private var presenter: CanvasPresenter?
    private var graph: RenderGraph?
    private var graphIdentity: String?
    private var decoded: LinearImage?
    private var decodedKey: String?
    private var decodedCaps: DecoderCapabilities?
    private var decodeMilliseconds: Double = 0
    private var generation = 0
    private weak var session: CatalogSession?
    private let bridge = ObservationBridge()

    /// `--ui-smoke` turns this off so its synchronous frame does not race the automatic ladder.
    public var autoRenderEnabled = true

    /// Read back every presented frame and hash it. Off by default: a 2560×1600 readback is 32 MB.
    public var hashesFrames = false

    // MARK: edit re-render (slider → frame)

    /// 50 ms: long enough that a 30–120 Hz slider stream collapses into one render, short enough
    /// that the frame still feels attached to the hand.
    public var debounceInterval: TimeInterval = 0.05
    private var editDebounce: DispatchWorkItem?
    /// Single-flight: at most one edit render in the queue. Requests that arrive while it runs are
    /// *collapsed* into one follow-up with the newest document (never queued individually).
    private var editInFlight = false
    private var editPending = false
    private var lastHandledRevision = 0
    public private(set) var editRenderCount = 0
    public private(set) var editRenderCoalesced = 0
    /// Slider tick → new pixels, in ms. Includes the debounce window on purpose.
    public private(set) var editLatencies: [Double] = []
    /// Decode scale the current `decoded` buffer was made at; edit renders reuse it so a slider
    /// never pays for ImageIO again.
    public private(set) var currentDecodeScale: Float = 0.5

    /// Last measured frames — printed by `--ui-smoke` and the 10k bench.
    public private(set) var firstFrameMilliseconds: Double = 0
    public private(set) var secondFrameMilliseconds: Double = 0
    public private(set) var lastFrame: FrameResult?
    public private(set) var lastPresentError: String?

    public init(session: CatalogSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    public required init?(coder: NSCoder) { fatalError("no nibs in this app") }

    public override func loadView() {
        view = canvasView
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        presenter = try? CanvasPresenter()
        if let p = presenter {
            CanvasPresenter.configure(canvasView.metalLayer, storage: p.storage, wantsEDR: false)
        }
        observeModel()
    }

    public override func viewDidLayout() {
        super.viewDidLayout()
        scheduleRender()
    }

    private func observeModel() {
        lastHandledRevision = session?.editRevision ?? 0
        bridge.observe({ [weak self] in
            guard let self else { return }
            _ = self.session?.anchorID
            _ = self.session?.mode
            _ = self.session?.editRevision
        }, { [weak self] in
            guard let self else { return }
            // One observer, two jobs: a document change re-renders the current decode (cheap,
            // ~ms); a photo change needs a new decode (expensive, the 0.5 → 1.0 ladder).
            let revision = self.session?.editRevision ?? 0
            if revision != self.lastHandledRevision {
                self.lastHandledRevision = revision
                self.requestEditRender()
            } else {
                self.scheduleRender()
            }
        })
    }

    // MARK: edit re-render (50 ms debounce, single-flight)

    /// A slider tick landed. Coalesce for `debounceInterval`; if the loupe is not on screen this
    /// costs nothing at all (no decode, no render, no queue entry).
    public func requestEditRender() {
        guard autoRenderEnabled, let session, session.mode == .loupe else { return }
        guard session.anchorAsset != nil else { return }
        editDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.startEditRender() }
        editDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    private func startEditRender() {
        guard autoRenderEnabled, let session, session.mode == .loupe,
              let asset = session.anchorAsset, let url = session.fileURL(for: asset) else { return }
        if editInFlight {
            // Only the newest document survives: the follow-up render reads `session.edit` itself.
            editPending = true
            editRenderCoalesced += 1
            return
        }
        let viewport = viewportPixels
        guard viewport.width > 8, viewport.height > 8 else { return }
        let edit = session.edit
        let changedAt = session.lastEditChangedAt
        let decodeScale = currentDecodeScale
        let gen = generation
        editInFlight = true

        queue.async { [weak self] in
            guard let self else { return }
            do {
                let frame = try self.makeFrame(asset: asset, url: url, viewport: viewport,
                                               decodeScale: decodeScale, edit: edit,
                                               hashPixels: self.hashesFrames)
                DispatchQueue.main.async {
                    guard self.generation == gen else { self.finishEditRender(); return }
                    self.present(frame: frame, renderMilliseconds: frame.renderMilliseconds, isFirst: false)
                    self.editRenderCount += 1
                    if changedAt > 0 {
                        self.editLatencies.append((CFAbsoluteTimeGetCurrent() - changedAt) * 1000)
                    }
                    self.finishEditRender()
                }
            } catch {
                DispatchQueue.main.async {
                    self.lastPresentError = "\(error)"
                    self.finishEditRender()
                }
            }
        }
    }

    private func finishEditRender() {
        editInFlight = false
        guard editPending else { return }
        editPending = false
        // The latest edit wins; no fresh debounce wait, this request is already old enough.
        startEditRender()
    }

    /// Slider→pixels distribution, computed the way the other benches do it (sorted, nearest-rank).
    public func editLatencyPercentiles() -> (p50: Double, p95: Double, count: Int) {
        let sorted = editLatencies.sorted()
        guard !sorted.isEmpty else { return (0, 0, 0) }
        func pct(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))] }
        return (pct(0.5), pct(0.95), sorted.count)
    }

    public func resetEditLatencies() { editLatencies.removeAll() }

    /// One synchronous frame with the given document, on the caller's thread. `--ui-smoke` uses it
    /// to prove pixel-sensitivity without a window animation in the way.
    public func renderEditNow(asset: Asset, url: URL, viewport: ImageSize, decodeScale: Float,
                              edit: EditModel) throws -> FrameResult {
        try makeFrame(asset: asset, url: url, viewport: viewport, decodeScale: decodeScale,
                      edit: edit, hashPixels: true)
    }

    // MARK: rendering

    /// Viewport in device pixels; the metal layer is the owner of that number.
    public var viewportPixels: ImageSize {
        let scale = canvasView.window?.backingScaleFactor ?? 2
        let size = canvasView.bounds.size
        return ImageSize(width: max(1, Int((size.width * scale).rounded())),
                         height: max(1, Int((size.height * scale).rounded())))
    }

    public func scheduleRender() {
        guard autoRenderEnabled else { return }
        guard let session, session.mode == .loupe,
              let asset = session.anchorAsset, let url = session.fileURL(for: asset) else { return }
        let viewport = viewportPixels
        guard viewport.width > 8, viewport.height > 8 else { return }
        generation += 1
        let gen = generation

        // Frame 1: decode 0.5 (fast). Frame 2: full resolution, then re-render into the same fit.
        queue.async { [weak self] in
            guard let self else { return }
            self.pump(asset: asset, url: url, viewport: viewport, decodeScale: 0.5, generation: gen, isFirst: true)
            // Only spend the full-resolution decode if this request is still the current one.
            guard self.generation == gen else { return }
            self.pump(asset: asset, url: url, viewport: viewport, decodeScale: 1.0, generation: gen, isFirst: false)
        }
    }

    /// One decode + one render + one present. Runs on `queue`; only the present hops to main.
    private func pump(asset: Asset, url: URL, viewport: ImageSize, decodeScale: Float,
                      generation gen: Int, isFirst: Bool) {
        let t0 = CFAbsoluteTimeGetCurrent()
        do {
            let frame = try makeFrame(asset: asset, url: url, viewport: viewport, decodeScale: decodeScale)
            let renderMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == gen else { return }
                self.present(frame: frame, renderMilliseconds: renderMs, isFirst: isFirst)
            }
        } catch {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == gen else { return }
                self.lastPresentError = "\(error)"
            }
        }
    }

    /// The whole GPU path for one frame, callable synchronously (ui-smoke uses this).
    ///
    /// `edit` defaults to the live document; passing it explicitly is what makes an edit frame
    /// deterministic (the caller snapshotted the document on the main thread — the render queue
    /// must never read `session.edit` itself and race a slider).
    public func makeFrame(asset: Asset, url: URL, viewport: ImageSize, decodeScale: Float,
                          edit: EditModel? = nil, hashPixels: Bool = false) throws -> FrameResult {
        let model = edit ?? session?.edit ?? .neutral
        // Decode (cached per url+scale, so the second render measures the graph, not ImageIO).
        let key = "\(asset.contentHash)|\(decodeScale)|\(asset.id)"
        var image: LinearImage
        var usedCache = false
        if decodedKey == key, let cached = decoded {
            image = cached
            usedCache = true
        } else {
            let decoder = try RAWDecoder()
            let t0 = CFAbsoluteTimeGetCurrent()
            let outcome = try decoder.decodeDetailed(url, options: DecodeOptions(decoderVersion: nil,
                                                                                exposureEV: 0,
                                                                                scale: decodeScale))
            decodeMilliseconds = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            image = outcome.image
            decoded = image
            decodedKey = key
            decodedCaps = outcome.capabilities
            graph = nil                      // a new source needs a new graph
            graphIdentity = nil
        }
        currentDecodeScale = decodeScale

        let identity = "\(asset.contentHash)-s\(decodeScale)"
        if graph == nil || graphIdentity != identity {
            graph = try RenderGraph(input: RenderInput(image: image, identity: identity))
            graphIdentity = identity
        }
        guard let graph else { throw RenderError.allocationFailed("loupe graph") }

        let fit = min(Double(viewport.width) / Double(image.width),
                      Double(viewport.height) / Double(image.height))
        let scale = min(1.0, max(0.01, fit))
        let primaries: OutputPrimaries = (presenter?.storage ?? .linear16) == .linear16 ? .displayP3 : .sRGB
        let t1 = CFAbsoluteTimeGetCurrent()
        let result = try graph.render(model, options: RenderOptions(
            canvas: viewport,
            scale: scale,
            display: DisplayOptions(primaries: primaries, bitDepth: 8, headroom: 1),
            useCache: true,
            wantsPixels: false))
        let renderMs = (CFAbsoluteTimeGetCurrent() - t1) * 1000
        guard let texture = result.output else { throw RenderError.executeFailed("loupe produced no texture") }
        let hash = hashPixels ? LoupeController.hash(texture) : nil
        let frame = FrameResult(texture: texture, canvas: result.canvas, content: result.content,
                                decodeScale: decodeScale, decodeMilliseconds: decodeMilliseconds,
                                renderMilliseconds: renderMs, usedCachedDecode: usedCache,
                                capabilities: decodedCaps, primaries: primaries,
                                editRevision: session?.editRevision ?? 0, displayHash: hash)
        return frame
    }

    /// SHA-256 of an rgba16f texture's bytes, taken while it is still out of the pool.
    static func hash(_ texture: MTLTexture) -> String {
        let w = texture.width, h = texture.height
        var raw = [UInt16](repeating: 0, count: w * h * 4)
        raw.withUnsafeMutableBytes { buf in
            texture.getBytes(buf.baseAddress!, bytesPerRow: w * 4 * MemoryLayout<UInt16>.size,
                             from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        }
        return raw.withUnsafeBytes { buf in
            let digest = SHA256.hash(data: Data(bytes: buf.baseAddress!, count: buf.count))
            return digest.map { String(format: "%02x", $0) }.joined()
        }
    }

    private func present(frame: FrameResult, renderMilliseconds: Double, isFirst: Bool) {
        guard let presenter else {
            lastPresentError = "no Metal presenter"
            return
        }
        let graphAtFrame = graph
        let ok = presenter.present(frame.texture, in: canvasView.metalLayer, wantsEDR: false) { [weak self] in
            guard let self, let graphAtFrame else { return }
            self.queue.async { graphAtFrame.recycle(output: frame.texture) }
        }
        // The layer refused the 16-bit drawable and fell back to 8-bit sRGB: re-render once with
        // sRGB primaries so the colours match the layer's colour space.
        if presenter.storage == .srgb8, frame.primaries != .sRGB {
            if let graphAtFrame { queue.async { graphAtFrame.recycle(output: frame.texture) } }
            lastPresentError = presenter.lastFailure
            scheduleRender()
            return
        }
        if !ok {
            lastPresentError = presenter.lastFailure
            if let graphAtFrame { queue.async { graphAtFrame.recycle(output: frame.texture) } }
            return
        }
        lastFrame = frame
        lastPresentError = nil
        if isFirst {
            firstFrameMilliseconds = renderMilliseconds
        } else {
            secondFrameMilliseconds = renderMilliseconds
        }
        if let caps = frame.capabilities { session?.recordCapabilities(caps) }
        canvasView.metalLayer.setNeedsDisplay()
        _ = renderMilliseconds
    }

    public var decodeSeconds: Double { decodeMilliseconds / 1000 }
}
