import CoreGraphics
import PhotonsCore

/// A viewport plus the zoom/pan state looking through it.
///
/// This is the pure value type the loupe's camera is being split into (P1): `LoupeFraming` already
/// knows the projection (viewport, source, crop), and `LoupeViewState` already knows where the
/// camera is. Putting them in one value lets the three camera operations — zoom about a canvas
/// point, pan by a canvas delta, resize the window — be written as functions of their inputs with no
/// controller state in reach.
///
/// Nothing is wired to this type yet; the controller keeps its own fields until P3/P4.
public struct LoupeViewport: Equatable, Sendable {

    public var framing: LoupeFraming
    public var state: LoupeViewState

    public init(framing: LoupeFraming, state: LoupeViewState = .fit) {
        self.framing = framing
        self.state = state
    }

    /// `framing.zoom(of: state)` — fit 模式是 fitZoom，actual 模式是夹取后的 state.zoom。
    public var zoom: Double {
        framing.zoom(of: state)
    }

    public var isFit: Bool {
        state.mode == .fit
    }

    /// 画布像素点下的源像素（`p` 在画布坐标系，左上原点、y 向下）。
    public func sourcePoint(atCanvas point: CGPoint) -> CGPoint {
        let centre = framing.windowCenter(of: state)
        let canvasCentre = CGPoint(x: Double(framing.viewport.width) / 2,
                                   y: Double(framing.viewport.height) / 2)
        return CGPoint(x: centre.x + (Double(point.x) - Double(canvasCentre.x)) / zoom,
                       y: centre.y + (Double(point.y) - Double(canvasCentre.y)) / zoom)
    }

    /// 以画布点为中心缩放 `factor` 倍；同一源像素在缩放前后仍在该画布点下。
    public func zoomed(aroundCanvas point: CGPoint, by factor: Double) -> LoupeViewport {
        let source = sourcePoint(atCanvas: point)
        let canvasCentre = CGPoint(x: Double(framing.viewport.width) / 2,
                                   y: Double(framing.viewport.height) / 2)
        let z2 = LoupeViewState.clampZoom(zoom * factor)
        let cx = Double(source.x) - (Double(point.x) - Double(canvasCentre.x)) / z2
        let cy = Double(source.y) - (Double(point.y) - Double(canvasCentre.y)) / z2
        // The window size only depends on the new zoom, so the raw centre can be measured first.
        let raw = LoupeViewState(mode: .actual, zoom: z2, centerX: cx, centerY: cy)
        let limited = framing.limitedCenter(x: cx, y: cy, window: framing.windowSize(of: raw))
        return LoupeViewport(framing: framing,
                             state: LoupeViewState(mode: .actual, zoom: z2,
                                                   centerX: limited.x, centerY: limited.y))
    }

    /// 画布位移（拖动）→ 源像素中心位移；fit 模式下不改 state（fit 忽略中心）。
    public func panned(byCanvas delta: CGSize) -> LoupeViewport {
        guard state.mode == .actual else { return self }
        let centre = framing.windowCenter(of: state)
        let z = zoom
        let cx = centre.x - Double(delta.width) / z
        let cy = centre.y - Double(delta.height) / z
        let limited = framing.limitedCenter(x: cx, y: cy, window: framing.windowSize(of: state))
        return LoupeViewport(framing: framing,
                             state: LoupeViewState(mode: .actual, zoom: state.zoom,
                                                   centerX: limited.x, centerY: limited.y))
    }

    /// 窗口尺寸变化：视图替换、模式与中心保留；fit 的数值由 `framing.fitZoom` 重算。
    public func resized(to viewport: ImageSize) -> LoupeViewport {
        var framing = self.framing
        framing.viewport = viewport
        return LoupeViewport(framing: framing, state: state)
    }
}
