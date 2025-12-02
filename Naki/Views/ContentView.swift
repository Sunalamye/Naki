//
//  ContentView.swift
//  akagi
//
//  Created by Suoie on 2025/11/29.
//  升級到 macOS 26 - 使用 Observation 框架和原生 WebView
//

import SwiftUI
import WebKit

struct ContentView: View {
    @State private var viewModel = WebViewModel()
    @State private var showSettings = false
    @State private var showGamePanel = true

    var body: some View {
        HStack(spacing: 0) {
            // 側邊欄（設定面板）
            if showSettings {
                SettingsPanel(viewModel: viewModel)
                    .frame(width: 280)
                    .transition(.move(edge: .leading))
            }

            // 主內容區
            VStack(spacing: 0) {
                // 頂部工具列
                TopToolbar(viewModel: viewModel, showSettings: $showSettings, showGamePanel: $showGamePanel)

                Divider()

                // 主體內容
                HSplitView {
                    // WebView
                    NakiWebView(viewModel: viewModel)
                        .frame(minWidth: 600)

                    // 遊戲面板（右側）
                    if showGamePanel {
                        GamePanel(viewModel: viewModel)
                            .frame(width: 320)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // 狀態列
                StatusBar(viewModel: viewModel)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showSettings)
        .animation(.easeInOut(duration: 0.2), value: showGamePanel)
    }
}

// MARK: - Game Panel (右側面板)

struct GamePanel: View {
    var viewModel: WebViewModel
    @State private var showLog = false

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
        .toolbar {
            ToolbarItem {
                Button(action: { showLog.toggle() }) {
                    Image(systemName: showLog ? "terminal.fill" : "terminal")
                }
                .help("顯示/隱藏日誌")
            }
        }
    }
}

// MARK: - Tehai Bar (底部手牌欄)

// MARK: - Top Toolbar

struct TopToolbar: View {
    var viewModel: WebViewModel
    @Binding var showSettings: Bool
    @Binding var showGamePanel: Bool

    var body: some View {
        HStack(spacing: 12) {
            // 設定按鈕
            Button(action: { showSettings.toggle() }) {
                Image(systemName: showSettings ? "sidebar.left" : "sidebar.right")
            }
            .help("顯示/隱藏設定")

            Text("Naki")
                .font(.headline)

            // 連接狀態指示器
            ConnectionIndicator(viewModel: viewModel)

            Spacer()

            Divider()
                .frame(height: 20)

            // 重新載入按鈕
            Button(action: {
                viewModel.wkWebView?.reload()
            }) {
                Image(systemName: "arrow.clockwise")
            }
            .help("重新載入")

            Divider()
                .frame(height: 20)

            // 遊戲面板切換
            Button(action: { showGamePanel.toggle() }) {
                Image(systemName: showGamePanel ? "sidebar.trailing" : "sidebar.right")
            }
            .help("顯示/隱藏遊戲面板")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

// MARK: - Connection Indicator

struct ConnectionIndicator: View {
    var viewModel: WebViewModel

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(viewModel.isConnected ? Color.green : Color.red)
                .frame(width: 8, height: 8)
            Text(viewModel.isConnected ? "已連接" : "未連接")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Settings Panel

struct SettingsPanel: View {
    var viewModel: WebViewModel
    @State private var selectedModel = "mortal"
    @State private var autoSwitch = true
    @State private var temperature = 0.3
    @State private var autoPlayMode: AutoPlayMode = .auto  // 預設開啟全自動
    @State private var actionDelay: Double = 1.0
    // 點擊位置校準 (預設值已根據實測調整)
    @State private var tileSpacing: Double = 96.0     // 手牌間距
    @State private var offsetX: Double = -200.0       // 水平偏移
    @State private var offsetY: Double = 0.0          // 垂直偏移

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 標題
            HStack {
                Image(systemName: "gearshape.fill")
                Text("設定")
                    .font(.headline)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Bot 引擎設定
                    GroupBox("Bot 引擎") {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Image(systemName: "cpu")
                                Text("原生 Core ML")
                                    .font(.headline)
                            }

                            Text("使用 MortalSwift + Core ML，無需 Python")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            HStack {
                                Button("創建 Bot") {
                                    Task {
                                        do {
                                            try await viewModel.createNativeBot(playerId: 0)
                                        } catch {
                                            viewModel.statusMessage = "創建失敗: \(error.localizedDescription)"
                                        }
                                    }
                                }
                                .buttonStyle(.bordered)

                                Button("刪除 Bot") {
                                    viewModel.deleteNativeBot()
                                }
                                .buttonStyle(.bordered)
                                .foregroundColor(.red)
                            }
                        }
                        .padding(.vertical, 4)
                    }

                    // 自動打牌設定 (實驗性功能)
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Image(systemName: "play.circle.fill")
                                    .foregroundColor(.orange)
                                Text("自動打牌")
                                    .font(.headline)
                                Text("實驗性")
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.orange.opacity(0.2))
                                    .foregroundColor(.orange)
                                    .cornerRadius(4)
                            }

                            Picker("模式:", selection: $autoPlayMode) {
                                ForEach(AutoPlayMode.allCases, id: \.self) { mode in
                                    Text(mode.rawValue).tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)
                            .onChange(of: autoPlayMode) { _, newValue in
                                viewModel.setAutoPlayMode(newValue)
                            }

                            if autoPlayMode != .off {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("動作延遲: \(actionDelay, specifier: "%.1f") 秒")
                                        .font(.caption)
                                    Slider(value: $actionDelay, in: 0.5...5.0, step: 0.5)
                                        .onChange(of: actionDelay) { _, newValue in
                                            viewModel.setAutoPlayDelay(newValue)
                                        }
                                }
                            }

                            if autoPlayMode == .auto {
                                HStack {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundColor(.yellow)
                                    Text("全自動模式會自動執行推薦動作")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }

                            Divider()

                            // 位置校準
                            VStack(alignment: .leading, spacing: 8) {
                                Text("位置校準")
                                    .font(.caption)
                                    .foregroundColor(.secondary)

                                // 手牌間距
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text("手牌間距:")
                                            .font(.caption)
                                        Spacer()
                                        Text("\(Int(tileSpacing)) px")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    Slider(value: $tileSpacing, in: 50...100, step: 1)
                                        .onChange(of: tileSpacing) { _, newValue in
                                            viewModel.updateClickCalibration(
                                                tileSpacing: newValue,
                                                offsetX: offsetX,
                                                offsetY: offsetY
                                            )
                                        }
                                }

                                // 水平偏移
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text("水平偏移 (←→):")
                                            .font(.caption)
                                        Spacer()
                                        Text("\(Int(offsetX)) px")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    Slider(value: $offsetX, in: -200...200, step: 5)
                                        .onChange(of: offsetX) { _, newValue in
                                            viewModel.updateClickCalibration(
                                                tileSpacing: tileSpacing,
                                                offsetX: newValue,
                                                offsetY: offsetY
                                            )
                                        }
                                }

                                // 垂直偏移
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text("垂直偏移 (↑↓):")
                                            .font(.caption)
                                        Spacer()
                                        Text("\(Int(offsetY)) px")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    Slider(value: $offsetY, in: -200...200, step: 5)
                                        .onChange(of: offsetY) { _, newValue in
                                            viewModel.updateClickCalibration(
                                                tileSpacing: tileSpacing,
                                                offsetX: offsetX,
                                                offsetY: newValue
                                            )
                                        }
                                }

                                // 重置按鈕
                                Button("重置為預設") {
                                    tileSpacing = 96.0
                                    offsetX = -200.0
                                    offsetY = 0.0
                                    viewModel.updateClickCalibration(
                                        tileSpacing: 96.0,
                                        offsetX: -200.0,
                                        offsetY: 0.0
                                    )
                                }
                                .font(.caption)
                                .buttonStyle(.bordered)
                            }

                            Divider()

                            // 測試按鈕
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Button("測試點擊位置") {
                                        viewModel.testAutoPlayIndicators()
                                    }
                                    .buttonStyle(.bordered)

                                    Button("測試單擊") {
                                        viewModel.testSingleClick()
                                    }
                                    .buttonStyle(.bordered)
                                }

                                HStack {
                                    Button("🔍 探測 API") {
                                        viewModel.detectGameAPI()
                                    }
                                    .buttonStyle(.bordered)

                                    Button("🔬 深度探索") {
                                        viewModel.exploreGameObjects()
                                    }
                                    .buttonStyle(.bordered)

                                    Button("🎯 找手牌") {
                                        viewModel.findHandTiles()
                                    }
                                    .buttonStyle(.bordered)
                                }
                                .help("搜尋遊戲內部 API 以自動計算座標")
                            }
                            .font(.caption)
                        }
                        .padding(.vertical, 4)
                    } label: {
                        HStack {
                            Text("自動打牌")
                            Spacer()
                            if autoPlayMode != .off {
                                Circle()
                                    .fill(Color.green)
                                    .frame(width: 8, height: 8)
                            }
                        }
                    }

                    // Debug Server
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: "server.rack")
                                    .foregroundColor(.purple)
                                Text("Debug Server")
                                    .font(.headline)
                            }

                            HStack {
                                Circle()
                                    .fill(viewModel.isDebugServerRunning ? Color.green : Color.gray)
                                    .frame(width: 8, height: 8)
                                Text(viewModel.isDebugServerRunning ? "運行中" : "已停止")
                                    .font(.caption)

                                Spacer()

                                Button(viewModel.isDebugServerRunning ? "停止" : "啟動") {
                                    viewModel.toggleDebugServer()
                                }
                                .buttonStyle(.bordered)
                                .tint(viewModel.isDebugServerRunning ? .red : .green)
                            }

                            if viewModel.isDebugServerRunning {
                                Text("http://localhost:\(viewModel.debugServerPort)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .textSelection(.enabled)

                                Text("curl http://localhost:\(viewModel.debugServerPort)/detect")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(.vertical, 4)
                    } label: {
                        HStack {
                            Text("Debug Server")
                            Spacer()
                            if viewModel.isDebugServerRunning {
                                Circle()
                                    .fill(Color.green)
                                    .frame(width: 8, height: 8)
                            }
                        }
                    }

                    // 模型設定
                    GroupBox("AI 模型") {
                        VStack(alignment: .leading, spacing: 12) {
                            Picker("模型:", selection: $selectedModel) {
                                Text("Mortal (4P)").tag("mortal")
                                Text("Mortal3p (3P)").tag("mortal3p")
                            }
                            .pickerStyle(.radioGroup)

                            Toggle("自動切換 (4P/3P)", isOn: $autoSwitch)

                            VStack(alignment: .leading, spacing: 4) {
                                Text("推薦溫度: \(temperature, specifier: "%.2f")")
                                Slider(value: $temperature, in: 0.1...2.0, step: 0.1)
                            }
                        }
                        .padding(.vertical, 4)
                    }

                    // 狀態顯示
                    GroupBox("狀態") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Circle()
                                    .fill(viewModel.isConnected ? Color.green : Color.red)
                                    .frame(width: 8, height: 8)
                                Text(viewModel.isConnected ? "已連接" : "未連接")
                            }
                            Text(viewModel.statusMessage)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
                .padding()
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
    }
}

// MARK: - Status Bar

struct StatusBar: View {
    var viewModel: WebViewModel

    var body: some View {
        if !viewModel.statusMessage.isEmpty {
            Divider()
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
