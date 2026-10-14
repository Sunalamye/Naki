import XCTest
@testable import Naki

/// 正式路徑 `SettingsStore()` 的初值（inline）必須與 `SettingsStore(defaults: .standard)` 逐項相同；
/// 兩份讀取各自漂移時，只測注入版的 `SettingsStoreInjectionTests` 抓不到。
@MainActor
final class SettingsStoreInlinePathTests: XCTestCase {

    func testInlineInitialValuesMatchInjectedInitOnStandard() {
        let inline = SettingsStore()
        let injected = SettingsStore(defaults: SettingsStore.standard)
        XCTAssertEqual(inline.appLanguage, injected.appLanguage)
        XCTAssertEqual(inline.keepAliveInBackground, injected.keepAliveInBackground)
        XCTAssertEqual(inline.autoCheckUpdate, injected.autoCheckUpdate)
        XCTAssertEqual(inline.lastUpdateCheck, injected.lastUpdateCheck)
        XCTAssertEqual(inline.skippedUpdateVersion, injected.skippedUpdateVersion)
        XCTAssertEqual(inline.enabledPluginIds, injected.enabledPluginIds)
        XCTAssertEqual(inline.pluginsMayModifyOutbound, injected.pluginsMayModifyOutbound)
        XCTAssertEqual(inline.majsoulServer, injected.majsoulServer)
        XCTAssertEqual(inline.majsoulUserAgent, injected.majsoulUserAgent)
        XCTAssertEqual(inline.majsoulExtraHeaders, injected.majsoulExtraHeaders)
        XCTAssertEqual(inline.pinMajsoulServer, injected.pinMajsoulServer)
        XCTAssertEqual(inline.showStatusBar, injected.showStatusBar)
        XCTAssertEqual(inline.actionDelaySeconds, injected.actionDelaySeconds)
        XCTAssertEqual(inline.fullAutoPrefersSanma, injected.fullAutoPrefersSanma)
        XCTAssertEqual(inline.fullAutoRoomPreference, injected.fullAutoRoomPreference)
        XCTAssertEqual(inline.cloudInferenceEnabled, injected.cloudInferenceEnabled)
        XCTAssertEqual(inline.cloudServerURL, injected.cloudServerURL)
        XCTAssertEqual(inline.cloudModel4P, injected.cloudModel4P)
        XCTAssertEqual(inline.cloudModel3P, injected.cloudModel3P)
    }

    /// `load…(from:)` 對空 suite 回的預設值；任何一個漂移，inline 與注入版會一起漂，只有這裡抓得到。
    func testLoadersReturnDocumentedDefaultsOnEmptySuite() throws {
        let name = "naki.tests.loaders.\(UUID().uuidString)"
        let empty = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { empty.removePersistentDomain(forName: name) }
        let s = SettingsStore(defaults: empty)
        XCTAssertEqual(s.majsoulServer, .cn)
        XCTAssertEqual(s.cloudServerURL, "https://mjapi.shinkuan.me")
        XCTAssertEqual(s.majsoulUserAgent, "")
        XCTAssertEqual(s.cloudModel4P, "")
        XCTAssertEqual(s.cloudModel3P, "")
        XCTAssertFalse(s.pluginsMayModifyOutbound)
        XCTAssertFalse(s.pinMajsoulServer)
        XCTAssertFalse(s.showStatusBar)
        XCTAssertFalse(s.cloudInferenceEnabled)
        XCTAssertTrue(s.enabledPluginIds.isEmpty)
        XCTAssertNil(s.lastUpdateCheck)
        XCTAssertNil(s.skippedUpdateVersion)
    }
}
