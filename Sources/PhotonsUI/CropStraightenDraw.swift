import AppKit
import CoreGraphics
import PhotonsCore

// MARK: - 328 画线拉直: draw a line, straighten to the nearest axis
//
// The angle slider and the ⌘-drag outside the frame both *dial* an angle. This is the third way a
// user says 「把它摆正」 — the one Lightroom's 拉直工具, darktable's straighten gesture and Apple 照片
// all offer: **draw a line along something that should be level (or plumb), let go, and the picture
// turns the short way to make it level**. All three agree on the three properties this file keeps:
//
//   1. the line is drawn on the picture and read as a *direction*, so the picture is turned by the
//      **smallest** angle that puts it on the nearest axis (Lightroom's tool refuses to jump 90°);
//   2. the horizon-vs-vertical choice is the user's, not a menu: `|θ| ≤ 45°` means the line is
//      meant to be horizontal, anything else means vertical (darktable's straighten does the same
//      fold; Apple 照片 hides the decision entirely);
//   3. the applied value is the **existing** `straighten` field, clamped by the **existing**
//      `CropTool.clampStraighten`, so the slider, the bar and this gesture cannot disagree about
//      what the number means.
//
// What is *not* borrowed: none of the three publishes its arithmetic, and none of them has to undo a
// keystone. This file takes the one convention this repository already fixed (`CropTool.straighten`,
// `:589-641`): a document angle `s` turns the drawn picture by `+s` on a y-down canvas
// (`testAStraightenedFrameTurnsWithThePicture`), so a **screen**-space direction at `θ` appears at
// `θ + s` and the correction is `s = −θ` for the horizontal axis, `s = ±90° − θ` for the vertical
// one. **The sign of the correction is therefore the mirror of the hand-rotation gesture's**
// (`CropTool.straighten` returns `start − Δ` for a hand sweep `Δ`): a line, not a sweep, so the same
// convention expresses it as `+θ`.
//
// 328b — **the angle is the one on the screen.** 328 measured it after mapping both ends back to
// source pixels (`FrameTransform.viewPointToSource`, keystone `P⁻¹` included), which is the angle of
// the *thing in the photograph*: with no keystone the two spaces agree, so its 45-line suite was
// green; with one they do not, and it measured the cost itself — `(+30, −15)` and a 20° line came out
// `s = −20.000°`, the photograph level and **the line still 1.69° crooked on screen**. The user draws
// on a screen and judges on a screen (「画一条线，把它校正到横平竖直」), so the number has to be the
// screen's. That is also the one that cancels: the renderer is `P → R` and everything after `R`
// (the AABB placed in the letterbox, zoom, pan) is a uniform scale and a translation, so `R` is a
// rigid rotation of what the user sees and `s` shifts a screen direction by `s`. What is left is the
// canvas's whole-pixel AABB (`perspectiveCanvas` divides by `1/extent` per axis, so the last ~1e−4 of
// shear survives): measured, ≤ 0.2 px on a 600 pt stroke, against 328's 1.69° ≈ 18 px.
// `viewPointToSource` stays for the cross-checks (and, if a caller ever wants it, to ask whether the
// stroke lies on the photograph), never for the angle.

// MARK: - which axis the line is meant to be

/// The axis a drawn line is taken to mean. Chosen by the angle alone (`|θ| ≤ 45°` → horizontal),
/// never by a mode: the user draws, the tool decides, exactly like the three reference tools.
public enum CropStraightenAxis: String, Sendable, Equatable, Hashable {
    case horizontal
    case vertical

    public var label: String {
        switch self {
        case .horizontal: return "横"
        case .vertical: return "竖"
        }
    }

    /// The screen angle the line has to end up at, in degrees (y-down): 0 for 横, ±90 for 竖.
    public var targetDegrees: Double {
        switch self {
        case .horizontal: return 0
        case .vertical: return 90
        }
    }
}

// MARK: - one drawn line, measured

/// Everything one 画线拉直 gesture produced, with the numbers the readout and the tests print.
///
/// `raw` is the correction the line asks for, `applied` is what the document may actually hold
/// (`CropTool.clampStraighten`), and `wasClamped` is the difference — the card's slider reads the
/// **applied** value, so a clamped gesture shows the number that really took effect (§3.4).
public struct CropStraightenDraw: Equatable, Sendable {
    /// The two ends as drawn, in **view points** — what the overlay strokes for 0.3 s, and the
    /// segment whose angle this gesture is about (328b).
    public var start: CGPoint
    public var end: CGPoint
    /// The same two ends in **source pixels** (upright sensor coordinates, keystone undone) — the
    /// material points the stroke picked out of the photograph, kept for the cross-checks and for
    /// 「这条线落在照片上吗」. **Not** where the angle comes from (328b; see `CropDrawStraighten`).
    public var sourceStart: CGPoint
    public var sourceEnd: CGPoint
    /// The line's angle **on the screen**, folded into `(−90°, +90°]`, exactly as the hand drew it —
    /// the canvas's own current straighten included, because that is what the eye saw. (The
    /// correction takes that rotation back out: `s` is the document's absolute angle.)
    public var viewAngle: Double
    /// Which axis the fold put it on.
    public var axis: CropStraightenAxis
    /// The correction the line asks for, before the limit.
    public var raw: Double
    /// The value the document gets: `CropTool.clampStraighten(raw)`.
    public var applied: Double
    /// `true` when the limit changed the number (the readout then shows `applied`, never `raw`).
    public var wasClamped: Bool

    public init(start: CGPoint, end: CGPoint,
                sourceStart: CGPoint, sourceEnd: CGPoint,
                viewAngle: Double, axis: CropStraightenAxis,
                raw: Double, applied: Double, wasClamped: Bool) {
        self.start = start
        self.end = end
        self.sourceStart = sourceStart
        self.sourceEnd = sourceEnd
        self.viewAngle = viewAngle
        self.axis = axis
        self.raw = raw
        self.applied = applied
        self.wasClamped = wasClamped
    }
}

// MARK: - the arithmetic

/// The pure half of 画线拉直: two view points and the projection in, one angle out.
///
/// Nothing here writes a document, touches a view or reads a controller — the same rule `CropTool`
/// follows, so the whole gesture is measurable without a window.
public enum CropDrawStraighten {

    // MARK: constants (§2)

    /// A stroke shorter than this is a misfire, **in view points** — the same unit the hit radii use,
    /// so the threshold is 20 pt on screen at 25 % and at 400 %.
    public static let minimumLengthPoints: Double = 20

    /// The line's own width: 1.5 pt white (§2), plus a 1 px black shadow so it reads over a bright
    /// sky as well as over a dark foreground.
    public static let lineWidth: CGFloat = 1.5
    public static let shadowWidth: CGFloat = 1

    /// §2 — the line stays at full opacity for 0.3 s and then fades out over `fadeSeconds`, so it
    /// never blocks the next gesture but is still there when the eye lands.
    public static let holdSeconds: Double = 0.3
    public static let fadeSeconds: Double = 0.15

    /// The axis decision's boundary, in degrees. Not a tunable: it is the diagonal, the only angle
    /// that is equally far from both axes.
    public static let axisBoundaryDegrees: Double = 45

    // MARK: view → source

    /// A view point (points, y down) in **source pixels**, through the renderer's own inverse.
    ///
    /// `LoupeMapping.sourcePoint` *is* `FrameTransform.viewPointToSource` — the exact walk S0 runs
    /// backwards: letterbox + zoom/pan (S5 → S3), the crop window, `R⁻¹` about the photograph's
    /// centre, the flips, and — 246 — the keystone's inverse homography `P⁻¹`.
    ///
    /// **328b — this is no longer where the angle comes from.** The walk is what makes the four
    /// corners of a keystoned picture map back onto the sensor grid, so it is still the cross-check
    /// (`CropDrawStraightenTests` ②) and it is still how a caller asks where on the photograph a
    /// stroke landed. It is *not* the measurement: `P⁻¹` is a homography, so it bends a direction, and
    /// a correction derived from the bent direction levels the photograph while leaving the screen
    /// crooked (measured, `(+30, −15)` + 20°: 1.69°). The screen is what the user drew on.

    public static func sourcePoint(of point: CGPoint,
                                   mapping: LoupeMapping,
                                   pointScale: Double = 1) -> CGPoint {
        let scale = pointScale > 0 ? pointScale : 1
        let p = mapping.sourcePoint(viewX: Double(point.x) * scale,
                                    viewY: Double(point.y) * scale)
        return CGPoint(x: p.x, y: p.y)
    }

    // MARK: the angle

    /// `atan2` in degrees, y down — the convention every other angle in this tool uses.
    public static func degrees(dx: Double, dy: Double) -> Double {
        atan2(dy, dx) * 180 / .pi
    }

    /// A line has no direction, so `θ`, `θ + 180°` and `θ − 180°` are the same line: fold into
    /// `(−90°, +90°]`. Without this a "\" at −170° would be read as 10° away from vertical and be
    /// turned 80° instead of 10°.
    public static func fold(_ degrees: Double) -> Double {
        guard degrees.isFinite else { return 0 }
        var value = degrees.truncatingRemainder(dividingBy: 180)
        if value > 90 { value -= 180 }
        if value <= -90 { value += 180 }
        return value
    }

    /// §3.2 — `|θ| ≤ 45°` is 「这条线本该是横的」, anything else is 「本该是竖的」.
    public static func axis(forFoldedAngle degrees: Double) -> CropStraightenAxis {
        abs(degrees) <= axisBoundaryDegrees ? .horizontal : .vertical
    }

    /// The `straighten` a line at `degrees` (folded) asks for — §3.3, in `CropTool.straighten`'s
    /// sign convention.
    ///
    /// Derivation, one line: a document angle `s` turns the picture by `s` on the y-down canvas
    /// (`testAStraightenedFrameTurnsWithThePicture`), and `R` sits after the keystone with only a
    /// uniform scale and a translation after it, so a **screen** direction at `θ` appears at `θ + s`
    /// (`328b` — see the file header). For 横 that has to be 0 → `s = −θ`; for 竖 it has to be `±90°`,
    /// and the **short** way is `90° − θ` for a line leaning right and `−90° − θ` for one leaning
    /// left. Either branch is at most 45° of travel, which is why a drawn line can never ask for more
    /// than the document's limit — the fold, not the clamp, is what keeps the number legal.
    public static func correction(foldedAngle degrees: Double,
                                  axis: CropStraightenAxis) -> Double {
        switch axis {
        case .horizontal:
            return -degrees
        case .vertical:
            return degrees > 0 ? 90 - degrees : -90 - degrees
        }
    }

    // MARK: the gesture

    /// One stroke → the correction it means. `nil` when it is too short to be a line (§2: a misfire
    /// is **not applied** and says nothing).
    ///
    /// `nearestAxis` is the reverse gate (internal switch on the controller): with it off the axis is
    /// always 横, which is exactly the bug §4.9② describes — an 83° line then asks for −83° and the
    /// clamp silently turns it 45° instead of 7°.
    ///
    /// `angleOnScreen` is 328b's reverse gate and its default *is* the shipped rule. `false` measures
    /// `θ` after mapping both ends back to sensor pixels — 328's arithmetic, verbatim — so the
    /// keystone acceptance can be seen going red by the keystone's own angular distortion instead of
    /// being taken on faith. Nothing in the app writes it.
    public static func draw(from start: CGPoint,
                            to end: CGPoint,
                            mapping: LoupeMapping,
                            pointScale: Double = 1,
                            limit: Double = CropTool.straightenLimit,
                            nearestAxis: Bool = true,
                            angleOnScreen: Bool = true) -> CropStraightenDraw? {
        let dx = Double(end.x - start.x), dy = Double(end.y - start.y)
        let length = (dx * dx + dy * dy).squareRoot()
        guard length.isFinite, length >= minimumLengthPoints else { return nil }

        // The material points — the pixels the user drew across. `P⁻¹` included, so they are what the
        // picture has to be turned *about*; only the gate asks them for an angle.
        let a = sourcePoint(of: start, mapping: mapping, pointScale: pointScale)
        let b = sourcePoint(of: end, mapping: mapping, pointScale: pointScale)
        guard a.x.isFinite, a.y.isFinite, b.x.isFinite, b.y.isFinite else { return nil }

        // 328b — §1: the angle the user is looking at. Points are proportional to pixels and the
        // letterbox/zoom/pan after `R` is a uniform scale, so this is the angle on the screen whatever
        // the camera is doing; measuring it needs no inverse at all.
        //
        // **One rotation has to come back out of it.** `s` is the document's *absolute* angle, not a
        // delta, and the canvas is drawn at the angle the document already holds (`canvasEdit` — a
        // 转动 tick is draft-only, 088), so the screen shows `θ_P + current`. The angle that `s` has
        // to cancel is `θ_P`, the stroke's direction at straighten 0: `θ_P = θ_view − current`. With
        // no keystone that is exactly 328's source-space angle, which is why 328's numbers survive
        // (§2.3); with one it is the keystone-warped direction and no longer the photograph's.
        let current = mapping.transform?.straightenDegrees ?? 0
        let onScreen = fold(degrees(dx: dx, dy: dy))
        let folded: Double
        if angleOnScreen {
            folded = fold(onScreen - (current.isFinite ? current : 0))
        } else {
            // 328's walk, kept live for the gate: a homography bends the direction it sees.
            let sx = Double(b.x - a.x), sy = Double(b.y - a.y)
            guard (sx * sx + sy * sy).squareRoot() > 1e-9 else { return nil }
            folded = fold(degrees(dx: sx, dy: sy))
        }

        // 竖/横 and the correction both read `folded` — the angle the *picture* has to turn — not the
        // screen angle: `s` is absolute and the ±45 limit is on `s`, so the fold that decides the axis
        // is the fold that keeps the number legal (§3.2/§3.3, unchanged from 328).
        let chosen: CropStraightenAxis = nearestAxis ? axis(forFoldedAngle: folded) : .horizontal
        let raw = correction(foldedAngle: folded, axis: chosen)
        let applied = min(max(raw, -limit), limit)
        return CropStraightenDraw(start: start, end: end,
                                  sourceStart: a, sourceEnd: b,
                                  viewAngle: onScreen, axis: chosen,
                                  raw: raw, applied: applied, wasClamped: raw != applied)
    }

    // MARK: the flash

    /// The line's opacity `elapsed` seconds after the hand let go: 1 for `holdSeconds`, a linear
    /// ramp to 0 over `fadeSeconds`, then nothing. Pure, so 「保留 0.3 s 后淡出」 is a number and not
    /// a hope about a timer.
    public static func alpha(elapsed: Double) -> Double {
        guard elapsed.isFinite else { return 0 }
        if elapsed <= holdSeconds { return 1 }
        let faded = (elapsed - holdSeconds) / fadeSeconds
        if faded >= 1 { return 0 }
        return 1 - faded
    }
}

// MARK: - the line, drawn

/// The 0.3 s line the gesture leaves on the canvas — a white 1.5 pt stroke with a 1 px black shadow,
/// in **view points**, on top of the crop frame.
///
/// It lives in `CropToolOverlayView` rather than in a second view of its own (the mask rubber band
/// has one because it is a different tool): the line is crop chrome, it is drawn with the frame it
/// belongs to, and one overlay means one place where 「the thing on screen」 is decided. The view is
/// `hitTest → nil` like its container, so the fading line never eats the next press.
enum CropStraightenLinePainter {

    /// `1.5 pt` white over `1 px` black — §2's two numbers, in one place so the test can name them.
    static let lineWidth = CropDrawStraighten.lineWidth
    static let shadowWidth = CropDrawStraighten.shadowWidth

    static func path(for stroke: CropToolSegment) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: stroke.a)
        path.line(to: stroke.b)
        path.lineCapStyle = .round
        return path
    }

    /// Draw the stroke at `alpha` (1 during the gesture, then §`CropDrawStraighten.alpha`).
    ///
    /// 337 — `colour` lets 引导线 draw the line the fit **refused** in red while the accepted ones and
    /// 328's straighten line stay white; the default keeps every existing call site's pixels.
    static func draw(_ stroke: CropToolSegment, alpha: Double, colour: NSColor = .white) {
        guard alpha > 0.01 else { return }
        // The shadow first, and wider by one pixel on every side: it is what makes a white line
        // readable over a bright sky (the same trick Brightroom's crop guide does with a dark
        // hairline under its white frame — `CropView._InteractiveCropGuideView.swift:973-1009`).
        let shadow = path(for: stroke)
        shadow.lineWidth = lineWidth + 2 * shadowWidth
        NSColor.black.withAlphaComponent(0.55 * alpha).setStroke()
        shadow.stroke()

        let line = path(for: stroke)
        line.lineWidth = lineWidth
        colour.withAlphaComponent(alpha).setStroke()
        line.stroke()
    }
}
