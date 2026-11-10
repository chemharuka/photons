import AppKit
import QuartzCore
import PhotonsCore

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
    public weak var controller: LoupeController? {
        didSet { brushRing.controller = controller }
    }

    /// 235 — what the canvas shows between 「enter the loupe」 and the first real frame.
    ///
    /// On a cold start the decode of a 60 MP file takes hundreds of milliseconds, and until it lands
    /// the layer is the matte colour: the user sees an empty editor. The grid already holds this
    /// photo's thumbnail, so the controller hands it here and this view draws it **aspect-fit** over
    /// the matte. It is removed by the first `present`, so it is a stand-in, never a second picture
    /// path.
    private let firstFramePlaceholder = FirstFramePlaceholderView()

    /// 258 — the matte sheet that covers the **previous** photo's pixels from the instant the photo
    /// changes until a frame of the new photo is on the layer.
    ///
    /// The canvas is a `CAMetalLayer`: its last drawable keeps showing the last photo no matter what
    /// the controller does to its own bookkeeping. 235's stand-in is only installed once a thumbnail
    /// is in hand, so a cold cache left that drawable visible — the reported 「残留上一个照片的像素
    /// 缓存」. This sheet is synchronous, full-canvas and the same `#202020` as the matte, so the old
    /// photo can never be the first thing the new selection shows.
    ///
    /// **277 — it is a sublayer of the canvas, not a third top-level layer.** The canvas' invariant is
    /// "every layer composites the one matte constant", and a sibling `NSView` broke the count while
    /// doing the same job. A sublayer of the backing `CAMetalLayer` still draws above its drawable
    /// (children composite over their parent's contents) and below the stand-in and the brush ring,
    /// so the visual order is unchanged and the layer count is the one the invariant describes.
    private let canvasCover = CALayer()

    /// 247 — the 修复 brush-size ring. It is the **last** subview, so it composites above both the
    /// matte cover and the stand-in. `hitTest` is nil, so it never takes a click.
    public let brushRing = BrushRingView()

    /// 247 — true while the pointer is over the canvas. The ring's visibility is this **and** the
    /// heal tool; tests read it without having to synthesise an AppKit tracking area.
    public var isHealPointerInside: Bool { controller?.pointerCanvasPoint != nil }

    /// `true` only while a stand-in is actually drawn (an image was installed and no frame has
    /// replaced it). Read by the cold-start test and by `LoupeController.firstFrameContent`.
    public var isShowingFirstFramePlaceholder: Bool {
        !firstFramePlaceholder.isHidden && firstFramePlaceholder.image != nil
    }

    /// 284 — the installed stand-in bitmap, for the colour/headroom acceptance.
    var firstFramePlaceholderImage: CGImage? { firstFramePlaceholder.image }

    /// 284 — the stand-in's surface. `CAMetalLayer` whenever Metal is available.
    var firstFramePlaceholderLayer: CAMetalLayer? { firstFramePlaceholder.layer as? CAMetalLayer }

    /// 258 — `true` between a photo change and the new photo's first present, even when the stand-in
    /// itself is still being fetched.
    public var isCoveringCanvas: Bool { !canvasCover.isHidden }

    /// 258 — where the stand-in is drawn, in canvas points. The real frame draws its photograph in
    /// the same rectangle the projection gives, so this is the number the no-jump assertion reads.
    /// 283 — it may be larger than the canvas (a 400 % picture); the canvas' `masksToBounds` crops it.
    public var firstFramePlaceholderRect: CGRect { firstFramePlaceholder.frame }

    /// Draw `image` over the matte until the first frame arrives. The rectangle comes from the same
    /// `FrameTransform` as the real frame's photograph (0.90 content at 适应, the photograph's own
    /// `pixels × zoom` at a numeric stop), so the image **fills** it rather than being fitted inside
    /// it: the thumbnail's aspect and the rectangle's aspect are the photograph's, and a second
    /// fit would shrink a portrait into the shape of a landscape (283).
    public func showFirstFramePlaceholder(_ image: CGImage, contentRect: CGRect) {
        firstFramePlaceholder.show(image, in: contentRect)
    }

    /// Re-place the stand-in after a canvas resize without changing the picture it shows.
    public func setFirstFramePlaceholderContentRect(_ rect: CGRect) {
        firstFramePlaceholder.setContentRect(rect)
    }

    /// The real frame is on the layer (or the photo went away): take the stand-in down.
    public func hideFirstFramePlaceholder() {
        firstFramePlaceholder.clear()
    }

    /// 258 — cover the layer with the matte at a photo change. Idempotent; the first present for the
    /// new photo (or leaving the loupe) ends it.
    public func beginPhotoSwitchCover() {
        canvasCover.isHidden = false
    }

    public func endPhotoSwitchCover() {
        canvasCover.isHidden = true
    }

    /// The mask painter, when a brush is armed. Every event still goes through `LoupeController`,
    /// which is the only thing that can turn a view point into a normalised source point; this view
    /// only says *which* of the two gestures a drag is (Q22).
    public weak var maskPainter: MaskCanvasController?

    /// Where the last drag was, in view points. Only a drag gesture's own scratch space — the
    /// *camera* position lives in the controller, in source pixels.
    private var lastDragPoint: CGPoint = .zero
    private var isDragging = false
    private var isPainting = false
    /// 229 — a 红眼 drag: every spacing step tries a detection, and only a hit places a spot.
    private var isRedEyeDragging = false
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
        // is the matte the present pass paints outside the picture — this colour is only seen before
        // the first drawable arrives. 315: it is a preference (`CanvasBackdrop.current`), so it is
        // re-read on `.canvasBackdropDidChange` instead of being frozen here.
        applyCanvasBackdrop()
        metalLayer.isOpaque = true
        // 235 — a subview's layer composites above the view's backing layer, so this sits on top of
        // the Metal content and below every overlay the controller adds around the canvas.
        //
        // 258 — the matte cover goes first: it must hide the layer's previous drawable at a photo
        // change, and the stand-in (when one is ready) is drawn on top of it. Its colour is the one
        // `applyCanvasBackdrop` just wrote, so it is not copied a second time here (315).
        canvasCover.isHidden = true
        canvasCover.frame = bounds
        // Above the layer's own contents but below every view-backed sublayer (the stand-in, the
        // brush ring): those are siblings at z = 0, this sheet composites first.
        canvasCover.zPosition = -1
        metalLayer.addSublayer(canvasCover)
        firstFramePlaceholder.isHidden = true
        firstFramePlaceholder.frame = .zero
        addSubview(firstFramePlaceholder)
        // 247 — above both 258 sheets, hidden until a heal pointer move asks for it.
        brushRing.frame = bounds
        brushRing.autoresizingMask = [.width, .height]
        brushRing.isHidden = true
        addSubview(brushRing)
        // 315 — the stop is a preference, and this view stores it in two layers. `.main` queue: the
        // layers belong to the main thread and `set(_:)` is called from the main thread.
        canvasBackdropToken = NotificationCenter.default.addObserver(
            forName: .canvasBackdropDidChange, object: nil, queue: .main) { [weak self] _ in
                self?.applyCanvasBackdrop()
            }
    }

    /// 315 — the token for `.canvasBackdropDidChange`. This view caches the matte in two layers
    /// (`metalLayer.backgroundColor`, and the photo-switch cover that copies it), so it is one of the
    /// places that must be told; the pass's clear colour is recomputed per present and is not cached.
    private var canvasBackdropToken: NSObjectProtocol?

    /// 315 — re-read the stop into every layer of the canvas that **stores** it.
    ///
    /// Two, and both are seen before/behind a drawable: the backing `CAMetalLayer`'s background (the
    /// cold start, before the first present) and the 258 photo-switch cover, which is a sublayer and
    /// therefore does not inherit the parent's background colour. Idempotent, so the initial build and
    /// the notification take the same path.
    public func applyCanvasBackdrop() {
        let colour = NSColor.canvasMatte.cgColor
        metalLayer.backgroundColor = colour
        canvasCover.backgroundColor = colour
    }

    public required init?(coder: NSCoder) { fatalError("no nibs in this app") }

    deinit {
        if let canvasBackdropToken { NotificationCenter.default.removeObserver(canvasBackdropToken) }
    }

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
        // 277 — the matte sheet is a sublayer of the canvas, so it follows the canvas' own frame.
        canvasCover.frame = metalLayer.bounds
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
                // 328 — while 画线拉直 is armed, Escape is the gesture's own 取消 (drop the line, keep
                // the draft); the second Escape leaves 裁切 as it always has.
                if controller?.cancelStraightenDrawIfArmed() == true { return }
                controller?.cancelCropTool()
                return
            case "\r", "\u{3}":
                controller?.applyCropTool()
                return
            default:
                break
            }
        }
        // 247 — bare `[` / `]` resize the 修复 brush. The menu's `⌘[` / `⌘]` (90° rotation) keeps its
        // path: a modifier means "not this gesture", and the switch below is otherwise untouched.
        if controller?.healToolIsActive == true,
           event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
           key == "[" || key == "]" {
            controller?.adjustHealRadius(by: key == "]" ? 1.1 : 1.0 / 1.1)
            return
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
                rotate: event.modifierFlags.contains(.command),
                clickCount: event.clickCount) ?? false
            return
        case .cropToolApply:
            controller?.applyCropTool()
            return
        case .eyedropper:
            // 派单 009 C: the eyedropper is a modal gesture, so it is the innermost of all — it
            // consumes the click before a paint drag or a pan can start. White balance disarms after
            // one sample; the mask pickers stay armed (`staysArmed`) until Esc / the button.
            controller?.handleEyedropperClick(atViewPoint: point,
                                              option: event.modifierFlags.contains(.option))
            return
        case .healClick:
            // 2026-10-28 (078 P0-1): also a one-shot — the click places one spot and consumes
            // nothing else (the tool stays armed, which is what makes clipping several blemishes in a
            // row one action per click).
            controller?.addHealSpot(atViewPoint: point)
            // 229: only the 红眼 preset turns a drag into a row of spots; the heal preset keeps its
            // one-click-per-spot behaviour.
            isRedEyeDragging = controller?.isRedEyeMode == true
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
        if isRedEyeDragging {
            controller?.continueRedEyeDrag(atViewPoint: convert(event.locationInWindow, from: nil))
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
        if isRedEyeDragging {
            isRedEyeDragging = false
            controller?.endRedEyeDrag()
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
        // 247 — ⌥+wheel resizes the 修复 brush instead of panning. A mouse wheel steps one notch per
        // event; a trackpad's precise deltas are proportional, so a slow two-finger turn is a fine
        // adjustment and a flick is a big one.
        if controller?.healToolIsActive == true,
           event.modifierFlags.contains(.option) {
            let delta = event.scrollingDeltaY
            guard delta != 0 else { return }
            let raw = event.hasPreciseScrollingDeltas
                ? exp(Double(delta) * 0.01)
                : (delta > 0 ? 1.1 : 1.0 / 1.1)
            controller?.adjustHealRadius(by: min(max(raw, 0.5), 2))
            return
        }
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

/// 235 — an image view that is deliberately **not** part of the canvas' gesture surface.
///
/// The loupe canvas owns every click (pan, zoom, crop, mask), so a stand-in drawn above it must be
/// transparent to hit testing or the first click after entering the editor would be swallowed by a
/// dead picture.
///
/// 284 — the stand-in is a `CAMetalLayer` surface, not an `NSImageView`: the HD cache is a Display P3
/// PQ file, and `NSImageView` could only draw it through an 8-bit SDR bitmap, so the switch from the
/// stand-in to the (EDR) real frame changed brightness. Reuse `ThumbnailMetalSurface`, the same
/// texture/pipeline the grid and filmstrip already run, so all three views agree about the light.
/// The rectangle comes from 283 and is the photograph's own aspect; direct aspect-fill is therefore
/// the right fit (and when a crop edit changes the rect's aspect, a centred fill is closer than the
/// old `scaleAxesIndependently` stretch).
final class FirstFramePlaceholderView: NSView {
    private(set) var image: CGImage?
    private var surface: ThumbnailMetalSurface?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("no nibs in this app") }

    override var isOpaque: Bool { false }

    override func makeBackingLayer() -> CALayer {
        if ThumbnailMetalRenderer.shared.isAvailable {
            return CAMetalLayer()
        }
        let fallback = CALayer()
        fallback.contentsGravity = .resizeAspectFill
        fallback.masksToBounds = true
        return fallback
    }

    /// A **fresh layer per picture**. `CAMetalLayer` keeps its last drawable until a new one is
    /// presented; reusing the stand-in's layer across a photo switch could therefore show the old
    /// thumbnail while the new texture is in flight. A new layer starts with no drawable, so the
    /// view can be made visible in the same turn as the install (the 235/258 tests depend on that)
    /// without ever flashing the previous picture. Once a layer is reused, `ThumbnailMetalSurface`'s
    /// `onPresented` callback (used by `ThumbnailEDRView`) is the equivalent guard.
    private func installSurface() {
        let fresh = makeBackingLayer()
        fresh.frame = bounds
        layer = fresh
        if let metal = fresh as? CAMetalLayer {
            surface = ThumbnailMetalSurface(layer: metal, cornerRadius: 0)
        } else {
            surface = nil
            fresh.contentsGravity = .resizeAspectFill
            fresh.masksToBounds = true
        }
    }

    func show(_ image: CGImage, in rect: CGRect) {
        self.image = image
        frame = rect
        installSurface()
        if let surface {
            surface.setImage(image)
        } else {
            layer?.contents = image
        }
        isHidden = false
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    func setContentRect(_ rect: CGRect) {
        frame = rect
        needsLayout = true
    }

    func clear() {
        image = nil
        surface?.setImage(nil)
        surface = nil
        layer?.contents = nil
        isHidden = true
    }

    override func layout() {
        super.layout()
        let scale = window?.backingScaleFactor ?? 2
        layer?.contentsScale = scale
        surface?.layout(size: bounds.size, scale: scale)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
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
