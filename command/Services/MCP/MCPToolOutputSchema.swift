//
//  MCPToolOutputSchema.swift
//  Naki
//
//  每個 MCP 工具的 outputSchema（MCP 2025-06-18 起的 structured tool output）
//

import Foundation

/// 工具結果的 `outputSchema`。
///
/// 為什麼不是寫在各個工具型別上：`MCPTool` 協定來自 MCPKit（另一個 repo），
/// 這一輪不動它。schema 放在這裡由 `MCPToolRegistry.allToolDefinitions()` 掛上去，
/// 對 client 而言完全等價，而且 38 個工具的輸出契約能一眼看完。
///
/// **宣告原則**：規格對 `outputSchema` 是 MUST——宣告了就必須符合。
/// 所以這裡只寫「讀程式碼可以確定一定會有」的欄位，其餘用 `additionalProperties: true`
/// 放行；沒把握的欄位寫進 `required` 只會製造假的違規，比不宣告更糟。
/// 沒有 `$schema` 欄位＝JSON Schema 2020-12（規格的預設 dialect）。
enum NakiToolOutputSchemas {

    // MARK: - 查詢

    /// 找不到就回一個寬鬆物件——`tools/list` 寧可少宣告，也不要漏掉 outputSchema
    nonisolated static func schema(for toolName: String) -> [String: Any] {
        all[toolName] ?? object("工具結果（未宣告細部欄位）")
    }

    /// 有明確宣告的工具名（單測用來擋「新增工具忘了補 schema」）
    nonisolated static var declaredToolNames: Set<String> {
        Set(all.keys)
    }

    // MARK: - 表

    nonisolated static var all: [String: [String: Any]] {
        var table: [String: [String: Any]] = [:]

        // ── 系統 ─────────────────────────────────────────────
        table["get_status"] = object(
            "Server 狀態、版本、工具數與 log 路徑",
            properties: [
                "status": string("固定為 running"),
                "port": integer("loopback port"),
                "appVersion": string("CFBundleShortVersionString"),
                "appBuild": string("CFBundleVersion"),
                "toolsCount": integer("registry 實際註冊的工具數"),
                "mcpProtocol": object("current / supported / legacyHandshake 協定版本"),
                "timestamp": string("ISO8601 時間"),
                "logDir": string("本次執行的 log 目錄"),
                "logFile": string("合併 log 路徑"),
                "eventLog": string("對局事件 log 路徑"),
                "categoryLogs": object("分類 log 路徑（Bridge / Bot / WS / Liqi…）")
            ],
            required: ["status", "port", "appVersion", "toolsCount"])

        table["get_help"] = object(
            "JSON 版 API 說明（與 GET /help 同一份內容）",
            properties: [
                "name": string("說明文件名稱"),
                "version": string("這份說明的版本，與 App 版本不同"),
                "app_version": string("App 版本（含 build）"),
                "base_url": string("loopback base URL"),
                "mcp_endpoint": string("MCP endpoint"),
                "tools_count": integer("registry 實際註冊的工具數"),
                "protocol": object("支援的 MCP 版本與 structuredContent／Origin 規則"),
                "architecture": object("Unity／協定層／高亮的現況說明"),
                "workflows": object("常見流程"),
                "caveats": array("必讀限制"),
                "tile_notation": object("牌記法對照")
            ],
            required: ["name", "tools_count"])

        table["get_logs"] = object(
            "記憶體中的近期 log",
            properties: [
                "logs": array("log 行（依 timestamp 排序）"),
                "count": integer("行數")
            ],
            required: ["logs", "count"])

        table["clear_logs"] = successMessage("清空記憶體 log 的結果")

        table["replay_list"] = object(
            "已錄下的對局清單",
            properties: [
                "directory": string("錄影目錄"),
                "count": integer("錄影數"),
                "games": array("每局：file / events / bytes / path"),
                "note": string("下一步提示")
            ],
            required: ["directory", "count", "games"])

        table["replay_game"] = object(
            "離線重跑一局的決策（不會送出任何 Liqi 請求）",
            properties: [
                "source": string("錄影檔名"),
                "events": integer("事件總數"),
                "playerId": integer("座位"),
                "is3P": boolean("是否三麻"),
                "decisions": array("每步決策：index / event / action"),
                "decisionCount": integer("回傳的決策數"),
                "truncated": boolean("是否因 limit 被截斷"),
                "errors": array("重跑過程中的錯誤"),
                "note": string("資料語意說明")
            ],
            required: ["source", "events", "decisions", "decisionCount"])

        // ── Bot ─────────────────────────────────────────────
        table["bot_status"] = object(
            "Bot、對局狀態、模式與 AI 推薦（由 GameStore 供給）",
            properties: [
                "botStatus": object("isActive / playerId"),
                "gameState": object("bakaze / kyoku / honba"),
                "autoPlay": object("mode"),
                "recommendations": array("tile / action / label / prob / percentage"),
                "tehaiCount": integer("手牌張數"),
                "tsumoTile": any("剛摸到的牌，沒有時為 null")
            ])

        table["bot_trigger"] = successMessage("手動觸發自動打牌的結果")

        table["bot_ops"] = opsSnapshot
        table["game_ops"] = opsSnapshot

        table["bot_deep"] = object(
            "協定層完整診斷",
            properties: [
                "source": string("固定 swift-protocol-layer"),
                "registeredTools": integer("registry 工具數"),
                "snapshot": nullableObject("遊戲快照；回調未設定時為 null"),
                "snapshotError": string("快照不可用的原因"),
                "recentResponses": array("Naki 自送請求（msgId >= 60000）的 RESPONSE"),
                "broadcasts": array("收到的表情廣播"),
                "note": string("資料範圍說明")
            ],
            required: ["source", "registeredTools"])

        table["bot_chi"] = liqiSend(extra: [
            "index": integer("使用的吃組合索引"),
            "availableCombinations": array("oplist 提供的組合")
        ])
        table["bot_pon"] = liqiSend(extra: [
            "index": integer("使用的碰組合索引"),
            "availableCombinations": array("oplist 提供的組合")
        ])

        table["bot_sync"] = object(
            "強制重連結果",
            properties: [
                "success": boolean("是否關閉了至少一條連線"),
                "closedConnections": integer("被關閉的 WebSocket 數"),
                "message": string("人可讀說明")
            ],
            required: ["success", "closedConnections", "message"])

        // ── 遊戲狀態 ─────────────────────────────────────────
        table["game_state"] = object(
            "Liqi 封包在 Swift 端重建的對局快照（不是向伺服器查詢）",
            properties: [
                "source": string("固定 swift-protocol-layer"),
                "note": string("資料語意說明"),
                "accountId": integer("已解析到的帳號 id，未登入為 0"),
                "gameState": object("bakaze / kyoku / honba / kyotaku / scores / dora / seat / inGame"),
                "bot": object("isActive / model / seat / can* 旗標"),
                "hand": object("tehai / tehaiCount / tsumo（MJAI 記法）"),
                "recommendations": array("AI 推薦"),
                "autoPlay": object("mode"),
                "operations": object("pending / latest 的協定層 oplist")
            ])

        table["game_hand"] = object(
            "手牌與 AI 推薦",
            properties: [
                "source": string("資料來源"),
                "hand": nullableObject("tehai / tehaiCount / tsumo"),
                "recommendations": array("AI 推薦"),
                "seat": any("座位；未知為 null")
            ],
            required: ["source"])

        // ── 遊戲動作 ─────────────────────────────────────────
        table["game_discard"] = liqiSend(extra: [
            "tile": string("送出的牌（雀魂記法）"),
            "moqie": boolean("是否摸切")
        ])
        table["game_action"] = liqiSend(extra: [
            "action": string("動作名稱")
        ])
        table["game_action_verify"] = liqiSend(extra: [
            "action": string("動作名稱"),
            "verified": boolean("是否觀察到生效訊號"),
            "verifyReason": string("ops_snapshot_advanced / server_response_without_error / no_signal_within_timeout / not_sent"),
            "opsAdvanced": boolean("可用操作快照是否被推進"),
            "beforeSequence": any("送出前的 oplist sequence"),
            "afterSequence": any("送出後的 oplist sequence"),
            "verifyNote": string("opsAdvanced=false 不等於失敗的說明")
        ])

        // ── JavaScript ───────────────────────────────────────
        table["execute_js"] = object(
            "WebView 執行 JavaScript 的回傳值",
            properties: ["result": any("函數體的 return 值；沒有 return 時為 null")],
            required: ["result"])

        // ── 大廳 ─────────────────────────────────────────────
        for name in ["lobby_status", "lobby_server_time", "lobby_heartbeat", "lobby_login_beat"] {
            table[name] = liqiSend()
        }
        table["lobby_start_match"] = liqiSend(extra: ["match_mode": integer("送出的 match_mode")])
        table["lobby_cancel_match"] = liqiSend(extra: ["match_mode": integer("取消的 match_mode")])
        table["lobby_account_info"] = liqiSend(extra: [
            "account_id": integer("查詢的帳號 id"),
            "accountIdSource": string("naki-login-capture 或 argument"),
            "hint": string("缺 account_id 時的補救方式")
        ])

        table["lobby_match_modes"] = object(
            "從遊戲流量觀察到的 match_mode（不是靜態對照表）",
            properties: [
                "source": string("資料來源說明"),
                "knownErrorForBadMode": string("1306 = match_mode 不存在")
            ],
            required: ["source"])

        table["lobby_anti_idle"] = object(
            "自動心跳（防閒置）狀態",
            properties: [
                "success": boolean("回調是否可用"),
                "error": string("anti_idle_not_configured"),
                "reason": string("失敗原因")
            ],
            required: ["success"])

        // ── 友人房 ───────────────────────────────────────────
        table["room_create"] = liqiSend(extra: [
            "config": object("送出的房間設定"),
            "nextSteps": array("建議的下一步工具")
        ])
        table["room_add_robot"] = liqiSend(extra: ["position": integer("加入的座位")])
        table["room_start"] = liqiSend()
        table["room_info"] = liqiSend()
        table["room_join"] = liqiSend(extra: ["room_id": integer("加入的房號")])
        table["room_leave"] = liqiSend()
        table["room_quick_test"] = object(
            "建房 → 補人機 → 開局的逐步結果",
            properties: [
                "success": boolean("三步是否全部被伺服器接受"),
                "failedAt": string("失敗的步驟名稱"),
                "playerCount": integer("房間人數"),
                "steps": array("每步：step / serverAccepted / detail / response"),
                "reconnect_hint": string("客戶端沒進場時的補救方式")
            ],
            required: ["success", "steps"])

        // ── 表情 ─────────────────────────────────────────────
        table["game_emoji"] = object(
            "表情送出結果",
            properties: [
                "success": boolean("是否全部送出成功"),
                "emo_id": integer("表情索引"),
                "requested": integer("要求送幾次"),
                "sentCount": integer("實際成功幾次"),
                "content": string("送出的 content JSON"),
                "method": string(".lq.FastTest.broadcastInGame"),
                "sends": array("逐次送出的完整結果")
            ],
            required: ["success", "sends"])

        table["game_emoji_listen"] = object(
            "收到的表情廣播紀錄",
            properties: [
                "success": boolean("固定 true"),
                "source": string("LiqiResponseStore (.lq.NotifyGameBroadcast)"),
                "count": integer("紀錄筆數"),
                "broadcasts": array("每筆廣播"),
                "cleared": boolean("是否在回傳後清空")
            ],
            required: ["success", "count", "broadcasts"])

        return table
    }

    // MARK: - 共用 schema

    /// 送 Liqi request 的工具共用這一份（`LiqiToolResult.dictionary` 的輸出）
    nonisolated static func liqiSend(extra: [String: [String: Any]] = [:]) -> [String: Any] {
        var properties: [String: [String: Any]] = [
            "success": boolean("bytes 是否成功交給 WebSocket——**不等於**伺服器接受"),
            "method": string("送出的 Liqi method"),
            "payloadHex": string("protobuf payload 的 hex（對拍用）"),
            "msgId": integer("Naki 自送請求的 msgId（60000 號段）"),
            "bytes": integer("送出的 byte 數"),
            "detail": string("送出通道的診斷訊息"),
            "error": string("liqi_sender_unavailable / send_failed / 工具自訂代碼"),
            "reason": string("失敗原因（人可讀）"),
            "serverAccepted": boolean("同 msgId 的 RESPONSE 沒有 error 才是 true"),
            "response": nullableObject("伺服器對該 msgId 的 RESPONSE，欄位以 fieldN 呈現"),
            "note": string("尚未收到 RESPONSE 時的說明")
        ]
        properties.merge(extra) { _, new in new }
        return object(
            "Liqi request 送出結果。判斷成功一律看 serverAccepted / response，不要只看 success。",
            properties: properties,
            required: ["success"])
    }

    /// 協定層 oplist 快照（`bot_ops` / `game_ops`）
    nonisolated static var opsSnapshot: [String: Any] {
        object(
            "協定層 OptionalOperationList 快照",
            properties: [
                "source": string("LiqiOperationStore (Liqi protocol layer)"),
                "hasPending": boolean("是否有尚未被消化的機會"),
                "pending": nullableObject("尚未被動作層消化的 oplist"),
                "latest": nullableObject("最近一次收到的 oplist（不論是否已處理）")
            ],
            required: ["source", "hasPending", "pending", "latest"])
    }

    nonisolated static func successMessage(_ description: String) -> [String: Any] {
        object(description,
               properties: [
                   "success": boolean("是否成功"),
                   "message": string("人可讀說明")
               ],
               required: ["success", "message"])
    }

    // MARK: - 小建構子

    nonisolated static func object(_ description: String,
                                   properties: [String: [String: Any]] = [:],
                                   required: [String] = []) -> [String: Any] {
        var schema: [String: Any] = [
            "type": "object",
            "description": description,
            // 工具回的是 runtime payload，不是固定 struct。宣告了 outputSchema
            // 就 MUST 相符，所以未列出的欄位一律放行。
            "additionalProperties": true
        ]
        if !properties.isEmpty { schema["properties"] = properties }
        if !required.isEmpty { schema["required"] = required }
        return schema
    }

    nonisolated static func string(_ description: String) -> [String: Any] {
        ["type": "string", "description": description]
    }

    nonisolated static func integer(_ description: String) -> [String: Any] {
        ["type": "integer", "description": description]
    }

    nonisolated static func boolean(_ description: String) -> [String: Any] {
        ["type": "boolean", "description": description]
    }

    nonisolated static func array(_ description: String) -> [String: Any] {
        ["type": "array", "description": description]
    }

    nonisolated static func nullableObject(_ description: String) -> [String: Any] {
        ["type": ["object", "null"], "description": description]
    }

    /// 型別不固定的欄位（例如 `execute_js` 的 return 值）：不宣告 type
    nonisolated static func any(_ description: String) -> [String: Any] {
        ["description": description]
    }
}
