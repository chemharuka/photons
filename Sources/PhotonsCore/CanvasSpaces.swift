import Foundation

// MARK: - 2026-11-01 · rotate + crop: the four spaces, in one place
//
// A rotated-and-cropped document is described by four rectangles, and every bug in this area has been
// one of them being computed twice with different rounding (176 / 188 / 192 / 196 / 202 / 219 / 224).
// They are named once here and derived from each other; the renderer, the loupe, the crop overlay and
// the low-resolution backdrop all ask this type instead of re-deriving.
//
//   1. **photo pixels** — the turned source (`CropGeometry.source`), i.e. the photograph's own grid
//      after the quarter turn. Normalized `CropRect`s are measured in it.
//   2. **frame** — the crop's pixel grid at 1:1, `frameSize`. The picture the document *keeps*.
//   3. **canvas** — `canvas` / `frameExtent`: the axis-aligned box that contains every pixel of the
//      kept picture once it is turned. At a right angle it *is* the frame (only a real angle grows
//      it, user rule 162). The renderer's output, the export's output.
//   4. **document canvas** — `photoCanvas`: the box that contains every pixel of the **whole
//      photograph** once it is turned (user 2026-11-01: 画布 = 能包住全部照片像素的最小矩形). A crop
//      frame may leave the photograph — the black corners the turn opens up — but not this box.
//      It is a function of (source, angle, quarter turn) only: **never** of the zoom, the window, the
//      viewport or the crop rect, which is what makes the crop clamp screen-independent.
//
// The one transform between (1)+(2) and (3) is a rotation about the frame's centre plus the frame's
// inset — the same walk `s0_geometry.metal` does backwards:
//
//     canvas = C/2 + R(θ)·(frame − F/2)          C = canvas pixels, F = frame pixels
//     frame  = F/2 + R(−θ)·(canvas − C/2)
//
// At θ = 0 this is the identity, so every un-straightened document keeps its numbers bit for bit.
public extension CropGeometry {

    // MARK: the frame (space 2)

    /// The crop's own pixel grid at 1:1 — what S0 calls the frame, after the keystone (183).
    ///
    /// The same `CropMath.frameSize` the renderer's `plan` uses, so a loupe window and an export
    /// cannot disagree about how many pixels the crop has.
    var frameSize: ImageSize {
        CropMath.frameSize(crop, in: source,
                           allowsOutsideSource: true,
                           perspective: perspective)
    }

    /// The frame's size in continuous pixels (the crop's normalized span × the photo's pixels).
    /// Only the keystone can make this differ from `frameSize`, and then only by rounding.
    var frameExtentPixels: DSize {
        DSize(width: Double(frameSize.width), height: Double(frameSize.height))
    }

    /// The turned frame's continuous bounding box — the canvas **before** the one `ceil`.
    ///
    /// At every right angle this is the frame itself: a quarter turn renames the axes, it does not
    /// rotate the rectangle (user rule 162, `CropMath.canvasSize`'s early return).
    var frameExtent: DSize {
        let f = frameExtentPixels
        guard hasAngle else { return f }
        return Self.rotatedExtent(width: f.width, height: f.height, degrees: rotationDegrees)
    }

    /// The one bounding-box formula of the whole project: a `w × h` box turned by `degrees`, as
    /// `|w·cos| + |h·sin|` by `|w·sin| + |h·cos|`.
    ///
    /// Every caller that used to spell this itself — `CropMath.canvasSize`, `CropMath.containingExtent`,
    /// `LoupeFraming.rotatedExtent`, `LoupeMapping.canvasRect` — now comes through here, so the four
    /// copies cannot drift apart again. Right angles return the input **bit for bit** (the guard, not
    /// a multiply by 1 and 0), which is what keeps every un-straightened number identical.
    static func rotatedExtent(width: Double, height: Double, degrees: Double) -> DSize {
        guard degrees.isFinite, degrees != 0 else { return DSize(width: width, height: height) }
        let quarter = degrees / 90
        let m = RotationMatrix(degrees: degrees)
        let c = abs(m.cosine), s = abs(m.sine)
        // A right angle is an axis rename: return the input unchanged rather than `w·1 + h·0`, which
        // for a huge `h` could still round.
        if abs(quarter - quarter.rounded()) < 1e-9 {
            let odd = Int(quarter.rounded()) % 2 != 0
            return odd ? DSize(width: height, height: width) : DSize(width: width, height: height)
        }
        return DSize(width: width * c + height * s, height: width * s + height * c)
    }

    static func rotatedExtent(of size: ImageSize, degrees: Double) -> DSize {
        rotatedExtent(width: Double(size.width), height: Double(size.height), degrees: degrees)
    }

    /// `true` when the document actually turns the picture — the one predicate the canvas arithmetic
    /// asks. A 0° document (and a 90/180/270 one) must not pay the AABB at all.
    var hasAngle: Bool {
        guard rotationDegrees.isFinite else { return false }
        let quarter = rotationDegrees / 90
        return abs(quarter - quarter.rounded()) >= 1e-9
    }

    // MARK: the canvas (space 3)

    /// The canvas in continuous pixels — `ceil` of this is `canvas`.
    var canvasExtent: DSize { frameExtent }

    /// `(canvas − frame) / 2` in canvas pixels, **continuous**. Reference value: the renderer and the
    /// loupe both snap it (see `canvasInsetPixels`) because a window and the whole frame can only be
    /// byte-identical when the picture sits at an integer offset inside the canvas.
    var canvasInset: (x: Double, y: Double) {
        ((Double(canvas.width) - Double(frameSize.width)) / 2,
         (Double(canvas.height) - Double(frameSize.height)) / 2)
    }

    /// `(canvas − frame) / 2` **rounded the way the renderer rounds it**: integer division, i.e.
    /// truncation of the odd half-pixel.
    ///
    /// 2026-11-01 (D1) — this is the one phase. `s0_geometry` places the picture at
    /// `frameOrigin = … − inset`, and a window's pixel 0 therefore samples frame pixel
    /// `windowX − inset`; only an integer inset makes that an integer *frame* pixel, which is what
    /// lets a windowed 1:1 plate equal the whole-frame render byte for byte. `RenderGraph.plan`
    /// computes the same quantity from the **scaled** sizes (`baseline = round(canvas·s)`,
    /// `frame = round(frameSize·s)`), and `LoupeFraming.canvasOrigin` reproduces it in decoded
    /// pixels; the two cannot disagree because both truncate the same difference.
    var canvasInsetPixels: (x: Int, y: Int) {
        ((canvas.width - frameSize.width) / 2,
         (canvas.height - frameSize.height) / 2)
    }

    // MARK: the document canvas (space 4)

    /// The turned **whole photograph**'s continuous bounding box, in photo pixels.
    var photoExtent: DSize {
        Self.rotatedExtent(of: source, degrees: rotationDegrees)
    }

    /// The document canvas: the smallest axis-aligned box holding every pixel of the whole photograph
    /// after the turn, in whole canvas pixels. `photoCanvas == source` at every right angle.
    var photoCanvas: ImageSize {
        let e = photoExtent
        return ImageSize(width: Self.canvasPixels(e.width), height: Self.canvasPixels(e.height))
    }

    /// The document canvas expressed in the photograph's **own** (un-turned) pixel coordinates: the
    /// rect `photoExtent` big, centred on the photograph. At 0° it is exactly `0…source`.
    ///
    /// This is the legal area of a crop frame (user 2026-11-01): the frame may leave the photograph —
    /// it may sit in the black corners the turn opens — but it may not leave this rect. It is a
    /// document fact: zoom, pan, viewport and window size do not enter it.
    var documentCanvasRect: CGRect {
        let e = photoExtent
        return CGRect(x: (Double(source.width) - e.width) / 2,
                      y: (Double(source.height) - e.height) / 2,
                      width: e.width, height: e.height)
    }

    /// `documentCanvasRect` in normalized photo coordinates — what `CropRect.clamped`-style callers
    /// want, and `[0, 1]²` at every right angle (so the 224 rule survives verbatim at θ = 0).
    var documentCanvasCropRect: CropRect {
        Self.documentCanvasCropRect(in: source, degrees: rotationDegrees)
    }

    /// The same rect from the raw parameters — for the callers that hold a draft angle and a source
    /// size but no `CropGeometry` (the crop drag's every tick).
    static func documentCanvasCropRect(in source: ImageSize,
                                       degrees: Double) -> CropRect {
        let w = Double(max(source.width, 1)), h = Double(max(source.height, 1))
        let e = rotatedExtent(width: w, height: h, degrees: degrees)
        let left = (w - e.width) / 2, top = (h - e.height) / 2
        return CropRect(left: left / w, top: top / h,
                        right: (left + e.width) / w, bottom: (top + e.height) / h)
    }

    // MARK: frame ⇄ canvas

    /// A frame point in canvas pixels. `θ = 0` ⇒ the same number plus the inset, and the inset is 0
    /// at every right angle, so this is the identity there.
    func canvasPoint(frameX: Double, frameY: Double) -> (x: Double, y: Double) {
        let f = frameExtentPixels
        guard hasAngle else { return (frameX, frameY) }
        let p = rotation.apply(x: frameX - f.width / 2, y: frameY - f.height / 2)
        return (Double(canvas.width) / 2 + p.x, Double(canvas.height) / 2 + p.y)
    }

    /// The inverse of `canvasPoint` — the walk a click on the canvas does to reach the frame.
    func framePoint(canvasX: Double, canvasY: Double) -> (x: Double, y: Double) {
        let f = frameExtentPixels
        guard hasAngle else { return (canvasX, canvasY) }
        let p = rotation.invert(x: canvasX - Double(canvas.width) / 2,
                                y: canvasY - Double(canvas.height) / 2)
        return (p.x + f.width / 2, p.y + f.height / 2)
    }

    // MARK: photo pixels ⇄ frame ⇄ canvas

    /// The frame's top-left in photo pixels — the crop's origin, which may be negative (132 lets a
    /// crop reach outside the photograph).
    var frameOriginInPhoto: (x: Double, y: Double) {
        (crop.left * Double(source.width), crop.top * Double(source.height))
    }

    /// A photograph point in frame pixels.
    func framePoint(photoX: Double, photoY: Double) -> (x: Double, y: Double) {
        let o = frameOriginInPhoto
        return (photoX - o.x, photoY - o.y)
    }

    /// A frame point back in photograph pixels.
    func photoPoint(frameX: Double, frameY: Double) -> (x: Double, y: Double) {
        let o = frameOriginInPhoto
        return (frameX + o.x, frameY + o.y)
    }

    /// A photograph point in canvas pixels — the composition the backdrop and the mask overlay need.
    func canvasPoint(photoX: Double, photoY: Double) -> (x: Double, y: Double) {
        let f = framePoint(photoX: photoX, photoY: photoY)
        let c = canvasPoint(frameX: f.x, frameY: f.y)
        // `canvasPoint(frame:)` returns canvas-local coordinates already (it adds the canvas centre),
        // and the frame origin is the canvas' own origin, so nothing else is added.
        return c
    }

    /// A normalized photograph point (0…1 of the turned photo) in canvas pixels.
    func canvasPoint(normalizedPhotoX x: Double, photoY y: Double) -> (x: Double, y: Double) {
        canvasPoint(photoX: x * Double(source.width), photoY: y * Double(source.height))
    }

    /// The crop frame's four corners in canvas pixels, in the order top-left, top-right,
    /// bottom-right, bottom-left — the quad a crop overlay draws and the quad a backdrop placement
    /// has to contain.
    var frameQuadInCanvas: [(x: Double, y: Double)] {
        let f = frameExtentPixels
        return [(0.0, 0.0), (f.width, 0.0), (f.width, f.height), (0.0, f.height)]
            .map { canvasPoint(frameX: $0.0, frameY: $0.1) }
    }

    /// The photograph's four corners in canvas pixels — the turned picture's quad.
    var photoQuadInCanvas: [(x: Double, y: Double)] {
        let w = Double(source.width), h = Double(source.height)
        return [(0.0, 0.0), (w, 0.0), (w, h), (0.0, h)]
            .map { canvasPoint(photoX: $0.0, photoY: $0.1) }
    }

    // MARK: the crop clamp

    /// `rect` (normalized photo coordinates) pulled inside the **document canvas** — the one legal
    /// area of a crop frame, independent of zoom, pan, viewport and window size.
    ///
    /// A crop is still allowed to leave the photograph (the black corners); it is not allowed to
    /// leave the canvas. The rect keeps at least `minimumSpan` and its own aspect: the clamp moves
    /// and shrinks it the least it can, then the caller's drag arithmetic runs again from the result.
    func clampedToDocumentCanvas(_ rect: CropRect, minimumSpan: Double = 0.001) -> CropRect {
        let legal = documentCanvasCropRect
        guard hasAngle else {
            // θ = 0: the canvas *is* the photograph, so this is the historical [0, 1]² clamp.
            return rect.clamped(minimumSpan: minimumSpan)
        }
        let span = min(max(minimumSpan, 0), 1)
        let w = min(max(rect.width.isFinite ? rect.width : span, span), legal.width)
        let h = min(max(rect.height.isFinite ? rect.height : span, span), legal.height)
        let l = min(max(rect.left.isFinite ? rect.left : legal.left, legal.left), legal.right - w)
        let t = min(max(rect.top.isFinite ? rect.top : legal.top, legal.top), legal.bottom - h)
        return CropRect(left: l, top: t, right: l + w, bottom: t + h)
    }

    /// The one `ceil` the canvas uses: up, with a `1e-9` snap so floating-point noise at an integer
    /// boundary cannot add a whole pixel (`400.00000000000006` is 400, not 401).
    static func canvasPixels(_ value: Double) -> Int {
        max(1, Int((value - 1e-9).rounded(.up)))
    }
}
