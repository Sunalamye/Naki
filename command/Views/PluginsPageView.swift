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
/// log 即時性：`naki.logManager` 是 `@Observable`，body 直接讀它的 `entries`
/// ⇒ 有新 log 進來就自動重繪（不必自己輪詢）。
struct PluginsPageView: View {
    @Environment(\.naki) private var naki
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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

    @State private var removal = RemovalConfirm()
    @State private var diagnostics: PluginDiagnostics?
    @State private var checkingDiagnostics = false
    @State private var tab: PluginTab = .plugins
    @State private var selectedPluginId: String?   // master-detail 選中的插件

    /// 分頁：把紀錄與權限分出去，插件管理不再和 log 擠一起。
    enum PluginTab: String, CaseIterable, Identifiable {
        case plugins = "插件"
        case log = "紀錄"
        case trust = "權限"
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
            HStack(spacing: PanelLayout.Spacing.s12) {
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
        }
        #endif
    }

    /// 「移除」原地變成確認列；有效與無效插件共用。
    private func removeControl(_ id: String) -> some View {
        let armed = removal.pending == id
        return VStack(alignment: .trailing, spacing: PanelLayout.Spacing.s4) {
            HStack(spacing: PanelLayout.Spacing.s8) {
                if armed {
                    Button("取消", role: .cancel) { removal.cancel() }
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("plugin-remove-cancel-\(id)")
                    Button("移除「\(id)」", role: .destructive) { confirmRemoval(id) }
                        .accessibilityIdentifier("plugin-remove-confirm-\(id)")
                } else {
                    Button(role: .destructive) { removal.arm(id, now: .now) } label: {
                        Label("移除", systemImage: "trash")
                    }
                    .accessibilityIdentifier("plugin-remove-\(id)")
                }
            }
            if armed {
                Text("會刪掉 \(id) 的整個插件目錄。可重新匯入或放檔案救回。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .animation(PanelLayout.animation(armed ? PanelLayout.valueChange : PanelLayout.exit,
                                         reduceMotion: reduceMotion), value: armed)
    }

    private func confirmRemoval(_ id: String) {
        guard removal.confirm(id, now: .now) else { return }
        withAnimation(PanelLayout.animation(PanelLayout.valueChange, reduceMotion: reduceMotion)) {
            naki.actions.removePlugin(id)
        }
        if selectedPluginId == id { selectedPluginId = nil }
    }

    /// 分頁主體：macOS 用雙欄管理；iOS 改成單欄，避免橫向 iPhone 把 split view 收成空白。
    /// 移除確認面在這裡逾時退回、換插件或換分頁即收起；離開頁面時 @State 隨 sheet 消失。
    private var tabBody: some View {
        Group { tabContent }
            .task(id: removal) {
                guard let id = removal.pending else { return }
                do { try await Task.sleep(for: RemovalConfirm.timeout) } catch { return }
                removal.expire(id)
            }
            .onChange(of: selectedPluginId) { _, id in removal.switchTarget(id) }
            .onChange(of: tab) { removal.cancel() }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch tab {
        case .plugins:
#if os(macOS)
            pluginsSplitView
#else
            iOSPluginsView
#endif
        case .log:
            ScrollView {
                VStack(spacing: PanelLayout.Spacing.s12) { diagnosticsSection; logSection }.padding()
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
                VStack(spacing: PanelLayout.Spacing.s6) {
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
                        Text(msg).font(.caption2).foregroundStyle(PanelLayout.success)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(PanelLayout.Spacing.s8)
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
            VStack(alignment: .leading, spacing: PanelLayout.Spacing.s16) {
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
                                        .padding(.top, PanelLayout.Spacing.s12)
                                } label: {
                                    sidebarRow(d)
                                }
                                .padding(.vertical, PanelLayout.Spacing.s8)

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

    private func status(_ d: PluginDescriptor) -> (symbol: String, color: Color, label: LocalizedStringKey) {
        if !d.isValid { return ("exclamationmark.triangle.fill", PanelLayout.danger, "無效插件") }
        return naki.settings.enabledPluginIds.contains(d.id)
            ? ("checkmark.circle.fill", PanelLayout.success, "已啟用")
            : ("circle", .secondary, "未啟用")
    }

    /// 左欄一列：狀態點 + 名稱 + id（緊湊，好掃）。
    private func sidebarRow(_ d: PluginDescriptor) -> some View {
        let status = status(d)
        return HStack(spacing: PanelLayout.Spacing.s8) {
            Image(systemName: status.symbol)
                .foregroundStyle(status.color)
                .imageScale(.small)
                .accessibilityLabel(status.label)
            VStack(alignment: .leading, spacing: PanelLayout.Spacing.s2) {
                Text(d.manifest?.name ?? d.id).font(.callout)
                Text(d.id).font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, PanelLayout.Spacing.s2)
    }

    /// 右欄：選中插件的完整詳情（header + 操作 + 設定 + 原始碼）。
    @ViewBuilder
    private func pluginDetail(_ d: PluginDescriptor) -> some View {
        if let m = d.manifest {
            VStack(alignment: .leading, spacing: PanelLayout.Spacing.s16) {
                VStack(alignment: .leading, spacing: PanelLayout.Spacing.s4) {
                    Text(m.name).font(.title3).bold()
                    Text("\(m.id) · v\(m.version)")
                        .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    HStack(spacing: PanelLayout.Spacing.s6) {
                        ForEach(m.capabilities, id: \.self) { cap in
                            Text(cap).font(.caption2)
                                .padding(.horizontal, PanelLayout.Spacing.s6).padding(.vertical, PanelLayout.Spacing.s2)
                                .background(Color.secondary.opacity(PanelLayout.Opacity.tint)).clipShape(Capsule())
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

                HStack(spacing: PanelLayout.Spacing.s16) {
                    Toggle("啟用", isOn: Binding(
                        get: { naki.settings.enabledPluginIds.contains(d.id) },
                        set: { on in naki.actions.setPluginEnabled(d.id, on) }
                    ))
                    .toggleStyle(.switch)
                    .accessibilityIdentifier("plugin-toggle-\(d.id)")
                    Spacer()
                    removeControl(d.id)
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
                        .background(Color.secondary.opacity(PanelLayout.Opacity.subtle))
                    }
                    .font(.callout)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: PanelLayout.Spacing.s10) {
                Text(d.id).font(.title3).bold()
                (d.failure.map { Text(verbatim: $0.text) } ?? Text("無效插件"))
                    .foregroundStyle(PanelLayout.danger)
                    .fixedSize(horizontal: false, vertical: true)
                removeControl(d.id)
            }
        }
    }

    // MARK: 從 URL 匯入（§6.5）

    @ViewBuilder
    private var importSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: PanelLayout.Spacing.s8) {
                Text("貼 **GitHub repo**（`owner/repo`，一次多個插件）、gist 連結、或任意 HTTPS 的 plugin.json。只抓一次、預覽確認後才落地。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    TextField("Sunalamye/naki-plugins 或 gist / plugin.json 網址", text: $importURL)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.caption, design: .monospaced))
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("plugin-import-url")
                    Button(importing ? "預覽中…" : "預覽") { Task { await fetchImport() } }
                        .disabled(importing || importURL.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button(updateChecking ? "檢查中…" : "檢查更新") { Task { await checkUpdates() } }
                        .disabled(updateChecking)
                        .help("對每個已裝插件重抓來源，比對內容有沒有變")
                }

                if let err = importError {
                    Text("匯入失敗：\(err)").font(.caption).foregroundStyle(PanelLayout.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let msg = importMessage {
                    Text(msg).font(.caption).foregroundStyle(PanelLayout.success)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !pendingUpdates.isEmpty {
                    Divider()
                    Text("有 \(pendingUpdates.count) 個插件可更新——確認後才會安裝並熱重載：")
                        .font(.caption).bold()
                    ForEach(pendingUpdates) { u in
                        VStack(alignment: .leading, spacing: PanelLayout.Spacing.s2) {
                            Text("\(u.id) · \(u.versionText)")
                                .font(.system(.caption, design: .monospaced))
                            if let change = u.permissionChange {
                                Text("權限變更：\(change)").font(.caption2).foregroundStyle(PanelLayout.danger)
                            } else {
                                Text("權限宣告未變").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Text("⚠️ 更新＝執行作者新寫的程式碼，等同重新信任。")
                        .font(.caption2).foregroundStyle(PanelLayout.danger)
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
                        HStack(alignment: .top, spacing: PanelLayout.Spacing.s8) {
                            Toggle(p.manifest.name, isOn: Binding(
                                get: { selectedImports.contains(p.id) },
                                set: { on in
                                    if on { selectedImports.insert(p.id) } else { selectedImports.remove(p.id) }
                                }
                            ))
                            .labelsHidden()
                            .accessibilityIdentifier("import-select-\(p.id)")

                            VStack(alignment: .leading, spacing: PanelLayout.Spacing.s4) {
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
                                    .background(Color.secondary.opacity(PanelLayout.Opacity.subtle))
                                }
                                .font(.caption2)
                            }
                        }
                        Divider()
                    }

                    Text("⚠️ 安裝＝信任作者。插件能用你的帳號送動作、讀頁面上任何資料，Naki 無法阻止。")
                        .font(.caption2).foregroundStyle(PanelLayout.danger)
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
        let result = await naki.actions.fetchPluginImport(urlString: importURL)
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
            VStack(alignment: .leading, spacing: PanelLayout.Spacing.s10) {
                // L3 總開關（§8.1）：預設關。開啟＝允許插件用你的帳號送遊戲動作。
                Toggle(isOn: Binding(
                    get: { naki.settings.pluginsMayModifyOutbound },
                    // 由關轉開先確認；關掉直接生效
                    set: { on in
                        if on { confirmingOutbound = true }
                        else { naki.actions.setPluginsMayModifyOutbound(false) }
                    }
                )) {
                    VStack(alignment: .leading, spacing: PanelLayout.Spacing.s2) {
                        Text("允許插件送出遊戲動作（L3）").font(.body).bold()
                        Text("開啟後，有 injectSend/rewriteSend 能力的插件可以用你的帳號送出 Liqi request。預設關閉。只在測試帳號、且你信任插件時開。")
                            .font(.caption)
                            .foregroundStyle(naki.settings.pluginsMayModifyOutbound ? PanelLayout.danger : PanelLayout.neutral)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityIdentifier("plugins-may-modify-outbound-toggle")

                Divider()

                Label {
                    Text("**安裝插件＝信任其作者。** 插件與遊戲跑在同一個 JS 環境裡，惡意插件可以用你的帳號送出任何遊戲動作、讀取頁面上任何資料（含 session token），Naki **無法阻止**。只裝你信任的插件。開關即時生效、免重新載入頁面。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(PanelLayout.warning)
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
                TextField(label, value: Binding(
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
                .labelsHidden()
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
                    label: label,
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
            VStack(alignment: .leading, spacing: PanelLayout.Spacing.s10) {
                Button("檢查 / 刷新狀態") { runDiagnostics(reinject: false) }
                    .disabled(checkingDiagnostics)
                Button("重新注入已啟用插件並檢查") { runDiagnostics(reinject: true) }
                    .disabled(checkingDiagnostics)
                Text("設定中的啟用數：\(naki.settings.enabledPluginIds.count)。下方 registered 是目前頁面實際註冊結果。")
                    .font(.caption).foregroundStyle(.secondary)
                diagnosticsBody
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var diagnosticsBody: Text {
        switch diagnostics {
        case nil: Text("尚未檢查目前遊戲頁面")
        case .noData: Text("頁面沒有回傳診斷資料")
        case .report(let text), .failed(let text): Text(verbatim: text)
        }
    }

    private func runDiagnostics(reinject: Bool) {
        checkingDiagnostics = true
        Task {
            diagnostics = await naki.actions.pluginDiagnostics(reinject: reinject)
            checkingDiagnostics = false
        }
    }

    // MARK: 即時 log

    /// 由新往舊掃，湊滿 300 筆就停：緩衝最多數千筆，body 每次重繪都會跑。
    private func recentPluginLogs() -> [LogEntry] {
        Array(naki.logManager.entries.reversed().lazy
            .filter { $0.message.contains("[Plugin]") }
            .prefix(300).reversed())
    }

    private var logSection: some View {
        GroupBox {
            let entries = recentPluginLogs()
            VStack(alignment: .leading, spacing: PanelLayout.Spacing.s6) {
                if entries.isEmpty {
                    Text("還沒有插件 log。啟用一個插件、進一局後，它經 ctx.log 送出的訊息會即時出現在這裡。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: PanelLayout.Spacing.s2) {
                            ForEach(entries) { entry in
                                Text(verbatim: "\(entry.formattedTime) \(entry.message)")
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
    let label: String
    let current: String
    let commit: (String) -> Void
    @State private var text: String
    @FocusState private var focused: Bool

    init(label: String, current: String, commit: @escaping (String) -> Void) {
        self.label = label
        self.current = current
        self.commit = commit
        _text = State(initialValue: current)
    }

    var body: some View {
        TextField(label, text: $text)
            .labelsHidden()
            .focused($focused)
            .onSubmit(apply)
            .onChange(of: focused) { _, isFocused in if !isFocused { apply() } }
            .onDisappear(perform: apply)
    }

    private func apply() {
        if text != current { commit(text) }
    }
}

/// 移除確認面只屬於一個插件 id；出現後 `guardInterval` 內的確認不算數（防雙擊）。
nonisolated struct RemovalConfirm: Equatable {
    static let guardInterval: TimeInterval = 0.28
    static let timeout: Duration = .seconds(4)

    private(set) var pending: String?
    private var armedAt: Date?

    mutating func arm(_ id: String, now: Date) {
        pending = id
        armedAt = now
    }

    /// 回 true 才可刪，同時收起確認面。
    mutating func confirm(_ id: String, now: Date) -> Bool {
        guard pending == id, let armedAt, now.timeIntervalSince(armedAt) >= Self.guardInterval else { return false }
        cancel()
        return true
    }

    mutating func cancel() {
        pending = nil
        armedAt = nil
    }

    mutating func expire(_ id: String) {
        if pending == id { cancel() }
    }

    mutating func switchTarget(_ id: String?) {
        if pending != id { cancel() }
    }
}
