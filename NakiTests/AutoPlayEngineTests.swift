//
//  AutoPlayEngineTests.swift
//  NakiTests
//
//  `AutoPlayEngine`（p3-2）本體的機械驗收。
//
//  這些性質在 p3-2 之前**一條都測不到**：狀態機散在 `WebViewModel` 裡，
//  而那個型別要有 WebPage / DebugServer / Timer 才建得起來。於是
//  「執行位會不會殘留」「決策綁在哪一批 oplist」「去抖擋不擋得住」
//  只能靠 live 對局撞——而它們正是最不容易撞到的那幾條。
//
//  fail-safe 的三個 fixture（空推薦＋和牌、送出失敗重試、伺服器和牌覆蓋 AI）
//  在 `AutoPlayFailsafeFixtureTests`，p3-2 之後那些也是跑這個引擎。
//

import XCTest

@testable import Naki

@MainActor
final class AutoPlayEngineTests: XCTestCase {

    // MARK: - 共用

    /// 所有時間常數歸零：測試不該真的等 1.8 秒的擬人延遲或 0.2 秒的重試間隔
    private func timing(maxAttempts: Int = 15, poll: TimeInterval = 1.0) -> AutoPlayEngine.Timing {
        var timing = AutoPlayEngine.Timing()
        timing.poll = poll
        timing.horaRetry = 0
        timing.passRetry = 0
        timing.retry = 0
        timing.maxAttempts = maxAttempts
        timing.passAttempts = maxAttempts
        timing.passPolicy = .init(maxAttempts: maxAttempts, delay: 0)
        timing.actionDelay = { _, _ in 0 }
        return timing
    }

    private func makeEngine(store: LiqiOperationStore,
                            sender: LiqiActionSender,
                            mode: AutoPlayMode = .auto,
                            recommendations: [Recommendation] = [],
                            isSanma: Bool = false,
                            isReady: Bool = true,
                            maxAttempts: Int = 15,
                            poll: TimeInterval = 1.0) -> AutoPlayEngine {
        AutoPlayEngine(
            store: store,
            sender: sender,
            timing: timing(maxAttempts: maxAttempts, poll: poll),
            context: {
                AutoPlayEngine.Context(mode: mode,
                                       recommendations: recommendations,
                                       seat: 0,
                                       isSanma: isSanma,
                                       tsumoTile: nil,
                                       isReady: isReady)
            })
    }

    private func ok() -> LiqiRawSendResult {
        LiqiRawSendResult(success: true, detail: "socket=0 bytes=26")
    }

    @discardableResult
    private func tsumoSnapshot(_ store: LiqiOperationStore) -> LiqiOperationSnapshot {
        store.record(seat: 0,
                     operations: [LiqiOperation(type: .tsumo)],
                     timeFixed: 300,
                     contextTile: "5p",
                     source: "ActionDealTile")
    }

    private let discardRecommendation = [
        Recommendation(tile: "1m", probability: 0.87, actionType: .discard)
    ]

    // MARK: - 執行位：一定歸零

    /// 舊實作用一個裸 `currentExecutionId` + `clearExecutionIfCurrent`，靠註解要求
    /// 8 條 return 路徑各自歸零；漏一條，1 秒輪詢（以 `== nil` 為前提）就**永久停用**。
    ///
    /// 現在進出執行位只有 `occupy(...)` 一個作用域（`defer { state = .idle }`）。
    /// 這條測試把四種結束方式各走一次，每次都要求回到 `.idle`。
    func testExecutionSlotAlwaysReturnsToIdle() async {
        // ① 成功送出
        let sent = LiqiOperationStore()
        let okSender = LiqiActionSender()
        okSender.sendHandler = { _ in self.ok() }
        tsumoSnapshot(sent)
        let engineA = makeEngine(store: sent, sender: okSender)
        let runA = await engineA.runCycle()
        XCTAssertEqual(runA.outcome, .sent(action: .hora, tile: "5p", attempts: 1))
        XCTAssertEqual(engineA.state, .idle, "送出成功之後執行位必須歸零")

        // ② 一路送出失敗
        let failed = LiqiOperationStore()
        let badSender = LiqiActionSender()
        badSender.sendHandler = { _ in .failure("no_gateway") }
        tsumoSnapshot(failed)
        let engineB = makeEngine(store: failed, sender: badSender, maxAttempts: 2)
        let runB = await engineB.runCycle()
        XCTAssertEqual(runB.outcome, .sendFailed(action: .hora, attempts: 2))
        XCTAssertEqual(engineB.state, .idle, "放棄之後執行位必須歸零（殘留＝輪詢永久停用）")

        // ③ resolver 說不送（模式閘門；手動觸發才看得到）
        let surfaced = LiqiOperationStore()
        let quietSender = LiqiActionSender()
        quietSender.sendHandler = { _ in self.ok() }
        tsumoSnapshot(surfaced)
        let engineC = makeEngine(store: surfaced, sender: quietSender,
                                 mode: .recommend, recommendations: discardRecommendation)
        let runC = await engineC.runManualCycle()
        XCTAssertEqual(runC.outcome, .surfaced(.hora))
        XCTAssertEqual(engineC.state, .idle)

        // ④ 閘門直接擋下（連執行位都不該碰）
        let skipped = LiqiOperationStore()
        let engineD = makeEngine(store: skipped, sender: LiqiActionSender(), mode: .off)
        let runD = await engineD.runCycle()
        XCTAssertEqual(runD.outcome, .skipped(.notAutoMode))
        XCTAssertEqual(engineD.state, .idle)
    }

    // MARK: - TOCTOU：決策綁在閘門看到的那一批 oplist

    /// 舊實作在閘門讀一次 `store.pending`、延遲之後**再讀一次**才交給 resolver。
    /// 中間換批的話，「因為 A 批而觸發」的動作會落在 B 批上——而 `isStillValid`
    /// 比對的是它自己剛讀的那一份，補救不到。
    ///
    /// 現在同一份 snapshot 一路傳到 resolver 與 executor，換批只能放棄。
    func testDecisionStaysBoundToTheSnapshotTheGateSaw() async {
        let store = LiqiOperationStore()
        let sender = LiqiActionSender()
        var sends = 0
        sender.sendHandler = { _ in
            sends += 1
            // 第一次送出失敗，而且在重試之前對局往前走了一批（新的 oplist 到達）
            if sends == 1 {
                store.record(seat: 0,
                             operations: [LiqiOperation(type: .discard)],
                             contextTile: "9p",
                             source: "ActionDealTile")
            }
            return .failure("no_gateway")
        }

        let first = tsumoSnapshot(store)
        let engine = makeEngine(store: store, sender: sender, maxAttempts: 5)
        let run = await engine.runCycle()

        XCTAssertEqual(sends, 1, "換批之後不可以再送一次——那等於替下一個決策做主")
        XCTAssertEqual(run.outcome, .notSent(reason: "stale_oplist"))
        XCTAssertTrue(run.log.contains { $0.contains("oplist 已更新") })
        XCTAssertNotEqual(store.pending?.sequence, first.sequence)
        XCTAssertNotNil(store.pending, "新到的那批要留給下一輪，不能被這次決策消化")
    }

    // MARK: - 去抖

    /// 同一個推薦在窗口內只觸發一次（窗口 = 動作延遲 + 0.5 秒）。
    ///
    /// 這份狀態原本由「1 秒輪詢」與「推薦更新」兩個觸發源共用，而兩者一個經閘門、
    /// 一個不經，時序耦合到無從單測。現在只有一條路。
    func testDebounceBlocksTheSameRecommendationWithinTheWindow() async {
        let store = LiqiOperationStore()
        let sender = LiqiActionSender()
        var sends = 0
        sender.sendHandler = { _ in
            sends += 1
            return .failure("no_gateway")   // 失敗才會保留 oplist，第二輪才有東西可擋
        }
        store.record(seat: 0,
                     operations: [LiqiOperation(type: .discard)],
                     contextTile: "3s",
                     source: "ActionDealTile")

        let now = Date()
        let engine = makeEngine(store: store, sender: sender,
                                recommendations: discardRecommendation, maxAttempts: 1)

        let first = await engine.runCycle(now: now)
        XCTAssertEqual(first.outcome, .sendFailed(action: .discard, attempts: 1))
        XCTAssertEqual(sends, 1)

        let second = await engine.runCycle(now: now)
        XCTAssertEqual(second.outcome, .notSent(reason: "debounced"))
        XCTAssertEqual(sends, 1, "窗口內同一個推薦不可以再送一次")

        // 切模式是明確的使用者意圖，不該被「剛才才觸發過」擋住
        engine.modeDidChange()
        let third = await engine.runCycle(now: now)
        XCTAssertEqual(third.outcome, .sendFailed(action: .discard, attempts: 1))
        XCTAssertEqual(sends, 2)
    }

    // MARK: - 延遲 stepper 的讀取端（p2-6）

    /// 引擎必須把 `Context.actionDelayScale` 讀出來、傳進延遲計算。
    ///
    /// 這正是 p1-3 抓到那批假控制的根因：stepper 寫得進值卻**沒有任何讀取端**。
    /// seam 帶著 scale，這條測試證明「引擎確實從 context 取了那個值並往下傳」——
    /// 換句話說，UI 上調 stepper 不會像從前一樣石沉大海。
    func testEngineThreadsContextDelayScaleIntoTheDelaySeam() async {
        let store = LiqiOperationStore()
        store.record(seat: 0,
                     operations: [LiqiOperation(type: .discard)],
                     contextTile: "1m",
                     source: "ActionDealTile")
        let sender = LiqiActionSender()
        sender.sendHandler = { _ in self.ok() }

        final class Box { var scale: Double = -1 }
        let box = Box()

        var t = timing()
        t.actionDelay = { _, scale in box.scale = scale; return 0 }

        let engine = AutoPlayEngine(
            store: store, sender: sender, timing: t,
            context: {
                AutoPlayEngine.Context(mode: .auto,
                                       recommendations: self.discardRecommendation,
                                       seat: 0,
                                       isSanma: false,
                                       tsumoTile: nil,
                                       isReady: true,
                                       actionDelayScale: 2.5)
            })

        let run = await engine.runCycle()

        guard case .sent(let action, _, _) = run.outcome else {
            return XCTFail("應該走到 .proceed 並送出，實際: \(run.outcome)")
        }
        XCTAssertEqual(action, .discard)
        XCTAssertEqual(box.scale, 2.5, accuracy: 1e-9,
                       "引擎沒有把 stepper 的係數讀出來傳給延遲計算——又變回假控制")
    }

    // MARK: - 手動觸發（不經閘門，三道自己擋）

    func testManualTriggerFailsClosedOnSanma() async {
        let store = LiqiOperationStore()
        let sender = LiqiActionSender()
        var sends = 0
        sender.sendHandler = { _ in
            sends += 1
            return self.ok()
        }
        tsumoSnapshot(store)

        let engine = makeEngine(store: store, sender: sender,
                                recommendations: discardRecommendation, isSanma: true)
        let run = await engine.runManualCycle()

        XCTAssertEqual(run.outcome, .notSent(reason: "sanma_unsupported"),
                       "內建模型只有四麻一份；手動觸發不經閘門，得自己擋")
        XCTAssertEqual(sends, 0)
        XCTAssertNotNil(store.pending)
    }

    func testManualTriggerWithoutOplistDoesNotSchedule() async {
        let store = LiqiOperationStore()
        let sender = LiqiActionSender()
        var sends = 0
        sender.sendHandler = { _ in
            sends += 1
            return self.ok()
        }

        let engine = makeEngine(store: store, sender: sender,
                                recommendations: discardRecommendation)
        let run = await engine.runManualCycle()

        XCTAssertEqual(run.outcome, .notSent(reason: "no_oplist"),
                       "合法性的權威在 oplist，沒有它就沒有伺服器授權")
        XCTAssertEqual(sends, 0)
    }

    // MARK: - 迴圈（取代 Timer 的那一個 Task）

    /// 沒有 `Timer`、沒有 `asyncAfter`：輪詢是同一個 Task 迴圈裡的 `Task.sleep`。
    ///
    /// 這條測試只證明「迴圈真的會自己動起來並收工」，不證明 1 秒節奏——
    /// 節奏是 live soak 的事（未驗證）。
    func testLoopDrivesACycleWithoutAnyTimer() async {
        let store = LiqiOperationStore()
        let sender = LiqiActionSender()
        var sends = 0
        sender.sendHandler = { _ in
            sends += 1
            return self.ok()
        }
        tsumoSnapshot(store)

        let engine = makeEngine(store: store, sender: sender, poll: 0.01)
        engine.start()

        let deadline = Date().addingTimeInterval(3)
        while sends == 0, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        engine.stop()

        XCTAssertEqual(sends, 1, "迴圈要自己跑出一輪並送出和牌")
        XCTAssertNil(store.pending, "送出成功才消化 oplist")
        XCTAssertEqual(engine.state, .idle)
    }

    /// `stop()` 之後迴圈不再送任何東西（App 收掉／測試結束都靠它）
    func testStopEndsTheLoop() async {
        let store = LiqiOperationStore()
        let sender = LiqiActionSender()
        var sends = 0
        sender.sendHandler = { _ in
            sends += 1
            return .failure("no_gateway")   // 一直失敗 → oplist 一直在 → 迴圈一直有事做
        }
        tsumoSnapshot(store)

        let engine = makeEngine(store: store, sender: sender, maxAttempts: 1, poll: 0.01)
        engine.start()
        let deadline = Date().addingTimeInterval(3)
        while sends == 0, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        engine.stop()

        let afterStop = sends
        try? await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertEqual(sends, afterStop, "stop() 之後不可以再送出任何 request")
    }
}

// MARK: - 結構鎖（p3-2 的驗收條件之一）

/// 「組裝點內無 Timer／asyncAfter 殘留」是結構性約束，型別系統看不見。
///
/// p3-4：掃描對象從 `ViewModels/WebViewModel.swift` 換成 `App/NakiRuntime.swift`
/// （view model 已刪除，自動打牌引擎的建立與轉發點搬到組裝點）。
///
/// 掃法與 `SingleGameStoreSourceTests` / `PlatformDivergenceTests` 同一套：
/// 跳過純註解行（檔案裡刻意留了說明搬走了什麼的註解），只看會被編譯的程式碼。
final class AutoPlayEngineSourceTests: XCTestCase {

    private func commandSourceRoot() throws -> URL {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // NakiTests/
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("command")
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw XCTSkip("找不到原始碼目錄 \(root.path)（repo 被搬走時這個鎖失效）")
        }
        return root
    }

    private func codeLines(in file: URL) throws -> [(line: Int, text: String)] {
        let source = try String(contentsOf: file, encoding: .utf8)
        return source.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .filter { !$0.element.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .map { ($0.offset + 1, String($0.element)) }
    }

    /// 自動打牌的併發原語只剩 `AutoPlayEngine` 的那一個 Task 迴圈
    func testRuntimeHasNoTimerOrAsyncAfter() throws {
        let file = try commandSourceRoot()
            .appendingPathComponent("App/NakiRuntime.swift")
        let banned = ["Timer(", "Timer.scheduledTimer", "asyncAfter", "currentExecutionId"]

        let hits = try codeLines(in: file).filter { line in
            banned.contains { line.text.contains($0) }
        }

        XCTAssertTrue(
            hits.isEmpty,
            "輪詢與延遲已收進 `AutoPlayEngine`（單一 Task 迴圈 + Task.sleep）；實際: "
                + hits.map { "NakiRuntime.swift:\($0.line)" }.joined(separator: ", "))
    }

    /// 送出的決策順序只准有一份：組裝點不得再自己呼叫 gate／resolver／executor
    func testRuntimeDoesNotReimplementTheDecisionOrder() throws {
        let file = try commandSourceRoot()
            .appendingPathComponent("App/NakiRuntime.swift")
        let banned = ["AutoPlayGate.evaluate",
                      "AutoPlayDecisionResolver.resolve",
                      "AutoPlayActionExecutor.execute",
                      "AutoPassDispatcher.send",
                      "AutoConfirmDispatcher.send"]

        let hits = try codeLines(in: file).filter { line in
            banned.contains { line.text.contains($0) }
        }

        XCTAssertTrue(
            hits.isEmpty,
            "閘門 → resolver → executor 的順序只准存在於 `AutoPlayEngine`；實際: "
                + hits.map { "NakiRuntime.swift:\($0.line)" }.joined(separator: ", "))
    }

    /// p2-2 路線 A 的回歸鎖：Legacy path **不得**自己實作一條送出決策。
    ///
    /// 先前 `LegacyWebViewModel.triggerAutoPlayNow` 抄了一份 resolver → executor
    /// （沒有閘門、沒有重試），現在兩條 path 共用同一個 `AutoPlayEngine`，
    /// 而「Legacy 不自動送出」由 `AutoPlayAvailability.commit` 的模式收斂達成。
    func testNoSecondDecisionPathOutsideTheEngine() throws {
        let root = try commandSourceRoot()
        let banned = ["AutoPlayGate.evaluate",
                      "AutoPlayDecisionResolver.resolve",
                      "AutoPlayActionExecutor.execute",
                      "AutoPassDispatcher.send",
                      "AutoConfirmDispatcher.send"]

        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        else { return XCTFail("無法列舉 \(root.path)") }

        var hits: [String] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
            guard relative != "Services/Bot/AutoPlayEngine.swift" else { continue }
            for line in try codeLines(in: url) where banned.contains(where: { line.text.contains($0) }) {
                hits.append("\(relative):\(line.line)")
            }
        }

        XCTAssertTrue(
            hits.isEmpty,
            "閘門 → resolver → executor 的順序只准存在於 `AutoPlayEngine`；實際: "
                + hits.joined(separator: ", "))
    }
}
