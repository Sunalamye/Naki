//
//  PluginsPageView.swift
//  Naki
//
//  插件獨立頁面與其字串設定欄位。
//

import SwiftUI

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
    @State private var pendingUpdates: [PluginUpdate] = []   // 檢查到、等使用者確認的更新
    @State private var confirmingOutbound = false            // L3 總開關由關轉開的確認
    @State private var selectedImports: Set<String> = []   // 預覽中勾選要引入的 id

    // 移除插件的確認
    @State private var pendingRemoval: String?
    @State private var diagnosticsText = L10n.text("尚未檢查目前遊戲頁面")
    @State private var checkingDiagnostics = false
    @State private var tab: PluginTab = .plugins
    @State private var selectedPluginId: String?   // master-detail 選中的插件

    /// 分頁：把 Log 與信任/L3 從主畫面分出去，插件管理不再和 log 擠一起。
    enum PluginTab: String, CaseIterable, Identifiable {
        case plugins = "插件"
        case log = "Log"
        case trust = "信任"
        var id: String { rawValue }
        var title: LocalizedStringKey { LocalizedStringKey(rawValue) }
        var icon: String {
            switch self {
            case .plugins: return "puzzlepiece.extension"
            case .log: return "text.append"
            case .trust: return "lock.shield"
            }
        }
    }

    var body: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Label("插件", systemImage: "puzzlepiece.extension").font(.headline)
                Spacer()
                tabPicker.frame(maxWidth: 320)
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("plugins-done-button")
            }
            .padding()
            .background(Color.contentBackground)
            Divider()
            tabBody
        }
        .frame(width: 900, height: 660)
        .confirmationDialog(removeDialogTitle, isPresented: removeDialogBinding,
                            presenting: pendingRemoval, actions: removeDialogActions,
                            message: removeDialogMessage)
        #else
        NavigationStack {
            VStack(spacing: 0) {
                tabPicker.padding([.horizontal, .top])
                tabBody
            }
            .navigationTitle("插件")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .accessibilityIdentifier("plugins-done-button")
                }
            }
            .confirmationDialog(removeDialogTitle, isPresented: removeDialogBinding,
                                presenting: pendingRemoval, actions: removeDialogActions,
                                message: removeDialogMessage)
        }
        #endif
    }

    // 移除確認對話（抽成可重用的片段，兩個平台共用）
    private var removeDialogTitle: LocalizedStringKey { "移除插件？" }
    private var removeDialogBinding: Binding<Bool> {
        Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } })
    }
    @ViewBuilder private func removeDialogActions(_ id: String) -> some View {
        Button("移除「\(id)」", role: .destructive) {
            naki.actions.removePlugin(id)
            if selectedPluginId == id { selectedPluginId = nil }
            pendingRemoval = nil
        }
        Button("取消", role: .cancel) { pendingRemoval = nil }
    }
    private func removeDialogMessage(_ id: String) -> some View {
        Text("會刪掉 \(id) 的整個插件目錄。可重新匯入或放檔案救回。")
    }

    /// 分頁主體：macOS 用雙欄管理；iOS 改成單欄，避免橫向 iPhone 把 split view 收成空白。
    @ViewBuilder
    private var tabBody: some View {
        switch tab {
        case .plugins:
#if os(macOS)
            pluginsSplitView
#else
            iOSPluginsView
#endif
        case .log:
            ScrollView {
                VStack(spacing: 12) { diagnosticsSection; logSection }.padding()
            }
        case .trust:
            ScrollView { trustSection.padding() }
        }
    }

    private var tabPicker: some View {
        Picker("分頁", selection: $tab) {
            ForEach(PluginTab.allCases) { t in
                Label(t.title, systemImage: t.icon).tag(t)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    @ViewBuilder
    // MARK: 插件 tab — master-detail（左清單、右詳情）

    private var pluginsSplitView: some View {
        NavigationSplitView {
            List(selection: $selectedPluginId) {
                if naki.pluginDescriptors.isEmpty {
                    Text("還沒有插件。點下方「從來源加入」貼 GitHub repo / gist / URL 引入。")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Section("已安裝（\(naki.pluginDescriptors.count)）") {
                        ForEach(naki.pluginDescriptors, id: \.id) { d in
                            sidebarRow(d).tag(d.id)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 6) {
                    Divider()
                    Button { selectedPluginId = nil } label: {
                        Label("從來源加入…", systemImage: "plus.circle").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderless)
                    Button { Task { await checkUpdates() } } label: {
                        Label(updateChecking ? "檢查中…" : "檢查更新",
                              systemImage: "arrow.triangle.2.circlepath").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderless)
                    .disabled(updateChecking)
                    if let msg = importMessage {
                        Text(msg).font(.caption2).foregroundColor(.green)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(8)
                .background(.bar)
            }
        } detail: {
            if let id = selectedPluginId, let d = naki.pluginDescriptors.first(where: { $0.id == id }) {
                ScrollView { pluginDetail(d).padding() }
            } else {
                ScrollView { importSection.padding() }   // 沒選插件 → 顯示匯入面板
            }
        }
        .navigationSplitViewStyle(.balanced)
    }

#if os(iOS)
    /// iPhone 上直接把匯入、已安裝插件與插件詳情放在同一個捲動頁面。
    /// 功能與 macOS 的 master-detail 相同，但不依賴 NavigationSplitView 的欄位顯示狀態。
    private var iOSPluginsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                importSection

                if naki.pluginDescriptors.isEmpty {
                    Text("還沒有插件。可以在上方貼 GitHub repo、gist 或 plugin.json 網址引入。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    GroupBox {
                        VStack(spacing: 0) {
                            ForEach(naki.pluginDescriptors, id: \.id) { d in
                                DisclosureGroup(isExpanded: Binding(
                                    get: { selectedPluginId == d.id },
                                    set: { isExpanded in
                                        if isExpanded {
                                            selectedPluginId = d.id
                                        } else if selectedPluginId == d.id {
                                            selectedPluginId = nil
                                        }
                                    }
                                )) {
                                    pluginDetail(d)
                                        .padding(.top, 12)
                                } label: {
                                    sidebarRow(d)
                                }
                                .padding(.vertical, 8)

                                if d.id != naki.pluginDescriptors.last?.id {
                                    Divider()
                                }
                            }
                        }
                    } label: {
                        Label("已安裝（\(naki.pluginDescriptors.count)）",
                              systemImage: "puzzlepiece.extension")
                    }
                }
            }
            .padding()
        }
    }
#endif

    private func statusColor(_ d: PluginDescriptor) -> Color {
        if !d.isValid { return .red }
        return naki.settings.enabledPluginIds.contains(d.id) ? .green : .secondary
    }

    /// 左欄一列：狀態點 + 名稱 + id（緊湊，好掃）。
    @ViewBuilder
    private func sidebarRow(_ d: PluginDescriptor) -> some View {
        HStack(spacing: 8) {
            Circle().fill(statusColor(d)).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(d.manifest?.name ?? d.id).font(.callout)
                Text(d.id).font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    /// 右欄：選中插件的完整詳情（header + 操作 + 設定 + 原始碼）。
    @ViewBuilder
    private func pluginDetail(_ d: PluginDescriptor) -> some View {
        if let m = d.manifest {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(m.name).font(.title3).bold()
                    Text("\(m.id) · v\(m.version)")
                        .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        ForEach(m.capabilities, id: \.self) { cap in
                            Text(cap).font(.caption2)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.15)).clipShape(Capsule())
                        }
                        if let lic = m.license {
                            Text(lic).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    if let desc = m.description {
                        Text(desc).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Divider()

                HStack(spacing: 16) {
                    Toggle("啟用", isOn: Binding(
                        get: { naki.settings.enabledPluginIds.contains(d.id) },
                        set: { on in naki.actions.setPluginEnabled(d.id, on) }
                    ))
                    .toggleStyle(.switch)
                    .accessibilityIdentifier("plugin-toggle-\(d.id)")
                    Spacer()
                    Button(role: .destructive) { pendingRemoval = d.id } label: {
                        Label("移除", systemImage: "trash")
                    }
                    .accessibilityIdentifier("plugin-remove-\(d.id)")
                }

                if let schema = m.settings, !schema.isEmpty {
                    Divider()
                    Text("設定").font(.headline)
                    ForEach(schema.keys.sorted(), id: \.self) { key in
                        if let field = schema[key] {
                            pluginSettingControl(pluginId: d.id, key: key, field: field)
                        }
                    }
                    if !naki.settings.enabledPluginIds.contains(d.id) {
                        Text("啟用後改設定即時套用（熱重載）。")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }

                if let src = d.entrySource {
                    Divider()
                    DisclosureGroup("原始碼（\(m.entry)）") {
                        ScrollView {
                            Text(src)
                                .font(.system(.caption2, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 220)
                        .background(Color.secondary.opacity(0.08))
                    }
                    .font(.callout)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text(d.id).font(.title3).bold()
                (d.failure.map { Text(verbatim: $0.text) } ?? Text("無效插件"))
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
                Button(role: .destructive) { pendingRemoval = d.id } label: {
                    Label("移除", systemImage: "trash")
                }
            }
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

                if !pendingUpdates.isEmpty {
                    Divider()
                    Text("有 \(pendingUpdates.count) 個插件可更新——確認後才會安裝並熱重載：")
                        .font(.caption).bold()
                    ForEach(pendingUpdates) { u in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(u.id) · \(u.versionText)")
                                .font(.system(.caption, design: .monospaced))
                            if let change = u.permissionChange {
                                Text("權限變更：\(change)").font(.caption2).foregroundColor(.red)
                            } else {
                                Text("權限宣告未變").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Text("⚠️ 更新＝執行作者新寫的程式碼，等同重新信任。")
                        .font(.caption2).foregroundColor(.red)
                    HStack {
                        Button("更新這些（\(pendingUpdates.count)）") { confirmUpdates() }
                            .buttonStyle(.borderedProminent)
                        Button("取消") { pendingUpdates = [] }
                    }
                }

                if !importPreview.isEmpty {
                    Divider()
                    HStack {
                        Text("預覽 \(importPreview.count) 個——勾選要引入的：")
                            .font(.caption).bold()
                        Spacer()
                        Button(selectedImports.count == importPreview.count ? "全不選" : "全選") {
                            selectedImports = selectedImports.count == importPreview.count
                                ? [] : Set(importPreview.map { $0.id })
                        }
                        .font(.caption)
                    }
                    ForEach(importPreview, id: \.id) { p in
                        HStack(alignment: .top, spacing: 8) {
                            Toggle("", isOn: Binding(
                                get: { selectedImports.contains(p.id) },
                                set: { on in
                                    if on { selectedImports.insert(p.id) } else { selectedImports.remove(p.id) }
                                }
                            ))
                            .labelsHidden()
                            .accessibilityIdentifier("import-select-\(p.id)")

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
                        }
                        Divider()
                    }

                    Text("⚠️ 安裝＝信任作者。插件能用你的帳號送動作、讀頁面上任何資料，Naki 無法阻止。")
                        .font(.caption2).foregroundColor(.red)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack {
                        Button("引入選中的（\(selectedImports.count)）") { confirmImportSelected() }
                            .buttonStyle(.borderedProminent)
                            .disabled(selectedImports.isEmpty)
                        Button("取消") { importPreview = []; selectedImports = [] }
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
        case .success(let list):
            importPreview = list
            selectedImports = Set(list.map { $0.id })   // 預設全選（方便），使用者可取消勾
        case .failure(let e): importError = e.text
        }
    }

    private func confirmImportSelected() {
        let chosen = importPreview.filter { selectedImports.contains($0.id) }
        let failures = naki.actions.installPlugins(chosen)
        importPreview = []
        selectedImports = []
        importURL = ""
        importMessage = L10n.text("已引入 \(chosen.count - failures.count)/\(chosen.count) 個插件。在上面清單啟用（熱插拔，免重載）。")
        importError = failures.isEmpty ? nil : failures.joined(separator: "\n")
    }

    /// 第一段：只檢查、列出有新版的插件，不安裝也不熱重載。
    private func checkUpdates() async {
        updateChecking = true; importError = nil; importMessage = nil; pendingUpdates = []
        pendingUpdates = await naki.actions.checkPluginUpdates()
        updateChecking = false
        if pendingUpdates.isEmpty { importMessage = L10n.text("檢查了 \(naki.pluginDescriptors.count) 個，沒有更新。") }
    }

    /// 第二段：使用者確認後才安裝（已啟用的會熱重載）。
    private func confirmUpdates() {
        let updates = pendingUpdates
        let failures = naki.actions.installPlugins(updates.map(\.fresh))
        pendingUpdates = []
        importMessage = L10n.text("更新了 \(updates.count - failures.count)/\(updates.count) 個插件（已啟用的會熱重載）。")
        importError = failures.isEmpty ? nil : failures.joined(separator: "\n")
    }

    // MARK: 信任 / L3（分頁）

    @ViewBuilder
    private var trustSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                // L3 總開關（§8.1）：預設關。開啟＝允許插件用你的帳號送遊戲動作。
                Toggle(isOn: Binding(
                    get: { naki.settings.pluginsMayModifyOutbound },
                    // 由關轉開先確認；關掉直接生效
                    set: { on in
                        if on { confirmingOutbound = true }
                        else { naki.actions.setPluginsMayModifyOutbound(false) }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("允許插件送出遊戲動作（L3）").font(.body).bold()
                        Text("開啟後，有 injectSend/rewriteSend 能力的插件可以用你的帳號送出 Liqi request。預設關閉。只在測試帳號、且你信任插件時開。")
                            .font(.caption)
                            .foregroundColor(naki.settings.pluginsMayModifyOutbound ? .red : .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityIdentifier("plugins-may-modify-outbound-toggle")

                Divider()

                Label {
                    Text("**安裝插件＝信任其作者。** 插件與遊戲跑在同一個 JS 環境裡，惡意插件可以用你的帳號送出任何遊戲動作、讀取頁面上任何資料（含 session token），Naki **無法阻止**。只裝你信任的插件。開關即時生效、免重新載入頁面。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
        } label: {
            Label("信任邊界與 L3 權限", systemImage: "lock.shield")
        }
        .confirmationDialog("允許插件送出遊戲動作？", isPresented: $confirmingOutbound) {
            Button("開啟", role: .destructive) { naki.actions.setPluginsMayModifyOutbound(true) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("插件將能用你的帳號送出 Liqi request、改寫收到的封包。只在測試帳號、且你信任插件時開。")
        }
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
                    naki.actions.setPluginSetting(pluginId, key, v)
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
                        // NaN／Inf 存進 UserDefaults 會讓之後每次組 grant 都崩
                        guard v.isFinite else { return }
                        naki.actions.setPluginSetting(pluginId, key, v)
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
                PluginStringSettingField(
                    current: (naki.settings.pluginSettingValue(pluginId: pluginId, key: key) as? String)
                        ?? { if case .string(let s) = field.defaultValue { return s }; return "" }(),
                    commit: { v in
                        naki.actions.setPluginSetting(pluginId, key, v)
                    })
                .id("\(pluginId).\(key)")
                .frame(width: 160)
                .font(.system(.caption, design: .monospaced))
                .textFieldStyle(.roundedBorder)
            }
        }
    }

    private var diagnosticsSection: some View {
        GroupBox("目前頁面診斷") {
            VStack(alignment: .leading, spacing: 10) {
                Button("檢查 / 刷新狀態") {
                    checkingDiagnostics = true
                    Task { @MainActor in
                        defer { checkingDiagnostics = false }
                        do {
                            let result = try await naki.actions.executeJavaScript("""
                            return JSON.stringify(window.__nakiPlugins?.diagnostics?.()
                              || {error: '插件診斷尚未載入，請確認 App 版本及遊戲頁面'}, null, 2);
                            """)
                            diagnosticsText = result as? String ?? L10n.text("頁面沒有回傳診斷資料")
                        } catch { diagnosticsText = error.localizedDescription }
                    }
                }
                .disabled(checkingDiagnostics)
                Button("重新注入已啟用插件並檢查") {
                    checkingDiagnostics = true
                    Task { @MainActor in
                        defer { checkingDiagnostics = false }
                        do {
                            for descriptor in naki.pluginDescriptors where naki.settings.enabledPluginIds.contains(descriptor.id) && descriptor.isValid {
                                let overrides = descriptor.manifest?.settings.map {
                                    naki.settings.pluginSettingOverrides(pluginId: descriptor.id, keys: Array($0.keys))
                                } ?? [:]
                                if let script = PluginRegistry.enableScript(for: descriptor, overrides: overrides,
                                        mayModifyOutbound: naki.settings.pluginsMayModifyOutbound) {
                                    _ = try await naki.actions.executeJavaScript(script)
                                }
                            }
                            let result = try await naki.actions.executeJavaScript("""
                            return JSON.stringify(window.__nakiPlugins?.diagnostics?.()
                              || {error: '插件診斷尚未載入，請確認 App 版本及遊戲頁面'}, null, 2);
                            """)
                            diagnosticsText = result as? String ?? L10n.text("頁面沒有回傳診斷資料")
                        } catch { diagnosticsText = error.localizedDescription }
                    }
                }
                .disabled(checkingDiagnostics)
                Text("設定中的啟用數：\(naki.settings.enabledPluginIds.count)。下方 registered 是目前頁面實際註冊結果。")
                    .font(.caption).foregroundStyle(.secondary)
                Text(diagnosticsText)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
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

/// 字串設定欄位：提交（Return）或失焦才套用，避免每個鍵擊都熱重載＋寫 UserDefaults。
private struct PluginStringSettingField: View {
    let current: String
    let commit: (String) -> Void
    @State private var text: String
    @FocusState private var focused: Bool

    init(current: String, commit: @escaping (String) -> Void) {
        self.current = current
        self.commit = commit
        _text = State(initialValue: current)
    }

    var body: some View {
        TextField("", text: $text)
            .focused($focused)
            .onSubmit(apply)
            .onChange(of: focused) { _, isFocused in if !isFocused { apply() } }
            .onDisappear(perform: apply)
    }

    private func apply() {
        if text != current { commit(text) }
    }
}
