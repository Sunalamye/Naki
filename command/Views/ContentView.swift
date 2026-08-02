//
//  ContentView.swift
//  Naki
//
//  Created by Suoie on 2025/11/29.
//  Updated: 2025/12/05 - 使用 @Environment 傳遞 WebViewModel
//  Updated: 2026/01/26 - 使用 AdaptiveNakiWebView 支援 macOS 14+/iOS 17+
//

import SwiftUI
import WebKit

struct ContentView: View {
    /// 使用 Factory 模式創建適當版本的 ViewModel
    @State private var viewModel: any WebViewModelProtocol = WebViewModelFactory.create()

#if os(macOS)
    @State private var showGamePanel = true
#else
    @State private var showGamePanel = false
#endif
    @State private var showAdvancedSettings = false
    @State private var showLog = false

    // 自動打牌控制
    //
    // key 與 ViewModel 共用（`AutoPlayModeStore.key`）：以前 UI 存 "AutoPlayMode"、
    // ViewModel 存 "naki.autoPlayMode"，兩邊各記各的，picker 顯示的模式可以跟
    // 實際驅動送出的模式不一致。舊 key 的一次性遷移在 `NakiApp.init()`。
    @AppStorage(AutoPlayModeStore.key) private var autoPlayMode: AutoPlayMode = AutoPlayModeStore
        .defaultMode

    /// 這條 WebView 路徑真的能執行的模式（Legacy 沒有「自動」，見 `AutoPlayAvailability`）
    private var availableAutoPlayModes: [AutoPlayMode] {
        AutoPlayAvailability.modes(autoPlaySupported: viewModel.supportsAutoPlay)
    }

    /// 模式 picker 本體：**刻意放在 `#if` 之外**，兩個平台的 toolbar 共用同一份。
    ///
    /// 這條路徑的選項與行為只有 iOS 17–25 會走到，而本機（macOS 26）連編譯都碰不到
    /// `#if os(iOS)` 區塊——寫兩份的話，iOS 那份的錯字要到實機上才會被發現。
    /// 共用之後 macOS build 至少會替它做型別檢查。
    private func autoPlayModePicker(width: CGFloat) -> some View {
        Picker("模式", selection: $autoPlayMode) {
            // 選項來自 `AutoPlayAvailability`：不支援自動送出的路徑上，
            // 「自動」不是灰掉的按鈕而是根本不存在——灰掉的控制照樣要解釋，
            // 而解釋放在進階設定裡（`autoPlayAvailabilityBox`）。
            ForEach(availableAutoPlayModes, id: \.self) { mode in
                Text(mode.pickerLabel).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        // a11y: fixed width for segmented control; kept to preserve toolbar layout
        .frame(width: width)
        .onChange(of: autoPlayMode) { _, newValue in
            // 收斂與持久化在 ViewModel → `AutoPlayAvailability.commit`；
            // Action 只是這個 View 對「切模式」這件副作用的型別化入口（p3-3）。
            SetAutoPlayModeAction(viewModel: viewModel)(newValue)
        }
        .accessibilityIdentifier("autoplay-mode-picker")
        .accessibilityLabel("自動打牌模式")
        .accessibilityHint(viewModel.supportsAutoPlay
                           ? "" : AutoPlayAvailability.autoUnavailableReason)
    }

    var body: some View {
        Group {
#if os(macOS)
            macOSLayout
#else
            iOSLayout
#endif
        }
        .environment(\.webViewModel, viewModel)
        .task {
            // 存檔可能是在支援自動送出的裝置上寫下的 `.auto`。Picker 上沒有那個選項時，
            // 選取值對不到任何 tag，segmented control 會顯示成「沒有任何一段被選中」；
            // ViewModel 那邊也已經降級成推薦，兩邊必須講同一句話。
            let clamped = AutoPlayAvailability.clamp(
                autoPlayMode, autoPlaySupported: viewModel.supportsAutoPlay)
            if clamped != autoPlayMode {
                autoPlayMode = clamped
                viewModel.setAutoPlayMode(clamped)
            }
        }
    }

    // MARK: - macOS Layout
#if os(macOS)
    private var macOSLayout: some View {
        HSplitView {
            // WebView (自動選擇新版或舊版實現)
            AdaptiveNakiWebView()
                .frame(minWidth: 600)

            // 遊戲面板（右側）
            if showGamePanel {
                GamePanel(showLog: $showLog)
                    .frame(width: 320)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .top) {
            JSInjectionFailureBanner()
        }
        .safeAreaInset(edge: .bottom) {
            StatusBar()
        }
        .animation(.easeInOut(duration: 0.2), value: showGamePanel)
        .sheet(isPresented: $showAdvancedSettings) {
            AdvancedSettingsSheet()
        }
        .toolbar {
            macOSToolbarContent
        }
    }

    @ToolbarContentBuilder
    private var macOSToolbarContent: some ToolbarContent {
        // 進階設定
        ToolbarItem(placement: .primaryAction) {
            Button(action: { showAdvancedSettings = true }) {
                Image(systemName: "gearshape")
            }
            .help("進階設定")
            .accessibilityIdentifier("toolbar-settings")
            .accessibilityLabel("進階設定")
        }

        // 左側：自動打牌模式
        ToolbarItem(placement: .navigation) {
            autoPlayModePicker(width: 160)
                .help(viewModel.supportsAutoPlay
                      ? "AI 推薦模式"
                      : "AI 推薦模式（此裝置不提供自動送出）")
        }

        // 註：「延遲調整」Stepper 已移除。它寫進去的值沒有任何讀取者，
        // 真正的送出延遲由 `ActionDelayModel` 依動作類型隨機決定（刻意設計，
        // 避免固定節奏）。留著只是一個看得到、轉得動、但不會改變任何行為的假控制。

        // MCP Server
        ToolbarItem(placement: .navigation) {
            Button(action: { viewModel.toggleDebugServer() }) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack{
                        Circle()
                            .fill(viewModel.isDebugServerRunning ? Color.green : Color.gray)
                            .frame(width: 6, height: 6)

                        Text("\(viewModel.debugServerPort)")
                            .font(.system(.caption, design: .monospaced))

                    }
                    Text("MCP Server")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .frame(width: 80)
            .help(viewModel.isDebugServerRunning ? "MCP Server 運行中" : "MCP Server 已停止")
            .accessibilityIdentifier("mcp-server-toggle")
            .accessibilityLabel("MCP Server")
            .accessibilityValue(viewModel.isDebugServerRunning ? "運行中，連接埠 \(viewModel.debugServerPort)" : "未運行")
        }

        // 連接狀態
        ToolbarItem(placement: .navigation) {
            ConnectionIndicator()
                .frame(width: 80)
        }

        // 重新載入
        ToolbarItem(placement: .destructiveAction) {
            Button(action: {
                viewModel.reload()
            }) {
                Image(systemName: "arrow.clockwise")
            }
            .help("重新載入")
            .accessibilityIdentifier("toolbar-reload")
            .accessibilityLabel("重新載入")
        }

        // 右側：日誌切換
        ToolbarItem(placement: .primaryAction) {
            Button(action: { showLog.toggle() }) {
                Image(systemName: showLog ? "terminal.fill" : "terminal")
            }
            .help("顯示/隱藏日誌")
            .accessibilityIdentifier("toolbar-log-toggle")
            .accessibilityLabel("顯示或隱藏日誌")
            .accessibilityValue(showLog ? "已顯示" : "已隱藏")
        }

        // 遊戲面板切換
        ToolbarItem(placement: .primaryAction) {
            Button(action: { showGamePanel.toggle() }) {
                Image(systemName: showGamePanel ? "sidebar.trailing" : "sidebar.right")
            }
            .help("顯示/隱藏遊戲面板")
            .accessibilityIdentifier("toolbar-game-panel-toggle")
            .accessibilityLabel("顯示或隱藏遊戲面板")
            .accessibilityValue(showGamePanel ? "已顯示" : "已隱藏")
        }
    }
#endif

    // MARK: - iOS Layout
#if os(iOS)

    private var iOSLayout: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                HStack(alignment: .top){
                    iOSLeftView
                    AdaptiveNakiWebView()
                }
                //                // 底部浮動控制面板
                iOSBottomPanel
                    .opacity(0.5)
                    .allowsHitTesting(false)
            }
            .ignoresSafeArea(edges: .bottom)
            .safeAreaInset(edge: .top) {
                JSInjectionFailureBanner()
            }
            .navigationTitle("Naki")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                iOSToolbarContent
            }
            .sheet(isPresented: $showGamePanel) {
                iOSGamePanelSheet
            }
            .sheet(isPresented: $showAdvancedSettings) {
                AdvancedSettingsSheet()
            }
        }
    }

    private var iOSBottomPanel: some View {
        HStack(spacing: 0) {
            if !viewModel.store.statusMessage.isEmpty {
                StatusBar()
            }
        }
    }
    private var iOSLeftView: some View {
        VStack(alignment:.leading, spacing: 16) {
            VStack{
                HStack(spacing: 4) {
                    Circle()
                        .fill(viewModel.store.isConnected ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                    Text(viewModel.store.isConnected ? "已連接" : "未連接")
                        .font(.caption)
                }

                Text("WebSocket")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("websocket-connection-indicator")
            .accessibilityLabel("WebSocket 連線狀態")
            .accessibilityValue(viewModel.store.isConnected ? "已連接" : "未連接")

            RecommendationView(
                recommendations: viewModel.store.recommendations,
                maxDisplay: 5,
                showsRecommendations: viewModel.autoPlayMode.showRecommendation,
                reloadBot: ForceReconnectAction(viewModel: viewModel)
            )
        }
        .frame(width: 140)
    }

    @ToolbarContentBuilder
    private var iOSToolbarContent: some ToolbarContent {
        // 左側：重新載入
        ToolbarItem(placement: .navigationBarLeading) {
            Button(action: {
                viewModel.reload()
            }) {
                Image(systemName: "arrow.clockwise")
            }
            .accessibilityIdentifier("toolbar-reload")
            .accessibilityLabel("重新載入")
        }

        ToolbarItem(placement: .automatic) {
            // iOS 17–25 走 Legacy WebView，那條路不提供自動送出：
            // picker 只會列出「關 / 推薦」，理由在進階設定裡說明。
            autoPlayModePicker(width: 150)
        }

        // 右側：遊戲面板
        ToolbarItem(placement: .navigationBarTrailing) {
            Button(action: { showGamePanel = true }) {
                Image(systemName: "sidebar.right")
            }
            .accessibilityIdentifier("toolbar-game-panel-toggle")
            .accessibilityLabel("顯示遊戲面板")
        }

        // 右側：設定
        ToolbarItem(placement: .navigationBarTrailing) {
            Button(action: { showAdvancedSettings = true }) {
                Image(systemName: "gearshape")
            }
            .accessibilityIdentifier("toolbar-settings")
            .accessibilityLabel("進階設定")
        }
    }

    private var iOSGamePanelSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // Bot 狀態
                    BotStatusView(
                        botStatus: viewModel.store.botStatus,
                        gameState: viewModel.store.gameState,
                        reloadBot: ForceReconnectAction(viewModel: viewModel)
                    )

                    // AI 推薦
                    RecommendationView(
                        recommendations: viewModel.store.recommendations,
                        maxDisplay: 5,
                        showsRecommendations: viewModel.autoPlayMode.showRecommendation,
                        reloadBot: ForceReconnectAction(viewModel: viewModel)
                    )

                    // 日誌（可展開）
                    DisclosureGroup("日誌") {
                        LogPanel()
                            .frame(height: 200)
                    }
                    .padding(.horizontal)
                }
                .padding()
            }
            .navigationTitle("遊戲狀態")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") {
                        showGamePanel = false
                    }
                    .accessibilityIdentifier("game-panel-done-button")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
#endif
}

// MARK: - Game Panel (macOS 右側面板)

#if os(macOS)
struct GamePanel: View {
    @Environment(\.webViewModel) private var viewModel
    @Binding var showLog: Bool

    /// 面板裡兩顆「重新載入」按鈕共用的動作。
    ///
    /// 沒有 view model（Preview／初始化中）時是 `.unavailable`：按下去不做事，
    /// 而不是靜靜地什麼都沒接（先前 `viewModel?.forceReconnect()` 就是後者）。
    private var reloadBot: ForceReconnectAction {
        viewModel.map { ForceReconnectAction(viewModel: $0) } ?? .unavailable
    }

    var body: some View {
        VSplitView {
            // 上半部分：Bot 狀態和推薦
            VStack(spacing: 12) {
                // Bot 狀態
                BotStatusView(
                    botStatus: viewModel?.store.botStatus ?? BotStatus(),
                    gameState: viewModel?.store.gameState ?? GameState(),
                    reloadBot: reloadBot
                )

                // AI 推薦
                RecommendationView(
                    recommendations: viewModel?.store.recommendations ?? [],
                    maxDisplay: 5,
                    showsRecommendations: viewModel?.autoPlayMode.showRecommendation ?? true,
                    reloadBot: reloadBot
                )

                Spacer()
            }
            .padding(12)
            .frame(minHeight: 150)

            // 下半部分：日誌面板
            if showLog {
                VStack(spacing: 0) {
                    Divider()
                    LogPanel()
                }
                .frame(minHeight: 150)
            }
        }
        .background(Color.windowBackground)
    }
}
#endif

// MARK: - Connection Indicator

struct ConnectionIndicator: View {
    @Environment(\.webViewModel) private var viewModel

    private var isConnected: Bool { viewModel?.store.isConnected ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Circle()
                    .fill(isConnected ? Color.green : Color.red)
                    .frame(width: 6, height: 6)
                Text(isConnected ? "已連接" : "未連接")
                    .font(.caption2)
            }
            Text("WebSocket")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("websocket-connection-indicator")
        .accessibilityLabel("WebSocket 連線狀態")
        .accessibilityValue(isConnected ? "已連接" : "未連接")
    }
}

// MARK: - Advanced Settings Sheet

struct AdvancedSettingsSheet: View {
    @Environment(\.webViewModel) private var viewModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("HidePlayerNames") private var hidePlayerNames = false

    /// 「重建 Bot」＝強制斷線重連（手段由各 WebView path 決定，見 `ForceReconnectAction`）
    private var rebuildBot: ForceReconnectAction {
        viewModel.map { ForceReconnectAction(viewModel: $0) } ?? .unavailable
    }

    var body: some View {
        #if os(macOS)
        macOSSettingsContent
        #else
        iOSSettingsContent
        #endif
    }

    #if os(macOS)
    private var macOSSettingsContent: some View {
        VStack(spacing: 0) {
            // 標題列
            HStack {
                Text("進階設定")
                    .font(.headline)
                Spacer()
                Button("完成") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("settings-done-button")
            }
            .padding()
            .background(Color.contentBackground)

            Divider()

            ScrollView {
                settingsForm
            }
        }
        // a11y: fixed sheet size; large Dynamic Type may clip — kept to preserve layout
        .frame(width: 400, height: 550)
    }
    #endif

    #if os(iOS)
    private var iOSSettingsContent: some View {
        NavigationStack {
            ScrollView {
                settingsForm
            }
            .navigationTitle("進階設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                    .accessibilityIdentifier("settings-done-button")
                }
            }
        }
    }
    #endif

    private var settingsForm: some View {
        VStack(alignment: .leading, spacing: 20) {

            // 自動打牌可用性（只有在這條路徑不支援時才出現）
            autoPlayAvailabilityBox

            // 畫面
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("隱藏玩家名稱", isOn: $hidePlayerNames)
                        .accessibilityIdentifier("hide-player-names-toggle")
                        .onChange(of: hidePlayerNames) { _, newValue in
                            viewModel?.setHidePlayerNames(newValue)
                        }

                    Text("在遊戲解析封包前把暱稱改寫成 Player 1–4。只對開啟之後才開始的對局生效；斷線重連與終局結算畫面仍會顯示原名。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } label: {
                Label("畫面", systemImage: "eye.slash")
            }

            // Bot 管理
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Bot 會在遊戲開始時自動創建，通常不需要手動管理。")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    HStack {
                        Button("重建 Bot") {
                            Task {
                                // 強制斷線重連以重建 Bot（手段由各 path 決定，見 Action）
                                await rebuildBot()
                            }
                        }
                        .buttonStyle(.bordered)
                        .help("強制斷線重連，伺服器會重新發送遊戲狀態重建 Bot")
                        .accessibilityIdentifier("rebuild-bot-button")

                        Button("刪除 Bot") {
                            viewModel?.deleteNativeBot()
                        }
                        .buttonStyle(.bordered)
                        #if os(macOS)
                        .tint(.red)
                        #endif
                        .accessibilityIdentifier("delete-bot-button")
                    }
                }
            } label: {
                Label("Bot 管理", systemImage: "cpu")
            }

            // MCP Server（兩個平台都有——p2-3 之後 DebugServer 不再是 macOS 專屬）。
            // 這個 GroupBox 先前包在 `#if os(macOS)` 裡，寫著「僅 macOS」；
            // 現在 iOS 也會綁 loopback 8765，控制項再藏起來就變成「跑著卻看不到、關不掉」。
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        HStack {
                            Circle()
                                .fill((viewModel?.isDebugServerRunning ?? false) ? Color.green : Color.gray)
                                .frame(width: 8, height: 8)
                            Text((viewModel?.isDebugServerRunning ?? false) ? "運行中" : "已停止")
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("mcp-server-status")
                        .accessibilityLabel("MCP Server 狀態")
                        .accessibilityValue((viewModel?.isDebugServerRunning ?? false) ? "運行中" : "已停止")

                        Spacer()

                        Button((viewModel?.isDebugServerRunning ?? false) ? "停止" : "啟動") {
                            viewModel?.toggleDebugServer()
                        }
                        .buttonStyle(.bordered)
                        .tint((viewModel?.isDebugServerRunning ?? false) ? .red : .green)
                        .accessibilityIdentifier("mcp-server-toggle-button")
                    }

                    if viewModel?.isDebugServerRunning ?? false {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("http://localhost:\(viewModel?.debugServerPort ?? 8765)")
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)

                            Text("curl http://localhost:\(viewModel?.debugServerPort ?? 8765)/logs")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundColor(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
            } label: {
                Label("MCP Server", systemImage: "server.rack")
            }
        }
        .padding()
    }

    /// 「為什麼沒有自動模式」的說明。
    ///
    /// 選項直接不出現在 picker 上，所以一定要有一個地方講清楚那不是壞掉、也不是漏做，
    /// 而是這條 WebView 路徑沒有經過任何實機對局驗證（見 `AutoPlayAvailability`）。
    @ViewBuilder
    private var autoPlayAvailabilityBox: some View {
        if viewModel?.supportsAutoPlay == false {
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text("自動送出：不可用")
                        .font(.callout)
                        .fontWeight(.semibold)
                    Text(AutoPlayAvailability.autoUnavailableReason)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("模式選單只提供「關 / 推薦」。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } label: {
                Label("自動打牌", systemImage: "hand.raised")
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("autoplay-unavailable-note")
            .accessibilityLabel("自動送出不可用")
            .accessibilityValue(AutoPlayAvailability.autoUnavailableReason)
        }
    }
}

// MARK: - JS 注入失敗橫幅

/// JavaScript 模組載入失敗時的常駐紅色橫幅。
///
/// 為什麼要獨立於 `StatusBar`：`statusMessage` 會被載入、連線、Bot 建立等事件
/// 一路覆蓋掉，錯誤看一眼就消失。而注入失敗是**不會自己好**的狀態
/// ——在這個狀態下 Naki 收不到任何封包、送不出任何動作，
/// 側欄的推薦、`/game/*`、`/bot/*` 全部不可信，所以必須一直掛著。
///
/// 資料來源是 `JSInjectionState.shared`（`@Observable`），
/// 由 `WebSocketInterceptor.createUserScript()` 在建立 WebView 時寫入。
struct JSInjectionFailureBanner: View {

    var body: some View {
        if let summary = JSInjectionState.shared.report.failureSummary {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .imageScale(.large)

                VStack(alignment: .leading, spacing: 2) {
                    Text("JavaScript 注入失敗：Naki 讀不到牌局，也送不出任何動作")
                        .font(.headline)
                    Text(summary)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    Text("這不是暫時性錯誤，重新載入頁面不會修好；請重新安裝／重新建置 App。")
                        .font(.caption)
                        .opacity(0.9)
                }

                Spacer(minLength: 0)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("js-injection-failure-banner")
            .accessibilityLabel("JavaScript 注入失敗")
            .accessibilityValue(summary)
        }
    }
}

// MARK: - Status Bar

struct StatusBar: View {
    @Environment(\.webViewModel) private var viewModel

    var body: some View {
        if let vm = viewModel, !vm.store.statusMessage.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: statusIcon)
                    .foregroundColor(statusColor)
                Text(vm.store.statusMessage)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                Spacer()

                // 顯示推薦數量
                if vm.store.recommendationCount > 0 {
                    Text("\(vm.store.recommendationCount) 推薦")
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.2))
                        .cornerRadius(4)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(statusColor.opacity(0.1))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("status-bar")
        }
    }

    private var statusIcon: String {
        guard let vm = viewModel else { return "info.circle.fill" }
        if vm.store.statusMessage.contains("錯誤") || vm.store.statusMessage.contains("Error") {
            return "exclamationmark.triangle.fill"
        } else if vm.store.statusMessage.contains("成功") || vm.store.statusMessage.contains("已") {
            return "checkmark.circle.fill"
        }
        return "info.circle.fill"
    }

    private var statusColor: Color {
        guard let vm = viewModel else { return .blue }
        if vm.store.statusMessage.contains("錯誤") || vm.store.statusMessage.contains("Error") {
            return .red
        } else if vm.store.statusMessage.contains("成功") || vm.store.statusMessage.contains("已") {
            return .green
        }
        return .blue
    }
}

#Preview {
    ContentView()
        #if os(macOS)
        .frame(width: 1200, height: 800)
        #endif
}
