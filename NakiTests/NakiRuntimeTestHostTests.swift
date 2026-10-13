//
//  NakiRuntimeTestHostTests.swift
//  NakiTests
//
//  test host 就是 App 本體，`NakiRuntime.init` 必須跳過 debug server 與 AutoPlayEngine，
//  否則每次跑測試都會綁 8765 並啟動引擎。
//

import XCTest

@testable import Naki

@MainActor
final class NakiRuntimeTestHostTests: XCTestCase {

    func testInitSkipsDebugServerAndAutoPlayEngineInTestHost() {
        XCTAssertTrue(SettingsStore.isTestHost)

        let runtime = NakiRuntime()

        XCTAssertFalse(runtime.store.isDebugServerRunning)
        XCTAssertFalse(runtime.isDebugServerStarted)
        XCTAssertFalse(runtime.isAutoPlayEngineRunning)
    }
}
