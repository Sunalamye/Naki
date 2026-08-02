//
//  MCPContext.swift
//  Naki
//
//  Created by Claude on 2025/12/05.
//  Naki 專用的 MCP 上下文擴展
//

import Foundation
import MCPKit
import MCPWebKit

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

    /// Swift 協定層的遊戲狀態快照（手牌 / 場況 / 座位 / accountId…）
    func getGameSnapshot() -> [String: Any]?

    /// 自動心跳（防閒置）開關
    /// - Parameters:
    ///   - enabled: nil 表示只查詢狀態，不改變開關
    ///   - intervalSeconds: nil 表示沿用目前間隔
    /// - Returns: 目前狀態；未注入回調時回 nil
    func setAntiIdle(enabled: Bool?, intervalSeconds: TimeInterval?) -> [String: Any]?
}

// MARK: - Default Naki Context Implementation

/// Naki 專用的 MCP 上下文實現
/// 包裝 WebViewMCPContext，添加 Naki 特有功能
@MainActor
final class DefaultNakiMCPContext: NakiMCPContext {

    /// 內部使用的 WebViewMCPContext
    private let webContext = WebViewMCPContext()

    /// 獲取 Bot 狀態的回調
    var getBotStatusCallback: (() -> [String: Any])?

    /// 觸發自動打牌的回調
    var triggerAutoPlayCallback: (() -> Void)?

    /// 送出 Liqi 請求的回調（由 WebViewModel 注入 `LiqiActionSender`）
    var sendLiqiCallback: ((LiqiRequestSpec, Int) async -> LiqiToolSendOutcome)?

    /// 取得 Swift 協定層遊戲快照的回調
    var getGameSnapshotCallback: (() -> [String: Any])?

    /// 自動心跳開關回調（enabled 為 nil 表示只查詢）
    var antiIdleCallback: ((Bool?, TimeInterval?) -> [String: Any])?

    // MARK: - MCPContext Implementation (委託給 webContext)

    var serverPort: UInt16 {
        get { webContext.serverPort }
        set { webContext.serverPort = newValue }
    }

    var executeJavaScriptCallback: ((String, @escaping (Any?, Error?) -> Void) -> Void)? {
        get { webContext.executeJavaScriptCallback }
        set { webContext.executeJavaScriptCallback = newValue }
    }

    var getLogsCallback: (() -> [String])? {
        get { webContext.getLogsCallback }
        set { webContext.getLogsCallback = newValue }
    }

    var clearLogsCallback: (() -> Void)? {
        get { webContext.clearLogsCallback }
        set { webContext.clearLogsCallback = newValue }
    }

    var logCallback: ((String) -> Void)? {
        get { webContext.logCallback }
        set { webContext.logCallback = newValue }
    }

    func executeJavaScript(_ script: String) async throws -> Any? {
        try await webContext.executeJavaScript(script)
    }

    func getLogs() -> [String] {
        webContext.getLogs()
    }

    func clearLogs() {
        webContext.clearLogs()
    }

    func log(_ message: String) {
        webContext.log(message)
    }

    // MARK: - NakiMCPContext Implementation

    func getBotStatus() -> [String: Any]? {
        return getBotStatusCallback?()
    }

    func triggerAutoPlay() {
        triggerAutoPlayCallback?()
    }

    func sendLiqi(_ spec: LiqiRequestSpec, awaitResponseMs: Int) async -> LiqiToolSendOutcome {
        guard let sendLiqiCallback else {
            return .unavailable("liqi_send_callback_not_configured")
        }
        return await sendLiqiCallback(spec, awaitResponseMs)
    }

    func getGameSnapshot() -> [String: Any]? {
        getGameSnapshotCallback?()
    }

    func setAntiIdle(enabled: Bool?, intervalSeconds: TimeInterval?) -> [String: Any]? {
        antiIdleCallback?(enabled, intervalSeconds)
    }
}
