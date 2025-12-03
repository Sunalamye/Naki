//
//  WebViewController.swift
//  akagi
//
//  Created by Suoie on 2025/11/29.
//  混合方案：結合原生 WebView 和 WKWebView 的優勢
//  Updated: 2025/11/30 - 添加 WebSocket 攔截功能
//

import SwiftUI
import WebKit

// MARK: - 方案 1: 簡單的原生 WebView（僅用於顯示網頁）

struct SimpleWebView: View {
    var viewModel: WebViewModel

    var body: some View {
        if let webPage = viewModel.webPage {
            WebView(webPage)
                .task {
                    await viewModel.loadHTML()
                }
        } else {
            ProgressView("正在初始化...")
        }
    }
}

// MARK: - 方案 2: 完整功能的 WKWebView（支援 JavaScript Bridge + WebSocket 攔截）

struct NakiWebView: NSViewRepresentable {
    var viewModel: WebViewModel

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let userContentController = WKUserContentController()

        // 註冊 JavaScript Bridge 處理器
        userContentController.add(context.coordinator, name: "swiftBridge")

        // 註冊 WebSocket 攔截處理器
        userContentController.add(context.coordinator.websocketHandler, name: "websocketBridge")

        // 注入 WebSocket 攔截腳本（在頁面加載前）
        let websocketScript = WebSocketInterceptor.createUserScript()
        userContentController.addUserScript(websocketScript)

        configuration.userContentController = userContentController

        // 允許所有媒體播放（雀魂需要）
        configuration.mediaTypesRequiringUserActionForPlayback = []

        #if os(iOS)
        configuration.allowsInlineMediaPlayback = true
        #endif

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator

        // 啟用 Web Inspector（僅用於開發調試）
        #if DEBUG
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }
        #endif

        // 設置 WebSocket 回調
        context.coordinator.setupWebSocketCallbacks()

        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // 將 webView 引用儲存到 viewModel
        if viewModel.wkWebView == nil {
            Task { @MainActor in
                viewModel.wkWebView = webView
                await viewModel.loadHTMLInWKWebView()
            }
        }
    }

    class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: NakiWebView

        /// WebSocket 消息處理器
        let websocketHandler = WebSocketMessageHandler()

        /// MJAI 事件流管理器
        let eventStream = MJAIEventStream()

        init(_ parent: NakiWebView) {
            self.parent = parent
        }

        /// 設置 WebSocket 回調
        func setupWebSocketCallbacks() {
            // 當收到 MJAI 事件時
            websocketHandler.onMJAIEvent = { [weak self] event in
                guard let self = self else { return }

                Task { @MainActor in
                    await self.handleMJAIEvent(event)
                }
            }

            // 當 WebSocket 連接狀態改變時
            websocketHandler.onWebSocketStatusChanged = { [weak self] connected in
                guard let self = self else { return }

                Task { @MainActor in
                    self.parent.viewModel.isConnected = connected
                    self.parent.viewModel.statusMessage = connected
                        ? "已連接到雀魂服務器"
                        : "已斷開連接"

                    if connected {
                        // 連接時重置橋接器
                        self.websocketHandler.reset()

                        // ⭐ 嘗試重新同步 Bot
                        // 如果是頁面 reload，eventStream 已被清空，canResync() 返回 false
                        if self.eventStream.canResync() {
                            print("[Coordinator] WebSocket reconnected, attempting to resync bot...")
                            await self.resyncBot()
                        } else {
                            // 沒有進行中的遊戲，正常重置
                            self.parent.viewModel.deleteNativeBot()
                            self.parent.viewModel.recommendations = []
                            self.parent.viewModel.tehaiTiles = []
                            self.parent.viewModel.tsumoTile = nil
                            print("[Coordinator] Reset state on WebSocket connect (no game in progress)")
                        }
                    } else {
                        // 斷開連接時停止消費者（但保留歷史以便重連時重放）
                        self.eventStream.stopConsumer()
                        print("[Coordinator] WebSocket disconnected, consumer stopped (history preserved)")
                    }
                }
            }
        }

        /// 處理 MJAI 事件
        private func handleMJAIEvent(_ event: [String: Any]) async {
            guard let eventType = event["type"] as? String else { return }

            bridgeLog("[Coordinator] MJAI Event: \(eventType)")

            // 根據事件類型處理
            switch eventType {
            case "start_game":
                // ⭐ 開始遊戲，每次都重建 Bot
                guard let playerId = event["id"] as? Int else {
                    bridgeLog("[Coordinator] ERROR: start_game has no id field!")
                    return
                }

                bridgeLog("[Coordinator] start_game: starting new game for player \(playerId)")

                // 1. 清空舊的 EventStream 並開始新遊戲
                eventStream.startNewGame()

                // 2. 發送 start_game 事件到 stream
                eventStream.emit(event)

                // 3. 刪除舊 Bot，創建新 Bot
                parent.viewModel.deleteNativeBot()

                do {
                    try await parent.viewModel.createNativeBot(playerId: playerId)
                    parent.viewModel.statusMessage = "Bot 已創建 (Player \(playerId))"
                    bridgeLog("[Coordinator] Bot created for player \(playerId)")

                    // 4. 啟動 Consumer，開始消費事件
                    startEventConsumer()
                } catch {
                    bridgeLog("[Coordinator] ERROR: Failed to create bot: \(error)")
                }

            case "end_game":
                // ⭐ 遊戲結束，發送事件給 Bot 然後清理
                bridgeLog("[Coordinator] end_game: cleaning up")

                // 發送 end_game 事件到 stream
                eventStream.emit(event)

                // 結束遊戲（cancel Task, 清空歷史）
                eventStream.endGame()

                // 清理 Bot 和 UI 狀態
                parent.viewModel.deleteNativeBot()
                parent.viewModel.recommendations = []
                parent.viewModel.tehaiTiles = []
                parent.viewModel.tsumoTile = nil
                parent.viewModel.statusMessage = "遊戲結束"

            default:
                // 其他事件直接發送到 stream
                eventStream.emit(event)
            }
        }

        /// 啟動事件消費者
        private func startEventConsumer() {
            bridgeLog("[Coordinator] Starting event consumer...")

            eventStream.startConsumer { [weak self] event in
                guard let self = self else { return }

                let eventType = event["type"] as? String ?? "unknown"

                do {
                    if let response = try await self.parent.viewModel.processNativeEvent(event) {
                        bridgeLog("[Consumer] \(eventType) → response: \(response)")
                    } else {
                        bridgeLog("[Consumer] \(eventType) → response: none")
                    }
                } catch {
                    bridgeLog("[Consumer] ERROR processing \(eventType): \(error)")
                }
            }
        }

        /// 重新同步 Bot（WebSocket 重連時使用）
        private func resyncBot() async {
            guard let playerId = eventStream.getPlayerId() else {
                bridgeLog("[Coordinator] Cannot resync: no playerId found in history")
                return
            }

            bridgeLog("[Coordinator] Resyncing bot for player \(playerId) with \(eventStream.eventCount) historical events")

            // 刪除舊 Bot，創建新 Bot
            parent.viewModel.deleteNativeBot()

            do {
                try await parent.viewModel.createNativeBot(playerId: playerId)
                parent.viewModel.statusMessage = "Bot 已重新同步 (Player \(playerId))"

                // 啟動 Consumer（會自動重放歷史事件）
                startEventConsumer()

                bridgeLog("[Coordinator] Bot resynced successfully")
            } catch {
                bridgeLog("[Coordinator] ERROR: Failed to resync bot: \(error)")
            }
        }

        // MARK: - WKScriptMessageHandler

        func userContentController(_ userContentController: WKUserContentController,
                                  didReceive message: WKScriptMessage) {

            // 只處理 swiftBridge 的消息，websocketBridge 由專門的 handler 處理
            guard message.name == "swiftBridge" else { return }

            guard let body = message.body as? [String: Any],
                  let messageName = body["name"] as? String,
                  let params = body["params"] as? [String: Any] else {
                print("Invalid JavaScript message format")
                return
            }

            Task {
                switch messageName {
                case "createBot":
                    await handleCreateBot(params: params)

                case "sendEvent":
                    await handleSendEvent(params: params)

                case "deleteBot":
                    await handleDeleteBot(params: params)

                case "log":
                    if let msg = params["message"] as? String {
                        print("[WebView] \(msg)")
                    }

                default:
                    print("Unknown message: \(messageName)")
                }
            }
        }

        // MARK: - Bridge Handlers

        private func handleCreateBot(params: [String: Any]) async {
            guard let playerId = params["playerId"] as? Int else { return }

            do {
                try await parent.viewModel.createNativeBot(playerId: playerId)
                bridgeLog("[Bridge] Bot created for player \(playerId)")
            } catch {
                bridgeLog("[Bridge] ERROR: Failed to create bot: \(error.localizedDescription)")
            }
        }

        private func handleSendEvent(params: [String: Any]) async {
            guard let playerId = params["playerId"] as? Int,
                  let event = params["event"] as? [String: Any] else { return }

            do {
                if let response = try await parent.viewModel.processNativeEvent(event) {
                    bridgeLog("[Bridge] Bot action for player \(playerId): \(response)")
                }
            } catch {
                bridgeLog("[Bridge] ERROR: \(error.localizedDescription)")
            }
        }

        private func handleDeleteBot(params: [String: Any]) async {
            guard let playerId = params["playerId"] as? Int else { return }

            parent.viewModel.deleteNativeBot()
            bridgeLog("[Bridge] Bot deleted for player \(playerId)")
        }

        // MARK: - WKNavigationDelegate

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            print("[WebView] Page loaded successfully")
            parent.viewModel.statusMessage = "雀魂已加載，等待連接..."
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            print("[WebView] Failed to load: \(error.localizedDescription)")
            parent.viewModel.statusMessage = "加載失敗: \(error.localizedDescription)"
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            print("[WebView] Started loading...")
            parent.viewModel.statusMessage = "正在加載雀魂..."

            // 頁面重新載入時完整重置狀態（包括 accountId 和 EventStream）
            // ⭐ 清空 eventStream，之後 canResync() 會返回 false，不會觸發重放
            websocketHandler.fullReset()
            eventStream.endGame()
            parent.viewModel.deleteNativeBot()
            parent.viewModel.recommendations = []
            parent.viewModel.tehaiTiles = []
            parent.viewModel.tsumoTile = nil
            parent.viewModel.isConnected = false
            print("[Coordinator] Full reset on page reload (including EventStream)")
        }
    }
}
