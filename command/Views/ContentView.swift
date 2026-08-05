//
//  ContentView.swift
//  Naki
//
//  Created by Suoie on 2025/11/29.
//  Updated: 2025/12/05 - 使用 @Environment 傳遞 WebViewModel
//  Updated: 2026/01/26 - 使用 AdaptiveNakiWebView 支援 macOS 14+/iOS 17+
//  Updated: 2026/08/02 - p3-4：改吃 `@Environment(\.naki)`（store / settings / actions）
//

import SwiftUI

struct ContentView: View {

    /// Naki 的三件東西：狀態、設定、副作用。
    ///
    /// p3-4：先前是 `@State private var viewModel = WebViewModelFactory.create()`
    /// ——View 自己建 view model，於是「誰擁有 App 的生命週期」是 SwiftUI 的
    /// diffing 規則說了算，而 Preview 會真的去建一個 WebView、啟一個 MCP server。
    /// 現在由 App 層（`NakiApp` / `Naki_MApp`）持有 `NakiRuntime` 並顯式注入；
    /// 這裡的預設值只給 Preview（見 `NakiEnvironment`）。
    @Environment(\.naki) private var naki

#if os(macOS)
    @State private var showGamePanel = true
#else
    @State private var showGamePanel = false
#endif
    @State private var showAdvancedSettings = false
    @State private var showLog = false

    // 自動打牌控制
    //
    // key 與 runtime 共用（`AutoPlayModeStore.key`）：以前 UI 存 "AutoPlayMode"、
    // ViewModel 存 "naki.autoPlayMode"，兩邊各記各的，picker 顯示的模式可以跟
    // 實際驅動送出的模式不一致。舊 key 的一次性遷移在 `NakiApp.init()`。
    @AppStorage(AutoPlayModeStore.key) private var autoPlayMode: AutoPlayMode = AutoPlayModeStore
        .defaultMode

    /// 這條 WebView 路徑真的能執行的模式（Legacy 沒有「自動」，見 `AutoPlayAvailability`）
    private var availableAutoPlayModes: [AutoPlayMode] {
        AutoPlayAvailability.modes(autoPlaySupported: naki.settings.supportsAutoPlay)
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
            // 收斂與持久化在 `NakiRuntime.setAutoPlayMode` → `AutoPlayAvailability.commit`；
            // Action 只是這個 View 對「切模式」這件副作用的型別化入口（p3-3）。
            naki.actions.setAutoPlayMode(newValue)
        }
        .accessibilityIdentifier("autoplay-mode-picker")
        .accessibilityLabel("自動打牌模式")
        .accessibilityHint(naki.settings.supportsAutoPlay
                           ? "" : AutoPlayAvailability.autoUnavailableReason)
    }

    /// 自動打牌基準延遲 stepper：`[ 1.0s ⌃⌄ ]`。
    ///
    /// p1-3 移除的假控制在 p2-6 做回來並接真——它不是取代 `ActionDelayModel` 的隨機
    /// 分布（那是防偵測的刻意設計），而是當它的**縮放係數**：1.0s＝現行行為，
    /// 向下更快、向上更慢。值寫進 `SettingsStore`（重啟保留），讀取端是 `AutoPlayEngine`。
    ///
    /// **只在這條 path 真的會自動送出時才出現**（`supportsAutoPlay`）：Legacy 路徑
    /// 不提供自動送出，延遲永遠不會生效，掛在那裡就又是一個假控制（見 picker 的同款判斷）。
    /// 在支援的 path 上不隨當前模式隱藏——它是「未來切到自動時」的設定，不是即時動作，
    /// 跟著模式閃現反而干擾。
    private var actionDelayStepper: some View {
        // 數字自己畫，Stepper 只出上下箭頭（`.labelsHidden`）。
        // macOS 的 `Stepper(value:) { label }` 在 toolbar 這種水平緊湊容器裡
        // 會把 trailing-closure label 吃掉、只剩箭頭（實測畫面上「1.0s」不見了），
        // 所以改成 HStack 把值文字明確擺在箭頭左邊。
        HStack(spacing: 4) {
            Text(String(format: "%.1fs", naki.settings.actionDelaySeconds))
                .font(.system(.caption, design: .monospaced))
                .monospacedDigit()
                .frame(minWidth: 32, alignment: .trailing)
            Stepper("自動打牌基準延遲",
                    value: Binding(get: { naki.settings.actionDelaySeconds },
                                   set: { naki.settings.actionDelaySeconds = $0 }),
                    in: SettingsStore.actionDelayRange,
                    step: SettingsStore.actionDelayStep)
                .labelsHidden()
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("autoplay-delay-stepper")
        .accessibilityLabel("自動打牌基準延遲")
        .accessibilityValue(String(format: "%.1f 秒", naki.settings.actionDelaySeconds))
        .help("送出前的模擬人類延遲基準；1.0s 為預設，向上更慢、向下更快（隨機分布保留）")
    }

    var body: some View {
        Group {
#if os(macOS)
            macOSLayout
#else
            iOSLayout
#endif
        }
        .task {
            // 存檔可能是在支援自動送出的裝置上寫下的 `.auto`。Picker 上沒有那個選項時，
            // 選取值對不到任何 tag，segmented control 會顯示成「沒有任何一段被選中」；
            // runtime 那邊也已經降級成推薦，兩邊必須講同一句話。
            let clamped = AutoPlayAvailability.clamp(
                autoPlayMode, autoPlaySupported: naki.settings.supportsAutoPlay)
            if clamped != autoPlayMode {
                autoPlayMode = clamped
                naki.actions.setAutoPlayMode(clamped)
            }
        }
    }

    // MARK: - macOS Layout
#if os(macOS)
    private var macOSLayout: some View {
        HSplitView {
            // WebView (由 WebSession 決定是 WebPage 還是 WKWebView)
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
            VStack(spacing: 0) {
                JSInjectionFailureBanner()
                LiqiParseFailureBanner()
            }
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
                .help(naki.settings.supportsAutoPlay
                      ? "AI 推薦模式"
                      : "AI 推薦模式（此裝置不提供自動送出）")
        }

        // 延遲基準 stepper（p2-6）：它縮放 `ActionDelayModel` 的隨機分布，讀取端是
        // `AutoPlayEngine`。只在支援自動送出的 path 上出現——否則延遲永不生效，
        // 掛著就是 p1-3 抓到的那種假控制。
        if naki.settings.supportsAutoPlay {
            ToolbarItem(placement: .navigation) {
                actionDelayStepper
                    .frame(width: 96)
            }
        }

        // MCP Server
        ToolbarItem(placement: .navigation) {
            Button(action: { naki.actions.toggleDebugServer() }) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack{
                        Circle()
                            .fill(naki.store.isDebugServerRunning ? Color.green : Color.gray)
                            .frame(width: 6, height: 6)

                        Text("\(naki.store.debugServerPort)")
                            .font(.system(.caption, design: .monospaced))

                    }
                    Text("MCP Server")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .frame(width: 80)
            .help(naki.store.isDebugServerRunning ? "MCP Server 運行中" : "MCP Server 已停止")
            .accessibilityIdentifier("mcp-server-toggle")
            .accessibilityLabel("MCP Server")
            .accessibilityValue(naki.store.isDebugServerRunning
                                ? "運行中，連接埠 \(naki.store.debugServerPort)" : "未運行")
        }

        // 連接狀態
        ToolbarItem(placement: .navigation) {
            ConnectionIndicator()
                .frame(width: 80)
        }

        // 重新載入
        ToolbarItem(placement: .destructiveAction) {
            Button(action: { naki.actions.reloadPage() }) {
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
            .safeAreaInset(edge: .top) {
                LiqiParseFailureBanner()
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
            if !naki.store.statusMessage.isEmpty {
                StatusBar()
            }
        }
    }
    private var iOSLeftView: some View {
        VStack(alignment:.leading, spacing: 16) {
            VStack{
                HStack(spacing: 4) {
                    Circle()
                        .fill(naki.store.isConnected ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                    Text(naki.store.isConnected ? "已連接" : "未連接")
                        .font(.caption)
                }

                Text("WebSocket")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("websocket-connection-indicator")
            .accessibilityLabel("WebSocket 連線狀態")
            .accessibilityValue(naki.store.isConnected ? "已連接" : "未連接")

            RecommendationView(
                recommendations: naki.store.recommendations,
                maxDisplay: 5,
                showsRecommendations: naki.store.autoPlayMode.showRecommendation,
                reloadBot: naki.actions.forceReconnect
            )
        }
        .frame(width: 140)
    }

    @ToolbarContentBuilder
    private var iOSToolbarContent: some ToolbarContent {
        // 左側：重新載入
        ToolbarItem(placement: .navigationBarLeading) {
            Button(action: { naki.actions.reloadPage() }) {
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

        // 延遲基準 stepper：與 macOS 同款、同一份 `SettingsStore` 讀寫；
        // 只在支援自動送出的 path（iOS 26+ WebPage）出現，Legacy 不掛假控制。
        if naki.settings.supportsAutoPlay {
            ToolbarItem(placement: .automatic) {
                actionDelayStepper
            }
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
                        botStatus: naki.store.botStatus,
                        gameState: naki.store.gameState,
                        reloadBot: naki.actions.forceReconnect
                    )

                    // AI 推薦
                    RecommendationView(
                        recommendations: naki.store.recommendations,
                        maxDisplay: 5,
                        showsRecommendations: naki.store.autoPlayMode.showRecommendation,
                        reloadBot: naki.actions.forceReconnect
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
    @Environment(\.naki) private var naki
    @Binding var showLog: Bool

    var body: some View {
        VSplitView {
            // 上半部分：Bot 狀態和推薦
            VStack(spacing: 12) {
                // Bot 狀態
                BotStatusView(
                    botStatus: naki.store.botStatus,
                    gameState: naki.store.gameState,
                    reloadBot: naki.actions.forceReconnect
                )

                // AI 推薦
                RecommendationView(
                    recommendations: naki.store.recommendations,
                    maxDisplay: 5,
                    showsRecommendations: naki.store.autoPlayMode.showRecommendation,
                    reloadBot: naki.actions.forceReconnect
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
    @Environment(\.naki) private var naki

    private var isConnected: Bool { naki.store.isConnected }

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
    @Environment(\.naki) private var naki
    @Environment(\.dismiss) private var dismiss

    /// 「測試連線」的結果（只活在這張 sheet 裡；nil＝還沒測）
    @State private var cloudTestResult: String?
    @State private var cloudTestRunning = false
    /// 測試連線取回的模型清單（供模型欄的下拉選擇；空＝還沒取到）
    @State private var cloudModels: [CloudModelInfo] = []

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

    /// 隱藏玩家名稱的持久化來源只有 `SettingsStore` 一份。
    ///
    /// 先前這裡是 `@AppStorage("HidePlayerNames")`，而兩個 view model 各自也寫同一個
    /// key——同一個設定三個寫入點，其中兩個是字面值字串。
    private var hidePlayerNames: Binding<Bool> {
        Binding(get: { naki.settings.hidePlayerNames },
                set: { naki.actions.setHidePlayerNames($0) })
    }

    // ☁️ 雲端推論設定：讀寫都是 `SettingsStore` 那一份（key 進 Keychain，
    // 見 `SettingsStore.cloudAPIKey`）。改動在**下一個決策點**生效並 reset 斷路器。
    private var cloudEnabled: Binding<Bool> {
        Binding(get: { naki.settings.cloudInferenceEnabled },
                set: { naki.settings.cloudInferenceEnabled = $0 })
    }
    private var cloudServerURL: Binding<String> {
        Binding(get: { naki.settings.cloudServerURL },
                set: { naki.settings.cloudServerURL = $0 })
    }
    private var cloudAPIKey: Binding<String> {
        Binding(get: { naki.settings.cloudAPIKey },
                set: { naki.settings.cloudAPIKey = $0 })
    }
    private var cloudModel4P: Binding<String> {
        Binding(get: { naki.settings.cloudModel4P },
                set: { naki.settings.cloudModel4P = $0 })
    }
    private var cloudModel3P: Binding<String> {
        Binding(get: { naki.settings.cloudModel3P },
                set: { naki.settings.cloudModel3P = $0 })
    }

    /// 模型欄：手動輸入為底、伺服器清單為加速器，兩者並存。
    ///
    /// 為什麼不是純下拉：`/v3/models` 是**認證端點**（沒貼有效 key 前拿不到
    /// 清單），而自架伺服器可能根本沒有這個端點——純下拉在這兩種情境會把
    /// 使用者卡死。所以自由輸入永遠可用，「測試連線」成功後箭頭選單才亮起。
    @ViewBuilder
    private func cloudModelRow(placeholder: String, text: Binding<String>,
                               game: String, accessibilityId: String) -> some View {
        HStack {
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .accessibilityIdentifier(accessibilityId)
            Menu {
                Button("伺服器預設（清空）") { text.wrappedValue = "" }
                ForEach(cloudModels.filter { $0.game.isEmpty || $0.game == game },
                        id: \.id) { model in
                    Button(model.desc.isEmpty ? model.id : "\(model.id) — \(model.desc)") {
                        text.wrappedValue = model.id
                    }
                }
            } label: {
                Image(systemName: "chevron.down.circle")
            }
            .disabled(cloudModels.isEmpty)
            .help(cloudModels.isEmpty ? "先按「測試連線」取得模型清單" : "從伺服器清單選擇")
            .accessibilityIdentifier("\(accessibilityId)-picker")
        }
    }

    /// 測試連線：`/healthz`（無認證，驗伺服器活不活）＋有 key 時再打
    /// `/v3/models`（驗 key、列可用模型）。對局開始前就能發現問題，
    /// 不必等到第一手。
    private func runCloudConnectionTest() {
        let baseURL = naki.settings.cloudServerURL
        let key = naki.settings.cloudAPIKey
        cloudTestRunning = true
        cloudTestResult = nil
        Task {
            defer { cloudTestRunning = false }
            do {
                let health = try await AkagiApiClient.health(baseURL: baseURL)
                guard !key.trimmingCharacters(in: .whitespaces).isEmpty else {
                    cloudTestResult = "伺服器 \(health.status)（未填 key，略過模型查詢）"
                    return
                }
                guard let client = AkagiApiClient(baseURL: baseURL, key: key) else {
                    cloudTestResult = "URL 無法解析"
                    return
                }
                let models = try await client.models()
                cloudModels = models   // 餵給模型欄的下拉（見 cloudModelRow）
                let ids = models.map { "\($0.id)(\($0.game))" }.joined(separator: ", ")
                cloudTestResult = "伺服器 \(health.status)；可用模型：\(ids.isEmpty ? "無" : ids)"
                    + (models.isEmpty ? "" : "——可用模型欄旁的箭頭直接選")
            } catch {
                cloudTestResult = "失敗：\(error.localizedDescription)"
            }
        }
    }

    private var settingsForm: some View {
        VStack(alignment: .leading, spacing: 20) {

            // 自動打牌可用性（只有在這條路徑不支援時才出現）
            autoPlayAvailabilityBox

            // 畫面
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("隱藏玩家名稱", isOn: hidePlayerNames)
                        .accessibilityIdentifier("hide-player-names-toggle")

                    Text("在遊戲解析封包前把暱稱改寫成 Player 1–4。只對開啟之後才開始的對局生效；斷線重連與終局結算畫面仍會顯示原名。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } label: {
                Label("畫面", systemImage: "eye.slash")
            }

            // ☁️ 雲端推論（docs/cloud-inference-plan.md；key 在 Keychain）
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("啟用雲端推論", isOn: cloudEnabled)
                        .accessibilityIdentifier("cloud-inference-toggle")

                    Text("啟用後，每個決策點會把**本局至今的對局事件（含自家手牌）**上傳到下方伺服器換取決策；伺服器失敗時自動退回內建本地模型，對局不會停擺。API key 存在 Keychain，不會出現在 log 或設定檔。")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    TextField("伺服器 URL", text: cloudServerURL)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("cloud-server-url-field")

                    SecureField("API Key（自行取得後貼上）", text: cloudAPIKey)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("cloud-api-key-field")

                    cloudModelRow(placeholder: "四麻模型（空＝伺服器預設）",
                                  text: cloudModel4P, game: "4p",
                                  accessibilityId: "cloud-model-4p-field")
                    cloudModelRow(placeholder: "三麻模型（空＝伺服器預設）",
                                  text: cloudModel3P, game: "3p",
                                  accessibilityId: "cloud-model-3p-field")

                    HStack {
                        Button(cloudTestRunning ? "測試中…" : "測試連線") {
                            runCloudConnectionTest()
                        }
                        .buttonStyle(.bordered)
                        .disabled(cloudTestRunning)
                        .accessibilityIdentifier("cloud-test-button")

                        if let result = cloudTestResult {
                            Text(result)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .accessibilityIdentifier("cloud-test-result")
                        }
                    }

                    Text("三麻提醒：雲端 3p 模型是目前唯一的真三麻路徑；雲端失敗退回的本地模型仍是四麻模型，側欄的決策來源會如實顯示。")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            } label: {
                Label("雲端推論", systemImage: "icloud.and.arrow.up")
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
                                await naki.actions.forceReconnect()
                            }
                        }
                        .buttonStyle(.bordered)
                        .help("強制斷線重連，伺服器會重新發送遊戲狀態重建 Bot")
                        .accessibilityIdentifier("rebuild-bot-button")

                        Button("刪除 Bot") {
                            naki.actions.deleteBot()
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
                                .fill(naki.store.isDebugServerRunning ? Color.green : Color.gray)
                                .frame(width: 8, height: 8)
                            Text(naki.store.isDebugServerRunning ? "運行中" : "已停止")
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("mcp-server-status")
                        .accessibilityLabel("MCP Server 狀態")
                        .accessibilityValue(naki.store.isDebugServerRunning ? "運行中" : "已停止")

                        Spacer()

                        Button(naki.store.isDebugServerRunning ? "停止" : "啟動") {
                            naki.actions.toggleDebugServer()
                        }
                        .buttonStyle(.bordered)
                        .tint(naki.store.isDebugServerRunning ? .red : .green)
                        .accessibilityIdentifier("mcp-server-toggle-button")
                    }

                    if naki.store.isDebugServerRunning {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("http://localhost:\(naki.store.debugServerPort)")
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)

                            Text("curl http://localhost:\(naki.store.debugServerPort)/logs")
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
        if !naki.settings.supportsAutoPlay {
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

// MARK: - Liqi 解析失敗橫幅

/// 封包解析失敗到「這一局不會運作」程度時的常駐橫幅（p4-1）。
///
/// 為什麼要有它：以前 authGame 回應少了 seatList 只會寫一行 log，
/// `start_game` 不發、Bot 不建立、推薦永遠是空的——而畫面上顯示的是
/// 「已連線到雀魂服务器」。使用者唯一的線索是「怎麼都沒有推薦」。
///
/// 與 `JSInjectionFailureBanner` 的分工：那個是「Naki 根本沒接上頁面」，
/// 這個是「接上了，但這一局的關鍵欄位解不開」。後者會自己好
/// （下一局 authGame／start_kyoku 成功就 `clearBlocking()`），所以不寫
/// 「重裝 App」那種指示。
struct LiqiParseFailureBanner: View {

    var body: some View {
        if let summary = LiqiParseFaultState.shared.bannerSummary {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .imageScale(.large)

                VStack(alignment: .leading, spacing: 2) {
                    Text("牌局封包解析失敗：這一局 Naki 不會給推薦，也不會自動打牌")
                        .font(.headline)
                    Text(summary)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    Text("下一局（或重連）解析成功就會自動消失；持續出現代表雀魂改了協定欄位。")
                        .font(.caption)
                        .opacity(0.9)
                }

                Spacer(minLength: 0)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("liqi-parse-failure-banner")
            .accessibilityLabel("牌局封包解析失敗")
            .accessibilityValue(summary)
        }
    }
}

// MARK: - Status Bar

struct StatusBar: View {
    @Environment(\.naki) private var naki

    private var message: String { naki.store.statusMessage }

    var body: some View {
        if !message.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: statusIcon)
                    .foregroundColor(statusColor)
                Text(message)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                Spacer()

                // 顯示推薦數量
                if naki.store.recommendationCount > 0 {
                    Text("\(naki.store.recommendationCount) 推薦")
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
        if message.contains("錯誤") || message.contains("Error") {
            return "exclamationmark.triangle.fill"
        } else if message.contains("成功") || message.contains("已") {
            return "checkmark.circle.fill"
        }
        return "info.circle.fill"
    }

    private var statusColor: Color {
        if message.contains("錯誤") || message.contains("Error") {
            return .red
        } else if message.contains("成功") || message.contains("已") {
            return .green
        }
        return .blue
    }
}

#Preview {
    // 預設 `NakiEnvironment`（空 store + 無副作用的 Action）——不會建立 WebView，
    // 也不會啟動 MCP server。正式 Scene 由 `NakiApp` 顯式注入。
    ContentView()
        #if os(macOS)
        .frame(width: 1200, height: 800)
        #endif
}
