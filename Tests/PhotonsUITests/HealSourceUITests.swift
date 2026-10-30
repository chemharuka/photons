import XCTest
import PhotonsCore
@testable import PhotonsUI

/// 184 — the UI side of 自动取源: the switch, the provider, and what a click writes.
@MainActor
final class HealSourceUITests: XCTestCase {

    private func session() -> CatalogSession { CatalogSession() }

    private static func hash01(_ x: Int, _ y: Int) -> Double {
        var h = UInt32(truncatingIfNeeded: x &* 73_856_093) &+ UInt32(truncatingIfNeeded: y &* 19_349_663)
        h = (h ^ (h >> 13)) &* 2_654_435_761
        h ^= h >> 16
        return Double(h % 1000) / 1000.0
    }

    /// 600 × 600: the same flat-gradient + round-blemish construction as `HealAutoSourceTests` A,
    /// in a smaller size so a UI test does not pay for a megapixel buffer.
    private func syntheticFrame() -> LinearImage {
        let width = 600, height = 600
        let radiusPx = 0.03 * Double(min(width, height))
        let cx = 0.5 * Double(width), cy = 0.5 * Double(height)
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                var v = 0.35 + 0.25 * (Double(x) + 0.5) / Double(width)
                v += 0.001 * Self.hash01(x, y)
                let dx = Double(x) + 0.5 - cx
                let dy = Double(y) + 0.5 - cy
                if (dx * dx + dy * dy).squareRoot() < radiusPx { v *= 0.97 }
                let o = (y * width + x) * 4
                rgba[o] = Float16(v); rgba[o + 1] = Float16(v)
                rgba[o + 2] = Float16(v); rgba[o + 3] = 1
            }
        }
        return LinearImage(width: width, height: height, rgba: rgba,
                           colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic-ui-184")
    }

    func testAutoSourceOffIsTheLegacyOffset() throws {
        let s = session()
        s.autoHealSource = false
        let spot = try XCTUnwrap(s.addHealSpot(at: NormalizedPoint(0.5, 0.5), radius: 0.03))
        XCTAssertEqual(spot.sourceOffset.x.bitPattern, (0.03 * 2).bitPattern)
        XCTAssertEqual(spot.sourceOffset.y.bitPattern, Double(0).bitPattern)
        XCTAssertEqual(s.lastHealSource?.status, .searchSkipped)
    }

    func testNoFrameFallsBack() throws {
        let s = session()
        let before = s.history.count
        let spot = try XCTUnwrap(s.addHealSpot(at: NormalizedPoint(0.5, 0.5), radius: 0.03))
        XCTAssertEqual(spot.sourceOffset.x.bitPattern, (0.03 * 2).bitPattern)
        XCTAssertEqual(spot.sourceOffset.y.bitPattern, Double(0).bitPattern)
        XCTAssertEqual(s.lastHealSource?.status, .searchSkipped)
        XCTAssertEqual(s.history.count, before + 1, "一次点击一行历史，回退不额外写")
    }

    func testAutoSourceOnWritesTheSearchedOffset() throws {
        let s = session()
        let frame = syntheticFrame()
        s.healFrameProvider = { frame }
        let spot = try XCTUnwrap(s.addHealSpot(at: NormalizedPoint(0.5, 0.5), radius: 0.03))
        let legacy = HealSpot.defaultSourceOffset(radius: 0.03)
        XCTAssertNotEqual(spot.sourceOffset, legacy)
        XCTAssertEqual(s.lastHealSource?.status, .found)
        print("UI auto source offset=\(spot.sourceOffset.x),\(spot.sourceOffset.y) "
              + "d=\(s.lastHealSource?.distanceInRadii ?? -1)")
    }

    func testThePanelCarriesTheAutoSourceToggle() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // PhotonsUITests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // repo
            .appendingPathComponent("Sources/PhotonsUI/MaskListPanel.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(source.contains("inspector.heal.autoSource"))
        XCTAssertTrue(source.contains("自动取源"))
    }
}
