//
//  MCPHandler.swift
//  Naki
//
//  Created by Claude on 2025/12/05.
//  MCP (Model Context Protocol) 處理器 - 使用 Protocol 模式重構
//

import Foundation
import Network
import MCPKit

// MARK: - MCP Handler

/// MCP Protocol 處理器
/// 負責處理所有 MCP JSON-RPC 請求，使用 MCPToolRegistry 管理工具
final class MCPHandler {

    // MARK: - Properties

    /// 執行上下文
    let context: DefaultNakiMCPContext

    /// 發送 HTTP 響應的回調
    var sendResponse: ((NWConnection, Int, String, String) -> Void)?

    // MARK: - Initialization

    init() {
        self.context = DefaultNakiMCPContext()

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

    /// 設置 Liqi 請求送出回調（Unity 時代唯一有效的動作／大廳面）
    var sendLiqi: ((LiqiRequestSpec, Int) async -> LiqiToolSendOutcome)? {
        get { context.sendLiqiCallback }
        set { context.sendLiqiCallback = newValue }
    }

    /// 設置遊戲狀態快照回調（Swift 協定層供給，取代已死的 DesktopMgr 讀取）
    var getGameSnapshot: (() -> [String: Any])? {
        get { context.getGameSnapshotCallback }
        set { context.getGameSnapshotCallback = newValue }
    }

    /// 設置自動心跳（防閒置）開關回調
    var setAntiIdle: ((Bool?, TimeInterval?) -> [String: Any])? {
        get { context.antiIdleCallback }
        set { context.antiIdleCallback = newValue }
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

    /// 處理 MCP 請求入口。
    ///
    /// 路由決策全部在 `NakiMCPRouter.plan`（純函式，單測對拍）；這裡只負責
    /// 執行決策：回 result、跑工具、或送錯誤。
    func handleRequest(body: String, headers: [String], connection: NWConnection) {
        context.log("MCP request received")

        let plan = NakiMCPRouter.plan(body: body,
                                      headers: headers,
                                      toolDefinitions: MCPToolRegistry.shared.allToolDefinitions())

        switch plan.outcome {
        case .result(let result):
            sendResult(connection: connection, id: plan.id, result: result)

        case .accepted:
            // JSON-RPC 通知沒有 id，也就沒有可回的 response
            sendResponse?(connection, 202, "", "application/json")

        case .failure(let failure):
            sendFailure(connection: connection, id: plan.id, failure: failure)

        case .toolCall(let name, let arguments):
            runTool(name: name, arguments: arguments, id: plan.id, era: plan.era, connection: connection)
        }
    }

    // MARK: - Method Handlers

    /// `initialize` 的回應內容。
    ///
    /// 抽成 static 是為了讓「serverInfo.version == App 版本」可以被單測比對，
    /// 不必起一個真的 server。版本讀 `NakiAppVersion`——先前寫死 `2.1.0`，
    /// App 早就是 2.6.0，MCP client 拿到的版本是假的。
    ///
    /// 內容本身已搬到 `NakiMCPProtocol`（協定語意的單一來源），這裡保留同名
    /// 入口讓既有呼叫端與測試不必跟著改。
    nonisolated static func initializeResult(requestedVersion: String? = nil) -> [String: Any] {
        NakiMCPProtocol.initializeResult(requestedVersion: requestedVersion)
    }

    /// 執行工具並回覆
    private func runTool(name: String,
                         arguments: [String: Any],
                         id: Any?,
                         era: NakiMCPProtocol.Era,
                         connection: NWConnection) {
        context.log("MCP tools/call: \(name) with args: \(arguments)")

        Task {
            let result = await MCPToolRegistry.shared.execute(
                toolNamed: name,
                arguments: arguments,
                context: context
            )

            await MainActor.run {
                switch result {
                case .success(let value):
                    self.sendResult(connection: connection,
                                    id: id,
                                    result: NakiMCPProtocol.toolSuccessPayload(content: value, era: era))
                case .error(let message):
                    // 參數驗證／執行失敗一律回 Tool Execution Error（`isError`），
                    // 不是 protocol error——模型才有機會自己改參數重試
                    self.sendResult(connection: connection,
                                    id: id,
                                    result: NakiMCPProtocol.toolErrorPayload(message: message, era: era))
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

    /// 構建 Help 內容（向後兼容 HTTP `/help`；與 `get_help` 共用同一份內容）
    func buildHelpContent() -> [String: Any] {
        NakiHelpContent.build(serverPort: serverPort)
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
        sendJSON(connection: connection, data: response, status: 200)
    }

    /// 發送 MCP 錯誤（HTTP status 由 `NakiMCPFailure` 決定：
    /// modern era 的 400／404 是規格要求，legacy era 維持 200 + JSON-RPC error）
    private func sendFailure(connection: NWConnection, id: Any?, failure: NakiMCPFailure) {
        var response: [String: Any] = [
            "jsonrpc": "2.0",
            "error": failure.errorObject
        ]
        if let id = id {
            response["id"] = id
        }
        sendJSON(connection: connection, data: response, status: failure.httpStatus)
    }

    /// 發送 MCP JSON 響應
    private func sendJSON(connection: NWConnection, data: [String: Any], status: Int) {
        do {
            let sanitized = JSONSanitizer.sanitize(data)
            let jsonData = try JSONSerialization.data(withJSONObject: sanitized, options: [])
            let body = String(data: jsonData, encoding: .utf8) ?? "{}"
            sendResponse?(connection, status, body, "application/json")
        } catch {
            sendResponse?(connection, 500, "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32603,\"message\":\"Internal error\"}}", "application/json")
        }
    }
}

// MARK: - Backwards Compatibility

extension MCPHandler {
    /// 舊版 ToolResult 類型別名（向後兼容）
    typealias ToolResult = MCPToolResult
}
