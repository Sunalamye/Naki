//
//  SettingsStoreTests.swift
//  NakiTests
//
//  `SettingsStore(defaults:)` 的注入縫：實例的每一次讀寫都落在注入的 suite，不碰 `.standard`。
//

import XCTest

@testable import Naki

@MainActor
final class SettingsStoreInjectionTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "naki.tests.settingsstore.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    private static let pluginKey = SettingsStore.pluginSettingKey("p", "k")

    private static let allKeys = [
        SettingsStore.appLanguageKey, SettingsStore.keepAliveInBackgroundKey,
        SettingsStore.autoCheckUpdateKey, SettingsStore.lastUpdateCheckKey,
        SettingsStore.skippedUpdateVersionKey, SettingsStore.enabledPluginIdsKey,
        SettingsStore.pluginsMayModifyOutboundKey, pluginKey,
        SettingsStore.majsoulServerKey, SettingsStore.majsoulUserAgentKey,
        SettingsStore.majsoulExtraHeadersKey, SettingsStore.pinMajsoulServerKey,
        SettingsStore.showStatusBarKey, SettingsStore.actionDelaySecondsKey,
        SettingsStore.fullAutoPrefersSanmaKey, SettingsStore.fullAutoRoomPreferenceKey,
        SettingsStore.cloudEnabledKey, SettingsStore.cloudBaseURLKey,
        SettingsStore.cloudModel4PKey, SettingsStore.cloudModel3PKey,
    ]

    private func standardSnapshot() -> [String] {
        Self.allKeys.map { String(describing: UserDefaults.standard.object(forKey: $0)) }
    }

    /// 每個持久化屬性都改成「與預設不同」的值，寫入必須全落在注入的 suite，`.standard` 一個 key 都不變。
    func testInstanceUsesInjectedSuite() {
        let before = standardSnapshot()
        let store = SettingsStore(defaults: defaults)
        let stamp = Date(timeIntervalSince1970: 1_000)

        store.appLanguage = .ja
        store.keepAliveInBackground = false
        store.autoCheckUpdate = false
        store.lastUpdateCheck = stamp
        store.skippedUpdateVersion = "1.2.3"
        store.enabledPluginIds = ["a", "b"]
        store.pluginsMayModifyOutbound = true
        store.setPluginSettingValue(pluginId: "p", key: "k", value: 2.5)
        store.majsoulServer = .jp
        store.majsoulUserAgent = "UA"
        store.majsoulExtraHeaders = ["X": "1"]
        store.pinMajsoulServer = true
        store.showStatusBar = true
        store.actionDelaySeconds = 2.0
        store.fullAutoPrefersSanma = true
        store.fullAutoRoomPreference = .highest
        store.cloudInferenceEnabled = true
        store.cloudServerURL = "https://example.invalid"
        store.cloudModel4P = "m4"
        store.cloudModel3P = "m3"

        XCTAssertEqual(defaults.string(forKey: SettingsStore.appLanguageKey), "ja")
        XCTAssertEqual(defaults.object(forKey: SettingsStore.keepAliveInBackgroundKey) as? Bool, false)
        XCTAssertEqual(defaults.object(forKey: SettingsStore.autoCheckUpdateKey) as? Bool, false)
        XCTAssertEqual(defaults.object(forKey: SettingsStore.lastUpdateCheckKey) as? Date, stamp)
        XCTAssertEqual(defaults.string(forKey: SettingsStore.skippedUpdateVersionKey), "1.2.3")
        XCTAssertEqual(defaults.stringArray(forKey: SettingsStore.enabledPluginIdsKey), ["a", "b"])
        XCTAssertEqual(defaults.object(forKey: SettingsStore.pluginsMayModifyOutboundKey) as? Bool, true)
        XCTAssertEqual(defaults.object(forKey: Self.pluginKey) as? Double, 2.5)
        XCTAssertEqual(defaults.string(forKey: SettingsStore.majsoulServerKey), "jp")
        XCTAssertEqual(defaults.string(forKey: SettingsStore.majsoulUserAgentKey), "UA")
        XCTAssertEqual(defaults.dictionary(forKey: SettingsStore.majsoulExtraHeadersKey) as? [String: String], ["X": "1"])
        XCTAssertEqual(defaults.object(forKey: SettingsStore.pinMajsoulServerKey) as? Bool, true)
        XCTAssertEqual(defaults.object(forKey: SettingsStore.showStatusBarKey) as? Bool, true)
        XCTAssertEqual(defaults.object(forKey: SettingsStore.actionDelaySecondsKey) as? Double, 2.0)
        XCTAssertEqual(defaults.object(forKey: SettingsStore.fullAutoPrefersSanmaKey) as? Bool, true)
        XCTAssertEqual(defaults.string(forKey: SettingsStore.fullAutoRoomPreferenceKey), "highest")
        XCTAssertEqual(defaults.object(forKey: SettingsStore.cloudEnabledKey) as? Bool, true)
        XCTAssertEqual(defaults.string(forKey: SettingsStore.cloudBaseURLKey), "https://example.invalid")
        XCTAssertEqual(defaults.string(forKey: SettingsStore.cloudModel4PKey), "m4")
        XCTAssertEqual(defaults.string(forKey: SettingsStore.cloudModel3PKey), "m3")
        XCTAssertEqual(standardSnapshot(), before, "寫入不得外漏到 .standard")
    }

    /// 初始值只讀注入的 suite：suite 有值就讀到，空 suite 回各自的預設。
    func testInstanceReadsInitialValuesFromInjectedSuite() {
        let empty = SettingsStore(defaults: defaults)
        XCTAssertEqual(Self.allKeys.filter { defaults.object(forKey: $0) != nil }, [], "建構不得寫入 suite")
        XCTAssertEqual(empty.appLanguage, .system)
        XCTAssertTrue(empty.keepAliveInBackground)
        XCTAssertTrue(empty.autoCheckUpdate)
        XCTAssertNil(empty.lastUpdateCheck)
        XCTAssertNil(empty.skippedUpdateVersion)
        XCTAssertTrue(empty.enabledPluginIds.isEmpty)
        XCTAssertFalse(empty.pluginsMayModifyOutbound)
        XCTAssertEqual(empty.majsoulServer, .cn)
        XCTAssertEqual(empty.majsoulUserAgent, "")
        XCTAssertTrue(empty.majsoulExtraHeaders.isEmpty)
        XCTAssertFalse(empty.pinMajsoulServer)
        XCTAssertFalse(empty.showStatusBar)
        XCTAssertEqual(empty.actionDelaySeconds, SettingsStore.defaultActionDelaySeconds)
        XCTAssertFalse(empty.fullAutoPrefersSanma)
        XCTAssertEqual(empty.fullAutoRoomPreference, .lowest)
        XCTAssertFalse(empty.cloudInferenceEnabled)
        XCTAssertEqual(empty.cloudServerURL, SettingsStore.defaultCloudBaseURL)
        XCTAssertEqual(empty.cloudModel4P, "")
        XCTAssertEqual(empty.cloudModel3P, "")

        let stamp = Date(timeIntervalSince1970: 2_000)
        defaults.set("en", forKey: SettingsStore.appLanguageKey)
        defaults.set(false, forKey: SettingsStore.keepAliveInBackgroundKey)
        defaults.set(false, forKey: SettingsStore.autoCheckUpdateKey)
        defaults.set(stamp, forKey: SettingsStore.lastUpdateCheckKey)
        defaults.set("9.9", forKey: SettingsStore.skippedUpdateVersionKey)
        defaults.set(["x"], forKey: SettingsStore.enabledPluginIdsKey)
        defaults.set(true, forKey: SettingsStore.pluginsMayModifyOutboundKey)
        defaults.set("flag", forKey: Self.pluginKey)
        defaults.set("intl", forKey: SettingsStore.majsoulServerKey)
        defaults.set("UA2", forKey: SettingsStore.majsoulUserAgentKey)
        defaults.set(["H": "v"], forKey: SettingsStore.majsoulExtraHeadersKey)
        defaults.set(true, forKey: SettingsStore.pinMajsoulServerKey)
        defaults.set(true, forKey: SettingsStore.showStatusBarKey)
        defaults.set(1.5, forKey: SettingsStore.actionDelaySecondsKey)
        defaults.set(true, forKey: SettingsStore.fullAutoPrefersSanmaKey)
        defaults.set("highest", forKey: SettingsStore.fullAutoRoomPreferenceKey)
        defaults.set(true, forKey: SettingsStore.cloudEnabledKey)
        defaults.set("https://u.invalid", forKey: SettingsStore.cloudBaseURLKey)
        defaults.set("a", forKey: SettingsStore.cloudModel4PKey)
        defaults.set("b", forKey: SettingsStore.cloudModel3PKey)

        let loaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(loaded.appLanguage, .en)
        XCTAssertFalse(loaded.keepAliveInBackground)
        XCTAssertFalse(loaded.autoCheckUpdate)
        XCTAssertEqual(loaded.lastUpdateCheck, stamp)
        XCTAssertEqual(loaded.skippedUpdateVersion, "9.9")
        XCTAssertEqual(loaded.enabledPluginIds, ["x"])
        XCTAssertTrue(loaded.pluginsMayModifyOutbound)
        XCTAssertEqual(loaded.pluginSettingValue(pluginId: "p", key: "k") as? String, "flag")
        XCTAssertEqual(loaded.pluginSettingOverrides(pluginId: "p", keys: ["k", "none"]).keys.sorted(), ["k"])
        XCTAssertEqual(loaded.majsoulServer, .intl)
        XCTAssertEqual(loaded.majsoulUserAgent, "UA2")
        XCTAssertEqual(loaded.majsoulExtraHeaders, ["H": "v"])
        XCTAssertTrue(loaded.pinMajsoulServer)
        XCTAssertTrue(loaded.showStatusBar)
        XCTAssertEqual(loaded.actionDelaySeconds, 1.5)
        XCTAssertTrue(loaded.fullAutoPrefersSanma)
        XCTAssertEqual(loaded.fullAutoRoomPreference, .highest)
        XCTAssertTrue(loaded.cloudInferenceEnabled)
        XCTAssertEqual(loaded.cloudServerURL, "https://u.invalid")
        XCTAssertEqual(loaded.cloudModel4P, "a")
        XCTAssertEqual(loaded.cloudModel3P, "b")
    }
}
