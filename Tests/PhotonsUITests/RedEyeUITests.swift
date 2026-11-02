import XCTest
import AppKit
import PhotonsCore
@testable import PhotonsUI

/// 229 — 红眼's session/UI surface.
///
/// The three things this file pins:
///
///  1. **One click = one snapshot**, found pupil or not. Three clicks produce exactly three rows —
///     the real-photo acceptance — while a click with no pupil writes the `noopThreshold` gate that
///     changes zero pixels.
///  2. **The landed spot is a heal spot with `kind: .redeye`** and the card's strength as opacity.
///  3. **The card actually carries the four 红眼 controls** (`inspector.redeye.*`), including the
///     0.5…8 pt radius travel.
@MainActor
final class RedEyeUITests: XCTestCase {

    private func session() -> CatalogSession { CatalogSession() }

    private func picture(width: Int = 256, height: Int = 256,
                         circle: (x: Double, y: Double, r: Double)?) -> LinearImage {
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                var r = 0.52, g = 0.49, b = 0.46
                if let circle {
                    let dx = Double(x) + 0.5 - circle.x
                    let dy = Double(y) + 0.5 - circle.y
                    if (dx * dx + dy * dy).squareRoot() <= circle.r {
                        r = 1; g = 0.05; b = 0.05
                    }
                }
                let o = (y * width + x) * 4
                rgba[o] = Float16(r); rgba[o + 1] = Float16(g)
                rgba[o + 2] = Float16(b); rgba[o + 3] = 1
            }
        }
        return LinearImage(width: width, height: height, rgba: rgba,
                           colorSpace: "extendedLinearSRGB",
                           decoderVersion: "synthetic-redeye-ui")
    }

    // MARK: - 1. one click, one snapshot

    func testThreeClicksMakeExactlyThreeHistoryRows() throws {
        let s = session()
        s.applyEdit { $0.light.exposure = 0.2 }
        s.commitEdit(label: "曝光")
        let image = picture(circle: (128.5, 128.5, 10))
        s.healFrameProvider = { image }
        s.redEyeFaceHintProvider = { _ in [] }   // deterministic; Vision is exercised separately
        let before = s.history.count

        // one click on the pupil, two on skin / empty wall
        XCTAssertNotNil(s.addRedEyeSpot(at: NormalizedPoint(128.5 / 256, 128.5 / 256),
                                        searchRadius: 0.06))
        XCTAssertNotNil(s.lastRedEyeDetection, "第一击命中了红瞳")
        XCTAssertNotNil(s.addRedEyeSpot(at: NormalizedPoint(0.2, 0.2), searchRadius: 0.06))
        XCTAssertNotNil(s.addRedEyeSpot(at: NormalizedPoint(0.8, 0.3), searchRadius: 0.06))

        XCTAssertEqual(s.edit.healSpots.count, 3)
        XCTAssertEqual(s.history.count, before + 3, "三次点击 = 恰好三行历史")
        XCTAssertTrue(s.edit.healSpots.allSatisfy { $0.kind == .redeye })

        let found = s.edit.healSpots[0]
        XCTAssertEqual(found.redThreshold, RedEye.defaultThreshold, accuracy: 1e-12,
                       "命中红瞳的点带着检测阈值")
        XCTAssertLessThan(found.redSoftness, 0.2)
        XCTAssertEqual(found.feather, 0, "红眼用红门做边，不用 disk feather")
        XCTAssertEqual(found.mode, .heal, "红眼是 heal 的预设，不是新算子")

        XCTAssertEqual(s.edit.healSpots[1].redThreshold, RedEye.noopThreshold,
                       "没有红瞳的点击写一个零像素的门")
        XCTAssertNil(s.lastRedEyeDetection, "最后一次点击没有红瞳")

        XCTAssertTrue(s.undo(), "⌘Z 一次撤销最后一条")
        XCTAssertEqual(s.edit.healSpots.count, 2)
    }

    func testTheCardRadiusAndStrengthAreWhatTheSessionStores() {
        let s = session()
        s.redEyeRadiusPoints = 0.5
        XCTAssertEqual(s.redEyeRadiusPoints, 0.5)
        s.redEyeRadiusPoints = 8
        XCTAssertEqual(s.redEyeRadiusPoints, 8)
        s.redEyeStrength = 0.35
        XCTAssertEqual(s.redEyeStrength, 0.35, accuracy: 1e-12)
        s.healToolMode = .redeye
        XCTAssertEqual(s.healToolMode, .redeye)
    }

    /// 229 — the eye landmark's box is the **initial radius**, not a claimed pupil. With a seed far
    /// too small to reach the disk, the hint is what makes the detector see it; the source is still
    /// the pixels.
    func testAFaceEyeHintSizesTheSeedAndThePixelsStillDecide() throws {
        let s = session()
        let image = picture(circle: (128.5, 128.5, 8))
        s.healFrameProvider = { image }
        s.redEyeRadiusPoints = 0.5
        s.redEyeFaceHintProvider = { _ in
            [RedEyeFaceHint(kind: .face,
                            bounds: NormalizedRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2),
                            eyeBounds: [NormalizedRect(x: 0.45, y: 0.45,
                                                       width: 0.1, height: 0.1)])]
        }
        // Without the hint this seed (0.0015 × 256 = 0.38 px) could not reach the 8 px disk.
        let spot = try XCTUnwrap(s.addRedEyeSpot(at: NormalizedPoint(0.5, 0.5),
                                                 searchRadius: 0.0015))
        XCTAssertEqual(spot.redThreshold, RedEye.defaultThreshold,
                       "眼睛框给了半径，红门仍是像素测出来的")
        XCTAssertNotNil(s.lastRedEyeDetection)
    }

    func testAnAnimalBoxSizesTheSeedButThereIsNoPupilClaim() throws {
        let s = session()
        let image = picture(circle: (128.5, 128.5, 8))
        s.healFrameProvider = { image }
        s.redEyeRadiusPoints = 0.5
        s.redEyeFaceHintProvider = { _ in
            [RedEyeFaceHint(kind: .animal,
                            bounds: NormalizedRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2),
                            eyeBounds: [], labels: ["cat"])]
        }
        let spot = try XCTUnwrap(s.addRedEyeSpot(at: NormalizedPoint(0.5, 0.5),
                                                 searchRadius: 0.0015))
        XCTAssertEqual(spot.redThreshold, RedEye.defaultThreshold,
                       "动物框只给种子半径；瞳孔位置仍然由红色像素决定")
        XCTAssertGreaterThan(spot.radius, 8.0 / 256.0 * 0.9)
    }

    // MARK: - 2. the real photograph

    /// The acceptance's real-photo gate: three clicks on `L1030433.dng` must not throw, must not
    /// produce a history row per internal write, and must produce exactly three rows.
    func testThreeClicksOnTheRealPhotoMakeThreeRows() throws {
        let candidates = [
            ProcessInfo.processInfo.environment["PHOTONS_TEST_RAW"],
            NSString(string: "~/Desktop/test/L1030433.dng").expandingTildeInPath,
        ].compactMap { $0 }
        guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) })
        else { throw XCTSkip("no RAW fixture; set PHOTONS_TEST_RAW") }

        let decoder = try RAWDecoder()
        let image = try decoder.decode(URL(fileURLWithPath: path),
                                       options: DecodeOptions(scale: 0.1))

        let s = session()
        s.applyEdit { $0.light.exposure = 0.15 }
        s.commitEdit(label: "曝光")
        s.healFrameProvider = { image }
        s.redEyeFaceHintProvider = { _ in [] }
        let before = s.history.count

        for point in [NormalizedPoint(0.3, 0.3), NormalizedPoint(0.5, 0.5),
                      NormalizedPoint(0.7, 0.4)] {
            XCTAssertNotNil(s.addRedEyeSpot(at: point, searchRadius: 0.02),
                            "真实照片上的点击不得崩、不得被拒绝")
        }
        XCTAssertEqual(s.edit.healSpots.count, 3)
        XCTAssertEqual(s.history.count, before + 3, "必须恰好 3 条历史")
        print("RedEye real photo: 3 spots, detections="
              + s.edit.healSpots.map { $0.redThreshold == RedEye.noopThreshold ? "noop" : "hit" }
                .joined(separator: ","))
    }

    // MARK: - 3. the card

    func testTheHealCardCarriesTheRedEyeControls() throws {
        let source = try String(contentsOf: Self.repoRoot
            .appendingPathComponent("Sources/PhotonsUI/HealCardPanel.swift"), encoding: .utf8)
        for identifier in ["inspector.redeye.mode", "inspector.redeye.radius",
                           "inspector.redeye.strength", "inspector.redeye.hint"] {
            XCTAssertTrue(source.contains(identifier), "缺 \(identifier)")
        }
        XCTAssertTrue(source.contains("RedEye.radiusPointsRange"), "半径滑杆的 0.5…8 pt 行程")
        XCTAssertTrue(source.contains("HealToolMode.allCases"), "修复 / 红眼 分段")
        XCTAssertTrue(source.contains("点一下修一只红眼；拖动连续修补"))
        // The pre-229 heal controls stay where they were.
        XCTAssertTrue(source.contains("inspector.heal.tool"))
        XCTAssertTrue(source.contains("inspector.heal.mode"))
    }

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // PhotonsUITests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // repo
    }
}
