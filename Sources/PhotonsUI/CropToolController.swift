import CoreGraphics
import Foundation
import Observation
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
/// canvas, the floating bar and (since 2026-10-27) the 变换 workspace's 裁切 card. Every geometry entry
/// point takes the **upright source frame** as a parameter; the app passes
/// `CatalogSession.maskSourceSize` and nothing else, which is what keeps a portrait file as accurate
/// as a landscape one (task 028).
///
/// **`@Observable` since 2026-10-27** — and only for the panel's sake. `isActive`, `draft` and
/// `showsGrid` are what the 裁切 card draws, and the card must not keep a second copy of any of them
/// (a mirror would need a `sync()` and would drift, which is exactly the bug the bar was written
/// against). Making the tool observable means the card reads *this* object and SwiftUI redraws when it
/// changes; nothing about the tool's behaviour, its writes or its history changed.
@MainActor
@Observable
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

        /// The draft as a document group, carrying `document`'s flips (the one field, §F) **and its
        /// quarter turn** (P0-10): the draft's rect is measured in the turned frame, so a group built
        /// without the turn would write that rect into an un-turned frame — every 应用 would silently
        /// undo the rotation.
        public func geometry(flipsOf document: GeometryGroup) -> GeometryGroup {
            GeometryGroup(crop: crop.clamped().normalizedRect,
                          rotationDegrees: CropTool.clampStraighten(straighten),
                          flipHorizontal: document.flipHorizontal,
                          flipVertical: document.flipVertical,
                          aspectLock: lock,
                          quarterTurns: document.quarterTurns)
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
    public var showsGrid = true {
        didSet { if showsGrid != oldValue { draftChanged() } }
    }

    /// 082 — the canvas half of one draft edit, wired by `LoupeController`: the card writes the draft,
    /// the loupe re-lays the overlay and the bar's readout and asks for one render. A callback and not a
    /// `didSet` on `draft` on purpose: `refreshCropTool` → `clampToView` can write the draft back, and a
    /// notification there would be a loop.
    var onDraftChange: (() -> Void)?

    private func draftChanged() { onDraftChange?() }
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
    /// 087 — the geometry the tool was entered with (Esc's target, see `cancel()`).
    private var entryGeometry: GeometryGroup?
    private var drag: CropToolDrag?
    private var rotating = false
    private var rotateStart: Double = 0

    /// With this `false`, `effectiveCrop` hands back the stored rect untouched — the anti-proof for
    /// 「旋转后框自动缩小」. A test flips it to show that the containment and monotonicity criteria go
    /// red without the constraint; nothing in the app touches it.
    var clampsToRotatedFrame = true

    public init(session: CatalogSession?) {
        self.session = session
    }

    /// The session's own upright frame — the only frame the crop tool measures with. A computed
    /// property (not a stored copy) so a photo switch cannot leave the tool measuring the previous
    /// picture's aspect.
    /// 2026-10-28 (P0-10): the frame the tool measures with, **in the document's direction**.
    ///
    /// The draft's rect is measured in the turned frame (schema 9), so every metric below — the
    /// ratio lock's fit, `effectiveCrop`'s inscribed quad, the pixel readout, the drag maths — has to
    /// use the turned dimensions: a rotated document is 4032×6048, not 6048×4032. At
    /// `quarterTurns == 0` this is `maskSourceSize` unchanged, which is why no pre-9 number moves.
    public var sourceSize: ImageSize {
        let stored = session?.maskSourceSize ?? ImageSize(width: 1, height: 1)
        return (session?.edit.geometry ?? GeometryGroup.identity).orientedSource(stored)
    }

    // MARK: the draft's rect, as the turned picture allows it

    /// `draft.crop` **as the straightened picture allows it**: the stored rect shrunk — centre and
    /// pixel aspect kept — until it is fully inscribed in the sensor's turned quad
    /// (`CropMath.clampedToRotatedFrame`).
    ///
    /// The stored rect is *not* written back, and that is the point: 拉直 is a view of the user's
    /// rect, so dragging the angle back to 0° gives the whole frame back instead of leaving it
    /// ratcheted smaller, and the shrink is idempotent by construction rather than by care.
    ///
    /// Every reader goes through this one function — the overlay (`layout`), the bar's pixel readout,
    /// the inspector's draft and 应用 — so the frame on screen and the rect the document records are
    /// the same four numbers (the 072 rule: one writer, one value).
    public func effectiveCrop(source: ImageSize? = nil, degrees: Double? = nil) -> CropRect {
        let src = source ?? sourceSize
        let stored = draft.crop.clamped()
        let angle = CropTool.clampStraighten(degrees ?? draft.straighten)
        guard clampsToRotatedFrame, angle != 0 else { return stored }
        return CropMath.clampedToRotatedFrame(stored, in: src, degrees: angle)
    }

    /// Hand the live draft to the inspector (派单 049). One property write, no render, no document:
    /// the row recomputes two strings, and only while the tool is on. Cleared the moment the tool
    /// closes, so 应用 / 取消 / 离开 all leave the row reading the document again.
    private func publishDraft() {
        guard let session else { return }
        guard isActive, let id = session.anchorAsset?.id else {
            session.cropToolDraft = nil
            return
        }
        var geometry = draft.geometry(flipsOf: session.edit.geometry)
        geometry.crop = effectiveCrop(source: sourceSize).clamped().normalizedRect
        session.cropToolDraft = (id, geometry)
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
        // 087 — the state Esc has to come back to. `转动` writes the document on every tick, and a
        // released drag closes/reopens the tool session (one row per gesture), so by the time Esc
        // arrives the session's own snapshot only covers the last gesture. Remembering the geometry
        // this tool was entered with is what makes 「除非 esc 取消回退」 true after several drags.
        entryGeometry = session.edit.geometry
        isActive = true
        isDragging = false
        drag = nil
        rotating = false
        lastHandle = nil
        // 077: the tool session is what makes 「裁切完成后只保留一个记录」 a property of the history
        // rather than a property of this file's discipline. From here to `apply()` / `cancel()` the
        // history records nothing, so no handle position, angle or draft rect can become a row.
        session.beginToolSession("裁切", label: "裁切与旋转")
        return true
    }

    /// 应用 (↵): the draft becomes the document, **once**.
    ///
    /// One `applyEdit`, and one snapshot — the session's (`endSession`), taken against the document as
    /// it was when the tool was entered. An apply whose geometry equals what the document already had
    /// commits nothing (`applyEdit` short-circuits on a semantically identical model and the session
    /// ends with nothing to record).
    @discardableResult
    public func apply() -> Bool {
        guard isActive, let session else { return false }
        // **The same rect the overlay drew.** 应用 commits `effectiveCrop`, not `draft.crop`: at a
        // non-zero straighten the stored rect is the user's *intent* and the constraint is what the
        // picture allows, so writing the stored one would commit a frame the user never saw.
        var geometry = draft.geometry(flipsOf: session.edit.geometry)
        geometry.crop = effectiveCrop(source: sourceSize).clamped().normalizedRect
        endDrag()
        isActive = false
        session.applyEdit { $0.geometry = geometry }
        let committed = session.endToolSession(label: "裁切与旋转")
        if committed { appliedCount += 1 }
        return committed
    }

    /// 取消 (Esc): drop the draft. Nothing is written, so the document, its revision and its history
    /// are exactly what they were before `begin()` — not "restored to", *untouched*.
    public func cancel() {
        guard isActive else { return }
        endDrag()
        isActive = false
        // 077: zero rows, and (for a tool whose bar can write mid-session, e.g. the flips) the
        // document goes back to the state the session started from.
        session?.cancelToolSession()
        // 087: rows a released 转动 gesture already wrote are outside that session; put the geometry
        // back to what it was when the tool was entered, as one undoable row.
        if let session, let entry = entryGeometry, session.edit.geometry != entry {
            session.applyEdit { $0.geometry = entry }
            _ = session.commitEdit(label: "变换 · 取消", coalesce: false)
        }
        draft = Draft(geometry: session?.edit.geometry ?? GeometryGroup.identity)
        cancelledCount += 1
    }

    /// Leaving the loupe, changing photo, or the canvas going away: drop the tool silently. Not a
    /// 取消 the user asked for, so it does not count as one.
    public func detach() {
        guard isActive else { return }
        endDrag()
        isActive = false
        // 077: the session ends with zero rows (the draft is discarded, and any mid-session document
        // write is rolled back by `cancelToolSession`).
        session?.cancelToolSession()
        draft = Draft(geometry: session?.edit.geometry ?? GeometryGroup.identity)
    }

    // MARK: the draft's commands (never touch the document)

    /// 082 — a section reset (or the card's title) wrote the **document** under an open tool: the draft
    /// is a copy of that geometry, so it is re-seeded from the document and the frame on screen is the
    /// frame that was just written (not the one the reset replaced).
    ///
    /// Not a write: the draft is still only the draft, and 应用 is still the only commit.
    public func reseedDraftFromDocument() {
        guard isActive, let session else { return }
        draft = Draft(geometry: session.edit.geometry)
    }

    /// 拉直 slider, and the readout next to it. Clamped to the document's own ±45.
    public func setStraighten(_ degrees: Double) {
        draft.straighten = CropTool.clampStraighten(degrees)
        draftChanged()
    }

    /// 087 — 转动 is live: every tick writes the document, no history.
    ///
    /// The crop frame keeps 086's draft semantics, so only `straightenDegrees` is written here. The
    /// open tool session swallows the commit; `commitStraighten()` is the one release action that
    /// leaves exactly one row.
    public func setStraightenLive(_ degrees: Double) {
        setStraighten(degrees)
        guard isActive, let session else { return }
        let angle = draft.straighten
        session.applyEdit { $0.geometry.rotationDegrees = angle }
    }

    /// End of one 转动 gesture: close the crop session around exactly one row, then reopen it so the
    /// crop draft still waits for 应用 (086).
    @discardableResult
    public func commitStraighten() -> Bool {
        guard isActive, let session else { return false }
        let inSession = session.isToolSessionActive
        let committed: Bool
        if inSession {
            committed = session.endToolSession(label: "转动")
        } else {
            committed = session.commitEdit(label: "转动", coalesce: false)
        }
        if inSession { session.beginToolSession("裁切", label: "裁切与旋转") }
        return committed
    }

    /// A ratio preset. The rect is reshaped **now** rather than at apply time, because the frame on
    /// screen has to be the frame that will be committed.
    public func setAspect(_ preset: CropAspectPreset, source: ImageSize? = nil) {
        let source = source ?? sourceSize
        let lock = preset.lock(source: source)
        draft.lock = lock
        draft.crop = CropTool.matching(lock, crop: draft.crop, source: source)
        draftChanged()
    }

    /// Direct lock write (the tests' door, and what `setAspect` ends in).
    public func setLock(_ lock: AspectLock, source: ImageSize? = nil) {
        let source = source ?? sourceSize
        draft.lock = lock
        draft.crop = CropTool.matching(lock, crop: draft.crop, source: source)
        draftChanged()
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
        // 077: a flip is a **discrete** action, not a handle position — 072's promise is 「一次翻转 =
        // 一次 ⌘Z」. So inside a crop session it closes the session first (that leaves the crop-so-far
        // as its own row, or nothing when the rect did not move) and reopens a fresh one, which keeps
        // 「应用 with an unchanged crop commits nothing」 true as well.
        let inSession = session.isToolSessionActive
        if inSession { session.endToolSession(label: "裁切与旋转") }

        let before = horizontal ? session.edit.geometry.flipHorizontal : session.edit.geometry.flipVertical
        session.applyEdit { model in
            if horizontal { model.geometry.flipHorizontal.toggle() }
            else { model.geometry.flipVertical.toggle() }
        }
        let after = horizontal ? session.edit.geometry.flipHorizontal : session.edit.geometry.flipVertical
        // A flip is discrete (072 §F): never fold it into the drag before it, and two flips are two
        // rows even when no tool session was open to bracket them.
        session.commitEdit(label: horizontal ? "水平翻转" : "垂直翻转", coalesce: false)
        if inSession { session.beginToolSession("裁切", label: "裁切与旋转") }
        // The answer the bar needs is "did the document move", not "was a row written".
        return after != before
    }

    /// 顺时针 / 逆时针旋转 90° — **the document's field** (P0-10), the same `EditModel.turn` the
    /// menu row, the shortcut and the card's two buttons call. One `applyEdit` + one
    /// `commitEdit(coalesce: false)`, so ⌘Z takes a turn back in one press.
    ///
    /// A turn inside a crop session closes it first and reopens a fresh one (072's rule for a
    /// discrete geometry action, the same as `flip`): the draft's rect is measured in the turned
    /// frame, so it has to be re-seeded from the document or the next 应用 would commit a rect in the
    /// old direction.
    @discardableResult
    public func rotateQuarter(clockwise: Bool) -> Bool {
        guard let session else { return false }
        let inSession = session.isToolSessionActive
        if inSession { session.endToolSession(label: "裁切与旋转") }
        var turned = false
        session.applyEdit { model in turned = model.turn(clockwise: clockwise) }
        guard turned else {
            if inSession { session.beginToolSession("裁切", label: "裁切与旋转") }
            return false
        }
        // The row first, then reopen: inside a tool session `commitEdit` answers `nil` (077 — the session
        // owns the next snapshot), so committing after the reopen wrote nothing at all (082 measured it
        // on the shipped path: one press left `quarterTurns` at 0 and added no row).
        session.commitEdit(label: clockwise ? "顺时针旋转 90°" : "逆时针旋转 90°", coalesce: false)
        if inSession { session.beginToolSession("裁切", label: "裁切与旋转") }
        return true
    }

    /// The document's quarter turn — what the card's badge prints.
    public var quarterTurns: Int { session?.edit.geometry.quarterTurns ?? 0 }

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
        let c = effectiveCrop(source: source)
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
        draftChanged()
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
    /// `carry` is the picture's own screen transform (device pixels) for a frame that is being drawn
    /// mid-animation — see `CropCarry`. Identity everywhere except a zoom bridge's tick.
    public func layout(mapping: LoupeMapping, source: ImageSize? = nil,
                       pointScale: Double = 1,
                       carry: CropCarry = .identity) -> CropToolLayout {
        CropTool.layout(crop: effectiveCrop(source: source),
                        source: source ?? sourceSize,
                        mapping: mapping,
                        pointScale: pointScale,
                        showsGrid: showsGrid,
                        carry: carry)
    }

    // MARK: the frame's allowed area (⑦ 框不许出画布 / 出照片)

    /// With this `false`, `clampToView` does nothing — ⑦'s anti-proof. A test flips it to show that
    /// every containment criterion goes red without the clamp; nothing in the app touches it.
    var clampsFrameToView = true

    /// The largest rect the frame may occupy **right now**, in normalized frame coordinates.
    ///
    /// Three questions, and the answer is their intersection — each one was a separate report:
    ///
    ///   · **the canvas.** Pulling the viewport back through the mapping gives the part of the frame
    ///     that is on screen. A crop whose edge is outside this rect is drawn *off the canvas* — the
    ///     「裁切框会出画布边缘，进入左侧和上方」 the user saw after zooming in from a full frame.
    ///   · **the photo.** `0…1²`: a crop rect is a rect of the frame, and a frame has no pixels
    ///     outside itself, so a frame past it is a frame over blank canvas.
    ///
    /// The **straightened** photo is a third bound and it is *not* a rect: at θ ≠ 0 the legal region
    /// is the sensor's turned quad, which depends on where the rect sits. It is enforced where it can
    /// be exact — `effectiveCrop`, a shrink about the rect's own centre — instead of by cutting this
    /// room down to the centred `inscribedCrop`. The old intersection was safe but wrong in the other
    /// direction: it pulled a frame near the edge of the picture toward the middle as soon as the
    /// angle left 0°.
    ///
    /// `framePoint` is axis-aligned (S0's zoom plus an offset — the rotation belongs to the picture,
    /// not to the frame the crop is drawn in), so two corners are enough for the pull-back, and the
    /// result is exactly the rect whose four corners land on the canvas' four corners.
    public func safeCropRect(mapping: LoupeMapping, source: ImageSize? = nil) -> CropRect {
        let src = source ?? sourceSize
        let w = Double(max(src.width, 1)), h = Double(max(src.height, 1))
        let a = mapping.framePoint(viewX: 0, viewY: 0)
        let b = mapping.framePoint(viewX: Double(mapping.viewport.width),
                                   viewY: Double(mapping.viewport.height))
        var left = min(a.x, b.x) / w, right = max(a.x, b.x) / w
        var top = min(a.y, b.y) / h, bottom = max(a.y, b.y) / h

        // The picture's own `0…1²` is the only rect bound left here. The **straightened** bound is no
        // longer an intersection with the centred `inscribedCrop`: that rect is the largest one at the
        // *frame's* centre, and cutting a room out of it dragged a frame at the edge of the picture
        // toward the middle (「旋转后框会自己跑」). The turned picture's real bound depends on where the
        // rect is, so it is a shrink about the rect's own centre — `effectiveCrop` — not a room.
        left = max(left, 0); top = max(top, 0)
        right = min(right, 1); bottom = min(bottom, 1)
        guard right > left + 1e-9, bottom > top + 1e-9 else {
            // Nothing of the frame is on screen (a degenerate projection): the whole frame is the only
            // answer that keeps the arithmetic finite; `effectiveCrop` then fits it to the picture.
            return .full
        }
        return CropRect(left: left, top: top, right: right, bottom: bottom)
    }

    /// Pull the draft's rect into `safeCropRect` — the **model-layer** floor of ⑦.
    ///
    /// The overlay draws `draft.crop` and nothing else, so a clamp here is the only one that cannot
    /// be bypassed: a view-level clamp would fix the drawing and leave the *committed* crop outside
    /// the picture. Shrinking keeps the aspect lock (`CropTool.constrain`, anchor `.center`), moving
    /// keeps the size; the shrink only happens when the frame genuinely has less room than its own
    /// size (zoomed past the frame), and then the room wins — the frame stays on screen, which is
    /// the whole point.
    ///
    /// Returns `true` when the draft moved, so a caller can tell "clamped" from "already legal".
    @discardableResult
    public func clampToView(mapping: LoupeMapping, source: ImageSize? = nil) -> Bool {
        guard isActive, clampsFrameToView else { return false }
        // A canvas that has not been laid out yet (a zero-sized viewport in a headless test, or the
        // first `layout` pass) is not an opinion about what fits: clamping against it would shrink the
        // crop to a pixel. A real canvas is at least 560 pt wide by contract.
        guard mapping.viewport.width > 64, mapping.viewport.height > 64 else { return false }
        let src = source ?? sourceSize
        let room = safeCropRect(mapping: mapping, source: src)
        let before = draft.crop.clamped()

        // Shrink **uniformly** — one scale for both axes — so the frame keeps its shape
        // (⑦.5's 宽高比不变). The minimum span is a floor on that same scale, and only when the room
        // is big enough to hold it; when it is not, the room wins and the frame is simply smaller.
        let span = CropTool.minimumSpan(source: src)
        var scale = min(1, min(room.width / max(before.width, 1e-9),
                               room.height / max(before.height, 1e-9)))
        if room.width >= span.width, room.height >= span.height {
            let floor = min(1, max(span.width / max(before.width, 1e-9),
                                   span.height / max(before.height, 1e-9)))
            scale = max(scale, floor)
        }
        var candidate = CropRect(left: before.centerX - before.width * scale / 2,
                                 top: before.centerY - before.height * scale / 2,
                                 right: before.centerX + before.width * scale / 2,
                                 bottom: before.centerY + before.height * scale / 2)
        if draft.lock.ratio != nil {
            candidate = CropTool.constrain(candidate, lock: draft.lock, source: src, anchor: .center)
        }
        // Move (never resize) into the room, so a crop that already fits keeps its exact size.
        let fw = min(candidate.width, room.width), fh = min(candidate.height, room.height)
        let left = min(max(candidate.left, room.left), max(room.left, room.right - fw))
        let top = min(max(candidate.top, room.top), max(room.top, room.bottom - fh))
        let next = CropRect(left: left, top: top, right: left + fw, bottom: top + fh)
        guard next != before else { return false }
        draft.crop = next
        return true
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
        // The hand grabs the frame **it can see**, which at a non-zero straighten is the constrained
        // one (`effectiveCrop`), not the stored intent behind it.
        drag = CropToolDrag(handle: rotating ? .inside : handle,
                            crop: effectiveCrop(source: source), grab: normalized)
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
        let next = drag.crop(at: normalized, source: source, lock: draft.lock)
        // A tick that would put the rect's **centre** outside the turned picture cannot be honoured by
        // shrinking (there is no size at that centre), and jumping it back to the middle from under the
        // hand would be worse than ignoring it: the last legal frame stands. Everything else is stored
        // as the hand drew it — the constraint is applied on the way *out* (`effectiveCrop`), so a
        // frame pushed against the turned edge pins there and comes back smoothly.
        if clampsToRotatedFrame, draft.straighten != 0,
           CropMath.rotatedFrameScale(next, in: source, degrees: draft.straighten) <= 0 {
            return
        }
        draft.crop = next
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
    /// 082 — **实际角度** = 滑块角度 + 90 × quarterTurns. What the bar's 角度 段 prints and what the card
    /// calls 「实际角度」; the slider's own number is 「滑块角度」.
    ///
    /// The two are different facts and the user says so explicitly: 「注意角度有两个，一个是实际角度，
    /// 一个是滑块角度。实际角度等于滑块角度 + 90 旋转两个之和」. A picture turned 90° clockwise has been
    /// rotated by 90° whether or not the straighten slider was touched, so 0.0° on the slider and 90.0°
    /// on the picture is not a contradiction — it is two numbers that add up.
    ///
    /// `quarterTurns` is the **document's** field (P0-10, the same one `tiff:Orientation` is written
    /// from), so the readout follows ⌘[ / ⌘] / the card's two buttons with no second state.
    public var sliderAngle: Double { draft.straighten }

    /// 「实际角度」 in degrees: `straightenAngle + 90 × quarterTurns`, normalized turns only (0…3), so
    /// four turns read as 0° again and the number never wanders off the 0…270 + ±45 domain.
    public var actualAngle: Double {
        draft.straighten + 90 * Double(GeometryGroup.normalizedQuarterTurns(quarterTurns))
    }

    /// The bar's 角度 段 — the **actual** angle (`+2.5°` on the slider, one 90° turn → `92.5°`).
    public func angleText() -> String { Self.actualAngleText(draft.straighten, quarterTurns: quarterTurns) }

    /// The card's 「滑块角度」 readout — the slider's own value, in the form the slider prints.
    public func sliderAngleText() -> String { Self.angleText(draft.straighten) }

    /// `92.5°` / `266.0°` / `-4.0°` — no leading `+`: an *actual* angle is a direction on a circle, and
    /// a sign in front of 266° reads like an arithmetic term instead of a heading. The slider keeps its
    /// `%+.1f°` form (it is a signed offset from zero).
    public static func actualAngleText(_ straighten: Double, quarterTurns: Int) -> String {
        let angle = CropTool.clampStraighten(straighten)
            + 90 * Double(GeometryGroup.normalizedQuarterTurns(quarterTurns))
        return String(format: "%.1f°", angle)
    }

    /// `+2.5°` / `-45.0°` — the `%+.1f` form the slider has always printed (a leading `+` says
    /// "turned clockwise" without a legend).
    public static func angleText(_ degrees: Double) -> String {
        String(format: "%+.1f°", CropTool.clampStraighten(degrees))
    }

    /// The ratio the draft renders at, in pixels: `1.50` / `0.56`.
    public func ratioText(source: ImageSize? = nil) -> String {
        CropToolController.ratioText(pixelRatio(source: source))
    }

    /// `6048×4032` — the pixel size of what the frame will commit, i.e. of `effectiveCrop`: at a
    /// non-zero straighten the picture's own quad is the smaller of the two, and the readout has to
    /// print the frame the user is looking at, not the intent stored behind it.
    public func pixelText(source: ImageSize? = nil) -> String {
        let src = source ?? sourceSize
        let pixels = CropMath.outputSize(effectiveCrop(source: src), in: src)
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
        /// `315.0°` — 082: the field prints the **actual** angle, whose domain is
        /// `straighten ±45` plus `0…270` of quarter turns, i.e. `-45.0°` … `315.0°`. Three digits (and
        /// the minus end, `-45.0°`) are both six glyphs; the three-digit form is the wider one in the
        /// monospaced-digit font the bar uses.
        public static let angle = "315.0°"
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
