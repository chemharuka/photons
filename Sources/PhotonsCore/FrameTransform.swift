import Foundation

// MARK: - 261 · the single per-frame transform exit
//
// Every scale factor on the loupe's picture path used to be spelled at the call site: the crop
// ratio, the rotated canvas' AABB, the render scale, the camera window and the letterbox inset.
// Each of them could be — and twice was — multiplied a second time (232's `origin`, 260's
// `canvasPerSource`). This type is the one place they are assembled:
//
//     S1 source px ──(crop · straighten · quarter turn · perspective)──▶ S3 frame canvas
//                 ──(camera window · zoom · letterbox)───────────────▶ S5 viewport
//
// It **assembles**; it does not define geometry. `CropGeometry` / `CropMath` remain the only
// owners of the crop → frame → canvas walk, and this file calls their public methods
// (`canvasPoint`, `framePoint`, `perspectiveCanvas`) instead of repeating the trigonometry.
//
// One value per frame: all outputs are `let`, so a consumer either reads the number or asks for
// nothing. Nothing here may run per pixel.
public struct FrameTransform: Sendable, Equatable {

    /// A point in any of the four continuous pixel spaces. `SIMD2<Double>` because a tuple is not
    /// `Equatable`/`Sendable` as a stored property (and this type is both).
    public typealias Point = SIMD2<Double>

    // MARK: S1 → S3

    /// S1 — the **turned** source frame (the quarter turn is already applied, exactly like
    /// `CropGeometry.source`). Normalized crop rects are measured in this grid.
    public let source: ImageSize
    /// The crop, resolved (aspect lock already folded in by the caller).
    public let crop: CropRect
    /// The quarter turn, kept so a consumer can name the document's orientation. It is **not**
    /// applied again here: `source` is already the turned frame.
    public let quarterTurns: Int
    public let straightenDegrees: Double
    public let perspective: PerspectiveMap?
    /// The rung the renderer actually decodes at. It drives `decodedSource` / `imageScale`; S3 itself
    /// is the **full-resolution** frame canvas (see the init's `cg` comment: building the canvas on
    /// the rung grid let its `ceil` and inset drift by up to half a decoded pixel × the zoom).
    public let decodeScale: Double
    /// The decoded S1 frame.
    public let decodedSource: ImageSize

    /// S3 — the frame canvas, in S1 pixels (full resolution).
    public let canvasS3: ImageSize
    /// S2 — the crop frame's bounding box in S3. At a right angle its origin is the frame's own
    /// top-left; at an angle the frame is a quad (`frameQuadInS3`) and this is its AABB.
    public let frameInS3: CGRect
    /// The crop frame's four corners in S3, top-left, top-right, bottom-right, bottom-left.
    public let frameQuadInS3: [Point]

    /// S1 px → S3 px (crop · straighten · flips · perspective; 281 — flip after turn, as in S0).
    public let s1ToS3: Matrix3
    public let s3ToS1: Matrix3

    // MARK: S3 → S5

    /// S5 — the viewport the content is letterboxed into.
    public let viewport: ImageSize
    /// S5 px per S3 px after letterboxing (`contentInS5.width / windowInS3Size.x`).
    public let contentPerS3: Double
    /// The content rect inside the viewport (the picture's place, letterbox included).
    public let contentInS5: CGRect
    /// The letterbox offset — `(viewport − content) / 2`. This is the one `origin`; 232 added it
    /// twice because `RenderGraph` and the loupe each kept a copy.
    public let origin: Point
    /// The S3 coordinate shown at the content's top-left (the camera window's origin). Zero for 適配.
    public let windowInS3: Point
    /// The S3 window size (the canvas for 適配, `viewport / zoom` for the camera).
    public let windowInS3Size: SIMD2<Double>
    /// The whole output at this render's scale — what `RenderOptions.outputWindow` indexes.
    public let requestedInS5: ImageSize

    /// S3 → S5 and its inverse.
    public let s3ToS5: Matrix3
    public let s5ToS3: Matrix3

    /// The one geometry owner, built on the renderer's decoded grid.
    private let geometry: CropGeometry
    private let flipHorizontal: Bool
    private let flipVertical: Bool
    /// `round(crop · decoded · zoom)` — the grid S0 actually walks. The convenience methods below
    /// use these integers, not the continuous 1:1 numbers, because a hit test has to agree with the
    /// pixels the renderer produced (260's half-pixel phase).
    private let renderFrame: SIMD2<Double>
    private let renderBaseline: ImageSize
    private let renderInset: SIMD2<Double>
    private let renderWindowOrigin: SIMD2<Double>
    /// Requested → content pixels (the letterbox squeeze).
    private let contentPerRequested: Double
    /// The crop's top-left in S1 (full-resolution, turned).
    private let cropOrigin: Point

    /// S5 px per **S1** px — the scale `RenderGraph` calls `imageScale`.
    public var imageScale: Double {
        contentPerS3 * Double(decodedSource.width) / Double(max(source.width, 1))
    }

    // MARK: - init

    /// The explicit constructor the 派单 names. Nothing is read from a global or a controller.
    ///
    /// - Parameters:
    ///   - source: S1, the **turned** source frame (the quarter turn is already in it).
    ///   - contentScale: output pixels per **decoded** pixel (`RenderOptions.scale`). Accepted for
    ///     callers that already hold the renderer's number; `zoom` drives the geometry and the two
    ///     agree in every shipped caller (`zoom == contentScale · decodeScale`).
    ///   - viewport: S5. `nil` means "the requested output is the viewport" (an export render).
    ///   - zoom: S5 pixels per S3 pixel (the camera's scale: `fitZoom` or the actual zoom).
    ///   - cameraOffset: the S3 coordinate shown at the content's top-left. `.zero` for 適配.
    ///   - cameraWindowSize: the S3 window size. `nil` means the whole canvas (適配 / export).
    public init(source: ImageSize,
                crop: CropRect,
                straightenDegrees: Double,
                quarterTurns: Int,
                flipHorizontal: Bool = false,
                flipVertical: Bool = false,
                perspective: PerspectiveMap? = nil,
                decodeScale: Double = 1,
                contentScale: Double = 1,
                viewport: ImageSize?,
                zoom: Double,
                cameraOffset: Point = .zero,
                cameraWindowSize: SIMD2<Double>? = nil,
                cameraWindow: CGRect? = nil,
                cameraWindowInS5: ImageRect? = nil,
                allowsUpscale: Bool = false) {
        let ds = Self.validScale(decodeScale)
        let z = Self.validScale(zoom)
        let crop = crop.clamped(allowsOutsideSource: true)
        self.source = source
        self.crop = crop
        self.quarterTurns = ((quarterTurns % 4) + 4) % 4
        self.straightenDegrees = straightenDegrees.isFinite ? straightenDegrees : 0
        self.perspective = perspective.flatMap { $0.hasWarp ? $0 : nil }
        self.flipHorizontal = flipHorizontal
        self.flipVertical = flipVertical
        self.decodeScale = ds
        let decoded = ImageSize(
            width: max(1, Int((Double(source.width) * ds).rounded())),
            height: max(1, Int((Double(source.height) * ds).rounded())))
        self.decodedSource = decoded

        // S1 → S3. The geometry stays in `CropGeometry`: build it on the decoded grid and compose
        // its public `canvasPoint` with the crop origin, flips and the rung scale.
        var group = GeometryGroup(crop: crop.normalizedRect,
                                  rotationDegrees: self.straightenDegrees,
                                  flipHorizontal: flipHorizontal,
                                  flipVertical: flipVertical,
                                  aspectLock: .original,
                                  quarterTurns: 0,
                                  perspectiveVertical: perspective?.vertical ?? 0,
                                  perspectiveHorizontal: perspective?.horizontal ?? 0)
        group.crop = crop.normalizedRect
        // **The full-resolution S3.** The rung moves no geometry (231): the loupe's hit test, the
        // overlay and the crop tool all speak the file's own pixel grid, and `decodeScale` only
        // scales the renderer's allocation — which `RenderGraph.plan` does on its own decoded grid
        // by passing it as `source` with `decodeScale == 1`. Building S3 on `decoded` here made the
        // canvas' `ceil` and its inset drift by up to half a decoded pixel (× the zoom).
        let cg = CropGeometry(geometry: group, source: source)
        self.geometry = cg
        self.canvasS3 = cg.canvas
        let frame = cg.frameSize
        self.cropOrigin = Point(crop.left * Double(source.width),
                                crop.top * Double(source.height))

        // S1 full px → decoded px, split per axis so a `round` on either dimension cannot leak in.
        let sx = Double(decoded.width) / Double(max(source.width, 1))
        let sy = Double(decoded.height) / Double(max(source.height, 1))
        let toDecoded = Matrix3(rows: [[sx, 0, 0], [0, sy, 0], [0, 0, 1]])
        let photoToCanvas: Matrix3
        if let perspective = self.perspective {
            // 246's composed map is already the one definition of photo-normalized → canvas-normalized.
            let pc = CropMath.perspectiveCanvas(crop: crop, in: decoded,
                                                straightenDegrees: self.straightenDegrees,
                                                perspective: perspective)
            let fromPhoto = Matrix3(rows: [[1 / Double(max(decoded.width, 1)), 0, 0],
                                           [0, 1 / Double(max(decoded.height, 1)), 0],
                                           [0, 0, 1]])
            let toCanvas = Matrix3(rows: [[Double(cg.canvas.width), 0, 0],
                                          [0, Double(cg.canvas.height), 0],
                                          [0, 0, 1]])
            let flip = Self.cropFlipMatrix(crop: crop, decoded: decoded,
                                           flipH: flipHorizontal, flipV: flipVertical)
            photoToCanvas = toCanvas * Self.matrix(pc.forward) * flip * fromPhoto * toDecoded
        } else {
            // 281 — the kernel's own walk (`s0_geometry.metal`), in **photograph** pixels:
            //
            //     photo  = R(θ, P)·p                    // turn about the photo centre FIRST
            //     canvas = inset + (F(photo) − cropOrigin)
            //
            // The order is the kernel's, not a free choice: S0 samples canvas → source as
            // `R(−θ)(flip(frame))` — it mirrors the photo-normalized sample **first**, then un-turns
            // it about `orientedSource/2` — and the forward walk (source → canvas) is its inverse,
            // `flip ∘ turn`. A mirror and a turn about the same point do **not** commute
            // (`R·F = F·R⁻¹`: reversing them mirrors the angle's sign), so this must be
            // `toFrame · flip · turn`, not `toFrame · turn · flip`. 274 measured the difference at
            // 640×480, 45°, flip H, rung 1: the rendered marker lands 0.69 S5 px from `F(R(θ)·p)`
            // and 112.91 S5 px from the old spelling `R(θ)·F(p)`; the guard matrix was red in
            // 216/720 combinations (every `flip × angle ≠ 0`), worst 979.00 px. At θ = 0 the two
            // orders coincide, which is why a flip-only document could not see it.
            //
            // The perspective branch above is deliberately **not** touched here: it still flips in
            // canvas-normalised space, and 274 records that difference (36.97 px at 45° / off-centre
            // / flip H) for the "kernel 透视路径统一到 S1/S3" task.
            let centre = Point(Double(source.width) / 2, Double(source.height) / 2)
            let inset = Point(Double(cg.canvasInset.x), Double(cg.canvasInset.y))
            let toFrame = Matrix3(rows: [[1, 0, inset.x - cropOrigin.x],
                                         [0, 1, inset.y - cropOrigin.y],
                                         [0, 0, 1]])
            let flip = Self.photoFlipMatrix(centre: centre,
                                            flipH: flipHorizontal, flipV: flipVertical)
            let turn = Self.rotationAbout(centre: centre, degrees: self.straightenDegrees)
            photoToCanvas = toFrame * flip * turn
        }
        self.s1ToS3 = photoToCanvas
        self.s3ToS1 = Self.inverse(photoToCanvas)
        // The crop frame's four corners in S3, through the same exit the pixels use. At θ = 0 this
        // is the crop's own rectangle (the canvas *is* the frame); at an angle it is the turned quad,
        // whose AABB is `frameInS3` (and, for an off-centre crop, no longer centred on the canvas).
        let corners = [(0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 1.0)].map { corner -> Point in
            Self.apply(photoToCanvas, Point((crop.left + corner.0 * crop.width) * Double(source.width),
                                            (crop.top + corner.1 * crop.height) * Double(source.height)))
        }
        self.frameQuadInS3 = corners
        let minX = corners.map(\.x).min() ?? 0
        let minY = corners.map(\.y).min() ?? 0
        let maxX = corners.map(\.x).max() ?? Double(frame.width)
        let maxY = corners.map(\.y).max() ?? Double(frame.height)
        self.frameInS3 = CGRect(x: minX, y: minY,
                                width: max(0, maxX - minX), height: max(0, maxY - minY))

        // S3 → S5: the camera window at the zoom, letterboxed into the viewport.
        let windowS3: (offset: Point, size: SIMD2<Double>)
        if let window = cameraWindowInS5 {
            // The renderer's own integer window, in content pixels at `z`. Dividing by `z` is the
            // one conversion to S3 — no rounding is re-done here, so the loupe and `plan` agree.
            windowS3 = (Point(Double(window.x) / z, Double(window.y) / z),
                        SIMD2(Double(window.width) / z, Double(window.height) / z))
        } else if let window = cameraWindow {
            // The camera names an axis-aligned rect in S1 frame pixels; S3 is that rect translated
            // by the canvas' own inset (the picture sits centred inside the turned canvas). It is
            // **not** rotated: the window is a window onto the canvas, exactly what
            // `RenderOptions.outputWindow` indexes.
            let inset = cg.canvasInset
            windowS3 = (Point((window.minX - cropOrigin.x) + inset.x,
                              (window.minY - cropOrigin.y) + inset.y),
                        SIMD2(Double(window.width), Double(window.height)))
        } else {
            windowS3 = (cameraOffset,
                        cameraWindowSize ?? SIMD2(Double(cg.canvas.width),
                                                  Double(cg.canvas.height)))
        }
        let safeWindow = SIMD2(max(windowS3.size.x, 1e-9), max(windowS3.size.y, 1e-9))
        let requested = ImageSize(
            width: max(1, Int((safeWindow.x * z).rounded())),
            height: max(1, Int((safeWindow.y * z).rounded())))
        let canvasViewport = viewport ?? requested
        // **Continuous** content, deliberately not an `ImageSize`: the picture is `window × zoom`
        // device pixels sitting centred in the viewport, and rounding it here is what made the crop
        // overlay's own scale disagree with the picture's by up to a pixel. The renderer rounds when
        // it allocates a texture (`RenderGraph.plan`), which is its business.
        var contentWidth = safeWindow.x * z, contentHeight = safeWindow.y * z
        if canvasViewport != requested {
            let fits = contentWidth <= Double(canvasViewport.width)
                && contentHeight <= Double(canvasViewport.height)
            let ratio = min(Double(canvasViewport.width) / max(contentWidth, 1e-9),
                            Double(canvasViewport.height) / max(contentHeight, 1e-9))
            if allowsUpscale || !fits {
                contentWidth *= ratio
                contentHeight *= ratio
            }
        }
        self.viewport = canvasViewport
        self.requestedInS5 = requested
        self.contentInS5 = CGRect(x: (Double(canvasViewport.width) - contentWidth) / 2,
                                  y: (Double(canvasViewport.height) - contentHeight) / 2,
                                  width: contentWidth, height: contentHeight)
        let origin = Point((Double(canvasViewport.width) - contentWidth) / 2,
                           (Double(canvasViewport.height) - contentHeight) / 2)
        self.origin = origin
        self.windowInS3 = windowS3.offset
        self.windowInS3Size = safeWindow
        let perS3 = contentWidth / safeWindow.x
        self.contentPerS3 = perS3
        let translate = Matrix3(rows: [[perS3, 0, origin.x - windowS3.offset.x * perS3],
                                       [0, perS3, origin.y - windowS3.offset.y * perS3],
                                       [0, 0, 1]])
        self.s3ToS5 = translate
        self.s5ToS3 = Self.inverse(translate)
        self.renderBaseline = ImageSize(width: max(1, Int((Double(cg.canvas.width) * z).rounded())),
                                        height: max(1, Int((Double(cg.canvas.height) * z).rounded())))
        let kx = contentWidth / Double(max(requested.width, 1))
        let ky = contentHeight / Double(max(requested.height, 1))
        self.contentPerRequested = kx
        // Content pixels — the grid S0's `frameSize` / `frameOrigin` are in.
        let frameBaselineW = max(1, Int((Double(frame.width) * z).rounded()))
        let frameBaselineH = max(1, Int((Double(frame.height) * z).rounded()))
        self.renderFrame = SIMD2(Double(frameBaselineW) * kx, Double(frameBaselineH) * ky)
        let inset = SIMD2((renderBaseline.width - frameBaselineW) / 2,
                          (renderBaseline.height - frameBaselineH) / 2)
        self.renderInset = SIMD2(Double(inset.x) * kx, Double(inset.y) * ky)
        self.renderWindowOrigin = SIMD2(Double(Int((windowS3.offset.x * z).rounded())) * kx,
                                        Double(Int((windowS3.offset.y * z).rounded())) * ky)
    }

    /// Convenience for callers that already hold the decoded grid (`RenderGraph`): `decodeScale`
    /// is 1 and `source` is the buffer's own size, so the S3 numbers are the renderer's.
    public init(source: ImageSize,
                crop: CropRect,
                straightenDegrees: Double,
                quarterTurns: Int,
                flipHorizontal: Bool,
                flipVertical: Bool,
                perspective: PerspectiveMap?,
                contentScale: Double,
                viewport: ImageSize?,
                cameraOffset: Point,
                cameraWindowSize: SIMD2<Double>?,
                allowsUpscale: Bool) {
        self.init(source: source, crop: crop, straightenDegrees: straightenDegrees,
                  quarterTurns: quarterTurns, flipHorizontal: flipHorizontal,
                  flipVertical: flipVertical, perspective: perspective,
                  decodeScale: 1, contentScale: contentScale, viewport: viewport,
                  zoom: contentScale, cameraOffset: cameraOffset,
                  cameraWindowSize: cameraWindowSize, allowsUpscale: allowsUpscale)
    }

    // MARK: - convenience

    /// S5 device pixel → S1 source pixel — the exact inverse of S0's walk.
    ///
    /// Continuous, on the same S3 the rest of this type assembles: the canvas half-pixel the
    /// renderer's integer grid adds (`renderInset`'s truncation) is **not** reproduced here, because
    /// a hit test is a continuous question ("which source pixel is under the cursor"); the test
    /// matrix measures that difference separately rather than folding it into the projection.
    public func viewPointToSource(_ point: Point) -> Point {
        // The matrix is the kernel's own walk, inverted: S5 → S3 (`s5ToS3`) → S1 (`s3ToS1`).
        // 273 — the crop frame's pivot is the **photograph's** centre, so an off-centre crop no longer
        // hit-tests `(I − R)(cropCentre − photoCentre)` away from the pixel under the cursor.
        Self.apply(s3ToS1, Self.apply(s5ToS3, point))
    }

    /// S1 source pixel → S5 device pixel.
    public func sourceToView(_ point: Point) -> Point {
        Self.apply(s3ToS5, Self.apply(s1ToS3, point))
    }

    /// S5 → S2 **without** the picture rotation: the frame space the crop overlay draws in (its
    /// sides stay axis-aligned while a straightened picture turns under them). Continuous geometry:
    /// an overlay must be a similarity, not the renderer's integer phase; the hit test is the one
    /// that has to land on a rendered pixel.
    public func viewPointToUnrotatedSource(_ point: Point) -> Point {
        let s3 = Self.apply(s5ToS3, point)
        let frame = geometry.framePoint(canvasX: s3.x, canvasY: s3.y)
        let sx = Double(source.width) / Double(max(decodedSource.width, 1))
        let sy = Double(source.height) / Double(max(decodedSource.height, 1))
        return Point(frame.x * sx + cropOrigin.x, frame.y * sy + cropOrigin.y)
    }

    /// S2 (absolute S1 coordinates, un-rotated) → S5. Continuous geometry (see above).
    public func unrotatedSourceToView(_ point: Point) -> Point {
        let sx = Double(decodedSource.width) / Double(max(source.width, 1))
        let sy = Double(decodedSource.height) / Double(max(source.height, 1))
        let frame = Point((point.x - cropOrigin.x) * sx, (point.y - cropOrigin.y) * sy)
        let p = geometry.canvasPoint(frameX: frame.x, frameY: frame.y)
        return Self.apply(s3ToS5, Point(p.x, p.y))
    }

    /// The S2 frame as a quad in S5: the crop tool's four corners, in frame order.
    public func frameQuadInS5() -> [Point] {
        [(crop.left, crop.top), (crop.right, crop.top),
         (crop.right, crop.bottom), (crop.left, crop.bottom)]
            .map { corner in
                unrotatedSourceToView(Point(corner.0 * Double(source.width),
                                            corner.1 * Double(source.height)))
            }
    }

    /// The crop frame's bounding rect in S5 (axis-aligned; a straightened frame's actual shape is
    /// `frameQuadInS5`).
    public func frameRectInS5() -> CGRect {
        let quad = frameQuadInS5()
        let xs = quad.map(\.x), ys = quad.map(\.y)
        return CGRect(x: xs.min() ?? 0, y: ys.min() ?? 0,
                      width: (xs.max() ?? 0) - (xs.min() ?? 0),
                      height: (ys.max() ?? 0) - (ys.min() ?? 0))
    }

    /// The frame's top-left in S5; `RenderGraph`'s `frameOrigin` is `origin − this`.
    public var frameOriginInS5: Point {
        unrotatedSourceToView(Point(crop.left * Double(source.width),
                                    crop.top * Double(source.height)))
    }

    /// The frame's size in S5 pixels.
    public var frameSizeInS5: SIMD2<Double> {
        let topLeft = frameOriginInS5
        let bottomRight = unrotatedSourceToView(Point(crop.right * Double(source.width),
                                                      crop.bottom * Double(source.height)))
        return SIMD2(bottomRight.x - topLeft.x, bottomRight.y - topLeft.y)
    }

    // MARK: - private assembly

    private static func validScale(_ value: Double) -> Double {
        guard value.isFinite, value > 0 else { return 1 }
        return value
    }

    private static func apply(_ matrix: Matrix3, _ point: Point) -> Point {
        let v = matrix.applying(to: SIMD3(point.x, point.y, 1))
        let w = v.z == 0 ? 1 : v.z
        return Point(v.x / w, v.y / w)
    }

    private static func inverse(_ matrix: Matrix3) -> Matrix3 {
        if abs(matrix.determinant) < 1e-15 { return .identity }
        return matrix.inverted()
    }

    private static func matrix(_ rows: [[Double]]) -> Matrix3 {
        Matrix3(rows: rows)
    }

    /// A rotation of `degrees` about an arbitrary `centre` (y-down, +θ = the picture turns clockwise).
    private static func rotationAbout(centre: Point, degrees: Double) -> Matrix3 {
        let r = CropGeometry.RotationMatrix(degrees: degrees)
        return Matrix3(rows: [[r.cosine, -r.sine,
                               centre.x - r.cosine * centre.x + r.sine * centre.y],
                              [r.sine, r.cosine,
                               centre.y - r.sine * centre.x - r.cosine * centre.y],
                              [0, 0, 1]])
    }

    /// A flip of the **photograph** about its own centre (`P = source / 2`), the same pivot
    /// `s0_geometry.metal` uses (`photo.x = 1 − photo.x` in photo-normalized space). A flip about the
    /// crop frame's centre would be visible only on an off-centre crop, which is why it survived 248.
    private static func photoFlipMatrix(centre: Point, flipH: Bool, flipV: Bool) -> Matrix3 {
        let fx: Matrix3 = flipH
            ? Matrix3(rows: [[-1, 0, 2 * centre.x], [0, 1, 0], [0, 0, 1]])
            : .identity
        let fy: Matrix3 = flipV
            ? Matrix3(rows: [[1, 0, 0], [0, -1, 2 * centre.y], [0, 0, 1]])
            : .identity
        return fy * fx
    }

    private static func frameFlipMatrix(width: Double, height: Double,
                                        flipH: Bool, flipV: Bool) -> Matrix3 {
        let sx = flipH ? -1.0 : 1.0
        let sy = flipV ? -1.0 : 1.0
        let cx = width / 2, cy = height / 2
        return Matrix3(rows: [[sx, 0, cx - sx * cx],
                              [0, sy, cy - sy * cy],
                              [0, 0, 1]])
    }

    private static func cropFlipMatrix(crop: CropRect, decoded: ImageSize,
                                       flipH: Bool, flipV: Bool) -> Matrix3 {
        // Flips act on the crop-normalized position, which the kernel flips before the keystone.
        let frame = CropMath.frameSize(crop, in: decoded, allowsOutsideSource: true)
        let flip = frameFlipMatrix(width: Double(frame.width), height: Double(frame.height),
                                   flipH: flipH, flipV: flipV)
        let toPhoto = Matrix3(rows: [[crop.width, 0, crop.left],
                                     [0, crop.height, crop.top],
                                     [0, 0, 1]])
        let toCrop = Matrix3(rows: [[1 / max(crop.width, 1e-12), 0,
                                     -crop.left / max(crop.width, 1e-12)],
                                    [0, 1 / max(crop.height, 1e-12),
                                     -crop.top / max(crop.height, 1e-12)],
                                    [0, 0, 1]])
        return toPhoto * flip * toCrop
    }
}
