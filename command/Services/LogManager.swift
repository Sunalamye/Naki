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
    let level: LogLevel
    let message: String

    var formattedTime: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: timestamp)
    }
}

/// 日誌等級
///
/// 分級的目的只有一個：**讓「這局發生了什麼」可以一眼看完**。
///
/// 先前所有東西都寫進同一個檔，而 LiqiParser 每解一個 protobuf 欄位就寫一行——
/// 單一摸打會產生數十行 `field 1, wireType 0, size 1`，把真正的事件淹掉。
/// 實測要靠 grep 才找得到「有沒有出現過和牌機會」。
enum LogLevel: Int, Comparable, CaseIterable {
    /// 解析內部細節。量極大，只寫進該類別自己的檔案
    case trace = 0
    /// 一般訊息
    case info = 1
    /// 對局時間軸上的事件：MJAI 事件、oplist 變化、決策、送出結果。
    /// 這一級會另外寫進 `naki-events.log`
    case event = 2

    static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    var tag: String {
        switch self {
        case .trace: return "·"
        case .info: return " "
        case .event: return "▸"
        }
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

    /// 合併日誌（不含 trace，避免被解析細節淹沒）
    private let logFile: URL
    private var fileHandle: FileHandle?

    /// 對局事件時間軸——只有 `.event`，這是要用眼睛讀的那份
    private let eventFile: URL
    private var eventHandle: FileHandle?

    /// 每個類別各自一份完整紀錄（含 trace），深入除錯時才看
    private var categoryHandles: [LogCategory: FileHandle] = [:]

    /// 是否把 trace 寫進各類別檔案（量很大，可關）
    var traceToCategoryFiles = true

    /// 專用序列佇列：序列化所有檔案寫入。
    /// log() 可能被任意執行緒（off-main 的 botLog / bridgeLog 等）呼叫，
    /// 單一 FileHandle 併發 seek+write 並不安全，這裡用 serial queue 保證順序與資料完整。
    private let fileWriteQueue = DispatchQueue(label: "com.naki.LogManager.fileWrite")

    /// 檔案日誌路徑（對外公開，方便從 `/status` 或除錯時直接開檔查）
    var logFilePath: String { logFile.path }

    /// 對局事件時間軸的路徑——查「剛剛發生什麼」看這個
    var eventLogPath: String { eventFile.path }

    /// 各類別日誌的路徑
    var categoryLogPaths: [String: String] {
        var m: [String: String] = [:]
        for c in LogCategory.allCases {
            m[c.rawValue] = logDirectory.appendingPathComponent("naki-\(c.rawValue.lowercased()).log").path
        }
        return m
    }

    private let logDirectory: URL

    /// 保留幾份歷史日誌（不含當前這份）
    private let rotationKeepCount = 5

    private init() {
        let dir = FileManager.default.temporaryDirectory
        logDirectory = dir
        logFile = dir.appendingPathComponent("akagi_websocket.log")
        eventFile = dir.appendingPathComponent("naki-events.log")

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

        // 事件時間軸與各類別檔案：每次啟動重建（合併檔已負責跨啟動保留）
        fm.createFile(atPath: eventFile.path, contents: nil)
        eventHandle = try? FileHandle(forWritingTo: eventFile)

        for c in LogCategory.allCases {
            let url = dir.appendingPathComponent("naki-\(c.rawValue.lowercased()).log")
            fm.createFile(atPath: url.path, contents: nil)
            categoryHandles[c] = try? FileHandle(forWritingTo: url)
        }
    }

    deinit {
        // 關閉 FileHandle（先等排入佇列的寫入完成，避免關閉時仍有 in-flight 寫入）
        let handles: [FileHandle] =
            [fileHandle, eventHandle].compactMap { $0 } + Array(categoryHandles.values)
        fileWriteQueue.sync {
            handles.forEach { try? $0.close() }
        }
    }

    /// 添加日誌
    func log(_ message: String, category: LogCategory = .system, level: LogLevel = .info) {
        let entry = LogEntry(timestamp: Date(), category: category, level: level, message: message)

        // UI 只顯示 info 以上——trace 是給檔案看的
        if level >= .info {
            DispatchQueue.main.async {
                self.entries.append(entry)

                if self.entries.count > self.maxEntries {
                    self.entries.removeFirst(self.entries.count - self.maxEntries)
                }
            }
        }

        if fileLoggingEnabled {
            writeToFile(entry)
        }

        // 控制台只印 info 以上，否則 Xcode console 也會被 trace 淹掉
        if level >= .info {
            print("[\(entry.formattedTime)] \(level.tag) [\(category.rawValue)] \(message)")
        }
    }

    /// 清空日誌
    func clear() {
        DispatchQueue.main.async {
            self.entries.removeAll()
        }
    }

    /// 寫入文件（透過 serial queue 序列化，避免多執行緒共用單一 FileHandle 造成資料競爭）
    private func writeToFile(_ entry: LogEntry) {
        let ts = ISO8601DateFormatter().string(from: entry.timestamp)
        let line = "[\(ts)] [\(entry.category.rawValue)] \(entry.message)\n"
        guard let data = line.data(using: .utf8) else { return }

        // 事件檔用簡短時間，因為那是要一行行讀的
        let eventLine = "\(entry.formattedTime) [\(entry.category.rawValue)] \(entry.message)\n"
        let eventData = eventLine.data(using: .utf8)

        let level = entry.level
        let category = entry.category
        let writeTrace = traceToCategoryFiles

        fileWriteQueue.async { [weak self] in
            guard let self else { return }

            // 合併檔：排除 trace，否則事件會被解析細節淹沒
            if level >= .info, let h = self.fileHandle {
                h.seekToEndOfFile(); h.write(data)
            }
            // 事件時間軸
            if level == .event, let d = eventData, let h = self.eventHandle {
                h.seekToEndOfFile(); h.write(d)
            }
            // 各類別檔案：完整保留
            if level >= .info || writeTrace, let h = self.categoryHandles[category] {
                h.seekToEndOfFile(); h.write(data)
            }
        }
    }
}

// MARK: - 全局日誌函數

/// WebSocket 日誌
func wsLog(_ message: String, level: LogLevel = .info) {
    LogManager.shared.log(message, category: .ws, level: level)
}

/// Liqi 協議日誌
func liqiLog(_ message: String, level: LogLevel = .trace) {
    LogManager.shared.log(message, category: .liqi, level: level)
}

/// MJAI 事件日誌
func mjaiLog(_ message: String, level: LogLevel = .event) {
    LogManager.shared.log(message, category: .mjai, level: level)
}

/// 橋接器日誌
func bridgeLog(_ message: String, level: LogLevel = .info) {
    LogManager.shared.log(message, category: .bridge, level: level)
}

/// Bot 日誌
func botLog(_ message: String, level: LogLevel = .info) {
    LogManager.shared.log(message, category: .bot, level: level)
}

/// 系統日誌
/// 對局時間軸事件——會另外寫進 naki-events.log
func eventLog(_ message: String, category: LogCategory = .bridge) {
    LogManager.shared.log(message, category: category, level: .event)
}

func systemLog(_ message: String) {
    LogManager.shared.log(message, category: .system)
}
