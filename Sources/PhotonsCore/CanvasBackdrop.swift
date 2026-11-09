import Foundation

/// 315 — the colour of the canvas **around** the picture: one enum, one `current`, every producer.
///
/// Before this type the value existed once (`CanvasPresenter.CanvasMatte`) but was a compile-time
/// constant, so a preference could not move it and a menu could not offer a second one. The default
/// was `0F` (`#0F0F0F`), which the user reported as indistinguishable from the `000000` the frame
/// writes where the photograph does not reach (「0f遮罩太暗了，和00有些区分不开」).
///
/// **Display-referred.** `eightBitValue` is an sRGB-encoded 8-bit code, exactly what an 8-bit screen
/// stores; `linear` is the same colour through the sRGB EOTF for the `rgba16Float` drawable. Neither
/// follows the display's EDR headroom: a matte that brightened with the panel's budget would stop
/// being the neutral the photograph is judged against.
///
/// The stops are spaced so the darkest one separates from the frame's `000000` (contrast ≥ 1.25,
/// 1.29 at `#202020` — the old `0F` was 1.10) and the rest bracket it up to near-white. An
/// intermediate `#2E2E2E` was considered and dropped: at L\* 18.9 it read as the same grey as
/// `#202020`.
public enum CanvasBackdrop: String, CaseIterable, Sendable {
    /// `#202020` — the default. L\* 12.3, 1.29 against `000000`.
    case dark
    /// `#808080` — mid grey. L\* 53.6, 6.4 against `000000`.
    case midGrey
    /// `#E6E6E6` — near white. L\* 91.7, 17.4 against `000000`.
    case light

    /// The display-encoded 8-bit code (`#20`, `#80`, `#E6`).
    public var eightBitValue: UInt8 {
        switch self {
        case .dark: return 0x20
        case .midGrey: return 0x80
        case .light: return 0xE6
        }
    }

    /// The same code as `0…1`, the space every 8-bit path stores.
    public var displayEncoded: Double { Double(eightBitValue) / 255 }

    /// Linear light, for the `rgba16Float` / extended-linear drawable. The same number through the
    /// sRGB EOTF — not a second colour.
    public var linear: Double {
        let v = displayEncoded
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    /// `photons.canvasBackdrop`. The raw value is the persisted form, so a stored stop that this build
    /// does not know (a downgrade, a hand-written preference) falls back to `.dark` instead of
    /// leaving the canvas undefined.
    public static let defaultsKey = "photons.canvasBackdrop"

    /// The stop the canvas is drawn with now. Read on every use rather than cached, so the producers
    /// that are recomputed per frame (the pass's clear colour) cannot lag a change.
    public static var current: CanvasBackdrop {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
              let stored = CanvasBackdrop(rawValue: raw) else { return .dark }
        return stored
    }

    /// Persist a stop and tell the producers that **cache** it to re-read it (`CAMetalLayer`
    /// backgrounds, the photo-switch cover, the grid's surfaces). The pass's clear colour needs no
    /// notification — it asks `current` per present — but the loupe re-presents the frame it already
    /// has so the visible canvas changes in the same turn.
    public static func set(_ value: CanvasBackdrop) {
        UserDefaults.standard.set(value.rawValue, forKey: defaultsKey)
        NotificationCenter.default.post(name: .canvasBackdropDidChange, object: nil)
    }
}

public extension Notification.Name {
    /// Posted by `CanvasBackdrop.set(_:)` after the preference is written.
    static let canvasBackdropDidChange = Notification.Name("photons.canvasBackdropDidChange")
}
