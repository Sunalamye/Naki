//
//  LiqiActionSender.swift
//  Naki
//
//  Unity 時代的動作層（②）與大廳層（③）：把動作組成 Liqi REQUEST 送出。
//
//  舊路徑（`window.naki.action.*` → Laya 物件）在 Unity WebGL 客戶端已完全失效，
//  本檔改走協定層：
//
//      LiqiRequestBuilder（純函式，組 payload 欄位）
//          → LiqiEncoder.encodeRequest（配 msgId、組 envelope）
//          → base64
//          → window.__nakiWebSocket.sendRaw(base64)   // 已實測可送出
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

// MARK: - 送出結果

/// JS 端 `sendRaw` 的回報
struct LiqiRawSendResult {
    let success: Bool
    /// 成功時為 `socket=… bytes=…`；失敗時為 JS 回報的 reason 或本地錯誤
    let detail: String?

    static func failure(_ reason: String) -> LiqiRawSendResult {
        LiqiRawSendResult(success: false, detail: reason)
    }
}

/// 一次送出的完整結果（含 msgId，方便對照伺服器 RESPONSE）
struct LiqiSendResult {
    let method: String
    let msgId: UInt16
    let byteCount: Int
    let success: Bool
    let detail: String?

    var logLine: String {
        let state = success ? "✅" : "❌"
        return "\(state) \(method) msgId=\(msgId) bytes=\(byteCount)\(detail.map { " (\($0))" } ?? "")"
    }
}

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

// MARK: - 牌字串轉換

/// MJAI ⇄ 雀魂牌字串轉換。
///
/// 雀魂：`0m` = 紅五萬、`1z`…`7z` = 東南西北白發中（與 `MajsoulBridge.MS_TILE_TO_MJAI` 對稱）。
/// MJAI：`5mr` = 紅五萬、`E/S/W/N/P/F/C` = 字牌。
enum LiqiTileCode {

    /// 字牌對照（雀魂 → MJAI）
    private static let honorToMJAI: [String: String] = [
        "1z": "E", "2z": "S", "3z": "W", "4z": "N",
        "5z": "P", "6z": "F", "7z": "C"
    ]

    /// 字牌對照（MJAI → 雀魂）
    private static let honorToMajsoul: [String: String] = [
        "E": "1z", "S": "2z", "W": "3z", "N": "4z",
        "P": "5z", "F": "6z", "C": "7z"
    ]

    /// MJAI → 雀魂（`5mr` → `0m`、`E` → `1z`）；無法辨識回 nil
    static func majsoul(fromMJAI mjai: String) -> String? {
        if let honor = honorToMajsoul[mjai] { return honor }

        let chars = Array(mjai)
        guard chars.count == 2 || chars.count == 3 else { return nil }
        guard let number = Int(String(chars[0])), (1...9).contains(number) else { return nil }
        let suit = chars[1]
        guard suit == "m" || suit == "p" || suit == "s" else { return nil }

        if chars.count == 3 {
            // 紅五：MJAI `5mr` → 雀魂 `0m`
            guard chars[2] == "r", number == 5 else { return nil }
            return "0\(suit)"
        }
        return "\(number)\(suit)"
    }

    /// 雀魂 → MJAI（`0m` → `5mr`、`1z` → `E`）；無法辨識回 nil
    static func mjai(fromMajsoul tile: String) -> String? {
        if let honor = honorToMJAI[tile] { return honor }

        let chars = Array(tile)
        guard chars.count == 2, let number = Int(String(chars[0])) else { return nil }
        let suit = chars[1]
        guard suit == "m" || suit == "p" || suit == "s" else { return nil }
        return number == 0 ? "5\(suit)r" : "\(number)\(suit)"
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
    ///   - tile: **雀魂格式**牌字串（`5m` / `0m` 紅五 / `1z` 東），MJAI 請先過 `LiqiTileCode`
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

    // MARK: - ④ 對局內廣播（表情）

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

// MARK: - 工具層送出結果

/// 「送出 + （可選）等待回應」的完整結果，供 MCP 工具轉成 JSON。
///
/// 三種狀態要分清楚：
/// - `unavailableReason != nil`：連送都沒送（沒有 WebViewModel / 沒有送出通道）
/// - `sent?.success == false`：送出被 JS 端拒絕（沒有 OPEN 的雀魂連線等）
/// - `sent?.success == true && response == nil`：**送出去了，但沒等到回應**
///   （可能是伺服器沒回、也可能是等待時間不夠；不可當成失敗，也不可當成成功）
struct LiqiToolSendOutcome {
    let sent: LiqiSendResult?
    let response: LiqiResponseRecord?
    let unavailableReason: String?

    init(sent: LiqiSendResult? = nil,
         response: LiqiResponseRecord? = nil,
         unavailableReason: String? = nil) {
        self.sent = sent
        self.response = response
        self.unavailableReason = unavailableReason
    }

    /// 沒有送出通道時的結果
    static func unavailable(_ reason: String) -> LiqiToolSendOutcome {
        LiqiToolSendOutcome(unavailableReason: reason)
    }
}

/// 把送出結果轉成 MCP 工具的回傳字典（純函式，可單元測試）
enum LiqiToolResult {

    /// - Parameters:
    ///   - outcome: 送出結果
    ///   - spec: 送出的請求（用來附上 method 與 payload hex，方便對拍）
    ///   - extra: 額外欄位（例如工具自己的參數回顯）
    static func dictionary(_ outcome: LiqiToolSendOutcome,
                           spec: LiqiRequestSpec,
                           extra: [String: Any] = [:]) -> [String: Any] {
        var result: [String: Any] = [
            "method": spec.method,
            "payloadHex": LiqiEncoder.hexString(spec.payload)
        ]
        result.merge(extra) { current, _ in current }

        guard let sent = outcome.sent else {
            result["success"] = false
            result["error"] = "liqi_sender_unavailable"
            result["reason"] = outcome.unavailableReason ?? "unknown"
            return result
        }

        result["success"] = sent.success
        result["msgId"] = Int(sent.msgId)
        result["bytes"] = sent.byteCount
        if let detail = sent.detail { result["detail"] = detail }

        if !sent.success {
            result["error"] = "send_failed"
            return result
        }

        if let response = outcome.response {
            result["response"] = response.dictionary
            result["serverAccepted"] = !response.hasError
        } else {
            result["response"] = NSNull()
            result["note"] = "請求已送出但尚未收到對應 msgId 的 RESPONSE；"
                + "可稍後用 get_logs 觀察，或提高 awaitResponseMs。"
                + "「送出成功」不等於「伺服器接受」。"
        }
        return result
    }
}

// MARK: - Action Sender

/// 動作／大廳請求送出器。
///
/// 自己不碰 WebView：由 `WebViewModel` 注入「base64 → JS」的送出閉包，
/// 讓本類別可以在單元測試中以假閉包驅動。
@MainActor
final class LiqiActionSender {

    /// base64 → 送出結果（由 WebViewModel 注入，內部呼叫
    /// `window.__nakiWebSocket.sendRaw(...)`）
    typealias SendHandler = (String) async -> LiqiRawSendResult

    /// 送出通道（未注入時所有送出都會失敗並記錄）
    var sendHandler: SendHandler?

    /// 日誌輸出（WebViewModel 會同時寫 bridgeLog 與 debug server）
    var logHandler: ((String) -> Void)?

    /// 最近一次送出結果（診斷用）
    private(set) var lastResult: LiqiSendResult?

    /// msgId → method 對照表（RESPONSE 只帶 msgId，沒有方法名）
    private(set) var pendingMethods: [UInt16: String] = [:]

    /// `pendingMethods` 的上限，避免長時間執行累積
    private let pendingMethodsLimit = 64

    /// 自動心跳計時器（防閒置；預設關閉）
    ///
    /// 刻意不寫 `deinit` 來 invalidate：本專案設 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，
    /// 為 MainActor class 加 deinit 會產生 isolated deinit，在同步 XCTest 釋放時會讓 host app abort。
    /// 計時器 closure 以 weak self 捕獲，self 消失後會自行 invalidate。
    private var antiIdleTimer: Timer?

    init(sendHandler: SendHandler? = nil) {
        self.sendHandler = sendHandler
    }

    // MARK: - 核心送出

    /// 送出一筆請求：組 envelope → base64 → JS `sendRaw`
    @discardableResult
    func send(_ spec: LiqiRequestSpec) async -> LiqiSendResult {
        let (msgId, bytes) = LiqiEncoder.encodeRequest(method: spec.method, fields: spec.fields)
        let base64 = LiqiEncoder.base64String(bytes)

        guard let sendHandler else {
            let result = LiqiSendResult(method: spec.method, msgId: msgId,
                                        byteCount: bytes.count, success: false,
                                        detail: "no_send_handler")
            lastResult = result
            logHandler?("[Liqi] \(result.logLine)")
            return result
        }

        rememberMethod(spec.method, for: msgId)
        logHandler?("[Liqi] → \(spec.method) msgId=\(msgId) bytes=\(bytes.count) payload=\(LiqiEncoder.hexString(spec.payload))")

        let raw = await sendHandler(base64)
        let result = LiqiSendResult(method: spec.method, msgId: msgId,
                                    byteCount: bytes.count, success: raw.success,
                                    detail: raw.detail)
        lastResult = result
        logHandler?("[Liqi] \(result.logLine)")
        return result
    }

    /// 查詢某個 msgId 對應的方法（收到 RESPONSE 時對照用）
    func method(forMsgId msgId: UInt16) -> String? { pendingMethods[msgId] }

    private func rememberMethod(_ method: String, for msgId: UInt16) {
        if pendingMethods.count >= pendingMethodsLimit {
            pendingMethods.removeAll(keepingCapacity: true)
        }
        pendingMethods[msgId] = method
    }

    // MARK: - ② 動作層 API

    /// 打牌
    /// - Parameter tile: **雀魂格式**（`5m` / `0m` / `1z`）
    @discardableResult
    func discard(tile: String, moqie: Bool, timeuse: UInt32 = 0) async -> LiqiSendResult {
        await send(LiqiRequestBuilder.discard(tile: tile, moqie: moqie, timeuse: timeuse))
    }

    /// 立直（需附帶要打出的牌，雀魂格式）
    @discardableResult
    func riichi(tile: String, moqie: Bool = false, timeuse: UInt32 = 0) async -> LiqiSendResult {
        await send(LiqiRequestBuilder.riichi(tile: tile, moqie: moqie, timeuse: timeuse))
    }

    /// 吃（index 為 oplist combination 的索引）
    @discardableResult
    func chi(index: UInt32, timeuse: UInt32 = 0) async -> LiqiSendResult {
        await send(LiqiRequestBuilder.chi(index: index, timeuse: timeuse))
    }

    /// 碰
    @discardableResult
    func pon(index: UInt32 = 0, timeuse: UInt32 = 0) async -> LiqiSendResult {
        await send(LiqiRequestBuilder.pon(index: index, timeuse: timeuse))
    }

    /// 槓（暗槓 / 加槓 / 大明槓由 type 決定走哪個方法）
    @discardableResult
    func kan(type: LiqiOperationType, index: UInt32 = 0, tile: String? = nil,
             timeuse: UInt32 = 0) async -> LiqiSendResult {
        await send(LiqiRequestBuilder.kan(type: type, index: index, tile: tile, timeuse: timeuse))
    }

    /// 自摸和
    @discardableResult
    func tsumo(timeuse: UInt32 = 0) async -> LiqiSendResult {
        await send(LiqiRequestBuilder.tsumo(timeuse: timeuse))
    }

    /// 榮和
    @discardableResult
    func ron(timeuse: UInt32 = 0) async -> LiqiSendResult {
        await send(LiqiRequestBuilder.ron(timeuse: timeuse))
    }

    /// 九種九牌
    @discardableResult
    func kyushu(timeuse: UInt32 = 0) async -> LiqiSendResult {
        await send(LiqiRequestBuilder.kyushu(timeuse: timeuse))
    }

    /// 拔北（三麻）
    @discardableResult
    func babei(timeuse: UInt32 = 0) async -> LiqiSendResult {
        await send(LiqiRequestBuilder.babei(timeuse: timeuse))
    }

    /// 跳過（cancel_operation = true）
    /// - Parameter channel: 預設 `.chiPengGang`（跳過的情境幾乎都是回應他家打牌）
    @discardableResult
    func pass(channel: LiqiActionChannel = .chiPengGang, timeuse: UInt32 = 0) async -> LiqiSendResult {
        await send(LiqiRequestBuilder.cancel(channel: channel, timeuse: timeuse))
    }

    // MARK: - ③ 大廳層 API

    /// 建立好友房
    @discardableResult
    func createFriendRoom(config: LiqiFriendRoomConfig) async -> LiqiSendResult {
        await send(LiqiRequestBuilder.createRoom(config: config))
    }

    /// 建立好友房（常用參數版）
    @discardableResult
    func createFriendRoom(playerCount: Int = 4,
                          mode: UInt32 = 1,
                          timeFixed: UInt32 = 60,
                          timeAdd: UInt32 = 5,
                          aiLevel: UInt32? = nil,
                          enableAI: Bool = false,
                          publicLive: Bool = false,
                          clientVersionString: String = "") async -> LiqiSendResult {
        var config = LiqiFriendRoomConfig()
        config.playerCount = UInt32(max(0, playerCount))
        config.mode = mode
        config.timeFixed = timeFixed
        config.timeAdd = timeAdd
        config.aiLevel = aiLevel
        config.enableAI = enableAI
        config.publicLive = publicLive
        config.clientVersionString = clientVersionString
        return await createFriendRoom(config: config)
    }

    /// 加機器人到指定座位
    @discardableResult
    func addRobot(position: UInt32) async -> LiqiSendResult {
        await send(LiqiRequestBuilder.addRoomRobot(position: position))
    }

    /// 開始對局
    @discardableResult
    func startRoom() async -> LiqiSendResult {
        await send(LiqiRequestBuilder.startRoom())
    }

    /// 加入房間
    @discardableResult
    func joinRoom(roomId: UInt32, clientVersionString: String = "") async -> LiqiSendResult {
        await send(LiqiRequestBuilder.joinRoom(roomId: roomId,
                                               clientVersionString: clientVersionString))
    }

    /// 離開房間
    @discardableResult
    func leaveRoom() async -> LiqiSendResult {
        await send(LiqiRequestBuilder.leaveRoom())
    }

    /// 查詢目前房間
    @discardableResult
    func fetchRoom() async -> LiqiSendResult {
        await send(LiqiRequestBuilder.fetchRoom())
    }

    // MARK: - 送出 + 等待回應

    /// 送出一筆請求，並在指定時間內輪詢 `LiqiResponseStore` 等它的 RESPONSE。
    ///
    /// RESPONSE 只帶 msgId 不帶方法名，配對完全靠 msgId；`LiqiParser` 會在
    /// 我們自己送出的封包經過 `ws.send` hook 時記下 `msgId → method`，
    /// 收到回應時再配回來（見 LiqiResponseStore 檔頭）。
    ///
    /// - Parameter awaitResponseMs: 等待毫秒數；`<= 0` 表示不等（純射後不理）
    func sendAwaitingResponse(_ spec: LiqiRequestSpec,
                              awaitResponseMs: Int) async -> LiqiToolSendOutcome {
        let result = await send(spec)
        guard result.success, awaitResponseMs > 0 else {
            return LiqiToolSendOutcome(sent: result)
        }

        let pollIntervalMs = 50
        var waited = 0
        while waited < awaitResponseMs {
            if let record = LiqiResponseStore.shared.response(forMsgId: result.msgId) {
                return LiqiToolSendOutcome(sent: result, response: record)
            }
            try? await Task.sleep(nanoseconds: UInt64(pollIntervalMs) * 1_000_000)
            waited += pollIntervalMs
        }
        return LiqiToolSendOutcome(sent: result,
                                   response: LiqiResponseStore.shared.response(forMsgId: result.msgId))
    }

    // MARK: - ③ 大廳層：匹配 / 帳號 / 保活 API

    /// 段位場排隊
    @discardableResult
    func matchGame(matchMode: UInt32, clientVersionString: String = "") async -> LiqiSendResult {
        await send(LiqiRequestBuilder.matchGame(matchMode: matchMode,
                                                clientVersionString: clientVersionString))
    }

    /// 取消排隊
    @discardableResult
    func cancelMatch(matchMode: UInt32) async -> LiqiSendResult {
        await send(LiqiRequestBuilder.cancelMatch(matchMode: matchMode))
    }

    /// 查詢帳號資訊（account_id 必填）
    @discardableResult
    func fetchAccountInfo(accountId: UInt32) async -> LiqiSendResult {
        await send(LiqiRequestBuilder.fetchAccountInfo(accountId: accountId))
    }

    /// 查詢目前對局／房間狀態
    @discardableResult
    func fetchGamingInfo() async -> LiqiSendResult {
        await send(LiqiRequestBuilder.fetchGamingInfo())
    }

    /// 查詢伺服器時間
    @discardableResult
    func fetchServerTime() async -> LiqiSendResult {
        await send(LiqiRequestBuilder.fetchServerTime())
    }

    /// 大廳心跳（防閒置）
    @discardableResult
    func heatbeat(noOperationCounter: UInt32 = 0) async -> LiqiSendResult {
        let result = await send(LiqiRequestBuilder.heatbeat(noOperationCounter: noOperationCounter))
        if result.success {
            lastHeartbeatAt = Date()
            heartbeatCount += 1
        }
        return result
    }

    /// 登入保活
    @discardableResult
    func loginBeat(contract: String) async -> LiqiSendResult {
        await send(LiqiRequestBuilder.loginBeat(contract: contract))
    }

    /// 對局內廣播表情
    @discardableResult
    func sendEmoji(emoId: Int, exceptSelf: Bool = false) async -> LiqiSendResult {
        await send(LiqiRequestBuilder.emoji(emoId: emoId, exceptSelf: exceptSelf))
    }

    // MARK: - 防閒置（自動心跳）

    /// 是否啟用自動心跳
    private(set) var antiIdleEnabled = false
    /// 自動心跳間隔（秒）
    private(set) var antiIdleInterval: TimeInterval = 300
    /// 最近一次成功送出心跳的時間
    private(set) var lastHeartbeatAt: Date?
    /// 累計成功送出的心跳次數
    private(set) var heartbeatCount = 0

    /// 設定自動心跳。
    ///
    /// 取代 Unity 下已失效的 `window.__nakiAntiIdle`（它呼叫 `GameMgr.Inst.clientHeatBeat()`）。
    /// 這裡改為由 Swift 定期送 `.lq.Lobby.heatbeat`。
    ///
    /// ⚠️ **未驗證**：雀魂的閒置判定是否吃這個心跳、以及合適的間隔，都需要真實登入觀察。
    /// - Parameter intervalSeconds: 送出間隔，下限 30 秒（避免打太頻繁）
    func setAntiIdle(enabled: Bool, intervalSeconds: TimeInterval? = nil) {
        if let intervalSeconds {
            antiIdleInterval = max(30, intervalSeconds)
        }
        antiIdleEnabled = enabled

        antiIdleTimer?.invalidate()
        antiIdleTimer = nil
        guard enabled else { return }

        antiIdleTimer = Timer.scheduledTimer(withTimeInterval: antiIdleInterval,
                                             repeats: true) { [weak self] timer in
            guard self != nil else {
                timer.invalidate()
                return
            }
            Task { @MainActor [weak self] in
                guard let self, self.antiIdleEnabled else { return }
                await self.heatbeat()
            }
        }
    }

    /// 自動心跳狀態（給 MCP 工具輸出）
    var antiIdleStatus: [String: Any] {
        var status: [String: Any] = [
            "enabled": antiIdleEnabled,
            "intervalSeconds": Int(antiIdleInterval),
            "heartbeatCount": heartbeatCount,
            "method": LiqiRequestBuilder.heatbeatMethod
        ]
        if let lastHeartbeatAt {
            status["lastHeartbeatAt"] = ISO8601DateFormatter().string(from: lastHeartbeatAt)
            status["secondsSinceLastHeartbeat"] = Int(Date().timeIntervalSince(lastHeartbeatAt))
        } else {
            status["lastHeartbeatAt"] = NSNull()
            status["secondsSinceLastHeartbeat"] = NSNull()
        }
        return status
    }
}
