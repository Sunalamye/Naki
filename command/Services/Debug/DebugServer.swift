//
//  DebugServer.swift
//  Naki
//
//  Created by Claude on 2025/12/01.
//  本地 HTTP MCP Server - 允許外部工具控制 App
//
//  平台：**macOS 與 iOS 都編譯**。整層只用 Foundation / Network / MCPKit，沒有一行 AppKit
//  （唯一真正的平台分歧是視窗截圖，留在 `CaptureScreenshotAction.windowScreenshot`
//  的 `#if os(macOS)`）。
//
//  不要把整個檔案包回 `#if os(macOS)`：`scripts/soak-test.sh`、`action-shots.sh`、
//  `replay-check.sh` 與所有 MCP 工具都只透過 loopback 8765 說話，關掉它等於
//  iOS build 完全沒有外部驗證面。
//

import Foundation
import Network
import MCPKit

// MARK: - Request Models

/// JavaScript 執行請求
private struct ExecuteJSRequest: Codable {
    let code: String
}

/// 已解析的 HTTP 請求（交給 endpoint handler）
struct DebugHTTPRequest {
    let method: String
    let path: String
    /// 原始請求的行（含 header），`/mcp` 需要
    let lines: [String]
    let body: String
}

/// 一筆 HTTP endpoint。
///
/// 路由與首頁說明共用這一份定義。兩者各寫一次的話，首頁看起來像文件，
/// 其實是會過期的手寫字串——漏列 endpoint、描述停在上一代客戶端都不會有人發現。
struct DebugEndpoint {
    let method: String
    let path: String
    /// 首頁分組標題
    let group: String
    /// 一行說明
    let summary: String
    /// 帳號／對局會被影響（首頁會標出來）
    let affectsAccount: Bool
    let handler: (DebugServer, DebugHTTPRequest, NWConnection) -> Void

    init(_ method: String,
         _ path: String,
         group: String,
         summary: String,
         affectsAccount: Bool = false,
         handler: @escaping (DebugServer, DebugHTTPRequest, NWConnection) -> Void) {
        self.method = method
        self.path = path
        self.group = group
        self.summary = summary
        self.affectsAccount = affectsAccount
        self.handler = handler
    }
}

// MARK: - MCP Server

/// 本地 HTTP MCP Server。
///
/// 這個型別**只負責 HTTP**：listener、request 累積、Origin 驗證、路由、回應寫回 socket。
/// 它不是 MCP 的依賴中轉站——依賴是 init 參數（`NakiMCPDependencies`），漏接在編譯期
/// 就過不了；改成 server 自己持有可寫的 `var xxx: (...)?` 再轉發，漏接就只剩執行期才發現。
class DebugServer: MCPHTTPResponder {

    /// `@MainActor` 隔離的 class 在 NakiTests host 釋放會 SIGABRT（見 CLAUDE.md
    /// 「專案結構的坑」）。app target 開了 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，
    /// 沒標註的 class 一樣是隔離的。
    nonisolated deinit { }

    // MARK: - Properties

    private var listener: NWListener?
    private let preferredPort: UInt16
    private(set) var actualPort: UInt16 = 0
    private var isRunning = false
    private let maxPortRetries = 10

    /// 單一 HTTP request 累積上限（含 header + body），避免超大或惡意 body 造成無限等待 / 記憶體爆掉
    private let maxRequestSize = 10 * 1024 * 1024  // 10 MB

    /// MCP／Debug 這一層需要的全部能力（狀態讀 `store`，副作用走 Action）
    private let dependencies: NakiMCPDependencies

    /// MCP 協議處理器。
    ///
    /// `lazy` 是因為它要拿 `self` 當 HTTP responder——這也是「回應寫回 socket」
    /// 這件事唯一還連著 DebugServer 的方向（協定，不是 closure）。
    private lazy var mcpHandler = MCPHandler(dependencies: dependencies, responder: self)

    // MARK: - Initialization

    init(port: UInt16 = 8765, dependencies: NakiMCPDependencies) {
        self.preferredPort = port
        self.actualPort = port
        self.dependencies = dependencies
        mcpHandler.serverPort = port
    }

    // MARK: - MCPHTTPResponder

    func sendMCPResponse(connection: NWConnection, status: Int, body: String, contentType: String) {
        sendResponse(connection: connection, status: status, body: body, contentType: contentType)
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
                    // 綁到哪個 port 是 server 自己才知道的事實（8765 被佔用會往上找），
                    // 直接寫進共用的 store；先前這裡是 `onPortChanged` closure 繞回 ViewModel。
                    self.dependencies.store.debugServerPort = port
                    self.dependencies.store.isDebugServerRunning = true
                    self.log("MCP Server started on http://localhost:\(port)")
                    systemLog("[生命週期] MCP Server 已啟動 port=\(port)")
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

        // Origin 驗證（MCP Streamable HTTP 的 DNS rebinding 防護）。
        //
        // 綁 loopback interface 擋得住同網段的其他裝置，擋不住**本機瀏覽器裡的任意頁面**：
        // 對它們來說 127.0.0.1:8765 是可達位址，而這個 server 能執行 JS、送出遊戲動作。
        // 規格要求非法 Origin 回 403，這裡對所有 endpoint 一起套用（`/js` 比 `/mcp` 更危險）。
        // 沒帶 Origin 的請求放行——curl、Claude Code 的 MCP client、skill 腳本都不送。
        let origin = NakiHTTPHeaderReader.value("origin", in: lines)
        guard NakiMCPOriginPolicy.isAllowed(origin) else {
            log("Rejected non-loopback origin: \(origin ?? "?") for \(method) \(path)")
            sendResponse(connection: connection,
                         status: 403,
                         body: NakiMCPOriginPolicy.forbiddenBody(origin: origin),
                         contentType: "application/json")
            return
        }

        log("Request: \(method) \(path)")

        // 解析 POST body
        var body = ""
        if method == "POST", let emptyLineIndex = lines.firstIndex(of: "") {
            body = lines[(emptyLineIndex + 1)...].joined(separator: "\r\n")
        }

        // 路由處理：查同一份 endpoint 表（首頁也是從這份表產生的）
        let parsed = DebugHTTPRequest(method: method, path: path, lines: lines, body: body)
        guard let endpoint = Self.endpoints.first(where: { $0.method == method && $0.path == path }) else {
            sendResponse(connection: connection, status: 404, body: "Not Found: \(method) \(path)")
            return
        }
        endpoint.handler(self, parsed, connection)
    }

    // MARK: - Endpoint Catalog

    /// 全部 HTTP endpoint 的唯一來源：路由查它、首頁列它。
    ///
    /// 加端點只要在這裡加一行；忘了更新首頁這種漂移在結構上不可能發生。
    static let endpoints: [DebugEndpoint] = [
        DebugEndpoint("GET", "/", group: "Server",
                      summary: "這張說明頁（由路由表產生）") { server, _, conn in
            server.handleRoot(connection: conn)
        },
        DebugEndpoint("GET", "/help", group: "Server",
                      summary: "JSON 版 API 說明（等同 MCP get_help）") { server, _, conn in
            server.handleHelp(connection: conn)
        },
        DebugEndpoint("GET", "/status", group: "Server",
                      summary: "server 狀態、port、版本、log 路徑、JS 注入結果") { server, _, conn in
            server.handleStatus(connection: conn)
        },
        DebugEndpoint("POST", "/mcp", group: "Server",
                      summary: "MCP JSON-RPC（server/discover ／ tools/list ／ tools/call；"
                          + "帶 _meta 走 2026-07-28，initialize 走 legacy）") { server, req, conn in
            server.mcpHandler.handleRequest(body: req.body, headers: req.lines, connection: conn)
        },

        DebugEndpoint("POST", "/js", group: "Debug",
                      summary: "在 WebView 執行 function body（取值要寫 return）") { server, req, conn in
            server.handleJavaScript(body: req.body, connection: conn)
        },
        DebugEndpoint("GET", "/screenshot", group: "Debug",
                      summary: "WebView 內容輸出 PNG（不需螢幕錄製權限，視窗被遮住也拍得到）") { server, _, conn in
            server.handleScreenshot(connection: conn)
        },
        DebugEndpoint("GET", "/logs", group: "Debug",
                      summary: "讀記憶體 log（LogManager，時間排序）") { server, _, conn in
            server.handleLogs(connection: conn)
        },
        DebugEndpoint("DELETE", "/logs", group: "Debug",
                      summary: "清空記憶體 log（檔案 log 不受影響）") { server, _, conn in
            server.handleClearLogs(connection: conn)
        },

        DebugEndpoint("GET", "/game/state", group: "Game（Swift 協定層狀態）",
                      summary: "Liqi 累積出來的對局快照") { server, _, conn in
            server.handleGameState(connection: conn)
        },
        DebugEndpoint("GET", "/game/hand", group: "Game（Swift 協定層狀態）",
                      summary: "手牌與 AI 推薦") { server, _, conn in
            server.handleGameHand(connection: conn)
        },
        DebugEndpoint("GET", "/game/ops", group: "Game（Swift 協定層狀態）",
                      summary: "pending／latest 的 Liqi oplist") { server, _, conn in
            server.handleGameOps(connection: conn)
        },

        DebugEndpoint("POST", "/game/discard", group: "Game（會送出動作）",
                      summary: "打牌，body: {\"tile\":\"5m\",\"moqie\":false}",
                      affectsAccount: true) { server, req, conn in
            server.handleGameDiscard(body: req.body, connection: conn)
        },
        DebugEndpoint("POST", "/game/action", group: "Game（會送出動作）",
                      summary: "送動作，body: {\"action\":\"pass\"}（參數平鋪）",
                      affectsAccount: true) { server, req, conn in
            server.handleGameAction(body: req.body, connection: conn)
        },

        DebugEndpoint("GET", "/bot/status", group: "Bot",
                      summary: "Bot、模式、推薦") { server, _, conn in
            server.handleBotStatus(connection: conn)
        },
        DebugEndpoint("GET", "/bot/ops", group: "Bot",
                      summary: "Liqi operation 快照") { server, _, conn in
            server.handleExploreOps(connection: conn)
        },
        DebugEndpoint("GET", "/bot/deep", group: "Bot",
                      summary: "協定層診斷（request／response 細節）") { server, _, conn in
            server.handleDeepExplore(connection: conn)
        },
        DebugEndpoint("POST", "/bot/trigger", group: "Bot（會送出動作）",
                      summary: "手動觸發自動打牌（需要當下有合法 oplist）",
                      affectsAccount: true) { server, _, conn in
            server.handleTriggerAutoPlay(connection: conn)
        },
        DebugEndpoint("POST", "/bot/chi", group: "Bot（會送出動作）",
                      summary: "送出吃", affectsAccount: true) { server, _, conn in
            server.handleTestChi(connection: conn)
        },
        DebugEndpoint("POST", "/bot/pon", group: "Bot（會送出動作）",
                      summary: "送出碰", affectsAccount: true) { server, _, conn in
            server.handleTestPon(connection: conn)
        }
    ] + debugBuildOnlyEndpoints

    /// 只存在於 DEBUG build 的端點（Release 查表查不到 ⇒ 404）。
    ///
    /// 與 `injectRecommendationsForTesting` 同一條理由：能偽造顯示狀態的入口
    /// 不該存在於使用者跑的 binary 裡。
    #if DEBUG
    static let debugBuildOnlyEndpoints: [DebugEndpoint] = [
        DebugEndpoint("POST", "/debug/ui", group: "Debug（僅 DEBUG build）",
                      summary: "注入側欄顯示狀態（純顯示層；下一次真實 bot 回應會覆蓋）") { server, request, conn in
            server.handleDebugUIState(body: request.body, connection: conn)
        }
    ]
    #else
    static let debugBuildOnlyEndpoints: [DebugEndpoint] = []
    #endif

    // MARK: - DEBUG 顯示層注入

    #if DEBUG
    /// `POST /debug/ui`（僅 DEBUG build）：直接寫 `GameStore`，讓 agent 能把側欄
    /// 擺出任意動作組合後用 `/screenshot` 逐一目視驗證。
    ///
    /// **純顯示層**：不碰決策管線、不送任何 Liqi 請求；下一次真實 bot 回應
    /// （`GameStore.apply`）會整份覆蓋。
    ///
    /// Body（全部欄位可選，缺省不動）：
    /// ```json
    /// { "recommendations": [{"action_type":"discard","tile":"5mr","prob":0.42}],
    ///   "isActive": true, "is3P": false,
    ///   "decisionSource": "cloud:4p-akg-v8", "cloudHost": "mjapi.shinkuan.me",
    ///   "available": ["discard","riichi","chi","pon","kan","hora","kita"],
    ///   "tehai": ["1m","2m"] }
    /// ```
    private func handleDebugUIState(body: String, connection: NWConnection) {
        guard let data = body.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            sendResponse(connection: connection, status: 400,
                         body: #"{"error":"body 必須是 JSON 物件"}"#,
                         contentType: "application/json")
            return
        }
        let store = dependencies.store

        if let recs = json["recommendations"] as? [[String: Any]] {
            store.recommendations = recs.map { Recommendation(from: $0) }
        }

        var status = store.botStatus
        if let value = json["isActive"] as? Bool { status.isActive = value }
        if let value = json["is3P"] as? Bool { status.is3P = value }
        if let value = json["decisionSource"] as? String { status.decisionSource = value }
        if json.keys.contains("cloudHost") { status.cloudHost = json["cloudHost"] as? String }
        if let value = json["cloudDegraded"] as? Bool { status.cloudDegraded = value }
        if let value = json["cloudFallbackStreak"] as? Int { status.cloudFallbackStreak = value }
        if let available = json["available"] as? [String] {
            status.canDiscard = available.contains("discard")
            status.canRiichi = available.contains("riichi")
            status.canChi = available.contains("chi")
            status.canPon = available.contains("pon")
            status.canKan = available.contains("kan")
            status.canAgari = available.contains("hora")
            status.canKita = available.contains("kita")
        }
        store.botStatus = status

        if let tehai = json["tehai"] as? [String] { store.tehaiTiles = tehai }

        sendResponse(connection: connection, status: 200,
                     body: #"{"ok":true,"note":"顯示層注入；下一次真實 bot 回應會覆蓋"}"#,
                     contentType: "application/json")
    }
    #endif

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
        sendResponse(connection: connection,
                     status: 200,
                     body: Self.rootHTML(port: actualPort),
                     contentType: "text/html")
    }

    /// 首頁 HTML——完全由 `endpoints` 產生，沒有第二份手寫清單
    static func rootHTML(port: UInt16) -> String {
        // 保持 `endpoints` 的宣告順序分組（不排序，否則群組順序會被字典序打亂）
        var groups: [(name: String, items: [DebugEndpoint])] = []
        for endpoint in endpoints {
            if let index = groups.firstIndex(where: { $0.name == endpoint.group }) {
                groups[index].items.append(endpoint)
            } else {
                groups.append((endpoint.group, [endpoint]))
            }
        }

        let sections = groups.map { group -> String in
            let items = group.items.map { endpoint -> String in
                let warning = endpoint.affectsAccount ? " <strong>⚠️ 會影響帳號</strong>" : ""
                return "  <li><code>\(escapeHTML(endpoint.method)) \(escapeHTML(endpoint.path))</code>"
                    + " — \(escapeHTML(endpoint.summary))\(warning)</li>"
            }.joined(separator: "\n")
            return "<h3>\(escapeHTML(group.name))</h3>\n<ul>\n\(items)\n</ul>"
        }.joined(separator: "\n")

        return """
        <!DOCTYPE html>
        <html lang="zh-Hant">
        <head><meta charset="utf-8"><title>Naki Debug / MCP Server</title></head>
        <body>
        <h1>🀄 Naki Debug / MCP Server</h1>
        <p>App \(escapeHTML(NakiAppVersion.full)) · port \(port) · loopback only</p>
        <p>這份清單由程式內的路由表產生，不是手寫的；工具數與 MCP 工具清單請查
        <code>POST /mcp</code> 的 <code>tools/list</code>。</p>
        \(sections)
        <h2>唯讀快測</h2>
        <pre>curl http://127.0.0.1:\(port)/status
        curl http://127.0.0.1:\(port)/bot/status
        curl http://127.0.0.1:\(port)/logs</pre>
        <p>標了 ⚠️ 的端點會真的送出 Liqi request，只在測試帳號使用。</p>
        </body>
        </html>
        """
    }

    /// 說明字串會出現 `{"tile":"5m"}` 這種內容，直接塞進 HTML 會壞掉
    private static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
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
        Task { [weak self] in
            guard let self else { return }
            switch await self.dependencies.captureScreenshot() {
            case .success(let data) where !data.isEmpty:
                self.sendBinary(connection: connection, data: data, contentType: "image/png")
            case .success:
                self.sendJSON(connection: connection, data: ["error": "empty snapshot"])
            case .failure(let error):
                self.sendJSON(connection: connection, data: ["error": error.localizedDescription])
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
        // MCP 2026-07-28 讓 status code 帶語意（400 = 版本／header 不合、
        // 403 = Origin 被擋、404 = 方法不存在、202 = 通知已接受），所以這張表
        // 不能只有原本那四個
        let statusText: String
        switch status {
        case 200: statusText = "OK"
        case 202: statusText = "Accepted"
        case 400: statusText = "Bad Request"
        case 403: statusText = "Forbidden"
        case 404: statusText = "Not Found"
        case 405: statusText = "Method Not Allowed"
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

            let sanitized = JSONSanitizer.sanitize(data)
            let jsonData = try JSONSerialization.data(withJSONObject: sanitized, options: .prettyPrinted)
            let body = String(data: jsonData, encoding: .utf8) ?? "{}"
            sendResponse(connection: connection, status: 200, body: body, contentType: "application/json")
        } catch {
            sendResponse(connection: connection, status: 500, body: "{\"error\": \"JSON serialization failed\"}", contentType: "application/json")
        }
    }

    // MARK: - Logging

    /// DebugServer 的訊息只有一個歸宿：LogManager。
    ///
    /// 先前這裡另外維護 `logBuffer`，同一條訊息又經 `onLog` 進 LogManager，
    /// `get_logs` 再把兩份 `+` 起來 → 每條 DebugServer 訊息在 `/logs` 出現兩次。
    /// 現在只寫一次；狀態列是同一個動作的副產品，不是第二條 log 通道
    /// （實作在 `NakiMCPDependencies.log`，MCP context 走的也是那一份）。
    private func log(_ message: String) {
        dependencies.log(message)
    }

    /// 添加外部日誌
    func addLog(_ message: String) {
        log(message)
    }

    /// 獲取所有日誌（單一來源：LogManager，已依時間排序）
    func getLogs() -> [String] {
        LogManager.shared.recentLogLines()
    }

    /// 清空日誌（記憶體那份；檔案 log 是完整紀錄，不清）
    func clearLogs() {
        LogManager.shared.clear()
    }
}
