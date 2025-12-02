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
class NativeBotController {

    // MARK: - Properties

    /// Bot 實例 (actor)
    private var bot: MortalBot?

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

    /// 最後一次 AI 回傳的動作 (用於自動打牌)
    private(set) var lastAction: MJAIAction?

    /// 最後一次的可用動作
    private(set) var lastCandidates: String?

    // 遊戲狀態追蹤
    private(set) var kyoku: Int = 0
    private(set) var honba: Int = 0
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
        self.playerId = playerId
        self.is3P = is3P

        // 使用內建的 Core ML 模型
        bot = try MortalBot(playerId: playerId, version: 4, useBundledModel: true)

        botLog("[NativeBotController] Bot 創建成功: playerId=\(playerId), is3P=\(is3P)")
    }

    /// 刪除 Bot 實例
    func deleteBot() {
        bot = nil
        resetState()
        botLog("[NativeBotController] Bot 已刪除")
    }

    // MARK: - Event Processing (Typed API)

    /// 處理 MJAI 事件並獲取回應 (強類型異步版本)
    /// ⭐ 使用 MortalSwift 的強類型 API
    /// - Parameter event: MJAI 事件
    /// - Returns: Bot 回應動作，無動作時返回 nil
    func react(event: MJAIEvent) async throws -> MJAIAction? {
        guard let bot = bot else {
            botLog("[NativeBotController] ERROR: Bot not initialized!")
            throw NativeBotError.botNotInitialized
        }

        // 記錄事件類型
        let eventType = event.typeName
        let eventActor = getEventActor(event)
        let isMyMeld = (eventType == "chi" || eventType == "pon" || eventType == "daiminkan") && eventActor == Int(playerId)
        let isMyDahai = eventType == "dahai" && eventActor == Int(playerId)
        let isEndEvent = eventType == "hora" || eventType == "ryukyoku" || eventType == "end_kyoku" || eventType == "end_game"

        botLog("[NativeBotController] Processing typed event: \(eventType), actor: \(eventActor), playerId: \(playerId)")

        // 更新內部狀態
        updateInternalState(from: event)

        // 當自己打牌後，清空推薦
        if isMyDahai {
            lastRecommendations = []
        }

        // 局/遊戲結束時清空推薦
        if isEndEvent {
            lastRecommendations = []
        }

        botLog("[NativeBotController] Calling bot.react with typed event: \(eventType)")

        // ⭐ 呼叫 Bot 處理事件 (強類型 async 版本)
        let action: MJAIAction?
        do {
            action = try await bot.react(event: event)
        } catch {
            botLog("[NativeBotController] ERROR: bot.react threw error: \(error)")
            throw error
        }

        guard let resultAction = action else {
            botLog("[NativeBotController] bot.react returned nil (no action needed)")
            if isMyMeld {
                botLog("[NativeBotController] 自己碰/吃後，需要選擇打牌")
                await updateRecommendationsFromCurrentMask()
            }
            return nil
        }

        botLog("[NativeBotController] bot.react returned action: \(resultAction.typeName)")

        // 更新推薦列表
        await updateRecommendations()

        // ⭐ 儲存最後動作供自動打牌使用
        self.lastAction = resultAction

        return resultAction
    }

    /// 批量處理多個 MJAI 事件 (強類型異步版本)
    func react(events: [MJAIEvent]) async throws -> MJAIAction? {
        var lastAction: MJAIAction?
        for event in events {
            if let action = try await react(event: event) {
                lastAction = action
            }
        }
        return lastAction
    }

    /// 獲取事件的 actor
    private func getEventActor(_ event: MJAIEvent) -> Int {
        switch event {
        case .tsumo(let e): return e.actor
        case .dahai(let e): return e.actor
        case .reach(let e): return e.actor
        case .reachAccepted(let e): return e.actor
        case .chi(let e): return e.actor
        case .pon(let e): return e.actor
        case .daiminkan(let e): return e.actor
        case .ankan(let e): return e.actor
        case .kakan(let e): return e.actor
        case .nukidora(let e): return e.actor
        case .hora(let e): return e.actor
        default: return -1
        }
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
        botLog("[NativeBotController] Bot returned action, updated recommendations: \(lastRecommendations.count) items")

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

    // MARK: - State Management (Typed API)

    /// 更新內部狀態 (強類型版本)
    private func updateInternalState(from event: MJAIEvent) {
        switch event {
        case .startGame(let e):
            handleStartGame(e)

        case .startKyoku(let e):
            handleStartKyoku(e)

        case .tsumo(let e):
            handleTsumo(e)

        case .dahai(let e):
            handleDahai(e)

        case .reach, .reachAccepted:
            botLog("[NativeBotController] reach/reach_accepted event")
            break

        case .chi(let e):
            handleMeld(consumed: e.consumed)

        case .pon(let e):
            handleMeld(consumed: e.consumed)

        case .daiminkan(let e):
            handleMeld(consumed: e.consumed)

        case .ankan(let e):
            handleMeld(consumed: e.consumed)

        case .kakan(let e):
            handleMeld(consumed: e.consumed)

        case .dora(let e):
            doraMarkers.append(e.doraMarker)

        case .hora, .ryukyoku, .endKyoku:
            handleEndKyoku()

        case .endGame:
            handleEndGame()

        case .nukidora:
            break
        }
    }

    private func handleStartGame(_ event: StartGameEvent) {
        kyoku = 0
        honba = 0
        scores = [25000, 25000, 25000, 25000]
        is3P = event.names.count == 3
    }

    private func handleStartKyoku(_ event: StartKyokuEvent) {
        botLog("[NativeBotController] handleStartKyoku (typed)")

        kyoku = event.kyoku
        honba = event.honba
        bakazeWind = event.bakaze
        scores = event.scores

        // 計算自風
        let playerCount = is3P ? 3 : 4
        let jikazeIndex = (Int(playerId) - ((kyoku - 1) % playerCount) + playerCount) % playerCount
        jikazeWind = Wind.fromIndex(jikazeIndex) ?? .east

        // 更新寶牌
        doraMarkers = [event.doraMarker]

        // 更新手牌
        if Int(playerId) < event.tehais.count {
            tehai = event.tehais[Int(playerId)].filter { $0 != .unknown }
            botLog("[NativeBotController] Set tehai to: \(tehai.map { $0.mjaiString })")
        }

        tsumo = nil
    }

    private func handleTsumo(_ event: TsumoEvent) {
        guard event.actor == Int(playerId) else { return }

        tsumo = event.pai
        canDiscard = true
        botLog("[NativeBotController] handleTsumo: my tsumo pai=\(event.pai.mjaiString)")
    }

    private func handleDahai(_ event: DahaiEvent) {
        guard event.actor == Int(playerId) else { return }

        let pai = event.pai

        // 從手牌中移除打出的牌
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

    private func handleMeld(consumed: [Tile]) {
        // 從手牌中移除 consumed 的牌
        for tile in consumed {
            if let index = tehai.firstIndex(of: tile) {
                tehai.remove(at: index)
            }
        }
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
        scores = [25000, 25000, 25000, 25000]

        if let names = event["names"] as? [String] {
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
        if let b = event["bakaze"] as? String {
            bakazeWind = Wind(rawValue: b) ?? .east
        }

        botLog("[NativeBotController] start_kyoku: bakaze=\(bakaze), kyoku=\(kyoku), honba=\(honba)")

        // 計算自風
        let playerCount = is3P ? 3 : 4
        let jikazeIndex = (Int(playerId) - (kyoku % playerCount) + playerCount) % playerCount
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

        // 解析 mask 來判斷可用動作
        canDiscard = mask.prefix(37).contains(where: { $0 == 1 })
        canRiichi = mask.count > MahjongAction.riichi.rawValue && mask[MahjongAction.riichi.rawValue] == 1
        canChi = [MahjongAction.chiLow, .chiMid, .chiHigh].contains(where: { mask.count > $0.rawValue && mask[$0.rawValue] == 1 })
        canPon = mask.count > MahjongAction.pon.rawValue && mask[MahjongAction.pon.rawValue] == 1
        canKan = mask.count > MahjongAction.kan.rawValue && mask[MahjongAction.kan.rawValue] == 1
        canAgari = mask.count > MahjongAction.hora.rawValue && mask[MahjongAction.hora.rawValue] == 1

        // ⭐ 儲存候選動作 (await 因為是 actor)
        lastCandidates = await bot.getCandidates()
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

            // 根據手牌生成可打牌的 mask
            mask = [UInt8](repeating: 0, count: MahjongAction.allCases.count)

            // 遍歷手牌，標記可以打的牌
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

        // ⭐ 嘗試獲取概率（如果 Bot 已經計算過）(await 因為是 actor)
        var probs = await bot.getLastProbs()

        // 如果沒有有效概率，使用均勻分佈
        let hasValidProbs = probs.contains(where: { $0 > 0 })
        let currentValidCount = mask.filter { $0 == 1 }.count

        if !hasValidProbs || currentValidCount != probs.filter({ $0 > 0 }).count {
            let uniformProb = Float(1.0) / Float(currentValidCount)
            probs = [Float](repeating: 0, count: MahjongAction.allCases.count)
            for (index, isAvailable) in mask.enumerated() where isAvailable == 1 {
                if index < probs.count {
                    probs[index] = uniformProb
                }
            }
            botLog("[NativeBotController] Using uniform probabilities for \(currentValidCount) actions")
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
        botLog("[NativeBotController] Generated \(lastRecommendations.count) recommendations after meld")
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

    private func actionIndexToRecommendation(_ index: Int, probability: Double) -> Recommendation? {
        guard let action = MahjongAction(rawValue: index) else { return nil }

        switch action {
        case .discard1m, .discard2m, .discard3m, .discard4m, .discard5m,
             .discard6m, .discard7m, .discard8m, .discard9m:
            let num = index + 1
            return Recommendation(tile: "\(num)m", probability: probability, actionType: .discard)

        case .discard1p, .discard2p, .discard3p, .discard4p, .discard5p,
             .discard6p, .discard7p, .discard8p, .discard9p:
            let num = index - 8
            return Recommendation(tile: "\(num)p", probability: probability, actionType: .discard)

        case .discard1s, .discard2s, .discard3s, .discard4s, .discard5s,
             .discard6s, .discard7s, .discard8s, .discard9s:
            let num = index - 17
            return Recommendation(tile: "\(num)s", probability: probability, actionType: .discard)

        case .discardEast:
            return Recommendation(tile: "E", probability: probability, actionType: .discard)
        case .discardSouth:
            return Recommendation(tile: "S", probability: probability, actionType: .discard)
        case .discardWest:
            return Recommendation(tile: "W", probability: probability, actionType: .discard)
        case .discardNorth:
            return Recommendation(tile: "N", probability: probability, actionType: .discard)
        case .discardWhite:
            return Recommendation(tile: "P", probability: probability, actionType: .discard)
        case .discardGreen:
            return Recommendation(tile: "F", probability: probability, actionType: .discard)
        case .discardRed:
            return Recommendation(tile: "C", probability: probability, actionType: .discard)

        case .riichi:
            return Recommendation(tile: "reach", probability: probability, actionType: .riichi)
        case .chiLow:
            // ⭐ 存储吃的类型在 label 中：chi_0 表示第一种吃法
            return Recommendation(tile: "chi_0", probability: probability, actionType: .chi)
        case .chiMid:
            return Recommendation(tile: "chi_1", probability: probability, actionType: .chi)
        case .chiHigh:
            return Recommendation(tile: "chi_2", probability: probability, actionType: .chi)
        case .pon:
            return Recommendation(tile: "pon", probability: probability, actionType: .pon)
        case .kan:
            return Recommendation(tile: "kan", probability: probability, actionType: .kan)
        case .hora:
            return Recommendation(tile: "hora", probability: probability, actionType: .hora)
        case .pass:
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
            kyotaku: 0,  // TODO: 追蹤供託
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
            modelName: is3P ? "mortal3p" : "mortal",
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
