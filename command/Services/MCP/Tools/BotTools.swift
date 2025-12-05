//
//  BotTools.swift
//  Naki
//
//  Created by Claude on 2025/12/05.
//  Bot 控制類 MCP 工具
//

import Foundation

// MARK: - Bot Status Tool

/// 獲取 Bot 狀態
struct BotStatusTool: MCPTool {
    static let name = "bot_status"
    static let description = "獲取 Bot 狀態，包含手牌、AI 推薦動作、可用操作等完整信息"
    static let inputSchema = MCPInputSchema.empty

    private let context: MCPContext

    init(context: MCPContext) {
        self.context = context
    }

    func execute(arguments: [String: Any]) async throws -> Any {
        guard let status = context.getBotStatus() else {
            throw MCPToolError.notAvailable("Bot status")
        }
        return status
    }
}

// MARK: - Bot Trigger Tool

/// 手動觸發自動打牌
struct BotTriggerTool: MCPTool {
    static let name = "bot_trigger"
    static let description = "手動觸發自動打牌（執行 AI 推薦的動作）"
    static let inputSchema = MCPInputSchema.empty

    private let context: MCPContext

    init(context: MCPContext) {
        self.context = context
    }

    func execute(arguments: [String: Any]) async throws -> Any {
        context.log("MCP: Manual auto-play trigger requested")
        context.triggerAutoPlay()
        return [
            "success": true,
            "message": "Auto-play triggered"
        ]
    }
}

// MARK: - Bot Ops Tool

/// 探索可用的副露操作
struct BotOpsTool: MCPTool {
    static let name = "bot_ops"
    static let description = "探索可用的副露操作（吃/碰/槓）"
    static let inputSchema = MCPInputSchema.empty

    private let context: MCPContext

    init(context: MCPContext) {
        self.context = context
    }

    func execute(arguments: [String: Any]) async throws -> Any {
        let script = "window.__nakiGameAPI.exploreOperationAPI()"
        let result = try await context.executeJavaScript(script)
        return ["result": result ?? NSNull()]
    }
}

// MARK: - Bot Deep Tool

/// 深度探索 naki API
struct BotDeepTool: MCPTool {
    static let name = "bot_deep"
    static let description = "深度探索 naki API（所有方法）"
    static let inputSchema = MCPInputSchema.empty

    private let context: MCPContext

    init(context: MCPContext) {
        self.context = context
    }

    func execute(arguments: [String: Any]) async throws -> Any {
        let script = "window.__nakiGameAPI.deepExploreNaki()"
        let result = try await context.executeJavaScript(script)
        return ["result": result ?? NSNull()]
    }
}

// MARK: - Bot Chi Tool

/// 測試吃操作
struct BotChiTool: MCPTool {
    static let name = "bot_chi"
    static let description = "測試吃操作"
    static let inputSchema = MCPInputSchema.empty

    private let context: MCPContext

    init(context: MCPContext) {
        self.context = context
    }

    func execute(arguments: [String: Any]) async throws -> Any {
        let script = "window.__nakiGameAPI.testChi()"
        let result = try await context.executeJavaScript(script)
        return ["result": result ?? NSNull()]
    }
}

// MARK: - Bot Pon Tool

/// 測試碰操作
struct BotPonTool: MCPTool {
    static let name = "bot_pon"
    static let description = "測試碰操作"
    static let inputSchema = MCPInputSchema.empty

    private let context: MCPContext

    init(context: MCPContext) {
        self.context = context
    }

    func execute(arguments: [String: Any]) async throws -> Any {
        let script = "window.__nakiGameAPI.testPon()"
        let result = try await context.executeJavaScript(script)
        return ["result": result ?? NSNull()]
    }
}
