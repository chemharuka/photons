import CoreGraphics
import Foundation

// MARK: - 082 (用户追加): 「裁切框 ⊆ 画布」——缩放与平移合成的那一个不变式
//
// 用户 2026-10-28 的原话：
//
//   > 裁切模式下，缩放与平移合成一个不变式：任何时候 裁切框 ⊆ 画布（图像）。缩放不外放大到框出画布，
//   > 平移不把框推出画布。简单、可解释，不要惯性/回弹/自适应。
//
// 所以这里只有一个几何事实和一个函数，没有第二套投影：
//
//     screen(e) = (e − centre) · zoom + canvas / 2        (e 是框在源像素里的边)
//
// 它**不是**新公式：`LoupeMapping.frameView` 在 `.actual` 相机下逐项就是这个（`contentWidth` 等于
// viewport、`cropWidth` 等于 `viewport / zoom`，两项相消），在 `.fit` 相机下也一致（`originX` 的
// letterbox 项与 `zoom = fitZoom`、`centre = 框中心` 相消）。测试用真实的 `CropToolLayout` 的四角
// 与它对比到 0.5 pt，所以这两处不可能各说一套。
//
// 由它直接读出两件事：
//
//   · **最大可放级别** `maxZoom = min(canvasW / frameW, canvasH / frameH)` —— 两轴里更紧的那个，
//     就是「框恰好内接于画布」的那一级。请求超过它 → 停在它上面（读数也是它，不是用户请求值）。
//   · **合法的平移区间**：`centre.x ∈ [frame.right − canvas/2z, frame.left + canvas/2z]`（y 同理）。
//     框被挤出边缘时把**画面**（相机的 centre）挪回来，不动框 —— 框是用户画的那四条边。
//
// `maxZoom` 永远由**当前的画布尺寸与框尺寸**算出来，没有常量：改窗口、换照片、拖手柄都会变。
public struct CropCanvasClamp: Equatable, Sendable {

    /// A camera as this type sees it: the app's own zoom (canvas pixels per source pixel) and the
    /// source-pixel centre of the window. `LoupeViewState` is the shape this is read out of, but the
    /// type stays free of it so the geometry can be measured on its own.
    public struct Camera: Equatable, Sendable {
        public var zoom: Double
        public var centerX: Double
        public var centerY: Double

        public init(zoom: Double, centerX: Double, centerY: Double) {
            self.zoom = zoom
            self.centerX = centerX
            self.centerY = centerY
        }
    }

    /// A closed interval in source pixels (one axis of the window centre).
    public struct Span: Equatable, Sendable {
        public var lower: Double
        public var upper: Double

        public init(lower: Double, upper: Double) {
            self.lower = lower
            self.upper = upper
        }

        public var isEmpty: Bool { !(upper >= lower) }

        public func clamp(_ value: Double) -> Double {
            guard !isEmpty else { return (lower + upper) / 2 }
            return min(max(value, lower), upper)
        }
    }

    // MARK: the one limit

    /// The largest zoom at which `frame` still fits entirely inside `canvas`: **the level where the
    /// crop frame is exactly inscribed in the canvas**. Never a constant — it is the two dimensions'
    /// tightest ratio, so a smaller canvas or a bigger frame lowers it by itself.
    ///
    /// 169 §0: the arithmetic now lives in `CropWorkspaceLayout` (the workspace's one layout truth);
    /// this spelling delegates so the camera clamp and the layout cannot answer differently.
    ///
    /// `0` for a degenerate input (no canvas, no frame): the caller reads that as "no camera is legal"
    /// rather than dividing by zero.
    public static func maxZoom(canvas: CGSize, frame: CGRect) -> Double {
        CropWorkspaceLayout.maxZoom(canvas: canvas, frame: frame)
    }

    /// The zoom a request is allowed to reach. Above the limit it **stops at the limit** (no bounce,
    /// no spring — the value simply is not exceeded), below it the request stands untouched.
    public static func clampZoom(_ requested: Double, canvas: CGSize, frame: CGRect) -> Double {
        let limit = maxZoom(canvas: canvas, frame: frame)
        guard limit > 0 else { return requested }
        let z = requested.isFinite ? requested : limit
        return min(z, limit)
    }

    // MARK: the two axes of the pan

    /// The window centre's legal interval on each axis at `zoom` — the set of centres for which
    /// `frame ⊆ canvas` still holds.
    public static func panLimits(canvas: CGSize, frame: CGRect, zoom: Double) -> (x: Span, y: Span) {
        let cw = Double(canvas.width), ch = Double(canvas.height)
        let z = zoom.isFinite && zoom > 0 ? zoom : maxZoom(canvas: canvas, frame: frame)
        let halfW = cw / 2 / max(z, 1e-9)
        let halfH = ch / 2 / max(z, 1e-9)
        return (Span(lower: Double(frame.maxX) - halfW, upper: Double(frame.minX) + halfW),
                Span(lower: Double(frame.maxY) - halfH, upper: Double(frame.minY) + halfH))
    }

    /// The nearest legal centre to `(x, y)`. Each axis is clamped on its own, so a pan that only
    /// runs off the right edge slides back horizontally and leaves the vertical position alone.
    ///
    /// This is the **auto-pan** of step 3: the picture (the window centre) moves, the crop frame keeps
    /// its four edges. It is a clamp of the requested value, never an accumulation, so reversing the
    /// gesture moves the picture again on the very next tick (no sticky edge, no rubber band).
    public static func clampCenter(x: Double, y: Double, canvas: CGSize, frame: CGRect,
                                   zoom: Double) -> (x: Double, y: Double) {
        let limits = panLimits(canvas: canvas, frame: frame, zoom: zoom)
        return (limits.x.clamp(x.isFinite ? x : limits.x.lower),
                limits.y.clamp(y.isFinite ? y : limits.y.lower))
    }

    /// **The one entry point**: a requested camera in, the legal camera out. Zoom first (step 2), then
    /// the centre at that zoom (step 3) — the order matters, because the pan interval depends on the
    /// zoom the request actually gets.
    public static func fit(zoom: Double, center: (x: Double, y: Double),
                           canvas: CGSize, frame: CGRect) -> Camera {
        let z = clampZoom(zoom, canvas: canvas, frame: frame)
        let centre = clampCenter(x: center.x, y: center.y, canvas: canvas, frame: frame, zoom: z)
        return Camera(zoom: z, centerX: centre.x, centerY: centre.y)
    }

    // MARK: what the invariant is measured with

    /// The crop frame's rect on the canvas, in the same pixels `canvas` is given in. The three lines
    /// below **are** the invariant: `frameRect(...) ⊆ CGRect(origin: .zero, size: canvas)` iff the
    /// camera is legal.
    public static func frameRect(canvas: CGSize, frame: CGRect, zoom: Double,
                                 center: (x: Double, y: Double)) -> CGRect {
        let z = zoom.isFinite ? zoom : 0
        let midX = Double(canvas.width) / 2, midY = Double(canvas.height) / 2
        let left = (Double(frame.minX) - center.x) * z + midX
        let top = (Double(frame.minY) - center.y) * z + midY
        return CGRect(x: left, y: top,
                      width: Double(frame.width) * z,
                      height: Double(frame.height) * z)
    }

    /// `frame ⊆ canvas`, the acceptance's own predicate — with `tolerance` for a float's last bit
    /// (`0` is the honest value; the tests pass 0.5 pt where they measure on screen).
    public static func contains(_ inner: CGRect, in outer: CGRect,
                                tolerance: Double = 0) -> Bool {
        let t = tolerance
        return Double(inner.minX) >= Double(outer.minX) - t
            && Double(inner.minY) >= Double(outer.minY) - t
            && Double(inner.maxX) <= Double(outer.maxX) + t
            && Double(inner.maxY) <= Double(outer.maxY) + t
    }
}
