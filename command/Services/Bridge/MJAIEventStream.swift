//
//  MJAIEventStream.swift
//  Naki
//
//  Created by Suoie on 2025/12/03.
//  MJAI 事件流管理器 - 使用 AsyncStream 管理事件傳遞和歷史記錄
//

import Foundation

/// MJAI 事件流管理器
/// 負責管理遊戲事件的流式傳遞和歷史記錄，支持 Bot 重新同步
@MainActor
class MJAIEventStream {

    // MARK: - Properties

    /// 事件歷史（當前遊戲的所有事件）
    private var eventHistory: [[String: Any]] = []

    /// 當前的 continuation（用於發送新事件到 stream）
    private var continuation: AsyncStream<[String: Any]>.Continuation?

    /// 消費者 Task（只保留一份，重建時會 cancel 舊的）
    private var consumerTask: Task<Void, Never>?

    /// 當前遊戲是否進行中
    private(set) var isGameInProgress: Bool = false

    /// 事件歷史數量
    var eventCount: Int { eventHistory.count }

    // MARK: - Game Lifecycle

    /// 開始新遊戲
    func startNewGame() {
        print("[MJAIEventStream] 開始新遊戲, 清空歷史 (\(eventHistory.count) 個事件)")

        // Cancel 舊的 Task
        consumerTask?.cancel()
        consumerTask = nil

        // Finish 舊的 continuation
        continuation?.finish()
        continuation = nil

        // 清空歷史
        eventHistory = []
        isGameInProgress = true
    }

    /// 結束遊戲
    func endGame() {
        print("[MJAIEventStream] 結束遊戲")

        consumerTask?.cancel()
        consumerTask = nil
        continuation?.finish()
        continuation = nil
        eventHistory = []
        isGameInProgress = false
    }

    // MARK: - Event Emission

    /// 發送事件（保存到歷史 + yield 給消費者）
    func emit(_ event: [String: Any]) {
        // 保存到歷史
        eventHistory.append(event)

        // 發送給消費者
        continuation?.yield(event)

        if let eventType = event["type"] as? String {
            print("[MJAIEventStream] 發送事件: \(eventType), 歷史數量: \(eventHistory.count)")
        }
    }

    // MARK: - Consumer Management

    /// 啟動消費者 Task（會先重放歷史事件）
    /// - Parameter handler: 事件處理閉包
    func startConsumer(handler: @escaping ([String: Any]) async -> Void) {
        // 1. Cancel 舊的 Task
        consumerTask?.cancel()
        continuation?.finish()

        // 2. 快照當前歷史
        let historySnapshot = eventHistory

        print("[MJAIEventStream] 啟動消費者, 有 \(historySnapshot.count) 個歷史事件")

        // 3. 創建新的 AsyncStream
        let stream = AsyncStream<[String: Any]> { [weak self] continuation in
            // 先 yield 所有歷史事件
            for event in historySnapshot {
                continuation.yield(event)
            }
            // 保存 continuation 用於接收新事件
            Task { @MainActor in
                self?.continuation = continuation
            }
        }

        // 4. 啟動新的消費者 Task
        consumerTask = Task { [weak self] in
            for await event in stream {
                guard !Task.isCancelled else {
                    print("[MJAIEventStream] 消費者任務已取消")
                    break
                }
                await handler(event)
            }
            await MainActor.run {
                self?.consumerTask = nil
            }
        }
    }

    /// 停止消費者（保留歷史以便重連時重放）
    func stopConsumer() {
        print("[MJAIEventStream] 停止消費者 (歷史已保留: \(eventHistory.count) 個事件)")
        consumerTask?.cancel()
        consumerTask = nil
        continuation?.finish()
        continuation = nil
    }

    // MARK: - Resync Support

    /// 檢查是否可以重新同步（是否有 start_game 歷史）
    func canResync() -> Bool {
        let hasStartGame = eventHistory.contains { ($0["type"] as? String) == "start_game" }
        print("[MJAIEventStream] canResync 檢查: hasStartGame=\(hasStartGame), eventCount=\(eventHistory.count)")
        return hasStartGame
    }

    /// 獲取 start_game 事件中的 playerId
    func getPlayerId() -> Int? {
        for event in eventHistory {
            if (event["type"] as? String) == "start_game",
               let playerId = event["id"] as? Int {
                return playerId
            }
        }
        return nil
    }
}
