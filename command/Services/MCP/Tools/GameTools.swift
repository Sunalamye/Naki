//
//  GameTools.swift
//  Naki
//
//  Created by Claude on 2025/12/05.
//  Updated 2026-07-31：Unity 遷移，整檔改寫。
//
//  舊實作全部呼叫 `window.__nakiGameAPI.*`，那層讀的是 Laya 的
//  `window.view.DesktopMgr.Inst`（手牌、oplist、打牌）。Unity WebGL 客戶端下
//  這個物件**實測不存在**，所以舊工具是靜默失敗（回 `{"error":"API not loaded"}`
//  或 `success:false`），不是「偶爾失敗」。
//
//  新分工：
//  - 狀態（state / hand / ops）→ Swift 協定層（`WebViewModel.protocolGameSnapshot()`，
//    資料來自 MajsoulBridge → NativeBotController + LiqiOperationStore）
//  - 動作（discard / action / action_verify）→ Liqi protobuf（`LiqiActionSender`）
//

#if os(macOS)

import Foundation
import MCPKit

// MARK: - 動作解析（純函式，可單元測試）

/// 把 MCP 的動作名稱 + 參數解析成 Liqi 請求。
///
/// 需要 oplist 快照的地方（槓型、和牌型、pass 走哪個方法）都由參數傳入，
/// 讓這一層保持無狀態、可對拍。
enum NakiGameAction {

    /// 支援的動作名稱（同時給 schema 描述與錯誤訊息用）
    static let supported = [
        "discard", "riichi", "chi", "pon", "kan",
        "tsumo", "ron", "hora", "kyushu", "babei", "pass"
    ]

    /// 牌字串正規化：接受 MJAI（`5mr` / `E`）或雀魂（`0m` / `1z`），一律轉成雀魂格式。
    /// - Returns: 雀魂格式牌字串；無法辨識回 nil
    static func majsoulTile(from input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        // 先當 MJAI 解（5mr → 0m、E → 1z）
        if let converted = LiqiTileCode.majsoul(fromMJAI: trimmed) { return converted }
        // 再確認是不是本來就是合法的雀魂牌字串
        if LiqiTileCode.mjai(fromMajsoul: trimmed) != nil { return trimmed }
        return nil
    }

    /// 解析槓型（未指定時由 oplist 推導，再退回暗槓）
    static func kanType(explicit: String?, snapshot: LiqiOperationSnapshot?) -> LiqiOperationType {
        switch explicit?.lowercased() {
        case "ankan": return .ankan
        case "minkan", "daiminkan": return .minkan
        case "kakan": return .kakan
        default: return snapshot?.kanOperation ?? .ankan
        }
    }

    /// 依動作名稱組出 Liqi 請求
    /// - Parameters:
    ///   - action: 動作名稱（見 `supported`）
    ///   - arguments: MCP 參數
    ///   - snapshot: 目前的可用操作快照（可為 nil）
    static func spec(action: String,
                     arguments: [String: Any],
                     snapshot: LiqiOperationSnapshot?) throws -> LiqiRequestSpec {
        let name = action.lowercased()
        let timeuse = UInt32(max(0, arguments["timeuse"] as? Int ?? 0))
        let index = UInt32(max(0, arguments["index"] as? Int ?? 0))

        func requiredTile() throws -> String {
            guard let raw = arguments["tile"] as? String else {
                throw MCPToolError.missingParameter("tile")
            }
            guard let tile = majsoulTile(from: raw) else {
                throw MCPToolError.invalidParameter("tile", expected: "MJAI（5mr / E）或雀魂（0m / 1z）格式牌字串")
            }
            return tile
        }

        switch name {
        case "discard":
            let tile = try requiredTile()
            let moqie = arguments["moqie"] as? Bool ?? false
            return LiqiRequestBuilder.discard(tile: tile, moqie: moqie, timeuse: timeuse)

        case "riichi":
            // ReqSelfOperation(type=7) 必須同時帶上宣言時打出的牌
            let tile = try requiredTile()
            let moqie = arguments["moqie"] as? Bool ?? false
            return LiqiRequestBuilder.riichi(tile: tile, moqie: moqie, timeuse: timeuse)

        case "chi":
            return LiqiRequestBuilder.chi(index: index, timeuse: timeuse)

        case "pon":
            return LiqiRequestBuilder.pon(index: index, timeuse: timeuse)

        case "kan":
            let type = kanType(explicit: arguments["kanType"] as? String, snapshot: snapshot)
            let tile = (arguments["tile"] as? String).flatMap { majsoulTile(from: $0) }
            return LiqiRequestBuilder.kan(type: type, index: index, tile: tile, timeuse: timeuse)

        case "tsumo":
            return LiqiRequestBuilder.tsumo(timeuse: timeuse)

        case "ron":
            return LiqiRequestBuilder.ron(timeuse: timeuse)

        case "hora":
            // 由 oplist 決定自摸還是榮和。⚠️ 現行 legacy fallback 在沒有 snapshot 時取自摸；
            // 這不是 server-authoritative，呼叫端必須先查 game_ops，後續應改成 fail closed。
            if (snapshot?.horaOperation ?? .tsumo) == .ron {
                return LiqiRequestBuilder.ron(timeuse: timeuse)
            }
            return LiqiRequestBuilder.tsumo(timeuse: timeuse)

        case "kyushu":
            return LiqiRequestBuilder.kyushu(timeuse: timeuse)

        case "babei":
            return LiqiRequestBuilder.babei(timeuse: timeuse)

        case "pass", "none", "cancel":
            // 回應他家打牌走 inputChiPengGang，自家回合的選項走 inputOperation
            let channel: LiqiActionChannel = (snapshot?.isCallOpportunity ?? true)
                ? .chiPengGang : .selfOperation
            return LiqiRequestBuilder.cancel(channel: channel, timeuse: timeuse)

        default:
            throw MCPToolError.invalidParameter("action", expected: supported.joined(separator: " / "))
        }
    }
}

// MARK: - Game State Tool

/// 獲取當前遊戲狀態（Swift 協定層）
struct GameStateTool: MCPTool {
    static let name = "game_state"
    static let description = """
        獲取當前遊戲狀態（場風/局/本場/供託/分數/寶牌/座位 + Bot 狀態 + 可用操作）。\
        資料由 Liqi 封包在 Swift 端重建，**不是**向伺服器查詢，也不再依賴任何 JS 遊戲物件。
        """
    static let inputSchema = MCPInputSchema.empty

    private let context: MCPContext

    init(context: MCPContext) {
        self.context = context
    }

    func execute(arguments: [String: Any]) async throws -> Any {
        guard let nakiContext = context as? NakiMCPContext,
              let snapshot = nakiContext.getGameSnapshot() else {
            throw MCPToolError.notAvailable("Game snapshot")
        }
        return snapshot
    }
}

// MARK: - Game Hand Tool

/// 獲取手牌資訊（Swift 協定層）
struct GameHandTool: MCPTool {
    static let name = "game_hand"
    static let description = "獲取手牌資訊（MJAI 記法）與目前的 AI 推薦。資料來自 Swift 協定層，不依賴 JS 遊戲物件"
    static let inputSchema = MCPInputSchema.empty

    private let context: MCPContext

    init(context: MCPContext) {
        self.context = context
    }

    func execute(arguments: [String: Any]) async throws -> Any {
        guard let nakiContext = context as? NakiMCPContext,
              let snapshot = nakiContext.getGameSnapshot() else {
            throw MCPToolError.notAvailable("Game snapshot")
        }

        var result: [String: Any] = [
            "source": snapshot["source"] ?? "swift-protocol-layer"
        ]
        result["hand"] = snapshot["hand"] ?? NSNull()
        result["recommendations"] = snapshot["recommendations"] ?? []
        result["seat"] = (snapshot["gameState"] as? [String: Any])?["seat"] ?? NSNull()
        return result
    }
}

// MARK: - Game Ops Tool

/// 獲取當前可用操作（協定層 oplist）
struct GameOpsTool: MCPTool {
    static let name = "game_ops"
    static let description = """
        獲取當前可用操作（協定層 OptionalOperationList）。\
        type 對照：1=打牌 2=吃 3=碰 4=暗槓 5=大明槓 6=加槓 7=立直 8=自摸 9=榮和 10=九種九牌 11=拔北。\
        runtime 已驗 discard / pon / riichi / tsumo request / ron；chi variants、赤五組合與三種槓仍待驗。
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

// MARK: - Game Discard Tool

/// 打牌（Liqi protobuf）
struct GameDiscardTool: MCPTool {
    static let name = "game_discard"
    static let description = """
        打出指定的牌。送出 .lq.FastTest.inputOperation (type=1)。\
        tile 接受 MJAI（5m / 5mr / E）或雀魂（5m / 0m / 1z）記法。\
        ⚠️ 不再使用手牌索引：Unity 客戶端沒有 UI 手牌陣列，索引沒有對應對象。
        """
    static let inputSchema = MCPInputSchema(
        properties: [
            "tile": .string("要打出的牌，MJAI（5mr / E）或雀魂（0m / 1z）記法"),
            "moqie": .boolean("是否為摸切（預設 false）"),
            "awaitResponseMs": .integer("等待伺服器回應的毫秒數（預設 800，0 = 不等）")
        ],
        required: ["tile"]
    )

    private let context: MCPContext

    init(context: MCPContext) {
        self.context = context
    }

    func execute(arguments: [String: Any]) async throws -> Any {
        guard let nakiContext = context as? NakiMCPContext else {
            throw MCPToolError.notAvailable("Naki context")
        }

        let snapshot = LiqiOperationStore.shared.pending
        let spec = try NakiGameAction.spec(action: "discard",
                                           arguments: arguments,
                                           snapshot: snapshot)
        let awaitMs = arguments["awaitResponseMs"] as? Int ?? 800
        let outcome = await nakiContext.sendLiqi(spec, awaitResponseMs: awaitMs)
        return LiqiToolResult.dictionary(outcome, spec: spec,
                                         extra: ["tile": arguments["tile"] as? String ?? "",
                                                 "moqie": arguments["moqie"] as? Bool ?? false])
    }
}

// MARK: - Game Action Tool

/// 執行遊戲動作（Liqi protobuf）
struct GameActionTool: MCPTool {
    static let name = "game_action"
    static let description = """
        執行遊戲動作，送出對應的 Liqi REQUEST。\
        action: discard / riichi（需 tile）、chi / pon / kan（可帶 index）、\
        tsumo / ron / hora / kyushu / babei / pass。hora 必須先有 game_ops snapshot；\
        現行無 snapshot fallback 會猜 tsumo，不具 server-authoritative 保證。\
        kan 未指定 kanType 時依 game_ops 推導（暗槓→加槓→大明槓）；\
        pass 依 game_ops 判斷送 inputChiPengGang 或 inputOperation。
        """
    static let inputSchema = MCPInputSchema(
        properties: [
            "action": .string("動作名稱：discard / riichi / chi / pon / kan / tsumo / ron / hora / kyushu / babei / pass"),
            "tile": .string("discard / riichi 必填；kan 可選。MJAI 或雀魂記法"),
            "moqie": .boolean("discard / riichi：是否摸切（預設 false）"),
            "index": .integer("chi / pon / kan：組合索引（預設 0）"),
            "kanType": .string("kan：ankan（暗槓）/ kakan（加槓）/ minkan（大明槓）；不填則由 game_ops 推導"),
            "timeuse": .integer("思考秒數（預設 0）"),
            "awaitResponseMs": .integer("等待伺服器回應的毫秒數（預設 800，0 = 不等）")
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
        guard let nakiContext = context as? NakiMCPContext else {
            throw MCPToolError.notAvailable("Naki context")
        }

        let snapshot = LiqiOperationStore.shared.pending
        let spec = try NakiGameAction.spec(action: action,
                                           arguments: arguments,
                                           snapshot: snapshot)
        let awaitMs = arguments["awaitResponseMs"] as? Int ?? 800
        let outcome = await nakiContext.sendLiqi(spec, awaitResponseMs: awaitMs)
        return LiqiToolResult.dictionary(outcome, spec: spec,
                                         extra: ["action": action])
    }
}

// MARK: - Game Action Verify Tool

/// 執行遊戲動作並在協定層驗證
struct GameActionVerifyTool: MCPTool {
    static let name = "game_action_verify"
    static let description = """
        執行遊戲動作並驗證是否真的生效。驗證訊號改為協定層：\
        (1) 伺服器對該 msgId 的 RESPONSE；(2) 可用操作快照的 sequence 是否被推進／清空\
        （代表伺服器已推播新的對局動作）。\
        取代舊的「等 oplist 清空 + 手牌數變化」JS 驗證（依賴已不存在的 DesktopMgr）。
        """
    static let inputSchema = MCPInputSchema(
        properties: [
            "action": .string("動作名稱（同 game_action）"),
            "tile": .string("discard / riichi 必填；kan 可選"),
            "moqie": .boolean("是否摸切（預設 false）"),
            "index": .integer("chi / pon / kan 的組合索引（預設 0）"),
            "kanType": .string("ankan / kakan / minkan"),
            "timeout": .integer("驗證逾時毫秒（預設 2000）")
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
        guard let nakiContext = context as? NakiMCPContext else {
            throw MCPToolError.notAvailable("Naki context")
        }

        let store = LiqiOperationStore.shared
        let before = store.pending
        let timeout = max(0, arguments["timeout"] as? Int ?? 2000)

        let spec = try NakiGameAction.spec(action: action,
                                           arguments: arguments,
                                           snapshot: before)
        // 一半時間用來等 RESPONSE，另一半等對局動作推進
        let outcome = await nakiContext.sendLiqi(spec, awaitResponseMs: timeout / 2)

        var result = LiqiToolResult.dictionary(outcome, spec: spec, extra: ["action": action])

        guard outcome.sent?.success == true else {
            result["verified"] = false
            result["verifyReason"] = "not_sent"
            return result
        }

        // 等可用操作被推進（新 sequence）或清空
        let deadlineMs = timeout - timeout / 2
        var waited = 0
        var advanced = false
        while waited < deadlineMs {
            let now = store.pending
            if now?.sequence != before?.sequence {
                advanced = true
                break
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
            waited += 50
        }

        let serverAccepted = outcome.response.map { !$0.hasError }
        result["verified"] = advanced || serverAccepted == true
        result["opsAdvanced"] = advanced
        result["beforeSequence"] = before.map { Int($0.sequence) } ?? NSNull()
        result["afterSequence"] = store.pending.map { Int($0.sequence) } ?? NSNull()
        result["verifyReason"] = advanced
            ? "ops_snapshot_advanced"
            : (serverAccepted == true ? "server_response_without_error" : "no_signal_within_timeout")
        result["verifyNote"] = "opsAdvanced=false 不代表失敗：若這個動作不會立刻產生新的可用操作"
            + "（例如打牌後輪到他家），只能靠 RESPONSE 判斷。"
        return result
    }
}

#endif  // os(macOS)
