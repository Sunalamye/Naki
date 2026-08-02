//
//  GameStateManager.swift
//  Naki
//
//  Created by Claude on 2025/12/03.
//  遊戲狀態管理器 - 集中管理遊戲狀態和 AI 推薦
//

import Combine
import Foundation
import SwiftUI
import MortalSwift

// MARK: - Game State Manager

/// 遊戲狀態管理器
/// 集中管理遊戲狀態、AI 推薦和 Bot 狀態，提供 UI 響應式更新
///
/// #p0-3: 整個 class 標 `@MainActor`，所有 mutator 都是同步直接賦值。
///
/// 之前每個 mutator 各自包一層 `DispatchQueue.main.async`：呼叫端（`WebViewModel`、
/// `LegacyWebViewModel`，兩者皆 `@MainActor`）明明已經在 main 上，寫入卻要延到下一個
/// runloop 才生效。後果是 SwiftUI 讀 WebViewModel 的鏡像屬性是「立即值」、MCP 的
/// `/bot/status` 與 `/game/state` 讀本 class 是「上一幀值」——同一時刻兩邊講不同的話。
/// 直接賦值後兩邊在同一個 main runloop turn 內一致。
///
/// 注意：app target 有 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，本 class 其實早就
/// 被隱式隔離在 MainActor；顯式標註是為了讓隔離不依賴 build setting，也讓非 app target
/// （測試、未來的 package 化）看到同一份語意。
@Observable
@MainActor
final class GameStateManager {

    // MARK: - Observable Properties

    /// 遊戲狀態
    private(set) var gameState = GameState()

    /// Bot 狀態
    private(set) var botStatus = BotStatus()

    /// AI 推薦動作列表
    private(set) var recommendations: [Recommendation] = []

    /// 推薦數量（用於 badge 顯示）
    private(set) var recommendationCount: Int = 0

    /// 是否正在計算推薦
    private(set) var isCalculating = false

    /// 最後更新時間
    private(set) var lastUpdateTime: Date?

    /// 錯誤訊息
    var errorMessage: String?

    // MARK: - Computed Properties

    /// 是否有推薦
    var hasRecommendations: Bool {
        !recommendations.isEmpty
    }

    /// 第一個推薦（最高機率）
    var topRecommendation: Recommendation? {
        recommendations.first
    }

    /// 是否在對局中
    ///
    /// `botStatus.isActive` 只代表「Bot 物件存在」——Bot 在 authGame 當下就建立，
    /// 那時還沒發牌；重連時也可能先建 Bot 才進局。`/game/state` 的 `inGame`
    /// 被用來回答「現在是不是在打」，所以再要求真的有局在跑。
    ///
    /// 對局結束後這個欄位停在 `true`（配上 東0局 / seat 0）曾讓測試工具誤判，
    /// 是「欄位名稱與語意不符」的典型代價。
    var isInGame: Bool {
        botStatus.isActive && gameState.kyoku > 0
    }

    /// 局數顯示
    var roundDisplay: String {
        gameState.kyokuDisplayName
    }

    /// 本場顯示
    var honbaDisplay: String {
        gameState.honba > 0 ? "\(gameState.honba) 本場" : ""
    }

    /// 供託顯示
    var kyotakuDisplay: String {
        gameState.kyotaku > 0 ? "\(gameState.kyotaku) 供託" : ""
    }

    /// 自己的分數
    var myScore: Int {
        guard gameState.playerId < gameState.scores.count else { return 0 }
        return gameState.scores[gameState.playerId]
    }

    // MARK: - Private Properties

    /// 日誌標籤
    private let logTag = "[GameStateManager]"

    /// Combine 訂閱
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Initialization

    init() {
        bridgeLog("\(logTag) 已初始化")
    }

    /// deinit 標 `nonisolated`——**沒有它，任何碰到本 class 的單元測試都會讓 test host 崩掉**。
    ///
    /// app target 是 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，所以 MainActor 隔離的
    /// class 連隱含的 deinit 都會走 `swift_task_deinitOnExecutor`。在 NakiTests 的 host
    /// 進程裡釋放這種物件會在 `TaskLocal::StopLookupScope::~StopLookupScope()` 觸發
    /// `pointer being freed was not allocated` 而 SIGABRT——測試不是 fail 而是整個
    /// host 掛掉重啟，看起來像「測試莫名其妙不跑」。
    ///
    /// 已用最小重現確認：`@MainActor final class`（有沒有 `@Observable` 都一樣）→ 崩；
    /// 同一個 class 改 `nonisolated deinit` → 過；`nonisolated final class` → 過。
    /// 本 class 的 deinit 不需要碰 MainActor 狀態（只是釋放值型別欄位），
    /// 所以 nonisolated 沒有語意代價。
    nonisolated deinit { }

    // MARK: - State Updates

    /// 更新遊戲狀態
    /// - Parameter state: 新的遊戲狀態
    func updateGameState(_ state: GameState) {
        gameState = state
        lastUpdateTime = Date()
        bridgeLog("\(logTag) 遊戲狀態已更新: \(state.kyokuDisplayName)")
    }

    /// 更新 Bot 狀態
    /// - Parameter status: 新的 Bot 狀態
    func updateBotStatus(_ status: BotStatus) {
        botStatus = status
        bridgeLog("\(logTag) Bot 狀態已更新: active=\(status.isActive)")
    }

    /// 更新 AI 推薦
    /// - Parameter recs: 新的推薦列表
    func updateRecommendations(_ recs: [Recommendation]) {
        recommendations = recs
        recommendationCount = recs.count
        isCalculating = false
        lastUpdateTime = Date()

        if let first = recs.first {
            bridgeLog("\(logTag) \(recs.count) 個推薦, 最佳: \(first.displayLabel) (\(first.percentageString))")
        } else {
            bridgeLog("\(logTag) 無推薦")
        }
    }

    /// 清除推薦
    func clearRecommendations() {
        recommendations = []
        recommendationCount = 0
    }

    /// 標記正在計算
    func setCalculating(_ calculating: Bool) {
        isCalculating = calculating
    }

    /// 設置錯誤訊息
    func setError(_ message: String?) {
        errorMessage = message
    }

    // MARK: - From Bot Controller

    /// 從 NativeBotController 同步狀態
    /// - Parameter controller: Bot 控制器
    ///
    /// #15: controller 已 @MainActor 隔離，與本 class 同一 isolation，直接同步讀取。
    /// #p0-3: 原本讀完 controller 之後還丟一次 `DispatchQueue.main.async` 才寫回，
    ///        等於在已經是 MainActor 的路徑上多繞一個 runloop。現在讀完就寫，
    ///        呼叫端 return 後立刻讀得到新值（`syncFromLeavesStateReadableImmediately` 鎖住）。
    func syncFrom(controller: NativeBotController) {
        // controller 為 @MainActor，這裡在 MainActor 上同步取得所有需要的值（值型別快照）
        let state = controller.gameState
        let recs = controller.lastRecommendations

        gameState = state
        recommendations = recs
        recommendationCount = recs.count
        lastUpdateTime = Date()

        // 更新 Bot 狀態
        var status = BotStatus()
        status.isActive = true
        status.modelName = "mortal"   // 同上：只有四麻模型，標籤不得造假
        status.playerId = state.playerId
        status.is3P = state.is3P
        status.canDiscard = controller.canDiscard
        status.canRiichi = controller.canRiichi
        status.canChi = controller.canChi
        status.canPon = controller.canPon
        status.canKan = controller.canKan
        status.canAgari = controller.canAgari
        botStatus = status
    }

    // MARK: - Reset

    /// 重置所有狀態（對局結束時調用）
    func reset() {
        gameState = GameState()
        botStatus = BotStatus()
        recommendations = []
        recommendationCount = 0
        isCalculating = false
        errorMessage = nil
        lastUpdateTime = nil
        bridgeLog("\(logTag) 狀態已重置")
    }

    // MARK: - Utility

    /// 獲取狀態摘要（用於調試）
    func getStatusSummary() -> [String: Any] {
        return [
            "round": gameState.kyokuDisplayName,
            "honba": gameState.honba,
            "kyotaku": gameState.kyotaku,
            "playerId": gameState.playerId,
            "scores": gameState.scores,
            "botActive": botStatus.isActive,
            "modelName": botStatus.modelName,
            "recommendationCount": recommendationCount,
            "topRecommendation": topRecommendation?.displayLabel ?? "none",
            "isCalculating": isCalculating,
            "lastUpdate": lastUpdateTime?.description ?? "never"
        ]
    }
}

