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
                        // 連接時重置橋接器和 Bot
                        self.websocketHandler.reset()
                        self.parent.viewModel.deleteNativeBot()
                        self.parent.viewModel.recommendations = []
                        self.parent.viewModel.tehaiTiles = []
                        self.parent.viewModel.tsumoTile = nil
                        print("[Coordinator] Reset state on WebSocket connect")
                    } else {
                        // 斷開連接時清理 Bot 狀態
                        self.parent.viewModel.deleteNativeBot()
                        self.parent.viewModel.recommendations = []
                        self.parent.viewModel.tehaiTiles = []
                        self.parent.viewModel.tsumoTile = nil
                        print("[Coordinator] Reset state on WebSocket disconnect")
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
                // ⭐ 開始遊戲，每次都重建 Bot（匹配 Python 行為）
                if let playerId = event["id"] as? Int {
                    bridgeLog("[Coordinator] start_game: (re)creating bot for player \(playerId)")
                    do {
                        // ⭐ 關鍵：先刪除舊 Bot，再創建新的
                        // Python 每次 start_game 都會 model = model.load_model()
                        parent.viewModel.deleteNativeBot()

                        try await parent.viewModel.createNativeBot(playerId: playerId)
                        parent.viewModel.statusMessage = "Bot 已創建 (Player \(playerId))"

                        // 將 start_game 事件也發送給 Bot
                        _ = try await parent.viewModel.processNativeEvent(event)
                        bridgeLog("[Coordinator] start_game: bot created and event sent")
                    } catch {
                        bridgeLog("[Coordinator] ERROR: Failed to create bot: \(error)")
                    }
                } else {
                    bridgeLog("[Coordinator] ERROR: start_game has no id field!")
                }

            case "start_kyoku":
                // 開始新一局，判斷是否為三麻
                bridgeLog("[Coordinator] start_kyoku: processing new kyoku")
                if let scores = event["scores"] as? [Int] {
                    let is3P = scores.count == 3 ||
                               (scores.count == 4 && scores[3] == 0)

                    if is3P {
                        parent.viewModel.statusMessage = "三麻模式"
                    }
                }
                // 將 start_kyoku 發送給 Bot 處理
                do {
                    bridgeLog("[Coordinator] Sending start_kyoku to bot")
                    if let response = try await parent.viewModel.processNativeEvent(event) {
                        bridgeLog("[Coordinator] Bot Response: \(response)")
                        // UI 已通過 viewModel 的 @Observable 屬性自動更新
                    } else {
                        bridgeLog("[Coordinator] Bot returned nil for start_kyoku")
                    }
                } catch {
                    bridgeLog("[Coordinator] ERROR: Bot react error: \(error)")
                }

            case "end_game":
                // ⭐ 遊戲結束，發送事件給 Bot 然後刪除 Bot
                bridgeLog("[Coordinator] end_game: cleaning up bot")
                do {
                    _ = try await parent.viewModel.processNativeEvent(event)
                } catch {
                    bridgeLog("[Coordinator] ERROR: Failed to process end_game: \(error)")
                }
                parent.viewModel.deleteNativeBot()
                parent.viewModel.recommendations = []
                parent.viewModel.tehaiTiles = []
                parent.viewModel.tsumoTile = nil
                parent.viewModel.statusMessage = "遊戲結束"

            default:
                // 將事件發送給 Bot 處理
                do {
                    bridgeLog("[Coordinator] Sending \(eventType) to bot")
                    if let response = try await parent.viewModel.processNativeEvent(event) {
                        // 有動作回應，可以在這裡處理 autoplay
                        bridgeLog("[Coordinator] Bot Response: \(response)")
                        // UI 已通過 viewModel 的 @Observable 屬性自動更新
                    } else {
                        bridgeLog("[Coordinator] Bot returned nil for \(eventType)")
                    }
                } catch {
                    bridgeLog("[Coordinator] ERROR: Bot react error: \(error)")
                }
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

            // 頁面重新載入時完整重置狀態（包括 accountId）
            websocketHandler.fullReset()
            parent.viewModel.deleteNativeBot()
            parent.viewModel.recommendations = []
            parent.viewModel.tehaiTiles = []
            parent.viewModel.tsumoTile = nil
            parent.viewModel.isConnected = false
            print("[Coordinator] Full reset on page reload")
        }
    }
}
