//
//  BundledCoreMLBot.swift
//  Naki
//
//  內建引擎：MortalSwift + Core ML。自 `NativeBotController` 抽出
//  （2026-08-05 protocol 重構），推論與推薦生成邏輯原樣搬移——
//  replay 決策指紋（`ReplayFingerprintTests`）鎖住「搬移沒有改變決策」。
//
//  持有 MortalBot 專屬 API（`getLastMask`/`getLastProbs`/`inferCurrentState`）
//  的只剩這一個檔案；`NativeBotController` 只認得 `any MahjongBot`。
//

import Foundation
import MortalSwift

/// 內建的本機推論引擎。
@MainActor
final class BundledCoreMLBot: MahjongBot {

    /// MortalSwift bot（actor；Core ML 推理在它裡面 off-main 執行）
    private let bot: MortalBot

    private let playerId: UInt8
    private let is3P: Bool

    /// mask 索引 → 推薦的解碼器（紅五判斷經 handProvider 讀 controller 的手牌）
    private let mapper: MortalActionMapper

    /// - Parameter hand: 讀當前手牌的 closure。手牌是遊戲狀態，權威在
    ///   `NativeBotController`（它在呼叫 `react` **之前**先更新手牌，
    ///   所以這裡讀到的一定是本事件之後的狀態——與抽出前的順序一致）。
    init(playerId: UInt8, is3P: Bool,
         hand: @escaping () -> (tehai: [Tile], tsumo: Tile?)) throws {
        // ⚠️ #3 已知風險：MortalBot 建構子不吃 sanma/is3P，且僅內建單一四麻模型
        //    (bundledModelURL = "mortal", version 4, obs 1012ch)。三麻仍送進四麻
        //    model；`identity.supports3P` 如實回 false。
        self.bot = try MortalBot(playerId: Int(playerId), version: 4, useBundledModel: true)
        self.playerId = playerId
        self.is3P = is3P
        self.mapper = MortalActionMapper(hand: hand)
    }

    /// `@MainActor` class 在 NakiTests host 釋放會 SIGABRT（見 CLAUDE.md「專案結構的坑」）
    nonisolated deinit {}

    var identity: BotIdentity {
        BotIdentity(name: "mortal-bundled",
                    displayName: "Mortal (4P)",
                    supports3P: false,
                    isLocal: true)
    }

    /// 每局由 controller 重建整個引擎（Akagi 同款：熱換模型＝砍掉重建），
    /// 沒有跨局狀態要清。
    func reset() {}

    // MARK: - React

    func react(events: [[String: Any]]) async throws -> BotReaction? {
        var last: BotReaction?
        for event in events {
            if let reaction = try await react(event: event) {
                last = reaction
            }
        }
        return last
    }

    private func react(event: [String: Any]) async throws -> BotReaction? {
        let eventType = event["type"] as? String ?? ""
        let eventActor = event["actor"] as? Int ?? -1
        let isMyMeld = (eventType == "chi" || eventType == "pon" || eventType == "daiminkan")
            && eventActor == Int(playerId)

        // 轉換為 JSON 字串
        let jsonData = try JSONSerialization.data(withJSONObject: event)
        guard let jsonString = String(data: jsonData, encoding: .utf8) else {
            botLog("[BundledCoreMLBot] ERROR: Failed to convert event to JSON")
            throw NativeBotError.invalidEvent
        }

        // ⭐ 呼叫 Bot 處理事件 (async 版本，自動在背景執行 Core ML 推理)
        let responseString: String?
        do {
            responseString = try await bot.react(mjaiEvent: jsonString)
        } catch {
            botLog("[BundledCoreMLBot] ERROR: bot.react threw error: \(error)")
            throw error
        }

        guard let responseStr = responseString else {
            // 無需動作時，如果是自己的碰/吃，仍需更新推薦（碰/吃後需要打牌）
            if isMyMeld {
                botLog("[BundledCoreMLBot] 自己碰/吃後，需要選擇打牌")
                let recommendations = await recommendationsFromCurrentMask()
                return BotReaction(action: nil, recommendations: recommendations,
                                   source: "local")
            }
            // 非決策點：不刷新、不清空，畫面保持現狀
            return nil
        }

        botLog("[BundledCoreMLBot] bot.react returned: \(responseStr)")

        // 解析回應
        guard let responseData = responseStr.data(using: .utf8),
              let response = try JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            botLog("[BundledCoreMLBot] ERROR: Failed to parse response JSON")
            // 防禦路徑（MortalBot 輸出必為合法 JSON）：以空推薦清空畫面，
            // 對應抽出前「清 lastRecommendations、回 nil」的語意
            return BotReaction(action: nil, recommendations: [], source: "local")
        }

        // 更新推薦列表（Bot 已選擇動作，顯示所有可用選項及其機率）
        let recommendations = await recommendationsAfterAction()
        return BotReaction(action: response, recommendations: recommendations,
                           source: "local")
    }

    // MARK: - 推薦生成（自 NativeBotController 原樣搬移）

    /// 動作後的推薦列 (async 因為 MortalBot 是 actor)
    private func recommendationsAfterAction() async -> [Recommendation] {
        // ⭐ 獲取 mask 和機率 (await 因為是 actor)
        // Use getLastMask() which was saved BEFORE the action was committed
        let mask = await bot.getLastMask()
        let probs = await bot.getLastProbs()

        // 建立推薦列表，使用實際機率
        var recommendations: [Recommendation] = []

        for (index, isAvailable) in mask.enumerated() where isAvailable == 1 {
            let probability = index < probs.count ? Double(probs[index]) : 0.0
            if let action = mapper.actionIndexToRecommendation(index, probability: probability) {
                recommendations.append(action)
            }
        }

        // 按機率排序（高到低）
        return recommendations.sorted { $0.probability > $1.probability }
    }

    /// 使用當前 mask 更新推薦（用於碰/吃後，需要打牌的情況）
    /// 這個方法會嘗試執行推理來獲取真正的概率
    private func recommendationsFromCurrentMask() async -> [Recommendation] {
        // ⭐ 碰/吃後，libriichi 不會立即返回 RIICHI_ACTION_REQUIRED
        // 需要根據手牌狀態自己生成可打牌的推薦

        // 首先嘗試使用當前 mask
        var mask = await bot.getMask()
        let validCount = mask.filter { $0 == 1 }.count

        botLog("[BundledCoreMLBot] recommendationsFromCurrentMask: mask has \(validCount) valid actions")

        // 如果 mask 沒有有效動作，根據手牌生成可打牌 mask
        if validCount == 0 {
            botLog("[BundledCoreMLBot] Mask is empty after meld, generating from tehai")

            // 根據手牌生成可打牌的 mask (使用 PlayerState.actionSpace)
            mask = [UInt8](repeating: 0, count: PlayerState.actionSpace)

            // 走訪手牌，標記可以打的牌
            let (tehai, _) = mapper.hand()
            for tile in tehai {
                if let actionIndex = mapper.discardActionIndex(for: tile) {
                    mask[actionIndex] = 1
                }
            }

            let newValidCount = mask.filter { $0 == 1 }.count
            botLog("[BundledCoreMLBot] Generated mask from tehai with \(newValidCount) valid actions")

            if newValidCount == 0 {
                botLog("[BundledCoreMLBot] Still no valid actions, tehai count: \(tehai.count)")
                return []
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
            botLog("[BundledCoreMLBot] 副露後推論失敗: \(error)")
        }

        let currentValidCount = mask.filter { $0 == 1 }.count
        let hasValidProbs = probs.contains(where: { $0 > 0 })

        if !hasValidProbs {
            // 推論真的失敗才退回均勻分布，而且要在 log 裡講清楚這不是模型的判斷
            guard currentValidCount > 0 else {
                return []
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
            if let action = mapper.actionIndexToRecommendation(index, probability: probability) {
                recommendations.append(action)
            }
        }

        // 按機率排序（高到低）
        let sorted = recommendations.sorted { $0.probability > $1.probability }
        let summary = sorted.prefix(6)
            .map { "\($0.actionType.rawValue):\($0.displayTile)@\($0.percentageString)" }
            .joined(separator: " ")
        eventLog("[Bot] 副露後推論: \(sorted.count) items [\(summary)]")
        return sorted
    }
}
