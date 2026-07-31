//
//  RoomTools.swift
//  Naki
//
//  Created 2026-07-31：友人房（好友房）MCP 工具。
//
//  這一組是 Unity 遷移後**新增**的：舊架構下建友人房只能點 Laya UI
//  （`GameMgr.Inst.uimgr._ui_lobby.setPage(2)` → 一連串按鈕），Unity 下完全做不到。
//  改走協定層後反而更直接——建房到開局的完整路徑可以純由 MCP 工具跑完：
//
//      room_create(player_count=4, time_fixed=300, time_add=0)
//        → room_add_robot(position=1) × 3
//        → room_start
//
//  欄位編號全部查自 docs/protocol/liqi.json：
//      ReqCreateRoom  { player_count=1, mode=2(GameMode), public_live=3,
//                       client_version_string=4, pre_rule=5 }
//      GameMode       { mode=1, ai=4, extendinfo=5, detail_rule=6(GameDetailRule) }
//      GameDetailRule { time_fixed=1, time_add=2, dora_count=3, shiduan=4,
//                       init_point=5, fandian=6, ai_level=38 }
//      ReqAddRoomRobot{ position=1 }   ReqRoomStart{}   ReqJoinRoom{ room_id=1, cvs=2 }
//      leaveRoom / fetchRoom = ReqCommon（空 payload）
//
//  ⚠️ **未驗證**：`GameMode.mode` 的數值語意（常見說法 1=東風戰、2=半莊戰）、
//  `ai_level` 的有效範圍、以及伺服器是否會因缺 `client_version_string` 而拒絕。
//  這些都要真實登入後看 RESPONSE 才能確認。
//

import Foundation
import MCPKit

// MARK: - Room Create Tool

/// 建立友人房
struct RoomCreateTool: MCPTool {
    static let name = "room_create"
    static let description = """
        建立友人房。送出 .lq.Lobby.createRoom。\
        預設 4 人、半莊(mode=2)、思考時間 300+0 秒。\
        建房成功後用 room_add_robot 加人機、room_start 開局。\
        ⚠️ mode 數值語意（1=東風 / 2=半莊）未經真實封包驗證。
        """
    static let inputSchema = MCPInputSchema(
        properties: [
            "player_count": .integer("人數：4=四麻、3=三麻（預設 4）"),
            "mode": .integer("GameMode.mode：1=東風戰、2=半莊戰（預設 2，未驗證）"),
            "time_fixed": .integer("固定思考時間秒數（預設 300）"),
            "time_add": .integer("每巡加時秒數（預設 0）"),
            "ai_level": .integer("AI 等級 GameDetailRule.ai_level（不填則不送此欄位）"),
            "dora_count": .integer("赤寶牌數量（預設 3）"),
            "shiduan": .integer("是否允許食斷：1=允許（預設 1）"),
            "init_point": .integer("起始點數（預設 25000）"),
            "fandian": .integer("返點／原點（預設 30000）"),
            "public_live": .boolean("是否公開觀戰（預設 false）"),
            "enable_ai": .boolean("GameMode.ai：是否允許 AI 代打（預設 false）"),
            "client_version_string": .string("客戶端版本字串（可選）"),
            "awaitResponseMs": .integer("等待伺服器回應的毫秒數（預設 2000）")
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

        let playerCount = arguments["player_count"] as? Int ?? 4
        guard playerCount == 3 || playerCount == 4 else {
            throw MCPToolError.invalidParameter("player_count", expected: "3 或 4")
        }

        var config = LiqiFriendRoomConfig()
        config.playerCount = UInt32(playerCount)
        config.mode = UInt32(max(0, arguments["mode"] as? Int ?? 2))
        config.timeFixed = UInt32(max(0, arguments["time_fixed"] as? Int ?? 300))
        config.timeAdd = UInt32(max(0, arguments["time_add"] as? Int ?? 0))
        config.doraCount = UInt32(max(0, arguments["dora_count"] as? Int ?? 3))
        config.shiduan = UInt32(max(0, arguments["shiduan"] as? Int ?? 1))
        config.initPoint = UInt32(max(0, arguments["init_point"] as? Int ?? 25000))
        config.fandian = UInt32(max(0, arguments["fandian"] as? Int ?? 30000))
        config.publicLive = arguments["public_live"] as? Bool ?? false
        config.enableAI = arguments["enable_ai"] as? Bool ?? false
        config.clientVersionString = arguments["client_version_string"] as? String ?? ""
        if let aiLevel = arguments["ai_level"] as? Int, aiLevel >= 0 {
            config.aiLevel = UInt32(aiLevel)
        }

        let spec = LiqiRequestBuilder.createRoom(config: config)
        let outcome = await nakiContext.sendLiqi(spec,
                                                 awaitResponseMs: arguments["awaitResponseMs"] as? Int ?? 2000)
        context.log("🏠 room_create player_count=\(playerCount) time=\(config.timeFixed)+\(config.timeAdd)")

        var result = LiqiToolResult.dictionary(outcome, spec: spec, extra: [
            "config": [
                "player_count": playerCount,
                "mode": Int(config.mode),
                "time_fixed": Int(config.timeFixed),
                "time_add": Int(config.timeAdd),
                "dora_count": Int(config.doraCount),
                "shiduan": Int(config.shiduan),
                "init_point": Int(config.initPoint),
                "fandian": Int(config.fandian),
                "ai_level": config.aiLevel.map { Int($0) } ?? NSNull(),
                "public_live": config.publicLive,
                "enable_ai": config.enableAI
            ] as [String: Any]
        ])
        result["nextSteps"] = ["room_info", "room_add_robot", "room_start"]
        return result
    }
}

// MARK: - Room Add Robot Tool

/// 加入人機
struct RoomAddRobotTool: MCPTool {
    static let name = "room_add_robot"
    static let description = """
        在友人房中加入一個人機。送出 .lq.Lobby.addRoomRobot（ReqAddRoomRobot：position=1）。\
        四麻要湊滿需呼叫 3 次。\
        ⚠️ position 的編號規則（0-based / 1-based、是否可指定座位）未經真實封包驗證；\
        position=0 依 proto3 會被省略，等同「不指定」。
        """
    static let inputSchema = MCPInputSchema(
        properties: [
            "position": .integer("座位編號（預設 0 = 不指定，由伺服器決定）"),
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
        let position = UInt32(max(0, arguments["position"] as? Int ?? 0))
        let spec = LiqiRequestBuilder.addRoomRobot(position: position)
        let outcome = await nakiContext.sendLiqi(spec,
                                                 awaitResponseMs: arguments["awaitResponseMs"] as? Int ?? 1500)
        context.log("🤖 room_add_robot position=\(position)")
        return LiqiToolResult.dictionary(outcome, spec: spec, extra: ["position": Int(position)])
    }
}

// MARK: - Room Start Tool

/// 開始對局
struct RoomStartTool: MCPTool {
    static let name = "room_start"
    static let description = """
        開始友人房對局。送出 .lq.Lobby.startRoom（ReqRoomStart，空 payload）。\
        ⚠️ 這會真的開一局；請只在測試帳號使用。
        """
    static let inputSchema = MCPInputSchema(
        properties: [
            "awaitResponseMs": .integer("等待伺服器回應的毫秒數（預設 2000）")
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
        let spec = LiqiRequestBuilder.startRoom()
        let outcome = await nakiContext.sendLiqi(spec,
                                                 awaitResponseMs: arguments["awaitResponseMs"] as? Int ?? 2000)
        context.log("▶️ room_start")
        return LiqiToolResult.dictionary(outcome, spec: spec)
    }
}

// MARK: - Room Info Tool

/// 查詢目前房間
struct RoomInfoTool: MCPTool {
    static let name = "room_info"
    static let description = """
        查詢目前所在的友人房。送出 .lq.Lobby.fetchRoom（ReqCommon，空 payload），\
        伺服器回 ResSelfRoom { error=1, room=2 }。\
        ⚠️ 回應以 protobuf 欄位編號呈現；巢狀的 Room 會是 base64，\
        欄位語意請查 liqi.json 的 Room（room_id=1, owner_id=2, persons=5, robot_count=9…）。
        """
    static let inputSchema = MCPInputSchema(
        properties: [
            "awaitResponseMs": .integer("等待伺服器回應的毫秒數（預設 2000）")
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
        let spec = LiqiRequestBuilder.fetchRoom()
        let outcome = await nakiContext.sendLiqi(spec,
                                                 awaitResponseMs: arguments["awaitResponseMs"] as? Int ?? 2000)
        return LiqiToolResult.dictionary(outcome, spec: spec)
    }
}

// MARK: - Room Join Tool

/// 加入他人的友人房
struct RoomJoinTool: MCPTool {
    static let name = "room_join"
    static let description = "加入指定房號的友人房。送出 .lq.Lobby.joinRoom（ReqJoinRoom：room_id=1, client_version_string=2）"
    static let inputSchema = MCPInputSchema(
        properties: [
            "room_id": .integer("房號"),
            "client_version_string": .string("客戶端版本字串（可選）"),
            "awaitResponseMs": .integer("等待伺服器回應的毫秒數（預設 2000）")
        ],
        required: ["room_id"]
    )

    private let context: MCPContext

    init(context: MCPContext) {
        self.context = context
    }

    func execute(arguments: [String: Any]) async throws -> Any {
        guard let roomId = arguments["room_id"] as? Int, roomId > 0 else {
            throw MCPToolError.missingParameter("room_id")
        }
        guard let nakiContext = context as? NakiMCPContext else {
            throw MCPToolError.notAvailable("Naki context")
        }
        let spec = LiqiRequestBuilder.joinRoom(
            roomId: UInt32(roomId),
            clientVersionString: arguments["client_version_string"] as? String ?? "")
        let outcome = await nakiContext.sendLiqi(spec,
                                                 awaitResponseMs: arguments["awaitResponseMs"] as? Int ?? 2000)
        context.log("🚪 room_join room_id=\(roomId)")
        return LiqiToolResult.dictionary(outcome, spec: spec, extra: ["room_id": roomId])
    }
}

// MARK: - Room Leave Tool

/// 離開房間
struct RoomLeaveTool: MCPTool {
    static let name = "room_leave"
    static let description = "離開目前的友人房。送出 .lq.Lobby.leaveRoom（ReqCommon，空 payload）"
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
        let spec = LiqiRequestBuilder.leaveRoom()
        let outcome = await nakiContext.sendLiqi(spec,
                                                 awaitResponseMs: arguments["awaitResponseMs"] as? Int ?? 1500)
        context.log("🚪 room_leave")
        return LiqiToolResult.dictionary(outcome, spec: spec)
    }
}

// MARK: - Room Quick Test Tool

/// 一鍵開測試局：建房 → 補滿人機 → 開局
///
/// 每次測自動打牌都要手動跑 `room_create` → `room_add_robot` ×3 → `room_start`，
/// 中間任一步失敗還得自己看 error code；這個工具把整串包起來並逐步回報。
///
/// ⚠️ 開局後 Unity 客戶端**不會自動進入對局**（房是走協定層建的，客戶端 UI 不知情）。
/// 需要呼叫端接著觸發一次 WebSocket 重連，客戶端才會以「斷線重連」路徑進入該局。
struct RoomQuickTestTool: MCPTool {
    static let name = "room_quick_test"
    static let description = """
        一鍵開測試局：createRoom → addRoomRobot 補滿 → startRoom，逐步回報結果。\
        用於快速驗證自動打牌。\
        ⚠️ 這會真的開一局；請只在測試帳號使用。\
        開局後客戶端需重連才會進入對局（reconnect_hint 會提示）。
        """
    static let inputSchema = MCPInputSchema(
        properties: [
            "player_count": .integer("人數：4=四麻、3=三麻（預設 4）"),
            "time_fixed": .integer("固定思考時間秒數（預設 60，測試用短一點）"),
            "time_add": .integer("每巡加時秒數（預設 0）"),
            "ai_level": .integer("AI 等級（不填則不送此欄位）")
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

        let playerCount = arguments["player_count"] as? Int ?? 4
        guard playerCount == 3 || playerCount == 4 else {
            throw MCPToolError.invalidParameter("player_count", expected: "3 或 4")
        }

        var steps: [[String: Any]] = []

        func record(_ name: String, _ outcome: LiqiToolSendOutcome, spec: LiqiRequestSpec) -> Bool {
            let dict = LiqiToolResult.dictionary(outcome, spec: spec)
            let accepted = (dict["serverAccepted"] as? Bool) ?? false
            steps.append([
                "step": name,
                "serverAccepted": accepted,
                "detail": dict["detail"] ?? NSNull(),
                "response": dict["response"] ?? NSNull()
            ])
            return accepted
        }

        // 1. 建房
        var config = LiqiFriendRoomConfig()
        config.playerCount = UInt32(playerCount)
        config.timeFixed = UInt32(max(0, arguments["time_fixed"] as? Int ?? 60))
        config.timeAdd = UInt32(max(0, arguments["time_add"] as? Int ?? 0))
        if let aiLevel = arguments["ai_level"] as? Int, aiLevel >= 0 {
            config.aiLevel = UInt32(aiLevel)
        }
        let createSpec = LiqiRequestBuilder.createRoom(config: config)
        let created = record("room_create",
                             await nakiContext.sendLiqi(createSpec, awaitResponseMs: 4000),
                             spec: createSpec)
        guard created else {
            context.log("🧪 room_quick_test 中止：建房失敗")
            return ["success": false, "failedAt": "room_create", "steps": steps]
        }

        // 2. 補滿人機（座位 1..playerCount-1）
        for position in 1..<playerCount {
            let robotSpec = LiqiRequestBuilder.addRoomRobot(position: UInt32(position))
            let ok = record("room_add_robot[\(position)]",
                            await nakiContext.sendLiqi(robotSpec, awaitResponseMs: 3000),
                            spec: robotSpec)
            guard ok else {
                context.log("🧪 room_quick_test 中止：加人機 position=\(position) 失敗")
                return ["success": false, "failedAt": "room_add_robot[\(position)]", "steps": steps]
            }
        }

        // 3. 開局
        let startSpec = LiqiRequestBuilder.startRoom()
        let started = record("room_start",
                             await nakiContext.sendLiqi(startSpec, awaitResponseMs: 4000),
                             spec: startSpec)
        guard started else {
            context.log("🧪 room_quick_test 中止：開局失敗")
            return ["success": false, "failedAt": "room_start", "steps": steps]
        }

        context.log("🧪 room_quick_test 完成：\(playerCount) 人房已開局")
        return [
            "success": true,
            "playerCount": playerCount,
            "steps": steps,
            "reconnect_hint": "客戶端尚未進入對局。請執行 execute_js: "
                + "return window.__nakiWebSocket.forceReconnect() "
                + "讓客戶端以斷線重連路徑進入該局，之後 bot_status 才會有手牌與推薦。"
        ]
    }
}
