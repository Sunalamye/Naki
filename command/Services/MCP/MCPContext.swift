//
//  MCPContext.swift
//  Naki
//
//  Created by Claude on 2025/12/05.
//  Naki 專用的 MCP 上下文擴展
//

import Foundation
import MCPKit

// MARK: - Naki MCP Context Protocol

/// Naki 專用的 MCP 上下文協議
/// 擴展 MCPKit 的 MCPContext，添加 Naki 特有的功能
protocol NakiMCPContext: MCPContext {
    /// 獲取 Bot 狀態
    func getBotStatus() -> [String: Any]?

    /// 觸發自動打牌
    func triggerAutoPlay()
}

// MARK: - Default Naki Context Implementation

/// Naki 專用的 MCP 上下文實現
/// 將回調模式橋接到 async/await
final class DefaultNakiMCPContext: NakiMCPContext {
    var serverPort: UInt16 = 8765

    /// 執行 JavaScript 的回調（從外部注入）
    var executeJavaScriptCallback: ((String, @escaping (Any?, Error?) -> Void) -> Void)?

    /// 獲取 Bot 狀態的回調
    var getBotStatusCallback: (() -> [String: Any])?

    /// 觸發自動打牌的回調
    var triggerAutoPlayCallback: (() -> Void)?

    /// 獲取日誌的回調
    var getLogsCallback: (() -> [String])?

    /// 清空日誌的回調
    var clearLogsCallback: (() -> Void)?

    /// 記錄日誌的回調
    var logCallback: ((String) -> Void)?

    // MARK: - MCPContext Implementation

    func executeJavaScript(_ script: String) async throws -> Any? {
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

    func getBotStatus() -> [String: Any]? {
        return getBotStatusCallback?()
    }

    func triggerAutoPlay() {
        triggerAutoPlayCallback?()
    }

    func getLogs() -> [String] {
        return getLogsCallback?() ?? []
    }

    func clearLogs() {
        clearLogsCallback?()
    }

    func log(_ message: String) {
        logCallback?(message)
    }
}
