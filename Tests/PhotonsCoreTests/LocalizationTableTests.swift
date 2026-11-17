import XCTest
@testable import PhotonsCore
import PhotonsLocalization

/// 本地化的**表级**验收（不需要 RAW，不打开窗口）。
///
/// 三条判据，全部是「错了一定要被发现」的那一类：
///
/// 1. **中文原文自洽**：`zh-Hans` 表的每一行必须是 `"X" = "X"` —— key 就是文案，
///    表里若出现 `"效果卡" = "特效卡"`，中文界面就会悄悄换词，而代码里读的 key 还是旧字。
/// 2. **英文表无空值**：`en` 表的每一行都必须有非空译文。空值会让英文界面显示出中文原文，
///    那是「漏译」，不是「回落到源语言」，必须红。
/// 3. **两张表 key 集合相同**：`en` 不许有 `zh-Hans` 里没有的 key（死条目），
///    `zh-Hans` 也不许有 `en` 里没有的 key（漏译）。
///
/// 缺 key 的**运行期**行为另有一条：`Loc.t("根本不存在的串")` 返回它自己（中文原文），
/// 永远不返回空串、不崩 —— 见 `testAnUnknownKeyFallsBackToItself`。
final class LocalizationTableTests: XCTestCase {

    private struct Table {
        let values: [String: String]
        init(_ language: String, file: StaticString = #filePath, line: UInt = #line) {
            guard let url = Loc.stringsURL(for: language),
                  let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8) else {
                XCTFail("找不到 \(language).lproj/Localizable.strings", file: file, line: line)
                values = [:]
                return
            }
            values = Self.parse(text)
        }

        /// `"key" = "value";` —— 只认这一种形态；两种语言的表都由 `extract_zh.py` 写出。
        static func parse(_ text: String) -> [String: String] {
            var out: [String: String] = [:]
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("\""), trimmed.hasSuffix(";"),
                      let equal = trimmed.range(of: "\" = \"") else { continue }
                let rawKey = String(trimmed[trimmed.index(after: trimmed.startIndex)..<equal.lowerBound])
                let rawValue = String(trimmed[equal.upperBound...].dropLast(2))
                out[unescape(rawKey)] = unescape(rawValue)
            }
            return out
        }

        static func unescape(_ s: String) -> String {
            var out = ""
            var iterator = Array(s).makeIterator()
            while let c = iterator.next() {
                guard c == "\\", let next = iterator.next() else { out.append(c); continue }
                switch next {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "\"": out.append("\"")
                case "\\": out.append("\\")
                default: out.append(c); out.append(next)
                }
            }
            return out
        }
    }

    private let chinese = Table("zh-Hans")
    private let english = Table("en")

    func testTheTablesAreNotEmpty() {
        XCTAssertGreaterThan(chinese.values.count, 500, "中文表读不到或有断行")
        XCTAssertGreaterThan(english.values.count, 500, "英文表读不到或有断行")
    }

    /// 判据 1 —— key 就是中文原文，值必须逐字相同。
    func testEveryChineseEntryIsItsOwnKey() {
        let drifted = chinese.values.filter { $0.key != $0.value }.map(\.key).sorted()
        XCTAssertEqual(drifted, [], "中文表里这些行的值与 key 不一致：\(drifted.prefix(8))")
    }

    /// 判据 2 —— 英文表不许有空值（空值 = 漏译，英文界面会显示中文）。
    func testNoEnglishEntryIsEmpty() {
        let empty = english.values.filter { $0.value.isEmpty }.map(\.key).sorted()
        XCTAssertEqual(empty, [], "英文表里这些 key 没有译文：\(empty.prefix(8))")
    }

    /// 判据 3 —— 两张表的 key 集合必须相同。
    func testTheTwoTablesHaveTheSameKeys() {
        let onlyChinese = Set(chinese.values.keys).subtracting(english.values.keys).sorted()
        let onlyEnglish = Set(english.values.keys).subtracting(chinese.values.keys).sorted()
        XCTAssertEqual(onlyChinese, [], "中文表有、英文表没有（漏译）：\(onlyChinese.prefix(8))")
        XCTAssertEqual(onlyEnglish, [], "英文表有、中文表没有（死条目）：\(onlyEnglish.prefix(8))")
    }

    /// 运行期回落：不存在的 key 原样返回，既不是空串也不是占位符。
    func testAnUnknownKeyFallsBackToItself() {
        let missing = "这一段翻译表里根本没有"
        XCTAssertEqual(Loc.t(missing), missing)
        XCTAssertEqual(Loc.t(missing, "a", "b"), missing, "无占位可代入时不该改动原文")
    }

    /// 两种代入方式的语义：`{n}` 位置代入 与 printf 说明符。
    func testPlaceholdersAndFormatSpecifiers() {
        XCTAssertEqual(Loc.t("{0} · {1}", "甲", "乙"), "甲 · 乙")
        XCTAssertEqual(Loc.t("{0} 与 {0}", "同", "弃"), "同 与 同", "同一占位可重复使用")
        XCTAssertEqual(Loc.f("%+.2f 档 (%.1f×)", 1.25, 2.0), "+1.25 档 (2.0×)")
    }

    /// 用户文本里形似占位符的内容不许被二次代入（`{1}` 出现在参数里）。
    func testUserTextResemblingAPlaceholderIsNotSubstitutedAgain() {
        XCTAssertEqual(Loc.t("值 {0}", "{1}"), "值 {1}")
    }

    /// 语言只有一个来源，且不在 `supportedLanguages` 之外的取值上崩。
    func testSupportedLanguagesAndDefault() {
        XCTAssertEqual(Loc.defaultLanguage, "zh-Hans")
        XCTAssertTrue(Loc.supportedLanguages.contains("zh-Hans"))
        XCTAssertTrue(Loc.supportedLanguages.contains("en"))
        XCTAssertEqual(Loc.localizedName(of: "zh-Hans"), "中文")
        XCTAssertEqual(Loc.localizedName(of: "en"), "English")
    }
}
