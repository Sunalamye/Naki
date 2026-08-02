//
//  LegacyWebViewModel.swift
//  Naki
//
//  舊版 WebViewModel 實現（WKWebView，macOS 14+/iOS 17+）
//  完整功能版本：Bot 整合、Debug Server、AutoPlay
//

import MortalSwift
import SwiftUI
import WebKit

// MARK: - Legacy WebViewModel

/// 舊版 WebViewModel，使用 WKWebView（macOS 14+/iOS 17+）
@available(macOS 14.0, iOS 17.0, *)
@available(macOS, deprecated: 26.0, message: "Use WebViewModel with WebPage API instead")
@available(iOS, deprecated: 26.0, message: "Use WebViewModel with WebPage API instead")
@Observable
@MainActor
class LegacyWebViewModel: WebViewModelProtocol {
    // MARK: - State Properties

    var statusMessage: String = "舊版模式"
    var isConnected: Bool = false
    var recommendationCount: Int = 0

    var gameState: GameState = GameState()
    var botStatus: BotStatus = BotStatus()
    var recommendations: [Recommendation] = []
    var tehaiTiles: [String] = []
    var tsumoTile: String?
    var highlightedTile: String?

    private(set) var gameStateManager: GameStateManager = GameStateManager()
    var isDebugServerRunning: Bool = false
    var debugServerPort: UInt16 = 8765

    // MARK: - Services

    /// 原生 Bot 控制器 (MortalSwift)
    private var nativeBotController: NativeBotController?

    /// 動作送出器（Liqi protobuf）
    ///
    /// 舊版走的是 `AutoPlayService` → 讀 Laya 物件找牌 → 模擬點擊。
    /// 雀魂改用 Unity 後那條路整條失效（`DesktopMgr` 等物件已不存在），
    /// 所以這裡與主路徑一致，改為自行組 Liqi 封包送出。
    private(set) var liqiSender = LiqiActionSender()

    /// 自動打牌模式（與主路徑共用同一個持久化 key，見 `AutoPlayModeStore`）
    ///
    /// **不變式：這條路徑上它永遠不會是 `.auto`。** 兩個寫入點（init、`setAutoPlayMode`）
    /// 都先過 `AutoPlayAvailability.clamp`，理由見 `supportsAutoPlay`。
    private(set) var autoPlayMode: AutoPlayMode = AutoPlayModeStore.defaultMode

    /// Legacy 路徑不提供自動送出（p2-2 路線 A）。
    ///
    /// 這條路缺主路徑的整層保護：沒有 1 秒輪詢的 `AutoPlayGate`（forceHora／sendPass 寬限）、
    /// 沒有 executionId 去抖、沒有送出重試；而且 macOS deployment target 是 26，
    /// 本機根本跑不到它——沒有 iOS 17–25 實機就沒有任何對局證據。
    /// 在那個證據出現以前，讓它自動送牌等於拿使用者的帳號賭一條沒驗過的路。
    /// 推薦顯示保留（`.recommend`），送出交回使用者。
    let supportsAutoPlay = false

    /// Debug Server (macOS only)
    #if os(macOS)
    private var debugServer: DebugServer?
    #endif

    // MARK: - WKWebView Reference

    /// WKWebView 引用（由 LegacyNakiWebView 設置）
    weak var webView: WKWebView?

    /// 是否已經套用過隱藏名稱設定
    private var hasAppliedHideNamesSettings = false

    // MARK: - Initialization

    init() {
        // 初始化原生 Bot 控制器
        nativeBotController = NativeBotController()

        // 動作送出改走協定層：Swift 端組好 Liqi envelope，JS 只負責把 base64 丟進 WebSocket
        // 同一條訊息只寫一次：`addLog` 內部已經進 LogManager（並更新狀態列）。
        // 先前 addLog 與 bridgeLog 都寫，`/logs` 會看到兩種前綴的同一件事。
        liqiSender.logHandler = { [weak self] message in
            self?.autoPlayLog(message)
        }
        // 腳本字串與回傳值解析都在 `NakiWebSocketScript`（主路徑走同一份）。
        // `executeJavaScript` 會把它包成 IIFE，所以同樣需要自帶 `return`。
        liqiSender.sendHandler = { [weak self] base64 in
            guard let self else { return .failure("viewmodel_deallocated") }
            do {
                return NakiWebSocketScript.sendResult(
                    from: try await self.executeJavaScript(
                        NakiWebSocketScript.sendRaw(base64: base64)))
            } catch {
                return .failure("js_error: \(error.localizedDescription)")
            }
        }

        // 沿用上次選的模式（與主路徑同一個 key，不再每次啟動硬設 .auto），
        // 但存檔可能是在支援自動送出的裝置上寫下的 `.auto`——這條路不執行它。
        // `commit` 會把收斂後的值寫回存檔：不寫的話 UI 的 @AppStorage 與這裡讀到的模式
        // 會不一致，picker 顯示「自動」而實際跑「推薦」正是先前要修掉的那種說謊介面。
        let stored = AutoPlayModeStore.load()
        autoPlayMode = AutoPlayAvailability.commit(stored, autoPlaySupported: supportsAutoPlay)
        if autoPlayMode != stored {
            bridgeLog("[LegacyWebViewModel] 存檔為自動模式，本路徑不支援 → 降級為推薦")
        }

        statusMessage = "準備就緒 (Legacy 模式，僅推薦不自動送出)"
    }

    // MARK: - WebView Setup

    /// 設置 WebView 引用（由 LegacyNakiWebView 調用）
    func setWebView(_ webView: WKWebView) {
        self.webView = webView

        // 啟動 Debug Server（在設置 WebView 後）
        #if os(macOS)
        startDebugServer()
        #endif
    }

    // MARK: - Bot Methods

    func createNativeBot(playerId: Int, is3P: Bool) async throws {
        guard let controller = nativeBotController else {
            throw NSError(domain: "Naki", code: -1, userInfo: [NSLocalizedDescriptionKey: "Bot 控制器未初始化"])
        }

        try controller.createBot(playerId: UInt8(playerId), is3P: is3P)

        // 更新狀態
        botStatus = controller.botState
        statusMessage = "Bot 已建立 (Player \(playerId))"

        bridgeLog("[LegacyWebViewModel] Bot 已為玩家 \(playerId) 建立 (is3P: \(is3P))")
    }

    func processNativeEvent(_ event: [String: Any]) async throws -> [String: Any]? {
        guard let controller = nativeBotController else { return nil }

        let eventType = event["type"] as? String ?? "unknown"
        bridgeLog("[LegacyWebViewModel] 處理事件: \(eventType)")

        // 處理事件並獲取回應
        let response = try await controller.react(event: event)

        // 更新 UI 狀態
        updateUIAfterBotResponse(from: controller)

        return response
    }

    func processNativeEvents(_ events: [[String: Any]]) async throws -> [String: Any]? {
        guard let controller = nativeBotController else { return nil }

        let response = try await controller.react(events: events)

        // 更新 UI 狀態
        updateUIAfterBotResponse(from: controller)

        return response
    }

    func deleteNativeBot() {
        nativeBotController?.deleteBot()
        botStatus = BotStatus()
        recommendations = []
        tehaiTiles = []
        tsumoTile = nil
        highlightedTile = nil
        // 與主路徑同一條清理規則：`GameStateManager` 才是 SwiftUI 面板的資料來源，
        // 不一併重置的話對局結束後畫面會停在上一局的手牌與推薦。
        gameStateManager.reset()
        statusMessage = "Bot 已清除"
        bridgeLog("[LegacyWebViewModel] Bot 已刪除")
    }

    func resyncBot() async {
        // 由 LegacyWebViewCoordinator 處理
        statusMessage = "重新同步 Bot..."
    }

    func forceReconnect() async {
        webView?.reload()
        statusMessage = "正在重新連接..."
    }

    // MARK: - UI Update After Bot Response

    private func updateUIAfterBotResponse(from controller: NativeBotController) {
        // 更新遊戲狀態
        gameState = controller.gameState
        botStatus = controller.botState
        tehaiTiles = controller.tehaiMjai
        tsumoTile = controller.lastTsumo
        recommendations = controller.lastRecommendations
        recommendationCount = recommendations.count

        // 同步到 GameStateManager（供 UI 回應式更新）
        gameStateManager.syncFrom(controller: controller)

        // 更新推薦顯示（這條路徑不自動送出，見 `supportsAutoPlay`）
        //
        // `.off` 不顯示推薦：`highlightedTile` 必須跟著空，否則它會宣稱
        // 畫面上標了一張其實沒有標的牌（側欄的閘門在 `RecommendationView`）。
        highlightedTile = autoPlayMode.showRecommendation
            ? recommendations.first?.displayTile : nil

        // 註：「oplist 有和牌但模型無推薦 → 強制交給 resolver」的 fail-safe 只存在於主路徑
        // （`AutoPlayGate.forceHora`）。這裡不再抄一份殘缺版：它以前也只在 `.auto` 才動作，
        // 而這條路的模式永遠不是 `.auto`，留著只是一段永遠不會執行的程式碼。
    }

    // MARK: - Auto Play Methods

    /// 設定自動打牌模式。
    ///
    /// 以前這裡只改記憶體、沒有寫進 UserDefaults——Legacy 路徑選的模式重啟就消失，
    /// 而 UI picker 又另外存自己的 key，兩邊講的話可以不一樣。現在與主路徑共用
    /// `AutoPlayModeStore`。
    ///
    /// `.auto` 在這條路徑上一律降級成 `.recommend`（見 `supportsAutoPlay`）。
    /// UI 的 picker 本來就不會列出「自動」，這裡是最後一道閘門：MCP、舊存檔或
    /// 之後任何呼叫端都不該有辦法在沒驗過的路徑上打開自動送出。
    func setAutoPlayMode(_ mode: AutoPlayMode) {
        let effective = AutoPlayAvailability.commit(mode, autoPlaySupported: supportsAutoPlay)
        autoPlayMode = effective
        // 切到 `.off` 時把「現在標了哪一張」收掉；切回來時由下一次 Bot 回應填上。
        if !effective.showRecommendation {
            highlightedTile = nil
        }
        if effective != mode {
            statusMessage = "此裝置不支援自動送出，已改為推薦模式"
            bridgeLog("[LegacyWebViewModel] 要求 \(mode.rawValue) → 降級為 \(effective.rawValue)："
                + AutoPlayAvailability.autoUnavailableReason)
        } else {
            bridgeLog("[LegacyWebViewModel] 自動打牌模式設定為: \(effective.rawValue)")
        }
    }

    // 註：`setAutoPlayDelay` / `confirmAutoPlayAction` / `cancelAutoPlayAction` 已移除，
    // 三個都是沒有實作內容的空殼（延遲由 `ActionDelayModel` 決定，也沒有待確認動作可取消）。

    func triggerAutoPlayNow(delay: TimeInterval) {
        // 與主路徑共用同一個 resolver。
        //
        // 這條路徑先前是直接送 `recommendations.first`——沒有 oplist 合法性檢查、
        // 沒有座位檢查、沒有過期檢查，也沒有 fail-closed。也就是說
        // 「伺服器說可以自摸但 AI 想打牌」時，它會忠實把和牌牌打掉，
        // 而那正是主路徑用 resolver 防住的問題。
        //
        // 沒有理由讓兩條路的安全性不同——合法性的權威在伺服器，跟走哪個 WebView 無關。
        //
        // 又：這條路的 `autoPlayMode` 永遠不是 `.auto`（見 `supportsAutoPlay`），
        // 所以 resolver 對每一批 oplist 的結論一定是 `.surfaceOnly` 或 `.none`，
        // 底下的送出分支在目前的路線 A 下不會被走到。刻意不改成「直接 return」：
        // 收斂的權威是模式閘門一處，不是散在各呼叫端的第二道 if。
        let snapshot = LiqiOperationStore.shared.pending
        let mode = autoPlayMode
        // 座位來源與主路徑同一份定義（`WebViewModelProtocol.autoPlaySeat`）。
        // 先前這裡讀 `botStatus.playerId`，`deleteNativeBot()` 之後會變 0 而 gameState 不會，
        // 於是同一個局面在兩條路上可以得到不同的 seat 判定。
        let seat = autoPlaySeat

        let decision = AutoPlayDecisionResolver.resolve(
            snapshot: snapshot, recommendations: recommendations, mode: mode, seat: seat,
            // 三麻 fail-closed 與主路徑同一條規則：只有四麻模型，不自動送出。
            isSanma: gameState.is3P)

        guard case .send(let action, let tile) = decision else {
            switch decision {
            case .none(let reason):
                bridgeLog("[LegacyWebViewModel] 不送出: \(reason)")
            case .surfaceOnly(let action, let tile):
                // 「為什麼沒送」必須看得到，否則推薦模式下的每一次不動作都無從查證
                bridgeLog("[LegacyWebViewModel] 僅顯示不送出: \(action.rawValue) \(tile)")
            case .send:
                break   // guard 已排除
            }
            return
        }

        if let top = recommendations.first, action != top.actionType {
            bridgeLog("[LegacyWebViewModel] ⚠️ 決策覆蓋: AI 建議 \(top.actionType.rawValue) → 送出 \(action.rawValue)")
        }

        Task { [weak self] in
            guard let self else { return }
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            // 延遲期間對局可能已經往前走，送出前再確認一次這批 oplist 還是原來那批
            guard let snapshot,
                  AutoPlayDecisionResolver.isStillValid(
                    decidedOn: snapshot, current: LiqiOperationStore.shared.pending)
            else {
                bridgeLog("[LegacyWebViewModel] ⏭️ oplist 已更新，捨棄過期決策")
                return
            }
            await self.sendAction(actionType: action, tileName: tile)
        }
    }

    /// 依推薦組出對應的 Liqi 請求並送出。
    ///
    /// 7-case switch 與「成功才 markHandled」都在 `AutoPlayActionExecutor`（p2-1 收斂）——
    /// 這條路以前是自己抄一份，抄的時候把所有診斷輸出與「吃的組合對照不到」的警告
    /// 都漏掉了，於是 Legacy 送出去的是什麼、為什麼沒送，事後完全查不到。
    ///
    /// 與主路徑唯一剩下的差別是**沒有重試框架**：送一次、記錄結果，
    /// 失敗就等下一次推薦更新再送（缺口清單與收斂決策見 p2-2）。
    private func sendAction(actionType: Recommendation.ActionType, tileName: String) async {
        await AutoPlayActionExecutor.execute(
            action: actionType,
            tile: tileName,
            snapshot: LiqiOperationStore.shared.pending,
            recommendations: recommendations,
            tsumoTile: tsumoTile,
            sender: liqiSender,
            store: LiqiOperationStore.shared,
            log: { self.autoPlayLog($0) },
            event: { self.autoPlayLog($0, isEvent: true) })
    }

    /// Legacy 路徑的診斷輸出路由（`liqiSender.logHandler` 與 executor 共用）。
    ///
    /// macOS 有 Debug Server 時走它的 buffer（`addLog` 內部就會寫進 LogManager），
    /// 否則退回 `bridgeLog`；兩者都寫會讓同一件事在 `/logs` 出現兩次。
    ///
    /// - Parameter isEvent: 「為什麼沒送出」這類關鍵事件，額外寫進當次 session 的
    ///   events.log（與主路徑 `logAutoPlayEvent` 同一條規則）。
    private func autoPlayLog(_ message: String, isEvent: Bool = false) {
        let line = "[LegacyWebViewModel] \(message)"
        if isEvent {
            eventLog(line)
        }
        #if os(macOS)
        if let server = debugServer {
            server.addLog(line)
            return
        }
        #endif
        bridgeLog(line)
    }

    // 註：`triggerAutoPlay(recommendation:)`（0.5 秒防抖 + `guard autoPlayMode == .auto`）
    // 已移除。這條路徑的模式永遠不是 `.auto`，那個 guard 之後的程式碼沒有任何執行路徑；
    // 留著會讓人以為 Legacy 仍會自己送牌。唯一的送出入口是 `triggerAutoPlayNow`
    // （協定要求的手動觸發點），而它照樣要過 resolver 的模式閘門。

    // MARK: - Settings

    func setHidePlayerNames(_ hide: Bool) {
        // 與主路徑同一條協定層實作；舊的 `__nakiPlayerNames` 依賴不存在的 uiscript。
        UserDefaults.standard.set(hide, forKey: "HidePlayerNames")
        Task {
            _ = try? await executeJavaScript("window.__nakiHideNames?.setEnabled(\(hide)) ?? false")
        }
    }

    func getPlayerNamesStatus() async -> [String: Any]? {
        let script = "JSON.stringify(window.__nakiHideNames?.getStatus() || {available: false})"
        if let result = try? await executeJavaScript(script) as? String,
           let data = result.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return json
        }
        return nil
    }

    func resetHideNamesSettings() {
        hasAppliedHideNamesSettings = false
    }

    /// 頁面載入完成後把持久化的隱藏名稱設定推回 JS
    ///
    /// JS 模組的開關存在 closure 變數裡，reload 會歸零；不重推的話設定只在
    /// 當次載入有效。
    func applyHideNamesSettingsIfNeeded() {
        guard !hasAppliedHideNamesSettings else { return }
        hasAppliedHideNamesSettings = true
        guard UserDefaults.standard.bool(forKey: "HidePlayerNames") else { return }
        setHidePlayerNames(true)
    }

    // MARK: - Debug Server

    #if os(macOS)
    func startDebugServer() {
        guard debugServer == nil else {
            statusMessage = "Debug Server 已在運行"
            return
        }

        debugServer = DebugServer(port: debugServerPort)

        // 設定 JavaScript 執行回調
        debugServer?.executeJavaScript = { [weak self] script, completion in
            guard let webView = self?.webView else {
                completion(nil, NSError(domain: "Naki", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "WebView not available"]))
                return
            }

            Task { @MainActor in
                // WKWebView 的 evaluateJavaScript 需要包裝成 IIFE
                let wrappedScript = "(function() { \(script) })()"

                webView.evaluateJavaScript(wrappedScript) { result, error in
                    if let error = error {
                        bridgeLog("[JS 除錯] 錯誤: \(error)")
                        completion(nil, error)
                    } else {
                        bridgeLog("[JS 除錯] 結果: \(String(describing: result))")
                        completion(result, nil)
                    }
                }
            }
        }

        // 狀態列回調——只更新 UI（log 由 DebugServer.log() 單一寫入 LogManager）
        debugServer?.onStatusMessage = { [weak self] message in
            Task { @MainActor in
                self?.statusMessage = message
            }
        }

        // 設定 Bot 狀態回調
        debugServer?.getBotStatus = { [weak self] in
            guard let self = self else { return [:] }

            let recs: [[String: Any]] = self.recommendations.map { rec in
                [
                    "tile": rec.displayTile,
                    "action": rec.actionType.rawValue,
                    "label": rec.displayLabel,
                    "prob": rec.probability,
                    "percentage": rec.percentageString,
                ]
            }

            return [
                "botStatus": [
                    "isActive": self.botStatus.isActive,
                    "playerId": self.botStatus.playerId,
                ],
                "gameState": [
                    "bakaze": self.gameState.bakazeDisplay,
                    "kyoku": self.gameState.kyoku,
                    "honba": self.gameState.honba,
                ],
                // `isMyTurn` / `hasPendingAction` 已移除（來源恆 false／恆 nil 的假欄位）
                "autoPlay": [
                    "mode": self.autoPlayMode.rawValue
                ],
                "recommendations": recs,
                "tehaiCount": self.tehaiTiles.count,
                "tsumoTile": self.tsumoTile as Any,
            ]
        }

        debugServer?.start()
        isDebugServerRunning = true
        statusMessage = "Debug Server 已啟動 (port \(debugServerPort))"
        bridgeLog("[LegacyWebViewModel] Debug Server 已啟動")
    }

    func stopDebugServer() {
        debugServer?.stop()
        debugServer = nil
        isDebugServerRunning = false
        statusMessage = "Debug Server 已停止"
    }

    func toggleDebugServer() {
        if isDebugServerRunning {
            stopDebugServer()
        } else {
            startDebugServer()
        }
    }
    #else
    func startDebugServer() {}
    func stopDebugServer() {}
    func toggleDebugServer() {}
    #endif

    // MARK: - JavaScript Execution

    func executeJavaScript(_ script: String) async throws -> Any? {
        guard let webView = webView else {
            throw NSError(domain: "Naki", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "WebView not available"])
        }

        // WKWebView 的 evaluateJavaScript 需要包裝成 IIFE
        let wrappedScript = "(function() { \(script) })()"

        return try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(wrappedScript) { result, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: result)
                }
            }
        }
    }

    // MARK: - URL Loading

    func loadMajsoul() async {
        guard let webView = webView else {
            statusMessage = "WebView 未初始化"
            return
        }

        if let url = URL(string: "https://game.maj-soul.com/1/") {
            webView.load(URLRequest(url: url))
            statusMessage = "正在加載雀魂麻將..."
        }
    }

    func loadURL(_ urlString: String) async {
        guard let webView = webView,
              let url = URL(string: urlString) else {
            return
        }
        webView.load(URLRequest(url: url))
    }

    func reload() {
        webView?.reload()
    }
}

