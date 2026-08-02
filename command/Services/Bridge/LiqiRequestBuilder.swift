//
//  LiqiRequestBuilder.swift
//  Naki
//
//  把語意動作（打牌／碰／建房／心跳…）組成 Liqi payload 欄位。
//
//  p4-2 之前這一層與送出器、牌碼轉換、MCP 呈現層擠在同一個 `LiqiActionSender.swift`
//  裡（880 行、四種職責）。本檔是其中的**純資料**部分：無狀態、無 I/O、無 log，
//  輸出可以在單元測試裡做位元組層級對拍。
//
//      LiqiRequestBuilder（本檔，組 payload 欄位）
//          → LiqiEncoder.encodeRequest（配 msgId、組 envelope，見 LiqiEnvelope）
//          → base64
//          → window.__nakiWebSocket.sendRaw(base64)
//
//  ⚠️ 驗收語彙：
//  - **已驗證（位元組層）**：欄位編號與型別取自 docs/protocol/liqi.json；
//    envelope 格式與 sendRaw 通道有實測封包佐證（見 docs/majsoul-unity-protocol.md）。
//  - **runtime 已驗 subset**：discard、pon、riichi、tsumo request、ron；ron 已確認走
//    inputOperation，pon 走 inputChiPengGang。chi variants、赤五 combination、三種槓、
//    timeuse 細節仍需真實對局驗證，不能把 subset 外推到全部動作。
//
//  proto3 慣例：預設值（0 / false / 空字串）省略不編碼，與 protobufjs 客戶端一致，
//  這樣送出的位元組才會與遊戲自己送的形狀相同。
//

import Foundation

// MARK: - 請求描述

/// 待送出的請求（method + payload 欄位）。
///
/// 刻意與「送出」分離：payload 是純資料，可在單元測試中做位元組層級對拍。
struct LiqiRequestSpec {
    let method: String
    let fields: [LiqiField]

    /// 已編碼的 payload bytes（不含 envelope）
    var payload: [UInt8] { LiqiEncoder.encodeFields(fields) }

    /// 指定 msgId 的完整 REQUEST envelope（測試用；正式送出走自動配號）
    func encoded(msgId: UInt16) -> [UInt8] {
        LiqiEncoder.encodeRequest(method: method, fields: fields, msgId: msgId)
    }
}

// MARK: - 建房設定

/// 好友房設定（`ReqCreateRoom` / `GameMode` / `GameDetailRule`）
///
/// 欄位編號取自 liqi.json；mode 1=東風、2=半莊已由 current config + runtime cross-check。
struct LiqiFriendRoomConfig {
    /// 人數（4 = 四麻、3 = 三麻）
    var playerCount: UInt32 = 4
    /// GameMode.mode（1 = 東風戰、2 = 半莊戰）
    var mode: UInt32 = 1
    /// GameMode.ai：是否允許 AI 代打
    var enableAI: Bool = false
    /// 是否公開觀戰
    var publicLive: Bool = false
    /// 客戶端版本字串（空字串則不送；真實客戶端會帶版本）
    var clientVersionString: String = ""
    /// pre_rule（一般為空）
    var preRule: String = ""

    // GameDetailRule
    /// 固定思考時間（秒）
    var timeFixed: UInt32 = 60
    /// 加時（秒）
    var timeAdd: UInt32 = 5
    /// 赤寶牌數量
    var doraCount: UInt32 = 3
    /// 是否允許食斷（1 = 允許）
    var shiduan: UInt32 = 1
    /// 起始點數
    var initPoint: UInt32 = 25000
    /// 返點（原點）
    var fandian: UInt32 = 30000
    /// AI 等級（nil 表示不送此欄位）
    var aiLevel: UInt32?
    /// 其他 GameDetailRule 欄位的逃生口（欄位編號查 liqi.json）
    var extraDetailRuleFields: [LiqiField] = []

    init() {}
}

// MARK: - Request Builder

/// 把語意動作組成 Liqi payload 欄位（純函式，無狀態，可單元測試）
enum LiqiRequestBuilder {

    // MARK: 方法全名（格式實測自 `.lq.Route.heartbeat`）

    /// `.lq.FastTest.inputOperation`
    static let inputOperationMethod = LiqiActionChannel.selfOperation.method
    /// `.lq.FastTest.inputChiPengGang`
    static let inputChiPengGangMethod = LiqiActionChannel.chiPengGang.method
    /// `.lq.Lobby.createRoom`
    static let createRoomMethod = ".lq.Lobby.createRoom"
    /// `.lq.Lobby.addRoomRobot`
    static let addRoomRobotMethod = ".lq.Lobby.addRoomRobot"
    /// `.lq.Lobby.startRoom`
    static let startRoomMethod = ".lq.Lobby.startRoom"
    /// `.lq.Lobby.joinRoom`
    static let joinRoomMethod = ".lq.Lobby.joinRoom"
    /// `.lq.Lobby.leaveRoom`
    static let leaveRoomMethod = ".lq.Lobby.leaveRoom"
    /// `.lq.Lobby.fetchRoom`
    static let fetchRoomMethod = ".lq.Lobby.fetchRoom"
    /// `.lq.Lobby.matchGame`
    static let matchGameMethod = ".lq.Lobby.matchGame"
    /// `.lq.Lobby.cancelMatch`
    static let cancelMatchMethod = ".lq.Lobby.cancelMatch"
    /// `.lq.Lobby.fetchAccountInfo`
    static let fetchAccountInfoMethod = ".lq.Lobby.fetchAccountInfo"
    /// `.lq.Lobby.fetchGamingInfo`
    static let fetchGamingInfoMethod = ".lq.Lobby.fetchGamingInfo"
    /// `.lq.Lobby.fetchServerTime`
    static let fetchServerTimeMethod = ".lq.Lobby.fetchServerTime"
    /// `.lq.Lobby.heatbeat`（拼字取自 liqi.json，不是 typo）
    static let heatbeatMethod = ".lq.Lobby.heatbeat"
    /// `.lq.Lobby.loginBeat`
    static let loginBeatMethod = ".lq.Lobby.loginBeat"
    /// `.lq.FastTest.broadcastInGame`
    static let broadcastInGameMethod = ".lq.FastTest.broadcastInGame"
    /// `.lq.FastTest.confirmNewRound`（局間結算 → 確認進下一局；payload 為 `ReqCommon`，零欄位）
    static let confirmNewRoundMethod = ".lq.FastTest.confirmNewRound"
    /// `.lq.FastTest.clearLeaving`（重連後清除「離開中」狀態；payload 為 `ReqCommon`，零欄位）
    static let clearLeavingMethod = ".lq.FastTest.clearLeaving"
    /// `.lq.FastTest.voteGameEnd`（投票提前結束對局；payload 為 `ReqVoteGameEnd`，非 `ReqCommon`）
    static let voteGameEndMethod = ".lq.FastTest.voteGameEnd"

    // MARK: - ② 動作層

    /// `ReqSelfOperation`
    /// （type=1, index=2, tile=3, cancel_operation=4, moqie=5, timeuse=6）
    static func selfOperation(type: UInt32,
                              index: UInt32? = nil,
                              tile: String? = nil,
                              cancelOperation: Bool = false,
                              moqie: Bool = false,
                              timeuse: UInt32 = 0) -> LiqiRequestSpec {
        var fields: [LiqiField] = []
        if type != 0 { fields.append(.varint(field: 1, value: UInt64(type))) }
        if let index, index != 0 { fields.append(.varint(field: 2, value: UInt64(index))) }
        if let tile, !tile.isEmpty { fields.append(.string(field: 3, value: tile)) }
        if cancelOperation { fields.append(.bool(field: 4, value: true)) }
        if moqie { fields.append(.bool(field: 5, value: true)) }
        if timeuse != 0 { fields.append(.varint(field: 6, value: UInt64(timeuse))) }
        return LiqiRequestSpec(method: inputOperationMethod, fields: fields)
    }

    /// `ReqChiPengGang`（type=1, index=2, cancel_operation=3, timeuse=6）
    static func chiPengGang(type: UInt32,
                            index: UInt32? = nil,
                            cancelOperation: Bool = false,
                            timeuse: UInt32 = 0) -> LiqiRequestSpec {
        var fields: [LiqiField] = []
        if type != 0 { fields.append(.varint(field: 1, value: UInt64(type))) }
        if let index, index != 0 { fields.append(.varint(field: 2, value: UInt64(index))) }
        if cancelOperation { fields.append(.bool(field: 3, value: true)) }
        if timeuse != 0 { fields.append(.varint(field: 6, value: UInt64(timeuse))) }
        return LiqiRequestSpec(method: inputChiPengGangMethod, fields: fields)
    }

    /// 打牌（type=1）
    /// - Parameters:
    ///   - tile: **雀魂格式**牌字串（`5m` / `0m` 紅五 / `1z` 東），MJAI 請先過 `LiqiTile`
    ///   - moqie: 是否摸切
    static func discard(tile: String, moqie: Bool, timeuse: UInt32 = 0) -> LiqiRequestSpec {
        selfOperation(type: LiqiOperationType.discard.rawValue,
                      tile: tile, moqie: moqie, timeuse: timeuse)
    }

    /// 立直（type=7）：protobuf 要求同時指定要打出的牌
    static func riichi(tile: String, moqie: Bool = false, timeuse: UInt32 = 0) -> LiqiRequestSpec {
        selfOperation(type: LiqiOperationType.riichi.rawValue,
                      tile: tile, moqie: moqie, timeuse: timeuse)
    }

    /// 自摸和（type=8）
    static func tsumo(timeuse: UInt32 = 0) -> LiqiRequestSpec {
        selfOperation(type: LiqiOperationType.tsumo.rawValue, timeuse: timeuse)
    }

    /// 榮和（type=9）
    ///
    /// 2026-08-01 runtime 已驗：榮和走 `inputOperation`，server RESPONSE 後收到 ActionHule。
    static func ron(index: UInt32? = nil, timeuse: UInt32 = 0) -> LiqiRequestSpec {
        let type = LiqiOperationType.ron
        switch type.channel {
        case .selfOperation:
            return selfOperation(type: type.rawValue, index: index, timeuse: timeuse)
        case .chiPengGang:
            return chiPengGang(type: type.rawValue, index: index, timeuse: timeuse)
        }
    }

    /// 九種九牌（type=10）
    static func kyushu(timeuse: UInt32 = 0) -> LiqiRequestSpec {
        selfOperation(type: LiqiOperationType.kyushu.rawValue, timeuse: timeuse)
    }

    /// 拔北（type=11，三麻）
    static func babei(timeuse: UInt32 = 0) -> LiqiRequestSpec {
        selfOperation(type: LiqiOperationType.babei.rawValue, timeuse: timeuse)
    }

    /// 吃（type=2）：`index` 為 `OptionalOperation.combination` 的索引
    static func chi(index: UInt32, timeuse: UInt32 = 0) -> LiqiRequestSpec {
        chiPengGang(type: LiqiOperationType.chi.rawValue, index: index, timeuse: timeuse)
    }

    /// 碰（type=3）
    static func pon(index: UInt32 = 0, timeuse: UInt32 = 0) -> LiqiRequestSpec {
        chiPengGang(type: LiqiOperationType.pon.rawValue, index: index, timeuse: timeuse)
    }

    /// 槓：依 type 決定送 `inputChiPengGang`（大明槓）或 `inputOperation`（暗槓 / 加槓）
    static func kan(type: LiqiOperationType,
                    index: UInt32 = 0,
                    tile: String? = nil,
                    timeuse: UInt32 = 0) -> LiqiRequestSpec {
        switch type.channel {
        case .chiPengGang:
            return chiPengGang(type: type.rawValue, index: index, timeuse: timeuse)
        case .selfOperation:
            return selfOperation(type: type.rawValue, index: index, tile: tile, timeuse: timeuse)
        }
    }

    /// 跳過（cancel_operation = true）
    /// - Parameter channel: 由當前 oplist 判斷；回應他家打牌走 `inputChiPengGang`
    static func cancel(channel: LiqiActionChannel, timeuse: UInt32 = 0) -> LiqiRequestSpec {
        switch channel {
        case .chiPengGang:
            return chiPengGang(type: 0, cancelOperation: true, timeuse: timeuse)
        case .selfOperation:
            return selfOperation(type: 0, cancelOperation: true, timeuse: timeuse)
        }
    }

    // MARK: - ③ 大廳層

    /// 建立好友房（`ReqCreateRoom`）
    static func createRoom(config: LiqiFriendRoomConfig) -> LiqiRequestSpec {
        var detailRule: [LiqiField] = []
        if config.timeFixed != 0 { detailRule.append(.varint(field: 1, value: UInt64(config.timeFixed))) }
        if config.timeAdd != 0 { detailRule.append(.varint(field: 2, value: UInt64(config.timeAdd))) }
        if config.doraCount != 0 { detailRule.append(.varint(field: 3, value: UInt64(config.doraCount))) }
        if config.shiduan != 0 { detailRule.append(.varint(field: 4, value: UInt64(config.shiduan))) }
        if config.initPoint != 0 { detailRule.append(.varint(field: 5, value: UInt64(config.initPoint))) }
        if config.fandian != 0 { detailRule.append(.varint(field: 6, value: UInt64(config.fandian))) }
        if let aiLevel = config.aiLevel { detailRule.append(.varint(field: 38, value: UInt64(aiLevel))) }
        detailRule += config.extraDetailRuleFields

        var mode: [LiqiField] = []
        if config.mode != 0 { mode.append(.varint(field: 1, value: UInt64(config.mode))) }
        if config.enableAI { mode.append(.bool(field: 4, value: true)) }
        if !detailRule.isEmpty { mode.append(.message(field: 6, fields: detailRule)) }

        var fields: [LiqiField] = []
        if config.playerCount != 0 {
            fields.append(.varint(field: 1, value: UInt64(config.playerCount)))
        }
        if !mode.isEmpty { fields.append(.message(field: 2, fields: mode)) }
        if config.publicLive { fields.append(.bool(field: 3, value: true)) }
        if !config.clientVersionString.isEmpty {
            fields.append(.string(field: 4, value: config.clientVersionString))
        }
        if !config.preRule.isEmpty { fields.append(.string(field: 5, value: config.preRule)) }

        return LiqiRequestSpec(method: createRoomMethod, fields: fields)
    }

    /// 加入機器人（`ReqAddRoomRobot`，position=1）
    static func addRoomRobot(position: UInt32) -> LiqiRequestSpec {
        var fields: [LiqiField] = []
        if position != 0 { fields.append(.varint(field: 1, value: UInt64(position))) }
        return LiqiRequestSpec(method: addRoomRobotMethod, fields: fields)
    }

    /// 開始對局（`ReqRoomStart`，空 payload）
    static func startRoom() -> LiqiRequestSpec {
        LiqiRequestSpec(method: startRoomMethod, fields: [])
    }

    /// 加入房間（`ReqJoinRoom`，room_id=1, client_version_string=2）
    static func joinRoom(roomId: UInt32, clientVersionString: String = "") -> LiqiRequestSpec {
        var fields: [LiqiField] = []
        if roomId != 0 { fields.append(.varint(field: 1, value: UInt64(roomId))) }
        if !clientVersionString.isEmpty {
            fields.append(.string(field: 2, value: clientVersionString))
        }
        return LiqiRequestSpec(method: joinRoomMethod, fields: fields)
    }

    /// 離開房間（`ReqCommon`，空 payload）
    static func leaveRoom() -> LiqiRequestSpec {
        LiqiRequestSpec(method: leaveRoomMethod, fields: [])
    }

    /// 查詢目前房間（`ReqCommon`，空 payload）
    static func fetchRoom() -> LiqiRequestSpec {
        LiqiRequestSpec(method: fetchRoomMethod, fields: [])
    }

    // MARK: - ③ 大廳層：匹配 / 帳號 / 保活
    //
    // 以下欄位編號全部取自 docs/protocol/liqi.json（已逐一查核），
    // server 是否接受仍須看每筆 RESPONSE；match mode 則由 current config 提供。

    /// 段位場排隊（`ReqJoinMatchQueue`：match_mode=1, client_version_string=2）
    static func matchGame(matchMode: UInt32, clientVersionString: String = "") -> LiqiRequestSpec {
        var fields: [LiqiField] = []
        if matchMode != 0 { fields.append(.varint(field: 1, value: UInt64(matchMode))) }
        if !clientVersionString.isEmpty {
            fields.append(.string(field: 2, value: clientVersionString))
        }
        return LiqiRequestSpec(method: matchGameMethod, fields: fields)
    }

    /// 取消排隊（`ReqCancelMatchQueue`：match_mode=1）
    ///
    /// ⚠️ `match_mode` 是必要參數：伺服器要知道取消哪一條隊列。
    static func cancelMatch(matchMode: UInt32) -> LiqiRequestSpec {
        var fields: [LiqiField] = []
        if matchMode != 0 { fields.append(.varint(field: 1, value: UInt64(matchMode))) }
        return LiqiRequestSpec(method: cancelMatchMethod, fields: fields)
    }

    /// 查詢帳號資訊（`ReqAccountInfo`：account_id=1）
    ///
    /// ⚠️ `account_id` 必填。proto3 會省略 0，送出空 payload 時伺服器不會回應，
    /// 所以呼叫端務必帶入真實 account_id（可由登入回應解析得到）。
    static func fetchAccountInfo(accountId: UInt32) -> LiqiRequestSpec {
        var fields: [LiqiField] = []
        if accountId != 0 { fields.append(.varint(field: 1, value: UInt64(accountId))) }
        return LiqiRequestSpec(method: fetchAccountInfoMethod, fields: fields)
    }

    /// 查詢目前對局／房間狀態（`ReqCommon`，空 payload）
    static func fetchGamingInfo() -> LiqiRequestSpec {
        LiqiRequestSpec(method: fetchGamingInfoMethod, fields: [])
    }

    /// 查詢伺服器時間（`ReqCommon`，空 payload）——最無害的連線探針
    static func fetchServerTime() -> LiqiRequestSpec {
        LiqiRequestSpec(method: fetchServerTimeMethod, fields: [])
    }

    /// 大廳心跳（`ReqHeatBeat`：no_operation_counter=1）
    ///
    /// 取代 Unity 下已失效的 `GameMgr.Inst.clientHeatBeat()`。
    /// `noOperationCounter` 為 0 時依 proto3 省略，payload 會是空的。
    static func heatbeat(noOperationCounter: UInt32 = 0) -> LiqiRequestSpec {
        var fields: [LiqiField] = []
        if noOperationCounter != 0 {
            fields.append(.varint(field: 1, value: UInt64(noOperationCounter)))
        }
        return LiqiRequestSpec(method: heatbeatMethod, fields: fields)
    }

    /// 登入保活（`ReqLoginBeat`：contract=1）
    static func loginBeat(contract: String) -> LiqiRequestSpec {
        var fields: [LiqiField] = []
        if !contract.isEmpty { fields.append(.string(field: 1, value: contract)) }
        return LiqiRequestSpec(method: loginBeatMethod, fields: fields)
    }

    // MARK: - ④ 對局流程：局間確認 / 清除離開 / 投票結束
    //
    // 三個方法都走 FastTest（前綴 `.lq.FastTest.`），所以 `sendRaw` 的 gateway 選線
    // 會自動把它們送到 game-gateway（naki-websocket.js 以 `.lq.FastTest.` 前綴判 isGameMethod）。
    // 方法名與 request 型別逐一查核自 docs/protocol/liqi.json 的 `.lq.FastTest`：
    // confirmNewRound → ReqCommon、clearLeaving → ReqCommon、voteGameEnd → ReqVoteGameEnd。

    /// 局間結算 → 確認進下一局（`ReqCommon`，空 payload）。
    ///
    /// 局結束（`ActionHule` / `ActionNoTile` / `ActionLiuJu`）後伺服器停在結算窗口等這個確認；
    /// 送出被接受後，下一局的權威 action 是 `ActionNewRound`。空 payload 的 envelope 仍會輸出
    /// `12 00`（與 `heatbeat` / `startRoom` 等 `ReqCommon` 一致）。
    static func confirmNewRound() -> LiqiRequestSpec {
        LiqiRequestSpec(method: confirmNewRoundMethod, fields: [])
    }

    /// 清除「離開中」狀態（`ReqCommon`，空 payload）。
    ///
    /// 重連（syncGame）後若伺服器把本家標記為 leaving，需送這個把狀態清掉。
    /// 目前只提供 builder，未接進任何自動路徑。
    static func clearLeaving() -> LiqiRequestSpec {
        LiqiRequestSpec(method: clearLeavingMethod, fields: [])
    }

    /// 投票提前結束對局（`ReqVoteGameEnd`：yes=1）。
    ///
    /// ⚠️ **破壞性**：這會發起「中途結束對局」的投票，不是唯讀查詢。
    /// 只提供 builder 與 MCP 工具，**不接進任何自動路徑**。
    ///
    /// 注意：liqi.json 的 `voteGameEnd` 用 `ReqVoteGameEnd { bool yes = 1 }`，
    /// **不是** p2-5 task 表寫的 `ReqCommon`——以協定為準。proto3 會省略 false，
    /// 所以 `yes=false` 的 payload 是空的。
    /// - Parameter yes: 是否投贊成票
    static func voteGameEnd(yes: Bool = true) -> LiqiRequestSpec {
        var fields: [LiqiField] = []
        if yes { fields.append(.bool(field: 1, value: true)) }
        return LiqiRequestSpec(method: voteGameEndMethod, fields: fields)
    }

    // MARK: - ⑤ 對局內廣播（表情）

    /// 對局內廣播（`ReqBroadcastInGame`：content=1, except_self=2）
    static func broadcastInGame(content: String, exceptSelf: Bool = false) -> LiqiRequestSpec {
        var fields: [LiqiField] = []
        if !content.isEmpty { fields.append(.string(field: 1, value: content)) }
        if exceptSelf { fields.append(.bool(field: 2, value: true)) }
        return LiqiRequestSpec(method: broadcastInGameMethod, fields: fields)
    }

    /// 表情廣播：content 固定為 `{"emo":N}`（與舊 NetAgent 路徑送出的內容相同）
    static func emoji(emoId: Int, exceptSelf: Bool = false) -> LiqiRequestSpec {
        broadcastInGame(content: "{\"emo\":\(emoId)}", exceptSelf: exceptSelf)
    }
}
