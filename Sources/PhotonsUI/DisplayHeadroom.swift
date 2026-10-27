import AppKit
import Foundation
import PhotonsCore

/// What the display can actually show, and the ceiling S4 is allowed to clamp at.
///
/// Two numbers, deliberately kept apart:
///
///   · **headroom** is the render-side contract (`DisplayOptions.headroom`): the upper bound of the
///     display encode in linear scene units, where `1` is SDR white. S4 writes `min(v, headroom)`;
///     at `headroom = 1` that is byte-identical to the pre-EDR output (§11.8).
///   · **maximumExtendedDynamicRangeColorComponentValue** is what AppKit reports for the screen the
///     window is on, as a *multiplier of SDR white* (measured on this machine: 1.2 with the built-in
///     XDR at SDR brightness, 16.0 potential). The "− 1" in the brief is the *extra* above white, so
///     the ceiling handed to S4 is `1 + extra` — i.e. the reported value itself, floored at 1 and
///     capped at the display's own potential. Subtracting without adding back would turn 1.2 into
///     0.2, clamp it to SDR, and make "EDR on" a no-op on exactly the screen that supports it.
///
/// Everything here is pure except `current(for:)`, so the tests can assert the arithmetic and the
/// degradation rules without a display.
public struct DisplayHeadroom: Equatable, Sendable {

    public enum Source: String, Sendable {
        /// The window's screen reported more than SDR white and the layer takes a 16-bit drawable.
        case extendedRange
        /// The screen is SDR (maximum = 1), or its EDR budget is currently 1: no headroom.
        case sdr
        /// The screen claims EDR but the canvas fell back to an 8-bit sRGB drawable.
        case layerRefusedEDR
        /// No window/screen yet (a controller built off-screen, or the window is closing).
        case unknown
    }

    /// SDR: the value S4 has always clamped at.
    public static let sdrHeadroom: Double = 1
    /// `maximumPotentialExtendedDynamicRangeColorComponentValue` on the built-in XDR is 16; nothing
    /// above that is worth letting a 16-bit drawable carry.
    public static let maximumHeadroom: Double = 16

    public var headroom: Double
    public var screenName: String?
    /// The raw AppKit number, kept for the status chip and for the report.
    public var maximumEDRComponent: Double
    public var source: Source

    public init(headroom: Double, screenName: String?, maximumEDRComponent: Double, source: Source) {
        self.headroom = min(max(headroom, Self.sdrHeadroom), Self.maximumHeadroom)
        self.screenName = screenName
        self.maximumEDRComponent = maximumEDRComponent
        self.source = source
    }

    public static let sdr = DisplayHeadroom(headroom: sdrHeadroom, screenName: nil,
                                          maximumEDRComponent: 1, source: .sdr)

    public var isHDR: Bool { headroom > Self.sdrHeadroom + 1e-9 }
    public var isDegraded: Bool { !isHDR }

    /// The render ceiling for one reported value — the `− 1` reading, made safe.
    public static func headroom(fromMaximumEDR maximum: Double) -> Double {
        guard maximum.isFinite else { return sdrHeadroom }
        let extra = max(0, maximum - 1)
        return min(maximumHeadroom, sdrHeadroom + extra)
    }

    /// Resolve the current display. `layerAcceptsEDR` is the presenter's answer after the drawable
    /// format is known: an 8-bit sRGB layer cannot carry values above 1, so the headroom must drop
    /// back to 1 *before* the render, not after a wrong-coloured frame.
    @MainActor
    public static func current(for screen: NSScreen?,
                              layerAcceptsEDR: Bool = true) -> DisplayHeadroom {
        guard let screen else {
            return DisplayHeadroom(headroom: sdrHeadroom, screenName: nil,
                                   maximumEDRComponent: 1, source: .unknown)
        }
        let maximum = screen.maximumExtendedDynamicRangeColorComponentValue
        let headroom = headroom(fromMaximumEDR: Double(maximum))
        let name = screen.localizedName
        if headroom <= sdrHeadroom + 1e-9 {
            return DisplayHeadroom(headroom: sdrHeadroom, screenName: name,
                                   maximumEDRComponent: Double(maximum), source: .sdr)
        }
        guard layerAcceptsEDR else {
            return DisplayHeadroom(headroom: sdrHeadroom, screenName: name,
                                   maximumEDRComponent: Double(maximum), source: .layerRefusedEDR)
        }
        return DisplayHeadroom(headroom: headroom, screenName: name,
                               maximumEDRComponent: Double(maximum), source: .extendedRange)
    }

    // MARK: text

    /// `HDR 显示器 · headroom 1.20×` / `SDR 显示器 · headroom 1.00×`.
    ///
    /// The SDR wording is what a user with a plain monitor sees; the reason it is SDR (no EDR
    /// budget, or the layer refused the 16-bit drawable) is appended so a bug report says which.
    public var displayText: String {
        let number = String(format: "%.2f", headroom)
        guard isHDR else {
            let why: String
            switch source {
            case .sdr: why = ""
            case .layerRefusedEDR: why = "（8-bit 图层）"
            case .unknown: why = "（无窗口）"
            case .extendedRange: why = ""
            }
            return "SDR 显示器 · headroom \(number)×\(why)"
        }
        return "HDR 显示器 · headroom \(number)×"
    }

    /// Everything a frame carries about the display, one line, for logs and `--ui-smoke`.
    public var detailText: String {
        "\(displayText)  [screen \(screenName ?? "—"), max EDR \(String(format: "%.2f", maximumEDRComponent)), \(source.rawValue)]"
    }

    /// Where this screen's ceiling sits on the plot's tail, in stops above display white.
    /// **The one conversion** — the tick, the chip's text and the pointer row's "is this light the
    /// panel can show" all come from here, so they cannot disagree.
    public var ceilingStops: Double { log2(max(headroom, 1)) }

    /// The chip the card paints next to the ceiling tick: `屏 1.70×`. One formatter, because the
    /// number on screen and the number in the log/report have to be the same string.
    public static func ceilingLabel(_ headroom: Double) -> String {
        String(format: "屏 %.2f×", headroom)
    }
}

// MARK: - where the ceiling comes from (2026-10-27)
//
// 派单: 「调节屏幕亮度后要更新直方图中屏幕亮度指示」.
//
// macOS does not announce a brightness change. Dragging the brightness slider moves
// `maximumExtendedDynamicRangeColorComponentValue` — the panel's EDR budget, which is what the ceiling
// tick and the `屏 x.xx×` chip are made of — and posts **no notification at all**. There is no
// `didChangeBrightnessNotification`, and the notifications that do exist
// (`didChangeScreenParameters` / `didChangeBackingProperties` / `didBecomeActive`) only fire when
// something else happens. So a value cached when the window opened is stale for as long as the owner
// leaves the slider where they put it, which is exactly the bug.
//
// The fix is a **provider that is asked, never remembered**: everything that needs the ceiling calls
// `readHeadroom()` again, and that call goes to the live `NSScreen` property every time. The card then
// decides whether the answer moved (`headroomChangeEpsilon`) — an unchanged read costs no repaint.
//
// One type per reason a number could come from: the live screen, and a fixed value a test states.

/// A thing that can be asked what the screen can show **right now**.
///
/// `@MainActor` because `NSScreen`'s EDR properties are only meaningful on the main thread, and because
/// every caller (the card's draw, the timer, the loupe) is on it already.
@MainActor
public protocol HeadroomSource: AnyObject {
    /// The display's budget, read **fresh**. A source that answers from a stored value is not a source.
    func readHeadroom() -> DisplayHeadroom
}

/// The live screen: `window.screen?.maximumExtendedDynamicRangeColorComponentValue`, read on demand.
///
/// `window.screen` and not `NSScreen.main`: the budget belongs to the screen the window is on, and a
/// window parked on an external SDR monitor must not borrow the built-in XDR panel's ceiling.
@MainActor
public final class ScreenHeadroomSource: HeadroomSource {

    /// The window whose screen is the truth. Weak — the card outlives nothing, and a source that kept
    /// its window alive would keep a closed editor's window around.
    public weak var window: NSWindow?
    /// Whether the drawable can carry extended range at all (the presenter's answer, handed in). The
    /// card does not own a layer, so this is the honest default: "if the screen offers headroom, the
    /// plot may assume the canvas can use it".
    public var layerAcceptsEDR: Bool
    /// How many times the screen was actually asked — the counter behind "the provider reads live".
    public private(set) var readCount = 0
    /// The raw AppKit number the last read returned, kept so a report can quote it beside the headroom.
    public private(set) var lastMaximumEDRComponent: Double = 1
    /// The screen the last read resolved to (`nil` when there was no window and no main screen).
    public private(set) var lastScreenName: String?

    public init(window: NSWindow? = nil, layerAcceptsEDR: Bool = true) {
        self.window = window
        self.layerAcceptsEDR = layerAcceptsEDR
    }

    public func readHeadroom() -> DisplayHeadroom {
        readCount += 1
        let screen = window?.screen ?? NSScreen.main
        let resolved = DisplayHeadroom.current(for: screen, layerAcceptsEDR: layerAcceptsEDR)
        lastMaximumEDRComponent = resolved.maximumEDRComponent
        lastScreenName = resolved.screenName
        return resolved
    }
}

/// A stated value — the injection point. The tests drive `headroom` through a sequence
/// (`1.0 → 1.695 → 4.08`) exactly as a brightness slider would move the real one.
@MainActor
public final class FixedHeadroomSource: HeadroomSource {

    /// The number the next read answers. Mutable on purpose: this is the stand-in for the slider.
    public var headroom: Double
    public var screenName: String?
    public private(set) var readCount = 0

    public init(headroom: Double = DisplayHeadroom.sdrHeadroom, screenName: String? = "injected") {
        self.headroom = headroom
        self.screenName = screenName
    }

    public func readHeadroom() -> DisplayHeadroom {
        readCount += 1
        let isHDR = headroom > DisplayHeadroom.sdrHeadroom + 1e-9
        return DisplayHeadroom(headroom: headroom, screenName: screenName,
                               maximumEDRComponent: headroom,
                               source: isHDR ? .extendedRange : .sdr)
    }
}
