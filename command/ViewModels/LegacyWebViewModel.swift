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

    /// 自動打牌服務
    private var autoPlayService = AutoPlayService()

    /// 自動打牌控制器
    private var autoPlayController: AutoPlayController?

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

        // 初始化自動打牌控制器
        autoPlayController = AutoPlayController()

        // 設定 AutoPlayService 委託和 JavaScript 執行器
        autoPlayService.delegate = self
        autoPlayService.setJSExecutor { [weak self] script in
            try await self?.executeJavaScript(script)
        }
        autoPlayController?.setJSExecutor { [weak self] script in
            try await self?.executeJavaScript(script)
        }

        // 自動設定全自動打牌模式
        autoPlayController?.setMode(.auto)

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
        }
    }

    // MARK: - Auto Play Methods

    func setAutoPlayMode(_ mode: AutoPlayMode) {
        autoPlayController?.setMode(mode)
    }

    func setAutoPlayDelay(_ delay: TimeInterval) {
        // AutoPlayController 不直接支援 setDelay，使用 triggerAction 的 delay 參數
    }

    func confirmAutoPlayAction() {
        // AutoPlayController 不直接支援 confirmAction
    }

    func cancelAutoPlayAction() {
        autoPlayController?.cancelPendingAction()
    }

    func triggerAutoPlayNow(delay: TimeInterval) {
        if let firstRec = recommendations.first {
            autoPlayService.triggerAction(
                actionType: firstRec.actionType,
                tileName: firstRec.displayTile,
                delay: delay
            )
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
        guard autoPlayController?.state.mode == .auto else { return }

        // 使用 AutoPlayService 觸發動作
        autoPlayService.triggerAction(
            actionType: recommendation.actionType,
            tileName: recommendation.displayTile,
            delay: 1.2
        )
    }

    // MARK: - Settings

    func setHighlightSettings(showRotatingEffect: Bool) {
        Task {
            let script = """
            (function() {
                if (window.__nakiRecommendHighlight) {
                    window.__nakiRecommendHighlight.setSettings({
                        showRotatingEffect: \(showRotatingEffect)
                    });
                    return true;
                }
                return false;
            })()
            """
            _ = try? await executeJavaScript(script)
        }
    }

    func setHidePlayerNames(_ hide: Bool) {
        Task {
            let script = hide
                ? "window.__nakiPlayerNames?.hide() || false"
                : "window.__nakiPlayerNames?.show() || false"
            _ = try? await executeJavaScript(script)
        }
    }

    func getPlayerNamesStatus() async -> [String: Any]? {
        let script = "JSON.stringify(window.__nakiPlayerNames?.getStatus() || {available: false})"
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
                "autoPlay": [
                    "mode": self.autoPlayController?.state.mode.rawValue ?? "unknown",
                    "isMyTurn": self.autoPlayController?.state.isMyTurn ?? false,
                    "hasPendingAction": self.autoPlayController?.state.pendingAction != nil,
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

    // MARK: - Game Events

    func onAddHandPai(handCount: Int) async {
        bridgeLog("[LegacyWebViewModel] 摸牌事件: handCount=\(handCount)")
        // 可以在這裡觸發相關邏輯
    }
}

// MARK: - AutoPlayServiceDelegate

@available(macOS 14.0, iOS 17.0, *)
extension LegacyWebViewModel: AutoPlayServiceDelegate {
    func autoPlayService(_ service: AutoPlayService, didLog message: String) {
        bridgeLog("[AutoPlay] \(message)")
    }

    func autoPlayService(_ service: AutoPlayService, didComplete actionType: Recommendation.ActionType) {
        bridgeLog("[LegacyWebViewModel] 自動打牌完成: \(actionType.rawValue)")
        recommendations = []
    }

    func autoPlayService(_ service: AutoPlayService, didFail actionType: Recommendation.ActionType, error: String) {
        bridgeLog("[LegacyWebViewModel] 自動打牌失敗: \(actionType.rawValue) - \(error)")
    }
}
