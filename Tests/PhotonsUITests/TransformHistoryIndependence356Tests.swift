import XCTest
import AppKit
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// **356 — 变换的行为不许取决于「历史里有没有东西」。**
///
/// 用户口径：「只要历史记录中存在变换的某些调整（清除历史记录后正常），变换的行为就有问题，
/// 确认是否有判据用的是历史记录或者双击归 0 后没有正确复位。」
///
/// 「历史里有没有东西」在这套代码里等价于 `session.isToolSessionActive`（`CatalogSession:1167`
/// → `history.isSessionActive`），而 `CropToolController` 曾用 6 处分支读它
/// （`:607 / :821 / :1298 / :1398 / :1508 / :1536`）。一个没被关掉的工具会话——滑杆拖完没 end，
/// ⌘Z / 双击归 0 之后残留——就让后续每个入口走另一条路：合并进旧行、被 `endToolSession` 提前
/// 结掉、或者写的行是 `base → edit` 而不是这一次的值。行的内容变了，⌘Z 还回来的文档就变了，
/// 于是「几何结果取决于历史」。
///
/// 本文件钉住的是**不变量**，不是某一条路径：
///   ① 六个入口 × 三种前置，几何逐字段相同；
///   ② 双击归 0 之后与「新建一份同样文档」逐字段相等；
///   ③ 六个入口执行后都没有残留会话；
///   ④ 45° 满幅图勾「不出像素」的内切，三种前置逐字节相同；
///   ⑤ (a) 与 (b) 同拖 20 tick，落点框逐值相同。
///
/// 前置的设计（这是能比较的前提，不是回避）：
///   · 三种前置的**文档与草稿完全相同**，`透视 +40` 是三者共同的 tip；
///   · (a) 空历史：baseline + 这一行；
///   · (b) 有变换历史且会话开着：tip 之下多一行 `透视 −12`，**并且**在 tip 之后留下一个没关掉
///     的会话（`beginToolSession` 之后不再 end）——用户说的那个泄漏状态；
///   · (c) 10 条历史：tip 之下多 10 行曝光。
/// 差值只在历史深度与会话状态上，所以「几何逐字段相同」量的正是本单要的那条不变量。
///
/// 入口走的是每个门自己的动词：`apply()`、变换卡滑杆的 `applyEdit`+`commitEdit`、
/// `setAngle`+`commitStraighten`、`commitGeometryCommand`（双击/分区复位的唯一写入口）、
/// `undo()`、`pasteSettings()`。
///
/// Run with `--filter "Crop|Perspective|Straighten|GuideLine|Keystone|CenterOnEdit|TransformPanel"`.
/// Every case name carries one of those tokens (`TransformPanel` / `Perspective` / `Crop` /
/// `Straighten`) on purpose: the wide filter is the only one this suite's topics are reachable
/// through, and a filter that matches nothing reports `Executed 0` — green without measuring.
@MainActor
final class TransformHistoryIndependence356Tests: XCTestCase {

    private static let source = ImageSize(width: 3000, height: 2000)
    private static let viewport = ImageSize(width: 1200, height: 800)
    /// `CropToolController` holds its session **weakly** (the window owns it in the app), so every
    /// fixture here keeps the `Tool` — and therefore the session — alive for the length of the test.
    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-356-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }
    /// The keystone every precondition carries as its tip — big enough that the photo quad moves.
    private static let tip: Double = 40
    private static let inner = CropRect(left: 0.12, top: 0.18, right: 0.82, bottom: 0.71)

    // MARK: - the value compared

    /// Everything a user could call 「几何结果」: the document's three numbers, the space, the
    /// preference, the draft's rect and its shadow fields, and the two derived readers. `rows` is
    /// carried for the printed report only — it *must* differ between the preconditions, and it is
    /// not part of the equality.
    private struct Geometry: Equatable, CustomStringConvertible {
        var v: Double
        var h: Double
        var s: Double
        var cropSpace: Int
        var staysInside: Bool
        var crop: CropRect
        var effective: CropRect
        var liveV: Double?
        var liveSpace: Int
        var draftV: Double
        var draftH: Double
        var draftS: Double
        var draftSpace: Int
        var exceeds: Bool
        /// For the printed report only — it **must** differ between the preconditions, so it is
        /// deliberately not part of `==`.
        var rows: Int

        static func == (lhs: Geometry, rhs: Geometry) -> Bool {
            lhs.v == rhs.v && lhs.h == rhs.h && lhs.s == rhs.s
                && lhs.cropSpace == rhs.cropSpace && lhs.staysInside == rhs.staysInside
                && lhs.crop == rhs.crop && lhs.effective == rhs.effective
                && lhs.liveV == rhs.liveV && lhs.liveSpace == rhs.liveSpace
                && lhs.draftV == rhs.draftV && lhs.draftH == rhs.draftH
                && lhs.draftS == rhs.draftS && lhs.draftSpace == rhs.draftSpace
                && lhs.exceeds == rhs.exceeds
        }

        var description: String {
            String(format: "v %+.4f · h %+.4f · s %+.4f · space %d · 不出像素 %@ · live %@ · "
                   + "liveSpace %d · draft (%+.4f, %+.4f, %+.4f, cs %d) · 出界 %@ · "
                   + "框 (%.9f, %.9f)-(%.9f, %.9f) · eff (%.9f, %.9f)-(%.9f, %.9f) · rows %d",
                   v, h, s, cropSpace, staysInside ? "on" : "off",
                   liveV.map { String(format: "%+.4f", $0) } ?? "nil", liveSpace,
                   draftV, draftH, draftS, draftSpace, exceeds ? "是" : "否",
                   crop.left, crop.top, crop.right, crop.bottom,
                   effective.left, effective.top, effective.right, effective.bottom, rows)
        }
    }

    private func geometry(_ tool: Tool) -> Geometry {
        let c = tool.controller
        let d = c.draft
        return Geometry(v: tool.session.edit.geometry.perspectiveVertical,
                        h: tool.session.edit.geometry.perspectiveHorizontal,
                        s: tool.session.edit.geometry.straightenDegrees,
                        cropSpace: tool.session.edit.geometry.cropSpace.rawValue,
                        staysInside: c.cropStaysInsidePixels,
                        crop: d.crop,
                        effective: c.effectiveCrop(),
                        liveV: c.livePerspective?.vertical,
                        liveSpace: c.liveCropSpace.rawValue,
                        draftV: d.perspectiveVertical,
                        draftH: d.perspectiveHorizontal,
                        draftS: d.straighten,
                        draftSpace: d.cropSpace.rawValue,
                        exceeds: c.frameExceedsPicture(),
                        rows: tool.session.history.snapshots.count)
    }

    // MARK: - ① 六个入口 × 三种前置

    func testOneTheSixTransformPanelEntriesGiveTheSameGeometryFromAllThreePreconditions() throws {
        var table: [Entry: [Precondition: Geometry]] = [:]
        for entry in Entry.allCases {
            for pre in Precondition.allCases {
                let tool = try makeTool(pre, for: entry)
                let before = geometry(tool)
                run(entry, on: tool)
                let after = geometry(tool)
                table[entry, default: [:]][pre] = after
                print("356 ① · \(entry.rawValue.padding(toLength: 12, withPad: " ", startingAt: 0))"
                      + "\(pre.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0)) · \(after)")
                _ = before
            }
        }

        for entry in Entry.allCases {
            guard let row = table[entry], let a = row[.empty], let b = row[.oneRowSessionOpen],
                  let c = row[.tenRows] else {
                return XCTFail("356 ① · \(entry.rawValue)：三种前置没跑全")
            }
            XCTAssertEqual(a, b, "356 ① · \(entry.rawValue)：空历史 与 有历史且会话开着 的几何不同")
            XCTAssertEqual(a, c, "356 ① · \(entry.rawValue)：空历史 与 10 条历史 的几何不同")
            XCTAssertEqual(b, c, "356 ① · \(entry.rawValue)：有历史且会话开着 与 10 条历史 的几何不同")
        }
    }

    private enum Precondition: String, CaseIterable {
        case empty = "空历史"
        case oneRowSessionOpen = "会话开着"
        case tenRows = "10条历史"
    }

    private enum Entry: String, CaseIterable {
        case apply = "裁切应用"
        case perspective = "透视滑杆"
        case rotation = "旋转滑杆"
        case reset = "双击归0"
        case undo = "⌘Z"
        case paste = "粘贴设置"
    }

    // MARK: - ② 复位 = 新建同参文档

    func testTwoThePerspectiveResetEqualsAFreshDocumentFieldForField() throws {
        let tool = try makeTool(.oneRowSessionOpen, for: .reset)
        XCTAssertEqual(tool.session.edit.geometry.perspectiveVertical, Self.tip, accuracy: 1e-12)
        XCTAssertEqual(tool.session.history.snapshots.count, 4, "① (b) 前置：tip 之下再多一行变换")

        run(.reset, on: tool)
        let reset = geometry(tool)
        let fresh = try freshGeometry()
        print("356 ② · 复位后（会话曾开着）· \(reset)")
        print("356 ② · 新建同参文档       · \(fresh)")

        // 逐字段，而不是「差不多」：文档三数、空间、偏好在 `Geometry` 里，草稿的四个影子字段也在。
        XCTAssertEqual(reset.v, 0, accuracy: 1e-12, "复位没写进文档")
        XCTAssertEqual(reset.draftV, 0, accuracy: 1e-12, "复位后 draft 的透视还是 \(reset.draftV)")
        XCTAssertNil(reset.liveV, "复位后 live 仍非 nil（读的是 draft 的旧拷贝）")
        XCTAssertEqual(reset.draftSpace, fresh.draftSpace, "复位后 draft 的空间不是新文档的空间")
        XCTAssertEqual(reset.liveSpace, fresh.liveSpace)
        XCTAssertEqual(reset.exceeds, fresh.exceeds)
        XCTAssertEqual(reset.effective, fresh.effective)
        XCTAssertEqual(reset, fresh, "复位后与新建的 perspective = 0 文档不逐字段相等")
    }

    // MARK: - ③ 没有残留会话

    func testThreeNoCropEntryLeavesAToolSessionOpen() throws {
        for entry in Entry.allCases {
            // (b) 是唯一会带着会话进门的前置 —— 也就是用户报的那个状态。
            let tool = try makeTool(.oneRowSessionOpen, for: entry)
            XCTAssertTrue(tool.session.isToolSessionActive,
                          "356 ③ · \(entry.rawValue)：前置没把会话留在开着，量不出残留")
            run(entry, on: tool)
            print("356 ③ · \(entry.rawValue.padding(toLength: 12, withPad: " ", startingAt: 0))"
                  + " · 执行后 isToolSessionActive = \(tool.session.isToolSessionActive)")
            XCTAssertFalse(tool.session.isToolSessionActive,
                           "356 ③ · \(entry.rawValue)：执行后还留着一个会话")
        }
    }

    // MARK: - ④ 45° 满幅图的内切，三种前置逐字节相同

    func testFourTheStraightenInscriptionOfAFullFrameAt45IsByteIdenticalInAllThreePreconditions() throws {
        var hashes: [Precondition: String] = [:]
        for pre in Precondition.allCases {
            let tool = try makeTool(pre, for: .rotation)
            _ = tool.controller.setCropStaysInsidePixels(false)
            tool.controller.setAngle(uiValue: 45)
            tool.session.applyEdit { $0.geometry.rotationDegrees = 45 }
            tool.session.commitEdit(label: "转动", coalesce: false)
            tool.controller.adoptDocumentKeystone()
            tool.controller.draft.crop = .full
            XCTAssertTrue(tool.controller.setCropStaysInsidePixels(true),
                          "356 ④ · \(pre.rawValue)：45° 满幅图没有触发内切 —— ④ 没有判别力")
            let rect = tool.controller.draft.crop
            XCTAssertNotEqual(rect, .full, "356 ④ · \(pre.rawValue)：内切后还是满幅")
            let bytes = Self.bytes(of: rect)
            hashes[pre] = bytes
            print("356 ④ · \(pre.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0))"
                  + " · sha \(bytes) · 框 " + Self.text(rect))
        }
        let distinct = Set(hashes.values)
        XCTAssertEqual(distinct.count, 1,
                       "356 ④：三种前置的内切不是逐字节相同 —— \(hashes)")
    }

    // MARK: - ⑤ 同一条角拖 20 tick，(a) 与 (b) 落点相同

    func testFiveTwentyCropTicksOfTheSameDragLandOnTheSameRectFromBothPreconditions() throws {
        var landed: [Precondition: CropRect] = [:]
        for pre in [Precondition.empty, .oneRowSessionOpen] {
            let tool = try makeTool(pre, for: .apply)
            let controller = tool.controller
            controller.draft.crop = CropRect(left: 0.20, top: 0.20, right: 0.60, bottom: 0.60)
            controller.setAngle(uiValue: 0)
            controller.adoptDocumentKeystone()
            let map = mapping(degrees: 0)
            // 按下框内，向右下拖 20 tick —— 每 tick 都走 app 的两步（drag + clampToView）。
            XCTAssertTrue(controller.beginDrag(atViewPoint: viewPoint(normalized:
                                                    NormalizedPoint(0.40, 0.40), mapping: map,
                                                    degrees: 0),
                                               mapping: map, source: Self.source))
            XCTAssertEqual(controller.lastHandle, .inside)
            for i in 1...20 {
                let t = 0.40 + 0.004 * Double(i)
                controller.continueDrag(atViewPoint: viewPoint(normalized: NormalizedPoint(t, t),
                                                               mapping: map, degrees: 0),
                                        mapping: map, source: Self.source)
                _ = controller.clampToView(mapping: map, source: Self.source)
            }
            let rect = controller.draft.crop
            controller.endDrag()
            landed[pre] = rect
            print("356 ⑤ · \(pre.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0))"
                  + " · 20 tick 落点 " + Self.text(rect)
                  + " · 会话 \(tool.session.isToolSessionActive)")
            XCTAssertFalse(tool.session.isToolSessionActive, "356 ⑤ · 拖完还留着会话")
        }
        guard let a = landed[.empty], let b = landed[.oneRowSessionOpen] else {
            return XCTFail("356 ⑤：两种前置没跑全")
        }
        for (lhs, rhs, name) in [(a.left, b.left, "left"), (a.top, b.top, "top"),
                                 (a.right, b.right, "right"), (a.bottom, b.bottom, "bottom")] {
            XCTAssertEqual(lhs, rhs, accuracy: 1e-9, "356 ⑤：\(name) 落点不同")
        }
    }

    // MARK: - fixtures

    private struct Tool {
        let session: CatalogSession
        let controller: CropToolController
    }

    /// The three preconditions, built so the **document and the draft are identical** and only the
    /// history depth and the session differ. See the file's header for why the tip is shared.
    private func makeTool(_ pre: Precondition, for entry: Entry) throws -> Tool {
        let (session, _) = try CropUITestSupport.makeSession(in: workDir,
                                                            width: Self.source.width,
                                                            height: Self.source.height)

        // …history the entry must not be able to see, **below the common row**.
        switch pre {
        case .empty:
            break
        case .oneRowSessionOpen:
            session.applyEdit { $0.geometry.perspectiveVertical = -12 }
            session.commitEdit(label: "透视", coalesce: false)
            // …and back to 0 **without committing**, so the common row below carries the same
            // document as (a)'s and (c)'s. The extra row is the *only* difference this precondition
            // is allowed to make.
            session.applyEdit { $0.geometry.perspectiveVertical = 0 }
        case .tenRows:
            for i in 1...10 {
                session.applyEdit { $0.light.exposure = 0.1 * Double(i) }
                session.commitEdit(label: "曝光", coalesce: false)
            }
        }

        // …the **common row**: whatever the history holds, the row directly under the tip is the
        // same one, so ⌘Z from the tip lands on the same document in all three preconditions. That is
        // what makes ①'s ⌘Z row a comparison instead of a tautology.
        session.applyEdit { $0.light.exposure = 0.4 }
        session.commitEdit(label: "曝光", coalesce: false)

        // …the shared tip: a transform row that is the last thing every precondition did.
        session.applyEdit { $0.geometry.perspectiveVertical = Self.tip }
        session.commitEdit(label: "透视", coalesce: false)

        // 粘贴 needs a clipboard that is *not* what the document already holds, identically in all
        // three preconditions: copy at +40, then flatten the document, so ⌘V puts the 40 back.
        if entry == .paste {
            _ = session.copySettingsFromAnchor()
            session.applyEdit { $0.geometry.perspectiveVertical = 0 }
            session.commitEdit(label: "透视", coalesce: false)
        }

        let controller = CropToolController(session: session, defaults: try defaults())
        XCTAssertTrue(controller.begin(), "裁切 mode 没打开")
        controller.adoptDocumentKeystone()

        // …and the leak: a gesture that never ended. This is the state the user reported.
        if pre == .oneRowSessionOpen {
            session.beginToolSession("裁切", label: "裁切与旋转")
        }
        return Tool(session: session, controller: controller)
    }

    /// A brand-new library whose document carries the same numbers — the ② referent.
    private func freshGeometry() throws -> Geometry {
        let (session, _) = try CropUITestSupport.makeSession(in: workDir,
                                                            width: Self.source.width,
                                                            height: Self.source.height)
        let controller = CropToolController(session: session, defaults: try defaults())
        XCTAssertTrue(controller.begin())
        controller.adoptDocumentKeystone()
        return geometry(Tool(session: session, controller: controller))
    }

    /// Each entry spells the verb its own door uses.
    private func run(_ entry: Entry, on tool: Tool) {
        let session = tool.session
        let controller = tool.controller
        switch entry {
        case .apply:
            controller.draft.crop = Self.inner
            _ = controller.apply()
        case .perspective:
            // `TransformPanel` 的滑杆：按下 begin、每 tick 一次 `applyEdit`、松手 end（一行）。
            session.beginToolGesture(tool: "透视", label: "透视")
            for value in stride(from: Self.tip, through: 18, by: -6) {
                session.applyEdit { $0.geometry.perspectiveVertical = value }
            }
            session.endToolGesture(label: "透视", coalesce: true)
        case .rotation:
            // 校正卡的拉直行：按下 begin、每 tick 一次 `setAngle`、松手 `commitStraighten`。
            session.beginToolGesture(tool: "裁切", label: "转动")
            for value in stride(from: 0.0, through: 6, by: 1) {
                controller.setAngle(uiValue: value)
            }
            _ = controller.commitStraighten()
        case .reset:
            // 双击「垂直透视」= 一行回 0，走的是复位唯一的写入口。
            session.commitGeometryCommand(label: "垂直透视") { geometry in
                guard geometry.perspectiveVertical != 0 else { return false }
                geometry.perspectiveVertical = 0
                return true
            }
        case .undo:
            XCTAssertTrue(session.undo(), "356 · ⌘Z 没执行")
        case .paste:
            _ = session.pasteSettings()
        }
        // The turn the loupe runs after every document write (`syncCropOverlay`).
        controller.adoptDocumentKeystone()
    }

    // MARK: - the drag harness (the same two steps the app runs per tick)

    private func mapping(degrees: Double) -> LoupeMapping {
        LoupeFraming(viewport: Self.viewport,
                     sourceWidth: Double(Self.source.width),
                     sourceHeight: Double(Self.source.height),
                     crop: .full,
                     straightenDegrees: degrees).mapping(of: LoupeViewState(mode: .fit, zoom: 1))
    }

    /// The exact inverse of `CropToolController.normalized` at the draft's angle.
    private func viewPoint(normalized point: NormalizedPoint, mapping: LoupeMapping,
                           degrees: Double) -> CGPoint {
        let w = Double(Self.source.width), h = Double(Self.source.height)
        let rotation = CropGeometry.RotationMatrix(degrees: degrees)
        let turned = rotation.invert(x: (point.x - 0.5) * w, y: (point.y - 0.5) * h)
        let p = mapping.frameView(frameX: w / 2 + turned.x, frameY: h / 2 + turned.y)
        return CGPoint(x: p.x, y: p.y)
    }

    // MARK: - misc

    /// A rect as the bytes a renderer would see: `1e−9` of agreement is not what ④ asks for.
    private static func bytes(of rect: CropRect) -> String {
        let values = [rect.left, rect.top, rect.right, rect.bottom]
        return values.withUnsafeBytes { raw in
            (0..<raw.count).map { String(format: "%02x", raw[$0]) }.joined()
        }
    }

    private static func text(_ r: CropRect) -> String {
        String(format: "(%.9f, %.9f)-(%.9f, %.9f)", r.left, r.top, r.right, r.bottom)
    }

    private func workDirectory() throws -> URL {
        workDir
    }

    private func defaults() throws -> UserDefaults {
        let suite = "photons.356.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }
}
