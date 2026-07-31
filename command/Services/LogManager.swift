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
    ///
    /// 500 條在真實對局下只夠涵蓋十幾秒（單一摸打就會產生數十行 parser 記錄），
    /// 事後回查「上一局為什麼這樣打」時早就被輪掉了。檔案日誌才是完整紀錄，
    /// 記憶體這份僅供 UI 即時顯示與 `/logs` 快取。
    var maxEntries = 5000

    /// 是否啟用文件日誌
    var fileLoggingEnabled = true

    /// 文件日誌路徑
    private let logFile: URL
    private var fileHandle: FileHandle?

    /// 專用序列佇列：序列化所有檔案寫入。
    /// log() 可能被任意執行緒（off-main 的 botLog / bridgeLog 等）呼叫，
    /// 單一 FileHandle 併發 seek+write 並不安全，這裡用 serial queue 保證順序與資料完整。
    private let fileWriteQueue = DispatchQueue(label: "com.naki.LogManager.fileWrite")

    /// 檔案日誌路徑（對外公開，方便從 `/status` 或除錯時直接開檔查）
    var logFilePath: String { logFile.path }

    /// 保留幾份歷史日誌（不含當前這份）
    private let rotationKeepCount = 5

    private init() {
        let dir = FileManager.default.temporaryDirectory
        logFile = dir.appendingPathComponent("akagi_websocket.log")

        // 啟動時輪替而非覆寫。
        //
        // 舊行為是每次啟動就 createFile 把檔案清空，於是「重啟前發生了什麼」永遠查不到——
        // 偏偏跨重啟的問題（重連後 Bot 狀態是否正確）正是最需要回溯的。
        // 改為把上一份改名保留，最多留 rotationKeepCount 份。
        let fm = FileManager.default
        if fm.fileExists(atPath: logFile.path) {
            let oldest = dir.appendingPathComponent("akagi_websocket.log.\(rotationKeepCount)")
            try? fm.removeItem(at: oldest)
            for i in stride(from: rotationKeepCount - 1, through: 1, by: -1) {
                let from = dir.appendingPathComponent("akagi_websocket.log.\(i)")
                let to = dir.appendingPathComponent("akagi_websocket.log.\(i + 1)")
                if fm.fileExists(atPath: from.path) {
                    try? fm.removeItem(at: to)
                    try? fm.moveItem(at: from, to: to)
                }
            }
            let first = dir.appendingPathComponent("akagi_websocket.log.1")
            try? fm.removeItem(at: first)
            try? fm.moveItem(at: logFile, to: first)
        }

        fm.createFile(atPath: logFile.path, contents: nil)
        fileHandle = try? FileHandle(forWritingTo: logFile)
    }

    deinit {
        // 關閉 FileHandle（先等排入佇列的寫入完成，避免關閉時仍有 in-flight 寫入）
        let handle = fileHandle
        fileWriteQueue.sync {
            try? handle?.close()
        }
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

    /// 寫入文件（透過 serial queue 序列化，避免多執行緒共用單一 FileHandle 造成資料競爭）
    private func writeToFile(_ entry: LogEntry) {
        let line = "[\(ISO8601DateFormatter().string(from: entry.timestamp))] [\(entry.category.rawValue)] \(entry.message)\n"
        guard let data = line.data(using: .utf8) else { return }
        fileWriteQueue.async { [weak self] in
            guard let handle = self?.fileHandle else { return }
            handle.seekToEndOfFile()
            handle.write(data)
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
