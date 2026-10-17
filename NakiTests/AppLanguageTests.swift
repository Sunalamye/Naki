//
//  AppLanguageTests.swift
//  NakiTests
//
//  App 內語言：設定的預設與持久化、L10n helper 依 locale 取翻譯、AutoPlayMode 的顯示名不動 rawValue。
//

import SwiftUI
import XCTest

@testable import Naki

@MainActor
final class AppLanguageTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "naki.tests.applanguage.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        removeIsolatedSuite(suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testDefaultIsSystemWithNoLocaleOverride() {
        XCTAssertEqual(SettingsStore.loadAppLanguage(from: defaults), .system)
        XCTAssertNil(AppLanguage.system.locale)
    }

    func testSaveThenLoadRoundTripsEveryLanguage() {
        for language in AppLanguage.allCases {
            SettingsStore.saveAppLanguage(language, to: defaults)
            XCTAssertEqual(SettingsStore.loadAppLanguage(from: defaults), language)
        }
    }

    func testInvalidStoredValueFallsBackToSystem() {
        defaults.set("klingon", forKey: SettingsStore.appLanguageKey)
        XCTAssertEqual(SettingsStore.loadAppLanguage(from: defaults), .system)
    }

    func testStoreWritesThroughToInjectedDefaults() {
        let store = SettingsStore(defaults: defaults)
        store.appLanguage = .ja
        XCTAssertEqual(store.locale?.identifier, "ja")
        XCTAssertEqual(SettingsStore.loadAppLanguage(from: defaults), .ja)
    }

    func testTextFollowsLocale() {
        XCTAssertEqual(L10n.text("關閉", locale: Locale(identifier: "en")), "Off")
        XCTAssertEqual(L10n.text("關閉", locale: Locale(identifier: "ja")), "オフ")
        XCTAssertEqual(L10n.text("關閉", locale: Locale(identifier: "ko")), "끄기")
        XCTAssertEqual(L10n.text("關閉", locale: Locale(identifier: "zh-Hans")), "关闭")
        XCTAssertEqual(L10n.text("關閉", locale: Locale(identifier: "zh-Hant")), "關閉")
    }

    func testAutoPlayModeRawValuesStayPersistedChinese() {
        XCTAssertEqual(AutoPlayMode.allCases.map(\.rawValue), ["關閉", "推薦", "自動", "全自動"])
    }
}

#if os(macOS)
extension AppLanguageTests {

    /// `Text("繁中 key")` 吃 environment 的 locale：與直接顯示翻譯字面值（catalog 查無的 key 原樣顯示）的像素逐位相同；不用 `verbatim`，因為本地化的 Text 會帶語言屬性、CJK 字形不同，才算真的切了語言。
    func testTextRespectsEnvironmentLocale() {
        func pixels<V: View>(_ view: V) -> Data? {
            let renderer = ImageRenderer(content: view.font(.largeTitle))
            renderer.scale = 1
            return renderer.nsImage?.tiffRepresentation
        }
        func localized(_ identifier: String) -> Data? {
            pixels(Text("關閉").environment(\.locale, Locale(identifier: identifier)))
        }
        for (identifier, expected) in [("en", "Off"), ("ko", "끄기"), ("zh-Hans", "关闭"), ("zh-Hant", "關閉")] {
            let literal = pixels(Text(LocalizedStringKey(expected)).environment(\.locale, Locale(identifier: identifier)))
            XCTAssertNotNil(literal)
            XCTAssertEqual(localized(identifier), literal, identifier)
        }
        let others = ["en", "ko", "zh-Hans", "zh-Hant"].map(localized)
        XCTAssertFalse(others.contains(localized("ja")), "ja 要渲染成有別於其他語言的字")
        XCTAssertNotEqual(pixels(Text(verbatim: "Off")), pixels(Text(verbatim: "關閉")), "sanity：不同字要渲染成不同像素")
    }
}
#endif