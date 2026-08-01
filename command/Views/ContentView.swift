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
    @AppStorage("AutoPlayMode") private var autoPlayMode: AutoPlayMode = .auto
    @State private var actionDelay: Double = 1.0

    var body: some View {
        Group {
#if os(macOS)
            macOSLayout
#else
            iOSLayout
#endif
        }
        .environment(\.webViewModel, viewModel)
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
            Picker("", selection: $autoPlayMode) {
                Text("關").tag(AutoPlayMode.off)
                Text("推薦").tag(AutoPlayMode.recommend)
                Text("自動").tag(AutoPlayMode.auto)
            }
            .pickerStyle(.segmented)
            .frame(width: 160) // a11y: fixed width for segmented control; kept to preserve toolbar layout
            .onChange(of: autoPlayMode) { _, newValue in
                viewModel.setAutoPlayMode(newValue)
            }
            .help("AI 推薦模式")
            .accessibilityIdentifier("autoplay-mode-picker")
            .accessibilityLabel("自動打牌模式")
        }

        // 延遲調整
        ToolbarItem(placement: .navigation) {
            if autoPlayMode != .off {
                HStack(spacing: 10) {
                    Text("\(actionDelay, specifier: "%.1f")s")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)

                    Stepper("", value: $actionDelay, in: 0.5...3.0, step: 0.5)
                        .labelsHidden()
                        .onChange(of: actionDelay) { _, newValue in
                            viewModel.setAutoPlayDelay(newValue)
                        }
                        .accessibilityIdentifier("action-delay-stepper")
                        .accessibilityLabel("動作延遲")
                        .accessibilityValue(String(format: "%.1f 秒", actionDelay))
                }
                .frame(width: 80)
                .help("動作延遲")
            }
        }

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
            if !viewModel.statusMessage.isEmpty {
                StatusBar()
            }
        }
    }
    private var iOSLeftView: some View {
        VStack(alignment:.leading, spacing: 16) {
            VStack{
                HStack(spacing: 4) {
                    Circle()
                        .fill(viewModel.isConnected ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                    Text(viewModel.isConnected ? "已連接" : "未連接")
                        .font(.caption)
                }

                Text("WebSocket")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("websocket-connection-indicator")
            .accessibilityLabel("WebSocket 連線狀態")
            .accessibilityValue(viewModel.isConnected ? "已連接" : "未連接")

            RecommendationView(
                recommendations: viewModel.recommendations,
                maxDisplay: 5
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
            Picker("模式", selection: $autoPlayMode) {
                Text("關").tag(AutoPlayMode.off)
                Text("推薦").tag(AutoPlayMode.recommend)
                Text("自動").tag(AutoPlayMode.auto)
            }
            .pickerStyle(.segmented)
            .frame(width: 150)
            .onChange(of: autoPlayMode) { _, newValue in
                viewModel.setAutoPlayMode(newValue)
            }
            .accessibilityIdentifier("autoplay-mode-picker")
            .accessibilityLabel("自動打牌模式")
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
                        botStatus: viewModel.botStatus,
                        gameState: viewModel.gameState
                    )

                    // AI 推薦
                    RecommendationView(
                        recommendations: viewModel.recommendations,
                        maxDisplay: 5
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

    var body: some View {
        VSplitView {
            // 上半部分：Bot 狀態和推薦
            VStack(spacing: 12) {
                // Bot 狀態
                BotStatusView(
                    botStatus: viewModel?.botStatus ?? BotStatus(),
                    gameState: viewModel?.gameState ?? GameState()
                )

                // AI 推薦
                RecommendationView(
                    recommendations: viewModel?.recommendations ?? [],
                    maxDisplay: 5
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

    private var isConnected: Bool { viewModel?.isConnected ?? false }

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
                                // 強制斷線重連以重建 Bot
                                await viewModel?.forceReconnect()
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

            #if os(macOS)
            // MCP Server (僅 macOS)
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
            #endif
        }
        .padding()
    }
}

// MARK: - Status Bar

struct StatusBar: View {
    @Environment(\.webViewModel) private var viewModel

    var body: some View {
        if let vm = viewModel, !vm.statusMessage.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: statusIcon)
                    .foregroundColor(statusColor)
                Text(vm.statusMessage)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                Spacer()

                // 顯示推薦數量
                if vm.recommendationCount > 0 {
                    Text("\(vm.recommendationCount) 推薦")
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
        if vm.statusMessage.contains("錯誤") || vm.statusMessage.contains("Error") {
            return "exclamationmark.triangle.fill"
        } else if vm.statusMessage.contains("成功") || vm.statusMessage.contains("已") {
            return "checkmark.circle.fill"
        }
        return "info.circle.fill"
    }

    private var statusColor: Color {
        guard let vm = viewModel else { return .blue }
        if vm.statusMessage.contains("錯誤") || vm.statusMessage.contains("Error") {
            return .red
        } else if vm.statusMessage.contains("成功") || vm.statusMessage.contains("已") {
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
