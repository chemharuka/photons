import XCTest
import AppKit
import SwiftUI
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 334 — **变换工作区改成三张卡：裁切（只有比例）/ 校正（拉直 + 透视 + 画线拉直）/ 变换（转向 + 镜像）。**
///
/// 用户的原话（2026-11-10）：
///
///   > 画线拉直的UI在哪？做到变换窗口中，另外变换窗口的卡片要重新改：透视从裁切中拿出来，现在有三个
///   > 卡片：裁切，校正，变换。裁切只含宽高比，常见比例的按钮(1:1 4:3 16:9 2:3)都放出来，不要做成
///   > 点击切换的模式。此外需要一个自定义比例的输入框。校正包括旋转、透视、以及新做的引导线UI，变换
///   > 包括旋转和镜像。旋转旁边的画线确定水平面功能，UI LOGO要改一下，看下有没有水平仪的LOGO，用来
///   > 和引导线UI区分开。
///
/// 这份文件钉的是**分家**本身，每一条都对着宿主在真窗口里、排过版的那张面板：
///
///   ① 三张卡，标题与顺序 == 裁切 / 校正 / 变换；
///   ② 裁切卡的 id 集合只有比例 + 自定义 + 不出像素 + 九宫格 + 应用/取消（没有 angle.* / perspective.*）；
///   ③ 校正卡四行 == 拉直 / 画线拉直 / 垂直透视 / 水平透视，画线拉直的图标是水平仪 `level`；
///   ④ 变换卡两行 == 旋转 / 镜像，左转一次 `quarterTurns` ±1；
///   ⑤ 反向断言：裁切卡里 perspective 行 0；校正卡里 aspect 行 0；
///   ⑥ 两条反向门：`.perspective` 塞回裁切卡 → 结构守卫红；画线按钮改 `line.diagonal` → ③ 红。
@MainActor
final class TransformCards334Tests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-334-cards-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    // MARK: - ① 三张卡

    func testTheWorkspaceDrawsThreeCardsCropThenCorrectionThenTransform() throws {
        let (panel, loupe) = try transformPanel(width: 330)
        defer { panel.window.contentView = nil }
        XCTAssertTrue(loupe.isCropToolActive || loupe.beginCropTool(), "334: 进变换就该在裁切模式")

        print("334 ① · cards \(panel.cards.cardTitles) · ids \(panel.cards.cardIDs)")
        // The declaration, the panel's own readback, and the three card frames all agree.
        XCTAssertEqual(TransformCardSpec.all.map(\.title), ["裁切", "校正", "变换"])
        XCTAssertEqual(InspectorView.cardTitles(in: .transform), ["裁切", "校正", "变换"])
        XCTAssertEqual(panel.cards.cardTitles, ["裁切", "校正", "变换"])

        let crop = try XCTUnwrap(panel.row(CropCardID.card))
        let correction = try XCTUnwrap(panel.row(CropCardID.correctionCard))
        let rotation = try XCTUnwrap(panel.row(CropCardID.angleCard))
        XCTAssertGreaterThan(correction.minY, crop.maxY)
        XCTAssertGreaterThan(rotation.minY, correction.maxY)
        print(String(format: "334 ① · 裁切 %@ · 校正 %@ · 变换 %@",
                     NSStringFromRect(crop), NSStringFromRect(correction), NSStringFromRect(rotation)))
    }

    // MARK: - ② 裁切卡只有比例（+ 不出像素 · 九宫格 · 应用/取消）

    /// The card's controls come in two halves, because SwiftUI's `.accessibilityIdentifier` does not
    /// reach `NSView.accessibilityIdentifier()` under `swift test` (measured: the AX tree of a hosted,
    /// window-less panel is empty):
    ///
    ///   · **AppKit leaves** — ratio buttons, 原始/自由, the typed field, 不出像素: found by id *and*
    ///     their frame is inside the crop card;
    ///   · **SwiftUI chips / buttons** — 九宫格, 取消, 应用: found by the row probe they are drawn in,
    ///     which is inside the crop card too.
    func testTheCropCardHoldsOnlyTheRatiosTheCheckboxTheGridAndApplyCancel() throws {
        let (panel, loupe) = try transformPanel(width: 330)
        defer { panel.window.contentView = nil }
        XCTAssertTrue(loupe.isCropToolActive || loupe.beginCropTool())

        let card = try XCTUnwrap(panel.row(CropCardID.card))
        let leaves = Set(panel.identifiers(inside: card))
        print("334 ② · 裁切卡 AppKit 叶子 id 集合 \(leaves.sorted())")

        // ── 四个比例 + 原始 / 自由 + 自定义字段 + 不出像素 ──────────────────────────────
        let required: Set<String> = [
            "inspector.crop.ratio.1x1",
            "inspector.crop.ratio.4x3",
            "inspector.crop.ratio.16x9",
            "inspector.crop.ratio.2x3",
            "inspector.crop.ratio.original",
            "inspector.crop.ratio.free",
            "inspector.crop.ratio.custom",
            "inspector.crop.staysInsidePixels",
        ]
        XCTAssertEqual(leaves, required,
                       "334: 裁切卡的 AppKit 叶子应正好是这八个（多 \(leaves.subtracting(required).sorted())"
                       + " · 少 \(required.subtracting(leaves).sorted())）")

        // ── 九宫格 · 取消 · 应用：三个 SwiftUI 叶子，按它们所在的行认 ──────────────────
        let rows = Set(panel.probes.filter {
            $0.rowID != CropCardID.card
        }.filter {
            card.insetBy(dx: -1, dy: -1).contains(CGPoint(x: $0.convert($0.bounds, to: panel.host).midX,
                                                          y: $0.convert($0.bounds, to: panel.host).midY))
        }.map(\.rowID))
        print("334 ② · 裁切卡行 \(rows.sorted())")
        let expectedRows: Set<String> = [CropCardID.section(.crop),
                                         CropAspectRow.probeID, CropAspectRow.extrasProbeID,
                                         CropAspectRow.customProbeID, CropCardID.staysInsidePixels,
                                         CropCardID.grid, CropCardID.apply]
        XCTAssertEqual(rows, expectedRows,
                       "334: 裁切卡的行应正好是 \(expectedRows)（多 \(rows.subtracting(expectedRows).sorted())"
                       + " · 少 \(expectedRows.subtracting(rows).sorted())）")
        // 那两个 SwiftUI 叶子用的就是 086/317 的 id（沿用，不新造）.
        XCTAssertEqual(CropChip.titleID("九宫格"), "inspector.crop.chip.九宫格")
        XCTAssertEqual(CropApplyRow.applyID, "inspector.crop.apply")
        XCTAssertEqual(CropApplyRow.cancelID, "inspector.crop.cancel")

        // ── 反向：裁切卡里没有 角度 / 透视 的任何控件 ────────────────────────────────
        XCTAssertEqual(leaves.filter { $0.contains("angle") || $0.contains("perspective") }, [])
        XCTAssertEqual(rows.filter {
            $0.hasPrefix("angle") || $0.hasPrefix("perspective")
        }, [], "334: 裁切卡里不许有角度/透视行")
        // ⑦a 反向断言：裁切卡里 perspective 行 0 条.
        let perspectiveRows = panel.probes.filter {
            $0.rowID.hasPrefix(CorrectionCardRow.perspectiveVertical.probeID)
                || $0.rowID.hasPrefix(CorrectionCardRow.perspectiveHorizontal.probeID)
        }.filter { card.contains($0.convert($0.bounds, to: panel.host).origin) }
        XCTAssertEqual(perspectiveRows.count, 0,
                       "334: 裁切卡里透视行必须是 0 条（实际 \(perspectiveRows.map(\.rowID))）")

        // ── 用户补充：应用/取消在最底下 ────────────────────────────────────────────
        let apply = try XCTUnwrap(panel.row(CropCardID.apply))
        let grid = try XCTUnwrap(panel.row(CropCardID.grid))
        let stays = try XCTUnwrap(panel.row(CropCardID.staysInsidePixels))
        let lowestOther = panel.probes
            .filter { $0.rowID != CropCardID.apply && $0.rowID != CropCardID.card }
            .map { $0.convert($0.bounds, to: panel.host) }
            .filter { card.contains($0.origin) }
            .map(\.maxY).max() ?? 0
        print(String(format: "334 ② · stays minY %.1f · grid minY %.1f · apply minY %.1f（卡内最大）· card maxY %.1f",
                     stays.minY, grid.minY, apply.minY, card.maxY))
        XCTAssertGreaterThan(apply.minY, stays.minY)
        XCTAssertGreaterThan(apply.minY, grid.minY)
        XCTAssertLessThanOrEqual(lowestOther, apply.maxY + 1,
                                 "334: 应用/取消必须是最底一行（其它内容最低 \(lowestOther)）")
    }

    // MARK: - ③ 校正卡：四行 + 水平仪图标

    func testTheCorrectionCardHasTheFourRowsAndTheLevelGlyph() throws {
        let (panel, loupe) = try transformPanel(width: 330)
        defer { panel.window.contentView = nil }
        XCTAssertTrue(loupe.isCropToolActive || loupe.beginCropTool(), "334: 进变换就该在裁切模式")

        XCTAssertEqual(CorrectionCardRow.allCases.map(\.title),
                       ["拉直", "画线拉直", "垂直透视", "水平透视"])
        let correction = try XCTUnwrap(panel.row(CropCardID.correctionCard))
        var rows: [(String, CGRect)] = []
        for row in CorrectionCardRow.allCases {
            let rect = try XCTUnwrap(panel.row(row.probeID), "334: 行「\(row.title)」没有画出来")
            rows.append((row.title, rect))
            XCTAssertTrue(correction.contains(rect.origin) || correction.contains(CGPoint(x: rect.midX, y: rect.midY)),
                          "334: 行「\(row.title)」不在校正卡里（\(NSStringFromRect(rect)) / \(NSStringFromRect(correction))）")
        }
        for (a, b) in zip(rows, rows.dropFirst()) {
            XCTAssertGreaterThan(b.1.minY, a.1.minY, "334: 「\(b.0)」必须在「\(a.0)」下面")
        }
        print("334 ③ · 校正行 " + rows.map {
            String(format: "%@ (y %.1f, h %.1f)", $0.0, $0.1.minY, $0.1.height)
        }.joined(separator: " · "))

        // 图标 = 水平仪（用户：看下有没有水平仪的LOGO，用来和引导线UI区分开）.
        let button = try XCTUnwrap(panel.view(DrawStraightenButton.self,
                                              identifier: DrawStraightenButton.identifierID),
                                   "334: 画线拉直按钮不在树上")
        XCTAssertNotNil(NSImage(systemSymbolName: "level", accessibilityDescription: nil),
                        "334: 本机必须有 level 这个符号")
        XCTAssertEqual(button.symbolName, "level", "334: 画线拉直必须用水平仪图标")
        XCTAssertEqual(button.accessibilityLabel(), "画线拉直")
        XCTAssertNotEqual(CropAspectRow.customSymbol, button.symbolName,
                          "334: 自定义比例与画线拉直不许共用一个符号")

        // ⑦b 反向断言：校正卡里 aspect 行 0 条.
        XCTAssertNil(panel.row(CropAspectRow.probeID).flatMap { correction.contains($0) ? $0 : nil },
                     "334: 校正卡里不许有宽高比那一行")
        print("334 ③ · icon \(button.symbolName) · label \(button.accessibilityLabel() ?? "-")")
    }

    // MARK: - ④ 变换卡：旋转 / 镜像 + 左转一次 ±1

    func testTheTransformCardHasRotationAndMirrorAndOneTurnMovesQuarterTurns() throws {
        let (panel, loupe) = try transformPanel(width: 330)
        defer { panel.window.contentView = nil }
        XCTAssertTrue(loupe.isCropToolActive || loupe.beginCropTool(), "334: 进变换就该在裁切模式")

        let rotation = try XCTUnwrap(panel.row(CropCardID.angleCard))
        let turnRow = try XCTUnwrap(panel.row(CropCardID.turn))
        let mirrorRow = try XCTUnwrap(panel.row(CropCardID.mirror))
        XCTAssertTrue(rotation.contains(turnRow.origin) || rotation.contains(CGPoint(x: turnRow.midX, y: turnRow.midY)))
        XCTAssertGreaterThan(mirrorRow.minY, turnRow.maxY)
        print("334 ④ · 变换卡行 \(["旋转", "镜像"]) · turn y \(turnRow.minY) · mirror y \(mirrorRow.minY)")

        let before = loupe.cropTool.quarterTurns
        let ccw = try XCTUnwrap(panel.view(TurnButton.self, identifier: CropTurnRow.counterClockwiseID),
                                "334: 左转按钮不在树上")
        ccw.performClick(nil)
        _ = try waitFor { loupe.cropTool.quarterTurns != before }
        let after = loupe.cropTool.quarterTurns
        print("334 ④ · 左转一次 quarterTurns \(before) → \(after)")
        XCTAssertEqual(GeometryGroup.normalizedQuarterTurns(after - before), 3,
                       "334: 左转 = −1（mod 4）：\(before) → \(after)")
    }

    // MARK: - ⑥ 反向门 ①：把 .perspective 塞回裁切卡 → 结构守卫红

    func testTheStructureGuardGoesRedWhenPerspectiveGoesBackIntoTheCropCard() throws {
        let broken = [
            TransformCardSpec(title: InspectorView.Section.crop.title, sections: [.crop, .perspective]),
            TransformCardSpec.correctionCard,
            TransformCardSpec.rotationCard,
        ]
        let issues = TransformCardSpec.issues(in: broken)
        print("334 ⑥ 反证 · issues(in:) = \(issues)")
        XCTAssertFalse(issues.isEmpty, "反向门：透视回到裁切卡必须被结构守卫拦下")
        XCTAssertTrue(issues.contains { $0.contains("perspectiveVertical") || $0.contains("perspectiveHorizontal") },
                      "反向门：守卫要点名透视频段被两张卡同时声明：\(issues)")
        // 正向：真实声明必须干净（这条才是绿的）.
        XCTAssertEqual(TransformCardSpec.issues(in: TransformCardSpec.all), [])
    }

    // MARK: - ⑥ 反向门 ②：画线按钮改 line.diagonal → ③ 的图标断言红

    func testTheGlyphAssertionGoesRedWhenTheDrawStraightenUsesALine() throws {
        _ = NSApplication.shared
        // Host the switch with the *wrong* glyph and read it back the way ③ does.
        let host = NSHostingView(rootView: CropDrawStraightenToggle(on: false, enabled: true,
                                                                    action: {}, symbol: "line.diagonal"))
        host.frame = NSRect(x: 0, y: 0, width: 120, height: 40)
        let window = TestWindows.make(contentRect: host.frame, styleMask: [.borderless],
                                      backing: .buffered, defer: false)
        window.contentView = host
        defer { window.orderOut(nil); window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))

        let button = try XCTUnwrap(Self.first(DrawStraightenButton.self, in: host),
                                   "334: 按钮没画出来")
        print("334 ⑥ 反证 · drawn glyph \(button.symbolName) · ③ 的断言 == level → \(button.symbolName == "level")")
        XCTAssertEqual(button.symbolName, "line.diagonal", "反向门：注入的符号必须被画出来")
        XCTAssertNotEqual(button.symbolName, "level",
                          "反向门：改成 line.diagonal 之后 ③ 的 `== level` 必须红（这一条证明它能红）")
    }

    // MARK: - harness

    private struct Panel {
        let host: NSHostingView<InspectorView>
        let window: NSWindow
        let state: InspectorWorkspaceState

        var cards: InspectorCardsProbe {
            views(ofType: InspectorCardsProbe.self).first ?? InspectorCardsProbe(frame: .zero)
        }

        var probes: [CropRowProbe] { views(ofType: CropRowProbe.self) }

        func row(_ id: String) -> CGRect? {
            probes.first { $0.rowID == id }.map { $0.convert($0.bounds, to: host) }
        }

        func view<T: NSView>(_ type: T.Type, identifier: String) -> T? {
            views(ofType: type).first { $0.accessibilityIdentifier() == identifier }
        }

        func views<T: NSView>(ofType: T.Type) -> [T] {
            var found: [T] = []
            func walk(_ root: NSView) {
                if let match = root as? T { found.append(match) }
                for sub in root.subviews { walk(sub) }
            }
            walk(host)
            return found
        }

        /// Every accessibility identifier a view **inside `rect`** reports — the card's own control set.
        ///
        /// SwiftUI-drawn leaves (the 九宫格 chip, 应用 / 取消) carry their identifier in the
        /// accessibility tree rather than on an `NSView`, so the walk unions the view tree with the AX
        /// tree; only the view-tree half can be scoped by frame, which is why the caller also checks
        /// each control's row probe lies inside the card.
        func identifiers(inside rect: CGRect) -> [String] {
            var out: Set<String> = []
            func walk(_ root: NSView) {
                let frame = root.convert(root.bounds, to: host)
                let id = root.accessibilityIdentifier()
                if !id.isEmpty, rect.insetBy(dx: -1, dy: -1).contains(CGPoint(x: frame.midX, y: frame.midY)) {
                    out.insert(id)
                }
                for sub in root.subviews { walk(sub) }
            }
            walk(host)
            out.formUnion(axIdentifiers())
            return out.sorted()
        }

        /// Every identifier the accessibility tree reports (SwiftUI's own leaves included).
        func axIdentifiers() -> Set<String> {
            var out: Set<String> = []
            func walk(_ node: Any, depth: Int) {
                guard depth < 30 else { return }
                if let view = node as? NSView {
                    let id = view.accessibilityIdentifier()
                    if !id.isEmpty { out.insert(id) }
                    for child in view.accessibilityChildren() ?? [] { walk(child, depth: depth + 1) }
                } else if let element = node as? NSAccessibilityElement {
                    if let id = element.accessibilityIdentifier(), !id.isEmpty { out.insert(id) }
                    for child in element.accessibilityChildren() ?? [] { walk(child, depth: depth + 1) }
                }
            }
            walk(host, depth: 0)
            return out
        }
    }

    private func transformPanel(width: CGFloat) throws -> (Panel, LoupeController) {
        let (session, _) = try CropUITestSupport.makeSession(in: workDir)
        let loupe = LoupeController(session: session)
        loupe.autoRenderEnabled = false
        loupe.collectsHistogram = false
        _ = loupe.view

        _ = NSApplication.shared
        let state = InspectorWorkspaceState()
        let host = NSHostingView(rootView: InspectorView(session: session, loupe: loupe,
                                                         workspaces: state))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 900)
        let window = TestWindows.make(contentRect: host.frame, styleMask: [.borderless],
                                      backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        CropUITestSupport.pump(0.4)
        host.layoutSubtreeIfNeeded()
        state.select(.transform)
        let panel = Panel(host: host, window: window, state: state)
        _ = try waitFor { panel.cards.cardIDs == ["crop", "transformCorrection", "angle"] }
        return (panel, loupe)
    }

    @discardableResult
    private func waitFor(_ predicate: () -> Bool) throws -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if predicate() { return true }
            CropUITestSupport.pump(0.05)
        }
        return predicate()
    }

    private static func first<T: NSView>(_ type: T.Type, in root: NSView) -> T? {
        if let match = root as? T { return match }
        for sub in root.subviews {
            if let match = first(type, in: sub) { return match }
        }
        return nil
    }
}
