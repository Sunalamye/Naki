//
//  MCPToolRegistry.swift
//  Naki
//
//  Created by Claude on 2025/12/05.
//  MCP 工具註冊表
//

import Foundation

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
    func registerBuiltInTools() {
        // 系統類
        register(GetStatusTool.self)
        register(GetHelpTool.self)
        register(GetLogsTool.self)
        register(ClearLogsTool.self)

        // Bot 控制類
        register(BotStatusTool.self)
        register(BotTriggerTool.self)
        register(BotOpsTool.self)
        register(BotDeepTool.self)
        register(BotChiTool.self)
        register(BotPonTool.self)
        register(BotSyncTool.self)

        // 遊戲狀態類
        register(GameStateTool.self)
        register(GameHandTool.self)
        register(GameOpsTool.self)
        register(GameDiscardTool.self)
        register(GameActionTool.self)

        // JavaScript 執行
        register(ExecuteJSTool.self)

        // 探索類
        register(DetectTool.self)
        register(ExploreTool.self)

        // UI 操作類
        register(TestIndicatorsTool.self)
        register(ClickTool.self)
        register(CalibrateTool.self)

        // UI 控制類
        register(UINameStatusTool.self)
        register(UINameHideTool.self)
        register(UINameShowTool.self)
        register(UINameToggleTool.self)

        // 大廳類
        register(LobbyStatusTool.self)
        register(MatchModeListTool.self)
        register(StartMatchTool.self)
        register(CancelMatchTool.self)
        register(MatchStatusTool.self)
        register(NavigateLobbyTool.self)
        register(AccountLevelTool.self)

        // 心跳/閒置管理
        register(HeartbeatTool.self)
        register(IdleStatusTool.self)
        register(AntiIdleToggleTool.self)

        // 表情類
        register(SendEmojiTool.self)
        register(ListEmojiTool.self)
    }
}
