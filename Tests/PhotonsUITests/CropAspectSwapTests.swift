import XCTest
import PhotonsCore
@testable import PhotonsUI

/// 072 §C — 比例：交换长宽 + 自定义比例.
///
/// C1 交换长宽 acts on whatever ratio is in force (a preset, 原始, or a custom one), keeps the frame's
/// centre and takes the **largest area the frame holds** at the new ratio — which is the only shape of
/// the operation that makes 16:9 → 9:16 → 16:9 come back to the same four edges (a swap that fitted
/// inside the *current* box would shrink twice).
///
/// C2 自定义比例 locks a typed `W:H` into `AspectLock.custom`, so it is the document that remembers it;
/// every handle drag afterwards keeps it (measured: 8 drags, ≤0.5 %), and illegal input is refused
/// before anything is written.
@MainActor
final class CropAspectSwapTests: XCTestCase {

    /// The upright frame of the pinned file, and the same picture with its axes transposed — the two
    /// cases where an implicit second swap would show up.
    private let landscape = ImageSize(width: 1200, height: 800)
    private let portrait = ImageSize(width: 800, height: 1200)

    private func controller(source: ImageSize) -> CropToolController {
        // No session: every §C path is pure draft arithmetic (`swapAspect` / `setCustomRatio` /
        // `CropToolDrag`), and a controller without one keeps the test off the document entirely.
        let tool = CropToolController(session: nil)
        tool.draft = CropToolController.Draft(crop: .full, straighten: 0, lock: .original)
        _ = source
        return tool
    }

    private func pixelRatio(_ tool: CropToolController, source: ImageSize) -> Double {
        let c = tool.draft.crop
        return (c.width * Double(source.width)) / max(c.height * Double(source.height), 1e-9)
    }

    // MARK: - C1

    /// 16:9 → 9:16 → 16:9: the four edges and the pixel size come back **exactly**, and 9:16 measures
    /// 0.5625.
    func testSwappingSixteenNineBackAndForthRestoresTheSameRect() throws {
        let tool = controller(source: landscape)
        tool.setAspect(.sixteenNine, source: landscape)
        let first = tool.draft.crop
        let firstPixels = CropMath.pixelRect(first, in: landscape)

        XCTAssertTrue(tool.swapAspect(source: landscape))
        let swapped = tool.draft.crop
        let swappedRatio = pixelRatio(tool, source: landscape)
        print(String(format: "C1 · 16:9 → 9:16 · ratio %.6f · rect %@ · pixels %d×%d",
                     swappedRatio, swapped.keyString, CropMath.pixelRect(swapped, in: landscape).width,
                     CropMath.pixelRect(swapped, in: landscape).height))
        XCTAssertEqual(swappedRatio, 9.0 / 16.0, accuracy: 0.005 * 9.0 / 16.0, "§C1: 9:16 ±0.5%")
        XCTAssertEqual(swapped.centerX, first.centerX, accuracy: 1e-12, "§C1: 框中心不动")
        XCTAssertEqual(swapped.centerY, first.centerY, accuracy: 1e-12)
        XCTAssertEqual(swapped.height, 1, accuracy: 1e-12, "the max-area 9:16 uses the full height")
        XCTAssertEqual(swapped.width * Double(landscape.width),
                       swapped.height * Double(landscape.height) * 9.0 / 16.0, accuracy: 1e-6)

        tool.swapAspect(source: landscape)
        let back = tool.draft.crop
        print("C1 · 9:16 → 16:9 · rect \(back.keyString) · equals the first: \(back == first)")
        XCTAssertEqual(back.left, first.left, accuracy: 1e-12)
        XCTAssertEqual(back.top, first.top, accuracy: 1e-12)
        XCTAssertEqual(back.right, first.right, accuracy: 1e-12)
        XCTAssertEqual(back.bottom, first.bottom, accuracy: 1e-12)
        XCTAssertEqual(back.keyString, first.keyString, "§C1: 四值逐值相等")
        XCTAssertEqual(CropMath.pixelRect(back, in: landscape), firstPixels, "§C1: 像素逐值相等")
        XCTAssertEqual(tool.draft.lock.code, AspectLock.sixteenNine.code,
                       "and 16:9 comes back as the preset, not as an anonymous custom")
    }

    /// 原始比例 swap = the physical width/height exchange, once — on a landscape and on a portrait
    /// upright frame (EXIF 6/8 already mapped into `sourceSize`), with no second implicit swap.
    func testSwappingTheOriginalRatioIsThePhysicalExchange() {
        for (name, source, expected) in [("landscape 1200×800", landscape, 2.0 / 3.0),
                                         ("portrait 800×1200", portrait, 3.0 / 2.0)] {
            let tool = controller(source: source)
            XCTAssertEqual(tool.draft.lock, .original, "原始 starts unconstrained")
            XCTAssertTrue(tool.swapAspect(source: source))
            let ratio = pixelRatio(tool, source: source)
            print(String(format: "C1 · 原始 %@ → %.6f (expected %.6f)", name, ratio, expected))
            XCTAssertEqual(ratio, expected, accuracy: expected * 0.005, "§C1: physical W:H exchanged once")
            // A swap is not a no-op and not a second swap: 3:2 becomes 2:3, never 3:2 again.
            XCTAssertNotEqual(ratio, Double(source.width) / Double(source.height), accuracy: 1e-9)
            XCTAssertEqual(tool.draft.crop.centerX, 0.5, accuracy: 1e-12)
        }
    }

    // MARK: - C2

    /// A custom 4:3 stays locked through all eight drags (four corners, four edges), ≤0.5 %.
    func testACustomRatioSurvivesEveryHandle() {
        let tool = controller(source: landscape)
        XCTAssertTrue(tool.setCustomRatio(4.0 / 3.0, source: landscape))
        XCTAssertEqual(tool.draft.lock.code, AspectLock.custom(4.0 / 3.0).code, "§C2: the lock is custom(4/3)")
        let target = 4.0 / 3.0
        var rows: [String] = []

        let handles: [CropToolHandle] = [.topLeft, .topRight, .bottomRight, .bottomLeft,
                                         .top, .right, .bottom, .left]
        for handle in handles {
            let start = tool.draft.crop
            let grab = NormalizedPoint(start.centerX, start.centerY)
            // Drag the grip 6 % of the frame towards the centre — every direction a hand would take.
            let inward: NormalizedPoint
            switch handle {
            case .topLeft: inward = NormalizedPoint(start.left + 0.06, start.top + 0.06)
            case .topRight: inward = NormalizedPoint(start.right - 0.06, start.top + 0.06)
            case .bottomRight: inward = NormalizedPoint(start.right - 0.06, start.bottom - 0.06)
            case .bottomLeft: inward = NormalizedPoint(start.left + 0.06, start.bottom - 0.06)
            case .top: inward = NormalizedPoint(start.centerX, start.top + 0.06)
            case .right: inward = NormalizedPoint(start.right - 0.06, start.centerY)
            case .bottom: inward = NormalizedPoint(start.centerX, start.bottom - 0.06)
            default: inward = NormalizedPoint(start.left + 0.06, start.centerY)
            }
            let drag = CropToolDrag(handle: handle, crop: start, grab: grab)
            tool.draft.crop = drag.crop(at: inward, source: landscape, lock: tool.draft.lock)
            // Restore the size between drags so each grip is measured from the same 4:3 box.
            let ratio = pixelRatio(tool, source: landscape)
            let error = abs(ratio - target) / target
            rows.append(String(format: "%@ → %.6f (%.3f%%)", handle.label, ratio, error * 100))
            XCTAssertLessThanOrEqual(error, 0.005, "§C2: \(handle.label) broke the 4:3 lock")
            tool.setCustomRatio(target, source: landscape)
        }
        print("C2 · 4:3 drag table:\n  " + rows.joined(separator: "\n  "))
    }

    /// The lock is the document's field: apply → the document carries `custom(4/3)`, a later `begin()`
    /// seeds it back, and 取消 throws away a preset switch without touching it.
    func testTheCustomRatioIsStoredInTheDocument() throws {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-custom-ratio-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let (session, _) = try CropUITestSupport.makeSession(in: workDir)
        let tool = CropToolController(session: session)
        XCTAssertTrue(tool.begin())
        XCTAssertTrue(tool.setCustomRatio(4.0 / 3.0))
        XCTAssertTrue(tool.apply())
        XCTAssertEqual(session.edit.geometry.aspectLock.code, AspectLock.custom(4.0 / 3.0).code,
                       "§C2: 比例进文档")
        let committed = session.edit.geometry.cropRect

        // A preset switch that is cancelled: the document's custom ratio is what comes back.
        XCTAssertTrue(tool.begin())
        tool.setAspect(.square)
        XCTAssertEqual(tool.draft.lock, .square)
        tool.cancel()
        XCTAssertTrue(tool.begin())
        XCTAssertEqual(tool.draft.lock.code, AspectLock.custom(4.0 / 3.0).code,
                       "§C2: 切换比例再切回不丢 — the document is the memory")
        XCTAssertEqual(tool.draft.crop.keyString, committed.keyString)
        tool.cancel()

        // The UI preference is a *separate* thing: the last typed string, never the ratio itself.
        let key = CropToolBar.customRatioDefaultsKey
        let previous = UserDefaults.standard.string(forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        CropToolBar.lastCustomRatioText = "7:5"
        XCTAssertEqual(UserDefaults.standard.string(forKey: key), "7:5", "§C2: 上次值作 UI 偏好")
        XCTAssertEqual(CropToolBar.lastCustomRatioText, "7:5")
    }

    // MARK: - C2 validation

    /// 非法输入（0 / 负 / 空 / 非数字）拒绝且不改当前比例.
    func testIllegalRatiosAreRefusedAndNothingChanges() {
        let accepted = ["4:3", "16:9", "1:1", "4/3", "1.5", " 3:2 ", "0.5625"]
        for text in accepted {
            XCTAssertNotNil(CropTool.ratio(from: text), "\"\(text)\" should parse")
        }
        XCTAssertEqual(CropTool.ratio(from: "4:3")!, 4.0 / 3.0, accuracy: 1e-12)
        XCTAssertEqual(CropTool.ratio(from: "16:9")!, 16.0 / 9.0, accuracy: 1e-12)
        XCTAssertEqual(CropTool.ratio(from: "1.5")!, 1.5, accuracy: 1e-12)

        let rejected = ["", "   ", "0", "0:1", "1:0", "-3", "-3:2", "3:-2", "abc", "4:abc",
                        "1e5", "nan", "inf", "0.0", "4:3:1", "::"]
        for text in rejected {
            XCTAssertNil(CropTool.ratio(from: text), "\"\(text)\" must be refused")
        }
        print("C2 · parser: accepts \(accepted) · refuses \(rejected.count) bad forms")

        // The controller refuses too, and the ratio in force does not move.
        let tool = controller(source: landscape)
        XCTAssertTrue(tool.setCustomRatio(16.0 / 9.0, source: landscape))
        let lockBefore = tool.draft.lock
        let cropBefore = tool.draft.crop
        for bad in [0.0, -1.5, .nan, .infinity] {
            XCTAssertFalse(tool.setCustomRatio(bad, source: landscape), "\(bad) must be refused")
            XCTAssertEqual(tool.draft.lock, lockBefore)
            XCTAssertEqual(tool.draft.crop, cropBefore)
        }
    }
}
