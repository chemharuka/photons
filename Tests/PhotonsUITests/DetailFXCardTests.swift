import XCTest
import AppKit
import SwiftUI
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 164 — the **new 细节 card**: 纹理 / 清晰度 (moved from 效果) and the two non-Bayer denoises.
///
/// 开发 holds the RAW decode amounts (031's four + 去摩尔纹); 效果 keeps only 去雾 + 颗粒. These tests
/// pin the card's contents, its reset scope, and that the two new sliders reach the document.
@MainActor
final class DetailFXCardTests: XCTestCase {

    func testTheCardIsBetweenCorrectionAndEffectsAndCarriesTheFourRows() {
        let titles = InspectorView.cardTitles(in: .adjust)
        let sections = InspectorView.sections(in: .adjust)
        let correction = try! XCTUnwrap(sections.firstIndex(of: .correction))
        let detailFX = try! XCTUnwrap(sections.firstIndex(of: .detailFX))
        let effects = try! XCTUnwrap(sections.firstIndex(of: .effects))
        XCTAssertEqual(detailFX, correction + 1)
        XCTAssertEqual(effects, detailFX + 1)
        XCTAssertEqual(Array(titles[(correction + 1)...(correction + 2)]), ["细节", "效果"])

        XCTAssertEqual(InspectorView.Section.detailFX.title, "细节")
        XCTAssertEqual(InspectorView.detailFXRows.map(\.title),
                       ["纹理", "清晰度", "非 Bayer 降噪", "非 Bayer 彩色降噪"])
        XCTAssertEqual(EditSnapshotSection.detailFX.title, "细节")
        XCTAssertEqual(EditSnapshotSection.detailFX.children.map(\.title),
                       ["纹理", "清晰度", "非 Bayer 降噪", "非 Bayer 彩色降噪"])
    }

    func testTheSpecOwnsExactlyThisCardsRows() {
        let spec = InspectorView.PanelCardSpec.detailFXCard
        XCTAssertEqual(spec.section, .detailFX)
        XCTAssertEqual(spec.group, .detailFX)
        XCTAssertEqual(spec.blocks.map(\.group), [.presence, .noise])
        XCTAssertEqual(spec.rows.map(\.keyPath), InspectorView.detailFXRows.map(\.keyPath))
        XCTAssertFalse(spec.rows.contains { $0.title == "去雾" }, "去雾属于效果卡")
        XCTAssertFalse(spec.rows.contains { $0.title == "暗角" }, "暗角属于校正卡")
        XCTAssertEqual(spec.accessibilityPrefix(for: spec.rows[0]), "inspector.detailFX")
    }

    func testTheTwoNonBayerRowsWriteTheDocumentAndResetTogether() {
        let session = CatalogSession()
        session.loadEditForAnchor()
        let resets = PanelResets(session: session)

        session.applyEdit {
            $0.effects.nonBayerLuminanceNR = 40
            $0.effects.nonBayerColorNR = 60
            $0.effects.texture = 12
            $0.effects.clarity = -8
            $0.effects.grain = 30
        }
        XCTAssertTrue(session.commitEdit(label: "拖动"))
        XCTAssertEqual(session.edit.effects.nonBayerLuminanceNR, 40)
        XCTAssertEqual(session.edit.effects.nonBayerColorNR, 60)
        let before = session.history.count

        XCTAssertTrue(resets.group(.detailFX))
        XCTAssertEqual(session.edit.effects.texture, 0)
        XCTAssertEqual(session.edit.effects.clarity, 0)
        XCTAssertEqual(session.edit.effects.nonBayerLuminanceNR, 0)
        XCTAssertEqual(session.edit.effects.nonBayerColorNR, 0)
        XCTAssertEqual(session.edit.effects.grain, 30, "颗粒属于效果卡，不被细节卡复位")
        XCTAssertEqual(session.history.count, before + 1)
        XCTAssertEqual(session.history.currentSnapshot?.label, "细节")
        XCTAssertFalse(resets.group(.detailFX), "已经在默认值就不再写")
    }

    func testTheCardRendersAndItsNumberFieldsCarryTheCardPrefix() throws {
        _ = NSApplication.shared
        let session = CatalogSession()
        let state = InspectorWorkspaceState(.adjust)
        let host = NSHostingView(rootView: InspectorView(session: session, workspaces: state))
        host.frame = NSRect(x: 0, y: 0, width: 330, height: 4200)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        defer { window.contentView = nil }

        let probe = try XCTUnwrap(Self.find(InspectorCardsProbe.self, in: host))
        XCTAssertTrue(probe.cardIDs.contains("detailFX"), "渲染树上没有 detailFX（\(probe.cardIDs)）")
        XCTAssertEqual(probe.cardTitles[probe.cardIDs.firstIndex(of: "detailFX")!], "细节")

        let ids = Set(Self.all(NumberTextField.self, in: host)
            .compactMap { $0.accessibilityIdentifier() }
            .filter { !$0.isEmpty })
        for row in InspectorView.detailFXRows {
            XCTAssertTrue(ids.contains("inspector.detailFX.\(row.title)"),
                          "「\(row.title)」没有画出来")
        }
    }

    func testTheTwoNonBayerRowsCopyAndPasteIndividually() {
        var source = EditModel.neutral
        source.effects.texture = 20
        source.effects.clarity = -10
        source.effects.nonBayerLuminanceNR = 40
        source.effects.nonBayerColorNR = 60
        source.effects.grain = 12

        let onlyLuma = CopySettingsSelection(sections: [.detailFX],
                                             children: [.nonBayerLuminance])
        let payload = EditSnapshot.capture(source).filtered(to: onlyLuma)
        XCTAssertEqual(payload.sections, [.detailFX])
        XCTAssertEqual(payload.fieldCount, 1, "只勾非 Bayer 降噪 = 一叶")
        XCTAssertEqual(payload.effects?.nonBayerLuminanceNR, 40)
        XCTAssertNil(payload.effects?.nonBayerColorNR)
        XCTAssertNil(payload.effects?.texture)
        XCTAssertNil(payload.effects?.grain, "颗粒属于效果卡，不在这个载荷里")

        var target = EditModel.neutral
        target.effects.texture = 5
        target.effects.nonBayerColorNR = 7
        let merged = payload.applied(to: target)
        XCTAssertEqual(merged.effects.nonBayerLuminanceNR, 40)
        XCTAssertEqual(merged.effects.nonBayerColorNR, 7, "目标自己的彩色降噪不动")
        XCTAssertEqual(merged.effects.texture, 5)
        XCTAssertEqual(merged.effects.grain, 0)

        let onlyChroma = CopySettingsSelection(sections: [.detailFX],
                                               children: [.nonBayerColor])
        let chromaPayload = EditSnapshot.capture(source).filtered(to: onlyChroma)
        XCTAssertEqual(chromaPayload.fieldCount, 1)
        XCTAssertEqual(chromaPayload.effects?.nonBayerColorNR, 60)
        XCTAssertNil(chromaPayload.effects?.nonBayerLuminanceNR)
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
}
