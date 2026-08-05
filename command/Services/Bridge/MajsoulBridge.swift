//
//  MajsoulBridge.swift
//  Naki
//
//  Created by Suoie on 2025/11/30.
//  雀魂協議橋接器 - 將 Majsoul Protobuf 消息轉換為 MJAI 格式
//  Updated: 2025/12/01 - 使用 MortalSwift 強類型 API
//

import Foundation
import MortalSwift

// 使用 LogManager 的 bridgeLog 函數

// MARK: - Constants

// 牌碼轉換（雀魂 ⇄ MJAI）與牌序都在 `LiqiTile`，不要在這裡另立一份。

/// 風牌名稱
private let BAKAZE_NAMES = ["E", "S", "W", "N"]

/// MJAI event 字典裡 Naki 自己附加的 key（非 MJAI 協定欄位）。
enum MJAIEventKey {
    /// 產生這個 event 的那批 oplist 的 sequence（`UInt64`）。
    /// 讓「推薦」能綁定「它所根據的那批決策機會」，避免用舊推薦回應新 oplist。
    static let oplistSequence = "__nakiOplistSequence"
}

// MARK: - MajsoulBridge

/// 雀魂協議橋接器
class MajsoulBridge {

    // MARK: - Properties

    /// Liqi 協議解析器
    private let liqiParser = LiqiParser()

    /// 解析失敗的去處（UI 橫幅、`/status`、`get_status` 都讀這一份）。
    ///
    /// 解析器只負責「這段 bytes 解不開」，**後果由這裡判定**。
    /// 少一個未知欄位是 degraded；拿不到座位或開不出 start_kyoku 是 blocking
    /// ——後者代表這一局 Naki 不會工作，必須讓使用者看見，而不是只留一行 log。
    ///
    /// 測試注入獨立實例，避免跨測試互相汙染。
    let faultState: LiqiParseFaultState

    init(faultState: LiqiParseFaultState = .shared) {
        self.faultState = faultState
    }

    /// `@MainActor` 隔離的 class 在 NakiTests host 釋放會 SIGABRT（見 CLAUDE.md「專案結構的坑」）
    nonisolated deinit { }

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

    /// 重置橋接器狀態（保留 accountId 與 seat／is3P）
    func reset() {
        liqiParser.reset()
        // 注意：不重置 accountId，因為它在整個遊戲會話中應該保持不變
        // accountId 只在登入時設置
        //
        // seat／is3P 同理**必須保留**（2026-08-05 live 422 事故）：這個 reset
        // 走的是「局中重連」路徑，重連回的是**同一局**，座位不可能變；而
        // syncGame 重連不會再送 seatList，歸零的 seat 永遠恢復不了 →
        // 之後每個新 kyoku 的 parseNewRound 都把自家手牌放到 tehais[0]，
        // 本地模型狀態壞掉（退化成摸切）、雲端伺服器整局 422 拒收。
        // 換帳號／換對局的歸零由 fullReset()（頁面重載）與 authGame
        // （重新推導座位）負責，不靠這裡。
        lastDiscard = nil
        doras = []
        pendingReachAccepted = nil
        syncing = false
        hasReceivedAuthGame = false
        LiqiOperationStore.shared.clear()
        bridgeLog("[MajsoulBridge] 重置 (accountId 已保留: \(accountId), seat 已保留: \(seat))")
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
        // 頁面重新載入＝重新開始：上一次載入留下的解析失敗不該掛在新頁面上
        faultState.reset()
        bridgeLog("[MajsoulBridge] 完整重置 (accountId 已清除)")
    }

    /// 設置帳號 ID
    func setAccountId(_ id: Int) {
        accountId = id
    }

    /// 最近一次 `parse` / `parseRaw` 的**原始**解析結果（轉不成 MJAI 事件時仍然有值）。
    ///
    /// 呼叫端要在 `parse` 回 nil 時 log 方法名，一律讀這個欄位，不要另建 `LiqiParser`
    /// 重解一次：新實例沒有 `pendingRequests`，每一則 RESPONSE 都必然配不上，
    /// 等於製造一份**錯的**解析結果，而且同一個 frame 會被解三次
    /// （send 面一次、receive 面一次、失敗重解一次）。
    private(set) var lastParsed: [String: Any]?

    /// 最近一次連 envelope 都解不開的原因（`lastParsed == nil` 時才有意義）
    var lastEnvelopeFailure: LiqiEnvelopeDecodeFailure? { liqiParser.lastEnvelopeFailure }

    /// 解析雀魂消息並返回原始解析結果（用於調試和請求跟蹤）
    func parseRaw(_ data: Data) -> [String: Any]? {
        let parsed = liqiParser.parse(data)
        lastParsed = parsed
        drainParserFaults()
        return parsed
    }

    /// 把解析器這一則訊息累積的失敗收進 `faultState`。
    ///
    /// 解析器報上來的一律是 degraded；要升級成 blocking 的地方（座位、start_kyoku）
    /// 由 `convertToMJAI` 自己判斷後另外記一筆。
    private func drainParserFaults() {
        for fault in liqiParser.faults {
            faultState.record(fault)
        }
    }

    /// 記一筆「這一局不會運作」的失敗（UI 會掛出常駐錯誤）
    private func recordBlockingFault(site: String,
                                     fieldId: Int? = nil,
                                     byteCount: Int = 0,
                                     reason: String) {
        let fault = LiqiParseFault(site: site,
                                   fieldId: fieldId,
                                   byteCount: byteCount,
                                   reason: reason,
                                   severity: .blocking)
        faultState.record(fault)
        eventLog("[MajsoulBridge] ⛔️ \(fault.text)")
    }

    /// 解析雀魂消息並返回 MJAI 事件 (字典格式，保持兼容性)
    func parse(_ data: Data) -> [[String: Any]]? {
        let parsedOrNil = liqiParser.parse(data)
        lastParsed = parsedOrNil
        drainParserFaults()

        guard let parsed = parsedOrNil else {
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

                // 座位是查出來的還是猜出來的，要說清楚。
                // heuristic = 沒有 seat_list，拿 players 的順序頂替；
                // 座位猜錯的後果是 resolver 的 `seat_mismatch` fail-closed 整批不動作，
                // 表象是「自動打牌完全不動」——不寫下來就查不到根因。
                if msgData["seatListConfidence"] as? String == LiqiParseConfidence.heuristic.rawValue {
                    eventLog("[MajsoulBridge] ⚠️ seatList 是從 players 順序推出來的（heuristic），"
                             + "座位可能是錯的：\(seatList)")
                }

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
                            ($0["nickname"] as? String) ?? ($0["accountId"] as? Int).map { "Player\($0)" }
                        }
                    }
                    if names.count != playerCount {
                        names = (0..<playerCount).map { $0 == seat ? "Naki" : "Player\($0)" }
                    }

                    // 帶上三麻旗標（bridge 由 seatList.count 判斷），供下游建立對應 bot
                    results.append([
                        "type": "start_game",
                        "id": seat,
                        "is3P": is3P,
                        "names": names
                    ])

                    // 這一局的前提（座位）拿到了 → 只收掉座位系列的常駐錯誤
                    faultState.clearBlocking(matchingSitePrefixes: ["ResAuthGame"])
                } else {
                    // 找不到 accountId → 不發 start_game（不靜默預設座位 0），
                    // 避免上層以錯誤座位建立 bot。記錄 accountId 與 seatList 供診斷。
                    bridgeLog("[MajsoulBridge] ERROR: accountId \(accountId) 在 seatList \(seatList) 中找不到! 不發送 start_game，避免以錯座位建立 bot。")
                    // 不發 start_game 代表**整局都不會工作**（沒有 bot、沒有推薦、
                    // 沒有自動打牌），這種狀態不能只留在 log 裡。
                    recordBlockingFault(site: "ResAuthGame.seat_list",
                                        fieldId: 3,
                                        reason: "accountId \(accountId) 不在 seatList \(seatList) 中，"
                                            + "無法決定自家座位 → 不建立 Bot")
                }
            } else {
                // 只 log 一行不夠：start_game 不發、整局靜默不工作，
                // 畫面上完全看不出來（側欄仍顯示「已連線」）。
                bridgeLog("[MajsoulBridge] 錯誤: authGame 回應中找不到 seatList!")
                recordBlockingFault(site: "ResAuthGame.seat_list",
                                    fieldId: 3,
                                    reason: "authGame 回應沒有 seatList（keys=\(msgData.keys.sorted())）"
                                        + "，無法決定自家座位 → 不建立 Bot")
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
        // 供 AutoPlayDecisionResolver → LiqiActionSender 這條決策鏈判斷。
        // sequence 會標記到這批 events 上（見 return 前的 stamp）。
        let oplistSequence = recordOperationSnapshot(name: name, data: data)

        // 處理待處理的立直接受消息
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
            // 局結束時清除待處理 reach_accepted，避免跨局殘留
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
               let mjaiTile = LiqiTile.mjai(fromMajsoul: newDora) {
                results.append([
                    "type": "dora",
                    "dora_marker": mjaiTile
                ])
                doras = doraList
            }
        }

        // 把這批 action 的 oplist sequence 標到每個 event 上（見 recordOperationSnapshot）。
        // 消費端（NakiWebCoordinator.process）用它讓推薦綁定它所根據的那批 oplist。
        if let oplistSequence {
            for i in results.indices {
                results[i][MJAIEventKey.oplistSequence] = oplistSequence
            }
        }

        return results.isEmpty ? nil : results
    }

    /// 把動作附帶的 `OptionalOperationList` 存進 `LiqiOperationStore`
    ///
    /// 動作帶 operation → 記錄成新快照（供送出端判斷可做什麼）；
    /// 動作不帶 operation → 代表上一批機會已經過期，直接清掉，
    /// 避免自動打牌拿著舊 oplist 送出遲到的動作。
    /// 回傳這批 action 建立的 oplist 快照 sequence（沒有可做的操作時回 nil）。
    /// 呼叫端把它標記到同一批 MJAI events 上，讓「推薦」能綁定「產生它的那批 oplist」——
    /// 否則自動打牌可能拿上一個機會的推薦，去回應這一個機會的 oplist。
    @discardableResult
    private func recordOperationSnapshot(name: String, data: [String: Any]) -> UInt64? {
        guard let operation = data["operation"] as? [String: Any] else {
            LiqiOperationStore.shared.clear()
            return nil
        }

        let contextTile = data["tile"] as? String
        guard let snapshot = LiqiOperationStore.shared.record(fromParsed: operation,
                                                             contextTile: contextTile,
                                                             source: name) else {
            // 動作**帶了** operation 卻建不出快照，代表解析結果不合預期
            // （operationList 空、或每筆都缺 type）。這在莊家第一打時實測發生過：
            // ActionNewRound 的 keys 有 operation，但沒有任何 oplist 更新，
            // 於是自動打牌整巡不送，直到伺服器逾時代打。
            //
            // 原本這條路是靜默的 `clear()`，查不出所以然。把內容印出來，
            // 下次發生時可以直接看到 operation 長什麼樣。
            let list = operation["operationList"] as? [[String: Any]]

            // 空的 operationList 是**正常**的：別家摸牌時伺服器也會附一個
            // operation，只是裡面沒有我們可做的事。實測一局出現 14 次。
            // 只有「有內容卻建不出快照」才值得看——那才是解析出問題。
            guard let list, !list.isEmpty else {
                // ActionNewRound 的空 operation 不正常：莊家第一打的授權就在這裡。
                // 別的動作（別家摸牌）帶空清單是常態，維持靜默。
                if name == "ActionNewRound" {
                    eventLog("[MajsoulBridge] ⚠️ ActionNewRound 的 operation 是空的"
                             + "（莊家第一打會因此拿不到 oplist）: "
                             + "rawBytes=\(operation["_rawBytes"] as? Int ?? -1) "
                             + "rawHex=\(operation["_rawHex"] as? String ?? "-") "
                             + "keys=\(operation.keys.sorted())")
                }
                LiqiOperationStore.shared.clear()
                return nil
            }

            eventLog("[MajsoulBridge] ⚠️ \(name) 帶了 operation 但無法建立快照: "
                     + "seat=\(operation["seat"] as? Int ?? -1) "
                     + "list=\(list.count) keys=\(operation.keys.sorted()) "
                     + "rawBytes=\(operation["_rawBytes"] as? Int ?? -1) "
                     + "rawHex=\(operation["_rawHex"] as? String ?? "-") "
                     + "list3=\(String(describing: list.prefix(3)))")
            LiqiOperationStore.shared.clear()
            return nil
        }

        eventLog("[MajsoulBridge] oplist 更新: \(name) seat=\(snapshot.seat) "
                  + "types=\(snapshot.rawTypes) tile=\(contextTile ?? "-") seq=\(snapshot.sequence)")
        return snapshot.sequence
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

        // 分數解不出來就**不開這一局**。
        //
        // 若在 parser 端補 [25000, 25000, 25000, 25000]、這裡再 `?? ` 一次同樣的預設值，
        // 「解析失敗」與「大家都還是起始分」在 Bot 眼裡就完全一樣，而 Mortal 的
        // 決策吃順位與點差——拿假點數推出來的推薦看起來一樣正常，只是錯的。
        // 少一個 start_kyoku 會讓後續事件在 log 裡大聲報錯，那是可以查的；
        // 用假分數打完一整局不會留下任何痕跡。
        guard var scores = data["scores"] as? [Int], scores.count == 3 || scores.count == 4 else {
            recordBlockingFault(site: "ActionNewRound.scores",
                                fieldId: 6,
                                reason: "拿不到本局起始點數（scores=\(data["scores"] ?? "nil")）"
                                    + " → 不發 start_kyoku，這一局不做推薦")
            return nil
        }

        if is3P && scores.count == 3 {
            scores.append(0)
        }

        // 處理寶牌
        var doraMarker = "?"
        if let doraList = data["doras"] as? [String],
           let firstDora = doraList.first,
           let mjaiDora = LiqiTile.mjai(fromMajsoul: firstDora) {
            doras = doraList
            doraMarker = mjaiDora
        }

        // 轉換手牌
        let playerCount = is3P ? 3 : 4
        var tehais = [[String]](repeating: [String](repeating: "?", count: 13), count: playerCount)

        let myTehais = tiles.prefix(13).compactMap { LiqiTile.mjai(fromMajsoul: $0) }
        if seat >= 0 && seat < playerCount {
            tehais[seat] = myTehais.sorted(by: LiqiTile.compare)
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

        // 這一局開起來了 → 只收掉 start_kyoku 系列的常駐錯誤（authGame／座位
        // 若仍未解決，那個 blocking 要留著——Bot 根本沒建，橫幅不能消失）
        faultState.clearBlocking(matchingSitePrefixes: ["ActionNewRound", "GameSnapshot"])

        // 如果配牌有 14 張（親家），添加自摸事件
        let isOya = (seat == ju)
        bridgeLog("[MajsoulBridge] parseNewRound: tiles.count=\(tiles.count), seat=\(seat), ju(oya)=\(ju), isOya=\(isOya)")
        bridgeLog("[MajsoulBridge] parseNewRound: tiles=\(tiles)")
        if tiles.count >= 14 {
            if let tsumoTile = tiles.last,
               let mjaiTile = LiqiTile.mjai(fromMajsoul: tsumoTile) {
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
        let mjaiTile = tile.isEmpty ? "?" : (LiqiTile.mjai(fromMajsoul: tile) ?? "?")

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
              let mjaiTile = LiqiTile.mjai(fromMajsoul: tile) else {
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
                    let mjaiTile = LiqiTile.mjai(fromMajsoul: tile) ?? tile
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
                pai = LiqiTile.mjai(fromMajsoul: firstTile) ?? firstTile
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
                    let mjaiTile = LiqiTile.mjai(fromMajsoul: tile) ?? tile
                    if mjaiTile != pai || consumed.count >= 2 {
                        if consumed.count < 2 {
                            consumed.append(mjaiTile)
                        }
                    }
                }
                // 如果還是不夠，添加所有非 pai 的牌
                if consumed.count < 2 {
                    for tile in tiles {
                        let mjaiTile = LiqiTile.mjai(fromMajsoul: tile) ?? tile
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

        let mjaiTile = LiqiTile.mjai(fromMajsoul: tile) ?? tile
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

    // MARK: - Sync Game Restore

    /// 解析遊戲恢復數據（用於活動模式、斷線重連等）
    /// 重要：與 Akagi 行為一致，不發送額外的 start_game
    /// start_game 應該由 authGame 響應觸發
    private func parseSyncGameRestore(_ gameRestore: [String: Any]) -> [[String: Any]]? {
        var results: [[String: Any]] = []

        bridgeLog("[MajsoulBridge] 解析 gameRestore: \(gameRestore.keys)")

        // ⚠️ 不發送額外的 start_game！authGame 響應已經發送過 start_game。

        // 重連時 start_kyoku 只保留單一來源，避免重複 start_kyoku 破壞局狀態。
        //   - 有 actions：只重放 actions 來發 start_kyoku（其中 ActionNewRound 會發一個），
        //     不由 snapshot(gameState) 另發（兩者都發 → 兩個 start_kyoku）。
        //   - 無 actions：才由 snapshot 的 parseGameState 發 start_kyoku（後備路徑）。
        // kan-dora 補發與 start_kyoku「同一來源、二擇一」，避免雙重 dora 事件：
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

        // 與 `parseNewRound` 同一條規則：解不出點數就不發 start_kyoku。
        // 這條是重連且沒有 actions 可重放時的後備路徑；`GameSnapshot` 的點數在
        // `players[].score`（liqi.json field 9 → PlayerSnapshot field 1）。
        guard var scores = gameState["scores"] as? [Int], scores.count == 3 || scores.count == 4 else {
            recordBlockingFault(site: "GameSnapshot.players.score",
                                fieldId: 9,
                                reason: "重連快照拿不到點數（scores=\(gameState["scores"] ?? "nil")）"
                                    + " → 不發 start_kyoku")
            return nil
        }

        if is3P && scores.count == 3 {
            scores.append(0)
        }

        // 獲取手牌
        let playerCount = is3P ? 3 : 4
        var tehais = [[String]](repeating: [String](repeating: "?", count: 13), count: playerCount)

        if let myTiles = gameState["tiles"] as? [String] {
            let myTehais = myTiles.prefix(13).compactMap { LiqiTile.mjai(fromMajsoul: $0) }
            if seat >= 0 && seat < playerCount {
                tehais[seat] = myTehais.sorted(by: LiqiTile.compare)
            }
        }

        // 處理寶牌：start_kyoku 只帶第一個 dora_marker
        var doraMarker = "?"
        if let doraList = gameState["doras"] as? [String] {
            if let firstDora = doraList.first,
               let mjaiDora = LiqiTile.mjai(fromMajsoul: firstDora) {
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

        // 重連的局面接起來了 → 只收掉 start_kyoku 系列的常駐錯誤
        faultState.clearBlocking(matchingSitePrefixes: ["ActionNewRound", "GameSnapshot"])

        // 後備路徑（無 actions 重連）補發已翻的 kan-dora。
        // start_kyoku 僅帶第一個 dora_marker，doraList 第 2 個(index 1)以後需逐一以 dora 事件補上，
        // 讓 bot 正確計算寶牌。本路徑與 actions 重放互斥（見 parseSyncGameRestore 的
        // 「同一來源、二擇一」註解），不會重複。
        if let doraList = gameState["doras"] as? [String], doraList.count > 1 {
            for extraDora in doraList.dropFirst() {
                if let mjaiExtra = LiqiTile.mjai(fromMajsoul: extraDora) {
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
