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
            // 132: the draft may sit outside the photograph (the output frame can be bigger).
            GeometryGroup(crop: crop.clamped(allowsOutsideSource: true).normalizedRect,
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

    /// 123 — the name the transform acceptance uses. It is the same view state as `isActive`; a
    /// session is "cropping" exactly while the draft is open.
    public var isCropping: Bool { isActive }

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

    /// The 803aff6 "框必须内切于旋转后的照片" rule — **off by default since 132** (user 2026-10-29:
    /// the crop may leave the picture; the pixels outside are black, and the frame turns red instead
    /// of being pulled back). A test flips it to prove the old containment behaviour still exists.
    var clampsToRotatedFrame = false

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

    // MARK: 123 — the one transform value

    /// The draft as the transform session sees it: the document's flips and quarter turn plus the
    /// draft's crop, angle and lock. This value type owns the UI→document angle mapping; nothing in
    /// the card does trigonometry.
    public var transformSession: TransformSession {
        TransformSession(geometry: draftGeometry, source: sourceSize)
    }

    /// Same value under the shorter name the panel reads.
    public var transform: TransformSession { transformSession }

    /// The geometry both the overlay and the renderer consume. The rotation matrix lives here, so a
    /// second caller cannot pick a different sign. The crop is `effectiveCrop` — the rect the overlay
    /// actually draws and `finish(.confirm)` writes — not the stored intent behind it.
    public var cropGeometry: CropGeometry {
        if !isActive, let session {
            return CropGeometry(geometry: session.edit.geometry, source: sourceSize)
        }
        return CropGeometry(geometry: effectiveGeometry(draftGeometry), source: sourceSize)
    }

    /// The overlay draws against the **un-turned** document while the slider is dragged (088), so it
    /// needs the delta between the draft and the committed angle — still derived from the session's
    /// geometry, never re-derived with its own `cos`/`sin`.
    public var overlayGeometry: CropGeometry {
        var delta = effectiveGeometry(draftGeometry)
        delta.rotationDegrees = CropTool.clampStraighten(draft.straighten)
            - CropTool.clampStraighten(session?.edit.geometry.straightenDegrees ?? 0)
        return CropGeometry(geometry: delta, source: sourceSize)
    }

    /// The draft's geometry with the document's flips and quarter turn carried (the same value
    /// `apply()` writes).
    private var draftGeometry: GeometryGroup {
        draft.geometry(flipsOf: session?.edit.geometry ?? GeometryGroup.identity)
    }

    /// The draft with the crop replaced by the rect the overlay drew (`effectiveCrop`).
    private func effectiveGeometry(_ geometry: GeometryGroup) -> GeometryGroup {
        var geometry = geometry
        geometry.crop = effectiveCrop(source: sourceSize)
            .clamped(allowsOutsideSource: true).normalizedRect
        return geometry
    }

    /// The geometry `finish(.confirm)` writes: the draft's fields, with the crop replaced by the one
    /// the overlay actually drew (`effectiveCrop` — the rect inscribed in the turned frame).
    private func committedGeometry(for document: GeometryGroup) -> GeometryGroup {
        effectiveGeometry(draft.geometry(flipsOf: document))
    }

    /// The slider's value in the UI's own convention: positive = clockwise.
    public var angleUIValue: Double { CropTool.clampStraighten(draft.straighten) }

    /// 123 — the one UI→document angle write. `TransformSession.setAngle(uiValue:)` chooses the
    /// sign; this method only carries its answer into the draft.
    public func setAngle(uiValue: Double) {
        var session = TransformSession(geometry: draftGeometry, source: sourceSize)
        session.setAngle(uiValue: uiValue)
        draft.straighten = session.draft.straightenDegrees
        draftChanged()
    }

    /// The canvas the draft will produce, in pixels.
    public var effectiveCanvas: ImageSize { cropGeometry.canvas }

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
        // 132: the draft may sit outside the photograph — the crop is the output frame now, and the
        // clamp only keeps the span finite/positive.
        let stored = draft.crop.clamped(allowsOutsideSource: true)
        let angle = CropTool.clampStraighten(degrees ?? draft.straighten)
        return CropMath.clampedToRotatedFrame(stored, in: src, degrees: angle,
                                              keepsInsideRotatedFrame: clampsToRotatedFrame)
    }

    /// Does the frame the user sees cover pixels outside the photograph? Read by the overlay only —
    /// it paints the frame red; it never moves the rect and never writes the document. The geometry
    /// is 803aff6's own `fitsInsideRotatedFrame` (kept, not rewritten), with its purpose changed from
    /// "pull the frame back" to "warn".
    public func frameExceedsPicture(source: ImageSize? = nil, degrees: Double? = nil) -> Bool {
        let src = source ?? sourceSize
        let angle = CropTool.clampStraighten(degrees ?? draft.straighten)
        return CropMath.frameExceedsPicture(effectiveCrop(source: src, degrees: angle),
                                            in: src, degrees: angle)
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
        geometry.crop = effectiveCrop(source: sourceSize)
            .clamped(allowsOutsideSource: true).normalizedRect
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
    public func apply() -> Bool { finish(.confirm) }

    /// 完成 (the card's button) — the same write as `apply()`, through the same `finish(_:)`.
    @discardableResult
    public func complete() -> Bool { finish(.done) }

    /// 123 — the one finish path. ↵ (`confirm`), Esc (`cancel`) and 完成 (`done`) all land here, so
    /// the mode, the draft, the history and the camera cannot take three different routes out.
    @discardableResult
    public func finish(_ outcome: TransformFinish) -> Bool {
        switch outcome {
        case .confirm, .done:
            return confirmDraft()
        case .cancel:
            cancelDraft()
            return false
        }
    }

    @discardableResult
    private func confirmDraft() -> Bool {
        guard isActive, let session else { return false }
        // **The same rect the overlay drew.** 应用 commits `effectiveCrop`, not `draft.crop`: at a
        // non-zero straighten the stored rect is the user's *intent* and the constraint is what the
        // picture allows, so writing the stored one would commit a frame the user never saw.
        let geometry = committedGeometry(for: session.edit.geometry)
        endDrag()
        isActive = false
        session.applyEdit { $0.geometry = geometry }
        let committed = session.endToolSession(label: "裁切与旋转")
        draft = Draft(geometry: geometry)
        if committed { appliedCount += 1 }
        return committed
    }

    /// 取消 (Esc): drop the draft. Nothing is written, so the document, its revision and its history
    /// are exactly what they were before `begin()` — not "restored to", *untouched*.
    private func cancelDraft() {
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

    /// Kept as the named Esc door; it is `finish(.cancel)`.
    public func cancel() { finish(.cancel) }

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

    /// 169 §2b — the crop session was opened on photo A and the user clicked photo B **without
    /// leaving 裁切**. The tool stays armed, but every piece of context has to be B's:
    ///
    ///   · the draft is re-seeded from B's document (A's crop rect is not B's);
    ///   · `entryGeometry` is B's too, or Esc would roll B back to A's geometry;
    ///   · the tool session is reopened on B's history (the photo switch already replaced it).
    ///
    /// This is the re-arm half of the one entry point; it never writes the document.
    @discardableResult
    public func reseedForPhotoChange() -> Bool {
        guard isActive, let session else { return false }
        endDrag()
        draft = Draft(geometry: session.edit.geometry)
        entryGeometry = session.edit.geometry
        if !session.isToolSessionActive {
            session.beginToolSession("裁切", label: "裁切与旋转")
        }
        return true
    }

    /// 拉直 slider, and the readout next to it. Clamped to the document's own ±45.
    ///
    /// 088 — a tick is a **draft** write only: the canvas keeps the document's pixels (and its
    /// framing) and only the frame quad turns (`layout`'s `quadRotationDegrees`). The document gets
    /// the angle once, in `commitStraighten()`, on mouse-up / return.
    public func setStraighten(_ degrees: Double) {
        draft.straighten = CropTool.clampStraighten(degrees)
        draftChanged()
    }

    /// 087's spelling, kept for the callers that still say 「live」: since 088 it is the same draft
    /// write as `setStraighten` — no document write happens per tick.
    public func setStraightenLive(_ degrees: Double) {
        setStraighten(degrees)
    }

    /// The angle still to be shown on top of the document: `θ − θ₀`, in degrees. 0 at rest and right
    /// after a release, and up to ±90 at the slider's extremes when the document already carries ±45
    /// (so it is *not* clamped again — the quad has to turn by the whole difference).
    public var straightenDelta: Double {
        let committed = CropTool.clampStraighten(session?.edit.geometry.straightenDegrees ?? 0)
        return draft.straighten - committed
    }

    /// End of one 转动 gesture: write the draft angle **once** (`applyEdit`), close the crop session
    /// around exactly one row, then reopen it so the crop draft still waits for 应用 (086).
    ///
    /// Order matters: the document write is what asks the loupe for the one re-render; ending the
    /// session before it would make `endToolSession` see no movement and add no row.
    @discardableResult
    public func commitStraighten() -> Bool {
        guard isActive, let session else { return false }
        let angle = CropTool.clampStraighten(draft.straighten)
        session.applyEdit { $0.geometry.rotationDegrees = angle }
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
        if preset != .free { rememberLocked(preset: preset) }
        draftChanged()
    }

    /// Direct lock write (the tests' door, and what `setAspect` ends in).
    public func setLock(_ lock: AspectLock, source: ImageSize? = nil) {
        let source = source ?? sourceSize
        draft.lock = lock
        draft.crop = CropTool.matching(lock, crop: draft.crop, source: source)
        draftChanged()
    }

    // MARK: 104 — the ratio chip's cycle and the lock's toggle

    /// 104: the last **locked** ratio the user chose, remembered for the 🔒 button. Process memory
    /// only — a UI preference like `CropToolBar.lastCustomRatioText`, never a document field. The
    /// default is 原始, so the first click on 🔓 brings the sensor's own ratio back.
    private var lastLockedPreset: CropAspectPreset = .original
    private var lastLockedCustom: Double?

    /// `true` only when the document's spelling is `AspectLock.original` — that is 自由. 原始 is a
    /// real constraint (`.matching(source:)`, i.e. `.custom` on a non-3:2 sensor), so it reads 🔒.
    public var isAspectFree: Bool { draft.lock.ratio == nil }

    /// 104 — one click on the ratio chip advances the fixed cycle
    /// `原始 → 1:1 → 4:3 → 3:2 → 16:9 → 自由 → 原始`; `backward` is ⇧-click and steps the other way.
    ///
    /// It ends in `setAspect`, the same verb the old menu called, so the chip, the menu (gone) and the
    /// tests cannot drift into two write paths. A custom lock has no slot of its own; `aspectPreset()`
    /// folds it to 自由, so a click on a typed `5:4` goes on to 原始 like the table says.
    public func cycleAspect(backward: Bool = false) {
        let presets = CropAspectPreset.allCases
        guard let index = presets.firstIndex(of: aspectPreset()) else { return }
        let step = backward ? -1 : 1
        let next = presets[(index + step + presets.count) % presets.count]
        setAspect(next)
    }

    /// 104 — the 🔒 / 🔓 button: 自由 ⇄ the last locked ratio (default 原始).
    public func toggleAspectLock() {
        if isAspectFree {
            if let ratio = lastLockedCustom, ratio.isFinite, ratio > 0 {
                _ = setCustomRatio(ratio)
            } else {
                setAspect(lastLockedPreset)
            }
            return
        }
        rememberCurrentLock()
        setAspect(.free)
    }

    private func rememberLocked(preset: CropAspectPreset) {
        lastLockedPreset = preset
        lastLockedCustom = nil
    }

    private func rememberCurrentLock() {
        if aspectPreset() == .free, case .custom(let ratio) = draft.lock,
           ratio.isFinite, ratio > 0 {
            lastLockedCustom = ratio
        } else {
            lastLockedPreset = aspectPreset()
            lastLockedCustom = nil
        }
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
        // 104: a typed ratio is a lock too — 🔓 must bring it back, not only the named presets.
        lastLockedCustom = ratio
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
                       carry: CropCarry = .identity,
                       quadRotationDegrees: Double? = nil) -> CropToolLayout {
        // 123: the angle is the same value the renderer will consume, via `CropGeometry`. The
        // overlay still draws the *delta* against the document while the slider is in flight (088).
        let geometry = overlayGeometry
        return CropTool.layout(crop: effectiveCrop(source: source),
                        source: source ?? sourceSize,
                        mapping: mapping,
                        pointScale: pointScale,
                        showsGrid: showsGrid,
                        carry: carry,
                        quadRotationDegrees: quadRotationDegrees ?? geometry.rotationDegrees,
                        exceedsPicture: frameExceedsPicture(source: source))
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
        CropWorkspaceLayout.canvasBounds(mapping: mapping, source: source ?? sourceSize)
    }

    /// 162 §2.3 — **the hard boundary**: the visible canvas, in normalized frame coordinates.
    ///
    /// This is the only bound a drag/keyboard step has to respect. It is *not* `0…1²`: the canvas can
    /// be larger than the photograph (a zoomed-out camera shows the black band around it), and a crop
    /// is allowed to cover that band. `sourcePixelBounds` below is the photograph itself — a readout
    /// and warning concept, never a clamp.
    public func canvasBounds(mapping: LoupeMapping, source: ImageSize? = nil) -> CropRect {
        safeCropRect(mapping: mapping, source: source)
    }

    /// The camera's own pixels (`0…1²`). **Not a hard boundary** since 162: a crop may cover the
    /// rotated-out / letterboxed band outside the sensor, and the pixels there render as zero. The
    /// overlay reads it only to paint the frame red (`frameExceedsPicture`).
    public var sourcePixelBounds: CropRect { .full }

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
        // 092 — at Δθ ≠ 0 the drawn frame is a **quad**, not the rect projected by the document
        // framing. Clamping the un-turned rect would leave the turned corners outside, so the
        // rotated path fits the quad's bounding box instead (Δθ = 0 keeps the old arithmetic bit
        // for bit).
        let delta = straightenDelta
        if delta.isFinite, delta != 0 {
            return clampRotatedQuadToView(mapping: mapping, source: src, degrees: delta)
        }
        let room = canvasBounds(mapping: mapping, source: src)
        let before = draft.crop.clamped(allowsOutsideSource: true)
        let next = clampedToCanvas(before, bounds: room, source: src, lock: draft.lock)
        guard next != before else { return false }
        draft.crop = next
        return true
    }

    /// 162 §2.3 — the **hard** clamp: every edge inside `bounds` (the visible canvas), with the
    /// frame's aspect kept. This is what makes 「框不能出画布」 true for a drag as well as for a
    /// camera change.
    ///
    /// A frame larger than the canvas is shrunk **uniformly** (the ratio is the user's rule), and a
    /// frame that fits is only *moved* — its size is untouched, so ⑦'s 「不弹回」 still means "the
    /// crop you drew stays the size you drew it". `bounds` is not `0…1²`; the source-pixel rectangle
    /// is deliberately not consulted here (162: 框可以出相机像素).
    private func clampedToCanvas(_ rect: CropRect, bounds: CropRect,
                                 source: ImageSize, lock: AspectLock) -> CropRect {
        let c = rect.clamped(allowsOutsideSource: true)
        guard bounds.width > 1e-9, bounds.height > 1e-9 else { return c }
        let scale = min(1, bounds.width / max(c.width, 1e-9),
                        bounds.height / max(c.height, 1e-9))
        var width = c.width * scale
        var height = c.height * scale
        // A degenerate bound (a window narrower than the tool's own floor) still has to produce a
        // legal rect; the canvas wins because it is the hard edge.
        width = min(max(width, min(CropTool.minimumSpan(source: source).width, bounds.width)),
                    bounds.width)
        height = min(max(height, min(CropTool.minimumSpan(source: source).height, bounds.height)),
                     bounds.height)
        if let ratio = lock.ratio, width > 0, height > 0 {
            // Re-apply the ratio after the minimum-span floor, inside the canvas.
            let normalized = ratio * Double(source.height) / Double(max(source.width, 1))
            if width / height > normalized { width = height * normalized } else { height = width / normalized }
            if width > bounds.width { width = bounds.width; height = width / normalized }
            if height > bounds.height { height = bounds.height; width = height * normalized }
        }
        let left = min(max(c.centerX - width / 2, bounds.left),
                       max(bounds.left, bounds.right - width))
        let top = min(max(c.centerY - height / 2, bounds.top),
                      max(bounds.top, bounds.bottom - height))
        return CropRect(left: left, top: top, right: left + width, bottom: top + height)
    }

    /// 190 — the Δθ ≠ 0 half of `clampToView`: keep the **turned frame over the canvas**, and keep
    /// it findable.
    ///
    /// The frame the user sees at `degrees` is `effectiveCrop` projected through `CropTool.layout`;
    /// its four corners are a rotated quad. 092 fitted that quad's AABB into the canvas, 188 only
    /// kept its *centre* there — and read both from `mapping.viewport`, i.e. from the **view**.
    /// That is the bug this replaces: at 适应 the viewport is the whole canvas and the two readings
    /// agree, but at 1:1 or 2× it is a window onto the document, so the bound shrank to nothing and
    /// the frame could be dragged out of the canvas entirely.
    ///
    /// The bound is now a document fact (see `documentCanvas`): **at least a quarter of the frame's
    /// own area still covers the canvas**, and one grip is on the canvas. A frame that breaks it is
    /// *moved* back toward the canvas' centre at its own size — never shrunk (188's rule), and its
    /// ratio and `minimumSpan` are untouched. The photo bound stays `effectiveCrop`'s job.
    private func clampRotatedQuadToView(mapping: LoupeMapping, source: ImageSize,
                                        degrees: Double) -> Bool {
        // 132: the turned-quad clamp existed to keep the *photo-bound* frame on the canvas. With the
        // frame allowed outside the photograph and the camera re-fitting the whole canvas (see
        // `LoupeFraming.fitZoom`), shrinking the draft here was the 「第一次改角度框就没了」 report.
        // 162: the **canvas** is still a hard bound at an angle — the frame's turned quad may cover the
        // blank/camera-outside pixels, but its AABB may not leave the viewport. The photo-bound shrink
        // stays opt-in (`clampsToRotatedFrame`), unchanged from 132.
        let before = draft.crop.clamped(allowsOutsideSource: true)
        let angle = CropTool.clampStraighten(draft.straighten)
        func seen(_ rect: CropRect) -> CropRect {
            let c = rect.clamped(allowsOutsideSource: true)
            guard clampsToRotatedFrame, angle != 0 else { return c }
            return CropMath.clampedToRotatedFrame(c, in: source, degrees: angle,
                                                  keepsInsideRotatedFrame: true)
        }
        // 190 — **the bound is a document question.** 「How much of the frame still covers the
        // canvas」 is asked of the turned frame's own pixels: `canvas` is the photograph's AABB and
        // `documentQuad` is the four corners `CropTool.layout` projects, with the view's similarity
        // removed. Neither number knows about a viewport, a zoom or a window, so the limit cannot
        // move when the framing does — which is exactly what 188 got wrong: it asked the *view*
        // (`mapping.viewport`), and it agreed with the canvas only at 适应. At 1:1 and 2× the
        // viewport is a window onto the document, so 「the quad's centre is in the viewport」 became
        // an almost empty rule and the frame could be dragged until a tenth of it was left
        // (measured at 5.4°: 10.9 % of the frame on the canvas at 适应, 100 % at 1:1 and 2×).
        let canvas = documentCanvas(source: source, degrees: angle)

        /// 162 — the ratio lock is a document constraint and has to survive this clamp. Applied to
        /// the *size* about the frame's centre, so it never goes through `CropTool.constrain`'s
        /// `0…1²` clamp (which would forbid the camera-outside band).
        func withLock(_ rect: CropRect) -> CropRect {
            guard let ratio = draft.lock.ratio,
                  let aspect = CropTool.normalizedAspect(ratio, source: source),
                  rect.width > 0, rect.height > 0 else { return rect }
            var w = rect.width, h = rect.height
            if w / h > aspect { w = h * aspect } else { h = w / aspect }
            let left: Double = rect.centerX - w / 2
            let top: Double = rect.centerY - h / 2
            return CropRect(left: left, top: top, right: left + w, bottom: top + h)
                .clamped(allowsOutsideSource: true)
        }
        let shaped = withLock(before)
        let base = seen(shaped)
        let width = Double(max(source.width, 1)), height = Double(max(source.height, 1))

        /// The turned frame's bounding box in document pixels.
        func quadBox(_ rect: CropRect) -> CGRect {
            let corners = documentQuad(rect, source: source, degrees: angle)
            guard let minX = corners.map({ $0.x }).min(), let maxX = corners.map({ $0.x }).max(),
                  let minY = corners.map({ $0.y }).min(), let maxY = corners.map({ $0.y }).max()
            else { return .zero }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }

        /// 196 (user 2026-10-31) — **the canvas is a hard bound again.** 190 read the user's
        /// 「框可以超出扩大后的画布」 as an area rule (≥25 % of the frame still over the canvas);
        /// the user has since reversed that: the frame may **not** leave the canvas at all, it may
        /// only leave the *photograph* (the rotated-out `000000` corners, and the canvas inside the
        /// photograph's edge). So the law is 162's again, stated on the **turned quad**: all four
        /// sides inside `canvasBounds`, which is the canvas in document pixels and therefore does
        /// not move with the zoom, the window or the framing (190's own finding, kept).
        ///
        /// Half a document pixel of slack: the overlay and the present round to whole pixels, and a
        /// frame that is *at* the edge must not be pulled back by the rounding.
        let containmentTolerance = 0.5
        func legal(_ rect: CropRect) -> Bool {
            let box = quadBox(rect)
            return box.minX >= canvas.minX - containmentTolerance
                && box.maxX <= canvas.maxX + containmentTolerance
                && box.minY >= canvas.minY - containmentTolerance
                && box.maxY <= canvas.maxY + containmentTolerance
        }

        // **Move, never shrink — until the frame genuinely cannot fit.** 188 deleted the
        // `0…1²`-room search and it is not coming back: a legal-size frame is *translated* the least
        // amount that puts its turned box inside the canvas. Only a frame whose turned box is
        // larger than the canvas is shrunk, uniformly about its centre, and that is 162's own rule
        // (`clampedToCanvas`), not a new one.
        func pulledBack() -> CropRect {
            var rect = base
            var box = quadBox(rect)
            let shrink = min(1, canvas.width / max(box.width, 1e-9),
                             canvas.height / max(box.height, 1e-9))
            if shrink < 1 {
                let w = rect.width * shrink, h = rect.height * shrink
                rect = CropRect(left: rect.centerX - w / 2, top: rect.centerY - h / 2,
                                right: rect.centerX + w / 2, bottom: rect.centerY + h / 2)
                    .clamped(allowsOutsideSource: true)
                box = quadBox(rect)
            }
            var dx = 0.0, dy = 0.0
            if box.minX < canvas.minX { dx = canvas.minX - box.minX }
            else if box.maxX > canvas.maxX { dx = canvas.maxX - box.maxX }
            if box.minY < canvas.minY { dy = canvas.minY - box.minY }
            else if box.maxY > canvas.maxY { dy = canvas.maxY - box.maxY }
            guard dx != 0 || dy != 0 else { return rect }
            // The quad is rigid: `documentQuad` puts a rect in document pixels through `R(−θ)`, so a
            // move of `d` in document pixels is `R(θ)·d` in the rect's own coordinates.
            let local = CropGeometry.RotationMatrix(degrees: angle).apply(x: dx, y: dy)
            let left = rect.left + local.x / width, top = rect.top + local.y / height
            return CropRect(left: left, top: top, right: left + rect.width,
                            bottom: top + rect.height)
                .clamped(allowsOutsideSource: true)
        }

        // The frame already satisfies the law: the only thing that may still have to be written back
        // is the **lock's reshape** (162 — a document constraint, not a canvas one). Otherwise the
        // stored rect stays bit for bit, so reducing the angle to 0° gives the whole frame back.
        if legal(base) {
            // 132: the opt-in photo bound (`clampsToRotatedFrame`) is a **view** fact — it lives in
            // `effectiveCrop` and must not reach the stored draft, so the pre-bound `shaped` is what
            // is written back here. `base` is only read to *test* the canvas law against it.
            guard shaped != before else { return false }
            draft.crop = shaped
            return true
        }

        var next = pulledBack()
        // 190 — `seen()` is the opt-in **photo-bound** shrink (`clampsToRotatedFrame`), and a shrink
        // is a view: it may not undo the canvas law that was just satisfied. Re-check it here and
        // refuse a shrink that breaks the law (宁可不缩), so no path can hand back a rect that
        // fails `legal`.
        if clampsToRotatedFrame, angle != 0 {
            let shrunk = seen(next)
            if legal(shrunk) { next = shrunk }
        }
        guard next != before else { return false }
        draft.crop = next
        return true
    }

    // MARK: - the document-space canvas (190)

    /// The smallest fraction of the frame that must keep covering the canvas. 25 % is the user's
    /// 「最多 3/4 出去」: the frame may leave the expanded canvas, but not so far that it stops being
    /// a frame *of* that canvas.
    static let canvasCoverageFloor: Double = 0.25

    /// The canvas in **document pixels**: the turned photograph's AABB, centred on the source's
    /// centre — the region the workspace calls 画布, with the letterbox being the viewport's
    /// business. Built from the photo and the angle alone, which is what makes every number derived
    /// from it (the 25 % floor, the pull-back) a property of the document rather than of a framing.
    private func documentCanvas(source: ImageSize, degrees: Double) -> CGRect {
        let w = Double(max(source.width, 1)), h = Double(max(source.height, 1))
        let extent = LoupeFraming.rotatedExtent(width: w, height: h, degrees: degrees)
        return CGRect(x: (w - extent.width) / 2, y: (h - extent.height) / 2,
                      width: extent.width, height: extent.height)
    }

    /// |frame ∩ canvas| / |frame| in document pixels. `rect` is the frame in normalized source
    /// coordinates, `canvas` the turned photograph's AABB, so the answer is a property of the
    /// document: **the same number at every zoom**, which is the whole of 190.
    private func canvasCoverage(_ rect: CropRect, canvas: CGRect, source: ImageSize,
                                degrees: Double) -> Double {
        let clipped = Self.clipped(documentQuad(rect, source: source, degrees: degrees), to: canvas)
        guard clipped.count >= 3 else { return 0 }
        var twice = 0.0
        for index in clipped.indices {
            let a = clipped[index], b = clipped[(index + 1) % clipped.count]
            twice += Double(a.x) * Double(b.y) - Double(b.x) * Double(a.y)
        }
        let w = Double(max(source.width, 1)), h = Double(max(source.height, 1))
        let own = rect.width * w * rect.height * h
        return own > 0 ? abs(twice) / 2 / own : 0
    }

    /// 190 — `canvasCoverage` for a rect at the draft's current angle, in document pixels. Exposed
    /// (internal) for the reverse gate: `CropBoundsTests` states the bound 190 puts on a drag in the
    /// same units the clamp uses, instead of comparing against the *visible* canvas — which at a
    /// zoom is a window and is exactly the confusion 188 fell into.
    func canvasCoverage(of rect: CropRect, source: ImageSize? = nil) -> Double {
        let src = source ?? sourceSize
        let degrees = CropTool.clampStraighten(draft.straighten)
        return canvasCoverage(rect, canvas: documentCanvas(source: src, degrees: degrees),
                              source: src, degrees: degrees)
    }

    /// **Diagnostic only — not part of the law.** `true` when a corner of the frame is on the canvas,
    /// or the canvas' centre is inside the frame. 188 used a viewport version of this as a *clamp*
    /// and that is what made the limit move with the zoom (see `legal`): it is printed by the tests
    /// to show where the frame's centre sits, and nothing may branch on it.
    func hasReachableGrip(_ rect: CropRect, source: ImageSize? = nil) -> Bool {
        let src = source ?? sourceSize
        let degrees = CropTool.clampStraighten(draft.straighten)
        return reachableGrip(rect, canvas: documentCanvas(source: src, degrees: degrees),
                             source: src, degrees: degrees)
    }

    private func reachableGrip(_ rect: CropRect, canvas: CGRect, source: ImageSize,
                               degrees: Double) -> Bool {
        let corners = documentQuad(rect, source: source, degrees: degrees)
        let tolerance = 1e-6
        if corners.contains(where: {
            $0.x >= canvas.minX - tolerance && $0.x <= canvas.maxX + tolerance
                && $0.y >= canvas.minY - tolerance && $0.y <= canvas.maxY + tolerance
        }) { return true }
        // Convex polygon, consistent winding: one sign for every cross product means "inside".
        guard corners.count == 4 else { return false }
        let centre = CGPoint(x: canvas.midX, y: canvas.midY)
        var positive = false, negative = false
        for index in corners.indices {
            let a = corners[index], b = corners[(index + 1) % corners.count]
            let cross = Double(b.x - a.x) * Double(centre.y - a.y)
                - Double(b.y - a.y) * Double(centre.x - a.x)
            if cross > 1e-9 { positive = true }
            if cross < -1e-9 { negative = true }
            if positive && negative { return false }
        }
        return true
    }
    /// The frame's four corners in document pixels — `CropTool.layout`'s quad with the view's
    /// similarity removed. `imagePoint` there is `centre + R(−θ)·(corner − centre)`, so this is the
    /// same arithmetic on the same numbers.
    private func documentQuad(_ rect: CropRect, source: ImageSize, degrees: Double) -> [CGPoint] {
        let w = Double(max(source.width, 1)), h = Double(max(source.height, 1))
        let rotation = CropGeometry.RotationMatrix(degrees: degrees.isFinite ? degrees : 0)
        func image(_ u: Double, _ v: Double) -> CGPoint {
            let turned = rotation.invert(x: u * w - w / 2, y: v * h - h / 2)
            return CGPoint(x: w / 2 + turned.x, y: h / 2 + turned.y)
        }
        return [image(rect.left, rect.top), image(rect.right, rect.top),
                image(rect.right, rect.bottom), image(rect.left, rect.bottom)]
    }

    /// Sutherland–Hodgman: a convex polygon clipped to an axis-aligned rectangle.
    private static func clipped(_ polygon: [CGPoint], to rect: CGRect) -> [CGPoint] {
        let edges: [(CGPoint, CGPoint)] = [
            (CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY)),
            (CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY)),
            (CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)),
            (CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.minY)),
        ]
        var output = polygon
        for (a, b) in edges where !output.isEmpty {
            func inside(_ p: CGPoint) -> Bool {
                (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x) >= 0
            }
            func crossing(_ p: CGPoint, _ q: CGPoint) -> CGPoint {
                let dx = q.x - p.x, dy = q.y - p.y
                let ex = b.x - a.x, ey = b.y - a.y
                let denominator = dx * ey - dy * ex
                guard abs(denominator) > 1e-12 else { return q }
                let t = ((a.x - p.x) * ey - (a.y - p.y) * ex) / denominator
                return CGPoint(x: p.x + dx * t, y: p.y + dy * t)
            }
            var next: [CGPoint] = []
            for index in output.indices {
                let current = output[index]
                let previous = output[(index + output.count - 1) % output.count]
                let currentIn = inside(current), previousIn = inside(previous)
                if currentIn {
                    if !previousIn { next.append(crossing(previous, current)) }
                    next.append(current)
                } else if previousIn {
                    next.append(crossing(previous, current))
                }
            }
            output = next
        }
        return output
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
                                                       pointScale: scale,
                                                       rotationDegrees: straightenDelta)
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
                                                             source: source, pointScale: scale,
                                                             rotationDegrees: straightenDelta)
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
        // 162 §2.3 — a drag is the one path that can put the frame outside the canvas; the hard
        // boundary is applied on the tick itself (not only on the next camera change), so the stored
        // rect and the drawn rect are the same legal four edges at all times.
        _ = clampToView(mapping: mapping, source: source)
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
    ///
    /// 088 — the inverse of `CropTool.layout`'s composite: view → image space through the document
    /// framing (`framePoint`, which is what the pixels on screen are laid out with), then turn the
    /// point back by `+θ − θ₀` about the image centre, and only then compare it with `rect`.
    static func normalized(_ point: CGPoint, mapping: LoupeMapping, source: ImageSize,
                           pointScale: Double,
                           rotationDegrees: Double = 0) -> NormalizedPoint? {
        let scale = pointScale > 0 ? pointScale : 1
        // **Frame space** (`framePoint`), not `sourcePoint`: the draft rect is a rect of the
        // straightened frame, so a grip dragged on screen has to move the edge that is under the hand.
        // Going through the rotating map turned every drag of a straightened picture into an arc
        // (and, while the projection was anisotropic, into a skew).
        let p = mapping.framePoint(viewX: Double(point.x) * scale,
                                   viewY: Double(point.y) * scale)
        guard p.x.isFinite, p.y.isFinite else { return nil }
        let w = Double(max(source.width, 1)), h = Double(max(source.height, 1))
        guard rotationDegrees.isFinite, rotationDegrees != 0 else {
            return NormalizedPoint(p.x / w, p.y / h)
        }
        // 123: the one rotation matrix (`CropGeometry.RotationMatrix`) — this file no longer spells
        // its own `cos`/`sin`.
        let rotation = CropGeometry.RotationMatrix(degrees: rotationDegrees)
        let dx = p.x - w / 2, dy = p.y - h / 2
        let turned = rotation.apply(x: dx, y: dy)
        return NormalizedPoint((w / 2 + turned.x) / w, (h / 2 + turned.y) / h)
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
