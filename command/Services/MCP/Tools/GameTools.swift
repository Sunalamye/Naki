//
//  GameTools.swift
//  Naki
//
//  Created by Claude on 2025/12/05.
//  遊戲狀態類 MCP 工具
//

import Foundation
import MCPKit

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

// MARK: - Game Action Verify Tool

/// 執行遊戲動作並驗證結果
struct GameActionVerifyTool: MCPTool {
    static let name = "game_action_verify"
    static let description = "執行遊戲動作並等待驗證結果。使用 NakiCoordinator 的動作驗證機制，確認動作是否成功執行（例如 oplist 清空、手牌數量變化等）"
    static let inputSchema = MCPInputSchema(
        properties: [
            "action": .string("動作名稱 (discard, pass, chi, pon, kan, hora, riichi)"),
            "tileIndex": .integer("打牌/立直時的牌索引（可選）"),
            "combinationIndex": .integer("吃牌時的組合索引（可選，預設 0）"),
            "useBuiltin": .boolean("是否使用遊戲內建自動功能（可選，對 pass/hora 有效）"),
            "timeout": .integer("驗證逾時時間 ms（可選，預設 2000）")
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

        let tileIndex = arguments["tileIndex"] as? Int
        let combinationIndex = arguments["combinationIndex"] as? Int ?? 0
        let useBuiltin = arguments["useBuiltin"] as? Bool ?? true
        let timeout = arguments["timeout"] as? Int ?? 2000

        // 構建參數物件
        var params: [String: Any] = [
            "verify": true,
            "verifyTimeout": timeout,
            "useBuiltin": useBuiltin
        ]

        if let idx = tileIndex {
            params["tileIndex"] = idx
        }
        params["combinationIndex"] = combinationIndex

        let paramsJson = (try? JSONSerialization.data(withJSONObject: params))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

        // 使用 NakiCoordinator 的 executeAndVerify
        let script = """
        (async function() {
            if (!window.NakiCoordinator) {
                return JSON.stringify({success: false, error: 'NakiCoordinator not loaded'});
            }
            try {
                const result = await window.NakiCoordinator.debug.executeAndVerify('\(action)', \(paramsJson));
                return JSON.stringify(result);
            } catch (e) {
                return JSON.stringify({success: false, error: e.message});
            }
        })()
        """

        let result = try await context.executeJavaScript(script)

        // 解析結果
        if let jsonString = result as? String,
           let data = jsonString.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return json
        }

        return [
            "success": false,
            "error": "Failed to parse result",
            "rawResult": result ?? NSNull()
        ]
    }
}
