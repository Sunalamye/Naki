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
                // a11y: 雀魂 Laya/WebGL canvas 對 VoiceOver 與 XCUIElement 是黑盒。
                // 用 .ignore 折成單一語意葉節點（而非 .accessibilityHidden(true)，
                // 後者會把元素連同 identifier 一併移出 a11y tree，UI 測試就無法斷言存在），
                // 讓 VO 讀到「雀魂遊戲畫面」而不卡在無語意的 canvas，同時保留 identifier 供 UI 測試查詢。
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("雀魂遊戲畫面")
                .accessibilityIdentifier("majsoul-webview")
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

    /// #6: 事件序列化入口（intake）。過去每則 WS MJAI 事件各包一個獨立 `Task { @MainActor }`，
    /// 獨立 Task 間無順序保證、各自內部 await 會亂序；且 `start_game` 在 `await createNativeBot`
    /// 期間，後續事件的 Task 可能先跑 → 事件亂序 / 早於 bot 建立。
    /// 改為單一 buffered AsyncStream + 單一 consumer task 依序 `await handleMJAIEvent`，保證：
    ///   (1) FIFO：單一 stream / 單一 consumer，事件依到達順序處理；
    ///   (2) bot-ready-before-consume：start_game 的 handleMJAIEvent 會 `await createNativeBot`
    ///       並啟動 eventStream consumer 後才返回，consumer 迴圈才取下一個事件，
    ///       後續事件不會在 bot 建立完成前被 handle / emit 進 eventStream。
    private var intakeContinuation: AsyncStream<[String: Any]>.Continuation?
    private var intakeTask: Task<Void, Never>?

    init(viewModel: WebViewModel?) {
        self.viewModel = viewModel
        setupEventIntake()          // #6: 先建立序列化入口，供 onMJAIEvent 使用
        setupWebSocketCallbacks()
    }

    /// #6: 建立事件序列化入口 —— 單一 buffered AsyncStream + 單一 consumer task
    /// consumer 迴圈以 `await` 逐一消費 handleMJAIEvent，故一個事件（含 start_game 的
    /// createNativeBot）完全處理完，才會取下一個事件 → FIFO 且 bot-ready-before-consume。
    /// 註：coordinator 為 WebViewModel 持有、與 App 同生命週期，故不另做 teardown（沿用既有設計）。
    private func setupEventIntake() {
        let (stream, continuation) = AsyncStream<[String: Any]>.makeStream()
        self.intakeContinuation = continuation
        self.intakeTask = Task { @MainActor [weak self] in
            for await event in stream {
                await self?.handleMJAIEvent(event)
            }
        }
    }

    /// 設定 WebSocket 回調
    private func setupWebSocketCallbacks() {
        // #6: 不再每則事件各開一個 Task（亂序 + 可能早於 bot 建立）。改為 yield 進序列化入口，
        //     由單一 consumer 依序 await handleMJAIEvent。Continuation 為 Sendable，可安全從
        //     WKScriptMessageHandler 回調（主執行緒）呼叫；捕獲值型別副本，不需觸及 self。
        let intake = self.intakeContinuation
        websocketHandler.onMJAIEvent = { event in
            intake?.yield(event)
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

        // 🎯 摸牌事件回調
        websocketHandler.onAddHandPai = { [weak self] handCount in
            guard let self = self else { return }

            Task { @MainActor in
                bridgeLog("[Hook] 收到摸牌事件: handCount=\(handCount)")
                // 🎯 未來可在此觸發推薦刷新或自動打牌
                // 目前推薦顏色會由 JavaScript 模組自動重新應用
                await self.viewModel?.onAddHandPai(handCount: handCount)
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

            // #3: 由 bridge 帶來的三麻旗標決定建立哪種 bot（預設四麻）
            let is3P = (event["is3P"] as? Bool) ?? false

            bridgeLog("[協調器] start_game: 為玩家 \(playerId) 開始新遊戲 (is3P=\(is3P))")

            eventStream.startNewGame()
            eventStream.emit(event)
            viewModel?.deleteNativeBot()

            do {
                try await viewModel?.createNativeBot(playerId: playerId, is3P: is3P)
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

        // #3: 重連重建時，由歷史中的 start_game 取回三麻旗標，保持與原局一致
        let is3P = eventStream.getIs3P()

        bridgeLog("[協調器] 為玩家 \(playerId) 重新同步 Bot, 歷史事件數: \(eventStream.eventCount), is3P=\(is3P)")

        viewModel?.deleteNativeBot()

        do {
            try await viewModel?.createNativeBot(playerId: playerId, is3P: is3P)
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
