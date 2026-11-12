import XCTest
import Metal
import PhotonsCore
@testable import PhotonsUI

/// 397 验收 —— `renderCrop` 的锁定比例必须按 **crop 所在的空间**换算。
///
/// 用户口径：
///
///   > 说明 lockedCrop 有问题，而且选择了 lockedCrop 后，选择不出像素，拖动/调整裁剪框大小也很不跟手
///   > 裁剪框选择为自由就没问题
///
/// 自由比例是一把钥匙：`.original` 时 `lockedCrop` 直接返回原 rect（没有比例就没有换算），所以
/// 「只有锁定才会坏」把范围锁到「重塑时用了哪个像素格」。裁剪框在 `.canvas` 空间（330），它的单位是
/// **文档画布** `photoQuadExtent`（这张照片 6552.887×9657.745，也就是 6060.3×9105.8 的导出画布）；
/// `renderCrop` 却一直用 `orientedSource`（6336×9520，导出 6060.3×8931.8）。同一把锁于是被解释成
/// 两个矩形：0.6785 与 0.6655，差 1.948 %。
///
/// 判据全部从**像素**来，不引用几何中间量，也不硬编码 35 px：
///
///   · ① 把文档渲染成一帧竖向画布视口（宽 1207 = 截图里的画面宽度，高 1207 / 锁 = 1813），
///     逐行数 `canvasRect` 内的纯黑行 —— 照片盖住画布 ⇒ 0 行。
///   · ⑧ 反向门不靠改生产代码：把 `cropRect` 换成**旧算术的答案**并把 lock 设成 `.original`，
///     `renderCrop` 就逐位返回那个矩形（`.original` 无比例），下游一切都是改动前的样子 —— 同一个
///     视口下必须重新出现那条黑带。这样门的红是「同一个渲染器的同一帧」，不是另算一遍几何。
@MainActor
final class CropLockUnits397Tests: XCTestCase {

    /// 用户照片（`~/Desktop/austria/L1030465.dng`）。
    static let stored = ImageSize(width: 9520, height: 6336)
    /// 25 % 档位：60 Mpx 文件在这一档上是 2380×1584，一帧不到 4 Mpx。
    static let decodeScale = 0.25
    /// §1.1 的真实 geometry，一个字符都不改。
    static let lock = 0.6655462185
    static let storedRect = NormalizedRect(x: 0.0646674912628925, y: 0.017063620705231153,
                                          width: 0.9248324293246755, height: 0.9428481909928997)
    /// 截图的视口宽度（§1.2：画面 `x 57…1263`，宽 1207）。
    static let viewportWidth = 1207

    /// 用户文档：quarterTurns = 1（画布竖向）、`.canvas` 裁剪、锁定 0.6655、透视 +31.7127、拉直 −1.1667。
    static func userDocument(lock: AspectLock = .custom(CropLockUnits397Tests.lock)) -> EditModel {
        var edit = EditModel.neutral
        // 几何测试：锐化会在画布边缘看到不同的邻域，与空间无关。
        edit.sharpen = SharpenGroup(amount: 0, radius: 2.0, detail: 25, masking: 0)
        edit.geometry.quarterTurns = 1
        edit.geometry.crop = storedRect
        edit.geometry.cropSpace = .canvas
        edit.geometry.aspectLock = lock
        edit.geometry.perspectiveVertical = 31.712741686055033
        edit.geometry.rotationDegrees = -1.166707175774583
        return edit
    }

    // MARK: - 一帧画布视口渲染

    private func image(_ w: Int, _ h: Int) -> LinearImage {
        // 每个纹素都点着：于是「这里有没有照片」是回读能答的问题。四边更亮，画面自身的边也能看见。
        var rgba = [Float16](repeating: 0.18, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let edge = x < 6 || y < 6 || x >= w - 6 || y >= h - 6
                let v: Float16 = edge ? 0.9 : 0.18
                let o = (y * w + x) * 4
                rgba[o] = v; rgba[o + 1] = v; rgba[o + 2] = v; rgba[o + 3] = 1
            }
        }
        return LinearImage(width: w, height: h, rgba: rgba,
                           colorSpace: "sRGB", decoderVersion: "crop-lock-units-397")
    }

    struct Frame {
        let result: RenderResult
        let texture: MTLTexture
        let graph: RenderGraph
        /// `canvasRect` 里**每一行都是纯黑**的行数（逐 texel `r+g+b == 0`）。
        let blackRows: Int
        let blackRowsAtTop: Int
        let blackRowsAtBottom: Int
        let height: Int
        var blackFraction: Double { Double(blackRows) / Double(max(height, 1)) }
    }

    /// 用户看的那一帧：竖向画布视口、无窗口、`.export` 角色（工作区/导出那一帧）。
    private func render(_ edit: EditModel, viewport: ImageSize) throws -> Frame {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let ds = Self.decodeScale
        let decoded = ImageSize(width: Int((Double(Self.stored.width) * ds).rounded()),
                                height: Int((Double(Self.stored.height) * ds).rounded()))
        let graph = try RenderGraph(input: RenderInput(image: image(decoded.width, decoded.height),
                                                      identity: "crop-lock-units-397-\(viewport.keyString)"))
        let framing = LoupeFraming(viewport: viewport, decoded: decoded, decodeScale: ds,
                                   edit: edit, canvasRole: .export)
        let result = try graph.render(edit, options: RenderOptions(
            canvas: viewport,
            scale: framing.renderScale(of: .fit, decodeScale: ds), outputWindow: nil,
            display: DisplayOptions(primaries: .sRGB, bitDepth: 8, headroom: 1),
            useCache: false, wantsPixels: false, source: .edited))
        let t = try XCTUnwrap(result.output, "the render produced no texture")
        let w = t.width, h = t.height
        var raw = [UInt16](repeating: 0, count: w * h * 4)
        raw.withUnsafeMutableBytes { buf in
            t.getBytes(buf.baseAddress!, bytesPerRow: w * 8,
                       from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        }
        func lit(_ y: Int, _ x: Int) -> Bool {
            let o = (y * w + x) * 4
            return raw[o] != 0 || raw[o + 1] != 0 || raw[o + 2] != 0
        }
        let canvas = result.canvasRect
        func rowBlack(_ y: Int) -> Bool {
            for x in canvas.x..<canvas.maxX where lit(y, x) { return false }
            return true
        }
        var rows = 0
        for y in canvas.y..<canvas.maxY where rowBlack(y) { rows += 1 }
        var top = 0
        for y in canvas.y..<canvas.maxY { if rowBlack(y) { top += 1 } else { break } }
        var bottom = 0
        for y in stride(from: canvas.maxY - 1, through: canvas.y, by: -1) {
            if rowBlack(y) { bottom += 1 } else { break }
        }
        return Frame(result: result, texture: t, graph: graph, blackRows: rows,
                     blackRowsAtTop: top, blackRowsAtBottom: bottom, height: canvas.height)
    }

    /// 一个恰好装下竖向画布的视口：宽 1207（截图里画面的宽度）、高 1207 ÷ 锁定比例 —— §1.2 算出的
    /// 1813.5，取整 1813。这一帧的画布**填满**纹理（`canvasRect == content`），所以量到的只能是
    /// 「照片盖不盖得住画布」，不掺 letterbox 的取整。
    static var userViewport: ImageSize {
        ImageSize(width: viewportWidth, height: Int(Double(viewportWidth) / lock))
    }

    // MARK: - ① 用户照片：画布里零纯黑行

    /// **①** §1.1 的真实 geometry，竖向画布视口帧，断言 `canvasRect` 内的**纯黑行数 == 0**。
    ///
    /// 判据按**比例**：同一个断言写成 `blackFraction == 0`；像素数随窗口/档位变，比例不变。
    func testUserDocumentHasNoBlackRowsInsideTheCanvas() throws {
        let viewport = Self.userViewport
        let document = Self.userDocument()
        let frame = try render(document, viewport: viewport)
        defer { frame.graph.recycle(output: frame.texture) }

        let cg = CropGeometry(geometry: document.geometry, source: Self.stored)
        let crop = document.geometry.renderCrop(source: Self.stored)
        let ratioOnCanvas = crop.width * cg.photoQuadExtent.width
            / (crop.height * cg.photoQuadExtent.height)
        print("397 ① viewport \(viewport.keyString) · canvas \(frame.result.canvas.keyString) "
              + "· content \(frame.result.content.keyString) "
              + "· drawnRect \(frame.result.drawnRect.keyString) "
              + "· canvasRect \(frame.result.canvasRect.keyString)")
        print("397 ① renderCrop \(crop.keyString) · pixel ratio on the canvas grid "
              + String(format: "%.10f", ratioOnCanvas) + " · lock \(Self.lock)")
        print("397 ① black rows inside canvasRect: \(frame.blackRows) of \(frame.height) = "
              + String(format: "%.5f%%", 100 * frame.blackFraction)
              + " · top \(frame.blackRowsAtTop) · bottom \(frame.blackRowsAtBottom)")

        XCTAssertEqual(frame.blackRows, 0,
                       "397 ① 画布内有 \(frame.blackRows) 行纯黑（"
                       + String(format: "%.3f%%", 100 * frame.blackFraction)
                       + " of the canvas) — 照片没盖住画布")
    }

    // MARK: - ② 锁定比例与实际像素一致

    /// **②** `renderCrop` 返回的 rect 按**画布单位**换算出的像素比例，与 `aspectLock.ratio` 的偏差
    /// `< 0.01 %`（= 1e-4 相对）。
    ///
    /// 旧算术在这里是 1.948 %（0.678511 vs 0.665546），正是 ① 的黑带。
    func testRenderCropPixelRatioMatchesTheLock() throws {
        let document = Self.userDocument()
        let cg = CropGeometry(geometry: document.geometry, source: Self.stored)
        let e = cg.photoQuadExtent
        print("397 ② canvas grid (photoQuadExtent) "
              + String(format: "%.4f × %.4f", e.width, e.height))
        for (name, lock) in [("custom 0.6655", AspectLock.custom(Self.lock)),
                             ("1:1", AspectLock.square),
                             ("3:2", AspectLock.threeTwo),
                             ("4:3", AspectLock.fourThree),
                             ("16:9", AspectLock.sixteenNine)] {
            var doc = document
            doc.geometry.aspectLock = lock
            let crop = doc.geometry.renderCrop(source: Self.stored)
            let pixelRatio = crop.width * e.width / (crop.height * e.height)
            let expected = try XCTUnwrap(lock.ratio)
            let error = abs(pixelRatio - expected) / expected
            print("397 ② \(name): rect \(crop.keyString) · on the canvas grid "
                  + String(format: "%.4f × %.4f px", crop.width * e.width, crop.height * e.height)
                  + " = " + String(format: "%.10f", pixelRatio)
                  + " vs lock " + String(format: "%.10f", expected)
                  + " · error " + String(format: "%.8f%%", 100 * error))
            XCTAssertLessThan(error, 1e-4,
                              "397 ② \(name): the locked rect is \(100 * error)% off its own ratio")
        }
    }

    /// **③b** 相机的 crop 与渲染器的 crop 是同一个矩形 —— 「镜头框的那张画」= 「画出来的那张画」。
    ///
    /// `LoupeFraming.init(decoded:)` 也曾自己按源图格换一次比例，于是相机描述 6061×8932 的画面、
    /// S0 画出 6061×9106 的画面：适应停短、框不跟手。现在它问 `renderCrop`，这里把「同一个
    /// decoded 格上两者逐位相同」钉住。
    func testTheCameraFramesTheRectTheRendererDraws() {
        let document = Self.userDocument()
        let decoded = ImageSize(width: 2380, height: 1584)     // 25 % of 9520×6336
        let render = document.geometry.renderCrop(source: decoded)
        for role in [CanvasRole.export, CanvasRole.document] {
            let framing = LoupeFraming(viewport: Self.userViewport, decoded: decoded,
                                       decodeScale: Self.decodeScale, edit: document,
                                       canvasRole: role)
            print("397 ③b \(role): framing.crop \(framing.crop.keyString) "
                  + "· renderCrop \(render.keyString) · equal \(framing.crop == render) "
                  + "· cropPixels " + String(format: "%.4f × %.4f",
                                             framing.cropWidthPixels, framing.cropHeightPixels))
            XCTAssertEqual(framing.crop, render,
                           "397 ③b \(role): 相机的 crop 与渲染的 crop 不是同一个矩形")
        }
        // 而它确实**不是**源图格那份答案 —— 否则两条错答相等时也会绿。
        let sourceGrid = CropMath.lockedCrop(document.geometry.aspectLock,
                                             in: document.geometry.cropRect,
                                             source: document.geometry.orientedSource(decoded))
        print("397 ③b source-grid lockedCrop \(sourceGrid.keyString) · differs \(sourceGrid != render)")
        XCTAssertNotEqual(sourceGrid, render, "397 ③b 修复没生效：相机仍在用源图格")
    }

    // MARK: - ③ 拖动与渲染同基准
    /// **③** 同一个 geometry 下，拖动路径（`CropTool.projection(...).units`）与 `renderCrop` 用的
    /// units **数值相等**；并打印自己算的 `photoQuadExtent` —— 三者相等才算真的同基准（规格 §5.1）。
    ///
    /// 拖动路径的角度是 `framing.transform.straightenDegrees`（文档的）**加**本 group 的角度；
    /// 静止时后一项是 0（`overlayGeometry.rotationDegrees` = 草稿 − 文档 = 0），所以这里传 0 ——
    /// 传 `straightenDegrees` 会把角度算两遍，那是错的门。
    func testDragAndRenderUseTheSameUnits() throws {
        let document = Self.userDocument()
        let viewport = Self.userViewport
        let ds = Self.decodeScale
        let decoded = ImageSize(width: Int((Double(Self.stored.width) * ds).rounded()),
                                height: Int((Double(Self.stored.height) * ds).rounded()))
        let framing = LoupeFraming(viewport: viewport, decoded: decoded, decodeScale: ds,
                                   edit: document, canvasRole: .document)
        let mapping = framing.mapping(of: .fit)
        let drag = CropTool.projection(source: document.geometry.orientedSource(Self.stored),
                                       mapping: mapping,
                                       angle: 0,
                                       cropSpace: document.geometry.cropSpace,
                                       perspective: document.geometry.perspective).units
        let render = document.geometry.cropUnitsForLock(source: Self.stored)
        let cg = CropGeometry(geometry: document.geometry, source: Self.stored)
        let oriented = document.geometry.orientedSource(Self.stored)
        print("397 ③ photoQuadExtent (measured here) "
              + String(format: "%.10f × %.10f", cg.photoQuadExtent.width, cg.photoQuadExtent.height))
        print("397 ③ drag units (CropToolProjection.units) "
              + String(format: "%.10f × %.10f", drag.width, drag.height))
        print("397 ③ render units (cropUnitsForLock)        "
              + String(format: "%.10f × %.10f", render.width, render.height))
        print("397 ③ delta " + String(format: "%.3e / %.3e",
                                      abs(drag.width - render.width),
                                      abs(drag.height - render.height)))
        print("397 ③ the grid the bug used (orientedSource) "
              + String(format: "%.1f × %.1f", Double(oriented.width), Double(oriented.height)))

        XCTAssertEqual(drag.width, render.width, accuracy: 1e-9,
                       "397 ③ 拖动与渲染的 width 不同基准")
        XCTAssertEqual(drag.height, render.height, accuracy: 1e-9,
                       "397 ③ 拖动与渲染的 height 不同基准")
        // 而它确实**不是**源图 —— 否则两个错答案相等时这条也会绿。
        XCTAssertGreaterThan(abs(render.width - Double(oriented.width)), 1,
                             "397 ③ render 的 units 仍是源图尺寸 —— 修复没生效")
    }

    // MARK: - ④ 自由比例逐位不变

    /// **④** `aspectLock == .original` ⇒ `renderCrop` 与改动前**逐位相同**。
    ///
    /// 旧值用反向门在同一进程内取：`readsSourceUnitsForLock = true` 就是 397 之前那一行
    /// （`lockedCrop(…, source: orientedSource)`），`false` 是修好的答案。两个 `CropRect` 是四个
    /// `Double`，`==` 即逐位，不写容差。
    func testFreeLockIsBitIdenticalToTheOldArithmetic() {
        for (name, space, quarter) in [("canvas/perspective q1", CropSpace.canvas, 1),
                                       ("canvas/perspective q0", CropSpace.canvas, 0),
                                       ("canvas/perspective q2", CropSpace.canvas, 2),
                                       ("canvas/no perspective", CropSpace.canvas, 0),
                                       ("source/perspective q1", CropSpace.source, 1),
                                       ("source/no perspective", CropSpace.source, 0)] {
            var document = Self.userDocument(lock: .original)
            document.geometry.cropSpace = space
            document.geometry.quarterTurns = quarter
            if name.hasSuffix("no perspective") {
                document.geometry.perspectiveVertical = 0
                document.geometry.perspectiveHorizontal = 0
                document.geometry.rotationDegrees = 0
            }
            GeometryGroup.readsSourceUnitsForLock = true
            let before = document.geometry.renderCrop(source: Self.stored)
            GeometryGroup.readsSourceUnitsForLock = false
            defer { GeometryGroup.readsSourceUnitsForLock = false }
            let after = document.geometry.renderCrop(source: Self.stored)
            print("397 ④ \(name): before(gate on) \(before.keyString) "
                  + "· after(gate off) \(after.keyString) "
                  + "· bit-identical \(before == after)")
            XCTAssertEqual(after, before,
                           "397 ④ \(name): 自由比例的 renderCrop 不再逐位相同")
            XCTAssertEqual(after.normalizedRect, document.geometry.crop,
                           "397 ④ \(name): 自由比例应当原样返回存储的 rect")
        }
    }

    // MARK: - ⑤ `.source` 空间逐位不变

    /// **⑤** `cropSpace == .source` ⇒ `renderCrop` 与改动前逐位相同 —— 对**每一种** lock，不只
    /// `.original`。旧值同样用反向门在进程内取。
    ///
    /// 有透视时 `.source` 与 `.canvas` 是两个不同的空间，而 `.source` 的旧算术（源图格）本来就是
    /// 对的；无透视时两格是同一张照片，答案必须与旧值一份不差。
    func testSourceSpaceIsBitIdenticalToTheOldArithmetic() {
        var groups = 0
        for perspective in [0.0, 31.712741686055033] {
            for angle in [0.0, -1.166707175774583] {
                for quarter in [0, 1] {
                    for lock in [AspectLock.original, .square, .threeTwo,
                                 .custom(Self.lock), .sixteenNine] {
                        var document = Self.userDocument(lock: lock)
                        document.geometry.cropSpace = .source
                        document.geometry.perspectiveVertical = perspective
                        document.geometry.rotationDegrees = angle
                        document.geometry.quarterTurns = quarter
                        GeometryGroup.readsSourceUnitsForLock = true
                        let before = document.geometry.renderCrop(source: Self.stored)
                        GeometryGroup.readsSourceUnitsForLock = false
                        let after = document.geometry.renderCrop(source: Self.stored)
                        XCTAssertEqual(after, before,
                                       "397 ⑤ .source \(lock.code) pv\(perspective) "
                                       + "θ\(angle) q\(quarter): \(before.keyString) → "
                                       + after.keyString)
                        // units 就是 turned 源图本身，一个 double 都不差。
                        let units = document.geometry.cropUnitsForLock(source: Self.stored)
                        let oriented = document.geometry.orientedSource(Self.stored)
                        XCTAssertEqual(units.width, Double(oriented.width))
                        XCTAssertEqual(units.height, Double(oriented.height))
                        groups += 1
                    }
                }
            }
        }
        print("397 ⑤ .source × {0, 31.7127} × {0°, −1.1667°} × {q0, q1} × 5 locks: "
              + "\(groups) 组全部逐位相同")
    }

    // MARK: - ⑥ 连续 10 tick 不跳变、不漂移

    /// **⑥** 连续 10 个 tick，每次 `constrain` 前后 rect 的比例偏差 `< 0.01 %`，且矩形不漂移。
    ///
    /// 形状法律是 `CropTool.constrain(rect, lock:units:anchor:bounds:)`（362 起用 rect 自己的
    /// units）。每个 tick 用**渲染路径的 units** 把上一个 tick 的矩形再锁一次 —— 一个不动的矩形必须
    /// 原地返回。旧代码里两套 units 不同，第 2 个 tick 就会把框改小 1.9 %。
    func testTenTicksHoldTheRatioAndDoNotDrift() throws {
        let document = Self.userDocument()
        let units = document.geometry.cropUnitsForLock(source: Self.stored)
        let ratio = try XCTUnwrap(document.geometry.aspectLock.ratio)
        var rect = document.geometry.renderCrop(source: Self.stored)
        let start = rect
        var previous = rect
        for tick in 1...10 {
            rect = CropTool.constrain(rect, lock: document.geometry.aspectLock,
                                      units: CropUnits(width: units.width, height: units.height),
                                      anchor: .center, bounds: nil)
            let pixelRatio = rect.width * units.width / (rect.height * units.height)
            let error = abs(pixelRatio - ratio) / ratio
            let drift = max(max(abs(rect.left - previous.left), abs(rect.top - previous.top)),
                            max(abs(rect.right - previous.right), abs(rect.bottom - previous.bottom)))
            print("397 ⑥ tick \(tick): rect \(rect.keyString) · pixel ratio "
                  + String(format: "%.10f", pixelRatio)
                  + " · error " + String(format: "%.8f%%", 100 * error)
                  + " · drift " + String(format: "%.3e", drift))
            XCTAssertLessThan(error, 1e-4, "397 ⑥ tick \(tick): the lock slipped \(100 * error)%")
            XCTAssertEqual(drift, 0, accuracy: 1e-15, "397 ⑥ tick \(tick): 矩形漂移了")
            previous = rect
        }
        XCTAssertEqual(rect, start, "397 ⑥ 十个 tick 后矩形不再是起点")
    }

    // MARK: - ⑧ 反向门：renderCrop 改回源图 ⇒ ① 与 ② 红

    /// **⑧** 把渲染路径改回**源图**格（= 397 之前），同一个视口下 ① 必须重新出现黑带、② 必须红。
    ///
    /// 门是生产代码里那个只由测试打开的开关（`GeometryGroup.readsSourceUnitsForLock`）——与
    /// `CropGeometry.pre330SourceSpace`、`LoupeFraming.readsCanvasCropAsSource` 同一套做法：门的红
    /// 来自**同一个渲染器、同一帧**，而不是另算一遍几何。`defer` 关回去，失败的测试也不留脏状态。
    func testTheSourceGridBringsTheBlackBandBack() throws {
        let document = Self.userDocument()
        let viewport = Self.userViewport
        let cg = CropGeometry(geometry: document.geometry, source: Self.stored)
        let e = cg.photoQuadExtent
        let fixed = document.geometry.renderCrop(source: Self.stored)

        GeometryGroup.readsSourceUnitsForLock = true
        defer { GeometryGroup.readsSourceUnitsForLock = false }

        let old = document.geometry.renderCrop(source: Self.stored)
        let oldRatio = old.width * e.width / (old.height * e.height)
        let oldError = abs(oldRatio - Self.lock) / Self.lock
        print("397 ⑧ gate on · source-grid renderCrop \(old.keyString) · pixel ratio on the canvas "
              + "grid " + String(format: "%.10f", oldRatio) + " vs lock "
              + String(format: "%.10f", Self.lock)
              + " · error " + String(format: "%.4f%%", 100 * oldError))
        print("397 ⑧ gate off · fixed renderCrop \(fixed.keyString) · pixel ratio "
              + String(format: "%.10f", fixed.width * e.width / (fixed.height * e.height)))
        print("397 ⑧ the old rect is "
              + String(format: "%.1f", (fixed.height - old.height) * e.height)
              + " px shorter on the canvas grid — that is the band")

        // ② red：旧算术的比例偏差远大于 1e-4。
        XCTAssertGreaterThan(oldError, 1e-4, "397 ⑧ 反向门没红：源图 units 居然也满足 ②")
        XCTAssertNotEqual(old, fixed, "397 ⑧ 反向门没红：开关没改变 renderCrop")

        // ① red：同一视口下，开了门的那一帧必须重新露出黑带。
        let frame = try render(document, viewport: viewport)
        defer { frame.graph.recycle(output: frame.texture) }
        print("397 ⑧ gate on frame: canvasRect \(frame.result.canvasRect.keyString) "
              + "· drawnRect \(frame.result.drawnRect.keyString)")
        print("397 ⑧ gate on frame black rows: \(frame.blackRows) of \(frame.height) = "
              + String(format: "%.4f%%", 100 * frame.blackFraction)
              + " · top \(frame.blackRowsAtTop) · bottom \(frame.blackRowsAtBottom)")
        XCTAssertGreaterThan(frame.blackRows, 0,
                             "397 ⑧ 反向门没红：源图格的那一帧居然零黑行")
        XCTAssertGreaterThan(frame.blackFraction, 0.01,
                             "397 ⑧ 反向门没红：黑带只有 "
                             + String(format: "%.4f%%", 100 * frame.blackFraction))
    }

    /// **⑨** 把拖动路径的 units 改成**源图**（模拟 362 之前），③ 与 ⑥ 必须红。
    func testTheSourceGridBreaksTheDrag() throws {
        let document = Self.userDocument()
        let viewport = Self.userViewport
        let ds = Self.decodeScale
        let decoded = ImageSize(width: Int((Double(Self.stored.width) * ds).rounded()),
                                height: Int((Double(Self.stored.height) * ds).rounded()))
        let framing = LoupeFraming(viewport: viewport, decoded: decoded, decodeScale: ds,
                                   edit: document, canvasRole: .document)
        let mapping = framing.mapping(of: .fit)
        let realDrag = CropTool.projection(source: document.geometry.orientedSource(Self.stored),
                                           mapping: mapping, angle: 0,
                                           cropSpace: document.geometry.cropSpace,
                                           perspective: document.geometry.perspective).units
        let sourceUnits = CropUnits(document.geometry.orientedSource(Self.stored))
        let render = document.geometry.cropUnitsForLock(source: Self.stored)
        print("397 ⑨ shipped drag units " + String(format: "%.6f × %.6f",
                                                   realDrag.width, realDrag.height)
              + " · source units " + String(format: "%.1f × %.1f",
                                             sourceUnits.width, sourceUnits.height)
              + " · render units " + String(format: "%.6f × %.6f", render.width, render.height))
        // ③ red：源图 units 与渲染 units 不相等。
        XCTAssertGreaterThan(abs(sourceUnits.width - render.width), 1,
                             "397 ⑨ 反向门没红：源图 units 等于渲染 units")
        // ⑥ red：用源图 units 锁同一个矩形，比例偏差 1.9 %。
        let rect = document.geometry.renderCrop(source: Self.stored)
        let constrained = CropTool.constrain(rect, lock: document.geometry.aspectLock,
                                             units: sourceUnits, anchor: .center, bounds: nil)
        let error = abs(constrained.width * render.width / (constrained.height * render.height)
                        - Self.lock) / Self.lock
        print("397 ⑨ source-unit constrain \(constrained.keyString) · pixel ratio "
              + String(format: "%.10f",
                       constrained.width * render.width / (constrained.height * render.height))
              + " · error " + String(format: "%.4f%%", 100 * error))
        XCTAssertGreaterThan(error, 1e-4, "397 ⑨ 反向门没红：源图 units 下 ⑥ 仍然满足")
    }
}
