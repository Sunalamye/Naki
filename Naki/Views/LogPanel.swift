//
//  LogPanel.swift
//  akagi
//
//  Created by Suoie on 2025/11/30.
//  日誌面板視圖 - 顯示即時日誌
//

import SwiftUI

struct LogPanel: View {
    @State private var logManager = LogManager.shared
    @State private var autoScroll = true
    @State private var filterCategory: LogCategory? = nil
    @State private var searchText = ""

    var filteredEntries: [LogEntry] {
        var entries = logManager.entries

        // 過濾類別
        if let category = filterCategory {
            entries = entries.filter { $0.category == category }
        }

        // 搜索過濾
        if !searchText.isEmpty {
            entries = entries.filter { $0.message.localizedCaseInsensitiveContains(searchText) }
        }

        return entries
    }

    var body: some View {
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

                // 自動滾動
                Toggle(isOn: $autoScroll) {
                    Image(systemName: autoScroll ? "arrow.down.circle.fill" : "arrow.down.circle")
                }
                .toggleStyle(.button)
                .help("自動滾動到最新")

                // 清除按鈕
                Button(action: { logManager.clear() }) {
                    Image(systemName: "trash")
                }
                .help("清除日誌")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // 搜索框
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("搜索...", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(6)
            .background(Color(NSColor.textBackgroundColor))

            Divider()

            // 日誌列表
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(filteredEntries) { entry in
                            LogEntryRow(entry: entry)
                                .id(entry.id)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
                .onChange(of: logManager.entries.count) {
                    if autoScroll, let last = filteredEntries.last {
                        withAnimation {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .background(Color(NSColor.textBackgroundColor))
    }
}

struct LogEntryRow: View {
    let entry: LogEntry

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            // 時間戳
            Text(entry.formattedTime)
                .font(.system(.caption2, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 70, alignment: .leading)

            // 類別標籤
            Text(entry.category.rawValue)
                .font(.system(.caption2, design: .monospaced))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(categoryColor.opacity(0.2))
                .foregroundColor(categoryColor)
                .cornerRadius(3)
                .frame(width: 45)

            // 消息內容
            Text(entry.message)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.primary)
                .lineLimit(3)
                .textSelection(.enabled)

            Spacer()
        }
        .padding(.vertical, 2)
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
