//
//  NativeBotController.swift
//  Naki
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
/// ⭐ 標為 @MainActor —— 可變狀態（tehai/tsumo/lastRecommendations…）在 MainActor 隔離，
///        消除呼叫端（`NakiWebCoordinator`，@MainActor）的資料競態。
///        heavy 的 Core ML 推理仍在 MortalBot actor 內 off-main，不受此隔離影響。
@MainActor
class NativeBotController {

    // MARK: - Properties

    /// 推論引擎（protocol 抽象；具體型別由 `createBot` 決定：
    /// `BundledCoreMLBot` 或包了雲端的 `CloudBot`）
    private var bot: (any MahjongBot)?

    /// #2: 世代序號（generation token）。每次 createBot/deleteBot 遞增，用於使 inflight 的
    /// react 結果失效：react 在 `await bot.react` 暫停期間若換了 bot（start_game / 重連），
    /// 恢復後檢查世代不符即丟棄本次結果，避免舊局的推論污染新局。
    private var generation = 0

    // MARK: - 雲端推論（docs/cloud-inference-plan.md；引擎抽象見 MahjongBot.swift）
    //
    // 2026-08-05 protocol 重構之後，雲端整段住在 `CloudBot` 裝飾器裡；
    // controller 只負責兩件事：createBot 時決定要不要包 CloudBot、
    // 把引擎回報的 `BotReaction.source` 轉給 UI／MCP。
    // Replay／單測建的 controller 沒有 provider ⇒ 純本地引擎，
    // 決策指紋天然穩定（`ReplayFingerprintTests` 鎖住）。

    /// 雲端設定來源（`NakiRuntime` 注入 `SettingsStore.cloudConfig`）。
    /// `CloudBot` 在每個決策點經它重讀設定；nil ⇒ 不包裝、雲端永遠關。
    var cloudConfigProvider: (() -> CloudInferenceConfig?)?

    /// 這批推薦由誰算出："local" 或 "cloud:<model>"（來自 `BotReaction.source`）。
    /// fallback 原則——可以更弱，但必須讓人看得出來（UI 與 /bot/status 都讀它）。
    private(set) var lastDecisionSource = "local"

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

    /// `lastRecommendations` 是針對哪一批 oplist（決策機會）算出來的
    /// （`LiqiOperationSnapshot.sequence`，由 MJAI event 攜帶）。
    ///
    /// 只在推薦**真的刷新**時更新，推薦被保留（react 回 nil）時保持不動——這樣它證明的是
    /// 「這份推薦由哪批 oplist 算出」而非「正在處理哪個 event」。自動打牌用它確認推薦與
    /// 當前決策機會同源，避免用舊推薦回應新機會。nil＝provenance 未知（不設限）。
    private(set) var lastRecommendationsOplistSequence: UInt64?

    // 註：`lastCandidates` 已移除。它的唯一寫入點是同樣零呼叫的 `updateAvailableActions()`，
    //     而且從來沒有讀取者——實際永遠是 nil。

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

    // MARK: - 可用動作（來源：協定層 oplist）

    /// 現在能做什麼，一律由伺服器推來的 `OptionalOperationList` 導出。
    ///
    /// 以前這六個是 stored property，唯一的寫入點 `updateAvailableActions()` 是 private
    /// 而且**零呼叫**（`updateInternalState` 尾巴只留了一行「移到 react() 後處理」的註解，
    /// 沒有人接上）。結果 `BotStatusView` 的六個徽章與 `/bot/status` 的 canXxx 恆為 false，
    /// 是 AUDIT §13「不能運作又不說」的同一類問題。
    ///
    /// 改成從 oplist 導出而不是把 mask 掃描接回來，理由是**權威不同**：
    /// mask 是模型對「自己認為的狀態」算出來的合法動作，oplist 是伺服器實際授權的動作。
    /// 動作層（`AutoPlayGate` / `AutoPlayDecisionResolver` / `LiqiActionSender`）本來就
    /// 只認 oplist，UI 顯示的「可用動作」跟著同一個來源才不會出現「徽章亮著但送不出去」。
    ///
    /// 用 `pending` 而不是 `latest`：動作送出並 `markHandled` 之後這批機會就消化掉了，
    /// 徽章應該跟著熄滅。
    var availableActions: BotAvailableActions {
        BotAvailableActions(snapshot: LiqiOperationStore.shared.pending)
    }

    var canDiscard: Bool { availableActions.canDiscard }
    var canRiichi: Bool { availableActions.canRiichi }
    var canChi: Bool { availableActions.canChi }
    var canPon: Bool { availableActions.canPon }
    var canKan: Bool { availableActions.canKan }
    var canAgari: Bool { availableActions.canAgari }

    // MARK: - Initialization

    init() {}

    /// `@MainActor` class 在 NakiTests host 釋放會 SIGABRT（見 CLAUDE.md「專案結構的坑」）
    nonisolated deinit { }

    /// 創建新的 Bot 實例
    /// - Parameters:
    ///   - playerId: 玩家座位 (0-3)
    ///   - is3P: 是否為三麻模式
    func createBot(playerId: UInt8, is3P: Bool = false) throws {
        // #2: 遞增世代，使任何 inflight 的舊 react 結果失效
        generation += 1
        self.playerId = playerId
        self.is3P = is3P

        if is3P {
            // 三麻：本地 4p 模型推三麻結構上無效——**連啟動都不啟動**
            // （2026-08-05 使用者定案）。引擎是雲端-only 的 CloudBot：
            // 決策點由伺服器 oplist 驅動，雲端未生效＝誠實地沒有推薦，
            // 不會有本地無效輸出頂上；設定啟用後下一批授權即生效。
            bot = CloudBot(local: nil, playerId: playerId, is3P: true,
                           configProvider: cloudConfigProvider ?? { nil },
                           serverAuthorization: { LiqiOperationStore.shared.pending != nil })
        } else {
            // 內建引擎經 handProvider 讀 controller 的手牌——手牌是**遊戲**狀態，
            // 權威在 `updateInternalState`（UI/MCP 匯出也讀同一份），引擎只讀不寫。
            let local = try BundledCoreMLBot(playerId: playerId, is3P: false,
                                             hand: { [weak self] in
                                                 (self?.tehai ?? [], self?.tsumo)
                                             })
            // 有雲端設定來源就包一層 CloudBot（設定未啟用時它是純轉發）；
            // Replay／單測沒有 provider ⇒ 純本地，決策指紋天然穩定
            if let provider = cloudConfigProvider {
                bot = CloudBot(local: local, playerId: playerId, is3P: false,
                               configProvider: provider)
            } else {
                bot = local
            }
        }

        botLog("[NativeBotController] Bot 創建成功: playerId=\(playerId), is3P=\(is3P), gen=\(generation), engine=\(bot?.identity.name ?? "?")")
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
    /// 生命週期事件：這些在 Bot 已被刪除後才抵達是正常的，不算錯誤
    private static let lifecycleEvents: Set<String> = ["end_game", "end_kyoku"]

    func react(event: [String: Any]) async throws -> [String: Any]? {
        guard let bot = bot else {
            // end_game 抵達時 Bot 幾乎一定已經不在了：協調器是先 emit 事件、
            // 再 deleteNativeBot，消費者從佇列取出時 bot 已為 nil。
            // 這種情況丟例外會讓每一局結束都走錯誤路徑，log 也從
            // 「[消費者] end_game → 回應: 無」變成「處理 end_game 時發生錯誤」——
            // 格式一變就足以讓依賴這行的工具全部失效（AUDIT §17.3）。
            //
            // 真正的錯誤（對局中途 bot 不見）仍然照丟。
            let type = event["type"] as? String ?? ""
            if Self.lifecycleEvents.contains(type) {
                botLog("[NativeBotController] \(type) 抵達時 Bot 已刪除（正常，忽略）")
                return nil
            }
            botLog("[NativeBotController] ERROR: Bot not initialized!")
            throw NativeBotError.botNotInitialized
        }

        // #2: 進入時捕獲當前世代。`await bot.react` 是唯一暫停點，暫停期間若換了 bot
        //     （deleteBot/createBot 皆遞增 generation），恢復後世代不符 → 丟棄本次結果。
        let gen = generation

        // 記錄事件類型，用於判斷是否需要更新推薦
        let eventType = event["type"] as? String ?? ""
        // 這個 event 是針對哪一批 oplist 產生的（MajsoulBridge 在 parse 時標的）。
        // 只有在推薦真的刷新時才拿它更新 provenance。
        let eventOplistSeq = event[MJAIEventKey.oplistSequence] as? UInt64
        let eventActor = event["actor"] as? Int ?? -1
        let isMyDahai = eventType == "dahai" && eventActor == Int(playerId)
        let isEndEvent = eventType == "hora" || eventType == "ryukyoku" || eventType == "end_kyoku" || eventType == "end_game"

        botLog("[NativeBotController] Processing event: \(eventType), actor: \(eventActor), playerId: \(playerId)")

        // 更新內部狀態
        updateInternalState(from: event)

        // 當自己打牌後，清空推薦（用戶已經做了決定）
        if isMyDahai {
            lastRecommendations = []
            lastRecommendationsOplistSequence = nil
            botLog("[NativeBotController] 自己打牌後，清空推薦")
        }

        // 局/遊戲結束時清空推薦
        if isEndEvent {
            lastRecommendations = []
            botLog("[NativeBotController] 局/遊戲結束，清空推薦")
        }

        botLog("[NativeBotController] Calling bot.react with: \(eventType)")

        // ⭐ 引擎推論。protocol 之後只剩這一個呼叫點：JSON 編解碼、mask 掃描、
        //    副露特例都在引擎（BundledCoreMLBot）裡；雲端代理在 CloudBot 裡。
        //    單元素批次的理由見 `MahjongBot.react(events:)` 註解。
        let reaction: BotReaction?
        do {
            reaction = try await bot.react(events: [event])
        } catch {
            botLog("[NativeBotController] ERROR: bot.react threw error: \(error)")
            throw error
        }

        // #2: `await bot.react` 已返回。若期間換了 bot（start_game / 重連 deleteBot+createBot），
        //     世代不符 → 直接丟棄本次結果，不寫回任何共享狀態，
        //     避免舊局 inflight 推論污染新局。
        guard gen == generation else {
            botLog("[NativeBotController] 丟棄過期 react 結果 (gen=\(gen) != 現世代=\(generation))，不污染新局")
            return nil
        }

        guard let reaction else {
            botLog("[NativeBotController] bot.react returned nil (no action needed)")
            // 注意：不清空 lastRecommendations
            // 讓推薦保持到下一次需要做決定時（provenance 也一起保持不動）
            // 只有在新的推薦產生時才會更新
            return nil
        }

        // 引擎刷新了推薦（有動作，或自家副露後的捨牌建議）→ 套用並綁定 provenance
        lastRecommendations = reaction.recommendations
        lastDecisionSource = reaction.source
        lastRecommendationsOplistSequence = eventOplistSeq   // 推薦刷新 → 綁定 provenance

        guard let response = reaction.action else {
            // 副露後的推薦刷新：無動作要回（log 由引擎的「副露後推論」一行負責）
            return nil
        }

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
        // 可用動作不再是本 class 的狀態：它由 oplist 導出。
        // 不帶 operation 的動作（和了／流局／別家動作）抵達時
        // `MajsoulBridge.recordOperationSnapshot` 會 `clear()`，六個旗標自然歸零。
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

    // MARK: - 雲端推論（重連重放抑制）

    /// 重連重放歷史事件前呼叫（`NakiWebCoordinator.resyncBot`）：
    /// 接下來 `eventCount` 個事件只走本地引擎，不打雲端 API——
    /// 歷史決策早就做完了，重放時重問伺服器是純浪費（N 決策 × 2s 預算＋額度）。
    func prepareForResyncReplay(eventCount: Int) {
        (bot as? CloudBot)?.suppressCloud(forNextEvents: eventCount)
    }

    private func resetState() {
        playerId = 0
        is3P = false
        tehai = []
        tsumo = nil
        lastRecommendations = []
        lastRecommendationsOplistSequence = nil
        kyoku = 0
        honba = 0
        kyotaku = 0
        bakazeWind = .east
        jikazeWind = .east
        scores = [25000, 25000, 25000, 25000]
        doraMarkers = []
        // 可用動作是 oplist 的投影，不在本 class 持有，因此沒有東西要重置。
        // ☁️ 雲端狀態（視窗／client／斷路器）住在 CloudBot，隨 deleteBot 一起釋放；
        // 這裡只歸零決策來源標記。
        lastDecisionSource = "local"
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
        var status = BotStatus(
            isActive: isInitialized,
            // modelName 必須反映**實際載入的是哪個**：四麻＝內建 Mortal；
            // 三麻＝雲端-only（本地模型不啟動，2026-08-05 起）
            modelName: is3P ? "cloud-3p" : "mortal",
            playerId: Int(playerId),
            is3P: is3P
        )
        status.applyAvailableActions(availableActions)
        // ☁️ 決策來源與資料去向：cloudHost 非 nil＝對局事件正在送往該主機
        // （UI 常駐顯示的依據，pluggable-bots-plan 安全節）
        status.decisionSource = lastDecisionSource
        status.cloudHost = bot?.cloudHost
        // fallback 可視化：退化旗標＋連續本地手數（紅色警示行的資料源）
        status.cloudDegraded = bot?.cloudDegraded ?? false
        status.cloudFallbackStreak = bot?.cloudFallbackStreak ?? 0
        return status
    }

    // MARK: - 測試注入（只在 DEBUG build 存在）

    #if DEBUG
    /// 直接指定「模型此刻說什麼」，不跑 Core ML 推論。**只有 DEBUG build 有這個入口。**
    ///
    /// fail-safe fixture 需要的是推薦這一個輸入，不是推論本身：
    /// 「推薦為空 ＋ oplist 有和牌」與「AI 想 discard ＋ 伺服器給 tsumo」兩種前提
    /// 都得精確擺出來，而真的跑一次模型既慢又給不出這兩種輸入
    /// （實測兩次和牌，模型都回 `hora@99.6%` 以上，從頭到尾沒有分歧）。
    ///
    /// 不進 Release 的理由與 `LiqiOperationStore.injectForTesting` 相同：
    /// 能偽造模型輸出的入口不該存在於使用者跑的 binary 裡。
    func injectRecommendationsForTesting(_ recommendations: [Recommendation]) {
        lastRecommendations = recommendations
    }
    #endif
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
