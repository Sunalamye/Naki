//
//  AdvancedSettingsSheet.swift
//  Naki
//
//  設定根 View：macOS 是 `Settings` scene 的分頁視窗，iOS 是單頁捲動的 sheet。
//

import SwiftUI

// MARK: - Settings

struct AdvancedSettingsSheet: View {
    @Environment(\.naki) private var naki
    @Environment(\.dismiss) private var dismiss

    /// 分頁歸屬的唯一定義點：macOS 的 `TabView` 與 iOS 的四個段落都經 `page(_:)`。
    enum SettingsTab: String, CaseIterable, Identifiable {
        case general, connection, ai, developer

        var id: String { rawValue }

        var title: LocalizedStringKey {
            switch self {
            case .general: "一般"
            case .connection: "連線"
            case .ai: "AI"
            case .developer: "開發者"
            }
        }

        var systemImage: String {
            switch self {
            case .general: "gearshape"
            case .connection: "link"
            case .ai: "cpu"
            case .developer: "chevron.left.forwardslash.chevron.right"
            }
        }
    }

    // 以下狀態都留在設定根 View：分頁 View 重建或切頁時不丟探測結果與未套用的草稿。

    /// 「測試連線」的結果（nil＝還沒測）
    @State private var cloudTest: CloudConnectionTest?
    @State private var cloudTestRunning = false
    @State private var updateCheckRunning = false
    /// 測試連線取回的模型清單（供模型欄的下拉選擇；空＝還沒取到）
    @State private var cloudModels: [CloudModelInfo] = []
    /// `GET /v3/key` 的方案／到期／今日用量（nil＝還沒查到或查不到）
    @State private var cloudKeyStatus: CloudKeyStatus?
    /// 自動探測失敗的原因（nil＝沒失敗）
    @State private var cloudProbeFailure: CloudKeyProbe?
    @State private var cloudProbing = false
    /// 雀魂連線的 Header 草稿；只經「套用並重新載入」寫回設定
    @State private var headerRows: [MajsoulConnectionSettingsBox.HeaderRow] = []
#if os(iOS)
    @State private var developerExpanded = false
#endif

    var body: some View {
        Group {
#if os(macOS)
            macOSSettingsContent
#else
            iOSSettingsContent
#endif
        }
        .task(id: cloudProbeToken) { await autoProbeCloud() }
        .task { headerRows = MajsoulConnectionSettingsBox.rows(from: naki.settings.majsoulExtraHeaders) }
    }

    @ViewBuilder
    private func page(_ tab: SettingsTab) -> some View {
        VStack(alignment: .leading, spacing: PanelLayout.Spacing.s16) {
            switch tab {
            case .general:
#if os(macOS)
                languageBox
#endif
                displayBox
                updateBox
            case .connection:
                majsoulServerBox
                MajsoulConnectionSettingsBox(rows: $headerRows)
            case .ai:
                autoPlayAvailabilityBox
                autoPlaySettingsBox
                cloudInferenceBox
            case .developer:
                cloudAPIBox
                botManagementBox
                mcpServerBox
            }
        }
        .groupBoxStyle(FullWidthGroupBoxStyle())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-page-\(tab.id)")
    }

    /// 單欄頁面裡每個 GroupBox 撐滿寬度（系統樣式只貼著內容寬）。
    private struct FullWidthGroupBoxStyle: GroupBoxStyle {
        func makeBody(configuration: Configuration) -> some View {
            GroupBox {
                configuration.content.frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                configuration.label
            }
            .groupBoxStyle(.automatic)
        }
    }

#if os(macOS)
    /// 分頁由系統畫成視窗 toolbar，標題列跟著選取的分頁；沒有完成鈕，以視窗關閉為準。
    private var macOSSettingsContent: some View {
        TabView {
            ForEach(SettingsTab.allCases) { tab in
                ScrollView {
                    page(tab).padding()
                }
                .tabItem { Label(tab.title, systemImage: tab.systemImage) }
            }
        }
        // a11y: fixed window size; large Dynamic Type scrolls inside each page
        .frame(width: 600, height: 560)
        .background(SettingsWindowRegistrar())
    }

    /// 把所在的 `NSWindow` 登記給 `SettingsWindowAction`（weak，比對物件不比對 identifier）。
    private struct SettingsWindowRegistrar: NSViewRepresentable {
        func makeNSView(context: Context) -> NSView { RegistrarView() }
        func updateNSView(_ nsView: NSView, context: Context) {}

        final class RegistrarView: NSView {
            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                if let window { SettingsWindowAction.window = window }
            }
        }
    }
#endif

#if os(iOS)
    /// 四組依序捲動；「開發者」預設折疊。折疊與捲動位置隨 sheet 重建而重設。
    private var iOSSettingsContent: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: PanelLayout.Spacing.s20) {
                    ForEach(SettingsTab.allCases) { tab in
                        if tab == .developer {
                            DisclosureGroup(isExpanded: $developerExpanded) {
                                page(tab).padding(.top, PanelLayout.Spacing.s8)
                            } label: {
                                // 掛在 label 上：掛在 DisclosureGroup 會蓋掉內容的 `settings-page-developer`
                                sectionTitle(tab).accessibilityIdentifier("settings-developer-disclosure")
                            }
                        } else {
                            VStack(alignment: .leading, spacing: PanelLayout.Spacing.s8) {
                                sectionTitle(tab)
                                page(tab)
                            }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        dismiss()
                    }
                    .accessibilityIdentifier("settings-done-button")
                }
            }
        }
    }

    private func sectionTitle(_ tab: SettingsTab) -> some View {
        Text(tab.title)
            .font(.subheadline)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
    }
#endif

#if os(macOS)
    /// 語言。setter 走 Action，與其他會影響執行期行為的設定同一條路。
    private var appLanguage: Binding<AppLanguage> {
        Binding(get: { naki.settings.appLanguage },
                set: { naki.actions.setAppLanguage($0) })
    }
#endif

    /// 背景保活。setter 走 Action：要即時推給已載入的頁面。
    private var keepAliveInBackground: Binding<Bool> {
        Binding(get: { naki.settings.keepAliveInBackground },
                set: { naki.actions.setKeepAliveInBackground($0) })
    }

    @ViewBuilder private var updateCheckResultText: some View {
        switch naki.store.updateCheckResult {
        case .upToDate: Text("已是最新版本").font(.caption).foregroundStyle(.secondary)
        case .available(let version): Text("有新版本 \(version)").font(.caption).foregroundStyle(.secondary)
        case .failed: Text("檢查失敗").font(.caption).foregroundStyle(.secondary)
        case nil: EmptyView()
        }
    }

    private var pinnedServerNote: Text {
        naki.settings.pinMajsoulServer
            ? Text("已固定為 \(Text(naki.settings.majsoulServer.regionNameKey))，啟動時直接進入。關掉這個開關就會恢復每次詢問。")
            : Text("每次啟動都會問要連哪個伺服器，上次選的會預先選起來。")
    }

    /// 區服。setter 走 Action 而不是直接寫 settings——換服要整頁重載，
    /// 那是副作用，屬於 `SwitchServerAction`（它自己會寫設定）。
    private var majsoulServer: Binding<MajsoulServer> {
        Binding(get: { naki.settings.majsoulServer },
                set: { naki.actions.switchServer($0) })
    }

    /// 模型欄：手動輸入為底、伺服器清單為加速器，兩者並存。
    ///
    /// 為什麼不是純下拉：`/v3/models` 是**認證端點**（沒貼有效 key 前拿不到
    /// 清單），而自架伺服器可能根本沒有這個端點——純下拉在這兩種情境會把
    /// 使用者卡死。所以自由輸入永遠可用，「測試連線」成功後箭頭選單才亮起。
    @ViewBuilder
    private func cloudModelRow(placeholder: LocalizedStringKey, pickerLabel: LocalizedStringKey,
                               text: Binding<String>, game: String,
                               accessibilityId: String) -> some View {
        HStack {
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .accessibilityIdentifier(accessibilityId)
            Menu(pickerLabel, systemImage: "chevron.down.circle") {
                Button("還原預設") { text.wrappedValue = "" }
                ForEach(cloudModels.filter { $0.game.isEmpty || $0.game == game },
                        id: \.id) { model in
                    Button(model.desc.isEmpty ? model.id : "\(model.id) — \(model.desc)") {
                        text.wrappedValue = model.id
                    }
                }
            }
            .labelStyle(.iconOnly)
            .disabled(cloudModels.isEmpty)
            .help(cloudModels.isEmpty ? "先到「開發者」按「測試連線」" : "從伺服器清單選擇")
            .accessibilityIdentifier("\(accessibilityId)-picker")
        }
    }

    /// 「現在到底有沒有在用雲端」——把 `enabled && url && key` 這個三段條件
    /// 直接寫成一句話。
    ///
    /// 缺哪一項就講哪一項：使用者最常見的狀態是「key 貼了、開關沒開」，而開關不在
    /// key 欄位旁，填完 key 就不會再去找它。
    @ViewBuilder
    private var cloudEffectiveStateRow: some View {
        let missing = naki.settings.cloudConfig.missingRequirementKeys

        if missing.isEmpty {
            Label("雲端推論已生效——對局中會以雲端決策為準", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(PanelLayout.success)
                .accessibilityIdentifier("cloud-effective-state")
        } else {
            Label("雲端推論尚未生效，仍在用內建本機模型。還缺：\(missingList(missing))",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(PanelLayout.warning)
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
        cloudProbeFailure = nil
        guard naki.settings.cloudInferenceEnabled else { cloudKeyStatus = nil; return }
        let key = naki.settings.cloudAPIKey.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { cloudKeyStatus = nil; return }

        try? await Task.sleep(for: .milliseconds(700))
        guard !Task.isCancelled else { return }

        cloudProbing = true
        defer { cloudProbing = false }
        let result = await naki.actions.probeCloud(baseURL: naki.settings.cloudServerURL, key: key)
        guard !Task.isCancelled else { return }
        switch result {
        case .ok(let status, let models):
            cloudKeyStatus = status
            // 順手把模型清單也帶回來，模型欄的下拉就不必再按一次「測試連線」
            if let models { cloudModels = models }
        case .invalidURL, .failed:
            cloudKeyStatus = nil
            cloudProbeFailure = result
        }
    }

    /// 方案／到期／今日用量。只有在雲端開著且真的查到時才出現。
    @ViewBuilder
    private var cloudKeyStatusCard: some View {
        if naki.settings.cloudInferenceEnabled {
            VStack(alignment: .leading, spacing: PanelLayout.Spacing.s6) {
                HStack {
                    Label("金鑰狀態", systemImage: "person.badge.key")
                        .font(.caption)
                        .fontWeight(.semibold)
                    Spacer()
                    if cloudProbing {
                        ProgressView().controlSize(.small)
                    } else if cloudKeyStatus != nil {
                        HStack(spacing: PanelLayout.Spacing.s4) {
                            Circle().fill(PanelLayout.success).frame(width: 6, height: 6)
                            Text("使用中").font(.caption2)
                        }
                    }
                }

                if let s = cloudKeyStatus {
                    keyRow("方案", Text(verbatim: s.plan.isEmpty ? "—" : s.plan))
                    if !s.expiresAtRaw.isEmpty {
                        keyRow("到期時間", expiryText(s))
                        if let days = s.daysRemaining {
                            keyRow("剩餘", s.isExpired ? Text("已過期") : Text("\(days) 天"),
                                   tint: s.isExpired ? PanelLayout.danger : (days <= 3 ? PanelLayout.warning : nil))
                        }
                    }
                    if s.rpd > 0 {
                        keyRow("今日用量", Text(verbatim: "\(s.usageToday) / \(s.rpd)"))
                        if let f = s.usageFraction {
                            ProgressView(value: f)
                                .progressViewStyle(.linear)
                                .tint(f > 0.9 ? PanelLayout.danger : (f > 0.7 ? PanelLayout.warning : .accentColor))
                        }
                    } else if s.usageToday > 0 {
                        keyRow("今日用量", Text(verbatim: "\(s.usageToday)"))
                    }
                    if s.rpm > 0 || s.topK > 0 {
                        keyRow("限額", limitText(rpm: Int(s.rpm.rounded()), topK: s.topK))
                    }
                } else if let failure = cloudProbeFailure {
                    // 查不到就說查不到。留白會讓人以為「這個方案沒有額度資訊」，
                    // 而實際上多半是 key 打錯或伺服器連不上。
                    probeFailureText(failure)
                        .font(.caption2)
                        .foregroundStyle(PanelLayout.warning)
                        .fixedSize(horizontal: false, vertical: true)
                } else if !cloudProbing {
                    Text("填入 API Key 後會自動查詢方案與今日用量。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(PanelLayout.Spacing.s10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.contentBackground)
            .clipShape(.rect(cornerRadius: PanelLayout.Radius.row))
            .accessibilityIdentifier("cloud-key-status-card")
        }
    }

    private func probeFailureText(_ probe: CloudKeyProbe) -> Text {
        if case .failed(let reason) = probe { return Text("讀不到金鑰狀態：\(reason)") }
        return Text("伺服器 URL 無法解析")
    }

    private func keyRow(_ label: LocalizedStringKey, _ value: Text, tint: Color? = nil) -> some View {
        HStack {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Spacer(minLength: PanelLayout.Spacing.s8)
            value
                .font(.system(.caption, design: .monospaced))
                .fontWeight(.medium)
                .foregroundStyle(tint ?? .primary)
        }
        .accessibilityElement(children: .combine)
    }

    private func limitText(rpm: Int, topK: Int) -> Text {
        switch (rpm > 0, topK > 0) {
        case (true, true): Text("\(rpm) 次/分・top-\(topK)")
        case (true, false): Text("\(rpm) 次/分")
        default: Text(verbatim: "top-\(topK)")
        }
    }

    /// 到期時間顯示成本地時間；解不出 `Date` 就照抄伺服器原字串，不隱藏。
    private func expiryText(_ s: CloudKeyStatus) -> Text {
        guard let d = s.expiresAt else { return Text(verbatim: s.expiresAtRaw) }
        return Text(d, format: .dateTime.year().month().day().hour().minute().second())
    }

    private func runCloudConnectionTest() {
        cloudTestRunning = true
        cloudTest = nil
        Task {
            defer { cloudTestRunning = false }
            let result = await naki.actions.testCloudConnection(
                baseURL: naki.settings.cloudServerURL, key: naki.settings.cloudAPIKey)
            if case .ok(_, let models, let key) = result {
                cloudModels = models   // 餵給模型欄的下拉（見 cloudModelRow）
                // 手動測試也把金鑰狀態帶回來：否則按了按鈕卻看不到方案／用量，
                // 會以為那張卡片壞了。
                cloudKeyStatus = key
            }
            cloudTest = result
        }
    }

    /// 「連得上」不等於「有在用」：開關沒開時附上這一句，否則成功訊息會強化「已經配置好了」的錯覺。
    private func cloudTestText(_ result: CloudConnectionTest) -> Text {
        switch result {
        case .healthOnly(let status):
            return Text("伺服器 \(status)（未填 key，略過模型查詢）")
        case .failed(let reason):
            return Text("失敗：\(reason)")
        case .ok(let status, let models, _):
            let list = models.isEmpty ? L10n.text("無") : models.map { "\($0.id)(\($0.game))" }.joined(separator: ", ")
            if naki.settings.cloudInferenceEnabled { return Text("伺服器 \(status)；可用模型：\(list)") }
            return models.isEmpty
                ? Text("伺服器 \(status)；可用模型：\(list)（但開關未開，對局仍走本機模型）")
                : Text("伺服器 \(status)；可用模型：\(list)（但開關未開，對局仍走本機模型）——可用模型欄旁的箭頭直接選")
        }
    }

    @ViewBuilder
    private var majsoulServerBox: some View {
        @Bindable var settings = naki.settings

        GroupBox {
            VStack(alignment: .leading, spacing: PanelLayout.Spacing.s8) {
                Picker("伺服器", selection: majsoulServer) {
                    ForEach(MajsoulServer.allCases) { server in
                        Text("\(Text(server.displayNameKey))・\(Text(server.regionNameKey))").tag(server)
                    }
                }
                .accessibilityIdentifier("majsoul-server-picker")

                Text("目前：\(naki.settings.majsoulServer.host)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)

                Text("換服要重新登入，對局中別換")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                Toggle("不再詢問", isOn: $settings.pinMajsoulServer)
                    .accessibilityIdentifier("pin-majsoul-server-toggle")

                // 這行是「取消固定」的說明：關掉開關就會恢復每次啟動詢問。
                // 沒有這句的話，勾過「以後都用這個」的人不會知道怎麼把它要回來。
                pinnedServerNote
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } label: {
            Label("雀魂伺服器", systemImage: "globe.asia.australia")
        }
    }

#if os(macOS)
    private var languageBox: some View {
        GroupBox {
            Picker("語言", selection: appLanguage) {
                ForEach(AppLanguage.allCases) { language in
                    if let name = language.nativeName {
                        Text(verbatim: name).tag(language)
                    } else {
                        Text("跟隨系統").tag(language)
                    }
                }
            }
            .accessibilityIdentifier("app-language-picker")
        } label: {
            Label("語言", systemImage: "character.bubble")
        }
    }
#endif

    @ViewBuilder
    private var displayBox: some View {
        @Bindable var settings = naki.settings

        GroupBox {
            VStack(alignment: .leading, spacing: PanelLayout.Spacing.s8) {
                Toggle("視窗在背景時保持遊戲運作", isOn: keepAliveInBackground)
                    .accessibilityIdentifier("keep-alive-in-background-toggle")

                Text("開啟後，視窗被蓋住仍低頻運作")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // 只有 iOS：那條狀態列疊在牌桌上。macOS 的是排版出來的一列，
                // 不擋任何東西，沒有這個開關要解決的問題。
                #if os(iOS)
                Divider()

                Toggle("顯示狀態訊息列", isOn: $settings.showStatusBar)
                    .accessibilityIdentifier("show-status-bar-toggle")
                #endif

                Divider()

                Text("暱稱隱藏與牌面高亮改由插件提供")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } label: {
            Label("畫面", systemImage: "eye.slash")
        }
    }

    @ViewBuilder
    private var updateBox: some View {
        @Bindable var settings = naki.settings

        GroupBox {
            VStack(alignment: .leading, spacing: PanelLayout.Spacing.s8) {
                Toggle("自動檢查更新", isOn: $settings.autoCheckUpdate)
                    .accessibilityIdentifier("auto-check-update-toggle")

                HStack {
                    Text("目前版本 \(NakiAppVersion.short)")
                    Button(updateCheckRunning ? "檢查中…" : "立即檢查") {
                        Task {
                            updateCheckRunning = true
                            await naki.actions.checkForUpdate(manual: true)
                            updateCheckRunning = false
                        }
                    }
                    .disabled(updateCheckRunning)
                    .accessibilityIdentifier("check-update-button")
                    updateCheckResultText
                }
            }
        } label: {
            Label("更新", systemImage: "arrow.down.circle")
        }
    }

    private var botManagementBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: PanelLayout.Spacing.s12) {
                Text("開局時自動建立，通常不必管")
                    .font(.caption)
                    .foregroundStyle(.secondary)

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
                    .tint(PanelLayout.danger)
                    #endif
                    .accessibilityIdentifier("delete-bot-button")
                }
            }
        } label: {
            Label("Bot 管理", systemImage: "cpu")
        }
    }

    /// MCP Server（兩個平台都有，`DebugServer` 不是 macOS 專屬）。
    /// **不要包回 `#if os(macOS)`**：iOS 也會綁 loopback 8765，
    /// 控制項藏起來就變成「跑著卻看不到、關不掉」。
    private var mcpServerBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: PanelLayout.Spacing.s8) {
                HStack {
                    HStack {
                        Circle()
                            .fill(naki.store.isDebugServerRunning ? PanelLayout.success : PanelLayout.neutral)
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
                    .tint(naki.store.isDebugServerRunning ? PanelLayout.danger : PanelLayout.success)
                    .accessibilityIdentifier("mcp-server-toggle-button")
                }

                if naki.store.isDebugServerRunning {
                    VStack(alignment: .leading, spacing: PanelLayout.Spacing.s4) {
                        Text(verbatim: "http://localhost:\(naki.store.debugServerPort)")
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)

                        Text(verbatim: "curl http://localhost:\(naki.store.debugServerPort)/logs")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
        } label: {
            Label("MCP Server", systemImage: "server.rack")
        }
    }

    /// AI 頁：雲端推論的開關與模型（資料外送聲明在這裡）。
    @ViewBuilder
    private var cloudInferenceBox: some View {
        @Bindable var settings = naki.settings

        GroupBox {
            VStack(alignment: .leading, spacing: PanelLayout.Spacing.s8) {
                Toggle("啟用雲端推論", isOn: $settings.cloudInferenceEnabled)
                    .accessibilityIdentifier("cloud-inference-toggle")

                Text("啟用後上傳本局牌譜與手牌，失敗改用本機")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                cloudModelRow(placeholder: "四麻模型（空＝伺服器預設）",
                              pickerLabel: "選擇四麻模型",
                              text: $settings.cloudModel4P, game: "4p",
                              accessibilityId: "cloud-model-4p-field")
                cloudModelRow(placeholder: "三麻模型（空＝伺服器預設）",
                              pickerLabel: "選擇三麻模型",
                              text: $settings.cloudModel3P, game: "3p",
                              accessibilityId: "cloud-model-3p-field")

                // 生效條件是 `enabled && url && key` 三者，開關與 URL／金鑰分在兩頁。
                // 兩頁都放這一行，否則「貼完 key 就走」會得到看起來已配置、行為卻是本機模型的設定
                // （Akagi #221 的形狀）。
                cloudEffectiveStateRow

                Text("三麻提醒：本機有 Akagi 三麻（default strength，模仿天鳳人類）接手，雲端啟用時雲端優先；側欄的建議來源會如實顯示。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } label: {
            Label("雲端推論", systemImage: "icloud.and.arrow.up")
        }
    }

    /// 開發者頁：雲端伺服器、金鑰與連線測試。金鑰經 `SettingsStore` 存 Keychain。
    @ViewBuilder
    private var cloudAPIBox: some View {
        @Bindable var settings = naki.settings

        GroupBox {
            VStack(alignment: .leading, spacing: PanelLayout.Spacing.s8) {
                HStack {
                    TextField("伺服器 URL", text: $settings.cloudServerURL)
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
                    .foregroundStyle(.secondary)

                SecureField("API Key（自行取得後貼上）", text: $settings.cloudAPIKey)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("cloud-api-key-field")

                Text("金鑰存在鑰匙圈，不會寫進紀錄")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Button(cloudTestRunning ? "測試中…" : "測試連線") {
                        runCloudConnectionTest()
                    }
                    .buttonStyle(.bordered)
                    .disabled(cloudTestRunning)
                    .accessibilityIdentifier("cloud-test-button")

                    if let result = cloudTest {
                        cloudTestText(result)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("cloud-test-result")
                    }
                }

                cloudEffectiveStateRow

                cloudKeyStatusCard
            }
        } label: {
            Label("雲端 API", systemImage: "key")
        }
    }

    /// 自動操作：送出可用性與基準延遲。
    ///
    /// 延遲在 toolbar 也有一個 stepper（對局中快速微調），這裡是它的完整說明版——
    /// toolbar 那顆只有數字，講不出合法範圍，也講不出隨機分布仍然會套用。
    @ViewBuilder
    private var autoPlaySettingsBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: PanelLayout.Spacing.s8) {
                HStack {
                    Text("自動送出")
                    Spacer()
                    Text(naki.settings.supportsAutoPlay ? "可用" : "不可用")
                        .fontWeight(.semibold)
                        .foregroundStyle(naki.settings.supportsAutoPlay ? PanelLayout.success : PanelLayout.neutral)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("autoplay-availability-row")

                if naki.settings.supportsAutoPlay {
                    Divider()
                    ActionDelayStepper()
                    Text("延遲是倍率，實際送出仍會隨機浮動")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                VStack(alignment: .leading, spacing: PanelLayout.Spacing.s8) {
                    Text("不能自動")
                        .font(.callout)
                        .fontWeight(.semibold)
                    Text(AutoPlayAvailability.autoUnavailableReasonKey)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("模式選單只有「關」與「推薦」")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } label: {
                Label("自動打牌", systemImage: "hand.raised")
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("autoplay-unavailable-note")
            .accessibilityLabel("不能自動")
            .accessibilityValue(AutoPlayAvailability.autoUnavailableReasonKey)
        }
    }
}
