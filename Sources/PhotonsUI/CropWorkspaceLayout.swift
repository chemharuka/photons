import CoreGraphics
import Foundation
import PhotonsCore

// MARK: - 169 §0 — the crop workspace's **one layout truth**
//
// The user's rule for this task is structural, not cosmetic: 「布局只有一个真相 + 武装只有一个入口」.
// Before this type, three places each derived a piece of the same geometry:
//
//   · `LoupeController.layoutCropBar()` measured the bar against `container.bounds`;
//   · `LoupeController.clampCropFrameToCanvas()` → `CropToolController.clampToView` →
//     `safeCropRect` measured the on-screen room through a `LoupeMapping`;
//   · `CropCanvasClamp.maxZoom(canvas:frame:)` measured the largest legal zoom.
//
// They agreed only by inspection. The resize bug (169 §1) is exactly what happens when two of them
// answer from different canvases: the overlay was re-projected against the new viewport while the
// frozen picture on the layer still had the old one.
//
// This value type is now the answer for all of them. It is **pure** — no session, no camera, no
// AppKit — so a test can ask it for every intermediate window size and get the same pair the app
// will draw. Inputs are `(source, quarterTurns, straighten, canvas)`; the entry layout adds the one
// document-dependent input (`crop`) and answers with the picture rectangle, the crop-frame
// rectangle, the 90 % entry zoom and the maximum zoom. Window resize, entering the workspace, a
// quarter turn and a photo switch all call it.
public struct CropWorkspaceLayout: Equatable, Sendable {

    /// The crop workspace's entry framing: ordinary 适应 × 0.90 (132 §9).
    public static let entryScale: Double = 0.90

    /// One answer, all four numbers — what the overlay draws and what the bar prints.
    public struct Entry: Equatable, Sendable {
        /// The canvas in the same pixels the inputs were given in (origin zero).
        public var canvas: CGRect
        /// The rotated source's bounding box on the canvas (the photograph).
        public var picture: CGRect
        /// The crop frame on the canvas (axis-aligned: the frame is a window, the photo turns under it).
        public var frame: CGRect
        /// Canvas pixels per source pixel at entry (`fit × 0.90`, or the refit beyond 6°).
        public var entryZoom: Double
        /// Canvas pixels per source pixel at which the crop frame is inscribed in the canvas.
        public var maxZoom: Double

        public init(canvas: CGRect, picture: CGRect, frame: CGRect,
                    entryZoom: Double, maxZoom: Double) {
            self.canvas = canvas
            self.picture = picture
            self.frame = frame
            self.entryZoom = entryZoom
            self.maxZoom = maxZoom
        }
    }

    /// The upright frame the renderer ingested, **before** the document's quarter turn.
    public var source: ImageSize
    /// 0…3, clockwise quarter turns (schema 9).
    public var quarterTurns: Int
    /// The document's straighten, in degrees (positive = clockwise).
    public var straighten: Double
    /// The canvas, in view/device pixels — origin zero.
    public var canvas: CGRect

    public init(source: ImageSize, quarterTurns: Int = 0, straighten: Double = 0,
                canvas: CGRect) {
        self.source = source
        self.quarterTurns = quarterTurns
        self.straighten = straighten.isFinite ? straighten : 0
        self.canvas = canvas
    }

    // MARK: the frame in the document's direction

    /// The source after the quarter turn — the same frame `CropToolController.sourceSize` measures.
    public var orientedSource: ImageSize {
        let turns = ((quarterTurns % 4) + 4) % 4
        return turns % 2 == 0 ? source : ImageSize(width: source.height, height: source.width)
    }

    /// The whole frame turned by the document's straighten — its AABB, in source pixels.
    public var rotatedSourceExtent: (width: Double, height: Double) {
        let oriented = orientedSource
        return LoupeFraming.rotatedExtent(width: Double(max(oriented.width, 1)),
                                          height: Double(max(oriented.height, 1)),
                                          degrees: straighten)
    }

    // MARK: the entry layout

    /// The one entry/arming layout: the picture and the frame at the workspace's fit, plus the two
    /// zoom numbers. `crop` is the draft's rect in the turned frame.
    ///
    /// The arithmetic is `LoupeFraming.fitZoom`'s, spelled once: the ordinary fit of the rotated
    /// source (never above 1:1), times `entryScale`; beyond `cropRefitDegrees` the turned crop's
    /// AABB takes over, exactly as the live projection does at 45°.
    public func entry(crop: CropRect = .full) -> Entry {
        let canvas = self.canvas.standardized
        let cw = Double(canvas.width), ch = Double(canvas.height)
        let oriented = orientedSource
        let ow = Double(max(oriented.width, 1)), oh = Double(max(oriented.height, 1))

        let rotatedSource = LoupeFraming.rotatedExtent(width: ow, height: oh, degrees: straighten)
        var zoom = min(cw / max(rotatedSource.width, 1e-9),
                       ch / max(rotatedSource.height, 1e-9)) * Self.entryScale
        let rect = crop.clamped(allowsOutsideSource: true)
        if abs(straighten) > LoupeFraming.cropRefitDegrees {
            // Beyond 6° the workspace re-fits the **whole canvas** once instead of keeping the
            // 90 % framing — the same rule `LoupeFraming.fitZoom` applies through `fitScale == 1`.
            let rotatedCrop = LoupeFraming.rotatedExtent(width: rect.width * ow,
                                                         height: rect.height * oh,
                                                         degrees: straighten)
            zoom = min(cw / max(rotatedCrop.width, 1e-9),
                       ch / max(rotatedCrop.height, 1e-9))
        }
        zoom = zoom.isFinite && zoom > 0 ? min(1, zoom) : 0

        // The crop frame is a rectangle of the **turned** frame, so it stays axis-aligned on screen.
        let frameWidth = rect.width * ow * zoom
        let frameHeight = rect.height * oh * zoom
        let frame = CGRect(x: canvas.midX - frameWidth / 2, y: canvas.midY - frameHeight / 2,
                           width: frameWidth, height: frameHeight)

        let pictureWidth = rotatedSource.width * zoom
        let pictureHeight = rotatedSource.height * zoom
        let picture = CGRect(x: canvas.midX - pictureWidth / 2,
                             y: canvas.midY - pictureHeight / 2,
                             width: pictureWidth, height: pictureHeight)

        // `maxZoom` is measured against the crop's own pixels, not the canvas rectangle: it is the
        // camera's ceiling, i.e. the level where the frame is exactly inscribed in the canvas.
        let sourceFrame = CGRect(x: rect.left * ow, y: rect.top * oh,
                                 width: rect.width * ow, height: rect.height * oh)
        return Entry(canvas: canvas, picture: picture, frame: frame,
                     entryZoom: zoom, maxZoom: Self.maxZoom(canvas: canvas.size, frame: sourceFrame))
    }

    // MARK: the two limits every caller shares

    /// The largest zoom at which `frame` (in **source pixels**) still fits entirely inside `canvas`:
    /// the level where the crop frame is exactly inscribed in the canvas. `0` for a degenerate input.
    public static func maxZoom(canvas: CGSize, frame: CGRect) -> Double {
        let cw = Double(canvas.width), ch = Double(canvas.height)
        let fw = Double(frame.width), fh = Double(frame.height)
        guard cw > 0, ch > 0, fw > 0, fh > 0,
              cw.isFinite, ch.isFinite, fw.isFinite, fh.isFinite else { return 0 }
        let z = min(cw / fw, ch / fh)
        return z.isFinite && z > 0 ? z : 0
    }

    /// The part of the frame the canvas shows, in normalized frame coordinates. This is the
    /// `safeCropRect` / `canvasBounds` arithmetic that used to live in `CropToolController`; it is
    /// here so the model clamp and the bar/overlay layout read the same number.
    public static func canvasBounds(mapping: LoupeMapping, source: ImageSize) -> CropRect {
        let w = Double(max(source.width, 1)), h = Double(max(source.height, 1))
        let a = mapping.framePoint(viewX: 0, viewY: 0)
        let b = mapping.framePoint(viewX: Double(mapping.viewport.width),
                                   viewY: Double(mapping.viewport.height))
        var left = min(a.x, b.x) / w, right = max(a.x, b.x) / w
        var top = min(a.y, b.y) / h, bottom = max(a.y, b.y) / h

        // 132: there is **no photo bound** — a crop may cover the letterboxed band outside the
        // sensor; the pixels there render black and the frame turns red. The canvas is the bound.
        left = max(left, -1e6); top = max(top, -1e6)
        right = min(right, 1e6); bottom = min(bottom, 1e6)
        guard right > left + 1e-9, bottom > top + 1e-9 else { return .full }
        return CropRect(left: left, top: top, right: right, bottom: bottom)
    }
}
