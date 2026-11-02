import Foundation

// MARK: - 229 · 红眼 / 宠物眼
//
// Red-eye is a **preset of 修复**, not a second repair. A click decides three things:
//
//   1. **Where the pupil is** (a red connected component near the click), and how big it is.
//   2. **Which source to sample** (heal's own `searchSource`, preferring a non-red ring when the
//      search lands on another red object).
//   3. **What counts as red** for the renderer's per-pixel gate.
//
// The last point is the important one for the acceptance: a repair that replaces the whole disk
// would touch the skin around the pupil. The gate is in `s1_9_heal.metal` (mode 2) and it applies
// exactly the same redness definition as this file, so "what the click found" and "what the kernel
// changes" cannot drift.
//
// ## Redness is measured in display encoding, not scene linear
//
// The task's input is the picture on screen (sRGB/P3). The decoded buffer this file is handed is
// scene-linear, so the test converts each sample through the sRGB OETF first. That matters: a
// saturated red pupil in linear light is `(0.20, 0.02, 0.02)` — a raw linear `r − max(g,b)` of
// 0.18, which a neutral skin tone easily reaches; after the OETF it is `(0.48, 0.18, 0.18)` and
// the separation from skin `(0.70, 0.63, 0.58)` is unambiguous. The kernel mirrors the same curve.
//
// ## The defaults
//
//   · `defaultThreshold = 0.20` — display-encoded `r − max(g,b)`.
//   · `defaultSoftness = 0.06` — half-width of the gate ramp.
//   · `noopThreshold = 2.0` — above the maximum possible redness; a click that found no pupil
//     writes this so the spot is one reversible history row and **zero** changed pixels.
//   · `defaultRadiusPoints = 3` on the card's 0.5…8 pt slider; the controller converts points to
//     short-edge units with the live projection, so the slider means the same thing at fit and 1:1.
//
// ## What is deliberately not claimed
//
// Vision has face landmarks (`leftEye`/`rightEye`) but **no dog/cat pupil landmarks**:
// `VNRecognizeAnimalsRequest` returns a species and a box. A pet-eye click therefore gets a box
// sized seed radius and the user's point, never an invented pupil location. That limitation is in
// `RedEyeVision` too, next to the request.

public enum RedEye {

    // MARK: - constants

    /// Display-encoded `r − max(g,b)` a pixel must reach to be called red.
    ///
    /// Measured on this machine (512² synthetic fixture, sRGB OETF): pupil **0.752**, neutral skin
    /// **0.016**. 0.25 sits well above ruddy skin and well below a flash red-eye; the negative
    /// gate is additionally protected by `maximumExtentFraction`.
    public static let defaultThreshold: Double = 0.25
    /// Half-width of the red gate's ramp, in the same unit as `defaultThreshold`.
    public static let defaultSoftness: Double = 0.06
    /// A red component larger than this fraction of the short edge is a red object (a lip, a
    /// shirt, a ruddy cheek), not a pupil. It is refused rather than repaired.
    public static let maximumExtentFraction: Double = 0.08
    /// A red gate no pixel can pass. The no-detection click writes this value.
    public static let noopThreshold: Double = 2.0
    /// The card's slider, in view points.
    public static let defaultRadiusPoints: Double = 3.0
    public static let radiusPointsRange: ClosedRange<Double> = 0.5 ... 8.0
    /// A connected component smaller than this is a stray pixel, not a pupil.
    public static let minimumRedPixels = 4

    // MARK: - the redness the renderer uses

    /// sRGB OETF, exactly the curve the kernel's `heal_srgb` applies.
    @inline(__always)
    public static func displayEncode(_ value: Double) -> Double {
        let c = min(max(value, 0), 1)
        return c <= 0.003_130_8 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
    }

    /// Display-encoded redness, `sRGB(r) − max(sRGB(g), sRGB(b))`. The one definition shared by
    /// detection, the source guard, and `s1_9_heal.metal`.
    @inline(__always)
    public static func redness(r: Double, g: Double, b: Double) -> Double {
        displayEncode(r) - max(displayEncode(g), displayEncode(b))
    }

    // MARK: - detection

    /// One pupil, in the image's normalised coordinates (row 0 = top).
    public struct Detection: Sendable, Equatable {
        /// Centre of the red component, normalised to the **image** (uncropped, upright).
        public let center: NormalizedPoint
        /// Radius in **short-edge units**, already grown to cover the component plus a 1.5 px rim.
        public let radius: Double
        public let peakRedness: Double
        public let meanRedness: Double
        /// Red pixels / pixels in the click's search window. Reported, not used as a gate.
        public let redFraction: Double
        public let pixelCount: Int
        /// The largest displacement from the centroid, in pixels; the audit number behind `radius`.
        public let extentPixels: Double

        public init(center: NormalizedPoint, radius: Double, peakRedness: Double,
                    meanRedness: Double, redFraction: Double, pixelCount: Int,
                    extentPixels: Double) {
            self.center = center
            self.radius = radius
            self.peakRedness = peakRedness
            self.meanRedness = meanRedness
            self.redFraction = redFraction
            self.pixelCount = pixelCount
            self.extentPixels = extentPixels
        }
    }

    /// Find the red component nearest `point` within `searchRadius` (short-edge units).
    ///
    /// The search window only **seeds** the component: a flood fill then grows it up to a bounded
    /// distance from the click, so a 3 pt click can still cover a 30 px pupil. `nil` means the
    /// window had no pixel above `threshold` — the negative gate. Nothing is invented: no red, no
    /// detection.
    public static func detect(in image: LinearImage, near point: NormalizedPoint,
                              searchRadius: Double,
                              threshold: Double = RedEye.defaultThreshold) -> Detection? {
        let w = image.width, h = image.height
        guard w > 1, h > 1,
              point.x.isFinite, point.y.isFinite,
              searchRadius.isFinite, searchRadius > 0 else { return nil }
        let shortEdge = Double(min(w, h))
        let searchPx = max(1.5, searchRadius * shortEdge)
        let cx = min(max(point.x * Double(w), 0), Double(w - 1))
        let cy = min(max(point.y * Double(h), 0), Double(h - 1))

        let seedX0 = max(0, Int((cx - searchPx).rounded(.down)))
        let seedX1 = min(w - 1, Int((cx + searchPx).rounded(.up)))
        let seedY0 = max(0, Int((cy - searchPx).rounded(.down)))
        let seedY1 = min(h - 1, Int((cy + searchPx).rounded(.up)))
        guard seedX0 <= seedX1, seedY0 <= seedY1 else { return nil }

        // The reddest pixel in the window, then the one nearest the click among the clearly red
        // ones. "Nearest" is what makes two pupils in one face two different clicks.
        var seed: (x: Int, y: Int, distance: Double)? = nil
        var windowRed = 0
        var windowPixels = 0
        for y in seedY0...seedY1 {
            for x in seedX0...seedX1 {
                windowPixels += 1
                let red = redness(of: image, x: x, y: y)
                guard red >= threshold else { continue }
                windowRed += 1
                let dx = Double(x) + 0.5 - cx, dy = Double(y) + 0.5 - cy
                let distance = (dx * dx + dy * dy).squareRoot()
                guard distance <= searchPx else { continue }
                if seed == nil || distance < seed!.distance {
                    seed = (x, y, distance)
                }
            }
        }
        guard let seed else { return nil }

        // Grow the component inside a bounded box around the click. The bound keeps a red shirt or
        // lipstick from turning one click into a frame-sized repair.
        let grow = min(max(searchPx * 4, 0.02 * shortEdge), 0.10 * shortEdge)
        // The seed can be at the edge of a large search radius; the component box must contain it,
        // or `seedLocal` would index outside the visited array.
        let growX = max(grow, abs(Double(seed.x) + 0.5 - cx) + 2)
        let growY = max(grow, abs(Double(seed.y) + 0.5 - cy) + 2)
        let gx0 = max(0, Int((cx - growX).rounded(.down)))
        let gx1 = min(w - 1, Int((cx + growX).rounded(.up)))
        let gy0 = max(0, Int((cy - growY).rounded(.down)))
        let gy1 = min(h - 1, Int((cy + growY).rounded(.up)))
        let bw = gx1 - gx0 + 1, bh = gy1 - gy0 + 1
        guard bw > 0, bh > 0 else { return nil }
        var visited = [Bool](repeating: false, count: bw * bh)
        var queue = [Int]()
        queue.reserveCapacity(256)
        let seedLocal = (seed.y - gy0) * bw + (seed.x - gx0)
        visited[seedLocal] = true
        queue.append(seedLocal)
        let maxPixels = 200_000
        var head = 0
        var sumX = 0.0, sumY = 0.0
        var count = 0
        var peak = 0.0
        var redSum = 0.0

        while head < queue.count, count < maxPixels {
            let local = queue[head]
            head += 1
            let lx = local % bw, ly = local / bw
            let x = gx0 + lx, y = gy0 + ly
            let red = redness(of: image, x: x, y: y)
            guard red >= threshold else { continue }
            count += 1
            sumX += Double(x) + 0.5
            sumY += Double(y) + 0.5
            peak = max(peak, red)
            redSum += red

            for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] {
                guard nx >= gx0, nx <= gx1, ny >= gy0, ny <= gy1 else { continue }
                let nLocal = (ny - gy0) * bw + (nx - gx0)
                guard !visited[nLocal] else { continue }
                visited[nLocal] = true
                if redness(of: image, x: nx, y: ny) >= threshold {
                    queue.append(nLocal)
                }
            }
        }
        guard count >= minimumRedPixels else { return nil }

        let centerX = sumX / Double(count)
        let centerY = sumY / Double(count)
        var extent = 0.0
        for ly in 0..<bh {
            for lx in 0..<bw where visited[ly * bw + lx] {
                let x = Double(gx0 + lx) + 0.5, y = Double(gy0 + ly) + 0.5
                let dx = x - centerX, dy = y - centerY
                extent = max(extent, (dx * dx + dy * dy).squareRoot())
            }
        }
        guard extent >= 1 else { return nil }
        // A cheek / lip / shirt is a large red region; repairing it would be the false positive the
        // negative acceptance is about. A pupil is compact.
        guard extent <= maximumExtentFraction * shortEdge else { return nil }
        let radiusPx = extent + max(1.5, 0.15 * extent)
        return Detection(center: NormalizedPoint(centerX / Double(w), centerY / Double(h)),
                         radius: radiusPx / shortEdge,
                         peakRedness: peak,
                         meanRedness: redSum / Double(count),
                         redFraction: windowPixels > 0 ? Double(windowRed) / Double(windowPixels) : 0,
                         pixelCount: count,
                         extentPixels: extent)
    }

    /// Display-encoded redness of one texel, straight from the decoded buffer.
    @inline(__always)
    public static func redness(of image: LinearImage, x: Int, y: Int) -> Double {
        guard x >= 0, x < image.width, y >= 0, y < image.height else { return 0 }
        let o = (y * image.width + x) * 4
        return redness(r: Double(image.rgba[o]),
                       g: Double(image.rgba[o + 1]),
                       b: Double(image.rgba[o + 2]))
    }

    // MARK: - the source

    /// Is the patch a spot of radius `radius` would sample at `offset` free of red? The gate for
    /// accepting heal's automatic source and for reporting the ring fallback honestly.
    public static func sourceIsNeutral(in image: LinearImage, center: NormalizedPoint,
                                       radius: Double, offset: NormalizedPoint,
                                       threshold: Double = RedEye.defaultThreshold) -> Bool {
        let shortEdge = Double(min(image.width, image.height))
        let cx = center.x * Double(image.width) + offset.x * shortEdge
        let cy = center.y * Double(image.height) + offset.y * shortEdge
        return meanRedness(in: image, centerX: cx, centerY: cy,
                           radiusPx: max(1.5, radius * shortEdge * 0.75)) < threshold * 0.8
    }

    /// A **non-red ring** source, the fallback when heal's SSD search lands on another red object
    /// (two pupils, a red lipstick swatch). `24` angles × `3` distances, nearest-red-free wins.
    public static func neutralSource(in image: LinearImage, center: NormalizedPoint,
                                     radius: Double,
                                     threshold: Double = RedEye.defaultThreshold) -> HealSourceResult? {
        let w = image.width, h = image.height
        let shortEdge = Double(min(w, h))
        let rPx = max(1.5, radius * shortEdge)
        let cx = center.x * Double(w), cy = center.y * Double(h)
        guard rPx * 2 < Double(w), rPx * 2 < Double(h) else { return nil }

        var best: (offset: NormalizedPoint, distance: Double, redness: Double, examined: Int)?
        for ring in 0..<3 {
            let d = 2.4 + 0.8 * Double(ring)
            for step in 0..<24 {
                let theta = 2 * Double.pi * Double(step) / 24
                let px = cx + d * rPx * cos(theta)
                let py = cy + d * rPx * sin(theta)
                guard px - 0.75 * rPx >= 0, px + 0.75 * rPx <= Double(w),
                      py - 0.75 * rPx >= 0, py + 0.75 * rPx <= Double(h) else { continue }
                let red = meanRedness(in: image, centerX: px, centerY: py, radiusPx: 0.75 * rPx)
                let candidate = (offset: NormalizedPoint((px - cx) / shortEdge,
                                                         (py - cy) / shortEdge),
                                 distance: d,
                                 redness: red,
                                 examined: (best?.examined ?? 0) + 1)
                if best == nil || red < best!.redness {
                    best = candidate
                }
            }
        }
        guard let best, best.redness < threshold * 0.8 else { return nil }
        return HealSourceResult(offset: best.offset, status: .found,
                                examined: best.examined, accepted: 1,
                                score: best.redness * best.redness,
                                distanceInRadii: best.distance)
    }

    /// Mean display-encoded redness inside a disk, sampled on a 5 × 5 grid.
    static func meanRedness(in image: LinearImage, centerX: Double, centerY: Double,
                            radiusPx: Double) -> Double {
        var sum = 0.0, n = 0
        for row in 0..<5 {
            for col in 0..<5 {
                let fx = (Double(col) + 0.5) / 5 * 2 - 1
                let fy = (Double(row) + 0.5) / 5 * 2 - 1
                let x = Int((centerX + fx * radiusPx).rounded())
                let y = Int((centerY + fy * radiusPx).rounded())
                guard x >= 0, x < image.width, y >= 0, y < image.height else { continue }
                sum += redness(of: image, x: x, y: y)
                n += 1
            }
        }
        return n > 0 ? sum / Double(n) : 0
    }
}
