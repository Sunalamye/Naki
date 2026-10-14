//
//  MCPContext.swift
//  Naki
//
//  Created by Claude on 2025/12/05.
//  Naki 專用的 MCP 上下文擴展
//
//  整層吃 `NakiMCPDependencies`（一個 struct，一次注入）。不要改回逐項的
//  `var xxxCallback: (...)?`：那種形狀沒有人擁有那些 closure，型別上看不出 MCP
//  依賴誰，漏接只會在 live 呼叫時變成 `xxx_callback_not_configured`。
//

import Foundation
import MCPKit

// MARK: - Naki MCP Context Protocol

/// Naki 專用的 MCP 上下文協議
/// 擴展 MCPKit 的 MCPContext，添加 Naki 特有的功能
///
/// ⚠️ Unity 遷移後的核心變化：工具**不再**透過 `executeJavaScript` 讀遊戲狀態或做動作
/// （`window.view.DesktopMgr` / `GameMgr` / `uiscript` 全部不存在）。
/// 狀態走 `getGameSnapshot()`（Swift 協定層），動作走 `sendLiqi(...)`（Liqi protobuf）。
protocol NakiMCPContext: MCPContext {
    /// 獲取 Bot 狀態
    func getBotStatus() -> [String: Any]?

    /// 這條 WebView path 是否提供自動送出（Legacy path 為 false）
    var supportsAutoPlay: Bool { get }

    /// 觸發自動打牌
    func triggerAutoPlay()

    /// 送出一筆 Liqi 請求，可選擇等待對應 msgId 的 RESPONSE
    /// - Parameter awaitResponseMs: 等待毫秒；<= 0 表示射後不理
    func sendLiqi(_ spec: LiqiRequestSpec, awaitResponseMs: Int) async -> LiqiToolSendOutcome

    /// 統一匹配排隊（現行段位場入口；`match_sid` 是字串）
    func startUnifiedMatch(matchSid: String,
                           clientVersionString: String,
                           awaitResponseMs: Int) async -> LiqiActionResult

    /// 取消統一匹配
    func cancelUnifiedMatch(matchSid: String, awaitResponseMs: Int) async -> LiqiActionResult

    /// 強制斷線重連（`bot_sync`）
    func forceReconnect() async -> ForceReconnectOutcome

    /// Swift 協定層的遊戲狀態快照（手牌 / 場況 / 座位 / accountId…）
    func getGameSnapshot() -> [String: Any]?

    /// 自動心跳（防閒置）開關
    /// - Parameters:
    ///   - enabled: nil 表示只查詢狀態，不改變開關
    ///   - intervalSeconds: nil 表示沿用目前間隔
    /// - Returns: 目前狀態；這條 path 沒有心跳能力時回 nil
    func setAntiIdle(enabled: Bool?, intervalSeconds: TimeInterval?) -> [String: Any]?
}

extension MCPContext {
    /// 工具共用的向下轉型。MCPKit 的 `init(context: MCPContext)` 簽章把 context 型別抹掉了。
    func naki() throws -> NakiMCPContext {
        guard let context = self as? NakiMCPContext else {
            throw MCPToolError.notAvailable("Naki context")
        }
        return context
    }
}

// MARK: - 參數轉型

/// 工具參數的無號整數轉型。
///
/// `as? Int` 不擋上界（`4294967296` 照樣成功），直接餵 `UInt32(_:)` 會 trap；
/// 超界統一回參數錯誤。負數維持既有語意，夾成 0。
enum MCPArguments {

    /// 等待伺服器回應的預設毫秒數：對局內動作、大廳請求、建房／開局各一檔。
    /// 數值的由來未知，只命名；工具描述字串引用同一份。
    nonisolated static let inGameAwaitMs = 800
    nonisolated static let lobbyAwaitMs = 1500
    nonisolated static let roomAwaitMs = 2000

    nonisolated static func uint32(_ value: Int, _ name: String) throws -> UInt32 {
        guard let result = UInt32(exactly: max(0, value)) else {
            throw MCPToolError.invalidParameter(name, expected: "0–\(UInt32.max) 的整數")
        }
        return result
    }

    /// 缺省或型別不符用 `default`
    nonisolated static func uint32(_ arguments: [String: Any], _ name: String,
                                   default fallback: Int = 0) throws -> UInt32 {
        try uint32(arguments[name] as? Int ?? fallback, name)
    }
}

// MARK: - Default Naki Context Implementation

/// Naki 專用的 MCP 上下文實現。
///
/// 狀態讀 `dependencies.store`（`GameStore`，SwiftUI 讀同一份），
/// 副作用走 `dependencies` 裡的 Action。這個型別本身沒有任何可變狀態
/// ——除了 `serverPort`，那是 server 綁定後才知道的值。
@MainActor
final class DefaultNakiMCPContext: NakiMCPContext {

    /// 這一層需要的全部能力（一次注入，之後不可換）
    private let dependencies: NakiMCPDependencies

    /// 實際綁到的 port（`get_status` / `get_help` 要輸出它）
    var serverPort: UInt16

    /// server 綁定前回報的 port（Debug server 的預設 port）
    nonisolated static let defaultServerPort: UInt16 = 8765

    init(dependencies: NakiMCPDependencies, serverPort: UInt16 = DefaultNakiMCPContext.defaultServerPort) {
        self.dependencies = dependencies
        self.serverPort = serverPort
    }

    /// `@MainActor` class 在 NakiTests host 釋放會 SIGABRT（見 CLAUDE.md「專案結構的坑」）
    nonisolated deinit {}

    // MARK: - MCPContext Implementation

    func executeJavaScript(_ script: String) async throws -> Any? {
        try await dependencies.executeJavaScript(script)
    }

    /// log 只有一個歸宿：`LogManager`。
    ///
    /// 先前這裡是 `getLogsCallback?() ?? logBuffer`——第二份 buffer 的存在讓
    /// 「`/logs` 為什麼同一句話出現兩次」變成一個要靠讀四層 closure 才答得出的問題。
    func getLogs() -> [String] {
        LogManager.shared.recentLogLines()
    }

    func clearLogs() {
        LogManager.shared.clear()
    }

    func log(_ message: String) {
        dependencies.log(message)
    }

    /// 診斷輸出：進 `LogManager`，不動狀態列。
    ///
    /// 每次 MCP 呼叫都會產生的那幾行（request received／tools\/call／callTool）
    /// 用這條。走 `log` 的話它們會把狀態列洗成 `callTool: game_state with args: []`，
    /// 而那是 2026-08-09 人機場實測時畫面底部實際長期停著的內容。
    func trace(_ message: String) {
        dependencies.trace(message)
    }

    // MARK: - NakiMCPContext Implementation

    func getBotStatus() -> [String: Any]? {
        NakiStatePayload.botStatus(store: dependencies.store)
    }

    var supportsAutoPlay: Bool { dependencies.settings.supportsAutoPlay }

    func triggerAutoPlay() {
        dependencies.triggerAutoPlay()
    }

    func sendLiqi(_ spec: LiqiRequestSpec, awaitResponseMs: Int) async -> LiqiToolSendOutcome {
        await dependencies.sendAction(spec, awaitResponseMs: awaitResponseMs)
    }

    /// 統一匹配排隊（現行段位場入口；`match_sid` 是字串）
    func startUnifiedMatch(matchSid: String,
                           clientVersionString: String,
                           awaitResponseMs: Int) async -> LiqiActionResult {
        await dependencies.startUnifiedMatch(matchSid: matchSid,
                                             clientVersionString: clientVersionString,
                                             awaitResponseMs: awaitResponseMs)
    }

    func cancelUnifiedMatch(matchSid: String, awaitResponseMs: Int) async -> LiqiActionResult {
        await dependencies.cancelUnifiedMatch(matchSid: matchSid, awaitResponseMs: awaitResponseMs)
    }

    func forceReconnect() async -> ForceReconnectOutcome {
        await dependencies.forceReconnect()
    }

    func getGameSnapshot() -> [String: Any]? {
        dependencies.gameSnapshot()
    }

    func setAntiIdle(enabled: Bool?, intervalSeconds: TimeInterval?) -> [String: Any]? {
        dependencies.setAntiIdle(enabled: enabled, intervalSeconds: intervalSeconds)
    }
}
