import AppKit
import QuartzCore
import CryptoKit
import Metal
import PhotonsCore
import PhotonsCatalog

/// The loupe canvas: a plain `NSView` whose backing layer is a `CAMetalLayer`.
///
/// No `NSScrollView`, no layer zooming, no `MTKView` (research `ui-stack.md` F6: every editor that
/// got 1:1 right re-renders at the new scale). The view stores **no** view state: it turns events
/// into intents ("toggle", "pan by this many points") and `LoupeController` decides what that means
/// in source pixels. Nothing here scales a layer, and nothing here remembers a zoom.
public final class LoupeCanvasView: NSView {
    public override var isOpaque: Bool { true }
    public override var isFlipped: Bool { true }

    public var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    /// The controller that owns the zoom/pan state. Weak: the controller owns the view.
    public weak var controller: LoupeController?

    /// Where the last drag was, in view points. Only a drag gesture's own scratch space — the
    /// *camera* position lives in the controller, in source pixels.
    private var lastDragPoint: CGPoint = .zero
    private var isDragging = false

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

    // MARK: 1:1 / pan / pinch

    /// Z or space: fit ↔ 1:1. Escape: back to fit.
    public override func keyDown(with event: NSEvent) {
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch key {
        case "z", " ":
            controller?.toggleActualSize()
        case "\u{1b}":
            controller?.zoomToFit()
        default:
            super.keyDown(with: event)
        }
    }

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount == 2 {
            controller?.handleDoubleClick(at: convert(event.locationInWindow, from: nil))
            return
        }
        isDragging = true
        lastDragPoint = event.locationInWindow
    }

    public override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        let delta = CGSize(width: event.locationInWindow.x - lastDragPoint.x,
                           height: event.locationInWindow.y - lastDragPoint.y)
        lastDragPoint = event.locationInWindow
        controller?.panImage(byPoints: delta)
    }

    public override func mouseUp(with event: NSEvent) {
        isDragging = false
    }

    /// Trackpads send two axes; a wheel sends mostly y. Both mean "move the camera", never "scale a
    /// layer" — the controller re-renders the window at the same zoom.
    public override func scrollWheel(with event: NSEvent) {
        controller?.scrollPan(deltaX: event.scrollingDeltaX,
                             deltaY: event.scrollingDeltaY,
                             precise: event.hasPreciseScrollingDeltas)
    }

    public override func magnify(with event: NSEvent) {
        controller?.magnify(by: 1 + event.magnification,
                            at: convert(event.locationInWindow, from: nil))
    }

    /// The interface M3 left inert, now the real thing: 1:1 in the middle of the frame.
    public func zoomToActualSize() { controller?.zoomToActualSize() }

    /// What the cursor should say: a pointing hand only when there is something to drag.
    public override func resetCursorRects() {
        let zoomed = controller?.viewState.isActualSize ?? false
        addCursorRect(bounds, cursor: zoomed ? .openHand : .arrow)
    }
}

/// Fits or zooms the anchor photo through `RenderGraph` and presents the S4 texture.
///
/// Two ladders live here, both keyed on `LoupeViewState` (a camera position in **source pixels**):
///
///   · **fit** — the M3 ladder unchanged: a 0.5 decode renders immediately, the full-resolution
///     decode replaces it.
///   · **1:1 and beyond** — one frame at the full decode, with the visible window expressed as a
///     derived crop rect (`LoupeFraming.zoomedEdit`). Panning and pinching re-render that window;
///     they never scale the layer. A pan frame is a stage-cache miss by construction (the crop is
///     part of the key chain), which is the honest cost of `D12`: one renderer, one path.
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
        /// Canvas pixels per source pixel this frame was rendered at (1 = 1:1).
        public let zoom: Double
        /// The S4 ceiling this frame was rendered with (`DisplayOptions.headroom`).
        public let headroom: Double
        /// The visible window in source pixels.
        public let window: ImageSize
    }

    /// One frame's cost, in milliseconds, as measured on the render queue.
    public struct FrameTimings: Sendable {
        public var decode: Double
        public var render: Double
        /// Hand-off to the layer (encoding + commit), not GPU completion.
        public var present: Double
        public var total: Double
        public var decodeScale: Float
        public var zoom: Double
        public var window: ImageSize
    }

    // MARK: views

    public let canvasView = LoupeCanvasView()
    private let container = NSView()
    private let statusChip = LoupeStatusChip()

    // MARK: render plumbing

    private let queue = DispatchQueue(label: "photons.loupe.render", qos: .userInitiated)
    private var presenter: CanvasPresenter?
    private var graph: RenderGraph?
    private var graphIdentity: String?
    private var decoded: LinearImage?
    private var decodedScale: Double = 0.5
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

    // MARK: camera (fit / 1:1 / pan / pinch)

    /// Where the loupe is looking, in source pixels. The only view-state this type keeps.
    public private(set) var viewState = LoupeViewState.fit
    /// What the window's screen can do; `headroom` is what S4 clamps at.
    public private(set) var displayHeadroom = DisplayHeadroom.sdr
    /// Set while the canvas layer is actually carrying extended-range values.
    public private(set) var wantsExtendedDynamicRange = false

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

    // Pan/zoom single-flight: a drag emits 60–120 events/s, a window frame costs more than that.
    private var viewInFlight = false
    private var viewPending = false
    /// How many pan/pinch requests were folded into a later frame (the never-a-backlog counter).
    public private(set) var viewRenderCoalesced = 0
    public private(set) var viewRenderCount = 0

    /// Last measured frames — printed by `--ui-smoke` and the 10k bench.
    public private(set) var firstFrameMilliseconds: Double = 0
    public private(set) var secondFrameMilliseconds: Double = 0
    public private(set) var lastFrame: FrameResult?
    public private(set) var lastTimings: FrameTimings?
    public private(set) var lastPresentError: String?

    public init(session: CatalogSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    public required init?(coder: NSCoder) { fatalError("no nibs in this app") }

    deinit {
        for token in screenTokens { NotificationCenter.default.removeObserver(token) }
    }

    // MARK: lifecycle

    public override func loadView() {
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        canvasView.frame = container.bounds
        canvasView.autoresizingMask = [.width, .height]
        canvasView.controller = self
        container.addSubview(canvasView)
        container.addSubview(statusChip)
        view = container
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        presenter = try? CanvasPresenter()
        if let p = presenter {
            CanvasPresenter.configure(canvasView.metalLayer, storage: p.storage, wantsEDR: false)
        }
        observeModel()
        observeScreenChanges()
        refreshDisplay()
    }

    public override func viewDidAppear() {
        super.viewDidAppear()
        refreshDisplay()
    }

    public override func viewDidLayout() {
        super.viewDidLayout()
        layoutStatusChip()
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

    // MARK: display / EDR (screen by screen, with degradation)

    private var screenTokens: [NSObjectProtocol] = []

    /// Two signals: the window moved to another screen, and the screen set itself changed
    /// (brightness, HDR mode, a display plugged in). Both can move the EDR budget, so both re-read.
    private func observeScreenChanges() {
        let center = NotificationCenter.default
        screenTokens.append(center.addObserver(forName: NSWindow.didChangeScreenNotification,
                                              object: nil, queue: .main) { [weak self] note in
            guard let self, let window = self.view.window else { return }
            guard (note.object as? NSWindow) === window else { return }
            self.refreshDisplay()
        })
        screenTokens.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                              object: nil, queue: .main) { [weak self] _ in
            self?.refreshDisplay()
        })
    }

    /// Re-read the screen's EDR budget and apply it to the layer. A no-op when nothing moved, so a
    /// notification storm cannot turn into a render storm.
    public func refreshDisplay() {
        let screen = view.window?.screen ?? NSScreen.main
        let layerAcceptsEDR = (presenter?.storage ?? .linear16) == .linear16
        let next = DisplayHeadroom.current(for: screen, layerAcceptsEDR: layerAcceptsEDR)
        if next == displayHeadroom { return }
        setDisplayHeadroom(next)
    }

    /// Apply display facts explicitly (the screen observer, and the tests that need a chosen
    /// headroom). A new budget is new pixels — `headroom` is in the display key chain.
    public func setDisplayHeadroom(_ next: DisplayHeadroom) {
        guard next != displayHeadroom else { return }
        displayHeadroom = next
        applyLayerEDR()
        updateStatusChip()
        if lastFrame != nil || autoRenderEnabled { scheduleRender() }
    }

    private func applyLayerEDR() {
        guard let presenter else { return }
        wantsExtendedDynamicRange = displayHeadroom.isHDR && presenter.storage == .linear16
        // The canvas contract in one call (§11.8 item 3): 16-bit float drawable +
        // `wantsExtendedDynamicRangeContent` + the extended-range colour space.
        CanvasPresenter.configure(canvasView.metalLayer,
                                  storage: presenter.storage,
                                  wantsEDR: wantsExtendedDynamicRange)
    }

    /// The headroom the *next* frame will be rendered with. `1` whenever EDR is unavailable.
    public var headroom: Double { displayHeadroom.headroom }

    /// What the status strip shows: display class, headroom, and where the camera is.
    public var statusText: String { "\(displayHeadroom.displayText) · \(viewState.zoomLabel)" }

    // MARK: camera state changes

    /// Z / space.
    public func toggleActualSize() {
        if viewState.isActualSize { zoomToFit() } else { zoomToActualSize() }
    }

    /// Fit → 1:1 around the middle of what is on screen. Already zoomed → back to exactly 1:1.
    public func zoomToActualSize() {
        guard let framing = framing() else { return }
        var next = viewState
        next.mode = .actual
        next.zoom = 1
        let centre = framing.visibleCenter(of: viewState)
        next.centerX = centre.x
        next.centerY = centre.y
        setViewState(framing.centering(next, onSource: centre))
    }

    /// Back to the whole frame. Keeps the last centre so Z‑Z returns to where the user was.
    public func zoomToFit() {
        var next = viewState
        next.mode = .fit
        setViewState(next)
    }

    /// Double-click: into 1:1 at the clicked pixel, or back to fit. (Both halves of the brief:
    /// a double-click is the "show me this at full size" gesture, and its inverse when already there.)
    public func handleDoubleClick(at point: CGPoint) {
        guard let framing = framing() else { return }
        if viewState.isActualSize {
            zoomToFit()
            return
        }
        let source = framing.mapping(of: viewState)
            .sourcePoint(viewX: Double(point.x) * backingScale,
                         viewY: Double(point.y) * backingScale)
        var next = viewState
        next.mode = .actual
        next.zoom = 1
        setViewState(framing.centering(next, onSource: source))
    }

    /// Drag pan. `delta` is in view points; the *content* moves with the hand, so the camera moves
    /// the other way — in source pixels, through the straighten rotation.
    public func panImage(byPoints delta: CGSize) {
        guard viewState.isActualSize, let framing = framing() else { return }
        let scale = backingScale
        let content = (x: -Double(delta.width) * scale, y: -Double(delta.height) * scale)
        panBy(contentDelta: content, framing: framing)
    }

    /// Wheel / two-finger scroll. A wheel notch reports ~1 point; a trackpad reports pixels, so the
    /// two are scaled differently instead of one of them feeling like glue.
    public func scrollPan(deltaX: CGFloat, deltaY: CGFloat, precise: Bool) {
        guard viewState.isActualSize, let framing = framing() else { return }
        let factor = precise ? backingScale : backingScale * 12
        let content = (x: -Double(deltaX) * factor, y: -Double(deltaY) * factor)
        panBy(contentDelta: content, framing: framing)
    }

    private func panBy(contentDelta: (x: Double, y: Double), framing: LoupeFraming) {
        let next = framing.panning(viewState, byContent: contentDelta)
        guard next != viewState else { return }
        setViewState(next)
    }

    /// Trackpad pinch: zoom about the cursor, 1…8, re-rendered at the new scale.
    public func magnify(by factor: CGFloat, at point: CGPoint) {
        guard let framing = framing(), factor.isFinite, factor > 0 else { return }
        let target = (viewState.isActualSize ? viewState.zoom : 1) * Double(factor)
        // Below 1:1 there is only fit, so pinching in means "show me the whole frame" — the same
        // destination as Z and the second half of a double-click.
        if target < LoupeViewState.minimumZoom {
            if viewState.isActualSize { zoomToFit() }
            return
        }
        let base = viewState.isActualSize ? viewState : LoupeViewState(
            mode: .actual, zoom: 1,
            centerX: framing.visibleCenter(of: viewState).x,
            centerY: framing.visibleCenter(of: viewState).y)
        let next = framing.zooming(base, to: target, aroundView: point, backingScale: backingScale)
        setViewState(next)
    }

    private func setViewState(_ next: LoupeViewState) {
        guard next != viewState else { return }
        viewState = next
        updateStatusChip()
        view.window?.invalidateCursorRects(for: canvasView)
        requestViewportRender()
    }

    private var backingScale: Double {
        Double(canvasView.window?.backingScaleFactor ?? 2)
    }

    /// The projection for the *current* decode buffer (or the asset's own size before the first
    /// decode lands). Hit-testing must work before the first frame: a double-click queues one.
    public func framing(viewport: ImageSize? = nil) -> LoupeFraming? {
        let size = viewport ?? viewportPixels
        let edit = session?.edit ?? .neutral
        if let image = decoded {
            return LoupeFraming(viewport: size,
                                decoded: ImageSize(width: image.width, height: image.height),
                                decodeScale: decodedScale,
                                edit: edit)
        }
        if let asset = session?.anchorAsset, let w = asset.width, let h = asset.height, w > 0, h > 0 {
            return LoupeFraming(viewport: size,
                                decoded: ImageSize(width: w, height: h),
                                decodeScale: 1,
                                edit: edit)
        }
        return nil
    }

    /// Source pixel under a view point (points, y down). Exposed for the round-trip test and for the
    /// inspector's future "read pixel here".
    public func sourcePoint(forViewPoint point: CGPoint) -> (x: Double, y: Double)? {
        guard let framing = framing() else { return nil }
        let p = framing.mapping(of: viewState)
            .sourcePoint(viewX: Double(point.x) * backingScale, viewY: Double(point.y) * backingScale)
        return (p.x, p.y)
    }

    /// View point (points) of a source pixel.
    public func viewPoint(forSourcePoint source: (x: Double, y: Double)) -> CGPoint? {
        guard let framing = framing() else { return nil }
        let p = framing.mapping(of: viewState).viewPoint(sourceX: source.x, sourceY: source.y)
        return CGPoint(x: p.x / backingScale, y: p.y / backingScale)
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
        // A 1:1 frame must come from the full decode; a fit frame can ride the current rung.
        let decodeScale = viewState.isActualSize ? Float(1) : currentDecodeScale
        let state = viewState
        let gen = generation
        editInFlight = true

        queue.async { [weak self] in
            guard let self else { return }
            do {
                let frame = try self.makeFrame(asset: asset, url: url, viewport: viewport,
                                               decodeScale: decodeScale, edit: edit,
                                               state: state, hashPixels: self.hashesFrames)
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

    // MARK: pan / pinch render loop (single-flight)

    /// A pan/zoom request. Collapsed like the edit path: at most one frame in flight, and the newest
    /// camera wins the follow-up. A drag therefore renders as fast as the GPU allows instead of
    /// building a backlog it would then have to drain after the hand stops.
    public func requestViewportRender() {
        guard autoRenderEnabled, let session, session.mode == .loupe else { return }
        guard session.anchorAsset != nil else { return }
        if viewInFlight {
            viewPending = true
            viewRenderCoalesced += 1
            return
        }
        startViewportRender()
    }

    private func startViewportRender() {
        guard autoRenderEnabled, let session, session.mode == .loupe,
              let asset = session.anchorAsset, let url = session.fileURL(for: asset) else { return }
        let viewport = viewportPixels
        guard viewport.width > 8, viewport.height > 8 else { return }
        let state = viewState
        let edit = session.edit
        let gen = generation
        viewInFlight = true

        queue.async { [weak self] in
            guard let self else { return }
            do {
                // Zoom always samples the full decode: half-resolution pixels magnified 1:1 is the
                // one thing a loupe must never show.
                let frame = try self.makeFrame(asset: asset, url: url, viewport: viewport,
                                               decodeScale: 1.0, edit: edit, state: state,
                                               hashPixels: self.hashesFrames)
                DispatchQueue.main.async {
                    guard self.generation == gen else { self.finishViewRender(); return }
                    self.present(frame: frame, renderMilliseconds: frame.renderMilliseconds, isFirst: false)
                    self.viewRenderCount += 1
                    self.finishViewRender()
                }
            } catch {
                DispatchQueue.main.async {
                    self.lastPresentError = "\(error)"
                    self.finishViewRender()
                }
            }
        }
    }

    private func finishViewRender() {
        viewInFlight = false
        guard viewPending else { return }
        viewPending = false
        startViewportRender()
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
        let state = viewState
        let edit = session.edit

        queue.async { [weak self] in
            guard let self else { return }
            if state.mode == .actual {
                // One frame, full decode: the 0.5 stand-in would be a 2× blow-up of a blur.
                self.pump(asset: asset, url: url, viewport: viewport, decodeScale: 1.0,
                          edit: edit, state: state, generation: gen, isFirst: false)
                return
            }
            // Frame 1: decode 0.5 (fast). Frame 2: full resolution, then re-render into the same fit.
            self.pump(asset: asset, url: url, viewport: viewport, decodeScale: 0.5,
                      edit: edit, state: state, generation: gen, isFirst: true)
            guard self.generation == gen else { return }
            self.pump(asset: asset, url: url, viewport: viewport, decodeScale: 1.0,
                      edit: edit, state: state, generation: gen, isFirst: false)
        }
    }

    /// One decode + one render + one present. Runs on `queue`; only the present hops to main.
    private func pump(asset: Asset, url: URL, viewport: ImageSize, decodeScale: Float,
                      edit: EditModel, state: LoupeViewState, generation gen: Int, isFirst: Bool) {
        let t0 = CFAbsoluteTimeGetCurrent()
        do {
            let frame = try makeFrame(asset: asset, url: url, viewport: viewport,
                                      decodeScale: decodeScale, edit: edit, state: state)
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

    // MARK: frame

    /// The whole GPU path for one frame, callable synchronously (ui-smoke uses this).
    ///
    /// `edit` defaults to the live document; passing it explicitly is what makes an edit frame
    /// deterministic (the caller snapshotted the document on the main thread — the render queue
    /// must never read `session.edit` itself and race a slider).
    public func makeFrame(asset: Asset, url: URL, viewport: ImageSize, decodeScale: Float,
                          edit: EditModel? = nil, state: LoupeViewState? = nil,
                          hashPixels: Bool = false) throws -> FrameResult {
        try makeFrame(url: url,
                      cacheIdentity: "\(asset.contentHash)|\(asset.id)",
                      viewport: viewport, decodeScale: decodeScale,
                      edit: edit ?? session?.edit ?? .neutral,
                      state: state ?? viewState,
                      hashPixels: hashPixels)
    }

    /// Same frame, without a catalog row — what the unit tests and a future import preview use.
    /// `cacheIdentity` only has to be stable per file; anything that changes pixels is in the key
    /// chain already.
    public func makeFrame(url: URL, viewport: ImageSize, decodeScale: Float, edit: EditModel,
                          state: LoupeViewState = .fit,
                          hashPixels: Bool = false) throws -> FrameResult {
        try makeFrame(url: url, cacheIdentity: url.lastPathComponent,
                      viewport: viewport, decodeScale: decodeScale, edit: edit,
                      state: state, hashPixels: hashPixels)
    }

    private func makeFrame(url: URL, cacheIdentity: String, viewport: ImageSize, decodeScale: Float,
                           edit model: EditModel, state: LoupeViewState,
                           hashPixels: Bool) throws -> FrameResult {
        let ds = Double(max(decodeScale, 0.01))
        // Decode (cached per url+scale, so the second render measures the graph, not ImageIO).
        let key = "\(cacheIdentity)|\(decodeScale)"
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
            decodedScale = ds
            decodedCaps = outcome.capabilities
            graph = nil                      // a new source needs a new graph
            graphIdentity = nil
        }
        currentDecodeScale = decodeScale

        let identity = "\(cacheIdentity)-s\(decodeScale)"
        if graph == nil || graphIdentity != identity {
            graph = try RenderGraph(input: RenderInput(image: image, identity: identity, sourceURL: url))
            graphIdentity = identity
        }
        guard let graph else { throw RenderError.allocationFailed("loupe graph") }

        // The camera: a fit frame is the document's own crop; 1:1 and beyond is a source-pixel
        // window, expressed as a derived crop so `RenderGraph` needs no new knob (D12).
        let projected = LoupeFraming(viewport: viewport,
                                     decoded: ImageSize(width: image.width, height: image.height),
                                     decodeScale: ds,
                                     edit: model)
        let renderEdit = projected.zoomedEdit(model, for: state)
        let scale = max(0.01, projected.renderScale(of: state, decodeScale: ds))
        let window = projected.windowPixels(of: state)
        let primaries: OutputPrimaries = (presenter?.storage ?? .linear16) == .linear16 ? .displayP3 : .sRGB
        let ceiling = displayHeadroom.headroom
        let t1 = CFAbsoluteTimeGetCurrent()
        let result = try graph.render(renderEdit, options: RenderOptions(
            canvas: viewport,
            scale: scale,
            display: DisplayOptions(primaries: primaries, bitDepth: 8, headroom: ceiling),
            useCache: true,
            wantsPixels: false))
        let renderMs = (CFAbsoluteTimeGetCurrent() - t1) * 1000
        guard let texture = result.output else { throw RenderError.executeFailed("loupe produced no texture") }
        let hash = hashPixels ? LoupeController.hash(texture) : nil
        return FrameResult(texture: texture, canvas: result.canvas, content: result.content,
                           decodeScale: decodeScale, decodeMilliseconds: decodeMilliseconds,
                           renderMilliseconds: renderMs, usedCachedDecode: usedCache,
                           capabilities: decodedCaps, primaries: primaries,
                           editRevision: session?.editRevision ?? 0, displayHash: hash,
                           zoom: projected.zoom(of: state), headroom: ceiling, window: window)
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
        let t0 = CFAbsoluteTimeGetCurrent()
        let ok = presenter.present(frame.texture, in: canvasView.metalLayer,
                                   wantsEDR: wantsExtendedDynamicRange) { [weak self] in
            guard let self, let graphAtFrame else { return }
            self.queue.async { graphAtFrame.recycle(output: frame.texture) }
        }
        let presentMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        // The layer refused the 16-bit drawable and fell back to 8-bit sRGB: re-render once with
        // sRGB primaries so the colours match the layer's colour space.
        if presenter.storage == .srgb8, frame.primaries != .sRGB {
            if let graphAtFrame { queue.async { graphAtFrame.recycle(output: frame.texture) } }
            lastPresentError = presenter.lastFailure
            // An 8-bit drawable cannot carry values above 1 either: drop the ceiling back to SDR
            // before the next render instead of presenting clipped highlights.
            refreshDisplay()
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
        lastTimings = FrameTimings(decode: frame.decodeMilliseconds,
                                   render: frame.renderMilliseconds,
                                   present: presentMs,
                                   total: frame.decodeMilliseconds + frame.renderMilliseconds,
                                   decodeScale: frame.decodeScale,
                                   zoom: frame.zoom,
                                   window: frame.window)
        if isFirst {
            firstFrameMilliseconds = renderMilliseconds
        } else {
            secondFrameMilliseconds = renderMilliseconds
        }
        if let caps = frame.capabilities { session?.recordCapabilities(caps) }
        canvasView.metalLayer.setNeedsDisplay()
    }

    public var decodeSeconds: Double { decodeMilliseconds / 1000 }

    // MARK: status strip

    private func updateStatusChip() {
        statusChip.text = statusText
        statusChip.tooltip = displayHeadroom.detailText
        layoutStatusChip()
    }

    private func layoutStatusChip() {
        statusChip.layout(in: container.bounds)
    }
}

/// The one-line display readout: `HDR 显示器 · headroom 1.20× · 1:1`.
///
/// It sits *on* the canvas (bottom-left, over the matte) rather than in a status bar the window does
/// not have yet: the fact belongs to this canvas — it is the surface that is or is not extended-range.
final class LoupeStatusChip: NSView {
    private let label = NSTextField(labelWithString: "")

    var text: String {
        get { label.stringValue }
        set {
            guard label.stringValue != newValue else { return }
            label.stringValue = newValue
        }
    }

    var tooltip: String? {
        get { toolTip }
        set { toolTip = newValue }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        layer?.cornerRadius = 5
        label.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
        label.textColor = NSColor.white.withAlphaComponent(0.9)
        label.drawsBackground = false
        label.isBordered = false
        label.isEditable = false
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("no nibs in this app") }

    /// Bottom-left, 10 pt inset, hugging the text. Never participates in the canvas' layout: the
    /// viewport must not shrink because the readout grew a character.
    func layout(in bounds: CGRect) {
        label.sizeToFit()
        let padding = CGSize(width: 7, height: 3)
        let size = CGSize(width: label.frame.width + padding.width * 2,
                          height: label.frame.height + padding.height * 2)
        frame = CGRect(x: bounds.minX + 10,
                       y: bounds.maxY - size.height - 10,
                       width: size.width, height: size.height)
        label.frame = CGRect(x: padding.width, y: padding.height,
                             width: label.frame.width, height: label.frame.height)
    }

    /// The readout is a label, never a hit target: clicks belong to the canvas.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
