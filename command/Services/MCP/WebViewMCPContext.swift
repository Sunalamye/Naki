//
//  WebViewMCPContext.swift
//  Naki
//
//  MCPKit `MCPContext` 的回調式實作：把 WKWebView 的 completion-handler JS 執行
//  橋接成 async/await，並在沒有外部 log 回調時提供一個有上限的記憶體 buffer。
//
//  來源：Sunalamye/MCPWebKit 0.3.0 的同名型別，2026-08-02 內聯進 Naki。
//  Naki 對那個套件的全部用量就是這一個 class，而它又把 WebViewBridge 當傳遞依賴
//  拖進 Package.resolved——為了一個 class 綁兩個遠端套件不划算。現在 Naki 只留
//  MCPKit（MCPContext／MCPTool／MCPToolRegistry 這一層型別仍來自那裡）。
//
//  與上游唯一的差異：上游還有 `getCustomStatusCallback` / `getCustomStatus()`，
//  那是給該套件自己的 built-in tools 用的；Naki 的 `system_get_status` 走
//  `SystemTools` + `DefaultNakiMCPContext` 的回調，從來沒呼叫過，所以不複製過來。
//

import Foundation
import MCPKit

// MARK: - WebView MCP Context

/// WebView 專用的 MCP 上下文實作
/// 提供 JavaScript 執行與日誌功能
@MainActor
final class WebViewMCPContext: MCPContext {

    // MARK: - Properties

    var serverPort: UInt16 = 8765

    /// 執行 JavaScript 的回調（從外部注入）
    var executeJavaScriptCallback: ((String, @escaping (Any?, Error?) -> Void) -> Void)?

    /// 獲取日誌的回調
    var getLogsCallback: (() -> [String])?

    /// 清空日誌的回調
    var clearLogsCallback: (() -> Void)?

    /// 記錄日誌的回調
    var logCallback: ((String) -> Void)?

    /// 內部日誌緩衝區（只有在沒有 `logCallback` 時才會用到）
    private var logBuffer: [String] = []
    private let maxLogCount = 10000

    // MARK: - Initialization

    init() {}

    /// app target 開了 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，NakiTests 沒開；
    /// 沒有這行的話單測釋放這個實例會 SIGABRT 把 test host 打掉（見 CLAUDE.md）。
    nonisolated deinit { }

    // MARK: - MCPContext Implementation

    func executeJavaScript(_ script: String) async throws -> Any? {
        guard let callback = executeJavaScriptCallback else {
            throw MCPToolError.notAvailable("JavaScript execution")
        }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any?, Error>) in
            callback(script) { result, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    // 回調本來就在 MainActor 上，`Any?` 不是 Sendable，這裡明確標記不檢查
                    nonisolated(unsafe) let unsafeResult = result
                    continuation.resume(returning: unsafeResult)
                }
            }
        }
    }

    func getLogs() -> [String] {
        return getLogsCallback?() ?? logBuffer
    }

    func clearLogs() {
        clearLogsCallback?()
        logBuffer.removeAll()
    }

    func log(_ message: String) {
        if let callback = logCallback {
            callback(message)
        } else {
            let timestamp = ISO8601DateFormatter().string(from: Date())
            let logMessage = "[\(timestamp)] \(message)"
            logBuffer.append(logMessage)
            if logBuffer.count > maxLogCount {
                logBuffer.removeFirst()
            }
            print("[Naki] \(message)")
        }
    }
}
