//
//  ContentView.swift
//  Naki
//
//  Created by Suoie on 2025/11/29.
//  Updated: 2026/01/26 - 使用 AdaptiveNakiWebView 支援 macOS 14+/iOS 17+
//  Updated: 2026/08/02 - 改吃 `@Environment(\.naki)`（store / settings / actions）
//

import SwiftUI

/// 面板尺寸與動態的決策，抽成純函式讓單元測試鎖得住。
enum PanelLayout {
    /// Apple HIG 的最小可點區域。
    static let minTapTarget: CGFloat = 44

    /// iPhone 橫向（compact）維持 220pt；regular 寬度（iPad、Max 機型橫向）有餘裕放寬。
    static func iOSPanelWidth(horizontal: UserInterfaceSizeClass?) -> CGFloat {
        horizontal == .regular ? 300 : 220
    }

    /// 寬度 compact 且高度 regular（iPad 窄分割、Slide Over）放不下 220pt 面板，預設收起。
    static func startsVisible(horizontal: UserInterfaceSizeClass?,
                              vertical: UserInterfaceSizeClass?) -> Bool {
        !(horizontal == .compact && vertical == .regular)
    }

    /// 開啟「減少動態效果」時不做動畫。
    static func animation(_ base: Animation = .easeInOut(duration: 0.2),
                          reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : base
    }
}

/// 只靠顏色區分的狀態點：開啟「不以顏色區分」時改畫符號。
private struct StatusDot: View {
    let isOn: Bool
    let onColor: Color
    let offColor: Color
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiate

    var body: some View {
        if differentiate {
            Image(systemName: isOn ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(isOn ? onColor : offColor)
        } else {
            Circle()
                .fill(isOn ? onColor : offColor)
                .frame(width: 6, height: 6)
        }
    }
}

struct ContentView: View {

    /// Naki 的三件東西：狀態、設定、副作用。
    ///
    /// **View 不自己建這些東西**：由 App 層（`NakiApp` / `Naki_MApp`）持有 `NakiRuntime`
    /// 並顯式注入。改成在 View 裡用 `@State` 建的話，「誰擁有 App 的生命週期」就變成
    /// SwiftUI 的 diffing 規則說了算，而 Preview 會真的去建一個 WebView、啟一個 MCP server。
    /// 這裡讀到的預設值只給 Preview（見 `NakiEnvironment`）。
    @Environment(\.naki) private var naki
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
#if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
#endif

    /// 決策面板／HUD 是否顯示。
    ///
    /// iOS 從 `false` 改成 `true`：它現在是浮在 WebView 上的 HUD，不再從牌桌
    /// 切走寬度，所以預設藏起來只會讓人以為 Naki 沒在運作。
    @State private var showGamePanel = true
    @State private var showAdvancedSettings = false
    @State private var showPlugins = false
    @State private var showLog = false

    /// 切到「全自動」時彈出的設定表（人數 × 房間偏好）
    @State private var showFullAutoKindChoice = false

    // sheet 上的暫存選擇：按「開始」才寫進 settings，取消就整個丟掉。
    // 直接綁 settings 的話，滑一下 picker 就已經改掉正在生效的設定了。
    @State private var draftPrefersSanma = false
    @State private var draftRoomPreference: RoomPreference = .lowest

    /// Picker 的選取值。讀 runtime 的生效模式、不綁存檔：選「全自動」在確認前不能寫入，
    /// 取消後也自然回到取消當下的實際模式（表單開著時 MCP 改了模式也不會被覆蓋）。
    private var autoPlayModeSelection: Binding<AutoPlayMode> {
        Binding(
            get: { showFullAutoKindChoice ? .fullAuto : naki.store.autoPlayMode },
            set: { newValue in
                // 全自動會**主動把帳號排進伺服器隊列**，排哪一種必須是使用者當下說的，
                // 不是沿用一個他看不到的舊設定。每次切進來都問（帶上次的選擇當預設）。
                // （模式已經是全自動＝別處設的，例如 MCP，就不再問。）
                if newValue == .fullAuto && naki.store.autoPlayMode != .fullAuto {
                    draftPrefersSanma = naki.settings.fullAutoPrefersSanma
                    draftRoomPreference = naki.settings.fullAutoRoomPreference
                    showFullAutoKindChoice = true
                } else {
                    naki.actions.setAutoPlayMode(newValue)
                }
            })
    }

    /// 這條 WebView 路徑真的能執行的模式（Legacy 沒有「自動」，見 `AutoPlayAvailability`）
    private var availableAutoPlayModes: [AutoPlayMode] {
        AutoPlayAvailability.modes(autoPlaySupported: naki.settings.supportsAutoPlay)
    }

    /// 模式 picker 本體：**刻意放在 `#if` 之外**，兩個平台的 toolbar 共用同一份。
    ///
    /// 這條路徑的選項與行為只有 iOS 17–25 會走到，而本機（macOS 26）連編譯都碰不到
    /// `#if os(iOS)` 區塊——寫兩份的話，iOS 那份的錯字要到實機上才會被發現。
    /// 共用之後 macOS build 至少會替它做型別檢查。
    ///
    /// `width` 傳 `nil` 代表不約束寬度：segmented control 會自己撐滿父容器。
    /// iOS 的右側欄用這條——欄寬改了不必回頭同步一個寫死的點數。
    private func autoPlayModePicker(width: CGFloat?, menu: Bool = false) -> some View {
        Picker("模式", selection: autoPlayModeSelection) {
            // 選項來自 `AutoPlayAvailability`：不支援自動送出的路徑上，
            // 「自動」不是灰掉的按鈕而是根本不存在——灰掉的控制照樣要解釋，
            // 而解釋放在進階設定裡（`autoPlayAvailabilityBox`）。
            ForEach(availableAutoPlayModes, id: \.self) { mode in
                Text(mode.pickerLabelKey).tag(mode)
            }
        }
        // 兩種樣式共用底下所有 modifier（onChange／sheet／a11y），
        // 分開寫兩份 Picker 的話，改行為時很容易只改到一邊。
        .modifier(ModePickerStyle(menu: menu))
        .frame(width: width)
        // 用 sheet 而不是 confirmationDialog：人數 × 房間偏好共 4 種組合，
        // macOS 的 confirmationDialog 只渲染得下 3 個按鈕＋取消——實測第 4 個
        // 「三人麻將・最高房」直接消失，而取消鈕被畫成「OK」。選項用 Picker 表達
        // 就不受按鈕數限制，也讓兩個維度看起來像兩個維度。
        // 按 Esc 或點視窗外關掉也走同一條：模式本來就沒動，取消不需要任何還原。
        .sheet(isPresented: $showFullAutoKindChoice) {
            FullAutoSetupSheet(
                sanma: $draftPrefersSanma,
                room: $draftRoomPreference,
                sanmaEngineAvailable: AkagiSanmaBot.isBundled || naki.settings.cloudConfig.isActive,
                onStart: {
                    showFullAutoKindChoice = false
                    naki.actions.startFullAuto(sanma: draftPrefersSanma, room: draftRoomPreference)
                },
                onCancel: { showFullAutoKindChoice = false })
            .appLocale()
        }
        .accessibilityIdentifier("autoplay-mode-picker")
        .accessibilityLabel("自動打牌模式")
        .accessibilityHint(naki.settings.supportsAutoPlay
                           ? "" : AutoPlayAvailability.autoUnavailableReasonKey)
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
        @Bindable var settings = naki.settings
        return HStack(spacing: 4) {
            delaySecondsText
                .font(.system(.caption, design: .monospaced))
                .monospacedDigit()
                .frame(minWidth: 40, alignment: .trailing)
            Stepper("自動打牌基準延遲",
                    value: $settings.actionDelaySeconds,
                    in: SettingsStore.actionDelayRange,
                    step: SettingsStore.actionDelayStep)
                .labelsHidden()
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("autoplay-delay-stepper")
        .accessibilityLabel("自動打牌基準延遲")
        .accessibilityValue(delaySecondsText)
#if os(macOS)
        // `.help` 只包 macOS：iOS 上 tooltip 只在有指標裝置時看得到，對 iPhone 是
        // 多餘的 pointer 互動註冊。專案既有慣例就是這樣（見 `LogPanel` 的兩個 `.help`）。
        .help("送出前的模擬人類延遲基準；1.0s 為預設，向上更慢、向下更快（隨機分布保留）")
#endif
    }

    private var delaySecondsText: Text {
        Text("\(naki.settings.actionDelaySeconds, format: .number.precision(.fractionLength(1))) 秒")
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
            Label("雲端推論", systemImage: cloudIconName)
                .labelStyle(.iconOnly)
                .foregroundStyle(cloudIconTint)
        }
#if os(macOS)
        .help(cloudToggleHelp)
#endif
        .accessibilityIdentifier("toolbar-cloud-toggle")
        .accessibilityValue(cloudToggleHelp)
    }

    /// 缺哪些條件才算生效（與設定頁的 `cloudEffectiveStateRow` 讀同一份判定）
    private var cloudMissing: [LocalizedStringKey] { naki.settings.cloudConfig.missingRequirementKeys }

    private var cloudIconName: String {
        if cloudMissing.isEmpty { return "icloud.fill" }
        // 開關開著卻沒生效是要警告的狀態，不能跟「刻意關閉」共用同一個圖示
        return naki.settings.cloudInferenceEnabled ? "exclamationmark.icloud" : "icloud.slash"
    }

    private var cloudIconTint: Color {
        if cloudMissing.isEmpty { return .accentColor }
        return naki.settings.cloudInferenceEnabled ? .orange : .secondary
    }

    private var cloudToggleHelp: Text {
        if cloudMissing.isEmpty { return Text("雲端推論已生效——點一下切回本地模型") }
        if naki.settings.cloudInferenceEnabled {
            return Text("雲端推論尚未生效，還缺：\(missingList(cloudMissing))")
        }
        return Text("雲端推論已關閉，目前使用內建本地模型")
    }

    /// 啟動時要不要問區服。
    ///
    /// 用 `@AppStorage` 直接讀 UserDefaults 而不是等 `naki.settings`：`@Environment`
    /// 要到 body 求值時才拿得到，那時主版面已經渲染過一幀——而渲染主版面就等於
    /// 建立 WebView、開始載入舊的服（見 `ServerPickerView` 的註解）。
    ///
    /// **只讀不寫。** 寫入仍然只有 `SettingsStore.pinMajsoulServer` 一個入口——
    /// 同一個設定兩個寫入點正是 `hidePlayerNames` 踩過的坑。
    @AppStorage(SettingsStore.pinMajsoulServerKey) private var serverPinned = false

    /// 這次啟動已經選過了（選完就不再擋，即使沒勾「以後都用這個」）
    @State private var serverChosen = false

    private var showsServerPicker: Bool { !serverPinned && !serverChosen }

    var body: some View {
        Group {
            if showsServerPicker {
                ServerPickerView(initial: naki.settings.majsoulServer) { server, pin in
                    naki.actions.chooseServer(server, pin: pin)
                    serverChosen = true
                }
            } else {
#if os(macOS)
                macOSLayout
#else
                iOSLayout
#endif
            }
        }
        // 必須在 ContentView 內、不能掛在 Scene 根：型別名會成為視窗 autosave key
        .appLocale()
        // 選完區服、主視窗出現後再查；延遲是讓出啟動時的網路與主執行緒
        .task(id: showsServerPicker) {
            guard !showsServerPicker else { return }
            guard (try? await Task.sleep(for: .seconds(5))) != nil else { return }
            await naki.actions.checkForUpdate(manual: false)
        }
    }

    // MARK: - macOS Layout
#if os(macOS)
    private var macOSLayout: some View {
        HSplitView {
            // 橫幅排在牌桌上方、只佔左欄：`HSplitView` 是 AppKit 的，不吃 `safeAreaInset`，
            // 掛在它外面會浮在側欄標頭上（按鈕蓋住「待機」狀態點）。
            VStack(spacing: 0) {
                JSInjectionFailureBanner()
                LiqiParseFailureBanner()
                PageLoadFailureBanner()
                UpdateAvailableBanner()
                BotFailureBanner()
                // WebView (由 WebSession 決定是 WebPage 還是 WKWebView)
                AdaptiveNakiWebView()
            }
            .frame(minWidth: 600)

            // 決策面板（右側）
            if showGamePanel {
                GamePanel(showLog: $showLog)
                    .frame(minWidth: 300, idealWidth: 360, maxWidth: 480)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom) {
            StatusBar()
        }
        .animation(PanelLayout.animation(reduceMotion: reduceMotion), value: showGamePanel)
        .sheet(isPresented: $showAdvancedSettings) {
            AdvancedSettingsSheet().appLocale()
        }
        .sheet(isPresented: $showPlugins) {
            PluginsPageView().appLocale()
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
            Button("進階設定", systemImage: "gearshape") { showAdvancedSettings = true }
                .labelStyle(.iconOnly)
                .help("進階設定")
                .accessibilityIdentifier("toolbar-settings")
        }

        // 插件（獨立頁面：清單 + 熱插拔開關 + 即時 log）
        ToolbarItem(placement: .primaryAction) {
            Button("插件", systemImage: "puzzlepiece.extension") { showPlugins = true }
                .labelStyle(.iconOnly)
                .help("插件")
                .accessibilityIdentifier("toolbar-plugins")
        }

        // 左側：自動打牌模式
        ToolbarItem(placement: .navigation) {
            autoPlayModePicker(width: nil, menu: true)
                .fixedSize()
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
                    HStack {
                        StatusDot(isOn: naki.store.isDebugServerRunning, onColor: .green, offColor: .gray)
                        Text("\(naki.store.debugServerPort)")
                            .font(.system(.caption, design: .monospaced))
                    }
                    Text("MCP Server")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 80)
            .help(naki.store.isDebugServerRunning ? "MCP Server 運行中" : "MCP Server 已停止")
            .accessibilityIdentifier("mcp-server-toggle")
            .accessibilityLabel("MCP Server")
            .accessibilityValue(naki.store.isDebugServerRunning
                                ? "運行中，連接埠 \(Int(naki.store.debugServerPort))" : "未運行")
        }

        // 連接狀態
        ToolbarItem(placement: .navigation) {
            ConnectionIndicator()
                .frame(width: 80)
        }

        // 重新載入
        ToolbarItem(placement: .primaryAction) {
            Button("重新載入", systemImage: "arrow.clockwise") { naki.actions.reloadPage() }
                .labelStyle(.iconOnly)
                .help("重新載入")
                .accessibilityIdentifier("toolbar-reload")
        }

        // 右側：日誌切換
        ToolbarItem(placement: .primaryAction) {
            Button("顯示或隱藏日誌", systemImage: showLog ? "terminal.fill" : "terminal") { showLog.toggle() }
                .labelStyle(.iconOnly)
                .help("顯示/隱藏日誌")
                .accessibilityIdentifier("toolbar-log-toggle")
                .accessibilityValue(showLog ? "已顯示" : "已隱藏")
        }

        // 遊戲面板切換
        ToolbarItem(placement: .primaryAction) {
            Button("顯示或隱藏遊戲面板", systemImage: showGamePanel ? "sidebar.trailing" : "sidebar.right") {
                showGamePanel.toggle()
            }
            .labelStyle(.iconOnly)
            .help("顯示/隱藏遊戲面板")
            .accessibilityIdentifier("toolbar-game-panel-toggle")
            .accessibilityValue(showGamePanel ? "已顯示" : "已隱藏")
        }
    }
#endif

    // MARK: - iOS Layout
#if os(iOS)

    /// 右側常駐欄的寬度，依 size class 決定（見 `PanelLayout.iOSPanelWidth`）。
    ///
    /// compact 的 220pt 是兩個下限的交集：segmented picker 三段（關／推薦／自動）
    /// 要 ~200pt 才不把字擠掉；`DecisionSidebar(compact:)` 的摘要條是照 ~190–210pt
    /// 內容寬設計的。圖示列放不下的部分靠橫向捲動。
    private var iOSPanelWidth: CGFloat {
        PanelLayout.iOSPanelWidth(horizontal: horizontalSizeClass)
    }

    /// home indicator 那條的高度。
    ///
    /// **不能**用 `GeometryReader` 或 `safeAreaPadding` 讀。整個 iOS 版面活在
    /// `.ignoresSafeArea(.container)` 的座標系裡（那正是面板能貼齊螢幕右緣、與底層佔位
    /// 對齊的原因），而 SwiftUI 在那個座標系裡回報的 safe area **一律是 0**——實測
    /// iPhone 17 Pro 橫向：`GeometryProxy` 四邊全 0、size 是完整的 874×402，同一刻
    /// UIKit 報 `left/right 62、bottom 20`。所以只能直接問 UIKit。
    @State private var bottomSafeInset: CGFloat = 0

    /// 取所有 window 的最大值，不是 `keyWindow` 的值：`keyWindow` 在 `onAppear` 這個
    /// 時間點常常還是 nil（實測就是這樣讀回 0 的），而 sheet 疊上來時它又會換人。
    private func refreshBottomSafeInset() {
        let inset = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .map(\.safeAreaInsets.bottom)
            .max() ?? 0
        if inset != bottomSafeInset { bottomSafeInset = inset }
    }

    /// iPhone 橫向版面：牌桌拿全高，控制與決策收進右側常駐欄。
    ///
    /// **為什麼右側欄不會讓牌桌變小**：雀魂是 16:9 等比縮放的 Unity canvas，橫向 iPhone
    /// 的瓶頸是**高度**——canvas 貼齊高度之後，左右本來就空著約 25% 的黑邊。把 nav bar
    /// 與底部狀態列佔掉的高度還給 WebView、再把面板放進原本是黑邊的那塊寬度，牌桌反而
    /// 比「有 nav bar、沒有面板」時更大（iPhone 16 Pro 橫向推算 571×321 → 622×350）。
    ///
    /// 所以這裡**沒有** `NavigationStack`：它的 nav bar 是唯一會從牌桌切走高度的東西，
    /// 而兩張 sheet 各自帶自己的 `NavigationStack`，不靠外層這一個。
    ///
    /// 牌桌上也**不再有任何浮層**（HUD、狀態列都進了右欄）。那是附帶效果但值得記一筆：
    /// `DecisionHUDTouchTests` 盯的崩潰正是「SwiftUI 手勢層疊在 WKWebView 上」那一類。
    private var iOSLayout: some View {
        ZStack(alignment: .trailing) {
            // 底層：牌桌鋪滿整個螢幕（含瀏海／home indicator 那一圈），右側用一塊
            // 等寬佔位讓開面板——Unity canvas 是在**扣掉佔位之後**的區域裡置中，
            // 所以牌桌不會有任何一角被面板蓋到。
            HStack(spacing: 0) {
                AdaptiveNakiWebView()
                    .safeAreaInset(edge: .top) {
                        JSInjectionFailureBanner()
                    }
                    .safeAreaInset(edge: .top) {
                        LiqiParseFailureBanner()
                    }
                    .safeAreaInset(edge: .top) {
                        UpdateAvailableBanner()
                    }
                    .safeAreaInset(edge: .top) {
                        BotFailureBanner()
                    }
                    // 狀態訊息回到牌桌底部（預設關，見 `SettingsStore.showStatusBar`）。
                    // 掛在 WebView 上而不是整個 ZStack 上：橫跨全寬會連面板底部一起壓。
                    .overlay(alignment: .bottom) {
                        IOSStatusOverlay(bottomInset: bottomSafeInset)
                    }

                if showGamePanel {
                    Color.clear
                        .frame(width: iOSPanelWidth)
                        .allowsHitTesting(false)
                }
            }

            // 上層：面板。它跟底層在**同一個** `ignoresSafeArea` 座標系裡，所以外緣
            // 貼齊螢幕右緣、與上面那塊佔位對齊——這是它不會壓進牌桌的原因。
            //
            // 分成兩層的理由是高度：放同一個 HStack 裡的話，WebView 的
            // `ignoresSafeArea` 會把整個 HStack 撐成「含 safe area 的全螢幕高」，
            // 面板被一起拉到最下緣。
            if showGamePanel {
                iOSSidePanel
                    .frame(width: iOSPanelWidth)
                    .transition(reduceMotion ? .opacity : .move(edge: .trailing))
            }

            // 面板收起來之後唯一叫得回來的入口。
            //
            // 它**必須**待在這個 ZStack 裡（而不是掛在外層 `.overlay` 上）：外層那個
            // 位置會重新套用 safe area，把按鈕往畫面內推 62pt，正好壓在牌桌右上角的
            // 「公告」那一區。在這裡它貼的是螢幕右緣那條黑邊。
            //
            // identifier 與面板內那顆收合鈕共用：兩者互斥出現，測試永遠只找得到一顆。
            if !showGamePanel {
                Button("顯示決策面板", systemImage: "sidebar.right") {
                    withAnimation(PanelLayout.animation(reduceMotion: reduceMotion)) { showGamePanel = true }
                }
                .labelStyle(.iconOnly)
                .padding(10)
                .background(.ultraThinMaterial, in: Circle())
                .iOSTapTarget()
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .accessibilityIdentifier("toolbar-game-panel-toggle")
                .accessibilityValue("已隱藏")
            }
        }
        // 只忽略容器 safe area（瀏海／home indicator），**不含鍵盤**：點雀魂
        // 登入頁的 `<input>` 時 layout 照舊避讓，與改版前一致。鍵盤那條是
        // 已知崩潰的觸發路徑（見上述測試），不在這次一起動。
        .ignoresSafeArea(.container)
        // 面板同色鋪滿 safe area：橫向旋轉方向決定瀏海在左或右，靠右那次會在面板
        // 外側露出一條底色。這一行讓那條跟面板連續，而不是一道黑邊。
        .background(Color.windowBackground.ignoresSafeArea())
        // 這裡**不放** `.animation(_:value:)`：它會把隱式動畫套到整個子樹（含
        // WKWebView）。動畫一律由切換處的 `withAnimation` 驅動。
        // 見 `docs/ui-reference/implementation-decisions.md` 的「iOS 間歇性崩潰」。
        //
        // 用尺寸變化當「該重讀 safe area 了」的訊號，而不是
        // `orientationDidChangeNotification`：那個通知要先
        // `beginGeneratingDeviceOrientationNotifications()` 才會發，而且面朝上平放時
        // 會回報 `.faceUp`——旋轉了但版面沒變、以及版面變了但沒旋轉（分割視窗、鍵盤）
        // 兩種情況它都答錯。版面尺寸變了才是真的要重算。
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onChange(of: proxy.size, initial: true) { _, _ in refreshBottomSafeInset() }
            }
        }
        .onAppear {
            if !PanelLayout.startsVisible(horizontal: horizontalSizeClass, vertical: verticalSizeClass) {
                showGamePanel = false
            }
        }
        .sheet(isPresented: $showLog) {
            iOSLogSheet.appLocale()
        }
        .sheet(isPresented: $showAdvancedSettings) {
            AdvancedSettingsSheet().appLocale()
        }
        .sheet(isPresented: $showPlugins) {
            PluginsPageView().appLocale()
        }
    }

    /// 右側常駐欄：控制列在上、決策在中、狀態訊息釘在最下。
    ///
    /// 三塊各自從別處搬來——控制列原本在 nav bar（吃牌桌高度）、決策原本是浮在牌桌上的
    /// HUD（遮住右家那一區）、狀態訊息原本是疊在手牌上的浮層。
    private var iOSSidePanel: some View {
        VStack(spacing: 0) {
            iOSPanelControls

            Divider()

            // 捲動只包決策：控制列不該跟著內容捲走。
            ScrollView {
                DecisionSidebar(compact: true)
            }
        }
        // 面板整體活在忽略 safe area 的座標系裡（見 `iOSLayout`），所以 home indicator
        // 那條要自己讓——不讓的話決策內容的最後一列會被那根橫條壓住。
        .padding(.bottom, bottomSafeInset)
        .accessibilityIdentifier("ios-decision-hud")
    }

    /// 面板頂端的控制列——原本 nav bar 上那一整排。
    ///
    /// 六顆圖示按鈕各至少 44×44pt（`PanelLayout.minTapTarget`），超出側欄寬度時可以左右滑動。
    ///
    /// **順序：圖示列在最上，模式與延遲在下。** 圖示那排是「離開這裡去別的地方」
    /// （重載／日誌／雲端／設定／收面板／插件），一局裡按不到幾次；模式與延遲是對局中真的會動的
    /// 東西，排在下面就離決策區更近。
    private var iOSPanelControls: some View {
        VStack(spacing: 8) {
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    Button("重新載入", systemImage: "arrow.clockwise") { naki.actions.reloadPage() }
                        .iOSTapTarget()
                        .accessibilityIdentifier("toolbar-reload")

                    Button("顯示日誌", systemImage: "terminal") { showLog = true }
                        .iOSTapTarget()
                        .accessibilityIdentifier("toolbar-log-toggle")

                    cloudQuickToggle
                        .iOSTapTarget()

                    Button("進階設定", systemImage: "gearshape") { showAdvancedSettings = true }
                        .iOSTapTarget()
                        .accessibilityIdentifier("toolbar-settings")

                    Button("隱藏決策面板", systemImage: "sidebar.trailing") {
                        withAnimation(PanelLayout.animation(reduceMotion: reduceMotion)) { showGamePanel = false }
                    }
                    .iOSTapTarget()
                    .accessibilityIdentifier("toolbar-game-panel-toggle")
                    .accessibilityValue("已顯示")

                    Button("插件", systemImage: "puzzlepiece.extension") { showPlugins = true }
                        .iOSTapTarget()
                        .accessibilityIdentifier("toolbar-plugins")
                }
                .labelStyle(.iconOnly)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)

            // 傳 nil：segmented control 自己撐滿欄寬，欄寬改了不必回頭同步點數。
            autoPlayModePicker(width: nil)

            // 只在這條 path 真的會自動送出時才出現（與 macOS 同一個判斷）
            if naki.settings.supportsAutoPlay {
                actionDelayStepper
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 8)
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
                    ToolbarItem(placement: .confirmationAction) {
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

#if os(iOS)
private extension View {
    func iOSTapTarget() -> some View {
        frame(minWidth: PanelLayout.minTapTarget, minHeight: PanelLayout.minTapTarget)
            .contentShape(Rectangle())
    }
}

/// 牌桌底部的狀態訊息浮層。**預設關閉**，見 `SettingsStore.showStatusBar`。
///
/// 獨立成 view 是為了讓 `statusMessage` 的讀取只重算這一塊，而不是整個 iOS 版面。
/// `allowsHitTesting(false)` 是必要的：它是純資訊顯示，卻疊在 WebView 上，
/// 少了這行就平白吃掉牌桌那一條的觸控。
private struct IOSStatusOverlay: View {
    @Environment(\.naki) private var naki
    let bottomInset: CGFloat

    var body: some View {
        if naki.settings.showStatusBar, !naki.store.statusMessage.isEmpty {
            StatusBar()
                .background(.ultraThinMaterial)
                // 整條（含背景）讓開 home indicator，否則最後一行字會被那根橫條壓住
                .padding(.bottom, bottomInset)
                .allowsHitTesting(false)
        }
    }
}
#endif

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

// MARK: - 啟動時的區服選擇

/// 啟動時問要連哪個雀魂區服。
///
/// **它取代整個畫面，而不是蓋在上面。** WebView 一旦進了 view tree 就會開始載入
/// （`WebSession.makeView()` 的 `.task` → `loadMajsoulIfNeeded`），所以用
/// sheet／fullScreenCover 蓋上去等於「先載入上次的服、選完再整頁重載一次」。
/// 不渲染它就不會載——首次啟動因此只有一次頁面載入。
///
/// 兩個平台共用這一份：macOS 版面大，但這個畫面沒有任何需要更多空間的東西，
/// 寫兩份只會讓其中一份先過期。
struct ServerPickerView: View {

    /// 預選上次用的服。常換服的人多半也只在兩個之間切，預選上次那個比預選第一個有用。
    @State private var selection: MajsoulServer
    @State private var pin = false

    /// `(選定的服, 要不要記住)`
    let onConfirm: (MajsoulServer, Bool) -> Void

    init(initial: MajsoulServer, onConfirm: @escaping (MajsoulServer, Bool) -> Void) {
        _selection = State(initialValue: initial)
        self.onConfirm = onConfirm
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                content
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(Color.windowBackground)
        .accessibilityIdentifier("server-picker")
    }

    private var content: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 12)

            Text("選擇雀魂伺服器")
                .font(.title3)
                .fontWeight(.semibold)

            // 這句是這個畫面存在的理由：選錯服不是「畫面不對」而是「登不進去」。
            Text("各服的帳號不互通")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 3)
                .padding(.bottom, 16)

            VStack(spacing: 8) {
                ForEach(MajsoulServer.allCases) { server in
                    row(for: server)
                }
            }
            .frame(maxWidth: 340)

            Toggle("以後都用這個伺服器，不要再問", isOn: $pin)
                .font(.callout)
                .frame(maxWidth: 340)
                .padding(.top, 16)
                .accessibilityIdentifier("server-picker-pin-toggle")

            Text("之後可以在進階設定裡改，或取消固定。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 340, alignment: .leading)
                .padding(.top, 4)

            Button {
                onConfirm(selection, pin)
            } label: {
                Text("進入遊戲")
                    .fontWeight(.semibold)
                    .frame(maxWidth: 340)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 18)
#if os(macOS)
            // Enter＝預設按鈕是 macOS 的慣例。iOS 上沒有這個慣例，而且它會讓任何
            // 送進來的 Return 直接確認選擇——這個畫面的誤觸代價是連錯服。
            .keyboardShortcut(.defaultAction)
#endif
            .accessibilityIdentifier("server-picker-confirm")

            Spacer(minLength: 12)
        }
        .padding(.horizontal, 20)
    }

    private func row(for server: MajsoulServer) -> some View {
        let isOn = selection == server
        return Button {
            selection = server
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isOn ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                    .imageScale(.large)

                VStack(alignment: .leading, spacing: 1) {
                    Text("\(Text(server.displayNameKey))・\(Text(server.regionNameKey))")
                        .fontWeight(isOn ? .semibold : .regular)
                    // 網域是「我要連去哪」的唯一憑據——國服與國際服的招牌長得不像，
                    // 但網址是使用者真正認得的東西
                    Text(server.host)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(isOn ? Color.accentColor.opacity(0.12) : Color.contentBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isOn ? Color.accentColor.opacity(0.55)
                                       : Color.secondary.opacity(0.22),
                                  lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("server-option-\(server.rawValue)")
        .accessibilityLabel(Text("\(Text(server.displayNameKey)) \(Text(server.regionNameKey))"))
        .accessibilityValue(isOn ? "已選擇" : "未選擇")
    }
}

/// 缺項逐項本地化後以本地化分隔符串起來（`Text` 插值 `Text`）。
func missingList(_ items: [LocalizedStringKey]) -> Text {
    items.enumerated().reduce(Text(verbatim: "")) { acc, item in
        item.offset == 0 ? Text(item.element) : Text("\(acc)\(Text("、"))\(Text(item.element))")
    }
}

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
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("websocket-connection-indicator")
        .accessibilityLabel("WebSocket 連線狀態")
        .accessibilityValue(isConnected ? "已連接" : "未連接")
    }
}

// MARK: - 模式 picker 樣式

/// macOS toolbar 用下拉選單、iOS 側欄用 segmented control。
///
/// 抽成 modifier 是因為兩種 `pickerStyle` 的回傳型別不同，寫在同一個 `some View`
/// 函式裡會逼出兩份 Picker——而底下的 `onChange`／`sheet`／a11y 是共用的，
/// 複製兩份就等著哪天只改到一邊。
private struct ModePickerStyle: ViewModifier {
    let menu: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if menu {
            content.pickerStyle(.menu)
        } else {
            content.pickerStyle(.segmented)
        }
    }
}

private extension RoomPreference {
    /// 兩字加「房」整句翻譯，不拼接 `label`（語序因語言而異）。
    var title: LocalizedStringKey {
        switch self {
        case .lowest: return "最低房"
        case .highest: return "最高房"
        }
    }
}

// MARK: - 全自動設定表

/// 切到「全自動」時要當場確認的兩件事：打幾人麻將、排哪一級的房。
///
/// 為什麼是 sheet 不是 confirmationDialog：4 種組合在 macOS 的
/// confirmationDialog 上只畫得出 3 個按鈕（第 4 個消失、取消鈕變成 OK，2026-08-09 實測）。
/// 兩個維度用兩個 Picker 表達也比 4 個複合按鈕好讀。
private struct FullAutoSetupSheet: View {

    @Binding var sanma: Bool
    @Binding var room: RoomPreference
    /// 是否有三麻引擎（本地 Akagi 三麻或雲端 3p；決定要不要對三麻掛警告）
    let sanmaEngineAvailable: Bool
    let onStart: () -> Void
    let onCancel: () -> Void

    /// 選三麻但沒有三麻引擎＝排進去也一手都不會打
    private var sanmaBlocked: Bool { sanma && !sanmaEngineAvailable }

    var body: some View {
        ScrollView {
            form
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom) {
            buttons
        }
#if os(macOS)
        .frame(width: 380)
        .frame(minHeight: 300, idealHeight: 440)
#endif
        .accessibilityIdentifier("fullauto-setup-sheet")
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("全自動")
                .font(.headline)
            Text("對局結束後會自動排下一場，直到你切走模式。")
                .font(.callout)
                .foregroundStyle(.secondary)

            Picker("人數", selection: $sanma) {
                Text("四人麻將").tag(false)
                Text("三人麻將").tag(true)
            }
            .pickerStyle(.segmented)

            Picker("房間", selection: $room) {
                ForEach(RoomPreference.allCases, id: \.self) { pref in
                    Text(pref.title).tag(pref)
                }
            }
            .pickerStyle(.segmented)

            Text("""
                依帳號段位挑一間打得了的房：「最低」對手最弱、掉段風險最小；\
                「最高」點數效率高但打不好會掉段。
                """)
                .font(.footnote)
                .foregroundStyle(.secondary)

            if sanmaBlocked {
                Label("選了三麻但沒有三麻引擎，不排隊——排進去也不會出手。",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            Text("只會排你自己點過、而且已經打過一場的場次；沒有的話會停下來並在紀錄裡說明。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(20)
    }

    private var buttons: some View {
        HStack {
            Spacer()
            Button("取消", role: .cancel, action: onCancel)
                .keyboardShortcut(.cancelAction)
            Button("開始", action: onStart)
                .keyboardShortcut(.defaultAction)
                // 選了會直接失敗的組合就不讓按，而不是按了才在 log 裡說不行
                .disabled(sanmaBlocked)
        }
        .padding(20)
        .background(.bar)
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
