//
//  LogManager.swift
//  akagi
//
//  Created by Suoie on 2025/11/30.
//  統一的日誌管理器 - 提供 UI 顯示和文件記錄
//

import Foundation

/// 日誌條目
struct LogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let category: LogCategory
    let message: String

    var formattedTime: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: timestamp)
    }
}

/// 日誌類別
enum LogCategory: String, CaseIterable {
    case ws = "WS"
    case liqi = "Liqi"
    case mjai = "MJAI"
    case bridge = "Bridge"
    case bot = "Bot"
    case system = "System"

    var color: String {
        switch self {
        case .ws: return "blue"
        case .liqi: return "purple"
        case .mjai: return "green"
        case .bridge: return "orange"
        case .bot: return "red"
        case .system: return "gray"
        }
    }
}

/// 日誌管理器（單例）
@Observable
class LogManager {
    static let shared = LogManager()

    /// 日誌條目列表
    var entries: [LogEntry] = []

    /// 最大日誌條目數
    var maxEntries = 500

    /// 是否啟用文件日誌
    var fileLoggingEnabled = true

    /// 文件日誌路徑
    private let logFile: URL
    private var fileHandle: FileHandle?

    private init() {
        logFile = FileManager.default.temporaryDirectory.appendingPathComponent("akagi_websocket.log")

        // 嘗試開啟文件
        FileManager.default.createFile(atPath: logFile.path, contents: nil)
        fileHandle = try? FileHandle(forWritingTo: logFile)
    }

    /// 添加日誌
    func log(_ message: String, category: LogCategory = .system) {
        let entry = LogEntry(timestamp: Date(), category: category, message: message)

        // 在主線程更新 UI
        DispatchQueue.main.async {
            self.entries.append(entry)

            // 限制條目數量
            if self.entries.count > self.maxEntries {
                self.entries.removeFirst(self.entries.count - self.maxEntries)
            }
        }

        // 寫入文件
        if fileLoggingEnabled {
            writeToFile(entry)
        }

        // 也輸出到控制台
        print("[\(entry.formattedTime)] [\(category.rawValue)] \(message)")
    }

    /// 清空日誌
    func clear() {
        DispatchQueue.main.async {
            self.entries.removeAll()
        }
    }

    /// 寫入文件
    private func writeToFile(_ entry: LogEntry) {
        let line = "[\(ISO8601DateFormatter().string(from: entry.timestamp))] [\(entry.category.rawValue)] \(entry.message)\n"
        if let data = line.data(using: .utf8) {
            fileHandle?.seekToEndOfFile()
            fileHandle?.write(data)
        }
    }
}

// MARK: - 全局日誌函數

/// WebSocket 日誌
func wsLog(_ message: String) {
    LogManager.shared.log(message, category: .ws)
}

/// Liqi 協議日誌
func liqiLog(_ message: String) {
    LogManager.shared.log(message, category: .liqi)
}

/// MJAI 事件日誌
func mjaiLog(_ message: String) {
    LogManager.shared.log(message, category: .mjai)
}

/// 橋接器日誌
func bridgeLog(_ message: String) {
    LogManager.shared.log(message, category: .bridge)
}

/// Bot 日誌
func botLog(_ message: String) {
    LogManager.shared.log(message, category: .bot)
}

/// 系統日誌
func systemLog(_ message: String) {
    LogManager.shared.log(message, category: .system)
}
