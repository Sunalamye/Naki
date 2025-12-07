//
//  MCPHTTPServer.swift
//  MCPKit
//
//  HTTP 傳輸層實現
//  提供 HTTP 伺服器來處理 MCP 請求
//

import Foundation
import Network

// MARK: - MCP HTTP Server

/// MCP HTTP 伺服器
/// 提供 HTTP 端點來處理 MCP JSON-RPC 請求
@MainActor
public final class MCPHTTPServer {

    // MARK: - Properties

    private var listener: NWListener?
    private let preferredPort: UInt16
    private(set) public var actualPort: UInt16 = 0
    private var isRunning = false
    private let maxPortRetries = 10

    /// MCP 處理器
    public let handler: MCPHandler

    /// 日誌回調
    public var onLog: ((String) -> Void)?

    /// 端口變更回調
    public var onPortChanged: ((UInt16) -> Void)?

    /// 額外的 HTTP 路由處理器
    public var customRoutes: [String: (String, String, @escaping (Int, String, String) -> Void) -> Bool] = [:]

    // MARK: - Initialization

    public init(context: MCPContext, registry: MCPToolRegistry? = nil, port: UInt16 = 8765) {
        self.preferredPort = port
        self.actualPort = port
        self.handler = MCPHandler(context: context, registry: registry)
    }

    // MARK: - Server Control

    /// 啟動 Server（會自動嘗試其他端口如果被佔用）
    public func start() {
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
                Task { @MainActor in
                    guard let self = self else { return }
                    switch state {
                    case .ready:
                        self.actualPort = port
                        self.isRunning = true
                        self.log("MCP Server started on http://localhost:\(port)")
                        self.onPortChanged?(port)
                    case .failed(let error):
                        self.log("Server failed on port \(port): \(error)")
                        self.listener?.cancel()
                        self.listener = nil
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
            }

            listener?.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    self?.handleConnection(connection)
                }
            }

            listener?.start(queue: .main)

        } catch {
            log("Failed to start server on port \(port): \(error)")
            let nextPort = port + 1
            log("Trying port \(nextPort)...")
            startWithPort(nextPort, retryCount: retryCount + 1)
        }
    }

    /// 停止 Server
    public func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
        log("MCP Server stopped")
    }

    // MARK: - Connection Handling

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .main)

        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            Task { @MainActor in
                if let data = data, let request = String(data: data, encoding: .utf8) {
                    self?.handleRequest(request, connection: connection)
                } else if let error = error {
                    self?.log("Connection error: \(error)")
                    connection.cancel()
                }
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

        // 檢查自定義路由
        let routeKey = "\(method) \(path)"
        if let customHandler = customRoutes[routeKey] {
            let handled = customHandler(method, body) { [weak self] status, responseBody, contentType in
                self?.sendResponse(connection: connection, status: status, body: responseBody, contentType: contentType)
            }
            if handled { return }
        }

        // 內建路由
        switch (method, path) {
        case ("GET", "/"):
            handleRoot(connection: connection)

        case ("GET", "/status"):
            handleStatus(connection: connection)

        case ("POST", "/mcp"):
            handleMCP(body: body, connection: connection)

        default:
            sendResponse(connection: connection, status: 404, body: "Not Found: \(path)")
        }
    }

    // MARK: - Built-in Handlers

    private func handleRoot(connection: NWConnection) {
        let html = """
        <!DOCTYPE html>
        <html>
        <head><title>MCP Server</title></head>
        <body>
        <h1>🔌 MCP Server</h1>
        <h2>Available Endpoints:</h2>
        <ul>
            <li><code>GET /status</code> - Get server status</li>
            <li><code>POST /mcp</code> - MCP JSON-RPC endpoint</li>
        </ul>
        <h2>Registered Tools: \(handler.registry.count)</h2>
        <ul>
        \(handler.registry.registeredToolNames.map { "<li><code>\($0)</code></li>" }.joined(separator: "\n"))
        </ul>
        <h2>Quick Test:</h2>
        <pre>curl http://localhost:\(actualPort)/status</pre>
        </body>
        </html>
        """
        sendResponse(connection: connection, status: 200, body: html, contentType: "text/html")
    }

    private func handleStatus(connection: NWConnection) {
        let status: [String: Any] = [
            "status": "running",
            "port": actualPort,
            "serverName": handler.serverName,
            "serverVersion": handler.serverVersion,
            "toolsCount": handler.registry.count,
            "tools": handler.registry.registeredToolNames
        ]
        sendJSON(connection: connection, data: status)
    }

    private func handleMCP(body: String, connection: NWConnection) {
        handler.handleRequest(body: body) { [weak self] status, responseBody, contentType in
            self?.sendResponse(connection: connection, status: status, body: responseBody, contentType: contentType)
        }
    }

    // MARK: - Response Helpers

    public func sendResponse(connection: NWConnection, status: Int, body: String, contentType: String = "text/plain") {
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

    public func sendJSON(connection: NWConnection, data: [String: Any]) {
        do {
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
        print("[MCPServer] \(message)")
        onLog?(message)
    }
}

// MARK: - Route Registration Extension

public extension MCPHTTPServer {
    /// 註冊 GET 路由
    func get(_ path: String, handler: @escaping (String, @escaping (Int, String, String) -> Void) -> Void) {
        customRoutes["GET \(path)"] = { _, body, completion in
            handler(body, completion)
            return true
        }
    }

    /// 註冊 POST 路由
    func post(_ path: String, handler: @escaping (String, @escaping (Int, String, String) -> Void) -> Void) {
        customRoutes["POST \(path)"] = { _, body, completion in
            handler(body, completion)
            return true
        }
    }

    /// 註冊 DELETE 路由
    func delete(_ path: String, handler: @escaping (String, @escaping (Int, String, String) -> Void) -> Void) {
        customRoutes["DELETE \(path)"] = { _, body, completion in
            handler(body, completion)
            return true
        }
    }
}
