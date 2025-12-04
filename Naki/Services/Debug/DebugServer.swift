//
//  DebugServer.swift
//  Naki
//
//  Created by Claude on 2025/12/01.
//  本地 HTTP Debug Server - 允許外部工具控制 App
//

import Foundation
import Network

// MARK: - Debug Server

/// 本地 HTTP Debug Server
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

    /// ⭐ 日誌存儲（最多保留 10000 條）
    private var logBuffer: [String] = []
    private let maxLogCount = 10000

    /// ⭐ 獲取 Bot 狀態的回調
    var getBotStatus: (() -> [String: Any])?

    /// ⭐ 手動觸發自動打牌的回調
    var triggerAutoPlay: (() -> Void)?

    /// ⭐ 執行 JavaScript 的回調
    var evaluateJS: ((_ script: String, _ completion: @escaping (Any?, Error?) -> Void) -> Void)?

    // MARK: - Initialization

    init(port: UInt16 = 8765) {
        self.preferredPort = port
        self.actualPort = port
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
                    self.log("Debug Server started on http://localhost:\(port)")
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
        log("Debug Server stopped")
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

        // ⭐ 新增：遊戲 API 端點
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

        // ⭐ 新增：Debug 端點
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

        default:
            sendResponse(connection: connection, status: 404, body: "Not Found: \(path)")
        }
    }

    // MARK: - Request Handlers

    private func handleRoot(connection: NWConnection) {
        let html = """
        <!DOCTYPE html>
        <html>
        <head><title>Naki Debug Server</title></head>
        <body>
        <h1>🀄 Naki Debug Server</h1>
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
        </body>
        </html>
        """
        sendResponse(connection: connection, status: 200, body: html, contentType: "text/html")
    }

    private func handleStatus(connection: NWConnection) {
        let status: [String: Any] = [
            "status": "running",
            "port": actualPort,
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
        sendJSON(connection: connection, data: status)
    }

    /// AI 友好的 Help 端點 - 返回結構化的 API 文檔
    private func handleHelp(connection: NWConnection) {
        let help: [String: Any] = [
            "name": "Naki Debug API",
            "version": "1.0",
            "description": "Naki 麻將 AI 助手的 Debug API，用於監控遊戲狀態、控制 Bot、執行遊戲操作",
            "base_url": "http://localhost:\(actualPort)",
            "endpoints": [
                // 系統類
                [
                    "method": "GET",
                    "path": "/",
                    "description": "首頁，HTML 格式的端點列表（人類可讀）",
                    "returns": "HTML"
                ],
                [
                    "method": "GET",
                    "path": "/help",
                    "description": "本端點，JSON 格式的 API 文檔（AI 友好）",
                    "returns": "JSON with complete API documentation"
                ],
                [
                    "method": "GET",
                    "path": "/status",
                    "description": "伺服器狀態和埠號",
                    "returns": "{\"status\": \"running\", \"port\": 8765, \"timestamp\": \"ISO8601\"}"
                ],
                [
                    "method": "GET",
                    "path": "/logs",
                    "description": "獲取 Debug 日誌（最多 10,000 條）",
                    "returns": "{\"logs\": [...], \"count\": number}"
                ],
                [
                    "method": "DELETE",
                    "path": "/logs",
                    "description": "清空所有日誌",
                    "returns": "{\"success\": true}"
                ],
                // Bot 控制類
                [
                    "method": "GET",
                    "path": "/bot/status",
                    "description": "Bot 狀態、手牌、推薦、可用動作",
                    "returns": "Complete bot status with recommendations"
                ],
                [
                    "method": "POST",
                    "path": "/bot/trigger",
                    "description": "手動觸發自動打牌",
                    "returns": "{\"success\": true}"
                ],
                [
                    "method": "GET",
                    "path": "/bot/ops",
                    "description": "探索可用的副露操作 (chi/pon/kan)",
                    "returns": "{\"success\": true, \"data\": {...}}"
                ],
                [
                    "method": "GET",
                    "path": "/bot/deep",
                    "description": "深度探索 naki API (所有方法)",
                    "returns": "{\"success\": true, \"data\": {...}}"
                ],
                [
                    "method": "POST",
                    "path": "/bot/chi",
                    "description": "測試吃操作",
                    "returns": "{\"success\": true, \"data\": {...}}"
                ],
                [
                    "method": "POST",
                    "path": "/bot/pon",
                    "description": "測試碰操作",
                    "returns": "{\"success\": true, \"data\": {...}}"
                ],
                // 遊戲狀態類
                [
                    "method": "GET",
                    "path": "/game/state",
                    "description": "當前遊戲狀態",
                    "returns": "Game state JSON"
                ],
                [
                    "method": "GET",
                    "path": "/game/hand",
                    "description": "手牌資訊",
                    "returns": "Hand tiles info"
                ],
                [
                    "method": "GET",
                    "path": "/game/ops",
                    "description": "當前可用操作",
                    "returns": "{\"ops\": [...]}"
                ],
                [
                    "method": "POST",
                    "path": "/game/discard",
                    "description": "打出指定牌",
                    "body": "{\"tileIndex\": 0}",
                    "returns": "{\"success\": true, \"tileIndex\": 0}"
                ],
                [
                    "method": "POST",
                    "path": "/game/action",
                    "description": "執行遊戲動作",
                    "body": "{\"action\": \"pass\", \"params\": {}}",
                    "returns": "{\"success\": true, \"action\": \"pass\"}"
                ],
                // JavaScript 執行
                [
                    "method": "POST",
                    "path": "/js",
                    "description": "執行任意 JavaScript",
                    "body": "JavaScript code as string",
                    "returns": "{\"result\": ...}"
                ],
                // 探索類
                [
                    "method": "GET",
                    "path": "/detect",
                    "description": "檢測遊戲 API",
                    "returns": "Game API detection result"
                ],
                [
                    "method": "GET",
                    "path": "/explore",
                    "description": "探索遊戲物件",
                    "returns": "Game objects exploration data"
                ],
                // UI 操作類
                [
                    "method": "GET",
                    "path": "/test-indicators",
                    "description": "顯示測試指示器",
                    "returns": "{\"result\": \"OK\"}"
                ],
                [
                    "method": "POST",
                    "path": "/click",
                    "description": "在指定座標點擊",
                    "body": "{\"x\": 100, \"y\": 200, \"label\": \"optional\"}",
                    "returns": "{\"result\": \"clicked\", \"x\": 100, \"y\": 200}"
                ],
                [
                    "method": "POST",
                    "path": "/calibrate",
                    "description": "設定校準參數",
                    "body": "{\"tileSpacing\": 96, \"offsetX\": -200, \"offsetY\": 0}",
                    "returns": "{\"tileSpacing\": 96, \"offsetX\": -200, \"offsetY\": 0}"
                ]
            ],
            "common_workflows": [
                [
                    "name": "監控遊戲狀態",
                    "steps": [
                        "GET /bot/status - 檢查 Bot 狀態和手牌",
                        "GET /logs - 查看最近的操作日誌",
                        "GET /game/state - 獲取當前遊戲狀態"
                    ]
                ],
                [
                    "name": "手動控制自動打牌",
                    "steps": [
                        "GET /bot/status - 查看當前推薦",
                        "POST /bot/trigger - 手動觸發自動打牌",
                        "GET /logs - 查看執行結果"
                    ]
                ],
                [
                    "name": "測試副露操作",
                    "steps": [
                        "GET /bot/ops - 探索可用操作",
                        "POST /bot/chi 或 /bot/pon - 測試具體操作",
                        "GET /logs - 查看測試結果"
                    ]
                ],
                [
                    "name": "執行 JavaScript 調試",
                    "steps": [
                        "POST /js -d 'your_script' - 執行任意 JavaScript",
                        "GET /logs - 查看執行日誌"
                    ]
                ]
            ],
            "tile_notation": [
                "數牌（Suited）": "1-9 + m(萬)/p(筒)/s(索)，如 1m, 5p, 9s",
                "紅寶牌（Red 5s）": "5mr, 5pr, 5sr",
                "字牌（Honor）": "E(東), S(南), W(西), N(北), P(白), F(發), C(中)"
            ],
            "tips": [
                "使用 /help 獲取此文檔",
                "使用 /logs 查看操作歷史",
                "使用 /bot/status 一次性獲取所有狀態",
                "Bot 的推薦按機率排序，第一個通常是最佳選擇",
                "使用 /js 端點執行任意 JavaScript 進行調試",
                "遊戲狀態通過 @import @docs/architecture-deep-dive.md 了解詳細流程"
            ]
        ]
        sendJSON(connection: connection, data: help)
    }

    private func handleJavaScript(body: String, connection: NWConnection) {
        guard !body.isEmpty else {
            sendJSON(connection: connection, data: ["error": "No JavaScript code provided"])
            return
        }

        executeJavaScript?(body) { [weak self] result, error in
            if let error = error {
                self?.sendJSON(connection: connection, data: ["error": error.localizedDescription])
            } else {
                self?.sendJSON(connection: connection, data: ["result": result ?? NSNull()])
            }
        }
    }

    private func handleDetect(connection: NWConnection) {
        executeJavaScript?("window.__nakiDetectGameAPI ? __nakiDetectGameAPI() : {error: 'Not loaded'}") { [weak self] result, error in
            if let error = error {
                self?.sendJSON(connection: connection, data: ["error": error.localizedDescription])
            } else {
                self?.sendJSON(connection: connection, data: ["result": result ?? NSNull()])
            }
        }
    }

    private func handleExplore(connection: NWConnection) {
        executeJavaScript?("window.__nakiExploreGameObjects ? __nakiExploreGameObjects() : {error: 'Not loaded'}") { [weak self] result, error in
            if let error = error {
                self?.sendJSON(connection: connection, data: ["error": error.localizedDescription])
            } else {
                self?.sendJSON(connection: connection, data: ["result": result ?? NSNull()])
            }
        }
    }

    private func handleTestIndicators(connection: NWConnection) {
        executeJavaScript?("window.__nakiTestIndicators ? (__nakiTestIndicators(), 'OK') : 'Not loaded'") { [weak self] result, error in
            if let error = error {
                self?.sendJSON(connection: connection, data: ["error": error.localizedDescription])
            } else {
                self?.sendJSON(connection: connection, data: ["result": result ?? "OK"])
            }
        }
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
        let script = "window.__nakiAutoPlay.click(\(x), \(y), '\(label)')"

        executeJavaScript?(script) { [weak self] result, error in
            if let error = error {
                self?.sendJSON(connection: connection, data: ["error": error.localizedDescription])
            } else {
                self?.sendJSON(connection: connection, data: ["result": "clicked", "x": x, "y": y])
            }
        }
    }

    private func handleCalibrate(body: String, connection: NWConnection) {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            sendJSON(connection: connection, data: ["error": "Invalid JSON"])
            return
        }

        let tileSpacing = json["tileSpacing"] as? Double ?? 96
        let offsetX = json["offsetX"] as? Double ?? -200
        let offsetY = json["offsetY"] as? Double ?? 0

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

        executeJavaScript?(script) { [weak self] result, error in
            if let error = error {
                self?.sendJSON(connection: connection, data: ["error": error.localizedDescription])
            } else {
                self?.sendJSON(connection: connection, data: [
                    "result": "calibrated",
                    "tileSpacing": tileSpacing,
                    "offsetX": offsetX,
                    "offsetY": offsetY
                ])
            }
        }
    }

    // MARK: - Game API Handlers

    private func handleGameState(connection: NWConnection) {
        executeJavaScript?("window.__nakiGameAPI ? JSON.stringify(__nakiGameAPI.getGameState()) : '{\"error\": \"API not loaded\"}'") { [weak self] result, error in
            if let error = error {
                self?.sendJSON(connection: connection, data: ["error": error.localizedDescription])
            } else if let jsonString = result as? String,
                      let data = jsonString.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                self?.sendJSON(connection: connection, data: json)
            } else {
                self?.sendJSON(connection: connection, data: ["error": "Failed to parse game state"])
            }
        }
    }

    private func handleGameHand(connection: NWConnection) {
        executeJavaScript?("window.__nakiGameAPI ? JSON.stringify(__nakiGameAPI.getHandInfo()) : '{\"error\": \"API not loaded\"}'") { [weak self] result, error in
            if let error = error {
                self?.sendJSON(connection: connection, data: ["error": error.localizedDescription])
            } else if let jsonString = result as? String,
                      let data = jsonString.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                self?.sendJSON(connection: connection, data: json)
            } else {
                self?.sendJSON(connection: connection, data: ["error": "Failed to parse hand info"])
            }
        }
    }

    private func handleGameOps(connection: NWConnection) {
        executeJavaScript?("window.__nakiGameAPI ? JSON.stringify(__nakiGameAPI.getAvailableOps()) : '[]'") { [weak self] result, error in
            if let error = error {
                self?.sendJSON(connection: connection, data: ["error": error.localizedDescription])
            } else if let jsonString = result as? String,
                      let data = jsonString.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                self?.sendJSON(connection: connection, data: ["ops": json])
            } else {
                self?.sendJSON(connection: connection, data: ["ops": []])
            }
        }
    }

    private func handleGameDiscard(body: String, connection: NWConnection) {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tileIndex = json["tileIndex"] as? Int else {
            sendJSON(connection: connection, data: ["error": "Invalid JSON. Expected: {\"tileIndex\": 0}"])
            return
        }

        let script = "window.__nakiGameAPI ? __nakiGameAPI.discardTile(\(tileIndex)) : false"

        executeJavaScript?(script) { [weak self] result, error in
            if let error = error {
                self?.sendJSON(connection: connection, data: ["error": error.localizedDescription])
            } else if let success = result as? Bool {
                self?.sendJSON(connection: connection, data: ["success": success, "tileIndex": tileIndex])
            } else {
                self?.sendJSON(connection: connection, data: ["error": "Discard failed"])
            }
        }
    }

    private func handleGameAction(body: String, connection: NWConnection) {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = json["action"] as? String else {
            sendJSON(connection: connection, data: ["error": "Invalid JSON. Expected: {\"action\": \"pass\"}"])
            return
        }

        let params = json["params"] as? [String: Any] ?? [:]
        let paramsJson = (try? JSONSerialization.data(withJSONObject: params))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

        let script = "window.__nakiGameAPI ? __nakiGameAPI.smartExecute('\(action)', \(paramsJson)) : false"

        executeJavaScript?(script) { [weak self] result, error in
            if let error = error {
                self?.sendJSON(connection: connection, data: ["error": error.localizedDescription])
            } else {
                self?.sendJSON(connection: connection, data: ["success": true, "action": action])
            }
        }
    }

    // MARK: - Debug Handlers

    private func handleLogs(connection: NWConnection) {
        sendJSON(connection: connection, data: ["logs": logBuffer, "count": logBuffer.count])
    }

    private func handleClearLogs(connection: NWConnection) {
        logBuffer.removeAll()
        sendJSON(connection: connection, data: ["success": true, "message": "Logs cleared"])
    }

    private func handleBotStatus(connection: NWConnection) {
        if let status = getBotStatus?() {
            sendJSON(connection: connection, data: status)
        } else {
            sendJSON(connection: connection, data: ["error": "Bot status not available"])
        }
    }

    private func handleTriggerAutoPlay(connection: NWConnection) {
        log("Manual auto-play trigger requested")
        triggerAutoPlay?()
        sendJSON(connection: connection, data: ["success": true, "message": "Auto-play triggered"])
    }

    private func handleExploreOps(connection: NWConnection) {
        log("Explore operation API requested")
        guard let evaluateJS = evaluateJS else {
            sendJSON(connection: connection, data: ["error": "JS evaluation not available"])
            return
        }

        let script = "window.__nakiGameAPI.exploreOperationAPI()"
        evaluateJS(script) { [weak self] result, error in
            DispatchQueue.main.async {
                if let error = error {
                    self?.sendJSON(connection: connection, data: ["error": error.localizedDescription])
                } else if let result = result {
                    self?.sendJSON(connection: connection, data: ["success": true, "data": result])
                } else {
                    self?.sendJSON(connection: connection, data: ["error": "No result"])
                }
            }
        }
    }

    private func handleDeepExplore(connection: NWConnection) {
        log("Deep explore naki API requested")
        guard let evaluateJS = evaluateJS else {
            sendJSON(connection: connection, data: ["error": "JS evaluation not available"])
            return
        }

        let script = "window.__nakiGameAPI.deepExploreNaki()"
        evaluateJS(script) { [weak self] result, error in
            DispatchQueue.main.async {
                if let error = error {
                    self?.sendJSON(connection: connection, data: ["error": error.localizedDescription])
                } else if let result = result {
                    self?.sendJSON(connection: connection, data: ["success": true, "data": result])
                } else {
                    self?.sendJSON(connection: connection, data: ["error": "No result"])
                }
            }
        }
    }

    private func handleTestChi(connection: NWConnection) {
        log("Test Chi requested")
        guard let evaluateJS = evaluateJS else {
            sendJSON(connection: connection, data: ["error": "JS evaluation not available"])
            return
        }

        let script = "window.__nakiGameAPI.testChi()"
        evaluateJS(script) { [weak self] result, error in
            DispatchQueue.main.async {
                if let error = error {
                    self?.sendJSON(connection: connection, data: ["error": error.localizedDescription])
                } else if let result = result {
                    self?.sendJSON(connection: connection, data: ["success": true, "data": result])
                } else {
                    self?.sendJSON(connection: connection, data: ["error": "No result"])
                }
            }
        }
    }

    private func handleTestPon(connection: NWConnection) {
        log("Test Pon requested")
        guard let evaluateJS = evaluateJS else {
            sendJSON(connection: connection, data: ["error": "JS evaluation not available"])
            return
        }

        let script = "window.__nakiGameAPI.testPon()"
        evaluateJS(script) { [weak self] result, error in
            DispatchQueue.main.async {
                if let error = error {
                    self?.sendJSON(connection: connection, data: ["error": error.localizedDescription])
                } else if let result = result {
                    self?.sendJSON(connection: connection, data: ["success": true, "data": result])
                } else {
                    self?.sendJSON(connection: connection, data: ["error": "No result"])
                }
            }
        }
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
            let jsonData = try JSONSerialization.data(withJSONObject: data, options: .prettyPrinted)
            let body = String(data: jsonData, encoding: .utf8) ?? "{}"
            sendResponse(connection: connection, status: 200, body: body, contentType: "application/json")
        } catch {
            sendResponse(connection: connection, status: 500, body: "{\"error\": \"JSON serialization failed\"}", contentType: "application/json")
        }
    }

    // MARK: - Logging

    private func log(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let logMessage = "[\(timestamp)] \(message)"
        print("[DebugServer] \(message)")

        // 存儲到 buffer
        logBuffer.append(logMessage)
        if logBuffer.count > maxLogCount {
            logBuffer.removeFirst()
        }

        onLog?(logMessage)
    }

    /// ⭐ 添加外部日誌
    func addLog(_ message: String) {
        log(message)
    }

    /// ⭐ 獲取所有日誌
    func getLogs() -> [String] {
        return logBuffer
    }

    /// ⭐ 清空日誌
    func clearLogs() {
        logBuffer.removeAll()
    }
}
