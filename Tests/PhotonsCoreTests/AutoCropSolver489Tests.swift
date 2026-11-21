import XCTest
import PhotonsCore

/// 489 §2.3 — 自动裁剪 = the largest axis-aligned rectangle that introduces no black corner.
///
/// The solver is compared against an **independent brute-force** scan of the same polygon, not
/// against its own arithmetic, and every corner of the answer is asserted inside the polygon.
final class AutoCropSolver489Tests: XCTestCase {

    func testAnUprightPictureIsTheWholeFrame() {
        let square = [NormalizedPoint(0, 0), NormalizedPoint(1, 0),
                      NormalizedPoint(1, 1), NormalizedPoint(0, 1)]
        let rect = AutoCropSolver.maximumRectangle(in: square)
        XCTAssertEqual(rect?.x ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(rect?.y ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(rect?.width ?? -1, 1, accuracy: 1e-9)
        XCTAssertEqual(rect?.height ?? -1, 1, accuracy: 1e-9)
    }

    func testThirtyDegreeRotationHasNoBlackCornersAndIsWithinOnePercentOfOptimum() throws {
        // A 70 % square rotated about its centre: its corners stay inside `[0,1]²`, so the solver's
        // legal-box clip is not what produces the answer.
        let polygon = rotatedRectangle(width: 300, height: 300, degrees: 30, inset: 0.7)
        let rect = try XCTUnwrap(AutoCropSolver.maximumRectangle(in: polygon))
        let corners = [NormalizedPoint(rect.x, rect.y),
                       NormalizedPoint(rect.x + rect.width, rect.y),
                       NormalizedPoint(rect.x + rect.width, rect.y + rect.height),
                       NormalizedPoint(rect.x, rect.y + rect.height)]
        for corner in corners {
            XCTAssertTrue(CropMath.quadContains(polygon, x: corner.x, y: corner.y),
                          "自动裁剪 的角 \(corner) 在照片多边形外 —— 会出 000000")
        }
        let optimum = bruteForceArea(polygon)
        let area = Double(rect.width * rect.height)
        print(String(format: "489 自动裁剪: 30° · solver %.6f · brute %.6f · ratio %.4f",
                     area, optimum, area / max(optimum, 1e-12)))
        XCTAssertGreaterThanOrEqual(area, optimum * 0.99,
                                    "自动裁剪面积 \(area) 小于枚举最优 \(optimum) 的 99%")
    }

    func testAQuarterTurnLeavesTheWholeFrameValid() {
        let polygon = rotatedRectangle(width: 200, height: 200, degrees: 90)
        let rect = AutoCropSolver.maximumRectangle(in: polygon)
        XCTAssertNotNil(rect)
        XCTAssertEqual(Double((rect?.width ?? 0) * (rect?.height ?? 0)), 1.0, accuracy: 1e-9,
                       "90° 是轴对齐的，最大矩形仍是整幅")
    }

    // MARK: - fixtures

    /// The source rectangle rotated about its centre and normalized back to the source frame.
    private func rotatedRectangle(width: Double, height: Double, degrees: Double,
                                  inset: Double = 1) -> [NormalizedPoint] {
        let r = CropGeometry.RotationMatrix(degrees: degrees)
        return [(0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 1.0)].map { corner in
            let x = (corner.0 - 0.5) * width * inset
            let y = (corner.1 - 0.5) * height * inset
            let p = r.apply(x: x, y: y)
            return NormalizedPoint(0.5 + p.x / width, 0.5 + p.y / height)
        }
    }

    /// Independent optimum: scan the left/right edges, measure the highest strip the polygon allows
    /// between them by sampling the vertical chord, and take the largest area. Deliberately shares no
    /// code with the solver's corner enumeration.
    private func bruteForceArea(_ polygon: [NormalizedPoint]) -> Double {
        let steps = 800
        var best = 0.0
        for i in 0...steps {
            let l = Double(i) / Double(steps)
            for j in i...steps {
                let r = Double(j) / Double(steps)
                guard r - l > 1e-4 else { continue }
                var top = Double.infinity
                var bottom = -Double.infinity
                for k in 0...24 {
                    let x = l + (r - l) * Double(k) / 24
                    let (lo, hi) = chord(polygon, x: x)
                    guard lo <= hi else { continue }
                    top = min(top, hi)
                    bottom = max(bottom, lo)
                }
                let height = top - bottom
                if height > 0 { best = max(best, (r - l) * height) }
            }
        }
        return best
    }

    private func chord(_ polygon: [NormalizedPoint], x: Double) -> (Double, Double) {
        var values: [Double] = []
        for i in polygon.indices {
            let a = polygon[i], b = polygon[(i + 1) % polygon.count]
            if abs(b.x - a.x) < 1e-12 {
                if abs(x - a.x) < 1e-9 { values.append(a.y); values.append(b.y) }
                continue
            }
            let t = (x - a.x) / (b.x - a.x)
            if t >= -1e-9 && t <= 1 + 1e-9 {
                values.append(a.y + (b.y - a.y) * t)
            }
        }
        return (values.min() ?? 0, values.max() ?? 0)
    }
}
