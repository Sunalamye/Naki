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

    /// 消費者世代編號：每次 `startConsumer` 建新 Task 就 +1
    ///
    /// #p0-4: 舊 task 結束時的清理閉包（`consumerTask = nil`）是排在 MainActor 上**之後**才跑的。
    /// 連續兩次 `startConsumer` 時，第一次的 task 因 `continuation.finish()` 結束，它的清理
    /// 排在第二次 `startConsumer` 返回之後 → 把**新** task 的引用清成 nil。
    /// 新 task 不會因為失去引用而取消（Task 不是 refcount 驅動的），於是後續
    /// `stopConsumer()` 的 `cancel()` 打在 nil 上，變成一個沒人能停的孤兒 consumer。
    ///
    /// 用世代編號讓清理閉包只在「我還是當前這一代」時才動 `consumerTask`。
    /// 不用 Task 本身比對是因為 `Task` 的 `==` 只在同型別、且需要保留強引用才可靠，
    /// 而清理閉包只能持 `weak self`，拿不到穩定的 identity。
    private var consumerGeneration: UInt64 = 0

    /// 目前是否有被追蹤（因此 `stopConsumer()` 真的能取消）的 consumer
    ///
    /// 這是 p0-4 的可觀測不變式：`startConsumer` 之後必須是 true，
    /// 而且不能被上一代 task 的清理閉包在事後打成 false。
    var hasActiveConsumer: Bool { consumerTask != nil }

    /// 當前遊戲是否進行中
    private(set) var isGameInProgress: Bool = false

    /// 對局錄影（寫進當次 session 的 log 目錄）
    ///
    /// 錄的是**送進 Bot 的 MJAI 事件**，不是原始 WS frame：replay 的目的是
    /// 重跑決策，而決策的輸入就是這一層。原始 frame 另有 liqi log 可查。
    let recorder = GameRecorder(
        directory: LogManager.shared.logDirectory.appendingPathComponent("games", isDirectory: true))

    /// 事件歷史數量
    var eventCount: Int { eventHistory.count }

    /// deinit 標 `nonisolated`——理由與 `NativeBotController`／`GameStore` 同一條：
    /// app target 開了 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，MainActor 隔離的 class
    /// 連隱含 deinit 都走 `swift_task_deinitOnExecutor`；在 NakiTests 的 host 進程裡釋放
    /// 這種物件會 `pointer being freed was not allocated` 而 SIGABRT，整個 test host 掛掉重啟。
    /// 本 class 的 deinit 不需要碰 MainActor 狀態。
    nonisolated deinit { }

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
        recorder.startGame()
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
        recorder.finishGame()
    }

    // MARK: - Event Emission

    /// 發送事件（保存到歷史 + yield 給消費者）
    func emit(_ event: [String: Any]) {
        // 保存到歷史
        eventHistory.append(event)
        recorder.record(event)

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
        // #5: 用 makeStream 同步取得 continuation，避免以往在 build 閉包內把 continuation
        //     指派丟進延遲的 Task { @MainActor }。那個跨 Task hop 會讓 startConsumer 返回到
        //     該 Task 執行之間的 emit() yield 到舊/nil continuation → 消費者啟動後最初幾個 live
        //     事件遺失。這裡在 @MainActor 上同步保存 continuation，emit() 立即可用、不漏事件。
        let (stream, continuation) = AsyncStream<[String: Any]>.makeStream()

        // 先 yield 所有歷史事件（消費者啟動後會依序重放）
        for event in historySnapshot {
            continuation.yield(event)
        }

        // 同步保存 continuation 用於接收新事件（startConsumer 為 @MainActor，此指派在返回前完成）
        self.continuation = continuation

        // 4. 啟動新的消費者 Task
        //    #p0-4: 先取新世代編號並讓 Task 捕獲它；清理時只有「還是這一代」才把
        //    consumerTask 清成 nil，否則上一代的清理會誤殺剛建好的這一代。
        consumerGeneration &+= 1
        let generation = consumerGeneration

        consumerTask = Task { [weak self] in
            for await event in stream {
                guard !Task.isCancelled else {
                    print("[MJAIEventStream] 消費者任務已取消")
                    break
                }
                await handler(event)
            }
            await MainActor.run {
                guard let self else { return }
                guard self.consumerGeneration == generation else {
                    // 已經有更新的 consumer 接手了；這裡清掉會製造孤兒
                    print("[MJAIEventStream] 舊消費者(第 \(generation) 代)結束，當前為第 \(self.consumerGeneration) 代，不清除引用")
                    return
                }
                self.consumerTask = nil
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

    /// #3: 獲取 start_game 事件中的三麻旗標（用於重連重建時保持一致；預設四麻）
    func getIs3P() -> Bool {
        for event in eventHistory {
            if (event["type"] as? String) == "start_game" {
                return (event["is3P"] as? Bool) ?? false
            }
        }
        return false
    }
}
