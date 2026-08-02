//
//  MCPContext.swift
//  Naki
//
//  Created by Claude on 2025/12/05.
//  Naki 專用的 MCP 上下文擴展
//
//  2026-08-02（p3-3）：整層改吃 `NakiMCPDependencies`（一個 struct，一次注入）。
//  先前這裡有 9 個 `var xxxCallback: (...)?`，加上內部包一個 `WebViewMCPContext`
//  再轉發 4 個——真正的問題不是行數，是**沒有人擁有那些 closure**：
//  它們由 `WebViewModel.startDebugServer()` 就地建立、經 DebugServer 與 MCPHandler
//  兩層純轉發抵達這裡，型別上看不出 MCP 依賴 view model，漏接只會在 live 呼叫時
//  變成 `xxx_callback_not_configured`。
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

    /// 觸發自動打牌
    func triggerAutoPlay()

    /// 送出一筆 Liqi 請求，可選擇等待對應 msgId 的 RESPONSE
    /// - Parameter awaitResponseMs: 等待毫秒；<= 0 表示射後不理
    func sendLiqi(_ spec: LiqiRequestSpec, awaitResponseMs: Int) async -> LiqiToolSendOutcome

    /// 段位場排隊（spec 由 Action 組，呼叫端不必自己拼欄位）
    func startMatch(matchMode: UInt32,
                    clientVersionString: String,
                    awaitResponseMs: Int) async -> LiqiActionResult

    /// 取消段位場排隊
    func cancelMatch(matchMode: UInt32, awaitResponseMs: Int) async -> LiqiActionResult

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

// MARK: - Default Naki Context Implementation

/// Naki 專用的 MCP 上下文實現。
///
/// 狀態讀 `dependencies.store`（`GameStore`，SwiftUI 讀同一份），
/// 副作用走 `dependencies` 裡的 Action。這個型別本身沒有任何可變狀態
/// ——除了 `serverPort`，那是 server 綁定後才知道的值。
@MainActor
final class DefaultNakiMCPContext: NakiMCPContext {

    /// 這一層需要的全部能力（p3-3：一次注入，之後不可換）
    private let dependencies: NakiMCPDependencies

    /// 實際綁到的 port（`get_status` / `get_help` 要輸出它）
    var serverPort: UInt16

    init(dependencies: NakiMCPDependencies, serverPort: UInt16 = 8765) {
        self.dependencies = dependencies
        self.serverPort = serverPort
    }

    /// app target 開了 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，NakiTests 沒開；
    /// 沒有這行的話單測釋放這個實例會 SIGABRT 把 test host 打掉（見 CLAUDE.md）。
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

    // MARK: - NakiMCPContext Implementation

    func getBotStatus() -> [String: Any]? {
        NakiStatePayload.botStatus(store: dependencies.store)
    }

    func triggerAutoPlay() {
        dependencies.triggerAutoPlay()
    }

    func sendLiqi(_ spec: LiqiRequestSpec, awaitResponseMs: Int) async -> LiqiToolSendOutcome {
        await dependencies.sendAction(spec, awaitResponseMs: awaitResponseMs)
    }

    func startMatch(matchMode: UInt32,
                    clientVersionString: String,
                    awaitResponseMs: Int) async -> LiqiActionResult {
        await dependencies.startMatch(matchMode: matchMode,
                                      clientVersionString: clientVersionString,
                                      awaitResponseMs: awaitResponseMs)
    }

    func cancelMatch(matchMode: UInt32, awaitResponseMs: Int) async -> LiqiActionResult {
        await dependencies.cancelMatch(matchMode: matchMode, awaitResponseMs: awaitResponseMs)
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
