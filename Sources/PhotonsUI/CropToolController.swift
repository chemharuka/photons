import CoreGraphics
import Foundation
import PhotonsCore

// MARK: - the crop tool's view state (task 035)
//
// 「添加旋转/裁切工具」 is an **interaction layer** over geometry that already exists: `EditModel
// .geometry` carries crop / rotationDegrees / flips / aspectLock, `CropMath` is the math, S0 is the
// renderer. So this file adds no rendering, no document field and no second projection. What it adds
// is:
//
//   · the mode (entering, cancelling, applying) — **view state**, kept here and never in
//     `EditModel`: an abandoned crop is not a document revision, and a document that carried a
//     "crop tool is open" flag would make ⌘Z look like it closed a tool (the same rule task 032
//     applies to the mask overlay, `MaskViewState`);
//   · a **draft** (crop, straighten, flips, lock) that the canvas draws and the drags edit;
//   · one writer at the end: 应用 writes the geometry once and commits one snapshot, 取消 writes
//     nothing at all — so Escape leaves the document byte-identical and the history untouched.
//
// While the tool is on, the canvas shows the **uncropped** frame (`previewEdit`): the user is
// cropping, so the part about to be thrown away has to be visible. Phos does the same thing — its
// crop mode renders `params.cropNeutral` and gates every other canvas gesture on `cropMode`
// (`local/src/swift-raw/Zenodeng_Phos/Sources/Phos/AppMain.swift:124,590`,
// `Sources/Phos/WorkspaceCanvasInput.swift:32`).
//
// The preview is a *derived document*, not a write: `LoupeFraming(edit:)` and `makeJob` see it, S0
// renders it, and `session.edit` never moves. Geometry is not a decode input (`DecodeInputs`), so a
// drag costs one render and zero decodes.

// MARK: - the ratio presets the bar offers

/// 原始 / 1:1 / 4:3 / 3:2 / 16:9 / 自由 — the six items of the ratio popup, in the order the bar
/// shows them.
///
/// 原始 and 自由 are **not** the same thing: 原始 is the sensor's own ratio (`AspectLock.matching`,
/// i.e. `.custom` unless the frame happens to be 3:2), while 自由 is `.original`, the document's
/// "no constraint" spelling (`CropMath.swift:118-128`). Brightroom draws the same line between
/// "original" and a named ratio (`Sources/BrightroomEngine/Library/Geometry.swift:140-196`).
public enum CropAspectPreset: String, Sendable, Equatable, Hashable, CaseIterable {
    case original
    case square
    case fourThree
    case threeTwo
    case sixteenNine
    case free

    public var displayName: String {
        switch self {
        case .original: return "原始"
        case .square: return "1:1"
        case .fourThree: return "4:3"
        case .threeTwo: return "3:2"
        case .sixteenNine: return "16:9"
        case .free: return "自由"
        }
    }

    /// The lock a click on this preset means for `source`.
    public func lock(source: ImageSize) -> AspectLock {
        switch self {
        case .original: return .matching(source: source)
        case .square: return .square
        case .fourThree: return .fourThree
        case .threeTwo: return .threeTwo
        case .sixteenNine: return .sixteenNine
        case .free: return .original
        }
    }

    /// Which preset a stored lock was chosen as — `.free` for `.original` (there is no way to tell
    /// "never had a lock" from "chose 自由", and they mean the same thing).
    public init(lock: AspectLock, source: ImageSize) {
        switch lock {
        case .original: self = .free
        case .square: self = .square
        case .threeTwo: self = .threeTwo
        case .fourThree: self = .fourThree
        case .sixteenNine: self = .sixteenNine
        case .custom(let ratio):
            let frame = Double(max(source.width, 1)) / Double(max(source.height, 1))
            self = (ratio.isFinite && abs(ratio - frame) <= 1e-6) ? .original : .free
        }
    }
}

// MARK: - the controller

/// The crop tool: mode, draft, drag lifecycle, and the one commit.
///
/// Owned by `LoupeController` (the canvas is where the gestures are) and driven by the menu, the
/// canvas and the floating bar. Every geometry entry point takes the **upright source frame** as a
/// parameter; the app passes `CatalogSession.maskSourceSize` and nothing else, which is what keeps a
/// portrait file as accurate as a landscape one (task 028).
@MainActor
public final class CropToolController {

    // MARK: draft

    /// The geometry being edited. Nothing here is in the document until `apply()`.
    public struct Draft: Sendable, Equatable {
        public var crop: CropRect = .full
        public var straighten: Double = 0
        public var flipHorizontal: Bool = false
        public var flipVertical: Bool = false
        public var lock: AspectLock = .original

        public init(crop: CropRect = .full, straighten: Double = 0,
                    flipHorizontal: Bool = false, flipVertical: Bool = false,
                    lock: AspectLock = .original) {
            self.crop = crop
            self.straighten = straighten
            self.flipHorizontal = flipHorizontal
            self.flipVertical = flipVertical
            self.lock = lock
        }

        /// The draft as a document group.
        public var geometry: GeometryGroup {
            GeometryGroup(crop: crop.clamped().normalizedRect,
                          rotationDegrees: CropTool.clampStraighten(straighten),
                          flipHorizontal: flipHorizontal,
                          flipVertical: flipVertical,
                          aspectLock: lock)
        }

        public init(geometry: GeometryGroup) {
            self.init(crop: geometry.cropRect,
                      straighten: geometry.straightenDegrees,
                      flipHorizontal: geometry.flipHorizontal,
                      flipVertical: geometry.flipVertical,
                      lock: geometry.aspectLock)
        }
    }

    // MARK: state

    public private(set) var isActive = false {
        // 派单 049: the inspector's 「像素数量 / 尺寸」 follows the *live* draft, so every entry into
        // and exit from 裁切 mode republishes it (leaving clears it, and the row falls back to the
        // document — which is what a cancelled draft must print).
        didSet { if isActive != oldValue { publishDraft() } }
    }
    /// The draft the canvas draws. Setter-free from outside except through the commands below.
    public private(set) var draft = Draft() {
        didSet { if draft != oldValue { publishDraft() } }
    }
    /// 九宫格. View state, and the only toggle that does not touch the draft.
    public var showsGrid = true
    public private(set) var isDragging = false
    /// True while a ⌘-drag is turning the picture rather than moving the frame.
    public var isRotatingPicture: Bool { rotating }

    /// 应用 that actually grew the history — one per real apply, zero for an apply that changed
    /// nothing (`EditHistory.commit` is a no-op then, and a counter that lied about it would make
    /// the "一次应用 = 一条历史" test pass for the wrong reason).
    public private(set) var appliedCount = 0
    /// 取消 presses that dropped a live draft.
    public private(set) var cancelledCount = 0
    /// Canvas gestures the tool took while it was on — the counter behind 手势优先级: in crop mode
    /// every drag/pinch/wheel is the tool's, and none of them reaches a pan or a mask gesture.
    public private(set) var swallowedGestures = 0
    /// The grip the last drag took, for the status line and the QA report.
    public private(set) var lastHandle: CropToolHandle?

    private weak var session: CatalogSession?
    private var drag: CropToolDrag?
    private var rotating = false
    private var rotateStart: Double = 0

    public init(session: CatalogSession?) {
        self.session = session
    }

    /// The session's own upright frame — the only frame the crop tool measures with. A computed
    /// property (not a stored copy) so a photo switch cannot leave the tool measuring the previous
    /// picture's aspect.
    public var sourceSize: ImageSize { session?.maskSourceSize ?? ImageSize(width: 1, height: 1) }

    /// Hand the live draft to the inspector (派单 049). One property write, no render, no document:
    /// the row recomputes two strings, and only while the tool is on. Cleared the moment the tool
    /// closes, so 应用 / 取消 / 离开 all leave the row reading the document again.
    private func publishDraft() {
        guard let session else { return }
        guard isActive, let id = session.anchorAsset?.id else {
            session.cropToolDraft = nil
            return
        }
        session.cropToolDraft = (id, draft.geometry)
    }

    // MARK: the mode

    /// Enter 裁切 mode with a draft seeded from the document.
    ///
    /// Returns false when there is nothing to crop (or the tool is already on) so the menu can be a
    /// plain toggle and the canvas cannot enter twice.
    @discardableResult
    public func begin() -> Bool {
        guard !isActive, let session else { return false }
        draft = Draft(geometry: session.edit.geometry)
        isActive = true
        isDragging = false
        drag = nil
        rotating = false
        lastHandle = nil
        return true
    }

    /// 应用 (↵): the draft becomes the document, **once**.
    ///
    /// One `applyEdit`, one `commitEdit` — so one ⌘Z, and an apply whose geometry equals what the
    /// document already had commits nothing (the two calls are no-ops by construction:
    /// `applyEdit` short-circuits on a semantically identical model and `EditHistory.commit` on an
    /// unchanged snapshot).
    @discardableResult
    public func apply() -> Bool {
        guard isActive, let session else { return false }
        let geometry = draft.geometry
        endDrag()
        isActive = false
        session.applyEdit { $0.geometry = geometry }
        let committed = session.commitEdit(label: "裁切与旋转")
        if committed { appliedCount += 1 }
        return committed
    }

    /// 取消 (Esc): drop the draft. Nothing is written, so the document, its revision and its history
    /// are exactly what they were before `begin()` — not "restored to", *untouched*.
    public func cancel() {
        guard isActive else { return }
        endDrag()
        isActive = false
        draft = Draft(geometry: session?.edit.geometry ?? GeometryGroup.identity)
        cancelledCount += 1
    }

    /// Leaving the loupe, changing photo, or the canvas going away: drop the tool silently. Not a
    /// 取消 the user asked for, so it does not count as one.
    public func detach() {
        guard isActive else { return }
        endDrag()
        isActive = false
        draft = Draft(geometry: session?.edit.geometry ?? GeometryGroup.identity)
    }

    // MARK: the draft's commands (never touch the document)

    /// 拉直 slider, and the readout next to it. Clamped to the document's own ±45.
    public func setStraighten(_ degrees: Double) {
        draft.straighten = CropTool.clampStraighten(degrees)
    }

    /// A ratio preset. The rect is reshaped **now** rather than at apply time, because the frame on
    /// screen has to be the frame that will be committed.
    public func setAspect(_ preset: CropAspectPreset, source: ImageSize? = nil) {
        let source = source ?? sourceSize
        let lock = preset.lock(source: source)
        draft.lock = lock
        draft.crop = CropTool.matching(lock, crop: draft.crop, source: source)
    }

    /// Direct lock write (the tests' door, and what `setAspect` ends in).
    public func setLock(_ lock: AspectLock, source: ImageSize? = nil) {
        let source = source ?? sourceSize
        draft.lock = lock
        draft.crop = CropTool.matching(lock, crop: draft.crop, source: source)
    }

    /// 水平翻转 / 垂直翻转.
    ///
    /// The flip is applied *inside* the crop frame by S0 (`uv` is flipped in place before the
    /// rotation, `CanvasPresenter.swift:17-28`), so the box keeps its place and the picture mirrors
    /// within it — no crop-rect arithmetic, and nothing to keep in sync.
    public func toggleFlipHorizontal() { draft.flipHorizontal.toggle() }
    public func toggleFlipVertical() { draft.flipVertical.toggle() }

    public func toggleGrid() { showsGrid.toggle() }

    /// The current ratio, as the popup shows it.
    public func aspectPreset(source: ImageSize? = nil) -> CropAspectPreset {
        CropAspectPreset(lock: draft.lock, source: source ?? sourceSize)
    }

    // MARK: the preview

    /// The document the canvas should render while the tool is on: **the whole frame**, with the
    /// draft's straighten and flips.
    ///
    /// Crop goes to `.full` because that is what "裁剪模式下画布显示未裁剪图" means, and the lock goes
    /// to `.original` because the draft rect is already the answer — the frame on screen must be the
    /// picture, not a pre-cropped one. Nothing is written: this value lives for one `makeJob`.
    public func previewEdit(from edit: EditModel) -> EditModel {
        guard isActive else { return edit }
        var e = edit
        e.geometry.crop = .full
        e.geometry.rotationDegrees = CropTool.clampStraighten(draft.straighten)
        e.geometry.flipHorizontal = draft.flipHorizontal
        e.geometry.flipVertical = draft.flipVertical
        e.geometry.aspectLock = .original
        return e
    }

    // MARK: layout

    /// The frame in view points, for the overlay and for the hit test.
    public func layout(mapping: LoupeMapping, source: ImageSize? = nil,
                       pointScale: Double = 1) -> CropToolLayout {
        CropTool.layout(crop: draft.crop,
                        source: source ?? sourceSize,
                        mapping: mapping,
                        pointScale: pointScale,
                        showsGrid: showsGrid)
    }

    // MARK: the drag

    /// Take the gesture at `point` (view points, y down).
    ///
    /// `rotate` is ⌘: a drag that starts **outside** the frame with it rotates the picture instead of
    /// drawing a new frame (the "专用模式" of the task, without a second tool button). A drag inside
    /// the frame is always a pan of the picture.
    @discardableResult
    public func beginDrag(atViewPoint point: CGPoint,
                          mapping: LoupeMapping,
                          source: ImageSize? = nil,
                          pointScale: Double = 1,
                          rotate: Bool = false) -> Bool {
        guard isActive else { return false }
        let source = source ?? sourceSize
        let scale = pointScale > 0 ? pointScale : 1
        let layout = layout(mapping: mapping, source: source, pointScale: scale)
        let handle = CropTool.hit(point, in: layout)
        swallowedGestures += 1
        lastHandle = handle

        let normalized = CropToolController.normalized(point, mapping: mapping, source: source,
                                                       pointScale: scale)
        guard let normalized else { return true }

        rotating = rotate && (handle == .outside || handle == .inside)
        rotateStart = draft.straighten
        drag = CropToolDrag(handle: rotating ? .inside : handle, crop: draft.crop, grab: normalized)
        isDragging = true
        return true
    }

    /// One tick. The rect comes from the mouse-down state every time (never from the last tick), so
    /// a drag cannot drift and a clamped edge cannot ratchet.
    public func continueDrag(atViewPoint point: CGPoint,
                             mapping: LoupeMapping,
                             source: ImageSize? = nil,
                             pointScale: Double = 1) {
        guard isActive, isDragging, let drag else { return }
        let source = source ?? sourceSize
        let scale = pointScale > 0 ? pointScale : 1
        guard let normalized = CropToolController.normalized(point, mapping: mapping,
                                                             source: source, pointScale: scale)
        else { return }

        if rotating {
            let centre = NormalizedPoint(draft.crop.centerX, draft.crop.centerY)
            draft.straighten = CropTool.straighten(rotateStart, grab: drag.grab,
                                                   to: normalized, centre: centre, source: source)
            return
        }
        draft.crop = drag.crop(at: normalized, source: source, lock: draft.lock)
    }

    /// Mouse-up. The draft stays; the document is untouched until 应用.
    public func endDrag() {
        isDragging = false
        drag = nil
        rotating = false
    }

    /// Escape mid-drag: the frame goes back to where it was at mouse-down, and nothing is written.
    public func cancelDrag() {
        guard let drag else { endDrag(); return }
        if !rotating { draft.crop = drag.crop }
        else { draft.straighten = rotateStart }
        endDrag()
    }

    // MARK: converting a pointer

    /// View point (points, y down) → normalized upright source point. `nil` when the mapping is
    /// degenerate (a zero-sized canvas), so a drag during layout cannot write a NaN rect.
    static func normalized(_ point: CGPoint, mapping: LoupeMapping, source: ImageSize,
                           pointScale: Double) -> NormalizedPoint? {
        let scale = pointScale > 0 ? pointScale : 1
        // **Frame space** (`framePoint`), not `sourcePoint`: the draft rect is a rect of the
        // straightened frame, so a grip dragged on screen has to move the edge that is under the hand.
        // Going through the rotating map turned every drag of a straightened picture into an arc
        // (and, while the projection was anisotropic, into a skew).
        let p = mapping.framePoint(viewX: Double(point.x) * scale,
                                   viewY: Double(point.y) * scale)
        guard p.x.isFinite, p.y.isFinite else { return nil }
        return NormalizedPoint(p.x / Double(max(source.width, 1)),
                               p.y / Double(max(source.height, 1)))
    }

    // MARK: the readout

    /// What the bar prints: `3:2 · 6048×4032` — the ratio the draft renders at, in pixels.
    public func sizeReadout(source: ImageSize? = nil) -> String {
        let source = source ?? sourceSize
        let pixels = CropMath.outputSize(draft.crop, in: source)
        let ratio = Double(pixels.width) / Double(max(pixels.height, 1))
        return "\(draft.lock.displayName)·\(CropToolController.ratioText(ratio)) · \(pixels.width)×\(pixels.height)"
    }

    static func ratioText(_ ratio: Double) -> String {
        guard ratio.isFinite, ratio > 0 else { return "—" }
        for known in [1.0, 4.0 / 3.0, 3.0 / 2.0, 16.0 / 9.0] {
            if abs(ratio - known) < 0.01 { return String(format: "%.2f", ratio) }
        }
        return String(format: "%.2f", ratio)
    }
}
