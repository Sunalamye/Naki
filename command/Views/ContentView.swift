//
//  ContentView.swift
//  Naki
//
//  Created by Suoie on 2025/11/29.
//  Updated: 2026/01/26 - 使用 AdaptiveNakiWebView 支援 macOS 14+/iOS 17+
//  Updated: 2026/08/02 - 改吃 `@Environment(\.naki)`（store / settings / actions）
//

import SwiftUI

struct ContentView: View {

    /// Naki 的三件東西：狀態、設定、副作用。
    ///
    /// **View 不自己建這些東西**：由 App 層（`NakiApp` / `Naki_MApp`）持有 `NakiRuntime`
    /// 並顯式注入。改成在 View 裡用 `@State` 建的話，「誰擁有 App 的生命週期」就變成
    /// SwiftUI 的 diffing 規則說了算，而 Preview 會真的去建一個 WebView、啟一個 MCP server。
    /// 這裡讀到的預設值只給 Preview（見 `NakiEnvironment`）。
    @Environment(\.naki) private var naki

    /// 決策面板／HUD 是否顯示。
    ///
    /// iOS 從 `false` 改成 `true`：它現在是浮在 WebView 上的 HUD，不再從牌桌
    /// 切走寬度，所以預設藏起來只會讓人以為 Naki 沒在運作。
    @State private var showGamePanel = true
    @State private var showAdvancedSettings = false
    @State private var showLog = false

    // 自動打牌控制
    //
    // key 與 runtime 共用（`AutoPlayModeStore.key`）：UI 與送出端各記各的 key，
    // picker 顯示的模式就會跟實際驅動送出的模式不一致。
    // 舊 key 的一次性遷移在 `NakiApp.init()`。
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
            // Action 只是這個 View 對「切模式」這件副作用的型別化入口。
            naki.actions.setAutoPlayMode(newValue)
        }
        .accessibilityIdentifier("autoplay-mode-picker")
        .accessibilityLabel("自動打牌模式")
        .accessibilityHint(naki.settings.supportsAutoPlay
                           ? "" : AutoPlayAvailability.autoUnavailableReason)
    }

    /// 自動打牌基準延遲 stepper：`[ 1.0s ⌃⌄ ]`。
    ///
    /// 它不取代 `ActionDelayModel` 的隨機分布（那是防偵測的刻意設計），而是當它的
    /// **縮放係數**：1.0s＝現行行為，向下更快、向上更慢。
    /// 值寫進 `SettingsStore`（重啟保留），讀取端是 `AutoPlayEngine`。
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
#if os(macOS)
        // `.help` 只包 macOS：iOS 上 tooltip 只在有指標裝置時看得到，對 iPhone 是
        // 多餘的 pointer 互動註冊。專案既有慣例就是這樣（見 `LogPanel` 的兩個 `.help`）。
        .help("送出前的模擬人類延遲基準；1.0s 為預設，向上更慢、向下更快（隨機分布保留）")
#endif
    }

    /// 雲端推論快速開關。
    ///
    /// 放 toolbar 而不是只留在設定頁：切雲端是**對局中**會做的事（雲端變慢就切回本地），
    /// 而設定頁在兩層之外。圖示反映的是**實際生效狀態**，不是開關值——
    /// 生效需要「開關＋URL＋key」三者同時成立，只畫開關會讓「貼了 key 沒開」
    /// 和「開了沒 key」長得一模一樣，而那正是最常見的兩種設定錯誤。
    private var cloudQuickToggle: some View {
        Button {
            naki.settings.cloudInferenceEnabled.toggle()
        } label: {
            Image(systemName: cloudIconName)
                .foregroundStyle(cloudIconTint)
        }
#if os(macOS)
        .help(cloudToggleHelp)
#endif
        .accessibilityIdentifier("toolbar-cloud-toggle")
        .accessibilityLabel("雲端推論")
        .accessibilityValue(cloudToggleHelp)
    }

    /// 缺哪些條件才算生效（與設定頁的 `cloudEffectiveStateRow` 讀同一份判定）
    private var cloudMissing: [String] { naki.settings.cloudConfig.missingRequirements }

    private var cloudIconName: String {
        if cloudMissing.isEmpty { return "icloud.fill" }
        // 開關開著卻沒生效是要警告的狀態，不能跟「刻意關閉」共用同一個圖示
        return naki.settings.cloudInferenceEnabled ? "exclamationmark.icloud" : "icloud.slash"
    }

    private var cloudIconTint: Color {
        if cloudMissing.isEmpty { return .accentColor }
        return naki.settings.cloudInferenceEnabled ? .orange : .secondary
    }

    private var cloudToggleHelp: String {
        if cloudMissing.isEmpty { return "雲端推論已生效——點一下切回本地模型" }
        if naki.settings.cloudInferenceEnabled {
            return "雲端推論尚未生效，還缺：" + cloudMissing.joined(separator: "、")
        }
        return "雲端推論已關閉，目前使用內建本地模型"
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

            // 決策面板（右側）
            if showGamePanel {
                GamePanel(showLog: $showLog)
                    .frame(width: 360)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .top) {
            VStack(spacing: 0) {
                JSInjectionFailureBanner()
                LiqiParseFailureBanner()
                PageLoadFailureBanner()
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
        // 雲端推論快速開關
        ToolbarItem(placement: .primaryAction) {
            cloudQuickToggle
        }

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

        // 延遲基準 stepper：它縮放 `ActionDelayModel` 的隨機分布，讀取端是
        // `AutoPlayEngine`。只在支援自動送出的 path 上出現——否則延遲永不生效，
        // 掛著就是個假控制。
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

    /// iPhone 版面：WebView 全寬，決策以浮動 HUD 疊在右上。
    ///
    /// 舊版是 `HStack { 固定 140pt 欄; WebView }`——那條側欄直接從牌桌切走一塊寬度，
    /// 而雀魂是 3D 橫向畫面，壓縮它的代價很實在。狀態列則是
    /// `.opacity(0.5).allowsHitTesting(false)` 疊在手牌上：半透明讓它既擋畫面又讀不清。
    ///
    /// HUD 不是側欄的等比縮小（見 `DecisionSidebar` 的 `compact`）：摘要條在 210pt 寬
    /// 只留局況與自風，其餘降級到展開層，否則每欄會縮到讀不了。
    private var iOSLayout: some View {
        NavigationStack {
            ZStack(alignment: .topTrailing) {
                AdaptiveNakiWebView()

                if showGamePanel {
                    DecisionSidebar(compact: true)
                        .frame(width: 210)
                        .background(.ultraThinMaterial,
                                    in: RoundedRectangle(cornerRadius: 14))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .strokeBorder(Color.secondary.opacity(0.28), lineWidth: 1)
                        )
                        .padding(10)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                        .accessibilityIdentifier("ios-decision-hud")
                }
            }
            // ⚠️ **絕對不要**在這裡加 `.animation(_:value:)`。
            //
            // 它會把隱式動畫套到整個子樹，包含 `AdaptiveNakiWebView`（WKWebView），
            // 而 WKWebView 自己帶一整組 UIGestureRecognizer。在 iOS 26 上，點雀魂
            // 登入頁的輸入框（鍵盤升起 → safe area 劇烈變動）會直接崩：
            //
            //     *** -[__NSArrayM insertObject:atIndex:]: object cannot be nil
            //     3  UIKitCore  -[UIGestureRecognizer _delayTouchesForEvent:inPhase:]
            //     7  UIKitCore  -[UIWindow sendEvent:]
            //
            // 2026-08-09 用二分法證實：其餘修正全部保留、只把這一行加回去，
            // `DecisionHUDTouchTests.testTappingWebViewTextFieldDoesNotCrash` 立刻
            // 重現崩潰（app state 變成 notRunning）。拿掉就過。
            //
            // 動畫改由切換處的 `withAnimation` 驅動，只作用在 HUD 的 transition。
            .safeAreaInset(edge: .top) {
                JSInjectionFailureBanner()
            }
            .safeAreaInset(edge: .top) {
                LiqiParseFailureBanner()
            }
            // 狀態列浮在畫面上但**可讀**：material 背景取代原本的 `opacity(0.5)`
            // （半透明到讀不清的文字沒有存在價值）。
            //
            // `allowsHitTesting(false)` 要保留——它是純資訊顯示，沒有任何可點的東西，
            // 卻疊在 WebView 上。先前改材質時把它拿掉了，那會讓它平白吃掉牌桌的觸控。
            // （它**不是**上面那個崩潰的成因，二分法已排除；純粹是它本來就該有。）
            .overlay(alignment: .bottom) {
                if !naki.store.statusMessage.isEmpty {
                    StatusBar()
                        .background(.ultraThinMaterial)
                        .allowsHitTesting(false)
                }
            }
            .navigationTitle("Naki")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                iOSToolbarContent
            }
            .sheet(isPresented: $showLog) {
                iOSLogSheet
            }
            .sheet(isPresented: $showAdvancedSettings) {
                AdvancedSettingsSheet()
            }
        }
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

        // 右側：決策 HUD 開關
        ToolbarItem(placement: .navigationBarTrailing) {
            Button {
                // 動畫綁在這裡而不是容器上：容器那條會波及 WebView（見 iOSLayout 註解）
                withAnimation(.easeInOut(duration: 0.2)) { showGamePanel.toggle() }
            } label: {
                Image(systemName: showGamePanel ? "sidebar.trailing" : "sidebar.right")
            }
            .accessibilityIdentifier("toolbar-game-panel-toggle")
            .accessibilityLabel("顯示或隱藏決策面板")
            .accessibilityValue(showGamePanel ? "已顯示" : "已隱藏")
        }

        // 右側：日誌
        ToolbarItem(placement: .navigationBarTrailing) {
            Button(action: { showLog = true }) {
                Image(systemName: "terminal")
            }
            .accessibilityIdentifier("toolbar-log-toggle")
            .accessibilityLabel("顯示日誌")
        }

        // 右側：雲端推論快速開關
        ToolbarItem(placement: .navigationBarTrailing) {
            cloudQuickToggle
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

    /// 日誌 sheet。
    ///
    /// 決策與局況都已經在 HUD 上（含可展開的詳細資訊），所以這張 sheet 不再重複
    /// 承載它們——舊版的「遊戲狀態」sheet 會蓋掉整個牌桌去顯示側欄已有的東西。
    private var iOSLogSheet: some View {
        NavigationStack {
            LogPanel()
                .navigationTitle("日誌")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("完成") { showLog = false }
                            .accessibilityIdentifier("log-sheet-done-button")
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
            // 上半部分：決策側欄（答案 → 次選 → 細節收合）
            //
            // 舊版是「Bot 狀態卡在上、AI 推薦卡在下」，把每手都要看的推薦壓在
            // 約 260pt 的常數狀態底下。順序在 `DecisionSidebar` 反轉了。
            ScrollView {
                DecisionSidebar()
            }
            .frame(minHeight: 200)

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
    /// `GET /v3/key` 的方案／到期／今日用量（nil＝還沒查到或查不到）
    @State private var cloudKeyStatus: CloudKeyStatus?
    /// 自動探測的結果訊息（與手動「測試連線」共用顯示區）
    @State private var cloudProbeError: String?
    @State private var cloudProbing = false

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
        .frame(width: 900, height: 620)
        .task(id: cloudProbeToken) { await autoProbeCloud() }
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
            .task(id: cloudProbeToken) { await autoProbeCloud() }
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
    /// **不要改回 `@AppStorage("HidePlayerNames")`**：那會讓同一個設定多一個寫入點，
    /// 而且 key 是字面值字串（唯一定義在 `SettingsStore.hidePlayerNamesKey`）。
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
    /// 「現在到底有沒有在用雲端」——把 `enabled && url && key` 這個三段條件
    /// 直接寫成一句話。
    ///
    /// 缺哪一項就講哪一項：使用者最常見的狀態是「key 貼了、開關沒開」，而那個開關
    /// 排在 key 欄位上方，捲下來填完就不會再往上看。
    @ViewBuilder
    private var cloudEffectiveStateRow: some View {
        let missing = naki.settings.cloudConfig.missingRequirements

        if missing.isEmpty {
            Label("雲端推論已生效——對局中會以雲端決策為準", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundColor(.green)
                .accessibilityIdentifier("cloud-effective-state")
        } else {
            Label("雲端推論尚未生效，仍在用內建本地模型。還缺："
                  + missing.joined(separator: "、"),
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundColor(.orange)
                .accessibilityIdentifier("cloud-effective-state")
        }
    }

    /// 探測的觸發依據：開關、URL、key 任一改變就重新查。
    ///
    /// 用 key 的**長度與後四碼**而不是 key 本身當 token 的一部分是刻意的——
    /// `task(id:)` 的值會進 SwiftUI 的 diff 記錄，完整 key 不該在那裡出現。
    private var cloudProbeToken: String {
        let key = naki.settings.cloudAPIKey
        let fingerprint = key.isEmpty ? "none" : "\(key.count):\(String(key.suffix(4)))"
        return "\(naki.settings.cloudInferenceEnabled)|\(naki.settings.cloudServerURL)|\(fingerprint)"
    }

    /// 自動探測雲端可用性。
    ///
    /// 「測試連線」按鈕仍在，但不該是**唯一**的知道方式：貼完 key 就關掉設定頁的人
    /// 永遠不會按它，而 key 打錯的後果（整局都在用本地模型）在對局中沒有明顯徵兆。
    /// `task(id:)` 在 token 變動時會取消上一個 task，所以前面那段 sleep 同時也是
    /// debounce——打字過程中不會每個字元都打一次伺服器。
    private func autoProbeCloud() async {
        cloudProbeError = nil
        guard naki.settings.cloudInferenceEnabled else { cloudKeyStatus = nil; return }
        let key = naki.settings.cloudAPIKey.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { cloudKeyStatus = nil; return }

        try? await Task.sleep(nanoseconds: 700_000_000)
        guard !Task.isCancelled else { return }

        guard let client = AkagiApiClient(baseURL: naki.settings.cloudServerURL, key: key) else {
            cloudKeyStatus = nil
            cloudProbeError = "伺服器 URL 無法解析"
            return
        }
        cloudProbing = true
        defer { cloudProbing = false }
        do {
            let status = try await client.keyStatus()
            guard !Task.isCancelled else { return }
            cloudKeyStatus = status
            // 順手把模型清單也帶回來，模型欄的下拉就不必再按一次「測試連線」
            if let models = try? await client.models(), !Task.isCancelled {
                cloudModels = models
            }
        } catch {
            guard !Task.isCancelled else { return }
            cloudKeyStatus = nil
            cloudProbeError = error.localizedDescription
        }
    }

    /// 方案／到期／今日用量。只有在雲端開著且真的查到時才出現。
    @ViewBuilder
    private var cloudKeyStatusCard: some View {
        if naki.settings.cloudInferenceEnabled {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("金鑰狀態", systemImage: "person.badge.key")
                        .font(.caption)
                        .fontWeight(.semibold)
                    Spacer()
                    if cloudProbing {
                        ProgressView().controlSize(.small)
                    } else if cloudKeyStatus != nil {
                        HStack(spacing: 4) {
                            Circle().fill(Color.green).frame(width: 6, height: 6)
                            Text("使用中").font(.caption2)
                        }
                    }
                }

                if let s = cloudKeyStatus {
                    keyRow("方案", s.plan.isEmpty ? "—" : s.plan)
                    if !s.expiresAtRaw.isEmpty {
                        keyRow("到期時間", formattedExpiry(s))
                        if let days = s.daysRemaining {
                            keyRow("剩餘", s.isExpired ? "已過期" : "\(days) 天",
                                   tint: s.isExpired ? .red : (days <= 3 ? .orange : nil))
                        }
                    }
                    if s.rpd > 0 {
                        keyRow("今日用量", "\(s.usageToday) / \(s.rpd)")
                        if let f = s.usageFraction {
                            ProgressView(value: f)
                                .progressViewStyle(.linear)
                                .tint(f > 0.9 ? .red : (f > 0.7 ? .orange : .accentColor))
                        }
                    } else if s.usageToday > 0 {
                        keyRow("今日用量", "\(s.usageToday)")
                    }
                    if s.rpm > 0 || s.topK > 0 {
                        keyRow("限額",
                               [s.rpm > 0 ? String(format: "%.0f 次/分", s.rpm) : nil,
                                s.topK > 0 ? "top-\(s.topK)" : nil]
                                .compactMap { $0 }.joined(separator: "・"))
                    }
                } else if let err = cloudProbeError {
                    // 查不到就說查不到。留白會讓人以為「這個方案沒有額度資訊」，
                    // 而實際上多半是 key 打錯或伺服器連不上。
                    Text("讀不到金鑰狀態：\(err)")
                        .font(.caption2)
                        .foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else if !cloudProbing {
                    Text("填入 API Key 後會自動查詢方案與今日用量。")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.contentBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .accessibilityIdentifier("cloud-key-status-card")
        }
    }

    private func keyRow(_ label: String, _ value: String, tint: Color? = nil) -> some View {
        HStack {
            Text(label).font(.caption2).foregroundColor(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .fontWeight(.medium)
                .foregroundColor(tint)
        }
        .accessibilityElement(children: .combine)
    }

    /// 到期時間顯示成本地時間；解不出 `Date` 就照抄伺服器原字串，不隱藏。
    private func formattedExpiry(_ s: CloudKeyStatus) -> String {
        guard let d = s.expiresAt else { return s.expiresAtRaw }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: d)
    }

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
                // 手動測試也把金鑰狀態帶回來：否則按了按鈕卻看不到方案／用量，
                // 會以為那張卡片壞了。失敗不影響這次測試的結論（模型清單已經拿到）。
                cloudKeyStatus = try? await client.keyStatus()
                let ids = models.map { "\($0.id)(\($0.game))" }.joined(separator: ", ")
                let base = "伺服器 \(health.status)；可用模型：\(ids.isEmpty ? "無" : ids)"
                // 「連得上」不等於「有在用」。不附這一句的話，開關沒開時這則成功訊息
                // 反而會強化「已經配置好了」的錯覺——這是本來就要修的那個問題的幫兇。
                cloudTestResult = naki.settings.cloudInferenceEnabled
                    ? base
                    : base + "（但開關未開，對局仍走本地模型）"
                    + (models.isEmpty ? "" : "——可用模型欄旁的箭頭直接選")
            } catch {
                cloudTestResult = "失敗：\(error.localizedDescription)"
            }
        }
    }

    /// 設定表單。
    ///
    /// macOS 走兩欄。單欄 400pt 捲動 sheet 的問題不只是要捲：雲端那組有六個控制
    /// （開關／URL／key／兩個模型欄／測試連線），而「生效」需要開關＋URL＋key 三者同時成立，
    /// 開關又排在 key 上面——捲下去貼完 key 就不會再往上看，於是得到一個看起來配置好、
    /// 行為卻完全是本地模型的設定（Akagi #221 的形狀）。兩欄讓開關與其結果同時在畫面上。
    /// iOS 維持單欄捲動：窄畫面放不下兩欄。
    private var settingsForm: some View {
#if os(macOS)
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 16) {
                operationalSettings
            }
            .frame(width: 300)

            VStack(alignment: .leading, spacing: 16) {
                cloudSettings
            }
            .frame(maxWidth: .infinity)
        }
        .padding()
#else
        VStack(alignment: .leading, spacing: 20) {
            operationalSettings
            cloudSettings
        }
        .padding()
#endif
    }

    /// 左欄：這台機器怎麼跑（畫面／自動操作／Bot／MCP）
    @ViewBuilder
    private var operationalSettings: some View {
        // 自動打牌可用性（只有在這條路徑不支援時才出現）
        autoPlayAvailabilityBox

        autoPlaySettingsBox

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

            // MCP Server（兩個平台都有，`DebugServer` 不是 macOS 專屬）。
            // **不要包回 `#if os(macOS)`**：iOS 也會綁 loopback 8765，
            // 控制項藏起來就變成「跑著卻看不到、關不掉」。
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

    /// 右欄：雲端推論（唯一一組需要對外連線的設定）
    @ViewBuilder
    private var cloudSettings: some View {
            // ☁️ 雲端推論（docs/cloud-inference-plan.md；key 在 Keychain）
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("啟用雲端推論", isOn: cloudEnabled)
                        .accessibilityIdentifier("cloud-inference-toggle")

                    Text("啟用後，每個決策點會把**本局至今的對局事件（含自家手牌）**上傳到下方伺服器換取決策；伺服器失敗時自動退回內建本地模型，對局不會停擺。API key 存在 Keychain，不會出現在 log 或設定檔。")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    HStack {
                        TextField("伺服器 URL", text: cloudServerURL)
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("cloud-server-url-field")

                        // 一鍵填回官方預設。手打這串 URL 很容易少個字母，而打錯的結果
                        // 是「測試連線失敗」——那跟 key 無效、伺服器掛掉長得一樣。
                        Button("預設") {
                            naki.settings.cloudServerURL = SettingsStore.defaultCloudBaseURL
                        }
                        .buttonStyle(.bordered)
                        .disabled(naki.settings.cloudServerURL == SettingsStore.defaultCloudBaseURL)
                        .help("填入 \(SettingsStore.defaultCloudBaseURL)")
                        .accessibilityIdentifier("cloud-url-default-button")
                    }
                    Text("預設：\(SettingsStore.defaultCloudBaseURL)（Akagi 官方；也可填自架位址）")
                        .font(.caption2)
                        .foregroundColor(.secondary)

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

                    // 生效條件是 `enabled && url && key` 三者，而它們是三個分開的控制、
                    // 開關還排在 key 欄位**上方**。沒有這一行，「貼完 key 就走」會得到
                    // 一個看起來已配置、行為卻完全是本地模型的設定——而畫面上任何地方
                    // 都不會說。這是 Akagi #221 的形狀，Naki 當初照抄了它的判定條件。
                    cloudEffectiveStateRow

                    cloudKeyStatusCard

                    Text("三麻提醒：雲端 3p 模型是目前唯一的真三麻路徑；雲端失敗退回的本地模型仍是四麻模型，側欄的決策來源會如實顯示。")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            } label: {
                Label("雲端推論", systemImage: "icloud.and.arrow.up")
            }
    }

    /// 自動操作：送出可用性與基準延遲。
    ///
    /// 延遲在 toolbar 也有一個 stepper（對局中快速微調），這裡是它的完整說明版——
    /// toolbar 那顆只有數字，講不出合法範圍，也講不出隨機分布仍然會套用。
    @ViewBuilder
    private var autoPlaySettingsBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("自動送出")
                    Spacer()
                    Text(naki.settings.supportsAutoPlay ? "可用" : "不可用")
                        .fontWeight(.semibold)
                        .foregroundStyle(naki.settings.supportsAutoPlay ? Color.green : Color.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("autoplay-availability-row")

                if naki.settings.supportsAutoPlay {
                    Divider()
                    HStack {
                        Text("基準延遲")
                        Spacer()
                        Text(String(format: "%.1f 秒", naki.settings.actionDelaySeconds))
                            .font(.system(.body, design: .monospaced))
                            .monospacedDigit()
                        Stepper("基準延遲",
                                value: Binding(get: { naki.settings.actionDelaySeconds },
                                               set: { naki.settings.actionDelaySeconds = $0 }),
                                in: SettingsStore.actionDelayRange,
                                step: SettingsStore.actionDelayStep)
                            .labelsHidden()
                            .accessibilityIdentifier("settings-delay-stepper")
                    }
                    Text("這是縮放係數，不是固定值：實際送出仍會套用 ActionDelayModel 的隨機分布。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } label: {
            Label("自動操作", systemImage: "timer")
        }
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
/// 頁面載不起來時的常駐橫幅。
///
/// 在此之前這件事只寫進 `store.statusMessage`——那會被下一個事件蓋掉，
/// 使用者看到的是一個空白頁面加一句稍縱即逝的文字。頁面沒載起來 Naki 什麼都做不了，
/// 這個狀態必須掛著直到重新載入成功（`webDidFinishNavigation` 會清掉）。
struct PageLoadFailureBanner: View {

    @Environment(\.naki) private var naki

    var body: some View {
        if let reason = naki.store.pageLoadFailure {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "wifi.exclamationmark")
                    .imageScale(.large)

                VStack(alignment: .leading, spacing: 2) {
                    Text("頁面載入失敗：Naki 讀不到牌局")
                        .fontWeight(.semibold)
                    Text(reason)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Button("重新載入") { naki.actions.reloadPage() }
                    .buttonStyle(.bordered)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.15))
            .accessibilityIdentifier("page-load-failure-banner")
        }
    }
}

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

/// 封包解析失敗到「這一局不會運作」程度時的常駐橫幅。
///
/// 為什麼要有它：沒有橫幅時，authGame 回應少了 seatList 只會寫一行 log，
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
