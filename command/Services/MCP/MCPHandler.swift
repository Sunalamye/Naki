//
//  MCPHandler.swift
//  Naki
//
//  Created by Claude on 2025/12/05.
//  MCP (Model Context Protocol) 處理器 - 從 DebugServer 拆分
//

import Foundation
import Network

// MARK: - Tool Result

/// 工具調用結果
enum ToolResult {
    case success(Any)
    case error(String)

    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }

    var value: Any? {
        if case .success(let v) = self { return v }
        return nil
    }

    var errorMessage: String? {
        if case .error(let msg) = self { return msg }
        return nil
    }
}

// MARK: - MCP Handler

/// MCP Protocol 處理器
/// 負責處理所有 MCP JSON-RPC 請求，也提供直接調用工具的 API
class MCPHandler {

    // MARK: - Dependencies

    /// 伺服器埠號（用於 help 文檔）
    var serverPort: UInt16 = 8765

    /// 執行 JavaScript 的回調
    var executeJavaScript: ((String, @escaping (Any?, Error?) -> Void) -> Void)?

    /// 獲取 Bot 狀態的回調
    var getBotStatus: (() -> [String: Any])?

    /// 觸發自動打牌的回調
    var triggerAutoPlay: (() -> Void)?

    /// 獲取日誌的回調
    var getLogs: (() -> [String])?

    /// 清空日誌的回調
    var clearLogs: (() -> Void)?

    /// 記錄日誌的回調
    var log: ((String) -> Void)?

    /// 發送 HTTP 響應的回調
    var sendResponse: ((NWConnection, Int, String, String) -> Void)?

    // MARK: - MCP Tools Definition

    /// 從 JSON 文件載入的工具定義緩存
    private var _mcpTools: [[String: Any]]?

    /// MCP 工具定義列表（從 mcp-tools.json 載入）
    var mcpTools: [[String: Any]] {
        if let cached = _mcpTools {
            return cached
        }

        // 嘗試從 Bundle 載入 JSON 文件
        if let url = Bundle.main.url(forResource: "mcp-tools", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let tools = json["tools"] as? [[String: Any]] {
            _mcpTools = tools
            return tools
        }

        // 回退：返回空陣列（不應該發生）
        log?("Warning: Failed to load mcp-tools.json")
        return []
    }

    // MARK: - Main Handler

    /// 處理 MCP 請求入口
    func handleRequest(body: String, headers: [String], connection: NWConnection) {
        log?("MCP request received")

        // 解析 JSON-RPC 請求
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = json["method"] as? String else {
            sendError(connection: connection, id: nil, code: -32700, message: "Parse error")
            return
        }

        let id = json["id"]  // 可以是 Int 或 String
        let params = json["params"] as? [String: Any] ?? [:]

        log?("MCP method: \(method)")

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
                "version": "1.2.0"
            ],
            "capabilities": [
                "tools": [:]
            ]
        ]
        sendResult(connection: connection, id: id, result: result)
    }

    /// 處理 tools/list 請求
    private func handleToolsList(id: Any?, connection: NWConnection) {
        let result: [String: Any] = [
            "tools": mcpTools
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
        log?("MCP tools/call: \(toolName) with args: \(arguments)")

        // 根據工具名稱執行對應的操作
        switch toolName {
        // 系統類
        case "get_status":
            let status: [String: Any] = [
                "status": "running",
                "port": serverPort,
                "timestamp": ISO8601DateFormatter().string(from: Date())
            ]
            sendToolResult(connection: connection, id: id, content: status)

        case "get_help":
            let help = buildHelpContent()
            sendToolResult(connection: connection, id: id, content: help)

        case "get_logs":
            let logs = getLogs?() ?? []
            sendToolResult(connection: connection, id: id, content: ["logs": logs, "count": logs.count])

        case "clear_logs":
            clearLogs?()
            sendToolResult(connection: connection, id: id, content: ["success": true, "message": "Logs cleared"])

        // Bot 控制類
        case "bot_status":
            if let status = getBotStatus?() {
                sendToolResult(connection: connection, id: id, content: status)
            } else {
                sendToolError(connection: connection, id: id, message: "Bot status not available")
            }

        case "bot_trigger":
            log?("MCP: Manual auto-play trigger requested")
            triggerAutoPlay?()
            sendToolResult(connection: connection, id: id, content: ["success": true, "message": "Auto-play triggered"])

        case "bot_ops":
            executeJSForMCP("window.__nakiGameAPI.exploreOperationAPI()", id: id, connection: connection)

        case "bot_deep":
            executeJSForMCP("window.__nakiGameAPI.deepExploreNaki()", id: id, connection: connection)

        case "bot_chi":
            executeJSForMCP("window.__nakiGameAPI.testChi()", id: id, connection: connection)

        case "bot_pon":
            executeJSForMCP("window.__nakiGameAPI.testPon()", id: id, connection: connection)

        // 遊戲狀態類
        case "game_state":
            executeJSForMCP("window.__nakiGameAPI ? JSON.stringify(__nakiGameAPI.getGameState()) : '{\"error\": \"API not loaded\"}'", id: id, connection: connection, parseJSON: true)

        case "game_hand":
            executeJSForMCP("window.__nakiGameAPI ? JSON.stringify(__nakiGameAPI.getHandInfo()) : '{\"error\": \"API not loaded\"}'", id: id, connection: connection, parseJSON: true)

        case "game_ops":
            executeJSForMCP("window.__nakiGameAPI ? JSON.stringify(__nakiGameAPI.getAvailableOps()) : '[]'", id: id, connection: connection, parseJSON: true)

        case "game_discard":
            handleGameDiscard(id: id, arguments: arguments, connection: connection)

        case "game_action":
            handleGameAction(id: id, arguments: arguments, connection: connection)

        // JavaScript 執行
        case "execute_js":
            handleExecuteJS(id: id, arguments: arguments, connection: connection)

        // 探索類
        case "detect":
            executeJSForMCP("window.__nakiDetectGameAPI ? __nakiDetectGameAPI() : {error: 'Not loaded'}", id: id, connection: connection)

        case "explore":
            executeJSForMCP("window.__nakiExploreGameObjects ? __nakiExploreGameObjects() : {error: 'Not loaded'}", id: id, connection: connection)

        // UI 操作類
        case "test_indicators":
            executeJSForMCP("window.__nakiTestIndicators ? (__nakiTestIndicators(), 'OK') : 'Not loaded'", id: id, connection: connection)

        case "click":
            handleClick(id: id, arguments: arguments, connection: connection)

        case "calibrate":
            handleCalibrate(id: id, arguments: arguments, connection: connection)

        // UI 控制類
        case "ui_names_status":
            executeJSForMCP("JSON.stringify(window.__nakiPlayerNames?.getStatus() || {available: false})", id: id, connection: connection, parseJSON: true)

        case "ui_names_hide":
            handleUINameVisibility(id: id, action: "hide", connection: connection)

        case "ui_names_show":
            handleUINameVisibility(id: id, action: "show", connection: connection)

        case "ui_names_toggle":
            handleUINameToggle(id: id, connection: connection)

        default:
            sendToolError(connection: connection, id: id, message: "Unknown tool: \(toolName)")
        }
    }

    // MARK: - Public Tool API

    /// 直接調用工具（供 HTTP endpoints 使用）
    /// - Parameters:
    ///   - name: 工具名稱
    ///   - arguments: 工具參數
    ///   - completion: 完成回調，返回 ToolResult
    func callTool(name: String, arguments: [String: Any] = [:], completion: @escaping (ToolResult) -> Void) {
        log?("callTool: \(name) with args: \(arguments)")

        switch name {
        // 系統類
        case "get_status":
            let status: [String: Any] = [
                "status": "running",
                "port": serverPort,
                "timestamp": ISO8601DateFormatter().string(from: Date())
            ]
            completion(.success(status))

        case "get_help":
            let help = buildHelpContent()
            completion(.success(help))

        case "get_logs":
            let logs = getLogs?() ?? []
            completion(.success(["logs": logs, "count": logs.count]))

        case "clear_logs":
            clearLogs?()
            completion(.success(["success": true, "message": "Logs cleared"]))

        // Bot 控制類
        case "bot_status":
            if let status = getBotStatus?() {
                completion(.success(status))
            } else {
                completion(.error("Bot status not available"))
            }

        case "bot_trigger":
            log?("callTool: Manual auto-play trigger requested")
            triggerAutoPlay?()
            completion(.success(["success": true, "message": "Auto-play triggered"]))

        case "bot_ops":
            executeJSForTool("window.__nakiGameAPI.exploreOperationAPI()", completion: completion)

        case "bot_deep":
            executeJSForTool("window.__nakiGameAPI.deepExploreNaki()", completion: completion)

        case "bot_chi":
            executeJSForTool("window.__nakiGameAPI.testChi()", completion: completion)

        case "bot_pon":
            executeJSForTool("window.__nakiGameAPI.testPon()", completion: completion)

        // 遊戲狀態類
        case "game_state":
            executeJSForTool("window.__nakiGameAPI ? JSON.stringify(__nakiGameAPI.getGameState()) : '{\"error\": \"API not loaded\"}'", parseJSON: true, completion: completion)

        case "game_hand":
            executeJSForTool("window.__nakiGameAPI ? JSON.stringify(__nakiGameAPI.getHandInfo()) : '{\"error\": \"API not loaded\"}'", parseJSON: true, completion: completion)

        case "game_ops":
            executeJSForTool("window.__nakiGameAPI ? JSON.stringify(__nakiGameAPI.getAvailableOps()) : '[]'", parseJSON: true, completion: completion)

        case "game_discard":
            guard let tileIndex = arguments["tileIndex"] as? Int else {
                completion(.error("Missing tileIndex parameter"))
                return
            }
            let script = "window.__nakiGameAPI ? __nakiGameAPI.discardTile(\(tileIndex)) : false"
            executeJavaScript?(script) { result, error in
                if let error = error {
                    completion(.error(error.localizedDescription))
                } else if let success = result as? Bool {
                    completion(.success(["success": success, "tileIndex": tileIndex]))
                } else {
                    completion(.error("Discard failed"))
                }
            }

        case "game_action":
            guard let action = arguments["action"] as? String else {
                completion(.error("Missing action parameter"))
                return
            }
            let actionParams = arguments["params"] as? [String: Any] ?? [:]
            let paramsJson = (try? JSONSerialization.data(withJSONObject: actionParams))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            let script = "window.__nakiGameAPI ? __nakiGameAPI.smartExecute('\(action)', \(paramsJson)) : false"
            executeJavaScript?(script) { _, error in
                if let error = error {
                    completion(.error(error.localizedDescription))
                } else {
                    completion(.success(["success": true, "action": action]))
                }
            }

        // JavaScript 執行
        case "execute_js":
            guard let code = arguments["code"] as? String, !code.isEmpty else {
                completion(.error("Missing or empty code parameter"))
                return
            }
            executeJavaScript?(code) { result, error in
                if let error = error {
                    completion(.error(error.localizedDescription))
                } else {
                    completion(.success(["result": result ?? NSNull()]))
                }
            }

        // 探索類
        case "detect":
            executeJSForTool("window.__nakiDetectGameAPI ? __nakiDetectGameAPI() : {error: 'Not loaded'}", completion: completion)

        case "explore":
            executeJSForTool("window.__nakiExploreGameObjects ? __nakiExploreGameObjects() : {error: 'Not loaded'}", completion: completion)

        // UI 操作類
        case "test_indicators":
            executeJSForTool("window.__nakiTestIndicators ? (__nakiTestIndicators(), 'OK') : 'Not loaded'", completion: completion)

        case "click":
            guard let x = arguments["x"] as? Double,
                  let y = arguments["y"] as? Double else {
                completion(.error("Missing x or y parameter"))
                return
            }
            let label = arguments["label"] as? String ?? "MCP Click"
            let script = "window.__nakiAutoPlay.click(\(x), \(y), '\(label)')"
            executeJavaScript?(script) { _, error in
                if let error = error {
                    completion(.error(error.localizedDescription))
                } else {
                    completion(.success(["result": "clicked", "x": x, "y": y]))
                }
            }

        case "calibrate":
            let tileSpacing = arguments["tileSpacing"] as? Double ?? 96
            let offsetX = arguments["offsetX"] as? Double ?? -200
            let offsetY = arguments["offsetY"] as? Double ?? 0
            let script = """
            if (window.__nakiAutoPlay) {
                window.__nakiAutoPlay.calibration = {
                    tileSpacing: \(tileSpacing),
                    offsetX: \(offsetX),
                    offsetY: \(offsetY)
                };
                JSON.stringify(window.__nakiAutoPlay.calibration);
            } else {
                'Not loaded';
            }
            """
            executeJavaScript?(script) { _, error in
                if let error = error {
                    completion(.error(error.localizedDescription))
                } else {
                    completion(.success([
                        "result": "calibrated",
                        "tileSpacing": tileSpacing,
                        "offsetX": offsetX,
                        "offsetY": offsetY
                    ]))
                }
            }

        // UI 控制類
        case "ui_names_status":
            executeJSForTool("JSON.stringify(window.__nakiPlayerNames?.getStatus() || {available: false})", parseJSON: true, completion: completion)

        case "ui_names_hide":
            let script = "window.__nakiPlayerNames?.hide() || false"
            executeJavaScript?(script) { result, error in
                if let error = error {
                    completion(.error(error.localizedDescription))
                } else {
                    let success = result as? Bool ?? false
                    completion(.success(["success": success, "hidden": true]))
                }
            }

        case "ui_names_show":
            let script = "window.__nakiPlayerNames?.show() || false"
            executeJavaScript?(script) { result, error in
                if let error = error {
                    completion(.error(error.localizedDescription))
                } else {
                    let success = result as? Bool ?? false
                    completion(.success(["success": success, "hidden": false]))
                }
            }

        case "ui_names_toggle":
            executeJavaScript?("window.__nakiPlayerNames?.toggle() || false") { [weak self] result, error in
                if let error = error {
                    completion(.error(error.localizedDescription))
                } else {
                    let success = result as? Bool ?? false
                    self?.executeJavaScript?("window.__nakiPlayerNames?.hidden || false") { statusResult, _ in
                        let hidden = statusResult as? Bool ?? false
                        completion(.success(["success": success, "hidden": hidden]))
                    }
                }
            }

        default:
            completion(.error("Unknown tool: \(name)"))
        }
    }

    /// 執行 JavaScript 並返回 ToolResult
    private func executeJSForTool(_ script: String, parseJSON: Bool = false, completion: @escaping (ToolResult) -> Void) {
        executeJavaScript?(script) { result, error in
            DispatchQueue.main.async {
                if let error = error {
                    completion(.error(error.localizedDescription))
                } else if parseJSON, let jsonString = result as? String,
                          let data = jsonString.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: data) {
                    completion(.success(json))
                } else {
                    completion(.success(["result": result ?? NSNull()]))
                }
            }
        }
    }

    // MARK: - Tool Handlers (Legacy - for MCP protocol)

    private func handleGameDiscard(id: Any?, arguments: [String: Any], connection: NWConnection) {
        guard let tileIndex = arguments["tileIndex"] as? Int else {
            sendToolError(connection: connection, id: id, message: "Missing tileIndex parameter")
            return
        }
        let script = "window.__nakiGameAPI ? __nakiGameAPI.discardTile(\(tileIndex)) : false"
        executeJavaScript?(script) { [weak self] result, error in
            if let error = error {
                self?.sendToolError(connection: connection, id: id, message: error.localizedDescription)
            } else if let success = result as? Bool {
                self?.sendToolResult(connection: connection, id: id, content: ["success": success, "tileIndex": tileIndex])
            } else {
                self?.sendToolError(connection: connection, id: id, message: "Discard failed")
            }
        }
    }

    private func handleGameAction(id: Any?, arguments: [String: Any], connection: NWConnection) {
        guard let action = arguments["action"] as? String else {
            sendToolError(connection: connection, id: id, message: "Missing action parameter")
            return
        }
        let actionParams = arguments["params"] as? [String: Any] ?? [:]
        let paramsJson = (try? JSONSerialization.data(withJSONObject: actionParams))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let script = "window.__nakiGameAPI ? __nakiGameAPI.smartExecute('\(action)', \(paramsJson)) : false"
        executeJavaScript?(script) { [weak self] _, error in
            if let error = error {
                self?.sendToolError(connection: connection, id: id, message: error.localizedDescription)
            } else {
                self?.sendToolResult(connection: connection, id: id, content: ["success": true, "action": action])
            }
        }
    }

    private func handleExecuteJS(id: Any?, arguments: [String: Any], connection: NWConnection) {
        guard let code = arguments["code"] as? String, !code.isEmpty else {
            sendToolError(connection: connection, id: id, message: "Missing or empty code parameter")
            return
        }
        executeJavaScript?(code) { [weak self] result, error in
            if let error = error {
                self?.sendToolError(connection: connection, id: id, message: error.localizedDescription)
            } else {
                self?.sendToolResult(connection: connection, id: id, content: ["result": result ?? NSNull()])
            }
        }
    }

    private func handleClick(id: Any?, arguments: [String: Any], connection: NWConnection) {
        guard let x = arguments["x"] as? Double,
              let y = arguments["y"] as? Double else {
            sendToolError(connection: connection, id: id, message: "Missing x or y parameter")
            return
        }
        let label = arguments["label"] as? String ?? "MCP Click"
        let script = "window.__nakiAutoPlay.click(\(x), \(y), '\(label)')"
        executeJavaScript?(script) { [weak self] _, error in
            if let error = error {
                self?.sendToolError(connection: connection, id: id, message: error.localizedDescription)
            } else {
                self?.sendToolResult(connection: connection, id: id, content: ["result": "clicked", "x": x, "y": y])
            }
        }
    }

    private func handleCalibrate(id: Any?, arguments: [String: Any], connection: NWConnection) {
        let tileSpacing = arguments["tileSpacing"] as? Double ?? 96
        let offsetX = arguments["offsetX"] as? Double ?? -200
        let offsetY = arguments["offsetY"] as? Double ?? 0
        let script = """
        if (window.__nakiAutoPlay) {
            window.__nakiAutoPlay.calibration = {
                tileSpacing: \(tileSpacing),
                offsetX: \(offsetX),
                offsetY: \(offsetY)
            };
            JSON.stringify(window.__nakiAutoPlay.calibration);
        } else {
            'Not loaded';
        }
        """
        executeJavaScript?(script) { [weak self] _, error in
            if let error = error {
                self?.sendToolError(connection: connection, id: id, message: error.localizedDescription)
            } else {
                self?.sendToolResult(connection: connection, id: id, content: [
                    "result": "calibrated",
                    "tileSpacing": tileSpacing,
                    "offsetX": offsetX,
                    "offsetY": offsetY
                ])
            }
        }
    }

    private func handleUINameVisibility(id: Any?, action: String, connection: NWConnection) {
        let script = "window.__nakiPlayerNames?.\(action)() || false"
        executeJavaScript?(script) { [weak self] result, error in
            if let error = error {
                self?.sendToolError(connection: connection, id: id, message: error.localizedDescription)
            } else {
                let success = result as? Bool ?? false
                let hidden = action == "hide"
                self?.sendToolResult(connection: connection, id: id, content: ["success": success, "hidden": hidden])
            }
        }
    }

    private func handleUINameToggle(id: Any?, connection: NWConnection) {
        executeJavaScript?("window.__nakiPlayerNames?.toggle() || false") { [weak self] result, error in
            if let error = error {
                self?.sendToolError(connection: connection, id: id, message: error.localizedDescription)
            } else {
                let success = result as? Bool ?? false
                // 獲取當前狀態
                self?.executeJavaScript?("window.__nakiPlayerNames?.hidden || false") { statusResult, _ in
                    let hidden = statusResult as? Bool ?? false
                    self?.sendToolResult(connection: connection, id: id, content: ["success": success, "hidden": hidden])
                }
            }
        }
    }

    // MARK: - Helper Methods

    /// 執行 JavaScript 並返回 MCP 結果
    private func executeJSForMCP(_ script: String, id: Any?, connection: NWConnection, parseJSON: Bool = false) {
        executeJavaScript?(script) { [weak self] result, error in
            DispatchQueue.main.async {
                if let error = error {
                    self?.sendToolError(connection: connection, id: id, message: error.localizedDescription)
                } else if parseJSON, let jsonString = result as? String,
                          let data = jsonString.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: data) {
                    self?.sendToolResult(connection: connection, id: id, content: json)
                } else {
                    self?.sendToolResult(connection: connection, id: id, content: ["result": result ?? NSNull()])
                }
            }
        }
    }

    /// 構建 Help 內容
    func buildHelpContent() -> [String: Any] {
        return [
            "name": "Naki Debug API",
            "version": "1.0",
            "description": "Naki 麻將 AI 助手的 Debug API，用於監控遊戲狀態、控制 Bot、執行遊戲操作",
            "base_url": "http://localhost:\(serverPort)",
            "mcp_endpoint": "http://localhost:\(serverPort)/mcp",
            "tools_count": mcpTools.count,
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
