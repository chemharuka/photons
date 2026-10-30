import XCTest
import AppKit
import SwiftUI
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 140 — **点颜色** on a hosted panel: where the card sits, its five rows, what one gesture costs the
/// history, what a double-click resets, and whether the swatch really shows the sample.
///
///   1. **一张卡、五行**: 范围 / 过渡 / 色相 / 饱和 / 亮度, in the 色彩 workspace between HSL and
///      色彩分级 (`RenderStage.order`'s `.hsl, .pointColour, .grade`).
///   2. **画出来了**: five rows and the sample block are inside the card at the three panel widths.
///   3. **一根滑杆 = 一条历史**: a drag writes the document and commits once; a reset is its own row.
///   4. **复位**: one row's double-click clears one number, the title clears the whole object to `nil`.
///   5. **色块显示采样色**: the probe reports the sample and the sRGB the view actually fills with.
///   6. **吸管**: one sample = one history row and writes only `sampleHue`/`sampleChroma`.
@MainActor
final class PointColorPanelTests: XCTestCase {

    private static let panelHeight: CGFloat = 1600
    private static let widths: [CGFloat] = [300, 330, 364]

    // MARK: - 1. the card, its position and its table

    func testTheCardIsFiveRowsBetweenHSLAndColorGrading() throws {
        XCTAssertEqual(InspectorWorkspace.colour.cards,
                       [.hsl, .pointColor, .colorGrading, .blackAndWhite])
        XCTAssertEqual(InspectorView.sections(in: .colour).map(\.title),
                       ["HSL", "点颜色", "色彩分级", "黑白"])
        XCTAssertEqual(InspectorView.Section.pointColor.title, "点颜色", "标题 = 卡名 = 撤销标签")

        XCTAssertEqual(PointColorAxis.allCases.count, 5)
        XCTAssertEqual(PointColorAxis.allCases.map(\.title),
                       ["范围", "过渡", "色相", "饱和", "亮度"])
        XCTAssertEqual(PointColorAxis.allCases.map(\.fieldKey),
                       ["color.point.range", "color.point.feather",
                        "color.point.hue", "color.point.saturation", "color.point.luminance"])
        XCTAssertEqual(PointColorAxis.range.range, 0 ... 120, "范围以度为单位")
        XCTAssertEqual(PointColorAxis.feather.range, 0 ... 120, "过渡以度为单位")
        XCTAssertEqual(PointColorAxis.hue.range, -100 ... 100)
        XCTAssertEqual(PointColorAxis.saturation.range, -100 ... 100)
        XCTAssertEqual(PointColorAxis.luminance.range, -100 ... 100)
        XCTAssertEqual(PointColorAxis.range.defaultValue, 30, "默认 30°：一吸就选中")
        XCTAssertEqual(PointColorAxis.feather.defaultValue, 30)
        XCTAssertEqual(PointColorAxis.hue.defaultValue, 0)
        XCTAssertEqual(PointColorAxis.saturation.defaultValue, 0)
        XCTAssertEqual(PointColorAxis.luminance.defaultValue, 0)

        XCTAssertTrue(PanelResets.Group.allCases.contains(.pointColor))
        XCTAssertEqual(PanelResets.Group.pointColor.title, "点颜色")
        print("POINT CARD · \(PointColorAxis.allCases.map(\.fieldKey))")
    }

    // MARK: - 2. the card is drawn

    func testTheHostedCardDrawsItsFiveRowsAndSwatchInsideTheCard() throws {
        let panel = try host(width: 330)
        defer { panel.window.contentView = nil }
        try waitFor(panel) { $0.probes.count == 7 }       // card + swatch + five rows

        let card = try XCTUnwrap(panel.cardFrame, "没有卡片 frame")
        XCTAssertGreaterThan(card.width, 200)
        let rows = try PointColorAxis.allCases.map { axis -> (String, CGRect) in
            let frame = try XCTUnwrap(panel.rowFrame(axis.rawValue), "「\(axis.title)」没有画出来")
            XCTAssertGreaterThan(frame.width, 60, "\(axis.title) 只剩 \(frame.width) pt")
            XCTAssertGreaterThanOrEqual(frame.minX, card.minX - 0.5)
            XCTAssertLessThanOrEqual(frame.maxX, card.maxX + 0.5)
            XCTAssertGreaterThan(frame.height, 10)
            return (axis.rawValue, frame)
        }
        let ordered = rows.sorted { $0.1.minY < $1.1.minY }.map(\.0)
        XCTAssertEqual(ordered, PointColorAxis.allCases.map(\.rawValue), "五行必须按表的顺序")
        let sorted = rows.map(\.1).sorted { $0.minY < $1.minY }
        for (a, b) in zip(sorted, sorted.dropFirst()) {
            XCTAssertLessThanOrEqual(a.maxY, b.minY + 0.5, "两根行压在一起了")
        }
        let swatch = try XCTUnwrap(panel.rowFrame(PointColorProbe.swatchID), "色块没有画出来")
        XCTAssertGreaterThan(swatch.width, 20)
        print("POINT CARD · card \(card) · rows \(rows.map { "\($0.0)@\(Int($0.1.minY))" })")
    }

    func testTheFiveRowsFitAtTheThreeWidths() throws {
        var measured: [String: CGRect] = [:]
        for width in Self.widths {
            let panel = try host(width: width)
            defer { panel.window.contentView = nil }
            try waitFor(panel) { $0.probes.count == 7 }
            let card = try XCTUnwrap(panel.cardFrame)
            XCTAssertEqual(card.width, width - 2 * 12, accuracy: 0.5,
                           "卡宽 = 面板 − 2·12，实测 \(card.width)")
            let contentWidth = width - 2 * 12 - 2 * WorkspaceLayout.cardInsetH
            for axis in PointColorAxis.allCases {
                let frame = try XCTUnwrap(panel.rowFrame(axis.rawValue),
                                          "\(width) pt：\(axis.title) 没画出来")
                XCTAssertEqual(frame.width, contentWidth, accuracy: 1.0)
                measured[axis.rawValue] = frame
            }
        }
        print("POINT CARD WIDTHS · " + Self.widths.map { "\(Int($0))→\(measured.count) rows" }
            .joined(separator: " · "))
    }

    // MARK: - 3. rows write the document, one gesture = one row

    func testARowWritesOnlyItsOwnNumberAndOneDragIsOneHistoryRow() throws {
        let session = CatalogSession()
        var point = PointColor(sampleHue: 20, sampleChroma: 0.08)
        point.range = 45
        session.applyEdit { $0.color.point = point }
        session.commitEdit(label: "点颜色")
        let base = session.history.count

        session.applyEdit { model in
            var p = model.color.point ?? PointColor()
            p[.hue] = 24
            model.color.point = p
        }
        session.commitEdit(label: "点颜色 色相")
        XCTAssertEqual(session.edit.color.point?.hue, 24)
        XCTAssertEqual(session.edit.color.point?.range, 45, "别的行不许被顺手改了")
        XCTAssertEqual(session.edit.color.point?.saturation, 0)
        XCTAssertEqual(session.edit.color.point?.sampleHue, 20, "采样色不是滑杆")
        XCTAssertEqual(session.history.count, base + 1)
        XCTAssertEqual(session.history.snapshots.last?.label, "点颜色 色相")

        // Every axis round-trips through the same subscript the binding uses.
        var p = PointColor()
        p[.range] = 55; p[.feather] = 12; p[.hue] = -30
        p[.saturation] = 40; p[.luminance] = -20
        XCTAssertEqual(p.range, 55)
        XCTAssertEqual(p.feather, 12)
        XCTAssertEqual(p.hue, -30)
        XCTAssertEqual(p.saturation, 40)
        XCTAssertEqual(p.luminance, -20)
        print("POINT HISTORY · \(session.history.snapshots.map(\.label))")
    }

    // MARK: - 4. reset

    func testOneRowResetClearsOneNumberAndTheTitleClearsTheObject() throws {
        let session = CatalogSession()
        var point = PointColor(sampleHue: 30, sampleChroma: 0.1)
        point.range = 45
        point.feather = 20
        point.hue = 25
        point.saturation = -15
        point.luminance = 10
        session.applyEdit { $0.color.point = point }
        session.commitEdit(label: "点颜色")
        let base = session.history.count
        let resets = PanelResets(session: session)

        XCTAssertTrue(resets.pointColorField(.range))
        XCTAssertEqual(session.edit.color.point?.range, PointColor.defaultRange)
        XCTAssertEqual(session.edit.color.point?.feather, 20, "只清这一根")
        XCTAssertEqual(session.edit.color.point?.hue, 25)
        XCTAssertEqual(session.history.count, base + 1, "一根行复位 = 一条历史")
        XCTAssertFalse(resets.pointColorField(.range), "已经在该行的默认值上，不许造空快照")
        XCTAssertEqual(session.history.count, base + 1)

        XCTAssertTrue(resets.pointColor())
        XCTAssertNil(session.edit.color.point, "标题双击 = 回到 nil（未启用）")
        XCTAssertEqual(session.history.count, base + 2)
        XCTAssertFalse(resets.pointColor(), "已经 nil，不许再造一行")
        XCTAssertEqual(session.history.count, base + 2)
        print("POINT RESET · \(session.history.snapshots.map(\.label))")
    }

    // MARK: - 5. the swatch shows the sample

    func testTheSwatchReportsTheSampledColour() throws {
        let session = CatalogSession()
        var point = PointColor(sampleHue: 24.78, sampleChroma: 0.08)
        point.hue = 20
        session.applyEdit { $0.color.point = point }
        session.commitEdit(label: "点颜色")

        let panel = try host(session: session, width: 330)
        defer { panel.window.contentView = nil }
        try waitFor(panel) { $0.probes.count == 7 }
        let probe = try XCTUnwrap(panel.probes.first { $0.rowID == PointColorProbe.swatchID })
        XCTAssertTrue(probe.isSampled)
        XCTAssertEqual(probe.sampleHue, 24.78, accuracy: 1e-9)
        XCTAssertEqual(probe.sampleChroma, 0.08, accuracy: 1e-9)
        let expected = PointColorSwatchView.srgb(for: point)
        XCTAssertEqual(probe.swatchRed, expected.r, accuracy: 1e-9)
        XCTAssertEqual(probe.swatchGreen, expected.g, accuracy: 1e-9)
        XCTAssertEqual(probe.swatchBlue, expected.b, accuracy: 1e-9)
        XCTAssertNotEqual(probe.swatchRed, probe.swatchGreen, "红样本不该画成灰")
        print(String(format: "POINT SWATCH · H %.1f° C %.2f → sRGB %.3f %.3f %.3f",
                     probe.sampleHue, probe.sampleChroma,
                     probe.swatchRed, probe.swatchGreen, probe.swatchBlue))
    }

    // MARK: - 6. the dropper

    func testSamplingWritesTheSampleInOneHistoryRow() throws {
        let session = CatalogSession()
        let base = session.history.count
        let commands = PointColorCommands(session: session)

        XCTAssertTrue(commands.sample(RGBSample(r: 0.8, g: 0.1, b: 0.05)))
        XCTAssertEqual(session.history.count, base + 1, "一次取样 = 一条历史")
        XCTAssertEqual(session.history.snapshots.last?.label, "点颜色 取样")
        let stored = try XCTUnwrap(session.edit.color.point)
        XCTAssertTrue(stored.isSampled)
        XCTAssertGreaterThan(stored.sampleChroma, 0.1, "红样本必须有彩度")
        XCTAssertEqual(stored.hue, 0, "取样不改任何调整滑杆")
        XCTAssertEqual(stored.saturation, 0)
        XCTAssertEqual(stored.luminance, 0)

        XCTAssertFalse(commands.sample(RGBSample(r: 0.8, g: 0.1, b: 0.05)),
                       "同一个颜色再点一次不许造空快照")
        XCTAssertEqual(session.history.count, base + 1)
        print("POINT DROPPER · sample H \(String(format: "%.1f", stored.sampleHue))°"
              + " C \(String(format: "%.3f", stored.sampleChroma))")
    }

    // MARK: - 7. the card goes through the panel furniture

    func testTheCardGoesThroughThePanelFurniture() throws {
        let card = try Self.body(of: "private var pointColorCard: some View {",
                                 upTo: "    private func pointColorBinding", in: Self.inspectorSource)
        XCTAssertTrue(card.contains("reset: { resets.pointColor() }"),
                      "标题双击必须走 group(.pointColor)（一行快照）")
        XCTAssertTrue(card.contains("resets.pointColorField(axis)"),
                      "每行的双击复位必须走 PanelResets")
        XCTAssertTrue(card.contains("if !editing { session.commitEdit(label: \"点颜色 \\(axis.title)\") }"),
                      "拖动结束必须提交一行")
        XCTAssertTrue(card.contains("PointColorSwatchView(point: point)"), "色块")
        XCTAssertTrue(card.contains("先吸取一个颜色"), "未取色时给出提示")
        XCTAssertTrue(card.contains("sliderRow("), "每一行都是面板唯一的那根行")
        XCTAssertEqual(Self.occurrences(of: "Slider(value: ", in: card), 0, "卡里不许自己造滑杆")
        let source = try String(contentsOf: Self.inspectorSource, encoding: .utf8)
        XCTAssertTrue(source.contains("loupe.armEyedropper"), "吸管走 LoupeController")
        XCTAssertTrue(card.contains("Esc 取消"), "交叉光标之外还有文字说明")
    }

    // MARK: - host

    private struct Panel {
        let host: NSHostingView<InspectorView>
        let window: NSWindow
        let probes: [PointColorProbe]

        var cardFrame: CGRect? {
            guard let probe = probes.first(where: { $0.rowID == PointColorProbe.cardID }) else {
                return nil
            }
            return probe.convert(probe.bounds, to: host)
        }

        func rowFrame(_ id: String) -> CGRect? {
            guard let probe = probes.first(where: { $0.rowID == id }) else { return nil }
            return probe.convert(probe.bounds, to: host)
        }
    }

    private func host(width: CGFloat) throws -> Panel {
        try host(session: CatalogSession(), width: width)
    }

    private func host(session: CatalogSession, width: CGFloat) throws -> Panel {
        _ = NSApplication.shared
        let state = InspectorWorkspaceState(.colour)
        let host = NSHostingView(rootView: InspectorView(session: session, workspaces: state))
        host.frame = NSRect(x: 0, y: 0, width: width, height: Self.panelHeight)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        return Panel(host: host, window: window,
                     probes: Self.all(PointColorProbe.self, in: host))
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
