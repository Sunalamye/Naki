//
//  WebViewController.swift
//  akagi
//
//  Created by Suoie on 2025/11/29.
//  Updated: 2025/12/05 - 使用 @Environment 取得 WebViewModel
//

import SwiftUI
import WebKit

// MARK: - Naki WebView (使用 WebPage API)

/// 主要的 WebView 元件，使用 macOS 26.0+ 的 WebPage API
struct NakiWebView: View {
    @Environment(\.webViewModel) private var viewModel

    var body: some View {
        if let webPage = viewModel?.webPage {
            WebView(webPage)
                .task {
                    await viewModel?.loadMajsoul()
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
        bridgeLog("[JS 警告] \(message)")
    }

    func handleJavaScriptConfirm(message: String, initiatedBy frame: WebPage.FrameInfo) async -> WebPage.JavaScriptConfirmResult {
        bridgeLog("[JS 確認] \(message)")
        return .ok
    }

    func handleJavaScriptPrompt(message: String, defaultText: String?, initiatedBy frame: WebPage.FrameInfo) async -> WebPage.JavaScriptPromptResult {
        bridgeLog("[JS 提示] \(message)")
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

    /// 設定 WebSocket 回調
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
                        print("[協調器] WebSocket 已重連, 嘗試重新同步 Bot...")
                        await self.resyncBot()
                    } else {
                        self.viewModel?.deleteNativeBot()
                        self.viewModel?.recommendations = []
                        self.viewModel?.tehaiTiles = []
                        self.viewModel?.tsumoTile = nil
                        print("[協調器] WebSocket 連線時重置狀態 (無進行中的遊戲)")
                    }
                } else {
                    self.eventStream.stopConsumer()
                    print("[協調器] WebSocket 已斷線, 消費者已停止 (歷史記錄已保留)")
                }
            }
        }
    }

    /// 處理 MJAI 事件
    private func handleMJAIEvent(_ event: [String: Any]) async {
        guard let eventType = event["type"] as? String else { return }

        bridgeLog("[協調器] MJAI 事件: \(eventType)")

        switch eventType {
        case "start_game":
            guard let playerId = event["id"] as? Int else {
                bridgeLog("[協調器] 錯誤: start_game 沒有 id 欄位!")
                return
            }

            bridgeLog("[協調器] start_game: 為玩家 \(playerId) 開始新遊戲")

            eventStream.startNewGame()
            eventStream.emit(event)
            viewModel?.deleteNativeBot()

            do {
                try await viewModel?.createNativeBot(playerId: playerId)
                viewModel?.statusMessage = "Bot 已建立 (Player \(playerId))"
                bridgeLog("[協調器] 已為玩家 \(playerId) 建立 Bot")
                startEventConsumer()
            } catch {
                bridgeLog("[協調器] 錯誤: 建立 Bot 失敗: \(error)")
            }

        case "end_game":
            bridgeLog("[協調器] end_game: 清理中")
            eventStream.emit(event)
            eventStream.endGame()
            viewModel?.deleteNativeBot()
            viewModel?.recommendations = []
            viewModel?.tehaiTiles = []
            viewModel?.tsumoTile = nil
            viewModel?.statusMessage = "遊戲結束"

        default:
            eventStream.emit(event)
        }
    }

    /// 啟動事件消費者
    private func startEventConsumer() {
        bridgeLog("[協調器] 啟動事件消費者...")

        eventStream.startConsumer { [weak self] event in
            guard let self = self else { return }

            let eventType = event["type"] as? String ?? "unknown"

            do {
                if let response = try await self.viewModel?.processNativeEvent(event) {
                    bridgeLog("[消費者] \(eventType) → 回應: \(response)")
                } else {
                    bridgeLog("[消費者] \(eventType) → 回應: 無")
                }
            } catch {
                bridgeLog("[消費者] 處理 \(eventType) 時發生錯誤: \(error)")
            }
        }
    }

    /// 重新同步 Bot（WebSocket 重連時或手動重建時使用）
    func resyncBot() async {
        guard let playerId = eventStream.getPlayerId() else {
            bridgeLog("[協調器] 無法重新同步: 歷史記錄中找不到 playerId")
            return
        }

        bridgeLog("[協調器] 為玩家 \(playerId) 重新同步 Bot, 歷史事件數: \(eventStream.eventCount)")

        viewModel?.deleteNativeBot()

        do {
            try await viewModel?.createNativeBot(playerId: playerId)
            viewModel?.statusMessage = "Bot 已重新同步 (Player \(playerId))"
            startEventConsumer()
            bridgeLog("[協調器] Bot 重新同步成功")
        } catch {
            bridgeLog("[協調器] 錯誤: Bot 重新同步失敗: \(error)")
        }
    }

    /// 頁面開始載入時的重置
    func handleNavigationStarted() {
        websocketHandler.fullReset()
        eventStream.endGame()
        viewModel?.deleteNativeBot()
        viewModel?.recommendations = []
        viewModel?.tehaiTiles = []
        viewModel?.tsumoTile = nil
        viewModel?.isConnected = false
        print("[協調器] 導覽開始時完整重置 (包含 EventStream)")
    }
}
