//
//  MJAIEventStreamTests.swift
//  NakiTests
//
//  p0-4 回歸鎖：`MJAIEventStream.startConsumer` 的舊 task 清理閉包不得誤殺新 task。
//
//  舊版消費者 Task 結束時無條件執行 `await MainActor.run { self?.consumerTask = nil }`。
//  連續兩次 `startConsumer`（重連 → resyncBot 就是這個形狀）時，第一代 task 因為
//  `continuation.finish()` 立刻結束，但它的清理是排在 MainActor 上**之後**才跑的，
//  於是把第二代 task 的引用清成 nil。Task 不是 refcount 驅動的，第二代照跑不誤，
//  只是 `stopConsumer()` 的 `cancel()` 從此打在 nil 上 → 孤兒 consumer 停不掉。
//
//  這裡用三個角度鎖住：
//  1. 兩次 startConsumer 之後引用仍在（`hasActiveConsumer`）。
//  2. 事件只被當前這一代消費一次，停掉之後不再消費。
//  3. `stopConsumer()` 的取消訊號真的傳到 handler 內部（孤兒的話收不到）。
//
//  第 3 條是唯一能區分「真的停掉」與「剛好 stream 結束所以迴圈自然退出」的檢查。
//

import XCTest

@testable import Naki

/// 跨 task 計數用的盒子。
///
/// 刻意不用 `@MainActor` class：本 target 沒開 `SWIFT_DEFAULT_ACTOR_ISOLATION`，
/// 但 handler 會在 consumer task 的 context 裡跑，用鎖比用隔離簡單且不牽扯 deinit 執行緒。
private final class CountBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func bump() {
        lock.lock()
        storage += 1
        lock.unlock()
    }
}

@MainActor
final class MJAIEventStreamTests: XCTestCase {

    // MARK: - Helpers

    /// 讓已經排隊的 task／MainActor 工作有機會跑完。
    ///
    /// 舊版的失敗就發生在「`startConsumer` 返回**之後**」那一段，所以測試必須真的
    /// 把 MainActor 讓出去；同步斷言看不到這個 bug。
    private func settle(rounds: Int = 20) async {
        for _ in 0..<rounds {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)  // 5ms
        }
    }

    @discardableResult
    private func waitUntil(timeout: TimeInterval = 3.0,
                           _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return condition()
    }

    // MARK: - 1. 引用不得被上一代清掉

    func testSecondStartConsumerSurvivesFirstConsumerCleanup() async {
        let stream = MJAIEventStream()
        defer { stream.stopConsumer() }

        stream.startConsumer { _ in }
        XCTAssertTrue(stream.hasActiveConsumer, "第一次 startConsumer 後就該有被追蹤的 consumer")

        stream.startConsumer { _ in }

        // 第一代 task 的 stream 已被 finish，它會結束並排一次清理到 MainActor。
        await settle()

        XCTAssertTrue(stream.hasActiveConsumer,
                      "第一代 consumer 的清理把第二代的引用清掉了 → stopConsumer 之後將無法取消（孤兒）")
    }

    func testThirdStartConsumerAlsoSurvivesEarlierCleanups() async {
        let stream = MJAIEventStream()
        defer { stream.stopConsumer() }

        stream.startConsumer { _ in }
        stream.startConsumer { _ in }
        stream.startConsumer { _ in }

        await settle()

        XCTAssertTrue(stream.hasActiveConsumer,
                      "連續三次 startConsumer 後仍必須追蹤到最後一代")
    }

    func testStopConsumerClearsTheReference() async {
        let stream = MJAIEventStream()

        stream.startConsumer { _ in }
        stream.startConsumer { _ in }
        await settle()

        stream.stopConsumer()
        XCTAssertFalse(stream.hasActiveConsumer, "stopConsumer 之後不應再有被追蹤的 consumer")

        // 停掉之後上一代的清理再跑也不能把狀態弄壞
        await settle()
        XCTAssertFalse(stream.hasActiveConsumer)
    }

    // MARK: - 2. 事件計數：不重複消費、停掉之後不再消費

    func testEventIsConsumedOnceByCurrentConsumerOnly() async {
        let stream = MJAIEventStream()
        defer { stream.stopConsumer() }

        let firstCount = CountBox()
        let secondCount = CountBox()

        stream.startConsumer { _ in firstCount.bump() }
        stream.startConsumer { _ in secondCount.bump() }

        await settle()

        stream.emit(["type": "tsumo", "actor": 0, "pai": "1m"])
        await waitUntil { secondCount.value == 1 }
        // 再等一輪，讓「如果有第二個 consumer 也會收到」的情況有機會顯形
        await settle()

        XCTAssertEqual(firstCount.value, 0, "第一代 consumer 的 stream 已 finish，不該再收到新事件")
        XCTAssertEqual(secondCount.value, 1, "當前 consumer 必須恰好收到一次")
    }

    func testNoConsumptionAfterStopConsumer() async {
        let stream = MJAIEventStream()
        let count = CountBox()

        stream.startConsumer { _ in count.bump() }
        stream.startConsumer { _ in count.bump() }
        await settle()

        stream.emit(["type": "tsumo", "actor": 0, "pai": "1m"])
        await waitUntil { count.value == 1 }

        stream.stopConsumer()
        stream.emit(["type": "dahai", "actor": 0, "pai": "1m", "tsumogiri": true])
        await settle()

        XCTAssertEqual(count.value, 1, "stopConsumer 之後送出的事件不該再被任何 consumer 處理")
        XCTAssertEqual(stream.eventCount, 2, "歷史仍要保留（重連重放靠它）")
    }

    // MARK: - 3. stopConsumer 的取消訊號要真的送達 handler

    /// 這一條是「真的停掉」與「只是 stream 剛好結束」的分水嶺。
    ///
    /// handler 進入後長時間輪詢 `Task.isCancelled`：
    /// - 引用還在（修好）→ `stopConsumer()` 的 `cancel()` 傳到 handler，立刻觀察到取消。
    /// - 引用被上一代清成 nil（孤兒）→ cancel 打在 nil 上，handler 一路跑完沒收到取消。
    func testStopConsumerCancellationReachesRunningHandler() async {
        let stream = MJAIEventStream()
        defer { stream.stopConsumer() }

        let entered = CountBox()
        let cancelObserved = CountBox()
        let ranToCompletionUncancelled = CountBox()

        stream.startConsumer { _ in }
        stream.startConsumer { _ in
            entered.bump()
            // 最多輪詢 ~1 秒；孤兒的情況會走完整個迴圈
            for _ in 0..<200 {
                if Task.isCancelled {
                    cancelObserved.bump()
                    return
                }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            ranToCompletionUncancelled.bump()
        }

        await settle()

        stream.emit(["type": "tsumo", "actor": 0, "pai": "1m"])
        let didEnter = await waitUntil { entered.value == 1 }
        XCTAssertTrue(didEnter, "handler 沒被呼叫，後續的取消觀察沒有意義")

        stream.stopConsumer()

        await waitUntil(timeout: 4.0) {
            cancelObserved.value == 1 || ranToCompletionUncancelled.value == 1
        }

        XCTAssertEqual(cancelObserved.value, 1,
                       "stopConsumer 的取消沒有送到執行中的 handler → consumerTask 引用已被上一代清掉（孤兒）")
        XCTAssertEqual(ranToCompletionUncancelled.value, 0,
                       "handler 在沒收到取消的情況下跑完，代表 stopConsumer 沒能停掉它")
    }

    // MARK: - 4. 生命週期方法不得留下孤兒

    func testEndGameClearsConsumerEvenAfterRepeatedStarts() async {
        let stream = MJAIEventStream()

        stream.startNewGame()
        stream.startConsumer { _ in }
        stream.startConsumer { _ in }
        await settle()
        XCTAssertTrue(stream.hasActiveConsumer)

        stream.endGame()
        XCTAssertFalse(stream.hasActiveConsumer)
        XCTAssertFalse(stream.isGameInProgress)
        XCTAssertEqual(stream.eventCount, 0)

        await settle()
        XCTAssertFalse(stream.hasActiveConsumer, "endGame 之後不該有殘留的 consumer 引用")
    }
}
