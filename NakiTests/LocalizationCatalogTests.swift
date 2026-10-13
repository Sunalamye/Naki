//
//  LocalizationCatalogTests.swift
//  NakiTests
//
//  `Localizable.xcstrings` 的三條不變式，與 `scripts/xcstrings-gate.py` 同規則：來源語系 zh-Hant、每 key 四語系齊、各語系占位符與 key 一致。
//

import XCTest

final class LocalizationCatalogTests: XCTestCase {

    private static let languages = ["en", "ja", "ko", "zh-Hans"]
    private static let placeholder = try! NSRegularExpression(pattern: "%(?:\\d+\\$)?(@|l{0,2}[dui]|f)")

    private func catalog() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("command/Resources/Localizable.xcstrings")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func placeholders(_ text: String) -> [String: Int] {
        let text = text.replacingOccurrences(of: "%%", with: "")
        return Self.placeholder.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .reduce(into: [:]) { counts, match in counts[(text as NSString).substring(with: match.range(at: 1)), default: 0] += 1 }
    }

    func testSourceLanguageIsTraditionalChinese() throws {
        XCTAssertEqual(try catalog()["sourceLanguage"] as? String, "zh-Hant")
    }

    func testEveryKeyIsTranslatedWithMatchingPlaceholders() throws {
        let strings = try XCTUnwrap(try catalog()["strings"] as? [String: [String: Any]])
        XCTAssertFalse(strings.isEmpty)
        for (key, entry) in strings {
            let localizations = entry["localizations"] as? [String: [String: Any]] ?? [:]
            for language in Self.languages {
                let unit = localizations[language]?["stringUnit"] as? [String: String]
                guard let value = unit?["value"], !value.isEmpty, unit?["state"] == "translated" else {
                    XCTFail("\(key) 缺 \(language)")
                    continue
                }
                XCTAssertEqual(placeholders(value), placeholders(key), "\(key) \(language) 占位符不符：\(value)")
            }
        }
    }
}
