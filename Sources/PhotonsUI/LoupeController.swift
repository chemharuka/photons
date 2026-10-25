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

    /// The mask painter, when a brush is armed. Every event still goes through `LoupeController`,
    /// which is the only thing that can turn a view point into a normalised source point; this view
    /// only says *which* of the two gestures a drag is (Q22).
    public weak var maskPainter: MaskCanvasController?

    /// Where the last drag was, in view points. Only a drag gesture's own scratch space — the
    /// *camera* position lives in the controller, in source pixels.
    private var lastDragPoint: CGPoint = .zero
    private var isDragging = false
    private var isPainting = false
    /// A gradient drag: creating a linear/radial mask, or reshaping the selected one.
    private var isShaping = false

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
            // Escape abandons a gradient drag before it becomes a mask, and otherwise means "fit".
            if isShaping { isShaping = false; controller?.cancelShapeDrag() }
            else { controller?.zoomToFit() }
        default:
            super.keyDown(with: event)
        }
    }

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        // A gradient drag is the innermost gesture: it exists only while a shape is armed, and it is
        // what turns two clicks into a linear ramp / an ellipse (or reshapes the selected one).
        if controller?.isShapeDragArmed == true {
            isShaping = true
            controller?.beginShapeDrag(at: point)
            return
        }
        // A paint drag is a paint drag: it never pans, and a double-click while a brush is armed is
        // two dabs rather than a zoom. Turning the tool off is what gives the camera back.
        if maskPainter?.isArmed == true {
            isPainting = true
            controller?.beginPaint(at: point, pressure: Self.pressure(of: event))
            return
        }
        if event.clickCount == 2 {
            controller?.handleDoubleClick(at: point)
            return
        }
        isDragging = true
        lastDragPoint = event.locationInWindow
    }

    public override func mouseDragged(with event: NSEvent) {
        if isShaping {
            controller?.continueShapeDrag(at: convert(event.locationInWindow, from: nil))
            return
        }
        if isPainting {
            controller?.continuePaint(at: convert(event.locationInWindow, from: nil),
                                      pressure: Self.pressure(of: event))
            return
        }
        guard isDragging else { return }
        let delta = CGSize(width: event.locationInWindow.x - lastDragPoint.x,
                           height: event.locationInWindow.y - lastDragPoint.y)
        lastDragPoint = event.locationInWindow
        controller?.panImage(byPoints: delta)
    }

    public override func mouseUp(with event: NSEvent) {
        if isShaping {
            isShaping = false
            controller?.endShapeDrag(at: convert(event.locationInWindow, from: nil))
            return
        }
        if isPainting {
            isPainting = false
            controller?.endPaint()
            return
        }
        isDragging = false
    }

    /// Tablet pressure, or nil. A mouse and a trackpad report a constant 1.0 (so storing it would be
    /// a 300-entry array of ones in every stroke); only `.tabletPoint` events carry a real curve.
    static func pressure(of event: NSEvent) -> Double? {
        event.subtype == .tabletPoint ? Double(event.pressure) : nil
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

    /// What the cursor should say: a crosshair for a brush, a pointing hand only when there is
    /// something to drag.
    public override func resetCursorRects() {
        if controller?.isShapeDragArmed == true {
            // Two clicks will become a gradient: the pointer has to say "draw here".
            addCursorRect(bounds, cursor: .crosshair)
            return
        }
        if maskPainter?.isArmed == true {
            addCursorRect(bounds, cursor: .crosshair)
            return
        }
        let zoomed = controller?.viewState.isActualSize ?? false
        addCursorRect(bounds, cursor: zoomed ? .openHand : .arrow)
    }
}

/// Fits or zooms the anchor photo through `RenderGraph` and presents the S4 texture.
///
/// One ladder, keyed on `LoupeViewState` (a camera position in **source pixels**) and on the
/// *rung* the frame is rendered from (`DecodeLadder`, §11.10):
///
///   · **fit** and **1:1 and beyond** ask the ladder for the same target rung, the full decode; a
///     window (`RenderOptions.outputWindow`) is what makes 1:1 cheap to *render*, and the rung is
///     what makes it expensive to *develop*. Neither is scaled by the layer, and panning re-renders
///     the window — it never moves a layer around.
///   · **The first frame never waits for a development.** If the full rung is not resident yet the
///     ladder hands over the 0.5 rung that is, so 1:1 opens on a magnified preview in one render and
///     the full-resolution frame replaces it when ImageIO is done. That preview is a *stage*, not a
///     steady state: a resident full rung is what every later frame (pan, pinch, edit) renders from.
///
/// **Two queues (Q29).** Developments run on `DecodeQueue`'s own serial queue; frames run on `queue`.
/// A 60 MP development is 800–1400 ms, and while it runs the camera keeps moving: every frame renders
/// from whatever rung the ladder already has (0.5 while the full one is being made), and the moment a
/// bigger rung lands the ladder stores it and **one** replacement frame goes up. A frame never
/// develops, so it is never queued behind ImageIO — which is the difference between "the picture
/// freezes for a second" and "the picture is briefly soft".
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

        /// The frame's own histogram (005f), when `collectsHistogram` asked for it. Measured on the
        /// *same* command buffer and the same pixels the layer is about to show, so the inspector
        /// card updates with the re-render instead of paying for a second one.
        public let histogram: Histogram?
        /// Clipped-pixel grid (the highlight warning's input), when the warning was armed. `nil`
        /// otherwise — the readback only happens when someone is looking at it.
        public let clipped: ClippedGrid?
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

    // MARK: where a frame's pixels come from

    /// A viewport request that does not come from the catalog.
    ///
    /// The shipped path names a photo through `CatalogSession` (an `Asset`, its `contentHash`, the
    /// catalog's file URL). The Q29 bench and the unit tests have no catalog row — they have a file —
    /// and a future import preview would have the same shape. Rather than a second render path (and a
    /// second set of bugs), they hand the loupe this, and `scheduleRender` /
    /// `requestViewportRender` build their job from it instead of the session.
    public struct FrameSource {
        public let url: URL
        /// The ladder key. Anything stable per photo and per file will do; the app uses
        /// `contentHash|assetID`.
        public let identity: String
        public let viewport: ImageSize
        public let state: LoupeViewState
        public let edit: EditModel

        public init(url: URL, identity: String, viewport: ImageSize,
                    state: LoupeViewState = .fit, edit: EditModel = .neutral) {
            self.url = url
            self.identity = identity
            self.viewport = viewport
            self.state = state
            self.edit = edit
        }
    }

    /// When set, frames are made for this URL instead of the session's anchor photo (tests, the
    /// bench, an import preview). `nil` in the app.
    public var frameSource: FrameSource?

    /// Everything one frame needs, snapshotted on the main thread: the render queue must never read
    /// `session` itself (a slider would race it) and the decode queue must never read a view state.
    private struct RenderJob {
        /// Who asked for this frame. It decides which counter it lands in and — the part that is easy
        /// to get wrong — which single-flight flag it is allowed to release: a scheduled frame must not
        /// release a pan's flag, or a second pan frame could start while the first is still rendering
        /// and the newest camera would stop winning.
        enum Kind { case scheduled, view, edit }

        let kind: Kind
        let url: URL
        let identity: String
        let viewport: ImageSize
        let edit: EditModel
        let state: LoupeViewState
        /// The caller's frame generation. `var` because `scheduleRender` bumps the counter *after* it
        /// has decided there is something to draw, and the job it just built has to carry the new one.
        var generation: Int
        /// Only edit frames carry a slider timestamp.
        let changedAt: CFAbsoluteTime

        /// The rung the camera needs. Everything — fit, 1:1, 4:1 — renders from the full buffer: a
        /// window is what makes 1:1 cheap to *render*, and the rung is what makes it expensive to
        /// *develop*. Asking for the biggest rung once is what keeps `fit ↔ 1:1` at one development.
        var target: Float { DecodeLadder.fullScale }
    }

    // MARK: views

    public let canvasView = LoupeCanvasView()
    private let container = NSView()
    private let statusChip = LoupeStatusChip()
    /// The two UI-only overlays. Both are transparent siblings of the `CAMetalLayer`, both refuse
    /// hit tests, and neither is part of a document or of any cache key.
    private let highlightOverlay = HighlightOverlayView()
    private let draftOverlay = MaskDraftOverlayView()

    /// The mask painter: pointer → sampled points → `Stroke` (Q22). Owned here because the paint
    /// gesture is a canvas gesture, and handed to the view so `mouseDown` knows which of the two
    /// gestures a drag is.
    public let maskCanvas: MaskCanvasController

    // MARK: render plumbing

    private let queue = DispatchQueue(label: "photons.loupe.render", qos: .userInitiated)
    /// Developments, on their own serial queue (Q29). Nothing about a frame waits for it: this queue
    /// owns `RAWDecoder`, the render queue owns `RenderGraph`, and the only thing they share is the
    /// ladder's buffers (guarded by its own lock).
    private let decodeQueue = DecodeQueue(label: "photons.loupe.decode")
    private var presenter: CanvasPresenter?
    private var graph: RenderGraph?
    private var graphIdentity: String?
    /// The decoded buffers of the photo on screen, keyed by rung (§11.10). A single `(key, buffer)`
    /// slot here is what made `fit → 1:1 → fit → 1:1` develop the same 60 MP file three times: the
    /// preview rung and the full rung evicted each other, so every visit to either paid ImageIO
    /// again. The ladder keys on (photo, scale) and keeps one photo resident.
    private let ladder = DecodeLadder()
    /// The rung the last presented frame came from — what `framing()` measures and what an edit
    /// frame reuses. `decoded` is the same buffer, kept because hit-testing must not need the queue.
    private var decoded: LinearImage?
    private var decodedScale: Double = 0.5
    private var decodedCaps: DecoderCapabilities?
    private var decodeMilliseconds: Double = 0
    private var generation = 0
    private weak var session: CatalogSession?
    private let bridge = ObservationBridge()

    /// `--ui-smoke` turns this off so its synchronous frame does not race the automatic ladder.
    public var autoRenderEnabled = true

    /// Read back every presented frame and hash it. Off by default: a 2560×1600 readback is 32 MB.
    public var hashesFrames = false

    /// Ask every frame for its histogram (one dispatch in the frame's own command buffer plus the
    /// reduced readback — see `RenderOptions.collectHistogram`). On by default because the inspector
    /// card is always on screen in this build; a bench that wants the pre-005f frame turns it off.
    public var collectsHistogram = true

    /// The last clipping grid the warning produced (nil while the warning is off or before a frame).
    public private(set) var lastClipped: ClippedGrid?
    /// Frames whose histogram reached the session — the smoke asserts it is not a second render.
    public private(set) var histogramPublishCount = 0

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
    /// How many edit renders the debounce actually **started**.
    ///
    /// `editRenderCount` counts frames that reached the screen, which is zero while the decode ladder
    /// has no rung to draw from — a property of the ladder, not of the debounce. "Ten ticks, one
    /// render" is about this counter, and it is what the smoke asserts.
    public private(set) var editRenderStarts = 0
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

    /// True between a `scheduleRender` and the first frame it puts up. A cold open presents nothing
    /// until the preview rung lands (there is no buffer to draw), so "first frame" cannot be "index
    /// 0 of a loop" any more — it is the first frame after a request, whenever that arrives.
    private var awaitingFirstFrame = false
    /// Rungs a development delivered into the ladder, and deliveries that were **not painted**
    /// because the frame (or the photo) they were made for was gone. Both are counters rather than
    /// timings: "an old result never reached the canvas" is a claim about a count.
    public private(set) var rungArrivals = 0
    public private(set) var staleRungDrops = 0
    /// The identity the last `scheduleRender` was for — a photo change cancels the previous photo's
    /// queued developments instead of paying for pixels nobody will see.
    private var pendingIdentity: String?
    /// The rung the last frame that reached the canvas was rendered from. Set when the frame is
    /// *handed over*, before the layer is asked for a drawable: a headless test can still say which
    /// buffer the canvas was given, which is what the acceptance numbers are about.
    public private(set) var lastPresentedScale: Float?

    public init(session: CatalogSession) {
        self.session = session
        self.maskCanvas = MaskCanvasController(session: session)
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
        canvasView.maskPainter = maskCanvas
        container.addSubview(canvasView)
        // Over the canvas, under the readout: the clipping wash and the shape-drag rubber band. Both
        // are `hitTest → nil`, so every click still belongs to the canvas.
        for overlay in [highlightOverlay as NSView, draftOverlay as NSView] {
            overlay.frame = container.bounds
            overlay.autoresizingMask = [.width, .height]
            container.addSubview(overlay)
        }
        container.addSubview(statusChip)
        view = container
        highlightOverlay.isArmed = session?.highlightWarning ?? false
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
                // Leaving the loupe (or switching photo) is a cancellation: a development already
                // running belongs to a picture nobody is looking at, and finishing the next one would
                // steal ImageIO from the one they are. `scheduleRender` no-ops outside the loupe, so
                // this is the only thing that has to run there.
                if self.session?.mode != .loupe { self.cancelPendingFrames() }
                self.scheduleRender()
            }
        })
        // The clipping warning is a display preference, not an edit: it has its own signal, so
        // arming it never looks like a document change to the renderer (`editRevision` stays put).
        bridge.observe({ [weak self] in
            _ = self?.session?.highlightWarningRevision
        }, { [weak self] in
            self?.applyHighlightWarning()
        })
    }

    /// The warning was switched on the session. Nothing in the document moved; the canvas just needs
    /// a frame to read the grid from (the previous texture is already back in the graph's pool).
    private func applyHighlightWarning() {
        let armed = session?.highlightWarning ?? false
        highlightOverlay.isArmed = armed
        if !armed {
            lastClipped = nil
            highlightOverlay.grid = nil
        }
        // One frame, no document change: the same `editRevision`, the same pixels, one readback.
        if armed, autoRenderEnabled { requestViewportRender() }
    }

    public var showsHighlightWarning: Bool { session?.highlightWarning ?? false }

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

    // MARK: the zoom ladder (显示 ▸ 倍率)

    /// The four stops the menu offers, in order. `1` is 1:1; the ceiling is
    /// `LoupeViewState.maximumZoom`, and above 8:1 a 60 MP frame is being shown through 64 canvas
    /// pixels per source pixel — nothing left to reveal.
    public static let zoomStops: [Double] = [1, 2, 4, 8]

    /// Canvas pixels per source pixel the frame is being drawn at — `fit`'s own ratio included, so a
    /// readout can say "0.31:1 (fit)" without a special case.
    public var effectiveZoom: Double { framing()?.zoom(of: viewState) ?? 1 }

    /// "fit" / "1:1" / "2:1" — the number the status chip and the menu tick both use.
    public var zoomLabel: String { viewState.zoomLabel }

    /// The menu stop the camera is exactly on, or nil (fit, or a pinch between stops) — what the
    /// View menu ticks.
    public var currentZoomStop: Double? {
        guard viewState.isActualSize else { return nil }
        let zoom = LoupeViewState.clampZoom(viewState.zoom)
        return LoupeController.zoomStops.first { abs($0 - zoom) < 0.005 }
    }

    /// A menu stop (1 / 2 / 4 / 8): same centre, new scale, one re-render.
    ///
    /// Unlike a pinch this does not need a cursor anchor — the command's subject is the picture in
    /// the window, so the centre is kept and the window shrinks around it.
    public func zoom(to stop: Double) {
        guard let framing = framing() else { return }
        var next = viewState
        next.mode = .actual
        next.zoom = LoupeViewState.clampZoom(stop)
        let centre = framing.visibleCenter(of: viewState)
        next.centerX = centre.x
        next.centerY = centre.y
        setViewState(framing.centering(next, onSource: centre))
    }

    /// ⌘+ / ⌘=: the next stop up, or 8:1 from anything between. From `fit` it lands on 1:1 — the
    /// same destination as Z, because "zoom in from the whole frame" means full size first.
    public func zoomIn() {
        guard viewState.isActualSize else { zoomToActualSize(); return }
        let current = LoupeViewState.clampZoom(viewState.zoom)
        let next = LoupeController.zoomStops.first { $0 > current + 0.005 } ?? LoupeViewState.maximumZoom
        zoom(to: next)
    }

    /// ⌘−: the next stop down, and below 1:1 back to the whole frame (there is no 0.5:1 mode).
    public func zoomOut() {
        guard viewState.isActualSize else { return }
        let current = LoupeViewState.clampZoom(viewState.zoom)
        guard let next = LoupeController.zoomStops.last(where: { $0 < current - 0.005 }) else {
            zoomToFit()
            return
        }
        zoom(to: next)
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

    // MARK: painting (Q22)

    /// View point → normalised **uncropped source** coordinates, which is the space every mask
    /// parameter lives in (§2/§4): the crop, the straighten angle and the flips are undone here, so
    /// the same stroke is the same shape at fit, at 1:1 and at 8:1.
    public func normalizedSourcePoint(forViewPoint point: CGPoint) -> NormalizedPoint? {
        guard let framing = framing() else { return nil }
        let p = framing.mapping(of: viewState)
            .sourcePoint(viewX: Double(point.x) * backingScale,
                         viewY: Double(point.y) * backingScale)
        guard p.x.isFinite, p.y.isFinite else { return nil }
        return NormalizedPoint(p.x / max(framing.sourceWidth, 1), p.y / max(framing.sourceHeight, 1))
    }

    public func beginPaint(at point: CGPoint, pressure: Double? = nil) {
        guard let p = normalizedSourcePoint(forViewPoint: point) else { return }
        maskCanvas.begin(at: p, pressure: pressure)
    }

    public func continuePaint(at point: CGPoint, pressure: Double? = nil) {
        guard let p = normalizedSourcePoint(forViewPoint: point) else { return }
        maskCanvas.extend(to: p, pressure: pressure)
    }

    public func endPaint() {
        maskCanvas.end()
    }

    // MARK: shape masks drawn by hand (linear / radial)

    /// What a drag on the canvas means while a gradient is armed. Two cases, one gesture handler:
    /// a **creation** armed from the inspector's 新建 menu (no mask exists yet), and an
    /// **adjustment** of the selected mask's own geometry.
    private enum ShapeDragMode {
        case create(MaskCreationKind)
        case adjust(maskID: String, component: Int, kind: MaskCreationKind)

        var kind: MaskCreationKind {
            switch self {
            case .create(let kind): return kind
            case .adjust(_, _, let kind): return kind
            }
        }
    }

    /// The drag's first point, in view points and in normalised source coordinates. Both are kept:
    /// the overlay draws in view space, the document is written in source space.
    private var shapeDragStartView: CGPoint?
    private var shapeDragStartSource: NormalizedPoint?

    /// Gestures that landed a new mask / a new geometry, and gestures that were refused because the
    /// drag was shorter than a click (the smoke prints both; a refused gesture is not a failure).
    public private(set) var shapeDragsCreated = 0
    public private(set) var shapeDragsAdjusted = 0
    public private(set) var shapeDragsRefused = 0

    /// True when a drag should draw a gradient instead of panning — what `LoupeCanvasView` asks.
    public var isShapeDragArmed: Bool { shapeDragMode != nil }

    private var shapeDragMode: ShapeDragMode? {
        guard let session, session.anchorAsset != nil else { return nil }
        if let kind = session.pendingMaskShape, kind.isDragCreated { return .create(kind) }
        // An armed brush outranks an armed gradient: if the user picked 画笔, a drag paints — a
        // selected ellipse must not steal the gesture from the tool they just chose.
        guard !session.maskTool.isPainting else { return nil }
        guard session.adjustShapeOnDrag,
              let target = session.selectedAdjustableShape() else { return nil }
        return .adjust(maskID: target.maskID, component: target.component, kind: target.kind)
    }

    public func beginShapeDrag(at point: CGPoint) {
        guard let mode = shapeDragMode,
              let source = normalizedSourcePoint(forViewPoint: point) else { return }
        shapeDragStartView = point
        shapeDragStartSource = source
        draftOverlay.draft = (kind: mode.kind, start: point, current: point)
    }

    public func continueShapeDrag(at point: CGPoint) {
        guard let start = shapeDragStartView, let mode = shapeDragMode else { return }
        draftOverlay.draft = (kind: mode.kind, start: start, current: point)
        // An adjustment follows the hand live (the same rule as a brush stroke: the pixels move
        // while the mouse is down, the history grows once on mouse-up).
        guard case .adjust(let maskID, let component, let kind) = mode,
              let startSource = shapeDragStartSource,
              let end = normalizedSourcePoint(forViewPoint: point) else { return }
        guard let shape = draggedShape(kind: kind, from: startSource, to: end) else { return }
        session?.setMaskComponentShape(maskID, component: component, shape: shape,
                                       commit: false, label: "")
    }

    /// Mouse-up: the geometry becomes the document — **one** commit, so ⌘Z takes the whole gesture
    /// back (for a creation that means the mask itself disappears).
    public func endShapeDrag(at point: CGPoint? = nil) {
        defer {
            shapeDragStartView = nil
            shapeDragStartSource = nil
            draftOverlay.draft = nil
        }
        guard let mode = shapeDragMode, let start = shapeDragStartSource else { return }
        let endPoint = point ?? shapeDragStartView ?? .zero
        guard let end = normalizedSourcePoint(forViewPoint: endPoint),
              let shape = draggedShape(kind: mode.kind, from: start, to: end) else {
            shapeDragsRefused += 1
            // A refused creation must not stay armed forever: the next drag would be refused too.
            if case .create = mode { session?.pendingMaskShape = nil }
            return
        }
        switch mode {
        case .create(let kind):
            if session?.addShapeMask(kind, from: start, to: end) != nil {
                shapeDragsCreated += 1
            } else {
                shapeDragsRefused += 1
            }
        case .adjust(let maskID, let component, let kind):
            session?.setMaskComponentShape(maskID, component: component, shape: shape,
                                           commit: false, label: "")
            session?.commitEdit(label: "调整\(kind.label)蒙版")
            shapeDragsAdjusted += 1
        }
    }

    /// Escape during a shape drag: nothing is written and nothing is committed.
    public func cancelShapeDrag() {
        shapeDragStartView = nil
        shapeDragStartSource = nil
        draftOverlay.draft = nil
    }

    /// The shape a drag means, or nil when it is too short to be one (a click, not a gradient).
    private func draggedShape(kind: MaskCreationKind, from start: NormalizedPoint,
                              to end: NormalizedPoint) -> MaskShape? {
        guard let session else { return nil }
        let source = session.maskSourceSize
        guard MaskDragGeometry.isMeaningful(from: start, to: end, source: source) else { return nil }
        switch kind {
        case .linearGradient:
            return .linearGradient(MaskDragGeometry.linear(from: start, to: end))
        case .radialGradient:
            return .radialGradient(MaskDragGeometry.radial(center: start, to: end, source: source))
        default:
            return nil
        }
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
        guard autoRenderEnabled else { return }
        if frameSource == nil {
            guard let session, session.mode == .loupe, session.anchorAsset != nil else { return }
        }
        if editInFlight {
            // Only the newest document survives: the follow-up render reads `session.edit` itself.
            editPending = true
            editRenderCoalesced += 1
            return
        }
        guard let job = makeJob(kind: .edit, changedAt: session?.lastEditChangedAt ?? 0) else { return }
        editRenderStarts += 1
        editInFlight = true
        queue.async { [weak self] in self?.renderFrame(job) }
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
    ///
    /// Nothing here waits for a development: the frame rides the rung the ladder has (the 0.5 preview
    /// while the full one is being made) and the full rung replaces it when it lands. That is the
    /// whole point of the split — a pan is a *frame*, not a decode.
    public func requestViewportRender() {
        guard autoRenderEnabled else { return }
        if frameSource == nil {
            guard let session, session.mode == .loupe, session.anchorAsset != nil else { return }
        }
        if viewInFlight {
            viewPending = true
            viewRenderCoalesced += 1
            return
        }
        startViewportRender()
    }

    private func startViewportRender() {
        guard let job = makeJob(kind: .view) else { return }
        viewInFlight = true
        queue.async { [weak self] in self?.renderFrame(job) }
    }

    private func finishViewRender() {
        viewInFlight = false
        guard viewPending else { return }
        viewPending = false
        startViewportRender()
    }

    // MARK: one frame, two queues

    /// Everything one request needs, snapshotted on the main thread — or `nil` when there is nothing
    /// to draw (no photo, no viewport yet).
    private func makeJob(kind: RenderJob.Kind,
                         changedAt: CFAbsoluteTime = 0) -> RenderJob? {
        let gen = generation
        if let source = frameSource {
            return RenderJob(kind: kind, url: source.url, identity: source.identity,
                             viewport: source.viewport, edit: source.edit, state: source.state,
                             generation: gen, changedAt: changedAt)
        }
        guard let session, session.mode == .loupe,
              let asset = session.anchorAsset, let url = session.fileURL(for: asset) else { return nil }
        let viewport = viewportPixels
        guard viewport.width > 8, viewport.height > 8 else { return nil }
        return RenderJob(kind: kind, url: url, identity: ladderIdentity(asset), viewport: viewport,
                         edit: session.edit, state: viewState, generation: gen,
                         changedAt: changedAt)
    }

    /// One frame, on the render queue. It **never develops**: it renders from the rung the ladder
    /// already has and asks the decode queue for the one the camera wants. That is the difference
    /// between a pan that costs 5 ms while a 60 MP development runs and a pan that costs 800 ms
    /// because the development was dispatched first on the same queue.
    private func renderFrame(_ job: RenderJob) {
        requestDevelopment(ladder.plan(identity: job.identity, target: job.target), job: job)

        let t0 = CFAbsoluteTimeGetCurrent()
        let frame = residentFrame(job)
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // A frame whose generation moved on is not presented: the camera (or the photo) is not
            // the one this frame was rendered for. The single-flight flag is released either way.
            if self.generation == job.generation, let frame {
                self.lastPresentedScale = frame.decodeScale
                self.present(frame: frame, renderMilliseconds: ms)
                switch job.kind {
                case .edit:
                    self.editRenderCount += 1
                    if job.changedAt > 0 {
                        self.editLatencies.append((CFAbsoluteTimeGetCurrent() - job.changedAt) * 1000)
                    }
                case .view, .scheduled:
                    self.viewRenderCount += 1
                }
            }
            switch job.kind {
            case .edit: self.finishEditRender()
            case .view: self.finishViewRender()
            case .scheduled: break
            }
        }
    }

    /// The frame the ladder can produce **now**, from the biggest rung it has.
    ///
    /// `nil` before the first development of a photo lands: there is nothing honest to draw, and the
    /// canvas keeps the previous picture rather than flashing black. The development that fixes it has
    /// already been queued by `requestDevelopment`.
    private func residentFrame(_ job: RenderJob) -> FrameResult? {
        guard let rung = ladder.best(identity: job.identity, atOrBelow: job.target) else { return nil }
        do {
            let frame = try makeFrame(url: job.url, cacheIdentity: job.identity,
                                      viewport: job.viewport, decodeScale: rung.scale,
                                      edit: job.edit, state: job.state,
                                      hashPixels: hashesFrames, resolve: .residentOnly)
            decodeMilliseconds = rung.milliseconds
            return frame
        } catch {
            lastPresentError = "\(error)"
            return nil
        }
    }

    /// Ask the decode queue for every rung the camera needs and the ladder does not have, in plan
    /// order (the preview first, the target second).
    ///
    /// The queue dedupes by `(photo, rung)`, so twenty pans during one development cost **one** decode
    /// and twenty deliveries; `rungArrived` then ignores the duplicates because the rung is resident.
    private func requestDevelopment(_ plan: DecodeLadderPlan, job: RenderJob) {
        for scale in plan.rungs where ladder.resident(identity: job.identity, scale: scale) == nil {
            decodeQueue.request(identity: job.identity, scale: scale, generation: job.generation,
                                work: { try Self.develop(url: job.url, scale: scale) },
                                completion: { [weak self] result, generation in
                guard let self else { return }
                DispatchQueue.main.async {
                    self.rungArrived(result, identity: job.identity, generation: generation)
                }
            })
        }
    }

    /// A development landed. The **only** way a rung enters the ladder in the loupe, which is what
    /// makes "one replacement frame per rung" a property of this function instead of a hope.
    ///
    /// Three rules, in order:
    ///  1. **Another photo's buffer is dropped outright.** Storing it would evict the rungs of the
    ///     photo on screen (`DecodeLadder.store` clears on a new identity) — the old single-slot
    ///     eviction bug, one queue later.
    ///  2. **A rung that is already resident is not news.** Two pans can join one development; only
    ///     the first arrival may repaint.
    ///  3. **A stale generation still caches, but never paints.** The buffer is this photo's and was
    ///     paid for, so it lands in the ladder for the next frame; the *frame* it was meant for is
    ///     gone, so the canvas is left alone.
    private func rungArrived(_ result: Result<DecodeRung, Error>, identity: String, generation gen: Int) {
        let isCurrentFrame = gen == generation
        switch result {
        case .failure(let error):
            if isCurrentFrame { lastPresentError = "\(error)" }
        case .success(let rung):
            guard isCurrentPhoto(identity) else {
                staleRungDrops += 1
                return
            }
            if ladder.resident(identity: identity, scale: rung.scale) != nil { return }
            ladder.store(rung, identity: identity)
            rungArrivals += 1
            guard isCurrentFrame else {
                staleRungDrops += 1
                return
            }
            // Exactly one replacement: this render finds the rung resident and asks for nothing.
            requestViewportRender()
        }
    }

    /// Is `identity` the photo this loupe is showing *now*?
    private func isCurrentPhoto(_ identity: String) -> Bool {
        if let source = frameSource { return source.identity == identity }
        guard let asset = session?.anchorAsset else { return false }
        return ladderIdentity(asset) == identity
    }

    /// Stop paying for a picture nobody is looking at: leaving the loupe, or switching to another
    /// photo, drops the queued developments and refuses the delivery of one already running.
    ///
    /// Bumping the generation is the whole mechanism — every arrival and every frame compares against
    /// it — so a cancelled photo cannot paint over its successor even when ImageIO is already busy
    /// with it and cannot be aborted.
    public func cancelPendingFrames() {
        generation += 1
        viewPending = false
        editPending = false
        if let identity = frameSource?.identity ?? session?.anchorAsset.map({ ladderIdentity($0) }) {
            decodeQueue.cancel(identity: identity)
        }
    }

    /// Developments the queue has run, requests it has folded into one, deliveries it made and
    /// results it dropped. Diagnostics: the pan budget is a timing, the decode *count* is this.
    public var developmentStats: (decodes: Int, coalesced: Int, deliveries: Int, drops: Int) {
        (decodeQueue.decodes, decodeQueue.coalesced, decodeQueue.deliveries, decodeQueue.drops)
    }

    /// Block until every queued development has finished — tests and the bench only. The loupe never
    /// waits for one; that is the point of the split.
    @discardableResult
    public func awaitPendingDevelopments(timeout: TimeInterval = 60) -> Bool {
        decodeQueue.waitUntilIdle(timeout: timeout)
    }

    // MARK: rendering

    /// Viewport in device pixels; the metal layer is the owner of that number.
    public var viewportPixels: ImageSize {
        let scale = canvasView.window?.backingScaleFactor ?? 2
        let size = canvasView.bounds.size
        return ImageSize(width: max(1, Int((size.width * scale).rounded())),
                         height: max(1, Int((size.height * scale).rounded())))
    }

    /// A new photo, a resize, fit ↔ 1:1, a new headroom: one frame from what the ladder has, plus a
    /// development request for what it does not.
    public func scheduleRender() {
        guard autoRenderEnabled else { return }
        guard var job = makeJob(kind: .scheduled) else { return }
        // A different photo: the old one's queued developments are waste, and finishing them would
        // steal ImageIO from the picture that is on screen now. (A running one cannot be aborted; its
        // delivery is refused instead — see `DecodeQueue.cancel`.)
        if let previous = pendingIdentity, previous != job.identity {
            decodeQueue.cancel(identity: previous)
        }
        pendingIdentity = job.identity
        // A scheduled render is a new intent: any frame or development still on its way was for the
        // previous one. The *buffers* survive (the ladder is keyed by photo); the *frames* do not.
        generation += 1
        job.generation = generation
        awaitingFirstFrame = true
        queue.async { [weak self] in self?.renderFrame(job) }
    }

    /// The ladder identity of an asset: the same string `makeFrame` keys its graph on, so a plan can
    /// never be made for one photo and applied to another.
    private func ladderIdentity(_ asset: Asset) -> String { "\(asset.contentHash)|\(asset.id)" }

    // MARK: frame

    /// One development, wrapped as a rung.
    ///
    /// This is the decode queue's unit of work and the only place the loupe opens a file: a frame
    /// calls it only on the synchronous path (`--ui-smoke`, tests), never from the render queue. A
    /// fresh `RAWDecoder` per development is deliberate — one `CIContext` and one Metal command queue
    /// per development, so the decode queue never shares GPU state with the render queue.
    static func develop(url: URL, scale: Float) throws -> DecodeRung {
        let decoder = try RAWDecoder()
        let t0 = CFAbsoluteTimeGetCurrent()
        let developed = try decoder.decodeDetailed(url, options: DecodeOptions(decoderVersion: nil,
                                                                              exposureEV: 0,
                                                                              scale: scale))
        return DecodeRung(scale: scale, image: developed.image,
                          capabilities: developed.capabilities,
                          milliseconds: (CFAbsoluteTimeGetCurrent() - t0) * 1000)
    }

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

    /// Whether a frame may develop the rung it wants.
    private enum RungResolution {
        /// Develop on a miss. The synchronous path: `--ui-smoke`, the tests, an import preview — a
        /// caller that has nothing else to put on screen and is willing to wait for ImageIO.
        case developIfMissing
        /// Ride what the ladder already has; a miss is a `LoupeFrameError.notResident`, never a
        /// development. This is the loupe's own frame path: developing there would put a 60 MP
        /// development back in front of every pan, which is the defect Q29 removed.
        case residentOnly
    }

    private func makeFrame(url: URL, cacheIdentity: String, viewport: ImageSize, decodeScale: Float,
                           edit model: EditModel, state: LoupeViewState,
                           hashPixels: Bool, resolve: RungResolution = .developIfMissing) throws -> FrameResult {
        let ds = Double(max(decodeScale, 0.01))
        // ── the decode ladder (§11.10) ───────────────────────────────────────────────────────
        // One photo, one development per rung. Keyed by (photo, scale), so the second visit to fit
        // or to 1:1 is a render and nothing else. `residentOnly` frames (every frame the loupe's
        // queues produce) never develop: the rung they want was requested from the decode queue by
        // the caller, and a miss here means the very first development of a photo has not landed.
        let outcome: (rung: DecodeRung, cached: Bool)
        switch resolve {
        case .developIfMissing:
            outcome = try ladder.rung(identity: cacheIdentity, scale: decodeScale) {
                try Self.develop(url: url, scale: decodeScale)
            }
        case .residentOnly:
            guard let resident = ladder.resident(identity: cacheIdentity, scale: decodeScale) else {
                throw LoupeFrameError.notResident(scale: decodeScale)
            }
            outcome = (resident, true)
        }
        let image = outcome.rung.image
        let usedCache = outcome.cached
        if !outcome.cached {
            decodeMilliseconds = outcome.rung.milliseconds
            graph = nil                      // a new source needs a new graph
            graphIdentity = nil
        }
        decoded = image
        decodedScale = ds
        decodedCaps = outcome.rung.capabilities
        currentDecodeScale = decodeScale

        let identity = "\(cacheIdentity)-s\(decodeScale)"
        if graph == nil || graphIdentity != identity {
            graph = try RenderGraph(input: RenderInput(image: image, identity: identity, sourceURL: url))
            graphIdentity = identity
        }
        guard let graph else { throw RenderError.allocationFailed("loupe graph") }

        // The camera: the document's own crop is the frame at every zoom, and 1:1 (or beyond) is an
        // **output window** into it — S0 crops/straightens/flips the whole frame and hands back that
        // rectangle, so the projection, the vignette and the mask feather are the frame's, not the
        // window's (`RenderOptions.outputWindow`). `fit` names no window, i.e. the whole frame.
        let projected = LoupeFraming(viewport: viewport,
                                     decoded: ImageSize(width: image.width, height: image.height),
                                     decodeScale: ds,
                                     edit: model)
        let outputWindow = projected.outputWindow(of: state)
        let scale = max(0.01, projected.renderScale(of: state, decodeScale: ds))
        let window = projected.windowPixels(of: state)
        let primaries: OutputPrimaries = (presenter?.storage ?? .linear16) == .linear16 ? .displayP3 : .sRGB
        let ceiling = displayHeadroom.headroom
        let t1 = CFAbsoluteTimeGetCurrent()
        let result = try graph.render(model, options: RenderOptions(
            canvas: viewport,
            scale: scale,
            outputWindow: outputWindow,
            display: DisplayOptions(primaries: primaries, bitDepth: 8, headroom: ceiling),
            useCache: true,
            wantsPixels: false,
            // The histogram is measured by the *same* frame — one extra dispatch in the frame's own
            // command buffer plus the reduced readback, never a second render (`RenderGraph`'s
            // `collectHistogram`). That is what lets the inspector card follow a slider without
            // doubling the cost of every tick.
            collectHistogram: collectsHistogram,
            histogramBins: 256))
        let renderMs = (CFAbsoluteTimeGetCurrent() - t1) * 1000
        guard let texture = result.output else { throw RenderError.executeFailed("loupe produced no texture") }
        let hash = hashPixels ? LoupeController.hash(texture) : nil
        // The clipping warning's input. Only read while the warning is on: it is a UI aid, and a
        // readback nobody looks at is a millisecond nobody asked for.
        let clipped = (session?.highlightWarning ?? false)
            ? HighlightWarning.grid(of: texture) : nil
        return FrameResult(texture: texture, canvas: result.canvas, content: result.content,
                           decodeScale: decodeScale, decodeMilliseconds: decodeMilliseconds,
                           renderMilliseconds: renderMs, usedCachedDecode: usedCache,
                           capabilities: decodedCaps, primaries: primaries,
                           editRevision: session?.editRevision ?? 0, displayHash: hash,
                           zoom: projected.zoom(of: state), headroom: ceiling, window: window,
                           histogram: result.histogram, clipped: clipped)
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

    private func present(frame: FrameResult, renderMilliseconds: Double) {
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
        recordMeasurements(frame)
        lastTimings = FrameTimings(decode: frame.decodeMilliseconds,
                                   render: frame.renderMilliseconds,
                                   present: presentMs,
                                   total: frame.decodeMilliseconds + frame.renderMilliseconds,
                                   decodeScale: frame.decodeScale,
                                   zoom: frame.zoom,
                                   window: frame.window)
        if awaitingFirstFrame {
            firstFrameMilliseconds = renderMilliseconds
            awaitingFirstFrame = false
        } else {
            secondFrameMilliseconds = renderMilliseconds
        }
        if let caps = frame.capabilities { session?.recordCapabilities(caps) }
        canvasView.metalLayer.setNeedsDisplay()
    }

    public var decodeSeconds: Double { decodeMilliseconds / 1000 }

    // MARK: measurements (histogram + clipping warning)
    //
    // This is the "re-render finished" callback the inspector's histogram card hangs off: the frame
    // already measured itself (`collectHistogram` in its own command buffer, and the clipping grid
    // when the warning is on), so publishing costs a main-thread hand-off and nothing else. Called
    // from `present`; `--ui-smoke` calls the same function for a frame it rendered synchronously, so
    // the card is asserted through the shipped path rather than a test-only one.

    public func recordMeasurements(_ frame: FrameResult) {
        session?.recordHistogram(frame.histogram)
        histogramPublishCount += 1
        if let clipped = frame.clipped {
            lastClipped = clipped
            highlightOverlay.grid = clipped
        } else if !(session?.highlightWarning ?? false) {
            lastClipped = nil
            highlightOverlay.grid = nil
        }
        highlightOverlay.isArmed = session?.highlightWarning ?? false
    }

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

/// A frame the loupe's queue path could not produce — because it must never develop one itself.
///
/// This is not a failure in the shipped flow: it means "no rung is resident yet", i.e. the very
/// first development of a photo is still on its way, and the canvas is right to keep the previous
/// picture. `rungArrived` will repaint when it lands.
public enum LoupeFrameError: LocalizedError, Equatable {
    case notResident(scale: Float)

    public var errorDescription: String? {
        switch self {
        case .notResident(let scale):
            return "no decoded rung at scale \(scale) is resident; the development is on the decode queue"
        }
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
