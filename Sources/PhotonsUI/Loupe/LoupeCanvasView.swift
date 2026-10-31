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
