//
//  DebugServer.swift
//  Naki
//
//  Created by Claude on 2025/12/01.
//  本地 HTTP MCP Server - 允許外部工具控制 App
//

#if os(macOS)

import Foundation
import Network
import MCPKit
import MCPWebKit

// MARK: - Request Models

/// JavaScript 執行請求
private struct ExecuteJSRequest: Codable {
    let code: String
}

// MARK: - MCP Server

/// 本地 HTTP MCP Server
/// 支援 macOS 14.0+，使用回調式 JavaScript 執行抽象
class DebugServer {

    // MARK: - Properties

    private var listener: NWListener?
    private let preferredPort: UInt16
    private(set) var actualPort: UInt16 = 0
    private var isRunning = false
    private let maxPortRetries = 10

    /// WebView 執行 JavaScript 的回調
    var executeJavaScript: ((String, @escaping (Any?, Error?) -> Void) -> Void)?

    /// WebView 截圖回調，回傳 PNG bytes
    ///
    /// 走 `WebPage.exported(as: .image(...))` 而不是 OS 層的 `screencapture`：
    /// 後者需要「螢幕錄製」權限，而且抓的是螢幕上那塊區域——視窗被遮住、
    /// 在其他 Space、或最小化就拍不到。WebView 自己輸出則不受這些影響。
    var captureScreenshot: ((@escaping (Data?, Error?) -> Void) -> Void)?

    /// 日誌回調
    var onLog: ((String) -> Void)?

    /// 端口變更回調
    var onPortChanged: ((UInt16) -> Void)?

    /// 日誌存儲（最多保留 10000 條）
    private var logBuffer: [String] = []
    private let maxLogCount = 10000

    /// 單一 HTTP request 累積上限（含 header + body），避免超大或惡意 body 造成無限等待 / 記憶體爆掉
    private let maxRequestSize = 10 * 1024 * 1024  // 10 MB

    /// 獲取 Bot 狀態的回調
    var getBotStatus: (() -> [String: Any])?

    /// 手動觸發自動打牌的回調
    var triggerAutoPlay: (() -> Void)?

    /// 送出 Liqi 請求的回調（Unity 時代的動作／大廳面；由 WebViewModel 注入）
    var sendLiqi: ((LiqiRequestSpec, Int) async -> LiqiToolSendOutcome)?

    /// 遊戲狀態快照回調（Swift 協定層供給）
    var getGameSnapshot: (() -> [String: Any])?

    /// 自動心跳（防閒置）開關回調
    var setAntiIdle: ((Bool?, TimeInterval?) -> [String: Any])?

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
        mcpHandler.sendLiqi = { [weak self] spec, awaitMs in
            guard let handler = self?.sendLiqi else {
                return .unavailable("debug_server_liqi_sender_not_configured")
            }
            return await handler(spec, awaitMs)
        }
        mcpHandler.getGameSnapshot = { [weak self] in
            self?.getGameSnapshot?() ?? [:]
        }
        mcpHandler.setAntiIdle = { [weak self] enabled, interval in
            self?.setAntiIdle?(enabled, interval) ?? [:]
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
            // #22 帳號安全：只綁 loopback interface（127.0.0.1 / ::1），阻止同網段其他裝置
            // 存取這個能在遊戲 context 執行 JS 的 debug/MCP server。
            parameters.requiredInterfaceType = .loopback

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
        receiveRequest(connection: connection, buffer: Data())
    }

    /// 持續 receive 累積資料，直到整條 HTTP request 收滿（header + Content-Length 指定的 body）
    /// 或連線結束 / 達到大小上限。解決大的 `/js`、`/mcp` body 跨 TCP 段被截斷的問題。
    private func receiveRequest(connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            var accumulated = buffer
            if let data = data, !data.isEmpty {
                accumulated.append(data)
            }

            // 上限保護：避免無限等待 / 記憶體爆掉
            if accumulated.count > self.maxRequestSize {
                self.log("Request exceeds max size (\(accumulated.count) > \(self.maxRequestSize)), rejecting")
                self.sendResponse(connection: connection, status: 400, body: "Request Entity Too Large")
                return
            }

            // 對端已關閉（half-close）或發生錯誤，視為不會再有更多資料
            let ended = isComplete || (error != nil)

            // 完全沒收到資料的錯誤 → 直接關閉
            if let error = error, accumulated.isEmpty {
                self.log("Connection error: \(error)")
                connection.cancel()
                return
            }

            // 尚未收到任何資料
            if accumulated.isEmpty {
                if ended {
                    connection.cancel()
                } else {
                    self.receiveRequest(connection: connection, buffer: accumulated)
                }
                return
            }

            // 檢查 HTTP header 是否收齊（\r\n\r\n）
            guard let headerEnd = accumulated.range(of: Data([0x0d, 0x0a, 0x0d, 0x0a])) else {
                if ended {
                    // 連線結束但 header 仍不完整 → 用現有資料盡力處理
                    self.processRequestData(accumulated, connection: connection)
                } else {
                    self.receiveRequest(connection: connection, buffer: accumulated)
                }
                return
            }

            // 解析 Content-Length，判斷 body 是否收滿
            let headerData = accumulated.subdata(in: accumulated.startIndex..<headerEnd.lowerBound)
            let expectedBodyLength = self.parseContentLength(fromHeaderData: headerData) ?? 0
            let currentBodyLength = accumulated.distance(from: headerEnd.upperBound, to: accumulated.endIndex)

            if currentBodyLength >= expectedBodyLength || ended {
                // body 已收滿（或連線結束）→ 處理
                self.processRequestData(accumulated, connection: connection)
            } else {
                // body 跨 TCP 段尚未收滿，繼續累積
                self.receiveRequest(connection: connection, buffer: accumulated)
            }
        }
    }

    /// 將完整 request 資料轉為字串並交給路由處理
    private func processRequestData(_ data: Data, connection: NWConnection) {
        if let request = String(data: data, encoding: .utf8) {
            handleRequest(request, connection: connection)
        } else {
            // 非 UTF-8：用 lossy 解碼避免整條丟棄
            handleRequest(String(decoding: data, as: UTF8.self), connection: connection)
        }
    }

    /// 從 HTTP header 區塊解析 Content-Length（大小寫不敏感）
    private func parseContentLength(fromHeaderData headerData: Data) -> Int? {
        guard let headerString = String(data: headerData, encoding: .utf8) else { return nil }
        for line in headerString.components(separatedBy: "\r\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            if name == "content-length" {
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                return Int(value)
            }
        }
        return nil
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
        let rawPath = parts[1]
        // query string 要拆掉，否則 `/screenshot?mode=view` 會走到 404
        let path = rawPath.components(separatedBy: "?").first ?? rawPath
        _ = rawPath.components(separatedBy: "?").dropFirst()  // query 目前沒有端點需要

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
        case ("GET", "/screenshot"):
            handleScreenshot(connection: connection)

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
            <li><code>GET /help</code> - Current JSON API help</li>
            <li><code>GET /status</code> - Get server status</li>
            <li><code>POST /js</code> - Execute a JavaScript function body (use return for a value)</li>
            <li><code>GET /logs</code> / <code>DELETE /logs</code> - Read / clear in-memory logs</li>
            <li><code>POST /mcp</code> - MCP JSON-RPC endpoint</li>
        </ul>
        <h3>Game API:</h3>
        <ul>
            <li><code>GET /game/state</code> - Get Naki's Swift protocol-layer snapshot</li>
            <li><code>GET /game/hand</code> - Get hand and recommendations</li>
            <li><code>GET /game/ops</code> - Get pending / latest Liqi operations</li>
            <li><code>POST /game/discard</code> - Discard by tile string (body: {"tile":"5m","moqie":false})</li>
            <li><code>POST /game/action</code> - Execute action (body: {"action":"pass"})</li>
        </ul>
        <h3>Debug & Auto-Play:</h3>
        <ul>
            <li><code>GET /bot/status</code> - Get bot and auto-play status</li>
            <li><code>POST /bot/trigger</code> - Manually trigger auto-play</li>
            <li><code>GET /bot/ops</code> - Get Liqi operation snapshot</li>
            <li><code>GET /bot/deep</code> - Get protocol-layer diagnostics</li>
            <li><code>POST /bot/chi</code> - Send chi (real account action)</li>
            <li><code>POST /bot/pon</code> - Send pon (real account action)</li>
        </ul>
        <h2>Quick Test:</h2>
        <pre>curl http://localhost:\(actualPort)/status</pre>
        <pre>curl http://localhost:\(actualPort)/bot/status</pre>
        <pre>curl http://localhost:\(actualPort)/logs</pre>
        <h2>Account-affecting actions (test account only):</h2>
        <pre>curl -X POST http://localhost:\(actualPort)/bot/trigger  # requires a current legal oplist</pre>
        <pre>curl http://localhost:\(actualPort)/bot/deep</pre>
        <pre>curl -X POST http://localhost:\(actualPort)/bot/chi</pre>
        <pre>curl -X POST http://localhost:\(actualPort)/bot/pon</pre>
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

        // 解析 JSON 請求，支持 {"code": "..."} 或純文本
        let code: String
        if let data = body.data(using: .utf8),
           let request = try? JSONDecoder().decode(ExecuteJSRequest.self, from: data) {
            code = request.code
        } else {
            // 向後兼容：純文本作為 code
            code = body
        }

        callToolAndRespond(tool: "execute_js", arguments: ["code": code], connection: connection)
    }

    private func handleScreenshot(connection: NWConnection) {
        guard let capture = captureScreenshot else {
            sendJSON(connection: connection, data: ["error": "screenshot not wired"])
            return
        }
        capture { [weak self] data, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.sendBinary(connection: connection, data: data, contentType: "image/png")
            } else {
                self.sendJSON(connection: connection,
                              data: ["error": error?.localizedDescription ?? "empty snapshot"])
            }
        }
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

    /// 打牌：Unity 下沒有 UI 手牌陣列，改以牌字串指定（MJAI 或雀魂記法皆可）
    private func handleGameDiscard(body: String, connection: NWConnection) {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tile = json["tile"] as? String else {
            sendJSON(connection: connection,
                     data: ["error": "Invalid JSON. Expected: {\"tile\": \"5m\", \"moqie\": false}"])
            return
        }
        var arguments: [String: Any] = ["tile": tile]
        if let moqie = json["moqie"] as? Bool { arguments["moqie"] = moqie }
        callToolAndRespond(tool: "game_discard", arguments: arguments, connection: connection)
    }

    private func handleGameAction(body: String, connection: NWConnection) {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = json["action"] as? String else {
            sendJSON(connection: connection, data: ["error": "Invalid JSON. Expected: {\"action\": \"pass\"}"])
            return
        }
        // 參數改為平鋪（tile / moqie / index / kanType / timeuse），
        // 同時相容舊的 {"params": {...}} 包裝
        var arguments: [String: Any] = json
        if let params = json["params"] as? [String: Any] {
            arguments.removeValue(forKey: "params")
            arguments.merge(params) { _, new in new }
        }
        arguments["action"] = action
        callToolAndRespond(tool: "game_action", arguments: arguments, connection: connection)
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
        Access-Control-Allow-Origin: http://localhost:\(actualPort)\r
        Connection: close\r
        \r
        \(body)
        """

        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    /// 送 binary body。`sendResponse` 是 String-only，PNG 走那條會被 UTF-8 轉換破壞。
    private func sendBinary(connection: NWConnection, data: Data, contentType: String) {
        let header = """
        HTTP/1.1 200 OK\r
        Content-Type: \(contentType)\r
        Content-Length: \(data.count)\r
        Access-Control-Allow-Origin: http://localhost:\(actualPort)\r
        Connection: close\r
        \r
        
        """
        var payload = Data(header.utf8)
        payload.append(data)
        connection.send(content: payload, completion: .contentProcessed { _ in
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
        // buffer 自己保留時間戳（`/logs` 直接回這份）
        let timestamp = ISO8601DateFormatter().string(from: Date())
        logBuffer.append("[\(timestamp)] \(message)")
        if logBuffer.count > maxLogCount {
            logBuffer.removeFirst()
        }

        // 轉給 LogManager 的是**原始訊息**。
        // 先前傳的是已加時間戳的字串，LogManager 又加一次，
        // 於是檔案裡變成 `[ts] [Bridge] [ts] 訊息`，而且同一件事會出現兩行。
        onLog?(message)
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

#endif  // os(macOS)
