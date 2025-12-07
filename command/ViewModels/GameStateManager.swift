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
final class GameStateManager: ObservableObject {

    // MARK: - Published Properties

    /// 遊戲狀態
    @Published private(set) var gameState = GameState()

    /// Bot 狀態
    @Published private(set) var botStatus = BotStatus()

    /// AI 推薦動作列表
    @Published private(set) var recommendations: [Recommendation] = []

    /// 推薦數量（用於 badge 顯示）
    @Published private(set) var recommendationCount: Int = 0

    /// 是否正在計算推薦
    @Published private(set) var isCalculating = false

    /// 最後更新時間
    @Published private(set) var lastUpdateTime: Date?

    /// 錯誤訊息
    @Published var errorMessage: String?

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
    var isInGame: Bool {
        botStatus.isActive
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

    // MARK: - State Updates

    /// 更新遊戲狀態
    /// - Parameter state: 新的遊戲狀態
    func updateGameState(_ state: GameState) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.gameState = state
            self.lastUpdateTime = Date()
            bridgeLog("\(self.logTag) 遊戲狀態已更新: \(state.kyokuDisplayName)")
        }
    }

    /// 更新 Bot 狀態
    /// - Parameter status: 新的 Bot 狀態
    func updateBotStatus(_ status: BotStatus) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.botStatus = status
            bridgeLog("\(self.logTag) Bot 狀態已更新: active=\(status.isActive)")
        }
    }

    /// 更新 AI 推薦
    /// - Parameter recs: 新的推薦列表
    func updateRecommendations(_ recs: [Recommendation]) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.recommendations = recs
            self.recommendationCount = recs.count
            self.isCalculating = false
            self.lastUpdateTime = Date()

            if let first = recs.first {
                bridgeLog("\(self.logTag) \(recs.count) 個推薦, 最佳: \(first.displayLabel) (\(first.percentageString))")
            } else {
                bridgeLog("\(self.logTag) 無推薦")
            }
        }
    }

    /// 清除推薦
    func clearRecommendations() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.recommendations = []
            self.recommendationCount = 0
        }
    }

    /// 標記正在計算
    func setCalculating(_ calculating: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.isCalculating = calculating
        }
    }

    /// 設置錯誤訊息
    func setError(_ message: String?) {
        DispatchQueue.main.async { [weak self] in
            self?.errorMessage = message
        }
    }

    // MARK: - From Bot Controller

    /// 從 NativeBotController 同步狀態
    /// - Parameter controller: Bot 控制器
    func syncFrom(controller: NativeBotController) {
        // 在主線程外先獲取所有需要的值
        let state = controller.gameState
        let recs = controller.lastRecommendations
        let is3P = controller.is3P
        let canDiscard = controller.canDiscard
        let canRiichi = controller.canRiichi
        let canChi = controller.canChi
        let canPon = controller.canPon
        let canKan = controller.canKan
        let canAgari = controller.canAgari

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            self.gameState = state
            self.recommendations = recs
            self.recommendationCount = recs.count
            self.lastUpdateTime = Date()

            // 更新 Bot 狀態
            var status = BotStatus()
            status.isActive = true
            status.modelName = is3P ? "mortal3p" : "mortal"
            status.playerId = state.playerId
            status.is3P = state.is3P
            status.canDiscard = canDiscard
            status.canRiichi = canRiichi
            status.canChi = canChi
            status.canPon = canPon
            status.canKan = canKan
            status.canAgari = canAgari
            self.botStatus = status
        }
    }

    // MARK: - Reset

    /// 重置所有狀態（對局結束時調用）
    func reset() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.gameState = GameState()
            self.botStatus = BotStatus()
            self.recommendations = []
            self.recommendationCount = 0
            self.isCalculating = false
            self.errorMessage = nil
            self.lastUpdateTime = nil
            bridgeLog("\(self.logTag) 狀態已重置")
        }
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

