import XCTest
import AppKit
import GRDB
import PhotonsCatalog
@testable import PhotonsUI

/// 423 — 左栏两件事：**不再漏出桌面**，两块面板各有一圈**与右侧检查器同族**的卡片边框。
///
/// 用户原话：「左侧栏修改ui后，还在使用玻璃背景，会导致文件夹和照片侧栏的背景漏光，与其他部分
/// 不漏光的不统一」→「先加分隔就是加卡片边框，边框作为视觉上的分隔」。
///
/// 定位结论（423 派单 §B.2，实测）：`NSScrollView` 里那个铺满的 `NSVisualEffectView` 是
/// `.sourceList` 招来的（AppKit 给源列表装上下方材质），配 `drawsBackground = false` 之后它直接
/// 采样窗口后面的桌面。`matte`（`StudioPanelView`）本身是不透明的、也确实铺满 `view.bounds`。
/// 所以修法是换掉 style，而不是动主题色 —— 下面 `testNoBehindWindowMaterialIsLeftInEitherPane`
/// 就是这条定位的机器版：两个 scroll view 里都不许再出现 `NSVisualEffectView`。
///
/// 卡片边框的四条数字判据（C②/C④/C⑤）都要**画出像素**才有意义：一个空的 `NSView` 也满足
/// 「有这个 view、frame 对」。所以 C④/C⑤ 把 `PaneCardBackground` 离屏渲染成 bitmap，逐点采样。
@MainActor
final class BrowserPaneChrome423Tests: XCTestCase {

    private var tmp: URL!
    private var library: URL!
    private var root: SourceRoot!
    private var session: CatalogSession!
    private var controller: BrowserPaneController!

    private static let panelHeight: CGFloat = 744

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("photons-chrome423-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        library = tmp.appendingPathComponent("c.photonslibrary", isDirectory: true)
        let catalog = try Catalog.create(at: library)
        let shoot = tmp.appendingPathComponent("shoot", isDirectory: true)
        try FileManager.default.createDirectory(at: shoot, withIntermediateDirectories: true)
        root = try catalog.ensureRoot(for: shoot, mode: .reference)
        for (relPath, minute) in [("a.dng", 4), ("day2/b.dng", 3), ("day2/sub/c.dng", 2)] {
            let asset = Asset(sourceRootId: root.id,
                              relPath: relPath,
                              filename: (relPath as NSString).lastPathComponent,
                              ext: "dng", kind: .raw, size: 4096, mtime: 0,
                              contentHash: UUID().uuidString,
                              width: 100, height: 100,
                              captureTime: String(format: "2026-05-01T10:%02d:00Z", minute))
            try catalog.dbQueue.write { db in try asset.insert(db) }
        }
        session = CatalogSession()
        try session.open(library)
        controller = BrowserPaneController(session: session)
        _ = controller.view
        controller.applyLayout(in: CGSize(width: WorkspaceLayout.browserWidthDefault,
                                          height: Self.panelHeight))
    }

    override func tearDownWithError() throws {
        controller = nil
        session = nil
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - B · 透明源

    /// 定位实验的机器版：两个 scroll view 的内容子树里**不许**有 `NSVisualEffectView`。
    ///
    /// `.sourceList` 会插一个铺满 scroll 的 `NSVisualEffectView`（behind-window 材质），
    /// `drawsBackground = false` 时它就是那块漏出桌面的玻璃。换成 `.plain` + 显式 panel 底色后
    /// 它不再出现——这条断言在改前红、改后绿，就是根因的证明。
    ///
    /// ⚠ 必须把面板放进一个（离屏的）窗口再查：AppKit 是在 scroll view 进窗口之后才把那个
    /// `NSVisualEffectView` 装进去的。只在无窗口的视图树上查，`.sourceList` 也会「绿」——
    /// 那就是一条恒真的门（已实测：不进窗口时 §D 的反向门不红）。
    func testNoBehindWindowMaterialIsLeftInEitherPane() {
        let window = hostInWindow(controller.view)
        defer { window.orderOut(nil) }
        let panes = controller.paneCardViews
        for (name, scroll) in [("相册/文件夹", panes.sources.scroll), ("照片列表", panes.photos.scroll)] {
            let effects = descendants(of: scroll).filter { $0 is NSVisualEffectView }
            XCTAssertEqual(effects.count, 0,
                           "「\(name)」的 scroll view 里还有 \(effects.count) 个 NSVisualEffectView"
                           + "（behind-window 材质 = 漏桌面）")
            // `NSScrollPocket` 的滚动边缘效果在两种 style 下都在，它不是那块玻璃；只查
            // `NSVisualEffectView`（behind-window 材质本身就是它）。
            XCTAssertFalse(scroll.drawsBackground, "scroll 自己不填底，底色由表格给")
        }
        print("B· 两个 scroll view 的子树里 NSVisualEffectView = 0（在窗口内查的）")
    }

    /// 表格自己就是那块不透明面：`style == .plain` 且底色 = `StudioTheme.panel`。
    func testBothTablesAreOpaquePanelNotClear() {
        let tree = controller.sourceTreeForTesting
        let list = controller.photoListForTesting
        XCTAssertEqual(tree.style, .plain, "文件夹树不能用 .sourceList")
        XCTAssertEqual(list.style, .plain, "照片列表不能用 .sourceList")
        XCTAssertEqual(coloursMatch(tree.backgroundColor, StudioTheme.panel), true,
                       "文件夹树的底色必须是 StudioTheme.panel，实际 \(tree.backgroundColor)")
        XCTAssertEqual(coloursMatch(list.backgroundColor, StudioTheme.panel), true,
                       "照片列表的底色必须是 StudioTheme.panel，实际 \(list.backgroundColor)")
        // 行高契约仍然成立（`.sourceList` 会改行度量，换成 `.plain` 之后必须再核一次）。
        XCTAssertEqual(tree.rowHeight, WorkspaceLayout.browserTreeRowHeight,
                       "树行高仍是 28")
        XCTAssertEqual(list.rowHeight, WorkspaceLayout.browserRowHeight, "照片行高仍是 46")
        print("B· tree style=\(tree.style.rawValue) rowHeight=\(tree.rowHeight)"
              + " · list style=\(list.style.rawValue) rowHeight=\(list.rowHeight)")
    }

    /// `matte` 铺满、在最底层：这是「底下的不透明面接得住」的前提。
    func testMatteCoversTheWholePaneAndIsTheBottomSibling() {
        let root = controller.view
        guard let matte = root.subviews.first else { return XCTFail("no matte") }
        XCTAssertTrue(matte is StudioPanelView, "第一个子视图是 matte，实际 \(type(of: matte))")
        XCTAssertEqual(matte.frame, root.bounds, "matte 必须铺满 view.bounds")
        XCTAssertTrue(matte.isOpaque, "matte 必须是不透明的")
        // 它必须在两块卡片和两个 scroll view 之下。
        let cards = controller.paneCardViews
        for (name, sub) in [("相册卡片", cards.sources.card as NSView),
                            ("照片卡片", cards.photos.card as NSView),
                            ("相册 scroll", cards.sources.scroll as NSView),
                            ("照片 scroll", cards.photos.scroll as NSView)] {
            let matteIndex = root.subviews.firstIndex(of: matte) ?? -1
            let subIndex = root.subviews.firstIndex(of: sub) ?? -1
            XCTAssertLessThan(matteIndex, subIndex, "matte 必须在「\(name)」之下")
        }
        print("B· matte frame=\(NSStringFromRect(matte.frame)) bounds=\(NSStringFromRect(root.bounds))"
              + " index=\(root.subviews.firstIndex(of: matte) ?? -1)")
    }

    /// 渲染证据：把整块面板离屏画出来，采样两个 scroll view 的可见区中心与靠近边缘的位置，
    /// 这些像素**必须不透明**（alpha 1）且等于 `StudioTheme.panel` —— 也就是「漏不出桌面」。
    func testRenderedPanePixelsAreOpaquePanelEverywhereInBothScrollAreas() throws {
        let root = controller.view
        let rep = try XCTUnwrap(render(root, appearance: .aqua))
        let expectedPanel = resolved(PaneCardStyle.fill, appearance: .aqua)
        let scale = CGFloat(rep.pixelsWide) / max(1, rep.size.width)
        let panes = controller.paneCardViews
        var samples: [String] = []
        for (name, scroll) in [("相册/文件夹", panes.sources.scroll), ("照片列表", panes.photos.scroll)] {
            // 采样 scroll 内的 5 个点：四角内缩 6 pt + 中心。
            let r = scroll.frame
            let points: [(String, CGPoint)] = [
                ("左上", CGPoint(x: r.minX + 6, y: r.minY + 6)),
                ("右上", CGPoint(x: r.maxX - 6, y: r.minY + 6)),
                ("左下", CGPoint(x: r.minX + 6, y: r.maxY - 6)),
                ("右下", CGPoint(x: r.maxX - 6, y: r.maxY - 6)),
                ("中心", CGPoint(x: r.midX, y: r.midY)),
            ]
            for (where_, point) in points {
                let x = Int((point.x * scale).rounded())
                // 视图是 flipped 的，bitmap 的行 0 在上：换算成“自顶向下”。
                let y = Int((point.y * scale).rounded())
                let colour = try XCTUnwrap(rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                                           "「\(name)」\(where_) 采不到像素")
                XCTAssertEqual(colour.alphaComponent, 1.0, accuracy: 0.001,
                               "「\(name)」\(where_) alpha=\(colour.alphaComponent) —— 这一块在透光")
                XCTAssertEqual(coloursMatch(colour, expectedPanel), true,
                               "「\(name)」\(where_) 不是 StudioTheme.panel：\(describe(colour))")
                samples.append("\(name)\(where_)=\(describe(colour))")
            }
        }
        print("B· 渲染采样：" + samples.joined(separator: " · "))
    }

    // MARK: - C① 每块面板一个卡片，且在其 scroll 之下

    func testEachPaneHasExactlyOneCardBelowItsScroll() throws {
        let root = controller.view
        let panes = controller.paneCardViews
        // 两张卡片是**两个不同**的对象（不是同一个 view 被挂两次）。
        XCTAssertFalse(panes.sources.card === panes.photos.card, "两块面板的卡片必须是两个实例")
        XCTAssertEqual(root.subviews.filter { String(describing: type(of: $0)) == "PaneCardBackground" }.count,
                       2, "整块面板上正好两块卡片")
        for (name, card, scroll) in [("相册/文件夹", panes.sources.card, panes.sources.scroll),
                                     ("照片列表", panes.photos.card, panes.photos.scroll)] {
            XCTAssertEqual(root.subviews.filter { $0 === card }.count, 1,
                           "「\(name)」在本块面板上出现且只出现一次")
            let cardIndex = try XCTUnwrap(root.subviews.firstIndex(of: card), "「\(name)」卡片不在视图树里")
            let scrollIndex = try XCTUnwrap(root.subviews.firstIndex(of: scroll), "「\(name)」scroll 不在视图树里")
            XCTAssertLessThan(cardIndex, scrollIndex, "「\(name)」的卡片必须在 scroll 之下")
        }
    }

    // MARK: - C② 四个样式数与检查器一致

    /// 四个数：圆角 4、线宽 0.5、描边 alpha 0.7、底色 = `StudioTheme.panel`。
    /// 「不许抄字面量到两个地方」—— 这里拿右侧检查器的**源码**当参照物，逐个数字比对，
    /// 任何一边单独改了都会红。
    func testCardStyleNumbersMatchTheInspectorCardShell() throws {
        XCTAssertEqual(PaneCardStyle.cornerRadius, 4)
        XCTAssertEqual(PaneCardStyle.strokeWidth, 0.5)
        XCTAssertEqual(PaneCardStyle.strokeAlpha, 0.7)
        XCTAssertEqual(coloursMatch(PaneCardStyle.fill, StudioTheme.panel), true)
        XCTAssertEqual(coloursMatch(PaneCardStyle.stroke, StudioTheme.separator), true)
        XCTAssertEqual(PaneCardStyle.contentInset, 1, "scroll 相对卡片内缩 1 pt")

        // 检查器那边的三行（SwiftUI）：`.clipShape(RoundedRectangle(cornerRadius: 4))`、
        // `.strokeBorder(…opacity(0.7), lineWidth: 0.5)`、`.background(Color(nsColor: StudioTheme.panel))`。
        let source = try String(contentsOf: Self.inspectorSource, encoding: .utf8)
        XCTAssertTrue(source.contains(".clipShape(RoundedRectangle(cornerRadius: 4))"),
                      "检查器的圆角不再是 4 —— 左栏卡片必须跟着改")
        XCTAssertTrue(source.contains("lineWidth: 0.5)"), "检查器的描边不再是 0.5 pt")
        XCTAssertTrue(source.contains(".opacity(0.7)"), "检查器的描边 alpha 不再是 0.7")
        XCTAssertTrue(source.contains(".background(Color(nsColor: StudioTheme.panel))"),
                      "检查器的卡身底色不再是 StudioTheme.panel")
        print("C② 圆角=\(PaneCardStyle.cornerRadius) 线宽=\(PaneCardStyle.strokeWidth)"
              + " alpha=\(PaneCardStyle.strokeAlpha) fill=panel stroke=separator 内缩=\(PaneCardStyle.contentInset)")
    }

    private static var inspectorSource: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/PhotonsUI/InspectorView.swift")
    }

    // MARK: - C③ frame 只差 1 pt 内缩

    func testCardFramesAreExactlyOnePointLargerThanTheirScrolls() {
        for height in [CGFloat(744), 900, 1200] {
            controller.applyLayout(in: CGSize(width: WorkspaceLayout.browserWidthDefault, height: height))
            let panes = controller.paneCardViews
            for (name, card, scroll) in [("相册/文件夹", panes.sources.card, panes.sources.scroll),
                                         ("照片列表", panes.photos.card, panes.photos.scroll)] {
                let expected = scroll.frame.insetBy(dx: -PaneCardStyle.contentInset,
                                                    dy: -PaneCardStyle.contentInset)
                XCTAssertEqual(card.frame, expected,
                               "「\(name)」面板 \(height) pt 时卡片与 scroll 的差不是 1 pt 内缩："
                               + "card=\(NSStringFromRect(card.frame)) scroll=\(NSStringFromRect(scroll.frame))")
            }
            print("C③ panel \(height): card=\(NSStringFromRect(panes.sources.card.frame))"
                  + " scroll=\(NSStringFromRect(panes.sources.scroll.frame))")
        }
    }

    // MARK: - C④ / C⑤ 边框与圆角真的画出来了（bitmap 采样）

    /// 卡片的离屏渲染：四边中点的像素必须是 `separator` @ 0.7 叠在 panel 上，中心必须是 panel。
    ///
    /// 容差 0.01/通道是刻意的：`cacheDisplay` 出来的 bitmap 走一次色彩空间往返，纯色也会差 1–2/255
    /// （下面实测 0.119 vs 理论 0.114、0.167 vs 0.170）。这条门仍有判别力 —— 描边与卡身相差
    /// ≈ 0.048/通道，是容差的近 5 倍；⑧c（不画描边）时边缘像素就是卡身色，必红（见 `test…`
    /// 旁边那条「描边必须与卡身可区分」的断言，它不依赖理论值）。
    func testBitmapShowsAStrokeOnAllFourEdgesAndPanelInTheCentre() throws {
        var lines: [String] = []
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            lines.append(try strokeEvidence(appearance: appearance))
        }
        print("C④ " + lines.joined(separator: " ‖ "))
    }

    /// 一个外观下的四边描边证据。浅色/深色各跑一次：`StudioTheme` 是动态色，只有两边都画对，
    /// 「与右侧检查器同一族」在用户的两种外观下才都成立。
    private func strokeEvidence(appearance: NSAppearance.Name) throws -> String {
        let card = makePaneCardForTesting(frame: NSRect(x: 0, y: 0, width: 120, height: 90))
        let rep = try XCTUnwrap(render(card, appearance: appearance))
        let scale = CGFloat(rep.pixelsWide) / max(1, rep.size.width)
        let w = rep.pixelsWide, h = rep.pixelsHigh
        let fill = resolved(PaneCardStyle.fill, appearance: appearance)
        let expectedStroke = blended(resolved(PaneCardStyle.stroke, appearance: appearance),
                                     alpha: PaneCardStyle.strokeAlpha, over: fill)

        let midX = w / 2, midY = h / 2
        // 0.5 pt `strokeBorder` 从边向内画，2× 下就是第 0 个像素；四边中点各采一次。
        var edges: [(String, NSColor)] = []
        for (name, x, y) in [("左边中点", 0, midY), ("右边中点", w - 1, midY),
                             ("上边中点", midX, 0), ("下边中点", midX, h - 1)] {
            let colour = try XCTUnwrap(rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                                       "\(appearance.rawValue) \(name) 采不到像素")
            edges.append((name, colour))
        }
        let centre = try XCTUnwrap(rep.colorAt(x: midX, y: midY)?.usingColorSpace(.sRGB))
        var samples: [String] = []

        for (name, colour) in edges {
            XCTAssertEqual(colour.alphaComponent, 1.0, accuracy: 0.01, "\(name) 必须不透明")
            XCTAssertTrue(coloursMatch(colour, expectedStroke, tolerance: 0.01),
                          "\(appearance.rawValue) \(name) 不是描边色：实际 \(describe(colour))"
                          + " 期望 \(describe(expectedStroke))（\(w)×\(h) @\(scale)x）")
            // 与卡身必须可区分 —— 这条不依赖理论色值，⑧c 会先在这里红。
            XCTAssertGreaterThan(abs(colour.redComponent - centre.redComponent), 0.02,
                                 "\(appearance.rawValue) \(name) 与卡身同色 ⇒ 描边没画出来（\(describe(colour))）")
            samples.append("\(name)=\(describe(colour))")
        }

        XCTAssertTrue(coloursMatch(centre, fill, tolerance: 0.01),
                      "\(appearance.rawValue) 中心不是 panel：\(describe(centre)) 期望 \(describe(fill))")
        samples.append("中心=\(describe(centre))")
        return "\(appearance.rawValue) \(w)×\(h)@\(scale)x " + samples.joined(separator: " ")
            + " 期望描边=\(describe(expectedStroke)) 期望卡身=\(describe(fill))"
    }

    /// 圆角生效：左上角 1×1 px 不等于卡身色（被圆角裁掉），而距边 4 pt 处已是卡身色。
    func testBitmapCornersAreRounded() throws {
        let card = makePaneCardForTesting(frame: NSRect(x: 0, y: 0, width: 120, height: 90))
        let rep = try XCTUnwrap(render(card, appearance: .darkAqua))
        let scale = CGFloat(rep.pixelsWide) / max(1, rep.size.width)
        let w = rep.pixelsWide, h = rep.pixelsHigh
        let fill = resolved(PaneCardStyle.fill, appearance: .darkAqua)

        // bitmap 的行 0 是**视图顶部**（cacheDisplay 的坐标），所以左上角 = (0, 0)。
        let corner = try XCTUnwrap(rep.colorAt(x: 0, y: 0)?.usingColorSpace(.sRGB))
        XCTAssertFalse(coloursMatch(corner, fill),
                       "左上角 1×1 px 不该是卡身色 —— 圆角没生效（\(describe(corner))）")

        // 沿对角线走进去：距边 4 pt（2× 下 8 px）处已经是卡身色（4 pt 圆角的对角线上，
        // 圆心在 (4,4)、半径 4 ⇒ 对角线进入卡身的位置约 4 - 4/√2 ≈ 1.17 pt）。
        let inset = Int((4 * scale).rounded())
        let inside = try XCTUnwrap(rep.colorAt(x: inset, y: inset)?.usingColorSpace(.sRGB))
        XCTAssertEqual(coloursMatch(inside, fill), true,
                       "距边 4 pt 处应是卡身色，实际 \(describe(inside))")

        // 四角都不是卡身色（四个角都被裁）。
        for (name, x, y) in [("左上", 0, 0), ("右上", w - 1, 0), ("左下", 0, h - 1), ("右下", w - 1, h - 1)] {
            let c = try XCTUnwrap(rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
            XCTAssertFalse(coloursMatch(c, fill), "\(name)角应是圆角裁掉的透明")
        }
        print("C⑤ 角(0,0)=\(describe(corner)) · 距边4pt=\(describe(inside)) · 整块 \(w)×\(h) @\(scale)x")
    }

    // MARK: - C⑥ 高度逐位不变

    /// 用户明说「不改高度了」：两块面板的高度必须**逐位**等于改前的值。
    ///
    /// 两套断言，同一件事：
    /// ① 公式 —— 树高仍由 `WorkspaceLayout.browserTreeHeight(rowCount:panelHeight:)` 决定，
    ///    照片列表高仍是「剩下的高度」；
    /// ② 字面量 —— 下面这三个数是在**基（main@ca7a0d2，`git stash` 掉本次改动后）**同一个 fixture 上
    ///    实测的（`tree=180 / photos=476` @744、`180 / 632` @900、`180 / 932` @1200、rows=3）。
    ///    只要有人往 `layoutPanes()` 里塞一个手动树高或一个持久值，② 就红。
    func testPaneHeightsAreStillTheContractHeights() {
        // fixture 有三个文件夹行（`a.dng`、`day2`、`day2/sub`）。
        XCTAssertEqual(controller.folderTreeRowCount, 3, "fixture 的行数变了，下面的字面量就要重测")
        let baseline: [CGFloat: (tree: CGFloat, photos: CGFloat)] = [
            744: (180, 476), 900: (180, 632), 1200: (180, 932),
        ]
        for (height, expected) in baseline.sorted(by: { $0.key < $1.key }) {
            let frames = controller.applyLayout(in: CGSize(width: WorkspaceLayout.browserWidthDefault,
                                                           height: height))
            // ① 公式
            let formulaTree = WorkspaceLayout.browserTreeHeight(rowCount: controller.folderTreeRowCount,
                                                                panelHeight: height)
            XCTAssertEqual(frames.tree.height, formulaTree, accuracy: 0.001,
                           "panel \(height): 树高不再由契约决定")
            let formulaPhotos = max(WorkspaceLayout.browserPhotoListMinHeight,
                                    height - (WorkspaceLayout.browserHeaderHeight + formulaTree
                                              + WorkspaceLayout.browserPaneGap)
                                        - WorkspaceLayout.browserFooterHeight)
            XCTAssertEqual(frames.photos.height, formulaPhotos, accuracy: 0.001,
                           "panel \(height): 照片列表高不再由契约决定")
            // ② 改前实测值
            XCTAssertEqual(frames.tree.height, expected.tree, accuracy: 0.001,
                           "panel \(height): 树高与改前不一致")
            XCTAssertEqual(frames.photos.height, expected.photos, accuracy: 0.001,
                           "panel \(height): 照片列表高与改前不一致")
            // 三个对外读数（CenterOnEdit / SingleClick / DoubleClickGuard 读的就是它们）。
            XCTAssertEqual(controller.folderTreeHeight, expected.tree, accuracy: 0.001)
            XCTAssertEqual(controller.photoListHeight, expected.photos, accuracy: 0.001)
            print("C⑥ panel \(height): tree=\(frames.tree.height) photos=\(frames.photos.height)"
                  + " (改前 \(expected.tree)/\(expected.photos))")
        }
    }

    // MARK: - C⑧ 外观切换重绘

    func testCardRedrawsOnAppearanceChange() {
        let card = makePaneCardForTesting(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 40, height: 40),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = card
        card.layoutSubtreeIfNeeded()
        card.needsDisplay = false
        card.viewDidChangeEffectiveAppearance()
        XCTAssertTrue(card.needsDisplay, "切外观后卡片必须重绘")
        // 两个外观都要重绘：浅色与深色各切一次。
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            card.appearance = NSAppearance(named: appearance)
            card.needsDisplay = false
            card.viewDidChangeEffectiveAppearance()
            XCTAssertTrue(card.needsDisplay, "\(appearance.rawValue) 下切外观没有重绘")
        }
        window.contentView = nil
    }

    // MARK: - helpers

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.reduce(into: view.subviews) { $0 += descendants(of: $1) }
    }

    /// 把一块视图挂进一个离屏窗口（`orderOut` 之前，AppKit 会走完“进窗口”的那条安装路径）。
    private func hostInWindow(_ content: NSView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: max(240, content.frame.width),
                                                  height: max(240, content.frame.height)),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = content
        content.layoutSubtreeIfNeeded()
        return window
    }

    private func describe(_ colour: NSColor) -> String {
        let c = colour.usingColorSpace(.sRGB) ?? colour
        return String(format: "%.3f,%.3f,%.3f,%.3f",
                      c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent)
    }

    /// 描边色按 alpha 叠在卡身色上的结果（本视图离屏渲染到底色透明的 bitmap 上，
    /// `stroke` 的 alpha 会与 `fill` 复合，所以期望值要按 over 算）。
    private func blended(_ stroke: NSColor, alpha: CGFloat, over fill: NSColor) -> NSColor {
        let f = fill.usingColorSpace(.sRGB) ?? fill
        let s = (stroke.usingColorSpace(.sRGB) ?? stroke).withAlphaComponent(alpha)
        let a = s.alphaComponent + f.alphaComponent * (1 - s.alphaComponent)
        guard a > 0 else { return .clear }
        func mix(_ sc: CGFloat, _ fc: CGFloat) -> CGFloat {
            (sc * s.alphaComponent + fc * f.alphaComponent * (1 - s.alphaComponent)) / a
        }
        return NSColor(srgbRed: mix(s.redComponent, f.redComponent),
                       green: mix(s.greenComponent, f.greenComponent),
                       blue: mix(s.blueComponent, f.blueComponent),
                       alpha: a)
    }

    /// 把一个动态 `StudioTheme` 色在给定外观下**解析**成固定 sRGB。
    ///
    /// `StudioTheme` 的四个色都是 `NSColor(name:dynamicProvider:)`。拿它直接与 bitmap 里的像素比
    /// 会拿“当前 App 外观”解析，而渲染是在 `performAsCurrentDrawingAppearance` 里做的 —— 两个外观
    /// 不一致时，即便像素完全正确也会红（或者更糟：正确的东西看着红、错的东西看着绿）。
    private func resolved(_ colour: NSColor, appearance: NSAppearance.Name) -> NSColor {
        var out = colour
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            out = colour.usingColorSpace(.sRGB) ?? colour
        }
        return out
    }

    private func coloursMatch(_ a: NSColor?, _ b: NSColor?, tolerance: CGFloat = 0.004) -> Bool {
        guard let a, let b else { return false }
        guard let lhs = a.usingColorSpace(.sRGB), let rhs = b.usingColorSpace(.sRGB) else {
            return a == b
        }
        return abs(lhs.redComponent - rhs.redComponent) < tolerance
            && abs(lhs.greenComponent - rhs.greenComponent) < tolerance
            && abs(lhs.blueComponent - rhs.blueComponent) < tolerance
            && abs(lhs.alphaComponent - rhs.alphaComponent) < tolerance
    }

    /// 一个真实 `draw` 到 bitmap 的渲染（不需要窗口）。
    private func render(_ view: NSView, appearance: NSAppearance.Name) -> NSBitmapImageRep? {
        guard let resolution = NSAppearance(named: appearance) else { return nil }
        view.appearance = resolution
        view.layoutSubtreeIfNeeded()
        var rep: NSBitmapImageRep?
        resolution.performAsCurrentDrawingAppearance {
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            rep = bitmap
        }
        return rep
    }
}
