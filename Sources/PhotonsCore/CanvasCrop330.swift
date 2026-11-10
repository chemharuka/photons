import Foundation

// MARK: - 330 · 裁切框是**画布上的矩形**，不是照片上的矩形
//
// 用户的次序（他一直是这么说的）：**先透视 → 再旋转 → 再裁切**。裁切发生在变换**之后**，所以裁切
// 矩形是「变换后的文档画布」（324 的 `photoCanvas` = `photoQuad()` 的 AABB）上的轴对齐矩形。
//
// 330 之前 `GeometryGroup.crop` 是**源（照片）空间**的归一化矩形：透视把那个矩形映到屏幕上就是
// 一个四边形，于是「透视把裁剪框也透视了」。裁切框是「输出什么」的定义，它不参与透视，所以它必须
// 住在一个**不参与透视**的坐标系里 —— 画布空间。
//
// 两种空间，一个显式标记（`GeometryGroup.cropSpace`）：
//
//   · `.source`（0，旧文档）= 裁切矩形量在照片上（301/307/317/324 的全部算术）；
//   · `.canvas`（1，新文档）= 裁切矩形量在文档画布上，轴对齐，四边永远横平竖直。
//
// `keystone == 0` 时两者**逐字节等价**（没有透视就没有四边形可弯），所以旧文档一个字节都不动，
// 迁移只发生在真的带透视的文档上（`GeometryGroup.migrateCropToCanvasSpace(source:)`）。
//
// 采样只有一条映射：`CropMath.documentCanvas` 就是 `perspectiveCanvas(crop: .full, …)` ——
// 导出用的那条 `P → R` 的 3×3，一像素不改；裁切只是从它上面**切一个窗口**（`CropMath.canvasCrop`，
// 一个归一化仿射乘在同一个 `sampling` 的右边）。没有第二份逆映射可以漂移。

/// **裁切矩形量在哪个空间。** `GeometryGroup.cropSpace` 的取值范围。
///
/// 默认 `.source`：任何没有这个键的文档（=`cropSpace` 缺省）都是源空间，解读与 330 之前逐字节相同。
public enum CropSpace: Int, Sendable, Codable, Hashable, CaseIterable {
    /// 照片（源）空间 —— 330 之前所有文档的含义。归一化到 `orientedSource`。
    case source = 0
    /// **文档画布**空间 —— 透视 + 旋转之后那张画布（324 的 `photoCanvas`）上的轴对齐矩形。
    case canvas = 1

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(Int.self)
        self = CropSpace(rawValue: raw) ?? .source
    }

    /// 键材料里的记号：`cs=1`。`.source` 不写，旧文档的几何键逐字节不变。
    public var keyToken: String? {
        switch self {
        case .source: return nil
        case .canvas: return "cs=1"
        }
    }
}

public extension CropMath {

    // MARK: the one document mapping

    /// **文档画布映射**：photo-normalized → document-canvas-normalized，任意文档。
    ///
    /// 这不是新的一条映射，而是**导出那条映射在 `.full` 上的取值**：`perspectiveCanvas(crop: .full, …)`
    /// 的 forward 恰好就是 324 的 `documentPointInCanvas` 走的 `P → R → −AABB origin`（无透视时 `P = I`，
    /// 面积就是 `rotatedExtent(source)`）。所以导出、overlay、夹取、迁移读的是同一个 `sampling`。
    static func documentCanvas(source: ImageSize, straightenDegrees: Double,
                               perspective: PerspectiveMap?) -> PerspectiveCanvas {
        perspectiveCanvas(crop: .full, in: source,
                          straightenDegrees: straightenDegrees,
                          perspective: perspective ?? PerspectiveMap(vertical: 0, horizontal: 0))
    }

    /// **从文档画布上切一个窗口** —— 画布空间的裁切矩形就是这条窗口。
    ///
    /// `crop` 是画布归一化坐标（`[0,1]²` = 整张画布）。返回的画布：
    ///   · `extent` = 窗口的连续像素尺寸（渲染器按它归一化，`ceil` 只加边不缩放）；
    ///   · `sampling` = `document.sampling · [[w,0,left],[0,h,top],[0,0,1]]`，一个 3×3 乘法，
    ///     左边的 `sampling` 一个数都没重算 —— 这就是「复用导出那条映射」的字面意思。
    static func canvasCrop(document: PerspectiveCanvas, crop: CropRect) -> PerspectiveCanvas {
        let c = crop.clamped(allowsOutsideSource: true)
        let extent = DSize(width: document.extent.width * c.width,
                           height: document.extent.height * c.height)
        let size = ImageSize(width: CropGeometry.canvasPixels(extent.width),
                             height: CropGeometry.canvasPixels(extent.height))
        let window: [[Double]] = [[c.width, 0, c.left],
                                  [0, c.height, c.top],
                                  [0, 0, 1]]
        let sampling = PerspectiveMap.multiply(document.sampling, window)
        let forward = PerspectiveMap.invert(sampling)
        return PerspectiveCanvas(size: size, extent: extent,
                                 originX: document.originX + c.left * document.extent.width,
                                 originY: document.originY + c.top * document.extent.height,
                                 frame: extent, sampling: sampling, forward: forward)
    }
}

public extension CropGeometry {

    // MARK: which space

    /// **330 reverse gate — never true in the app.** Setting this restores the pre-330 walk for a
    /// canvas-spaced crop: `documentQuad` warps the rect through `P → R` again (a quadrilateral), and
    /// `exportPerspectiveCanvas` samples through 246's map of the *crop's own quad* instead of the
    /// document canvas. It exists so 验收 ①/② can be turned **red on purpose**, from a test, without
    /// editing the implementation — the same door `CropToolController.clampsFrameToView` and
    /// `RenderKeyChain.materialWithoutAlgorithmVersion` are.
    nonisolated(unsafe) static var pre330SourceSpace = false

    /// `true` when `crop` is a rectangle of the **document canvas** (330's new documents).
    var cropIsCanvasSpaced: Bool { cropSpace == .canvas }

    /// The crop as a rectangle of the **document canvas**, in canvas-normalized coordinates.
    ///
    /// · `.canvas` — `crop` itself: it already is one.
    /// · `.source` — the AABB of the crop's image under `P → R`, normalized by `photoQuadExtent`.
    ///   That is exactly the box the pre-330 renderer exported (246's `P → R → AABB`), which is why
    ///   this is also the migration's arithmetic (`GeometryGroup.migrateCropToCanvasSpace`).
    var canvasCrop: CropRect {
        if cropIsCanvasSpaced { return crop }
        return canvasRect(fromSource: crop)
    }

    /// `rect` (source-normalized) as the AABB of its image on the document canvas — canvas-normalized.
    ///
    /// The walk is `documentPointInCanvas` (P → R → −AABB origin), which is *unconditionally* the
    /// photograph-to-canvas map — it does not read `cropSpace`, which is what makes this the right
    /// primitive for the migration and for the `.source` branch of `canvasCrop`.
    func canvasRect(fromSource rect: CropRect) -> CropRect {
        let e = photoQuadExtent
        let w = max(e.width, 1e-9), h = max(e.height, 1e-9)
        let corners = [(rect.left, rect.top), (rect.right, rect.top),
                       (rect.right, rect.bottom), (rect.left, rect.bottom)]
            .map { documentPointInCanvas(normalizedX: $0.0, $0.1) }
        let xs = corners.map(\.x), ys = corners.map(\.y)
        return CropRect(left: (xs.min() ?? 0) / w, top: (ys.min() ?? 0) / h,
                        right: (xs.max() ?? w) / w, bottom: (ys.max() ?? h) / h)
    }

    /// The inverse AABB: a canvas-normalized rect back on the photograph, in source-normalized
    /// coordinates. The copy/paste path uses it when a canvas-spaced crop is pasted into a document
    /// that still measures its crop on the photograph.
    func sourceRect(fromCanvas rect: CropRect) -> CropRect {
        let e = photoQuadExtent
        let corners = [(rect.left, rect.top), (rect.right, rect.top),
                       (rect.right, rect.bottom), (rect.left, rect.bottom)].map { corner in
            photoNormalized(documentX: corner.0 * e.width, corner.1 * e.height)
        }
        let xs = corners.map(\.x), ys = corners.map(\.y)
        return CropRect(left: xs.min() ?? 0, top: ys.min() ?? 0,
                        right: xs.max() ?? 1, bottom: ys.max() ?? 1)
    }

    /// The region a crop rect may occupy, **in the crop's own coordinates**.
    ///
    /// `.source`: the document canvas walked back to photo coordinates (307/324's
    /// `documentCanvasCropRect`) — `[0,1]²` at every right angle.
    /// `.canvas`: the canvas itself, `[0,1]²`, because the crop's coordinates *are* the canvas'.
    var cropLegalRect: CropRect {
        cropIsCanvasSpaced ? .full : documentCanvasCropRect
    }

    // MARK: the export canvas

    /// The document canvas' own mapping (the whole photograph after `P → R`), independent of the crop.
    var documentCanvasMap: PerspectiveCanvas {
        CropMath.documentCanvas(source: source, straightenDegrees: rotationDegrees,
                                perspective: perspective)
    }

    /// **The export canvas of this document**, or `nil` when the legacy path already describes it.
    ///
    /// · `.canvas` — the crop is a window on `documentCanvasMap`; `CropMath.canvasCrop` cuts it. This
    ///   is the one place the renderer, the loupe and the overlay read the export's pixel grid from.
    /// · `.source` — 246's `P → R → AABB` of the warped crop, byte for byte (and `nil` with no
    ///   keystone, which is the pre-246 path).
    var exportPerspectiveCanvas: PerspectiveCanvas? {
        if cropIsCanvasSpaced {
            // 330 reverse gate (see `pre330SourceSpace`): the pre-330 sampling, for 验收 ② to go red.
            if CropGeometry.pre330SourceSpace, let naive = naiveSourceCropCanvas { return naive }
            return CropMath.canvasCrop(document: documentCanvasMap, crop: crop)
        }
        guard let perspective, perspective.hasWarp else { return nil }
        return CropMath.perspectiveCanvas(crop: crop, in: source,
                                          straightenDegrees: rotationDegrees,
                                          perspective: perspective)
    }

    /// The naive map a canvas-spaced implementation must **not** use: the keystone applied to the
    /// crop's own quad instead of to the document canvas (the reverse gate of 验收 ②). Kept as a named
    /// alternative so the gate can be measured rather than described.
    var naiveSourceCropCanvas: PerspectiveCanvas? {
        guard let perspective, perspective.hasWarp else { return nil }
        return CropMath.perspectiveCanvas(crop: crop, in: source,
                                          straightenDegrees: rotationDegrees,
                                          perspective: perspective)
    }
}

public extension EditModel {
    /// 330 — the document door to the crop migration, the sibling of `migrateHealSpots`: one call for
    /// the session, the history and the tests, so the geometry group is never migrated "by hand".
    @discardableResult
    mutating func migrateCropToCanvasSpace(sourceSize: ImageSize) -> Bool {
        geometry.migrateCropToCanvasSpace(source: sourceSize)
    }
}
