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
    ///
    /// 072 §F — **no flips here.** 水平/垂直翻转 is a document-level geometry action
    /// (`GeometryGroup.flipHorizontal/flipVertical`) shared with 变换 ▸ 水平翻转, so there is exactly
    /// one field: a `Draft` that carried its own copy could disagree with the document, and the bar's
    /// switch would then be invisible to ⌘Z until 应用. `begin()` seeds the rest from the document and
    /// `apply()` writes it back *around* the document's flips (`geometry(flipsOf:)`).
    public struct Draft: Sendable, Equatable {
        public var crop: CropRect = .full
        public var straighten: Double = 0
        public var lock: AspectLock = .original

        public init(crop: CropRect = .full, straighten: Double = 0, lock: AspectLock = .original) {
            self.crop = crop
            self.straighten = straighten
            self.lock = lock
        }

        /// The draft as a document group, carrying `document`'s flips (the one field, §F).
        public func geometry(flipsOf document: GeometryGroup) -> GeometryGroup {
            GeometryGroup(crop: crop.clamped().normalizedRect,
                          rotationDegrees: CropTool.clampStraighten(straighten),
                          flipHorizontal: document.flipHorizontal,
                          flipVertical: document.flipVertical,
                          aspectLock: lock)
        }

        public init(geometry: GeometryGroup) {
            self.init(crop: geometry.cropRect,
                      straighten: geometry.straightenDegrees,
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
    /// The draft the canvas draws. Setter-free from outside except through the commands below — the
    /// `internal(set)` is the tests' door (a drag's result without an `NSEvent`), never the app's.
    public internal(set) var draft = Draft() {
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
        session.cropToolDraft = (id, draft.geometry(flipsOf: session.edit.geometry))
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
        let geometry = draft.geometry(flipsOf: session.edit.geometry)
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

    /// 水平翻转 / 垂直翻转 — **the document's field**, the same one 变换 ▸ 水平翻转 writes (§F).
    ///
    /// The flip is applied *inside* the crop frame by S0 (`uv` is flipped in place before the
    /// rotation), so the box keeps its place and the picture mirrors within it — no crop-rect
    /// arithmetic, and nothing to keep in sync. What changed in 072: this writes the document with one
    /// `applyEdit` + one `commitEdit`, so ⌘Z takes it back in one press whether it came from the bar or
    /// the menu, and the two controls read the same bit.
    @discardableResult
    public func toggleFlipHorizontal() -> Bool { flip(horizontal: true) }

    @discardableResult
    public func toggleFlipVertical() -> Bool { flip(horizontal: false) }

    @discardableResult
    private func flip(horizontal: Bool) -> Bool {
        guard let session else { return false }
        session.applyEdit { model in
            if horizontal { model.geometry.flipHorizontal.toggle() }
            else { model.geometry.flipVertical.toggle() }
        }
        return session.commitEdit(label: horizontal ? "水平翻转" : "垂直翻转")
    }

    /// The document's flips — what the bar's two switches show (§F: no draft copy).
    public var flipHorizontal: Bool { session?.edit.geometry.flipHorizontal ?? false }
    public var flipVertical: Bool { session?.edit.geometry.flipVertical ?? false }

    public func toggleGrid() { showsGrid.toggle() }

    // MARK: 比例 (§C1 交换 / §C2 自定义)

    /// The ratio the draft is showing, in **pixels** — the lock's own ratio, or the rect's when the
    /// lock is 原始/自由 (nothing is constrained, so the rect is the answer).
    public func pixelRatio(source: ImageSize? = nil) -> Double {
        let source = source ?? sourceSize
        if let ratio = draft.lock.ratio { return ratio }
        let c = draft.crop.clamped()
        return (c.width * Double(max(source.width, 1))) / max(c.height * Double(max(source.height, 1)), 1e-9)
    }

    /// 交换长宽 (§C1): the current ratio's reciprocal, applied to the frame.
    ///
    /// Applies to whatever is in force — a named preset, 原始 (the frame's physical W:H), or a custom
    /// ratio — and writes the reciprocal as `.custom` when no preset names it (16:9 → 9:16 has no
    /// preset, and pretending it were 自由 would drop the constraint on the next drag). The rect is
    /// re-cut **inside the frame**: same centre, largest area that the frame holds at the new ratio, so
    /// 16:9 → 9:16 → 16:9 returns to the same four edges and the same pixels. The orientation mapping
    /// (EXIF 5…8 → the upright frame) has already happened in `sourceSize`, so there is no second,
    /// implicit swap here — the ratio is divided once, in pixel space.
    @discardableResult
    public func swapAspect(source: ImageSize? = nil) -> Bool {
        let source = source ?? sourceSize
        let current = pixelRatio(source: source)
        guard current.isFinite, current > 0 else { return false }
        let swapped = 1 / current
        guard swapped.isFinite, swapped > 0 else { return false }
        applyRatio(swapped, lock: AspectLock.matching(ratio: swapped), source: source)
        return true
    }

    /// 自定义比例 (§C2): `W:H`, parsed by `CropTool.ratio(from:)` before it gets here.
    ///
    /// The lock is `custom` — the document's own spelling — so the ratio survives a preset switch
    /// (`setAspect`) and comes back with the document. The rect is re-cut the same way a swap is
    /// (same centre, largest area the frame holds), and every later handle drag keeps it
    /// (`CropToolDrag` → `CropTool.constrain`, ≤0.5 % measured in `CropAspectSwapTests`).
    @discardableResult
    public func setCustomRatio(_ ratio: Double, source: ImageSize? = nil) -> Bool {
        guard ratio.isFinite, ratio > 0 else { return false }
        applyRatio(ratio, lock: .custom(ratio), source: source ?? sourceSize)
        return true
    }

    /// Same centre, largest area the **frame** holds at `ratio`, then the lock.
    private func applyRatio(_ ratio: Double, lock: AspectLock, source: ImageSize) {
        let c = draft.crop.clamped()
        let fitted = CropMath.fittedCrop(aspect: ratio, in: .full, source: source)
        let width = min(max(fitted.width, 1e-6), 1)
        let height = min(max(fitted.height, 1e-6), 1)
        // The centre is what the user asked to keep; it is only moved when the max-area rect cannot be
        // centred there (a crop near an edge has nowhere else to go).
        let left = min(max(c.centerX - width / 2, 0), 1 - width)
        let top = min(max(c.centerY - height / 2, 0), 1 - height)
        draft.lock = lock
        draft.crop = CropRect(left: left, top: top, right: left + width, bottom: top + height)
    }

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
        e.geometry.aspectLock = .original
        // 072 §F — the flips are the document's, so they are carried, not overridden: a 水平翻转 from
        // 变换 ▸ 水平翻转 while the tool is on has to show on the canvas immediately, and there is no
        // draft copy left that could disagree with it.
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

    /// The three fields of the bar's 信息栏 (072 §D1): [角度] [比值] [像素], in that order, each one a
    /// **fixed-width** field of its own. There used to be four — the lock's name (`比例`), the ratio and
    /// the pixel size, glued together by dots in one label — so the bar's width changed with the
    /// document and the numbers slid around as they were edited. Here each segment is its own string,
    /// and `CropToolBar` measures the worst case of each once and never lets it grow.
    public func angleText() -> String { CropToolController.angleText(draft.straighten) }

    /// `+2.5°` / `-45.0°` — the `%+.1f` form the slider has always printed (a leading `+` says
    /// "turned clockwise" without a legend).
    public static func angleText(_ degrees: Double) -> String {
        String(format: "%+.1f°", CropTool.clampStraighten(degrees))
    }

    /// The ratio the draft renders at, in pixels: `1.50` / `0.56`.
    public func ratioText(source: ImageSize? = nil) -> String {
        CropToolController.ratioText(pixelRatio(source: source))
    }

    /// `6048×4032` — the pixel size of what the frame will commit.
    public func pixelText(source: ImageSize? = nil) -> String {
        let pixels = CropMath.outputSize(draft.crop, in: source ?? sourceSize)
        return "\(pixels.width)×\(pixels.height)"
    }

    /// The whole 信息栏 in one line, for the QA/status path — the same three segments, separated by a
    /// single space, and **no** lock name and no dots (§D1).
    public func sizeReadout(source: ImageSize? = nil) -> String {
        "\(angleText()) \(ratioText(source: source)) \(pixelText(source: source))"
    }

    /// The worst string each of the three fields can ever print. `CropToolBar` measures these to size
    /// its fixed-width fields, and `CropBarLayoutTests` asserts that four extreme drafts produce the
    /// same `frame(x, width)` — so the constant lives next to the formatter that produces it.
    public enum WorstCase {
        /// `-45.0°` — 6 characters, and the minus is the wide one of the two signs.
        public static let angle = "-45.0°"
        /// The widest `%.2f` a ratio can print: four integer digits and two decimals.
        public static let ratio = "9999.99"
        /// `9999×9999` — four digits per side and the multiplication sign.
        public static let pixels = "9999×9999"
    }

    static func ratioText(_ ratio: Double) -> String {
        guard ratio.isFinite, ratio > 0 else { return "—" }
        return String(format: "%.2f", ratio)
    }
}
