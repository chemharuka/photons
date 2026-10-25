import AppKit
import PhotonsCore

// MARK: - what a drag on the canvas means
//
// Q22: the mask UI. Three pieces live here, all of them PhotonsUI's:
//
//   1. `MaskTool` / `MaskViewState` — the split between "the document" and "what the canvas is
//      doing right now". `showMask` is *view state*: the renderer reads it from the document value,
//      but a snapshot must never carry it (`docs/tasks/QUEUE.md` 第 5 轮遗留 #1).
//   2. `CatalogSession`'s mask document API — new/delete/enable/select, the overlay toggle, and the
//      one stroke writer the canvas uses.
//   3. `MaskCanvasController` — pointer events → sampled points → a `Stroke` in the document.
//      Sampling is by **distance** (half a brush radius), not one point per mouse event: a 120 Hz
//      trackpad drag over a 200 pt stroke is 200 events and ~20 points, and the difference is a
//      200-point JSON blob per stroke versus a 20-point one.

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

    private weak var session: CatalogSession?
    private var points: [Float] = []
    private var pressures: [Float] = []
    private var lastKept: (x: Double, y: Double)?
    private var targetMaskID: String?
    private var placement: (component: Int, stroke: Int)?
    private var usingPressure = false

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
    private func shortEdgeDistance(_ a: (x: Double, y: Double), _ b: (x: Double, y: Double),
                                  session: CatalogSession) -> Double {
        let width = Double(session.anchorAsset?.width ?? 1)
        let height = Double(session.anchorAsset?.height ?? 1)
        let minSide = max(1, min(width, height))
        let dx = (b.x - a.x) * width / minSide
        let dy = (b.y - a.y) * height / minSide
        return (dx * dx + dy * dy).squareRoot()
    }
}
