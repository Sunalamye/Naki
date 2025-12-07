//
//  MCPContext.swift
//  Naki
//
//  Created by Claude on 2025/12/05.
//  Naki 專用的 MCP 上下文擴展
//

import Foundation
import MCPKit
import MCPWebKit

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
/// 包裝 WebViewMCPContext，添加 Naki 特有功能
@MainActor
final class DefaultNakiMCPContext: NakiMCPContext {

    /// 內部使用的 WebViewMCPContext
    private let webContext = WebViewMCPContext()

    /// 獲取 Bot 狀態的回調
    var getBotStatusCallback: (() -> [String: Any])?

    /// 觸發自動打牌的回調
    var triggerAutoPlayCallback: (() -> Void)?

    // MARK: - MCPContext Implementation (委託給 webContext)

    var serverPort: UInt16 {
        get { webContext.serverPort }
        set { webContext.serverPort = newValue }
    }

    var executeJavaScriptCallback: ((String, @escaping (Any?, Error?) -> Void) -> Void)? {
        get { webContext.executeJavaScriptCallback }
        set { webContext.executeJavaScriptCallback = newValue }
    }

    var getLogsCallback: (() -> [String])? {
        get { webContext.getLogsCallback }
        set { webContext.getLogsCallback = newValue }
    }

    var clearLogsCallback: (() -> Void)? {
        get { webContext.clearLogsCallback }
        set { webContext.clearLogsCallback = newValue }
    }

    var logCallback: ((String) -> Void)? {
        get { webContext.logCallback }
        set { webContext.logCallback = newValue }
    }

    func executeJavaScript(_ script: String) async throws -> Any? {
        try await webContext.executeJavaScript(script)
    }

    func getLogs() -> [String] {
        webContext.getLogs()
    }

    func clearLogs() {
        webContext.clearLogs()
    }

    func log(_ message: String) {
        webContext.log(message)
    }

    // MARK: - NakiMCPContext Implementation

    func getBotStatus() -> [String: Any]? {
        return getBotStatusCallback?()
    }

    func triggerAutoPlay() {
        triggerAutoPlayCallback?()
    }
}
