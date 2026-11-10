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
        /// 246 — the document's keystone, carried through the crop session so the red-frame
        /// predicate and 应用 both see the picture the user is looking at.
        public var perspectiveVertical: Double = 0
        public var perspectiveHorizontal: Double = 0
        /// 330 — the space `crop` is measured in. `.canvas` for any document that carries a keystone
        /// (the crop is a rectangle of the document canvas); `.source` for everything else, which is
        /// where the two spaces are the same picture anyway.
        public var cropSpace: CropSpace = .source

        public init(crop: CropRect = .full, straighten: Double = 0, lock: AspectLock = .original,
                    perspectiveVertical: Double = 0, perspectiveHorizontal: Double = 0,
                    cropSpace: CropSpace = .source) {
            self.crop = crop
            self.straighten = straighten
            self.lock = lock
            self.perspectiveVertical = perspectiveVertical
            self.perspectiveHorizontal = perspectiveHorizontal
            self.cropSpace = cropSpace
        }

        public var perspective: PerspectiveMap? {
            guard perspectiveVertical != 0 || perspectiveHorizontal != 0 else { return nil }
            return PerspectiveMap(vertical: perspectiveVertical,
                                  horizontal: perspectiveHorizontal)
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
                          quarterTurns: document.quarterTurns,
                          perspectiveVertical: perspectiveVertical,
                          perspectiveHorizontal: perspectiveHorizontal,
                          cropSpace: cropSpace)
        }

        public init(geometry: GeometryGroup) {
            // 224 — the draft is a rect of the document canvas: a legacy document carrying an
            // out-of-canvas crop is shown (and edited) from its legal rect, never outside it.
            self.init(crop: geometry.cropRect.clamped(),
                      straighten: geometry.straightenDegrees,
                      lock: geometry.aspectLock,
                      perspectiveVertical: geometry.perspectiveVertical,
                      perspectiveHorizontal: geometry.perspectiveHorizontal,
                      cropSpace: geometry.cropSpace)
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

    /// The 803aff6 "框必须内切于旋转后的照片" rule — **off since 307**, back on 132's contract.
    ///
    /// 301 turned it on because the output canvas *was* the crop frame, so a frame reaching into the
    /// turned photo's black corners would have put black into the export. 307 separates the two
    /// canvases (`CanvasRole`): the interaction canvas is the turned **whole photograph's AABB**, and
    /// the user's rule for it is 「裁剪框可以拖到 00 的文档画布里，不能拖到 0F 的背景遮罩里」. So the
    /// frame may sit in the black corners (`000000`, inside the canvas) and is stopped by
    /// `CropTool.clampToCanvas` at the canvas edge — never by the photograph's turned quad, which is
    /// what made the limit feel like 「照片像素」.
    ///
    /// The export needs no black corner either: moving the straighten from 0 to θ **once** inscribes
    /// the draft (`setAngle(uiValue:)`), so the rect 应用 writes is inside the turned picture by
    /// construction. A test flips this to `true` to prove the old containment behaviour is still
    /// reachable.
    var clampsToRotatedFrame = false

    // MARK: 317 — 「不出像素」 (a UI preference, never a document field)

    /// The preference's key — `false` (307's behaviour) for every library that never ticked the box.
    public static let staysInsidePixelsKey = "photons.cropStaysInsidePixels"

    /// Where the box is remembered. Injected so a test can point at its own suite; the app gets
    /// `UserDefaults.standard`, the same store `CropToolBar.lastCustomRatioText` uses.
    private let defaults: UserDefaults

    /// The checkbox's state. Stored (not a computed read of `defaults`) so `@Observable` redraws the
    /// card when it changes; `defaults` is written on every change and re-read by `begin()`.
    private var staysInsidePixelsStorage = false

    /// 317 — **「不出像素」**: while this is on, a moved frame is stopped by the **rotated
    /// photograph's pixels**, not by the document canvas.
    ///
    /// Two behaviours, and they are the user's two sentences:
    ///
    ///   · off (the default, 307) — the frame may be dragged into the canvas' black corners
    ///     (`000000`) and is stopped only at the canvas edge;
    ///   · on — the frame's four corners stay inside the turned photo's quad. A **move** is a
    ///     projection of the translation onto that convex set (§`placedInsidePixels`): it slides and
    ///     stops, and it never resizes (310). Only a frame that no translation can hold — a full
    ///     frame at 45° — is inscribed, once, at the moment the box is ticked or the angle changes.
    ///
    /// Persisted, so it survives `setAngle`, a photo switch and a re-opened tool; the value is read
    /// back in `begin()` rather than kept alive by a second copy in the card.
    public var cropStaysInsidePixels: Bool {
        get { staysInsidePixelsStorage }
        set { setCropStaysInsidePixels(newValue) }
    }

    /// The card's write path. Returns `true` when the state actually changed (the reverse gate and
    /// the acceptance read it; a click that repeats the state is a no-op).
    @discardableResult
    public func setCropStaysInsidePixels(_ on: Bool) -> Bool {
        defaults.set(on, forKey: Self.staysInsidePixelsKey)
        guard on != staysInsidePixelsStorage else { return false }
        staysInsidePixelsStorage = on
        // §3.5 — the only moment this preference may shrink the frame, and only when it must.
        if on { inscribeIntoPixelsIfNeeded() }
        draftChanged()
        return true
    }

    /// 310 — `true` re-attaches the ratio lock's reshape to the **`.inside`** drag; the reverse gate
    /// only, the app never sets it. The shipped behaviour is `false`: a frame moved by its inside is
    /// translated, never resized (the lock constrains the handles and a new frame, not the move).
    var reshapesLockOnInsideDrag = false

    /// 310 — how many times `CropTool.clampToCanvas`'s **shrink** branch fired (the only place the
    /// canvas is allowed to change a frame's size). The claim of 310 is that moving a frame never
    /// needs it; the tests assert 0 for a whole drag, which is what makes «到边只停住» measurable
    /// instead of merely plausible.
    public private(set) var canvasShrinkTicks = 0

    /// 310 — **the move owns the size.** Set when a drag starts on the frame's inside, cleared by
    /// every gesture that is *about* a size (a grip, a new frame, a ratio preset, a straighten).
    ///
    /// While it is set, neither the drag tick nor the ⑦ refresh (`clampToView`, which the app calls
    /// on every `refreshCropTool`) may re-shape the rect to `draft.lock`. That is the whole of the
    /// user's rule: 「拖动裁剪框裁剪框大小不变」 — the lock is what a *sizing* gesture honours, not a
    /// constraint that silently re-cuts a frame the user is carrying across the canvas. The flag
    /// deliberately survives the mouse-up: a refresh one turn later would otherwise undo the drag.
    private var lockReshapeSuspended = false

    public init(session: CatalogSession?, defaults: UserDefaults = .standard) {
        self.session = session
        self.defaults = defaults
        self.staysInsidePixelsStorage = defaults.bool(forKey: Self.staysInsidePixelsKey)
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
        (session?.edit.geometry ?? GeometryGroup.identity).orientedSource(uprightSource)
    }

    /// The photo's **own** frame, before the document's quarter turn — what `CropGeometry` wants.
    ///
    /// 2026-11-01: `CropGeometry.init(geometry:source:)` applies `orientedSource` itself, so handing
    /// it `sourceSize` (already turned) swapped the two dimensions a second time at 90°/270°: the crop
    /// tool's `source`, `frameSize` and `canvas` then described the *un-turned* document while
    /// `RenderGraph` described the turned one — the frame's aspect, its pixel readout and its canvas
    /// disagreed with the picture being rendered, and only at odd quarter turns.
    private var uprightSource: ImageSize {
        session?.maskSourceSize ?? ImageSize(width: 1, height: 1)
    }

    // MARK: 123 — the one transform value

    /// The draft as the transform session sees it: the document's flips and quarter turn plus the
    /// draft's crop, angle and lock. This value type owns the UI→document angle mapping; nothing in
    /// the card does trigonometry.
    public var transformSession: TransformSession {
        TransformSession(geometry: draftGeometry, source: uprightSource)
    }

    /// Same value under the shorter name the panel reads.
    public var transform: TransformSession { transformSession }

    /// The geometry both the overlay and the renderer consume. The rotation matrix lives here, so a
    /// second caller cannot pick a different sign. The crop is `effectiveCrop` — the rect the overlay
    /// actually draws and `finish(.confirm)` writes — not the stored intent behind it.
    public var cropGeometry: CropGeometry {
        if !isActive, let session {
            return CropGeometry(geometry: session.edit.geometry, source: uprightSource)
        }
        return CropGeometry(geometry: effectiveGeometry(draftGeometry), source: uprightSource)
    }

    /// The overlay draws against the **un-turned** document while the slider is dragged (088), so it
    /// needs the delta between the draft and the committed angle — still derived from the session's
    /// geometry, never re-derived with its own `cos`/`sin`.
    public var overlayGeometry: CropGeometry {
        var delta = effectiveGeometry(draftGeometry)
        delta.rotationDegrees = CropTool.clampStraighten(draft.straighten)
            - CropTool.clampStraighten(session?.edit.geometry.straightenDegrees ?? 0)
        return CropGeometry(geometry: delta, source: uprightSource)
    }

    /// The draft's geometry with the document's flips and quarter turn carried (the same value
    /// `apply()` writes).
    private var draftGeometry: GeometryGroup {
        var group = draft.geometry(flipsOf: session?.edit.geometry ?? GeometryGroup.identity)
        // 327 — the keystone is the document's while a crop session is open (see `effectiveGeometry`).
        group.perspectiveVertical = livePerspective?.vertical ?? 0
        group.perspectiveHorizontal = livePerspective?.horizontal ?? 0
        return group
    }

    /// The draft with the crop replaced by the rect the overlay drew (`effectiveCrop`), and with the
    /// **document's** keystone.
    ///
    /// 327 — `draft.perspectiveVertical/Horizontal` are a copy taken at `begin()`, while the 变换 card's
    /// two sliders write the **document** (`TransformPanel`: `session.applyEdit { … }`). Every other
    /// reader in this file already follows the live document (`livePerspective`: the red-frame
    /// predicate, both clamps, the inscription, the overlay), so a keystone dragged with 裁切 open was
    /// visible on screen and then **overwritten with the stale copy by 应用** — the picture came out
    /// flat. The write takes the same answer as the preview, in one place.
    private func effectiveGeometry(_ geometry: GeometryGroup) -> GeometryGroup {
        var geometry = geometry
        geometry.perspectiveVertical = livePerspective?.vertical ?? 0
        geometry.perspectiveHorizontal = livePerspective?.horizontal ?? 0
        geometry.crop = effectiveCrop(source: sourceSize)
            .clamped(allowsOutsideSource: true).normalizedRect
        return geometry
    }

    /// The draft's keystone **and the space its rect is measured in**, brought onto the document's —
    /// the one writer of those two copies.
    ///
    /// 327 — the 变换 card's two sliders write the **document**, so the draft's copy (taken at
    /// `begin()`) is only ever a mirror. 341 — that mirror used to be `livePerspective`'s *fallback*
    /// whenever the document had no keystone, which is exactly the state a reset leaves behind: the
    /// document said 0, the draft still said 40, and every reader kept answering 40. The document is
    /// the authority now (`livePerspective` / `liveCropSpace`); this keeps the copy itself in step, so
    /// the draft the bar, the readout and 应用 see is the *same* 0 — and the `.source` space that comes
    /// back with a keystone-free document — instead of the picture before the reset.
    ///
    /// Every document write reaches it through the overlay's one rebuild point
    /// (`LoupeController.syncCropOverlay`) and every clamp refresh (`clampToView`), so the slider, the
    /// double-click, ⌘Z and a preset all land here without a per-entry hook. Returns whether the draft
    /// moved (a reset did), never whether the document did.
    ///
    /// Internal so the 341 acceptance can drive the same turn the loupe does.
    @discardableResult
    func adoptDocumentKeystone() -> Bool {
        guard isActive else { return false }
        let live = livePerspective
        var next = draft
        next.perspectiveVertical = live?.vertical ?? 0
        next.perspectiveHorizontal = live?.horizontal ?? 0
        next.cropSpace = liveCropSpace
        guard next != draft else { return false }
        draft = next                     // one write: one `publishDraft`, no half-synced turn
        return true
    }

    /// The geometry `finish(.confirm)` writes: the draft's fields, with the crop replaced by the one
    /// the overlay actually drew (`effectiveCrop` — the rect inscribed in the turned frame).
    private func committedGeometry(for document: GeometryGroup) -> GeometryGroup {
        effectiveGeometry(draft.geometry(flipsOf: document))
    }

    /// The slider's value in the UI's own convention: positive = clockwise.
    public var angleUIValue: Double { CropTool.clampStraighten(draft.straighten) }

    /// The rect the **straighten** is measured against: the draft's frame as it stood when the angle
    /// left 0°. Every 0 → θ inscription is taken from this base, not from the rect the previous tick
    /// produced, so a 150-tick slider drag shrinks the frame **once**, not 150 times. A manual crop
    /// drag clears it, so a later angle change is cut from what the user just set.
    private var straightenBaseCrop: CropRect?

    /// 123 — the one UI→document angle write. `TransformSession.setAngle(uiValue:)` chooses the
    /// sign; this method only carries its answer into the draft.
    ///
    /// **307 — the one-shot inscription.** Pulling the straighten away from 0° cuts the frame into
    /// the turned photograph (`clampsToRotatedFrame(keepsInsideRotatedFrame: true)`), and writes that
    /// rect into the **draft** — so 「应用」 records the inscribed frame as the document's crop and the
    /// export has no black corner (measured 0.000 %). It is deliberately *not* a standing clamp:
    /// `clampsToRotatedFrame` is `false`, so once the angle holds still the frame may be dragged into
    /// the black corners of the document canvas (000000, still inside the canvas) — the user's
    /// 「裁剪框可以拖到 00 的文档画布里」. Only the canvas edge stops it, in `CropTool.clampToCanvas`.
    public func setAngle(uiValue: Double) {
        var session = TransformSession(geometry: draftGeometry, source: uprightSource)
        session.setAngle(uiValue: uiValue)
        writeStraighten(session.draft.straightenDegrees)
    }

    /// The **one** draft-angle write: the slider (`setAngle`), the ⌘-drag release
    /// (`commitStraighten`) and 328's 画线拉直 all come out here, so the 307 one-shot inscription,
    /// the 310 lock re-arm and the 317 「不出像素」 question happen exactly once per value.
    private func writeStraighten(_ degrees: Double) {
        let previous = draft.straighten
        let next = CropTool.clampStraighten(degrees)
        draft.straighten = next
        // 310 — turning the picture re-inscribes the frame, so it *is* a sizing gesture: re-arm the
        // lock's reshape (the inscription keeps the rect's own ratio and the canvas keeps the size).
        lockReshapeSuspended = false
        if next != 0 {
            if previous == 0 || straightenBaseCrop == nil {
                straightenBaseCrop = draft.crop.clamped(allowsOutsideSource: true)
            }
            if let base = straightenBaseCrop {
                draft.crop = CropMath.clampedToRotatedFrame(base, in: sourceSize, degrees: next,
                                                            keepsInsideRotatedFrame: true)
            }
        } else {
            // Back to upright: the frame is legal as it stands, and the next lift cuts from it.
            straightenBaseCrop = nil
        }
        // 317 — 「改角度之后」: the same one-shot question as the checkbox (307 has already inscribed
        // into the turned quad, so with the box on this is usually a no-op — it exists for the angle
        // pairs where it is not).
        inscribeIntoPixelsIfNeeded()
        draftChanged()
    }

    /// The canvas the draft will produce, in pixels — the **export** canvas (the crop frame, 301).
    public var effectiveCanvas: ImageSize { cropGeometry.canvas }

    /// 307 — **which canvas the screen is showing**: the document canvas while 裁切 is on (the turned
    /// whole photograph's AABB, `000000` in its corners, `0F` outside it), the export canvas otherwise.
    ///
    /// One decision, read by the projection (`LoupeFraming`), the transform (`FrameTransform`) and the
    /// renderer (`RenderOptions.canvasRole`) — the three places 301/301b had drifted apart. The crop
    /// tool always hands the canvas `crop == .full` (`canvasEdit`), so the frame *is* the photograph
    /// and the document role's centred inset is exact, not an approximation.
    public var canvasRole: CanvasRole { isActive ? .document : .export }

    // MARK: the draft's rect, as the turned picture allows it

    /// `draft.crop` **as the straightened picture allows it**: the stored rect shrunk — centre and
    /// pixel aspect kept — until it is fully inscribed in the sensor's turned quad
    /// (`CropMath.clampedToRotatedFrame`).
    ///
    /// **Space (248).** The return value is a `CropRect` in the **turned photo's normalized
    /// coordinates** — the same space `GeometryGroup.crop` and S0's `p.c` are measured in, after the
    /// quarter turn and before the straighten. It is *not* a canvas rect: the renderer turns the
    /// **whole photograph** about its centre (`P + R(photo − P)`, `s0_geometry.metal`) and cuts this
    /// window out of that turned picture; the overlay draws the same window through `LoupeMapping`,
    /// whose rotation pivot is also `frameWidth/2`. `应用` can therefore write this value straight
    /// into `geometry.crop` — the two paths use one space and one pivot.
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
        // 246 §2.3 — the picture is a **quadrilateral** once a keystone is on; the predicate reads
        // `CropGeometry`'s one definition of it, never an AABB.
        // 341 — **the live document's** keystone, through the one accessor: asking
        // `session…perspective ?? draft.perspective` here was the second copy of the bug below (a
        // reset document's `nil` fell back to the 40 the draft still carried, so a frame that only
        // the keystone put outside stayed red after the reset).
        let perspective = livePerspective
        // 330 — a canvas-spaced frame's export canvas **is** the rect, so 「出照片」 is its four
        // document corners against the photo **quad** (the same region the 勾选 clamp uses).
        if liveCropSpace == .canvas {
            let geometry = draftCropGeometry(source: src, perspective: perspective)
            let region = DocumentRegion(geometry.photoQuad())
            let e = geometry.photoQuadExtent
            let rect = effectiveCrop(source: src, degrees: angle)
            return ![(rect.left, rect.top), (rect.right, rect.top),
                     (rect.right, rect.bottom), (rect.left, rect.bottom)]
                .allSatisfy { region.inset(DocumentPoint($0.0 * e.width, $0.1 * e.height)) >= -1e-9 }
        }
        return CropMath.frameExceedsPicture(effectiveCrop(source: src, degrees: angle),
                                            in: src, degrees: angle,
                                            perspective: perspective)
    }

    /// 317 — **the one place 「不出像素」 may change a size.**
    ///
    /// Called when the box is ticked and after an angle change, never per tick. It asks the one
    /// question the preference asks of a frame: *is there any translation of this size that fits?*
    /// (`CropMath.pixelTranslationLimit`). If there is, nothing happens — field for field, which is
    /// §3.4: a 10 %-inset frame at 0° or 9° must come out of the toggle byte-identical. If there is
    /// not — a full frame at 45°, whose diagonal is wider than the picture on both axes — the frame
    /// is inscribed **once**, with 307's own arithmetic (`clampedToRotatedFrame(keepsInside…: true)`:
    /// same centre when it can, same pixel aspect, the largest rect that fits). Because it is a
    /// **discrete** step (072/077's rule for a flip or a turn), the tool session is closed and
    /// reopened around it, so 应用 records the inscribed frame as its own row instead of folding it
    /// into a drag that is still in flight.
    private func inscribeIntoPixelsIfNeeded() {
        guard staysInsidePixelsStorage, isActive else { return }
        let src = sourceSize
        let angle = CropTool.clampStraighten(draft.straighten)
        let current = draft.crop.clamped(allowsOutsideSource: true)
        let inscribed: CropRect
        if liveCropSpace == .canvas {
            // 330 — the export canvas *is* the rect, so 「放得下」 is its four document corners against
            // the photo quad. One-shot inscription, same law as 324's, in canvas coordinates.
            guard frameExceedsPicture(source: src, degrees: angle) else {
                return                          // 放得下：一毫米都不动
            }
            let geometry = draftCropGeometry(source: src, perspective: livePerspective)
            inscribed = geometry.inscribedInPhotoQuad(current)
        } else if let perspective = livePerspective, perspective.hasWarp {
            // 324 — a keystoned frame is a quadrilateral, so "can this frame be kept at all?" is the
            // export question (`frameSize == canvas`, 246): the frame's AABB must lie inside the
            // photo quad, or the file gets black corners. The one-shot inscription is the largest
            // rect of the frame's own shape whose canvas does.
            guard CropMath.frameExceedsPicture(current, in: src, degrees: angle,
                                               perspective: perspective) else {
                return                          // 放得下：一毫米都不动
            }
            let geometry = draftCropGeometry(source: src, perspective: perspective)
            inscribed = geometry.inscribedInPhotoQuad(current)
        } else {
            guard !CropMath.pixelTranslationLimit(of: current, in: src, degrees: angle).isFeasible else {
                return                          // 放得下：一毫米都不动
            }
            inscribed = CropMath.clampedToRotatedFrame(current, in: src, degrees: angle,
                                                       keepsInsideRotatedFrame: true)
        }
        guard inscribed != current else { return }
        draft.crop = inscribed
        // 356 — **nothing else.** This used to close and reopen the tool session here so that the
        // inscribed frame got its own row instead of folding into a drag still in flight. That made
        // the *history* decide how many rows one gesture left, and — because a row is what ⌘Z
        // restores — what the document looked like afterwards. The geometry above is one line and
        // it is unconditional: the rect is the same whether or not a session is open. The row is
        // closed by whoever called this: the gesture's own mouse-up (`endDrag`) or the non-gesture
        // writer, which closes the session *before* it writes.
    }

    /// 317 — **the four-corner law as a write**: with 「不出像素」 on, any rect about to become the
    /// draft is **translated** into the turned photograph (never resized — 310; the size question is
    /// `inscribeIntoPixelsIfNeeded`'s, and it fires only at the two moments above).
    ///
    /// A frame that fits nowhere is handed back unchanged rather than shrunk: a move must not resize,
    /// and §3b leaves the out-of-bounds frame visible — the overlay paints it red through 307's
    /// `frameExceedsPicture`, no new colour and no backdrop change.
    private func placedInsidePixels(_ rect: CropRect, source: ImageSize) -> CropRect {
        guard staysInsidePixelsStorage else { return rect }
        let angle = CropTool.clampStraighten(draft.straighten)
        // 330 — a canvas-spaced rect: the photo quad's four half-planes, the frame's four axis-aligned
        // corners (`documentQuad`), one translation. Covers the keystone-reset case too, where a
        // canvas-spaced crop has no warp but is still measured on the canvas.
        if liveCropSpace == .canvas {
            let geometry = draftCropGeometry(source: source, perspective: livePerspective)
            return geometry.translatedInsidePhotoQuad(rect, tolerance: 1e-9) ?? rect
        }
        // 324 — a keystoned picture is a **quadrilateral**: the four half-planes are its edges, not a
        // turned rectangle's. One reader (`CropGeometry.photoQuad()`), one translation.
        if let perspective = livePerspective, perspective.hasWarp {
            let geometry = draftCropGeometry(source: source, perspective: perspective)
            return geometry.translatedInsidePhotoQuad(rect, tolerance: 1e-9) ?? rect
        }
        return CropMath.translatedInsidePixels(rect, in: source, degrees: angle) ?? rect
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
        // 341 — the geometry 应用 would write, through the same one owner: the old two lines built
        // the value from `draft.geometry(…)` and only replaced the crop, so the row kept printing the
        // keystone the *draft* was seeded with after the document's had been reset to 0.
        session.cropToolDraft = (id, committedGeometry(for: session.edit.geometry))
    }

    // MARK: 356 — the tool session belongs to a gesture

    /// Open the session a **gesture** owns: a mouse-down on the frame, a grip, or the 转动 handle.
    ///
    /// Anything a previous gesture left open is closed first, so this gesture's row can never be
    /// folded into — or silently swallowed by — it. Both doors are the same call whether or not a
    /// session is open, which is the point: `beginSession` ignores a second open and `endSession`
    /// answers `nil` without one, so nothing here needs to ask the history what it contains.
    private func openGestureSession() {
        closeToolSession(label: "裁切与旋转")
        session?.beginToolSession("裁切", label: "裁切与旋转")
    }

    /// Close the session, writing **one** row for what it changed (`base → edit`), or nothing when it
    /// changed nothing. A no-op when no session is open.
    ///
    /// Every non-gesture write in this file calls this **before** it touches the document (双击复位,
    /// ⌘Z, 粘贴, 引导线应用, 内切, 翻转, 90° 旋转): a session is a gesture's, and a command is not one.
    private func closeToolSession(label: String? = nil) {
        _ = session?.endToolSession(label: label)
    }

    /// The mouse-up half of a gesture that shrank its own row: close the session, and when the entry
    /// was driven without one (a slider tick, a preset, an internal commit) fall back to the ordinary
    /// single commit. One row either way — the caller never asks which case it is.
    @discardableResult
    private func closeGestureSession(label: String) -> Bool {
        guard let session else { return false }
        if session.endToolSession(label: label) { return true }
        return session.commitEdit(label: label, coalesce: false)
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
        // 330 — **a keystoned document is cropped on its canvas.** The stored rect may still be the
        // pre-330 photo-space one (the file is migrated where its pixels are known); the draft must
        // hold the *effective* rect so its numbers and its space agree from the first tick, or the
        // overlay would draw a rectangle read from the wrong coordinates.
        if session.edit.geometry.perspective?.hasWarp == true {
            let effective = CropGeometry(geometry: session.edit.geometry, source: sourceSize)
            // …and the rect itself is converted here (`canvasRect(fromSource:)` is the migration's own
            // arithmetic), so the draft's numbers and its space agree from the first tick.
            draft.crop = effective.canvasRect(fromSource: effective.crop)
            draft.cropSpace = .canvas
        }
        draftPhotoID = session.anchorID
        // 317 — 「重开工具保持」: the box is a preference, so it is read back here rather than
        // remembered twice. When it is on and the document's own crop cannot be held by any
        // translation, the draft is inscribed before the frame is first drawn.
        staysInsidePixelsStorage = defaults.bool(forKey: Self.staysInsidePixelsKey)
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
        lockReshapeSuspended = false       // 310 — a new session, a new lock question
        straightenBaseCrop = nil
        // 317 — before anything opens (so the inscribe cannot bracket an empty session).
        inscribeIntoPixelsIfNeeded()
        // 077 said 「裁切完成后只保留一个记录」, and 356 keeps it without a session that spans the
        // whole mode: the draft is the only thing a handle position writes, so nothing is recorded
        // between here and 应用 anyway, and 应用 writes its one row itself. A session that outlived
        // the gesture that opened it is exactly what made a later 双击 / ⌘Z / 粘贴 behave differently
        // depending on what the history happened to contain — so the tool no longer opens one.
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
        // 328 — 画线拉直 is this session's view state: leaving the tool puts the crosshair away and
        // drops any line, whatever the door (↵ 应用 / 完成 / Esc).
        cancelDrawStraighten()
        cancelGuideLines()
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
        // 356 — 应用 is a command, not a gesture: close whatever a gesture left behind first, then
        // write the document and commit its **one** row directly. Asking the session for the row
        // (`endToolSession`) was the same row only when a session happened to be open; with none it
        // recorded nothing at all and 应用 silently stopped being undoable.
        closeToolSession(label: "裁切与旋转")
        session.applyEdit { $0.geometry = geometry }
        let committed = session.commitEdit(label: "裁切与旋转", coalesce: false)
        draft = Draft(geometry: geometry)
        draftPhotoID = session.anchorID
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
        draftPhotoID = session?.anchorID
        lockReshapeSuspended = false       // 310 — Esc restores the document, lock included
        cancelledCount += 1
    }

    /// Kept as the named Esc door; it is `finish(.cancel)`.
    public func cancel() { finish(.cancel) }

    /// Leaving the loupe, changing photo, or the canvas going away: drop the tool silently. Not a
    /// 取消 the user asked for, so it does not count as one.
    public func detach() {
        guard isActive else { return }
        cancelDrawStraighten()
        cancelGuideLines()
        endDrag()
        isActive = false
        // 077: the session ends with zero rows (the draft is discarded, and any mid-session document
        // write is rolled back by `cancelToolSession`).
        session?.cancelToolSession()
        draft = Draft(geometry: session?.edit.geometry ?? GeometryGroup.identity)
        draftPhotoID = session?.anchorID
        lockReshapeSuspended = false       // 310 — leaving the tool forgets the move
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
        draftPhotoID = session.anchorID
        lockReshapeSuspended = false       // 310 — the document's lock is the question again
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
        draftPhotoID = session.anchorID
        lockReshapeSuspended = false       // 310 — another photo, another lock question
        entryGeometry = session.edit.geometry
        // 317 — 换图 keeps the box (it is a preference) and re-asks the size question for B's frame.
        staysInsidePixelsStorage = defaults.bool(forKey: Self.staysInsidePixelsKey)
        inscribeIntoPixelsIfNeeded()
        // 356 — a photo switch is not a gesture: it closes a gesture's session instead of opening a
        // new one on top (the old guard here opened one only when none was open, so the *next*
        // entry's door depended on what this one had done).
        closeToolSession()
        return true
    }

    /// 202 ④ — **which photo the draft was seeded for.**
    ///
    /// The overlay and the frame job read the draft on **every** turn, and a photo switch publishes
    /// the new anchor (and the new `cropSourceSize`) several turns before the observation that
    /// re-seeds the draft runs. Those turns draw the *previous* photo's rect on the *new* photo: on a
    /// 3000 × 2000 → 2000 × 3000 switch the stale full-frame rect lands as a small patch in the
    /// top-left corner (measured in `CropPhotoSwitchFrame202Tests`: 「1/4 面积的左上角」, then the
    /// correct frame). Tagging the draft with the photo it belongs to makes that state visible and
    /// lets the reader heal it before it is drawn instead of after.
    public private(set) var draftPhotoID: String?

    /// 202 ④ — **the self-heal the reader calls**: if the draft belongs to another photo, re-seed it
    /// from the document on screen *now*, before anything is laid out. Synchronous by design (the
    /// ask's preferred fix: 「同步种好…在第一次 present 之前完成」) — the new document's geometry is
    /// already in `session.edit` by the time the anchor changes, so there is nothing to wait for and
    /// no reason to draw a frame that belongs to the previous picture.
    ///
    /// Returns `true` when it re-seeded, so a caller can refresh the bar and the readouts.
    @discardableResult
    public func reseedIfPhotoMoved() -> Bool {
        guard isActive, let session else { return false }
        // `nil` on both sides is 「no photo」, which is not a move.
        guard draftPhotoID != session.anchorID else { return false }
        return reseedForPhotoChange()
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

    // MARK: 328 — 画线拉直 (manual straighten by drawing a line)

    /// The card's `line.diagonal` toggle: while this is on, a press on the canvas starts a "draw a
    /// line" stroke instead of moving the frame (§2). View state, like `showsGrid` — it is never in
    /// the document, never in the history, and it is dropped when the tool closes.
    public private(set) var isDrawStraightenArmed = false

    /// A stroke is in flight (mouse down … up).
    public private(set) var isDrawingStraighten = false

    /// The line on screen, in **view points**: the stroke while the hand is down, and the finished
    /// line for `CropDrawStraighten.holdSeconds` afterwards. `nil` is 「nothing to draw」.
    public private(set) var straightenStroke: CropToolSegment?

    /// Its opacity, from `CropDrawStraighten.alpha(elapsed:)`.
    public private(set) var straightenStrokeAlpha: Double = 1

    /// How many strokes actually turned the picture, and how many were too short to be a line (§2's
    /// 「20 pt 以下算误触，不应用、不提示，只计数」). The second number is what a QA report reads.
    public private(set) var drawnStraightenCount = 0
    public private(set) var tooShortStraightenCount = 0

    /// The last stroke's numbers — the readout the tests (and a future status line) print.
    public private(set) var lastStraightenDraw: CropStraightenDraw?

    /// §4.9② — the reverse gate. `true` is the shipped rule (`|θ| ≤ 45°` → 横, otherwise 竖); the
    /// test flips it to prove that without the fold an 83° line is turned 45° the wrong way. Nothing
    /// in the app writes it.
    var foldsToNearestAxis = true

    /// 328b §2.6 — the other reverse gate. `true` is the shipped rule: the line's angle is measured
    /// **on the screen**, which is what the user drew on. The test flips it to 328's source-space
    /// reading and watches the keystone acceptance go red (screen residual 1.69° for a 20° line on a
    /// `(+30, −15)` picture). Nothing in the app writes it.
    var measuresAngleOnScreen = true

    /// The canvas half: the loupe assigns this to push the stroke at the overlay **without** the
    /// frame's layout pass (`clampToView` must not run mid-stroke — §2's 「画线期间不得移动裁切框」).
    var onStraightenStrokeChange: (() -> Void)?

    // MARK: 337 — 引导线 (guide lines: two drawn lines → the keystone)

    /// The card's 引导线 switch. View state like 328's, and mutually exclusive with it: both own the
    /// canvas press, so arming one disarms the other.
    public private(set) var isGuideLinesArmed = false
    /// A guide-line stroke is in flight (mouse down … up).
    public private(set) var isDrawingGuideLine = false
    /// The stroke under the hand, in view points; `nil` between gestures.
    public private(set) var guideLineStroke: CropToolSegment?
    /// Its opacity, from `GuideLinesSolve.alpha(elapsed:)` — the 0.3 s flash after the release.
    public private(set) var guideLineStrokeAlpha: Double = 1
    /// The lines the current fit stands on, oldest first. At most 2 vertical + 2 horizontal.
    public private(set) var guideLines: [GuideLine] = []
    /// The accepted fit (the values the document holds), or `nil` before the first success.
    public private(set) var guideLineSolution: GuideLineSolution?
    /// Why the last gesture did **not** take — `nil` after a success.
    public private(set) var guideLineFailure: GuideLineFailure?
    /// 348 — how far apart the lines were when the fit refused, in degrees: 「线间相差 6.2°」 has to
    /// print the 6.2, or the user only learns that something is wrong.
    public private(set) var guideLineMeasuredPairwise: Double?
    /// 348 — `.rotationOutOfRange` when the keystone took but the turn could not be held by the
    /// dial (±45°); the two steps are independent, so this is not a refusal.
    public private(set) var guideLineRotationFailure: GuideLineFailure?
    /// The line the last gesture drew and threw away, drawn red for the same 0.3 s.
    public private(set) var rejectedGuideLine: GuideLine?
    public private(set) var rejectedGuideLineAlpha: Double = 1
    /// Counters for the QA report: fits applied, strokes ignored (too short / over the ceiling).
    public private(set) var guideLineApplyCount = 0
    public private(set) var ignoredGuideLineCount = 0
    public private(set) var tooShortGuideLineCount = 0

    /// 337 §4 gate ① — `true` is the shipped rule: the stroke's endpoints are walked back through
    /// the **current** composite inverse (`P⁻¹ · R⁻¹`, `LoupeMapping.sourcePoint`) before the fit, so
    /// the fit is about the photograph's material lines. With it off the view points are used as if
    /// they were source pixels — the screen angle, which double-applies the current keystone. Only
    /// the acceptance writes it.
    var guideLinesMapBackToSource = true

    /// 337 §4 gate ② — the fit's acceptance tolerance, in degrees. `0.05` shipped; the gate widens
    /// it to 1° to prove the ≤0.05° acceptance is what rejects the sloppier answer.
    var guideLineTolerance = GuideLinesSolve.toleranceDegrees

    /// The canvas half of 337: one assignment pushes the lines at the overlay without a layout pass,
    /// exactly like `onStraightenStrokeChange` (「画线期间不得移动裁切框」).
    var onGuideLineChange: (() -> Void)?

    private var guideLineTimer: Timer?

    private var strokeTimer: Timer?

    /// The card's button: arm/disarm. Disarming drops the line and writes nothing.
    @discardableResult
    public func toggleDrawStraighten() -> Bool {
        setDrawStraightenArmed(!isDrawStraightenArmed)
    }

    @discardableResult
    public func setDrawStraightenArmed(_ armed: Bool) -> Bool {
        guard isActive else {
            isDrawStraightenArmed = false
            return false
        }
        guard armed != isDrawStraightenArmed else { return false }
        if armed {
            isDrawStraightenArmed = true
        } else {
            // The button's second press is §2's 取消: no apply, no row.
            cancelDrawStraighten()
        }
        return true
    }

    /// Mouse-down while armed: start a stroke. The frame is **not** grabbed — `drag` stays `nil`,
    /// `isDragging` stays `false`, and nothing in `draft` is touched.
    @discardableResult
    public func beginDrawStraighten(atViewPoint point: CGPoint) -> Bool {
        guard isActive, isDrawStraightenArmed else { return false }
        stopStrokeTimer()
        straightenStroke = CropToolSegment(a: point, b: point)
        straightenStrokeAlpha = 1
        isDrawingStraighten = true
        swallowedGestures += 1
        onStraightenStrokeChange?()
        return true
    }

    /// One tick of the draw. **Only the stroke moves** (§2 「画线期间拖动不得移动/改变裁切框」): no
    /// `draft.crop` write, no `clampToView`, no lock reshape, no inscription — the 310 invariant is
    /// not re-established here, it is never asked.
    public func continueDrawStraighten(atViewPoint point: CGPoint) {
        guard isActive, isDrawingStraighten, let stroke = straightenStroke else { return }
        straightenStroke = CropToolSegment(a: stroke.a, b: point)
        straightenStrokeAlpha = 1
        onStraightenStrokeChange?()
    }

    /// Mouse-up: measure the line and, if it is long enough, turn the picture **once**.
    ///
    /// One gesture is one history row: the value goes through `writeStraighten` and then
    /// `commitStraighten` (the slider's own release path), which writes the document once and
    /// closes/reopens the crop session around exactly one snapshot — so ⌘Z is the angle from before
    /// the line (§3.5). A 19 pt stroke changes nothing and commits nothing.
    @discardableResult
    public func endDrawStraighten(mapping: LoupeMapping,
                                  pointScale: Double = 1) -> CropStraightenDraw? {
        guard isActive, isDrawingStraighten, let stroke = straightenStroke else { return nil }
        isDrawingStraighten = false
        guard let draw = CropDrawStraighten.draw(from: stroke.a, to: stroke.b,
                                                 mapping: mapping,
                                                 pointScale: pointScale,
                                                 nearestAxis: foldsToNearestAxis,
                                                 angleOnScreen: measuresAngleOnScreen) else {
            // §2 — 误触: nothing applied, nothing said, counted for the report.
            tooShortStraightenCount += 1
            straightenStroke = nil
            straightenStrokeAlpha = 1
            onStraightenStrokeChange?()
            return nil
        }
        straightenStroke = CropToolSegment(a: draw.start, b: draw.end)
        straightenStrokeAlpha = 1
        lastStraightenDraw = draw
        _ = applyDrawnStraighten(draw.raw)
        scheduleStrokeFade()
        onStraightenStrokeChange?()
        return draw
    }

    /// §2 — Esc / the button: drop the stroke, keep the draft, write nothing.
    @discardableResult
    public func cancelDrawStraighten() -> Bool {
        let wasLive = isDrawingStraighten || isDrawStraightenArmed || straightenStroke != nil
        stopStrokeTimer()
        isDrawingStraighten = false
        isDrawStraightenArmed = false
        straightenStroke = nil
        straightenStrokeAlpha = 1
        if wasLive { onStraightenStrokeChange?() }
        return wasLive
    }

    /// The one write, exposed (internal) so a test can drive the clamp through the real door —
    /// `CropTool.clampStraighten` is the limit, and the card's readout is `draft.straighten`, so a
    /// clamped value is reported as the value that took effect (§3.4).
    @discardableResult
    func applyDrawnStraighten(_ raw: Double) -> Double {
        guard isActive else { return draft.straighten }
        writeStraighten(raw)
        let applied = draft.straighten
        drawnStraightenCount += 1
        _ = commitStraighten()
        return applied
    }

    /// §2 — 1.5 pt white + 1 px black, held `holdSeconds` and then faded over `fadeSeconds`.
    private func scheduleStrokeFade() {
        stopStrokeTimer()
        let shownAt = Date()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                let elapsed = Date().timeIntervalSince(shownAt)
                self.straightenStrokeAlpha = CropDrawStraighten.alpha(elapsed: elapsed)
                if self.straightenStrokeAlpha <= 0 {
                    timer.invalidate()
                    self.strokeTimer = nil
                    self.straightenStroke = nil
                    self.straightenStrokeAlpha = 1
                }
                self.onStraightenStrokeChange?()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        strokeTimer = timer
    }

    private func stopStrokeTimer() {
        strokeTimer?.invalidate()
        strokeTimer = nil
    }

    // MARK: 337 — 引导线: the gesture

    /// The card's 引导线 button: arm/disarm. Disarming is §2's 取消 — the lines and the draft stay
    /// where they are, and nothing is written (a fit that already succeeded has already written, so
    /// its ⌘Z row is untouched).
    @discardableResult
    public func toggleGuideLines() -> Bool {
        setGuideLinesArmed(!isGuideLinesArmed)
    }

    @discardableResult
    public func setGuideLinesArmed(_ armed: Bool) -> Bool {
        guard isActive else {
            isGuideLinesArmed = false
            return false
        }
        guard armed != isGuideLinesArmed else { return false }
        if armed {
            // 337 — one canvas, one tool: 画线拉直 and 引导线 cannot both own the press.
            _ = setDrawStraightenArmed(false)
            isGuideLinesArmed = true
            guideLineFailure = nil
            guideLineMeasuredPairwise = nil
            guideLineRotationFailure = nil
        } else {
            cancelGuideLines()
        }
        onGuideLineChange?()
        return true
    }

    /// Mouse-down while armed: start a stroke. The frame is **not** grabbed — `drag` stays `nil`,
    /// `isDragging` stays `false`, and nothing in `draft.crop` is touched (§2's 画线期间不动裁切框).
    @discardableResult
    public func beginGuideLine(atViewPoint point: CGPoint) -> Bool {
        guard isActive, isGuideLinesArmed else { return false }
        stopGuideLineTimer()
        guideLineStroke = CropToolSegment(a: point, b: point)
        guideLineStrokeAlpha = 1
        isDrawingGuideLine = true
        rejectedGuideLine = nil
        swallowedGestures += 1
        onGuideLineChange?()
        return true
    }

    /// One tick of the draw. **Only the stroke moves** — no `draft.crop` write, no `clampToView`, no
    /// lock reshape, so 310's invariant is not re-established here, it is never asked.
    public func continueGuideLine(atViewPoint point: CGPoint) {
        guard isActive, isDrawingGuideLine, let stroke = guideLineStroke else { return }
        guideLineStroke = CropToolSegment(a: stroke.a, b: point)
        guideLineStrokeAlpha = 1
        onGuideLineChange?()
    }

    /// Mouse-up: one line → the fit (§2b), and — only when the whole fit is accepted — one document
    /// write and one history row.
    ///
    /// `nil` means the gesture changed nothing: a stroke shorter than 20 pt, a fifth line, a
    /// degenerate pair, or a fit whose residuals cannot all come inside 0.05°. `guideLineFailure`
    /// says which, and the previous valid values stay.
    @discardableResult
    public func endGuideLine(mapping: LoupeMapping,
                             pointScale: Double = 1) -> GuideLineSolution? {
        guard isActive, isDrawingGuideLine, let stroke = guideLineStroke else { return nil }
        isDrawingGuideLine = false

        let dx = Double(stroke.b.x - stroke.a.x), dy = Double(stroke.b.y - stroke.a.y)
        let length = (dx * dx + dy * dy).squareRoot()
        guard length.isFinite, length >= GuideLinesSolve.minimumLengthPoints else {
            // §4.6 — a misfire is nothing: no line, no fit, no write.
            tooShortGuideLineCount += 1
            guideLineStroke = nil
            guideLineStrokeAlpha = 1
            onGuideLineChange?()
            return nil
        }

        let scale = pointScale > 0 ? pointScale : 1
        // §2.4 — the material points: the stroke's ends through the **current** composite inverse
        // (`P_current⁻¹ · R⁻¹`, plus the crop window and the camera). The gate's `false` branch uses
        // the view points as they are — the screen reading the acceptance shows going red.
        let a: CGPoint, b: CGPoint
        if guideLinesMapBackToSource {
            let p = mapping.sourcePoint(viewX: Double(stroke.a.x) * scale,
                                        viewY: Double(stroke.a.y) * scale)
            let q = mapping.sourcePoint(viewX: Double(stroke.b.x) * scale,
                                        viewY: Double(stroke.b.y) * scale)
            a = CGPoint(x: p.x, y: p.y)
            b = CGPoint(x: q.x, y: q.y)
        } else {
            a = stroke.a
            b = stroke.b
        }
        guard a.x.isFinite, a.y.isFinite, b.x.isFinite, b.y.isFinite else {
            guideLineStroke = nil
            onGuideLineChange?()
            return nil
        }

        let viewAngle = GuideLinesSolve.fold(GuideLinesSolve.degrees(dx: dx, dy: dy))
        let line = GuideLine(start: stroke.a, end: stroke.b,
                             sourceStart: a, sourceEnd: b,
                             viewAngle: viewAngle,
                             axis: GuideLinesSolve.axis(forFoldedAngle: viewAngle))

        // §2b.1 — at most four lines, at most two per axis. The fifth is ignored **with a reason**,
        // never silently: the previous fit (and its document values) stay.
        let sameAxis = guideLines.filter { $0.axis == line.axis }.count
        guard guideLines.count < GuideLinesSolve.maxLines,
              sameAxis < GuideLinesSolve.maxLinesPerAxis else {
            ignoredGuideLineCount += 1
            guideLineFailure = .tooManyLines
            guideLineStroke = nil
            guideLineStrokeAlpha = 1
            onGuideLineChange?()
            return nil
        }

        let candidate = guideLines + [line]
        // §2.2 — one line is kept but solves nothing: 「画 2 条后自动求解」. The line stays on the
        // canvas (dim) so the user can see what the first stroke was.
        guard candidate.count >= 2 else {
            guideLines = candidate
            guideLineSolution = nil
            guideLineFailure = .notEnoughLines
            guideLineStroke = CropToolSegment(a: stroke.a, b: stroke.b)
            guideLineStrokeAlpha = 1
            scheduleGuideLineFade()
            onGuideLineChange?()
            return nil
        }
        let fit = GuideLinesSolve.fit(lines: candidate,
                                      current: documentPerspective,
                                      source: sourceSize,
                                      straightenDegrees: CropTool.clampStraighten(draft.straighten),
                                      tolerance: guideLineTolerance)
        guard let solution = fit.solution else {
            // §2b.2 — all-or-nothing: the line is withdrawn (red for the same 0.3 s), the accepted
            // set and the document keep their last valid state.
            guideLineFailure = fit.failure
            guideLineMeasuredPairwise = fit.measuredWorstPairwise
            guideLineRotationFailure = nil
            rejectedGuideLine = line
            rejectedGuideLineAlpha = 1
            guideLineStroke = nil
            guideLineStrokeAlpha = 1
            scheduleGuideLineFade()
            onGuideLineChange?()
            return nil
        }

        guideLines = candidate
        guideLineSolution = solution
        guideLineFailure = nil
        guideLineMeasuredPairwise = solution.worstResidual
        guideLineRotationFailure = solution.rotationFailure
        rejectedGuideLine = nil
        guideLineStroke = CropToolSegment(a: stroke.a, b: stroke.b)
        guideLineStrokeAlpha = 1
        guideLineApplyCount += 1
        writeGuideLineSolution(solution)
        scheduleGuideLineFade()
        onGuideLineChange?()
        return solution
    }

    /// §2 / §4.6 — Esc or the button again: drop the stroke and every line, write nothing.
    /// The document keeps whatever an **earlier successful** fit wrote (that was its own row); this
    /// only ends the gesture.
    @discardableResult
    public func cancelGuideLines() -> Bool {
        let wasLive = isDrawingGuideLine || isGuideLinesArmed || guideLineStroke != nil
            || !guideLines.isEmpty || rejectedGuideLine != nil
        stopGuideLineTimer()
        isDrawingGuideLine = false
        isGuideLinesArmed = false
        guideLineStroke = nil
        guideLineStrokeAlpha = 1
        guideLines = []
        guideLineSolution = nil
        guideLineMeasuredPairwise = nil
        guideLineRotationFailure = nil
        rejectedGuideLine = nil
        rejectedGuideLineAlpha = 1
        if wasLive { onGuideLineChange?() }
        return wasLive
    }

    /// §2.5 — the one write: both parameters **and the turn** into the document, **one** history row.
    ///
    /// The fields are the sliders' own (`GeometryGroup.perspectiveVertical/Horizontal` and
    /// `rotationDegrees`), so the card's readout follows by construction — there is no second copy to
    /// update. 348 writes the third value here because 「先平行，再摆正」 is one gesture to the user:
    /// two rows would make ⌘Z put the keystone back while leaving the picture turned.
    /// The row is closed the way `commitStraighten` closes 转动's (end/reopen the crop session),
    /// because a guide-line fit is one discrete gesture and must not fold into a drag still in flight.
    private func writeGuideLineSolution(_ solution: GuideLineSolution) {
        guard let session else { return }
        // 356 — 引导线应用 is a **command**, not a gesture: close a gesture's session *before* the
        // write, so the fit's row is written by `commitEdit` in exactly one way from every
        // precondition. The old shape asked the history afterwards and took two different doors:
        // inside a session the row was the whole `base → edit` (crop-so-far **and** fit in one row,
        // so ⌘Z put both back), outside it was the fit alone. Same 40 px of keystone, two different
        // documents after the next ⌘Z — the user's 「只要历史里有东西，变换就不对」.
        closeToolSession(label: "引导线")
        let before = session.edit.geometry
        session.applyEdit {
            $0.geometry.perspectiveVertical = solution.vertical
            $0.geometry.perspectiveHorizontal = solution.horizontal
            // `solution.straighten` is the dial's value either way: when the turn was skipped it is
            // the angle the document already had, so this line is a no-op for `.rotationOutOfRange`.
            $0.geometry.rotationDegrees = CropTool.clampStraighten(solution.straighten)
        }
        guard session.edit.geometry != before else { return }
        _ = session.commitEdit(label: "引导线", coalesce: false)
        // The draft carries the document's keystone so the overlay, the red-frame predicate and
        // 应用 all see the picture the fit just produced.
        draft.perspectiveVertical = session.edit.geometry.perspectiveVertical
        draft.perspectiveHorizontal = session.edit.geometry.perspectiveHorizontal
        // 348 — and the turn, so the angle dial and the overlay agree with the picture on screen.
        draft.straighten = CropTool.clampStraighten(session.edit.geometry.rotationDegrees)
        // §2c — Lightroom's `Constrain Crop` equivalent, and the **existing** switch: with
        // 「不出像素」 on (the default) the frame is inscribed once into the photo quad, so the
        // export has no black pixel; with it off the frame may stay on the `000000` corners. No new
        // toggle, no canvas change — the canvas is still the AABB (330).
        inscribeIntoPixelsIfNeeded()
        draftChanged()
    }

    /// The document's `(v, h)` — the fit's starting point (§2b.3 初值取当前) and the value an
    /// unconstrained axis keeps.
    private var documentPerspective: PerspectiveMap {
        PerspectiveMap(vertical: session?.edit.geometry.perspectiveVertical ?? draft.perspectiveVertical,
                       horizontal: session?.edit.geometry.perspectiveHorizontal ?? draft.perspectiveHorizontal)
    }

    /// §2.2 — the finished line stays at full opacity for 0.3 s, then fades; the rejected one does
    /// the same in red.
    private func scheduleGuideLineFade() {
        stopGuideLineTimer()
        let shownAt = Date()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                let elapsed = Date().timeIntervalSince(shownAt)
                self.guideLineStrokeAlpha = GuideLinesSolve.alpha(elapsed: elapsed)
                self.rejectedGuideLineAlpha = GuideLinesSolve.alpha(elapsed: elapsed)
                if self.guideLineStrokeAlpha <= 0 {
                    timer.invalidate()
                    self.guideLineTimer = nil
                    self.guideLineStroke = nil
                    self.rejectedGuideLine = nil
                    self.guideLineStrokeAlpha = 1
                    self.rejectedGuideLineAlpha = 1
                }
                self.onGuideLineChange?()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        guideLineTimer = timer
    }

    private func stopGuideLineTimer() {
        guideLineTimer?.invalidate()
        guideLineTimer = nil
    }

    /// The lines the overlay draws dimly: every accepted line of the current fit, in view points.
    public var acceptedGuideLineSegments: [CropToolSegment] {
        guideLines.map { CropToolSegment(a: $0.start, b: $0.end) }
    }

    /// The card's one-line status (§2.3's 「另一方向请再画两条」 included). `nil` prints nothing.
    ///
    /// 348 — a refusal says **how far apart** the lines are (`measuredWorstPairwise`), and a fit that
    /// took but could not be turned upright appends the turn's own reason: 「透视已应用」 has to be in
    /// the sentence, or the user will think nothing happened when the keystone did.
    public var guideLineStatusText: String? {
        if let failure = guideLineFailure {
            return failure.message(measuredWorstPairwise: guideLineMeasuredPairwise)
        }
        guard let solution = guideLineSolution else { return nil }
        var text = solution.summary
        if let rotation = solution.rotationFailure {
            text += " · " + rotation.message(measuredWorstPairwise: solution.straightenRequested)
        }
        if GuideLinesSolve.isMixedDirection(guideLines) { text += " · 另一方向请再画两条" }
        return text
    }

    /// The angle still to be shown on top of the document: `θ − θ₀`, in degrees. 0 at rest and right
    /// after a release, and up to ±90 at the slider's extremes when the document already carries ±45
    /// (so it is *not* clamped again — the quad has to turn by the whole difference).
    public var straightenDelta: Double {
        let committed = CropTool.clampStraighten(session?.edit.geometry.straightenDegrees ?? 0)
        return draft.straighten - committed
    }

    /// End of one 转动 gesture: write the draft angle **once** (`applyEdit`), then close the gesture's
    /// session around exactly one row. 356 — the session is the mouse-down's, so there is no "reopen
    /// so the crop draft still waits for 应用": the crop draft waits because nothing opens one.
    ///
    /// Order matters: the document write is what asks the loupe for the one re-render, and it is what
    /// the row records — so it comes first, then the close.
    @discardableResult
    public func commitStraighten() -> Bool {
        guard isActive, let session else { return false }
        let angle = CropTool.clampStraighten(draft.straighten)
        session.applyEdit { $0.geometry.rotationDegrees = angle }
        // 356 — one door, and it never asks the history which case it is: a session that is open
        // (the mouse-down's) records `base → edit`; with none, the same one row is committed.
        let committed = closeGestureSession(label: "转动")
        // 317 — 「改角度之后」: the released 转动 gets the one-shot question too (the bare slider's
        // `setAngle` asks it per move; this is the gesture's `.inside`-rotate twin).
        inscribeIntoPixelsIfNeeded()
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
        lockReshapeSuspended = false       // 310 — a ratio preset *is* about the size
        draftChanged()
    }

    /// Direct lock write (the tests' door, and what `setAspect` ends in).
    public func setLock(_ lock: AspectLock, source: ImageSize? = nil) {
        let source = source ?? sourceSize
        draft.lock = lock
        draft.crop = CropTool.matching(lock, crop: draft.crop, source: source)
        lockReshapeSuspended = false       // 310 — choosing a lock re-arms its reshape
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
        // 072's promise is 「一次翻转 = 一次 ⌘Z」, and 356's rule is that a session belongs to a
        // gesture: a flip is a click, so it **closes** whatever a gesture left open (its row is the
        // crop-so-far, which 应用 would have written anyway) instead of ending-and-reopening around
        // itself. The old shape's answer — one row or two, and therefore what the next ⌘Z restored —
        // depended on whether the history happened to hold a session.
        closeToolSession(label: "裁切与旋转")

        let before = horizontal ? session.edit.geometry.flipHorizontal : session.edit.geometry.flipVertical
        session.applyEdit { model in
            if horizontal { model.geometry.flipHorizontal.toggle() }
            else { model.geometry.flipVertical.toggle() }
        }
        let after = horizontal ? session.edit.geometry.flipHorizontal : session.edit.geometry.flipVertical
        // A flip is discrete (072 §F): never fold it into the drag before it.
        session.commitEdit(label: horizontal ? "水平翻转" : "垂直翻转", coalesce: false)
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
        // 356 — a turn is a click, not a gesture: close a gesture's session (one row for the
        // crop-so-far, or nothing) and write the turn's own row. No reopen, so a second press cannot
        // take a different door because of what the first one left behind.
        closeToolSession(label: "裁切与旋转")
        var turned = false
        session.applyEdit { model in turned = model.turn(clockwise: clockwise) }
        guard turned else { return false }
        session.commitEdit(label: clockwise ? "顺时针旋转 90°" : "逆时针旋转 90°", coalesce: false)
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
        lockReshapeSuspended = false       // 310 — a typed/swapped ratio is about the size
        draftChanged()
    }

    /// The current ratio, as the popup shows it.
    public func aspectPreset(source: ImageSize? = nil) -> CropAspectPreset {
        CropAspectPreset(lock: draft.lock, source: source ?? sourceSize)
    }

    // MARK: the preview

    /// 197 — the document the **canvas** is of while the tool is on: **the whole frame**, with the
    /// document's own 拉直 / 翻转 / 90° turn.
    ///
    /// Crop goes to `.full` because that is what "裁剪模式下画布显示未裁剪图" means, and the lock goes
    /// to `.original` because the draft rect is already the answer — the frame on screen must be the
    /// picture, not a pre-cropped one. Nothing is written: this value lives for one `makeJob`.
    ///
    /// This is the variant the **pixels and the camera** use (`LoupeController.makeJob` /
    /// `framing`). `previewEdit` below is the *draft's* variant: it also carries the in-flight 拉直
    /// angle, which is what the canvas-geometry key has to follow (a tick can change
    /// `CropMath.canvasSize`), but which 088 keeps out of the render — a slider tick turns the frame
    /// quad only, and the camera must describe the picture the last release rendered.
    ///
    /// Before 197 only the geometry key used the preview document and the frame job used the
    /// **document**, so re-entering 裁切 on a photo that already had a crop rendered just the kept
    /// rectangle: 应用 → 再进裁切 ⇒ 画布只剩裁切区.
    public func canvasEdit(from edit: EditModel) -> EditModel {
        guard isActive else { return edit }
        var e = edit
        e.geometry.crop = .full
        e.geometry.aspectLock = .original
        // 072 §F — the flips are the document's, so they are carried, not overridden: a 水平翻转 from
        // 变换 ▸ 水平翻转 while the tool is on has to show on the canvas immediately, and there is no
        // draft copy left that could disagree with it.
        return e
    }

    /// The same document with the **draft's** angle — what the overlay and the canvas-geometry key
    /// describe while the slider is in flight.
    public func previewEdit(from edit: EditModel) -> EditModel {
        guard isActive else { return edit }
        var e = canvasEdit(from: edit)
        e.geometry.rotationDegrees = CropTool.clampStraighten(draft.straighten)
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
        // 088 says the framing handed in is the **document's** (`cropMapping` uses `canvasEdit`), so
        // the quad's rotation is exactly the draft delta and the picture on screen is at the
        // document's angle. A framing that already carries part of the draft angle (a draft-angle
        // mapping, as the clamp probes build) turns the *picture* by that much too, so the total
        // angle the drawn frame actually turns through in the source is
        // `mapping angle + quad rotation` — not `draft.straighten` alone. The inscribed clamp has to
        // be taken at that total, or a previewed frame is clamped for an angle it is not drawn at
        // (9° + 9° probe: corners just outside the sensor). In the app the framing angle **is** the
        // document's, the difference is zero, and this is `draft.straighten` bit for bit.
        let documentAngle = session?.edit.geometry.straightenDegrees ?? 0
        let framingAngle = mapping.transform?.straightenDegrees ?? documentAngle
        let drawnAngle = CropTool.clampStraighten(draft.straighten) + (framingAngle - documentAngle)
        let quadRotation = quadRotationDegrees ?? geometry.rotationDegrees
        return CropTool.layout(crop: effectiveCrop(source: source, degrees: drawnAngle),
                        source: source ?? sourceSize,
                        mapping: mapping,
                        pointScale: pointScale,
                        showsGrid: showsGrid,
                        carry: carry,
                        quadRotationDegrees: quadRotation,
                        cropSpace: liveCropSpace,
                        exceedsPicture: frameExceedsPicture(source: source))
    }

    // MARK: the frame's allowed area (⑦ 框不许出画布 / 出照片)

    /// With this `false`, `clampToView` does nothing — ⑦'s anti-proof. A test flips it to show that
    /// every containment criterion goes red without the clamp; nothing in the app touches it.
    var clampsFrameToView = true

    /// How many times `clampToView` has been asked to run, and how many of those moved the draft.
    /// Diagnostics only (the 202 probe prints them to say *who* moved a frame that ended up
    /// outside the canvas — the clamp that never ran, or a camera that moved under it).
    public private(set) var clampCalls = 0
    public private(set) var clampMoves = 0

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

    /// Pull the draft's rect onto the **document's canvas** — `[0,1]²` in the rect's own space.
    ///
    /// 224 — the bound is the document, not the screen. 213 measured the frame in the viewport and
    /// 219 re-based it on the picture at the current camera (`LoupeMapping.canvasRect`); that made the
    /// canvas grow with the angle (1485 × 1485 at 45° on a 1400 × 1000 viewport) and the frame could
    /// be dragged out without an upper bound. The user's rule — 「画布就是画布，和屏幕无关」 — makes
    /// the answer a property of the rect alone: every framing and every angle clamp identically.
    ///
    /// The document's `canvasBounds` / `sourcePixelBounds` below remain readouts; the picture's turned
    /// quad is the red warning (`frameExceedsPicture`), never a clamp. Moving is preferred; only a
    /// rect genuinely larger than `[0,1]²` is shrunk (about its centre, so the ratio keeps).
    ///
    /// Returns `true` when the draft moved.
    @discardableResult
    public func clampToView(mapping: LoupeMapping, source: ImageSize? = nil) -> Bool {
        clampCalls &+= 1
        guard isActive, clampsFrameToView else { return false }
        // 327 — the 变换 card may have moved the knobs since the last refresh; the draft follows the
        // document before any geometry is asked of it.
        adoptDocumentKeystone()
        let src = source ?? sourceSize
        let before = draft.crop.clamped(allowsOutsideSource: true)

        // The ratio lock is a document constraint and has to survive the clamp. Applied to the size
        // about the frame's centre, before the canvas question is asked. **310** — not while the user
        // is *moving* the frame: a refresh must never re-cut the size a drag just carried.
        let shaped = lockReshapeSuspended ? before : reshapedForLock(before, source: src)
        let base = seen(shaped, source: src)
        let next = clampToCanvas(base, mapping: mapping, source: src)
        // 317 — the refresh owes the same containment as the tick: a frame that a drag left outside
        // the turned photograph (or an external write did) is **translated** in, never resized.
        let placed = placedInsidePixels(next, source: src)

        if placed != before {
            draft.crop = placed
            clampMoves &+= 1
            return true
        }
        // The frame is where it already was: the only thing that may still have to be written back
        // is the lock's reshape.
        guard shaped != before else { return false }
        draft.crop = shaped
        clampMoves &+= 1
        return true
    }

    /// 162 — the ratio lock as a **document constraint**, applied to the size about the frame's
    /// centre so it never goes through `CropTool.constrain`'s `0…1²` clamp (which would forbid the
    /// camera-outside band). `clampedToCanvas` used to carry this inline; 213 keeps it as one helper
    /// so the screen-space clamp and its callers cannot disagree about the lock.
    private func reshapedForLock(_ rect: CropRect, source: ImageSize) -> CropRect {
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

    /// 224 — the straightened picture's quad is a **warning, not a clamp**. The old opt-in shrink
    /// (`CropMath.clampedToRotatedFrame`, 132) pulled the frame back inside the turned photograph and
    /// therefore fought 「允许出照片像素」: the frame may cover the black corners a straighten cuts off.
    /// `effectiveCrop`'s explicit opt-in is the only place left that can still inscribe, and the app
    /// never turns it on; `frameExceedsPicture` is what tells the overlay to paint the frame red.
    private func seen(_ rect: CropRect, source: ImageSize) -> CropRect {
        rect.clamped(allowsOutsideSource: true)
    }

    /// 224 / 2026-11-02 — the document-space containment: the candidate rect is clamped to the
    /// **document canvas** (`CropGeometry.documentCanvasCropRect`, `[0,1]²` at every right angle) by
    /// `CropTool.clampToCanvas`, which reads no mapping and no screen. The draft's own angle is what
    /// makes the canvas the turned photograph's AABB, so it has to be handed over here — the drag is
    /// the one caller that knows the angle the user is currently looking at.
    private func clampToCanvas(_ rect: CropRect, mapping: LoupeMapping,
                               source: ImageSize) -> CropRect {
        var ticks = canvasShrinkTicks
        let clamped = CropTool.clampToCanvas(rect, mapping: mapping, source: source,
                                             degrees: CropTool.clampStraighten(draft.straighten),
                                             perspective: livePerspective,
                                             cropSpace: liveCropSpace,
                                             shrinkTicks: &ticks)
        canvasShrinkTicks = ticks
        return clamped
    }

    /// 324 — the document's keystone as the crop session must see it.
    ///
    /// **341 — the document is the authority, always.** A keystone is never a *temporary* draft edit:
    /// both sliders in 变换 write the document (`TransformPanel` → `session.applyEdit`), so the draft
    /// has no keystone of its own to prefer. The old shape asked the document first but fell back to
    /// `draft.perspective` whenever the document answered `nil` — i.e. **0**, which is exactly what
    /// 双击「垂直透视」 writes. A reset document was therefore read as the 40 the draft still carried,
    /// and the red-frame predicate, both clamps, the inscription and the overlay kept answering 40
    /// while the picture was already back at 0. `nil` here *is* the answer for an un-keystoned
    /// document. The draft's copy survives only for a controller with no session at all.
    ///
    /// Internal (not public) so the 341 acceptance can print it beside the document and the draft.
    var livePerspective: PerspectiveMap? {
        if let document = session?.edit.geometry { return document.perspective }
        return draft.perspective
    }

    /// 330 — the space the draft's rect is measured in. **A keystoned document is always read on its
    /// canvas** (that is the migration `CropGeometry.init` applies, so the two answers cannot differ);
    /// without a keystone the document's stored marker is the answer — the document's, never the
    /// draft's copy (341: a draft seeded while the document was keystoned keeps `.canvas` in its copy
    /// after the reset, and reading it would put a keystone-free document's frame in a space it no
    /// longer has). Every pre-330 document answers `.source` — the branch it always took.
    var liveCropSpace: CropSpace {
        if livePerspective?.hasWarp == true { return .canvas }
        if let live = session?.edit.geometry { return live.cropSpace }
        return draft.cropSpace
    }

    /// 324 — the draft's geometry as the one `CropGeometry` (P → R), which is the owner of
    /// `photoQuad()` / `documentQuad(of:)`. Nothing else in this file re-derives a corner.
    private func draftCropGeometry(source: ImageSize,
                                   perspective: PerspectiveMap?) -> CropGeometry {
        let document = session?.edit.geometry ?? .identity
        var group = draft.geometry(flipsOf: document)
        group.crop = draft.crop.clamped(allowsOutsideSource: true).normalizedRect
        group.perspectiveVertical = perspective?.vertical ?? 0
        group.perspectiveHorizontal = perspective?.horizontal ?? 0
        // 330 — the draft's rect lives in the space the session draws it in: the canvas for a
        // keystoned document, the photograph otherwise. 341 — the **session's** answer, not the
        // draft's copy: a draft seeded while the document was keystoned keeps `.canvas` after the
        // keystone is reset, and a frame that is canvas-spaced on a keystone-free document is a frame
        // in a space the document no longer has (it is what made the reset document's numbers differ
        // from a new one's).
        group.cropSpace = liveCropSpace
        return CropGeometry(geometry: group, source: source)
    }

    /// The document canvas the frame is allowed to occupy, in normalized turned-frame coordinates —
    /// `[0,1]²` for an upright document, the turned photograph's AABB otherwise.
    private func canvasBounds(source: ImageSize) -> CropRect {
        CropGeometry.documentCanvasCropRect(in: source,
                                            degrees: CropTool.clampStraighten(draft.straighten))
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
        // 2026-11-01 — the rect now comes from `CropGeometry`, the one owner of the four spaces, so
        // the coverage readout below and the clamp cannot describe two different canvases (they did:
        // 190 measured this AABB while 224 clamped to `[0,1]²`).
        //
        // 324 — with a keystone the canvas is the AABB of the photo **quad**, so the rect is
        // `CropGeometry.documentCanvasCropRect` (the keystone branch walks the quad back through the
        // one map) rather than `documentCanvasCropRect(in:degrees:)`, which only knows a rectangle.
        let r = draftCropGeometry(source: source, perspective: livePerspective).documentCanvasCropRect
        let w = Double(max(source.width, 1)), h = Double(max(source.height, 1))
        return CGRect(x: r.left * w, y: r.top * h, width: r.width * w, height: r.height * h)
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
                                                       rotationDegrees: straightenDelta,
                                                       perspective: livePerspective)
        guard let normalized else { return true }

        rotating = rotate && (handle == .outside || handle == .inside)
        rotateStart = draft.straighten
        // 310 — the size belongs to whoever is about to change it: a press on the inside suspends the
        // lock's reshape (a move never resizes), a press on a grip or outside re-arms it (those
        // gestures *are* about a size). `rotating` is a picture turn, which may re-inscribe the rect
        // in `setAngle`, so it re-arms as well.
        lockReshapeSuspended = (handle == .inside) && !rotate
        // The hand grabs the frame **it can see**, which at a non-zero straighten is the constrained
        // one (`effectiveCrop`), not the stored intent behind it. `clamped()` (224) keeps even the
        // mouse-down snapshot inside the document canvas.
        drag = CropToolDrag(handle: rotating ? .inside : handle,
                            crop: effectiveCrop(source: source).clamped(), grab: normalized)
        isDragging = true
        // 356 — **mouse-down opens the session**, and nothing else does. From here to the matching
        // `endDrag` (mouse-up, Esc, a cancelled drag, the canvas going away) the document is the
        // gesture's to write, and the gesture leaves at most one row. Two ticks later nobody has to
        // ask the history whether a session is open: the answer is "only during a gesture".
        openGestureSession()
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
                                                             rotationDegrees: straightenDelta,
                                                             perspective: livePerspective)
        else { return }

        if rotating {
            let centre = NormalizedPoint(draft.crop.centerX, draft.crop.centerY)
            draft.straighten = CropTool.straighten(rotateStart, grab: drag.grab,
                                                   to: normalized, centre: centre, source: source)
            return
        }
        let next = drag.crop(at: normalized, source: source, lock: draft.lock,
                             bounds: canvasBounds(source: source))
        // A tick that would put the rect's **centre** outside the turned picture cannot be honoured by
        // shrinking (there is no size at that centre), and jumping it back to the middle from under the
        // hand would be worse than ignoring it: the last legal frame stands.
        if clampsToRotatedFrame, draft.straighten != 0,
           CropMath.rotatedFrameScale(next, in: source, degrees: draft.straighten) <= 0 {
            return
        }
        // 224 补充契约 — clamp the candidate **before** the single write. `draft.crop` is inside
        // `[0,1]²` at every observable moment: there is no "outside for one tick, pulled back on the
        // next" state, and no second write to hide one. A tick that is already pinned produces the
        // same rect, so the draft does not change at all (no jitter, no drift).
        // `clampsFrameToView = false` remains the tests' anti-proof switch and writes the candidate
        // unclamped; the app never turns it off.
        guard clampsFrameToView else {
            draft.crop = next
            return
        }
        // 310 — a move is a translation, full stop: the tick's rect is the mouse-down size slid by the
        // hand. `reshapedForLock` is the **sizing** law (a grip, a new frame, a preset), and running it
        // on `.inside` is what made a locked frame shrink / change ratio as it approached the canvas
        // (measured: 0.9000 × 0.8000 → 0.8000 × 0.8000 on the first tick). The switch re-attaches it
        // for the reverse gate only.
        let candidate = (drag.handle == .inside && !reshapesLockOnInsideDrag)
            ? next
            : reshapedForLock(next, source: source)
        let clamped = clampToCanvas(candidate, mapping: mapping, source: source)
        clampCalls &+= 1
        if clamped != candidate { clampMoves &+= 1 }
        // 317 — 「不出像素」: the tick's rect is **translated** into the turned photograph. The size
        // is the mouse-down size either way (310), and a frame nothing can hold stays where it is
        // instead of being shrunk by a move (§3b: the overlay paints it red).
        draft.crop = placedInsidePixels(clamped, source: source)
        // 307 — a frame the user moved is the new base for any later straighten inscription; the
        // one they had at 0° is stale the moment they take manual control.
        straightenBaseCrop = nil
    }

    /// Mouse-up. The draft stays; the document is untouched until 应用.
    ///
    /// 356 — **mouse-up ends the session the mouse-down opened**, whatever the gesture was: a crop
    /// drag wrote only the draft, so this records nothing; a 转动 wrote the document on its release,
    /// so this is that row. This is also the cancel/detach door, where the same call records nothing.
    /// Closing here is what stops a session outliving its gesture and changing the door a later
    /// 双击 / ⌘Z / 粘贴 takes.
    public func endDrag() {
        isDragging = false
        drag = nil
        rotating = false
        closeToolSession(label: "裁切与旋转")
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
                           rotationDegrees: Double = 0,
                           perspective: PerspectiveMap? = nil,
                           cropSpace: CropSpace = .source) -> NormalizedPoint? {
        let scale = pointScale > 0 ? pointScale : 1
        // **330 — a canvas-spaced rect's inverse is the canvas' own grid.** View → document pixels
        // (`LoupeMapping.documentPoint`) → `[0,1]²` of the canvas. No perspective is undone here: the
        // crop never entered the picture's space, which is why a drag on a keystoned picture moves the
        // edge under the hand *and* keeps the frame a rectangle.
        if cropSpace == .canvas,
           let document = mapping.documentPoint(viewX: Double(point.x) * scale,
                                                viewY: Double(point.y) * scale) {
            let geometry = CropGeometry(
                geometry: GeometryGroup(crop: .full,
                                        rotationDegrees: CropTool.clampStraighten(rotationDegrees),
                                        aspectLock: .original,
                                        quarterTurns: 0,
                                        perspectiveVertical: perspective?.vertical ?? 0,
                                        perspectiveHorizontal: perspective?.horizontal ?? 0,
                                        cropSpace: .canvas),
                source: source)
            let e = geometry.photoQuadExtent
            guard e.width > 0, e.height > 0 else { return nil }
            return NormalizedPoint(document.x / e.width, document.y / e.height)
        }
        // **327 — the inverse of the keystone projection.** View → the document canvas' pixels →
        // `photoNormalized` (the exact inverse of `CropGeometry.documentPoint`, P → R undone in one
        // place). Without this branch a drag on a keystoned picture read the *un-warped* frame and the
        // grip under the hand moved a different edge.
        if let perspective, perspective.hasWarp,
           let document = mapping.documentPoint(viewX: Double(point.x) * scale,
                                                viewY: Double(point.y) * scale) {
            let geometry = CropGeometry(
                geometry: GeometryGroup(crop: .full,
                                        rotationDegrees: CropTool.clampStraighten(rotationDegrees),
                                        aspectLock: .original,
                                        quarterTurns: 0,
                                        perspectiveVertical: perspective.vertical,
                                        perspectiveHorizontal: perspective.horizontal),
                source: source)
            return geometry.photoNormalized(documentX: document.x, document.y)
        }
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
        /// `99999×99999` — five digits per side and the multiplication sign. Five, not four: a 60 MP
        /// frame cropped to a 102 000-px-wide stitch or a 1:8 ratio still prints five digits, and the
        /// field must not clip the number it exists to report (N7, user 2026-11-02).
        public static let pixels = "99999×99999"
    }

    static func ratioText(_ ratio: Double) -> String {
        guard ratio.isFinite, ratio > 0 else { return "—" }
        return String(format: "%.2f", ratio)
    }
}
