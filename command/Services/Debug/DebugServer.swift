//
//  DebugServer.swift
//  Naki
//
//  Created by Claude on 2025/12/01.
//  本地 HTTP MCP Server - 允許外部工具控制 App
//

import Foundation
import Network

// MARK: - MCP Server

/// 本地 HTTP MCP Server
class DebugServer {

    // MARK: - Properties

    private var listener: NWListener?
    private let preferredPort: UInt16
    private(set) var actualPort: UInt16 = 0
    private var isRunning = false
    private let maxPortRetries = 10

    /// WebView 執行 JavaScript 的回調
    var executeJavaScript: ((String, @escaping (Any?, Error?) -> Void) -> Void)?

    /// 日誌回調
    var onLog: ((String) -> Void)?

    /// 端口變更回調
    var onPortChanged: ((UInt16) -> Void)?

    /// 日誌存儲（最多保留 10000 條）
    private var logBuffer: [String] = []
    private let maxLogCount = 10000

    /// 獲取 Bot 狀態的回調
    var getBotStatus: (() -> [String: Any])?

    /// 手動觸發自動打牌的回調
    var triggerAutoPlay: (() -> Void)?

    /// MCP 協議處理器
    private let mcpHandler = MCPHandler()

    // MARK: - Initialization

    init(port: UInt16 = 8765) {
        self.preferredPort = port
        self.actualPort = port
        setupMCPHandler()
    }

    /// 設置 MCP Handler 的回調
    private func setupMCPHandler() {
        mcpHandler.serverPort = actualPort
        mcpHandler.executeJavaScript = { [weak self] script, completion in
            self?.executeJavaScript?(script, completion)
        }
        mcpHandler.getBotStatus = { [weak self] in
            self?.getBotStatus?() ?? [:]
        }
        mcpHandler.triggerAutoPlay = { [weak self] in
            self?.triggerAutoPlay?()
        }
        mcpHandler.getLogs = { [weak self] in
            // 合併 DebugServer log 和 LogManager log
            let serverLogs = self?.logBuffer ?? []
            let managerLogs = LogManager.shared.entries.map { entry in
                let timestamp = ISO8601DateFormatter().string(from: entry.timestamp)
                return "[\(timestamp)] [\(entry.category.rawValue)] \(entry.message)"
            }
            // 按時間排序合併
            return (serverLogs + managerLogs).sorted()
        }
        mcpHandler.clearLogs = { [weak self] in
            self?.logBuffer.removeAll()
            LogManager.shared.clear()
        }
        mcpHandler.log = { [weak self] message in
            self?.log(message)
        }
        mcpHandler.sendResponse = { [weak self] connection, status, body, contentType in
            self?.sendResponse(connection: connection, status: status, body: body, contentType: contentType)
        }
    }

    // MARK: - Server Control

    /// 啟動 Server（會自動嘗試其他端口如果被佔用）
    func start() {
        guard !isRunning else {
            log("Server already running on port \(actualPort)")
            return
        }

        startWithPort(preferredPort, retryCount: 0)
    }

    private func startWithPort(_ port: UInt16, retryCount: Int) {
        guard retryCount < maxPortRetries else {
            log("Failed to start server after \(maxPortRetries) attempts")
            return
        }

        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true

            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                log("Invalid port: \(port)")
                return
            }

            listener = try NWListener(using: parameters, on: nwPort)
            listener?.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                switch state {
                case .ready:
                    self.actualPort = port
                    self.isRunning = true
                    self.mcpHandler.serverPort = port
                    self.log("MCP Server started on http://localhost:\(port)")
                    self.onPortChanged?(port)
                case .failed(let error):
                    self.log("Server failed on port \(port): \(error)")
                    self.listener?.cancel()
                    self.listener = nil
                    // 嘗試下一個端口
                    let nextPort = port + 1
                    self.log("Trying port \(nextPort)...")
                    self.startWithPort(nextPort, retryCount: retryCount + 1)
                case .cancelled:
                    self.log("Server cancelled")
                    self.isRunning = false
                default:
                    break
                }
            }

            listener?.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }

            listener?.start(queue: .main)

        } catch {
            log("Failed to start server on port \(port): \(error)")
            // 嘗試下一個端口
            let nextPort = port + 1
            log("Trying port \(nextPort)...")
            startWithPort(nextPort, retryCount: retryCount + 1)
        }
    }

    /// 停止 Server
    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
        log("MCP Server stopped")
    }

    // MARK: - Connection Handling

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .main)

        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            if let data = data, let request = String(data: data, encoding: .utf8) {
                self?.handleRequest(request, connection: connection)
            } else if let error = error {
                self?.log("Connection error: \(error)")
                connection.cancel()
            }
        }
    }

    private func handleRequest(_ request: String, connection: NWConnection) {
        // 解析 HTTP 請求
        let lines = request.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else {
            sendResponse(connection: connection, status: 400, body: "Bad Request")
            return
        }

        let parts = firstLine.components(separatedBy: " ")
        guard parts.count >= 2 else {
            sendResponse(connection: connection, status: 400, body: "Bad Request")
            return
        }

        let method = parts[0]
        let path = parts[1]

        log("Request: \(method) \(path)")

        // 解析 POST body
        var body = ""
        if method == "POST", let emptyLineIndex = lines.firstIndex(of: "") {
            body = lines[(emptyLineIndex + 1)...].joined(separator: "\r\n")
        }

        // 路由處理
        switch (method, path) {
        case ("GET", "/"):
            handleRoot(connection: connection)

        case ("GET", "/help"):
            handleHelp(connection: connection)

        case ("GET", "/status"):
            handleStatus(connection: connection)

        case ("POST", "/js"):
            handleJavaScript(body: body, connection: connection)

        case ("GET", "/detect"):
            handleDetect(connection: connection)

        case ("GET", "/explore"):
            handleExplore(connection: connection)

        case ("GET", "/test-indicators"):
            handleTestIndicators(connection: connection)

        case ("POST", "/click"):
            handleClick(body: body, connection: connection)

        case ("POST", "/calibrate"):
            handleCalibrate(body: body, connection: connection)

        // 遊戲 API 端點
        case ("GET", "/game/state"):
            handleGameState(connection: connection)

        case ("GET", "/game/hand"):
            handleGameHand(connection: connection)

        case ("GET", "/game/ops"):
            handleGameOps(connection: connection)

        case ("POST", "/game/discard"):
            handleGameDiscard(body: body, connection: connection)

        case ("POST", "/game/action"):
            handleGameAction(body: body, connection: connection)

        // Debug 端點
        case ("GET", "/logs"):
            handleLogs(connection: connection)

        case ("DELETE", "/logs"):
            handleClearLogs(connection: connection)

        case ("GET", "/bot/status"):
            handleBotStatus(connection: connection)

        case ("POST", "/bot/trigger"):
            handleTriggerAutoPlay(connection: connection)

        case ("GET", "/bot/ops"):
            handleExploreOps(connection: connection)

        case ("GET", "/bot/deep"):
            handleDeepExplore(connection: connection)

        case ("POST", "/bot/chi"):
            handleTestChi(connection: connection)

        case ("POST", "/bot/pon"):
            handleTestPon(connection: connection)

        // MCP Protocol 端點（委託給 MCPHandler）
        case ("POST", "/mcp"):
            mcpHandler.handleRequest(body: body, headers: lines, connection: connection)

        // UI 控制端點
        case ("GET", "/ui/names"):
            handleGetPlayerNamesStatus(connection: connection)

        case ("POST", "/ui/names/hide"):
            handleHidePlayerNames(connection: connection)

        case ("POST", "/ui/names/show"):
            handleShowPlayerNames(connection: connection)

        case ("POST", "/ui/names/toggle"):
            handleTogglePlayerNames(connection: connection)

        default:
            sendResponse(connection: connection, status: 404, body: "Not Found: \(path)")
        }
    }

    // MARK: - MCP Tool Helper

    /// 調用 MCP 工具並發送 HTTP 響應
    private func callToolAndRespond(tool: String, arguments: [String: Any] = [:], connection: NWConnection) {
        mcpHandler.callTool(name: tool, arguments: arguments) { [weak self] result in
            switch result {
            case .success(let value):
                if let dict = value as? [String: Any] {
                    self?.sendJSON(connection: connection, data: dict)
                } else if let array = value as? [Any] {
                    self?.sendJSON(connection: connection, data: ["data": array])
                } else {
                    self?.sendJSON(connection: connection, data: ["result": value])
                }
            case .error(let message):
                self?.sendJSON(connection: connection, data: ["error": message])
            }
        }
    }

    // MARK: - Request Handlers

    private func handleRoot(connection: NWConnection) {
        let html = """
        <!DOCTYPE html>
        <html>
        <head><title>Naki MCP Server</title></head>
        <body>
        <h1>🀄 Naki MCP Server</h1>
        <h2>Available Endpoints:</h2>
        <ul>
            <li><code>GET /status</code> - Get server status</li>
            <li><code>POST /js</code> - Execute JavaScript (body: JS code)</li>
            <li><code>GET /detect</code> - Detect game API</li>
            <li><code>GET /explore</code> - Explore game objects</li>
            <li><code>GET /test-indicators</code> - Show click indicators</li>
            <li><code>POST /click</code> - Click at position (body: {"x":100,"y":200})</li>
            <li><code>POST /calibrate</code> - Set calibration (body: {"tileSpacing":96,"offsetX":-200,"offsetY":0})</li>
        </ul>
        <h3>Game API:</h3>
        <ul>
            <li><code>GET /game/state</code> - Get current game state</li>
            <li><code>GET /game/hand</code> - Get hand tiles info</li>
            <li><code>GET /game/ops</code> - Get available operations</li>
            <li><code>POST /game/discard</code> - Discard tile (body: {"tileIndex":0})</li>
            <li><code>POST /game/action</code> - Execute action (body: {"action":"pass"})</li>
        </ul>
        <h3>Debug & Auto-Play:</h3>
        <ul>
            <li><code>GET /logs</code> - Get debug logs</li>
            <li><code>DELETE /logs</code> - Clear logs</li>
            <li><code>GET /bot/status</code> - Get bot and auto-play status</li>
            <li><code>POST /bot/trigger</code> - Manually trigger auto-play</li>
            <li><code>GET /bot/ops</code> - Explore available operations (chi/pon/kan)</li>
            <li><code>GET /bot/deep</code> - Deep explore naki API (all methods)</li>
            <li><code>POST /bot/chi</code> - Test chi operation</li>
            <li><code>POST /bot/pon</code> - Test pon operation</li>
        </ul>
        <h2>Quick Test:</h2>
        <pre>curl http://localhost:\(actualPort)/status</pre>
        <pre>curl http://localhost:\(actualPort)/bot/status</pre>
        <pre>curl http://localhost:\(actualPort)/logs</pre>
        <pre>curl -X POST http://localhost:\(actualPort)/bot/trigger</pre>
        <h2>Naki Test (when opportunity available):</h2>
        <pre>curl http://localhost:\(actualPort)/bot/deep</pre>
        <pre>curl -X POST http://localhost:\(actualPort)/bot/chi</pre>
        <pre>curl -X POST http://localhost:\(actualPort)/bot/pon</pre>
        <h3>UI Control:</h3>
        <ul>
            <li><code>GET /ui/names</code> - Get player names visibility status</li>
            <li><code>POST /ui/names/hide</code> - Hide all player names</li>
            <li><code>POST /ui/names/show</code> - Show all player names</li>
            <li><code>POST /ui/names/toggle</code> - Toggle player names visibility</li>
        </ul>
        <h2>Quick UI Control:</h2>
        <pre>curl http://localhost:\(actualPort)/ui/names</pre>
        <pre>curl -X POST http://localhost:\(actualPort)/ui/names/hide</pre>
        <pre>curl -X POST http://localhost:\(actualPort)/ui/names/show</pre>
        </body>
        </html>
        """
        sendResponse(connection: connection, status: 200, body: html, contentType: "text/html")
    }

    private func handleStatus(connection: NWConnection) {
        callToolAndRespond(tool: "get_status", connection: connection)
    }

    /// AI 友好的 Help 端點 - 返回結構化的 API 文檔
    private func handleHelp(connection: NWConnection) {
        callToolAndRespond(tool: "get_help", connection: connection)
    }

    private func handleJavaScript(body: String, connection: NWConnection) {
        guard !body.isEmpty else {
            sendJSON(connection: connection, data: ["error": "No JavaScript code provided"])
            return
        }
        callToolAndRespond(tool: "execute_js", arguments: ["code": body], connection: connection)
    }

    private func handleDetect(connection: NWConnection) {
        callToolAndRespond(tool: "detect", connection: connection)
    }

    private func handleExplore(connection: NWConnection) {
        callToolAndRespond(tool: "explore", connection: connection)
    }

    private func handleTestIndicators(connection: NWConnection) {
        callToolAndRespond(tool: "test_indicators", connection: connection)
    }

    private func handleClick(body: String, connection: NWConnection) {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let x = json["x"] as? Double,
              let y = json["y"] as? Double else {
            sendJSON(connection: connection, data: ["error": "Invalid JSON. Expected: {\"x\": 100, \"y\": 200}"])
            return
        }
        let label = json["label"] as? String ?? "API Click"
        callToolAndRespond(tool: "click", arguments: ["x": x, "y": y, "label": label], connection: connection)
    }

    private func handleCalibrate(body: String, connection: NWConnection) {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            sendJSON(connection: connection, data: ["error": "Invalid JSON"])
            return
        }
        callToolAndRespond(tool: "calibrate", arguments: json, connection: connection)
    }

    // MARK: - Game API Handlers

    private func handleGameState(connection: NWConnection) {
        callToolAndRespond(tool: "game_state", connection: connection)
    }

    private func handleGameHand(connection: NWConnection) {
        callToolAndRespond(tool: "game_hand", connection: connection)
    }

    private func handleGameOps(connection: NWConnection) {
        callToolAndRespond(tool: "game_ops", connection: connection)
    }

    private func handleGameDiscard(body: String, connection: NWConnection) {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tileIndex = json["tileIndex"] as? Int else {
            sendJSON(connection: connection, data: ["error": "Invalid JSON. Expected: {\"tileIndex\": 0}"])
            return
        }
        callToolAndRespond(tool: "game_discard", arguments: ["tileIndex": tileIndex], connection: connection)
    }

    private func handleGameAction(body: String, connection: NWConnection) {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = json["action"] as? String else {
            sendJSON(connection: connection, data: ["error": "Invalid JSON. Expected: {\"action\": \"pass\"}"])
            return
        }
        let params = json["params"] as? [String: Any] ?? [:]
        callToolAndRespond(tool: "game_action", arguments: ["action": action, "params": params], connection: connection)
    }

    // MARK: - Debug Handlers

    private func handleLogs(connection: NWConnection) {
        callToolAndRespond(tool: "get_logs", connection: connection)
    }

    private func handleClearLogs(connection: NWConnection) {
        callToolAndRespond(tool: "clear_logs", connection: connection)
    }

    private func handleBotStatus(connection: NWConnection) {
        callToolAndRespond(tool: "bot_status", connection: connection)
    }

    private func handleTriggerAutoPlay(connection: NWConnection) {
        callToolAndRespond(tool: "bot_trigger", connection: connection)
    }

    private func handleExploreOps(connection: NWConnection) {
        callToolAndRespond(tool: "bot_ops", connection: connection)
    }

    private func handleDeepExplore(connection: NWConnection) {
        callToolAndRespond(tool: "bot_deep", connection: connection)
    }

    private func handleTestChi(connection: NWConnection) {
        callToolAndRespond(tool: "bot_chi", connection: connection)
    }

    private func handleTestPon(connection: NWConnection) {
        callToolAndRespond(tool: "bot_pon", connection: connection)
    }

    // MARK: - UI Control Handlers

    private func handleGetPlayerNamesStatus(connection: NWConnection) {
        callToolAndRespond(tool: "ui_names_status", connection: connection)
    }

    private func handleHidePlayerNames(connection: NWConnection) {
        callToolAndRespond(tool: "ui_names_hide", connection: connection)
    }

    private func handleShowPlayerNames(connection: NWConnection) {
        callToolAndRespond(tool: "ui_names_show", connection: connection)
    }

    private func handleTogglePlayerNames(connection: NWConnection) {
        callToolAndRespond(tool: "ui_names_toggle", connection: connection)
    }

    // MARK: - Response Helpers

    private func sendResponse(connection: NWConnection, status: Int, body: String, contentType: String = "text/plain") {
        let statusText: String
        switch status {
        case 200: statusText = "OK"
        case 400: statusText = "Bad Request"
        case 404: statusText = "Not Found"
        case 500: statusText = "Internal Server Error"
        default: statusText = "Unknown"
        }

        let response = """
        HTTP/1.1 \(status) \(statusText)\r
        Content-Type: \(contentType); charset=utf-8\r
        Content-Length: \(body.utf8.count)\r
        Access-Control-Allow-Origin: *\r
        Connection: close\r
        \r
        \(body)
        """

        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func sendJSON(connection: NWConnection, data: [String: Any]) {
        do {
            if data.isEmpty {
                throw NSError(domain: "MCPServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Empty JSON data"])
            }

            let sanitized = sanitizeForJSON(data) as! [String: Any]
            let jsonData = try JSONSerialization.data(withJSONObject: sanitized, options: .prettyPrinted)
            let body = String(data: jsonData, encoding: .utf8) ?? "{}"
            sendResponse(connection: connection, status: 200, body: body, contentType: "application/json")
        } catch {
            sendResponse(connection: connection, status: 500, body: "{\"error\": \"JSON serialization failed\"}", contentType: "application/json")
        }
    }

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

    // MARK: - Logging

    private func log(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let logMessage = "[\(timestamp)] \(message)"
        print("[MCPServer] \(message)")

        // 存儲到 buffer
        logBuffer.append(logMessage)
        if logBuffer.count > maxLogCount {
            logBuffer.removeFirst()
        }

        onLog?(logMessage)
    }

    /// 添加外部日誌
    func addLog(_ message: String) {
        log(message)
    }

    /// 獲取所有日誌
    func getLogs() -> [String] {
        return logBuffer
    }

    /// 清空日誌
    func clearLogs() {
        logBuffer.removeAll()
    }
}
