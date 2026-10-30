import XCTest
import AppKit
import SwiftUI
import Metal
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 179 — **校准** on a hosted panel: the seven rows 179's matrix reads, what a double-click costs the
/// history, and — the reason the card exists — that a number typed on the panel reaches the pixel.
///
/// The engine half (`CalibrationTests`) proves the matrix; this file is about the missing half the
/// lane was chartered for: a document field nobody can reach is the 029 colour-fringe bug again (the
/// model, the kernel and the key all worked, and no user could touch it).
///
///   1. **七行**: 阴影色调 + 红/绿/蓝 各自的 色相/饱和, in the 色彩 workspace, in slider units
///      (−100…+100), `.linear` (071's third class — arithmetic on the scene-linear buffer), typeable,
///      with a double-click reset on each name and on the card title.
///   2. **画出来了**:七个 number field, in row order, in the card's own identifier namespace.
///   3. **一次输入 = 一条历史**: a typed number stores exactly that number (no unit conversion — the
///      panel's unit *is* the document's), and costs one history row; a title reset costs one.
///   4. **复位范围 = 卡片范围**: a row reset moves that number only; the title reset moves all seven
///      and nothing on 色彩分级 / 黑白.
///   5. **复制 / 预设**: the seven numbers survive `EditSnapshot` and `Preset` round trips and nothing
///      else travels with them.
@MainActor
final class CalibrationCardTests: XCTestCase {

    private static let panelHeight: CGFloat = 3600

    // MARK: - 1. the seven rows, as data

    func testTheSevenRowsLiveInTheirOwnColourWorkspaceCard() throws {
        XCTAssertEqual(InspectorView.Section.calibration.title, "校准")
        // 179: 色彩 workspace, directly after 色彩分级 (both cards move colour by a classification of
        // it) and before 黑白.
        XCTAssertTrue(InspectorWorkspace.colour.cards.contains(.calibration))
        XCTAssertEqual(InspectorView.cardTitles(in: .colour),
                       ["HSL", "点颜色", "色彩分级", "校准", "黑白"])

        XCTAssertEqual(InspectorView.calibrationRows.map(\.title),
                       ["阴影色调", "红 色相", "红 饱和", "绿 色相", "绿 饱和", "蓝 色相", "蓝 饱和"])
        for row in InspectorView.calibrationRows {
            XCTAssertEqual(row.range, CalibrationGroup.sliderRange, "\(row.title)：−100…+100")
            XCTAssertEqual(row.range, -100 ... 100)
            XCTAssertEqual(row.format, "%.0f", "\(row.title)：整数读数")
            XCTAssertEqual(row.shape, .linear, "\(row.title)：S1 出口的线性算术 → 071 的第三类")
            XCTAssertEqual(row.shape.accent, SliderShape.linearAccent)
            XCTAssertTrue(row.editable, "047：每一行都能键入")
            XCTAssertEqual(row.defaultValue, 0, "默认 = 文档的 0（`CalibrationGroup()`，不是字面量）")
        }
    }

    /// Each row owns exactly one document field, and the seven of them are the seven `CalibrationGroup`
    /// numbers — no second parameter set, no row that writes a neighbour's field.
    func testEachRowOwnsOneOfTheSevenNumbers() throws {
        var probe = EditModel.neutral
        for (index, row) in InspectorView.calibrationRows.enumerated() {
            probe[keyPath: row.keyPath] = Double(index + 1)
        }
        XCTAssertEqual(probe.calibration.shadowTint, 1)
        XCTAssertEqual(probe.calibration.redHue, 2)
        XCTAssertEqual(probe.calibration.redSat, 3)
        XCTAssertEqual(probe.calibration.greenHue, 4)
        XCTAssertEqual(probe.calibration.greenSat, 5)
        XCTAssertEqual(probe.calibration.blueHue, 6)
        XCTAssertEqual(probe.calibration.blueSat, 7)
        XCTAssertEqual(Set(InspectorView.calibrationRows.map(\.keyPath)).count, 7)
    }

    // MARK: - 2. it is really drawn

    func testTheCardDrawsSevenNumberFieldsInRowOrder() throws {
        let panel = host()
        defer { panel.window.contentView = nil }
        let ids = panel.numberFieldIDs.filter { $0.hasPrefix("inspector.calibration.") }
        XCTAssertEqual(ids.count, 7, "七行：\(ids.sorted())")
        for row in InspectorView.calibrationRows {
            XCTAssertTrue(ids.contains("inspector.calibration.\(row.title)"),
                          "\(row.title) 没有画出来：\(ids.sorted())")
        }
    }

    // MARK: - 3. typing / resetting costs one history row and writes the number

    func testATypedNumberStoresTheNumberAndCostsOneHistoryRow() throws {
        let session = CatalogSession()
        let resets = PanelResets(session: session)
        session.applyEdit { $0.calibration.redHue = 30 }
        XCTAssertTrue(session.commitEdit())
        let before = session.history.count

        // A double-click on a row's name is one command, not part of the drag before it.
        XCTAssertTrue(resets.field(\.calibration.redHue, label: "红 色相"))
        XCTAssertEqual(session.edit.calibration.redHue, 0, "复位回 0")
        XCTAssertEqual(session.history.count, before + 1)
        // …and a second double-click writes nothing (no empty snapshot, no truncated redo branch).
        XCTAssertFalse(resets.field(\.calibration.redHue, label: "红 色相"))
        XCTAssertEqual(session.history.count, before + 1)
    }

    func testARowResetMovesThatNumberOnlyAndTheTitleResetMovesAllSeven() throws {
        let session = CatalogSession()
        let resets = PanelResets(session: session)
        session.applyEdit { model in
            model.calibration = CalibrationGroup(shadowTint: 20, redHue: 15, redSat: -10,
                                                 greenHue: 5, greenSat: 25,
                                                 blueHue: -20, blueSat: 30)
            // a sentinel on the neighbouring card: a 校准 reset must leave it alone.
            model.colorGrading.shadows.hue = 12
        }
        XCTAssertTrue(session.commitEdit())

        XCTAssertTrue(resets.field(\.calibration.greenSat, label: "绿 饱和"))
        XCTAssertEqual(session.edit.calibration.greenSat, 0)
        XCTAssertEqual(session.edit.calibration.shadowTint, 20, "别的字段不许动")
        XCTAssertEqual(session.edit.calibration.blueSat, 30)

        // The card title: all seven at once, one snapshot, and 色彩分级 keeps its wheel.
        let before = session.history.count
        XCTAssertTrue(resets.group(.calibration))
        XCTAssertTrue(session.edit.calibration.isIdentity)
        XCTAssertEqual(session.edit.colorGrading.shadows.hue, 12, "双击校准不能撤销色彩分级")
        XCTAssertEqual(session.history.count, before + 1)
        XCTAssertFalse(resets.group(.calibration), "已经是全 0：不许写空快照")
        XCTAssertEqual(session.history.count, before + 1)
    }

    // MARK: - 4. copy / preset carry the seven numbers

    func testCopyCarriesTheSevenNumbersAndNothingElse() throws {
        var source = EditModel.neutral
        source.calibration = CalibrationGroup(shadowTint: -12.5, redHue: 30, blueSat: 40)
        source.colorGrading.shadows.hue = 12

        let snapshot = EditSnapshot.capture(source)
        XCTAssertEqual(snapshot.sections, [.calibration, .colorGrading])
        XCTAssertEqual(snapshot.calibration?.fieldCount, 3, "只有非 0 的三个数走")

        let narrow = snapshot.filtered(to: [.calibration])
        XCTAssertEqual(narrow.calibration?.fieldCount, 3)
        XCTAssertNil(narrow.colorGrading, "只勾校准：色彩分级不许跟")

        let pasted = narrow.applied(to: .neutral)
        XCTAssertEqual(pasted.calibration, source.calibration)
        XCTAssertTrue(pasted.colorGrading.isIdentity)
        XCTAssertNotNil(pasted.calibration.matrix(), "粘过来的是能出矩阵的文档")
    }

    func testAPresetCarriesTheSevenNumbersAndRoundTrips() throws {
        var source = EditModel.neutral
        source.calibration = CalibrationGroup(shadowTint: 10, greenHue: -25, greenSat: 15)
        source.light.exposure = 1.5      // a neighbouring group the 校准 preset must not carry

        let preset = Preset(name: "校准 only", fromSections: [.calibration], of: source)
        XCTAssertTrue(preset.groups.contains(.calibration))
        XCTAssertEqual(preset.edit.calibration, source.calibration)
        XCTAssertEqual(preset.edit.light.exposure, 0, "只勾校准：曝光不许跟")

        let data = try JSONEncoder().encode(preset)
        let back = try JSONDecoder().decode(Preset.self, from: data)
        XCTAssertEqual(back.edit.calibration, source.calibration)
        XCTAssertTrue(back.groups.contains(.calibration))

        // 081: a **section-scoped** preset merges field by field, so it writes the three numbers it
        // carries and leaves the destination's untouched ones alone (the same rule that makes a
        // 白平衡-only preset keep the destination's 曝光). A redHue the preset never carried survives.
        var target = EditModel.neutral
        target.calibration = CalibrationGroup(redHue: -60)
        let applied = back.apply(to: target)
        XCTAssertEqual(applied.calibration.shadowTint, 10)
        XCTAssertEqual(applied.calibration.greenHue, -25)
        XCTAssertEqual(applied.calibration.greenSat, 15)
        XCTAssertEqual(applied.calibration.redHue, -60, "预设置没有的叶子不许被清掉")

        // A whole-group preset (no `sections`) replaces the group: all seven come from the preset.
        let whole = Preset(name: "whole", groups: [.calibration], edit: source)
        XCTAssertEqual(whole.apply(to: target).calibration, source.calibration)
    }

    // MARK: - 5. the pixel

    /// The panel's number reaches S1: a 0.18 grey stays a grey at exactly 0.18 (the matrix's white
    /// point), while a saturated patch moves by the amount the CPU matrix says it should.
    ///
    /// This is the same claim `CalibrationTests.testTheKernelAppliesTheCPUMatrixAndTint` makes for the
    /// engine; here it goes through the **card's own binding** — `session.applyEdit { $0[keyPath: …] }`
    /// — so a row wired to the wrong keyPath would show up as a grey that moved.
    func testTheRowBindingReachesS1() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let session = CatalogSession()
        for row in [InspectorView.calibrationRows[1], InspectorView.calibrationRows[6]] {
            session.applyEdit { $0[keyPath: row.keyPath] = 40 }
        }
        XCTAssertEqual(session.edit.calibration.redHue, 40)
        XCTAssertEqual(session.edit.calibration.blueSat, 40)

        let grey = try render(SIMD3(0.18, 0.18, 0.18), session.edit)
        let plain = try render(SIMD3(0.18, 0.18, 0.18), .neutral)
        for c in 0..<3 {
            XCTAssertEqual(grey[c], plain[c], accuracy: 1e-4, "0.18 灰在白点上，不许动")
        }
        let red = try render(SIMD3(1, 0, 0), session.edit)
        let redPlain = try render(SIMD3(1, 0, 0), .neutral)
        XCTAssertGreaterThan(abs(red.y - redPlain.y) + abs(red.z - redPlain.z), 0.05,
                             "红块必须被动到 —— 否则行没接到 S1")
    }

    // MARK: - helpers

    private func flat(_ v: SIMD3<Double>) -> LinearImage {
        let w = 8, h = 8
        var rgba = [Float16](repeating: 1, count: w * h * 4)
        for i in 0..<(w * h) {
            rgba[i * 4] = Float16(Float(v.x))
            rgba[i * 4 + 1] = Float16(Float(v.y))
            rgba[i * 4 + 2] = Float16(Float(v.z))
            rgba[i * 4 + 3] = 1
        }
        return LinearImage(width: w, height: h, rgba: rgba,
                           colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic-calibration")
    }

    private func render(_ v: SIMD3<Double>, _ edit: EditModel) throws -> SIMD3<Float> {
        let graph = try RenderGraph(input: RenderInput(image: flat(v), identity: "calibration-card"))
        let result = try graph.render(edit, options: RenderOptions(scale: 1, useCache: false,
                                                                  wantsPixels: true))
        let image = try XCTUnwrap(result.display)
        let o = ((image.height / 2) * image.width + image.width / 2) * 4
        return SIMD3(Float(image.rgba[o]), Float(image.rgba[o + 1]), Float(image.rgba[o + 2]))
    }

    private struct Hosted {
        let host: NSHostingView<InspectorView>
        let window: NSWindow

        var numberFieldIDs: Set<String> {
            Set(Self.all(NumberTextField.self, in: host)
                .compactMap { $0.accessibilityIdentifier() }
                .filter { !$0.isEmpty })
        }

        static func all<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
            var found: [T] = []
            if let hit = view as? T { found.append(hit) }
            for sub in view.subviews { found += all(type, in: sub) }
            return found
        }
    }

    private func host(workspace: InspectorWorkspace = .colour) -> Hosted {
        _ = NSApplication.shared
        let state = InspectorWorkspaceState(workspace)
        let host = NSHostingView(rootView: InspectorView(session: CatalogSession(), workspaces: state))
        host.frame = NSRect(x: 0, y: 0, width: 330, height: Self.panelHeight)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        return Hosted(host: host, window: window)
    }
}
