//
//  BotTools.swift
//  Naki
//
//  Created by Claude on 2025/12/05.
//  Updated 2026-07-31：Unity 遷移。
//
//  改動摘要：
//  - `bot_ops` / `bot_deep`：原本呼叫 `window.__nakiGameAPI.*`（讀 Laya `DesktopMgr`），
//    改讀 Swift 協定層（`LiqiOperationStore` / 遊戲快照 / `LiqiResponseStore`）。
//  - `bot_chi` / `bot_pon`：原本呼叫 `__nakiGameAPI.testChi()`（點 Laya 按鈕），
//    改送 `.lq.FastTest.inputChiPengGang` protobuf。
//  - `bot_status` / `bot_trigger` / `bot_sync`：本來就不碰遊戲物件，維持原樣。
//

#if os(macOS)

import Foundation
import MCPKit

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
        guard let nakiContext = context as? NakiMCPContext,
              let status = nakiContext.getBotStatus() else {
            throw MCPToolError.notAvailable("Bot status")
        }
        return status
    }
}

// MARK: - Bot Trigger Tool

/// 手動觸發自動打牌
struct BotTriggerTool: MCPTool {
    static let name = "bot_trigger"
    static let description = "手動觸發自動打牌（執行 AI 推薦的動作，經 Liqi protobuf 送出）"
    static let inputSchema = MCPInputSchema.empty

    private let context: MCPContext

    init(context: MCPContext) {
        self.context = context
    }

    func execute(arguments: [String: Any]) async throws -> Any {
        guard let nakiContext = context as? NakiMCPContext else {
            throw MCPToolError.notAvailable("Naki context")
        }
        context.log("MCP: Manual auto-play trigger requested")
        nakiContext.triggerAutoPlay()
        return [
            "success": true,
            "message": "Auto-play triggered"
        ]
    }
}

// MARK: - Bot Ops Tool

/// 讀取協定層的可用操作
struct BotOpsTool: MCPTool {
    static let name = "bot_ops"
    static let description = """
        獲取當前可用的操作（吃/碰/槓/立直/和了/九種九牌…）。\
        資料來源是 Liqi 協定層的 OptionalOperationList 快照（取代已失效的 DesktopMgr.oplist 探測）。\
        pending = 尚未被動作層消化的機會；latest = 最近一次收到的（不論是否已處理）。
        """
    static let inputSchema = MCPInputSchema.empty

    private let context: MCPContext

    init(context: MCPContext) {
        self.context = context
    }

    func execute(arguments: [String: Any]) async throws -> Any {
        let store = LiqiOperationStore.shared
        var result: [String: Any] = [
            "source": "LiqiOperationStore (Liqi protocol layer)",
            "hasPending": store.pending != nil
        ]
        result["pending"] = store.pending?.dictionary ?? NSNull()
        result["latest"] = store.latest?.dictionary ?? NSNull()
        return result
    }
}

// MARK: - Bot Deep Tool

/// 深度診斷：協定層狀態總覽
struct BotDeepTool: MCPTool {
    static let name = "bot_deep"
    static let description = """
        深度診斷：一次取回 Swift 協定層的完整狀態（遊戲快照 + 可用操作 + \
        Naki 自送請求最近收到的 RESPONSE + 表情廣播紀錄 + 已註冊工具數）。\
        Bot 沒反應時先看這個，再決定要不要 bot_sync。
        """
    static let inputSchema = MCPInputSchema.empty

    private let context: MCPContext

    init(context: MCPContext) {
        self.context = context
    }

    func execute(arguments: [String: Any]) async throws -> Any {
        var result: [String: Any] = [
            "source": "swift-protocol-layer",
            "registeredTools": MCPToolRegistry.shared.registeredToolNames.count
        ]

        if let nakiContext = context as? NakiMCPContext,
           let snapshot = nakiContext.getGameSnapshot() {
            result["snapshot"] = snapshot
        } else {
            result["snapshot"] = NSNull()
            result["snapshotError"] = "game_snapshot_callback_not_configured"
        }

        let responses = LiqiResponseStore.shared
        result["recentResponses"] = responses.recentResponses.map { $0.dictionary }
        result["broadcasts"] = responses.broadcasts.map { $0.dictionary }
        result["note"] = "recentResponses 只含 Naki 自己送出（msgId >= 60000）的請求回應"

        return result
    }
}

// MARK: - Bot Chi Tool

/// 吃（Liqi protobuf）
struct BotChiTool: MCPTool {
    static let name = "bot_chi"
    static let description = """
        執行「吃」。送出 .lq.FastTest.inputChiPengGang (type=2)。\
        index 為 bot_ops 回傳的 chi combination 索引（預設 0）。\
        ⚠️ 這是真的對伺服器送出動作，不是測試。
        """
    static let inputSchema = MCPInputSchema(
        properties: [
            "index": .integer("吃的組合索引（對應 bot_ops 中 type=2 的 combination，預設 0）"),
            "awaitResponseMs": .integer("等待伺服器回應的毫秒數（預設 800，0 = 不等）")
        ],
        required: []
    )

    private let context: MCPContext

    init(context: MCPContext) {
        self.context = context
    }

    func execute(arguments: [String: Any]) async throws -> Any {
        guard let nakiContext = context as? NakiMCPContext else {
            throw MCPToolError.notAvailable("Naki context")
        }

        let index = UInt32(max(0, arguments["index"] as? Int ?? 0))
        let awaitMs = arguments["awaitResponseMs"] as? Int ?? 800

        let spec = LiqiRequestBuilder.chi(index: index)
        let outcome = await nakiContext.sendLiqi(spec, awaitResponseMs: awaitMs)
        let combos = LiqiOperationStore.shared.pending?.operation(of: .chi)?.combination ?? []
        return LiqiToolResult.dictionary(outcome, spec: spec,
                                         extra: ["index": Int(index),
                                                 "availableCombinations": combos])
    }
}

// MARK: - Bot Pon Tool

/// 碰（Liqi protobuf）
struct BotPonTool: MCPTool {
    static let name = "bot_pon"
    static let description = """
        執行「碰」。送出 .lq.FastTest.inputChiPengGang (type=3)。\
        含紅五時可能有多組 combination，用 index 指定（預設 0）。\
        ⚠️ 這是真的對伺服器送出動作，不是測試。
        """
    static let inputSchema = MCPInputSchema(
        properties: [
            "index": .integer("碰的組合索引（預設 0）"),
            "awaitResponseMs": .integer("等待伺服器回應的毫秒數（預設 800，0 = 不等）")
        ],
        required: []
    )

    private let context: MCPContext

    init(context: MCPContext) {
        self.context = context
    }

    func execute(arguments: [String: Any]) async throws -> Any {
        guard let nakiContext = context as? NakiMCPContext else {
            throw MCPToolError.notAvailable("Naki context")
        }

        let index = UInt32(max(0, arguments["index"] as? Int ?? 0))
        let awaitMs = arguments["awaitResponseMs"] as? Int ?? 800

        let spec = LiqiRequestBuilder.pon(index: index)
        let outcome = await nakiContext.sendLiqi(spec, awaitResponseMs: awaitMs)
        let combos = LiqiOperationStore.shared.pending?.operation(of: .pon)?.combination ?? []
        return LiqiToolResult.dictionary(outcome, spec: spec,
                                         extra: ["index": Int(index),
                                                 "availableCombinations": combos])
    }
}

// MARK: - Bot Sync Tool

/// 強制重連以重建 Bot 狀態
///
/// 仍走 JS：`window.__nakiWebSocket` 是 Naki 自己注入的模組，不依賴任何遊戲物件，
/// Unity 遷移後照常運作（見 docs/majsoul-unity-protocol.md「攔截」段）。
struct BotSyncTool: MCPTool {
    static let name = "bot_sync"
    static let description = "強制斷線重連以重建 Bot 狀態。當 Bot 沒有推薦提示時使用，會關閉 WebSocket 連線觸發遊戲重連，伺服器會發送完整的遊戲歷史重建 Bot"
    static let inputSchema = MCPInputSchema.empty

    private let context: MCPContext

    init(context: MCPContext) {
        self.context = context
    }

    func execute(arguments: [String: Any]) async throws -> Any {
        context.log("MCP: Force reconnecting to rebuild Bot state")

        let result = try await context.executeJavaScript(NakiWebSocketScript.forceReconnect)

        let closedCount = NakiWebSocketScript.closedCount(from: result)
        let success = closedCount > 0

        context.log("MCP: forceReconnect result: closed \(closedCount) connections")

        return [
            "success": success,
            "closedConnections": closedCount,
            "message": success ? "已關閉 \(closedCount) 個連線，遊戲將自動重連並重建 Bot" : "沒有找到可關閉的連線"
        ]
    }
}

#endif  // os(macOS)
