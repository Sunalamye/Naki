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
//  docs/protocol/liqi.json（見各工具註解），但**伺服器是否接受、match_mode 的
//  數值語意**仍需真實登入驗證。
//
//  移除的工具：
//  - `lobby_match_status`：協定沒有「查詢自己排隊狀態」的方法（客戶端自己記），
//    功能併入 `lobby_status`（fetchGamingInfo）。
//  - `lobby_navigate`：純 UI 換頁，Unity 下沒有可操作的 UI 層，也沒有協定等價物。
//  - `lobby_idle_status`：讀 `GameMgr.Inst._last_heatbeat_time`；改由 `lobby_anti_idle`
//    回報 Naki 自己送出的心跳狀態。
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
        guard let nakiContext = context as? NakiMCPContext else {
            throw MCPToolError.notAvailable("Naki context")
        }
        let spec = LiqiRequestBuilder.fetchGamingInfo()
        let outcome = await nakiContext.sendLiqi(spec,
                                                 awaitResponseMs: arguments["awaitResponseMs"] as? Int ?? 1500)
        return LiqiToolResult.dictionary(outcome, spec: spec)
    }
}

// MARK: - Match Mode List Tool

/// 匹配模式對照表（靜態，不碰遊戲物件）
struct MatchModeListTool: MCPTool {
    static let name = "lobby_match_modes"
    static let description = "獲取段位場 match_mode 對照表（給 lobby_start_match / lobby_cancel_match 用）"
    static let inputSchema = MCPInputSchema.empty

    private let context: MCPContext

    init(context: MCPContext) {
        self.context = context
    }

    func execute(arguments: [String: Any]) async throws -> Any {
        let modes: [[String: Any]] = [
            ["id": 1, "room": "銅之間", "type": "東風", "minLevel": 0, "description": "銅之間 - 東風戰"],
            ["id": 2, "room": "銅之間", "type": "半莊", "minLevel": 0, "description": "銅之間 - 半莊戰"],
            ["id": 4, "room": "銀之間", "type": "東風", "minLevel": 10200, "description": "銀之間 - 東風戰"],
            ["id": 5, "room": "銀之間", "type": "半莊", "minLevel": 10200, "description": "銀之間 - 半莊戰"],
            ["id": 7, "room": "金之間", "type": "東風", "minLevel": 10300, "description": "金之間 - 東風戰"],
            ["id": 8, "room": "金之間", "type": "半莊", "minLevel": 10300, "description": "金之間 - 半莊戰"],
            ["id": 10, "room": "玉之間", "type": "東風", "minLevel": 10400, "description": "玉之間 - 東風戰"],
            ["id": 11, "room": "玉之間", "type": "半莊", "minLevel": 10400, "description": "玉之間 - 半莊戰"],
            ["id": 13, "room": "王座之間", "type": "東風", "minLevel": 10501, "description": "王座之間 - 東風戰"],
            ["id": 14, "room": "王座之間", "type": "半莊", "minLevel": 10501, "description": "王座之間 - 半莊戰"]
        ]

        return [
            "modes": modes,
            "levelEncoding": [
                "10xxx": "四麻 (4-player)",
                "20xxx": "三麻 (3-player)",
                "x01xx": "初心",
                "x02xx": "雀士",
                "x03xx": "雀傑",
                "x04xx": "雀豪",
                "x05xx": "雀聖",
                "x06xx": "魂天"
            ],
            "warning": "match_mode 數值來自 Laya 時代的觀察，liqi.json 沒有對應 enum，尚未以真實封包驗證"
        ]
    }
}

// MARK: - Start Match Tool

/// 開始段位場匹配
struct StartMatchTool: MCPTool {
    static let name = "lobby_start_match"
    static let description = """
        開始段位場匹配。送出 .lq.Lobby.matchGame（ReqJoinMatchQueue：match_mode=1, \
        client_version_string=2）。match_mode 對照表見 lobby_match_modes。\
        ⚠️ 真的會排進伺服器隊列，請只在測試帳號使用。
        """
    static let inputSchema = MCPInputSchema(
        properties: [
            "match_mode": .integer("匹配模式 ID（1=銅東, 2=銅半, 4=銀東, 5=銀半, 7=金東, 8=金半, 10=玉東, 11=玉半, 13=王座東, 14=王座半）"),
            "client_version_string": .string("客戶端版本字串（可選，空字串則不送此欄位）"),
            "awaitResponseMs": .integer("等待伺服器回應的毫秒數（預設 1500）")
        ],
        required: ["match_mode"]
    )

    private let context: MCPContext

    init(context: MCPContext) {
        self.context = context
    }

    func execute(arguments: [String: Any]) async throws -> Any {
        guard let matchMode = arguments["match_mode"] as? Int else {
            throw MCPToolError.missingParameter("match_mode")
        }
        let validModes = [1, 2, 4, 5, 7, 8, 10, 11, 13, 14]
        guard validModes.contains(matchMode) else {
            throw MCPToolError.invalidParameter("match_mode", expected: "1, 2, 4, 5, 7, 8, 10, 11, 13, 14")
        }
        guard let nakiContext = context as? NakiMCPContext else {
            throw MCPToolError.notAvailable("Naki context")
        }

        let spec = LiqiRequestBuilder.matchGame(
            matchMode: UInt32(matchMode),
            clientVersionString: arguments["client_version_string"] as? String ?? "")
        let outcome = await nakiContext.sendLiqi(spec,
                                                 awaitResponseMs: arguments["awaitResponseMs"] as? Int ?? 1500)
        context.log("🎮 lobby_start_match match_mode=\(matchMode)")
        return LiqiToolResult.dictionary(outcome, spec: spec, extra: ["match_mode": matchMode])
    }
}

// MARK: - Cancel Match Tool

/// 取消匹配
struct CancelMatchTool: MCPTool {
    static let name = "lobby_cancel_match"
    static let description = """
        取消段位場匹配。送出 .lq.Lobby.cancelMatch（ReqCancelMatchQueue：match_mode=1）。\
        ⚠️ match_mode 為必填：伺服器要知道取消哪一條隊列（與舊版無參數的行為不同）。
        """
    static let inputSchema = MCPInputSchema(
        properties: [
            "match_mode": .integer("要取消的匹配模式 ID（與 lobby_start_match 相同）"),
            "awaitResponseMs": .integer("等待伺服器回應的毫秒數（預設 1500）")
        ],
        required: ["match_mode"]
    )

    private let context: MCPContext

    init(context: MCPContext) {
        self.context = context
    }

    func execute(arguments: [String: Any]) async throws -> Any {
        guard let matchMode = arguments["match_mode"] as? Int else {
            throw MCPToolError.missingParameter("match_mode")
        }
        guard let nakiContext = context as? NakiMCPContext else {
            throw MCPToolError.notAvailable("Naki context")
        }

        let spec = LiqiRequestBuilder.cancelMatch(matchMode: UInt32(max(0, matchMode)))
        let outcome = await nakiContext.sendLiqi(spec,
                                                 awaitResponseMs: arguments["awaitResponseMs"] as? Int ?? 1500)
        context.log("⏹️ lobby_cancel_match match_mode=\(matchMode)")
        return LiqiToolResult.dictionary(outcome, spec: spec, extra: ["match_mode": matchMode])
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
        guard let nakiContext = context as? NakiMCPContext else {
            throw MCPToolError.notAvailable("Naki context")
        }

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

        let spec = LiqiRequestBuilder.fetchAccountInfo(accountId: UInt32(accountId))
        let outcome = await nakiContext.sendLiqi(spec,
                                                 awaitResponseMs: arguments["awaitResponseMs"] as? Int ?? 1500)
        return LiqiToolResult.dictionary(outcome, spec: spec,
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
        guard let nakiContext = context as? NakiMCPContext else {
            throw MCPToolError.notAvailable("Naki context")
        }
        let spec = LiqiRequestBuilder.fetchServerTime()
        let outcome = await nakiContext.sendLiqi(spec,
                                                 awaitResponseMs: arguments["awaitResponseMs"] as? Int ?? 1500)
        return LiqiToolResult.dictionary(outcome, spec: spec)
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
        guard let nakiContext = context as? NakiMCPContext else {
            throw MCPToolError.notAvailable("Naki context")
        }
        let counter = UInt32(max(0, arguments["no_operation_counter"] as? Int ?? 0))
        let spec = LiqiRequestBuilder.heatbeat(noOperationCounter: counter)
        let outcome = await nakiContext.sendLiqi(spec,
                                                 awaitResponseMs: arguments["awaitResponseMs"] as? Int ?? 1500)
        context.log("💓 lobby_heartbeat sent")
        return LiqiToolResult.dictionary(outcome, spec: spec,
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
        guard let nakiContext = context as? NakiMCPContext else {
            throw MCPToolError.notAvailable("Naki context")
        }
        let contract = arguments["contract"] as? String ?? ""
        let spec = LiqiRequestBuilder.loginBeat(contract: contract)
        let outcome = await nakiContext.sendLiqi(spec,
                                                 awaitResponseMs: arguments["awaitResponseMs"] as? Int ?? 1500)
        return LiqiToolResult.dictionary(outcome, spec: spec,
                                         extra: ["contractProvided": !contract.isEmpty])
    }
}

// MARK: - Anti-Idle Toggle Tool

/// 自動心跳（防閒置）開關
struct AntiIdleToggleTool: MCPTool {
    static let name = "lobby_anti_idle"
    static let description = """
        切換自動防閒置：啟用後由 Swift 定期送 .lq.Lobby.heatbeat（取代已失效的 \
        window.__nakiAntiIdle，它呼叫 GameMgr.Inst.clientHeatBeat()）。\
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
        guard let nakiContext = context as? NakiMCPContext else {
            throw MCPToolError.notAvailable("Naki context")
        }

        let enabled = arguments["enabled"] as? Bool
        let interval = (arguments["intervalSeconds"] as? Int).map { TimeInterval($0) }

        guard var status = nakiContext.setAntiIdle(enabled: enabled, intervalSeconds: interval) else {
            return [
                "success": false,
                "error": "anti_idle_not_configured",
                "reason": "尚未注入自動心跳控制回調（WebViewModel 未啟動 Debug Server 時會如此）"
            ]
        }

        status["success"] = true
        if let enabled {
            context.log(enabled ? "🛡️ Anti-idle enabled (Liqi heatbeat)" : "⏹️ Anti-idle disabled")
        }
        return status
    }
}
