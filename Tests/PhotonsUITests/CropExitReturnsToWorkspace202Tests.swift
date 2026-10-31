import XCTest
import AppKit
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 202 ① — **leaving 裁切 hands the panel back to the workspace the user came from.**
///
/// The ask: 「裁剪+取消裁剪（按按钮/esc）后应该退回其他工作栏例如调整」 — and an entry from 色彩 comes
/// back to 色彩. All three doors (↵ 应用 / 完成, Esc, the card's 取消) leave the *mode*; the panel used
/// to follow only the confirmed one (123), and it forced 调整 even when the user had come from 色彩.
@MainActor
final class CropExitReturnsToWorkspace202Tests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-crop-202e-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    private enum Door: String, CaseIterable {
        case escape, cancelButton, apply

        var title: String {
            switch self {
            case .escape: return "Esc"
            case .cancelButton: return "取消按钮"
            case .apply: return "应用"
            }
        }
    }

    private func exit(_ door: Door, _ editor: EditorWindowController) {
        switch door {
        case .escape: editor.rootView.loupeController.cancelCropTool()
        case .cancelButton: editor.cancelCropAction(nil)      // 变换 card's 取消 / menu 取消裁切
        case .apply: editor.rootView.loupeController.applyCropTool()
        }
        CropUITestSupport.pump(0.08)
    }

    func testEveryExitDoorReturnsToThePreviousWorkspace() throws {
        let editor = try CropUITestSupport.makeEditor(in: workDir)
        defer { editor.window?.close() }
        let loupe = editor.rootView.loupeController
        let workspaces = editor.rootView.inspectorWorkspaces

        for entry in [InspectorWorkspace.adjust, .colour] {
            for door in Door.allCases {
                workspaces.select(entry)
                CropUITestSupport.pump(0.05)
                workspaces.select(.transform)
                CropUITestSupport.pump(0.08)
                XCTAssertTrue(loupe.isCropToolActive, "\(entry) \(door): 变换 did not open the frame")
                XCTAssertEqual(workspaces.selection, .transform)

                exit(door, editor)
                print("202 ① · enter \(entry.title) · exit \(door.title) → \(workspaces.selection.title) "
                      + "· crop active \(loupe.isCropToolActive)")
                XCTAssertFalse(loupe.isCropToolActive, "\(door): the tool is still on")
                XCTAssertEqual(workspaces.selection, entry,
                               "\(door) from \(entry.title) landed on \(workspaces.selection.title)")
                XCTAssertFalse(workspaces.selection.showsCropCard,
                               "\(door): the panel is still on the crop card")
            }
        }

        // The default: a panel that has only ever shown 调整 returns there.
        let fresh = InspectorWorkspaceState()
        XCTAssertEqual(fresh.lastNonCropWorkspace, .adjust)
        fresh.select(.transform)
        fresh.returnFromCrop()
        XCTAssertEqual(fresh.selection, .adjust, "the default has to be 调整/光")

        // …and the memory is only ever written by a **non-crop** workspace.
        fresh.select(.colour)
        fresh.select(.transform)
        XCTAssertEqual(fresh.lastNonCropWorkspace, .colour)
        fresh.returnFromCrop()
        XCTAssertEqual(fresh.selection, .colour)
    }
}
