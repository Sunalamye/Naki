//
//  NativeBotController.swift
//  akagi
//
//  Created by Suoie on 2025/11/30.
//  原生 Mortal Bot 控制器 - 使用 MortalSwift 進行本地 AI 推理
//  Updated: 2025/12/01 - 使用 MortalSwift 強類型 API
//

import Foundation
import MortalSwift

// MARK: - Native Bot Controller

/// 原生 Bot 控制器，使用 MortalSwift 進行 Core ML 推理
/// ⭐ 現在 MortalBot 是 actor，所有方法都需要 async
/// ⭐ 支援強類型 MJAIEvent/MJAIAction API
/// ⭐ #2: 標為 @MainActor —— 可變狀態（tehai/tsumo/lastRecommendations…）在 MainActor 隔離，
///        消除呼叫端（WebViewModel/NakiWebCoordinator 皆 @MainActor）的資料競態。
///        heavy 的 Core ML 推理仍在 MortalBot actor 內 off-main，不受此隔離影響。
@MainActor
class NativeBotController {

    // MARK: - Properties

    /// Bot 實例 (actor)
    private var bot: MortalBot?

    /// #2: 世代序號（generation token）。每次 createBot/deleteBot 遞增，用於使 inflight 的
    /// react 結果失效：react 在 `await bot.react` 暫停期間若換了 bot（start_game / 重連），
    /// 恢復後檢查世代不符即丟棄本次結果，避免舊局的推論污染新局。
    private var generation = 0

    /// 玩家 ID (0-3)
    private(set) var playerId: UInt8 = 0

    /// Bot 是否已初始化
    var isInitialized: Bool { bot != nil }

    /// 是否為 3P 模式
    private(set) var is3P: Bool = false

    /// 手牌狀態 (強類型)
    private(set) var tehai: [Tile] = []

    /// 手牌狀態 (MJAI 字串格式，保持兼容性)
    var tehaiMjai: [String] {
        tehai.map { $0.mjaiString }
    }

    /// 自摸牌 (強類型)
    private(set) var tsumo: Tile?

    /// 自摸牌 (MJAI 字串格式，保持兼容性)
    var lastTsumo: String? {
        tsumo?.mjaiString
    }

    /// 最後一次的推薦列表
    private(set) var lastRecommendations: [Recommendation] = []

    /// 最後一次的可用動作
    private(set) var lastCandidates: String?

    // 遊戲狀態追蹤
    private(set) var kyoku: Int = 0
    private(set) var honba: Int = 0
    /// 供託（立直棒數），來自 start_kyoku 事件的 kyotaku 欄位
    private(set) var kyotaku: Int = 0
    private(set) var bakazeWind: Wind = .east
    private(set) var jikazeWind: Wind = .east
    private(set) var scores: [Int] = [25000, 25000, 25000, 25000]
    private(set) var doraMarkers: [Tile] = []

    /// 場風 (MJAI 字串格式，保持兼容性)
    var bakaze: String { bakazeWind.rawValue }
    /// 自風 (MJAI 字串格式，保持兼容性)
    var jikaze: String { jikazeWind.rawValue }
    /// 寶牌指示牌 (MJAI 字串格式，保持兼容性)
    var doraIndicators: [String] { doraMarkers.map { $0.mjaiString } }

    // 可用動作
    private(set) var canDiscard: Bool = false
    private(set) var canRiichi: Bool = false
    private(set) var canChi: Bool = false
    private(set) var canPon: Bool = false
    private(set) var canKan: Bool = false
    private(set) var canAgari: Bool = false

    // MARK: - Initialization

    init() {}

    /// 創建新的 Bot 實例
    /// - Parameters:
    ///   - playerId: 玩家座位 (0-3)
    ///   - is3P: 是否為三麻模式
    func createBot(playerId: UInt8, is3P: Bool = false) throws {
        // #2: 遞增世代，使任何 inflight 的舊 react 結果失效
        generation += 1
        self.playerId = playerId
        self.is3P = is3P

        // 使用內建的 Core ML 模型
        // MortalSwift v0.3.0 使用 Int 作為 playerId
        // ⚠️ #3 已知風險：MortalBot 建構子不吃 sanma/is3P，且僅內建單一四麻模型
        //    (bundledModelURL = "mortal", version 4, obs 1012ch)。is3P 只用於本控制器狀態
        //    （GameState.is3P / 模型名稱標籤 / 自風 playerCount），實際推論仍為四麻。
        //    真三麻需 MortalSwift 提供三麻模型與 sanma 建構參數。
        bot = try MortalBot(playerId: Int(playerId), version: 4, useBundledModel: true)

        botLog("[NativeBotController] Bot 創建成功: playerId=\(playerId), is3P=\(is3P), gen=\(generation)")
    }

    /// 刪除 Bot 實例
    func deleteBot() {
        // #2: 遞增世代，使任何 inflight 的舊 react 結果失效
        generation += 1
        bot = nil
        resetState()
        botLog("[NativeBotController] Bot 已刪除, gen=\(generation)")
    }

    // MARK: - Event Processing (Dictionary API - Legacy)

    /// 處理 MJAI 事件並獲取回應 (字典異步版本，保持兼容性)
    /// ⭐ MortalBot 是 actor，使用 async react() 自動在背景執行推理
    /// - Parameter event: MJAI 事件字典
    /// - Returns: Bot 回應字典，無動作時返回 nil
    func react(event: [String: Any]) async throws -> [String: Any]? {
        guard let bot = bot else {
            botLog("[NativeBotController] ERROR: Bot not initialized!")
            throw NativeBotError.botNotInitialized
        }

        // #2: 進入時捕獲當前世代。`await bot.react` 是唯一暫停點，暫停期間若換了 bot
        //     （deleteBot/createBot 皆遞增 generation），恢復後世代不符 → 丟棄本次結果。
        let gen = generation

        // 記錄事件類型，用於判斷是否需要更新推薦
        let eventType = event["type"] as? String ?? ""
        let eventActor = event["actor"] as? Int ?? -1
        let isMyMeld = (eventType == "chi" || eventType == "pon" || eventType == "daiminkan") && eventActor == Int(playerId)
        let isMyDahai = eventType == "dahai" && eventActor == Int(playerId)
        let isEndEvent = eventType == "hora" || eventType == "ryukyoku" || eventType == "end_kyoku" || eventType == "end_game"

        botLog("[NativeBotController] Processing event: \(eventType), actor: \(eventActor), playerId: \(playerId)")

        // 更新內部狀態
        updateInternalState(from: event)

        // 當自己打牌後，清空推薦（用戶已經做了決定）
        if isMyDahai {
            lastRecommendations = []
            botLog("[NativeBotController] 自己打牌後，清空推薦")
        }

        // 局/遊戲結束時清空推薦
        if isEndEvent {
            lastRecommendations = []
            botLog("[NativeBotController] 局/遊戲結束，清空推薦")
        }

        // 轉換為 JSON 字串
        let jsonData = try JSONSerialization.data(withJSONObject: event)
        guard let jsonString = String(data: jsonData, encoding: .utf8) else {
            botLog("[NativeBotController] ERROR: Failed to convert event to JSON")
            throw NativeBotError.invalidEvent
        }

        botLog("[NativeBotController] Calling bot.react with: \(eventType)")

        // ⭐ 呼叫 Bot 處理事件 (async 版本，自動在背景執行 Core ML 推理)
        let responseString: String?
        do {
            responseString = try await bot.react(mjaiEvent: jsonString)
        } catch {
            botLog("[NativeBotController] ERROR: bot.react threw error: \(error)")
            throw error
        }

        // #2: `await bot.react` 已返回。若期間換了 bot（start_game / 重連 deleteBot+createBot），
        //     世代不符 → 直接丟棄本次結果，不寫回任何共享狀態、也不讀「新」bot 的 mask/推薦，
        //     避免舊局 inflight 推論污染新局。
        guard gen == generation else {
            botLog("[NativeBotController] 丟棄過期 react 結果 (gen=\(gen) != 現世代=\(generation))，不污染新局")
            return nil
        }

        guard let responseStr = responseString else {
            botLog("[NativeBotController] bot.react returned nil (no action needed)")
            // 無需動作時，如果是自己的碰/吃，仍需更新推薦（碰/吃後需要打牌）
            if isMyMeld {
                botLog("[NativeBotController] 自己碰/吃後，需要選擇打牌")
                // 碰/吃後 Bot 內部狀態已更新，mask 應該包含可打的牌
                // 使用當前 mask 來更新推薦
                await updateRecommendationsFromCurrentMask()
            }
            // 注意：不再清空 lastRecommendations
            // 讓推薦保持到下一次需要做決定時
            // 只有在新的推薦產生時才會更新
            return nil
        }

        botLog("[NativeBotController] bot.react returned: \(responseStr)")

        // 解析回應
        guard let responseData = responseStr.data(using: .utf8),
              let response = try JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            botLog("[NativeBotController] ERROR: Failed to parse response JSON")
            lastRecommendations = []
            return nil
        }

        // 更新推薦列表（Bot 已選擇動作，顯示所有可用選項及其機率）
        await updateRecommendations()
        // 只記筆數不足以事後判斷「Mortal 為什麼沒選和牌」——必須看得到它到底有哪些選項，
        // 以及協定層同時給了哪些可用操作。兩者不一致就是 Mortal 的狀態與實際牌局脫節。
        let recSummary = lastRecommendations.prefix(6)
            .map { "\($0.actionType.rawValue):\($0.displayTile)@\($0.percentageString)" }
            .joined(separator: " ")
        let opsSummary = LiqiOperationStore.shared.latest.map { "\($0.rawTypes)" } ?? "-"
        eventLog("[Bot] Bot returned action, updated recommendations: "
               + "\(lastRecommendations.count) items [\(recSummary)] oplist=\(opsSummary)")

        return response
    }

    /// 批量處理多個 MJAI 事件 (異步版本)
    /// - Parameter events: MJAI 事件陣列
    /// - Returns: 最後一個需要回應的動作
    func react(events: [[String: Any]]) async throws -> [String: Any]? {
        var lastResponse: [String: Any]?

        for event in events {
            if let response = try await react(event: event) {
                lastResponse = response
            }
        }

        return lastResponse
    }

    private func handleEndKyoku() {
        botLog("[NativeBotController] handleEndKyoku (typed)")
        tehai = []
        tsumo = nil
        canDiscard = false
        canRiichi = false
        canChi = false
        canPon = false
        canKan = false
        canAgari = false
    }

    private func handleEndGame() {
        botLog("[NativeBotController] handleEndGame (typed)")
        resetState()
    }

    // MARK: - State Management (Dictionary API - Legacy)

    private func updateInternalState(from event: [String: Any]) {
        guard let type = event["type"] as? String else { return }

        switch type {
        case "start_game":
            handleStartGameDict(event)

        case "start_kyoku":
            handleStartKyokuDict(event)

        case "tsumo":
            handleTsumoDict(event)

        case "dahai":
            handleDahaiDict(event)

        case "reach", "reach_accepted":
            // 立直相關
            botLog("[NativeBotController] reach/reach_accepted event")
            break

        case "chi", "pon", "daiminkan", "kakan", "ankan":
            handleMeldDict(event)

        case "hora", "ryukyoku", "end_kyoku":
            handleEndKyoku()

        case "end_game":
            handleEndGame()

        default:
            break
        }

        // 注意：updateAvailableActions 需要 async，移到 react() 後處理
    }

    private func handleStartGameDict(_ event: [String: Any]) {
        // 重置遊戲狀態
        kyoku = 0
        honba = 0
        kyotaku = 0
        scores = [25000, 25000, 25000, 25000]

        // #3: 優先用 bridge 帶來的 is3P 旗標；否則退回 names 陣列長度判斷。
        //     （createBot 已用 is3P 參數設過，此處只在 react 重放 start_game 時保持一致，不覆蓋為錯值。）
        if let flag = event["is3P"] as? Bool {
            is3P = flag
        } else if let names = event["names"] as? [String] {
            is3P = names.count == 3
        }
    }

    private func handleStartKyokuDict(_ event: [String: Any]) {
        botLog("[NativeBotController] handleStartKyokuDict called")

        if let k = event["kyoku"] as? Int {
            kyoku = k
        }
        if let h = event["honba"] as? Int {
            honba = h
        }
        // #21: 從 start_kyoku 事件持久化供託（bridge parseNewRound/parseGameState 皆帶 kyotaku 欄位）
        if let ky = event["kyotaku"] as? Int {
            kyotaku = ky
        }
        if let b = event["bakaze"] as? String {
            bakazeWind = Wind(rawValue: b) ?? .east
        }

        botLog("[NativeBotController] start_kyoku: bakaze=\(bakaze), kyoku=\(kyoku), honba=\(honba), kyotaku=\(kyotaku)")

        // 計算自風
        // #8: kyoku 為 1-based（oya = kyoku-1），故以 (kyoku - 1) 取模；原式用 kyoku 取模差一。
        let playerCount = is3P ? 3 : 4
        let jikazeIndex = (Int(playerId) - ((kyoku - 1) % playerCount) + playerCount) % playerCount
        jikazeWind = Wind.fromIndex(jikazeIndex) ?? .east

        if let s = event["scores"] as? [Int] {
            scores = s
        }

        if let dora = event["dora_marker"] as? String,
           let tile = Tile(mjaiString: dora) {
            doraMarkers = [tile]
        }

        botLog("[NativeBotController] start_kyoku: playerId=\(playerId)")

        if let tehais = event["tehais"] as? [[String]] {
            botLog("[NativeBotController] tehais count: \(tehais.count)")

            if Int(playerId) < tehais.count {
                tehai = tehais[Int(playerId)].compactMap { Tile(mjaiString: $0) }
                botLog("[NativeBotController] Set tehai to: \(tehaiMjai)")
            } else {
                botLog("[NativeBotController] ERROR: playerId \(playerId) >= tehais.count \(tehais.count)")
            }
        } else {
            botLog("[NativeBotController] ERROR: Failed to cast tehais as [[String]]")
        }

        tsumo = nil
    }

    private func handleTsumoDict(_ event: [String: Any]) {
        guard let actor = event["actor"] as? Int else {
            botLog("[NativeBotController] handleTsumo: no actor in event")
            return
        }

        guard actor == Int(playerId) else {
            return
        }

        guard let pai = event["pai"] as? String,
              let tile = Tile(mjaiString: pai) else {
            botLog("[NativeBotController] handleTsumo: no pai in event for my tsumo!")
            return
        }

        tsumo = tile
        canDiscard = true
        botLog("[NativeBotController] handleTsumo: my tsumo pai=\(pai)")
    }

    private func handleDahaiDict(_ event: [String: Any]) {
        guard let actor = event["actor"] as? Int,
              actor == Int(playerId),
              let paiStr = event["pai"] as? String,
              let pai = Tile(mjaiString: paiStr) else {
            return
        }

        if let t = tsumo, t == pai {
            tsumo = nil
        } else if let index = tehai.firstIndex(of: pai) {
            tehai.remove(at: index)
            if let t = tsumo {
                tehai.append(t)
                tehai.sort { $0.index < $1.index }
                tsumo = nil
            }
        }

        canDiscard = false
    }

    private func handleMeldDict(_ event: [String: Any]) {
        guard let actor = event["actor"] as? Int,
              actor == Int(playerId) else {
            return
        }

        if let consumed = event["consumed"] as? [String] {
            for tileStr in consumed {
                if let tile = Tile(mjaiString: tileStr),
                   let index = tehai.firstIndex(of: tile) {
                    tehai.remove(at: index)
                }
            }
        }
    }

    /// 更新可用動作 (async 因為 MortalBot 是 actor)
    private func updateAvailableActions() async {
        guard let bot = bot else { return }

        // ⭐ 獲取可用動作的 mask (await 因為是 actor)
        let mask = await bot.getMask()

        // 使用 PlayerState.ActionIndex 常量
        typealias AI = PlayerState.ActionIndex

        // 解析 mask 來判斷可用動作
        canDiscard = mask.prefix(AI.discardEnd + 1).contains(where: { $0 == 1 })
        canRiichi = mask.count > AI.riichi && mask[AI.riichi] == 1
        canChi = [AI.chiLow, AI.chiMid, AI.chiHigh].contains(where: { mask.count > $0 && mask[$0] == 1 })
        canPon = mask.count > AI.pon && mask[AI.pon] == 1
        canKan = mask.count > AI.kan && mask[AI.kan] == 1
        canAgari = mask.count > AI.hora && mask[AI.hora] == 1

        // ⭐ 儲存候選動作 (await 因為是 actor) - v0.3.0 使用 getCandidateActions()
        let candidates = await bot.getCandidateActions()
        if let jsonData = try? JSONEncoder().encode(candidates),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            lastCandidates = jsonString
        }
    }

    /// 更新推薦列表 (async 因為 MortalBot 是 actor)
    private func updateRecommendations() async {
        guard let bot = bot else {
            lastRecommendations = []
            return
        }

        // ⭐ 獲取 mask 和機率 (await 因為是 actor)
        // Use getLastMask() which was saved BEFORE the action was committed
        let mask = await bot.getLastMask()
        let probs = await bot.getLastProbs()

        // 建立推薦列表，使用實際機率
        var recommendations: [Recommendation] = []

        for (index, isAvailable) in mask.enumerated() where isAvailable == 1 {
            let probability = index < probs.count ? Double(probs[index]) : 0.0
            if let action = actionIndexToRecommendation(index, probability: probability) {
                recommendations.append(action)
            }
        }

        // 按機率排序（高到低）
        lastRecommendations = recommendations.sorted { $0.probability > $1.probability }
    }

    /// 使用當前 mask 更新推薦（用於碰/吃後，需要打牌的情況）
    /// 這個方法會嘗試執行推理來獲取真正的概率
    private func updateRecommendationsFromCurrentMask() async {
        guard let bot = bot else {
            lastRecommendations = []
            return
        }

        // ⭐ 碰/吃後，libriichi 不會立即返回 RIICHI_ACTION_REQUIRED
        // 需要根據手牌狀態自己生成可打牌的推薦

        // 首先嘗試使用當前 mask
        var mask = await bot.getMask()
        let validCount = mask.filter { $0 == 1 }.count

        botLog("[NativeBotController] updateRecommendationsFromCurrentMask: mask has \(validCount) valid actions")

        // 如果 mask 沒有有效動作，根據手牌生成可打牌 mask
        if validCount == 0 {
            botLog("[NativeBotController] Mask is empty after meld, generating from tehai")

            // 根據手牌生成可打牌的 mask (使用 PlayerState.actionSpace)
            mask = [UInt8](repeating: 0, count: PlayerState.actionSpace)

            // 走訪手牌，標記可以打的牌
            for tile in tehai {
                if let actionIndex = tileToDiscardActionIndex(tile) {
                    mask[actionIndex] = 1
                }
            }

            let newValidCount = mask.filter { $0 == 1 }.count
            botLog("[NativeBotController] Generated mask from tehai with \(newValidCount) valid actions")

            if newValidCount == 0 {
                botLog("[NativeBotController] Still no valid actions, tehai count: \(tehai.count)")
                lastRecommendations = []
                return
            }
        }

        // 對**當前狀態**重新推論。
        //
        // 這裡曾經是「拿 lastProbs，取不到就用均勻分布」。但副露之後 MJAI 不會再送
        // 事件，react 沒被呼叫過，lastProbs 停在副露前那一次——手牌早就變了。
        // 於是實際走的一律是均勻分布那條路，等於「拿 mask 裡第一個合法的牌」，
        // 完全沒有模型參與。使用者的體感是「有時候不會丟最推薦的牌」，
        // 真相是**那時候根本沒有推薦**。
        //
        // 側欄還把它顯示得跟真推薦一模一樣，看不出差別——正是 AUDIT §13
        // 「不能運作又不說」要防的那類問題。
        var probs: [Float] = []
        do {
            _ = try await bot.inferCurrentState()
            probs = await bot.getLastProbs()
            mask = await bot.getLastMask()
        } catch {
            botLog("[NativeBotController] 副露後推論失敗: \(error)")
        }

        let currentValidCount = mask.filter { $0 == 1 }.count
        let hasValidProbs = probs.contains(where: { $0 > 0 })

        if !hasValidProbs {
            // 推論真的失敗才退回均勻分布，而且要在 log 裡講清楚這不是模型的判斷
            guard currentValidCount > 0 else {
                lastRecommendations = []
                return
            }
            let uniformProb = Float(1.0) / Float(currentValidCount)
            probs = [Float](repeating: 0, count: PlayerState.actionSpace)
            for (index, isAvailable) in mask.enumerated() where isAvailable == 1 {
                if index < probs.count { probs[index] = uniformProb }
            }
            eventLog("[Bot] ⚠️ 副露後推論失敗，退回均勻分布 (\(currentValidCount) 個動作)"
                   + "——這批推薦不是模型的判斷")
        }

        // 建立推薦列表
        var recommendations: [Recommendation] = []

        for (index, isAvailable) in mask.enumerated() where isAvailable == 1 {
            let probability = index < probs.count ? Double(probs[index]) : 0.0
            if let action = actionIndexToRecommendation(index, probability: probability) {
                recommendations.append(action)
            }
        }

        // 按機率排序（高到低）
        lastRecommendations = recommendations.sorted { $0.probability > $1.probability }
        let summary = lastRecommendations.prefix(6)
            .map { "\($0.actionType.rawValue):\($0.displayTile)@\($0.percentageString)" }
            .joined(separator: " ")
        eventLog("[Bot] 副露後推論: \(lastRecommendations.count) items [\(summary)]")
    }

    /// 將 Tile 轉換為對應的打牌動作索引
    private func tileToDiscardActionIndex(_ tile: Tile) -> Int? {
        switch tile {
        case .man(let num, _): return num - 1           // 0-8 for 1m-9m
        case .pin(let num, _): return 9 + (num - 1)     // 9-17 for 1p-9p
        case .sou(let num, _): return 18 + (num - 1)    // 18-26 for 1s-9s
        case .east: return 27
        case .south: return 28
        case .west: return 29
        case .north: return 30
        case .white: return 31
        case .green: return 32
        case .red: return 33
        case .unknown: return nil
        }
    }

    /// 判斷丟 5 牌時是否應該丟紅寶牌
    /// 邏輯：如果手牌中只有紅寶牌（沒有普通的 5），才丟紅寶牌
    /// 如果有普通的 5，優先丟普通的（保留紅寶牌的價值）
    private func shouldDiscardRedDora(suit: String) -> Bool {
        // 收集手牌 + 自摸牌中所有指定花色的 5
        var allTiles = tehai
        if let t = tsumo { allTiles.append(t) }

        var hasRed = false
        var hasNormal = false

        for tile in allTiles {
            switch (tile, suit) {
            case (.man(5, let red), "m"):
                if red { hasRed = true } else { hasNormal = true }
            case (.pin(5, let red), "p"):
                if red { hasRed = true } else { hasNormal = true }
            case (.sou(5, let red), "s"):
                if red { hasRed = true } else { hasNormal = true }
            default:
                continue
            }
        }

        // 只有在「有紅寶牌」且「沒有普通牌」的情況下才丟紅寶牌
        return hasRed && !hasNormal
    }

    private func actionIndexToRecommendation(_ index: Int, probability: Double) -> Recommendation? {
        typealias AI = PlayerState.ActionIndex

        // 打牌動作 (0-33)
        if index >= AI.discardStart && index <= AI.discardEnd {
            // 萬子 (0-8 -> 1m-9m)
            if index <= 8 {
                let num = index + 1
                if num == 5 {
                    let tileStr = shouldDiscardRedDora(suit: "m") ? "5mr" : "5m"
                    return Recommendation(tile: tileStr, probability: probability, actionType: .discard)
                }
                return Recommendation(tile: "\(num)m", probability: probability, actionType: .discard)
            }
            // 筒子 (9-17 -> 1p-9p)
            else if index <= 17 {
                let num = index - 8
                if num == 5 {
                    let tileStr = shouldDiscardRedDora(suit: "p") ? "5pr" : "5p"
                    return Recommendation(tile: tileStr, probability: probability, actionType: .discard)
                }
                return Recommendation(tile: "\(num)p", probability: probability, actionType: .discard)
            }
            // 索子 (18-26 -> 1s-9s)
            else if index <= 26 {
                let num = index - 17
                if num == 5 {
                    let tileStr = shouldDiscardRedDora(suit: "s") ? "5sr" : "5s"
                    return Recommendation(tile: tileStr, probability: probability, actionType: .discard)
                }
                return Recommendation(tile: "\(num)s", probability: probability, actionType: .discard)
            }
            // 字牌 (27-33 -> E/S/W/N/P/F/C)
            else {
                let honorTiles = ["E", "S", "W", "N", "P", "F", "C"]
                let honorIndex = index - 27
                if honorIndex < honorTiles.count {
                    return Recommendation(tile: honorTiles[honorIndex], probability: probability, actionType: .discard)
                }
            }
        }

        // 其他動作
        switch index {
        case AI.riichi:
            return Recommendation(tile: "reach", probability: probability, actionType: .riichi)
        case AI.chiLow:
            return Recommendation(tile: "chi_0", probability: probability, actionType: .chi)
        case AI.chiMid:
            return Recommendation(tile: "chi_1", probability: probability, actionType: .chi)
        case AI.chiHigh:
            return Recommendation(tile: "chi_2", probability: probability, actionType: .chi)
        case AI.pon:
            return Recommendation(tile: "pon", probability: probability, actionType: .pon)
        case AI.kan:
            return Recommendation(tile: "kan", probability: probability, actionType: .kan)
        case AI.hora:
            return Recommendation(tile: "hora", probability: probability, actionType: .hora)
        case AI.pass:
            return Recommendation(tile: "none", probability: probability, actionType: .none)
        default:
            return nil
        }
    }

    private func resetState() {
        playerId = 0
        is3P = false
        tehai = []
        tsumo = nil
        lastRecommendations = []
        lastCandidates = nil
        kyoku = 0
        honba = 0
        kyotaku = 0
        bakazeWind = .east
        jikazeWind = .east
        scores = [25000, 25000, 25000, 25000]
        doraMarkers = []
        canDiscard = false
        canRiichi = false
        canChi = false
        canPon = false
        canKan = false
        canAgari = false
    }

    // MARK: - State Export

    /// 獲取當前遊戲狀態
    var gameState: GameState {
        GameState(
            kyoku: kyoku,
            honba: honba,
            kyotaku: kyotaku,
            bakaze: bakazeWind,
            jikaze: jikazeWind,
            scores: scores,
            playerId: Int(playerId),
            doraMarkers: doraMarkers,
            is3P: is3P
        )
    }

    /// 獲取當前 Bot 狀態
    var botState: BotStatus {
        BotStatus(
            isActive: isInitialized,
            // 內建模型只有四麻一份，modelName 必須反映**實際載入的是哪個**，
            // 不能因為對局是三麻就標成 mortal3p——那會讓 UI 宣稱有三麻模型
            modelName: "mortal",
            playerId: Int(playerId),
            is3P: is3P,
            canDiscard: canDiscard,
            canRiichi: canRiichi,
            canChi: canChi,
            canPon: canPon,
            canKan: canKan,
            canAgari: canAgari
        )
    }
}

// MARK: - Errors

enum NativeBotError: Error, LocalizedError {
    case botNotInitialized
    case invalidEvent
    case reactionFailed(String)

    var errorDescription: String? {
        switch self {
        case .botNotInitialized:
            return "Bot 尚未初始化"
        case .invalidEvent:
            return "無效的事件格式"
        case .reactionFailed(let message):
            return "Bot 處理失敗: \(message)"
        }
    }
}
