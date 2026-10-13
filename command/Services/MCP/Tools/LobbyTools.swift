//
//  LobbyTools.swift
//  Naki
//
//  Created by Claude on 2025/12/06.
//  Updated 2026-07-31：Unity 遷移，整檔改走 Liqi protobuf。
//
//  舊實作全部操作 `window.GameMgr.Inst.uimgr`（`_ui_lobby.setPage()`、
//  `_uis[105].addMatch()`、`account_data`、`clientHeatBeat()`）。
//  Unity WebGL 客戶端下 `GameMgr` **實測不存在**，這些工具是靜默失敗。
//
//  新做法：直接送 `.lq.Lobby.*` REQUEST。所有欄位編號都查過
//  docs/protocol/liqi.json（見各工具註解），但**伺服器是否接受**仍需真實登入驗證。
//
//  移除的工具：
//  - `lobby_match_status`：協定沒有「查詢自己排隊狀態」的方法（客戶端自己記），
//    功能併入 `lobby_status`（fetchGamingInfo）。
//  - `lobby_navigate`：純 UI 換頁，Unity 下沒有可操作的 UI 層，也沒有協定等價物。
//  - `lobby_idle_status`：讀 `GameMgr.Inst._last_heatbeat_time`；改由 `lobby_anti_idle`
//    回報 Naki 自己送出的心跳狀態。
//  - 舊段位場入口的 start／cancel／match_modes 三個工具：2026-10-13 移除。
//    `.lq.Lobby.matchGame` 對 match_mode 1／2／3 一律回 error 1306，現行入口是 `startUnifiedMatch`。
//

import Foundation
import MCPKit

// MARK: - Lobby Status Tool

/// 查詢目前對局／房間狀態
struct LobbyStatusTool: MCPTool {
    static let name = "lobby_status"
    static let description = """
        查詢大廳狀態：送出 .lq.Lobby.fetchGamingInfo（ReqCommon，空 payload），\
        伺服器回覆目前是否在對局／房間中。\
        ⚠️ 回應以 protobuf 欄位編號（fieldN）呈現，語意請對照 liqi.json 的 ResFetchGamingInfo。
        """
    static let inputSchema = MCPInputSchema(
        properties: [
            "awaitResponseMs": .integer("等待伺服器回應的毫秒數（預設 1500，0 = 不等）")
        ],
        required: []
    )

    private let context: MCPContext

    init(context: MCPContext) {
        self.context = context
    }

    func execute(arguments: [String: Any]) async throws -> Any {
        let nakiContext = try context.naki()
        let spec = LiqiRequestBuilder.fetchGamingInfo()
        let outcome = await nakiContext.sendLiqi(spec,
                                                 awaitResponseMs: arguments["awaitResponseMs"] as? Int ?? 1500)
        return LiqiToolResult.dictionaryLoggingRejection(outcome, spec: spec)
    }
}

// MARK: - Unified Match Tools

/// 統一匹配 `match_sid`：**從遊戲流量觀察**，因為沒有任何地方可以查
///
/// `ReqStartUnifiedMatch.match_sid` 是 string，而 `liqi.json` 裡沒有任何 response
/// 或 config 訊息會產生這個字串。唯一來源是玩家自己點入口時客戶端送的那一筆
/// `startUnifiedMatch`（見 `ObservedMatchSids`）。
struct MatchSidListTool: MCPTool {
    static let name = "lobby_match_sids"
    static let description = """
        列出從遊戲流量觀察到的 match_sid（統一匹配用）。⚠️ 沒有靜態表可查——\
        liqi.json 裡沒有任何訊息會產生 match_sid。要有資料，請先在遊戲裡自己點一次\
        段位場的場次入口，客戶端會送 .lq.Lobby.startUnifiedMatch，Naki 就攔得到。
        """
    static let inputSchema = MCPInputSchema.empty

    private let context: MCPContext

    init(context: MCPContext) {
        self.context = context
    }

    func execute(arguments: [String: Any]) async throws -> Any {
        ObservedMatchSids.shared.dictionary
    }
}

/// 開始統一匹配（現行段位場入口）
struct StartUnifiedMatchTool: MCPTool {
    static let name = "lobby_start_unified_match"
    static let description = """
        開始段位場匹配（現行入口）。送出 .lq.Lobby.startUnifiedMatch\
        （ReqStartUnifiedMatch：match_sid=1, client_version_string=2）。\
        match_sid 是**字串**，用 lobby_match_sids 查（從流量觀察）；不填則用最近一次\
        觀察到的那一組。⚠️ 真的會排進伺服器隊列，請只在測試帳號使用。
        """
    static let inputSchema = MCPInputSchema(
        properties: [
            "match_sid": .string("匹配 sid 字串（不填則用 lobby_match_sids 最近觀察到的一組）"),
            "client_version_string": .string("客戶端版本字串（不填則沿用該次觀察到的值）"),
            "awaitResponseMs": .integer("等待伺服器回應的毫秒數（預設 1500）")
        ],
        required: []
    )

    private let context: MCPContext

    init(context: MCPContext) {
        self.context = context
    }

    func execute(arguments: [String: Any]) async throws -> Any {
        let nakiContext = try context.naki()

        // 沒帶參數時退回「最近觀察到的那一組」——這是唯一有真憑據的預設值。
        // 猜一個 sid 送出去比失敗更糟：可能排進非預期的場次。
        let observed = ObservedMatchSids.shared.latest
        let matchSid = (arguments["match_sid"] as? String) ?? observed?.sid ?? ""
        guard !matchSid.isEmpty else {
            throw MCPToolError.invalidParameter(
                "match_sid",
                expected: "非空字串；還沒觀察到任何 sid 時必須自己指定"
                    + "（先在遊戲裡點一次段位場入口，或查 lobby_match_sids）")
        }
        let clientVersion = (arguments["client_version_string"] as? String)
            ?? observed?.clientVersionString ?? ""

        let result = await nakiContext.startUnifiedMatch(
            matchSid: matchSid,
            clientVersionString: clientVersion,
            awaitResponseMs: arguments["awaitResponseMs"] as? Int ?? 1500)
        context.log("🎮 lobby_start_unified_match match_sid=\(matchSid)")
        return LiqiToolResult.dictionaryLoggingRejection(
            result.outcome, spec: result.spec,
            extra: ["match_sid": matchSid,
                    "client_version_string": clientVersion,
                    "sidSource": arguments["match_sid"] == nil ? "observed" : "argument"])
    }
}

/// 取消統一匹配
struct CancelUnifiedMatchTool: MCPTool {
    static let name = "lobby_cancel_unified_match"
    static let description = """
        取消段位場匹配（現行入口）。送出 .lq.Lobby.cancelUnifiedMatch\
        （ReqCancelUnifiedMatch：match_sid=1）。match_sid 不填則用最近一次觀察到的那一組。
        """
    static let inputSchema = MCPInputSchema(
        properties: [
            "match_sid": .string("要取消的匹配 sid（不填則用最近觀察到的一組）"),
            "awaitResponseMs": .integer("等待伺服器回應的毫秒數（預設 1500）")
        ],
        required: []
    )

    private let context: MCPContext

    init(context: MCPContext) {
        self.context = context
    }

    func execute(arguments: [String: Any]) async throws -> Any {
        let nakiContext = try context.naki()
        // `??` 右側是 autoclosure，不能直接放 await——先取出來再合併。
        let observed = ObservedMatchSids.shared.latest
        let matchSid = (arguments["match_sid"] as? String) ?? observed?.sid ?? ""
        guard !matchSid.isEmpty else {
            throw MCPToolError.invalidParameter(
                "match_sid", expected: "非空字串；查 lobby_match_sids")
        }

        let result = await nakiContext.cancelUnifiedMatch(
            matchSid: matchSid,
            awaitResponseMs: arguments["awaitResponseMs"] as? Int ?? 1500)
        context.log("⏹️ lobby_cancel_unified_match match_sid=\(matchSid)")
        return LiqiToolResult.dictionaryLoggingRejection(result.outcome, spec: result.spec,
                                                         extra: ["match_sid": matchSid])
    }
}

// MARK: - Account Info Tool

/// 查詢帳號資訊（段位等）
struct AccountInfoTool: MCPTool {
    static let name = "lobby_account_info"
    static let description = """
        查詢帳號資訊（含段位）。送出 .lq.Lobby.fetchAccountInfo（ReqAccountInfo：account_id=1）。\
        ⚠️ account_id 必填；未提供時使用 Naki 從登入封包解析到的 account_id，\
        若尚未登入（=0）會直接回失敗，因為送空 payload 伺服器不會回應。\
        （舊名 lobby_account_level，改名以反映它是協定查詢而非本地讀值）
        """
    static let inputSchema = MCPInputSchema(
        properties: [
            "account_id": .integer("要查詢的 account_id；不填則用 Naki 已知的登入帳號"),
            "awaitResponseMs": .integer("等待伺服器回應的毫秒數（預設 1500）")
        ],
        required: []
    )

    private let context: MCPContext

    init(context: MCPContext) {
        self.context = context
    }

    func execute(arguments: [String: Any]) async throws -> Any {
        let nakiContext = try context.naki()

        let known = (nakiContext.getGameSnapshot()?["accountId"] as? Int) ?? 0
        let accountId = arguments["account_id"] as? Int ?? known

        guard accountId > 0 else {
            return [
                "success": false,
                "error": "missing_account_id",
                "reason": "ReqAccountInfo.account_id 必填，且 Naki 尚未從登入封包解析到 account_id"
                    + "（尚未登入，或 Naki 是在登入之後才啟動而錯過了登入回應）。",
                "hint": "先登入雀魂；或直接帶入 account_id 參數。"
            ]
        }

        let spec = LiqiRequestBuilder.fetchAccountInfo(accountId: try MCPArguments.uint32(accountId, "account_id"))
        let outcome = await nakiContext.sendLiqi(spec,
                                                 awaitResponseMs: arguments["awaitResponseMs"] as? Int ?? 1500)
        return LiqiToolResult.dictionaryLoggingRejection(outcome, spec: spec,
                                                         extra: ["account_id": accountId,
                                                                 "accountIdSource": arguments["account_id"] == nil ? "naki-login-capture" : "argument"])
    }
}

// MARK: - Server Time Tool

/// 查詢伺服器時間（最無害的連線探針）
struct ServerTimeTool: MCPTool {
    static let name = "lobby_server_time"
    static let description = """
        查詢伺服器時間。送出 .lq.Lobby.fetchServerTime（ReqCommon，空 payload）。\
        這是最無害的查詢類請求，適合用來確認「注入通道是否真的通到伺服器」\
        （有 RESPONSE 回來就代表整條鏈路 OK）。
        """
    static let inputSchema = MCPInputSchema(
        properties: [
            "awaitResponseMs": .integer("等待伺服器回應的毫秒數（預設 1500）")
        ],
        required: []
    )

    private let context: MCPContext

    init(context: MCPContext) {
        self.context = context
    }

    func execute(arguments: [String: Any]) async throws -> Any {
        let nakiContext = try context.naki()
        let spec = LiqiRequestBuilder.fetchServerTime()
        let outcome = await nakiContext.sendLiqi(spec,
                                                 awaitResponseMs: arguments["awaitResponseMs"] as? Int ?? 1500)
        return LiqiToolResult.dictionaryLoggingRejection(outcome, spec: spec)
    }
}

// MARK: - Heartbeat Tool

/// 手動送出大廳心跳
struct HeartbeatTool: MCPTool {
    static let name = "lobby_heartbeat"
    static let description = """
        送出大廳心跳防止閒置登出。送出 .lq.Lobby.heatbeat（ReqHeatBeat：no_operation_counter=1）。\
        取代 Unity 下已失效的 GameMgr.Inst.clientHeatBeat()。\
        要自動定期送請用 lobby_anti_idle。
        """
    static let inputSchema = MCPInputSchema(
        properties: [
            "no_operation_counter": .integer("無操作計數（預設 0；為 0 時依 proto3 省略，payload 為空）"),
            "awaitResponseMs": .integer("等待伺服器回應的毫秒數（預設 1500）")
        ],
        required: []
    )

    private let context: MCPContext

    init(context: MCPContext) {
        self.context = context
    }

    func execute(arguments: [String: Any]) async throws -> Any {
        let nakiContext = try context.naki()
        let counter = try MCPArguments.uint32(arguments, "no_operation_counter")
        let spec = LiqiRequestBuilder.heatbeat(noOperationCounter: counter)
        let outcome = await nakiContext.sendLiqi(spec,
                                                 awaitResponseMs: arguments["awaitResponseMs"] as? Int ?? 1500)
        context.log("💓 lobby_heartbeat sent")
        return LiqiToolResult.dictionaryLoggingRejection(outcome, spec: spec,
                                                         extra: ["no_operation_counter": Int(counter)])
    }
}

// MARK: - Login Beat Tool

/// 登入保活
struct LoginBeatTool: MCPTool {
    static let name = "lobby_login_beat"
    static let description = """
        送出登入保活。送出 .lq.Lobby.loginBeat（ReqLoginBeat：contract=1）。\
        ⚠️ contract 的來源與內容未驗證（一般由登入流程取得），空字串會送出空 payload。
        """
    static let inputSchema = MCPInputSchema(
        properties: [
            "contract": .string("contract 字串（由登入流程取得）"),
            "awaitResponseMs": .integer("等待伺服器回應的毫秒數（預設 1500）")
        ],
        required: []
    )

    private let context: MCPContext

    init(context: MCPContext) {
        self.context = context
    }

    func execute(arguments: [String: Any]) async throws -> Any {
        let nakiContext = try context.naki()
        let contract = arguments["contract"] as? String ?? ""
        let spec = LiqiRequestBuilder.loginBeat(contract: contract)
        let outcome = await nakiContext.sendLiqi(spec,
                                                 awaitResponseMs: arguments["awaitResponseMs"] as? Int ?? 1500)
        return LiqiToolResult.dictionaryLoggingRejection(outcome, spec: spec,
                                                         extra: ["contractProvided": !contract.isEmpty])
    }
}

// MARK: - Anti-Idle Toggle Tool

/// 自動心跳（防閒置）開關
struct AntiIdleToggleTool: MCPTool {
    static let name = "lobby_anti_idle"
    static let description = """
        切換自動防閒置：啟用後由 Swift 定期送 .lq.Lobby.heatbeat（取代已刪除的 \
        window.__nakiAntiIdle，它呼叫 Unity 下不存在的 GameMgr.Inst.clientHeatBeat()）。\
        不帶參數則只回報目前狀態。
        """
    static let inputSchema = MCPInputSchema(
        properties: [
            "enabled": .boolean("是否啟用自動心跳（不提供則只回報狀態）"),
            "intervalSeconds": .integer("送出間隔秒數（預設 300，下限 30）")
        ],
        required: []
    )

    private let context: MCPContext

    init(context: MCPContext) {
        self.context = context
    }

    func execute(arguments: [String: Any]) async throws -> Any {
        let nakiContext = try context.naki()

        let enabled = arguments["enabled"] as? Bool
        let interval = (arguments["intervalSeconds"] as? Int).map { TimeInterval($0) }

        guard var status = nakiContext.setAntiIdle(enabled: enabled, intervalSeconds: interval) else {
            return [
                "success": false,
                "error": "anti_idle_not_configured",
                "reason": "這條 WebView path 不提供自動心跳（未驗證的 Legacy path 上動作面一律停用）"
            ]
        }

        status["success"] = true
        if let enabled {
            context.log(enabled ? "🛡️ Anti-idle enabled (Liqi heatbeat)" : "⏹️ Anti-idle disabled")
        }
        return status
    }
}
