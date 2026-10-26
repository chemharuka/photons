import Foundation
import Metal
import PhotonsCore

// MARK: - the size rule (037 ②, user 2026-10-27)

/// How big the low-resolution whole-picture preview is, and how far it is scaled down.
///
/// The user's final wording, twice corrected:
///
/// > 修正一下，修改为缩略图大小最大是原图的一半，且不得长边大于 4096，后台渲染 24MP 还是要时间的
///
/// So: **at most half the original, and never a long edge above 4096**. Nothing else takes part —
/// the screen does not, the viewport does not, and the zoom does not, which is why changing screen or
/// display scale can never invalidate the texture (`037`: 屏幕尺寸不再参与计算).
///
/// Two properties are load-bearing and each has a test:
///
///   · the **scale is an arbitrary `Double`**. 9000 → 4096 is `0.4551…`, not `0.5`: snapping it to a
///     half or a quarter would render 4500 px and then throw pixels away, or render 2048 and lose the
///     whole point of the 4096 ceiling.
///   · the **1024 floor** is a guard rail added here, not by the user (noted in the report): a small
///     file would otherwise shrink to a colour block behind the frame. A file smaller than 2048 is
///     therefore rendered slightly *up*, which costs nothing and cannot be mistaken for detail.
public enum BackdropScale {

    /// The hard ceiling (user: 不得长边大于 4096).
    public static let maximumLongEdge = 4096

    /// The guard rail: below this the backdrop is a smear rather than a picture.
    public static let minimumLongEdge = 1024

    /// `min(imageLongEdge / 2, 4096)`, floored at 1024. Integer division, as specified.
    public static func previewLongEdge(imageLongEdge: Int) -> Int {
        let edge = max(imageLongEdge, 1)
        return max(minimumLongEdge, min(edge / 2, maximumLongEdge))
    }

    /// The render scale that produces `previewLongEdge` for a picture whose own long edge is
    /// `contentLongEdge` pixels.
    ///
    /// `content` — the cropped picture — is what is rendered, so the scale is taken against **its**
    /// long edge. The ceiling above is still the *original's* (`previewLongEdge(imageLongEdge:)`): a
    /// crop can only be smaller than the frame it was cut from, so the result satisfies "≤ half the
    /// original, ≤ 4096" either way, and a heavy crop does not render at 1:1 by accident.
    public static func renderScale(imageLongEdge: Int, contentLongEdge: Int) -> Double {
        Double(previewLongEdge(imageLongEdge: imageLongEdge)) / Double(max(contentLongEdge, 1))
    }
}

// MARK: - does the frame cover the canvas?

extension PresentWindow {

    /// Does the picture reach **every** canvas pixel through this window?
    ///
    /// `uv = u0 + p·du`, so the picture occupies `p ∈ [−u0/du, (1−u0)/du]` of the canvas — the same
    /// rectangle `CanvasPresenter.makeParams` feathers against (`d`). When that rectangle contains
    /// `[0, 1]²` the pass draws the picture everywhere and there is nothing for a backdrop to fill;
    /// when it does not — a *shrinking* window, whose `du = 1/s > 1` — the canvas has area the frame
    /// does not reach, and that area is what 025 filled with the picture's own stretched edge.
    ///
    /// **This is the whole of the present-side wiring** (`039`): a backdrop is drawn exactly when this
    /// is false. Zooming in, 1:1 and fit all return `true`, so the engine's 2 px feather can never mix
    /// low-resolution colour into the edge of a frame that covers the canvas.
    public var coversCanvas: Bool {
        let tolerance = 1e-6
        let u = Double(du), v = Double(dv)
        guard u.isFinite, v.isFinite, u > 1e-9, v > 1e-9 else { return false }
        let x0 = -Double(u0) / u, x1 = (1 - Double(u0)) / u
        let y0 = -Double(v0) / v, y1 = (1 - Double(v0)) / v
        return x0 <= tolerance && y0 <= tolerance
            && x1 >= 1 - tolerance && y1 >= 1 - tolerance
    }
}

// MARK: - the cache

/// The low-resolution **whole picture**, kept for the duration of one document (037 ② / 039).
///
/// ### When it is made (the hard requirement)
///
/// Only when **both** hold, and the two are checked in one place (`shouldGenerate(onPointerEnter:)`):
///
///   1. the document has moved since the texture was made — a different photo, a different develop
///      key (white balance, detail, decoder version), or a different edit digest;
///   2. the pointer has just come **into the canvas** from the inspector or from outside it.
///
/// Everything else is a no, and that is the performance argument the user made themselves
/// (不会影响性能): a stop change, a slider drag, a pan and a zoom transition must never start one of
/// these renders. An edit **marks it stale** and does not render anything; the next pointer entry
/// pays for it.
///
/// ### Why it is a type and not four fields in the controller
///
/// "Exactly one generation per dirty pointer entry" is the claim the tests pin, and it has three
/// states (held, stale, in flight) that a controller with `if`s in three places gets wrong eventually
/// — the second entry while the first render is running would make two textures for one document. The
/// state machine lives here, the GPU work stays in `LoupeController` (it owns the graph and the queue).
public final class BackdropCache {

    /// What a cached texture is *of*: the photo, and the document rendered on top of it.
    ///
    /// **The document half is the edit digest.** It is `Histogram.editDigest(edit)` — the same string
    /// the histogram caches its own numbers by — plus `DecodeInputs.key`, the develop half (white
    /// balance, detail, decoder version), because those change pixels through the *decoder* and are
    /// therefore not in the digest of an `EditModel`. A caller that wants to know whether the texture
    /// on hand is the document it is about to measure compares `digest` (and `develop`) with its own,
    /// which is why both are `public` and reported by `lowResFullFrame`.
    public struct Key: Equatable, Sendable {
        /// The photo: `contentHash|assetID`, or a test's frame-source identity.
        public let photo: String
        /// `DecodeInputs.key` — the decoder-side half of the document.
        public let develop: String
        /// `Histogram.editDigest(edit)` — the renderer-side half, one short hex string.
        public let digest: String

        public init(photo: String, develop: String, digest: String) {
            self.photo = photo
            self.develop = develop
            self.digest = digest
        }

        /// The whole document in one string; what "has it moved?" compares.
        public var identity: String { "\(photo)|\(develop)|\(digest)" }
    }

    /// The whole picture at ≤4096 long edge, `rgba16Float`, in the same space as the frame textures
    /// (linear P3 or sRGB, per `CanvasPresenter.Storage`). `nil` until one has been made — and then
    /// every present passes `backdrop: nil` and the canvas is 025's edge extrapolation again.
    public private(set) var texture: MTLTexture?
    /// The key `texture` was rendered from.
    public private(set) var key: Key?
    /// The texture's pixel size (diagnostics and the tests: "it is not 0.5 ×, it is 0.4551 ×").
    public private(set) var size: ImageSize?
    /// The picture's own rect inside `texture`.
    ///
    /// The backdrop is rendered with no canvas (`RenderOptions.canvas == nil`), so the picture fills the
    /// texture: origin `(0, 0)`, size == `size`. Stored rather than assumed because the histogram's
    /// consumer needs a rect to measure over, and "the whole picture is the whole texture" is a fact
    /// about *this* render that belongs with the texture.
    public private(set) var content: ImageRect?
    /// Generations that reached the cache. The number the acceptance test pins.
    public private(set) var generationCount = 0
    /// The last generation's own cost, in milliseconds, measured around `graph.render` on the queue.
    public private(set) var lastGenerationMilliseconds: Double = 0
    /// Why the last attempt produced nothing (`nil` after a success).
    public private(set) var lastError: String?

    /// The key a render is running for, if one is. Read by the controller's completion.
    private(set) var inFlight: Key?
    /// Bumped by `invalidate()`. A render that started before a photo switch carries the old value and
    /// is refused, so a stale picture can never be adopted as the new one's backdrop.
    private(set) var serial = 0
    /// Pointer entries that asked for a generation — the same number as `generationCount` when every
    /// render lands. Kept apart so "asked twice, rendered once" is visible rather than assumed.
    public private(set) var requests = 0

    public init() {}

    // MARK: the gate

    /// Is the texture missing or for another document? (**Not** "is it stale": this is the dirty half.)
    public func needsGeneration(for key: Key) -> Bool {
        texture == nil || self.key != key
    }

    /// **The** condition (039): the document has moved *and* the pointer has just entered the canvas.
    ///
    /// A request already in flight for the same key refuses the second entry: two entries 5 ms apart
    /// are one generation, not two, and a render that is already running is the answer.
    public func shouldGenerate(onPointerEnter key: Key) -> Bool {
        guard needsGeneration(for: key) else { return false }
        return inFlight != key
    }

    // MARK: the state machine

    /// Take the request. Returns the serial the completion must present to be accepted.
    @discardableResult
    func begin(_ key: Key) -> Int {
        requests += 1
        inFlight = key
        inFlightSerial = serial
        return serial
    }

    /// A render landed. Returns `false` when it was refused (another photo, or a request that no
    /// longer names the document) — the controller then drops the texture instead of drawing it.
    @discardableResult
    func finish(_ texture: MTLTexture, key: Key, content: ImageRect, milliseconds: Double,
                serial: Int) -> Bool {
        guard serial == self.serial, inFlightSerial == serial, inFlight == key else {
            if inFlight == key { inFlight = nil }
            return false
        }
        inFlight = nil
        self.texture = texture
        self.key = key
        self.size = ImageSize(width: texture.width, height: texture.height)
        self.content = content
        generationCount += 1
        lastGenerationMilliseconds = milliseconds
        lastError = nil
        return true
    }

    /// The render produced nothing (`no render graph yet`, a Metal error): record it and stay dirty, so
    /// the next pointer entry tries again instead of leaving the loupe without a backdrop for the rest
    /// of the document.
    func fail(_ key: Key, error: String) {
        if inFlight == key { inFlight = nil }
        lastError = error
    }

    /// The serial `begin` handed out last — `finish` compares against it so a render started before
    /// `invalidate()` cannot be adopted.
    private var inFlightSerial = 0

    /// A different photo, or the loupe going away: **release** the texture and forget the key.
    ///
    /// Counters survive on purpose — "how many generations did this session make" is a fact about the
    /// session, not about the picture on screen, and the tests read it across a photo switch.
    public func invalidate() {
        serial += 1
        inFlight = nil
        texture = nil
        key = nil
        size = nil
        content = nil
        lastError = nil
    }

    /// No render in flight — wait on this instead of sleeping in a test.
    public var isIdle: Bool { inFlight == nil }
}
