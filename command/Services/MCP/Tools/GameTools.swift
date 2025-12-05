//
//  GameTools.swift
//  Naki
//
//  Created by Claude on 2025/12/05.
//  遊戲狀態類 MCP 工具
//

import Foundation

// MARK: - Game State Tool

/// 獲取當前遊戲狀態
struct GameStateTool: MCPTool {
    static let name = "game_state"
    static let description = "獲取當前遊戲狀態"
    static let inputSchema = MCPInputSchema.empty

    private let context: MCPContext

    init(context: MCPContext) {
        self.context = context
    }

    func execute(arguments: [String: Any]) async throws -> Any {
        let script = """
        window.__nakiGameAPI ? JSON.stringify(__nakiGameAPI.getGameState()) : '{"error": "API not loaded"}'
        """
        let result = try await context.executeJavaScript(script)

        // 嘗試解析 JSON
        if let jsonString = result as? String,
           let data = jsonString.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) {
            return json
        }
        return ["result": result ?? NSNull()]
    }
}

// MARK: - Game Hand Tool

/// 獲取手牌資訊
struct GameHandTool: MCPTool {
    static let name = "game_hand"
    static let description = "獲取手牌資訊"
    static let inputSchema = MCPInputSchema.empty

    private let context: MCPContext

    init(context: MCPContext) {
        self.context = context
    }

    func execute(arguments: [String: Any]) async throws -> Any {
        let script = """
        window.__nakiGameAPI ? JSON.stringify(__nakiGameAPI.getHandInfo()) : '{"error": "API not loaded"}'
        """
        let result = try await context.executeJavaScript(script)

        // 嘗試解析 JSON
        if let jsonString = result as? String,
           let data = jsonString.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) {
            return json
        }
        return ["result": result ?? NSNull()]
    }
}

// MARK: - Game Ops Tool

/// 獲取當前可用操作
struct GameOpsTool: MCPTool {
    static let name = "game_ops"
    static let description = "獲取當前可用操作"
    static let inputSchema = MCPInputSchema.empty

    private let context: MCPContext

    init(context: MCPContext) {
        self.context = context
    }

    func execute(arguments: [String: Any]) async throws -> Any {
        let script = """
        window.__nakiGameAPI ? JSON.stringify(__nakiGameAPI.getAvailableOps()) : '[]'
        """
        let result = try await context.executeJavaScript(script)

        // 嘗試解析 JSON
        if let jsonString = result as? String,
           let data = jsonString.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) {
            return json
        }
        return ["result": result ?? NSNull()]
    }
}

// MARK: - Game Discard Tool

/// 打出指定索引的牌
struct GameDiscardTool: MCPTool {
    static let name = "game_discard"
    static let description = "打出指定索引的牌"
    static let inputSchema = MCPInputSchema(
        properties: [
            "tileIndex": .integer("要打出的牌在手牌中的索引 (0-13)")
        ],
        required: ["tileIndex"]
    )

    private let context: MCPContext

    init(context: MCPContext) {
        self.context = context
    }

    func execute(arguments: [String: Any]) async throws -> Any {
        guard let tileIndex = arguments["tileIndex"] as? Int else {
            throw MCPToolError.missingParameter("tileIndex")
        }

        let script = "window.__nakiGameAPI ? __nakiGameAPI.discardTile(\(tileIndex)) : false"
        let result = try await context.executeJavaScript(script)
        let success = result as? Bool ?? false

        return [
            "success": success,
            "tileIndex": tileIndex
        ]
    }
}

// MARK: - Game Action Tool

/// 執行遊戲動作
struct GameActionTool: MCPTool {
    static let name = "game_action"
    static let description = "執行遊戲動作（如 pass, chi, pon, kan, riichi, tsumo, ron）"
    static let inputSchema = MCPInputSchema(
        properties: [
            "action": .string("動作名稱"),
            "params": .object("動作參數（可選）")
        ],
        required: ["action"]
    )

    private let context: MCPContext

    init(context: MCPContext) {
        self.context = context
    }

    func execute(arguments: [String: Any]) async throws -> Any {
        guard let action = arguments["action"] as? String else {
            throw MCPToolError.missingParameter("action")
        }

        let actionParams = arguments["params"] as? [String: Any] ?? [:]
        let paramsJson = (try? JSONSerialization.data(withJSONObject: actionParams))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

        let script = "window.__nakiGameAPI ? __nakiGameAPI.smartExecute('\(action)', \(paramsJson)) : false"
        _ = try await context.executeJavaScript(script)

        return [
            "success": true,
            "action": action
        ]
    }
}
