//
//  MCPToolRegistry.swift
//  Naki
//
//  Created by Claude on 2025/12/05.
//  MCP 工具註冊表
//

import Foundation
import MCPKit

// MARK: - Tool Registry

/// MCP 工具註冊表
/// 管理所有已註冊的工具，提供工具查找和定義生成
final class MCPToolRegistry {

    /// 單例
    static let shared = MCPToolRegistry()

    /// 已註冊的工具類型
    private var toolTypes: [String: any MCPTool.Type] = [:]

    /// 工具註冊順序（用於保持輸出順序）
    private var toolOrder: [String] = []

    private init() {}

    // MARK: - Registration

    /// 註冊工具
    /// - Parameter toolType: 工具類型
    func register<T: MCPTool>(_ toolType: T.Type) {
        let name = T.name
        if toolTypes[name] == nil {
            toolOrder.append(name)
        }
        toolTypes[name] = toolType
    }

    /// 批量註冊工具
    /// - Parameter toolTypes: 工具類型列表
    func registerAll(_ types: [any MCPTool.Type]) {
        for toolType in types {
            let name = toolType.name
            if toolTypes[name] == nil {
                toolOrder.append(name)
            }
            toolTypes[name] = toolType
        }
    }

    // MARK: - Tool Access

    /// 獲取工具實例
    /// - Parameters:
    ///   - name: 工具名稱
    ///   - context: 執行上下文
    /// - Returns: 工具實例，如果未找到則返回 nil
    func tool(named name: String, context: MCPContext) -> (any MCPTool)? {
        guard let toolType = toolTypes[name] else { return nil }
        return toolType.init(context: context)
    }

    /// 檢查工具是否存在
    /// - Parameter name: 工具名稱
    /// - Returns: 是否存在
    func hasToolNamed(_ name: String) -> Bool {
        return toolTypes[name] != nil
    }

    /// 獲取所有已註冊的工具名稱
    var registeredToolNames: [String] {
        return toolOrder
    }

    // MARK: - Tool Definitions

    /// 生成所有工具的定義列表（用於 MCP tools/list）
    /// - Returns: 工具定義陣列
    func allToolDefinitions() -> [[String: Any]] {
        return toolOrder.compactMap { name -> [String: Any]? in
            guard let toolType = toolTypes[name] else { return nil }
            return [
                "name": toolType.name,
                "description": toolType.description,
                "inputSchema": toolType.inputSchema.toJSON()
            ]
        }
    }

    /// 生成工具定義 JSON（可保存到文件）
    /// - Returns: JSON 字串
    func generateToolsJSON() -> String? {
        let definitions = allToolDefinitions()
        let json: [String: Any] = ["tools": definitions]

        guard let data = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted),
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }

    // MARK: - Tool Execution

    /// 執行工具
    /// - Parameters:
    ///   - name: 工具名稱
    ///   - arguments: 調用參數
    ///   - context: 執行上下文
    /// - Returns: 執行結果
    func execute(
        toolNamed name: String,
        arguments: [String: Any],
        context: MCPContext
    ) async -> MCPToolResult {
        guard let tool = tool(named: name, context: context) else {
            return .error("Unknown tool: \(name)")
        }

        do {
            let result = try await tool.execute(arguments: arguments)
            return .success(result)
        } catch {
            return .error(error.localizedDescription)
        }
    }

    // MARK: - Reset (for testing)

    /// 清空所有註冊（僅用於測試）
    func reset() {
        toolTypes.removeAll()
        toolOrder.removeAll()
    }
}

// MARK: - Convenience Registration

extension MCPToolRegistry {
    /// 註冊所有內建工具
    ///
    /// 下方 registration 是工具數的**唯一真實來源**（本次靜態計數 38 個）；
    /// `get_status` 的 `tools_count` 直接數 `registeredToolNames`，不會跟註解漂移，
    /// 要確認 live 數字請看 `tools/list` 或 `get_status`。
    /// 2026-08-02 移除 6 個 highlight 失敗樁（見下）。
    ///
    /// 移除的舊工具（呼叫會得到 `Unknown tool: <name>`）與理由：
    /// - `detect` / `explore` / `test_indicators` / `click` / `calibrate`：Laya DOM 座標探測，
    ///   Unity 只有單一 `<canvas>`，沒有替代面（要 ad-hoc 探測請用 `execute_js`）
    /// - `ui_names_status` / `ui_names_hide` / `ui_names_show` / `ui_names_toggle`：
    ///   依賴 `uiscript.UI_DesktopInfo`，UI 層已搬進 wasm
    /// - `lobby_match_status`：協定沒有「查自己排隊狀態」的方法，併入 `lobby_status`
    /// - `lobby_navigate`：純 UI 換頁，無協定等價物
    /// - `lobby_idle_status`：讀 `GameMgr._last_heatbeat_time`，改由 `lobby_anti_idle` 回報
    /// - `game_emoji_list`：registry 沒有提供 catalog tool；需要時應 fresh parse 公開配置資源
    /// - `game_emoji_auto_reply`：需要 `DesktopMgr.seat` + NetAgent，兩者皆無
    /// - `highlight_tile` / `reset_tile_color` / `highlight_status` / `highlight_settings` /
    ///   `show_recommendations` / `hide_highlight`（2026-08-02 移除）：
    ///   6 個固定回 unavailable 的相容失敗樁。它們的參數契約源自 Laya 牌物件，
    ///   從來沒有接到現行的 `window.__nakiHighlight` WebGL hook，也不打算接——
    ///   App 內建的自動推薦高亮由 `WebViewModel.syncGameHighlight()` 直接驅動，
    ///   MCP 不需要第二個入口。留著只是讓 `tools/list` 多 6 個永遠失敗的工具，
    ///   還會讓人誤以為「Unity 下高亮不可能」。推薦資料請讀 `bot_status` / `game_hand`。
    func registerBuiltInTools() {
        // 系統類（6）— 不碰遊戲物件
        register(GetStatusTool.self)
        register(GetHelpTool.self)
        register(GetLogsTool.self)
        register(ListRecordingsTool.self)
        register(ReplayGameTool.self)
        register(ClearLogsTool.self)

        // Bot 控制類（7）— 讀 Swift 協定層狀態 / 送 Liqi 動作
        register(BotStatusTool.self)
        register(BotTriggerTool.self)
        register(BotOpsTool.self)
        register(BotDeepTool.self)
        register(BotChiTool.self)
        register(BotPonTool.self)
        register(BotSyncTool.self)

        // 遊戲狀態與動作類（6）— 狀態走協定層、動作走 protobuf
        register(GameStateTool.self)
        register(GameHandTool.self)
        register(GameOpsTool.self)
        register(GameDiscardTool.self)
        register(GameActionTool.self)
        register(GameActionVerifyTool.self)

        // JavaScript 執行（1）
        register(ExecuteJSTool.self)

        // 大廳類（8）— 全部走 .lq.Lobby.* protobuf
        register(LobbyStatusTool.self)
        register(MatchModeListTool.self)
        register(StartMatchTool.self)
        register(CancelMatchTool.self)
        register(AccountInfoTool.self)
        register(ServerTimeTool.self)
        register(HeartbeatTool.self)
        register(LoginBeatTool.self)

        // 防閒置（1）— Swift 定期送 .lq.Lobby.heatbeat
        register(AntiIdleToggleTool.self)

        // 友人房類（7）— 新增：建房 → 加人機 → 開局可純由 MCP 完成
        register(RoomCreateTool.self)
        register(RoomAddRobotTool.self)
        register(RoomStartTool.self)
        register(RoomInfoTool.self)
        register(RoomJoinTool.self)
        register(RoomLeaveTool.self)
        register(RoomQuickTestTool.self)

        // 表情類（2）— 送出走 broadcastInGame、接收走 NotifyGameBroadcast
        register(SendEmojiTool.self)
        register(EmojiListenTool.self)
    }
}
