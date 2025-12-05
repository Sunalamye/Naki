//
//  ContentView.swift
//  Naki
//
//  Created by Suoie on 2025/11/29.
//  Updated: 2025/12/04 - 支援 iOS/macOS 跨平台
//

import SwiftUI
import WebKit

struct ContentView: View {
    @State private var viewModel = WebViewModel()
    
#if os(macOS)
    @State private var showGamePanel = true
#else
    @State private var showGamePanel = false
#endif
    @State private var showAdvancedSettings = false
    @State private var showLog = false
    
    // 自動打牌控制
    @State private var autoPlayMode: AutoPlayMode = .auto
    @State private var actionDelay: Double = 1.0
    
    var body: some View {
#if os(macOS)
        macOSLayout
#else
        iOSLayout
#endif
    }
    
    // MARK: - macOS Layout
#if os(macOS)
    private var macOSLayout: some View {
        HSplitView {
            // WebView
            NakiWebView(viewModel: viewModel)
                .frame(minWidth: 600)
            
            // 遊戲面板（右側）
            if showGamePanel {
                GamePanel(viewModel: viewModel, showLog: $showLog)
                    .frame(width: 320)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom) {
            StatusBar(viewModel: viewModel)
        }
        .animation(.easeInOut(duration: 0.2), value: showGamePanel)
        .sheet(isPresented: $showAdvancedSettings) {
            AdvancedSettingsSheet(viewModel: viewModel)
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
        }
        
        // 左側：自動打牌模式
        ToolbarItem(placement: .navigation) {
            Picker("", selection: $autoPlayMode) {
                Text("關").tag(AutoPlayMode.off)
                Text("推薦").tag(AutoPlayMode.recommend)
                Text("自動").tag(AutoPlayMode.auto)
            }
            .pickerStyle(.segmented)
            .frame(width: 160)
            .onChange(of: autoPlayMode) { _, newValue in
                viewModel.setAutoPlayMode(newValue)
            }
            .help("AI 推薦模式")
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
                }
                .frame(width: 80)
                .help("動作延遲")
            }
        }
        
        // Debug Server
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
                    Text("Debug Server")
                        .font(.system(size: 8))
                        .foregroundColor(.secondary)
                }
            }
            .frame(width: 80)
            .help(viewModel.isDebugServerRunning ? "Debug Server 運行中" : "Debug Server 已停止")
        }
        
        // 連接狀態
        ToolbarItem(placement: .navigation) {
            ConnectionIndicator(viewModel: viewModel)
                .frame(width: 80)
        }
        
        // 重新載入
        ToolbarItem(placement: .destructiveAction) {
            Button(action: {
                Task {
                    try? await viewModel.webPage?.reload()
                }
            }) {
                Image(systemName: "arrow.clockwise")
            }
            .help("重新載入")
        }
        
        // 右側：日誌切換
        ToolbarItem(placement: .primaryAction) {
            Button(action: { showLog.toggle() }) {
                Image(systemName: showLog ? "terminal.fill" : "terminal")
            }
            .help("顯示/隱藏日誌")
        }
        
        // 遊戲面板切換
        ToolbarItem(placement: .primaryAction) {
            Button(action: { showGamePanel.toggle() }) {
                Image(systemName: showGamePanel ? "sidebar.trailing" : "sidebar.right")
            }
            .help("顯示/隱藏遊戲面板")
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
                    NakiWebView(viewModel: viewModel)
                        .ignoresSafeArea(edges: .bottom)
                }
                //                // 底部浮動控制面板
                iOSBottomPanel
                    .opacity(0.5)
                    .allowsHitTesting(false)
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
                AdvancedSettingsSheet(viewModel: viewModel)
            }
        }
    }
    
    private var iOSBottomPanel: some View {
        HStack(spacing: 0) {
            if !viewModel.statusMessage.isEmpty {
                StatusBar(viewModel: viewModel)
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
                    .font(.system(size: 8))
                    .foregroundColor(.secondary)
            }
            
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
                viewModel.webPage?.reload()
            }) {
                Image(systemName: "arrow.clockwise")
            }
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
        }
        
        // 右側：遊戲面板
        ToolbarItem(placement: .navigationBarTrailing) {
            Button(action: { showGamePanel = true }) {
                Image(systemName: "sidebar.right")
            }
        }
        
        // 右側：設定
        ToolbarItem(placement: .navigationBarTrailing) {
            Button(action: { showAdvancedSettings = true }) {
                Image(systemName: "gearshape")
            }
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
    var viewModel: WebViewModel
    @Binding var showLog: Bool

    var body: some View {
        VSplitView {
            // 上半部分：Bot 狀態和推薦
            VStack(spacing: 12) {
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
    var viewModel: WebViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Circle()
                    .fill(viewModel.isConnected ? Color.green : Color.red)
                    .frame(width: 6, height: 6)
                Text(viewModel.isConnected ? "已連接" : "未連接")
                    .font(.caption2)
            }
            Text("WebSocket")
                .font(.system(size: 8))
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Advanced Settings Sheet

struct AdvancedSettingsSheet: View {
    var viewModel: WebViewModel
    @Environment(\.dismiss) private var dismiss

    // AI 設定
    @State private var temperature: Double = 0.3
    @State private var showRotatingEffect: Bool = false  // 預設關閉旋轉效果

    // 隱私設定
    @AppStorage("hidePlayerNames") private var hidePlayerNames: Bool = false

    // 位置校準
    @State private var tileSpacing: Double = 96.0
    @State private var offsetX: Double = -200.0
    @State private var offsetY: Double = 0.0

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
            }
            .padding()
            .background(Color.contentBackground)

            Divider()

            ScrollView {
                settingsForm
            }
        }
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
                }
            }
        }
    }
    #endif

    private var settingsForm: some View {
        VStack(alignment: .leading, spacing: 20) {
            // AI 設定
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("推薦溫度")
                            Spacer()
                            Text("\(temperature, specifier: "%.2f")")
                                .foregroundColor(.secondary)
                        }
                        Slider(value: $temperature, in: 0.1...2.0, step: 0.1)
                    }

                    Text("較低溫度 = 更確定性的推薦，較高溫度 = 更多樣化的推薦")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Divider()

                    // 旋轉高亮效果開關
                    Toggle(isOn: $showRotatingEffect) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("顯示旋轉高亮效果")
                            Text("啟用後會在推薦牌上顯示額外的旋轉光環效果")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .onChange(of: showRotatingEffect) { _, newValue in
                        viewModel.setHighlightSettings(showRotatingEffect: newValue)
                    }
                }
            } label: {
                Label("AI 設定", systemImage: "brain")
            }

            // 隱私設定
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(isOn: $hidePlayerNames) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("隱藏玩家名稱")
                            Text("隱藏遊戲中所有玩家的暱稱顯示")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .onChange(of: hidePlayerNames) { _, newValue in
                        viewModel.setHidePlayerNames(newValue)
                    }
                }
            } label: {
                Label("隱私設定", systemImage: "eye.slash")
            }

            #if os(macOS)
            // 位置校準 (僅 macOS)
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    // 手牌間距
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("手牌間距")
                            Spacer()
                            Text("\(Int(tileSpacing)) px")
                                .foregroundColor(.secondary)
                        }
                        Slider(value: $tileSpacing, in: 50...100, step: 1)
                            .onChange(of: tileSpacing) { _, _ in
                                updateCalibration()
                            }
                    }

                    // 水平偏移
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("水平偏移")
                            Spacer()
                            Text("\(Int(offsetX)) px")
                                .foregroundColor(.secondary)
                        }
                        Slider(value: $offsetX, in: -200...200, step: 5)
                            .onChange(of: offsetX) { _, _ in
                                updateCalibration()
                            }
                    }

                    // 垂直偏移
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("垂直偏移")
                            Spacer()
                            Text("\(Int(offsetY)) px")
                                .foregroundColor(.secondary)
                        }
                        Slider(value: $offsetY, in: -200...200, step: 5)
                            .onChange(of: offsetY) { _, _ in
                                updateCalibration()
                            }
                    }

                    Divider()

                    // 按鈕
                    HStack {
                        Button("重置預設") {
                            tileSpacing = 96.0
                            offsetX = -200.0
                            offsetY = 0.0
                            updateCalibration()
                        }
                        .buttonStyle(.bordered)
                    }
                }
            } label: {
                Label("位置校準", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            #endif

            // Bot 管理
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Bot 會在遊戲開始時自動創建，通常不需要手動管理。")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    HStack {
                        Button("重建 Bot") {
                            Task {
                                viewModel.deleteNativeBot()
                                try? await Task.sleep(nanoseconds: 100_000_000)
                                try? await viewModel.createNativeBot(playerId: 0)
                            }
                        }
                        .buttonStyle(.bordered)

                        Button("刪除 Bot") {
                            viewModel.deleteNativeBot()
                        }
                        .buttonStyle(.bordered)
                        #if os(macOS)
                        .tint(.red)
                        #endif
                    }
                }
            } label: {
                Label("Bot 管理", systemImage: "cpu")
            }

            #if os(macOS)
            // Debug Server (僅 macOS)
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Circle()
                            .fill(viewModel.isDebugServerRunning ? Color.green : Color.gray)
                            .frame(width: 8, height: 8)
                        Text(viewModel.isDebugServerRunning ? "運行中" : "已停止")

                        Spacer()

                        Button(viewModel.isDebugServerRunning ? "停止" : "啟動") {
                            viewModel.toggleDebugServer()
                        }
                        .buttonStyle(.bordered)
                        .tint(viewModel.isDebugServerRunning ? .red : .green)
                    }

                    if viewModel.isDebugServerRunning {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("http://localhost:\(viewModel.debugServerPort)")
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)

                            Text("curl http://localhost:\(viewModel.debugServerPort)/logs")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundColor(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
            } label: {
                Label("Debug Server", systemImage: "server.rack")
            }
            #endif
        }
        .padding()
    }

    private func updateCalibration() {
        // TODO: 實作校準更新功能
    }
}

// MARK: - Status Bar

struct StatusBar: View {
    var viewModel: WebViewModel

    var body: some View {
        if !viewModel.statusMessage.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: statusIcon)
                    .foregroundColor(statusColor)
                Text(viewModel.statusMessage)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                Spacer()

                // 顯示推薦數量
                if viewModel.recommendationCount > 0 {
                    Text("\(viewModel.recommendationCount) 推薦")
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
        }
    }

    private var statusIcon: String {
        if viewModel.statusMessage.contains("錯誤") || viewModel.statusMessage.contains("Error") {
            return "exclamationmark.triangle.fill"
        } else if viewModel.statusMessage.contains("成功") || viewModel.statusMessage.contains("已") {
            return "checkmark.circle.fill"
        }
        return "info.circle.fill"
    }

    private var statusColor: Color {
        if viewModel.statusMessage.contains("錯誤") || viewModel.statusMessage.contains("Error") {
            return .red
        } else if viewModel.statusMessage.contains("成功") || viewModel.statusMessage.contains("已") {
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
