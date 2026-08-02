//
//  SerialEventIntakeTests.swift
//  NakiTests
//
//  p2-2 回歸鎖：WS 事件必須依到達順序、且不重疊地被處理。
//
//  舊行為（Legacy 路徑）：`onMJAIEvent` 每則事件各開一個 `Task { @MainActor }`。
//  獨立 Task 之間沒有順序保證，而 `start_game` 的 handler 中間會
//  `await createNativeBot`——它一暫停，後面的 tsumo / dahai 就可能先跑完，
//  等於在 bot 還沒建立時就被消費掉。
//
//  這兩個 test 直接對著那個前提寫：第 0 則刻意處理得比後面每一則都久。
//  舊寫法會得到 [1,2,3,4,0]（或任何非遞增序列），現在必須是 [0,1,2,3,4]。
//

import XCTest

@testable import Naki

final class SerialEventIntakeTests: XCTestCase {

    /// 處理順序與重疊偵測（handler 在 MainActor 上跑，斷言在測試 task 上）
    private actor Recorder {
        private(set) var order: [Int] = []
        private(set) var overlapped = false
        private var inFlight = false

        func begin(_ n: Int) {
            if inFlight { overlapped = true }
            inFlight = true
        }

        func end(_ n: Int) {
            inFlight = false
            order.append(n)
        }
    }

    /// FIFO：先到的事件先處理完，即使它處理得比較久
    func testEventsAreHandledInArrivalOrder() async {
        let recorder = Recorder()
        let done = expectation(description: "所有事件處理完畢")

        let intake = SerialEventIntake { event in
            let n = event["n"] as? Int ?? -1
            await recorder.begin(n)
            // 第一則刻意慢：舊的「每則一個 Task」寫法會讓它最後才完成
            try? await Task.sleep(nanoseconds: n == 0 ? 120_000_000 : 1_000_000)
            await recorder.end(n)
            if n == 4 { done.fulfill() }
        }

        for n in 0..<5 {
            intake.yield(["type": "tsumo", "n": n])
        }

        await fulfillment(of: [done], timeout: 5)

        let order = await recorder.order
        XCTAssertEqual(order, [0, 1, 2, 3, 4], "事件必須依 yield 的順序被處理完")

        // 別讓 ARC 在 await 期間提前釋放 intake（deinit 會 finish + cancel consumer）
        withExtendedLifetime(intake) {}
    }

    /// 互斥：一則事件完全處理完（含內部 await）才取下一則
    ///
    /// 這正是 `start_game` 需要的性質——`await createNativeBot` 期間不會有別的事件被消費。
    func testHandlersDoNotOverlap() async {
        let recorder = Recorder()
        let done = expectation(description: "所有事件處理完畢")

        let intake = SerialEventIntake { event in
            let n = event["n"] as? Int ?? -1
            await recorder.begin(n)
            try? await Task.sleep(nanoseconds: 20_000_000)
            await recorder.end(n)
            if n == 2 { done.fulfill() }
        }

        for n in 0..<3 {
            intake.yield(["type": "dahai", "n": n])
        }

        await fulfillment(of: [done], timeout: 5)

        let overlapped = await recorder.overlapped
        XCTAssertFalse(overlapped, "同時有兩則事件在處理 = 沒有序列化")

        withExtendedLifetime(intake) {}
    }
}
