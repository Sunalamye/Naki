//
//  EmojiTools.swift
//  Naki
//
//  Created by Claude on 2025/12/06.
//  Updated 2026-07-31：Unity 遷移，改走 Liqi protobuf。
//
//  舊實作：
//  - `game_emoji` 用 `app.NetAgent.sendReq2MJ('FastTest','broadcastInGame', …)` → NetAgent 已不存在
//  - `game_emoji_list` 讀 `uiscript.UI_MJ_Emoji.Inst.emos` → uiscript 已不存在
//  - `game_emoji_listen` 掛 `netRouteGroup_mj.notifyHander.handlers['.lq.NotifyGameBroadcast']`
//    → 同上
//
//  新實作：
//  - 送出：直接組 `.lq.FastTest.broadcastInGame`（ReqBroadcastInGame：content=1, except_self=2），
//    content 沿用雀魂格式 `{"emo":N}`。
//  - 接收：`.lq.NotifyGameBroadcast` 本來就會經過 Naki 的 WebSocket 攔截，
//    由 `LiqiResponseStore` 在 `MajsoulBridge.parse` 接住（見該檔說明）。
//
//  移除的工具：
//  - `game_emoji_list`：角色表情清單存在客戶端配置表（`cfg`），Unity 下隨引擎進 wasm，
//    JS/協定層都拿不到，也沒有替代面。emo_id 0-8 可直接盲送。
//  - `game_emoji_auto_reply`：舊模組 `window.__nakiEmojiAutoReply` 要靠
//    `view.DesktopMgr.Inst.seat` 判斷「不是自己發的」再用 NetAgent 回送，兩個依賴都沒了。
//    在 Swift 重寫一份自動回應等於新功能，且無法在沒有真實對局的情況下驗證，故移除；
//    手動路徑是 game_emoji_listen + game_emoji。
//

#if os(macOS)

import Foundation
import MCPKit

// MARK: - Send Emoji Tool

/// 發送遊戲內表情（Liqi protobuf）
struct SendEmojiTool: MCPTool {
    static let name = "game_emoji"
    static let description = """
        在對局中發送表情。送出 .lq.FastTest.broadcastInGame，content = {"emo":N}。\
        emo_id 0-8 對應當前角色的 9 個表情（清單無法取得，見 game_emoji_list 已移除的說明）。\
        count 可設定連續發送次數（1-5）。
        """
    static let inputSchema = MCPInputSchema(
        properties: [
            "emo_id": .integer("表情索引 (0-8)"),
            "count": .integer("連續發送次數 (1-5)，預設 1"),
            "except_self": .boolean("是否不廣播給自己（預設 false）"),
            "awaitResponseMs": .integer("等待伺服器回應的毫秒數（預設 800，0 = 不等）")
        ],
        required: ["emo_id"]
    )

    private let context: MCPContext

    init(context: MCPContext) {
        self.context = context
    }

    func execute(arguments: [String: Any]) async throws -> Any {
        guard let emoId = arguments["emo_id"] as? Int else {
            throw MCPToolError.missingParameter("emo_id")
        }
        guard emoId >= 0 && emoId <= 8 else {
            throw MCPToolError.invalidParameter("emo_id", expected: "0-8")
        }
        guard let nakiContext = context as? NakiMCPContext else {
            throw MCPToolError.notAvailable("Naki context")
        }

        let count = max(1, min(5, arguments["count"] as? Int ?? 1))
        let exceptSelf = arguments["except_self"] as? Bool ?? false
        let awaitMs = arguments["awaitResponseMs"] as? Int ?? 800

        let spec = LiqiRequestBuilder.emoji(emoId: emoId, exceptSelf: exceptSelf)
        var sends: [[String: Any]] = []
        var successCount = 0

        for _ in 0..<count {
            let outcome = await nakiContext.sendLiqi(spec, awaitResponseMs: awaitMs)
            if outcome.sent?.success == true { successCount += 1 }
            sends.append(LiqiToolResult.dictionary(outcome, spec: spec))
        }

        return [
            // 全部送成功才算成功；部分成功要看 sends 逐筆判斷
            "success": successCount == count,
            "emo_id": emoId,
            "requested": count,
            "sentCount": successCount,
            "content": "{\"emo\":\(emoId)}",
            "method": spec.method,
            "sends": sends
        ]
    }
}

// MARK: - Emoji Listen Tool

/// 讀取收到的表情廣播（協定層）
struct EmojiListenTool: MCPTool {
    static let name = "game_emoji_listen"
    static let description = """
        獲取收到的表情廣播紀錄（其他玩家發送的表情）。\
        資料來自 Liqi 協定層：`.lq.NotifyGameBroadcast` 由 Naki 的 WebSocket 攔截接住，\
        不需要也不再有「安裝監聽器」的步驟（舊版要 hook NetAgent handler）。\
        最多保留最近 50 筆；用 clear=true 清空。
        """
    static let inputSchema = MCPInputSchema(
        properties: [
            "clear": .boolean("是否在回傳後清空記錄（預設 false）")
        ],
        required: []
    )

    private let context: MCPContext

    init(context: MCPContext) {
        self.context = context
    }

    func execute(arguments: [String: Any]) async throws -> Any {
        let clear = arguments["clear"] as? Bool ?? false
        let store = LiqiResponseStore.shared
        let records = store.broadcasts

        var result: [String: Any] = [
            "success": true,
            "source": "LiqiResponseStore (.lq.NotifyGameBroadcast)",
            "count": records.count,
            "broadcasts": records.map { $0.dictionary }
        ]

        if clear {
            store.clearBroadcasts()
            result["cleared"] = true
        }
        return result
    }
}

#endif  // os(macOS)
