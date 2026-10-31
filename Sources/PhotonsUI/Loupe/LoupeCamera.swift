import CoreGraphics
import PhotonsCore

/// The camera's **target state**: the arithmetic behind every zoom and pan command, with no side
/// effects and no controller state in reach.
///
/// P3 moves the "what should the next `LoupeViewState` be" question out of `LoupeController` and into
/// this value. The controller keeps the one place a camera change is applied (`setViewState`), so the
/// animation, the crop ceiling, the pointer anchor and the pinch accumulator keep their existing
/// semantics — this type only answers with the state those paths should be handed.
public struct LoupeCamera: Equatable, Sendable {

    public var viewport: LoupeViewport
    public var backingScale: Double
    public var cropLimit: Double?

    public init(viewport: LoupeViewport, backingScale: Double, cropLimit: Double?) {
        self.viewport = viewport
        self.backingScale = backingScale
        self.cropLimit = cropLimit
    }

    public var state: LoupeViewState { viewport.state }
    public var zoom: Double { viewport.zoom }

    /// The numeric stop the camera is exactly on, or nil (fit) — `LoupeController.currentZoomStop`.
    ///
    /// `1e-9`, not a fudge factor: the camera is only ever parked on a table value, so "on a stop" is
    /// an equality question about the table's own doubles.
    public var currentStop: Double? {
        guard state.isActualSize else { return nil }
        let zoom = LoupeViewState.clampZoom(state.zoom)
        return LoupeViewState.zoomStops.first { abs($0 - zoom) < 1e-9 }
    }

    /// `"适应 31%"` / `"50%"` / `"33.3%"` — `LoupeController.zoomLabel`'s rule.
    public var label: String {
        guard !state.isActualSize else { return state.zoomLabel }
        return "适应 \(Int((viewport.framing.fitZoom * 100).rounded()))%"
    }

    /// What `⌘=` / `⌘−` should do next; the caller still owns the action.
    public enum Step: Equatable, Sendable {
        case fit
        case actualSize
        case stop(Double)
        case none
    }

    /// Back to the whole frame — `mode = .fit`, with the centre kept as a memory of where to return.
    public func fitted() -> LoupeViewState {
        var next = state
        next.mode = .fit
        return next
    }

    /// 1:1 around a canvas point, capped by the crop workspace's ceiling.
    public func actualSize(aroundView point: CGPoint) -> LoupeViewState {
        let target = min(1, cropLimit ?? Double.infinity)
        return viewport.framing.zooming(state, to: target, aroundView: point,
                                        backingScale: backingScale)
    }

    /// A named stop, snapped **down** onto the ladder before the ceiling is applied.
    public func zoomed(to stop: Double, aroundView point: CGPoint) -> LoupeViewState {
        let ladder = LoupeViewState.snappedLevel(for: LoupeViewState.clampZoom(stop)).zoom
        let target = min(ladder, cropLimit ?? Double.infinity)
        return viewport.framing.zooming(state, to: target, aroundView: point,
                                        backingScale: backingScale)
    }

    /// The next rung up, or 400 % from anything between; from `fit`, 1:1 first.
    public func stepped(inward: Bool) -> Step {
        guard state.isActualSize else { return inward ? .actualSize : .none }
        let current = LoupeViewState.clampZoom(state.zoom)
        if inward {
            let next = LoupeViewState.zoomStops.first { $0 > current + 1e-9 }
                ?? LoupeViewState.maximumZoom
            return .stop(next)
        }
        guard let next = LoupeViewState.zoomStops.last(where: { $0 < current - 1e-9 }) else {
            return .fit
        }
        return .stop(next)
    }

    /// Drag pan: the delta is in **window** points (y up), the content delta in device pixels (y down).
    public func panned(byWindowPoints delta: CGSize) -> LoupeViewState {
        guard state.isActualSize else { return state }
        let content = (x: -Double(delta.width) * backingScale,
                       y: Double(delta.height) * backingScale)
        return viewport.framing.panning(state, byContent: content)
    }

    /// Wheel / two-finger scroll, normalised on `NSEvent.isDirectionInvertedFromDevice`.
    public func scrolled(deltaX: CGFloat, deltaY: CGFloat, precise: Bool,
                         inverted: Bool) -> LoupeViewState {
        guard state.isActualSize else { return state }
        let factor = precise ? backingScale : backingScale * 12
        let sign: Double = inverted ? 1 : -1
        let content = (x: -Double(deltaX) * factor * sign,
                       y: -Double(deltaY) * factor * sign)
        return viewport.framing.panning(state, byContent: content)
    }

    /// Pinch: a continuous accumulator feeding the discrete ladder. `accumulated` is the raw value
    /// carried between events, so the camera can stay on a rung while the gesture keeps moving.
    public func pinched(by factor: CGFloat, aroundView point: CGPoint,
                        accumulated: Double?) -> (state: LoupeViewState, accumulated: Double) {
        guard factor.isFinite, factor > 0 else {
            return (state, accumulated ?? state.zoom)
        }
        let raw = (accumulated ?? viewport.framing.zoom(of: state)) * Double(factor)
        let level = LoupeViewState.snappedLevel(for: raw)
        let target = min(level.zoom, cropLimit ?? Double.infinity)
        let next = viewport.framing.zooming(state, to: target, aroundView: point,
                                            backingScale: backingScale)
        return (next, raw)
    }
}
