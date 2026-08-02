//
//  NakiActionLayerTests.swift
//  NakiTests
//
//  p3-3 回歸鎖：Action 層與 `NakiMCPDependencies`。
//
//  取代 `WebViewMCPContextTests`（`WebViewMCPContext` 已刪除——它存在的唯一理由是把
//  四個 optional callback 橋成 `MCPContext`，而那四個 callback 正是 p3-3 拆掉的九跳之一）。
//  原檔鎖住的四件事在這裡有對應：
//    沒接上 JS 要 throw          → testExecuteJavaScriptActionThrowsWhenUnavailable
//    completion 橋成 async        → testExecuteJavaScriptActionReturnsStubResult
//    error 原樣傳回               → testExecuteJavaScriptActionPropagatesError
//    log 只有一個歸宿             → testContextLogGoesToStatusBarAndLogManagerOnly
//
//  外加 p3-3 自己的驗收面：狀態輸出是純導出（`NakiStatePayload`）、
//  Action 的 stub 真的被呼叫到、`.unavailable` 不會假裝成功。
//

import XCTest

@testable import Naki

@MainActor
final class NakiActionLayerTests: XCTestCase {

    // MARK: - Helpers

    /// 全部 Action 都用 stub 的依賴表。
    ///
    /// 參數一律 optional，nil ＝「這條 path 沒有這個能力」，所以每個測試只要寫它關心的那一個。
    /// （不用預設值是因為 NakiTests target 沒有開 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，
    /// 預設引數在 nonisolated 上下文求值，碰不到 `@MainActor` 的 static。）
    private func makeDependencies(
        store: GameStore,
        executeJavaScript: ExecuteJavaScriptAction? = nil,
        captureScreenshot: CaptureScreenshotAction? = nil,
        sendAction: SendActionAction? = nil,
        triggerAutoPlay: TriggerAutoPlayAction? = nil,
        setAntiIdle: SetAntiIdleAction? = nil,
        gameSnapshot: GameSnapshotAction? = nil,
        forceReconnect: ForceReconnectAction? = nil
    ) -> NakiMCPDependencies {
        let send = sendAction ?? .unavailable("test_not_wired")
        return NakiMCPDependencies(
            store: store,
            executeJavaScript: executeJavaScript ?? .unavailable,
            captureScreenshot: captureScreenshot ?? .unavailable,
            sendAction: send,
            startMatch: StartMatchAction(send: send),
            cancelMatch: CancelMatchAction(send: send),
            triggerAutoPlay: triggerAutoPlay ?? .unavailable,
            setAntiIdle: setAntiIdle ?? .unavailable,
            gameSnapshot: gameSnapshot ?? GameSnapshotAction(store: store, accountSource: nil),
            forceReconnect: forceReconnect ?? .unavailable)
    }

    // MARK: - ExecuteJavaScriptAction

    /// 沒有頁面可執行時必須 throw，而不是回 nil 假裝成功——
    /// MCP 的 `execute_js` 靠這個錯誤把「頁面還沒接上」跟「腳本回 null」分開。
    func testExecuteJavaScriptActionThrowsWhenUnavailable() async {
        do {
            _ = try await ExecuteJavaScriptAction.unavailable("return 1")
            XCTFail("沒有 JS 通道時不應該成功回傳")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains("JavaScript execution"),
                "錯誤訊息應指出 JS 通道不可用，實際是 \(error.localizedDescription)")
        }
    }

    func testExecuteJavaScriptActionReturnsStubResult() async throws {
        var receivedScript: String?
        let action = ExecuteJavaScriptAction(stub: { script in
            receivedScript = script
            return "ok"
        })

        let result = try await action("return 'ok'")

        XCTAssertEqual(result as? String, "ok")
        XCTAssertEqual(receivedScript, "return 'ok'")
    }

    func testExecuteJavaScriptActionPropagatesError() async {
        let expected = NSError(domain: "NakiTests", code: 42)
        let action = ExecuteJavaScriptAction(stub: { _ in throw expected })

        do {
            _ = try await action("boom")
            XCTFail("stub 拋錯時不應該成功回傳")
        } catch {
            XCTAssertEqual((error as NSError).code, 42)
        }
    }

    /// context 只是把 Action 轉出去，不自己再包一層 callback
    func testContextExecuteJavaScriptUsesInjectedAction() async throws {
        let store = GameStore()
        let context = DefaultNakiMCPContext(
            dependencies: makeDependencies(
                store: store,
                executeJavaScript: ExecuteJavaScriptAction(stub: { _ in 7 })))

        let result = try await context.executeJavaScript("return 7")

        XCTAssertEqual(result as? Int, 7)
    }

    // MARK: - log 通道

    /// `log()` 更新狀態列，而且**只更新一次**；log 本體的歸宿是 LogManager 一份。
    ///
    /// 先前這條路是 `MCPHandler.log` closure → `DebugServer.log()` → `onStatusMessage`
    /// closure → view model，三跳之後才寫到同一個地方。
    func testContextLogGoesToStatusBarAndLogManagerOnly() {
        let store = GameStore()
        let context = DefaultNakiMCPContext(dependencies: makeDependencies(store: store))

        context.log("hello-from-mcp")

        XCTAssertEqual(store.statusMessage, "hello-from-mcp")
        // `getLogs()` 沒有第二份 buffer 可讀：它就是 LogManager
        XCTAssertEqual(context.getLogs().count, LogManager.shared.recentLogLines().count)
    }

    // MARK: - NakiStatePayload（狀態是導出值，不是第二份狀態）

    func testBotStatusPayloadReadsStore() {
        let store = GameStore()
        store.autoPlayMode = .off
        store.tehaiTiles = ["1m", "2m", "3m"]
        store.tsumoTile = "5p"
        store.botStatus = BotStatus(isActive: true, modelName: "mortal", playerId: 2)

        let payload = NakiStatePayload.botStatus(store: store)

        XCTAssertEqual((payload["autoPlay"] as? [String: Any])?["mode"] as? String,
                       AutoPlayMode.off.rawValue)
        XCTAssertEqual(payload["tehaiCount"] as? Int, 3)
        XCTAssertEqual(payload["tsumoTile"] as? String, "5p")
        XCTAssertEqual((payload["botStatus"] as? [String: Any])?["playerId"] as? Int, 2)
    }

    /// 沒有摸牌時要輸出 NSNull，不是把欄位吞掉——
    /// 兩條 path 先前各寫一份，其中一份是 `as Any`（nil 會變成無法序列化的東西）。
    func testBotStatusPayloadUsesNullForMissingTsumo() {
        let store = GameStore()
        store.tsumoTile = nil

        XCTAssertTrue(NakiStatePayload.botStatus(store: store)["tsumoTile"] is NSNull)
    }

    func testGameSnapshotCarriesAccountIdAndMode() {
        let store = GameStore()
        store.autoPlayMode = .recommend
        store.gameState.playerId = 3

        let snapshot = NakiStatePayload.gameSnapshot(store: store, accountId: 123_456)

        XCTAssertEqual(snapshot["accountId"] as? Int, 123_456)
        XCTAssertEqual((snapshot["gameState"] as? [String: Any])?["seat"] as? Int, 3)
        XCTAssertEqual((snapshot["autoPlay"] as? [String: Any])?["mode"] as? String,
                       AutoPlayMode.recommend.rawValue)
        XCTAssertNotNil(snapshot["operations"])
    }

    /// 沒有 account 來源（Legacy path）時回 0，而不是憑空生一個 id
    func testGameSnapshotActionWithoutAccountSourceReportsZero() {
        let store = GameStore()
        let action = GameSnapshotAction(store: store, accountSource: nil)

        XCTAssertEqual(action()["accountId"] as? Int, 0)
    }

    // MARK: - 送出面

    /// `.unavailable` 必須是「連送都沒送」，不能被讀成送出失敗或成功
    func testUnavailableSendActionReportsReason() async {
        let outcome = await SendActionAction.unavailable("legacy_path_action_send_disabled")(
            LiqiRequestBuilder.cancelMatch(matchMode: 1), awaitResponseMs: 0)

        XCTAssertEqual(outcome.unavailableReason, "legacy_path_action_send_disabled")
        XCTAssertNil(outcome.sent)
    }

    /// 匹配 Action 自己組 spec（工具端不再拼一次），並把等待時間原樣傳下去
    func testStartMatchActionBuildsSpecAndForwardsTimeout() async {
        var seenAwaitMs: Int?
        var seenMethod: String?
        let action = StartMatchAction(send: SendActionAction(stub: { spec, awaitMs in
            seenMethod = spec.method
            seenAwaitMs = awaitMs
            return .unavailable("stubbed")
        }))

        let result = await action(matchMode: 8, clientVersionString: "", awaitResponseMs: 1500)

        XCTAssertEqual(seenMethod, LiqiRequestBuilder.matchGameMethod)
        XCTAssertEqual(result.spec.method, LiqiRequestBuilder.matchGameMethod)
        XCTAssertEqual(seenAwaitMs, 1500)
    }

    func testCancelMatchActionBuildsSpec() async {
        let action = CancelMatchAction(send: SendActionAction(stub: { _, _ in .unavailable("s") }))

        let result = await action(matchMode: 8, awaitResponseMs: 0)

        XCTAssertEqual(result.spec.method, LiqiRequestBuilder.cancelMatchMethod)
    }

    /// 心跳不可用時要回 nil：工具靠這個 nil 回報 `anti_idle_not_configured`，
    /// 回一份空狀態會變成「成功但什麼都沒有」。
    func testUnavailableAntiIdleReturnsNil() {
        XCTAssertNil(SetAntiIdleAction.unavailable(enabled: true, intervalSeconds: nil))
    }

    /// `bot_trigger` 走 context → Action，中間沒有第二條捷徑
    func testContextTriggerAutoPlayCallsAction() {
        let store = GameStore()
        var triggered = 0
        let context = DefaultNakiMCPContext(
            dependencies: makeDependencies(
                store: store,
                triggerAutoPlay: TriggerAutoPlayAction(stub: { triggered += 1 })))

        context.triggerAutoPlay()

        XCTAssertEqual(triggered, 1)
    }

    // MARK: - ForceReconnectAction

    /// p0-2 的核心：JS 回傳值要被真的讀出來（腳本漏 `return` 時它會是 nil → 0）
    func testForceReconnectActionReadsClosedCount() async {
        let action = ForceReconnectAction(javaScript: ExecuteJavaScriptAction(stub: { script in
            XCTAssertEqual(script, NakiWebSocketScript.forceReconnect)
            return 3
        }))

        let outcome = await action()

        XCTAssertTrue(outcome.success)
        XCTAssertEqual(outcome.dictionary["closedConnections"] as? Int, 3)
    }

    /// 關到 0 條不是錯誤，但也不是成功——訊息與 `success` 都要說實話
    func testForceReconnectActionZeroClosedIsNotSuccess() async {
        let action = ForceReconnectAction(javaScript: ExecuteJavaScriptAction(stub: { _ in 0 }))

        let outcome = await action()

        XCTAssertFalse(outcome.success)
        XCTAssertEqual(outcome.statusMessage, "沒有活躍的連接")
    }

    func testForceReconnectActionSurfacesJavaScriptError() async {
        let action = ForceReconnectAction(javaScript: .unavailable)

        let outcome = await action()

        XCTAssertFalse(outcome.success)
        XCTAssertEqual(outcome.dictionary["success"] as? Bool, false)
        XCTAssertNotNil(outcome.dictionary["error"])
    }

    /// Legacy path 走整頁重載：不可以偽裝成「關了 0 條連線」
    func testReloadedOutcomeIsSuccessWithoutClosedConnections() {
        let outcome = ForceReconnectOutcome.reloaded

        XCTAssertTrue(outcome.success)
        XCTAssertEqual(outcome.dictionary["success"] as? Bool, true)
    }

    /// UI 按鈕注入的是同一個型別，行為由 stub 決定（Preview 因此能拉起來）
    func testForceReconnectStubIsInvokedByCallAsFunction() async {
        var called = false
        let action = ForceReconnectAction(stub: {
            called = true
            return .closed(1)
        })

        _ = await action()

        XCTAssertTrue(called)
    }

    // MARK: - SetAutoPlayModeAction

    func testSetAutoPlayModeStubReceivesMode() {
        var received: AutoPlayMode?
        let action = SetAutoPlayModeAction(stub: { received = $0 })

        action(.off)

        XCTAssertEqual(received, .off)
    }
}
