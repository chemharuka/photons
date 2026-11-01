import XCTest
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// **214 — 卡片标题双击复位：作用域由卡片声明推导。**
///
/// 用户的原话（2026-11-01）：
///
///   > 双击裁切卡片会重置『裁切+旋转』，双击『旋转』卡片无法重置……双击归位由程序自动选择覆盖的
///   > key，不要写死。
///
/// 这些用例不点名任何字段路径以外的「实现」：它们遍历 `TransformCardSpec.all`，用声明本身算出
/// 应有的作用域，再和 `PanelResets.reset(fields:)` 实际写出来的文档逐字段比较。于是
///
///   · 卡片漏字段 / 多字段 → 一致性断言红；
///   · 卡片标题越界复位兄弟卡的字段 → 逐字段快照红；
///   · 某张卡根本复位不了 → 「灌非默认值再复位」红；
///   · 守卫本身被删掉 → 反向门（故意漏一个字段）红。
@MainActor
final class PanelResetScopeTests: XCTestCase {

    // MARK: - 1. 声明自身：非空、由 sections 推导、两卡互斥且覆盖全部字段

    func testEveryCardDeclarationIsNonEmptyAndMatchesItsSections() {
        let specs = TransformCardSpec.all
        XCTAssertEqual(specs.map(\.title),
                       [InspectorView.Section.crop.title, InspectorView.Section.angle.title],
                       "变换工作区的两张卡")
        XCTAssertEqual(TransformCardSpec.issues(in: specs), [],
                       "声明与 sections 不一致：\(TransformCardSpec.issues(in: specs))")

        for card in specs {
            XCTAssertFalse(card.fields.isEmpty, "\(card.title)：卡没有字段")
            XCTAssertFalse(card.sections.isEmpty, "\(card.title)：卡没有 section")
            XCTAssertEqual(card.fields, card.sectionFieldUnion,
                           "\(card.title)：fields 必须正好是 sections 的并集")
        }

        // 每张卡恰好只声明自己的字段；合起来正好是全部 geometry 字段（无遗漏、无重复）。
        for a in specs {
            for b in specs where a != b {
                XCTAssertTrue(a.fields.intersection(b.fields).isEmpty,
                              "\(a.title) 与 \(b.title) 都声明了 "
                              + "\(a.fields.intersection(b.fields).ordered.map(\.rawValue))")
            }
        }
        XCTAssertEqual(specs.reduce(GeometryFieldSet.empty) { $0.union($1.fields) },
                       GeometryFieldSet.all,
                       "所有卡合起来必须覆盖全部 geometry 字段")
        XCTAssertEqual(CropSection.displayOrder, specs.flatMap(\.sections),
                       "分区顺序由卡片声明推导")
    }

    // MARK: - 2 + 3. 每张卡：只复位自己的 fields，一条历史，⌘Z 一次回来

    func testEachCardTitleResetsExactlyItsOwnFieldsInOneSnapshot() {
        for card in TransformCardSpec.all {
            let session = CatalogSession()
            let resets = PanelResets(session: session)

            // 每个字段都推到非默认值：复位后自己的字段回默认，兄弟卡的字段逐字段一个不动
            // （这一条就是「互不越界」；像 turn() 那样的连带写会在这里红）。
            session.applyEdit { model in
                for field in GeometryField.allCases { Self.makeNonDefault(field, in: &model.geometry) }
            }
            XCTAssertTrue(session.commitEdit(label: "seed \(card.title)"),
                          "\(card.title)：种子文档没提交")

            let before = session.edit.geometry
            let historyBefore = session.history.count
            for field in card.fields.ordered {
                XCTAssertFalse(Self.isDefault(field, in: before),
                               "\(card.title)：种子里的 \(field.rawValue) 还是默认值，测不出复位")
            }

            XCTAssertTrue(resets.cropCard(card), "\(card.title)：双击卡标题必须真的写一条")
            let after = session.edit.geometry

            // 自己的字段：全部回 `GeometryGroup.identity` 的值。
            for field in card.fields.ordered {
                XCTAssertEqual(Self.value(field, in: after), Self.value(field, in: .identity),
                               "\(card.title)：\(field.rawValue) 没回默认")
            }
            // 兄弟卡的字段：逐字段一个不动（互不越界）。
            for sibling in TransformCardSpec.all where sibling != card {
                for field in sibling.fields.ordered {
                    XCTAssertEqual(Self.value(field, in: after), Self.value(field, in: before),
                                   "\(card.title) 越界改了 \(sibling.title) 的 \(field.rawValue)")
                }
            }

            XCTAssertEqual(session.history.count, historyBefore + 1,
                           "\(card.title)：一次复位 = 一条历史")
            XCTAssertEqual(session.history.currentSnapshot?.label, card.title,
                           "\(card.title)：undo 的标签是卡名")

            // 已经默认：不写空快照。
            XCTAssertFalse(resets.cropCard(card), "\(card.title)：已经归位就不写")
            XCTAssertEqual(session.history.count, historyBefore + 1,
                           "\(card.title)：第二次双击不该长历史")

            // ⌘Z 一次回到复位前。
            XCTAssertTrue(session.undo(), "\(card.title)：⌘Z 必须能撤回复位")
            for field in card.fields.ordered {
                XCTAssertEqual(Self.value(field, in: session.edit.geometry),
                               Self.value(field, in: before),
                               "\(card.title)：⌘Z 后 \(field.rawValue) 没回到复位前")
            }
            print("214 · \(card.title) · \(card.fields.ordered.map(\.rawValue)) · 一条历史 · ⌘Z 回滚")
        }
    }

    // MARK: - 3. 卡内 section 标题只影响自己的 fields

    func testEverySectionTitleResetsOnlyThatSectionsFields() {
        for section in CropSection.allCases {
            let session = CatalogSession()
            let resets = PanelResets(session: session)

            session.applyEdit { model in
                for field in GeometryField.allCases { Self.makeNonDefault(field, in: &model.geometry) }
            }
            XCTAssertTrue(session.commitEdit(label: "seed all"))

            let before = session.edit.geometry
            let historyBefore = session.history.count
            XCTAssertTrue(resets.cropSection(section), "「\(section.title)」必须真的写一条")
            let after = session.edit.geometry

            for field in section.fields.ordered {
                XCTAssertEqual(Self.value(field, in: after), Self.value(field, in: .identity),
                               "「\(section.title)」：\(field.rawValue) 没回默认")
            }
            for field in GeometryField.allCases where !section.fields.contains(field) {
                XCTAssertEqual(Self.value(field, in: after), Self.value(field, in: before),
                               "「\(section.title)」越界改了 \(field.rawValue)")
            }
            XCTAssertEqual(session.history.count, historyBefore + 1,
                           "「\(section.title)」：一次复位 = 一条历史")
        }
    }

    // MARK: - 4. 反向门：故意漏一个字段，守卫必须红

    func testTheGuardCatchesACardThatOmitsAField() {
        let card = TransformCardSpec.rotationCard
        let missing = GeometryField.flipVertical
        XCTAssertTrue(card.fields.contains(missing))

        let broken = TransformCardSpec(title: card.title,
                                       sections: card.sections,
                                       fields: card.fields.subtracting(missing))

        // 结构守卫：声明的 fields 与 sections 的并不一致 —— 正是测试 1 的断言会红。
        XCTAssertNotEqual(broken.fields, broken.sectionFieldUnion,
                          "反向门：漏字段必须能被 sectionFieldUnion 识破")
        XCTAssertFalse(TransformCardSpec.issues(in: [broken]).isEmpty,
                       "反向门：结构守卫必须报出漏字段的卡")
        XCTAssertEqual(TransformCardSpec.issues(in: TransformCardSpec.all), [],
                       "正向：真实声明必须干净")

        // 行为守卫：用漏了字段的声明复位，那个字段必须留在非默认值 —— 证明「漏了就真的没复位」。
        let session = CatalogSession()
        let resets = PanelResets(session: session)
        session.applyEdit { model in
            for field in card.fields.ordered { Self.makeNonDefault(field, in: &model.geometry) }
        }
        XCTAssertTrue(session.commitEdit(label: "seed"))
        XCTAssertTrue(resets.reset(fields: broken.fields, label: broken.title))
        XCTAssertFalse(Self.isDefault(missing, in: session.edit.geometry),
                       "反向门：漏掉的 \(missing.rawValue) 不该被复位（否则守具没牙齿）")
    }

    // MARK: - field snapshots

    /// One field's value as a comparable string — the tests only need equality between two snapshots.
    private static func value(_ field: GeometryField, in geometry: GeometryGroup) -> String {
        switch field {
        case .cropRect: return geometry.cropRect.keyString
        case .aspectLock: return String(describing: geometry.aspectLock)
        case .straightenDegrees: return String(format: "%.12f", geometry.straightenDegrees)
        case .quarterTurns: return "\(geometry.quarterTurns)"
        case .flipHorizontal: return "\(geometry.flipHorizontal)"
        case .flipVertical: return "\(geometry.flipVertical)"
        case .perspectiveVertical: return String(format: "%.12f", geometry.perspectiveVertical)
        case .perspectiveHorizontal: return String(format: "%.12f", geometry.perspectiveHorizontal)
        }
    }

    private static func isDefault(_ field: GeometryField, in geometry: GeometryGroup) -> Bool {
        value(field, in: geometry) == value(field, in: .identity)
    }

    /// A legal non-default value for one field, so "the reset did something" is provable.
    private static func makeNonDefault(_ field: GeometryField, in geometry: inout GeometryGroup) {
        switch field {
        case .cropRect:
            geometry.cropRect = CropRect(left: 0.1, top: 0.2, right: 0.8, bottom: 0.9)
        case .aspectLock:
            geometry.aspectLock = .square
        case .straightenDegrees:
            geometry.rotationDegrees = 6.5
        case .quarterTurns:
            geometry.quarterTurns = 1
        case .flipHorizontal:
            geometry.flipHorizontal = true
        case .flipVertical:
            geometry.flipVertical = true
        case .perspectiveVertical:
            geometry.perspectiveVertical = 12
        case .perspectiveHorizontal:
            geometry.perspectiveHorizontal = -9
        }
    }
}
