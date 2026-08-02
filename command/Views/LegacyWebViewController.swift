//
//  LegacyWebViewController.swift
//  Naki
//
//  支援 macOS 14+ / iOS 17+ 的 WKWebView 實現
//  用於向後相容舊版系統
//
//  功能完整版本：包含 WebSocket 攔截和 Bot 整合
//

import SwiftUI
import WebKit

// MARK: - Legacy WebView (WKWebView for macOS 14+ / iOS 17+)

#if os(macOS)
/// macOS 版本的 WKWebView 包裝器
@available(macOS 14.0, *)
@available(macOS, deprecated: 26.0, message: "Use NakiWebView with WebPage API instead")
struct LegacyNakiWebView: NSViewRepresentable {
    @Environment(\.webViewModel) private var viewModel

    func makeCoordinator() -> LegacyWebViewCoordinator {
        LegacyWebViewCoordinator(viewModel: viewModel)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = createWebViewConfiguration(coordinator: context.coordinator)
        let webView = WKWebView(frame: .zero, configuration: configuration)

        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator

        #if DEBUG
        webView.isInspectable = true
        #endif

        // 保存 webView 引用到 coordinator
        context.coordinator.webView = webView

        // 設置 WebView 引用到 ViewModel（啟動 Debug Server）
        if let legacyViewModel = viewModel as? LegacyWebViewModel {
            legacyViewModel.setWebView(webView)
        }

        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // 如果還沒載入，載入雀魂
        if webView.url == nil {
            if let url = URL(string: "https://game.maj-soul.com/1/") {
                webView.load(URLRequest(url: url))
                viewModel?.store.statusMessage = "正在加載雀魂麻將..."
            }
        }
    }

    private func createWebViewConfiguration(coordinator: LegacyWebViewCoordinator) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        let userContentController = WKUserContentController()

        // 注入 WebSocket 攔截腳本。
        // nil = 模組載入失敗且沒有 fallback，一律不注入；失敗狀態記在
        // `JSInjectionState.shared`，由 StatusBar／橫幅與 /status 呈現。
        if let websocketScript = WebSocketInterceptor.createUserScript() {
            userContentController.addUserScript(websocketScript)
        } else {
            // 這裡還在 make*View 的更新週期內，直接改 @Observable 會撞
            // 「Modifying state during view update」；延到下一個 runloop。
            let vm = viewModel
            DispatchQueue.main.async {
                vm?.store.statusMessage = "錯誤：JavaScript 注入失敗，Naki 無法讀牌局也無法送出動作"
            }
        }

        // ⭐ 關鍵：註冊 Message Handler 來接收 JavaScript 的 WebSocket 消息
        userContentController.add(coordinator.websocketHandler, name: "websocketBridge")

        configuration.userContentController = userContentController
        configuration.mediaTypesRequiringUserActionForPlayback = []

        return configuration
    }
}

#elseif os(iOS)
/// iOS 版本的 WKWebView 包裝器
@available(iOS 17.0, *)
@available(iOS, deprecated: 26.0, message: "Use NakiWebView with WebPage API instead")
struct LegacyNakiWebView: UIViewRepresentable {
    @Environment(\.webViewModel) private var viewModel

    func makeCoordinator() -> LegacyWebViewCoordinator {
        LegacyWebViewCoordinator(viewModel: viewModel)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = createWebViewConfiguration(coordinator: context.coordinator)
        let webView = WKWebView(frame: .zero, configuration: configuration)

        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator

        #if DEBUG
        webView.isInspectable = true
        #endif

        // 保存 webView 引用到 coordinator
        context.coordinator.webView = webView

        // 設置 WebView 引用到 ViewModel（同時啟動 Debug Server，與 macOS 一致）
        if let legacyViewModel = viewModel as? LegacyWebViewModel {
            legacyViewModel.setWebView(webView)
        }

        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // 如果還沒載入，載入雀魂
        if webView.url == nil {
            if let url = URL(string: "https://game.maj-soul.com/1/") {
                webView.load(URLRequest(url: url))
                viewModel?.store.statusMessage = "正在加載雀魂麻將..."
            }
        }
    }

    private func createWebViewConfiguration(coordinator: LegacyWebViewCoordinator) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        let userContentController = WKUserContentController()

        // 注入 WebSocket 攔截腳本。
        // nil = 模組載入失敗且沒有 fallback，一律不注入；失敗狀態記在
        // `JSInjectionState.shared`，由 StatusBar／橫幅與 /status 呈現。
        if let websocketScript = WebSocketInterceptor.createUserScript() {
            userContentController.addUserScript(websocketScript)
        } else {
            // 這裡還在 make*View 的更新週期內，直接改 @Observable 會撞
            // 「Modifying state during view update」；延到下一個 runloop。
            let vm = viewModel
            DispatchQueue.main.async {
                vm?.store.statusMessage = "錯誤：JavaScript 注入失敗，Naki 無法讀牌局也無法送出動作"
            }
        }

        // ⭐ 關鍵：註冊 Message Handler 來接收 JavaScript 的 WebSocket 消息
        userContentController.add(coordinator.websocketHandler, name: "websocketBridge")

        configuration.userContentController = userContentController

        // 允許內嵌媒體播放 (iOS only)
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []

        return configuration
    }
}
#endif

// MARK: - Legacy WebView Coordinator

/// WKWebView 的協調器，處理導覽、UI 代理事件和 WebSocket 消息
@MainActor
class LegacyWebViewCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
    private var viewModel: (any WebViewModelProtocol)?
    weak var webView: WKWebView?

    /// WebSocket 訊息處理器
    let websocketHandler = WebSocketMessageHandler()

    /// MJAI 事件流管理器
    let eventStream = MJAIEventStream()

    /// 事件序列化入口（與主路徑共用 `SerialEventIntake`）。
    ///
    /// 這條路先前是每則事件各開一個 `Task { @MainActor }`：獨立 Task 之間沒有順序保證，
    /// 而 `start_game` 會在 `await createNativeBot` 期間暫停——後面的 tsumo / dahai
    /// 可以先跑完，等於在 bot 還沒建立時就被消費掉。主路徑早已改成單一 stream + 單一
    /// consumer，這裡補上同一份（p2-2 缺口 1）。
    private var intake: SerialEventIntake?

    init(viewModel: (any WebViewModelProtocol)?) {
        self.viewModel = viewModel
        super.init()
        setupEventIntake()          // 先建立序列化入口，供 onMJAIEvent 使用
        setupWebSocketCallbacks()
    }

    // MARK: - WebSocket Callbacks Setup

    /// 建立事件序列化入口（單一 stream / 單一 consumer，見 `SerialEventIntake`）
    private func setupEventIntake() {
        intake = SerialEventIntake { [weak self] event in
            await self?.handleMJAIEvent(event)
        }
    }

    /// 設定 WebSocket 回調
    private func setupWebSocketCallbacks() {
        // 不再每則事件各開一個 Task（亂序 + 可能早於 bot 建立）：改為 yield 進序列化入口。
        let intake = self.intake
        websocketHandler.onMJAIEvent = { event in
            intake?.yield(event)
        }

        websocketHandler.onWebSocketStatusChanged = { [weak self] connected in
            guard let self = self else { return }

            Task { @MainActor in
                self.viewModel?.store.isConnected = connected
                self.viewModel?.store.statusMessage = connected
                    ? "已連線到雀魂服务器"
                    : "已斷開連線"

                if connected {
                    self.websocketHandler.reset()

                    if self.eventStream.canResync() {
                        print("[Legacy 協調器] WebSocket 已重連, 嘗試重新同步 Bot...")
                        await self.resyncBot()
                    } else {
                        // `deleteNativeBot()` 已經清空本局資料（同一個 store）
                        self.viewModel?.deleteNativeBot()
                        print("[Legacy 協調器] WebSocket 連線時重置狀態 (無進行中的遊戲)")
                    }
                } else {
                    self.eventStream.stopConsumer()
                    print("[Legacy 協調器] WebSocket 已斷線, 消費者已停止 (歷史記錄已保留)")
                }
            }
        }
    }

    // MARK: - MJAI Event Handling

    /// 處理 MJAI 事件
    private func handleMJAIEvent(_ event: [String: Any]) async {
        guard let eventType = event["type"] as? String else { return }

        mjaiLog("[Legacy 協調器] MJAI 事件: \(eventType)")

        switch eventType {
        case "start_game":
            guard let playerId = event["id"] as? Int else {
                bridgeLog("[Legacy 協調器] 錯誤: start_game 沒有 id 欄位!")
                return
            }

            bridgeLog("[Legacy 協調器] start_game: 為玩家 \(playerId) 開始新遊戲")

            eventStream.startNewGame()
            eventStream.emit(event)
            viewModel?.deleteNativeBot()

            do {
                // 檢查是否為三麻 (names 陣列長度為 3)
                let is3P = (event["names"] as? [String])?.count == 3
                try await viewModel?.createNativeBot(playerId: playerId, is3P: is3P)
                viewModel?.store.statusMessage = "Bot 已建立 (Player \(playerId))"
                bridgeLog("[Legacy 協調器] 已為玩家 \(playerId) 建立 Bot (is3P: \(is3P))")
                startEventConsumer()
            } catch {
                bridgeLog("[Legacy 協調器] 錯誤: 建立 Bot 失敗: \(error)")
            }

        case "end_game":
            bridgeLog("[Legacy 協調器] end_game: 清理中")
            eventStream.emit(event)
            eventStream.endGame()
            viewModel?.deleteNativeBot()   // 手牌／推薦／botStatus 一併清空
            viewModel?.store.statusMessage = "遊戲結束"

        default:
            eventStream.emit(event)
        }
    }

    /// 啟動事件消費者
    private func startEventConsumer() {
        bridgeLog("[Legacy 協調器] 啟動事件消費者...")

        eventStream.startConsumer { [weak self] event in
            guard let self = self else { return }

            let eventType = event["type"] as? String ?? "unknown"

            do {
                if let response = try await self.viewModel?.processNativeEvent(event) {
                    bridgeLog("[Legacy 消費者] \(eventType) → 回應: \(response)")
                } else {
                    bridgeLog("[Legacy 消費者] \(eventType) → 回應: 無")
                }
            } catch {
                bridgeLog("[Legacy 消費者] 處理 \(eventType) 時發生錯誤: \(error)")
            }
        }
    }

    /// 重新同步 Bot
    func resyncBot() async {
        guard let playerId = eventStream.getPlayerId() else {
            bridgeLog("[Legacy 協調器] 無法重新同步: 歷史記錄中找不到 playerId")
            return
        }

        bridgeLog("[Legacy 協調器] 為玩家 \(playerId) 重新同步 Bot, 歷史事件數: \(eventStream.eventCount)")

        viewModel?.deleteNativeBot()

        do {
            // 從 start_game 事件帶的旗標取三麻（AUDIT §5 #3：改由 bridge 依 seatList 判定後帶下來，
            // 不再由 Legacy 端自行推斷；API 也隨之從 is3PlayerGame() 改名為 getIs3P()）
            let is3P = eventStream.getIs3P()
            try await viewModel?.createNativeBot(playerId: playerId, is3P: is3P)
            viewModel?.store.statusMessage = "Bot 已重新同步 (Player \(playerId))"
            startEventConsumer()
            bridgeLog("[Legacy 協調器] Bot 重新同步成功")
        } catch {
            bridgeLog("[Legacy 協調器] 錯誤: Bot 重新同步失敗: \(error)")
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        // 頁面開始載入時完整重置
        websocketHandler.fullReset()
        eventStream.endGame()
        viewModel?.deleteNativeBot()   // 手牌／推薦／botStatus 一併清空
        viewModel?.store.isConnected = false
        viewModel?.store.statusMessage = "正在加載雀魂..."
        viewModel?.resetHideNamesSettings()
        print("[Legacy 協調器] 導覽開始時完整重置")
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        viewModel?.store.statusMessage = "雀魂已加載，等待連接..."
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        print("[LegacyWebView] 頁面載入成功")
        viewModel?.applyHideNamesSettingsIfNeeded()
        if viewModel?.store.isConnected == false {
            viewModel?.store.statusMessage = "已載入，等待 WebSocket 連接..."
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        print("[LegacyWebView] 導覽錯誤: \(error)")
        viewModel?.store.statusMessage = "加載失敗: \(error.localizedDescription)"
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        return .allow
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        return .allow
    }

    // MARK: - WKUIDelegate

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
        bridgeLog("[JS 警告] \(message)")
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
        bridgeLog("[JS 確認] \(message)")
        return true
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo) async -> String? {
        bridgeLog("[JS 提示] \(prompt)")
        return nil
    }
}

// MARK: - Adaptive WebView

/// 自適應 WebView —— **不自己判版本**。
///
/// 版本分歧只在 `WebViewModelFactory.create()` 判一次；View 由當時選中的 VM
/// 用 `makeWebView()` 交出來，所以「WebPage VM 配到 Legacy View」這種組合
/// 從結構上就不存在。先前這裡與 factory 各寫一次 `#available`，靠註解要求一致，
/// 改一處忘另一處只會得到一個永遠轉型失敗的 `as?` 和一片空白畫面。
struct AdaptiveNakiWebView: View {
    @Environment(\.webViewModel) private var viewModel

    var body: some View {
        if let viewModel {
            viewModel.makeWebView()
        } else {
            // Environment 還沒注入 VM（理論上只有預覽／測試會走到）
            ProgressView("正在初始化...")
        }
    }
}
