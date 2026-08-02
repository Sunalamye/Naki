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
    private(set) var autoPlayMode: AutoPlayMode = AutoPlayModeStore.defaultMode

    /// Debug Server (macOS only)
    #if os(macOS)
    private var debugServer: DebugServer?
    #endif

    // MARK: - WKWebView Reference

    /// WKWebView 引用（由 LegacyNakiWebView 設置）
    weak var webView: WKWebView?

    /// 防止重複觸發自動打牌
    private var lastAutoPlayTriggerTime: Date = .distantPast
    private var lastAutoPlayActionType: Recommendation.ActionType?

    /// 是否已經套用過隱藏名稱設定
    private var hasAppliedHideNamesSettings = false

    // MARK: - Initialization

    init() {
        // 初始化原生 Bot 控制器
        nativeBotController = NativeBotController()

        // 動作送出改走協定層：Swift 端組好 Liqi envelope，JS 只負責把 base64 丟進 WebSocket
        liqiSender.logHandler = { [weak self] message in
            #if os(macOS)
            self?.debugServer?.addLog(message)
            #endif
            bridgeLog("[LegacyWebViewModel] \(message)")
        }
        liqiSender.sendHandler = { [weak self] base64 in
            guard let self else { return .failure("viewmodel_deallocated") }
            // base64 只含 A-Za-z0-9+/=，可安全放進單引號字串
            let script = "return JSON.stringify(window.__nakiWebSocket.sendRaw('\(base64)'))"
            do {
                let result = try await self.executeJavaScript(script)
                guard let json = result as? String,
                      let data = json.data(using: .utf8),
                      let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else {
                    return .failure("unparsable_js_result")
                }
                if dict["success"] as? Bool == true {
                    let bytes = dict["bytes"] as? Int ?? -1
                    let socketId = dict["socketId"].map { "\($0)" } ?? "?"
                    return LiqiRawSendResult(success: true, detail: "socket=\(socketId) bytes=\(bytes)")
                }
                return .failure(dict["reason"] as? String ?? "unknown_reason")
            } catch {
                return .failure("js_error: \(error.localizedDescription)")
            }
        }

        // 沿用上次選的模式（與主路徑同一個 key，不再每次啟動硬設 .auto）
        autoPlayMode = AutoPlayModeStore.load()

        statusMessage = "準備就緒 (Legacy 模式)"
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

        // 更新推薦顯示並觸發自動打牌
        if let firstRec = recommendations.first {
            highlightedTile = firstRec.displayTile
            triggerAutoPlay(recommendation: firstRec)
        } else if LiqiOperationStore.shared.pending?.horaOperation != nil {
            // 伺服器提供和牌時，不因為模型沒意見就放過（與主路徑同一條規則）
            bridgeLog("[LegacyWebViewModel] 🎯 oplist 有和牌但模型無推薦 → 交給 resolver")
            if autoPlayMode == .auto {
                triggerAutoPlayNow(delay: 0)
            }
        }
    }

    // MARK: - Auto Play Methods

    /// 設定自動打牌模式。
    ///
    /// 以前這裡只改記憶體、沒有寫進 UserDefaults——Legacy 路徑選的模式重啟就消失，
    /// 而 UI picker 又另外存自己的 key，兩邊講的話可以不一樣。現在與主路徑共用
    /// `AutoPlayModeStore`。
    func setAutoPlayMode(_ mode: AutoPlayMode) {
        autoPlayMode = mode
        AutoPlayModeStore.save(mode)
        bridgeLog("[LegacyWebViewModel] 自動打牌模式設定為: \(mode.rawValue)")
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
        let snapshot = LiqiOperationStore.shared.pending
        let mode = autoPlayMode
        let seat = botStatus.playerId

        let decision = AutoPlayDecisionResolver.resolve(
            snapshot: snapshot, recommendations: recommendations, mode: mode, seat: seat)

        guard case .send(let action, let tile) = decision else {
            if case .none(let reason) = decision {
                bridgeLog("[LegacyWebViewModel] 不送出: \(reason)")
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
    /// 與主路徑 `WebViewModel.executeAutoPlayAction` 同一套語意，
    /// 差別只在這裡沒有重試框架——Legacy 走的是舊 WKWebView，
    /// 保持單純：送一次、記錄結果，失敗就等下一次推薦更新再送。
    private func sendAction(actionType: Recommendation.ActionType, tileName: String) async {
        let snapshot = LiqiOperationStore.shared.pending
        var result: LiqiSendResult?

        switch actionType {
        case .discard:
            guard let majsoulTile = LiqiTileCode.majsoul(fromMJAI: tileName) else { return }
            result = await liqiSender.discard(tile: majsoulTile, moqie: tsumoTile == tileName)

        case .riichi:
            guard let discardRec = recommendations.first(where: { $0.actionType == .discard }),
                  let majsoulTile = LiqiTileCode.majsoul(fromMJAI: discardRec.displayTile)
            else { return }
            result = await liqiSender.riichi(tile: majsoulTile,
                                             moqie: tsumoTile == discardRec.displayTile)

        case .chi:
            var variant = 0
            if tileName.hasPrefix("chi_"), let idx = Int(String(tileName.dropFirst(4))) {
                variant = idx
            }
            result = await liqiSender.chi(index: UInt32(snapshot?.chiCombinationIndex(variant: variant) ?? 0))

        case .pon:
            result = await liqiSender.pon()

        case .kan:
            result = await liqiSender.kan(type: snapshot?.kanOperation ?? .ankan)

        case .hora:
            let horaType = snapshot?.horaOperation ?? .tsumo
            result = horaType == .ron ? await liqiSender.ron() : await liqiSender.tsumo()

        case .none:
            let channel: LiqiActionChannel =
                (snapshot?.isCallOpportunity ?? true) ? .chiPengGang : .selfOperation
            result = await liqiSender.pass(channel: channel)

        case .unknown:
            return
        }

        if result?.success == true, let seq = snapshot?.sequence {
            LiqiOperationStore.shared.markHandled(seq)
        }
    }

    private func triggerAutoPlay(recommendation: Recommendation) {
        // 防抖動檢查
        let now = Date()
        if now.timeIntervalSince(lastAutoPlayTriggerTime) < 0.5,
           lastAutoPlayActionType == recommendation.actionType {
            return
        }

        lastAutoPlayTriggerTime = now
        lastAutoPlayActionType = recommendation.actionType

        // 檢查是否為自動模式
        guard autoPlayMode == .auto else { return }

        triggerAutoPlayNow(delay: 1.2)
    }

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

        // 設定日誌回調
        debugServer?.onLog = { [weak self] message in
            bridgeLog(message)
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

