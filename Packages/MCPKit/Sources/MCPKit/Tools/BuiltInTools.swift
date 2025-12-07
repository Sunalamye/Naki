//
//  BuiltInTools.swift
//  MCPKit
//
//  內建的通用工具
//  這些工具可以在任何 MCP 應用中使用
//

import Foundation

// MARK: - Get Status Tool

/// 獲取伺服器狀態工具
public struct GetStatusTool: MCPTool {
    public static let name = "get_status"
    public static let description = "獲取 MCP Server 狀態和埠號"
    public static let inputSchema = MCPInputSchema.empty

    private let context: MCPContext

    public init(context: MCPContext) {
        self.context = context
    }

    public func execute(arguments: [String: Any]) async throws -> Any {
        return [
            "status": "running",
            "port": context.serverPort
        ]
    }
}

// MARK: - Get Logs Tool

/// 獲取日誌工具
public struct GetLogsTool: MCPTool {
    public static let name = "get_logs"
    public static let description = "獲取 Debug 日誌(最多 10,000 條)"
    public static let inputSchema = MCPInputSchema.empty

    private let context: MCPContext

    public init(context: MCPContext) {
        self.context = context
    }

    public func execute(arguments: [String: Any]) async throws -> Any {
        return ["logs": context.getLogs()]
    }
}

// MARK: - Clear Logs Tool

/// 清空日誌工具
public struct ClearLogsTool: MCPTool {
    public static let name = "clear_logs"
    public static let description = "清空所有日誌"
    public static let inputSchema = MCPInputSchema.empty

    private let context: MCPContext

    public init(context: MCPContext) {
        self.context = context
    }

    public func execute(arguments: [String: Any]) async throws -> Any {
        context.clearLogs()
        return ["success": true, "message": "Logs cleared"]
    }
}

// MARK: - Execute JavaScript Tool

/// 執行 JavaScript 工具（需要 WebView 支援）
public struct ExecuteJavaScriptTool: MCPTool {
    public static let name = "execute_js"
    public static let description = "在 WebView 中執行 JavaScript 代碼。⚠️ 重要:必須使用 return 語句才能獲取返回值!"
    public static let inputSchema = MCPInputSchema(
        properties: [
            "code": .string("要執行的 JavaScript 代碼(函數體格式,需要 return 語句才能獲取返回值)")
        ],
        required: ["code"]
    )

    private let context: MCPContext

    public init(context: MCPContext) {
        self.context = context
    }

    public func execute(arguments: [String: Any]) async throws -> Any {
        guard let code = arguments["code"] as? String else {
            throw MCPToolError.missingParameter("code")
        }

        let result = try await context.executeJavaScript(code)
        return ["result": result ?? NSNull()]
    }
}

// MARK: - Registry Extension

public extension MCPToolRegistry {
    /// 註冊 MCPKit 內建工具
    func registerBuiltInTools() {
        register(GetStatusTool.self)
        register(GetLogsTool.self)
        register(ClearLogsTool.self)
        register(ExecuteJavaScriptTool.self)
    }
}
