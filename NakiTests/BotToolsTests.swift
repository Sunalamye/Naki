//
//  BotToolsTests.swift
//  NakiTests
//
//  Legacy path 的 `bot_trigger` 短碼，以及 test host 不自起 MCP server 的鎖。
//

import XCTest

@testable import Naki

@MainActor
final class BotToolsTests: XCTestCase {

    override func setUp() {
        super.setUp()
        isolateAutoPlayDefaults()
    }

    /// Legacy path 的 `TriggerAutoPlayAction` 是空閉包；沒有這個短碼，工具會回假的 `queued: true`。
    /// 用「在 .normal path 一定會成功」的 oplist，才能證明擋下的是 path 而不是別的閘門。
    func testBotTriggerReportsLegacyShortCode() async throws {
        let shared = LiqiOperationStore.shared
        shared.reset()
        defer { shared.reset() }
        shared.record(seat: 0, operations: [LiqiOperation(type: .tsumo)], contextTile: "5p")

        let settings = SettingsStore()
        settings.adoptAutoPlaySupport(false)
        let store = GameStore()
        let send: SendActionAction = .unavailable("test_not_wired")
        var triggered = 0
        let context = DefaultNakiMCPContext(dependencies: NakiMCPDependencies(
            store: store, ui: UIState(), settings: settings,
            executeJavaScript: .unavailable, captureScreenshot: .unavailable,
            sendAction: send,
            startUnifiedMatch: StartUnifiedMatchAction(send: send),
            cancelUnifiedMatch: CancelUnifiedMatchAction(send: send),
            triggerAutoPlay: TriggerAutoPlayAction(stub: { triggered += 1 }),
            setAntiIdle: .unavailable,
            gameSnapshot: GameSnapshotAction(store: store, accountSource: nil),
            forceReconnect: .unavailable))

        let result = try await BotTriggerTool(context: context).execute(arguments: [:]) as? [String: Any]

        XCTAssertEqual(result?["success"] as? Bool, false)
        XCTAssertEqual(result?["error"] as? String, "legacy_path_action_send_disabled")
        XCTAssertEqual(result?["queued"] as? Bool, false)
        XCTAssertEqual(triggered, 0)
    }

    /// test host 本身就是 App：`NakiRuntime.init` 不跳過的話，每次跑測試都會綁 loopback 8765。
    /// 監聽就緒是非同步的，等一小段讓「沒跳過」的情況有時間現形。
    func testRuntimeInTestHostDoesNotStartDebugServer() async throws {
        let runtime = NakiRuntime()

        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertFalse(runtime.store.isDebugServerRunning)
    }

    /// 旗標為 true 時再次啟動只能回報「已在運行」，不能停掉舊 server 再綁新的。
    /// 用隨機高位 port：若 guard 失效，新 server 的啟動訊息會蓋掉狀態列。
    func testStartDebugServerIsNoOpWhileFlagSet() async throws {
        let runtime = NakiRuntime()
        let port = UInt16.random(in: 50000...60000)
        runtime.store.debugServerPort = port
        runtime.store.debugServerPreferredPort = port
        runtime.store.isDebugServerRunning = true

        runtime.startDebugServer()
        let expected = L10n.text("MCP Server 已在運行")
        XCTAssertEqual(runtime.store.statusMessage, expected)

        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertEqual(runtime.store.statusMessage, expected, "guard 失效時新 server 的啟動訊息會蓋掉它")
        XCTAssertEqual(runtime.store.debugServerPort, port)
        XCTAssertTrue(runtime.store.isDebugServerRunning)
    }

    /// 不支援自動送出時：模式降級、存檔寫回降級值，狀態列留的是降級提示而不是被「模式已變更」蓋掉。
    func testSetAutoPlayModeDegradeKeepsNoticeAndPersistsClampedMode() {
        let runtime = NakiRuntime()
        runtime.settings.adoptAutoPlaySupport(false)

        runtime.setAutoPlayMode(.auto)

        XCTAssertEqual(runtime.store.autoPlayMode, .recommend)
        XCTAssertEqual(AutoPlayModeStore.load(), .recommend)
        XCTAssertEqual(runtime.store.statusMessage, L10n.text("此裝置不支援自動送出，已改為推薦模式"))

        runtime.setAutoPlayMode(.off)

        XCTAssertEqual(runtime.store.autoPlayMode, .off)
        XCTAssertNotEqual(runtime.store.statusMessage, L10n.text("此裝置不支援自動送出，已改為推薦模式"),
                          "沒有降級時不得留著降級提示")
    }
}
