import AppKit
import QuartzCore
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
        bridge.observe({ [weak self] in
            guard let self else { return }
            _ = self.session?.anchorID
            _ = self.session?.mode
        }, { [weak self] in
            self?.scheduleRender()
        })
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
    public func makeFrame(asset: Asset, url: URL, viewport: ImageSize, decodeScale: Float) throws -> FrameResult {
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
        let result = try graph.render(session?.edit ?? .neutral, options: RenderOptions(
            canvas: viewport,
            scale: scale,
            display: DisplayOptions(primaries: primaries, bitDepth: 8, headroom: 1),
            useCache: true,
            wantsPixels: false))
        let renderMs = (CFAbsoluteTimeGetCurrent() - t1) * 1000
        guard let texture = result.output else { throw RenderError.executeFailed("loupe produced no texture") }
        let frame = FrameResult(texture: texture, canvas: result.canvas, content: result.content,
                                decodeScale: decodeScale, decodeMilliseconds: decodeMilliseconds,
                                renderMilliseconds: renderMs, usedCachedDecode: usedCache,
                                capabilities: decodedCaps, primaries: primaries)
        return frame
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
