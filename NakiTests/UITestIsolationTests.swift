//
//  UITestIsolationTests.swift
//  NakiTests
//
//  UI 測試啟動的 App 不是 test host，只靠 launchEnvironment 的兩個 key 避開真實設定檔與 Keychain。
//  key 寫字面值：引用產品碼常數的話，常數拼錯測試照樣會過。
//

import XCTest

@testable import Naki

final class UITestIsolationTests: XCTestCase {

    func testNoHookKeepsRealStores() {
        XCTAssertNil(SettingsStore.resolveSuiteName(environment: [:]))
        XCTAssertEqual(CloudKeyStore.resolveService(environment: [:]), "org.naki.cloud-inference")
    }

    func testTestHostWinsOverUITestSuite() {
        let env = ["XCTestConfigurationFilePath": "/x", "NAKI_UI_TEST_DEFAULTS_SUITE": "naki.tests.ui"]
        XCTAssertEqual(SettingsStore.resolveSuiteName(environment: ["XCTestConfigurationFilePath": "/x"]), "naki.tests.host")
        XCTAssertEqual(SettingsStore.resolveSuiteName(environment: env), "naki.tests.host")
    }

    func testSuiteWithoutTestPrefixFallsBack() {
        #if DEBUG
        for name in ["/tmp/x", "org.39c154f25912233a.akagi", ""] {
            XCTAssertEqual(SettingsStore.resolveSuiteName(environment: ["NAKI_UI_TEST_DEFAULTS_SUITE": name]), "naki.tests.ui", name)
        }
        #endif
    }

    func testUITestHooks() {
        let suite = SettingsStore.resolveSuiteName(environment: ["NAKI_UI_TEST_DEFAULTS_SUITE": "naki.tests.ui.a"])
        let emptySuite = SettingsStore.resolveSuiteName(environment: ["NAKI_UI_TEST_DEFAULTS_SUITE": ""])
        let service = CloudKeyStore.resolveService(environment: ["NAKI_UI_TEST_KEYCHAIN_SERVICE": "org.naki.test.a"])
        let emptyService = CloudKeyStore.resolveService(environment: ["NAKI_UI_TEST_KEYCHAIN_SERVICE": ""])
        let realService = CloudKeyStore.resolveService(environment: ["NAKI_UI_TEST_KEYCHAIN_SERVICE": "org.naki.cloud-inference"])
        #if DEBUG
        XCTAssertEqual(suite, "naki.tests.ui.a")
        XCTAssertEqual(emptySuite, "naki.tests.ui")
        XCTAssertEqual(service, "org.naki.test.a")
        XCTAssertEqual(emptyService, "org.naki.cloud-inference.uitest")
        XCTAssertEqual(realService, "org.naki.cloud-inference.uitest")
        #else
        XCTAssertNil(suite)
        XCTAssertNil(emptySuite)
        XCTAssertEqual(service, "org.naki.cloud-inference")
        XCTAssertEqual(emptyService, "org.naki.cloud-inference")
        XCTAssertEqual(realService, "org.naki.cloud-inference")
        #endif
    }

    /// 其他 key 不觸發鉤子。
    func testUnrelatedKeysIgnored() {
        let env = ["NAKI_UI_TEST_DEFAULTS": "x", "NAKI_UI_TEST_KEYCHAIN": "y", "NAKI_HOLD_AFTER_TAP": "1"]
        XCTAssertNil(SettingsStore.resolveSuiteName(environment: env))
        XCTAssertEqual(CloudKeyStore.resolveService(environment: env), "org.naki.cloud-inference")
    }

    /// 預設落點的所有讀者共用同一個實例：test host 中沒有誰還讀寫 `.standard`。
    @MainActor
    func testDefaultReadersShareSettingsStoreStandard() {
        XCTAssertTrue(L10n.defaults === SettingsStore.standard)
        XCTAssertTrue(AutoPlayModeStore.defaults === SettingsStore.standard)
        XCTAssertFalse(SettingsStore.standard === UserDefaults.standard)
    }

    /// 無效 suite 名稱（App 自己的 bundle id、`NSGlobalDomain`）不退回真實設定檔，而是落 `naki.tests.ui`。
    func testInvalidSuiteNameFallsBackToUITestSuite() throws {
        #if DEBUG
        let names = ["NSGlobalDomain", try XCTUnwrap(Bundle.main.bundleIdentifier)]
        let fallback = try XCTUnwrap(UserDefaults(suiteName: "naki.tests.ui"))
        for name in names {
            XCTAssertNil(UserDefaults(suiteName: name), name)
            let marker = "naki.tests.marker.\(UUID().uuidString)"
            fallback.set(1, forKey: marker)
            defer { fallback.removeObject(forKey: marker) }
            let resolved = SettingsStore.resolveDefaults(environment: ["NAKI_UI_TEST_DEFAULTS_SUITE": name])
            XCTAssertEqual(resolved.integer(forKey: marker), 1, name)
        }
        #endif
    }

    /// `ObservedMatchSids` 的 `init` 預設落點是 `SettingsStore.standard`。唯讀：不碰 `.shared`、不 record、不 reset。
    @MainActor
    func testObservedMatchSidsDefaultsToSettingsStoreStandard() {
        XCTAssertTrue(ObservedMatchSids.makeWithDefaultDefaults().defaultsForTesting === SettingsStore.standard)
    }
}
