//
//  NakiRuntime.swift
//  Naki
//
//  p3-4：App 的組裝點（composition root）。
//
//  這是 `WebViewModel` / `LegacyWebViewModel` / `WebViewModelProtocol` 三者留下的
//  最後一塊：**誰持有誰**。刪掉的不只是行數，是三個結構性問題：
//
//  1. **協定不是抽象，是兩份實作的最大公因數。** `WebViewModelProtocol` 有 20 個成員，
//     其中 `processNativeEvents` / `getPlayerNamesStatus` 兩條**零呼叫端**——它們存在的
//     唯一理由是兩份實作都寫了。而真正的平台差異（WebPage vs WKWebView）只有
//     「怎麼執行 JS、怎麼載入、交出哪個 View」三件事，現在收在 `WebSessionBackend`。
//  2. **View 靠 `as?` 撈具體型別。** `NakiWebView` 要 `as? WebViewModel` 才拿得到
//     `webPage`、`LegacyNakiWebView` 要 `as? LegacyWebViewModel` 才呼叫得到
//     `setWebView`；轉型失敗沒有編譯錯誤也沒有例外，畫面只剩「正在初始化…」。
//  3. **兩條 path 各抄一份組裝。** 兩個 view model 各自建 bot、各自接 `liqiSender`、
//     各自組 MCP 依賴表、各自 clamp 模式。差異只有「哪些能力不提供」，
//     卻用整份拷貝來表達。
//
//  現在只有一份組裝，差異是**值**（`session.supportsAutoPlay`）而不是型別。
//
//  ## 生命週期
//
//  由 `NakiApp` / `Naki_MApp` 以 `@State` 持有一份，透過
//  `.environment(\.naki, runtime.environment)` 注入 Scene。
//  `NakiEnvironment` 的預設值只給 Preview（見該處）。
//

import Foundation
import SwiftUI

/// Naki 的全部活物件，以及它們之間的接線。
@MainActor
final class NakiRuntime {

    // MARK: - 狀態

    /// 牌局、連線與狀態列的唯一真實來源（SwiftUI 與 MCP 讀同一份，p3-1）
    let store = GameStore()

    /// 使用者設定與這條 WebView path 的能力
    let settings = SettingsStore()

    // MARK: - 服務

    /// WebSocket → MJAI → Bot → `GameStore`
    let coordinator: NakiWebCoordinator

    /// 雀魂頁面（WebPage 或 WKWebView，平台差異只在它內部）
    let session: WebSession

    /// Liqi 動作／大廳請求送出器（Unity 時代唯一有效的動作面）
    private let liqiSender = LiqiActionSender()

    /// 自動打牌狀態機（單一 Task 迴圈；輪詢／延遲／重試都是 `Task.sleep`）
    private var autoPlayEngine: AutoPlayEngine?

    /// MCP／Debug HTTP server（兩個平台都啟動，見 `DebugServer` 檔頭）
    private var debugServer: DebugServer?

    /// View 層看得到的副作用集合（一次組好，之後不變）
    private(set) var actions = NakiActions()

    /// 注入 Scene 的值
    var environment: NakiEnvironment {
        NakiEnvironment(store: store, settings: settings, actions: actions)
    }

    // MARK: - 組裝

    init() {
        // ⓪ 自動打牌模式的兩個舊 key 合併成一個。
        //
        // **必須在這裡而不是只在 App 的 `init()` 裡**：`@State private var runtime = NakiRuntime()`
        // 是 stored property 的預設值，它在 App 的 `init` 本體**之前**求值——也就是說
        // 這個 runtime 會比 `NakiApp.init()` 裡那一行遷移更早跑。冪等，重複呼叫安全。
        AutoPlayModeStore.migrateLegacyKeyIfNeeded()

        // ① 牌局側：coordinator 擁有 bot / event stream / WS handler，直接寫 store
        coordinator = NakiWebCoordinator(store: store)

        // ② 頁面側：JS bridge 的收件人就是 coordinator 的 WS handler
        session = WebSession(store: store,
                             settings: settings,
                             messageHandler: coordinator.websocketHandler)

        // ③ 互相接線（兩邊都不認得對方的型別，只認得協定）
        coordinator.observer = self
        session.lifecycle = coordinator
        settings.adoptAutoPlaySupport(session.supportsAutoPlay)

        configureLiqiSender()
        adoptStoredAutoPlayMode()
        startAutoPlayEngine()

        actions = makeActions()

        // 自動啟動 MCP Server（兩個平台、兩條 path 一律啟動）
        //
        // 頁面本身**不在這裡載入**：首次載入掛在 `WebSession.makeView()` 的 `.task` 上，
        // 與遷移前同一個時機（見 `WebSession.loadMajsoulIfNeeded`）。
        startDebugServer()
    }

    /// `@MainActor` class 在 NakiTests host 釋放會 SIGABRT（見 CLAUDE.md「專案結構的坑」）
    nonisolated deinit {}

    // MARK: - Liqi 送出通道

    /// 送出鏈：Swift 組 envelope → base64 → `window.__nakiWebSocket.sendRaw(base64)`
    /// → JS 端取第一條 OPEN 的雀魂連線 `ws.send(buffer)`。
    ///
    /// 腳本字串與回傳值解析都在 `NakiWebSocketScript`；函式體語意（要值就寫 `return`）
    /// 由 `WebSession.callJavaScript` 統一，兩條 path 這裡看不到差別。
    private func configureLiqiSender() {
        // `addLog` 內部就會寫進 LogManager（並更新狀態列），所以這裡不能再 bridgeLog 一次；
        // 先前兩行都寫，同一件事在 `/logs` 會以兩種前綴各出現一次。
        liqiSender.logHandler = { [weak self] message in
            let line = "[Naki] \(message)"
            if let server = self?.debugServer {
                server.addLog(line)
            } else {
                bridgeLog(line)
            }
        }

        liqiSender.sendHandler = { [weak self] base64 in
            guard let self else { return .failure("runtime_deallocated") }
            do {
                return NakiWebSocketScript.sendResult(
                    from: try await self.session.callJavaScript(
                        NakiWebSocketScript.sendRaw(base64: base64)))
            } catch {
                return .failure("js_error: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - 自動打牌

    /// 沿用上次選的模式，並收斂到這條 path 真的能執行的值。
    ///
    /// 舊行為是每次啟動都硬設 `.auto`，於是使用者選的「關閉」一重啟就被沖掉。
    /// `commit` 會把收斂後的值寫回存檔：不寫的話 UI 的 `@AppStorage` 與這裡讀到的
    /// 模式會不一致，picker 顯示「自動」而實際跑「推薦」。
    private func adoptStoredAutoPlayMode() {
        let stored = AutoPlayModeStore.load()
        store.autoPlayMode = AutoPlayAvailability.commit(
            stored, autoPlaySupported: settings.supportsAutoPlay)
        if store.autoPlayMode != stored {
            bridgeLog("[Naki] 存檔為自動模式，本路徑不支援 → 降級為推薦")
        }
        bridgeLog("[Naki] 自動打牌模式（沿用上次）: \(store.autoPlayMode.rawValue)")
    }

    /// 建立並啟動自動打牌狀態機。
    ///
    /// 引擎不認得 runtime：它只拿到 oplist 儲存體、送出器、一個「現在的上下文」
    /// closure 與兩條 log 通道。這是它能被單測的前提（`AutoPlayEngineTests` 與
    /// p0-5 的 fail-safe fixture 建的是同一個型別）。
    ///
    /// **Legacy path 也跑這個迴圈**，但 `supportsAutoPlay == false` ⇒ 模式永遠不是
    /// `.auto` ⇒ `AutoPlayGate` 第一關就 `.skip(.notAutoMode)`（不記 log、不動作）。
    /// 收斂的權威是模式閘門一處，不是「這條 path 乾脆不啟動引擎」這種第二道 if。
    private func startAutoPlayEngine() {
        let engine = AutoPlayEngine(
            store: LiqiOperationStore.shared,
            sender: liqiSender,
            context: { [weak self] in
                guard let self else { return .init(mode: .off, isReady: false) }
                return .init(
                    mode: self.store.autoPlayMode,
                    recommendations: self.store.recommendations,
                    // 座位來源只有 `GameStore.autoPlaySeat` 一份定義
                    seat: self.store.autoPlaySeat,
                    isSanma: self.store.gameState.is3P,
                    tsumoTile: self.store.tsumoTile,
                    isReady: self.session.isReady,
                    // 延遲 stepper 的讀取端：每輪重取，調一下下一手就生效（p2-6）
                    actionDelayScale: self.settings.actionDelayScale)
            },
            log: { [weak self] message in self?.debugServer?.addLog(message) },
            event: { [weak self] message in self?.logAutoPlayEvent(message) })

        autoPlayEngine = engine
        engine.start()
    }

    /// 自動打牌的關鍵節點：同時進 Debug buffer 與 naki-events.log。
    ///
    /// 這些是「為什麼這樣打／為什麼沒打」的唯一線索，不能混在 parser 細節裡。
    private func logAutoPlayEvent(_ message: String) {
        debugServer?.addLog(message)
        eventLog(message)
    }

    /// 切換自動打牌模式（UI picker 與 MCP 共用同一個入口）。
    func setAutoPlayMode(_ mode: AutoPlayMode) {
        // 收斂＋持久化只有 `AutoPlayAvailability.commit` 一處
        let effective = AutoPlayAvailability.commit(
            mode, autoPlaySupported: settings.supportsAutoPlay)
        store.autoPlayMode = effective

        if effective != mode {
            store.statusMessage = "此裝置不支援自動送出，已改為推薦模式"
            bridgeLog("[Naki] 要求 \(mode.rawValue) → 降級為 \(effective.rawValue)："
                + AutoPlayAvailability.autoUnavailableReason)
        } else {
            bridgeLog("[Naki] 自動打牌模式設定為: \(effective.rawValue)")
        }
        debugServer?.addLog("模式已變更: \(effective.rawValue), 推薦數: \(store.recommendations.count)")

        // 模式一改就要立刻反映在畫面上，不能等下一次 Bot 回應：
        // 切到 `.off` 時把遊戲內標記清掉，切回 `.recommend` / `.auto` 時重新染上。
        store.updateHighlight(showRecommendation: effective.showRecommendation)
        session.syncHighlight()

        // 引擎自己會在下一輪讀新的模式；這裡只是叫它別等下一拍，並重設去抖。
        autoPlayEngine?.modeDidChange()
    }

    /// 手動觸發自動打牌（MCP `bot_trigger`）。
    ///
    /// 排進引擎的下一輪，不自己送：三麻 fail-closed、無推薦、無 oplist 三道閘門
    /// 在 `AutoPlayEngine.runManualCycle` 裡。
    func triggerAutoPlayNow(delay: TimeInterval = 1.2) {
        autoPlayEngine?.requestManualTrigger(delay: delay)
    }

    // MARK: - MCP／Debug Server

    /// 這條 path 提供給 MCP／Debug HTTP 的全部能力。
    ///
    /// **會送出 Liqi request 的能力在 Legacy path 上一律不提供**（`supportsAutoPlay`
    /// 為 false 時）。遷移前那幾個 closure 在 Legacy 上根本沒有被設定，行為等價；
    /// 這裡只是把「忘了接線」變成「明講不提供，並附上可 grep 的短碼」。
    /// 唯讀面（狀態快照、log、JS、截圖）與重連兩條 path 都有。
    private func makeMCPDependencies() -> NakiMCPDependencies {
        let javaScript = ExecuteJavaScriptAction(session: session)
        // 短碼而不是自由文字：它會出現在 MCP 工具輸出與 log 裡，要能被 grep
        let disabled = "legacy_path_action_send_disabled"
        let send: SendActionAction = settings.supportsAutoPlay
            ? SendActionAction(sender: liqiSender)
            : .unavailable(disabled)

        return NakiMCPDependencies(
            store: store,
            executeJavaScript: javaScript,
            captureScreenshot: CaptureScreenshotAction(),
            sendAction: send,
            startMatch: StartMatchAction(send: send),
            cancelMatch: CancelMatchAction(send: send),
            // 統一走主自動打牌路徑：推薦 → gate → resolver → LiqiActionSender，
            // 沒有第二條「照手牌排序索引直接打」的捷徑
            triggerAutoPlay: settings.supportsAutoPlay
                ? TriggerAutoPlayAction(runtime: self) : .unavailable,
            // Unity 下 GameMgr.clientHeatBeat 已不存在，改由 Swift 定期送 .lq.Lobby.heatbeat
            setAntiIdle: settings.supportsAutoPlay
                ? SetAntiIdleAction(sender: liqiSender) : .unavailable,
            gameSnapshot: GameSnapshotAction(
                store: store, accountSource: coordinator.websocketHandler),
            forceReconnect: ForceReconnectAction(session: session))
    }

    func startDebugServer() {
        guard debugServer == nil else {
            store.statusMessage = "MCP Server 已在運行"
            return
        }

        let server = DebugServer(port: store.debugServerPort,
                                 dependencies: makeMCPDependencies())
        debugServer = server
        server.start()
    }

    func stopDebugServer() {
        debugServer?.stop()
        debugServer = nil
        store.isDebugServerRunning = false
        store.statusMessage = "MCP Server 已停止"
        systemLog("[生命週期] MCP Server 已停止")
    }

    func toggleDebugServer() {
        if store.isDebugServerRunning {
            stopDebugServer()
        } else {
            startDebugServer()
        }
    }

    // MARK: - Action 集合

    private func makeActions() -> NakiActions {
        NakiActions(
            executeJavaScript: ExecuteJavaScriptAction(session: session),
            forceReconnect: ForceReconnectAction(session: session),
            setAutoPlayMode: SetAutoPlayModeAction(runtime: self),
            triggerAutoPlay: TriggerAutoPlayAction(runtime: self),
            deleteBot: DeleteBotAction(coordinator: coordinator),
            toggleDebugServer: ToggleDebugServerAction(runtime: self),
            reloadPage: ReloadPageAction(session: session),
            setHidePlayerNames: SetHidePlayerNamesAction(session: session),
            webView: WebViewAction(session: session))
    }
}

// MARK: - Bot 回應

extension NakiRuntime: BotResponseObserving {

    /// 模型剛跑完推論：同步遊戲內高亮，並叫醒自動打牌引擎。
    ///
    /// 先前這裡是直接呼叫 `triggerAutoPlayIfNeeded()`——那是第二個觸發源，
    /// **不經閘門**（沒有三麻檢查、沒有「已非本家打牌回合」檢查），
    /// 只與輪詢共用去抖變數。現在兩個觸發源走同一輪 `AutoPlayEngine.runCycle()`。
    func botDidRespond() {
        session.syncHighlight()
        autoPlayEngine?.recommendationsDidChange()
    }

    /// Bot 被刪除：推薦已清空 → 高亮會送出 `clear()`，標記不會留在畫面上。
    func botDidReset() {
        session.syncHighlight()
    }

    /// 一局結束（`end_kyoku`）：讓引擎在自動模式下送 confirmNewRound 進下一局。
    func roundDidEnd() {
        autoPlayEngine?.roundDidEnd()
    }

    /// 下一局開始（`start_kyoku`）：權威推進，清掉待確認。
    func roundDidBegin() {
        autoPlayEngine?.roundDidBegin()
    }

    /// 整場對局結束（`end_game`）：終局取消任何待送的 confirmNewRound。
    func gameDidEnd() {
        autoPlayEngine?.gameDidEnd()
    }
}
