//
//  MajsoulConnectionSettingsBox.swift
//  Naki
//
//  設定「連線」頁的「雀魂連線」區：自訂 User-Agent 與額外請求 header。
//

import SwiftUI

struct MajsoulConnectionSettingsBox: View {

    @Environment(\.naki) private var naki

    struct HeaderRow: Identifiable {
        let id = UUID()
        var name: String
        var value: String
    }

    static func rows(from headers: [String: String]) -> [HeaderRow] {
        headers.sorted { $0.key < $1.key }.map { HeaderRow(name: $0.key, value: $0.value) }
    }

    /// 編輯中的草稿，由設定根 View 持有（切頁不丟）；按「套用並重新載入」才寫回設定。
    @Binding var rows: [HeaderRow]
    @State private var defaultUserAgent: String?

    var body: some View {
        @Bindable var settings = naki.settings

        GroupBox {
            VStack(alignment: .leading, spacing: PanelLayout.Spacing.s8) {
                HStack {
                    TextField(text: $settings.majsoulUserAgent,
                              prompt: defaultUserAgent.map { Text(verbatim: $0) } ?? Text("預設（WebKit）")) {
                        Text(verbatim: "User-Agent")
                    }
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .help(settings.majsoulUserAgent.isEmpty ? (defaultUserAgent ?? "") : settings.majsoulUserAgent)
                        .accessibilityIdentifier("majsoul-user-agent-field")
                    Button("還原預設") { settings.majsoulUserAgent = "" }
                        .disabled(settings.majsoulUserAgent.isEmpty)
                }

                ForEach($rows) { $row in
                    headerRow($row)
                }

                HStack {
                    Button("新增 Header", systemImage: "plus") {
                        rows.append(HeaderRow(name: "", value: ""))
                    }
                    .accessibilityIdentifier("add-majsoul-header-button")
                    Spacer()
                    Button("套用並重新載入") {
                        naki.actions.connectionSettings.apply(headers: rows.map { ($0.name, $0.value) })
                    }
                        .accessibilityIdentifier("apply-majsoul-connection-button")
                }

                Text("額外 Header 只用於主頁面，User-Agent 用於全部請求")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("套用時會重新載入，對局中別套用")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } label: {
            Label("雀魂連線", systemImage: "network")
        }
        .task {
            defaultUserAgent = await naki.actions.connectionSettings.defaultUserAgent()
        }
    }

    private func headerRow(_ row: Binding<HeaderRow>) -> some View {
        VStack(alignment: .leading, spacing: PanelLayout.Spacing.s2) {
            HStack {
                TextField("Header 名稱", text: row.name)
                    .labelsHidden()
                    .accessibilityIdentifier("majsoul-header-name-field")
                    .autocorrectionDisabled()
                    .frame(maxWidth: 160)
                TextField("Header 值", text: row.value)
                    .labelsHidden()
                    .autocorrectionDisabled()
                Button("刪除 Header", systemImage: "minus.circle") {
                    rows.removeAll { $0.id == row.wrappedValue.id }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
            }
            .textFieldStyle(.roundedBorder)

            if let issue = issue(of: row.wrappedValue) {
                issueText(issue)
                    .font(.caption)
                    .foregroundStyle(PanelLayout.danger)
            }
        }
    }

    private func issue(of row: HeaderRow) -> MajsoulRequestBuilder.HeaderIssue? {
        guard !row.name.isEmpty || !row.value.isEmpty else { return nil }
        return MajsoulRequestBuilder.issue(name: row.name, value: row.value)
    }

    private func issueText(_ issue: MajsoulRequestBuilder.HeaderIssue) -> Text {
        switch issue {
        case .invalidName: Text("名稱不合法：不可為空，也不可含空白、冒號或換行。")
        case .reservedName: Text("此名稱由系統保留，不會送出。")
        case .invalidValue: Text("值不可為空或含換行。")
        }
    }
}
