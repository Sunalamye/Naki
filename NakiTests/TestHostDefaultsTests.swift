//
//  TestHostDefaultsTests.swift
//  NakiTests
//
//  test host 就是 App 本體，`NakiRuntime()` 在任何 `setUp` 之前建構；預設落點本身必須已經不是用戶真實設定檔。
//

import XCTest

@testable import Naki

final class TestHostDefaultsTests: XCTestCase {

    func testTestHostDefaultsAreNotStandard() {
        XCTAssertTrue(SettingsStore.isTestHost)
        XCTAssertFalse(SettingsStore.standard === UserDefaults.standard, "SettingsStore 會寫真實設定檔")
        XCTAssertFalse(AutoPlayModeStore.defaults === UserDefaults.standard, "AutoPlayModeStore 會寫真實設定檔")
    }

    /// 未隔離時跳過：這條會寫入，不能讓它寫進真實設定檔。
    @MainActor
    func testRuntimeSettingsWritesLandInHostSuite() throws {
        try XCTSkipIf(SettingsStore.standard === UserDefaults.standard, "預設落點仍是 .standard")
        let runtime = NakiRuntime()
        let original = runtime.settings.lastUpdateCheck
        let stamp = Date(timeIntervalSince1970: 1_234)

        runtime.settings.lastUpdateCheck = stamp
        defer { runtime.settings.lastUpdateCheck = original }

        XCTAssertEqual(SettingsStore.standard.object(forKey: SettingsStore.lastUpdateCheckKey) as? Date, stamp)
        XCTAssertNotEqual(UserDefaults.standard.object(forKey: SettingsStore.lastUpdateCheckKey) as? Date, stamp)
    }
}
