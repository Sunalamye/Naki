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

    /// mask 索引 → 推薦的解碼器（紅五判斷經 handProvider 讀 controller 的手牌）
    private let mapper: MortalActionMapper

    /// - Parameter hand: 讀當前手牌的 closure。手牌是遊戲狀態，權威在
    ///   `NativeBotController`（它在呼叫 `react` **之前**先更新手牌，
    ///   所以這裡讀到的一定是本事件之後的狀態——與抽出前的順序一致）。
    init(playerId: UInt8,
         hand: @escaping () -> (tehai: [Tile], tsumo: Tile?)) throws {
        // MortalBot 建構子不吃 sanma，且僅內建單一四麻模型
        // (bundledModelURL = "mortal", version 4, obs 1012ch)；`identity.supports3P` 如實回 false。
        // 三麻由 `AkagiSanmaBot` 處理，不會建這個引擎。
        self.bot = try MortalBot(playerId: Int(playerId), version: 4, useBundledModel: true)
        self.playerId = playerId
        self.mapper = MortalActionMapper(hand: hand)
    }

    /// `@MainActor` class 在 NakiTests host 釋放會 SIGABRT（見 CLAUDE.md「專案結構的坑」）
    nonisolated deinit {}

    /// 模型是否已確認載入（只驗一次，之後不再付 actor hop）
    private var modelVerified = false

    /// 確認 bundled Core ML 模型真的在。
    ///
    /// `MortalBot` 的建構子在模型檔缺失時**不會 throw**：它建出一個
    /// `hasModel == false` 的實例，而那個實例的推論退化成「選 mask 裡第一個合法
    /// 動作」——同時 `identity.isLocal` 照舊為 true、`/bot/status` 照舊回 `local`、
    /// 側欄照舊顯示推薦。看起來一樣，但那不是決策。
    ///
    /// 這是 AUDIT §14.5「副露後均勻分布假推薦」的同一個形狀，換了觸發條件。
    ///
    /// 檢查放在這裡而不是 `init`：`hasModel` 是 actor-isolated（`MortalBot` 是 actor），
    /// 而 `init` 與它的呼叫端 `NativeBotController.createBot` 都是同步的。第一次
    /// `react` 是最早能 await 到它的地方。
    private func verifyModelLoaded() async throws {
        guard !modelVerified else { return }
        guard await bot.hasModel else { throw NativeBotError.bundledModelMissing }
        modelVerified = true
    }

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
        try await verifyModelLoaded()

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
                // forced 不在這條路量：這不是 `react` 決策當下的合法集快照
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
        var (recommendations, legalCount) = await recommendationsAfterAction()
        if response["type"] as? String == "reach" {
            recommendations = Self.mergingDeclaration(await recommendationsAfterReach(),
                                                      into: recommendations)
        }
        return BotReaction(action: response, recommendations: recommendations,
                           source: "local", forced: legalCount == 1)
    }

    // MARK: - 推薦生成（自 NativeBotController 原樣搬移）

    /// 動作後的推薦列與完整合法動作數 (async 因為 MortalBot 是 actor)
    private func recommendationsAfterAction() async -> (list: [Recommendation],
                                                        legalCount: Int) {
        // ⭐ 獲取 mask 和機率 (await 因為是 actor)
        // Use getLastMask() which was saved BEFORE the action was committed
        let mask = await bot.getLastMask()
        let probs = await bot.getLastProbs()

        // legalCount 量在截斷前的 mask 上，不是 recommendations.count——
        // mapper 對個別索引可回 nil，映射後的數量分不出「強制」與「只映射出一個」
        return (rankedRecommendations(mask: mask, probs: probs),
                mask.filter { $0 == 1 }.count)
    }

    /// mask 內的合法動作解碼成推薦，依機率由高到低
    private func rankedRecommendations(mask: [UInt8], probs: [Float]) -> [Recommendation] {
        var recommendations: [Recommendation] = []
        for (index, isAvailable) in mask.enumerated() where isAvailable == 1 {
            let probability = index < probs.count ? Double(probs[index]) : 0.0
            if let action = mapper.actionIndexToRecommendation(index, probability: probability) {
                recommendations.append(action)
            }
        }
        return recommendations.sorted { $0.probability > $1.probability }
    }

    /// 立直項維持首位，打牌項換成宣言後的推論；`declaration` 為空就保留原列。
    nonisolated static func mergingDeclaration(_ declaration: [Recommendation],
                                   into base: [Recommendation]) -> [Recommendation] {
        guard !declaration.isEmpty else { return base }
        return base.filter { $0.actionType == .riichi } + declaration
    }

    /// 立直宣言後再推論：宣言牌的機率分布以「已立直」狀態重算，才不會是未立直時的打牌分布。
    /// 合成的 `reach` 之後伺服器還會真的餵一次，`handleReach` 只設旗標，重複無害。
    private func recommendationsAfterReach() async -> [Recommendation] {
        do {
            let event = try JSONSerialization.data(withJSONObject: ["type": "reach", "actor": Int(playerId)])
            _ = try await bot.react(mjaiEvent: String(decoding: event, as: UTF8.self))
        } catch {
            eventLog("[Bot] ⚠️ 立直後餵 reach 失敗（\(error)），沿用立直前的打牌推薦")
            return []
        }
        return await recommendationsFromCurrentMask()
    }

    /// 自家吃／碰／大明槓之後，對當前狀態推論出捨牌推薦。
    ///
    /// 副露後 MJAI 不會再送事件，`react` 沒被呼叫過，`lastProbs`／`lastMask` 停在
    /// 副露前那一次——手牌早就變了，所以必須對**當前狀態**重新推論。
    /// 推論拿不到（失敗、或沒有合法動作如大明槓）就回空推薦：舊的 probs／mask
    /// 或均勻分布都不是模型對這手牌的判斷，自動打牌會把它當模型判斷打出去。
    /// 寧可不送、讓伺服器逾時代打。
    private func recommendationsFromCurrentMask() async -> [Recommendation] {
        let probs: [Float]
        let mask: [UInt8]
        do {
            guard try await bot.inferCurrentState() != nil else {
                eventLog("[Bot] 副露後無合法動作可推論（大明槓後不需打牌），不送推薦")
                return []
            }
            probs = await bot.getLastProbs()
            mask = await bot.getLastMask()
        } catch {
            eventLog("[Bot] ⚠️ 副露後推論失敗（\(error)），不送推薦")
            return []
        }

        let sorted = rankedRecommendations(mask: mask, probs: probs)
        eventLog("[Bot] 副露後推論: \(sorted.count) items [\(sorted.logSummary)]")
        return sorted
    }
}
