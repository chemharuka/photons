import XCTest
import AppKit
import PhotonsCore
@testable import PhotonsUI

/// 2026-11-12 (user) — 2:3 按钮按当前框的横竖定方向，⇄ 恢复并把当前比例取反.
///
/// 用户原话：
///
///   > 裁剪界面，长宽比之前的交换按钮没了。用户点击 2:3 时，按一下交换，那么实际就变为 3:2。
///   > 进入的是 2:3 还是 3:2 取决于当前裁剪框的左右和上下高度比，左右长那么就是用比例中更大的
///   > （如 3）
///
/// 三层，逐层断言：
///
///   ① 控件层 —— `RatioButton.twoThree.lock(landscape:)` 是 `custom(3/2)` / `custom(2/3)`；
///   ② 控制器 —— 横框点 2:3 落 1.5，竖框落 0.6667；⇄ 各自取反，且自己就是自己的逆；
///   ③ 界面层 —— ⇄ 真的在树上（`inspector.crop.ratio.swap`），与自定义比例同一行，点一下把 3:2
///      变 2:3，且**只**动草稿.
@MainActor
final class CropAspectOrientationTests: XCTestCase {

    private var workDir: URL!
    private let landscape = ImageSize(width: 1200, height: 800)
    private let portrait = ImageSize(width: 800, height: 1200)

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-aspect-orient-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    private func controller() -> CropToolController {
        let tool = CropToolController(session: nil)
        tool.draft = CropToolController.Draft(crop: .full, straighten: 0, lock: .original)
        return tool
    }

    private func pixelRatio(_ tool: CropToolController, source: ImageSize) -> Double {
        let c = tool.draft.crop
        return (c.width * Double(source.width)) / max(c.height * Double(source.height), 1e-9)
    }

    // MARK: - ① 控件层

    /// The 2:3 button is the 3:2 **family**: same button, two numbers, chosen by the frame.
    func testTheTwoThreeButtonMeansOneNumberPerOrientation() {
        let wide = RatioButton.twoThree.lock(landscape: true).ratio ?? 0
        let tall = RatioButton.twoThree.lock(landscape: false).ratio ?? 0
        XCTAssertEqual(wide, 3.0 / 2.0, accuracy: 1e-12, "横构图点 2:3 → 3:2（更大的 3 在左边）")
        XCTAssertEqual(tall, 2.0 / 3.0, accuracy: 1e-12, "竖构图点 2:3 → 2:3")
        // 另外三颗不随方向变 —— 1:1 是自己的倒数，4:3 / 16:9 暂时只有一个拼法.
        for button in [RatioButton.square, .fourThree, .sixteenNine] {
            XCTAssertEqual(button.lock(landscape: true).ratio ?? 0,
                           button.lock(landscape: false).ratio ?? 0,
                           accuracy: 1e-12, "\(button.title) 不该随方向变")
        }
        print("① 2:3 → 横 \(RatioButton.twoThree.lock(landscape: true).code)"
              + " / 竖 \(RatioButton.twoThree.lock(landscape: false).code)")
    }

    /// `oriented` is the one spelling of "the other orientation of this number".
    func testOrientedIsTheLongSideOrItsReciprocal() {
        XCTAssertEqual(CropToolController.oriented(2.0 / 3.0, landscape: true), 1.5, accuracy: 1e-12)
        XCTAssertEqual(CropToolController.oriented(2.0 / 3.0, landscape: false), 2.0 / 3.0, accuracy: 1e-12)
        XCTAssertEqual(CropToolController.oriented(1.5, landscape: true), 1.5, accuracy: 1e-12)
        XCTAssertEqual(CropToolController.oriented(1.5, landscape: false), 2.0 / 3.0, accuracy: 1e-12)
        XCTAssertEqual(CropToolController.oriented(1, landscape: true), 1, accuracy: 1e-12)
        XCTAssertEqual(CropToolController.oriented(1, landscape: false), 1, accuracy: 1e-12)
    }

    // MARK: - ② 控制器

    /// `frameIsLandscape` reads the **draft rect in pixels**, not the photograph: a narrow crop of a
    /// landscape frame is portrait.
    func testTheFrameOrientationIsReadOffTheCropRectInPixels() {
        let tool = controller()
        XCTAssertTrue(tool.frameIsLandscape(source: landscape), "整幅横图 → 横")
        XCTAssertFalse(tool.frameIsLandscape(source: portrait), "整幅竖图 → 竖")

        tool.draft.crop = CropRect(left: 0.4, top: 0, right: 0.6, bottom: 1)
        XCTAssertFalse(tool.frameIsLandscape(source: landscape),
                       "1200×800 上取 20 % 宽：240×800 是竖的")
        print("② 同一个 1200×800：整幅=横，窄裁=竖")
    }

    /// Click 2:3 on a landscape frame → 3:2; press ⇄ → 2:3; press again → 3:2 with the first edges back.
    func testClickTwoThreeThenSwapWalksTheFamilyBothWays() {
        let tool = controller()
        XCTAssertTrue(tool.frameIsLandscape(source: landscape))
        _ = tool.setCustomRatio(RatioButton.twoThree.lock(landscape: true).ratio ?? 1, source: landscape)
        XCTAssertEqual(pixelRatio(tool, source: landscape), 1.5, accuracy: 0.005 * 1.5, "横框点 2:3 → 3:2")
        let wide = tool.draft.crop

        XCTAssertTrue(tool.swapAspect(source: landscape))
        XCTAssertEqual(pixelRatio(tool, source: landscape), 2.0 / 3.0, accuracy: 0.005 * 2.0 / 3.0,
                       "按一下 ⇄ → 2:3")
        XCTAssertEqual(tool.draft.lock.code, AspectLock.custom(2.0 / 3.0).code, "2:3 没有命名 preset，落 custom")

        XCTAssertTrue(tool.swapAspect(source: landscape))
        XCTAssertEqual(pixelRatio(tool, source: landscape), 1.5, accuracy: 0.005 * 1.5, "再按 ⇄ → 3:2")
        XCTAssertEqual(tool.draft.lock.code, AspectLock.threeTwo.code, "3:2 有命名 preset，回来时用它")
        XCTAssertEqual(tool.draft.crop.keyString, wide.keyString, "来回一趟四值回到原处")
        print("② 横框：2:3 → \(wide.keyString) → ⇄ 2:3 → ⇄ 3:2（四值复原）")
    }

    /// The same button on a portrait frame starts at 2:3 and swaps into 3:2.
    func testTheButtonStartsPortraitWhenTheFrameIsPortrait() {
        let tool = controller()
        XCTAssertFalse(tool.frameIsLandscape(source: portrait))
        _ = tool.setCustomRatio(RatioButton.twoThree.lock(landscape: false).ratio ?? 1, source: portrait)
        XCTAssertEqual(pixelRatio(tool, source: portrait), 2.0 / 3.0, accuracy: 0.005 * 2.0 / 3.0,
                       "竖框点 2:3 → 2:3")
        XCTAssertTrue(tool.swapAspect(source: portrait))
        XCTAssertEqual(pixelRatio(tool, source: portrait), 1.5, accuracy: 0.005 * 1.5, "按 ⇄ → 3:2")
        print("② 竖框：2:3 → 2:3 → ⇄ 3:2")
    }

    // MARK: - ③ 界面层

    /// The ⇄ button is on the custom-ratio row (「九宫格上方，自定义比例同一行」), and one click flips
    /// the draft's lock without touching the document.
    func testTheSwapButtonIsOnTheCustomRatioRowAndFlipsTheDraft() throws {
        let editor = try CropUITestSupport.makeEditor(in: workDir)
        defer { editor.window?.orderOut(nil) }
        let session = editor.session
        let loupe = editor.rootView.loupeController
        editor.rootView.inspectorWorkspaces.select(.transform)
        CropUITestSupport.pump(0.2)
        let inspector = editor.rootView.inspectorHost
        inspector.layoutSubtreeIfNeeded()

        let tool = try XCTUnwrap(loupe.cropTool, "334: 进变换就要有裁切工具")

        // Land on 3:2 first, so the swap has an unambiguous direction to prove.
        _ = tool.setCustomRatio(3.0 / 2.0)
        CropUITestSupport.pump(0.1)
        inspector.layoutSubtreeIfNeeded()
        XCTAssertEqual(tool.draft.lock.ratio ?? 0, 1.5, accuracy: 1e-6, "起点 3:2")

        // 先把这个子树里**所有** id 打出来。SwiftUI 的 `Button` 不一定是 `NSButton`，找到它的方式有
        // 好几种（host view 的 id、NSAccessibilityElement、或兄弟探针），先看看实际有什么。
        print("③ 树上 id · " + Self.allIdentifiers(in: inspector).sorted().joined(separator: " "))

        let swap = try XCTUnwrap(Self.view(id: CropAspectRow.swapID, in: inspector),
                                 "⇄ 必须在树上（\(CropAspectRow.swapID)）")
        // The row probe keeps its id in `rowID` (it is a `CropRowProbe`, not an accessibility leaf).
        let customRow = try XCTUnwrap(Self.probe(id: CropAspectRow.customProbeID, in: inspector),
                                      "自定义比例那一行的探针")
        // 两条 frame 必须换算到**同一个**坐标空间才有意义：视图各自的 `frame` 是相对父视图的，
        // ⇄ 的父是那一行、探针的父是卡片，直接比 midY 只能证明「两个 0 相等」。
        let swapInCard = swap.convert(swap.bounds, to: inspector)
        let rowInCard = customRow.convert(customRow.bounds, to: inspector)
        print("③ ⇄ 在检查器里 \(swapInCard) 自定义行 \(rowInCard)")
        XCTAssertEqual(swapInCard.midY, rowInCard.midY, accuracy: 2.0, "⇄ 与自定义比例同一行")
        XCTAssertGreaterThan(swapInCard.minX, rowInCard.midX, "⇄ 在自定义字段右边（贴右沿）")
        XCTAssertGreaterThanOrEqual(swapInCard.height, 16, "18 pt 命中尺寸")

        // 点一下：3:2 → 2:3，只动草稿.
        let before = tool.draft.crop
        Self.click(swap)
        CropUITestSupport.pump(0.1)
        inspector.layoutSubtreeIfNeeded()
        XCTAssertEqual(tool.draft.lock.ratio ?? 0, 2.0 / 3.0, accuracy: 1e-6, "点一次 ⇄：3:2 → 2:3")
        XCTAssertNotEqual(tool.draft.crop.keyString, before.keyString, "框跟着重裁")
        XCTAssertEqual(session.edit.geometry.aspectLock, .original, "交换是草稿的事，应用前不碰文档")
        print("③ 点一次 ⇄：lock=\(tool.draft.lock.code) 文档 aspectLock=\(session.edit.geometry.aspectLock.code)")
    }

    /// A real click on whatever the SwiftUI button landed as (an `NSButton` or a plain host view).
    private static func click(_ view: NSView) {
        if let button = view as? NSButton {
            button.performClick(nil)
            return
        }
        guard let window = view.window else { return }
        let point = view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                 timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil,
                                                 eventNumber: 0, clickCount: 1,
                                                 pressure: type == .leftMouseDown ? 1 : 0) else { continue }
            window.sendEvent(event)
        }
    }

    /// Every identifier in the subtree, however SwiftUI spelled it (`ApplyFooter336Tests`'s walk).
    private static func allIdentifiers(in root: NSView) -> Set<String> {
        var out: Set<String> = []
        func walk(_ view: NSView) {
            let id = view.accessibilityIdentifier()
            if !id.isEmpty { out.insert(id) }
            if let raw = view.identifier?.rawValue, !raw.isEmpty { out.insert(raw) }
            for child in view.accessibilityChildren() ?? [] {
                if let v = child as? NSView { walk(v) }
                else if let e = child as? NSAccessibilityElement,
                        let i = e.accessibilityIdentifier(), !i.isEmpty { out.insert(i) }
            }
            for sub in view.subviews { walk(sub) }
        }
        walk(root)
        return out
    }

    /// The row probe by its `rowID` — `CropRowProbe` is a plain `NSView` that records the id itself,
    /// it does not set an accessibility identifier (that is the leaf buttons' job).
    private static func probe(id: String, in root: NSView) -> NSView? {
        if let p = root as? CropRowProbe, p.rowID == id { return p }
        for sub in root.subviews {
            if let hit = probe(id: id, in: sub) { return hit }
        }
        return nil
    }

    /// Walking the id up the view tree — the same technique the neighbouring card tests use.
    ///
    /// A SwiftUI `Button` is **not** one of our `NSButton`s: what carries the identifier is a plain host
    /// view (or an `NSAccessibilityElement` child of one), so both spellings are searched. That is why
    /// the ratio presets are `NSButton`s and this one is not — the presets predate the SwiftUI card.
    private static func view(id: String, in root: NSView) -> NSView? {
        if root.accessibilityIdentifier() == id || root.identifier?.rawValue == id { return root }
        for child in root.accessibilityChildren() ?? [] {
            if let element = child as? NSAccessibilityElement,
               element.accessibilityIdentifier() == id,
               let frame = element.accessibilityFrame() as CGRect? {
                // Give the caller a view whose frame is the element's, so the row assertion can run.
                let host = NSView(frame: root.convert(frame, from: nil))
                host.identifier = NSUserInterfaceItemIdentifier(id)
                return host
            }
        }
        for sub in root.subviews {
            if let hit = view(id: id, in: sub) { return hit }
        }
        return nil
    }
}
