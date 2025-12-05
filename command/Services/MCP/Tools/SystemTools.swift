//
//  SystemTools.swift
//  Naki
//
//  Created by Claude on 2025/12/05.
//  系統類 MCP 工具
//

import Foundation

// MARK: - Get Status Tool

/// 獲取 Debug Server 狀態
struct GetStatusTool: MCPTool {
    static let name = "get_status"
    static let description = "獲取 Debug Server 狀態和埠號"
    static let inputSchema = MCPInputSchema.empty

    private let context: MCPContext

    init(context: MCPContext) {
        self.context = context
    }

    func execute(arguments: [String: Any]) async throws -> Any {
        return [
            "status": "running",
            "port": context.serverPort,
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
    }
}

// MARK: - Get Help Tool

/// 獲取 API 文檔
struct GetHelpTool: MCPTool {
    static let name = "get_help"
    static let description = "獲取完整的 API 文檔（JSON 格式）"
    static let inputSchema = MCPInputSchema.empty

    private let context: MCPContext

    init(context: MCPContext) {
        self.context = context
    }

    func execute(arguments: [String: Any]) async throws -> Any {
        let toolsCount = MCPToolRegistry.shared.registeredToolNames.count
        return [
            "name": "Naki Debug API",
            "version": "2.0",
            "description": "Naki 麻將 AI 助手的 Debug API，用於監控遊戲狀態、控制 Bot、執行遊戲操作",
            "base_url": "http://localhost:\(context.serverPort)",
            "mcp_endpoint": "http://localhost:\(context.serverPort)/mcp",
            "tools_count": toolsCount,
            "tile_notation": [
                "數牌（Suited）": "1-9 + m(萬)/p(筒)/s(索)，如 1m, 5p, 9s",
                "紅寶牌（Red 5s）": "5mr, 5pr, 5sr",
                "字牌（Honor）": "E(東), S(南), W(西), N(北), P(白), F(發), C(中)"
            ]
        ]
    }
}

// MARK: - Get Logs Tool

/// 獲取 Debug 日誌
struct GetLogsTool: MCPTool {
    static let name = "get_logs"
    static let description = "獲取 Debug 日誌（最多 10,000 條）"
    static let inputSchema = MCPInputSchema.empty

    private let context: MCPContext

    init(context: MCPContext) {
        self.context = context
    }

    func execute(arguments: [String: Any]) async throws -> Any {
        let logs = context.getLogs()
        return [
            "logs": logs,
            "count": logs.count
        ]
    }
}

// MARK: - Clear Logs Tool

/// 清空日誌
struct ClearLogsTool: MCPTool {
    static let name = "clear_logs"
    static let description = "清空所有日誌"
    static let inputSchema = MCPInputSchema.empty

    private let context: MCPContext

    init(context: MCPContext) {
        self.context = context
    }

    func execute(arguments: [String: Any]) async throws -> Any {
        context.clearLogs()
        return [
            "success": true,
            "message": "Logs cleared"
        ]
    }
}
