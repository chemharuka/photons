import XCTest
import AppKit
import SwiftUI
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 2026-10-28 (P0 色彩分级) — **色彩分级** on a hosted panel: three wheels × three axes, what one
/// gesture costs the history, what a double-click resets, and what the three panel widths do to the card.
///
/// The card is `InspectorView.colorGradingCard`; every row is the panel's **one** `SliderRow` (040/046)
/// and every number is `colorGrading.<region>.<axis>` — so what is pinned here is the *card*, not a
/// second implementation of a row.
///
///   1. **一张卡、九行**: 3 wheels × 3 axes, in the 色彩 workspace, after HSL (`RenderStage.order`'s
///      `… .hsl, .grade, .vignette`), with a required group reset.
///   2. **画出来了**: 9 rows, inside the card, in table order, no overlap — at 244 / 274 / 308 pt of
///      card content (panel 300 / 330 / 364).
///   3. **一根滑杆 = 一条历史，每轮一行**: a drag writes the document and commits once, and a second
///      axis of the **same** wheel folds into the same row while another wheel gets its own.
///   4. **复位**: one row's double-click clears one number (`coalesce: false`), the title clears all
///      nine in one snapshot, and neither mints an empty snapshot.
///   5. **反证**: the card's own text must go through `resets`/`sliderRow`; a card that wrote the model
///      directly would pass 3 and fail 4 (no snapshot at all) — the same counter-proof 黑白's card has.
@MainActor
final class ColorGradingCardTests: XCTestCase {

    private static let panelHeight: CGFloat = 1200
    private static let widths: [CGFloat] = [300, 330, 364]

    // MARK: - 1. 卡片清单、位置、行的表

    func testTheCardIsNineRowsAfterHSLInTheColourWorkspace() throws {
        XCTAssertEqual(InspectorWorkspace.colour.cards, [.hsl, .pointColor, .colorGrading, .blackAndWhite])
        XCTAssertEqual(InspectorView.sections(in: .colour).map(\.title), ["HSL", "点颜色", "色彩分级", "黑白"])
        XCTAssertEqual(InspectorView.Section.colorGrading.title, "色彩分级", "标题 = 卡名 = 撤销标签")

        // Nine rows, three per wheel, in the panel's order.
        XCTAssertEqual(InspectorView.gradeRows.count, 9)
        XCTAssertEqual(InspectorView.colorGradingRowCount, 9)
        XCTAssertEqual(InspectorView.gradeRows.map(\.region.title),
                       ["阴影", "阴影", "阴影", "中间调", "中间调", "中间调", "高光", "高光", "高光"])
        XCTAssertEqual(InspectorView.gradeRows.map(\.axis.title),
                       ["色相", "饱和", "亮度", "色相", "饱和", "亮度", "色相", "饱和", "亮度"])
        XCTAssertEqual(InspectorView.gradeRows.map(\.fieldKey),
                       ["colorGrading.shadows.hue", "colorGrading.shadows.saturation",
                        "colorGrading.shadows.lightness", "colorGrading.midtones.hue",
                        "colorGrading.midtones.saturation", "colorGrading.midtones.lightness",
                        "colorGrading.highlights.hue", "colorGrading.highlights.saturation",
                        "colorGrading.highlights.lightness"])

        for row in InspectorView.gradeRows {
            XCTAssertEqual(row.range, -100 ... 100, "\(row.fieldKey)：±100")
            XCTAssertEqual(row.format, "%.0f", "\(row.fieldKey)：整数读数")
            XCTAssertEqual(row.shape, .knob, "\(row.fieldKey)：蓝 = 显示域渲染参数（060 的类）")
            XCTAssertTrue(row.editable, "047：每一行都能键入")
            XCTAssertEqual(row.decimals, 0, "编辑时也是整数")
            XCTAssertEqual(row.quantum, 1, "文档的格子是 1 个单位：读数就是存进去的数")
            XCTAssertEqual(row.defaultValue, 0, "默认 0（`GradeWheel()`，不是字面量）")
        }
        // The group reset exists and is the card's own (a double-click on the title).
        XCTAssertTrue(PanelResets.Group.allCases.contains(.colorGrading))
        XCTAssertEqual(PanelResets.Group.colorGrading.title, "色彩分级")
        print("GRADE CARD · \(InspectorView.gradeRows.map(\.fieldKey))")
    }

    // MARK: - 2. 画出来了：九行都在卡里

    func testTheHostedCardDrawsItsNineRowsInsideTheCard() throws {
        let panel = try host(width: 330, filled: true)
        defer { panel.window.contentView = nil }
        try waitFor(panel) { $0.probes.count == 10 }        // card + 9 rows

        let card = try XCTUnwrap(panel.cardFrame, "没有卡片 frame")
        XCTAssertGreaterThan(card.width, 200)
        let rows = try InspectorView.gradeRows.map { row -> (String, CGRect) in
            let frame = try XCTUnwrap(panel.rowFrame(row.fieldKey), "「\(row.fieldKey)」没有画出来")
            return (row.fieldKey, frame)
        }
        for (key, frame) in rows {
            XCTAssertGreaterThan(frame.width, 60, "「\(key)」只剩 \(frame.width) pt")
            XCTAssertGreaterThanOrEqual(frame.minX, card.minX - 0.5, "「\(key)」出了卡片左边")
            XCTAssertLessThanOrEqual(frame.maxX, card.maxX + 0.5, "「\(key)」出了卡片右边")
            XCTAssertGreaterThan(frame.height, 10, "「\(key)」没有被画出来")
        }
        let ordered = rows.sorted { $0.1.minY < $1.1.minY }.map(\.0)
        XCTAssertEqual(ordered, InspectorView.gradeRows.map(\.fieldKey), "九行的上下顺序必须是表的顺序")
        let sorted = rows.map(\.1).sorted { $0.minY < $1.minY }
        for (a, b) in zip(sorted, sorted.dropFirst()) {
            XCTAssertLessThanOrEqual(a.maxY, b.minY + 0.5, "两根行压在一起了：\(a) / \(b)")
        }
        print("GRADE CARD · card \(card) · 9 rows \(rows.map { "\($0.0)@\(Int($0.1.minY))" })")
    }

    /// The three panel widths the resolver allows: every row stays inside the card and none is crushed.
    func testTheNineRowsFitAtTheThreeWidths() throws {
        var measured: [String: CGRect] = [:]
        for width in Self.widths {
            let panel = try host(width: width, filled: true)
            defer { panel.window.contentView = nil }
            try waitFor(panel) { $0.probes.count == 10 }
            let card = try XCTUnwrap(panel.cardFrame)
            // The column's 12 pt padding either side is the card's frame; the card's own 16 pt inset is
            // where the rows stop — the two numbers `LayoutContractTests` pins as 244 / 274 / 308.
            XCTAssertEqual(card.width, width - 2 * 12, accuracy: 0.5,
                           "卡宽 = 面板 − 2·12，实测 \(card.width)")
            let contentWidth = width - 2 * 12 - 2 * WorkspaceLayout.cardInsetH
            for row in InspectorView.gradeRows {
                let frame = try XCTUnwrap(panel.rowFrame(row.fieldKey), "\(width) pt：\(row.fieldKey) 没画出来")
                XCTAssertEqual(frame.width, contentWidth, accuracy: 1.0,
                               "\(width) pt：\(row.fieldKey) 的行宽应是卡内容宽 \(contentWidth)")
                XCTAssertGreaterThan(frame.width, 60, "\(width) pt：\(row.fieldKey) 只剩 \(frame.width) pt")
                XCTAssertLessThanOrEqual(frame.maxX, card.maxX + 0.5, "\(width) pt：\(row.fieldKey) 出了卡片")
                measured[row.fieldKey] = frame
            }
        }
        print("GRADE CARD WIDTHS · " + Self.widths.map { "\(Int($0))→\(Int(measured.count)) rows" }
            .joined(separator: " · "))
    }

    // MARK: - 3. 一次拖动 = 一行历史；每轮一行

    func testOneWheelIsOneHistoryRowAndAnotherWheelIsAnother() throws {
        let session = try Catalogue.makeSession()
        let base = session.history.count

        // A drag of 阴影 色相: what the slider binding and the gesture-end commit do.
        session.applyEdit { $0.colorGrading.shadows.hue = 24 }
        session.commitEdit(label: "色彩分级 阴影")
        XCTAssertEqual(session.history.count, base + 1)
        XCTAssertEqual(session.history.snapshots.last?.label, "色彩分级 阴影")

        // A second axis of the **same** wheel, in the same run: folded into that row.
        session.applyEdit { $0.colorGrading.shadows.saturation = 40 }
        session.commitEdit(label: "色彩分级 阴影")
        XCTAssertEqual(session.history.count, base + 1, "同一个轮的第二根轴必须合并进那一行")
        XCTAssertEqual(session.history.snapshots.last?.changes.count, 2)

        // A different wheel: its own row.
        session.applyEdit { $0.colorGrading.highlights.lightness = -30 }
        session.commitEdit(label: "色彩分级 高光")
        XCTAssertEqual(session.history.count, base + 2)
        XCTAssertEqual(session.history.snapshots.last?.label, "色彩分级 高光")
        XCTAssertEqual(session.history.snapshots.last?.changes.first?.summary, "色彩分级[高光] 亮度 -10 → -30")
        print("GRADE HISTORY · \(session.history.snapshots.map { "\($0.label)[\($0.changes.count)]" })")
    }

    /// A typed number takes the same path as a drag: the document holds what was typed, and one gesture
    /// is one row. (`SliderValueInput`'s parser is pinned in `NumberFieldTypingTests`; what is pinned
    /// here is that this card's row writes the number into `colorGrading` and nothing else.)
    func testARowWritesOnlyItsOwnNumber() throws {
        let session = try Catalogue.makeSession()
        let before = session.edit.colorGrading
        session.applyEdit { $0.colorGrading.midtones.hue = -12 }
        XCTAssertEqual(session.edit.colorGrading.midtones.hue, -12)
        // The *other* two wheels and the other two axes of this one are exactly what they were.
        XCTAssertEqual(session.edit.colorGrading.shadows, before.shadows, "别的轮不许被顺手改了")
        XCTAssertEqual(session.edit.colorGrading.highlights, before.highlights)
        XCTAssertEqual(session.edit.colorGrading.midtones.saturation, before.midtones.saturation)
        XCTAssertEqual(session.edit.colorGrading.midtones.lightness, before.midtones.lightness)
        // And nothing outside the group: not Color's two numbers, not the 24 band numbers.
        XCTAssertEqual(session.edit.color.vibrance, 0, "Color 卡的数不许被顺手改了")
        XCTAssertEqual(session.edit.color.bands, ColorGroup.identityBands, "HSL 的 24 个数不许被改")
    }

    // MARK: - 4. 复位

    func testOneRowResetClearsOneNumberAndTheTitleClearsAllNine() throws {
        let session = try Catalogue.makeSession()
        var all = EditModel.neutral
        all.colorGrading.shadows = GradeWheel(hue: 20, saturation: 30, lightness: 10)
        all.colorGrading.midtones = GradeWheel(hue: -5)
        all.colorGrading.highlights = GradeWheel(saturation: -20)
        session.applyEdit { $0.colorGrading = all.colorGrading }
        session.commitEdit(label: "色彩分级")
        let base = session.history.count
        let resets = PanelResets(session: session)

        // One row.
        let row = InspectorView.gradeRows[0]                  // 阴影 色相
        XCTAssertTrue(resets.colorGradingField(row))
        XCTAssertEqual(session.edit.colorGrading.shadows.hue, 0)
        XCTAssertEqual(session.edit.colorGrading.shadows.saturation, 30, "只清这一根")
        XCTAssertEqual(session.history.count, base + 1, "双击复位是一个命令，一行历史")
        // A second double-click on the same row writes nothing.
        XCTAssertFalse(resets.colorGradingField(row), "已经在该行的默认值上，不许造空快照")
        XCTAssertEqual(session.history.count, base + 1)

        // The whole card, one snapshot.
        XCTAssertTrue(resets.group(.colorGrading))
        XCTAssertTrue(session.edit.colorGrading.isIdentity, "标题双击 = 九个 0")
        XCTAssertEqual(session.history.count, base + 2, "整卡复位也是**一行**")
        XCTAssertFalse(resets.group(.colorGrading), "已经全 0，不许再造一行")
        XCTAssertEqual(session.history.count, base + 2)
        print("GRADE RESET · \(session.history.snapshots.map(\.label))")
    }

    // MARK: - 5. 反证：卡必须走 resets / sliderRow

    /// The card's source must not write the document itself: a card that bound a row straight to
    /// `EditModel` would still *look* right on screen, and its double-click would leave no history row —
    /// exactly the bug `PanelResets` exists to prevent. The positive assertions (the two verbs, the single
    /// row builder) are what make the negative ones meaningful.
    func testTheCardGoesThroughThePanelFurniture() throws {
        let card = try Self.body(of: "private var colorGradingCard: some View {",
                                 upTo: "// MARK: the Light card's rows", in: Self.inspectorSource)
        XCTAssertTrue(card.contains("resets.colorGradingField(row)"),
                      "每行的双击复位必须走 PanelResets")
        XCTAssertTrue(card.contains("resetGroup(.colorGrading)"),
                      "标题双击必须走 group(.colorGrading)（一行快照）")
        XCTAssertTrue(card.contains("if !editing { session.commitEdit(label: Self.gradeLabel(row)) }"),
                      "拖动结束必须提交一行，标签是「色彩分级 <轮>」")
        XCTAssertEqual(Self.occurrences(of: "Slider(value: ", in: card), 0, "卡里不许自己造滑杆")
        XCTAssertFalse(card.contains("step:"), "没有刻度线（046）")
        XCTAssertTrue(card.contains("sliderRow("), "每一行都是面板唯一的那根行")
    }

    // MARK: - host

    private enum Catalogue {
        /// A session whose document has one number in each wheel (so the card is not all zeros).
        @MainActor
        static func makeSession() throws -> CatalogSession {
            let session = CatalogSession()
            var edit = EditModel.neutral
            edit.colorGrading.shadows = GradeWheel(hue: 10)
            edit.colorGrading.midtones = GradeWheel(saturation: 20)
            edit.colorGrading.highlights = GradeWheel(lightness: -10)
            session.applyEdit { $0.colorGrading = edit.colorGrading }
            session.commitEdit(label: "色彩分级")
            return session
        }
    }

    private struct Panel {
        let host: NSHostingView<InspectorView>
        let window: NSWindow
        let cards: InspectorCardsProbe
        let probes: [ColorGradingProbe]

        var cardFrame: CGRect? {
            guard let probe = probes.first(where: { $0.rowID == ColorGradingProbe.cardID }) else { return nil }
            return probe.convert(probe.bounds, to: host)
        }

        func rowFrame(_ id: String) -> CGRect? {
            guard let probe = probes.first(where: { $0.rowID == id }) else { return nil }
            return probe.convert(probe.bounds, to: host)
        }
    }

    private func host(width: CGFloat, filled: Bool) throws -> Panel {
        let session: CatalogSession
        if filled {
            session = try Catalogue.makeSession()
        } else {
            session = CatalogSession()
        }
        return try host(session: session, width: width)
    }

    private func host(session: CatalogSession, width: CGFloat) throws -> Panel {
        _ = NSApplication.shared
        // 色彩 workspace: the grade card is the second card there, so the panel must be switched to it.
        let state = InspectorWorkspaceState(.colour)
        let host = NSHostingView(rootView: InspectorView(session: session, workspaces: state))
        host.frame = NSRect(x: 0, y: 0, width: width, height: Self.panelHeight)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        let cards = try XCTUnwrap(Self.find(InspectorCardsProbe.self, in: host), "卡片探针不在树上")
        return Panel(host: host, window: window, cards: cards,
                     probes: Self.all(ColorGradingProbe.self, in: host))
    }

    @discardableResult
    private func waitFor(_ panel: Panel, until predicate: (Panel) -> Bool) throws -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            panel.host.layoutSubtreeIfNeeded()
            if predicate(panel) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        panel.host.layoutSubtreeIfNeeded()
        return predicate(panel)
    }

    private static func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let hit = view as? T { return hit }
        for sub in view.subviews {
            if let hit = find(type, in: sub) { return hit }
        }
        return nil
    }

    private static func all<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        var found: [T] = []
        if let hit = view as? T { found.append(hit) }
        for sub in view.subviews { found += all(type, in: sub) }
        return found
    }

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // PhotonsUITests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
    }

    private static var inspectorSource: URL {
        repoRoot.appendingPathComponent("Sources/PhotonsUI/InspectorView.swift")
    }

    private static func body(of signature: String, upTo endMarker: String,
                             in url: URL) throws -> String {
        let source = try String(contentsOf: url, encoding: .utf8)
        guard let start = source.range(of: signature),
              let end = source.range(of: endMarker),
              start.lowerBound < end.lowerBound else {
            throw XCTSkip("no `\(signature)` … `\(endMarker)` section in \(url.lastPathComponent)")
        }
        return String(source[start.lowerBound..<end.lowerBound])
    }

    private static func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var search = haystack.startIndex..<haystack.endIndex
        while let found = haystack.range(of: needle, range: search) {
            count += 1
            search = found.upperBound..<haystack.endIndex
        }
        return count
    }
}
