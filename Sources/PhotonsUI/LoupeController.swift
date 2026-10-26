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
            // Escape abandons a gradient drag before it becomes a mask, disarms the eyedropper, and
            // otherwise means "fit".
            if controller?.isEyedropperArmed == true { controller?.cancelEyedropper() }
            else if isShaping { isShaping = false; controller?.cancelShapeDrag() }
            else { controller?.zoomToFit() }
        default:
            super.keyDown(with: event)
        }
    }

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        // 派单 009 C: the eyedropper is a modal one-shot, so it is the innermost gesture of all —
        // it consumes the click before a paint drag or a pan can start.
        if controller?.isEyedropperArmed == true {
            controller?.handleEyedropperClick(atViewPoint: point)
            return
        }
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
        if controller?.isEyedropperArmed == true {
            // A dropper is armed: every point of the canvas is a sample, so the pointer says so.
            addCursorRect(bounds, cursor: .crosshair)
            return
        }
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

        // There is deliberately no `histogram` field (005, 2026-10-26). A frame is the window the
        // camera is showing and the card's numbers are of the *picture*: carrying one here would make
        // it possible to publish a per-frame plot again, which is exactly the coupling that made the
        // numbers move when the user zoomed. `LoupeController.lastHistogram` is the card's input and
        // `RenderGraph.measureHistogram` is where the numbers come from.
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
        /// The camera this file is rendered at. `var` because the loupe's own camera commands are
        /// what move it: `setViewState` writes the new state back here, so a harness that says "show
        /// this file" is not frozen at the camera it was constructed with (a `zoom(to:)` would
        /// otherwise change `viewState` and render the old one, silently).
        public var state: LoupeViewState
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
        /// The **photo** identity — `contentHash|assetID`, with no decode component.
        ///
        /// 派单 011 A: the decode inputs are appended by `makeFrame` (one place, `DecodeInputs
        /// .appending(to:)`), so a job must carry the bare photo identity or the component lands
        /// twice. It did land twice before this split (`…|wb=5500K/+0|wb=5500K/+0`): the development
        /// was written under the queue's key while every frame looked itself up under the doubled
        /// one, so the white balance developed and the canvas never showed it — "改白平衡画面不变".
        let baseIdentity: String
        let viewport: ImageSize
        let edit: EditModel
        let state: LoupeViewState
        /// The caller's frame generation. `var` because `scheduleRender` bumps the counter *after* it
        /// has decided there is something to draw, and the job it just built has to carry the new one.
        var generation: Int
        /// Only edit frames carry a slider timestamp.
        let changedAt: CFAbsoluteTime

        /// The rung identity this job develops and renders from: the document's decode key on top of
        /// the photo identity. Derived from `edit`, never stored, so the two cannot drift.
        var identity: String { edit.decodeInputs.appending(to: baseIdentity) }

        /// The rung the camera needs. Everything — fit, 1:1, 4:1 — renders from the full buffer: a
        /// window is what makes 1:1 cheap to *render*, and the rung is what makes it expensive to
        /// *develop*. Asking for the biggest rung once is what keeps `fit ↔ 1:1` at one development.
        var target: Float { DecodeLadder.fullScale }
    }

    // MARK: views

    public let canvasView = LoupeCanvasView()
    private let container = NSView()
    private let statusChip = LoupeStatusChip()
    /// 画布右下角的**固定档位**缩放拖动条（液态玻璃药丸）。
    ///
    /// It names a rung and nothing else: its only way out is `onZoom`, wired to `zoom(to:)` — the
    /// same command the 倍率 menu and ⌘= use, bridge included. So the pill adds an input device,
    /// not a second zoom model.
    public let zoomSlider = ZoomGlassSlider()
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

    /// Ask for a histogram at all — the inspector card's switch.
    ///
    /// On by default because the card is always on screen in this build. What it does *not* mean is
    /// "measure every frame" or even "measure when the camera settles": since 005 the histogram is a
    /// measurement of the **picture**, so it is re-measured only when the picture's *key* changes — a
    /// new photo, a new decode rung, or an edit — and never because the viewport moved. Panning and
    /// zooming measure nothing at all (`noteHistogramKey(for:)`).
    public var collectsHistogram = true

    /// How long the picture must be unchanged before it is re-measured.
    ///
    /// 120 ms: long enough that a slider drag costs one measurement instead of one per tick, short
    /// enough that the card has followed the picture before a person's eye gets there. It is a
    /// debounce on the *edit*, not on the hand: a camera gesture cannot re-arm it, which is the
    /// difference between this and Q30's 60 ms settle.
    public var histogramDebounceInterval: TimeInterval = 0.12

    /// Frames that carried no measurement of their own — every frame, since 005.
    ///
    /// Kept as a counter (and asserted by the cadence tests) because "the pan frames measured
    /// nothing" is the claim this whole change rests on, and a counter cannot be talked out of the
    /// answer the way a frame time can.
    public private(set) var histogramSkippedFrames = 0
    /// Measurements that reached the card.
    public private(set) var histogramCollectedFrames = 0
    /// Measurements actually run (a cache hit for an unchanged picture is not one).
    public private(set) var histogramRefreshCount = 0
    /// The last measurement's own cost (thumbnail render + readback + binning), in milliseconds.
    public private(set) var lastHistogramMilliseconds: Double = 0
    /// The last measurement's latency: "the picture changed" → "the card has new numbers".
    public private(set) var lastHistogramLatency: Double = 0
    /// Why the last measurement did not run (`nil` when it did). A development that had not landed, or
    /// an edit that superseded the measurement before it started.
    public private(set) var lastHistogramError: String?

    private var histogramSettle: DispatchWorkItem?
    /// When the card's numbers went stale — the moment the picture's key changed. The measurement's
    /// latency is published against this, so it is "the picture changed → the card has new numbers".
    private var histogramStaleAt: CFAbsoluteTime = 0
    /// The key the armed debounce is waiting for (nil when nothing is pending).
    private var histogramPendingKey: String?
    /// The key `lastHistogram` belongs to.
    private var histogramMeasuredKey: String?
    private var histogramRefreshing = false
    /// `Histogram.cacheKey` → the numbers. A handful of entries: the current picture's edit chain, so
    /// sliding back is instant and a re-measurement of the same document cannot produce different
    /// numbers (it cannot produce anything — the key is the identity).
    private var histogramCache: [String: Histogram] = [:]
    private var histogramCacheOrder: [String] = []
    private var histogramCacheLimit = 8
    /// The last document digested, and its digest. `noteHistogramKey` runs on every frame, and a JSON
    /// encode plus a SHA-256 per frame would be a real cost on a 4 ms pan; an `EditModel` comparison is
    /// a field-by-field compare of a small struct. Render-queue only.
    private var lastEditDigest: (edit: EditModel, digest: String)?
    /// The camera the *previous* frame was rendered at. `nil` after a new photo, so its first frame
    /// measures instead of being mistaken for a gesture.
    private var lastFrameState: LoupeViewState?

    /// The numbers the card is showing: the last measurement that reached the session.
    ///
    /// Kept here as well as on the session because a measurement that *failed* (a rung that had not
    /// landed) must leave it alone instead of blanking the plot, and "what did the card last get" is
    /// the fact that tells the two cases apart.
    public private(set) var lastHistogram: Histogram?

    /// The last clipping grid the warning produced (nil while the warning is off or before a frame).
    public private(set) var lastClipped: ClippedGrid?
    /// Frames whose histogram reached the session — the smoke asserts it is not a second render.
    public private(set) var histogramPublishCount = 0

    // MARK: camera (fit / 1:1 / pan / pinch)

    /// Where the loupe is looking, in source pixels. The only view-state this type keeps.
    public private(set) var viewState = LoupeViewState.fit
    /// The continuous value a *pinch* has accumulated, in the same units as `viewState.zoom`.
    ///
    /// The camera itself is always on a rung (`LoupeViewState.snappedLevel`), which would otherwise
    /// round every 1–5 % pinch event straight back to the rung the gesture started on. Cleared by every
    /// command that names a rung outright — those are not a pinch continuing.
    private var pinchZoom: Double?
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
    /// Requests that reached `requestViewportRender` past its guards, and how many of them started a
    /// frame (diagnostics: a request that starts nothing is the interesting case).
    public private(set) var viewRenderRequests = 0
    public private(set) var viewRenderStarts = 0
    /// Frames that were rendered but thrown away because the generation moved on (a newer request
    /// superseded them) — a normal outcome during a gesture, a *bug signal* when nothing moved.
    public private(set) var staleFrameDrops = 0
    /// Frames that had nothing to draw: no decoded rung was resident when they ran.
    public private(set) var emptyFrameDrops = 0

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
        // Topmost chrome on the canvas, and the only piece of it that takes clicks (inside its own
        // pill — outside, `hitTest` is nil so a pan starting next to it still belongs to the canvas).
        container.addSubview(zoomSlider)
        zoomSlider.onZoom = { [weak self] stop in self?.zoomFromSlider(to: stop) }
        zoomSlider.onFit = { [weak self] in self?.zoomToFit() }
        // The wheel and the pinch stay the canvas' gestures even over the pill.
        zoomSlider.wheelTarget = canvasView
        layoutZoomSlider()
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
        syncZoomSlider()
    }

    public override func viewDidAppear() {
        super.viewDidAppear()
        refreshDisplay()
    }

    public override func viewDidLayout() {
        super.viewDidLayout()
        layoutStatusChip()
        layoutZoomSlider()
        // A resize is a new canvas: every pixel is re-rendered into it, and a bridge measured against
        // the old one would scale the picture about the wrong centre. Tear the transition down rather
        // than leave the transform in a mid-flight state nobody will ever finish.
        let size = viewportPixels
        if size != lastLaidOutViewport {
            let canvasChanged = lastLaidOutViewport != nil && zoomBridgeCanvas != nil
                && zoomBridgeCanvas != size
            lastLaidOutViewport = size
            if canvasChanged { cancelZoomBridge() }
        }
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

    /// What the status strip shows: display class, headroom, and where the camera is — in percent,
    /// with the fit rung's real ratio (`适应 31%`), so the number moves with the window.
    public var statusText: String { "\(displayHeadroom.displayText) · \(zoomLabel)" }

    // MARK: camera state changes

    /// Z / space.
    public func toggleActualSize() {
        if viewState.isActualSize { zoomToFit() } else { zoomToActualSize() }
    }

    /// Fit → 100 % around **the pointer**. Already zoomed → back to exactly 100 %.
    ///
    /// Both directions anchor on the pointer where there is one: leaving `fit` magnifies about the
    /// pixel under the cursor, and coming back from 300 % keeps that pixel in view instead of
    /// re-centring the picture on the crop's middle. `zoomToFit` is the one command with no anchor to
    /// honour — the whole frame is the whole frame.
    public func zoomToActualSize() {
        zoomToActualSize(aroundView: cursorAnchor())
    }

    /// The anchored form, for callers that know the point (the double-click, the tests).
    public func zoomToActualSize(aroundView point: CGPoint?) {
        guard let framing = framing() else { return }
        pinchZoom = nil
        let anchor = point ?? canvasCentrePoint()
        setViewState(framing.zooming(viewState, to: 1, aroundView: anchor, backingScale: backingScale))
    }

    /// Back to the whole frame — **whole and centred**, which is the one camera change with no anchor
    /// to honour: at `fit` the entire picture is on screen and there is nowhere else for it to be. The
    /// last centre is kept, so Z‑Z returns to where the user was.
    public func zoomToFit() {
        pinchZoom = nil
        var next = viewState
        next.mode = .fit
        setViewState(next)
    }

    // MARK: the zoom ladder (显示 ▸ 倍率)

    /// The eight numeric stops, in order — `LoupeViewState.zoomStops`, `0.25 … 4` with the thirds
    /// exact (`1.0/3.0`, `2.0/3.0`). `fit` is **not** one of them; it is a mode with its own entry
    /// point (`zoomFitEntryPoint`).
    public static let zoomStops: [Double] = LoupeViewState.zoomStops

    /// What the 倍率 menu can name: the same eight stops, at the same indices.
    ///
    /// The menu item's **tag is the index into this array**, not a percentage. That is the only
    /// identity that survives `1/3 → "33.3%" → 0.333` intact: a hundredths tag would round the third
    /// to 33 % and land the action on a stop the item never named. `EditorWindowController.zoomStopAction`
    /// reads `menuZoomStops[item.tag]`, so the value is exact and the label is only a label.
    public static let menuZoomStops: [Double] = LoupeViewState.zoomStops

    /// The ladder the menu and the readout print: eight numeric stops, ascending, no fit rung.
    public var zoomLevels: [LoupeZoomLevel] { LoupeViewState.levels }

    /// Where 适应窗口 is reachable from — **the single switch point** for `fit`.
    ///
    /// `fit` is not a rung: its ratio is a property of the window (0.31 on a 60 MP frame in a 2560-px
    /// viewport, 0.72 on a 24 MP one, above 1 on a small file), so it cannot sit in a table of fixed
    /// percentages, and the user has not said yet whether it wants its own menu row, a bare shortcut
    /// or a toolbar button. Everything that offers `fit` asks this one constant, so moving it is a
    /// one-line change here and no other code learns about the decision.
    ///
    /// TODO: fit 的位置待定，用户会指定（菜单单独一行 / 快捷键 / 工具栏）。在此之前它只是
    /// `zoomToFit()` 这个**独立动作**：不进档位表、不参与 ⌘=/⌘− 的档位循环、不参与捏合取档。
    public static let zoomFitEntryPoint: ZoomFitEntryPoint = .menuItem

    public enum ZoomFitEntryPoint: Sendable {
        /// Its own row in 显示 (what ships now): 显示 ▸ 适应窗口, ⌘0.
        case menuItem
        /// A shortcut with no menu row.
        case shortcutOnly
        /// A toolbar button.
        case toolbar
    }

    /// Canvas pixels per source pixel the frame is being drawn at — `fit`'s own ratio included, so a
    /// readout can say "适应 31%" without a special case.
    public var effectiveZoom: Double { framing()?.zoom(of: viewState) ?? 1 }

    /// `"适应 31%"` / `"50%"` / `"33.3%"` — the number the status chip and the menu tick both use.
    ///
    /// The fit ratio is printed to whole percent (it moves with the window; a tenth of a percent of a
    /// 0.31 viewport is noise), while the stops use `percentLabel`'s one-decimal rule for the thirds.
    public var zoomLabel: String {
        guard !viewState.isActualSize, let fit = framing()?.fitZoom else { return viewState.zoomLabel }
        return "适应 \(Int((fit * 100).rounded()))%"
    }

    /// The menu stop the camera is exactly on, or nil (fit) — what the View menu ticks.
    ///
    /// `1e-9`, not a fudge factor: the camera is only ever parked on a table value, so "on a stop" is
    /// an equality question about the table's own doubles.
    public var currentZoomStop: Double? {
        guard viewState.isActualSize else { return nil }
        let zoom = LoupeViewState.clampZoom(viewState.zoom)
        return LoupeController.zoomStops.first { abs($0 - zoom) < 1e-9 }
    }

    /// A menu stop (1 / 2 / 3 / 4): same **anchor**, new scale, one re-render.
    ///
    /// The anchor is the pointer (`cursorAnchor()`), not the middle of the picture. A zoom is a
    /// question about *this* pixel: moving it out from under the cursor is what makes a stop change
    /// feel like a different photograph rather than a bigger one. When the pointer is not over the
    /// canvas (a menu command, a shortcut pressed while it sits on the inspector) the picture's own
    /// centre is the anchor, which is the behaviour this command had.
    ///
    /// The maths is `LoupeFraming.zooming` — the same one the pinch uses, exact because the centre
    /// enters the mapping with slope 1 — so the anchored pixel does not move at all, not "by less than
    /// a pixel": the two projections are one similarity and the anchor is its fixed point. The picture
    /// is allowed to leave the frame for exactly this reason (the canvas shows background outside it,
    /// `s0_geometry`), so the only case that can still push the pixel is the excursion limit in
    /// `LoupeFraming.minimumPictureCoverage`, where the window would stop being half photograph.
    public func zoom(to stop: Double) {
        zoom(to: stop, aroundView: cursorAnchor())
    }

    /// The anchored form, for callers that know the point (the tests).
    ///
    /// The target is snapped **to a rung** (`LoupeViewState.snappedLevel`): the camera must never come
    /// to rest between stops, so a value that is not in the table is floored onto the one below it
    /// before anything is set. For a caller that names a table value this is the identity.
    public func zoom(to stop: Double, aroundView point: CGPoint?) {
        guard let framing = framing() else { return }
        pinchZoom = nil
        let target = LoupeViewState.snappedLevel(for: LoupeViewState.clampZoom(stop)).zoom
        let anchor = point ?? canvasCentrePoint()
        setViewState(framing.zooming(viewState, to: target, aroundView: anchor,
                                     backingScale: backingScale))
    }

    /// ⌘+ / ⌘=: the next stop up, or 4:1 from anything between. From `fit` it lands on 100 % — the
    /// same destination as Z, because "zoom in from the whole frame" means full size first.
    public func zoomIn() {
        guard viewState.isActualSize else { zoomToActualSize(); return }
        let current = LoupeViewState.clampZoom(viewState.zoom)
        let next = LoupeController.zoomStops.first { $0 > current + 1e-9 } ?? LoupeViewState.maximumZoom
        zoom(to: next)
    }

    /// ⌘−: the next stop down — 100 % → 66.7 % → 50 % → 33.3 % → 25 %. Below the lowest **numeric**
    /// stop the whole frame is the next step out; `fit` is outside the ladder and is reached here
    /// rather than by a snap, so one more ⌘− from 25 % always gives the same picture.
    public func zoomOut() {
        guard viewState.isActualSize else { return }
        let current = LoupeViewState.clampZoom(viewState.zoom)
        guard let next = LoupeController.zoomStops.last(where: { $0 < current - 1e-9 }) else {
            zoomToFit()
            return
        }
        zoom(to: next)
    }

    /// Double-click: into 1:1 **at the clicked pixel**, or back to fit. (Both halves of the brief:
    /// a double-click is the "show me this at full size" gesture, and its inverse when already there.)
    ///
    /// The clicked pixel is the anchor, not the destination: it stays under the pointer, and the
    /// picture grows around it. Putting it in the middle of the viewport is the thing this used to do
    /// and exactly what the user reported as "光标位置动了".
    public func handleDoubleClick(at point: CGPoint) {
        guard framing() != nil else { return }
        pinchZoom = nil
        if viewState.isActualSize {
            zoomToFit()
            return
        }
        zoomToActualSize(aroundView: point)
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

    /// Trackpad pinch: a **continuous accumulator feeding a discrete ladder**.
    ///
    /// A pinch event is 1–5 %; if the camera's own (already snapped) zoom were the base, every event
    /// would floor back to the rung the gesture started on and the pinch could never leave it. So the
    /// accumulator carries the continuous value, the camera stays on a rung, and the source pixel under
    /// the cursor stays where it is (`LoupeFraming.zooming`). Any command that names a rung outright
    /// (menu, ⌘=, ⌘−, Z, double-click) clears the accumulator: that is not a pinch continuing.
    public func magnify(by factor: CGFloat, at point: CGPoint) {
        guard let framing = framing(), factor.isFinite, factor > 0 else { return }
        let raw = (pinchZoom ?? framing.zoom(of: viewState)) * Double(factor)
        // The floor of the ladder is 25 %, and 25 % is where a pinch out stops: `fit` is a different
        // mode, entered by its own action, so a gesture cannot slide the camera into it by accident.
        let level = LoupeViewState.snappedLevel(for: raw)
        let target = level.zoom
        let next = framing.zooming(viewState, to: target, aroundView: point, backingScale: backingScale)
        pinchZoom = raw
        setViewState(next)
    }

    private func setViewState(_ next: LoupeViewState) {
        guard next != viewState else { return }
        let previous = viewState
        viewState = next
        // One camera, one place it is stored: a `FrameSource` names a file *and* the camera to render
        // it from, so a zoom that did not travel into it would leave `viewState` and the rendered
        // frames disagreeing (the trap for every "zoom, then look at the frame" test).
        if var source = frameSource {
            source.state = next
            frameSource = source
        }
        updateStatusChip()
        view.window?.invalidateCursorRects(for: canvasView)
        // **Every** stop change is bridged — fit ↔ a numeric stop, and numeric stop ↔ numeric stop
        // (`25 ↔ 33.3 ↔ 50 ↔ 66.7 ↔ 100 ↔ 200 ↔ 300 ↔ 400`). The camera jumps here and the pixels
        // follow when they are rendered; between the two the canvas still holds the old picture, so
        // without the bridge the change is a cut at whatever ratio the two stops differ by.
        //
        // The user's constraint is not "never animate" but "**never come to rest between stops**":
        // `viewState.zoom` is already the target stop on this line (snapped by `zoom(to:)`,
        // `magnify(by:)` and the `⌘=`/`⌘−` walk), so the model is never 137 %, and the bridge only
        // ever interpolates the *presentation* of the old picture on its way to that stop.
        //
        // A pan is not a stop change — `zoom` is untouched — and it keeps its hard per-frame cut:
        // animating a drag would leave the picture behind the hand.
        if let framing = framing(), movesScale(from: previous, to: next, framing: framing) {
            armZoomBridge(from: previous, to: next, framing: framing)
        }
        requestViewportRender()
    }

    /// Did this change move the picture's *scale*? A pan moves it too, and must not animate.
    private func movesScale(from old: LoupeViewState, to new: LoupeViewState,
                            framing: LoupeFraming) -> Bool {
        let o = framing.zoom(of: old), n = framing.zoom(of: new)
        guard o > 0, n > 0, o.isFinite, n.isFinite else { return false }
        return abs(n / o - 1) > 1e-6
    }

    // MARK: the stop-change bridge

    /// The bridge composited over the canvas right now, if any (`nil` = the canvas is the frame).
    public private(set) var zoomBridge: LoupeZoomBridge?
    /// Stop changes that armed a bridge — one per change with a picture on screen.
    public private(set) var zoomBridgeArmedCount = 0
    /// Frames that arrived while a bridge was moving. They are **held**, not presented (see
    /// `present(frame:renderMilliseconds:state:)`), and handed over when the geometry arrives.
    public private(set) var zoomBridgeCoveredPresents = 0
    /// Bridges that replaced a running one — a held ⌘= or ⌘−. Each of those starts from the
    /// presentation's current transform, which is what stops the picture jumping back.
    public private(set) var zoomBridgeRetargets = 0
    /// Bridges that reached their target geometry (and presented whatever frame was waiting).
    public private(set) var zoomBridgeCompletedCount = 0
    /// Held frames thrown away because the camera moved on before they could be shown.
    public private(set) var zoomBridgePendingDrops = 0

    private static let zoomBridgeKey = "photons.zoomBridge"

    /// The projection the pixels **on the canvas** were laid out with. A bridge always starts from
    /// these pixels, whatever the camera has done since.
    private var canvasContent: (mapping: LoupeMapping, content: ImageSize)?
    /// A frame that arrived while the bridge was still moving: kept, and presented the moment the
    /// geometry is at the target. Not a dropped frame — the generation gate upstream has already
    /// decided it is the current one.
    private var pendingFrame: (frame: FrameResult, graph: RenderGraph?, milliseconds: Double,
                               state: LoupeViewState)?
    /// Which bridge the completion timer belongs to: a superseded one must present nothing.
    private var zoomBridgeSerial = 0
    /// The canvas size the bridge was armed against; a resize invalidates it.
    private var zoomBridgeCanvas: ImageSize?
    private var lastLaidOutViewport: ImageSize?

    /// System setting ▸ 辅助功能 ▸ 显示 ▸ 减弱动态效果. The geometry still has to be right, so the
    /// bridge still holds the arriving frame; it snaps to the target instead of sliding there.
    public var reducesMotion: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    /// Carry the picture already on screen from the projection of the camera that produced it to the
    /// projection of the new camera in 180 ms easeOut, and hand the canvas over to the real frame when
    /// it arrives.
    ///
    /// Why a layer transform instead of a re-render: only the *presentation* may interpolate. The
    /// pixels the new camera wants are a render, and re-rendering at an interpolated scale for every
    /// animation frame would be 11 extra renders per 2× step, at the exact moment the ladder is busy.
    /// The picture on the canvas is the right picture — at the wrong scale — so the honest cheap fix
    /// is to move it: one `CATransform3D`, `present`'s single path untouched.
    ///
    /// Retargeting: the animation starts from the **presentation's** current transform, so a second
    /// ⌘= continues from where the picture actually is instead of restarting at identity. Nothing is
    /// ever added twice — the same key replaces the animation.
    private func armZoomBridge(from old: LoupeViewState, to new: LoupeViewState,
                               framing: LoupeFraming) {
        guard lastFrame != nil else { return }        // nothing on screen to carry
        let canvas = viewportPixels
        let k = backingScale
        let fromMapping = canvasContent?.mapping ?? framing.mapping(of: old)
        let fromContent = canvasContent?.content ?? framing.contentPixels(of: old)
        let toMapping = framing.mapping(of: new)
        // Where the composite already is. `identity` for a bridge armed from rest, and the running
        // animation's own value for one that replaces it (read off the presentation tree, which is
        // what the eye is looking at).
        let live = presentedLayerTransform()
        let start = canvasContent == nil
            ? (scale: 1.0, x: 0.0, y: 0.0)
            : LoupeZoomBridge.offset(ofLayerTransform: live, canvas: canvas, backingScale: k)
        let wasBridging = zoomBridge != nil
        let bridge = LoupeZoomBridge(
            fromContent: fromContent,
            toContent: framing.contentPixels(of: new),
            fromMapping: fromMapping,
            toMapping: toMapping,
            canvas: canvas,
            startScale: start.scale, startOffsetX: start.x, startOffsetY: start.y)
        guard bridge.isVisible else {
            // Nothing geometric moved (fit and 100 % coincide on a small file, or the window was
            // clamped to the same rect): the arriving frame *is* the whole change.
            zoomBridgeSerial += 1
            zoomBridge = nil
            removeZoomBridgeAnimation()
            return
        }
        if wasBridging { zoomBridgeRetargets += 1 }
        // A held frame for a camera we are no longer going to belongs nowhere: recycle it and let the
        // render that this stop change asks for take its place.
        if let pending = pendingFrame, pending.state != new {
            if let graph = pending.graph {
                queue.async { graph.recycle(output: pending.frame.texture) }
            }
            pendingFrame = nil
            zoomBridgePendingDrops += 1
        }
        zoomBridge = bridge
        zoomBridgeArmedCount += 1
        zoomBridgeCanvas = canvas
        // The model value goes back to identity before anything else: the animation (or the hold below)
        // owns the composite, and a leftover hold from the previous transition must not be the value
        // this one starts from.
        setLayerTransform(CATransform3DIdentity, animated: false)
        guard !reducesMotion, bridge.duration > 0 else {
            // Reduce Motion: no slide, but the same order of operations — geometry now, frame now.
            finishZoomBridge()
            return
        }
        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = bridge.startTransform(backingScale: k)
        animation.toValue = bridge.targetTransform(backingScale: k)
        animation.duration = bridge.duration
        // easeOut, not linear: the user asked for ~180 ms easeOut, and a curve that decelerates into
        // the stop reads as arriving *at* the stop rather than being cut off at it.
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        animation.isRemovedOnCompletion = false
        animation.fillMode = .forwards
        // The end value is held when a development outlives the motion — the picture is already where
        // the new camera will put it, so waiting there is a still frame, not a jump.
        canvasView.metalLayer.add(animation, forKey: Self.zoomBridgeKey)
        zoomBridgeSerial += 1
        let serial = zoomBridgeSerial
        DispatchQueue.main.asyncAfter(deadline: .now() + bridge.duration + 0.002) { [weak self] in
            guard let self, self.zoomBridgeSerial == serial else { return }
            self.finishZoomBridge()
        }
    }

    /// The geometry has arrived: hold the transform the animation ended on, remove it, and hand the
    /// waiting frame over. The transform goes back to identity when the new drawable is actually on
    /// the layer (a `CAMetalLayer` commits asynchronously) — dropping it first would flash the old
    /// picture back at 1× for a frame, which is the pop this whole path exists to avoid.
    private func finishZoomBridge() {
        zoomBridgeSerial += 1                 // any timer still in flight is stale now
        let wasBridging = zoomBridge != nil
        let held = zoomBridge?.targetTransform(backingScale: backingScale)
        zoomBridge = nil
        if let held {
            setLayerTransform(held, animated: false)
            canvasView.metalLayer.removeAnimation(forKey: Self.zoomBridgeKey)
        } else {
            removeZoomBridgeAnimation()
        }
        guard wasBridging else { return }
        zoomBridgeCompletedCount += 1
        guard let pending = pendingFrame else { return }
        pendingFrame = nil
        present(frame: pending.frame, renderMilliseconds: pending.milliseconds, state: pending.state,
                graph: pending.graph, resetTransformAfterPresent: held != nil)
    }

    private func setLayerTransform(_ m: CATransform3D, animated: Bool) {
        if !animated {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
        }
        canvasView.metalLayer.transform = m
        if !animated { CATransaction.commit() }
    }

    private func removeZoomBridgeAnimation() {
        let layer = canvasView.metalLayer
        guard layer.animation(forKey: Self.zoomBridgeKey) != nil
                || !CATransform3DIsIdentity(layer.transform) else {
            return
        }
        // Implicit animations off: this is a model change, not a second transition.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAnimation(forKey: Self.zoomBridgeKey)
        layer.transform = CATransform3DIdentity
        CATransaction.commit()
    }

    /// The layer transform the eye is currently looking at: the presentation tree while an animation
    /// is running, the model value otherwise.
    private func presentedLayerTransform() -> CATransform3D {
        canvasView.metalLayer.presentation()?.transform ?? canvasView.metalLayer.transform
    }

    /// A new canvas (resize, a new window, a new screen): the pixels are re-rendered for a different
    /// viewport, and a bridge measured against the old one is a transform about the wrong centre.
    /// Tear it down instead of leaving the picture somewhere in between.
    public func cancelZoomBridge() {
        guard zoomBridge != nil || pendingFrame != nil
                || canvasView.metalLayer.animation(forKey: Self.zoomBridgeKey) != nil else { return }
        if let pending = pendingFrame, let graph = pending.graph {
            queue.async { graph.recycle(output: pending.frame.texture) }
            zoomBridgePendingDrops += 1
        }
        pendingFrame = nil
        zoomBridgeSerial += 1
        zoomBridge = nil
        removeZoomBridgeAnimation()
        zoomBridgeCanvas = nil
    }

    /// Where the pointer is, in canvas **points** (y down — the space `NSEvent` and
    /// `handleDoubleClick` use), or `nil` when it is not over the canvas: a menu command chosen from
    /// the menu bar, a shortcut pressed while the pointer sits on the inspector.
    public func cursorAnchor() -> CGPoint? {
        guard let window = canvasView.window else { return nil }
        let point = canvasView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let bounds = canvasView.bounds
        guard bounds.width > 1, bounds.height > 1, bounds.contains(point) else { return nil }
        return point
    }

    /// The middle of the canvas: the anchor a command falls back to when the pointer is elsewhere.
    private func canvasCentrePoint() -> CGPoint {
        CGPoint(x: canvasView.bounds.midX, y: canvasView.bounds.midY)
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

    // MARK: white-balance eyedropper (派单 009 C)

    /// One pixel of the **resident decode buffer**, resolved from a click.
    ///
    /// Everything the inspector needs to explain itself: the source pixel (so the report can say
    /// where the sample came from), the buffer pixel it was read at (the rung is usually not 1:1),
    /// and the colour. Read from the buffer — never from the presented texture: the canvas has been
    /// through S0–S4 (crop, tone map, output primaries), and a white balance solved on display
    /// pixels would bake the tone curve into the Kelvin.
    public struct DropperSample: Equatable, Sendable {
        public let sourceX: Double
        public let sourceY: Double
        public let bufferX: Int
        public let bufferY: Int
        public let decodeScale: Double
        public let rgb: RGBSample

        public var text: String {
            String(format: "src %.0f,%.0f → buf %d,%d @%.2f× · RGB %@",
                   sourceX, sourceY, bufferX, bufferY, decodeScale, rgb.text)
        }
    }

    /// What a click on the canvas produced. Three cases, because the caller must be able to say
    /// *why* nothing happened without writing anything.
    public enum DropperOutcome: Equatable, Sendable {
        /// A sample, and the (approximate) balance that makes it neutral.
        case sampled(DropperSample)
        /// The click landed on the letterbox — outside the picture. No document write.
        case outsideImage
        /// There is no decode buffer yet (the first development has not landed). No document write.
        case notReady

        public var hint: String {
            switch self {
            case .sampled: return "取色完成"
            case .outsideImage: return "点在照片外（letterbox），未取样"
            case .notReady: return "画面尚未就绪，未取样"
            }
        }
    }

    /// True between arming the tool and the first successful sample (or Esc).
    public private(set) var isEyedropperArmed = false
    private var eyedropperHandler: ((DropperOutcome) -> Void)?

    /// Arm the one-shot picker. The next click on the canvas samples and disarms; a click that lands
    /// outside the picture reports `.outsideImage` and **stays armed**, so a user who missed does not
    /// have to re-arm (Lightroom behaves the same way).
    public func armEyedropper(_ handler: @escaping (DropperOutcome) -> Void) {
        isEyedropperArmed = true
        eyedropperHandler = handler
        refreshEyedropperCursor()
    }

    /// Esc, or the inspector's toggle going off.
    public func cancelEyedropper() {
        guard isEyedropperArmed else { return }
        isEyedropperArmed = false
        eyedropperHandler = nil
        refreshEyedropperCursor()
    }

    private func refreshEyedropperCursor() {
        canvasView.window?.invalidateCursorRects(for: canvasView)
    }

    /// The click route. `LoupeCanvasView` calls it on mouse-down while the tool is armed; the tests
    /// call it directly (there is no window in `swift test`).
    ///
    /// Returns `nil` when the tool is not armed — a plain click on the canvas is a pan, not a probe.
    @discardableResult
    public func handleEyedropperClick(atViewPoint point: CGPoint) -> DropperOutcome? {
        guard isEyedropperArmed, let handler = eyedropperHandler else { return nil }
        let outcome = samplePixel(atViewPoint: point)
        if case .sampled = outcome {
            isEyedropperArmed = false      // one-shot: Lightroom's dropper is a click, not a mode
            eyedropperHandler = nil
            refreshEyedropperCursor()
        }
        handler(outcome)
        return outcome
    }

    /// Read the buffer pixel under a view point (points, y down).
    ///
    /// `viewport`/`backingScale` exist for the tests: without a window the canvas has no backing
    /// scale, and a probe must still be able to say "this point, in this frame".
    public func samplePixel(atViewPoint point: CGPoint,
                            viewport: ImageSize? = nil,
                            backingScale scaleOverride: Double? = nil) -> DropperOutcome {
        guard let image = decoded else { return .notReady }
        guard let framing = framing(viewport: viewport) else { return .notReady }
        let scale = scaleOverride ?? backingScale
        let mapping = framing.mapping(of: viewState)
        let viewX = Double(point.x) * scale
        let viewY = Double(point.y) * scale
        // The letterbox is `content` inside `viewport`: outside it there is no pixel to read, and
        // clamping would silently sample the nearest edge of the picture instead.
        let eps = 0.5
        let inside = viewX >= mapping.originX - eps
            && viewX <= mapping.originX + mapping.contentWidth + eps
            && viewY >= mapping.originY - eps
            && viewY <= mapping.originY + mapping.contentHeight + eps
        guard inside else { return .outsideImage }

        let source = mapping.sourcePoint(viewX: viewX, viewY: viewY)
        guard source.x.isFinite, source.y.isFinite else { return .outsideImage }
        let ds = decodedScale > 0 ? decodedScale : 1
        let bx = Int((source.x * ds).rounded(.down))
        let by = Int((source.y * ds).rounded(.down))
        let (w, h) = image.uprightSize
        guard bx >= 0, by >= 0, bx < w, by < h else { return .outsideImage }
        return .sampled(DropperSample(sourceX: source.x, sourceY: source.y,
                                      bufferX: bx, bufferY: by, decodeScale: ds,
                                      rgb: image.averageRGB(x: bx, y: by)))
    }

    /// The picture's mean colour, for the 自动 preset. The same grey-world input Lightroom's Auto WB
    /// uses, measured on the resident buffer so it costs a strided scan and no development.
    public func averageSceneRGB(stride: Int = 8) -> RGBSample? {
        decoded?.meanRGB(stride: stride)
    }

    /// The as-shot pair the **resident buffer** was developed with. The white-balance solve is relative
    /// to it, and it has to come from the decode rather than from the asset row: it is a fact about the
    /// file that only `CIRAWFilter` knows.
    public var asShotWhiteBalance: WhiteBalance? { decodedCaps?.asShotWhiteBalance }

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
        viewRenderRequests += 1
        if viewInFlight {
            viewPending = true
            viewRenderCoalesced += 1
            return
        }
        startViewportRender()
    }

    private func startViewportRender() {
        guard let job = makeJob(kind: .view) else { return }
        viewRenderStarts += 1
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
            return RenderJob(kind: kind, url: source.url, baseIdentity: source.identity,
                             viewport: source.viewport, edit: source.edit, state: source.state,
                             generation: gen, changedAt: changedAt)
        }
        guard let session, session.mode == .loupe,
              let asset = session.anchorAsset, let url = session.fileURL(for: asset) else { return nil }
        let viewport = viewportPixels
        guard viewport.width > 8, viewport.height > 8 else { return nil }
        return RenderJob(kind: kind, url: url, baseIdentity: ladderIdentity(asset), viewport: viewport,
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
                self.present(frame: frame, renderMilliseconds: ms, state: job.state)
                switch job.kind {
                case .edit:
                    self.editRenderCount += 1
                    if job.changedAt > 0 {
                        self.editLatencies.append((CFAbsoluteTimeGetCurrent() - job.changedAt) * 1000)
                    }
                case .view, .scheduled:
                    self.viewRenderCount += 1
                }
            } else if frame != nil {
                self.staleFrameDrops += 1
            } else {
                self.emptyFrameDrops += 1
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
    private func residentFrame(_ job: RenderJob, reportingFailure: Bool = true) -> FrameResult? {
        guard let rung = ladder.best(identity: job.identity, atOrBelow: job.target) else { return nil }
        do {
            // `baseIdentity`, not `job.identity`: `makeFrame` appends the document's decode inputs
            // itself, and this is the same derivation the job's `identity` uses — so the rung this
            // frame looks up is the rung the arrival was stored under.
            let frame = try makeFrame(url: job.url, cacheIdentity: job.baseIdentity,
                                      viewport: job.viewport, decodeScale: rung.scale,
                                      edit: job.edit, state: job.state,
                                      hashPixels: hashesFrames, resolve: .residentOnly)
            decodeMilliseconds = rung.milliseconds
            return frame
        } catch {
            // A deferred measurement (Q30) is not a frame the user asked for: it must not put "no
            // decoded rung" in the status strip when it loses a race with a photo switch.
            if reportingFailure { lastPresentError = "\(error)" }
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
                                work: { try Self.develop(url: job.url,
                                                         scale: scale,
                                                         inputs: job.edit.decodeInputs) },
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
    ///  3. **A stale generation caches the buffer and asks for one frame at the current camera.**
    ///     The buffer is this photo's and was paid for, so it lands in the ladder; the *frame* it was
    ///     meant for is gone, so its pixels are never painted — but a request is made, because
    ///     otherwise nothing would ever paint it (2026-10-26: a photo opened while the display was
    ///     settling stayed black until the user touched the camera, and a full rung could land behind
    ///     a preview that stayed on screen).
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
                // The *frame* this development was started for is gone, so its pixels are not painted
                // (rule 3). But the **buffer** is this photo's and the current camera needs it: ask
                // for a frame at the camera that is on screen now, which will find the rung resident
                // and paint it. Without this, a photo opened while the display was still settling (the
                // headroom re-read bumps the generation twice on the way into the loupe) left the
                // canvas black until the user touched the camera — the reported "得缩放一下才出来".
                requestViewportRender()
                return
            }
            // Exactly one replacement: this render finds the rung resident and asks for nothing.
            requestViewportRender()
        }
    }

    /// Is `identity` the photo this loupe is showing *now*?
    ///
    /// A rung identity, not a photo identity: it carries the document's decode inputs, so a rung
    /// developed for an older white balance is not the current picture (派单 011 A).
    private func isCurrentPhoto(_ identity: String) -> Bool {
        if let source = frameSource {
            return source.edit.decodeInputs.appending(to: source.identity) == identity
        }
        guard let asset = session?.anchorAsset else { return false }
        return currentRungIdentity(asset) == identity
    }

    /// Stop paying for a picture nobody is looking at: leaving the loupe, or switching to another
    /// photo, drops the queued developments and refuses the delivery of one already running.
    ///
    /// Bumping the generation is the whole mechanism — every arrival and every frame compares against
    /// it — so a cancelled photo cannot paint over its successor even when ImageIO is already busy
    /// with it and cannot be aborted.
    public func cancelPendingFrames() {
        generation += 1
        // Nothing that was in flight belongs to the camera that is now on screen: a bridge would
        // carry the old picture over the new one, and a held frame is for a photo nobody is looking at.
        cancelZoomBridge()
        viewPending = false
        editPending = false
        // A measurement belongs to the picture it was armed for.
        histogramSettle?.cancel()
        histogramSettle = nil
        histogramPendingKey = nil
        histogramCache.removeAll()
        histogramCacheOrder.removeAll()
        histogramMeasuredKey = nil
        lastFrameState = nil
        if let identity = frameSource.map({ $0.edit.decodeInputs.appending(to: $0.identity) })
            ?? session?.anchorAsset.map({ currentRungIdentity($0) }) {
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

    /// Which rungs are in memory right now (diagnostics and the first-frame test).
    public var residentRungScales: [Float] { ladder.residentScales }

    /// The ladder identity of an asset: the same string `makeFrame` keys its graph on, so a plan can
    /// never be made for one photo and applied to another.
    private func ladderIdentity(_ asset: Asset) -> String { "\(asset.contentHash)|\(asset.id)" }

    /// The identity of one **rung** of one photo, including the document's decode inputs (派单 009/011).
    ///
    /// The white balance is a *decode* input since 派单 006 (`CIRAWFilter.neutralTemperature`), so two
    /// documents that differ only in Kelvin are two different buffers — the ladder must not answer
    /// `2850 K` with the buffer it developed as shot. `DecodeInputs.appending(to:)` is the one
    /// spelling of that rule; as shot appends nothing, so every pre-009 identity (and every cache key
    /// built from it) is byte-for-byte the old string.
    private static func rungIdentity(_ base: String, inputs: DecodeInputs) -> String {
        inputs.appending(to: base)
    }

    /// The identity of the rung this loupe would develop right now, for the document on screen.
    private func currentRungIdentity(_ asset: Asset) -> String {
        Self.rungIdentity(ladderIdentity(asset),
                          inputs: session?.edit.decodeInputs ?? .asShot)
    }

    /// The rung key, the decode inputs and the scale of the development this loupe would ask for
    /// right now — the diagnostic line `--ui-smoke` prints to tell "the development happened" from
    /// "the frame looked itself up under another key" (派单 011).
    public var currentDevelopmentDescription: String? {
        let base: String
        if let source = frameSource {
            base = source.identity
        } else if let asset = session?.anchorAsset {
            base = ladderIdentity(asset)
        } else {
            return nil
        }
        let inputs = (frameSource?.edit ?? session?.edit ?? .neutral).decodeInputs
        return "\(inputs.appending(to: base)) · wb=\(inputs.whiteBalance.summary)"
            + " · key=\(inputs.key)"
    }

    // MARK: frame

    /// One development, wrapped as a rung.
    ///
    /// This is the decode queue's unit of work and the only place the loupe opens a file: a frame
    /// calls it only on the synchronous path (`--ui-smoke`, tests), never from the render queue. A
    /// fresh `RAWDecoder` per development is deliberate — one `CIContext` and one Metal command queue
    /// per development, so the decode queue never shares GPU state with the render queue.
    ///
    /// 派单 011: `inputs` is **not** defaulted. It used to be `whiteBalance: WhiteBalance = .asShot`,
    /// and a call site that forgot it developed the as-shot buffer while the document asked for
    /// 5500 K — the failure looked exactly like "the decoder ignored the white balance". The decode
    /// inputs now come from the job's document, and a missing argument is a compile error.
    static func develop(url: URL, scale: Float, inputs: DecodeInputs) throws -> DecodeRung {
        let decoder = try RAWDecoder()
        let t0 = CFAbsoluteTimeGetCurrent()
        let developed = try decoder.decodeDetailed(url, options: DecodeOptions(decoderVersion: inputs.decoderVersion,
                                                                              exposureEV: 0,
                                                                              scale: scale,
                                                                              whiteBalance: inputs.whiteBalance))
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

    private func makeFrame(url: URL, cacheIdentity baseIdentity: String, viewport: ImageSize,
                           decodeScale: Float, edit model: EditModel, state: LoupeViewState,
                           hashPixels: Bool, resolve: RungResolution = .developIfMissing) throws -> FrameResult {
        let ds = Double(max(decodeScale, 0.01))
        // 派单 011: the white balance is a **decode** input, so it is part of the *rung*, not of the
        // render — a 2850 K document is a different development, never the as-shot buffer re-tinted
        // in S1 (S1 is identity there). `DecodeInputs` is the only thing allowed to name a buffer;
        // exposure/contrast/curve/colour never enter this identity, which is why changing them can
        // never develop.
        let inputs = model.decodeInputs
        let cacheIdentity = Self.rungIdentity(baseIdentity, inputs: inputs)
        // ── the decode ladder (§11.10) ───────────────────────────────────────────────────────
        // One photo, one development per rung. Keyed by (photo, scale), so the second visit to fit
        // or to 1:1 is a render and nothing else. `residentOnly` frames (every frame the loupe's
        // queues produce) never develop: the rung they want was requested from the decode queue by
        // the caller, and a miss here means the very first development of a photo has not landed.
        let outcome: (rung: DecodeRung, cached: Bool)
        switch resolve {
        case .developIfMissing:
            outcome = try ladder.rung(identity: cacheIdentity, scale: decodeScale) {
                try Self.develop(url: url, scale: decodeScale, inputs: inputs)
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
            // A new photo (or a new rung of it): its key is a different picture, so the measurement
            // armed below is a fresh one — the card must not keep the previous picture's numbers.
            lastFrameState = nil
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
        // The histogram's trigger (005, 2026-10-26). A frame measures **nothing**: the numbers are of
        // the picture, so this frame only reports whether the picture's key moved away from what the
        // card is showing — a new photo, a new rung, an edit — and the debounced measurement is armed
        // for that key. A pan or a zoom changes the camera and not the key, which is the whole reason
        // a gesture no longer costs a histogram.
        noteHistogramKey(identity: cacheIdentity, edit: model, fallbackScale: decodeScale)
        let result = try graph.render(model, options: RenderOptions(
            canvas: viewport,
            scale: scale,
            outputWindow: outputWindow,
            display: DisplayOptions(primaries: primaries, bitDepth: 8, headroom: ceiling),
            useCache: true,
            wantsPixels: false))
        let renderMs = (CFAbsoluteTimeGetCurrent() - t1) * 1000
        histogramSkippedFrames += 1
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
                           clipped: clipped)
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

    private func present(frame: FrameResult, renderMilliseconds: Double, state: LoupeViewState,
                         graph graphOverride: RenderGraph? = nil, underBridge: Bool = false,
                         resetTransformAfterPresent: Bool = false) {
        guard let presenter else {
            lastPresentError = "no Metal presenter"
            return
        }
        // A frame that lands while the bridge is still moving is the right picture at the wrong
        // time. Presenting it now would cut the motion off at whatever scale the composite happens
        // to be at — from a resident rung that is ~10 ms into a 180 ms slide, i.e. 1 % of the way —
        // which is exactly the cut this whole mechanism exists to remove, only at a random scale.
        //
        // So it is **held**: the canvas keeps the picture the eye is following, the frame waits, and
        // `finishZoomBridge` hands it to this same function when the geometry arrives. Holding is not
        // discarding — the generation gate upstream has already decided this frame is the current
        // one — and nothing renders twice: `present` remains the single path to the layer.
        if zoomBridge != nil, !underBridge {
            if let old = pendingFrame {
                // Superseded either way: a frame for the same camera that arrived later is the
                // better one, and a frame for a camera we are no longer going to is not ours.
                if old.state != state { zoomBridgePendingDrops += 1 }
                if let graph = old.graph { queue.async { graph.recycle(output: old.frame.texture) } }
            }
            pendingFrame = (frame, graphOverride ?? graph, renderMilliseconds, state)
            zoomBridgeCoveredPresents += 1
            return
        }
        let graphAtFrame = graphOverride ?? graph
        let t0 = CFAbsoluteTimeGetCurrent()
        let ok = presenter.present(frame.texture, in: canvasView.metalLayer,
                                   wantsEDR: wantsExtendedDynamicRange) { [weak self] in
            guard let self else { return }
            // The drawable is on the layer now: only here is the bridged geometry safe to drop.
            if resetTransformAfterPresent {
                DispatchQueue.main.async { self.removeZoomBridgeAnimation() }
            }
            guard let graphAtFrame else { return }
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
            if resetTransformAfterPresent { removeZoomBridgeAnimation() }
            return
        }
        if !ok {
            lastPresentError = presenter.lastFailure
            if let graphAtFrame { queue.async { graphAtFrame.recycle(output: frame.texture) } }
            if resetTransformAfterPresent { removeZoomBridgeAnimation() }
            retryPresentLater()
            return
        }
        presentRetries = 0
        // These pixels are now what the canvas carries, and they were laid out for `state` — the
        // projection a later bridge has to start from.
        if let mapping = framing(viewport: frame.canvas)?.mapping(of: state) {
            canvasContent = (mapping, frame.content)
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

    /// Retries already spent on a frame the canvas refused to take.
    private var presentRetries = 0
    /// Hard cap: a canvas that never becomes drawable (a headless test surface, a window that is
    /// never ordered in) must not keep a render loop alive.
    private static let maxPresentRetries = 4

    /// The canvas had no drawable yet — which is what the **first** frame after entering the loupe
    /// meets, because a `CAMetalLayer` hands out drawables only once it is in a visible window with a
    /// size. Without this the photo stayed black until any camera change re-rendered it (the reported
    /// bug: "点进编辑界面不会自动加载照片，得缩放一下"), since a settled layout schedules no further
    /// frame.
    ///
    /// Four attempts, 120 ms apart, the same frame each time: long enough for a window being ordered
    /// in or a resize to settle, short enough that it never competes with a real gesture (any new
    /// request goes through the normal single-flight path and the counter resets on success).
    private func retryPresentLater() {
        guard presentRetries < Self.maxPresentRetries, autoRenderEnabled else { return }
        presentRetries += 1
        let attempt = presentRetries
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12 * Double(attempt)) { [weak self] in
            guard let self, self.lastFrame == nil || self.lastPresentError != nil else { return }
            self.scheduleRender()
        }
    }

    // MARK: measurements (histogram + clipping warning)
    //
    // Two different cadences live here now, and keeping them apart is the point of 005:
    //
    //   · the **clipping grid** is a property of the frame on screen — it marks *these* pixels — so it
    //     rides with the frame, and `recordMeasurements` publishes it from the presenting frame;
    //   · the **histogram** is a property of the picture, so it has its own render, its own key and its
    //     own debounce. No frame carries one (`noteHistogramKey(identity:edit:fallbackScale:)`).
    //
    // Called from `present`; `--ui-smoke` calls the same function for a frame it rendered
    // synchronously, so the card is asserted through the shipped path rather than a test-only one.

    public func recordMeasurements(_ frame: FrameResult) {
        if let clipped = frame.clipped {
            lastClipped = clipped
            highlightOverlay.grid = clipped
        } else if !(session?.highlightWarning ?? false) {
            lastClipped = nil
            highlightOverlay.grid = nil
        }
        highlightOverlay.isArmed = session?.highlightWarning ?? false
    }

    /// Hand a measurement to the card. One function, so "the session has new numbers", "the card has
    /// them" and the publish count cannot disagree.
    private func publish(histogram: Histogram, key: String) {
        session?.recordHistogram(histogram)
        lastHistogram = histogram
        histogramMeasuredKey = key
        histogramPublishCount += 1
        histogramCollectedFrames += 1
    }

    // MARK: the histogram's key, cache and debounce (005, 2026-10-26)
    //
    // Q30 measured a *frame* and had to answer "is the camera still?" with 60 ms of quiet. The
    // measurement is of the picture now, so the question changed: "is the picture still?" — and a
    // picture is named by a key, not by a camera. Three rules, and no timestamps in the frame path:
    //
    //   · a frame computes the key of the picture it drew (`Histogram.cacheKey`: rung identity + edit
    //     digest + bins) and compares it with what the card is showing;
    //   · a *different* key arms the debounce (`histogramDebounceInterval`, 120 ms), which is where a
    //     slider drag collapses into one measurement;
    //   · the same key measures nothing — which is why panning and zooming, which cannot change the
    //     key, cost no measurement at all (they used to cost 8 ms per frame in release, 104 ms in a
    //     debug build).
    //
    // The measurement runs on the render queue (it uses that graph's pool and the ladder), presents
    // nothing, publishes on main, and is cached by key so sliding a slider back is instant.

    /// The key the picture would be measured under right now.
    ///
    /// The rung is the **biggest one the ladder has**, not the one this frame renders from: a frame at
    /// fit may render from the preview rung while 1:1 renders from the full one, and if the key carried
    /// the frame's rung the card would re-measure — with slightly different numbers — every time the
    /// zoom changed. The ladder keeps one rung in practice (`RenderJob.target` is always full scale),
    /// so this is the same buffer at every zoom; `fallbackScale` is only used before the first rung
    /// lands, and the key changes (and re-measures once) when the real one does.
    private func histogramKey(identity: String, digest: String, fallbackScale: Float) -> String {
        let rung = ladder.best(identity: identity, atOrBelow: DecodeLadder.fullScale)?.scale
            ?? fallbackScale
        return Histogram.cacheKey(rungIdentity: "\(identity)-s\(rung)",
                                  editDigest: digest, bins: 256)
    }

    /// The document's digest, memoised against the document itself (render queue only).
    private func cachedEditDigest(_ edit: EditModel) -> String {
        if let cached = lastEditDigest, cached.edit == edit { return cached.digest }
        let digest = Histogram.editDigest(edit)
        lastEditDigest = (edit, digest)
        return digest
    }

    /// Called by every frame: arm the measurement only if the picture's key moved.
    ///
    /// This is the whole decoupling: a pan changes `state`, `scale`, `outputWindow` and the canvas, and
    /// none of them is in the key, so a gesture reaches this function and does nothing.
    private func noteHistogramKey(identity: String, edit: EditModel, fallbackScale: Float) {
        guard collectsHistogram else { return }
        let key = histogramKey(identity: identity, digest: cachedEditDigest(edit),
                               fallbackScale: fallbackScale)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.collectsHistogram else { return }
            guard key != self.histogramMeasuredKey, key != self.histogramPendingKey else { return }
            self.histogramPendingKey = key
            self.histogramStaleAt = CFAbsoluteTimeGetCurrent()
            self.scheduleHistogramRefresh()
        }
    }

    /// Arm (or re-arm) the debounce. Every key change pushes the deadline out.
    private func scheduleHistogramRefresh() {
        guard collectsHistogram, autoRenderEnabled else { return }
        histogramSettle?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.startHistogramRefresh() }
        histogramSettle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + histogramDebounceInterval, execute: work)
    }

    private func startHistogramRefresh() {
        histogramSettle = nil
        guard collectsHistogram, let key = histogramPendingKey else { return }
        guard autoRenderEnabled, let job = makeJob(kind: .scheduled) else { return }
        // A measurement is of the picture, so it does not need the frame queues to be idle — only the
        // same picture to still be the one on screen.
        guard !histogramRefreshing, isCurrentPhoto(job.identity) else { return }
        histogramRefreshing = true
        queue.async { [weak self] in self?.renderHistogramRefresh(job, key: key) }
    }

    /// The measurement itself: a whole-picture thumbnail render, on the render queue.
    ///
    /// It does not go through `makeFrame`: that path is the *camera* — a window into the frame, a rung
    /// chosen for the zoom, a presented texture. This one wants the whole picture at a fixed scale, and
    /// `RenderGraph.measureHistogram` is exactly that.
    private func renderHistogramRefresh(_ job: RenderJob, key: String) {
        let t0 = CFAbsoluteTimeGetCurrent()
        var histogram: Histogram?
        var failure: String?
        if let cached = histogramCache[key] {
            histogram = cached
        } else if let rung = ladder.best(identity: job.identity, atOrBelow: DecodeLadder.fullScale) {
            do {
                let identity = "\(job.identity)-s\(rung.scale)"
                // Reuse the frame's graph when it is the same source (the common case: the ladder holds
                // one rung), so the measurement costs one thumbnail render and no texture upload. A
                // different rung builds a throwaway graph, whose source texture and pool go away with it.
                let measurer: RenderGraph
                if graphIdentity == identity, let existing = graph {
                    measurer = existing
                } else {
                    measurer = try RenderGraph(input: RenderInput(image: rung.image,
                                                                  identity: identity,
                                                                  sourceURL: job.url))
                }
                histogram = try measurer.measureHistogram(job.edit, bins: 256,
                                                          headroom: displayHeadroom.headroom)
            } catch {
                failure = "\(error)"
            }
        } else {
            // Nothing developed at or below the full rung yet: the picture that would be measured is
            // not the picture on screen. Keep the numbers and retry when the rung lands (the next frame
            // re-arms, because the key still differs from `histogramMeasuredKey`).
            failure = "no decoded rung at or below 1.0× yet"
        }
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        if let histogram { store(histogram: histogram, for: key) }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.histogramRefreshing = false
            self.lastHistogramMilliseconds = ms
            self.lastHistogramError = failure
            guard let histogram else {
                // Keep the card's numbers and stay pending: the next frame's key check re-arms this.
                return
            }
            guard self.histogramPendingKey == key else { return }   // superseded while measuring
            self.histogramRefreshCount += 1
            self.publish(histogram: histogram, key: key)
            self.histogramPendingKey = nil
            self.lastHistogramLatency = (CFAbsoluteTimeGetCurrent() - self.histogramStaleAt) * 1000
        }
    }

    /// The measurement, synchronously, on the caller's thread — the smoke's and the tests' path into
    /// the same numbers the card gets.
    ///
    /// It resolves the rung itself (developing the preview if nothing is resident) and publishes, so a
    /// caller only has to say *what* it wants measured. It is deliberately not the debounced path: a
    /// test wants the measurement now, and calling twice must produce the same bins — which it does,
    /// because the picture is the only input (`Histogram.cacheKey` is what the debounced path keys on).
    ///
    /// Main thread only: it publishes to the session and to `lastHistogram`.
    @discardableResult
    public func measureHistogramNow(asset: Asset, url: URL, edit: EditModel,
                                    bins: Int = 256) throws -> Histogram {
        // 派单 011 B: the identity below appends the decode inputs **once**. The asset overload used
        // to append them and then hand the result to the `identity:` overload, which appended them
        // again — the card's key was `…|wb=3000K/+0|wb=3000K/+0`. It is the same picture either way,
        // so nothing looked broken, which is exactly why a doubled key survives in a cache.
        try measureHistogramNow(url: url, identity: ladderIdentity(asset), edit: edit, bins: bins)
    }

    @discardableResult
    public func measureHistogramNow(url: URL, identity: String, edit: EditModel,
                                    bins: Int = 256) throws -> Histogram {
        // The measurement is of the *picture*, so it names the buffer the same way a frame does:
        // `DecodeInputs` on top of the bare photo identity.
        let inputs = edit.decodeInputs
        let identity = Self.rungIdentity(identity, inputs: inputs)
        let outcome = try ladder.rung(identity: identity, scale: DecodeLadder.fullScale) {
            try Self.develop(url: url, scale: DecodeLadder.fullScale, inputs: inputs)
        }
        let graphIdentityForRung = "\(identity)-s\(outcome.rung.scale)"
        let measurer: RenderGraph
        if graphIdentity == graphIdentityForRung, let existing = graph {
            measurer = existing
        } else {
            measurer = try RenderGraph(input: RenderInput(image: outcome.rung.image,
                                                          identity: graphIdentityForRung,
                                                          sourceURL: url))
        }
        let histogram = try measurer.measureHistogram(edit, bins: bins,
                                                     headroom: displayHeadroom.headroom)
        let key = histogramKey(identity: identity, digest: Histogram.editDigest(edit),
                               fallbackScale: outcome.rung.scale)
        store(histogram: histogram, for: key)
        publish(histogram: histogram, key: key)
        return histogram
    }

    /// Cache one measurement under its key, newest last, at most `histogramCacheLimit` of them.
    private func store(histogram: Histogram, for key: String) {
        histogramCache[key] = histogram
        histogramCacheOrder.removeAll { $0 == key }
        histogramCacheOrder.append(key)
        while histogramCacheOrder.count > histogramCacheLimit {
            let victim = histogramCacheOrder.removeFirst()
            histogramCache.removeValue(forKey: victim)
        }
        _ = histogramCacheLimit
    }

    // MARK: status strip

    private func updateStatusChip() {
        statusChip.text = statusText
        statusChip.tooltip = displayHeadroom.detailText
        layoutStatusChip()
        syncZoomSlider()
    }

    private func layoutStatusChip() {
        statusChip.layout(in: container.bounds)
    }

    // MARK: the fixed-stop zoom slider (canvas, bottom-right)

    private func layoutZoomSlider() {
        zoomSlider.layout(in: container.bounds)
    }

    /// Push the camera into the pill: the readout, the tick tints and the thumb.
    ///
    /// Every camera change already runs through `updateStatusChip()` (`setViewState` is the single
    /// writer of `viewState`), so ⌘=, ⌘−, the wheel, a pinch and ⌘0 all land here — the pill can
    /// never disagree with the canvas about where the camera is.
    private func syncZoomSlider() {
        // `currentZoomStop` is nil exactly in fit; the fit ratio is passed only so the thumb can be
        // *displayed* at its continuous position — it is never a snap target.
        zoomSlider.update(zoomStop: currentZoomStop, fitZoom: framing()?.fitZoom)
    }

    /// Slider-originated zoom: **always around the canvas centre**.
    ///
    /// Deliberately *not* `zoom(to:)`: that one anchors on `cursorAnchor()`, and while the pointer
    /// is on the slider it is not over the canvas at all, so a cursor anchor would name a stale or
    /// nonsense pixel. "通过滑动条缩放默认从中心" — the picture grows around the middle of the
    /// viewport.
    ///
    /// ⌘= / ⌘− / 显示 ▸ 倍率 / the wheel / the pinch keep their cursor anchor (the behaviour the
    /// user has already signed off on). This is the only entry point that is centred — do not
    /// "unify" the two.
    public func zoomFromSlider(to stop: Double) {
        // `nil` → `canvasCentrePoint()` inside `zoom(to:aroundView:)`.
        zoom(to: stop, aroundView: nil)
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
