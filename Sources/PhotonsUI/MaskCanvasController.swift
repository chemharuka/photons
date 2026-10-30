import AppKit
import PhotonsCore

// MARK: - what a drag on the canvas means
//
// Q22: the mask UI. Three pieces live here, all of them PhotonsUI's:
//
//   1. `MaskTool` / `MaskViewState` — the split between "the document" and "what the canvas is
//      doing right now". `showMask` is *view state*: the renderer reads it from the document value,
//      but a snapshot must never carry it: comparing it would make every overlay toggle a history
//      entry, and capturing it would let an undo silently switch the overlay off.
//   2. `CatalogSession`'s mask document API — new/delete/enable/select, the overlay toggle, and the
//      one stroke writer the canvas uses.
//   3. `MaskCanvasController` — pointer events → sampled points → a `Stroke` in the document.
//      Sampling is by **distance** (half a brush radius), not one point per mouse event: a 120 Hz
//      trackpad drag over a 200 pt stroke is 200 events and ~20 points, and the difference is a
//      200-point JSON blob per stroke versus a 20-point one.

// MARK: - 修复画笔 (078 P0-1)
//
// The smallest panel that can drive S1.9, and no more: arm the tool, click the canvas, and a spot
// lands at the click with its source automatically searched for (or, with auto source off, one
// radius to the right — `HealSpot.defaultSourceOffset`). The list below lets the user delete a spot
// and change its radius; there are **no drag handles** and no hand-placed source point in this
// version, which is stated here rather than discovered.

extension CatalogSession {

    /// Radius of the next spot, in short-edge units of the frame. View state like `brushSize`: the
    /// spot stores its own radius when it is created, so moving this never rewrites a spot that
    /// already exists (and never grows the undo stack).
    public static let defaultHealRadius: Double = HealSpot.defaultRadius

    /// Append a spot at a **frame-normalised** point (0…1 of the cropped picture).
    ///
    /// One snapshot per spot: the click is one action, so ⌘Z takes the whole thing back in one press.
    /// Returns `nil` when the document is full or the point is outside the frame, so a stray click on
    /// the letterbox does not mint a history row.
    @discardableResult
    public func addHealSpot(at framePoint: NormalizedPoint, radius: Double? = nil) -> HealSpot? {
        guard framePoint.x >= 0, framePoint.x <= 1,
              framePoint.y >= 0, framePoint.y <= 1 else { return nil }
        let r = radius ?? healRadius
        let source: HealSourceResult
        if autoHealSource, let image = healFrameProvider?() {
            source = HealSpot.searchSource(in: image, center: framePoint, radius: r)
        } else {
            source = .skipped(radius: r)
        }
        let spot = HealSpot(center: framePoint, radius: r,
                            sourceOffset: source.offset, mode: healMode)
        var landed: HealSpot?
        applyEdit { landed = $0.addHealSpot(spot) }
        guard let landed else { return nil }
        commitEdit(label: "修复", coalesce: false)
        selectedHealSpotID = landed.id
        setLastHealSource(source)
        return landed
    }

    /// Remove a spot. `commit: false` for a caller that is about to do more (nothing does today).
    public func deleteHealSpot(_ id: String, commit: Bool = true) {
        var removed = false
        applyEdit { removed = $0.removeHealSpot(id) }
        guard removed else { return }
        if commit { commitEdit(label: "删除修复", coalesce: false) }
        if selectedHealSpotID == id { selectedHealSpotID = edit.healSpots.last?.id }
    }

    /// Radius of one spot. The drag writes through with `commit: false` (so a hundred ticks are one
    /// frame each and **one** snapshot at the end — the mask card's rule); the mouse-up commits.
    public func setHealRadius(_ radius: Double, for id: String, commit: Bool = true) {
        guard let index = edit.healSpots.firstIndex(where: { $0.id == id }) else { return }
        let clamped = min(max(radius, 0.002), 0.5)
        applyEdit { $0.healSpots[index].radius = clamped }
        if commit { commitEdit(label: "修复 半径") }
    }

    /// Heal ⇄ clone for one spot — a discrete action, so its own snapshot.
    public func setHealMode(_ mode: HealMode, for id: String) {
        guard let index = edit.healSpots.firstIndex(where: { $0.id == id }),
              edit.healSpots[index].mode != mode else { return }
        applyEdit { $0.healSpots[index].mode = mode }
        commitEdit(label: "修复 模式", coalesce: false)
    }
}

// MARK: - tool

/// What a drag on the loupe canvas means. `.off` keeps the M3 behaviour (pan/pinch), so arming a
/// brush is the only thing that changes what the canvas does.
public enum MaskTool: String, Sendable, CaseIterable {
    case off
    case brush
    case erase

    public var isPainting: Bool { self != .off }

    public var label: String {
        switch self {
        case .off: return "浏览"
        case .brush: return "画笔"
        case .erase: return "擦除"
        }
    }
}

// MARK: - view state vs document

/// The one place that decides what belongs to a snapshot.
///
/// `EditModel.showMaskID` is read by the renderer (the S4.5 overlay) but it is not an edit: turning
/// the red wash on does not change the picture, must not grow the undo stack, and must not survive an
/// undo. So:
///
///   · snapshots are written as `documentOnly(edit)` — an overlay can never enter the history;
///   · a restored snapshot is shown as `restoring(snapshot, keeping: liveOverlay)` — ⌘Z moves the
///     pixels and leaves the display mode alone;
///   · `overlayIsViewState(a, b)` is the assertion behind both: two documents that differ only in
///     `showMaskID` are the same document as far as `EditHistory` is concerned.
public enum MaskViewState {

    /// The document with the overlay stripped — what a snapshot and `develop_json` store.
    public static func documentOnly(_ model: EditModel) -> EditModel {
        guard model.showMaskID != nil else { return model }
        var out = model
        out.showMaskID = nil
        return out
    }

    /// What is on screen after restoring `snapshot`: its document, plus the overlay that was on.
    /// An id that names a mask the snapshot does not contain is dropped — the renderer would paint
    /// nothing for it anyway, and the inspector should not claim a mask is being shown that is gone.
    public static func restoring(_ snapshot: EditModel, keeping showMaskID: String?) -> EditModel {
        var out = snapshot
        if let showMaskID, snapshot.masks.contains(where: { $0.id == showMaskID }) {
            out.showMaskID = showMaskID
        } else {
            out.showMaskID = nil
        }
        return out
    }

    /// True when `a` and `b` are the same **document** even if the overlay differs. This is what
    /// keeps "toggle 显示蒙版" out of the history: `EditHistory.commit` asks exactly this question.
    public static func overlayIsViewState(_ a: EditModel, _ b: EditModel) -> Bool {
        EditHistory.isSemanticallyIdentical(documentOnly(a), documentOnly(b))
    }
}

// MARK: - session: the mask document API

extension CatalogSession {

    /// A new mask with one empty brush component — visible in the list, covering nothing.
    ///
    /// Empty on purpose: creating a mask must not change a single pixel (the atlas layer is all
    /// zeros and S1.6 is the identity branch), so "new mask" is undoable without touching the
    /// picture, and `showMask` on it paints nothing (coverage 0).
    @discardableResult
    public func addMask(name: String? = nil) -> Mask? {
        guard edit.masks.count < Mask.maxCount else { return nil }
        let component = MaskComponent(id: "c-\(UUID().uuidString)",
                                      op: .add, invert: false, feather: 0.5,
                                      shape: .brush(BrushShape(size: brushSize, strokes: [])))
        let mask = Mask(name: name ?? "蒙版 \(edit.masks.count + 1)", components: [component])
        applyEdit { $0.masks.append(mask) }
        guard edit.masks.contains(where: { $0.id == mask.id }) else { return nil }
        commitEdit(label: "新建蒙版")
        setSelectedMaskID(mask.id)
        return mask
    }

    /// Remove a mask, and the overlay with it if that is what was being shown.
    public func deleteMask(_ id: String) {
        applyEdit { $0.masks.removeAll { $0.id == id } }
        commitEdit(label: "删除蒙版")
        if edit.showMaskID == id { setShowMask(nil) }
        if selectedMaskID == id { setSelectedMaskID(edit.masks.first?.id) }
    }

    /// Enable/disable a mask. Disabling drops it out of the atlas **and** out of the key material,
    /// so the frame goes back to the pixels it had without it (that is the acceptance criterion).
    public func setMaskEnabled(_ id: String, _ enabled: Bool) {
        guard let index = edit.masks.firstIndex(where: { $0.id == id }),
              edit.masks[index].isEnabled != enabled else { return }
        applyEdit { $0.masks[index].isEnabled = enabled }
        commitEdit(label: enabled ? "启用蒙版" : "停用蒙版")
        if !enabled, edit.showMaskID == id { setShowMask(nil) }
    }

    /// Which mask the inspector and the canvas are pointed at. View state only.
    public func selectMask(_ id: String?) {
        guard let id else { setSelectedMaskID(nil); return }
        setSelectedMaskID(edit.masks.contains(where: { $0.id == id }) ? id : nil)
    }

    /// Show / hide the red overlay for one mask.
    ///
    /// **Never history, never a write**: this republishes the document's `showMaskID` and bumps
    /// `editRevision` so the renderer re-encodes the last pass, and that is all. (`applyEdit` cannot
    /// be used here: it short-circuits on `isSemanticallyIdentical`, which is exactly the property
    /// we want for history and exactly what would swallow this change.)
    public func setShowMask(_ id: String?) {
        let next: String? = id.flatMap { wanted in
            edit.masks.contains(where: { $0.id == wanted && $0.isEnabled }) ? wanted : nil
        }
        guard next != edit.showMaskID else { return }
        publishViewState { $0.showMaskID = next }
    }

    /// The inspector's toggle: on for the selected mask, off for whatever was showing.
    public func toggleShowSelectedMask() {
        setShowMask(isShowingSelectedMask ? nil : selectedMaskID)
    }

    /// Mutate one mask, commit, persist — the click/toggle door. The slider door is `writeMask`
    /// with `commit: false` during the drag (`MaskParameters.swift`), so both share one writer.
    public func updateMask(_ id: String, label: String = "蒙版", _ body: (inout Mask) -> Void) {
        writeMask(id, label: label, commit: true, body)
    }

    /// Write one brush stroke (or replace the one at `strokeIndex`) into `mask`.
    ///
    /// The canvas calls this for every sampled point so the stroke appears while the hand is still
    /// moving; `endPaint` commits **once**, so one gesture is one snapshot (§7 历史栈粒度).
    /// Returns where the stroke landed, which is what the next sample replaces.
    @discardableResult
    public func writeBrushStroke(_ stroke: Stroke, toMask id: String,
                                 componentIndex: Int? = nil,
                                 strokeIndex: Int? = nil) -> (component: Int, stroke: Int)? {
        guard let maskIndex = edit.masks.firstIndex(where: { $0.id == id }) else { return nil }
        var component = componentIndex
        if component == nil {
            // Append to the mask's last brush component, or start one. A mask created by the UI
            // already has an empty brush component, so this is normally index 0.
            component = edit.masks[maskIndex].components.lastIndex { if case .brush = $0.shape { return true } else { return false } }
            if component == nil {
                let newComponent = MaskComponent(id: "c-\(UUID().uuidString)", op: .add,
                                                 invert: false, feather: 0.5,
                                                 shape: .brush(BrushShape(size: brushSize, strokes: [])))
                let index = edit.masks[maskIndex].components.count
                applyEdit { $0.masks[maskIndex].components.append(newComponent) }
                component = index
            }
        }
        guard let componentIndex = component,
              case .brush(var brush)? = edit.masks[maskIndex].components[safe: componentIndex]?.shape else {
            return nil
        }
        var landed = strokeIndex
        if let index = strokeIndex, brush.strokes.indices.contains(index) {
            brush.strokes[index] = stroke
        } else {
            brush.strokes.append(stroke)
            landed = brush.strokes.count - 1
        }
        guard let landed else { return nil }
        brush.size = brushSize
        let shape = MaskShape.brush(brush)
        applyEdit { $0.masks[maskIndex].components[componentIndex].shape = shape }
        return (componentIndex, landed)
    }

    /// Remove the in-progress stroke, if the canvas still points at it.
    @discardableResult
    public func removeBrushStroke(_ id: String, component: Int, stroke: Int) -> Bool {
        guard let maskIndex = edit.masks.firstIndex(where: { $0.id == id }),
              edit.masks[maskIndex].components.indices.contains(component),
              case .brush(var brush)? = edit.masks[maskIndex].components[safe: component]?.shape,
              brush.strokes.indices.contains(stroke) else { return false }
        brush.strokes.remove(at: stroke)
        let shape = MaskShape.brush(brush)
        applyEdit { $0.masks[maskIndex].components[component].shape = shape }
        return true
    }

    /// How many strokes a mask's brush components hold — the smoke's "one gesture, one stroke".
    public func strokeCount(ofMask id: String) -> Int {
        guard let mask = edit.masks.first(where: { $0.id == id }) else { return 0 }
        return mask.components.reduce(0) { total, component in
            if case .brush(let brush) = component.shape { return total + brush.strokes.count }
            return total
        }
    }
}

// MARK: - the canvas side

/// Turns a drag into a stroke.
///
/// Coordinates arrive **normalised to the uncropped source** (0…1, y down) — the projection lives in
/// `LoupeController`, which is the only thing that knows the crop, the straighten angle and the
/// backing scale. This type therefore never looks at a view coordinate, and the same code paints
/// correctly at fit, at 1:1 and at 8:1.
///
/// Sampling rule: a point is kept when it is at least **half a brush radius** from the last kept
/// point, measured in short-edge units (the units `Stroke.radius` is in). Two consequences, both
/// deliberate: a fast drag is a straight capsule chain rather than a blob of hundreds of points, and
/// a slow one still has enough points that the stroke follows the hand.
@MainActor
public final class MaskCanvasController {

    /// Events that arrived during the stroke (what the spacing rule is measured against).
    public private(set) var eventsReceived = 0
    /// Points actually stored on the last finished stroke.
    public private(set) var lastStrokePointCount = 0
    /// Strokes finished through this controller — one `commitEdit` each.
    public private(set) var finishedStrokes = 0
    /// Control-point drags that ended in a committed document (task 032). One drag, one ⌘Z.
    public private(set) var maskHandleDrags = 0
    /// The grip the last drag took, in words — what the status/QA line prints.
    public private(set) var lastHandleLabel: String?

    private weak var session: CatalogSession?
    private var points: [Float] = []
    private var pressures: [Float] = []
    private var lastKept: (x: Double, y: Double)?
    private var targetMaskID: String?
    private var placement: (component: Int, stroke: Int)?
    private var usingPressure = false

    /// The grip being dragged, with the shape it started from (see `MaskHandleDrag`: every update is
    /// computed from the mouse-down state, so nothing accumulates and a clamp cannot ratchet).
    private var handleDrag: MaskHandleDrag?
    private var handleTarget: (maskID: String, component: Int, frame: ImageSize)?

    public init(session: CatalogSession) {
        self.session = session
    }

    /// True when a drag should paint instead of pan: a painting tool is armed **and** there is a
    /// mask to paint into. Everything else (no mask, tool off) falls through to the M3 pan.
    public var isArmed: Bool {
        guard let session else { return false }
        return session.maskTool.isPainting && session.selectedMaskID != nil
    }

    public var isPainting: Bool { targetMaskID != nil }

    // MARK: gesture

    public func begin(at point: NormalizedPoint, pressure: Double? = nil) {
        guard let session, let maskID = session.selectedMaskID, session.maskTool.isPainting else { return }
        targetMaskID = maskID
        points = [Float(point.x), Float(point.y)]
        pressures = pressure.map { [Float($0)] } ?? []
        usingPressure = pressure != nil
        lastKept = (point.x, point.y)
        placement = nil
        eventsReceived = 1
        push(to: session)
    }

    public func extend(to point: NormalizedPoint, pressure: Double? = nil) {
        guard let session, targetMaskID != nil else { return }
        eventsReceived += 1
        if let last = lastKept, shortEdgeDistance(last, (point.x, point.y), session: session) < spacing(session) {
            // Below the spacing threshold: the hand moved, the stroke would not change. Keep the
            // point count honest (a 1000-event drag is still ~20 points) and do not re-render.
            return
        }
        points.append(Float(point.x))
        points.append(Float(point.y))
        if usingPressure || pressure != nil {
            usingPressure = true
            pressures.append(Float(pressure ?? 1))
        }
        lastKept = (point.x, point.y)
        push(to: session)
    }

    /// Mouse-up: the stroke is done — one commit, one snapshot, one write.
    public func end() {
        guard let session, targetMaskID != nil else { return }
        lastStrokePointCount = points.count / 2
        if lastStrokePointCount > 0 {
            session.commitEdit(label: session.maskTool == .erase ? "擦除" : "画笔")
            finishedStrokes += 1
        }
        targetMaskID = nil
        placement = nil
        points = []
        pressures = []
        lastKept = nil
        usingPressure = false
    }

    /// Escape / leaving the canvas: throw the in-progress stroke away instead of committing it.
    public func cancel() {
        if let session, let maskID = targetMaskID, let placed = placement {
            session.removeBrushStroke(maskID, component: placed.component, stroke: placed.stroke)
        }
        targetMaskID = nil
        placement = nil
        points = []
        pressures = []
        lastKept = nil
        usingPressure = false
    }

    // MARK: control points (task 032)
    //
    // The same shape of gesture as a brush stroke, and the same history rule: every tick writes the
    // document with `commit: false` (the pixels follow the hand, the inspector shows the new numbers),
    // and mouse-up commits **once**. So one drag is one ⌘Z — not one per tick, which is what would
    // happen if each `extend` committed, and not zero, which is what would happen if only the ticks
    // wrote.
    //
    // The frame is `session.maskSourceSize` (the upright frame the renderer ingested). The drag maths
    // never sees `asset.width/height`: those are the *stored* dimensions and are transposed for
    // EXIF 5…8, so a rim dragged 60 px sideways on a portrait photo would render 90 px wide
    // (task 028, `MaskPortraitProjectionTests`).

    public var isDraggingHandle: Bool { handleDrag != nil }

    /// Take the grip `kind` at `point` (normalised upright source coordinates).
    ///
    /// Returns false when there is nothing to drag, so the caller can fall through to the next
    /// gesture in the stack — a miss must never be swallowed by this controller.
    @discardableResult
    public func beginHandleDrag(_ kind: MaskHandleKind, at point: NormalizedPoint,
                                source frame: ImageSize? = nil) -> Bool {
        guard let session, handleDrag == nil,
              let target = session.selectedAdjustableShape() else { return false }
        let source = frame ?? session.maskSourceSize
        guard let handle = MaskHandles.handle(kind, in: target.shape, source: source) else {
            return false
        }
        handleDrag = MaskHandleDrag(handle: handle, shape: target.shape, grab: point)
        handleTarget = (target.maskID, target.component, source)
        lastHandleLabel = kind.label
        return true
    }

    /// One tick. `uniform` is ⇧ (an ellipse keeps its aspect).
    @discardableResult
    public func extendHandleDrag(to point: NormalizedPoint, uniform: Bool) -> Bool {
        guard let session, let drag = handleDrag, let target = handleTarget,
              let shape = drag.shape(at: point, source: target.frame, uniform: uniform) else {
            return false
        }
        session.setMaskComponentShape(target.maskID, component: target.component,
                                      shape: shape, commit: false, label: "")
        return true
    }

    /// Mouse-up: the geometry becomes the document — one commit, one snapshot.
    ///
    /// A drag that ended exactly where it started changes nothing, and `EditHistory.commit` is a
    /// no-op for it: the stack does not grow, and `maskHandleDrags` does not count it.
    @discardableResult
    public func endHandleDrag() -> Bool {
        guard let session, let drag = handleDrag else { return false }
        defer { clearHandleDrag() }
        let committed = session.commitEdit(label: "调整\(drag.handle.kind.label)蒙版")
        if committed { maskHandleDrags += 1 }
        return committed
    }

    /// Escape, or the canvas going away: put the shape back and commit nothing.
    public func cancelHandleDrag() {
        guard let session, let target = handleTarget, let drag = handleDrag else {
            clearHandleDrag()
            return
        }
        session.setMaskComponentShape(target.maskID, component: target.component,
                                      shape: drag.shape, commit: false, label: "")
        clearHandleDrag()
    }

    private func clearHandleDrag() {
        handleDrag = nil
        handleTarget = nil
    }

    // MARK: stroke construction

    private func push(to session: CatalogSession) {
        guard let maskID = targetMaskID else { return }
        let stroke = Stroke(points: points,
                            pressure: usingPressure ? pressures : [],
                            radius: max(0.001, session.brushSize * 0.5),
                            feather: min(max(1 - session.brushHardness, 0), 0.999),
                            flow: min(max(session.brushFlow, 0), 1),
                            erase: session.maskTool == .erase,
                            closed: false)
        if let placement {
            _ = session.writeBrushStroke(stroke, toMask: maskID,
                                         componentIndex: placement.component,
                                         strokeIndex: placement.stroke)
        } else if let landed = session.writeBrushStroke(stroke, toMask: maskID) {
            placement = landed
        }
    }

    /// One spacing step: half the brush radius, in short-edge units. A 12 % brush therefore samples
    /// every 3 % of the short edge — about 33 points across a full-width stroke.
    private func spacing(_ session: CatalogSession) -> Double {
        max(0.002, session.brushSize * 0.5 * 0.5)
    }

    /// Distance in **short-edge units**, i.e. the metric `Stroke.radius` is expressed in.
    ///
    /// The frame comes from `maskSourceSize` — the upright one the renderer ingested — not from the
    /// catalog row's stored dimensions, which are transposed for EXIF 5…8 (task 028: the spacing would
    /// then be measured in a frame the hand is not drawing in).
    private func shortEdgeDistance(_ a: (x: Double, y: Double), _ b: (x: Double, y: Double),
                                  session: CatalogSession) -> Double {
        let source = session.maskSourceSize
        let width = Double(source.width)
        let height = Double(source.height)
        let minSide = max(1, min(width, height))
        let dx = (b.x - a.x) * width / minSide
        let dy = (b.y - a.y) * height / minSide
        return (dx * dx + dy * dy).squareRoot()
    }
}
