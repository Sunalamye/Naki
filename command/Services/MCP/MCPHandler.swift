//
//  MCPHandler.swift
//  Naki
//
//  Created by Claude on 2025/12/05.
//  MCP (Model Context Protocol) 處理器 - 使用 Protocol 模式重構
//

import Foundation
import Network

// MARK: - MCP Handler

/// MCP Protocol 處理器
/// 負責處理所有 MCP JSON-RPC 請求，使用 MCPToolRegistry 管理工具
final class MCPHandler {

    // MARK: - Properties

    /// 執行上下文
    let context: DefaultMCPContext

    /// 發送 HTTP 響應的回調
    var sendResponse: ((NWConnection, Int, String, String) -> Void)?

    // MARK: - Initialization

    init() {
        self.context = DefaultMCPContext()

        // 註冊所有內建工具
        MCPToolRegistry.shared.registerBuiltInTools()
    }

    // MARK: - Context Configuration

    /// 設置伺服器埠號
    var serverPort: UInt16 {
        get { context.serverPort }
        set { context.serverPort = newValue }
    }

    /// 設置 JavaScript 執行回調
    var executeJavaScript: ((String, @escaping (Any?, Error?) -> Void) -> Void)? {
        get { context.executeJavaScriptCallback }
        set { context.executeJavaScriptCallback = newValue }
    }

    /// 設置獲取 Bot 狀態回調
    var getBotStatus: (() -> [String: Any])? {
        get { context.getBotStatusCallback }
        set { context.getBotStatusCallback = newValue }
    }

    /// 設置觸發自動打牌回調
    var triggerAutoPlay: (() -> Void)? {
        get { context.triggerAutoPlayCallback }
        set { context.triggerAutoPlayCallback = newValue }
    }

    /// 設置獲取日誌回調
    var getLogs: (() -> [String])? {
        get { context.getLogsCallback }
        set { context.getLogsCallback = newValue }
    }

    /// 設置清空日誌回調
    var clearLogs: (() -> Void)? {
        get { context.clearLogsCallback }
        set { context.clearLogsCallback = newValue }
    }

    /// 設置記錄日誌回調
    var log: ((String) -> Void)? {
        get { context.logCallback }
        set { context.logCallback = newValue }
    }

    // MARK: - MCP Request Handler

    /// 處理 MCP 請求入口
    func handleRequest(body: String, headers: [String], connection: NWConnection) {
        context.log("MCP request received")

        // 解析 JSON-RPC 請求
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = json["method"] as? String else {
            sendError(connection: connection, id: nil, code: -32700, message: "Parse error")
            return
        }

        let id = json["id"]  // 可以是 Int 或 String
        let params = json["params"] as? [String: Any] ?? [:]

        context.log("MCP method: \(method)")

        // 路由 MCP 方法
        switch method {
        case "initialize":
            handleInitialize(id: id, params: params, connection: connection)

        case "initialized":
            // 客戶端確認初始化完成，直接返回空響應
            sendResult(connection: connection, id: id, result: [:])

        case "tools/list":
            handleToolsList(id: id, connection: connection)

        case "tools/call":
            handleToolsCall(id: id, params: params, connection: connection)

        default:
            sendError(connection: connection, id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    // MARK: - Method Handlers

    /// 處理 initialize 請求
    private func handleInitialize(id: Any?, params: [String: Any], connection: NWConnection) {
        let result: [String: Any] = [
            "protocolVersion": "2025-03-26",
            "serverInfo": [
                "name": "naki",
                "version": "2.0.0"
            ],
            "capabilities": [
                "tools": [:]
            ]
        ]
        sendResult(connection: connection, id: id, result: result)
    }

    /// 處理 tools/list 請求（從 Registry 自動生成）
    private func handleToolsList(id: Any?, connection: NWConnection) {
        let result: [String: Any] = [
            "tools": MCPToolRegistry.shared.allToolDefinitions()
        ]
        sendResult(connection: connection, id: id, result: result)
    }

    /// 處理 tools/call 請求
    private func handleToolsCall(id: Any?, params: [String: Any], connection: NWConnection) {
        guard let toolName = params["name"] as? String else {
            sendError(connection: connection, id: id, code: -32602, message: "Missing tool name")
            return
        }

        let arguments = params["arguments"] as? [String: Any] ?? [:]
        context.log("MCP tools/call: \(toolName) with args: \(arguments)")

        // 使用 Registry 執行工具
        Task {
            let result = await MCPToolRegistry.shared.execute(
                toolNamed: toolName,
                arguments: arguments,
                context: context
            )

            await MainActor.run {
                switch result {
                case .success(let value):
                    self.sendToolResult(connection: connection, id: id, content: value)
                case .error(let message):
                    self.sendToolError(connection: connection, id: id, message: message)
                }
            }
        }
    }

    // MARK: - Public Tool API

    /// 直接調用工具（供 HTTP endpoints 使用）
    /// - Parameters:
    ///   - name: 工具名稱
    ///   - arguments: 工具參數
    ///   - completion: 完成回調，返回 MCPToolResult
    func callTool(name: String, arguments: [String: Any] = [:], completion: @escaping (MCPToolResult) -> Void) {
        context.log("callTool: \(name) with args: \(arguments)")

        Task {
            let result = await MCPToolRegistry.shared.execute(
                toolNamed: name,
                arguments: arguments,
                context: context
            )

            await MainActor.run {
                completion(result)
            }
        }
    }

    /// 構建 Help 內容（向後兼容）
    func buildHelpContent() -> [String: Any] {
        return [
            "name": "Naki Debug API",
            "version": "2.0",
            "description": "Naki 麻將 AI 助手的 Debug API，用於監控遊戲狀態、控制 Bot、執行遊戲操作",
            "base_url": "http://localhost:\(serverPort)",
            "mcp_endpoint": "http://localhost:\(serverPort)/mcp",
            "tools_count": MCPToolRegistry.shared.registeredToolNames.count,
            "tile_notation": [
                "數牌（Suited）": "1-9 + m(萬)/p(筒)/s(索)，如 1m, 5p, 9s",
                "紅寶牌（Red 5s）": "5mr, 5pr, 5sr",
                "字牌（Honor）": "E(東), S(南), W(西), N(北), P(白), F(發), C(中)"
            ]
        ]
    }

    // MARK: - Response Methods

    /// 發送 MCP 成功結果
    private func sendResult(connection: NWConnection, id: Any?, result: [String: Any]) {
        var response: [String: Any] = [
            "jsonrpc": "2.0",
            "result": result
        ]
        if let id = id {
            response["id"] = id
        }
        sendJSON(connection: connection, data: response)
    }

    /// 發送 MCP 工具執行結果
    private func sendToolResult(connection: NWConnection, id: Any?, content: Any) {
        let contentText: String
        if let dict = content as? [String: Any] {
            contentText = (try? JSONSerialization.data(withJSONObject: sanitizeForJSON(dict), options: []))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        } else if let array = content as? [Any] {
            contentText = (try? JSONSerialization.data(withJSONObject: sanitizeForJSON(array), options: []))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        } else {
            contentText = String(describing: content)
        }

        let result: [String: Any] = [
            "content": [
                ["type": "text", "text": contentText]
            ],
            "isError": false
        ]
        sendResult(connection: connection, id: id, result: result)
    }

    /// 發送 MCP 工具執行錯誤
    private func sendToolError(connection: NWConnection, id: Any?, message: String) {
        let result: [String: Any] = [
            "content": [
                ["type": "text", "text": message]
            ],
            "isError": true
        ]
        sendResult(connection: connection, id: id, result: result)
    }

    /// 發送 MCP 錯誤
    private func sendError(connection: NWConnection, id: Any?, code: Int, message: String) {
        var response: [String: Any] = [
            "jsonrpc": "2.0",
            "error": [
                "code": code,
                "message": message
            ]
        ]
        if let id = id {
            response["id"] = id
        }
        sendJSON(connection: connection, data: response)
    }

    /// 發送 MCP JSON 響應
    private func sendJSON(connection: NWConnection, data: [String: Any]) {
        do {
            let sanitized = sanitizeForJSON(data) as! [String: Any]
            let jsonData = try JSONSerialization.data(withJSONObject: sanitized, options: [])
            let body = String(data: jsonData, encoding: .utf8) ?? "{}"
            sendResponse?(connection, 200, body, "application/json")
        } catch {
            sendResponse?(connection, 500, "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32603,\"message\":\"Internal error\"}}", "application/json")
        }
    }

    /// 清理 JSON 值（處理 NaN 和 Infinity）
    private func sanitizeForJSON(_ value: Any) -> Any {
        switch value {
        case let dict as [String: Any]:
            return dict.mapValues { sanitizeForJSON($0) }
        case let array as [Any]:
            return array.map { sanitizeForJSON($0) }
        case let d as Double where d.isNaN || d.isInfinite:
            return NSNull()
        case let f as Float where f.isNaN || f.isInfinite:
            return NSNull()
        case let n as NSNumber:
            let d = n.doubleValue
            if d.isNaN || d.isInfinite {
                return NSNull()
            }
            return n
        default:
            return value
        }
    }
}

// MARK: - Backwards Compatibility

extension MCPHandler {
    /// 舊版 ToolResult 類型別名（向後兼容）
    typealias ToolResult = MCPToolResult
}
