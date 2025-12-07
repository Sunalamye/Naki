//
//  MCPContext.swift
//  MCPKit
//
//  MCP 工具執行上下文協議
//  定義工具執行所需的依賴注入介面
//

import Foundation

// MARK: - MCP Context Protocol

/// MCP 工具執行上下文
/// 提供工具執行所需的所有依賴
/// 應用程式需要實現此協議來提供具體功能
public protocol MCPContext: AnyObject {
    /// 伺服器埠號
    var serverPort: UInt16 { get }

    /// 執行 JavaScript（可選，用於 WebView 整合）
    /// - Parameter script: JavaScript 代碼
    /// - Returns: 執行結果
    func executeJavaScript(_ script: String) async throws -> Any?

    /// 獲取日誌
    func getLogs() -> [String]

    /// 清空日誌
    func clearLogs()

    /// 記錄日誌
    func log(_ message: String)
}

// MARK: - Default Implementation

public extension MCPContext {
    /// 預設的 JavaScript 執行（拋出不可用錯誤）
    func executeJavaScript(_ script: String) async throws -> Any? {
        throw MCPToolError.notAvailable("JavaScript execution")
    }
}

// MARK: - Basic Context Implementation

/// 基本的 MCP 上下文實現
/// 使用回調模式橋接到 async/await
@MainActor
public final class BasicMCPContext: MCPContext {
    public var serverPort: UInt16

    /// 執行 JavaScript 的回調（從外部注入）
    public var executeJavaScriptCallback: ((String, @escaping (Any?, Error?) -> Void) -> Void)?

    /// 獲取日誌的回調
    public var getLogsCallback: (() -> [String])?

    /// 清空日誌的回調
    public var clearLogsCallback: (() -> Void)?

    /// 記錄日誌的回調
    public var logCallback: ((String) -> Void)?

    /// 內部日誌緩衝區（當沒有外部回調時使用）
    private var logBuffer: [String] = []
    private let maxLogCount: Int

    public init(port: UInt16 = 8765, maxLogCount: Int = 10000) {
        self.serverPort = port
        self.maxLogCount = maxLogCount
    }

    // MARK: - MCPContext Implementation

    public func executeJavaScript(_ script: String) async throws -> Any? {
        guard let callback = executeJavaScriptCallback else {
            throw MCPToolError.notAvailable("JavaScript execution")
        }

        return try await withCheckedThrowingContinuation { continuation in
            callback(script) { result, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: result)
                }
            }
        }
    }

    public func getLogs() -> [String] {
        return getLogsCallback?() ?? logBuffer
    }

    public func clearLogs() {
        clearLogsCallback?()
        logBuffer.removeAll()
    }

    public func log(_ message: String) {
        if let callback = logCallback {
            callback(message)
        } else {
            let timestamp = ISO8601DateFormatter().string(from: Date())
            let logMessage = "[\(timestamp)] \(message)"
            logBuffer.append(logMessage)
            if logBuffer.count > maxLogCount {
                logBuffer.removeFirst()
            }
            print("[MCPKit] \(message)")
        }
    }
}
