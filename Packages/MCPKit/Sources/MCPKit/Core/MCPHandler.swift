//
//  MCPHandler.swift
//  MCPKit
//
//  MCP (Model Context Protocol) 處理器
//  負責處理所有 MCP JSON-RPC 請求
//

import Foundation

// MARK: - MCP Handler

/// MCP Protocol 處理器
/// 負責處理所有 MCP JSON-RPC 請求，使用 MCPToolRegistry 管理工具
@MainActor
public final class MCPHandler {

    // MARK: - Properties

    /// 工具註冊表
    public let registry: MCPToolRegistry

    /// 執行上下文
    public let context: MCPContext

    /// 伺服器資訊
    public var serverName: String = "MCPKit"
    public var serverVersion: String = "1.0.0"
    public var protocolVersion: String = "2025-03-26"

    /// 發送響應的回調（由傳輸層設置）
    public var sendResponse: ((_ statusCode: Int, _ body: String, _ contentType: String) -> Void)?

    // MARK: - Initialization

    public init(context: MCPContext, registry: MCPToolRegistry? = nil) {
        self.context = context
        self.registry = registry ?? MCPToolRegistry()
    }

    // MARK: - MCP Request Handler

    /// 處理 MCP 請求入口
    /// - Parameters:
    ///   - body: JSON-RPC 請求體
    ///   - completion: 完成回調，返回 (statusCode, responseBody, contentType)
    public func handleRequest(body: String, completion: @escaping (Int, String, String) -> Void) {
        context.log("MCP request received")

        // 解析 JSON-RPC 請求
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = json["method"] as? String else {
            let error = buildErrorResponse(id: nil, code: -32700, message: "Parse error")
            completion(200, error, "application/json")
            return
        }

        let id = json["id"]  // 可以是 Int 或 String
        let params = json["params"] as? [String: Any] ?? [:]

        context.log("MCP method: \(method)")

        // 路由 MCP 方法
        Task {
            let response: String
            switch method {
            case "initialize":
                response = handleInitialize(id: id, params: params)

            case "initialized":
                response = buildResultResponse(id: id, result: [:])

            case "tools/list":
                response = handleToolsList(id: id)

            case "tools/call":
                response = await handleToolsCall(id: id, params: params)

            default:
                response = buildErrorResponse(id: id, code: -32601, message: "Method not found: \(method)")
            }

            await MainActor.run {
                completion(200, response, "application/json")
            }
        }
    }

    // MARK: - Method Handlers

    /// 處理 initialize 請求
    private func handleInitialize(id: Any?, params: [String: Any]) -> String {
        let result: [String: Any] = [
            "protocolVersion": protocolVersion,
            "serverInfo": [
                "name": serverName,
                "version": serverVersion
            ],
            "capabilities": [
                "tools": [:]
            ]
        ]
        return buildResultResponse(id: id, result: result)
    }

    /// 處理 tools/list 請求（從 Registry 自動生成）
    private func handleToolsList(id: Any?) -> String {
        let result: [String: Any] = [
            "tools": registry.allToolDefinitions()
        ]
        return buildResultResponse(id: id, result: result)
    }

    /// 處理 tools/call 請求
    private func handleToolsCall(id: Any?, params: [String: Any]) async -> String {
        guard let toolName = params["name"] as? String else {
            return buildErrorResponse(id: id, code: -32602, message: "Missing tool name")
        }

        let arguments = params["arguments"] as? [String: Any] ?? [:]
        context.log("MCP tools/call: \(toolName) with args: \(arguments)")

        // 使用 Registry 執行工具
        let result = await registry.execute(
            toolNamed: toolName,
            arguments: arguments,
            context: context
        )

        switch result {
        case .success(let value):
            return buildToolResultResponse(id: id, content: value)
        case .error(let message):
            return buildToolErrorResponse(id: id, message: message)
        }
    }

    // MARK: - Public Tool API

    /// 直接調用工具
    /// - Parameters:
    ///   - name: 工具名稱
    ///   - arguments: 工具參數
    /// - Returns: MCPToolResult
    public func callTool(name: String, arguments: [String: Any] = [:]) async -> MCPToolResult {
        context.log("callTool: \(name) with args: \(arguments)")
        return await registry.execute(
            toolNamed: name,
            arguments: arguments,
            context: context
        )
    }

    // MARK: - Response Builders

    /// 構建 MCP 成功結果響應
    private func buildResultResponse(id: Any?, result: [String: Any]) -> String {
        var response: [String: Any] = [
            "jsonrpc": "2.0",
            "result": result
        ]
        if let id = id {
            response["id"] = id
        }
        return jsonString(from: response)
    }

    /// 構建 MCP 工具執行結果響應
    private func buildToolResultResponse(id: Any?, content: Any) -> String {
        let contentText: String
        if let dict = content as? [String: Any] {
            contentText = jsonString(from: sanitizeForJSON(dict) as! [String: Any])
        } else if let array = content as? [Any] {
            contentText = jsonString(from: sanitizeForJSON(array))
        } else {
            contentText = String(describing: content)
        }

        let result: [String: Any] = [
            "content": [
                ["type": "text", "text": contentText]
            ],
            "isError": false
        ]
        return buildResultResponse(id: id, result: result)
    }

    /// 構建 MCP 工具執行錯誤響應
    private func buildToolErrorResponse(id: Any?, message: String) -> String {
        let result: [String: Any] = [
            "content": [
                ["type": "text", "text": message]
            ],
            "isError": true
        ]
        return buildResultResponse(id: id, result: result)
    }

    /// 構建 MCP 錯誤響應
    private func buildErrorResponse(id: Any?, code: Int, message: String) -> String {
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
        return jsonString(from: response)
    }

    // MARK: - Helpers

    /// 轉換為 JSON 字串
    private func jsonString(from data: Any) -> String {
        do {
            let sanitized = sanitizeForJSON(data)
            let jsonData = try JSONSerialization.data(withJSONObject: sanitized, options: [])
            return String(data: jsonData, encoding: .utf8) ?? "{}"
        } catch {
            return "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32603,\"message\":\"Internal error\"}}"
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
