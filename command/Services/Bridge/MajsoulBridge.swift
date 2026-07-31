//
//  MajsoulBridge.swift
//  akagi
//
//  Created by Suoie on 2025/11/30.
//  雀魂協議橋接器 - 將 Majsoul Protobuf 消息轉換為 MJAI 格式
//  Updated: 2025/12/01 - 使用 MortalSwift 強類型 API
//

import Foundation
import MortalSwift

// 使用 LogManager 的 bridgeLog 函數

// MARK: - Constants (Legacy - for dictionary API)

/// 雀魂牌面到 MJAI 牌面的映射
private let MS_TILE_TO_MJAI: [String: String] = [
    "0m": "5mr", "1m": "1m", "2m": "2m", "3m": "3m", "4m": "4m",
    "5m": "5m", "6m": "6m", "7m": "7m", "8m": "8m", "9m": "9m",
    "0p": "5pr", "1p": "1p", "2p": "2p", "3p": "3p", "4p": "4p",
    "5p": "5p", "6p": "6p", "7p": "7p", "8p": "8p", "9p": "9p",
    "0s": "5sr", "1s": "1s", "2s": "2s", "3s": "3s", "4s": "4s",
    "5s": "5s", "6s": "6s", "7s": "7s", "8s": "8s", "9s": "9s",
    "1z": "E", "2z": "S", "3z": "W", "4z": "N",
    "5z": "P", "6z": "F", "7z": "C"
]

/// 風牌名稱
private let BAKAZE_NAMES = ["E", "S", "W", "N"]

// MARK: - MajsoulBridge

/// 雀魂協議橋接器
class MajsoulBridge {

    // MARK: - Properties

    /// Liqi 協議解析器
    private let liqiParser = LiqiParser()

    /// 帳號 ID
    private(set) var accountId: Int = 0

    /// 座位號
    private var seat: Int = 0

    /// 最後打牌的玩家
    private var lastDiscard: Int? = nil

    /// 已知的寶牌指示牌
    private var doras: [String] = []

    /// 是否為三麻
    private var is3P: Bool = false

    /// 待處理的立直接受消息
    private var pendingReachAccepted: [String: Any]? = nil

    /// 是否正在同步（斷線重連時使用）
    private var syncing: Bool = false

    /// 是否已收到過 authGame（用於判斷是否需要發送 start_game）
    private var hasReceivedAuthGame: Bool = false

    // MARK: - Public Methods

    /// 重置橋接器狀態（保留 accountId）
    func reset() {
        liqiParser.reset()
        // 注意：不重置 accountId，因為它在整個遊戲會話中應該保持不變
        // accountId 只在登入時設置
        seat = 0
        lastDiscard = nil
        doras = []
        is3P = false
        pendingReachAccepted = nil
        syncing = false
        hasReceivedAuthGame = false
        LiqiOperationStore.shared.clear()
        bridgeLog("[MajsoulBridge] 重置 (accountId 已保留: \(accountId))")
    }

    /// 完整重置橋接器狀態（包括 accountId，用於頁面重新載入）
    func fullReset() {
        liqiParser.reset()
        accountId = 0
        seat = 0
        lastDiscard = nil
        doras = []
        is3P = false
        pendingReachAccepted = nil
        syncing = false
        hasReceivedAuthGame = false
        LiqiOperationStore.shared.clear()
        LiqiResponseStore.shared.reset()
        bridgeLog("[MajsoulBridge] 完整重置 (accountId 已清除)")
    }

    /// 設置帳號 ID
    func setAccountId(_ id: Int) {
        accountId = id
    }

    /// 解析雀魂消息並返回原始解析結果（用於調試和請求跟蹤）
    func parseRaw(_ data: Data) -> [String: Any]? {
        return liqiParser.parse(data)
    }

    /// 解析雀魂消息並返回 MJAI 事件 (字典格式，保持兼容性)
    func parse(_ data: Data) -> [[String: Any]]? {
        guard let parsed = liqiParser.parse(data) else {
            return nil
        }

        // Unity 時代唯一能看到「自送請求的回應」與「表情廣播」的地方：
        // 這兩類訊息轉不成 MJAI 事件，若不在這裡接住就會被 convertToMJAI 丟掉。
        LiqiResponseStore.shared.capture(parsed)

        return convertToMJAI(parsed)
    }

    // MARK: - Private Methods

    /// 將解析後的消息轉換為 MJAI 格式
    private func convertToMJAI(_ msg: [String: Any]) -> [[String: Any]]? {
        guard let method = msg["method"] as? String else {
            return nil
        }

        let msgType = msg["type"] as? String ?? ""
        let msgData = msg["data"] as? [String: Any] ?? [:]

        var results: [[String: Any]] = []

        // 處理登入響應 - 獲取帳號 ID
        if (method == ".lq.Lobby.login" || method == ".lq.Lobby.oauth2Login" ||
            method == ".lq.Lobby.oauth2Auth" || method == ".lq.Lobby.emailLogin") && msgType == "response" {
            bridgeLog("[MajsoulBridge] 偵測到登入回應: \(method)")
            bridgeLog("[MajsoulBridge] 登入資料鍵: \(msgData.keys)")

            // 嘗試從不同結構獲取 account_id
            if let accId = msgData["accountId"] as? Int, accId > 0 {
                accountId = accId
                bridgeLog("[MajsoulBridge] 從直接欄位獲取 accountId: \(accountId)")
            } else if let account = msgData["account"] as? [String: Any] {
                if let accId = account["accountId"] as? Int {
                    accountId = accId
                    bridgeLog("[MajsoulBridge] 從 account.accountId 獲取 accountId: \(accountId)")
                } else if let accId = account["account_id"] as? Int {
                    accountId = accId
                    bridgeLog("[MajsoulBridge] 從 account.account_id 獲取 accountId: \(accountId)")
                }
            } else if let accId = msgData["account_id"] as? Int, accId > 0 {
                accountId = accId
                bridgeLog("[MajsoulBridge] 從 account_id 獲取 accountId: \(accountId)")
            }
        }

        // 處理 authGame 請求 - 重置狀態（新遊戲開始）
        if method == ".lq.FastTest.authGame" && msgType == "request" {
            bridgeLog("[MajsoulBridge] 偵測到 authGame 請求 - 重置狀態以開始新遊戲")
            // 重置遊戲狀態，但保留 accountId
            seat = 0
            lastDiscard = nil
            doras = []
            is3P = false
            pendingReachAccepted = nil

            // 從請求中獲取 accountId
            if let accId = msgData["accountId"] as? Int, accId > 0 {
                accountId = accId
                bridgeLog("[MajsoulBridge] 從 authGame 請求獲取 accountId: \(accountId)")
            }
        }

        // 處理 authGame 響應
        if method == ".lq.FastTest.authGame" && msgType == "response" {
            bridgeLog("[MajsoulBridge] 偵測到 authGame 回應")
            bridgeLog("[MajsoulBridge] 目前 accountId: \(accountId)")
            bridgeLog("[MajsoulBridge] authGame 資料鍵: \(msgData.keys)")

            hasReceivedAuthGame = true  // 標記已收到 authGame

            if let seatList = msgData["seatList"] as? [Int] {
                bridgeLog("[MajsoulBridge] 座位列表: \(seatList)")
                is3P = seatList.count == 3

                if let index = seatList.firstIndex(of: accountId) {
                    seat = index
                    bridgeLog("[MajsoulBridge] 找到座位索引: \(seat)")

                    // MortalSwift 的 StartGameEvent.names 是必填（decode 時 keyNotFound 會讓
                    // bot.react 直接拋錯、整局無法初始化）。優先用 authGame 回應裡的玩家暱稱，
                    // 取不到就補佔位名——Mortal 不用 names 做推論，只要求欄位存在。
                    let playerCount = seatList.count
                    var names: [String] = []
                    if let players = msgData["players"] as? [[String: Any]] {
                        names = players.compactMap {
                            ($0["nickname"] as? String) ?? ($0["account_id"] as? Int).map { "Player\($0)" }
                        }
                    }
                    if names.count != playerCount {
                        names = (0..<playerCount).map { $0 == seat ? "Naki" : "Player\($0)" }
                    }

                    // #3: 帶上三麻旗標（bridge 由 seatList.count 判斷），供下游建立對應 bot
                    results.append([
                        "type": "start_game",
                        "id": seat,
                        "is3P": is3P,
                        "names": names
                    ])
                } else {
                    // #10: 找不到 accountId → 不發 start_game（不再靜默預設座位 0），
                    // 避免上層以錯誤座位建立 bot。記錄 accountId 與 seatList 供診斷。
                    bridgeLog("[MajsoulBridge] ERROR: accountId \(accountId) 在 seatList \(seatList) 中找不到! 不發送 start_game，避免以錯座位建立 bot。")
                }
            } else {
                bridgeLog("[MajsoulBridge] 錯誤: authGame 回應中找不到 seatList!")
            }
        }

        // 處理遊戲動作
        if method == ".lq.ActionPrototype" {
            if let name = msgData["name"] as? String,
               let actionData = msgData["data"] as? [String: Any] {
                if let events = parseAction(name: name, data: actionData) {
                    results.append(contentsOf: events)
                }
            }
        }

        // 處理遊戲同步（活動模式、斷線重連等）
        // 重要：只處理 gameRestore.actions，不發送額外的 start_game（與 Akagi 行為一致）
        if method == ".lq.FastTest.syncGame" || method == ".lq.FastTest.enterGame" {
            bridgeLog("[MajsoulBridge] 偵測到 syncGame/enterGame, hasReceivedAuthGame=\(hasReceivedAuthGame)")
            syncing = true
            if let gameRestore = msgData["gameRestore"] as? [String: Any] {
                if let events = parseSyncGameRestore(gameRestore) {
                    results.append(contentsOf: events)
                }
            }
            syncing = false
        }

        // 處理遊戲結束
        if method == ".lq.NotifyGameEndResult" || method == ".lq.NotifyGameTerminate" {
            results.append(["type": "end_game"])
        }

        return results.isEmpty ? nil : results
    }

    /// 解析遊戲動作
    private func parseAction(name: String, data: [String: Any]) -> [[String: Any]]? {
        var results: [[String: Any]] = []

        bridgeLog("[MajsoulBridge] 解析動作: name=\(name)")

        // Unity 客戶端已無 `DesktopMgr.Inst.oplist`，改由協定層保存最近一次可用操作，
        // 供 WebViewModel 的自動打牌重試框架與 LiqiActionSender 判斷。
        recordOperationSnapshot(name: name, data: data)

        // #13: 處理待處理的立直接受消息
        // 若立直宣言牌立即被榮和（下個 action 為 ActionHule），立直棒實際未放置，
        // 應丟棄 pending 不發 reach_accepted；其他情況才正常補發。
        if let pending = pendingReachAccepted {
            pendingReachAccepted = nil
            if name == "ActionHule" {
                bridgeLog("[MajsoulBridge] 立直宣言牌被榮和，丟棄待處理 reach_accepted（立直棒未放置）")
            } else {
                results.append(pending)
            }
        }

        switch name {
        case "ActionNewRound":
            bridgeLog("[MajsoulBridge] 解析動作: ActionNewRound 資料鍵: \(data.keys)")
            if let events = parseNewRound(data) {
                bridgeLog("[MajsoulBridge] 解析動作: ActionNewRound 產生了 \(events.count) events")
                results.append(contentsOf: events)
            } else {
                bridgeLog("[MajsoulBridge] 解析動作: ActionNewRound 返回 nil!")
            }

        case "ActionDealTile":
            if let event = parseDealTile(data) {
                results.append(event)
            }

        case "ActionDiscardTile":
            if let events = parseDiscardTile(data) {
                results.append(contentsOf: events)
            }

        case "ActionChiPengGang":
            if let event = parseChiPengGang(data) {
                results.append(event)
            }
            // 碰/吃後如果是自己的操作，需要打牌
            if let actor = data["seat"] as? Int, actor == seat {
                // 碰/吃後需要發送一個 tsumo-like 事件讓 Bot 知道輪到自己打牌
                // 但實際上不是自摸，只是表示輪到自己出牌
                // Bot 在收到自己的 pon/chi 後會自動進入打牌模式
                bridgeLog("[MajsoulBridge] 自己碰/吃後，等待打牌選擇")
            }

        case "ActionAnGangAddGang":
            if let event = parseAnGangAddGang(data) {
                results.append(event)
            }

        case "ActionHule", "ActionNoTile", "ActionLiuJu":
            // #13: 局結束時清除待處理 reach_accepted，避免跨局殘留
            pendingReachAccepted = nil
            results.append(["type": "end_kyoku"])

        case "ActionBaBei":
            if let actor = data["seat"] as? Int {
                results.append([
                    "type": "nukidora",
                    "actor": actor,
                    "pai": "N"
                ])
            }

        default:
            break
        }

        // 處理寶牌
        if let doraList = data["doras"] as? [String], doraList.count > doras.count {
            if let newDora = doraList.last,
               let mjaiTile = MS_TILE_TO_MJAI[newDora] {
                results.append([
                    "type": "dora",
                    "dora_marker": mjaiTile
                ])
                doras = doraList
            }
        }

        return results.isEmpty ? nil : results
    }

    /// 把動作附帶的 `OptionalOperationList` 存進 `LiqiOperationStore`
    ///
    /// 動作帶 operation → 記錄成新快照（供送出端判斷可做什麼）；
    /// 動作不帶 operation → 代表上一批機會已經過期，直接清掉，
    /// 避免自動打牌拿著舊 oplist 送出遲到的動作。
    private func recordOperationSnapshot(name: String, data: [String: Any]) {
        guard let operation = data["operation"] as? [String: Any] else {
            LiqiOperationStore.shared.clear()
            return
        }

        let contextTile = data["tile"] as? String
        guard let snapshot = LiqiOperationStore.shared.record(fromParsed: operation,
                                                             contextTile: contextTile,
                                                             source: name) else {
            LiqiOperationStore.shared.clear()
            return
        }

        bridgeLog("[MajsoulBridge] oplist 更新: \(name) seat=\(snapshot.seat) "
                  + "types=\(snapshot.rawTypes) tile=\(contextTile ?? "-") seq=\(snapshot.sequence)")
    }

    /// 解析新一局開始
    private func parseNewRound(_ data: [String: Any]) -> [[String: Any]]? {
        var results: [[String: Any]] = []

        bridgeLog("[MajsoulBridge] parseNewRound 調用, 資料鍵: \(data.keys)")

        guard let chang = data["chang"] as? Int,
              let ju = data["ju"] as? Int else {
            bridgeLog("[MajsoulBridge] parseNewRound: 缺少 chang 或 ju!")
            return nil
        }

        let tiles = data["tiles"] as? [String] ?? []
        bridgeLog("[MajsoulBridge] parseNewRound: 場=\(chang), ju=\(ju), tiles.count=\(tiles.count)")

        let bakaze = BAKAZE_NAMES[chang % 4]
        let kyoku = ju + 1
        let honba = data["ben"] as? Int ?? 0
        let kyotaku = data["liqibang"] as? Int ?? 0
        var scores = data["scores"] as? [Int] ?? [25000, 25000, 25000, 25000]

        if is3P && scores.count == 3 {
            scores.append(0)
        }

        // 處理寶牌
        var doraMarker = "?"
        if let doraList = data["doras"] as? [String],
           let firstDora = doraList.first,
           let mjaiDora = MS_TILE_TO_MJAI[firstDora] {
            doras = doraList
            doraMarker = mjaiDora
        }

        // 轉換手牌
        let playerCount = is3P ? 3 : 4
        var tehais = [[String]](repeating: [String](repeating: "?", count: 13), count: playerCount)

        let myTehais = tiles.prefix(13).compactMap { MS_TILE_TO_MJAI[$0] }
        if seat >= 0 && seat < playerCount {
            tehais[seat] = myTehais.sorted(by: comparePai)
        }

        results.append([
            "type": "start_kyoku",
            "bakaze": bakaze,
            "dora_marker": doraMarker,
            "honba": honba,
            "kyoku": kyoku,
            "kyotaku": kyotaku,
            "oya": ju,
            "scores": scores,
            "tehais": tehais
        ])

        // 如果配牌有 14 張（親家），添加自摸事件
        let isOya = (seat == ju)
        bridgeLog("[MajsoulBridge] parseNewRound: tiles.count=\(tiles.count), seat=\(seat), ju(oya)=\(ju), isOya=\(isOya)")
        bridgeLog("[MajsoulBridge] parseNewRound: tiles=\(tiles)")
        if tiles.count >= 14 {
            if let tsumoTile = tiles.last,
               let mjaiTile = MS_TILE_TO_MJAI[tsumoTile] {
                bridgeLog("[MajsoulBridge] parseNewRound: 為親家添加合成摸牌, tile=\(tsumoTile) -> \(mjaiTile)")
                results.append([
                    "type": "tsumo",
                    "actor": seat,
                    "pai": mjaiTile
                ])
            } else {
                bridgeLog("[MajsoulBridge] parseNewRound: 錯誤 - 無法轉換第 14 張牌")
            }
        } else {
            bridgeLog("[MajsoulBridge] parseNewRound: 非親家, 無合成摸牌")
        }

        return results
    }

    /// 解析摸牌
    private func parseDealTile(_ data: [String: Any]) -> [String: Any]? {
        guard let actor = data["seat"] as? Int else { return nil }

        let tile = data["tile"] as? String ?? ""
        let mjaiTile = tile.isEmpty ? "?" : (MS_TILE_TO_MJAI[tile] ?? "?")

        // 如果是自己的摸牌但 tile 為空，這是一個解析錯誤
        // 不應該發送給 Bot，否則會導致狀態損壞
        if actor == seat && mjaiTile == "?" {
            bridgeLog("[MajsoulBridge] 警告: 自己的摸牌沒有牌資料! 跳過事件。")
            bridgeLog("[MajsoulBridge] parseDealTile 資料: \(data)")
            // 返回 nil 跳過這個事件，防止 Bot 崩潰
            return nil
        }

        bridgeLog("[MajsoulBridge] parseDealTile: 玩家=\(actor), tile=\(tile), mjaiTile=\(mjaiTile)")

        return [
            "type": "tsumo",
            "actor": actor,
            "pai": mjaiTile
        ]
    }

    /// 解析打牌
    private func parseDiscardTile(_ data: [String: Any]) -> [[String: Any]]? {
        var results: [[String: Any]] = []

        guard let actor = data["seat"] as? Int,
              let tile = data["tile"] as? String,
              let mjaiTile = MS_TILE_TO_MJAI[tile] else {
            return nil
        }

        lastDiscard = actor

        let tsumogiri = data["moqie"] as? Bool ?? false
        let isLiqi = data["isLiqi"] as? Bool ?? false

        // 如果是立直，先發送立直事件
        if isLiqi {
            results.append([
                "type": "reach",
                "actor": actor
            ])
        }

        results.append([
            "type": "dahai",
            "actor": actor,
            "pai": mjaiTile,
            "tsumogiri": tsumogiri
        ])

        // 儲存立直接受事件
        if isLiqi {
            pendingReachAccepted = [
                "type": "reach_accepted",
                "actor": actor
            ]
        }

        return results
    }

    /// 解析吃碰槓
    private func parseChiPengGang(_ data: [String: Any]) -> [String: Any]? {
        guard let actor = data["seat"] as? Int,
              let opType = data["type"] as? Int else {
            bridgeLog("[MajsoulBridge] parseChiPengGang: 缺少 seat 或 type")
            return nil
        }

        // 解析 tiles - 可能是字符串數組或單個字符串
        var tiles: [String] = []
        if let tilesArray = data["tiles"] as? [String] {
            tiles = tilesArray
        } else if let tilesStr = data["tiles"] as? String {
            // 單個字符串，需要處理
            tiles = [tilesStr]
        }

        // 解析 froms - 來源座位數組
        var froms: [Int] = []
        if let fromsArray = data["froms"] as? [Int] {
            froms = fromsArray
        }

        bridgeLog("[MajsoulBridge] parseChiPengGang: 玩家=\(actor), opType=\(opType), tiles=\(tiles), froms=\(froms)")

        // 如果 froms 為空，嘗試從 lastDiscard 獲取 target
        var target = lastDiscard ?? ((actor + 3) % 4)
        var pai = ""
        var consumed: [String] = []

        // ⭐ 使用 froms 數組來確定 pai (來自其他玩家的牌) 和 consumed (自己手中的牌)
        if !froms.isEmpty && froms.count == tiles.count {
            for (idx, fromSeat) in froms.enumerated() {
                if idx < tiles.count {
                    let tile = tiles[idx]
                    let mjaiTile = MS_TILE_TO_MJAI[tile] ?? tile
                    if fromSeat != actor {
                        // 這張牌來自其他玩家
                        target = fromSeat
                        pai = mjaiTile
                        bridgeLog("[MajsoulBridge] parseChiPengGang: 找到 pai=\(pai) from target=\(target)")
                    } else {
                        // 這張牌來自自己手中
                        consumed.append(mjaiTile)
                    }
                }
            }
        } else {
            // 備用邏輯：沒有 froms 或長度不匹配
            bridgeLog("[MajsoulBridge] parseChiPengGang: froms 缺失或不匹配, 使用備用方案")
            if let firstTile = tiles.first {
                pai = MS_TILE_TO_MJAI[firstTile] ?? firstTile
            }
            // 對於碰，consumed 是 2 張相同的牌
            if opType == 1 && !pai.isEmpty {
                consumed = [pai, pai]
            } else if opType == 2 && !pai.isEmpty {
                consumed = [pai, pai, pai]
            }
        }

        // ⭐ 如果 consumed 為空但應該有值，使用 tiles 和 pai 構建
        if consumed.isEmpty && tiles.count > 0 {
            if opType == 0 { // Chi - 排除 pai，其餘 2 張是 consumed
                for tile in tiles {
                    let mjaiTile = MS_TILE_TO_MJAI[tile] ?? tile
                    if mjaiTile != pai || consumed.count >= 2 {
                        if consumed.count < 2 {
                            consumed.append(mjaiTile)
                        }
                    }
                }
                // 如果還是不夠，添加所有非 pai 的牌
                if consumed.count < 2 {
                    for tile in tiles {
                        let mjaiTile = MS_TILE_TO_MJAI[tile] ?? tile
                        if !consumed.contains(mjaiTile) && consumed.count < 2 {
                            consumed.append(mjaiTile)
                        }
                    }
                }
            } else if opType == 1 && !pai.isEmpty { // Pon
                consumed = [pai, pai]
            } else if opType == 2 && !pai.isEmpty { // Daiminkan
                consumed = [pai, pai, pai]
            }
        }

        bridgeLog("[MajsoulBridge] parseChiPengGang 結果: target=\(target), pai=\(pai), consumed=\(consumed)")

        switch opType {
        case 0: // Chi
            return [
                "type": "chi",
                "actor": actor,
                "target": target,
                "pai": pai,
                "consumed": consumed
            ]

        case 1: // Pon
            return [
                "type": "pon",
                "actor": actor,
                "target": target,
                "pai": pai,
                "consumed": consumed
            ]

        case 2: // Daiminkan
            return [
                "type": "daiminkan",
                "actor": actor,
                "target": target,
                "pai": pai,
                "consumed": consumed
            ]

        default:
            return nil
        }
    }

    /// 解析暗槓/加槓
    private func parseAnGangAddGang(_ data: [String: Any]) -> [String: Any]? {
        guard let actor = data["seat"] as? Int,
              let tile = data["tiles"] as? String,
              let opType = data["type"] as? Int else {
            return nil
        }

        let mjaiTile = MS_TILE_TO_MJAI[tile] ?? tile
        let baseTile = mjaiTile.replacingOccurrences(of: "r", with: "")

        switch opType {
        case 3: // Ankan
            var consumed = [String](repeating: baseTile, count: 4)
            if mjaiTile.first == "5" && !mjaiTile.hasSuffix("z") {
                consumed[0] = baseTile + "r"
            }
            return [
                "type": "ankan",
                "actor": actor,
                "consumed": consumed
            ]

        case 2: // Kakan
            var consumed = [String](repeating: baseTile, count: 3)
            if baseTile.first == "5" && !mjaiTile.hasSuffix("r") {
                consumed[0] = baseTile + "r"
            }
            return [
                "type": "kakan",
                "actor": actor,
                "pai": mjaiTile,
                "consumed": consumed
            ]

        default:
            return nil
        }
    }

    /// 牌的比較函數
    private func comparePai(_ a: String, _ b: String) -> Bool {
        let order = [
            "1m", "2m", "3m", "4m", "5mr", "5m", "6m", "7m", "8m", "9m",
            "1p", "2p", "3p", "4p", "5pr", "5p", "6p", "7p", "8p", "9p",
            "1s", "2s", "3s", "4s", "5sr", "5s", "6s", "7s", "8s", "9s",
            "E", "S", "W", "N", "P", "F", "C", "?"
        ]
        let idxA = order.firstIndex(of: a) ?? order.count
        let idxB = order.firstIndex(of: b) ?? order.count
        return idxA < idxB
    }

    // MARK: - Sync Game Restore

    /// 解析遊戲恢復數據（用於活動模式、斷線重連等）
    /// 重要：與 Akagi 行為一致，不發送額外的 start_game
    /// start_game 應該由 authGame 響應觸發
    private func parseSyncGameRestore(_ gameRestore: [String: Any]) -> [[String: Any]]? {
        var results: [[String: Any]] = []

        bridgeLog("[MajsoulBridge] 解析 gameRestore: \(gameRestore.keys)")

        // ⚠️ 不發送額外的 start_game！authGame 響應已經發送過 start_game。

        // #9: 重連時 start_kyoku 只保留單一來源，避免重複 start_kyoku 破壞局狀態。
        //   - 有 actions：只重放 actions 來發 start_kyoku（其中 ActionNewRound 會發一個），
        //     不再由 snapshot(gameState) 另發（原本兩者都發 → 兩個 start_kyoku）。
        //   - 無 actions：才由 snapshot 的 parseGameState 發 start_kyoku（後備路徑）。
        // #18: kan-dora 補發與 start_kyoku「同一來源、二擇一」，避免雙重 dora 事件：
        //   - actions 路徑：各 action 的 doras 欄位經 parseAction 內建的 dora 補發自然重現 kan-dora；
        //   - snapshot 路徑：由 parseGameState 從 doraList 第 2 個(index 1)以後補發。
        if let actions = gameRestore["actions"] as? [[String: Any]], !actions.isEmpty {
            // 主路徑：重放歷史動作（與 Akagi 的 parse_syncGame 行為一致）
            bridgeLog("[MajsoulBridge] 找到 \(actions.count) 個動作需要重播（start_kyoku/kan-dora 皆由重放產生）")
            for action in actions {
                if let name = action["name"] as? String,
                   let data = action["data"] as? [String: Any] {
                    if let events = parseAction(name: name, data: data) {
                        results.append(contentsOf: events)
                    }
                }
            }
        } else if let gameState = gameRestore["gameState"] as? [String: Any] {
            // 後備路徑：無 actions 時，才由 snapshot 發 start_kyoku 並補 kan-dora
            bridgeLog("[MajsoulBridge] 無 actions，改用 snapshot gameState 發 start_kyoku: \(gameState.keys)")
            if let events = parseGameState(gameState) {
                results.append(contentsOf: events)
            }
        }

        return results.isEmpty ? nil : results
    }

    /// 解析遊戲狀態
    private func parseGameState(_ gameState: [String: Any]) -> [[String: Any]]? {
        var results: [[String: Any]] = []

        // 從 gameState 中提取信息構建 start_kyoku 事件
        let chang = gameState["chang"] as? Int ?? 0
        let ju = gameState["ju"] as? Int ?? 0
        let ben = gameState["ben"] as? Int ?? 0
        let kyotaku = gameState["liqibang"] as? Int ?? 0

        let bakaze = BAKAZE_NAMES[chang % 4]
        let kyoku = ju + 1

        var scores = gameState["scores"] as? [Int] ?? [25000, 25000, 25000, 25000]
        if is3P && scores.count == 3 {
            scores.append(0)
        }

        // 獲取手牌
        let playerCount = is3P ? 3 : 4
        var tehais = [[String]](repeating: [String](repeating: "?", count: 13), count: playerCount)

        if let myTiles = gameState["tiles"] as? [String] {
            let myTehais = myTiles.prefix(13).compactMap { MS_TILE_TO_MJAI[$0] }
            if seat >= 0 && seat < playerCount {
                tehais[seat] = myTehais.sorted(by: comparePai)
            }
        }

        // 處理寶牌：start_kyoku 只帶第一個 dora_marker
        var doraMarker = "?"
        if let doraList = gameState["doras"] as? [String] {
            if let firstDora = doraList.first,
               let mjaiDora = MS_TILE_TO_MJAI[firstDora] {
                doraMarker = mjaiDora
            }
            doras = doraList
        }

        results.append([
            "type": "start_kyoku",
            "bakaze": bakaze,
            "dora_marker": doraMarker,
            "honba": ben,
            "kyoku": kyoku,
            "kyotaku": kyotaku,
            "oya": ju,
            "scores": scores,
            "tehais": tehais
        ])

        // #18: 後備路徑（無 actions 重連）補發已翻的 kan-dora。
        // start_kyoku 僅帶第一個 dora_marker，doraList 第 2 個(index 1)以後需逐一以 dora 事件補上，
        // 讓 bot 正確計算寶牌。本路徑與 actions 重放互斥（見 parseSyncGameRestore #9/#18 註解），不會重複。
        if let doraList = gameState["doras"] as? [String], doraList.count > 1 {
            for extraDora in doraList.dropFirst() {
                if let mjaiExtra = MS_TILE_TO_MJAI[extraDora] {
                    results.append([
                        "type": "dora",
                        "dora_marker": mjaiExtra
                    ])
                }
            }
        }

        return results.isEmpty ? nil : results
    }
}
