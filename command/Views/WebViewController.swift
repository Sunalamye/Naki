//
//  WebViewController.swift
//  akagi
//
//  Created by Suoie on 2025/11/29.
//  Updated: 2025/12/04 - 使用 WebPage API (macOS 26.0+)
//

import SwiftUI
import WebKit

// MARK: - Naki WebView (使用 WebPage API)

/// 主要的 WebView 元件，使用 macOS 26.0+ 的 WebPage API
struct NakiWebView: View {
    var viewModel: WebViewModel

    var body: some View {
        if let webPage = viewModel.webPage {
            WebView(webPage)
                .task {
                    await viewModel.loadMajsoul()
                }
        } else {
            ProgressView("正在初始化...")
        }
    }
}

// MARK: - Navigation Decider

/// 導覽決策器，處理 WebPage 的導覽事件
@MainActor
class NakiNavigationDecider: WebPage.NavigationDeciding {
    weak var viewModel: WebViewModel?

    init(viewModel: WebViewModel?) {
        self.viewModel = viewModel
    }

    func decidePolicy(for action: WebPage.NavigationAction, preferences: inout WebPage.NavigationPreferences) async -> WKNavigationActionPolicy {
        // 允许所有導覽
        return .allow
    }

    func decidePolicy(for response: WebPage.NavigationResponse) async -> WKNavigationResponsePolicy {
        return .allow
    }

    func decideAuthenticationChallengeDisposition(for challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        return (.performDefaultHandling, nil)
    }
}

// MARK: - Dialog Presenter

/// 對話框展示器，處理 JavaScript 對話框
@MainActor
class NakiDialogPresenter: WebPage.DialogPresenting {
    weak var viewModel: WebViewModel?

    init(viewModel: WebViewModel?) {
        self.viewModel = viewModel
    }

    func handleJavaScriptAlert(message: String, initiatedBy frame: WebPage.FrameInfo) async {
        bridgeLog("[JS Alert] \(message)")
    }

    func handleJavaScriptConfirm(message: String, initiatedBy frame: WebPage.FrameInfo) async -> WebPage.JavaScriptConfirmResult {
        bridgeLog("[JS Confirm] \(message)")
        return .ok
    }

    func handleJavaScriptPrompt(message: String, defaultText: String?, initiatedBy frame: WebPage.FrameInfo) async -> WebPage.JavaScriptPromptResult {
        bridgeLog("[JS Prompt] \(message)")
        return .cancel
    }

    func handleFileInputPrompt(parameters: WKOpenPanelParameters, initiatedBy frame: WebPage.FrameInfo) async -> WebPage.FileInputPromptResult {
        return .cancel
    }
}

// MARK: - Naki Web Coordinator

// 注意：WebSocketMessageHandler 已移至 WebSocketInterceptor.swift
// 注意：MJAIEventStream 已移至 Services/Bridge/MJAIEventStream.swift

/// 協調器，管理 WebSocket 訊息處理和 MJAI 事件流
@MainActor
class NakiWebCoordinator {
    weak var viewModel: WebViewModel?

    /// WebSocket 訊息處理器
    let websocketHandler = WebSocketMessageHandler()

    /// MJAI 事件流管理器
    let eventStream = MJAIEventStream()

    init(viewModel: WebViewModel?) {
        self.viewModel = viewModel
        setupWebSocketCallbacks()
    }

    /// 設定 WebSocket 回调
    private func setupWebSocketCallbacks() {
        websocketHandler.onMJAIEvent = { [weak self] event in
            guard let self = self else { return }

            Task { @MainActor in
                await self.handleMJAIEvent(event)
            }
        }

        websocketHandler.onWebSocketStatusChanged = { [weak self] connected in
            guard let self = self else { return }

            Task { @MainActor in
                self.viewModel?.isConnected = connected
                self.viewModel?.statusMessage = connected
                    ? "已連線到雀魂服务器"
                    : "已斷開連線"

                if connected {
                    self.websocketHandler.reset()

                    if self.eventStream.canResync() {
                        print("[Coordinator] WebSocket reconnected, attempting to resync bot...")
                        await self.resyncBot()
                    } else {
                        self.viewModel?.deleteNativeBot()
                        self.viewModel?.recommendations = []
                        self.viewModel?.tehaiTiles = []
                        self.viewModel?.tsumoTile = nil
                        print("[Coordinator] Reset state on WebSocket connect (no game in progress)")
                    }
                } else {
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

        switch eventType {
        case "start_game":
            guard let playerId = event["id"] as? Int else {
                bridgeLog("[Coordinator] ERROR: start_game has no id field!")
                return
            }

            bridgeLog("[Coordinator] start_game: starting new game for player \(playerId)")

            eventStream.startNewGame()
            eventStream.emit(event)
            viewModel?.deleteNativeBot()

            do {
                try await viewModel?.createNativeBot(playerId: playerId)
                viewModel?.statusMessage = "Bot 已建立 (Player \(playerId))"
                bridgeLog("[Coordinator] Bot created for player \(playerId)")
                startEventConsumer()
            } catch {
                bridgeLog("[Coordinator] ERROR: Failed to create bot: \(error)")
            }

        case "end_game":
            bridgeLog("[Coordinator] end_game: cleaning up")
            eventStream.emit(event)
            eventStream.endGame()
            viewModel?.deleteNativeBot()
            viewModel?.recommendations = []
            viewModel?.tehaiTiles = []
            viewModel?.tsumoTile = nil
            viewModel?.statusMessage = "游戏結束"

        default:
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
                if let response = try await self.viewModel?.processNativeEvent(event) {
                    bridgeLog("[Consumer] \(eventType) → response: \(response)")
                } else {
                    bridgeLog("[Consumer] \(eventType) → response: none")
                }
            } catch {
                bridgeLog("[Consumer] ERROR processing \(eventType): \(error)")
            }
        }
    }

    /// 重新同步 Bot（WebSocket 重连时或手動重建時使用）
    func resyncBot() async {
        guard let playerId = eventStream.getPlayerId() else {
            bridgeLog("[Coordinator] Cannot resync: no playerId found in history")
            return
        }

        bridgeLog("[Coordinator] Resyncing bot for player \(playerId) with \(eventStream.eventCount) historical events")

        viewModel?.deleteNativeBot()

        do {
            try await viewModel?.createNativeBot(playerId: playerId)
            viewModel?.statusMessage = "Bot 已重新同步 (Player \(playerId))"
            startEventConsumer()
            bridgeLog("[Coordinator] Bot resynced successfully")
        } catch {
            bridgeLog("[Coordinator] ERROR: Failed to resync bot: \(error)")
        }
    }

    /// 页面開始加载时的重置
    func handleNavigationStarted() {
        websocketHandler.fullReset()
        eventStream.endGame()
        viewModel?.deleteNativeBot()
        viewModel?.recommendations = []
        viewModel?.tehaiTiles = []
        viewModel?.tsumoTile = nil
        viewModel?.isConnected = false
        print("[Coordinator] Full reset on navigation start (including EventStream)")
    }
}
