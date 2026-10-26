import Foundation

// MARK: - the two parameter streams (派单 011 A)
//
// A develop document holds two kinds of setting, and they part ways at the decoder:
//
//   · **DecodeInputs** — everything that changes the pixels ImageIO hands back: the white balance
//     (`CIRAWFilter.neutralTemperature`/`neutralTint`), the decode recipe, the requested decoder
//     version and the scale. A change here means "the buffer itself is a different picture", so it
//     must **develop again**: a new ladder rung, a new `DecodeCacheKey`, a new on-disk buffer.
//   · **RenderInputs** — everything the GPU stages do *after* the decode: exposure, contrast,
//     highlights/shadows/whites/blacks, curves, colour, masks, geometry. A change here means "draw
//     the buffer I already have differently", and must **never** develop.
//
// Before this split the app decided between the two by ad-hoc comparisons scattered through the
// loupe and the session (派单 009 was reverted over exactly that: white balance edits reached the
// document but not the decode, and a Kelvin change could be answered with the as-shot buffer). The
// rule is one function now — `EditModel.splitFrom(_:)` — and everything that keys a buffer reads
// `DecodeInputs`, everything that keys a render reads `RenderInputs`.
//
// The one property that must hold byte for byte: **as shot adds nothing.** A document that follows
// the file's own balance produces exactly the identity/cache key that the pre-006 code produced, so
// every linear buffer and rung already on disk keeps hitting.

/// Everything that can change the **decoded pixels** — and nothing that cannot.
///
/// `scale` and `recipe` are here rather than in the ladder because they are properties of the
/// development, not of the camera: two rungs of one photo differ in `scale`, and a recipe bump
/// orphans every buffer written by the old recipe.
public struct DecodeInputs: Sendable, Hashable {

    /// The white balance assigned inside the decoder. `.asShot` leaves Apple's own balance alone.
    public var whiteBalance: WhiteBalance
    /// Decoder version requested from the system pipeline; `nil` = whatever Apple defaults to.
    /// Part of the key because a v9 request that silently became v8 is a different buffer.
    public var decoderVersion: String?
    /// Decode scale (1.0 = full). A rung is a scale, so this belongs to the development.
    public var scale: Double
    /// The fixed decode recipe (`DecodeRecipe.current`). Bumped when the settings change.
    public var recipe: String

    /// The neutral development: the file's own balance, no version request, full scale.
    public static let asShot = DecodeInputs()

    public init(whiteBalance: WhiteBalance = .asShot,
                decoderVersion: String? = nil,
                scale: Double = 1,
                recipe: String = DecodeRecipe.current) {
        self.whiteBalance = whiteBalance
        self.decoderVersion = decoderVersion
        self.scale = scale
        self.recipe = recipe
    }

    /// The white-balance component of a decode key — `wb=5500K/+0` — or `nil` for as shot.
    ///
    /// `nil`, not an empty string: as shot must append **nothing at all**, which is what keeps the
    /// pre-006 digest and every pre-009 rung identity byte-identical.
    public var whiteBalanceComponent: String? { whiteBalance.decodeComponent }

    /// A stable, order-independent string for this development. Only decode inputs may enter it.
    public var key: String {
        var parts = ["recipe=\(recipe)",
                     "ver=\(decoderVersion ?? "auto")",
                     String(format: "scale=%.4f", scale)]
        if let wb = whiteBalanceComponent { parts.append(wb) }
        return parts.joined(separator: ";")
    }

    /// `base` for as shot, `base|wb=…` otherwise — the one spelling of a rung identity.
    ///
    /// Used by the loupe's `ladderIdentity` and by the histogram's cache key, so a buffer cannot be
    /// named one way on the way in and another on the way out.
    public func appending(to base: String) -> String {
        guard let wb = whiteBalanceComponent else { return base }
        return "\(base)|\(wb)"
    }
}

/// Everything the render graph reads — the document **without** its decode inputs.
///
/// A thin, explicit wrapper rather than "the rest of the struct": equality on this type is the
/// question "would the pixels differ for the same buffer?", and it is deliberately *insensitive* to
/// temperature/tint, which the buffer has already absorbed.
public struct RenderInputs: Sendable, Equatable {

    /// The document with its decode inputs neutralised (white balance back to as shot). Same crop,
    /// same tone, same curve, same colour, same masks — the decode half says nothing.
    public let edit: EditModel

    public init(_ edit: EditModel) {
        var e = edit
        e.light.temperature = nil
        e.light.tint = nil
        self.edit = e
    }

    /// A stable text over every stage material, in execution order (mask stages included: a mask is
    /// a render input). `n/a` for the display primaries, because those are a property of the surface,
    /// not of the document.
    public var key: String {
        RenderStage.order
            .map { "\($0.rawValue)=\(edit.keyMaterial($0))" }
            .joined(separator: "|")
    }
}

/// What a document change touched. The answer decides the whole pipeline:
///
///   · `.decode` → new `DecodeInputs` → new rung → `DecodeQueue` development → new pixels;
///   · `.render` → same buffer, new `RenderInputs` → one render, **zero** developments;
///   · `.none`   → nothing moved.
public enum EditSplit: String, Sendable, Equatable {
    case none
    case render
    case decode
}

public extension EditModel {

    /// This document's decode inputs. The **only** place a document says what to develop.
    ///
    /// The document keeps its white balance in `light` (one `Codable` blob, 派单 011 A's last
    /// bullet); this property is the derivation, so there is no second stored copy to drift.
    var decodeInputs: DecodeInputs {
        DecodeInputs(whiteBalance: light.whiteBalance,
                     decoderVersion: nil,
                     scale: 1,
                     recipe: DecodeRecipe.current)
    }

    /// The stable decode key: changes **iff** the decoded pixels would change.
    ///
    /// As shot documents all produce the same key (`recipe=…;ver=auto;scale=1.0000`), which is what
    /// makes "the as-shot key never moved" checkable in one string.
    var decodeKey: String { decodeInputs.key }

    /// The render half of the same document.
    var renderInputs: RenderInputs { RenderInputs(self) }

    /// Would these two documents have to develop different buffers?
    func decodesDifferently(from old: EditModel) -> Bool {
        decodeInputs != old.decodeInputs
    }

    /// The one decision function: decode, render, or nothing.
    ///
    /// A white-balance change is `.decode` even when the numbers happen to be the file's own
    /// (`nil` → 5871.6 K is still a decode: assigning a value is not a no-op — 派单 006 measured
    /// 0.15–0.40 % of samples moving). Exposure, contrast, curve, colour, masks and geometry are
    /// `.render`: the buffer is already the right picture.
    func splitFrom(_ old: EditModel) -> EditSplit {
        if decodesDifferently(from: old) { return .decode }
        if renderInputs != old.renderInputs { return .render }
        return .none
    }
}
