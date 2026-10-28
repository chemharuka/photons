import AppKit
import QuartzCore
import CryptoKit
import Metal
import PhotonsCore
import PhotonsCatalog

extension NSColor {
    /// 054 — the colour of the canvas around the picture: `#0F0F0F`, from
    /// `CanvasPresenter.CanvasMatte` and nowhere else.
    ///
    /// The bands around a fitted photograph are painted by the present pass (they live *in* the canvas
    /// texture — S2/S4 write 0 there), so this colour is only what shows while there is no drawable
    /// yet, or behind a layer that has not been drawn into. It is the same value as the fragment's
    /// matte and the pass's clear colour so the canvas cannot flash black on its way to grey.
    static let canvasMatte = NSColor(srgbRed: CGFloat(CanvasPresenter.CanvasMatte.displayEncoded),
                                     green: CGFloat(CanvasPresenter.CanvasMatte.displayEncoded),
                                     blue: CGFloat(CanvasPresenter.CanvasMatte.displayEncoded),
                                     alpha: 1)
}

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
    private var isDraggingHandle = false
    /// A 裁切 drag (task 035): the frame's grip, its inside, or a new frame. The draft it moves lives
    /// in `CropToolController`; this is only "the hand is down".
    private var isCropDragging = false

    public init() {
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        // The canvas is the matte surface the photo sits on, so a fit photo reads as a photo. 054: it
        // is `#0F0F0F`, the same value the present pass paints outside the picture — this colour is
        // only seen before the first drawable arrives.
        metalLayer.backgroundColor = NSColor.canvasMatte.cgColor
        metalLayer.isOpaque = true
    }

    public required init?(coder: NSCoder) { fatalError("no nibs in this app") }

    public override func makeBackingLayer() -> CALayer { CAMetalLayer() }

    public override func layout() {
        super.layout()
        // **The layer's geometry is pinned here, not assumed.** `LoupeZoomBridge.transform` conjugates
        // its translation by `anchorPoint · (W, H)`, and a view's backing layer has
        // `anchorPoint == (0, 0)` (not the `CALayer` default `(0.5, 0.5)`), so the composite scales
        // about the bottom-left corner unless the two agree. Saying it once, where the frame is set,
        // means the animation and the `layout` cannot disagree; `isGeometryFlipped` follows the view,
        // so a 180° picture cannot appear if AppKit ever stops setting it for a flipped view.
        metalLayer.anchorPoint = .zero
        metalLayer.frame = bounds
        metalLayer.isGeometryFlipped = isFlipped
        // A stop change used to scale this layer (`CATransform3D`), and a scaled layer paints outside
        // its view: the drawable covered the browser pane mid-zoom. Nothing transforms the layer now —
        // a bridge re-presents the texture through a sampling window instead — and this makes the
        // guarantee structural: whatever the canvas holds, it cannot draw past its own bounds.
        metalLayer.masksToBounds = true
        let scale = window?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        if metalLayer.drawableSize == .zero {
            metalLayer.drawableSize = CGSize(width: max(1, bounds.width * scale),
                                             height: max(1, bounds.height * scale))
        }
    }

    public override var acceptsFirstResponder: Bool { true }

    // MARK: live resize (067)
    //
    // A window drag delivers a layout pass per frame, and every pass used to ask for a render: a
    // dozen stale renders of a 60 MP frame, each presented with `nextDrawable()` on the main thread.
    // That is the freeze the user reported. 067's rule is stronger than coalescing — **nothing is
    // rendered while the hand is moving**: the picture already on the canvas is re-drawn with the
    // geometry it was drawn with (cropped when the window shrinks, the low-res backdrop in the area
    // a grown window exposes), and the one render for the size the hand stopped on is requested when
    // the drag ends.
    //
    // AppKit already tells a view both edges of a live resize, and `inLiveResize` covers the passes in
    // between, so the controller never has to guess from a size delta.
    public override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        controller?.beginLiveResize()
    }

    public override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        controller?.endLiveResize()
    }

    // MARK: the pointer (one source for the zoom anchor *and* the histogram readout)
    //
    // Two features ask "where is the pointer, and what is under it": the zoom commands anchor on that
    // pixel, and the histogram card reports it. They must not track separately — a second source would
    // be a second coordinate conversion, and the whole class of bug in this file is a coordinate
    // conversion that is right in one place and wrong in the other. So the view owns **one** tracking
    // area, and every event it delivers goes to `controller.pointerMoved(to:)`; `cursorAnchor()` and the
    // histogram row both read the value that call stores.
    //
    // `.inVisibleRect` (the rect is maintained by AppKit on resize, so no `updateTrackingAreas`
    // bookkeeping), `.activeInKeyWindow` (a loupe in a background window is not being pointed at), and
    // `.mouseEnteredAndExited` for the two edges. A tracking area is per-view and per-window, so this
    // is rebuilt by `updateTrackingAreas`, which AppKit calls on every layout.

    private var pointerTrackingArea: NSTrackingArea?

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTrackingArea {
            removeTrackingArea(pointerTrackingArea)
            self.pointerTrackingArea = nil
        }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .mouseEnteredAndExited,
                                            .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        pointerTrackingArea = area
    }

    /// A tracking area only gets `.mouseMoved` while the window accepts move events; nothing here
    /// depends on the flag being false, and both consumers of the pointer depend on it being true.
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        // Off screen (a new photo, the loupe going away): there is no pointer to report, and a stale
        // one would leave the histogram row reading a pixel of a picture that is no longer there.
        if window == nil { controller?.pointerExited() }
        updateTrackingAreas()
    }

    public override func mouseMoved(with event: NSEvent) {
        controller?.pointerMoved(to: convert(event.locationInWindow, from: nil))
    }

    public override func mouseEntered(with event: NSEvent) {
        controller?.pointerMoved(to: convert(event.locationInWindow, from: nil))
    }

    public override func mouseExited(with event: NSEvent) {
        controller?.pointerExited()
    }

    // MARK: 1:1 / pan / pinch

    /// Z or space: fit ↔ 1:1. Escape: back to fit.
    public override func keyDown(with event: NSEvent) {
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        // 裁切模式 (task 035) owns the keyboard while it is on: ↵ applies (one commit), Escape drops
        // the draft (nothing written). Everything else keeps falling through, so ⌘Z, ⌘0 and the
        // rating keys still work with the frame on screen.
        if controller?.isCropToolActive == true {
            switch key {
            case "\u{1b}":
                controller?.cancelCropTool()
                return
            case "\r", "\u{3}":
                controller?.applyCropTool()
                return
            default:
                break
            }
        }
        switch key {
        case "z", " ":
            controller?.toggleActualSize()
        case "\u{1b}":
            // Escape abandons a gradient drag before it becomes a mask, drops a control-point drag
            // (task 032: nothing is written, nothing is committed), disarms the eyedropper, and
            // otherwise means "fit".
            if controller?.isEyedropperArmed == true { controller?.cancelEyedropper() }
            else if isDraggingHandle { isDraggingHandle = false; controller?.cancelMaskHandleDrag() }
            else if isShaping { isShaping = false; controller?.cancelShapeDrag() }
            else { controller?.zoomToFit() }
        default:
            super.keyDown(with: event)
        }
    }

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        // 080: the 分屏 line is chrome the user placed, so it is the innermost gesture on the canvas —
        // a drag that starts on it moves the line and never pans the picture or paints a mask.
        if controller?.beginCompareDrag(atViewPoint: point) == true { return }
        switch controller?.gestureOwner(atViewPoint: point, clickCount: event.clickCount) {
        case .cropTool:
            isCropDragging = controller?.beginCropDrag(
                atViewPoint: point,
                rotate: event.modifierFlags.contains(.command)) ?? false
            return
        case .cropToolApply:
            controller?.applyCropTool()
            return
        case .eyedropper:
            // 派单 009 C: the eyedropper is a modal one-shot, so it is the innermost gesture of all —
            // it consumes the click before a paint drag or a pan can start.
            controller?.handleEyedropperClick(atViewPoint: point)
            return
        case .healClick:
            // 2026-10-28 (078 P0-1): also a one-shot — the click places one spot and consumes
            // nothing else (the tool stays armed, which is what makes clipping several blemishes in a
            // row one action per click).
            controller?.addHealSpot(atViewPoint: point)
            return
        case .maskCreate:
            // A gradient drag is the innermost mask gesture: it exists only while a shape is armed,
            // and it is what turns two clicks into a linear ramp / an ellipse.
            isShaping = true
            controller?.beginShapeDrag(at: point)
            return
        case .maskHandle:
            // Control points (task 032) come **before** the blanket "drag adjusts the selected
            // gradient" gesture: a hand that lands on a grip means "move this grip", so the click
            // must be taken here. A miss falls through to the adjust drag, and then to the pan — a
            // grip never turns into a pan, and the empty canvas still pans.
            // (`gestureOwner` is the pure hit test; this is the side effect that takes the grip.)
            isDraggingHandle = controller?.beginMaskHandleDrag(atViewPoint: point) ?? false
            return
        case .maskShape:
            isShaping = true
            controller?.beginShapeDrag(at: point)
            return
        case .paint:
            // A paint drag is a paint drag: it never pans, and a double-click while a brush is armed
            // is two dabs rather than a zoom.
            isPainting = true
            controller?.beginPaint(at: point, pressure: Self.pressure(of: event))
            return
        case .doubleClick:
            controller?.handleDoubleClick(at: point)
            return
        case .pan, .none:
            isDragging = true
            lastDragPoint = event.locationInWindow
        }
    }

    public override func mouseDragged(with event: NSEvent) {
        // A drag moves the pointer too: the histogram row follows the pixel under it, and the anchor a
        // ⌘= would use after a pan is where the hand left the cursor.
        controller?.pointerMoved(to: convert(event.locationInWindow, from: nil))
        if isCropDragging {
            // 裁切 (task 035): the frame follows the hand and **nothing is written** — the draft
            // lives in the tool until ↵.
            controller?.continueCropDrag(atViewPoint: convert(event.locationInWindow, from: nil))
            return
        }
        if controller?.isDraggingCompare == true {
            controller?.continueCompareDrag(atViewPoint: convert(event.locationInWindow, from: nil))
            return
        }
        if isShaping {
            controller?.continueShapeDrag(at: convert(event.locationInWindow, from: nil))
            return
        }
        if isDraggingHandle {
            // ⇧ keeps an ellipse's aspect while a rim is dragged (`MaskHandleDrag.shape(uniform:)`).
            controller?.continueMaskHandleDrag(atViewPoint: convert(event.locationInWindow, from: nil),
                                               uniform: event.modifierFlags.contains(.shift))
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
        if controller?.isDraggingCompare == true {
            controller?.endCompareDrag()
            return
        }
        if isCropDragging {
            isCropDragging = false
            controller?.endCropDrag()
            return
        }
        if isDraggingHandle {
            isDraggingHandle = false
            controller?.endMaskHandleDrag()
            return
        }
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
    ///
    /// ⑤/⑥ — the 裁切 gate that used to be here is gone. The camera is **view state**: a two-finger
    /// scroll through this method is the same `scrollPan` the loupe mode gets (same deltas, same
    /// anchor, same clamp), a wheel is the same event, and the frame over the picture is re-laid-out
    /// by `setViewState` → `syncCropOverlay` in the same turn. Locking the picture down while the tool
    /// was on never protected the document either: nothing here can write one.
    public override func scrollWheel(with event: NSEvent) {
        controller?.scrollPan(deltaX: event.scrollingDeltaX,
                             deltaY: event.scrollingDeltaY,
                             precise: event.hasPreciseScrollingDeltas,
                             inverted: event.isDirectionInvertedFromDevice)
    }

    /// ⑥ — the pinch is the loupe's zoom, crop mode included (`magnify(by:at:)` is the same ladder and
    /// the same pointer anchor the loupe mode uses).
    public override func magnify(with event: NSEvent) {
        controller?.magnify(by: 1 + event.magnification,
                            at: convert(event.locationInWindow, from: nil))
    }

    /// The interface M3 left inert, now the real thing: 1:1 in the middle of the frame.
    public func zoomToActualSize() { controller?.zoomToActualSize() }

    /// What the cursor should say: a crosshair for a brush, a pointing hand only when there is
    /// something to drag.
    public override func resetCursorRects() {
        if controller?.isCropToolActive == true {
            // Every point of the canvas is the frame's: corners and edges resize, inside moves the
            // picture, outside starts a new frame. A crosshair says "this is a tool surface".
            addCursorRect(bounds, cursor: .crosshair)
            return
        }
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

// MARK: - gesture ownership

/// Who owns a press on the canvas — the answer `LoupeCanvasView.mouseDown` switches on.
///
/// One enum instead of a chain of `if`s in the view, so the priority is a single readable list and a
/// test can ask the question without an `NSEvent` (task 035's 手势优先级 criterion, and the reason
/// task 032's grip test could be written at all).
public enum LoupeCanvasGesture: Equatable, Sendable {
    /// The crop frame (task 035). Everything else is unreachable while the tool is on.
    case cropTool
    /// A double-click inside the crop frame: 应用.
    case cropToolApply
    case eyedropper
    /// Two clicks will become a gradient.
    case maskCreate
    /// A knob on the selected mask.
    case maskHandle
    /// Dragging adjusts the selected mask's geometry.
    case maskShape
    /// 2026-10-28 (078 P0-1) — a click while the 修复画笔 is armed: one spot, at the click.
    ///
    /// Its own case rather than a corner of `.paint`: a spot is placed by a **click**, not a stroke,
    /// and the two must not share a state machine (a drag with the heal tool armed pans, which is
    /// what a one-shot tool should do).
    case healClick
    case paint
    case doubleClick
    case pan

    /// The crop tool's own split (task 035 §2): a double-click **inside** the frame applies it;
    /// everything else — a corner, an edge, the inside of a single click, the outside — is a drag.
    ///
    /// Pure and static so the rule can be asserted without a canvas, a click or a photo: the router
    /// (`LoupeController.gestureOwner`) is the only caller, so what a test reads is what ships.
    public static func crop(clickCount: Int, hit: CropToolHandle?) -> LoupeCanvasGesture {
        if clickCount >= 2, hit == .inside { return .cropToolApply }
        return .cropTool
    }
}

/// What a frame the loupe asks for is **of** (080).
///
/// One enum rather than two booleans, because 「显示原图」 and 前后对比 are not independent: the compare
/// mode is a split between the same two pictures `\` chooses between, and a state machine with four
/// reachable combinations (both off, one on, the other on, both on) has three behaviours to define
/// and one of them is nonsense. Here the precedence is total and testable:
/// `showOriginal` wins over 对比 (「先看原图」 is a request to see one picture), and 对比 wins over
/// nothing.
public enum LoupeFrameMode: Equatable, Sendable {
    /// The document, as edited.
    case edited
    /// `\` — the decode, display-encoded (`RenderSource.decoded`).
    case original
    /// Before/after: the decode on one side of a draggable line, the document on the other.
    case compare(CompareSplit)

    public var isOriginal: Bool { self == .original }
    public var compareSplit: CompareSplit? {
        if case .compare(let split) = self { return split }
        return nil
    }

    public var label: String {
        switch self {
        case .edited: return "编辑后"
        case .original: return "原图"
        case .compare: return "前后对比"
        }
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

public final class LoupeController: NSViewController, HeadroomSource {

    public struct FrameResult {
        public let texture: MTLTexture
        public let canvas: ImageSize
        public let content: ImageSize
        /// 054: where the photograph sits inside `texture`, in canvas pixels — `RenderResult.photoRect`,
        /// carried so the present pass can paint the canvas matte (`#0F0F0F`) around the picture and
        /// never over it. The letterbox bands are *in* the texture (S2/S4 write 0 outside the picture), so
        /// this rect is the only thing that says where they are.
        public let photoRect: ImageRect
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

        // There is deliberately no `histogram` field (005; 034 kept the rule and changed who measures
        // it). A frame is the window the camera is showing and the card's numbers are of the
        // *picture*: carrying one here would make it possible for a later caller to publish a
        // per-frame plot. Since 034 the controller measures the frame **on its way out**
        // (`histogramStep`), measures only frames that hold the whole picture, and publishes to
        // `LoupeController.lastHistogram` — the field would only be a second, staler copy.
        /// Clipped-pixel grid (the highlight warning's input), when the warning was armed. `nil`
        /// otherwise — the readback only happens when someone is looking at it.
        public let clipped: ClippedGrid?
        /// The **scene-linear sample the histogram was counted from** (2026-10-27), i.e. the picture's
        /// pixels before S4 at the measurement's ≤ 256-long-edge lattice. The pointer's readout reads
        /// this instead of `texture`, because `texture` is S4's output and S4 is
        /// `encode(min(v, headroom))`: on this panel everything above +1.98 stop left the frame as
        /// white. `nil` when no grid was asked for (nobody is reading the pointer, or the render had no
        /// picture rect), in which case the readout falls back to `texture` and says so
        /// (`PointerPixel.source`).
        public let sceneLinearSample: LinearSample?
        /// 080: what this frame is **of** — the document, the decode (`\`), or a before/after
        /// composite of the two. A frame's pixels are only half of what a caller needs to know: the
        /// pointer readout, the status strip and the tests all have to say whether the picture on the
        /// canvas is the edit or the original (`BeforeAfterUITests` reads this instead of inferring it
        /// from a hash).
        public let mode: LoupeFrameMode
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
    ///
    /// 派单 031: writing a frame source whose **detail amounts moved** is the harness spelling of "the
    /// user moved a 细节 slider" — it puts the frames on the preview rung and arms the "hand stopped"
    /// upgrade, exactly as `requestEditRender` does for a real drag. The settle's own re-render writes
    /// no new source, so it cannot re-arm itself.
    public var frameSource: FrameSource? {
        didSet {
            // 039 / 065: a different **photo** is a different picture, so the low-resolution backdrop is
            // released here (and, since 065b, the new photo's is asked for at once). An edit keeps the
            // identity (`contentHash|assetID`), so a slider never reaches this line — the digest half of
            // the key moves and only marks the texture stale.
            //
            // 065: releasing the texture was not enough. The same change also has to end whatever was
            // still running for the old picture — a development, a zoom bridge carrying its frame, the
            // frame that bridge is holding — which is exactly what `cancelPendingFrames` does, and it
            // is the one path both spellings of "a different photo" (this one, and the session's
            // anchor) go through.
            notePhotoIdentity(backdropPhotoKey)
            guard detailGesturing,
                  frameSource?.edit.detailSettings != oldValue?.edit.detailSettings else { return }
            detailPreview = true
            scheduleDetailSettle()
        }
    }

    /// Everything one frame needs, snapshotted on the main thread: the render queue must never read
    /// `session` itself (a slider would race it) and the decode queue must never read a view state.
    private struct RenderJob {
        /// Who asked for this frame. It decides which counter it lands in and — the part that is easy
        /// to get wrong — which single-flight flag it is allowed to release: a scheduled frame must not
        /// release a pan's flag, or a second pan frame could start while the first is still rendering
        /// and the newest camera would stop winning.
        enum Kind {
            case scheduled, view, edit
            /// 067: a frame the layout asked for because the canvas changed. Its own kind so it can be
            /// single-flight — one render at a time, at most one follow-up at the final size — while a
            /// *live* drag (which is the storm) asks for nothing at all.
            case resize
        }

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
        /// The rung this frame wants. `DecodeLadder.fullScale` for everything except a frame drawn
        /// while a 细节/降噪 slider is moving (派单 031): a detail change is a **new development**, so
        /// following the thumb at full size would put a 1–5 s 60 MP decode behind every tick. While
        /// the drag lasts the ladder is asked for the 0.5 rung only; 200 ms after the hand stops, a
        /// full-size frame is requested and replaces it.
        let target: Float
        /// The caller's frame generation. `var` because `scheduleRender` bumps the counter *after* it
        /// has decided there is something to draw, and the job it just built has to carry the new one.
        var generation: Int
        /// Only edit frames carry a slider timestamp.
        let changedAt: CFAbsoluteTime
        /// 080: what the frame is of, snapshotted with the document and the camera. A `\` or a
        /// 对比 drag that lands while a frame is in flight must not be undone by that frame
        /// presenting — the generation gate drops it, and this field is why the follow-up renders
        /// the right thing without reading the controller from the render queue.
        var mode: LoupeFrameMode = .edited

        /// The rung identity this job develops and renders from: the document's decode key on top of
        /// the photo identity. Derived from `edit`, never stored, so the two cannot drift.
        var identity: String { edit.decodeInputs.appending(to: baseIdentity) }
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
    /// The selected mask's control points (task 032) — grips and guides, drawn over the canvas and
    /// hit-tested by the controller (never by this view: `hitTest` is nil).
    private let maskHandlesOverlay = MaskHandlesOverlayView()
    /// 裁切框 (task 035) — the dimmed outside, the frame, its eight grips and the thirds grid. Same
    /// contract as the two above: `hitTest → nil`, and the positions come from `CropTool.layout`,
    /// i.e. from the one projection.
    private let cropOverlay = CropToolOverlayView()
    /// 裁切工具条: 比例 / 拉直 / 翻转 / 九宫格 / 应用 / 取消. The only chrome on the canvas that takes
    /// clicks, and it exists only while the tool is on.
    let cropBar = CropToolBar()

    /// The mask painter: pointer → sampled points → `Stroke` (Q22). Owned here because the paint
    /// gesture is a canvas gesture, and handed to the view so `mouseDown` knows which of the two
    /// gestures a drag is.
    public let maskCanvas: MaskCanvasController

    /// 旋转/裁切 (task 035). Owned here because the frame is a canvas gesture; the draft it edits is
    /// view state and never enters `EditModel` until 应用.
    public let cropTool: CropToolController

    // MARK: render plumbing

    private let queue = DispatchQueue(label: "photons.loupe.render", qos: .userInitiated)
    /// Developments, on their own serial queue (Q29). Nothing about a frame waits for it: this queue
    /// owns `RAWDecoder`, the render queue owns `RenderGraph`, and the only thing they share is the
    /// ladder's buffers (guarded by its own lock).
    private let decodeQueue = DecodeQueue(label: "photons.loupe.decode")
    private var presenter: CanvasPresenter?
    /// The layer's presenter, for a test that asserts on what reached the drawable (068). Read-only and
    /// `nil` only before `viewDidLoad` — the app never reaches for it.
    public var canvasPresenter: CanvasPresenter? { presenter }
    private var graph: RenderGraph?
    private var graphIdentity: String?
    /// 065: the **photo** `graph` was built from (`contentHash|assetID`, or a frame source's identity).
    ///
    /// The graph is the frame path's, and it is only replaced when a frame of the new photo is
    /// rendered — so between a photo switch and that first frame it still holds the previous picture's
    /// decoded pixels. The backdrop renders through this graph, which meant a request that outlived its
    /// photo could render **A's pixels through B's edit** and file the result under B's key: a backdrop
    /// that claims to be the new photo and is the old one. `renderBackdrop` compares this with the key.
    private var graphPhoto: String?

    /// 037 ② / 039 — the low-resolution **whole picture** the canvas draws outside a shrinking frame.
    ///
    /// Public so a test can read the state machine it is asserting (`generationCount`, `key`,
    /// `isIdle`); the GPU work stays in `renderBackdrop` because this class owns the graph and the
    /// queue. Nothing in the app reads it, and nothing here is a second render path: it is the same
    /// `RenderGraph.render`, at a smaller scale, once per dirty pointer entry.
    public let backdrop = BackdropCache()

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

    // MARK: - 080 · 原图 / 前后对比 (state)

    /// 「显示原图」(`\`). True while the canvas is showing the **decode** rather than the document.
    ///
    /// Nothing about this reaches `EditModel`, `CatalogSession` or the history: it is a fact about
    /// what the next frame is *of*, and the only thing it changes is `frameMode` — which the frame
    /// builder reads. That is the whole mechanism behind 「显示原图不写文档、不产生历史」.
    public private(set) var showOriginal = false

    /// The 前后对比 split, or `nil` when 对比 is off.
    ///
    /// Kept as a `CompareSplit` (axis + fraction) rather than a pair of numbers because the drag
    /// hands exactly that value to the composite, and the axis and the position have to travel
    /// together or a horizontal split can be dragged with the vertical arithmetic.
    public private(set) var compareSplit: CompareSplit?

    /// What the next frame will be of. `showOriginal` wins over 对比 (see `LoupeFrameMode`).
    public var frameMode: LoupeFrameMode {
        if showOriginal { return .original }
        if let split = compareSplit { return .compare(split) }
        return .edited
    }

    /// How many times the frame mode changed, and how many frames each mode produced — the numbers a
    /// test reads to tell "the toggle re-rendered once" from "the toggle started a loop".
    public private(set) var frameModeChanges = 0
    public private(set) var originalFrames = 0
    public private(set) var compareFrames = 0

    /// `\` — show the decode, or go back to the document.
    ///
    /// A toggle rather than a press-and-hold because AppKit cannot report a key *release* for a menu
    /// key equivalent: LR's `\` is a toggle too (press to see, press again), and the same verb is
    /// what the menu row offers. Returns the new state so a caller can assert it.
    @discardableResult
    public func toggleShowOriginal() -> Bool {
        setShowOriginal(!showOriginal)
        return showOriginal
    }

    @discardableResult
    public func setShowOriginal(_ on: Bool) -> Bool {
        guard on != showOriginal else { return showOriginal }
        showOriginal = on
        frameModeDidChange()
        return showOriginal
    }

    /// Y — before/after. Off → on splits the canvas at the current fraction (50 % the first time).
    @discardableResult
    public func toggleCompare() -> Bool {
        setCompare(compareSplit == nil)
        return compareSplit != nil
    }

    @discardableResult
    public func setCompare(_ on: Bool) -> Bool {
        if on {
            guard compareSplit == nil else { return true }
            compareSplit = lastCompareSplit ?? .half
        } else {
            guard let previous = compareSplit else { return false }
            lastCompareSplit = previous
            compareSplit = nil
        }
        frameModeDidChange()
        return compareSplit != nil
    }

    /// ⇧Y — 左右 ↔ 上下. Keeps the fraction, because the user is asking about the *layout* of the
    /// line they already placed.
    public func toggleCompareAxis() {
        guard var split = compareSplit else { return }
        split.axis = split.axis == .vertical ? .horizontal : .vertical
        compareSplit = split
        lastCompareSplit = split
        frameModeDidChange()
    }

    public func setCompareAxis(_ axis: CompareSplit.Axis) {
        guard var split = compareSplit, split.axis != axis else { return }
        split.axis = axis
        compareSplit = split
        lastCompareSplit = split
        frameModeDidChange()
    }

    /// Move the line. Called by the drag (and by the menu's 50 % row): **no document, no history, no
    /// decode** — a new line is a new composite of two textures that already exist, so it costs one
    /// render of the pair and nothing else.
    public func setCompareFraction(_ fraction: Double) {
        guard var split = compareSplit else { return }
        let next = min(max(fraction.isFinite ? fraction : 0.5, 0), 1)
        guard abs(next - split.fraction) > 1e-6 else { return }
        split.fraction = next
        compareSplit = split
        lastCompareSplit = split
        compareSplitDrags += 1
        frameModeDidChange()
    }

    /// The split a drag remembers when 对比 is switched off and on again.
    private var lastCompareSplit: CompareSplit?
    /// How many times the line moved — the counter 「拖动分界线不写文档」 is stated against.
    public private(set) var compareSplitDrags = 0

    /// A mode change is a new intent for the canvas: the in-flight frame (if any) belongs to the old
    /// one, so the generation moves and a frame is asked for. `autoRenderEnabled == false` (tests,
    /// `--ui-smoke`) means the caller drives the frames itself, and nothing is asked for here.
    ///
    /// The request is the camera path, not the edit path: 对比 and `\` change what a frame is *of*,
    /// never the document, so a mode change must not look like an edit (no latency sample, no
    /// settle frame) — and `requestViewportRender` coalesces, so a drag's hundreds of line positions
    /// cost one render at a time.
    private func frameModeDidChange() {
        frameModeChanges += 1
        generation += 1
        guard autoRenderEnabled else { return }
        requestViewportRender()
    }

    // MARK: - 080 · the divider drag

    /// True while the pointer is dragging the 分屏 line.
    public private(set) var isDraggingCompare = false

    /// How close to the line a click has to land, in points. Wide enough to grab with a mouse, narrow
    /// enough that a click meant for the picture (a pan, a mask) is not taken by the line.
    public static let compareGrabPoints = 9.0

    /// Where along the split axis a canvas point sits, 0…1.
    ///
    /// The canvas is drawn in **device pixels** (`viewportPixels`) and hit-tested in points
    /// (`LoupeCanvasView.isFlipped`, so view `y = 0` is the picture's top row). One conversion, used
    /// by the hit test and by the drag, so a line that is grabbable is also a line that moves where
    /// the hand is.
    public func compareFraction(atViewPoint point: CGPoint) -> Double {
        let bounds = canvasView.bounds
        guard bounds.width > 1, bounds.height > 1 else { return 0.5 }
        let x = Double(point.x / bounds.width)
        let y = Double(point.y / bounds.height)
        let fraction = (compareSplit?.axis ?? .vertical) == .vertical ? x : y
        return min(max(fraction, 0), 1)
    }

    /// Is this click on the line? `nil` (对比 off) is never a hit.
    public func compareDividerHit(atViewPoint point: CGPoint) -> Bool {
        guard let split = compareSplit else { return false }
        let canvas = viewportPixels
        let extent = split.axis == .vertical ? canvas.width : canvas.height
        guard extent > 0 else { return false }
        let lineFraction = Double(split.dividerPixel(canvas: canvas)) / Double(extent)
        let grab = Self.compareGrabPoints * backingScale / Double(extent)
        return abs(compareFraction(atViewPoint: point) - lineFraction) <= grab
    }

    /// A click on the line takes the drag. Returns `false` so the canvas's other gestures (pan, crop,
    /// paint) are untouched when the click was not on it.
    @discardableResult
    public func beginCompareDrag(atViewPoint point: CGPoint) -> Bool {
        guard compareDividerHit(atViewPoint: point) else { return false }
        isDraggingCompare = true
        return true
    }

    /// Move the line. Nothing is written: the document, the history and the decode ladder are not
    /// touched, and the frame that follows is a composite of two renders whose keys did not move.
    public func continueCompareDrag(atViewPoint point: CGPoint) {
        guard isDraggingCompare else { return }
        setCompareFraction(compareFraction(atViewPoint: point))
    }

    public func endCompareDrag() {
        isDraggingCompare = false
    }

    /// Ask for a histogram at all — the inspector card's switch.
    ///
    /// On by default because the card is always on screen in this build. What it does *not* mean is
    /// "measure every frame": since 005 the histogram is a measurement of the **picture**, so it is
    /// re-measured only when the picture's *key* changes — a new photo, a new decode rung, or an edit
    /// — and never because the viewport moved. Panning and zooming measure nothing at all
    /// (`histogramStep(for:from:...)`).
    ///
    /// Since 034 there is no debounce between the key change and the measurement: the numbers are
    /// read out of the frame that key change already produced (`RenderGraph.measureFrameHistogram`),
    /// so a slider drag moves the plot on the frame it draws. What is still skipped is everything a
    /// frame can be that is not news: the same key (a pan), or a frame that is only a *window* into
    /// the picture (1:1 and beyond).
    public var collectsHistogram = true

    /// Frames that **published nothing**: the picture's key had not moved (a pan or a zoom), the
    /// frame was a window into the picture, or the measurement failed.
    ///
    /// Kept as a counter (and asserted by the cadence tests) because "a gesture costs no histogram"
    /// is the claim this whole design rests on, and a counter cannot be talked out of the answer the
    /// way a frame time can.
    ///
    /// **034 changed what is counted.** It used to count *every* frame, because every frame measured
    /// nothing (the measurement was a separate render behind a debounce). Now a frame that measured
    /// its picture is not skipped, so for the frames a loupe drew: `frames == refreshed + cache hits
    /// + skipped`.
    ///
    /// **045**: a window frame is still counted here — *this frame* published nothing — but it now
    /// arms the background whole-picture measurement (`fullPictureSource` / `measureHistogram`) that
    /// follows the edit. So `histogramRefreshCount` can move without a frame, and the sum above is a
    /// claim about frames only.
    public private(set) var histogramSkippedFrames = 0
    /// Frames whose numbers **reached the card** — measured on that frame, or reused from the cache.
    public private(set) var histogramCollectedFrames = 0
    /// Frames that actually **ran a measurement** (`measureFrameHistogram`). A cache hit for a
    /// picture that was already measured is not one, and a frame whose key had not moved never gets
    /// that far.
    ///
    /// 045: a zoomed edit's whole-picture measurement counts here too, because it *is* a measurement —
    /// so this is "measurements of the picture", not "frames that measured".
    public private(set) var histogramRefreshCount = 0
    /// The last measurement's own cost (frame readback + binning + the GPU wait), in milliseconds.
    ///
    /// **034 changed what it measures**: it used to be a whole extra thumbnail render (≈11 ms), now it
    /// is the readout of a frame that was drawn anyway (≈1.4 ms engine-side).
    public private(set) var lastHistogramMilliseconds: Double = 0
    /// The last measurement's latency: "this frame started drawing" → "the card has new numbers".
    public private(set) var lastHistogramLatency: Double = 0
    /// Why the last measurement did not run (`nil` when it did).
    ///
    /// Two values matter: `"window frame"` (034 — the frame is a crop of the picture, so its pixels
    /// are not the picture's and the card keeps the whole-picture numbers it has) and a decoder's
    /// message (a development that had not landed). A successful publish clears it.
    public private(set) var lastHistogramError: String?

    /// Guards `histogramCache`/`histogramCacheOrder`, `histogramFrameKey` and `histogramInFlight`.
    ///
    /// The cache used to be touched from main (`measureHistogramNow`) and from the render queue (the
    /// debounced measurement) with nothing between them. 034 measures on the render queue on *every*
    /// frame that changes the picture, so the two sides are now genuinely concurrent: one lock, one
    /// scope.
    private let histogramLock = NSLock()
    /// The key `lastHistogram` belongs to. Main thread.
    private var histogramMeasuredKey: String?
    /// The key of the last frame that measured (or cache-hit) the picture — the dedupe that makes a
    /// pan free. Guarded by `histogramLock`: `cancelPendingFrames` clears it on main while a frame may
    /// be comparing it on the render queue.
    private var histogramFrameKey: String?
    /// Histogram steps handed to main but not applied yet. Guarded by `histogramLock`; since 045 it is
    /// no longer the only thing `histogramIsIdle` reports on (a windowed edit's background measurement
    /// is the other), but it is still the main-queue hop.
    private var histogramInFlight = 0

    // MARK: 045 — the whole-picture measurement for a zoomed edit
    //
    // 034's rule was "only a frame that holds the whole picture may publish", because a 1:1 frame is a
    // *crop* and its bins are the crop's. That answer left the card standing still for the whole of a
    // zoomed drag (the owner's report: 「拖动黑色/白色 后 直方图就不更新了」). The picture did change —
    // only the frame stopped being the picture — so the fix is to measure the **picture** off the frame
    // path, as Lightroom does, instead of measuring the frame.
    //
    // Three properties, and each one is why the machinery below looks the way it does:
    //
    //   · **the frame path never waits for it.** The window frame hands its pixels to the canvas and
    //     returns; the measurement runs on `pictureQueue` with its own `RenderGraph`. Sharing the frame
    //     graph would mean sharing its `TexturePool` (a plain dictionary, not thread-safe) with a
    //     render, and serialising the two would put 11–24 ms of measurement in front of the next
    //     frame;
    //   · **at most one runs, and a newer edit replaces an older one.** One pending slot, overwritten
    //     by every newer key; an outcome for a picture the card has moved past is dropped, so the plot
    //     never flashes an intermediate document;
    //   · **a frame and an edit can never cross.** The injected base (`fullPictureSource`) carries the
    //     digest of the edit it was rendered with, and it is only read when that digest *is* this
    //     edit's. Everything else falls back to a whole-picture render of the edit that is being
    //     measured — never to a frame that holds an older document.

    /// Where a **whole-picture** measurement may read the picture from, instead of rendering one here.
    ///
    /// The cheapest whole picture available in this app is the low-res full-picture base the canvas
    /// already keeps for a shrinking zoom (037/039). Handing it over is one `measureFrameHistogram`
    /// call — 256 on the long edge, ≈1 ms — where rendering the picture costs 11–24 ms.
    ///
    /// - Parameters (returned): `texture` the display-encoded rgba16f base; `content` the picture's
    ///   rect inside it, in texture pixels; `digest` the edit it was rendered with
    ///   (`Histogram.editDigest`).
    ///
    /// **The digest is the whole contract.** A base rendered for another document is not this
    /// picture, and a caller with nothing current returns a digest that cannot match (or `nil`); the
    /// measurement then falls back to `RenderGraph.measureHistogram` on the same background queue.
    /// `nil` (the default) means the base is not wired and every zoomed edit takes the render path.
    ///
    /// **Threading.** The closure is called on the measurement queue
    /// (`photons.loupe.picture`, utility), never on main and never on the render queue, so it may not
    /// block on the main thread (a `DispatchQueue.main.sync` inside it would deadlock a slider drag).
    /// The texture it returns is read *after* the closure returns, on that same queue: do not hand over
    /// a texture another thread is writing at the time.
    public var fullPictureSource: ((EditModel) -> (texture: MTLTexture, content: ImageRect,
                                                   digest: String,
                                                   histogram: Histogram?)?)?

    /// The serial queue a windowed edit's whole-picture measurement runs on.
    ///
    /// Deliberately **not** `queue`: see the note above — a graph owns one command queue and one
    /// texture pool, so this path has its own graph (`pictureGraph`) and its own thread. Utility QoS
    /// because nothing is waiting on it: the user is dragging a slider, and the plot is allowed to
    /// arrive one measurement late.
    private let pictureQueue = DispatchQueue(label: "photons.loupe.picture", qos: .utility)

    /// The newest armed request (`nil` once a worker has taken it). Guarded by `histogramLock`.
    private var picturePending: PictureRequest?
    /// The key of the newest picture armed — the staleness test an outcome is checked against.
    private var pictureLatestKey: String?
    /// The key of the picture a window frame has already asked for, so twenty pan frames at 1:1 ask
    /// once. Cleared when it lands (or fails, so a transient failure is retried).
    private var pictureArmedKey: String?
    /// Measurements running on `pictureQueue` right now. Guarded by `histogramLock`.
    private var pictureRunning = 0
    /// Whether a drain is already scheduled on `pictureQueue`. Guarded by `histogramLock`.
    private var pictureScheduled = false
    /// Measurements that read the injected base, and that rendered the picture instead (045's two
    /// paths, counted for the tests and for the claim "the base is used when it is current").
    private var pictureFrameUses = 0
    private var pictureRenderUses = 0
    /// Requests **cancelled before they started** — replaced in the pending slot by a newer edit. This
    /// is the counter that makes "at most one measurement runs" checkable: `pictureArms ==
    /// (pictureFrameUses + pictureRenderUses) + pictureDrops` once the queue is quiet.
    private var pictureDrops = 0
    /// Measured outcomes whose numbers were thrown away because a newer edit had been armed while they
    /// measured. Those *did* measure (they are in `pictureFrameUses`/`pictureRenderUses`); the plot just
    /// does not flash them.
    private var pictureStales = 0
    /// Requests actually armed (a frame that asked for a picture nobody had asked for yet).
    private var pictureArms = 0
    /// The graph the background measurement renders on, and the source identity it was built for.
    ///
    /// Guarded by `histogramLock`: the picture queue builds and uses it, `cancelPendingFrames` drops
    /// it on main. Holding the lock only long enough to hand the reference out is safe — an in-flight
    /// use keeps the graph alive through ARC.
    private var pictureGraph: RenderGraph?
    private var pictureGraphIdentity: String?

    /// `Histogram.cacheKey` → the numbers. A handful of entries: the current picture's edit chain, so
    /// sliding back is instant and a re-measurement of the same document cannot produce different
    /// numbers (it cannot produce anything — the key is the identity).
    private var histogramCache: [String: Histogram] = [:]
    private var histogramCacheOrder: [String] = []
    private var histogramCacheLimit = 8
    /// The last document digested, and its digest. `histogramStep` runs on every frame, and a JSON
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

    /// Read-only, for the cadence tests: **nothing is measuring and nothing is on its way to the
    /// card**, so a counter read now is the settled answer and not a sample taken mid-flight.
    ///
    /// It exists so the tests can say "wait until the card is quiet" instead of "sleep 300 ms and
    /// hope": a `sleep` is the wall clock in a test, and this is a fact about the object. Since 034
    /// there is no debounce to wait out and no second render in flight — a measurement happens inside
    /// the frame — so the only thing left is the main-queue hop that applies a frame's step.
    ///
    /// 045 added the second kind of work: a zoomed edit's whole-picture measurement runs on
    /// `pictureQueue`, so "quiet" also means "nothing armed, nothing running, nothing to apply".
    public var histogramIsIdle: Bool {
        histogramLock.lock()
        defer { histogramLock.unlock() }
        return histogramInFlight == 0 && picturePending == nil && pictureRunning == 0
    }

    /// How many whole-picture measurements read the **injected base** (045) — the ≈1 ms path.
    public var pictureFrameMeasurementCount: Int {
        histogramLock.lock()
        defer { histogramLock.unlock() }
        return pictureFrameUses
    }

    /// How many whole-picture measurements had to **render the picture** (`measureHistogram`, 11–24 ms)
    /// because no base for this edit was available — the fallback path.
    public var pictureRenderMeasurementCount: Int {
        histogramLock.lock()
        defer { histogramLock.unlock() }
        return pictureRenderUses
    }

    /// Requests cancelled before they started, because a newer edit replaced them. Zero while the loupe
    /// settles one edit at a time; a burst of slider ticks replaces instead of queueing.
    public var pictureMeasurementDropCount: Int {
        histogramLock.lock()
        defer { histogramLock.unlock() }
        return pictureDrops
    }

    /// Measured outcomes discarded because a newer edit was armed while they measured. They cost one
    /// measurement each and moved nothing — the plot never shows an intermediate document.
    public var pictureStaleOutcomeCount: Int {
        histogramLock.lock()
        defer { histogramLock.unlock() }
        return pictureStales
    }

    /// Requests armed for a whole-picture measurement — one per zoomed edit, and never one per frame
    /// of a pan (`testAPanAtOneToOneStillPublishesNothing`).
    ///
    /// Together with the two measurement counts and the drop count it says what happened to every
    /// request: `arms == measurements + drops + still running`, which is how "at most one runs and a
    /// newer edit replaces an older one" is checkable without a clock.
    public var pictureArmCount: Int {
        histogramLock.lock()
        defer { histogramLock.unlock() }
        return pictureArms
    }

    // MARK: camera (fit / 1:1 / pan / pinch)

    /// Where the loupe is looking, in source pixels. The only view-state this type keeps.
    public private(set) var viewState = LoupeViewState.fit
    /// The camera the 裁切 tool borrowed: restored on 应用/取消, so a precision tool never leaves the
    /// user at a zoom they did not choose (`WINDOW_INTEGRATION.md:14` — 临时fit，退出恢复会话视口).
    private var cropEntryState: LoupeViewState?
    /// 072 §E1/§E2 — 「裁切模式打开 / 关闭」, published exactly once per change.
    ///
    /// The workspace hangs the inspector's event layer on this: while the frame owns the canvas the
    /// right-hand panel is **inert** (its hosting view answers `hitTest → nil`), not merely greyed, and
    /// the moment the tool closes the panel is live again. View state, like the mode itself.
    public var onCropModeChange: ((Bool) -> Void)?
    /// What the callback was last told, so a drag tick cannot republish it.
    private var publishedCropModeActive = false
    /// 072 §A1 — 确认/取消裁切后, the picture is carried from the crop framing to the entry framing by
    /// the stop-change bridge. That is the one animation in the loupe, so leaving the tool forces it on
    /// even when the *scale* happens to match (a crop change moves the picture's content, not only its
    /// ratio), instead of cutting.
    public private(set) var cropExitAnimations = 0
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
    /// The photo the 裁切 frame was opened on — a change drops the tool rather than crop one picture
    /// with another's framing.
    private var lastHandledAnchorID: String?
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
    /// True while a pan/zoom frame has been started and not yet reached the canvas.
    ///
    /// Read-only diagnostic, used by tests only: a frame that is *in flight* moves no paint counter,
    /// and a 60 MP frame under load can take seconds, so "the counters stopped moving" is not
    /// quiescence. Nothing in the app reads this.
    public var isRenderingViewportFrame: Bool { viewInFlight }
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

    /// Read-only, for the cadence tests: no viewport frame is rendering, and none is waiting for the
    /// queue. "The pans have landed" is a fact, not a duration — this is that fact.
    public var viewportRenderInFlight: Bool { viewInFlight || viewPending }

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
        self.cropTool = CropToolController(session: session)
        super.init(nibName: nil, bundle: nil)

        // 045 × 039: the histogram's whole-picture source **is** the backdrop cache — same render,
        // two purposes. `nil` when no backdrop for the current document exists, and always digest
        // gated: measuring a frame rendered from another edit is worse than not updating at all.
        fullPictureSource = { [box = fullPictureBox] edit in
            guard let frame = box.current(), frame.digest == Histogram.editDigest(edit) else { return nil }
            return (frame.texture, frame.content, frame.digest, frame.histogram)
        }
    }

    public required init?(coder: NSCoder) { fatalError("no nibs in this app") }

    deinit {
        for token in screenTokens { NotificationCenter.default.removeObserver(token) }
    }

    // MARK: lifecycle

    public override func loadView() {
        container.wantsLayer = true
        // 054: the view behind the canvas is the same `#0F0F0F` as the matte the pass paints, so a
        // resize that exposes it for a frame shows grey, not a black edge.
        container.layer?.backgroundColor = NSColor.canvasMatte.cgColor
        canvasView.frame = container.bounds
        canvasView.autoresizingMask = [.width, .height]
        canvasView.controller = self
        canvasView.maskPainter = maskCanvas
        container.addSubview(canvasView)
        // Over the canvas, under the readout: the clipping wash, the shape-drag rubber band, and the
        // selected mask's control points. All three are `hitTest → nil`, so every click still belongs
        // to the canvas.
        for overlay in [highlightOverlay as NSView, draftOverlay as NSView,
                        maskHandlesOverlay as NSView, cropOverlay as NSView] {
            overlay.frame = container.bounds
            overlay.autoresizingMask = [.width, .height]
            container.addSubview(overlay)
        }
        cropOverlay.isHidden = true
        // The mask chrome belongs to the inspector's 蒙版 workspace, so it starts away — and
        // `setMasksWorkspaceActive` is what puts it up (2026-10-27: 「退出蒙版菜单栏后应该隐藏」).
        draftOverlay.isHidden = true
        maskHandlesOverlay.isHidden = true
        // The tool strip. Above the overlays (it takes clicks), below the zoom pill (which stays the
        // topmost chrome), and hidden until 裁切 mode is on.
        container.addSubview(cropBar)
        cropBar.isHidden = true
        // 082: the bar is **three read-only numbers** now — no apply/cancel, no slider, no flips. The
        // controls (and the draft's own write paths) live in the 裁切 card, so there is nothing for
        // the canvas to wire back beyond the controller it reads.
        cropBar.controller = cropTool
        // 082: the card is the control surface now, so a draft edit it makes has to reach the canvas —
        // the overlay's frame and the bar's three readouts are redrawn on the same tick, and one render
        // is asked for (a straighten moves the picture).
        cropTool.onDraftChange = { [weak self] in
            guard let self else { return }
            self.refreshCropTool()
            self.requestEditRender()
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
        // The control points live in view points, so a resize moves them: rebuild rather than let the
        // overlay keep the old canvas' coordinates.
        refreshMaskHandles()
        // Same for the crop frame: a resize is a new projection, and both the frame and the tool strip
        // are laid out in view points.
        refreshCropTool()
        // A resize is a new canvas: every pixel is re-rendered into it, and a bridge measured against
        // the old one would scale the picture about the wrong centre. Tear the transition down rather
        // than leave the transform in a mid-flight state nobody will ever finish.
        let size = viewportPixels
        if size != lastLaidOutViewport {
            let canvasChanged = lastLaidOutViewport != nil && zoomBridgeCanvas != nil
                && zoomBridgeCanvas != size
            lastLaidOutViewport = size
            // 067: the teardown re-presents the frame that is on the canvas **with the geometry it was
            // drawn with** (`rePresentFrozen`), not with a fresh `.whole` window — the latter maps the
            // old frame across a new canvas, which is the stretch this task exists to remove.
            if canvasChanged { cancelZoomBridge(rePresent: false) }
        }
        // 068: **one** rule for every gesture that moves the canvas — a window edge, the inspector's
        // divider, the browser's divider — because the canvas sees one thing from all of them: bounds
        // changing many times, faster than a frame can be presented.
        //
        // Inside the gesture a layout pass draws the frame already on the canvas at its own geometry
        // and asks for no render, and the **draw is coalesced to one per runloop tick**. The draw is
        // what costs, not the quad: `present` takes a drawable with `displaySyncEnabled`, i.e.
        // `nextDrawable()` on the main thread waits for the next vsync. A drag that is laid out twice
        // per display frame therefore made one of the two presents wait for a vsync it had already
        // missed — the window server showed the layer at the last size it had, then the late present
        // moved it, twice per frame. That alternation is the 「果冻」.
        if isCanvasGeometryFrozen {
            liveResizeLayouts += 1
            scheduleFrozenPresent()
            return
        }
        // The hand let go: the last size never got a frame of its own, so exactly one render is asked
        // for, at the canvas that is on screen now. `releaseFrozenCanvasIfNeeded` is the same funnel
        // the gesture's own end uses, so the two callers cost one request between them.
        if releaseFrozenCanvasIfNeeded() { return }
        requestResizeRender()
    }

    private func observeModel() {
        lastHandledRevision = session?.editRevision ?? 0
        lastHandledAnchorID = session?.anchorID
        bridge.observe({ [weak self] in
            guard let self else { return }
            _ = self.session?.anchorID
            _ = self.session?.mode
            _ = self.session?.editRevision
        }, { [weak self] in
            guard let self else { return }
            // 065: the photo on screen first, because everything below assumes the work in flight
            // belongs to it. In the app this is the **only** place a switch is noticed: `frameSource`
            // is nil there, and `cancelPendingFrames` used to run on leaving the loupe only — so a
            // switch from photo A to photo B kept A's backdrop, A's histogram snapshot and A's zoom
            // bridge, which is `「背景用的低清渲染图还是上一张的」`.
            self.notePhotoIdentity(self.backdropPhotoKey)
            // One observer, two jobs: a document change re-renders the current decode (cheap,
            // ~ms); a photo change needs a new decode (expensive, the 0.5 → 1.0 ladder).
            let revision = self.session?.editRevision ?? 0
            // 裁切 mode belongs to the photo it was opened on, and to the loupe: a different picture
            // (or another module) drops the frame rather than cropping one photo with another's
            // framing (task 035).
            self.dropCropToolIfStale()
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
        // 068: the window's own two edges of a live resize, observed rather than only overridden. The
        // `NSView` pair (`viewWillStartLiveResize`) is sent down the hierarchy, but the canvas is three
        // levels below the content view and the freeze must not depend on that delivery: the release is
        // what puts a correct frame on the final size, and a missed `viewDidEndLiveResize` would leave
        // the picture frozen at its pre-drag geometry. `beginCanvasGeometryGesture` is idempotent per
        // source, so a double delivery costs nothing.
        screenTokens.append(center.addObserver(forName: NSWindow.willStartLiveResizeNotification,
                                              object: nil, queue: .main) { [weak self] note in
            guard let self, let window = self.view.window else { return }
            guard (note.object as? NSWindow) === window else { return }
            self.beginLiveResize()
        })
        screenTokens.append(center.addObserver(forName: NSWindow.didEndLiveResizeNotification,
                                              object: nil, queue: .main) { [weak self] note in
            guard let self, let window = self.view.window else { return }
            guard (note.object as? NSWindow) === window else { return }
            self.endLiveResize()
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

    /// The display, asked again — `HeadroomSource` for the histogram card's ceiling (2026-10-27).
    ///
    /// **One reader of the screen for the whole app.** `refreshDisplay()` re-reads
    /// `window.screen?.maximumExtendedDynamicRangeColorComponentValue` (the property that moves when the
    /// brightness slider moves) and applies it, including the layer's `layerAcceptsEDR` answer — which a
    /// bare `NSScreen` read cannot know. It is a no-op when nothing moved, so the card's poll costs a
    /// property read and a comparison on a settled window.
    ///
    /// A moved budget also means a **re-render at the new ceiling** (`setDisplayHeadroom` schedules
    /// one): the tick and the pixels must describe the same screen, and a frame measured at the old
    /// budget would leave 削顶 describing a display that no longer exists.
    public func readHeadroom() -> DisplayHeadroom {
        refreshDisplay()
        return displayHeadroom
    }

    /// Called after every frame that reached the layer — the histogram card's ceiling re-read, and
    /// nothing else (2026-10-27). One place, because `presentCanvas` is the only path to the layer.
    ///
    /// A brightness change moves the screen's EDR budget and posts no notification, so a presented
    /// frame is the cheapest chance to notice it; the card's own 0.5 s poll covers the frames that never
    /// come. `nil` (no card) costs one branch.
    public var onFramePresented: (() -> Void)?

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
        // 082: 1:1 is a *stop* like any other — a crop session whose frame is smaller than the canvas
        // at 1:1 stops at the frame-inscribed level instead.
        let target = min(1, cropZoomLimit() ?? Double.infinity)
        let anchor = point ?? canvasCentrePoint()
        setViewState(framing.zooming(viewState, to: target, aroundView: anchor, backingScale: backingScale),
                     anchor: .pointer(viewPoint: anchor, backingScale: backingScale))
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

    /// The nine numeric stops, in order — `LoupeViewState.zoomStops`, `0.125 … 4` with the thirds
    /// exact (`1.0/3.0`, `2.0/3.0`). `fit` is **not** one of them; it is a mode with its own entry
    /// point (`zoomFitEntryPoint`).
    public static let zoomStops: [Double] = LoupeViewState.zoomStops

    /// What the 倍率 menu can name: the same nine stops, at the same indices.
    ///
    /// The menu item's **tag is the index into this array**, not a percentage. That is the only
    /// identity that survives `1/3 → "33.3%" → 0.333` intact: a hundredths tag would round the third
    /// to 33 % and land the action on a stop the item never named. `EditorWindowController.zoomStopAction`
    /// reads `menuZoomStops[item.tag]`, so the value is exact and the label is only a label.
    public static let menuZoomStops: [Double] = LoupeViewState.zoomStops

    /// The ladder the menu and the readout print: nine numeric stops, ascending, no fit rung.
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
        // 082: a crop session's ceiling is 「框恰好内接于画布」 — clamped **before** the anchor maths,
        // so the pixel under the cursor is kept for the zoom that actually lands.
        let ladder = LoupeViewState.snappedLevel(for: LoupeViewState.clampZoom(stop)).zoom
        let target = min(ladder, cropZoomLimit() ?? Double.infinity)
        let anchor = point ?? canvasCentrePoint()
        setViewState(framing.zooming(viewState, to: target, aroundView: anchor,
                                     backingScale: backingScale),
                     anchor: .pointer(viewPoint: anchor, backingScale: backingScale))
    }

    /// ⌘+ / ⌘=: the next stop up, or 4:1 from anything between. From `fit` it lands on 100 % — the
    /// same destination as Z, because "zoom in from the whole frame" means full size first.
    public func zoomIn() {
        guard viewState.isActualSize else { zoomToActualSize(); return }
        let current = LoupeViewState.clampZoom(viewState.zoom)
        let next = LoupeController.zoomStops.first { $0 > current + 1e-9 } ?? LoupeViewState.maximumZoom
        zoom(to: next)
    }

    /// ⌘−: the next stop down — 100 % → 66.7 % → 50 % → 33.3 % → 25 % → 12.5 %. Below the lowest
    /// **numeric** stop the whole frame is the next step out; `fit` is outside the ladder and is reached
    /// here rather than by a snap, so one more ⌘− from 12.5 % always gives the same picture.
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

    /// Drag pan. `delta` is the delta the event reported, in **window** points — the space
    /// `NSEvent.locationInWindow` is in, y up. The picture follows the hand: the pixel grabbed at
    /// `mouseDown` stays under the cursor, so the camera moves the other way. The y term is the one
    /// place the two conventions meet — window coordinates are y **up**, the projection is y **down**
    /// (`LoupeCanvasView.isFlipped`) — so it is negated on the way in; without that a drag downwards
    /// moved the picture upwards, which is the bug the user reported.
    public func panImage(byPoints delta: CGSize) {
        guard viewState.isActualSize, let framing = framing() else { return }
        let scale = backingScale
        let content = (x: -Double(delta.width) * scale, y: Double(delta.height) * scale)
        panBy(contentDelta: content, framing: framing)
    }

    /// Wheel / two-finger scroll. A wheel notch reports ~1 point; a trackpad reports pixels, so the
    /// two are scaled differently instead of one of them feeling like glue.
    ///
    /// `inverted` is `NSEvent.isDirectionInvertedFromDevice`, and it is **not** a hint — it is the
    /// whole rule. With 「自然滚动」 on (the macOS default) the system has already inverted
    /// `scrollingDelta*` so that they describe the movement of the **content**
    /// (`NSEvent.isDirectionInvertedFromDevice`: "the values are automatically inverted according to
    /// the user's preferences … such that it feels like they are moving the content"), so the picture
    /// moves by `+delta`. With it off the deltas are the **device's** own direction, and the picture
    /// moves by `−delta`. Reading `scrollingDeltaY` and negating it — what this did — makes the two
    /// settings behave differently; normalising on the flag is what makes the result depend only on
    /// which way the fingers went.
    public func scrollPan(deltaX: CGFloat, deltaY: CGFloat, precise: Bool, inverted: Bool) {
        guard viewState.isActualSize, let framing = framing() else { return }
        let factor = precise ? backingScale : backingScale * 12
        let sign: Double = inverted ? 1 : -1
        let content = (x: -Double(deltaX) * factor * sign, y: -Double(deltaY) * factor * sign)
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
        // 082: a crop session's pinch stops at 「框恰好内接于画布」 (the accumulator keeps running, so a
        // pinch back in leaves on the next event).
        let target = min(level.zoom, cropZoomLimit() ?? Double.infinity)
        let next = framing.zooming(viewState, to: target, aroundView: point, backingScale: backingScale)
        pinchZoom = raw
        setViewState(next, anchor: .pointer(viewPoint: point, backingScale: backingScale))
    }

    private func setViewState(_ requested: LoupeViewState, anchor: LoupeZoomAnchor = .center,
                              forceAnimation: Bool = false) {
        // 082 — **the** one gate: every camera change (wheel, pinch, pill, ⌘=/⌘−, double-click, drag
        // pan, two-finger scroll, the crop entry's own `zoomToFit`) is written on the two lines below,
        // so a crop session's 「裁切框 ⊆ 画布」 is decided here and nowhere else. Outside 裁切 mode, and
        // for `.fit`, this is the identity — which is what makes the clamp belong to the tool only.
        let next = clampedToCropCanvas(requested)
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
        // ① — the **one** place a camera change reaches the crop overlay.
        //
        // `viewState` is written here and nowhere else (that is the invariant `updateStatusChip`
        // already relies on), so a zoom from the pill, ⌘= / ⌘−, a double-click, a touchpad scroll or
        // a pinch — and a pan from a two-finger scroll or a drag — all pass through this line. The
        // frame is a rect of the *projection*, so it has to be re-laid-out in the same turn the
        // projection changed: before this, `refreshCropTool()` only ran on draft changes and mode
        // changes, and the overlay kept drawing the fit-time rectangle after a zoom.
        //
        // ② (2026-10-27) — **unless a stop change is about to animate**. Then the picture is still the
        // old one for the next 180 ms, and the frame must travel with it instead of jumping to the
        // target on this line; the bridge's own tick lays it out (see `presentZoomBridgeFrame`), and
        // the call here only puts it on frame 0 of that same animation. The arm therefore runs first:
        // whether a bridge exists is what decides between "follow the animation" and "the cut is the
        // change".
        view.window?.invalidateCursorRects(for: canvasView)
        // **Every** stop change is bridged — fit ↔ a numeric stop, and numeric stop ↔ numeric stop
        // (`12.5 ↔ 25 ↔ 33.3 ↔ 50 ↔ 66.7 ↔ 100 ↔ 200 ↔ 300 ↔ 400`). The camera jumps here and the pixels
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
        var bridging = false
        if let framing = framing(),
           forceAnimation || movesScale(from: previous, to: next, framing: framing) {
            bridging = armZoomBridge(from: previous, to: next, framing: framing, anchor: anchor)
        }
        if syncsCropOverlayOnCameraChange {
            // A bridge owns the next 180 ms: the frame is drawn at its frame 0 here, which is the
            // picture that is on screen right now. With no bridge the target geometry *is* the picture.
            syncCropOverlay(progress: bridging ? 0 : nil)
        }
        // ③ (2026-10-27) — the mask chrome rides the **same** camera callback. A pan moves the picture
        // on this line (no animation), so the grips and the rubber band are re-projected on this line;
        // a stop change puts them on frame 0 of the bridge, and the bridge's own tick carries them the
        // rest of the way (`presentZoomBridgeFrame`). No second timeline, for the same reason there is
        // no second camera.
        if syncsMaskOverlaysOnCameraChange {
            syncMaskOverlays(progress: bridging ? 0 : nil)
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

    /// One presented frame of a stop change: the progress it was drawn at, the sampling window it
    /// was drawn with, and the drawable it went into (025 — the evidence lives here).
    public struct ZoomBridgeFrame: Equatable, Sendable {
        /// The bridge that drew it (`zoomBridgeArmedCount` when it was armed). A retarget keeps the
        /// log growing, so this is what tells one bridge's frames from the next one's.
        public let serial: Int
        public let progress: Double
        public let window: PresentWindow
        public let drawable: ImageSize
        public let canvas: ImageSize
        /// 065: **which texture** the bridge sampled — the frame the canvas was holding when it was
        /// armed. A bridge that outlives its photo keeps presenting that texture, so "no bridge frame
        /// after a switch samples the previous photo's texture" is a question only identity answers.
        public let source: ObjectIdentifier?

        public init(serial: Int, progress: Double, window: PresentWindow,
                    drawable: ImageSize, canvas: ImageSize,
                    source: ObjectIdentifier? = nil) {
            self.serial = serial
            self.progress = progress
            self.window = window
            self.drawable = drawable
            self.canvas = canvas
            self.source = source
        }
    }
    /// Every frame of every bridge, in the order it was presented — append-only, so a retarget adds
    /// to the record instead of erasing what the eye already saw. Capped, because it is a log.
    public private(set) var zoomBridgeFrames: [ZoomBridgeFrame] = []
    private static let zoomBridgeFrameLimit = 512

    /// The projection the pixels **on the canvas** were laid out with, and where those pixels sit on
    /// the whole picture (058). A bridge always starts from these pixels, whatever the camera has done
    /// since.
    private var canvasContent: (mapping: LoupeMapping, content: ImageSize,
                                placement: FramePlacement)?
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

    // MARK: the texture the canvas is showing (025)
    //
    // The stop change no longer moves the layer: it re-presents **this** texture with a different
    // sampling window on every display frame. That needs the texture to stay out of the render pool
    // for as long as it is on the layer, so ownership moved here: the frame that lands becomes
    // `canvasTexture`, and the one it replaced is recycled when the new drawable is committed
    // (instead of the landing frame being recycled the moment it is presented).
    private var canvasTexture: (texture: MTLTexture, graph: RenderGraph?)?

    /// 054: where the photograph sat inside `canvasTexture`, in canvas pixels, and the canvas it was
    /// normalised against. `cancelZoomBridge` re-presents that same texture with `window: .whole`; without
    /// this the matte it paints would cover the photograph, because a canvas-sized frame's letterbox is
    /// inside the texture and the rect is the only thing that says where the picture is.
    private var canvasPicture: (rect: ImageRect, canvas: ImageSize)?

    /// The bridge's display-cadence driver. A `Timer` on the main run loop in `.common` mode, at
    /// 120 Hz: the window is a *parameter of the present pass*, not a layer property, so nothing in
    /// Core Animation can interpolate it for us — and a present is a full-screen quad, i.e. the same
    /// cost as one blit.
    private var zoomBridgeTicker: Timer?
    /// When the running bridge started, `CACurrentMediaTime()`.
    private var zoomBridgeStart: CFTimeInterval = 0
    /// Presents in flight. Two, not one: a single slot would make the transition's frame rate collapse
    /// to the GPU's completion rate the moment anything else is busy, and one slot would also serialise
    /// the pipeline for no reason. More than two would starve `nextDrawable()` and block the main
    /// thread, which is worse than a dropped frame.
    private var zoomBridgePresentsInFlight = 0

    private static let zoomBridgeInterval: TimeInterval = 1.0 / 120

    /// System setting ▸ 辅助功能 ▸ 显示 ▸ 减弱动态效果. The geometry still has to be right, so the
    /// bridge still holds the arriving frame; it snaps to the target instead of sliding there.
    public var reducesMotion: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    /// Carry the picture already on screen from the projection of the camera that produced it to the
    /// projection of the new camera in 180 ms easeOut, and hand the canvas over to the real frame when
    /// it arrives.
    ///
    /// **The carry is a sampling window, not a layer transform** (025). A `CATransform3D` on the
    /// canvas's layer scales the layer itself: the drawable grows past the view's bounds and paints
    /// over the browser pane (bug 2), and when it shrinks it leaves the canvas uncovered, so the
    /// window behind shows through as black until the new frame lands (bug 3). The window keeps the
    /// drawable at the canvas size and moves only *which part of the texture it reads*, so neither can
    /// happen: a growing picture is cropped at the canvas edge by construction, and a shrinking one
    /// samples past the texture's edge, where `clamp_to_edge` extends the picture's own border pixels.
    ///
    /// Retargeting: a second ⌘= starts from the map the eye is currently looking at (read off the
    /// running bridge, not off a presentation tree), so nothing jumps back and nothing is added twice.
    ///
    /// Returns whether a bridge is **running** after the call — that is what tells `setViewState`
    /// whether the crop overlay must follow an animation or may cut straight to the target geometry.
    @discardableResult
    private func armZoomBridge(from old: LoupeViewState, to new: LoupeViewState,
                               framing: LoupeFraming, anchor: LoupeZoomAnchor) -> Bool {
        guard lastFrame != nil, let onCanvas = canvasTexture else { return false }  // nothing to carry
        let canvas = viewportPixels
        let texture = ImageSize(width: onCanvas.texture.width, height: onCanvas.texture.height)
        let fromMapping = canvasContent?.mapping ?? framing.mapping(of: old)
        let fromContent = canvasContent?.content ?? framing.contentPixels(of: old)
        let toMapping = framing.mapping(of: new)
        // Where the composite already is: identity for a bridge armed from rest, and the running
        // bridge's own map for one that replaces it (read off the bridge, which is the value that was
        // actually presented — the eye is looking at exactly this).
        let wasBridging = zoomBridge != nil
        let start: (scale: Double, x: Double, y: Double)
        if let running = zoomBridge {
            start = running.map(atProgress: zoomBridgeProgress())
        } else {
            start = (1, 0, 0)
        }
        let bridge = LoupeZoomBridge(
            fromContent: fromContent,
            toContent: framing.contentPixels(of: new),
            fromMapping: fromMapping,
            toMapping: toMapping,
            canvas: canvas,
            startScale: start.scale, startOffsetX: start.x, startOffsetY: start.y,
            layerAnchorPoint: canvasView.metalLayer.anchorPoint,
            layerIsFlipped: canvasView.metalLayer.isGeometryFlipped,
            anchor: anchor)
        guard bridge.isVisible else {
            // Nothing geometric moved (fit and 100 % coincide on a small file, or the window was
            // clamped to the same rect): the arriving frame *is* the whole change.
            zoomBridgeSerial += 1
            zoomBridge = nil
            stopZoomBridgeTicker()
            return false
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
        let serial = zoomBridgeArmedCount
        zoomBridgeCanvas = canvas
        zoomBridgeSerial += 1
        zoomBridgeStart = CACurrentMediaTime()
        // Frame 0 is the picture as it is. For a bridge armed from rest that is the identity window
        // (the canvas was last presented with it); for a retarget it is the window the running bridge
        // had reached, because that is what the eye is looking at.
        recordZoomBridgeFrame(ZoomBridgeFrame(serial: serial, progress: 0,
                                              window: bridge.window(atProgress: 0, textureSize: texture),
                                              drawable: canvas, canvas: canvas,
                                              source: ObjectIdentifier(onCanvas.texture)))
        guard !reducesMotion, bridge.duration > 0 else {
            // Reduce Motion: no slide — one present at the stop's own geometry, then hand over.
            presentZoomBridgeFrame(progress: 1, bridge: bridge, texture: onCanvas.texture, serial: serial)
            finishZoomBridge()
            return true
        }
        startZoomBridgeTicker()
        let armSerial = zoomBridgeSerial
        DispatchQueue.main.asyncAfter(deadline: .now() + bridge.duration + 0.002) { [weak self] in
            guard let self, self.zoomBridgeSerial == armSerial else { return }
            self.finishZoomBridge()
        }
        return true
    }

    private func recordZoomBridgeFrame(_ frame: ZoomBridgeFrame) {
        zoomBridgeFrames.append(frame)
        if zoomBridgeFrames.count > Self.zoomBridgeFrameLimit {
            zoomBridgeFrames.removeFirst(zoomBridgeFrames.count - Self.zoomBridgeFrameLimit)
        }
    }

    // MARK: what the crop overlay drew, frame by frame (②, 2026-10-27)

    /// The overlay as it was **drawn** after one bridge frame: which bridge, at what progress, and the
    /// whole layout (quad, eight grips, nine-square grid) the view was left holding.
    ///
    /// Recorded by the present tick itself (not reconstructed in a test), because the claim is about
    /// what the eye saw: the same tick, the same progress, the same curve.
    public struct CropOverlayFollowFrame: Equatable, Sendable {
        public let serial: Int
        public let progress: Double
        public let layout: CropToolLayout?
    }

    /// Every bridge frame's overlay, in order, append-only and capped like the frame log.
    public private(set) var cropOverlayFollowFrames: [CropOverlayFollowFrame] = []
    private static let cropOverlayFollowFrameLimit = 512

    /// The overlay as it was drawn for the bridge frame that just went up: recorded by the tick itself,
    /// because the claim (②) is about what the eye saw, at that frame's progress.
    private func recordCropOverlayFollowFrame(serial: Int, progress: Double) {
        guard cropTool.isActive else { return }
        cropOverlayFollowFrames.append(CropOverlayFollowFrame(serial: serial, progress: progress,
                                                              layout: cropOverlay.layout))
        if cropOverlayFollowFrames.count > Self.cropOverlayFollowFrameLimit {
            cropOverlayFollowFrames
                .removeFirst(cropOverlayFollowFrames.count - Self.cropOverlayFollowFrameLimit)
        }
    }

    /// The geometry has arrived (or the clock has run out): stop driving the window and hand the
    /// waiting frame over.
    ///
    /// The stop's own window is left on the canvas when nothing is waiting, so a development that
    /// outlives the 180 ms is a still frame at the new camera's geometry rather than a jump back.
    /// No ordering dance is needed any more: the frame is presented with the identity window, so its
    /// drawable is already the new camera's — there is no held transform to drop afterwards.
    private func finishZoomBridge() {
        zoomBridgeSerial += 1                 // any timer still in flight is stale now
        stopZoomBridgeTicker()
        let wasBridging = zoomBridge != nil
        let serial = zoomBridgeArmedCount
        let texture = canvasTexture?.texture
        let target = zoomBridge.flatMap { bridge -> PresentWindow? in
            guard let texture else { return nil }
            return bridge.window(atProgress: 1,
                                 textureSize: ImageSize(width: texture.width, height: texture.height))
        }
        let reached = zoomBridgeFrames.last(where: { $0.serial == serial }).map { $0.progress >= 0.999 }
            ?? false
        zoomBridge = nil
        guard wasBridging else { return }
        zoomBridgeCompletedCount += 1
        // ② (2026-10-27) — the picture on the canvas is the stop's own geometry now, so the overlay
        // lands on the same projection in the same call. At rest the error is exactly zero, because
        // this is the non-animating path's own layout function (`cropToolLayout()`).
        defer {
            syncCropOverlay()
            // ③ — and the mask chrome lands with it: the same end of the same bridge.
            syncMaskOverlays()
        }
        if let pending = pendingFrame {
            pendingFrame = nil
            present(frame: pending.frame, renderMilliseconds: pending.milliseconds, state: pending.state,
                    graph: pending.graph)
            return
        }
        // Nothing waiting: sit on the stop. (The ticker normally got there already; this covers Reduce
        // Motion and a bridge that ended between two ticks.)
        if !reached, let target, let texture, let presenter {
            let canvas = viewportPixels
            let drawn = backdropTexture(for: target)
            let backdropWindow = target.onWholePicture(canvasPlacement)
            // 067: the held frame's own picture rect, read through the stop's window — so the
            // photograph lands where the *stop's* map puts it. This is the call that used to pass no
            // rect at all: 054's matte needs one, and without it the frame's `float4(0)` letterbox was
            // drawn as **pure black** (the user's 「缩小时，如果画面在边缘，纯黑色背景还是存在」).
            let picture = canvasPicture?.rect
                ?? ImageRect(x: 0, y: 0, width: texture.width, height: texture.height)
            presentCanvas(presenter, texture: texture, photoRect: picture,
                          frameCanvas: canvasPicture?.canvas ?? canvas, window: target,
                          placement: canvasPlacement, backdrop: drawn,
                          backdropWindow: backdropWindow, canvas: canvas, serial: serial,
                          zoom: lastFrame?.zoom ?? 0)
            recordZoomBridgeFrame(ZoomBridgeFrame(serial: serial, progress: 1, window: target,
                                                  drawable: canvas, canvas: canvas,
                                                  source: ObjectIdentifier(texture)))
        }
    }

    // MARK: the bridge's display-cadence driver

    private func startZoomBridgeTicker() {
        stopZoomBridgeTicker()
        let timer = Timer(timeInterval: Self.zoomBridgeInterval, repeats: true) { [weak self] _ in
            self?.tickZoomBridge()
        }
        timer.tolerance = 0
        RunLoop.main.add(timer, forMode: .common)
        zoomBridgeTicker = timer
        tickZoomBridge()                      // frame 0 immediately: a transition must not start late
    }

    private func stopZoomBridgeTicker() {
        zoomBridgeTicker?.invalidate()
        zoomBridgeTicker = nil
        zoomBridgePresentsInFlight = 0
    }

    private func tickZoomBridge() {
        guard let bridge = zoomBridge, let onCanvas = canvasTexture else {
            stopZoomBridgeTicker()
            return
        }
        let progress = zoomBridgeProgress()
        presentZoomBridgeFrame(progress: progress, bridge: bridge, texture: onCanvas.texture,
                               serial: zoomBridgeArmedCount)
        if progress >= 1 { stopZoomBridgeTicker() }   // the stop's own geometry, held
    }

    /// The progress the picture is drawn at: `elapsed / duration` through the transition's curve.
    private func zoomBridgeProgress() -> Double {
        guard let bridge = zoomBridge, bridge.duration > 0 else { return 1 }
        let raw = (CACurrentMediaTime() - zoomBridgeStart) / bridge.duration
        return LoupeZoomCurve.easeOut(min(max(raw, 0), 1))
    }

    /// Present the frame on the canvas through `progress` of the transition.
    ///
    /// One present in flight at a time: `nextDrawable()` blocks once the queue is empty, and stalling
    /// the main thread to draw a transition is worse than drawing it at the display's own rate.
    private func presentZoomBridgeFrame(progress: Double, bridge: LoupeZoomBridge, texture: MTLTexture,
                                        serial: Int) {
        guard let presenter, zoomBridgePresentsInFlight < 2 else { return }
        let canvas = viewportPixels
        let window = bridge.window(atProgress: progress,
                                   textureSize: ImageSize(width: texture.width, height: texture.height))
        zoomBridgePresentsInFlight += 1
        // A shrinking frame does not reach the canvas: this is the call the user's 「用低清预览做界面外
        // 背景」 is about. A growing one covers it, and gets `nil` instead.
        let drawn = backdropTexture(for: window)
        // 058: the backdrop is the **whole picture**, the frame texture is one part of it — the frame's
        // window has to be read in the picture's coordinates before the backdrop is sampled through it.
        let placement = canvasPlacement
        let backdropWindow = window.onWholePicture(placement)
        // 067: the photograph's rect inside the held texture, read through **this frame's** window.
        // The quad therefore moves with the bridge: a zoom no longer draws the old matte at the old,
        // unscaled rect (the user's 「边缘 0f 的遮罩固定住，等渲染完了突然消失」).
        let picture = canvasPicture?.rect
            ?? ImageRect(x: 0, y: 0, width: texture.width, height: texture.height)
        let ok = presentCanvas(presenter, texture: texture, photoRect: picture,
                               frameCanvas: canvasPicture?.canvas ?? canvas, window: window,
                               placement: placement, backdrop: drawn,
                               backdropWindow: backdropWindow, canvas: canvas, serial: serial,
                               zoom: lastFrame?.zoom ?? 0) { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.zoomBridgePresentsInFlight = max(0, self.zoomBridgePresentsInFlight - 1)
            }
        }
        if !ok {
            zoomBridgePresentsInFlight = max(0, zoomBridgePresentsInFlight - 1)
            return
        }
        recordZoomBridgeFrame(ZoomBridgeFrame(serial: serial, progress: progress, window: window,
                                              drawable: canvas, canvas: canvas,
                                              source: ObjectIdentifier(texture)))
        // ② (2026-10-27) — the overlay moves on the **same tick, the same progress, the same curve** as
        // the pixels that just went up. Not a second timer and not a poll of `viewState`: `progress`
        // here is the value this present was drawn at, so the frame, its eight grips and its grid are
        // laid out on the picture the eye is looking at, not on where the picture will be in 180 ms.
        if followsCropOverlayDuringBridge {
            syncCropOverlay(progress: progress)
        }
        recordCropOverlayFollowFrame(serial: serial, progress: progress)
        // ③ (2026-10-27) — the mask chrome moves on the same tick, at the same progress, through the
        // same curve as the pixels that just went up. The grips go back with the frame, so they sit on
        // the picture the eye is looking at rather than on where it will be in 180 ms.
        if followsMaskOverlaysDuringBridge {
            syncMaskOverlays(progress: progress)
        }
        recordMaskOverlayFrame(serial: serial, progress: progress)
    }

    /// A new canvas (resize, a new window, a new screen): the pixels are re-rendered for a different
    /// viewport, and a bridge measured against the old one is a window in the wrong space. Tear it
    /// down instead of leaving the picture somewhere in between.
    ///
    /// `rePresent` says whether this call should put the frame back on the canvas. `viewDidLayout`
    /// passes `false` during a live resize, because `rePresentFrozen` is about to draw the same frame
    /// with the same (stretched) geometry — two presents of one frame is one too many, and they would
    /// fight over which canvas they were built for.
    public func cancelZoomBridge(rePresent: Bool = true) {
        guard zoomBridge != nil || pendingFrame != nil || zoomBridgeTicker != nil else { return }
        if let pending = pendingFrame, let graph = pending.graph {
            queue.async { graph.recycle(output: pending.frame.texture) }
            zoomBridgePendingDrops += 1
        }
        pendingFrame = nil
        zoomBridgeSerial += 1
        stopZoomBridgeTicker()
        let wasBridging = zoomBridge != nil
        zoomBridge = nil
        zoomBridgeCanvas = nil
        // ② (2026-10-27) — a torn-down bridge (resize, photo switch, leaving the tool) leaves the
        // overlay at a mid-transition rect nobody is going to animate away. Put it back on the current
        // camera's projection in the same turn, so a switch can never leave the old photo's frame on
        // screen: the same gate that ends the pixels ends the overlay.
        if wasBridging { syncCropOverlay() }
        // ③ — the same gate ends the mask chrome: a torn-down bridge must not leave a grip at a
        // mid-transition coordinate nobody is going to animate away.
        if wasBridging { syncMaskOverlays() }
        // The canvas still holds the old picture seen through whatever window the bridge had reached:
        // put it back at the geometry it was drawn with, or a resize would leave the picture stuck at a
        // mid-transition scale until the next frame lands. Deferred — this is called from
        // `viewDidLayout`, and taking a drawable mid-layout is asking for trouble. Guarded by identity,
        // so a frame that arrived in the meantime wins.
        //
        // 067: go through `rePresentFrozen` rather than re-presenting with a fresh `.whole` window.
        // `.whole` maps the held frame across whatever canvas is current — which is the stretch
        // (「变扁」) this task removes; the frozen geometry keeps the picture's pixel size and lets the
        // surface crop or extend it.
        guard rePresent, let stuck = canvasTexture?.texture else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.zoomBridge == nil, self.canvasTexture?.texture === stuck else { return }
            self.rePresentFrozen()
        }
    }

    /// Where the pointer is, in canvas **points** (y down — the space `NSEvent` and
    /// `handleDoubleClick` use), or `nil` when it is not over the canvas: a menu command chosen from
    /// the menu bar, a shortcut pressed while the pointer sits on the inspector.
    ///
    /// Two answers, one pointer. The **tracking area** (`LoupeCanvasView.updateTrackingAreas`) is the
    /// primary source: it is the same value the histogram's pixel readout uses, so the pixel the zoom
    /// anchors on and the brightness the card reports are the same pixel by construction. The live
    /// `mouseLocationOutsideOfEventStream` query is the fallback for the one case tracking cannot
    /// cover — a pointer that was already over the canvas before any move event was delivered (the
    /// first ⌘= after launch, a loupe that just appeared under a resting cursor).
    ///
    /// The conversion is `NSView.convert(_:from: nil)`, i.e. "from window base coordinates" (y **up**),
    /// into this view's flipped space (y **down**). Doing it by hand — subtracting `frame.origin` —
    /// is the y-flip bug this method is one `convert` call away from; `PointerAnchorTests` asserts the
    /// flipped answer against a hand conversion of a known window point.
    public func cursorAnchor() -> CGPoint? {
        if let tracked = pointerCanvasPoint { return tracked }
        guard let window = canvasView.window else { return nil }
        let point = canvasView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let bounds = canvasView.bounds
        guard bounds.width > 1, bounds.height > 1, bounds.contains(point) else { return nil }
        return point
    }

    // MARK: the pointer (the one source both features read)
    //
    // `LoupeCanvasView` owns a single tracking area and calls these. Everything downstream — the zoom
    // anchor above and the histogram card's bottom row — reads what they store, so there is exactly one
    // "current mouse position" in the app.

    /// The last pointer position the tracking area reported, in canvas points (y down), or `nil` when
    /// the pointer is not over the canvas. **The** current mouse position, as far as the loupe goes.
    public private(set) var pointerCanvasPoint: CGPoint?
    /// The pixel the row is currently reporting, `nil` when nothing is painted.
    public private(set) var pointerReadout: PointerPixel?
    /// Which source the current reading came from — the readback the acceptance numbers are about
    /// (`sceneLinear` in the app; `presented` only when the frame carried no measurement grid).
    public private(set) var pointerReadoutSource: PointerSampleSource?
    /// How many 1×1 texture readbacks the pointer has cost. The throttle is asserted from this number:
    /// a still pointer must not read, and 100 moves must not read 100 times.
    public private(set) var pointerReadbackCount = 0
    /// Where the reading is published (the histogram card). `weak`: a rebuilt inspector releases the
    /// old card, and the loupe must not write into it.
    public weak var pointerReadoutTarget: (any PointerReadoutTarget)? {
        didSet {
            // A plain bool mirror, because the decision is made on the **render** queue and a weak
            // reference may not be loaded from there: `makeFrame` reads this flag, main writes it here.
            pointerReadoutWanted = pointerReadoutTarget != nil
            publishPointerReadout()
            // A card that appears after the picture did needs a frame that **carries the sample**: the
            // frames rendered before it existed asked for no grid, and without this the row would keep
            // reading S4's clamped white until some unrelated render happened. One extra frame, once.
            if pointerReadoutTarget != nil, let frame = lastFrame, frame.sceneLinearSample == nil {
                scheduleRender()
            }
        }
    }
    /// Does anyone want a pointer reading? Main-thread written, render-queue read (see above). It is
    /// what asks a frame for the scene-linear sample even when the frame measures nothing.
    private var pointerReadoutWanted = false

    /// Which frame the last readback was taken from, and from which texel — together they are the
    /// throttle: the same texel of the same frame is never read twice.
    private var pointerSampleFrame = -1
    private var pointerSampleTexel: (x: Int, y: Int)?
    /// Bumped on every `present`. A readback belongs to a frame, not to a mouse event.
    private var frameSerial = 0
    /// Readbacks the throttle refused — the other half of "it did not read".
    public private(set) var pointerReadbacksSkipped = 0

    /// The pointer moved to `point` (canvas points, y down) — the tracking area's `mouseMoved`.
    public func pointerMoved(to point: CGPoint) {
        let bounds = canvasView.bounds
        guard bounds.width > 1, bounds.height > 1, bounds.contains(point) else {
            pointerExited()
            return
        }
        // 037 ②: **one** of the two conditions for a low-resolution backdrop is "the pointer came into
        // the canvas from the inspector or from outside it". A `mouseEntered` routes here too
        // (`LoupeCanvasView` hands both events to this one function), so a single read of "was there
        // no pointer a moment ago" covers both spellings the task names — and a pointer that is
        // already on the canvas never re-triggers it, however many move events arrive.
        let entered = pointerCanvasPoint == nil
        pointerCanvasPoint = point
        if entered { notePointerEnteredCanvas() }
        refreshPointerReadout()
        // A move is the moment before a grab: the selected mask's grips are re-projected here (and
        // only redrawn if a grip actually moved), so picking a gradient in the list shows its
        // control points without waiting for an edit.
        refreshMaskHandles()
    }

    /// The pointer left the canvas (a tracking-area exit, the view leaving its window, a photo switch):
    /// the row goes back to idle and the anchor falls back to the centre.
    public func pointerExited() {
        let had = pointerCanvasPoint != nil || pointerReadout != nil
        pointerCanvasPoint = nil
        pointerSampleTexel = nil
        pointerSampleFrame = -1
        if pointerReadout != nil { pointerReadout = nil }
        if had { pointerReadoutTarget?.clearPointerReadout() }
    }

    /// Read the pixel under the pointer, once per (frame, texel).
    ///
    /// The cost model is the point: a 1×1 `getBytes` is a synchronisation with the GPU, so it happens
    /// **only when the answer can have changed** — a different texel, or a different frame. A resting
    /// pointer and a stream of move events in the same pixel both cost nothing, which is what keeps the
    /// readout off the frame-time budget.
    ///
    /// **What is read** (2026-10-27): the frame's `sceneLinearSample` — the measurement's own grid, the
    /// pixels the plot counted, before S4 — mapped through `PointerSampleLattice`. That is the fix for
    /// the owner's 「上限就是屏幕亮度」: the presented frame is `encode(min(v, headroom))`, so a pixel
    /// the picture holds at +2.3 stops is white in it and can never print `+2.3`. Only a frame with no
    /// grid (nobody reading, or a render without a picture rect) falls back to the frame texture, and the
    /// resulting pixel says `source == .presented` so the two can never be confused.
    private func refreshPointerReadout() {
        guard let point = pointerCanvasPoint, let frame = lastFrame else {
            pointerReadoutTarget?.clearPointerReadout()
            pointerReadout = nil
            pointerReadoutSource = nil
            return
        }
        guard let texel = textureTexel(forViewPoint: point) else {
            pointerReadoutTarget?.clearPointerReadout()
            pointerReadout = nil
            pointerReadoutSource = nil
            return
        }
        if pointerSampleFrame == frameSerial, let last = pointerSampleTexel,
           last.x == texel.x, last.y == texel.y {
            pointerReadbacksSkipped += 1
            return
        }
        pointerSampleFrame = frameSerial
        pointerSampleTexel = texel
        pointerReadbackCount += 1
        let pixel = Self.sample(frame, x: texel.x, y: texel.y, histogram: lastHistogram)
        guard let pixel else {
            pointerReadout = nil
            pointerReadoutSource = nil
            pointerReadoutTarget?.clearPointerReadout()
            return
        }
        pointerReadout = pixel
        pointerReadoutSource = pixel.source
        pointerReadoutTarget?.showPointerReadout(pixel)
    }

    /// Canvas point (points, y down) → the texel of the presented frame that is under it.
    ///
    /// `frame.texture` is the canvas: the frame is rendered **at the viewport's device-pixel size**, so
    /// a canvas pixel *is* a texel (the `× backingScale` is the whole of the conversion), and while a
    /// bridge is moving the texture on screen is still the *old* frame seen through a sampling window —
    /// so the point goes through the inverse of that window first, or the row would read the pixel that
    /// is about to arrive instead of the one the eye is on.
    public func textureTexel(forViewPoint point: CGPoint) -> (x: Int, y: Int)? {
        guard let frame = lastFrame else { return nil }
        let k = backingScale
        var v = (x: Double(point.x) * k, y: Double(point.y) * k)
        let canvas = frame.canvas
        if let bridge = zoomBridge, zoomBridgeCanvas == canvas {
            // The pixels on screen are the *old* frame seen through the running bridge's window.
            let live = bridge.map(atProgress: zoomBridgeProgress())
            if live.scale > 1e-6 {
                v = (x: (v.x - live.x) / live.scale, y: (v.y - live.y) / live.scale)
            }
        }
        let w = Double(canvas.width), h = Double(canvas.height)
        guard v.x >= 0, v.y >= 0, v.x < w, v.y < h else { return nil }
        let tx = v.x * Double(frame.texture.width) / w
        let ty = v.y * Double(frame.texture.height) / h
        return (x: min(frame.texture.width - 1, max(0, Int(tx))),
                y: min(frame.texture.height - 1, max(0, Int(ty))))
    }

    /// One texel of a frame, as a `PointerPixel` — **the scene-linear grid when the frame has one**,
    /// the presented texture otherwise.
    ///
    /// This is the shipped entry point (`refreshPointerReadout`). The grid is the histogram's own
    /// sample, so the reading is the light the *picture* holds — `+2.3` on a panel that renders it as
    /// white — and the frame texture is only the fallback for a frame that carried no grid.
    /// Static and public so the tests can call it on a frame they built themselves, and assert which
    /// source answered (`PointerPixel.source`).
    public static func sample(_ frame: FrameResult, x: Int, y: Int,
                              histogram: Histogram?) -> PointerPixel? {
        if let grid = frame.sceneLinearSample {
            let lattice = PointerSampleLattice(picture: frame.photoRect, grid: grid.size)
            let cell = lattice.gridTexel(forTextureX: x, y: y)
            if let texel = grid.texel(x: cell.x, y: cell.y) {
                return PointerPixel(linearRed: texel.red, green: texel.green, blue: texel.blue,
                                    histogram: histogram)
            }
        }
        return sample(frame.texture, x: x, y: y, histogram: histogram)
    }

    /// One texel of an rgba16f **presented** frame, as a `PointerPixel` — the fallback path.
    ///
    /// Static and public so the tests can call it on a texture they built themselves — the acceptance
    /// test reads the same texel a second way and compares, which is only meaningful if both sides are
    /// the same code path. What it cannot do is recover light above the panel's headroom: S4 already
    /// clamped it, which is why the frame path also carries the scene-linear grid.
    public static func sample(_ texture: MTLTexture, x: Int, y: Int,
                              histogram: Histogram?) -> PointerPixel? {
        guard texture.pixelFormat == .rgba16Float,
              x >= 0, y >= 0, x < texture.width, y < texture.height else { return nil }
        var raw = [UInt16](repeating: 0, count: 4)
        raw.withUnsafeMutableBytes { buffer in
            texture.getBytes(buffer.baseAddress!,
                             bytesPerRow: 4 * MemoryLayout<UInt16>.size,
                             from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
        }
        func channel(_ i: Int) -> Float { Float(Float16(bitPattern: raw[i])) }
        return PointerPixel(encodedRed: channel(0), green: channel(1), blue: channel(2),
                           histogram: histogram)
    }

    private func publishPointerReadout() {
        guard let target = pointerReadoutTarget else { return }
        if let pixel = pointerReadout { target.showPointerReadout(pixel) }
        else { target.clearPointerReadout() }
    }

    /// The middle of the canvas: the anchor a command falls back to when the pointer is elsewhere.
    private func canvasCentrePoint() -> CGPoint {
        CGPoint(x: canvasView.bounds.midX, y: canvasView.bounds.midY)
    }

    /// Canvas points → device pixels for this window. Internal because the projection is published in
    /// device pixels (`LoupeMapping`) and a test that reads a screen rect back into points needs the
    /// same divisor the controller used.
    var backingScale: Double {
        Double(canvasView.window?.backingScaleFactor ?? 2)
    }

    /// The projection for the *current* decode buffer (or the asset's own size before the first
    /// decode lands). Hit-testing must work before the first frame: a double-click queues one.
    ///
    /// While 裁切 mode is on, the projection is built from the tool's **preview** document — the whole
    /// frame with the draft's straighten and flips — so the frame on screen, the crop box drawn on it
    /// and every hit test are one geometry (task 035). Nothing is written: `previewEdit` is a value
    /// derived from the draft for as long as the tool is on.
    public func framing(viewport: ImageSize? = nil) -> LoupeFraming? {
        let size = viewport ?? viewportPixels
        var edit = session?.edit ?? .neutral
        if cropTool.isActive { edit = cropTool.previewEdit(from: edit) }
        if let image = decoded {
            return LoupeFraming(viewport: size,
                                decoded: ImageSize(width: image.width, height: image.height),
                                decodeScale: decodedScale,
                                edit: edit)
        }
        if let asset = session?.anchorAsset, asset.width != nil, asset.height != nil {
            // No decoded rung yet: the frame comes from the **same** authority the mask drag maths
            // uses (`maskSourceSize`, task 028). It stops disagreeing with the decoded framing the
            // moment this photo's first frame is ingested, and it never mixes the stored dimensions
            // into a projection that is otherwise display-oriented.
            let source = session?.maskSourceSize
                ?? ImageSize(width: max(1, asset.width ?? 1), height: max(1, asset.height ?? 1))
            return LoupeFraming(viewport: size,
                                decoded: source,
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

    /// 2026-10-28 (078 P0-1) — one click, one spot.
    ///
    /// The click arrives in **source** space (`normalizedSourcePoint`, the same projection the brush
    /// uses) and the spot lives in **frame** space (the cropped picture — `HealSpot`'s header says
    /// why), so the document's own crop rect is what converts one into the other. A click that lands
    /// outside the crop (on the empty canvas around a cropped picture, or before a decode has
    /// arrived) places nothing: S1.9 has no pixels there.
    ///
    /// The mode and radius come from the panel's view state, and the source is the default one — one
    /// radius to the right, which is Lightroom's own first guess.
    @discardableResult
    public func addHealSpot(atViewPoint point: CGPoint) -> HealSpot? {
        guard let session, let p = normalizedSourcePoint(forViewPoint: point) else { return nil }
        let crop = session.edit.geometry.crop
        let width = max(crop.width, 1e-6), height = max(crop.height, 1e-6)
        let frame = NormalizedPoint((p.x - crop.x) / width, (p.y - crop.y) / height)
        return session.addHealSpot(at: frame)
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

    /// The rubber band **in source pixels** — the space the projection maps *from*. Stored here and
    /// re-projected on every frame (`syncMaskOverlays`) instead of as view points, which is what makes
    /// a pan or a zoom carry the band with the picture: a band kept in view points is frozen at the
    /// coordinates of the mouse-down, and that was the reported 「不跟手」.
    private var shapeDraft: (kind: MaskCreationKind,
                             start: (x: Double, y: Double),
                             current: (x: Double, y: Double))?

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
              let source = normalizedSourcePoint(forViewPoint: point),
              let pixels = sourcePoint(forViewPoint: point) else { return }
        shapeDragStartView = point
        shapeDragStartSource = source
        shapeDraft = (kind: mode.kind, start: pixels, current: pixels)
        syncMaskOverlays()
    }

    public func continueShapeDrag(at point: CGPoint) {
        guard shapeDragStartView != nil, let mode = shapeDragMode else { return }
        // The band moves in **source** space, so the next frame (a pan, a zoom, a resize) can put it
        // back on the picture: the hand's view point is converted once, here.
        if var draft = shapeDraft, let pixels = sourcePoint(forViewPoint: point) {
            draft.current = pixels
            shapeDraft = draft
            syncMaskOverlays()
        }
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
            shapeDraft = nil
            syncMaskOverlays()
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
        shapeDraft = nil
        syncMaskOverlays()
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

    /// True when the armed drag is a **creation** (the inspector's 新建 menu is waiting for a
    /// gesture). Kept apart from `isShapeDragArmed` because the two now sit at different depths of
    /// the gesture stack: a creation outranks the control points (there is no mask yet), while the
    /// blanket adjust-drag ranks **behind** them (task 032).
    public var isShapeCreateArmed: Bool {
        if case .create = shapeDragMode { return true }
        return false
    }

    // MARK: mask control points (task 032)
    //
    // The canvas half of 「蒙版创建后应该产生多个控制点」. Three small pieces:
    //
    //   · the **grips** come from `MaskHandles.handles` (normalised, upright source frame) and are
    //     projected here — the only place that knows the crop, the straighten angle, the flips, the
    //     backing scale and the zoom, i.e. `LoupeFraming`/`LoupeMapping`. No second projection.
    //   · the **hit test** is `MaskHandles.hit`, in view **points**: the radius is the same on screen
    //     at 25 % and at 400 %.
    //   · the **drag** is `MaskCanvasController`'s (the same object that turns a drag into a stroke,
    //     so the "one gesture, one commit" rule is in one place), with
    //     `session.maskSourceSize` as its frame.

    /// The selected mask's adjustable component, with everything a grip needs.
    public struct MaskHandleTarget: Equatable {
        public var maskID: String
        public var component: Int
        public var shape: MaskShape
        public var feather: Double
    }

    /// The selected mask's drawn geometry, or nil when it has none (brush, colour, luminance,
    /// semantic — and no selection at all).
    public func maskHandleTarget() -> MaskHandleTarget? {
        guard let session, let target = session.selectedAdjustableShape(),
              let mask = session.edit.masks.first(where: { $0.id == target.maskID }),
              mask.components.indices.contains(target.component) else { return nil }
        return MaskHandleTarget(maskID: target.maskID, component: target.component,
                                shape: target.shape,
                                feather: mask.components[target.component].feather)
    }

    // MARK: the projection the mask chrome is drawn in (2026-10-27)

    /// The projection the **pixels on the canvas** are drawn with right now, plus the carry from it to
    /// what the eye is looking at.
    ///
    /// At rest it is the camera's own mapping and the identity carry — bit-for-bit the arithmetic this
    /// file always used (`1·p + 0` is `p`). During a stop change the canvas holds the *old* picture
    /// re-presented every display tick through a sampling window, which is **one similarity**
    /// (`LoupeZoomBridge.map(atProgress:)`) and not any camera's projection: the grips have to be
    /// projected by `bridge.fromMapping` — the mapping those pixels were laid out with — and then
    /// carried by that frame's own map. Exactly the rule `cropToolLayout(bridge:progress:)` follows
    /// for the crop frame, so the two overlays cannot disagree about where the picture is.
    public struct MaskPictureProjection: Equatable, Sendable {
        /// The mapping the pixels on the canvas were laid out with.
        public var mapping: LoupeMapping
        /// `p ↦ scale·p + offset`, in **device pixels**, y down. Identity when nothing is animating.
        public var carry: CropCarry
        /// Device pixels per point.
        public var pointScale: Double
    }

    /// Where the mask chrome belongs this instant, in the projection the canvas pixels are in.
    ///
    /// `progress` names the frame of a running bridge explicitly; left out, the progress the bridge has
    /// reached right now is used. A `viewport` override (the headless tests) is always the idle path:
    /// a bridge is measured against the live canvas, never against a size someone made up.
    public func maskPictureProjection(viewport: ImageSize? = nil,
                                      backingScale scaleOverride: Double? = nil,
                                      progress: Double? = nil) -> MaskPictureProjection? {
        let scale = scaleOverride ?? backingScale
        if viewport == nil, let bridge = zoomBridge {
            let frame = progress ?? zoomBridgeProgress()
            return MaskPictureProjection(mapping: bridge.fromMapping,
                                         carry: CropCarry(bridge.map(atProgress: frame)),
                                         pointScale: scale)
        }
        guard let framing = framing(viewport: viewport) else { return nil }
        return MaskPictureProjection(mapping: framing.mapping(of: viewState),
                                     carry: .identity, pointScale: scale)
    }

    // MARK: when the mask chrome is on the canvas at all

    /// True while the inspector is showing the **蒙版** workspace. The canvas' mask chrome belongs to
    /// that panel: grips and the rubber band are drawn only while it is up, and a workspace switch
    /// takes them away instead of leaving them floating over a 调节 panel the user is reading.
    ///
    /// View state, and the loupe's own copy of it — `WorkspaceRootView` publishes the panel's selection
    /// (`InspectorWorkspaceState.onChange` → `setMasksWorkspaceActive`).
    public private(set) var masksWorkspaceActive = false

    /// How many times the overlays were **laid out** (geometry computed and assigned). A hidden
    /// overlay must not appear here at all, which is the number 「隐藏期间更新计数 == 0」 is about.
    public private(set) var maskOverlaySyncCount = 0
    /// Updates refused because the mask workspace is not on screen — the geometry computations the
    /// gate saved. Counted separately so "it did not update" is a claim about a count, not a silence.
    public private(set) var maskOverlayHiddenSkips = 0

    /// Test seams, the same pair the crop overlay has: `false` reproduces the two defects being fixed
    /// (the chrome that only moved when the document changed, and one that cut straight to the target
    /// instead of travelling with the animation), so the reverse evidence is a measurement.
    public var syncsMaskOverlaysOnCameraChange = true
    public var followsMaskOverlaysDuringBridge = true

    /// One frame of a bridge, as the mask chrome was **drawn** on it: which bridge, at what progress,
    /// and the whole thing the overlay views were left holding.
    ///
    /// Recorded by the present tick itself (not reconstructed in a test), because the claim is about
    /// what the eye saw: the same tick, the same progress, the same curve.
    public struct MaskOverlayFrame: Equatable, Sendable {
        public let serial: Int
        public let progress: Double
        public let handles: MaskHandlesLayout?
        public let draft: MaskDraftShape?
    }

    /// Every bridge frame's mask chrome, in order — append-only and capped like the frame log.
    public private(set) var maskOverlayFollowFrames: [MaskOverlayFrame] = []
    private static let maskOverlayFollowFrameLimit = 512

    /// The inspector switched to (or away from) the 蒙版 workspace.
    ///
    /// Away hides **for real**: both overlays stop drawing and are emptied, every gesture that was
    /// pointing at a canvas coordinate is dropped, and `syncMaskOverlays` refuses to compute anything
    /// (so a 120 Hz bridge cannot spend a line of arithmetic on chrome nobody can see).
    ///
    /// The armed 新建 state is deliberately **not** cleared — that is the panel's state, not a
    /// gesture's, and losing it would mean re-choosing 线性渐变 after a glance at 色彩. What is dropped
    /// is the rubber band and the drag, so coming back finds no half-drawn shape from another tab.
    public func setMasksWorkspaceActive(_ active: Bool) {
        guard masksWorkspaceActive != active else { return }
        masksWorkspaceActive = active
        guard !active else {
            syncMaskOverlays()
            return
        }
        // A grip drag in flight puts the shape back to what it was at mouse-down and commits nothing,
        // so a switch mid-drag leaves the document and the history exactly as they were.
        if maskCanvas.isDraggingHandle { maskCanvas.cancelHandleDrag() }
        shapeDragStartView = nil
        shapeDragStartSource = nil
        shapeDraft = nil
        maskHandlesOverlay.active = nil
        syncMaskOverlays()          // the gate now hides, empties and skips
    }

    /// **The only writer** of the mask overlays (2026-10-27).
    ///
    /// Six callers, one function: `setViewState` (every pan tick and every zoom tick), the bridge's own
    /// present tick (`presentZoomBridgeFrame`, with the very progress the pixels went up at),
    /// `finishZoomBridge`, `cancelZoomBridge`, `viewDidLayout` (a resize is a new projection) and
    /// `refreshMaskHandles` (a document or drag change). No timer of its own — the picture already has
    /// one, and a second timeline would drift against it.
    private func syncMaskOverlays(progress: Double? = nil) {
        guard masksWorkspaceActive else {
            maskOverlayHiddenSkips += 1
            hideMaskOverlays()
            return
        }
        guard let projection = maskPictureProjection(progress: progress) else {
            // No projection at all (no photo): draw nothing rather than something made up.
            maskHandlesOverlay.layout = nil
            draftOverlay.draft = nil
            return
        }
        maskOverlaySyncCount += 1
        maskHandlesOverlay.isHidden = false
        draftOverlay.isHidden = false
        maskHandlesOverlay.layout = maskHandlesLayout(projection)
        // The rubber band lives in **source pixels**; the projection is applied here, on every frame,
        // which is what makes it travel with a pan and with a zoom animation.
        if let draft = shapeDraft {
            func point(_ p: (x: Double, y: Double)) -> CGPoint {
                let v = projection.mapping.viewPoint(sourceX: p.x, sourceY: p.y)
                return CGPoint(x: projection.carry.applyX(v.x) / projection.pointScale,
                               y: projection.carry.applyY(v.y) / projection.pointScale)
            }
            draftOverlay.draft = MaskDraftShape(kind: draft.kind,
                                                start: point(draft.start),
                                                current: point(draft.current))
        } else {
            draftOverlay.draft = nil
        }
    }

    /// Leave nothing on screen and nothing to hit: no layout, no band, no highlight, not drawn.
    private func hideMaskOverlays() {
        if maskHandlesOverlay.layout != nil { maskHandlesOverlay.layout = nil }
        if draftOverlay.draft != nil { draftOverlay.draft = nil }
        if maskHandlesOverlay.active != nil { maskHandlesOverlay.active = nil }
        if !maskHandlesOverlay.isHidden { maskHandlesOverlay.isHidden = true }
        if !draftOverlay.isHidden { draftOverlay.isHidden = true }
    }

    private func recordMaskOverlayFrame(serial: Int, progress: Double) {
        guard masksWorkspaceActive else { return }
        maskOverlayFollowFrames.append(MaskOverlayFrame(serial: serial, progress: progress,
                                                        handles: maskHandlesOverlay.layout,
                                                        draft: draftOverlay.draft))
        if maskOverlayFollowFrames.count > Self.maskOverlayFollowFrameLimit {
            maskOverlayFollowFrames
                .removeFirst(maskOverlayFollowFrames.count - Self.maskOverlayFollowFrameLimit)
        }
    }

    /// The views themselves, for the tests that measure what was **drawn** (`isHidden`, `frame`,
    /// `layout`, `draft`). A copy would be a second thing that could be right while the screen is wrong.
    var maskHandlesOverlayView: MaskHandlesOverlayView { maskHandlesOverlay }
    var maskDraftOverlayView: MaskDraftOverlayView { draftOverlay }
    var maskHandlesLayoutForTesting: MaskHandlesLayout? { maskHandlesOverlay.layout }
    var maskDraftForTesting: MaskDraftShape? { draftOverlay.draft }

    /// Grips and guides in view points for the overlay (and for the tests: this is what a click is
    /// hit-tested against).
    ///
    /// `viewport`/`backingScale` exist for the headless tests — without a window the canvas has no
    /// size and no scale, and a hit test must still be able to say "this point, in this frame".
    ///
    /// `nil` while the inspector is **not** showing the 蒙版 workspace: hidden chrome is not drawn, not
    /// hit-testable and not computed (see `setMasksWorkspaceActive`). A click where a grip used to be
    /// therefore belongs to the canvas — a pan — which is the second half of the report
    /// 「蒙版控件在退出蒙版菜单栏后应该隐藏」.
    public func maskHandlesLayout(viewport: ImageSize? = nil,
                                  backingScale scaleOverride: Double? = nil)
        -> MaskHandlesLayout? {
        guard masksWorkspaceActive,
              let projection = maskPictureProjection(viewport: viewport,
                                                     backingScale: scaleOverride) else { return nil }
        return maskHandlesLayout(projection)
    }

    /// The layout in one explicit projection — the projection is the *only* variable, so what is
    /// drawn, what is hit and what the tests measure cannot drift apart.
    private func maskHandlesLayout(_ projection: MaskPictureProjection) -> MaskHandlesLayout? {
        guard let target = maskHandleTarget() else { return nil }
        return MaskHandles.layout(shape: target.shape, feather: target.feather,
                                  source: cropSourceSize,
                                  mapping: projection.mapping,
                                  pointScale: projection.pointScale,
                                  carry: projection.carry)
    }

    /// The grip under `point` (view points), or nil.
    public func hitMaskHandle(atViewPoint point: CGPoint) -> MaskHandleKind? {
        guard let layout = maskHandlesLayout() else { return nil }
        return MaskHandles.hit(point, in: layout)
    }

    /// Pure version of "is a grip under this point" — what `gestureOwner` asks before
    /// `beginMaskHandleDrag` takes it (task 035 folded the canvas' priority chain into one function,
    /// and a router that began a drag as a side effect of being asked would fire twice).
    public func isMaskHandleArmed(atViewPoint point: CGPoint) -> Bool {
        hitMaskHandle(atViewPoint: point) != nil
    }

    /// Take the grip under the click. `true` means the click belongs to a control point and **must
    /// not** also start a pan or a shape-adjust drag — the caller returns on `true`.
    @discardableResult
    public func beginMaskHandleDrag(atViewPoint point: CGPoint,
                                    viewport: ImageSize? = nil,
                                    backingScale scaleOverride: Double? = nil) -> Bool {
        guard let framing = framing(viewport: viewport) else { return false }
        let scale = scaleOverride ?? backingScale
        let mapping = framing.mapping(of: viewState)
        guard let layout = maskHandlesLayout(viewport: viewport, backingScale: scale),
              let kind = MaskHandles.hit(point, in: layout) else { return false }
        let source = mapping.sourcePoint(viewX: Double(point.x) * scale,
                                         viewY: Double(point.y) * scale)
        guard source.x.isFinite, source.y.isFinite else { return false }
        let normalized = NormalizedPoint(source.x / max(framing.sourceWidth, 1),
                                        source.y / max(framing.sourceHeight, 1))
        guard maskCanvas.beginHandleDrag(kind, at: normalized) else { return false }
        maskHandlesOverlay.active = kind
        refreshMaskHandles()
        return true
    }

    /// One tick of a control-point drag. ⇧ = uniform (an ellipse keeps its aspect).
    public func continueMaskHandleDrag(atViewPoint point: CGPoint, uniform: Bool = false,
                                       viewport: ImageSize? = nil,
                                       backingScale scaleOverride: Double? = nil) {
        guard maskCanvas.isDraggingHandle, let framing = framing(viewport: viewport) else { return }
        let scale = scaleOverride ?? backingScale
        let source = framing.mapping(of: viewState)
            .sourcePoint(viewX: Double(point.x) * scale, viewY: Double(point.y) * scale)
        guard source.x.isFinite, source.y.isFinite else { return }
        maskCanvas.extendHandleDrag(to: NormalizedPoint(source.x / max(framing.sourceWidth, 1),
                                                       source.y / max(framing.sourceHeight, 1)),
                                    uniform: uniform)
        refreshMaskHandles()
    }

    /// Mouse-up: one commit, one ⌘Z.
    public func endMaskHandleDrag() {
        maskCanvas.endHandleDrag()
        maskHandlesOverlay.active = nil
        refreshMaskHandles()
    }

    /// Escape: the shape goes back, the history does not grow.
    public func cancelMaskHandleDrag() {
        maskCanvas.cancelHandleDrag()
        maskHandlesOverlay.active = nil
        refreshMaskHandles()
    }

    /// Rebuild the overlays from the live document and the current projection. Cheap (a dozen points)
    /// and idempotent: the overlay's setter compares before it redraws, so calling it on every mouse
    /// move is free. A document change does **not** move the picture, so the projection is the idle one
    /// unless a stop change happens to be travelling (then the running bridge's frame is used).
    public func refreshMaskHandles() {
        syncMaskOverlays()
    }

    /// Control-point drags committed through the canvas (one per ⌘Z).
    public var maskHandleDrags: Int { maskCanvas.maskHandleDrags }
    /// The grip the last drag took, for the status/QA line.
    public var lastMaskHandleLabel: String? { maskCanvas.lastHandleLabel }
    public var isMaskHandleDragging: Bool { maskCanvas.isDraggingHandle }

    // MARK: 旋转 / 裁切 (task 035)
    //
    // The canvas half of 「添加旋转/裁切工具」. Four small pieces, and none of them renders anything:
    //
    //   · the **frame** comes from `CropTool.layout` (the draft rect through the one projection), so a
    //     portrait file, a straightened frame and a flipped one are the same code path;
    //   · the **hit test** is `CropTool.hit`, in view points (the same size on screen at every zoom);
    //   · the **draft** lives in `CropToolController` — view state, never written to the document
    //     until 应用 (one `applyEdit`, one `commitEdit`, so one ⌘Z);
    //   · the **preview** is `CropToolController.previewEdit`, which `framing()` and `makeJob` already
    //     read: while the tool is on, the canvas shows the whole frame with the draft's straighten and
    //     flips, which is what makes 「进入时显示完整图像」 true without touching the document.
    //
    // The frame is `session.maskSourceSize` — the upright frame the renderer ingested (task 028) —
    // and never `asset.width/height`, which are the *stored* dimensions and are transposed for
    // EXIF 5…8.

    public var isCropToolActive: Bool { cropTool.isActive }

    /// What a press at `point` belongs to — **one** decision, in one place.
    ///
    /// The order is the gesture's depth: the crop tool first, because while it is on the canvas is a
    /// crop frame and nothing else (Phos gates every other canvas gesture on `cropMode` for the same
    /// reason, `local/src/swift-raw/Zenodeng_Phos/Sources/Phos/WorkspaceCanvasInput.swift:32`); then
    /// the eyedropper's one-shot; then a mask's creation, its grips and its adjust drag; then the
    /// paint drag; then double-click; and last the pan. `LoupeCanvasView.mouseDown` switches on
    /// exactly this value, so a test can ask "who owns this click?" without synthesising an `NSEvent`
    /// — and the answer cannot drift from the shipped path.
    public func gestureOwner(atViewPoint point: CGPoint, clickCount: Int = 1) -> LoupeCanvasGesture {
        if isCropToolActive {
            return LoupeCanvasGesture.crop(clickCount: clickCount, hit: cropHit(atViewPoint: point))
        }
        if isEyedropperArmed { return .eyedropper }
        if session?.healTool == true { return .healClick }
        if isShapeCreateArmed { return .maskCreate }
        if isMaskHandleArmed(atViewPoint: point) { return .maskHandle }
        if isShapeDragArmed { return .maskShape }
        if maskCanvas.isArmed { return .paint }
        if clickCount >= 2 { return .doubleClick }
        return .pan
    }

    /// The one frame the crop tool measures with. Same authority as the mask drag maths, so a portrait
    /// file's frame lands on its picture (task 028) and a review of this file can grep one call site.
    ///
    /// 2026-10-28 (P0-10): this is the frame **in the document's direction** — the crop tool's rect is
    /// measured in the turned frame (schema 9), so a 90° turn swaps the two numbers here and every
    /// consumer of this property (layout, `effectiveCrop`, the pixel readout, the clamp) is measuring
    /// the frame the user sees. At `quarterTurns == 0` it is `maskSourceSize` unchanged.
    public var cropSourceSize: ImageSize {
        let stored = session?.maskSourceSize ?? ImageSize(width: 1, height: 1)
        return (session?.edit.geometry ?? .identity).orientedSource(stored)
    }

    /// 显影 ▸ 裁切与旋转 (⌘R): enter, or — if it is already on — 应用 and leave.
    ///
    /// Entering does three things beyond the mode switch, and each is load-bearing: the mask tools are
    /// disarmed (they are canvas gestures too, and the frame owns every drag now), the camera goes to
    /// **fit** (the whole picture has to be visible to be cropped), and one render is requested for
    /// the preview document.
    @discardableResult
    public func toggleCropTool() -> Bool {
        if cropTool.isActive { return applyCropTool() }
        return beginCropTool()
    }

    @discardableResult
    public func beginCropTool() -> Bool {
        guard let session, session.mode == .loupe, session.anchorAsset != nil else {
            // A silent `false` here is indistinguishable from a broken shortcut: the menu item is greyed
            // by the same two conditions (`EditorWindowController.validateMenuItem`), so ⌘R in a window
            // with no anchor does *nothing at all*. Say so out loud instead.
            NSSound.beep()
            return false
        }
        guard cropTool.begin() else { return false }
        // The camera is remembered and restored on exit: a precision tool is a temporary fit over the
        // session viewport (`local/src/swift-raw/Zenodeng_Phos/WINDOW_INTEGRATION.md:14`).
        cropEntryState = viewState
        // One gesture owner while the frame is up: no eyedropper, no shape drag, no brush.
        cancelEyedropper()
        if isShapeDragArmed { cancelShapeDrag() }
        session.pendingMaskShape = nil
        session.maskTool = .off
        zoomToFit()
        refreshCropTool()
        requestEditRender()
        return true
    }

    /// 082 — the card's section resets (and its title) write the document; the frame on screen is the
    /// draft, so it is re-seeded from the new document and re-laid-out in the same turn.
    public func afterCropGeometryReset() {
        cropTool.reseedDraftFromDocument()
        if cropTool.isActive {
            refreshCropTool()
            requestEditRender()
        }
    }

    /// With this `false`, the workspace stops driving the mode — 082's anti-proof. A test flips it to
    /// show that 「切到变换 → 选框出现」 goes red without the hook; nothing in the app touches it.
    var workspaceDrivesCropMode = true

    /// 082 — the **workspace** drives the mode: seeing the 裁切 card (变换) *is* being in 裁切 mode;
    /// leaving that workspace (or clicking another card) ends it.
    ///
    /// The user's words: 「点击右侧裁切菜单后，自动进入裁切模式出现裁切选框。离开裁切模式也退出裁切选框」.
    /// So the two entry points the mode always had (the 直角尺 icon, ⌘R) are kept — they are the explicit
    /// "same mode, again" shortcuts — and this adds the third one: the card being on screen.
    ///
    /// It is still **view state**: `beginCropTool` / `cancelCropTool` write neither the document nor
    /// the history (the acceptance asserts `documentHash` / `history.count` / `editRevision`), and
    /// leaving 变换 *cancels* rather than applies — a workspace switch is not the user saying 「应用」.
    ///
    /// Silently does nothing when there is nothing to crop (no anchor, not in 单图 mode): a workspace
    /// click must not beep because the library is still loading.
    @discardableResult
    public func setCropWorkspaceActive(_ active: Bool) -> Bool {
        guard workspaceDrivesCropMode else { return false }
        if active {
            guard !cropTool.isActive else { return false }
            guard let session, session.mode == .loupe, session.anchorAsset != nil else { return false }
            return beginCropTool()
        }
        guard cropTool.isActive else { return false }
        cancelCropTool()
        return true
    }

    /// ↵ (and 双击框内): the draft becomes the document, once.
    @discardableResult
    public func applyCropTool() -> Bool {
        guard cropTool.isActive else { return false }
        let applied = cropTool.apply()
        leaveCropTool()
        return applied
    }

    /// Esc: the frame goes away and **nothing** is written — the document, its revision and its
    /// history are exactly what they were before ⌘R.
    public func cancelCropTool() {
        guard cropTool.isActive else { return }
        cropTool.cancel()
        leaveCropTool()
    }

    private func leaveCropTool() {
        if let previous = cropEntryState {
            // 072 §A1 — **动画**回到进入前 framing, not a cut. The endpoint is the entry camera
            // itself (`previous`, restored verbatim: same rung, same pan — nothing is re-fitted or
            // re-centred), and the travel there is the loupe's own stop-change bridge, forced on
            // because a crop change moves the picture's *content* as well as its ratio.
            let leaving = viewState
            setViewState(previous, forceAnimation: true)
            if viewState == previous, leaving != previous {
                cropExitAnimations += 1
            }
        }
        cropEntryState = nil
        refreshCropTool()
        requestEditRender()
    }

    /// The photo changed, or the loupe is not the module on screen: the frame goes away without
    /// writing and without counting as a 取消 (the user did not press Esc).
    private func dropCropToolIfStale() {
        guard cropTool.isActive else { return }
        let anchor = session?.anchorID
        let stale = anchor != lastHandledAnchorID || session?.mode != .loupe
        guard stale else { return }
        cropTool.detach()
        cropEntryState = nil
        lastHandledAnchorID = anchor
        refreshCropTool()
    }

    // MARK: 变换 ▸ 水平翻转 / 垂直翻转 (072 §F)

    /// 菜单 ▸ 变换 ▸ 水平翻转 (⌥⌘H) and 裁切工具栏的 水平 switch — **one** action, one field.
    ///
    /// The flip is a **document-level geometry action**: `GeometryGroup.flipHorizontal` is written
    /// through `applyEdit`, committed once, and undone by one ⌘Z. It used to be a *draft* flag of the
    /// crop tool, which meant the bar and the menu could disagree about it and the bar's switch was
    /// invisible to ⌘Z until the crop was applied. Now the document is the only place a flip lives, so
    /// the menu's tick, the bar's switch and S0's `uv` flip all read the same bit.
    @discardableResult
    public func flipHorizontal() -> Bool { flip(horizontal: true) }

    /// 菜单 ▸ 变换 ▸ 垂直翻转 (⌥⌘V) / 裁切工具栏的 垂直 switch.
    @discardableResult
    public func flipVertical() -> Bool { flip(horizontal: false) }

    @discardableResult
    private func flip(horizontal: Bool) -> Bool {
        guard let session, session.mode == .loupe, session.anchorID != nil else {
            NSSound.beep()          // nothing to flip: say so instead of a silent no-op
            return false
        }
        session.applyEdit { model in
            if horizontal { model.geometry.flipHorizontal.toggle() }
            else { model.geometry.flipVertical.toggle() }
        }
        // The picture changed, so the frame the crop tool draws must follow it (the overlay is built
        // from the same flips) — and a mode that is on gets one render.
        if cropTool.isActive { refreshCropTool() }
        requestEditRender()
        return session.commitEdit(label: horizontal ? "水平翻转" : "垂直翻转")
    }

    /// The document's flips — what the menu ticks and the bar's two switches show.
    public var isFlippedHorizontally: Bool { session?.edit.geometry.flipHorizontal ?? false }
    public var isFlippedVertically: Bool { session?.edit.geometry.flipVertical ?? false }

    // MARK: 变换 ▸ 顺时针/逆时针旋转 90° (P0-10)

    /// 顺时针旋转 90° (⌘]) — the card's 右 button, the menu row and the shortcut, **one** verb.
    ///
    /// The document's geometry is the whole state: `quarterTurns` (0…3) turns the frame, the crop
    /// rect turns with it (`GeometryGroup.turn` → `CropMath.turnedClockwise`), and the straighten
    /// angle and the flips keep their numbers because they are measured in the frame the user sees.
    /// One `applyEdit` + one `commitEdit(coalesce: false)`, so ⌘Z takes a turn back in one press —
    /// a turn is a **discrete command**, never the continuation of whatever slider was last dragged.
    ///
    /// Four presses are the identity: the rect's edge arithmetic is exact (`1 − x` and a
    /// permutation), so turn 4 hands the renderer the same document it had at turn 0, and the frame
    /// comes back byte for byte (`QuarterTurnTests.testFourTurnsReturnTheSameFrame`).
    @discardableResult
    public func rotateQuarterClockwise() -> Bool { rotateQuarter(clockwise: true) }

    /// 逆时针旋转 90° (⌘[).
    @discardableResult
    public func rotateQuarterCounterClockwise() -> Bool { rotateQuarter(clockwise: false) }

    @discardableResult
    public func rotateQuarter(clockwise: Bool) -> Bool {
        guard let session, session.mode == .loupe, session.anchorID != nil else {
            NSSound.beep()      // nothing to turn: say so instead of a silent no-op
            return false
        }
        // 077/072's rule for a discrete geometry action inside a crop session: close the session
        // first (it commits the crop-so-far as its own row, or nothing when the rect did not move),
        // write the turn, then reopen a fresh one — the draft is re-seeded from the turned document,
        // so the frame on screen keeps covering the pixels it covered before the press.
        let inSession = session.isToolSessionActive
        if inSession { session.endToolSession(label: "裁切与旋转") }
        var turned = false
        session.applyEdit { model in turned = model.turn(clockwise: clockwise) }
        guard turned else {
            if inSession { session.beginToolSession("裁切", label: "裁切与旋转") }
            return false
        }
        // **The row is committed before the crop session is reopened.** `commitEdit` answers `nil`
        // inside a tool session (077: the session owns the next snapshot), so committing after the
        // reopen wrote nothing — and the turn then lived only in memory until 应用, which is the
        // 「点了一下没反应」 a crop session showed (082 measured it: `quarterTurns` stayed 0 and the
        // history gained no row). Writing the row first is also what P0-10 promised: one press,
        // one snapshot, with or without the frame up.
        let committed = session.commitEdit(label: clockwise ? "顺时针旋转 90°" : "逆时针旋转 90°",
                                           coalesce: false)
        if inSession { session.beginToolSession("裁切", label: "裁切与旋转") }
        if cropTool.isActive { refreshCropTool() }
        requestEditRender()
        return committed
    }

    /// The document's quarter turn and the badge the 变换 card prints for it.
    public var quarterTurns: Int { session?.edit.geometry.quarterTurns ?? 0 }
    public var quarterTurnBadge: String { Self.quarterTurnBadge(for: quarterTurns) }

    /// `0°` / `90°` / `180°` / `270°` — clockwise, the number the badge shows and the one
    /// `tiff:Orientation` is derived from (`XMPOrientation`), so the panel and the sidecar agree.
    public static func quarterTurnBadge(for turns: Int) -> String {
        "\(GeometryGroup.normalizedQuarterTurns(turns) * 90)°"
    }

    /// The document's flips — what the menu ticks and the bar's two switches show.

    /// The crop frame's layout in view points, for the overlay and for the tests.
    ///
    /// `viewport`/`backingScale` exist for the headless tests, exactly as they do for
    /// `maskHandlesLayout`: without a window the canvas has no size, and a hit test must still be
    /// able to say "this point, in this frame".
    public func cropToolLayout(viewport: ImageSize? = nil,
                               backingScale scaleOverride: Double? = nil) -> CropToolLayout? {
        guard cropTool.isActive else { return nil }
        let scale = scaleOverride ?? backingScale
        guard let mapping = cropMapping(viewport: viewport) else { return nil }
        return cropTool.layout(mapping: mapping, source: cropSourceSize, pointScale: scale)
    }

    /// The projection the crop layout is built from at the current camera.
    private func cropMapping(viewport: ImageSize? = nil) -> LoupeMapping? {
        if let framing = framing(viewport: viewport) {
            return framing.mapping(of: viewState)
        }
        // No projection yet (no photo at all): draw the frame against the session's own upright
        // frame same as everything else, rather than return nothing. Same authority, same maths.
        let size = viewport ?? viewportPixels
        let frame = cropSourceSize
        return LoupeFraming(viewport: size,
                            sourceWidth: Double(frame.width),
                            sourceHeight: Double(frame.height),
                            crop: .full,
                            straightenDegrees: cropTool.draft.straighten,
                            flipH: isFlippedHorizontally,
                            flipV: isFlippedVertically).mapping(of: viewState)
    }

    /// The layout the **pixels on the canvas** are drawn at, `progress` of the way through a stop
    /// change (2026-10-27 ②: 「裁切框在缩放动画中不跟着动」).
    ///
    /// A bridge frame is not a camera: the pixels are the *previous* projection's picture carried by
    /// one similarity (`LoupeZoomBridge.map(atProgress:)`). So the frame is projected by the very
    /// mapping those pixels were laid out with (`bridge.fromMapping`) and then carried by that same
    /// map — one transform, the same one the present pass drew with, in the same tick. At `progress 0`
    /// the carry is the identity (the frame does not move on the first frame); at `progress 1` it is
    /// the target camera's, value for value.
    private func cropToolLayout(bridge: LoupeZoomBridge, progress: Double) -> CropToolLayout? {
        guard cropTool.isActive else { return nil }
        return cropTool.layout(mapping: bridge.fromMapping, source: cropSourceSize,
                               pointScale: backingScale,
                               carry: CropCarry(bridge.map(atProgress: progress)))
    }

    /// The grip under `point` (view points): corner, edge, `.inside` or `.outside`. `nil` only when
    /// the tool is off.
    public func cropHit(atViewPoint point: CGPoint) -> CropToolHandle? {
        guard let layout = cropToolLayout() else { return nil }
        return CropTool.hit(point, in: layout)
    }

    /// The layout the overlay view is **drawing** at this instant (`nil` when the tool is off).
    ///
    /// ① is a claim about the view and the camera agreeing, so the number has to come from the view —
    /// recomputing `cropToolLayout()` in the test would pass even if `syncCropOverlay` were never
    /// called.
    var cropOverlayLayoutForTesting: CropToolLayout? { cropOverlay.layout }

    /// **Is the frame really on screen?** — the 2026-10-27 card's acceptance.
    ///
    /// `isCropToolActive` is a fact about the tool; it says nothing about the overlay the user is
    /// supposed to see. This asks the view itself: it is not hidden, it is in a parent, that parent has
    /// a window, it has a laid-out rect, and it is drawing a frame (`layout != nil`). A tool that went
    /// active while the overlay stayed hidden fails here, which is exactly the failure a "点图标就进入
    /// 裁切模式" claim can hide.
    var isCropOverlayOnScreenForTesting: Bool {
        !cropOverlay.isHidden
            && cropOverlay.superview != nil
            && cropOverlay.window != nil
            && cropOverlay.layout != nil
            && cropOverlay.frame.width > 1
            && cropOverlay.frame.height > 1
    }

    /// Take the press. `true` means the canvas is dragging the frame and must not pan.
    @discardableResult
    public func beginCropDrag(atViewPoint point: CGPoint, rotate: Bool = false,
                              viewport: ImageSize? = nil,
                              backingScale scaleOverride: Double? = nil) -> Bool {
        guard cropTool.isActive, let framing = framing(viewport: viewport) else { return false }
        let scale = scaleOverride ?? backingScale
        let started = cropTool.beginDrag(atViewPoint: point,
                                         mapping: framing.mapping(of: viewState),
                                         source: cropSourceSize, pointScale: scale,
                                         rotate: rotate)
        refreshCropTool()
        return started
    }

    /// One tick of a frame drag (or of a ⌘-rotation). No render is requested per tick: a crop drag
    /// only moves the overlay, which is AppKit, not the graph. The exception is the rotation, which
    /// moves the *picture* — the bar's `onChange` asks for that frame.
    public func continueCropDrag(atViewPoint point: CGPoint,
                                 viewport: ImageSize? = nil,
                                 backingScale scaleOverride: Double? = nil) {
        guard cropTool.isActive, cropTool.isDragging, let framing = framing(viewport: viewport) else {
            return
        }
        let scale = scaleOverride ?? backingScale
        let before = cropTool.draft.straighten
        cropTool.continueDrag(atViewPoint: point, mapping: framing.mapping(of: viewState),
                              source: cropSourceSize, pointScale: scale)
        refreshCropTool()
        if cropTool.draft.straighten != before { requestEditRender() }
    }

    /// Mouse-up: the draft stays, the document is still untouched.
    public func endCropDrag() {
        cropTool.endDrag()
        refreshCropTool()
    }

    /// Escape mid-drag.
    public func cancelCropDrag() {
        let before = cropTool.draft.straighten
        cropTool.cancelDrag()
        refreshCropTool()
        if cropTool.draft.straighten != before { requestEditRender() }
    }

    /// Rebuild the overlay and the bar from the live draft. Cheap (a dozen points) and idempotent.
    public func refreshCropTool() {
        let active = cropTool.isActive
        cropOverlay.isHidden = !active
        cropBar.isHidden = !active
        // 072 §E4 — the zoom pill is **not** a sidebar 调节, and the user asked for it explicitly:
        // 「进入裁切模式的缩放功能也要保留」. Nothing hides it here any more (it used to be hidden while
        // the frame was up). It is canvas chrome: the frame owns the *picture* gestures, the pill owns
        // the camera, and neither can move the other's number.
        // 072 §E1/§E2 — the mode change is published once, so the workspace can put the inspector's
        // event layer away (and hand it back on exit) instead of merely greying its rows.
        if publishedCropModeActive != active {
            publishedCropModeActive = active
            onCropModeChange?(active)
        }
        // ② — the pill lives in a different corner while the frame is up (the bar is centred at the
        // bottom of the canvas). Set **before** the `guard`, because leaving the tool is the case that
        // has to put it back.
        layoutZoomSlider()
        guard active else {
            cropOverlay.layout = nil
            cropOverlay.active = nil
            return
        }
        syncCropOverlay()
        cropBar.sync()
        layoutCropBar()
        // ④ — the draft's own geometry (拉直 / 裁切 / 翻转) is part of the document the low-resolution
        // whole picture is made from, so a change to it retires the cached one.
        noteBackdropKeyMoved()
    }

    // MARK: 082 (追加) — 裁切模式的相机边界：任何时候「裁切框 ⊆ 画布」
    //
    // 用户 2026-10-28 的两条追加要求合成一条不变式：裁切模式下缩放不许把裁切框放大到画布之外，平移
    // 不许把裁切框推出画布；越界的请求不是被弹回、不是被惯性吃掉，而是**钳住**（缩放停在
    // `maxZoom`，平移停在框贴边的那一格）。几何全部在 `CropCanvasClamp` 里，这里只做三件事：
    //
    //   · 把草稿的四条边（源像素）交给它 —— `cropFrameRect`；
    //   · 在相机写入的唯一入口（`setViewState`）套用它 —— 滚轮、捏合、pill、⌘=/⌘−、双击、拖拽平移、
    //     两指滚动全都经过那一行，所以没有第二条路径能绕过；
    //   · 在**算锚点之前**先把请求的 zoom 钳住（`zoom(to:)` / `zoomToActualSize` / `magnify`），否则
    //     指针锚定算的是用户请求的那个级别，落地却是另一个。
    //
    // 框**不动**：被挪的是画面（相机的 centre）。这与 ⑦ `clampToView` 不同，⑦ 是「框太大→缩小框」的
    // 兜底（拖手柄仍需要它），这里是把相机挡在「框刚好内接于画布」那一级之前。

    /// With this `false`, the crop session's camera clamp does nothing — 082 (追加)'s anti-proof. A test
    /// flips it to show that 「框 ⊆ 画布」 and 「钳位后不再变化」 go red without it; the app never does.
    var clampsCropCamera = true

    /// The crop frame in **source pixels** — the four edges the draft is drawing right now.
    public func cropFrameRect(source: ImageSize? = nil) -> CGRect? {
        guard cropTool.isActive else { return nil }
        let src = source ?? cropSourceSize
        let w = Double(max(src.width, 1)), h = Double(max(src.height, 1))
        let c = cropTool.effectiveCrop(source: src)
        return CGRect(x: c.left * w, y: c.top * h, width: c.width * w, height: c.height * h)
    }

    /// 「框恰好内接于画布」那一级 —— 裁切模式允许的最大缩放（canvas px per source px）。
    ///
    /// Not a constant: the canvas' size and the frame's size both enter, so a resized window, an
    /// anchored pan and a dragged handle all move it. `nil` when there is no frame to measure (the
    /// tool is off) or the projection is degenerate.
    public func cropZoomLimit(viewport: ImageSize? = nil) -> Double? {
        guard clampsCropCamera else { return nil }
        guard let frame = cropFrameRect(), let framing = framing(viewport: viewport) else { return nil }
        let canvas = CGSize(width: Double(framing.viewport.width),
                            height: Double(framing.viewport.height))
        let limit = CropCanvasClamp.maxZoom(canvas: canvas, frame: frame)
        guard limit > 0 else { return nil }
        return min(limit, LoupeViewState.maximumZoom)
    }

    /// A requested camera, as the crop session allows it: zoom clamped to `cropZoomLimit`, then the
    /// window centre moved (never the frame) until the frame is back inside the canvas.
    ///
    /// The identity outside 裁切 mode, and the identity for `.fit` (at fit the whole frame is
    /// inscribed in the viewport by construction, so there is nothing to clamp). That is what makes
    /// 「退出裁切后缩放/平移恢复自由」 true without a second rule.
    public func clampedToCropCanvas(_ state: LoupeViewState,
                                    viewport: ImageSize? = nil) -> LoupeViewState {
        guard clampsCropCamera, cropTool.isActive, state.mode == .actual,
              let frame = cropFrameRect(), let framing = framing(viewport: viewport) else { return state }
        let canvas = CGSize(width: Double(framing.viewport.width),
                            height: Double(framing.viewport.height))
        let limit = min(CropCanvasClamp.maxZoom(canvas: canvas, frame: frame),
                        LoupeViewState.maximumZoom)
        guard limit > 0 else { return state }
        var next = state
        next.zoom = limit < LoupeViewState.minimumZoom
            ? limit
            : min(LoupeViewState.clampZoom(state.zoom), limit)
        let centre = CropCanvasClamp.clampCenter(x: state.centerX, y: state.centerY,
                                                 canvas: canvas, frame: frame, zoom: next.zoom)
        next.centerX = centre.x
        next.centerY = centre.y
        return next
    }

    /// ⑦ — the model-layer clamp, run before anything reads the layout (and after any gesture that
    /// could have put the frame outside the canvas: a drag, a zoom, a pan, a straighten).
    @discardableResult
    private func clampCropFrameToCanvas() -> Bool {
        guard cropTool.isActive, let framing = framing() else { return false }
        return cropTool.clampToView(mapping: framing.mapping(of: viewState), source: cropSourceSize)
    }

    /// ① — the overlay from the **current** projection: the frame quad, the eight grips and the
    /// nine-square grid, in one assignment, so nothing on screen can be half-updated.
    ///
    /// Called from `setViewState` (every zoom and pan), from `refreshCropTool` (every draft and mode
    /// change) and from `viewDidLayout` (a resize is a new projection). One function, so "framing
    /// changed → overlay follows" is a single place to look — the wheel, the pinch, the pill, ⌘=/⌘−,
    /// the double-click and the two-finger scroll all end here.
    private func syncCropOverlay(progress: Double? = nil) {
        guard cropTool.isActive else {
            if cropOverlay.layout != nil {
                cropOverlay.layout = nil
                cropOverlay.active = nil
            }
            return
        }
        // ② (2026-10-27) — mid-animation the frame is a rect of the *picture on the canvas*, not of the
        // camera: project it with the bridge's own mapping and carry it by that frame's own similarity.
        // No clamp and no bar sync here: the draft is already lawful (it was clamped when the stop
        // change started, against the target geometry) and the bar's numbers describe the draft, not
        // the transient picture. The one assignment keeps quad, eight grips and grid on one projection.
        //
        // `progress` names the frame explicitly; left out, a running bridge is read at the progress it
        // has reached right now — so a draft change or a mode refresh during a transition cannot jump
        // the frame to the target either.
        if let bridge = zoomBridge {
            cropOverlay.layout = cropToolLayout(bridge: bridge,
                                                progress: progress ?? zoomBridgeProgress())
            cropOverlay.active = cropTool.isDragging ? cropTool.lastHandle : nil
            return
        }
        // ⑦ first: a zoom or a pan is exactly what can put the frame outside the canvas, so the
        // clamp belongs on this path and not only on the drag paths. When it moves the draft the bar's
        // numbers move with it, or the readout would describe a rect that is no longer on screen.
        if clampCropFrameToCanvas() { cropBar.sync() }
        cropOverlay.layout = cropToolLayout()
        cropOverlay.active = cropTool.isDragging ? cropTool.lastHandle : nil
    }

    private func layoutCropBar() {
        guard !cropBar.isHidden else { return }
        cropBar.layout(in: container.bounds)
    }

    // MARK: edit re-render (50 ms debounce, single-flight)

    /// 派单 031: how long after the hand stops a detail change is re-developed at **full** size.
    ///
    /// The window the task asks for is 150–250 ms; 200 ms sits in the middle. Shorter and a drag
    /// with a stutter starts a 60 MP development it will have to throw away; longer and the picture
    /// stays soft after the user has visibly stopped.
    public static let detailSettleInterval: TimeInterval = 0.2

    /// True while a 细节/降噪 slider is held. It decides **the rung**, never the document:
    /// `makeJob` asks the ladder for the preview rung while `detailPreview` is on, and for the full
    /// one otherwise.
    private var detailGesturing = false
    /// True while the frames being produced are preview-rung frames. Cleared by the "hand stopped"
    /// timer, so a drag that pauses for 200 ms gets its full-size development — and the next tick
    /// (if the drag resumes) puts the preview back on.
    private var detailPreview = false
    /// The pending "the hand stopped" re-development.
    private var detailSettle: DispatchWorkItem?
    /// The identity of the last preview rung this loupe asked for during a detail drag, so the next
    /// tick can drop the one it superseded instead of queueing a decode for every thumb position.
    private var pendingDetailPreviewIdentity: String?

    /// A 细节/降噪 slider was grabbed: the frames that follow rebuild from the preview rung.
    public func beginDetailAdjustment() {
        detailGesturing = true
        detailPreview = true
        detailSettle?.cancel()
        detailSettle = nil
    }

    /// The slider was released: commit-time work is the caller's; this only schedules the full-size
    /// re-development for `detailSettleInterval` later (the same "hand stopped" timer a paused drag
    /// gets, so holding still and letting go behave identically).
    public func endDetailAdjustment() {
        detailGesturing = false
        scheduleDetailSettle()
    }

    /// Arm (or re-arm) the "the hand stopped" timer. Every detail tick re-arms it, so a drag produces
    /// exactly one full-size development — after the last movement, not during it.
    private func scheduleDetailSettle() {
        detailSettle?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.detailSettle = nil
            // The hand stopped: whatever produced the last frame was a preview, so this one is the
            // full-size development the spec asks for 150–250 ms after the movement ended.
            self.detailPreview = false
            self.requestSettleFrame()
        }
        detailSettle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.detailSettleInterval, execute: work)
    }

    /// Ask for one frame at the current camera, on whichever path this loupe is running.
    ///
    /// In the app that is an **edit** frame (`requestEditRender`, with the slider timestamp that feeds
    /// the latency counters). A loupe with a `frameSource` — `--ui-smoke`, the tests, an import
    /// preview — has no catalog session to be "in the loupe of", so it asks for a viewport frame
    /// instead; both end in `renderFrame`, which is where the rung decision actually lives.
    private func requestSettleFrame() {
        if frameSource != nil { requestViewportRender() } else { requestEditRender() }
    }

    /// A slider tick landed. Coalesce for `debounceInterval`; if the loupe is not on screen this
    /// costs nothing at all (no decode, no render, no queue entry).
    public func requestEditRender() {
        guard autoRenderEnabled, let session, session.mode == .loupe else { return }
        guard session.anchorAsset != nil else { return }
        // 派单 031: a detail tick is a *development*, so it stays on the preview rung and re-arms the
        // "hand stopped" upgrade. Both only while the slider is actually held.
        if detailGesturing {
            detailPreview = true
            scheduleDetailSettle()
        }
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

    // MARK: resize (066 / 067)

    /// Counters a resize test reads instead of watching the picture.
    ///
    /// `decodeRequests` is the decode storm's own number: every request that reaches `DecodeQueue`
    /// (a joined one included — the count is of *requests*, so a storm is visible even when the queue
    /// dedupes it). `resizeRequests` is what a live drag must leave at **zero**.
    public private(set) var decodeRequests = 0
    /// Frames the layout asked for (`requestResizeRender`), and how many of those were folded into the
    /// frame already running. A programmatic resize storm is "twelve layout passes, two renders".
    public private(set) var resizeRequests = 0
    public private(set) var resizeCoalesced = 0
    public private(set) var resizeRenderStarts = 0
    /// Queued frames that never rendered: their canvas had moved before the render queue reached them.
    public private(set) var staleCanvasDrops = 0
    /// Frames the presenter refused because they were rendered for another canvas.
    public private(set) var canvasMismatchDrops = 0

    /// Counter-proof switch for `WindowResizeTests`: `true` reproduces the pre-066 behaviour — every
    /// layout pass renders, and a frame for an old canvas is presented anyway. Off in the app and in
    /// every other test; it exists so the acceptance assertions can be shown to go red for the reason
    /// they name (a test that cannot go red is not a test).
    public var disableResizeCoalescing = false
    /// Second half of the same counter-proof: present a frame into the drawable of the *previous*
    /// present, which is how the photograph came out stretched (「变扁」).
    public var forceStaleCanvasPresent = false

    private var resizeInFlight = false
    private var resizePending = false

    /// The canvas a queued frame was made for, readable from the render queue (main writes it, the
    /// queue reads it). A job whose viewport is not this one is already wrong: rendering it spends GPU
    /// time on pixels that cannot be presented.
    private final class CanvasSizeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: ImageSize?
        func store(_ new: ImageSize?) { lock.lock(); value = new; lock.unlock() }
        func current() -> ImageSize? { lock.lock(); defer { lock.unlock() }; return value }
    }
    private let canvasSizeBox = CanvasSizeBox()

    /// The canvas a job should be made for: the frame source's declared viewport in the harness, the
    /// live viewport in the app, and `nil` when there is not enough of a canvas to render into.
    private func jobViewport() -> ImageSize? {
        if let source = frameSource { return source.viewport }
        let viewport = viewportPixels
        guard viewport.width > 8, viewport.height > 8 else { return nil }
        return viewport
    }

    /// The layout changed the canvas outside a live drag (a programmatic resize, a screen change, the
    /// pane appearing): re-render **once** for the canvas that is here, with at most one follow-up.
    ///
    /// A *live* drag does not come here at all — `viewDidLayout` returns before this while
    /// `isLiveResizing`, which is 067's rule: no request is made while the hand is moving. This path
    /// exists for the changes that have no beginning and no end to hang a freeze on, and it must not
    /// be a storm: one frame in flight, one more at the final size, and the follow-up is guaranteed
    /// (unlike a debounce, which is a timer the user can outrun).
    public func requestResizeRender() {
        guard autoRenderEnabled else { return }
        resizeRequests += 1
        if isCanvasGeometryFrozen {
            // Belt and braces: nothing inside a gesture may reach the render queue, however it got
            // here. Counted, because "0" is the number the acceptance test asserts.
            liveResizeRenderRequests += 1
            return
        }
        if disableResizeCoalescing {
            // The 066 counter-proof: the pre-fix shape — every layout pass renders.
            scheduleRender()
            return
        }
        if resizeInFlight {
            resizePending = true
            resizeCoalesced += 1
            return
        }
        startResizeRender()
    }

    private func startResizeRender() {
        guard let viewport = jobViewport(), var job = makeJob(kind: .resize) else {
            // No canvas big enough to render into (a collapsed pane): nothing to do, and nothing left
            // in flight — the next layout will ask again.
            resizeInFlight = false
            return
        }
        // 068: the canvas already holds a frame made for exactly this viewport — a follow-up that was
        // only queued because the layout pass arrived before the previous render landed. Rendering it
        // again would produce the same pixels at the same size: this is what keeps a gesture's release
        // to **one** render instead of one plus the follow-up the coalescer had already armed.
        if let frame = lastFrame, frame.canvas == viewportPixels, !disableResizeCoalescing {
            resizeInFlight = false
            resizePending = false
            return
        }
        canvasSizeBox.store(viewport)
        // A resize is a new intent like any other: a frame or a development still on its way belongs
        // to the canvas that no longer exists.
        generation += 1
        job.generation = generation
        resizeRenderStarts += 1
        resizeInFlight = true
        queue.async { [weak self] in self?.renderFrame(job) }
    }

    private func finishResizeRender() {
        resizeInFlight = false
        guard resizePending else { return }
        resizePending = false
        startResizeRender()
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
        // 派单 031: while a detail slider moves, ask the ladder for the preview rung only.
        let target = detailPreview ? DecodeLadder.previewScale : DecodeLadder.fullScale
        if let source = frameSource {
            // 067/066: the canvas this job is for, published to the render queue so a job overtaken by
            // a resize is dropped instead of rendered.
            canvasSizeBox.store(source.viewport)
            var job = RenderJob(kind: kind, url: source.url, baseIdentity: source.identity,
                                viewport: source.viewport, edit: source.edit, state: source.state,
                                target: target, generation: gen, changedAt: changedAt)
            job.mode = frameMode
            return job
        }
        guard let session, session.mode == .loupe,
              let asset = session.anchorAsset, let url = session.fileURL(for: asset) else { return nil }
        guard let viewport = jobViewport() else { return nil }
        canvasSizeBox.store(viewport)
        // 裁切 mode renders the tool's preview document (whole frame + draft straighten/flips), so
        // the picture under the frame is the picture the frame is measured against. Geometry is not
        // a decode input, so this costs a render and never a development (task 035).
        let edit = cropTool.isActive ? cropTool.previewEdit(from: session.edit) : session.edit
        var job = RenderJob(kind: kind, url: url, baseIdentity: ladderIdentity(asset), viewport: viewport,
                            edit: edit, state: viewState, target: target, generation: gen,
                            changedAt: changedAt)
        // 080: the mode is snapshotted with the camera and the document, so the frame the queue
        // renders is the frame the user asked for even if `\` is pressed again while it is in flight.
        job.mode = frameMode
        return job
    }

    /// One frame, on the render queue. It **never develops**: it renders from the rung the ladder
    /// already has and asks the decode queue for the one the camera wants. That is the difference
    /// between a pan that costs 5 ms while a 60 MP development runs and a pan that costs 800 ms
    /// because the development was dispatched first on the same queue.
    private func renderFrame(_ job: RenderJob) {
        // 066/067: a frame made for a canvas that has since moved cannot be presented — the quads are
        // pixel rectangles of the canvas the frame was rendered for, so an old-canvas texture in a new
        // drawable is the picture **stretched** (the reported 「变扁」). Dropped here, before the GPU work
        // and before the development request, so a drag's backlog costs nothing instead of draining
        // stale frames. 067 does not make this redundant: the live-resize path renders nothing, but a
        // render already queued when the drag started still has to die here.
        if !disableResizeCoalescing, let live = canvasSizeBox.current(), live != job.viewport {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.staleCanvasDrops += 1
                self.releaseFlight(for: job.kind)
            }
            return
        }
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
                case .view, .scheduled, .resize:
                    self.viewRenderCount += 1
                }
            } else if frame != nil {
                self.staleFrameDrops += 1
            } else {
                self.emptyFrameDrops += 1
            }
            self.releaseFlight(for: job.kind)
        }
    }

    /// Release the single-flight flag a frame owns. One function, so a dropped frame (a stale canvas,
    /// an empty rung) cannot leave its kind's flag set and stall every later frame of that kind.
    private func releaseFlight(for kind: RenderJob.Kind) {
        switch kind {
        case .edit: finishEditRender()
        case .view: finishViewRender()
        case .resize: finishResizeRender()
        case .scheduled: break
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
                                      edit: job.edit, state: job.state, mode: job.mode,
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
        // 派单 031: a detail drag produces one identity per thumb position, and every one of them is
        // a new `(identity, scale)` key — so without this the queue would develop every position the
        // thumb passed through. The previous preview rung can never be shown again (its document is
        // gone), so drop it first: at most one preview decode runs, and at most one waits.
        if detailPreview {
            if let previous = pendingDetailPreviewIdentity, previous != job.identity {
                decodeQueue.cancel(identity: previous)
            }
            pendingDetailPreviewIdentity = job.identity
        } else if !plan.isResident {
            pendingDetailPreviewIdentity = nil
        }
        for scale in plan.rungs where ladder.resident(identity: job.identity, scale: scale) == nil {
            // 067: counted where the request is made, not where the queue accepts it — a joined
            // request is still a request, and "twelve resizes, no decode storm" needs the number that
            // a dedupe would hide.
            decodeRequests += 1
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
        // P1b — the document this graph was feeding is going away (leaving the loupe, another module,
        // another photo), so its idle textures are for a canvas no frame will ask for. Trimmed on the
        // render queue because the pool belongs to that queue; a queued frame still runs unchanged.
        reclaimIdleTextures()
        // 037 ②: the low-resolution whole picture belongs to the photo going away. Released here (and
        // not re-rendered) — the next pointer entry on the new photo generates its own. The histogram's
        // snapshot goes with it, so a background measurement can never read the old photo's picture.
        backdrop.invalidate()
        fullPictureBox.store(nil)
        // 派单 031: a pending detail settle belongs to the photo that is going away; firing it at the
        // next one would develop a 60 MP frame nobody asked for.
        detailSettle?.cancel()
        detailSettle = nil
        detailGesturing = false
        detailPreview = false
        pendingDetailPreviewIdentity = nil
        // Nothing that was in flight belongs to the camera that is now on screen: a bridge would
        // carry the old picture over the new one, and a held frame is for a photo nobody is looking at.
        cancelZoomBridge()
        // The pointer's reading is a pixel of the picture that is going away: clear the row rather
        // than let it keep reporting a brightness nobody is looking at.
        pointerExited()
        viewPending = false
        editPending = false
        // A measurement belongs to the picture it was measured for: drop the cache and the dedupe key,
        // so the next frame of the new picture measures instead of matching a stale key.
        histogramLock.lock()
        histogramCache.removeAll()
        histogramCacheOrder.removeAll()
        histogramFrameKey = nil
        // 045: the background whole-picture measurement goes with it. A request nobody will read any
        // more is dropped, an outcome already in flight is refused (its key can no longer be the
        // newest), and the measurement graph — one full-scale buffer — is released with the photo.
        picturePending = nil
        // 065: a re-arm that was waiting for the previous photo's graph is not this photo's entry.
        backdropWanted = false
        pictureLatestKey = nil
        pictureArmedKey = nil
        pictureGraph = nil
        pictureGraphIdentity = nil
        histogramLock.unlock()
        histogramMeasuredKey = nil
        lastFrameState = nil
        if let identity = frameSource.map({ $0.edit.decodeInputs.appending(to: $0.identity) })
            ?? session?.anchorAsset.map({ currentRungIdentity($0) }) {
            decodeQueue.cancel(identity: identity)
        }
    }

    /// P1b — give this graph's **idle** textures back to the device.
    ///
    /// The idle list exists for one reason: the next frame of the same canvas reuses a texture instead
    /// of paying `makeTexture`. When the picture is going away (leaving the loupe, another module,
    /// another photo, the document closed) there is no next frame, so the list is pure footprint — a
    /// 60 Mpx canvas makes each entry 483 MB.
    ///
    /// On the render queue, because the pool is that queue's (`TexturePool` is a plain dictionary; see
    /// the note above `pictureMeasurementGraph`). Trimming only drops idle textures, so a frame that
    /// is already queued renders exactly as it would have.
    ///
    /// `completion` runs on main **after** the trim (a test's handle on "it has happened"; the app
    /// passes nothing).
    public func reclaimIdleTextures(completion: (() -> Void)? = nil) {
        queue.async { [weak self] in
            let bytes = self?.graph?.releaseIdleTextures() ?? 0
            guard let self else { return }
            if bytes > 0 { self.reclaimedIdleTextureBytes += bytes }
            if let completion { DispatchQueue.main.async(execute: completion) }
        }
    }

    /// Bytes `reclaimIdleTextures()` has handed back over this controller's life — the number
    /// `LoupeTextureReclaimTests` reads, so "the pool is empty after the photo went away" is an
    /// assertion and not a claim.
    public private(set) var reclaimedIdleTextureBytes = 0

    /// The photo every piece of the loupe's in-flight work belongs to, as `backdropPhotoKey` spells it
    /// (`contentHash|assetID`, or a frame source's identity in the harness).
    private var renderedPhoto: String?

    /// 065: **the** photo-switch path, whichever way the photo is named — `frameSource` in the tests
    /// and the bench, the session's anchored asset in the app.
    ///
    /// A different photo is not a different document: nothing made for the old picture may reach the
    /// new one, and `cancelPendingFrames` is already the function that says so in one place — it bumps
    /// the generation (a development or a frame in flight can no longer land), releases the
    /// low-resolution backdrop **and the histogram's snapshot of it**, ends any zoom bridge, and throws
    /// away the frame that bridge was holding.
    ///
    /// All three of those were reachable with the old picture still on screen, which is the user's
    /// 「在放大视图切换照片，背景用的低清渲染图还是上一张的」:
    ///
    ///   · a running bridge keeps compositing the old frame texture (and, through it, the old
    ///     backdrop) at whatever scale the eye was looking at, and `finishZoomBridge` presents the
    ///     frame it was holding — the last photo, drawn after the switch;
    ///   · the histogram's whole-picture snapshot is gated on a **digest of the `EditModel`** and the
    ///     digest does not contain the photo, so an untouched document hands the histogram thread the
    ///     previous picture's pixels the moment the photo changes;
    ///   · a frame or development in flight lands because nothing moved the generation.
    private func notePhotoIdentity(_ identity: String?) {
        guard identity != renderedPhoto else { return }
        renderedPhoto = identity
        cancelPendingFrames()
        // 065b: 「低清照片渲染在切换/打开照片的一瞬间就要完成并且换进来」. The ask is armed here, at the
        // instant the photo changes, and **served by the first frame of that photo** — the render queue
        // is serial, so nothing this asks for can be queued in front of the frame the user is waiting
        // for. The old gate (a pointer entry once the document was dirty) survives for edits; it is no
        // longer what decides whether an opened photo has a bottom image at all.
        backdropWanted = true
        let now = CACurrentMediaTime()
        photoSwitchTime = now
        backdropWantedAt = now
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

    // MARK: the low-resolution whole picture (037 ② / 039)

    /// The gate, and the whole of "不影响性能": a backdrop is rendered when the pointer comes into the
    /// canvas **and** the document has moved since the last one. No other function in this file starts
    /// it, so a stop change, a slider drag, a pan and every frame of a zoom transition cost nothing —
    /// and an edit only moves the key (`backdropKey` carries the document digest), which marks the
    /// texture stale without rendering anything.
    private func notePointerEnteredCanvas() {
        guard autoRenderEnabled, presenter != nil else { return }
        guard let key = backdropKey else { return }
        guard backdrop.shouldGenerate(onPointerEnter: key) else { return }
        guard let job = makeJob(kind: .scheduled) else { return }
        requestLowResFullFrame(key: key, edit: job.edit, template: job)
    }

    /// What the cached texture is of: the photo, plus the develop key and the edit digest.
    ///
    /// Three things have to move it, and each is a different kind of change: a different photo (the
    /// picture on screen), a different `DecodeInputs.key` (white balance, detail, decoder version —
    /// the same rules the decode ladder uses), and a different `EditModel` (everything S1–S3 does,
    /// through `Histogram.editDigest`).
    ///
    /// ④ — **the edit is the one the canvas renders**, not the document: while 裁切 mode is on the
    /// picture on screen carries the draft's straighten (`previewEdit`), so the whole-picture frame has
    /// to be rendered from the same edit or the two disagree about the angle. Before this the key came
    /// from `currentEdit` (the document) while the *pixels* came from `makeJob`'s preview edit — so a
    /// 拉直 moved the sharp frame and left the low-resolution one at 0°, and zooming out showed the
    /// picture straighten itself.
    private var backdropKey: BackdropCache.Key? {
        guard let edit = effectiveEdit else { return nil }
        return backdropKey(edit: edit)
    }

    /// The document the **canvas** renders: the crop tool's preview document while the frame is up
    /// (whole frame + draft straighten + the document's flips), the document itself otherwise. One
    /// property so the backdrop, its key and `makeJob` cannot disagree about which edit is on screen.
    private var effectiveEdit: EditModel? {
        guard let edit = currentEdit else { return nil }
        guard backdropUsesEffectiveEdit, cropTool.isActive else { return edit }
        return cropTool.previewEdit(from: edit)
    }

    // MARK: the anti-proof switches (tests only)

    /// With this `false`, a camera change does **not** re-lay-out the crop overlay — the pre-①
    /// behaviour. It exists so the follow tests can show their own assertion going red; nothing in
    /// the app sets it.
    var syncsCropOverlayOnCameraChange = true

    /// With this `false`, the crop overlay is laid out on **frame 0 and at rest only** — the pre-②
    /// behaviour, where an animating stop change left the frame where it was until the target frame
    /// landed. It exists so the follow tests can show their own per-frame assertion going red; nothing
    /// in the app sets it.
    var followsCropOverlayDuringBridge = true

    /// With this `false`, the low-resolution whole picture is keyed on the **document** instead of the
    /// edit on screen — the pre-④ behaviour (a 拉直 that never reached the backdrop). Same reason.
    var backdropUsesEffectiveEdit = true

    private func backdropKey(edit: EditModel) -> BackdropCache.Key? {
        guard let photo = backdropPhotoKey else { return nil }
        return BackdropCache.Key(photo: photo, develop: edit.decodeInputs.key,
                                 digest: Histogram.editDigest(edit))
    }

    /// The photo half of the key: `contentHash|assetID` in the app, a frame source's identity in the
    /// tests and the bench — the same strings the decode ladder keys on.
    private var backdropPhotoKey: String? {
        if let source = frameSource { return source.identity }
        guard let session, let asset = session.anchorAsset else { return nil }
        return ladderIdentity(asset)
    }

    /// The whole document in one string — what the cached low-resolution picture is filed under right
    /// now. Internal: the ④ suite compares it with `editDigest` of the edit the sharp frame renders.
    var backdropKeyIdentity: String? { backdropKey?.identity }

    /// Just the digest half of the key (the document the low-resolution frame is of).
    var backdropDigestForTesting: String? { backdropKey?.digest }

    /// The whole key, for a test that has to file a texture under it.
    var backdropKeyForTesting: BackdropCache.Key? { backdropKey }

    /// The texture a present would draw behind `window` at this instant (④'s stale refusal is
    /// measured through the shipped accessor, not a re-implementation of it).
    func backdropTextureForTesting(for window: PresentWindow) -> MTLTexture? {
        backdropTexture(for: window)
    }

    /// ④ — the low-resolution whole picture is made from the **effective** edit, so when that edit
    /// moves (the draft's 拉直 / 裁切 / 翻转 in 裁切 mode) the cached texture is retired instead of
    /// drawn at the old angle. `backdropWanted` hands the replacement to the next landed frame
    /// (`serveWantedBackdrop`), which is the same path an open/photo switch already uses — one render,
    /// not one per slider tick: `ensureLowResFullFrame` refuses while another generation is running and
    /// the key comparison below is what makes a repeat call a no-op.
    private func noteBackdropKeyMoved() {
        guard presenter != nil else { return }
        guard let key = backdropKey else { return }
        guard let held = backdrop.key, held != key else { return }
        backdrop.invalidate()
        backdropWanted = true
    }

    /// The document on screen as this class sees it (a frame source names its own document).
    private var currentEdit: EditModel? {
        if let source = frameSource { return source.edit }
        return session?.edit
    }

    /// Start the one render. Shared by the pointer-entry gate and the explicit request below, so the
    /// two cannot disagree about the key or about what a generation is.
    private func requestLowResFullFrame(key: BackdropCache.Key, edit: EditModel,
                                        template: RenderJob) {
        let job = RenderJob(kind: template.kind, url: template.url,
                            baseIdentity: template.baseIdentity, viewport: template.viewport,
                            edit: edit, state: template.state, target: template.target,
                            generation: template.generation, changedAt: template.changedAt)
        let serial = backdrop.begin(key)
        queue.async { [weak self] in self?.renderBackdrop(key: key, serial: serial, job: job) }
    }

    // MARK: the read-only accessor (for the histogram's whole-picture source)

    /// The whole picture at low resolution, with the document it was rendered from.
    ///
    /// **Read-only and side-effect free**: it never starts a render. The consumer (the histogram's
    /// whole-picture measurement, 040) may look at this once per frame, and a getter that could queue a
    /// render is a render loop with extra steps. Call `ensureLowResFullFrame(edit:)` when a *specific*
    /// document is needed and a pointer entry is not going to happen.
    ///
    /// The pixels are a frame-like `rgba16Float` texture in the same display space frames are made in
    /// (linear P3 or sRGB, current headroom), so `RenderGraph.measureFrameHistogram(fromFrame:…)` reads
    /// it the way it reads a frame; `content` is the picture's rect inside it (the whole texture).
    /// The histogram's background measurement runs on `pictureQueue`, **not** on the main actor
    /// (`main.sync` there would deadlock a slider drag), so it cannot read `lowResFullFrame` — that is
    /// main-actor state. This box is the snapshot it reads instead: one texture reference, replaced
    /// whenever the backdrop is published or released, guarded by a lock.
    ///
    /// 039 × 045: **one** low-res whole picture serves two purposes — the letterbox backdrop while
    /// shrinking, and the whole-picture source for the histogram of a zoomed-in frame. Without this the
    /// histogram would render the picture a second time (11–24 ms) on every edit.
    private final class FullPictureBox: @unchecked Sendable {
        private let lock = NSLock()
        private var frame: LowResFullFrame?
        func store(_ new: LowResFullFrame?) { lock.lock(); frame = new; lock.unlock() }
        func current() -> LowResFullFrame? { lock.lock(); defer { lock.unlock() }; return frame }
    }
    private let fullPictureBox = FullPictureBox()

    public struct LowResFullFrame {
        public let texture: MTLTexture
        /// The picture's rect inside `texture` — the whole texture for this render.
        public let content: ImageRect
        /// `Histogram.editDigest(edit)` of the document this texture was rendered from.
        public let digest: String
        /// `DecodeInputs.key` of the same document (white balance / detail / decoder version).
        public let develop: String
        /// The photo half of the key (`contentHash|assetID` or a frame source's identity).
        public let photo: String
        /// 070: the scene-linear measurement that came out of the same render (`nil` when it did not
        /// measure one — the consumer then renders its own picture).
        public let histogram: Histogram?
    }

    /// `nil` until a backdrop has been generated for the document on screen — and immediately after a
    /// photo switch (`cancelPendingFrames` releases it).
    public var lowResFullFrame: LowResFullFrame? {
        guard let texture = backdrop.texture, let key = backdrop.key,
              let content = backdrop.content else { return nil }
        return LowResFullFrame(texture: texture, content: content, digest: key.digest,
                               develop: key.develop, photo: key.photo,
                               histogram: backdrop.histogram)
    }

    /// An **explicit** request for the whole picture at low resolution, for a caller that cannot wait
    /// for a pointer entry (the histogram of a zoomed-in frame).
    ///
    /// It is the same gate as the pointer entry — one render, only when the requested document is not
    /// the one already cached, and refused while another generation is in flight — and it says so. It
    /// is **not** wired to any frame, camera or edit path: nothing in this file calls it, and calling it
    /// from a per-frame hook would be exactly the render loop the design forbids. Returns `true` when a
    /// render was started (the result arrives through `lowResFullFrame`).
    @discardableResult
    public func ensureLowResFullFrame(edit: EditModel? = nil) -> Bool {
        guard autoRenderEnabled, presenter != nil else { return false }
        guard let edit = edit ?? currentEdit, let key = backdropKey(edit: edit) else { return false }
        guard backdrop.needsGeneration(for: key), backdrop.isIdle else { return false }
        guard let job = makeJob(kind: .scheduled) else { return false }
        requestLowResFullFrame(key: key, edit: edit, template: job)
        return true
    }

    /// 065: the diagnostics the photo switch is asserted from.
    ///
    /// `lastBackdropRenderedPhoto` is the photo whose pixels the last **adopted** generation actually
    /// rendered — the frame graph's own photo, which is not the key's when a request outlived its
    /// picture. It equals `backdrop.key?.photo` exactly when the flow is honest.
    public private(set) var lastBackdropRenderedPhoto: String?
    /// Generations refused because the frame graph still belonged to the previous photo (065, H2).
    public private(set) var backdropStaleGraphRefusals = 0
    /// A bottom image is wanted for the photo on screen and has not been made yet: armed by an
    /// open/photo switch (065b) or by a refusal, served by the first frame that lands.
    private var backdropWanted = false
    /// 065b / 065, the two timings the "generate at the open, never instead of the first frame" rule is
    /// accountable for: 切换/打开 → 首帧 on screen, and → 低清全图 available. Milliseconds, measured from
    /// the instant the photo identity changed.
    public private(set) var lastPhotoSwitchFirstFrameMilliseconds: Double = 0
    public private(set) var lastPhotoSwitchBackdropMilliseconds: Double = 0
    private var photoSwitchTime: CFTimeInterval?
    private var backdropWantedAt: CFTimeInterval?

    /// 065b: serve the request an open or a switch armed, **after** the frame that brings the graph for
    /// that photo. Called from `present` — a landed frame is exactly the moment the render queue is free
    /// and the graph is the current photo's, so the generation is enqueued behind the picture and in
    /// front of nothing.
    ///
    /// It is not a render loop: the flag is set by an open/switch or by one refusal, and cleared as soon
    /// as a request is started. A stop change, a pan and an edit still generate nothing (039's rule).
    private func serveWantedBackdrop() {
        guard backdropWanted else { return }
        guard let key = backdropKey else { return }
        guard backdrop.needsGeneration(for: key) else {
            backdropWanted = false
            return
        }
        guard ensureLowResFullFrame() else { return }
        backdropWanted = false
    }

    /// Render the whole picture at `BackdropScale` on the render queue and hand it to main.
    ///
    /// `useCache: false` on purpose. This is a one-off at a scale no frame uses, and the stage cache is
    /// keyed by canvas: storing it would evict the entries the viewport's *next* frame wants (the same
    /// reason `RenderGraph.measureHistogram` asks for a cold render). The pixels are the same either
    /// way — the cache is a cost knob, never a quality knob.
    private func renderBackdrop(key: BackdropCache.Key, serial: Int, job: RenderJob) {
        // 065: 「可取消」. A switch has already bumped the serial, so this generation is nobody's: do not
        // render it, and do not leave it queued in front of the new photo's bottom image.
        guard backdrop.isCurrent(serial) else { return }
        guard let graph else {
            DispatchQueue.main.async { [weak self] in
                self?.backdrop.fail(key, error: "no frame yet (nothing decoded)")
            }
            return
        }
        // 065 (H2): the graph is the **frame** path's, and it only moves to the new photo when a frame
        // of it is rendered. A request that outlived its photo would otherwise render the previous
        // picture through the new document's edit and be adopted under the new key — a backdrop that
        // says B and is A's pixels, i.e. exactly 「背景还是上一张」 with a key that looks right.
        // Refusing is the honest answer: no backdrop is 025's edge extrapolation, the old picture is
        // not shown. The request is re-armed once this photo's own graph exists (see
        // `retryBackdropAfterPhotoSwitch`), so the flow does finish without a second pointer entry.
        let photo = graphPhoto ?? ""
        guard photo == key.photo else {
            let reason = "the frame graph is still \(photo.isEmpty ? "unset" : photo)"
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.backdrop.fail(key, error: "\(reason), not \(key.photo)")
                self.backdropStaleGraphRefusals += 1
                self.backdropWanted = true
            }
            return
        }
        let source = graph.sourceSize
        let cropPixels = job.edit.geometry.outputPixels(in: source)
        // Two pixel grids are in play, and confusing them is a half-resolution bug: the graph renders
        // from the **decoded rung** (`graph.sourceSize` is that buffer's size), while the rule is
        // written against the **original** (`min(imageLongEdge / 2, 4096)`). The rung's scale is what
        // converts between them, so the ceiling is computed on the original and divided by the rung's
        // own crop — without this, a 0.5 rung of a 9520 px file asks for 2380 px (half of the preview
        // the user asked for) instead of 4096.
        let rungScale = decodedScale.isFinite && decodedScale > 0 ? decodedScale : 1
        let originalLongEdge = Int((Double(max(source.width, source.height)) / rungScale).rounded())
        let scale = BackdropScale.renderScale(imageLongEdge: originalLongEdge,
                                              contentLongEdge: max(cropPixels.width, cropPixels.height))
        // The same display space the frame textures are made in (`makeFrame` reads these two the same
        // way, on this queue): the pass samples the backdrop with the same linearise as the frame, so
        // a mismatch here would show as a colour step at the feather band.
        let primaries: OutputPrimaries = (presenter?.storage ?? .linear16) == .linear16 ? .displayP3 : .sRGB
        let headroom = displayHeadroom.headroom
        let t0 = CFAbsoluteTimeGetCurrent()
        do {
            let result = try graph.render(job.edit, options: RenderOptions(
                scale: scale,
                display: DisplayOptions(primaries: primaries, bitDepth: 16, headroom: headroom),
                useCache: false, wantsPixels: false,
                // 070: the backdrop render is the whole picture, so it also produces the histogram
                // the loupe needs when a **windowed** frame cannot measure one itself. The measurement
                // is taken on this render's scene-linear texture — never on S4's clamped output — and
                // costs one 256-grid stride pass plus a 0.29 MB readback, once per backdrop.
                collectHistogram: true,
                histogramSampleLongEdge: Histogram.frameSampleLongEdge))
            let milliseconds = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            guard let texture = result.output else {
                throw RenderError.executeFailed("the backdrop render produced no texture")
            }
            let measured = result.histogram
            // No canvas was asked for, so the picture is the whole texture — but say it with the size
            // the render reported rather than with `texture.width`, so a letterbox can never be
            // silently described as picture.
            let content = ImageRect(x: 0, y: 0, width: result.content.width, height: result.content.height)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let adopted = self.backdrop.finish(texture, key: key, content: content,
                                                   histogram: measured,
                                                   milliseconds: milliseconds, serial: serial)
                if adopted { self.lastBackdropRenderedPhoto = photo }
                if adopted, let at = self.backdropWantedAt {
                    self.backdropWantedAt = nil
                    self.lastPhotoSwitchBackdropMilliseconds = (CACurrentMediaTime() - at) * 1000
                }
                if !adopted {
                    // The photo moved on while this rendered: the texture is nobody's, so it goes back
                    // to the pool it came from instead of being drawn over the new picture.
                    self.queue.async { graph.recycle(output: texture) }
                }
                // Hand the histogram thread the picture it may measure (nil when this render lost).
                self.fullPictureBox.store(adopted ? self.lowResFullFrame : nil)
            }
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.backdrop.fail(key, error: "\(error)")
            }
        }
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
        // 065b: opening the loupe on a photo is an open like any other, and it may become known without
        // a model change (a window created with the photo already anchored). Cheap and idempotent: it
        // returns immediately unless the photo actually moved.
        notePhotoIdentity(backdropPhotoKey)
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

    /// 派单 031: the four decoder-side detail values of the buffer on screen, so the 细节 card can print
    /// what its 0 position means for this body. `nil` before the first development lands.
    public var currentDetailBaseline: DetailBaseline? { ladder.best?.detailBaseline }

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
                                                                              whiteBalance: inputs.whiteBalance,
                                                                              detail: inputs.detail))
        return DecodeRung(scale: scale, image: developed.image,
                          capabilities: developed.capabilities,
                          milliseconds: (CFAbsoluteTimeGetCurrent() - t0) * 1000,
                          detailBaseline: developed.detailBaseline)
    }

    /// The whole GPU path for one frame, callable synchronously (ui-smoke uses this).
    ///
    /// `edit` defaults to the live document; passing it explicitly is what makes an edit frame
    /// deterministic (the caller snapshotted the document on the main thread — the render queue
    /// must never read `session.edit` itself and race a slider).
    public func makeFrame(asset: Asset, url: URL, viewport: ImageSize, decodeScale: Float,
                          edit: EditModel? = nil, state: LoupeViewState? = nil,
                          mode: LoupeFrameMode = .edited,
                          hashPixels: Bool = false) throws -> FrameResult {
        try makeFrame(url: url,
                      cacheIdentity: "\(asset.contentHash)|\(asset.id)",
                      viewport: viewport, decodeScale: decodeScale,
                      edit: edit ?? session?.edit ?? .neutral,
                      state: state ?? viewState, mode: mode,
                      hashPixels: hashPixels)
    }

    /// Same frame, without a catalog row — what the unit tests and a future import preview use.
    /// `cacheIdentity` only has to be stable per file; anything that changes pixels is in the key
    /// chain already.
    public func makeFrame(url: URL, viewport: ImageSize, decodeScale: Float, edit: EditModel,
                          state: LoupeViewState = .fit, mode: LoupeFrameMode = .edited,
                          hashPixels: Bool = false) throws -> FrameResult {
        try makeFrame(url: url, cacheIdentity: url.lastPathComponent,
                      viewport: viewport, decodeScale: decodeScale, edit: edit,
                      state: state, mode: mode, hashPixels: hashPixels)
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
                           mode: LoupeFrameMode = .edited,
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
            // P1b: a different rung of this picture (or another picture) means the graph's idle
            // textures are for a canvas nobody will ask for again. Hand them back *before* the new
            // source is built, not at the same moment as its 483 MB source texture.
            graph?.releaseIdleTextures()
            graph = nil                      // a new source needs a new graph
            graphIdentity = nil
            graphPhoto = nil
        }
        decoded = image
        decodedScale = ds
        decodedCaps = outcome.rung.capabilities
        currentDecodeScale = decodeScale

        let identity = "\(cacheIdentity)-s\(decodeScale)"
        if graph == nil || graphIdentity != identity {
            graph = try RenderGraph(input: RenderInput(image: image, identity: identity, sourceURL: url))
            graphIdentity = identity
            graphPhoto = baseIdentity
            // A new photo (or a new rung of it): its key is a different picture, so the measurement
            // armed below is a fresh one — the card must not keep the previous picture's numbers.
            lastFrameState = nil
        }
        guard let graph else { throw RenderError.allocationFailed("loupe graph") }

        // The camera. 080: 「显示原图」 shows the **whole decode**, so its framing is the whole decode's
        // — the crop is a property of the document, and a frame of the decode that framed itself with
        // the crop would be the right pixels of the wrong picture (it would take the crop's rectangle
        // out of a whole frame, or letterbox a whole frame into a crop's aspect).
        struct Shot {
            let projected: LoupeFraming
            let window: ImageRect?
            let scale: Double
            let pixels: ImageSize
        }
        func shot(_ cameraEdit: EditModel) -> Shot {
            // 1:1 (or beyond) is an **output window** into the frame: S0 cropped/straightened/flipped
            // the whole frame and hands back that rectangle, so the projection, the vignette and the
            // mask feather are the frame's, not the window's. `fit` names no window.
            let projected = LoupeFraming(viewport: viewport,
                                         decoded: ImageSize(width: image.width, height: image.height),
                                         decodeScale: ds,
                                         edit: cameraEdit)
            return Shot(projected: projected,
                        window: projected.outputWindow(of: state),
                        scale: max(0.01, projected.renderScale(of: state, decodeScale: ds)),
                        pixels: projected.windowPixels(of: state))
        }
        let editedShot = shot(model)
        let originalShot = shot(model.disregardingGeometry)
        let primaries: OutputPrimaries = (presenter?.storage ?? .linear16) == .linear16 ? .displayP3 : .sRGB
        let ceiling = displayHeadroom.headroom
        // The histogram's trigger (005, 034): keyed by the picture, not by the camera. 080: a `\` frame
        // measures nothing — the plot is of the **document's** picture, and republishing the decode's
        // numbers over it would be the card lying about what the sliders are doing.
        let coverage = pictureCoverage(editedShot.projected, state: state)
        let wantsPointerSample = pointerReadoutWanted
        let measureHistogram = mode != .original
            && wantsHistogramMeasurement(edit: model, identity: cacheIdentity,
                                         fallbackScale: decodeScale, coverage: coverage)

        // One render over the resident rung. `useCache: true` in both sources: the edited pipeline's
        // keys are the document's, so a compare frame hits S1…S3 exactly where the plain frame did and
        // leaving 对比 asks for nothing new.
        func renderOne(_ source: RenderSource, _ s: Shot, _ editForRender: EditModel,
                       measure: Bool) throws -> (result: RenderResult, ms: Double) {
            let t = CFAbsoluteTimeGetCurrent()
            let r = try graph.render(editForRender, options: RenderOptions(
                canvas: viewport,
                scale: s.scale,
                outputWindow: s.window,
                display: DisplayOptions(primaries: primaries, bitDepth: 8, headroom: ceiling),
                useCache: true,
                wantsPixels: false,
                collectHistogram: measure,
                histogramSampleLongEdge: (measure || wantsPointerSample)
                    ? Histogram.frameSampleLongEdge : 0,
                source: source))
            return (r, (CFAbsoluteTimeGetCurrent() - t) * 1000)
        }

        let t1 = CFAbsoluteTimeGetCurrent()
        // The document's frame is rendered in every mode but `\`: 对比 needs it on one side of the
        // line, and 原图 does not — which is why `\` costs one pass and 对比 costs two plus the
        // composite.
        var editedShotResult: (result: RenderResult, ms: Double)?
        if mode != .original {
            editedShotResult = try renderOne(.edited, editedShot, model, measure: measureHistogram)
        }

        let texture: MTLTexture
        let drawing: RenderResult
        let renderMs: Double
        var photoRect: ImageRect
        switch mode {
        case .edited:
            guard let e = editedShotResult, let out = e.result.output else {
                throw RenderError.executeFailed("loupe produced no texture")
            }
            drawing = e.result
            texture = out
            renderMs = e.ms
            photoRect = e.result.drawnRect
        case .original:
            let o = try renderOne(.decoded, originalShot, model.disregardingGeometry, measure: false)
            guard let out = o.result.output else {
                throw RenderError.executeFailed("loupe produced no texture")
            }
            drawing = o.result
            texture = out
            renderMs = o.ms
            photoRect = o.result.drawnRect
            originalFrames += 1
        case .compare(let split):
            guard let e = editedShotResult, let editedTexture = e.result.output else {
                throw RenderError.executeFailed("loupe produced no texture")
            }
            let o = try renderOne(.decoded, originalShot, model.disregardingGeometry, measure: false)
            guard let originalTexture = o.result.output else {
                graph.recycle(output: editedTexture)
                throw RenderError.executeFailed("loupe produced no decode texture")
            }
            // The two frames are recycled the moment the composite has read them: the composite is
            // what the canvas presents, and it came from the same pool.
            let composed: MTLTexture
            do {
                composed = try graph.composite(original: originalTexture, edited: editedTexture,
                                               split: split)
            } catch {
                graph.recycle(output: originalTexture)
                graph.recycle(output: editedTexture)
                throw error
            }
            graph.recycle(output: originalTexture)
            graph.recycle(output: editedTexture)
            drawing = e.result
            texture = composed
            renderMs = e.ms + o.ms
            // The matte is painted only outside **both** pictures: a comparison of a cropped document
            // with the whole frame is two differently-placed photographs inside one canvas, and the
            // union is the only rect that is outside neither.
            photoRect = Self.union(e.result.drawnRect, o.result.drawnRect, in: e.result.canvas)
            compareFrames += 1
        }

        // The histogram, out of the edited render: `result.histogram` is measured on the **scene-linear**
        // texture S4 read (not on S4's clamped output, which stops at the panel's headroom — 070), so
        // a picture with three stops of highlight above white plots three stops above white.
        if let e = editedShotResult {
            deliver(histogramStep(for: model, measured: e.result.histogram,
                                  milliseconds: e.result.histogramMilliseconds,
                                  identity: cacheIdentity,
                                  coverage: coverage, primaries: primaries, ceiling: ceiling,
                                  fallbackScale: decodeScale, sourceURL: url,
                                  startedAt: t1))
        }
        let hash = hashPixels ? LoupeController.hash(texture) : nil
        // The clipping warning's input. Only read while the warning is on: it is a UI aid, and a
        // readback nobody looks at is a millisecond nobody asked for.
        let clipped = (session?.highlightWarning ?? false)
            ? HighlightWarning.grid(of: texture) : nil
        // The pointer's readout rides a stride sample of the picture **before S4**, and the lattice it
        // is indexed with is the frame's picture rect. A compare frame's rect is the union of two
        // pictures (the presenter's matte rule), so that lattice would describe a rectangle the grid
        // was not sampled over — the readout falls back to the presented bytes instead, which for a
        // composite is the only honest answer.
        let pointerSample: LinearSample? = {
            if case .compare = mode { return nil }
            return drawing.histogramSample
        }()
        let shotForFrame = mode == .original ? originalShot : editedShot
        return FrameResult(texture: texture, canvas: drawing.canvas, content: drawing.content,
                           photoRect: photoRect,
                           decodeScale: decodeScale, decodeMilliseconds: decodeMilliseconds,
                           renderMilliseconds: renderMs, usedCachedDecode: usedCache,
                           capabilities: decodedCaps, primaries: primaries,
                           editRevision: session?.editRevision ?? 0, displayHash: hash,
                           zoom: shotForFrame.projected.zoom(of: state), headroom: ceiling,
                           window: shotForFrame.pixels,
                           clipped: clipped,
                           sceneLinearSample: pointerSample,
                           mode: mode)
    }

    /// The bounding box of two rects, clipped to the canvas — the matte rule for a compare frame.
    static func union(_ a: ImageRect, _ b: ImageRect, in canvas: ImageSize) -> ImageRect {
        let x0 = min(a.x, b.x), y0 = min(a.y, b.y)
        let x1 = max(a.maxX, b.maxX), y1 = max(a.maxY, b.maxY)
        return ImageRect(x: x0, y: y0, width: max(0, x1 - x0), height: max(0, y1 - y0))
            .intersected(in: canvas)
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

    // MARK: - the backdrop on the canvas (037 ② / 039)

    /// One present of the canvas as the backdrop saw it.
    ///
    /// The on-screen drawable cannot be read back (`framebufferOnly`), so the *parameters* of the pass
    /// are the only observable evidence that the wiring is right — and they are recorded for every
    /// present, not only while a bridge runs, because both rules of `039` have to be pinned:
    /// a shrinking frame is drawn **with** the low-resolution picture and a frame that covers the
    /// canvas is drawn **without** it (the engine feathers 2 px of low resolution into the frame's own
    /// edge otherwise).
    public struct BackdropPresent: Equatable, Sendable {
        /// The bridge that drew it (`zoomBridgeArmedCount`), or 0 for a settled frame or a teardown.
        public let serial: Int
        public let window: PresentWindow
        /// The window the **low-resolution picture** was read through.
        ///
        /// Since 058 this is the frame's window **composed with where the frame texture sits on the
        /// whole picture** (`FramePlacement` / `PresentWindow.onWholePicture`), so it is a window in the
        /// picture's coordinates. 053 used to pass `window` itself here, which is only the same number
        /// when the texture *is* the picture — at 300 % it is a ninth of it, and reading the frame's
        /// window as picture coordinates put the backdrop's UVs far outside `[0, 1]` and turned the
        /// band into one column of the picture's edge. `windowsMatch` is the relationship, the pair of
        /// fields is the evidence.
        public let backdropWindow: PresentWindow
        /// The backdrop's pixel size — `nil` when the pass was given none.
        public let backdrop: ImageSize?
        /// 065: **which texture** the pass was given, not how big it was.
        ///
        /// The size cannot tell two photos apart: an untouched document's preview is the same
        /// `min(longEdge / 2, 4096)` for every file, so 「A 的纹理 and B's」 compare equal by size — and
        /// the bug this pins is a present carrying the **previous** photo's texture. Identity is the
        /// only question that catches it, so every present records it.
        public let backdropIdentity: ObjectIdentifier?
        /// Whether the window already reached every canvas pixel.
        public let coversCanvas: Bool
        /// Where the frame texture sat on the whole picture (058) — what `backdropWindow` was computed
        /// from, recorded so the conversion can be checked field by field rather than trusted.
        public let placement: FramePlacement

        /// Are the two textures read through one mapping? 053's claim, in the form that survives the
        /// coordinate change: the backdrop's window is the frame's window *read on the picture*.
        public var windowsMatch: Bool { window.onWholePicture(placement) == backdropWindow }

        /// Are the two windows literally the same numbers? True exactly when the frame texture holds
        /// the whole picture (适应 with no letterbox, a texture rendered without a canvas) — 053's
        /// literal rule, kept as the special case it always was.
        public var windowsAreIdentical: Bool { window == backdropWindow }

        /// 067: where the photograph was drawn on the canvas, in canvas pixels — the quad the pass was
        /// handed, derived from `window` and the frame's own picture rect. It is the number that makes
        /// a present correct or not, so it is recorded rather than inferred from the window.
        public let pictureQuad: ImageRect
    }

    /// Every present, in order (capped; it is a log).
    public private(set) var backdropPresents: [BackdropPresent] = []
    /// The last present, with both windows it was given — read-only, for a caller (or a test) that
    /// wants the current mapping without copying the log (053).
    public var lastBackdropPresent: BackdropPresent? { backdropPresents.last }
    /// Presents that carried a backdrop, and presents that did not.
    public private(set) var backdropDrawCount = 0
    public private(set) var backdroplessDrawCount = 0
    private static let backdropPresentLimit = 512

    /// The texture to draw behind `window`: the whole picture when the frame does **not** reach the
    /// canvas, and `nil` whenever it does.
    ///
    /// Deliberately geometric — it asks nothing about bridges, gestures or zoom state. A covering frame
    /// therefore can never pick up the low-resolution edge, and a shrinking frame drawn for any reason
    /// (a transition, a teardown) gets the same honest background. `nil` while no backdrop has been
    /// generated: the pass then falls back to 025's edge extrapolation, which is what keeps 「没有未渲染
    /// 的黑」 true even before the first pointer entry.
    private func backdropTexture(for window: PresentWindow) -> MTLTexture? {
        guard !window.coversCanvas else { return nil }
        // A backdrop belongs to one photo. Between a switch and the next pointer entry the cached
        // texture is still the **previous** picture's, and drawing it behind a shrinking frame would
        // show the old photograph's edge around the new one — a worse artefact than 025's extrapolation.
        // The key carries the photo (`contentHash|assetID`), so the check is the same one that makes the
        // next entry regenerate.
        //
        // ④ — and it carries the **edit** too. A texture whose key is not the document on screen (a
        // 拉直 in the crop draft, an edit applied while a low-resolution frame was cached) is refused
        // here rather than drawn: a backdrop at another angle is the 「缩放时画面会变」, and no backdrop
        // at all — 025's edge extrapolation — is the honest picture until the replacement lands.
        guard let key = backdrop.key, key == backdropKey else { return nil }
        return backdrop.texture
    }

    private func recordBackdropPresent(window: PresentWindow, backdropWindow: PresentWindow,
                                       drawn: MTLTexture?, placement: FramePlacement,
                                       pictureQuad: ImageRect, serial: Int) {
        let size = drawn.map { ImageSize(width: $0.width, height: $0.height) }
        if size == nil { backdroplessDrawCount += 1 } else { backdropDrawCount += 1 }
        backdropPresents.append(BackdropPresent(serial: serial, window: window,
                                                backdropWindow: backdropWindow, backdrop: size,
                                                backdropIdentity: drawn.map(ObjectIdentifier.init),
                                                coversCanvas: window.coversCanvas,
                                                placement: placement, pictureQuad: pictureQuad))
        if backdropPresents.count > Self.backdropPresentLimit {
            backdropPresents.removeFirst(backdropPresents.count - Self.backdropPresentLimit)
        }
    }

    /// 058: where the pixels **on the canvas** sit on the whole picture.
    ///
    /// The backdrop is the whole picture; the frame texture is a canvas-sized render of one part of it
    /// with the photograph letterboxed inside. Composing the frame's window with this is what makes
    /// `backdropUV` a picture coordinate — `.whole` (identity) only while no frame has been presented,
    /// which is also the only case where 053's rule would have been right.
    private var canvasPlacement: FramePlacement {
        canvasContent?.placement ?? .whole
    }

    // MARK: - the one present path (067)

    /// One settled present, as a resize test reads it: the drawable the quads were computed for, and
    /// the canvas the frame texture was **rendered** for. `drawable == frameCanvas` is the invariant
    /// that 066's 「变扁」 violates (a frame for a 1200×800 canvas drawn into a 1600×500 one is the
    /// photograph at another aspect); the only presents where the two differ on purpose are the ones
    /// a live resize makes, and those keep the picture's pixel geometry (`pictureQuad` unchanged)
    /// instead of re-deriving it.
    public struct PresentRecord: Equatable, Sendable {
        public let drawable: ImageSize
        public let frameCanvas: ImageSize
        public let pictureQuad: ImageRect
        public let backdropQuad: ImageRect?
        public let zoom: Double
        /// 067: this present drew the frame that was already on the canvas at its own geometry,
        /// because a window drag is in progress. No render was asked for.
        public let frozen: Bool
    }
    /// Every present, in order (capped; it is a log).
    public private(set) var presentRecords: [PresentRecord] = []
    private static let presentRecordLimit = 256
    /// The last present: what the layer was handed, and what the frame inside it was made for.
    public var lastPresented: PresentRecord? { presentRecords.last }
    /// Where the photograph sits on the canvas, in drawable pixels, as the layer was last given it.
    public var presentedPictureQuad: ImageRect? { lastPresented?.pictureQuad }

    private func recordPresent(_ record: PresentRecord) {
        presentRecords.append(record)
        if presentRecords.count > Self.presentRecordLimit {
            presentRecords.removeFirst(presentRecords.count - Self.presentRecordLimit)
        }
    }

    /// **The only call into `CanvasPresenter`.** Every path — settled frame, bridge frame, the stop the
    /// bridge lands on, the teardown after a resize, and the frozen frame a live resize re-draws — comes
    /// through here, which is what makes "somebody forgot to hand the geometry over" a compile error
    /// rather than a black band: there is no overload without a picture rect and a window.
    ///
    /// The quad is not passed: `PresentRequest` inverts the window onto the photograph's own rect, so
    /// the geometry follows the map. A bridge frame's picture therefore moves with the bridge, which is
    /// exactly the bug the user reported (「放大时边缘 0f 的遮罩会固定住，渲染完了突然消失」— the old matte
    /// sat at the held frame's unscaled rect while the picture moved).
    @discardableResult
    private func presentCanvas(_ presenter: CanvasPresenter, texture: MTLTexture,
                               photoRect: ImageRect, frameCanvas: ImageSize,
                               window: PresentWindow, placement: FramePlacement,
                               backdrop: MTLTexture?, backdropWindow: PresentWindow,
                               canvas: ImageSize, serial: Int, zoom: Double, frozen: Bool = false,
                               completion: (() -> Void)? = nil) -> Bool {
        let request = PresentRequest(picture: texture, photoRect: photoRect, window: window,
                                     canvas: canvas, backdrop: backdrop,
                                     backdropWindow: backdropWindow)
        let ok = presenter.present(request, in: canvasView.metalLayer,
                                   wantsEDR: wantsExtendedDynamicRange,
                                   drawableSize: canvas, onComplete: completion)
        guard ok else { return false }
        recordBackdropPresent(window: window, backdropWindow: backdropWindow, drawn: backdrop,
                              placement: placement, pictureQuad: request.pictureQuad, serial: serial)
        recordPresent(PresentRecord(drawable: canvas, frameCanvas: frameCanvas,
                                    pictureQuad: request.pictureQuad,
                                    backdropQuad: request.backdropQuad, zoom: zoom,
                                    frozen: frozen))
        // 068: the canvas the layer is now showing something for. A frozen draw is skipped when this is
        // already the canvas on screen — a gesture that stopped moving must stop drawing.
        lastPresentCanvas = canvas
        frozenFrame = FrozenFrame(texture: texture, photoRect: photoRect,
                                  frameCanvas: frameCanvas, canvas: canvas, window: window,
                                  backdropWindow: backdropWindow, placement: placement, zoom: zoom)
        // 2026-10-27: a frame that reached the layer is a free chance to re-read the screen's EDR budget
        // (the brightness slider moves it and posts no notification). One property read that ends in
        // "nothing changed" nine times out of ten — the histogram card's ceiling is the consumer.
        onFramePresented?()
        return true
    }

    /// The canvas of the last present that reached the layer.
    private var lastPresentCanvas: ImageSize?

    /// The frame on the canvas, with the geometry it was drawn with: what a live resize re-draws.
    ///
    /// It is deliberately **not** a `PresentRequest`: the request's quads belong to one canvas, and the
    /// whole point of freezing is that the canvas may change under it. Holding the *window* instead
    /// means `PresentWindow.stretched(to:from:)` can say "the same picture, on a different surface",
    /// and the quads come out of the same derivation as everything else.
    private struct FrozenFrame {
        let texture: MTLTexture
        let photoRect: ImageRect
        let frameCanvas: ImageSize
        let canvas: ImageSize
        let window: PresentWindow
        let backdropWindow: PresentWindow
        let placement: FramePlacement
        let zoom: Double
    }
    private var frozenFrame: FrozenFrame?

    // MARK: - geometry gestures (068)

    /// A gesture that moves the canvas. Two entry points the user names — dragging the window's edge
    /// and dragging the inspector's divider — plus the browser's divider, which is the same event
    /// stream one pane over.
    ///
    /// They are *one* type and *one* freeze, not two implementations: a divider drag does not start a
    /// window live resize (AppKit has no idea a plain `mouseDown` loop is resizing anything), so the
    /// workspace tells the canvas, and from there the rule is identical — no render while the hand is
    /// moving, one per runloop tick to follow it, one render at the size it stops on.
    public enum CanvasGeometryGesture: Hashable, Sendable {
        /// A window edge, held. Also implied by `NSWindow.inLiveResize`, so this one is a convenience.
        case windowLiveResize
        /// The inspector's (or the browser's) divider, held.
        case panelDivider
    }

    private var activeGeometryGestures: Set<CanvasGeometryGesture> = []
    /// How many gestures are held right now (a window edge and a divider at once is a real state).
    public var activeGeometryGestureCount: Int { activeGeometryGestures.count }
    /// Layout passes that fell inside a gesture (they drew a frozen frame and asked for no render).
    public private(set) var liveResizeLayouts = 0
    /// Render requests a gesture made while the hand was moving — the number a regression shows up in,
    /// and the one the acceptance test asserts is 0.
    public private(set) var liveResizeRenderRequests = 0
    /// Frozen draws the layer was actually handed, and the ones folded into a draw already queued for
    /// this runloop tick. "Forty layout passes, twenty draws" is these two numbers.
    public private(set) var frozenDrawCount = 0
    public private(set) var coalescedDrawCount = 0
    /// Frames that arrived while the hand was moving and were **not** drawn (068). A resize is not a new
    /// picture: the canvas is moving, so any frame landing now would re-fit the photograph under the hand
    /// into a size the next layout pass replaces. The release renders the exact final size instead.
    public private(set) var framesHeldDuringGesture = 0

    /// Is a gesture moving the canvas right now?
    ///
    /// `NSWindow.inLiveResize` is asked directly rather than trusted from the view messages: it is the
    /// documented source of truth (NSView.h: "inLiveResize can be called at any time to determine if
    /// the window is performing a live resize"), it costs nothing, and it makes the freeze independent
    /// of whether AppKit delivered `viewWillStartLiveResize` to a view this far down the hierarchy.
    public var isCanvasGeometryFrozen: Bool {
        if disableResizeCoalescing { return false }
        if !activeGeometryGestures.isEmpty { return true }
        return view.window?.inLiveResize ?? false
    }

    /// The window drag is in progress. Kept as the 067 name so the existing resize tests read the same,
    /// and implemented as the `.windowLiveResize` gesture so there is one code path.
    public var isLiveResizing: Bool { activeGeometryGestures.contains(.windowLiveResize) }

    public func beginLiveResize() { beginCanvasGeometryGesture(.windowLiveResize) }
    public func endLiveResize() { endCanvasGeometryGesture(.windowLiveResize) }

    public func beginCanvasGeometryGesture(_ gesture: CanvasGeometryGesture) {
        guard activeGeometryGestures.insert(gesture).inserted else { return }
        guard activeGeometryGestures.count == 1 else { return }
        liveResizeLayouts = 0
        releasedForCanvas = nil
        // The transition is measured against the canvas that is about to move: it cannot continue. The
        // teardown does not re-present here — the next layout pass draws the frozen frame, and it is
        // the pass that knows the new canvas.
        cancelZoomBridge(rePresent: false)
    }

    /// The hand let go. One render, at the canvas that is on screen now — see
    /// `releaseFrozenCanvasIfNeeded`.
    public func endCanvasGeometryGesture(_ gesture: CanvasGeometryGesture) {
        guard activeGeometryGestures.remove(gesture) != nil else { return }
        releaseFrozenCanvasIfNeeded()
    }

    /// The canvas the release already asked a frame for. Two callers can reach a release for the same
    /// final size (the gesture's own end, and the first layout pass after it); the canvas is the key,
    /// so the second one is the same intent and costs nothing.
    private var releasedForCanvas: ImageSize?

    /// A gesture ended: one render request, and only for a canvas that has not already been asked for.
    ///
    /// Deliberately not debounced: the final size always gets a frame, which a timer cannot promise
    /// (the user can outrun it). At 适应 the frame that comes back is laid out for the new viewport, so
    /// the picture re-fits by itself — that is the one camera change a gesture is allowed to cause.
    @discardableResult
    private func releaseFrozenCanvasIfNeeded() -> Bool {
        guard liveResizeLayouts > 0, !isCanvasGeometryFrozen else { return false }
        liveResizeLayouts = 0
        guard let canvas = jobViewport(), canvas != releasedForCanvas else { return false }
        releasedForCanvas = canvas
        requestResizeRender()
        return true
    }

    /// One frozen draw per runloop tick, for the size the canvas has **when the tick runs** — which is
    /// the whole point: the passes in between are sizes nobody will ever see.
    private var frozenPresentQueued = false

    private func scheduleFrozenPresent() {
        guard frozenFrame != nil else { return }
        if frozenPresentQueued {
            coalescedDrawCount += 1
            return
        }
        frozenPresentQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.frozenPresentQueued = false
            self.rePresentFrozenOnce()
        }
    }

    /// The frozen frame at the canvas on screen now — skipped when the last present already drew this
    /// canvas, so a gesture that stops moving stops drawing.
    @discardableResult
    private func rePresentFrozenOnce() -> Bool {
        guard viewportPixels != lastPresentCanvas else { return false }
        return rePresentFrozen()
    }

    /// Draw the frame that is on the canvas again, with the geometry it was drawn with, on the canvas
    /// that is on screen now (067).
    ///
    /// This is the whole of what a gesture does to the picture:
    ///
    ///   · **smaller canvas** → the same picture at the same pixels, cropped by the surface. No
    ///     rescaling, because the window is stretched by the canvas ratio and the quad comes out
    ///     unchanged (`PresentWindow.stretched`).
    ///   · **larger canvas** → the same picture at the same pixels, and the area the surface grew by is
    ///     filled by the **low-resolution whole picture through the same map** — the backdrop's quad is
    ///     derived from the backdrop window, which is stretched alongside, so its content lands where
    ///     that content belongs. So a grown window shows more of the photograph's surroundings at
    ///     preview resolution instead of a grey or black band.
    ///   · **no backdrop cached yet** (a document opened seconds ago) → that area is the canvas colour
    ///     `#0F0F0F`. Never black, never stretched: the fallback is the clear colour, in that order.
    @discardableResult
    private func rePresentFrozen() -> Bool {
        guard let frozen = frozenFrame, let presenter else { return false }
        let canvas = viewportPixels
        let window = frozen.window.stretched(to: canvas, from: frozen.canvas)
        let backdropWindow = frozen.backdropWindow.stretched(to: canvas, from: frozen.canvas)
        // The gate is geometric and is asked about the **stretched** window: a frame that covered the
        // canvas at the old size may no longer cover it at the new one, and that is exactly when the
        // backdrop is wanted. `nil` (nothing cached for this document) leaves the clear colour.
        let drawn = backdropTexture(for: window)
        let ok = presentCanvas(presenter, texture: frozen.texture, photoRect: frozen.photoRect,
                               frameCanvas: frozen.frameCanvas, window: window,
                               placement: frozen.placement,
                               backdrop: drawn, backdropWindow: backdropWindow, canvas: canvas,
                               serial: 0, zoom: frozen.zoom, frozen: true)
        if ok { frozenDrawCount += 1 }
        return ok
    }

    private func present(frame: FrameResult, renderMilliseconds: Double, state: LoupeViewState,
                         graph graphOverride: RenderGraph? = nil) {
        guard let presenter else {
            lastPresentError = "no Metal presenter"
            return
        }
        // 065 (H2) / 065b: a frame landing is the frame graph moving on — the new photo's first frame,
        // which is exactly when the bottom image this photo asked for at the open can be made. The
        // request is answered here, behind that frame, never in front of it.
        serveWantedBackdrop()
        if let at = photoSwitchTime {
            photoSwitchTime = nil
            lastPhotoSwitchFirstFrameMilliseconds = (CACurrentMediaTime() - at) * 1000
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
        if zoomBridge != nil {
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
        // Task 028: the mask UI measures its normalised geometry against the frame the renderer
        // actually ingested (upright, EXIF orientation already applied). Published here — on the main
        // thread, next to the pixels it belongs to — because the catalog row's `PixelWidth/PixelHeight`
        // are the *stored* dimensions, which are transposed for EXIF 5…8 and made a portrait drag
        // render as a landscape-shaped ellipse.
        if let graphAtFrame, let assetID = session?.anchorAsset?.id {
            session?.ingestedSourceFrame = (assetID, graphAtFrame.sourceSize)
        }
        let canvas = viewportPixels
        // 068: **while the hand is moving, nothing new goes on the canvas.** A frame that lands now was
        // either rendered for a canvas the hand has already left, or for this one — but fitted into a
        // size the next tick replaces. Drawing either re-fits the photograph under the hand, which is
        // the movement being reported; the frozen frame stays where it is and the release renders the
        // exact final size. A canvas with nothing on it is the one exception: with no frame to hold, the
        // arriving frame is the best picture there is.
        if !forceStaleCanvasPresent, isCanvasGeometryFrozen, frozenFrame != nil {
            framesHeldDuringGesture += 1
            if let graphAtFrame { queue.async { graphAtFrame.recycle(output: frame.texture) } }
            return
        }
        // 066's stale-canvas rule, kept (067 does not make it unnecessary): a frame rendered for another
        // canvas cannot be drawn here **as if it filled this one** — the quads are pixel rectangles of
        // the canvas the frame was rendered for, so a full-bleed present of an old-canvas frame is the
        // photograph at another aspect, the reported 「变扁」.
        //
        // What it *can* do is what a live resize does: keep its own pixel geometry and let this surface
        // crop or extend it (`PresentWindow.stretched`). That is the difference between "the picture is
        // stretched into the window" and "the window changed around the picture" — and it means a frame
        // that lost the race with a resize is one correct frame rather than a blank canvas. A frame for
        // this canvas is requested on top; only if one can be made, since re-requesting the same canvas
        // would be a loop.
        let staleCanvas = !forceStaleCanvasPresent && canvas != frame.canvas
        if staleCanvas { canvasMismatchDrops += 1 }
        // The frame that is about to be replaced: it stays out of the render pool until this one's
        // drawable is committed (the bridge may still be sampling it), and is recycled then.
        let replaced = canvasTexture
        let t0 = CFAbsoluteTimeGetCurrent()
        // A settled frame is the whole picture at the canvas size, so `window: .whole` covers the
        // canvas and the pass gets no backdrop — the rule is the window's, not this call site's.
        let settledWindow = staleCanvas
            ? PresentWindow.whole.stretched(to: canvas, from: frame.canvas)
            : PresentWindow.whole
        // 058: which part of the picture this frame holds and where the photograph sits inside it —
        // the camera's own mapping, the same one `canvasContent` stores below. Recorded even though a
        // covering present draws no backdrop: the record must still say what a backdrop *would* have
        // been read through, and the settled present is where `.whole` frame and picture windows coincide.
        let settledPlacement = framing(viewport: frame.canvas)
            .map { $0.framePlacement(of: $0.mapping(of: state)) } ?? .whole
        let settledBackdropWindow = settledWindow.onWholePicture(settledPlacement)
        let drawn = backdropTexture(for: settledWindow)
        // 067: the photograph's rect inside the frame texture is the *only* geometry this present
        // supplies — the quad on the canvas follows from it and from the window. There is no optional
        // "pass the rect if you remember" argument any more, which is what used to turn a letterboxed
        // frame into a black band.
        let ok = presentCanvas(presenter, texture: frame.texture, photoRect: frame.photoRect,
                               frameCanvas: frame.canvas, window: settledWindow,
                               placement: settledPlacement, backdrop: drawn,
                               backdropWindow: settledBackdropWindow, canvas: canvas, serial: 0,
                               zoom: frame.zoom, frozen: staleCanvas) { [weak self] in            guard let self else { return }
            guard let replaced, let oldGraph = replaced.graph else { return }
            self.queue.async { oldGraph.recycle(output: replaced.texture) }
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
            retryPresentLater()
            return
        }
        // The pixels on the layer are `frame.texture` now, and they must stay alive for as long as a
        // bridge may re-sample them.
        canvasTexture = (frame.texture, graphAtFrame)
        // 067: kept — not for the matte (there is none any more) but because it is the **only** thing
        // that says where the photograph is inside the texture on the canvas. Every present that
        // re-draws this frame (a bridge, a teardown, a window drag) derives its quad from it.
        canvasPicture = (frame.photoRect, canvas)
        // The frame landed at its own canvas: ask for one for the canvas that is on screen, if the
        // renderer can produce it. (A stale frame is presented frozen, not dropped — see above.)
        if staleCanvas, jobViewport() != frame.canvas { requestResizeRender() }
        presentRetries = 0
        // A new frame is a new answer for whatever the pointer is over: the readback throttle is keyed
        // on this serial, so the next move re-reads instead of trusting the previous picture's texel.
        frameSerial += 1
        // These pixels are now what the canvas carries, and they were laid out for `state` — the
        // projection a later bridge has to start from.
        if let framing = framing(viewport: frame.canvas) {
            let mapping = framing.mapping(of: state)
            canvasContent = (mapping, frame.content, framing.framePlacement(of: mapping))
        }
        lastFrame = frame
        lastPresentError = nil
        // A new frame is a new answer for the pixel under the pointer, and since 2026-10-27 it is also
        // a new `sceneLinearSample`: the row must follow the picture without waiting for the next mouse
        // move, or a pan would leave the previous frame's numbers on screen while the pixels move under
        // a still cursor. The (frame, texel) throttle makes this one read per frame.
        if pointerCanvasPoint != nil { refreshPointerReadout() }
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
    // Two cadences live here, and 034 moved the histogram's onto the frame:
    //
    //   · the **clipping grid** is a property of the frame on screen — it marks *these* pixels — so it
    //     rides with the frame, and `recordMeasurements` publishes it from the presenting frame;
    //   · the **histogram** is a property of the picture. It used to be a second, thumbnail-sized
    //     render behind a 120 ms edit debounce (005); since 034 it is measured from the texture S4 has
    //     already written for this frame (`RenderGraph.measureFrameHistogram(fromFrame:)`, engine-side
    //     p50 1.38 / p95 3.21 ms), so a drag moves the plot on the frame it draws.
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
    ///
    /// - Parameter frame: whether the numbers came from a **frame** (`histogramCollectedFrames` counts
    ///   those). A zoomed edit's whole-picture measurement is not one — it measured the picture while
    ///   no frame was the picture — so it passes `false` and moves the plot without moving that count.
    private func publish(histogram: Histogram, key: String, frame: Bool = true) {
        session?.recordHistogram(histogram)
        lastHistogram = histogram
        histogramMeasuredKey = key
        histogramPublishCount += 1
        if frame { histogramCollectedFrames += 1 }
        // The card now has numbers of the picture that is on screen, so any "why nothing published"
        // mark (a `window frame` from a zoom the user has since left) is answered and must go.
        lastHistogramError = nil
    }

    // MARK: the histogram's key, cache and per-frame measurement (005, 034)
    //
    // Q30 measured a *frame* and had to answer "is the camera still?" with 60 ms of quiet. The
    // measurement is of the picture, so the question is "is the picture still?" — and a picture is
    // named by a key, not by a camera. Three rules, and no timestamps in the frame path:
    //
    //   · a frame computes the key of the picture it drew (`Histogram.cacheKey`: rung identity + edit
    //     digest + bins) and compares it with the key of the last frame that measured one
    //     (`histogramFrameKey`);
    //   · a *different* key is measured **on that frame**, from that frame's own texture. 034 removed
    //     the 120 ms settle that used to collapse a drag into one measurement: a drag renders ~20
    //     frames a second and each one now carries the plot's new numbers (≤ 1 frame of lag, which is
    //     what "like the picture" means);
    //   · the same key measures nothing — which is why panning and zooming, which cannot change the
    //     key, cost no measurement at all (they used to cost 8 ms per frame in release, 104 ms in a
    //     debug build, and one extra render per edit).
    //
    // Two guards stand in front of the measurement, and both are about *which pixels* a frame holds:
    //   · a frame that is a **window** into the picture (1:1, 200 %, 400 %) is not the picture, so it
    //     publishes nothing and marks `lastHistogramError == "window frame"`. The card keeps the
    //     whole-picture numbers it already has — a zoom must not move the plot (Lightroom behaves the
    //     same way) and must not blank it either, which is why the mark is the *only* thing a window
    //     frame does. **045**: the frame still publishes nothing, but it now arms a background
    //     measurement of the *picture* (`drainPictureMeasurements`), so a drag at 1:1 does move the
    //     plot — one measurement later, and never at the cost of a frame;
    //   · a key already in `histogramCache` publishes without measuring, so A → B → A is two
    //     measurements, not three.
    //
    // The measurement runs on the render queue (that graph's pool and that graph's queue — the engine
    // says it must), before the frame's texture goes back to the pool. Everything else — counters,
    // the cache, the card — is applied on main by `apply(_:)`.

    /// The key the picture would be measured under right now.
    ///
    /// The rung is the **biggest one the ladder has**, not the one this frame renders from: a frame at
    /// fit may render from the preview rung while 1:1 renders from the full one, and if the key carried
    /// the frame's rung the card would re-measure — with slightly different numbers — every time the
    /// zoom changed. The ladder keeps one rung in practice (`RenderJob.target` is always full scale),
    /// so this is the same buffer at every zoom; `fallbackScale` is only used before the first rung
    /// lands, and the key changes (and re-measures once) when the real one does.
    private func histogramKey(identity: String, digest: String, fallbackScale: Float) -> String {
        let rung = histogramRungScale(identity: identity, fallbackScale: fallbackScale)
        return Histogram.cacheKey(rungIdentity: "\(identity)-s\(rung)",
                                  editDigest: digest, bins: 256)
    }

    /// The rung a picture's histogram is measured from — the biggest one the ladder has, or the frame's
    /// own scale before the first rung lands. Split out of `histogramKey` because 045's background
    /// measurement has to build its graph from **this** buffer: the key names it, the numbers are
    /// labelled with it, and a measurement from any other rung would be a different picture.
    private func histogramRungScale(identity: String, fallbackScale: Float) -> Float {
        ladder.best(identity: identity, atOrBelow: DecodeLadder.fullScale)?.scale ?? fallbackScale
    }

    /// The document's digest, memoised against the document itself (render queue only).
    private func cachedEditDigest(_ edit: EditModel) -> String {
        if let cached = lastEditDigest, cached.edit == edit { return cached.digest }
        let digest = Histogram.editDigest(edit)
        lastEditDigest = (edit, digest)
        return digest
    }

    /// How much of the picture this camera actually holds — `1` at fit, ~0.16 at 1:1 on a 24 MP file,
    /// ~0.06 at 400 % (a 2560×1600 viewport against a 6208×4144 crop).
    ///
    /// 034's rule is "publish only a frame that covers the picture", and the honest measure of that is
    /// the camera's window against the document's crop, in source pixels: at fit `windowSize` *is* the
    /// crop, so this is exactly 1.
    ///
    /// **`Histogram.sampleFraction` cannot serve as that signal**, which is why it is not used here:
    /// it is a sampling *density* (`sampleCount / roi.area`), and a ≤ 256-long-edge grid over a 25 Mpx
    /// picture reads ≈ 0.17 % at every zoom — a "≥ 0.999" test on it would reject the fit frame too.
    /// The spec for this wiring asked for `sampleFraction ≥ 0.999`; the number that means "the frame
    /// is the whole picture" is this one, and it is what the 0.999 threshold below is applied to.
    private func pictureCoverage(_ framing: LoupeFraming, state: LoupeViewState) -> Double {
        let window = framing.windowSize(of: state)
        let pictureWidth = framing.cropWidthPixels, pictureHeight = framing.cropHeightPixels
        guard pictureWidth > 0, pictureHeight > 0 else { return 0 }
        // Per axis, then multiplied: a window can be wider than the crop and still miss half of it,
        // and a plain area ratio would call that "most of the picture".
        return min(1, window.width / pictureWidth) * min(1, window.height / pictureHeight)
    }

    /// The fraction of the picture a frame must hold before its pixels may be published as the
    /// picture's histogram. 0.999 leaves room for the integer rounding the renderer does on a window
    /// rect — `RenderGraph.plan` already normalizes a window that covers the whole frame to "no
    /// window", so a frame this close is the whole picture by the renderer's own reckoning.
    static let histogramWholePictureCoverage = 0.999

    /// What one frame's histogram step came to. Built on the render queue, applied on main.
    private struct HistogramStep {
        /// The picture this step is about (`Histogram.cacheKey`).
        var key: String
        /// The numbers to publish, or `nil` when this frame publishes nothing.
        var histogram: Histogram?
        /// `true` only when this frame ran a measurement (a cache hit is not one).
        var measured = false
        /// The measurement's own cost in milliseconds (GPU downsample + readback + CPU binning).
        var milliseconds: Double = 0
        /// Why nothing was published, when that is a fact worth keeping (`"window frame"`).
        var failure: String?
        /// Frame start → measurement in hand, in milliseconds.
        var latency: Double = 0
    }

    /// What this frame's histogram step came to — decided and executed on the render queue.
    ///
    /// This is 034's replacement for `noteHistogramKey` + `scheduleHistogramRefresh` +
    /// `renderHistogramRefresh`: the key is compared with the last frame that measured one, and a
    /// different key is measured **now**, out of the texture `makeFrame` has just rendered. Nothing
    /// about the camera is in the comparison, so twenty pan frames arrive here, match the key and
    /// leave without touching the GPU.
    ///
    /// A step is returned for **every** frame, including the ones that publish nothing: `apply(_:)`
    /// is what counts them, and "the pan frames measured nothing" is a claim the cadence tests make
    /// out of that counter.
    ///
    /// 070: the numbers arrive **already measured** (`RenderResult.histogram`), taken on the
    /// scene-linear texture inside the frame's own command buffer. This function no longer takes a
    /// texture at all, and nothing here reads pixels.
    private func histogramStep(for edit: EditModel, measured: Histogram?, milliseconds: Double,
                               identity: String, coverage: Double,
                               primaries: OutputPrimaries, ceiling: Double,
                               fallbackScale: Float, sourceURL: URL,
                               startedAt: CFAbsoluteTime) -> HistogramStep {
        // The card is off: this frame is a non-measurement, like every other.
        guard collectsHistogram else { return HistogramStep(key: "") }
        let key = histogramKey(identity: identity, digest: cachedEditDigest(edit),
                               fallbackScale: fallbackScale)
        let latency = { (CFAbsoluteTimeGetCurrent() - startedAt) * 1000 }
        // The picture's key has not moved: a pan, a zoom, a mask-visibility toggle. Nothing to measure
        // and nothing to publish — the card already has this picture's numbers.
        guard !frameAlreadyMeasured(key) else { return HistogramStep(key: key) }
        // The frame is a window into the picture (1:1 or beyond): its pixels are a *crop*, so any
        // numbers read out of it would be the crop's. This frame publishes nothing and says why — but
        // the *picture* may well have changed (an edit made at 1:1 or 400 %), so 045 answers it in the
        // background: numbers already measured under this key come out of the cache at once, and
        // otherwise one whole-picture measurement is armed. The key is not remembered by the frame
        // itself, so the edit is still measured when the camera returns to fit — that is the "no
        // flash, no blank plot" half of the rule.
        guard coverage >= Self.histogramWholePictureCoverage else {
            if let cached = cachedHistogram(for: key) {
                rememberMeasuredFrame(key)
                return HistogramStep(key: key, histogram: cached, latency: latency())
            }
            armPictureMeasurement(PictureRequest(edit: edit, key: key, identity: identity,
                                                 rungScale: histogramRungScale(identity: identity,
                                                                               fallbackScale: fallbackScale),
                                                 sourceURL: sourceURL, primaries: primaries,
                                                 ceiling: ceiling, armedAt: startedAt))
            return HistogramStep(key: key, failure: "window frame", latency: latency())
        }
        // Measured before (A → B → A): publish the numbers we have, do not measure again.
        if let cached = cachedHistogram(for: key) {
            rememberMeasuredFrame(key)
            return HistogramStep(key: key, histogram: cached, latency: latency())
        }
        if let histogram = measured {
            // The render measured this frame's picture, on the scene-linear texture S4 was about to
            // read — the rect is `plan.drawnRect` (S0's own layout, so no matte probe and no
            // background in bin 0) and the domain is light, not codes (070).
            store(histogram: histogram, for: key)
            rememberMeasuredFrame(key)
            return HistogramStep(key: key, histogram: histogram, measured: true,
                                 milliseconds: milliseconds, latency: latency())
        }
        // `wantsHistogramMeasurement` asked this frame for numbers, so `nil` here means the graph
        // could not produce a grid (a degenerate layout, a Metal failure). Answer it in the
        // background — that path renders the picture itself — rather than leave the card on another
        // document's numbers.
        armPictureMeasurement(PictureRequest(edit: edit, key: key, identity: identity,
                                             rungScale: histogramRungScale(identity: identity,
                                                                           fallbackScale: fallbackScale),
                                             sourceURL: sourceURL, primaries: primaries,
                                             ceiling: ceiling, armedAt: startedAt))
        return HistogramStep(key: key, failure: "no measurement", latency: latency())
    }

    /// Does this frame need to carry a histogram? — the **pre-render** half of `histogramStep`.
    ///
    /// 070 moved the measurement into the frame's own command buffer, so the decision has to be made
    /// before `render` is called rather than after: a `collectHistogram` frame pays a 36 k-thread pass
    /// and a 0.29 MB readback, and a pan or a zoom (which cannot change the picture's key) must not pay
    /// either. The guards are exactly `histogramStep`'s, in the same order, so the two cannot disagree:
    ///
    ///   · the card's switch is off → no measurement (`collectsHistogram`);
    ///   · the frame is a window into the picture → no measurement (a crop's numbers are the crop's);
    ///   · this key was already measured, or its numbers are in the cache → no measurement (A → B → A
    ///     publishes the cache and nothing needs re-counting).
    private func wantsHistogramMeasurement(edit: EditModel, identity: String,
                                           fallbackScale: Float, coverage: Double) -> Bool {
        guard collectsHistogram else { return false }
        guard coverage >= Self.histogramWholePictureCoverage else { return false }
        let key = histogramKey(identity: identity, digest: cachedEditDigest(edit),
                               fallbackScale: fallbackScale)
        guard !frameAlreadyMeasured(key) else { return false }
        return cachedHistogram(for: key) == nil
    }

    /// Hand a step to the main thread, where the counters, the cache and the card live.
    ///
    /// Synchronous when the frame was drawn on main (the tests' and `--ui-smoke`'s synchronous path),
    /// so a caller reads the counters of the frame it just drew; one hop otherwise, and
    /// `histogramIsIdle` is the flag that says a hop is outstanding.
    private func deliver(_ step: HistogramStep) {
        if Thread.isMainThread { return apply(step) }
        histogramLock.lock()
        histogramInFlight += 1
        histogramLock.unlock()
        DispatchQueue.main.async { [weak self] in self?.apply(step) }
    }

    /// Apply one frame's histogram step: counters, the error mark, the card.
    private func apply(_ step: HistogramStep) {
        histogramLock.lock()
        histogramInFlight = max(0, histogramInFlight - 1)
        histogramLock.unlock()
        if step.measured {
            histogramRefreshCount += 1
            lastHistogramMilliseconds = step.milliseconds
        }
        if let histogram = step.histogram {
            // A cache hit for the key the card is already showing is not news — publishing it again
            // would only inflate `histogramPublishCount` and make the smoke's "one publish per edit"
            // unreadable.
            if step.key != histogramMeasuredKey { publish(histogram: histogram, key: step.key) }
            lastHistogramLatency = step.latency
            return
        }
        histogramSkippedFrames += 1
        if let failure = step.failure { lastHistogramError = failure }
    }

    // MARK: 045 — the whole-picture measurement a window frame arms
    //
    // The design note is at the state block (`fullPictureSource`). The mechanism: a window frame whose
    // key has moved calls `armPictureMeasurement`, which drops the request into a single slot and makes
    // sure one drain is scheduled on `pictureQueue`. The drain takes the slot, measures (injected base
    // → one 256-grid readback; otherwise a whole-picture render), and hands the outcome to main; a
    // request that arrived meanwhile replaced the slot, so the drain loops instead of returning. An
    // outcome whose key is no longer the newest is dropped — that is what "a newer edit cancels the
    // older one" costs: at most one wasted measurement, never a stale plot.

    /// One request: everything the measurement needs that the frame already knew.
    private struct PictureRequest {
        /// The document to measure. "A frame and an edit never cross" is enforced against this, not
        /// against the frame that armed it.
        var edit: EditModel
        /// `Histogram.cacheKey` of the picture — the identity of the numbers.
        var key: String
        /// The rung identity (photo content + decode inputs), so the measurement can build its own
        /// graph from the picture's own buffer.
        var identity: String
        /// The rung the key names (`histogramRungScale` at arm time): the measurement builds its graph
        /// from that buffer, so the labels, the key and the numbers cannot disagree about the picture.
        var rungScale: Float
        /// Where the picture came from, for the fallback's development.
        var sourceURL: URL
        /// What the frame was rendered with, so the codes it measures are labelled truthfully.
        var primaries: OutputPrimaries
        var ceiling: Double
        /// Frame start on the `CFAbsoluteTime` clock, for the latency readout.
        var armedAt: CFAbsoluteTime
    }

    /// What one background measurement came to.
    private struct PictureOutcome {
        var key: String
        var histogram: Histogram?
        var milliseconds: Double = 0
        var latency: Double = 0
        var failure: String?
    }

    /// Arm one whole-picture measurement of `request`, replacing any request not yet started.
    ///
    /// Called from the frame path (the render queue, or main for a synchronous frame), so it does
    /// nothing but take the lock and hand out one block.
    private func armPictureMeasurement(_ request: PictureRequest) {
        histogramLock.lock()
        // The card already has this picture, or has already asked for it: twenty pan frames at 1:1
        // cost one request, not twenty.
        let answered = histogramFrameKey == request.key || pictureArmedKey == request.key
        if answered {
            histogramLock.unlock()
            return
        }
        pictureArmedKey = request.key
        pictureLatestKey = request.key
        // A request that never started is *cancelled* here: replacing it is what keeps the queue at one
        // measurement, and it is counted so `arms == measurements + drops` stays true.
        if picturePending != nil { pictureDrops += 1 }
        picturePending = request
        pictureArms += 1
        let schedule = !pictureScheduled
        if schedule { pictureScheduled = true }
        histogramLock.unlock()
        if schedule { pictureQueue.async { [weak self] in self?.drainPictureMeasurements() } }
    }

    /// Take requests off the slot until it is empty. `pictureQueue` only, at most one of these.
    private func drainPictureMeasurements() {
        while true {
            histogramLock.lock()
            guard let request = picturePending else {
                pictureScheduled = false
                histogramLock.unlock()
                return
            }
            picturePending = nil
            pictureRunning += 1
            histogramLock.unlock()

            let outcome = measurePicture(request)

            histogramLock.lock()
            pictureRunning = max(0, pictureRunning - 1)
            // The main-queue hop below is work the card is waiting for, so it counts as in flight:
            // `histogramIsIdle` is what the tests (and the smoke) call "settled".
            histogramInFlight += 1
            histogramLock.unlock()
            DispatchQueue.main.async { [weak self] in self?.applyPicture(outcome) }
        }
    }

    /// The measurement itself, on `pictureQueue`. Never throws: a failure is an outcome with a mark, so
    /// the card can say why it has nothing instead of keeping a stale plot in silence.
    private func measurePicture(_ request: PictureRequest) -> PictureOutcome {
        let started = CFAbsoluteTimeGetCurrent()
        let latency = { (CFAbsoluteTimeGetCurrent() - request.armedAt) * 1000 }
        do {
            let graph = try pictureMeasurementGraph(for: request)
            // The injected base first: the whole picture for ≈1 ms — and its digest is what says
            // whether it is the picture *of this edit* at all. A base rendered for another document is
            // never measured against this one.
            if let source = fullPictureSource?(request.edit),
               source.digest == Histogram.editDigest(request.edit),
               let histogram = source.histogram,
               abs(histogram.headroom - request.ceiling) < 1e-9 {
                // 070: that render measured its **own** scene-linear sample (`collectHistogram` +
                // `histogramSampleLongEdge`), so nothing is sampled here — no readback, no second
                // render, and no S4 clamp. Its headroom is the screen's at the time it was made; a
                // screen change would make the ceiling tick stale, so that case falls through to the
                // render below rather than publishing a marker for the wrong panel.
                histogramLock.lock()
                pictureFrameUses += 1
                histogramLock.unlock()
                return PictureOutcome(key: request.key, histogram: histogram,
                                      latency: latency())
            }
            let histogram = try graph.measureHistogram(request.edit, bins: 256,
                                                       headroom: request.ceiling)
            histogramLock.lock()
            pictureRenderUses += 1
            histogramLock.unlock()
            return PictureOutcome(key: request.key, histogram: histogram,
                                  milliseconds: (CFAbsoluteTimeGetCurrent() - started) * 1000,
                                  latency: latency())
        } catch {
            return PictureOutcome(key: request.key, latency: latency(), failure: "\(error)")
        }
    }

    /// The graph the background measurement renders on: built from the picture's **own rung** — the one
    /// `histogramRungScale` named when the request was armed, i.e. the buffer the key is built from. So
    /// the `canvas`/`roi` the numbers are labelled with are the picture's, and the fallback render
    /// samples exactly what `measureHistogramNow` samples (same rung, same options — the two therefore
    /// produce the same bins). Built once per rung identity, on `pictureQueue`; `cancelPendingFrames`
    /// drops it with the photo.
    ///
    /// A second graph rather than the frame's, on purpose: `RenderGraph` owns one command queue and one
    /// `TexturePool`, and a pool shared with the frame path from another thread is a data race.
    private func pictureMeasurementGraph(for request: PictureRequest) throws -> RenderGraph {
        let identity = "\(request.identity)-s\(request.rungScale)"
        histogramLock.lock()
        let cached = pictureGraphIdentity == identity ? pictureGraph : nil
        histogramLock.unlock()
        if let cached { return cached }
        let inputs = request.edit.decodeInputs
        // A miss here is a rung the ladder released under us; developing it again is the only way to
        // measure the picture the key names, and it is a background thread's business either way.
        let outcome = try ladder.rung(identity: request.identity, scale: request.rungScale) {
            try Self.develop(url: request.sourceURL, scale: request.rungScale, inputs: inputs)
        }
        let graph = try RenderGraph(input: RenderInput(image: outcome.rung.image,
                                                       identity: identity,
                                                       sourceURL: request.sourceURL))
        histogramLock.lock()
        pictureGraph = graph                 // an older rung's graph is replaced, not reused
        pictureGraphIdentity = identity
        histogramLock.unlock()
        return graph
    }

    /// Apply one background measurement on main: the counters, the cache, the card.
    private func applyPicture(_ outcome: PictureOutcome) {
        // A frame may have measured the same picture while this was in flight (the camera came back to
        // fit): those numbers are equally the picture's, and publishing the same key twice would only
        // inflate the count.
        let alreadyOnCard = outcome.key == histogramMeasuredKey
        histogramLock.lock()
        histogramInFlight = max(0, histogramInFlight - 1)
        if pictureArmedKey == outcome.key { pictureArmedKey = nil }
        let superseded = outcome.key != pictureLatestKey || alreadyOnCard
        if superseded { pictureStales += 1 }
        histogramLock.unlock()
        if superseded { return }

        guard let histogram = outcome.histogram else {
            // The arm is not remembered, so the next frame of this picture asks again — the same rule
            // as the fit path's `catch`: a transient failure must not freeze the card.
            lastHistogramError = outcome.failure ?? "picture measurement failed"
            return
        }
        histogramRefreshCount += 1
        lastHistogramMilliseconds = outcome.milliseconds
        lastHistogramLatency = outcome.latency
        // Under the picture's own key, so coming back to fit publishes these numbers instead of
        // measuring again, and A → B → A at 1:1 is one measurement.
        store(histogram: histogram, for: outcome.key)
        rememberMeasuredFrame(outcome.key)
        publish(histogram: histogram, key: outcome.key, frame: false)
    }

    /// Has this picture already been measured (or taken from the cache) by a frame?
    private func frameAlreadyMeasured(_ key: String) -> Bool {
        histogramLock.lock()
        defer { histogramLock.unlock() }
        return histogramFrameKey == key
    }

    private func rememberMeasuredFrame(_ key: String) {
        histogramLock.lock()
        histogramFrameKey = key
        histogramLock.unlock()
    }

    /// The measurement, synchronously, on the caller's thread — the smoke's and the tests' path into
    /// a whole-picture reading.
    ///
    /// It resolves the rung itself (developing the full one if nothing is resident) and publishes, so
    /// a caller only has to say *what* it wants measured. It is deliberately **not** the frame path:
    /// this one renders the picture at thumbnail scale, independent of any camera, which is what
    /// `--ui-smoke` asserts against (`canvas`/`roi` cover the whole picture, bins are reproducible
    /// across calls). The card no longer waits for it — since 034 the card is fed by the frames' own
    /// pixels — but the two agree because both are keyed by `Histogram.cacheKey` and a publish under
    /// the same key is what the card shows.
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
    ///
    /// Locked: `measureHistogramNow` stores from main while a frame may be storing from the render
    /// queue (034 measures on the frame path).
    private func store(histogram: Histogram, for key: String) {
        histogramLock.lock()
        defer { histogramLock.unlock() }
        histogramCache[key] = histogram
        histogramCacheOrder.removeAll { $0 == key }
        histogramCacheOrder.append(key)
        while histogramCacheOrder.count > histogramCacheLimit {
            let victim = histogramCacheOrder.removeFirst()
            histogramCache.removeValue(forKey: victim)
        }
    }

    /// The numbers this picture was measured at, if it has been measured before (A → B → A).
    private func cachedHistogram(for key: String) -> Histogram? {
        histogramLock.lock()
        defer { histogramLock.unlock() }
        return histogramCache[key]
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

    // MARK: the fixed-stop zoom slider (canvas, top-right)

    private func layoutZoomSlider() {
        // 2026-10-27 用户要求普通模式也放上方: the pill is in the **top-right** corner in *both*
        // modes — ordinary and 裁切. The branch that used to send ordinary mode to the bottom-right is
        // gone, and so is the reason it existed: the crop bar is centred at the bottom of the canvas,
        // so the bottom-right corner is exactly where two chrome rectangles overlap. One corner for
        // every mode means the reader never has to look for the control after entering the tool.
        zoomSlider.placement = .topRight
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
        //
        // 082: `zoom` is the camera's own number, so a crop session's frame-inscribed ceiling (which is
        // not a rung) prints as itself on the chip instead of the neighbouring stop's label.
        zoomSlider.update(zoomStop: currentZoomStop, fitZoom: framing()?.fitZoom,
                          zoom: viewState.isActualSize ? viewState.zoom : nil)
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
