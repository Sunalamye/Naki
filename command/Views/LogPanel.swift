//
//  LogPanel.swift
//  Naki
//
//  Created by Suoie on 2025/11/30.
//  日誌面板視圖 - 顯示即時日誌
//

import SwiftUI

struct LogPanel: View {
    private let logManager = LogManager.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var autoScroll = true
    @State private var filterCategory: LogCategory? = nil
    @State private var searchText = ""

    var body: some View {
        let shown = logManager.recentEntries(category: filterCategory, search: searchText, limit: .max)
        VStack(spacing: 0) {
            // 工具欄
            HStack(spacing: 8) {
                Image(systemName: "list.bullet.rectangle")
                Text("Log")
                    .font(.headline)

                Spacer()

                // 類別過濾
                Picker("", selection: $filterCategory) {
                    Text("全部").tag(nil as LogCategory?)
                    ForEach(LogCategory.allCases, id: \.self) { category in
                        Text(category.rawValue).tag(category as LogCategory?)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 80)
                .accessibilityIdentifier("log-category-picker")
                .accessibilityLabel("日誌分類")

                // 自動滾動
                Toggle("自動捲動",
                       systemImage: autoScroll ? "arrow.down.circle.fill" : "arrow.down.circle",
                       isOn: $autoScroll)
                    .labelStyle(.iconOnly)
                    .toggleStyle(.button)
                .accessibilityIdentifier("log-autoscroll-toggle")
                .accessibilityValue(autoScroll ? Text("開") : Text("關"))
                #if os(macOS)
                .help("自動滾動到最新")
                #endif

                // 清除按鈕
                Button("清除日誌", systemImage: "trash") { logManager.clear() }
                    .labelStyle(.iconOnly)
                .accessibilityIdentifier("log-clear-button")
                #if os(macOS)
                .help("清除日誌")
                #endif
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.contentBackground)

            Divider()

            // 搜尋框
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜尋…", text: $searchText)
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier("log-search-field")
                if !searchText.isEmpty {
                    Button("清除搜尋", systemImage: "xmark.circle.fill") { searchText = "" }
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.secondary)
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("log-clear-search-button")
                }
            }
            .padding(6)
            .background(Color.textFieldBackground)

            Divider()

            // 日誌列表
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(shown) { entry in
                            LogEntryRow(entry: entry)
                                .id(entry.id)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
                // 觀察最後一筆的 id 而非 count：滿 `maxEntries` 後 count 恆定，只有 last.id 會變
                .onChange(of: shown.last?.id) { _, lastID in
                    guard autoScroll, let lastID else { return }
                    if reduceMotion {
                        proxy.scrollTo(lastID, anchor: .bottom)
                    } else {
                        withAnimation { proxy.scrollTo(lastID, anchor: .bottom) }
                    }
                }
            }
        }
        .background(Color.textFieldBackground)
    }
}

struct LogEntryRow: View {
    let entry: LogEntry

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            // 時間戳
            Text(entry.formattedTime)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()

            // 類別標籤
            Text(entry.category.rawValue)
                .font(.system(.caption2, design: .monospaced))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(categoryColor.opacity(0.2))
                .foregroundStyle(categoryColor)
                .clipShape(.rect(cornerRadius: 3))
                .lineLimit(1)
                .fixedSize()

            // 消息內容
            Text(entry.message)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(3)
                .textSelection(.enabled)

            Spacer()
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var categoryColor: Color {
        switch entry.category {
        case .ws: return .blue
        case .liqi: return .purple
        case .mjai: return .green
        case .bridge: return .orange
        case .bot: return .red
        case .system: return .gray
        }
    }
}

#Preview {
    LogPanel()
        .frame(width: 400, height: 300)
}
