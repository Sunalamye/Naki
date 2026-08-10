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
    @State private var showPlugins = false
    @State private var showLog = false

    /// 切到「全自動」時彈出的設定表（人數 × 房間偏好）
    @State private var showFullAutoKindChoice = false

    // sheet 上的暫存選擇：按「開始」才寫進 settings，取消就整個丟掉。
    // 直接綁 settings 的話，滑一下 picker 就已經改掉正在生效的設定了。
    @State private var draftPrefersSanma = false
    @State private var draftRoomPreference: RoomPreference = .lowest

    /// 這次的設定表是不是按「開始」關掉的。
    ///
    /// 判斷放在 `onDismiss` 而不是取消鈕的 action：按 Esc 或點視窗外關掉 sheet 時，
    /// SwiftUI **不會**呼叫取消鈕的 action，模式就會停在「全自動」但設定沒確認
    /// （2026-08-09 實測）。`onDismiss` 是唯一不論怎麼關都會走到的地方。
    @State private var fullAutoConfirmed = false

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

    /// iOS 側欄的 segmented control 寬度（依實際標籤字數算，不寫死點數）。
    private var autoPlayPickerWidth: CGFloat {
        availableAutoPlayModes.reduce(0) { total, mode in
            total + CGFloat(mode.pickerLabel.count) * 15 + 26
        }
    }

    /// macOS toolbar 的下拉選單寬度。
    ///
    /// 四個模式在 segmented control 上排不好看：SwiftUI 會**等寬分配**，而標籤是
    /// 1/2/2/3 字，「關」那格被撐得很空、「全自動」剛好塞滿（2026-08-09 實測截圖）。
    /// 下拉選單只顯示目前選中的那一個，寬度看最長的標籤就夠。
    private var autoPlayMenuWidth: CGFloat {
        let longest = availableAutoPlayModes.map(\.pickerLabel.count).max() ?? 2
        return CGFloat(longest) * 15 + 52   // 文字 ＋ 箭頭 ＋ 左右 padding
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
        Picker("模式", selection: $autoPlayMode) {
            // 選項來自 `AutoPlayAvailability`：不支援自動送出的路徑上，
            // 「自動」不是灰掉的按鈕而是根本不存在——灰掉的控制照樣要解釋，
            // 而解釋放在進階設定裡（`autoPlayAvailabilityBox`）。
            ForEach(availableAutoPlayModes, id: \.self) { mode in
                Text(mode.pickerLabel).tag(mode)
            }
        }
        // 兩種樣式共用底下所有 modifier（onChange／sheet／a11y），
        // 分開寫兩份 Picker 的話，改行為時很容易只改到一邊。
        .modifier(ModePickerStyle(menu: menu))
        // a11y: fixed width for segmented control; kept to preserve toolbar layout
        .frame(width: width)
        .onChange(of: autoPlayMode) { _, newValue in
            // 收斂與持久化在 `NakiRuntime.setAutoPlayMode` → `AutoPlayAvailability.commit`；
            // Action 只是這個 View 對「切模式」這件副作用的型別化入口。
            naki.actions.setAutoPlayMode(newValue)

            // 全自動會**主動把帳號排進伺服器隊列**，排哪一種必須是使用者當下說的，
            // 不是沿用一個他看不到的舊設定。每次切進來都問（帶上次的選擇當預設）。
            if newValue == .fullAuto {
                draftPrefersSanma = naki.settings.fullAutoPrefersSanma
                draftRoomPreference = naki.settings.fullAutoRoomPreference
                showFullAutoKindChoice = true
            }
        }
        // 用 sheet 而不是 confirmationDialog：人數 × 房間偏好共 4 種組合，
        // macOS 的 confirmationDialog 只渲染得下 3 個按鈕＋取消——實測第 4 個
        // 「三人麻將・最高房」直接消失，而取消鈕被畫成「OK」。選項用 Picker 表達
        // 就不受按鈕數限制，也讓兩個維度看起來像兩個維度。
        .sheet(isPresented: $showFullAutoKindChoice, onDismiss: {
            // 沒按「開始」就退回「自動」：這一局照打，但不會自己再開下一場。
            // 只寫 `autoPlayMode`，不要再呼叫一次 `setAutoPlayMode`——
            // 上面的 `onChange` 已經會轉呼叫，兩邊都做會執行兩次（log 印兩行）。
            if !fullAutoConfirmed { autoPlayMode = .auto }
            fullAutoConfirmed = false
        }) {
            FullAutoSetupSheet(
                sanma: $draftPrefersSanma,
                room: $draftRoomPreference,
                cloudActive: naki.settings.cloudConfig.isActive,
                onStart: {
                    applyFullAutoChoice(sanma: draftPrefersSanma, room: draftRoomPreference)
                    fullAutoConfirmed = true
                    showFullAutoKindChoice = false
                    // 在大廳按「開始」就該立刻排一場——續局引擎是 end_game 驅動的，
                    // 大廳沒有 end_game 可等，不踢這一腳就會什麼都不發生。
                    naki.actions.startFullAutoNow()
                },
                onCancel: { showFullAutoKindChoice = false })
        }
        .accessibilityIdentifier("autoplay-mode-picker")
        .accessibilityLabel("自動打牌模式")
        .accessibilityHint(naki.settings.supportsAutoPlay
                           ? "" : AutoPlayAvailability.autoUnavailableReason)
    }

    /// 套用全自動的兩個選擇。兩個設定一起寫，避免只改一半就開始排隊。
    private func applyFullAutoChoice(sanma: Bool, room: RoomPreference) {
        naki.settings.fullAutoPrefersSanma = sanma
        naki.settings.fullAutoRoomPreference = room
    }

    /// 選人數時要先講清楚的兩件事：續局用的是哪個入口、三麻需要雲端。
    private var fullAutoKindMessage: String {
        var lines = ["對局結束後會自動排下一場，直到你切走模式。"]
        if !naki.settings.cloudConfig.isActive {
            // 三麻是雲端-only（bundled 模型的 obs 對三麻結構性無效，見 CLAUDE.md）
            lines.append("⚠️ 雲端推論未啟用，選三麻會排不進去（排了也不會出手）。")
        }
        lines.append("只會排你自己點過、而且已經打過一場的場次；沒有的話會停下來並在紀錄裡說明。")
        return lines.joined(separator: "\n")
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
                    naki.settings.pinMajsoulServer = pin
                    // 相同就只寫設定，不重載——`switchServer` 一定會整頁重載，
                    // 而這時頁面根本還沒載過，重載沒有意義。
                    if server == naki.settings.majsoulServer {
                        naki.settings.majsoulServer = server
                    } else {
                        naki.actions.switchServer(server)
                    }
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
        .sheet(isPresented: $showPlugins) {
            PluginsPageView()
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

        // 插件（獨立頁面：清單 + 熱插拔開關 + 即時 log）
        ToolbarItem(placement: .primaryAction) {
            Button(action: { showPlugins = true }) {
                Image(systemName: "puzzlepiece.extension")
            }
            .help("插件")
            .accessibilityIdentifier("toolbar-plugins")
            .accessibilityLabel("插件")
        }

        // 左側：自動打牌模式
        ToolbarItem(placement: .navigation) {
            autoPlayModePicker(width: autoPlayMenuWidth, menu: true)
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

    /// 右側常駐欄的寬度。
    ///
    /// 220pt 不是視覺偏好而是三個下限的交集：segmented picker 三段（關／推薦／自動）
    /// 要 ~200pt 才不把字擠掉；`DecisionSidebar(compact:)` 的摘要條是照 ~190–210pt
    /// 內容寬設計的；控制列五顆圖示每顆 40pt 剛好排滿一列。再窄就得砍其中一項。
    private static let iOSPanelWidth: CGFloat = 220

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

    /// 牌桌底部的狀態訊息浮層。**預設關閉**，見 `SettingsStore.showStatusBar`。
    ///
    /// `allowsHitTesting(false)` 是必要的而不是保險：它是純資訊顯示、沒有任何可點的
    /// 東西，卻疊在 WebView 上——少了這行就平白吃掉牌桌那一條的觸控。
    @ViewBuilder
    private var iOSStatusOverlay: some View {
        if naki.settings.showStatusBar, !naki.store.statusMessage.isEmpty {
            StatusBar()
                .background(.ultraThinMaterial)
                // 整條（含背景）讓開 home indicator，否則最後一行字會被那根橫條壓住
                .padding(.bottom, bottomSafeInset)
                .allowsHitTesting(false)
        }
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
                    // 狀態訊息回到牌桌底部（預設關，見 `SettingsStore.showStatusBar`）。
                    // 掛在 WebView 上而不是整個 ZStack 上：橫跨全寬會連面板底部一起壓。
                    .overlay(alignment: .bottom) {
                        iOSStatusOverlay
                    }

                if showGamePanel {
                    Color.clear
                        .frame(width: Self.iOSPanelWidth)
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
                    .frame(width: Self.iOSPanelWidth)
                    .transition(.move(edge: .trailing))
            }

            // 面板收起來之後唯一叫得回來的入口。
            //
            // 它**必須**待在這個 ZStack 裡（而不是掛在外層 `.overlay` 上）：外層那個
            // 位置會重新套用 safe area，把按鈕往畫面內推 62pt，正好壓在牌桌右上角的
            // 「公告」那一區。在這裡它貼的是螢幕右緣那條黑邊。
            //
            // identifier 與面板內那顆收合鈕共用：兩者互斥出現，測試永遠只找得到一顆。
            if !showGamePanel {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showGamePanel = true }
                } label: {
                    Image(systemName: "sidebar.right")
                        .padding(10)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .accessibilityIdentifier("toolbar-game-panel-toggle")
                .accessibilityLabel("顯示決策面板")
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
        .sheet(isPresented: $showLog) {
            iOSLogSheet
        }
        .sheet(isPresented: $showAdvancedSettings) {
            AdvancedSettingsSheet()
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
    /// 排成三列而不是硬擠一列：220pt 欄寬裡，延遲 stepper（~130pt）與五顆圖示
    /// （~200pt）加起來超過可用寬度，擠在一起會先犧牲 stepper 的數字。
    ///
    /// **順序：圖示列在最上，模式與延遲在下。** 圖示那排是「離開這裡去別的地方」
    /// （重載／日誌／設定／收面板），一局裡按不到幾次；模式與延遲是對局中真的會動的
    /// 東西，排在下面就離決策區更近。
    private var iOSPanelControls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 0) {
                Button(action: { naki.actions.reloadPage() }) {
                    Image(systemName: "arrow.clockwise")
                }
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("toolbar-reload")
                .accessibilityLabel("重新載入")

                Button(action: { showLog = true }) {
                    Image(systemName: "terminal")
                }
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("toolbar-log-toggle")
                .accessibilityLabel("顯示日誌")

                cloudQuickToggle
                    .frame(maxWidth: .infinity)

                Button(action: { showAdvancedSettings = true }) {
                    Image(systemName: "gearshape")
                }
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("toolbar-settings")
                .accessibilityLabel("進階設定")

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showGamePanel = false }
                } label: {
                    Image(systemName: "sidebar.trailing")
                }
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("toolbar-game-panel-toggle")
                .accessibilityLabel("隱藏決策面板")
                .accessibilityValue("已顯示")
            }

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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.windowBackground)
        .accessibilityIdentifier("server-picker")
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
                    Text("\(server.displayName)・\(server.regionName)")
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
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isOn ? Color.accentColor.opacity(0.55)
                                       : Color.secondary.opacity(0.22),
                                  lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("server-option-\(server.rawValue)")
        .accessibilityLabel("\(server.displayName) \(server.regionName)")
        .accessibilityValue(isOn ? "已選擇" : "未選擇")
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

    /// 狀態訊息列的顯示與否。純顯示設定，沒有副作用要走 Action——
    /// 與 `hidePlayerNames` 不同，那個要連動 `WebSession` 去改注入的 JS。
    private var showStatusBar: Binding<Bool> {
        Binding(get: { naki.settings.showStatusBar },
                set: { naki.settings.showStatusBar = $0 })
    }

    /// 區服。setter 走 Action 而不是直接寫 settings——換服要整頁重載，
    /// 那是副作用，屬於 `SwitchServerAction`（它自己會寫設定）。
    private var majsoulServer: Binding<MajsoulServer> {
        Binding(get: { naki.settings.majsoulServer },
                set: { naki.actions.switchServer($0) })
    }

    /// 「啟動時不再詢問」。純設定，下次啟動才生效。
    private var pinMajsoulServer: Binding<Bool> {
        Binding(get: { naki.settings.pinMajsoulServer },
                set: { naki.settings.pinMajsoulServer = $0 })
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

            // 雀魂伺服器
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("伺服器", selection: majsoulServer) {
                        ForEach(MajsoulServer.allCases) { server in
                            Text("\(server.displayName)・\(server.regionName)").tag(server)
                        }
                    }
                    .accessibilityIdentifier("majsoul-server-picker")

                    Text("目前：\(naki.settings.majsoulServer.host)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)

                    Text("換伺服器會**整頁重新載入**，等於登出重來——各服的帳號不互通。對局中不要換。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Divider()

                    Toggle("啟動時不再詢問", isOn: pinMajsoulServer)
                        .accessibilityIdentifier("pin-majsoul-server-toggle")

                    // 這行是「取消固定」的說明：關掉開關就會恢復每次啟動詢問。
                    // 沒有這句的話，勾過「以後都用這個」的人不會知道怎麼把它要回來。
                    Text(naki.settings.pinMajsoulServer
                         ? "已固定為 \(naki.settings.majsoulServer.regionName)，啟動時直接進入。關掉這個開關就會恢復每次詢問。"
                         : "每次啟動都會問要連哪個伺服器，上次選的會預先選起來。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } label: {
                Label("雀魂伺服器", systemImage: "globe.asia.australia")
            }

            // 畫面
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text("暱稱隱藏與牌面高亮已改由**插件**提供（工具列拼圖圖示 → 插件頁面）。裝「暱稱隱藏」「牌面變色」插件即可；底層 API 仍在，只是不再內建自動開。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    // 只有 iOS：那條狀態列疊在牌桌上。macOS 的是排版出來的一列，
                    // 不擋任何東西，沒有這個開關要解決的問題。
                    #if os(iOS)
                    Divider()

                    Toggle("顯示狀態訊息列", isOn: showStatusBar)
                        .accessibilityIdentifier("show-status-bar-toggle")

                    Text("牌桌底部那條浮動訊息（連線狀態、未自動送出的原因等）。預設關閉——它疊在牌桌上，而內容多半是一次性回饋或診斷輸出。真正不會自己好的錯誤走頂端橫幅，不受這個開關影響。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    #endif
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

// MARK: - 全自動設定表

/// 切到「全自動」時要當場確認的兩件事：打幾人麻將、排哪一級的房。
///
/// 為什麼是 sheet 不是 confirmationDialog：4 種組合在 macOS 的
/// confirmationDialog 上只畫得出 3 個按鈕（第 4 個消失、取消鈕變成 OK，2026-08-09 實測）。
/// 兩個維度用兩個 Picker 表達也比 4 個複合按鈕好讀。
private struct FullAutoSetupSheet: View {

    @Binding var sanma: Bool
    @Binding var room: RoomPreference
    /// 雲端推論是否可用（決定要不要對三麻掛警告）
    let cloudActive: Bool
    let onStart: () -> Void
    let onCancel: () -> Void

    /// 選三麻但沒有雲端＝排進去也一手都不會打（三麻是雲端-only）
    private var sanmaBlocked: Bool { sanma && !cloudActive }

    var body: some View {
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
                    Text("\(pref.label)房").tag(pref)
                }
            }
            .pickerStyle(.segmented)

            Text("依帳號段位挑一間打得了的房：「最低」對手最弱、掉段風險最小；"
                 + "「最高」點數效率高但打不好會掉段。")
                .font(.footnote)
                .foregroundStyle(.secondary)

            if sanmaBlocked {
                Label("雲端推論未啟用，三麻不會排隊——三麻只有雲端路徑，排進去也不會出手。",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            Text("只會排你自己點過、而且已經打過一場的場次；沒有的話會停下來並在紀錄裡說明。")
                .font(.footnote)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("取消", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("開始", action: onStart)
                    .keyboardShortcut(.defaultAction)
                    // 選了會直接失敗的組合就不讓按，而不是按了才在 log 裡說不行
                    .disabled(sanmaBlocked)
            }
        }
        .padding(20)
        .frame(width: 380)
        .accessibilityIdentifier("fullauto-setup-sheet")
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

// MARK: - 插件頁面（獨立）

/// 插件的獨立頁面：上半是插件清單（帶**熱插拔**開關，即時生效免 reload），
/// 下半是即時的 `[Plugin]` log——啟用的插件經 `ctx.log` 送出的每一行都會出現在這。
///
/// log 即時性：`LogManager.shared` 是 `@Observable`，body 直接讀它的 `recentLogLines()`
/// ⇒ 有新 log 進來就自動重繪（不必自己輪詢）。
struct PluginsPageView: View {
    @Environment(\.naki) private var naki
    @Environment(\.dismiss) private var dismiss

    // 從 URL 匯入（§6.5）的狀態。importPreview 是**一批**（GitHub repo 可多個）。
    @State private var importURL = ""
    @State private var importing = false
    @State private var importPreview: [ImportedPlugin] = []
    @State private var importError: String?
    @State private var importMessage: String?
    @State private var updateChecking = false

    // 移除插件的確認
    @State private var pendingRemoval: String?

    var body: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            HStack {
                Label("插件", systemImage: "puzzlepiece.extension").font(.headline)
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("plugins-done-button")
            }
            .padding()
            .background(Color.contentBackground)
            Divider()
            ScrollView { content }
        }
        .frame(width: 720, height: 640)
        #else
        NavigationStack {
            ScrollView { content }
                .navigationTitle("插件")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { dismiss() }
                            .accessibilityIdentifier("plugins-done-button")
                    }
                }
        }
        #endif
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            pluginList
            importSection
            logSection
        }
        .padding()
        .confirmationDialog(
            "移除插件？",
            isPresented: Binding(get: { pendingRemoval != nil },
                                 set: { if !$0 { pendingRemoval = nil } }),
            presenting: pendingRemoval
        ) { id in
            Button("移除「\(id)」", role: .destructive) {
                naki.actions.removePlugin(id)   // 熱停用 + 刪目錄 + 重掃
                pendingRemoval = nil
            }
            Button("取消", role: .cancel) { pendingRemoval = nil }
        } message: { id in
            Text("會刪掉 \(id) 的整個插件目錄。可重新匯入或放檔案救回。")
        }
    }

    // MARK: 從 URL 匯入（§6.5）

    @ViewBuilder
    private var importSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text("貼 **GitHub repo**（`owner/repo`，一次多個插件）、gist 連結、或任意 HTTPS 的 plugin.json。只抓一次、預覽確認後才落地。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    TextField("Sunalamye/naki-plugins 或 gist / plugin.json 網址", text: $importURL)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.caption, design: .monospaced))
                        .disableAutocorrection(true)
                        .accessibilityIdentifier("plugin-import-url")
                    Button(importing ? "抓取中…" : "抓取") { Task { await fetchImport() } }
                        .disabled(importing || importURL.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button(updateChecking ? "檢查中…" : "檢查更新") { Task { await checkUpdates() } }
                        .disabled(updateChecking)
                        .help("對每個已裝插件重抓來源，比對內容有沒有變")
                }

                if let err = importError {
                    Text("匯入失敗：\(err)").font(.caption).foregroundColor(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let msg = importMessage {
                    Text(msg).font(.caption).foregroundColor(.green)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !importPreview.isEmpty {
                    Divider()
                    Text("預覽 \(importPreview.count) 個插件——看過原始碼再引入：")
                        .font(.caption).bold()
                    ForEach(importPreview, id: \.id) { p in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(p.manifest.name).font(.caption).bold()
                            Text("\(p.manifest.id) · v\(p.manifest.version) · \(p.manifest.capabilities.joined(separator: ", "))")
                                .font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                            if let rev = p.revision {
                                Text("revision：\(rev.prefix(12))").font(.caption2).foregroundStyle(.secondary)
                            }
                            DisclosureGroup("原始碼（\(p.manifest.entry)）") {
                                ScrollView {
                                    Text(p.entrySource)
                                        .font(.system(.caption2, design: .monospaced))
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .frame(maxHeight: 120)
                                .background(Color.secondary.opacity(0.08))
                            }
                            .font(.caption2)
                        }
                        Divider()
                    }

                    Text("⚠️ 安裝＝信任作者。插件能用你的帳號送動作、讀頁面上任何資料，Naki 無法阻止。")
                        .font(.caption2).foregroundColor(.red)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack {
                        Button("確認引入全部（\(importPreview.count)）") { confirmImportAll() }
                            .buttonStyle(.borderedProminent)
                        Button("取消") { importPreview = [] }
                    }
                }
            }
        } label: {
            Label("從來源加入（GitHub repo / gist / URL）", systemImage: "arrow.down.circle")
        }
    }

    private func fetchImport() async {
        importing = true; importError = nil; importMessage = nil; importPreview = []
        // fetchAny：repo → 多個；gist / plugin.json → 一個
        let result = await PluginImportSource.fetchAny(urlString: importURL)
        importing = false
        switch result {
        case .success(let list): importPreview = list
        case .failure(let e): importError = e.text
        }
    }

    private func confirmImportAll() {
        var ok = 0
        for p in importPreview {
            if case .success = PluginImportSource.install(p, now: Date()) { ok += 1 }
        }
        naki.actions.rescanPlugins()               // 刷新清單（@Observable → 立即反映）
        let total = importPreview.count
        importPreview = []
        importURL = ""
        importMessage = "已引入 \(ok)/\(total) 個插件。在上面清單啟用（熱插拔，免重載）。"
    }

    /// 檢查每個已裝插件有沒有更新；有的話一鍵更新（重抓 + 覆蓋 + 熱重載）。
    private func checkUpdates() async {
        updateChecking = true; importError = nil; importMessage = nil
        var updated = 0, checked = 0
        for d in naki.pluginDescriptors {
            checked += 1
            guard let fresh = await PluginImportSource.fetchUpdate(pluginId: d.id) else { continue }
            if case .success = PluginImportSource.install(fresh, now: Date()) {
                updated += 1
                // 熱重載：啟用中的話 disable→enable 帶新源碼
                if naki.settings.enabledPluginIds.contains(d.id) {
                    naki.actions.setPluginEnabled(d.id, false)
                    naki.actions.setPluginEnabled(d.id, true)
                }
            }
        }
        naki.actions.rescanPlugins()
        updateChecking = false
        importMessage = updated > 0
            ? "更新了 \(updated) 個插件（已熱重載套用）。"
            : "檢查了 \(checked) 個，沒有更新。"
    }

    // MARK: 插件清單

    @ViewBuilder
    private var pluginList: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                if naki.pluginDescriptors.isEmpty {
                    Text("沒有安裝插件。放進 ~/Library/Application Support/Naki/Plugins/<id>/ 後重新啟動 App。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(naki.pluginDescriptors, id: \.id) { descriptor in
                        pluginRow(descriptor)
                        if descriptor.id != naki.pluginDescriptors.last?.id {
                            Divider()
                        }
                    }
                }

                Divider()

                // L3 總開關（§8.1）：預設關。開啟＝允許插件用你的帳號送遊戲動作。
                Toggle(isOn: Binding(
                    get: { naki.settings.pluginsMayModifyOutbound },
                    set: { on in
                        naki.settings.pluginsMayModifyOutbound = on
                        let js = "window.__nakiPluginsMayModifyOutbound = \(on ? "true" : "false");"
                        Task { _ = try? await naki.actions.executeJavaScript(js) }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("允許插件送出遊戲動作（L3）").font(.caption).bold()
                        Text("開啟後，有 injectSend/rewriteSend 能力的插件可以用你的帳號送出 Liqi request。預設關閉。只在測試帳號、且你信任插件時開。")
                            .font(.caption2)
                            .foregroundColor(naki.settings.pluginsMayModifyOutbound ? .red : .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityIdentifier("plugins-may-modify-outbound-toggle")

                Divider()

                Text("**安裝插件＝信任其作者。** 插件與遊戲跑在同一個環境裡，惡意插件可以用你的帳號送出任何遊戲動作、讀取頁面上任何資料，Naki 無法阻止。只裝你信任的插件。開關**即時生效，免重新載入頁面**。")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } label: {
            Label("已安裝插件", systemImage: "square.stack.3d.up")
        }
    }

    @ViewBuilder
    private func pluginRow(_ descriptor: PluginDescriptor) -> some View {
        if let manifest = descriptor.manifest {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top) {
                    Toggle(isOn: Binding(
                        get: { naki.settings.enabledPluginIds.contains(descriptor.id) },
                        set: { on in naki.actions.setPluginEnabled(descriptor.id, on) }   // 熱插拔
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(manifest.name).font(.body)
                            Text("\(manifest.id) · v\(manifest.version) · \(manifest.capabilities.joined(separator: ", "))")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                            if let license = manifest.license {
                                Text("授權：\(license)").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .accessibilityIdentifier("plugin-toggle-\(descriptor.id)")

                    removeButton(descriptor.id)
                }

                // 插件設定（§7.10a）：有 schema 且已啟用才顯示；改值即時套用（熱重載）。
                if let schema = manifest.settings, !schema.isEmpty,
                   naki.settings.enabledPluginIds.contains(descriptor.id) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(schema.keys.sorted(), id: \.self) { key in
                            if let field = schema[key] {
                                pluginSettingControl(pluginId: descriptor.id, key: key, field: field)
                            }
                        }
                    }
                    .padding(.leading, 20)
                }
            }
        } else {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(descriptor.id).font(.body)
                    Text(descriptor.failure?.text ?? "無效插件")
                        .font(.caption)
                        .foregroundColor(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                removeButton(descriptor.id)   // 壞插件也能移除
            }
        }
    }

    /// 移除按鈕（垃圾桶）——點了走確認對話。
    @ViewBuilder
    private func removeButton(_ id: String) -> some View {
        Button(role: .destructive) { pendingRemoval = id } label: {
            Image(systemName: "trash")
        }
        .buttonStyle(.borderless)
        .help("移除插件（刪檔案，可重新匯入救回）")
        .accessibilityIdentifier("plugin-remove-\(id)")
    }

    /// 單一設定欄位的控制項（string→TextField、number→TextField、boolean→Toggle）。
    /// 改值 → 存 SettingsStore → 重新啟用該插件（熱重載，帶新設定值）。
    @ViewBuilder
    private func pluginSettingControl(pluginId: String, key: String, field: PluginSettingField) -> some View {
        let label = field.description ?? key
        switch field.type {
        case "boolean":
            Toggle(label, isOn: Binding(
                get: {
                    (naki.settings.pluginSettingValue(pluginId: pluginId, key: key) as? Bool)
                        ?? { if case .boolean(let b) = field.defaultValue { return b }; return false }()
                },
                set: { v in
                    naki.settings.setPluginSettingValue(pluginId: pluginId, key: key, value: v)
                    naki.actions.setPluginEnabled(pluginId, true)   // 熱重載套用
                }
            ))
            .font(.caption)
        case "number":
            HStack {
                Text(label).font(.caption)
                Spacer()
                TextField("", value: Binding(
                    get: {
                        (naki.settings.pluginSettingValue(pluginId: pluginId, key: key) as? Double)
                            ?? { if case .number(let d) = field.defaultValue { return d }; return 0 }()
                    },
                    set: { v in
                        naki.settings.setPluginSettingValue(pluginId: pluginId, key: key, value: v)
                        naki.actions.setPluginEnabled(pluginId, true)
                    }
                ), format: .number)
                .frame(width: 100)
                .font(.system(.caption, design: .monospaced))
                #if os(iOS)
                .keyboardType(.numbersAndPunctuation)
                #endif
            }
        default:   // string
            HStack {
                Text(label).font(.caption)
                Spacer()
                TextField("", text: Binding(
                    get: {
                        (naki.settings.pluginSettingValue(pluginId: pluginId, key: key) as? String)
                            ?? { if case .string(let s) = field.defaultValue { return s }; return "" }()
                    },
                    set: { v in
                        naki.settings.setPluginSettingValue(pluginId: pluginId, key: key, value: v)
                        naki.actions.setPluginEnabled(pluginId, true)
                    }
                ))
                .frame(width: 160)
                .font(.system(.caption, design: .monospaced))
                .textFieldStyle(.roundedBorder)
            }
        }
    }

    // MARK: 即時 log

    @ViewBuilder
    private var logSection: some View {
        GroupBox {
            let lines = LogManager.shared.recentLogLines().filter { $0.contains("[Plugin]") }
            VStack(alignment: .leading, spacing: 6) {
                if lines.isEmpty {
                    Text("還沒有插件 log。啟用一個插件、進一局後，它經 ctx.log 送出的訊息會即時出現在這裡。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(lines.suffix(300).enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.system(.caption2, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .frame(minHeight: 160, maxHeight: 280)
                }
            }
        } label: {
            Label("插件 Log（即時）", systemImage: "text.append")
        }
    }
}
