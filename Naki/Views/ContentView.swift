//
//  ContentView.swift
//  Naki
//
//  Created by Suoie on 2025/11/29.
//  Updated: 2025/12/03 - 控制項移至原生 Toolbar
//

import SwiftUI
import WebKit

struct ContentView: View {
    @State private var viewModel = WebViewModel()
    @State private var showGamePanel = true
    @State private var showAdvancedSettings = false
    @State private var showLog = false

    // 自動打牌控制
    @State private var autoPlayMode: AutoPlayMode = .auto
    @State private var actionDelay: Double = 1.0

    var body: some View {
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
                    Text("提示").tag(AutoPlayMode.recommend)
                    Text("自動").tag(AutoPlayMode.auto)
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
                .onChange(of: autoPlayMode) { _, newValue in
                    viewModel.setAutoPlayMode(newValue)
                }
                .help("自動打牌模式")
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
                Button(action: { viewModel.wkWebView?.reload() }) {
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
    }
}

// MARK: - Game Panel (右側面板)

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
        .background(Color(NSColor.windowBackgroundColor))
    }
}

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

    // 位置校準
    @State private var tileSpacing: Double = 96.0
    @State private var offsetX: Double = -200.0
    @State private var offsetY: Double = 0.0

    var body: some View {
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
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            ScrollView {
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
                        }
                    } label: {
                        Label("AI 設定", systemImage: "brain")
                    }

                    // 位置校準
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

                                Button("測試點擊") {
                                    viewModel.testAutoPlayIndicators()
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    } label: {
                        Label("位置校準", systemImage: "arrow.up.left.and.arrow.down.right")
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
                                .tint(.red)
                            }
                        }
                    } label: {
                        Label("Bot 管理", systemImage: "cpu")
                    }

                    // Debug Server
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
                }
                .padding()
            }
        }
        .frame(width: 400, height: 550)
    }

    private func updateCalibration() {
        viewModel.updateClickCalibration(
            tileSpacing: tileSpacing,
            offsetX: offsetX,
            offsetY: offsetY
        )
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
        .frame(width: 1200, height: 800)
}
