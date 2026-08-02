//
//  AutoPlayFailsafeFixtureTests.swift
//  NakiTests
//
//  兩個 P0 fail-safe 分支的注入式驗收（AUDIT §12、§15.4）。
//
//  §15.4 的 live 實測寫得很清楚：**兩個 P0 的分支都沒有被執行。**
//  P0-1 要「推薦為空 ＋ oplist 有和牌」，實測兩次和牌模型都給 `hora@99.6%` 以上；
//  P0-2 要 hora send 失敗，兩次都是第 1 次就成功。要撞到它們只能注入。
//
//  這裡的三個 fixture 對應 CLAUDE.md 的完成判準與 tasks/naki/p0-5：
//
//      A. 空推薦 ＋ oplist `[8]`      → gate `.forceHora` → resolver hora → sender 真的被呼叫
//      B. hora send 第一次失敗        → 不 markHandled、重試、成功之後才收工
//      C. server `[1,7,8]` ＋ AI discard → resolver 覆蓋成 hora（送出的是 type=8 不是打牌）
//
//  斷言刻意落在**位元組**上（`12020808` = payload `08 08` = ReqSelfOperation type=8）：
//  「呼叫過 sender」不等於「送出的是和牌」，這兩者在漏和這件事上差很多。
//
//  實際跑過的 mutation（2026-08-02，改完跑、跑完還原）：
//  - 拿掉 `AutoPlayGate` 的 `if snapshot.horaOperation != nil { return .forceHora }`
//    → A、B、B'、D 轉紅（4 tests）
//  - resolver 的終局保護改成「只有推薦為空時才生效」
//    → C、C'、E 轉紅（另外 3 個既有 resolver 測試也紅）
//  - 把 `markHandled` 搬到送出之前 → B、B' 轉紅
//    ⚠️ 這一條動的是**本 harness**，不是 `WebViewModel`：正式的「成功才 markHandled」
//    寫在 `WebViewModel.executeAutoPlayAction` 裡，測試碰不到它（要等 p2-1 抽出 executor）。
//
//  ⚠️ 走的是 `AutoPlayFailsafePipeline`（harness），不是 `WebViewModel` 本體，
//  也不是 live 對局：CLAUDE.md 要求的 live fixture
//  「server `[1,7,8]` + AI discard → resolver hora → RESPONSE → ActionHule」**仍未驗證**。
//

import XCTest

@testable import Naki

final class AutoPlayFailsafeFixtureTests: XCTestCase {

    // MARK: - 共用

    /// 送出成功時 JS 端的回報形狀（實測 `{success:true, bytes, socketId}`）
    private func ok(_ bytes: Int = 26) -> LiqiRawSendResult {
        LiqiRawSendResult(success: true, detail: "socket=0 bytes=\(bytes)")
    }

    /// base64 → hex，用來確認送出去的真的是那個動作。
    ///
    /// 吃 optional 是刻意的：斷言失敗時（例如 mutation 讓一個 request 都沒送出去）
    /// 直接 `captured[0]` 會 index out of range 把整個 test host 打掉，
    /// 那會讓「哪一條斷言先破」看不出來。
    private func hex(_ base64: String?) -> String {
        guard let base64 else { return "(未送出)" }
        return LiqiEncoder.hexString([UInt8](Data(base64Encoded: base64) ?? Data()))
    }

    /// 自摸／榮和 request 的結尾：field 2（payload）＝ `08 08` / `08 09`
    private let tsumoPayloadSuffix = "12020808"
    private let ronPayloadSuffix = "12020809"

    // MARK: - Fixture A：空推薦 ＋ 伺服器給自摸

    /// 模型完全沒有意見，但伺服器在 oplist 裡給了自摸（type 8）。
    ///
    /// 舊行為是「recommendations 為空就不進主動作」——伺服器給了和牌也照樣放過，
    /// 那是漏自摸的直接成因。
    @MainActor
    func testFixtureA_emptyRecommendationWithServerTsumoStillDeclaresHora() async {
        let store = LiqiOperationStore()
        let sender = LiqiActionSender()
        var captured: [String] = []
        sender.sendHandler = { base64 in
            captured.append(base64)
            return self.ok()
        }

        let snapshot = store.record(seat: 0,
                                    operations: [LiqiOperation(type: .tsumo)],
                                    timeFixed: 300,
                                    contextTile: "5p",
                                    source: "ActionDealTile")

        let run = await AutoPlayFailsafePipeline(
            store: store, sender: sender, recommendations: []).run()

        XCTAssertEqual(run.gate, .forceHora, "空推薦 ＋ oplist 有和牌必須交給 resolver")
        XCTAssertEqual(run.outcome, .sent(action: .hora, tile: "5p", attempts: 1))

        XCTAssertEqual(captured.count, 1, "sender 必須真的被呼叫一次")
        XCTAssertEqual(sender.lastResult?.method, ".lq.FastTest.inputOperation")
        XCTAssertTrue(hex(captured.first).hasSuffix(tsumoPayloadSuffix),
                      "送出的必須是 ReqSelfOperation type=8，實際 bytes=\(hex(captured.first))")

        XCTAssertNil(store.pending, "送出成功之後才可以消化這批 oplist")
        XCTAssertEqual(store.latest?.sequence, snapshot.sequence, "latest 仍保留供診斷")
    }

    /// 同一批 oplist 在 `.off` 模式下一個 request 都不能送出（fail-safe 不是「永遠送」）
    @MainActor
    func testFixtureA_offModeNeverSendsEvenWhenServerOffersHora() async {
        let store = LiqiOperationStore()
        let sender = LiqiActionSender()
        var sendCount = 0
        sender.sendHandler = { _ in
            sendCount += 1
            return self.ok()
        }
        let snapshot = store.record(seat: 0,
                                    operations: [LiqiOperation(type: .tsumo)],
                                    contextTile: "5p",
                                    source: "ActionDealTile")

        var pipeline = AutoPlayFailsafePipeline(store: store, sender: sender)
        pipeline.mode = .off
        let run = await pipeline.run()

        XCTAssertEqual(run.gate, .skip(.notAutoMode))
        XCTAssertEqual(sendCount, 0)
        XCTAssertEqual(store.pending?.sequence, snapshot.sequence, "沒送出就不能消化")
    }

    // MARK: - Fixture B：hora send 失敗

    /// 第一次送出失敗 → 不可以 markHandled，必須重送；成功之後才收工。
    @MainActor
    func testFixtureB_horaSendFailureRetriesAndOnlyMarksHandledAfterSuccess() async {
        let store = LiqiOperationStore()
        let sender = LiqiActionSender()
        var attempts = 0
        var pendingSeenDuringSend: [UInt64?] = []
        sender.sendHandler = { _ in
            attempts += 1
            // 送出當下這批 oplist 必須還在（否則就是「先 mark 再送」）
            pendingSeenDuringSend.append(store.pending?.sequence)
            return attempts >= 2 ? self.ok() : .failure("no_open_majsoul_connection")
        }

        let snapshot = store.record(seat: 0,
                                    operations: [LiqiOperation(type: .tsumo)],
                                    contextTile: "5p",
                                    source: "ActionDealTile")

        let run = await AutoPlayFailsafePipeline(
            store: store, sender: sender, recommendations: [], maxAttempts: 3).run()

        XCTAssertEqual(attempts, 2, "第一次失敗必須重送")
        XCTAssertEqual(run.outcome, .sent(action: .hora, tile: "5p", attempts: 2))
        XCTAssertEqual(pendingSeenDuringSend, [snapshot.sequence, snapshot.sequence],
                       "重試時看到的必須還是同一批 oplist（失敗沒有把它消化掉）")
        XCTAssertNil(store.pending, "成功之後才消化")
        XCTAssertTrue(run.log.contains { $0.contains("no_open_majsoul_connection") },
                      "JS 端回報的失敗原因要留在 log 裡")
    }

    /// 一路失敗到放棄 → oplist 必須保留，下一輪（通道恢復後）還能再送一次並成功。
    @MainActor
    func testFixtureB_horaAllSendsFailKeepOplistPendingForNextRound() async {
        let store = LiqiOperationStore()
        let sender = LiqiActionSender()
        var attempts = 0
        sender.sendHandler = { _ in
            attempts += 1
            return .failure("no_gateway")
        }

        let snapshot = store.record(seat: 0,
                                    operations: [LiqiOperation(type: .tsumo)],
                                    contextTile: "5p",
                                    source: "ActionDealTile")

        let failed = await AutoPlayFailsafePipeline(
            store: store, sender: sender, recommendations: [], maxAttempts: 3).run()

        XCTAssertEqual(failed.outcome, .sendFailed(action: .hora, attempts: 3))
        XCTAssertEqual(attempts, 3, "重試次數要用滿")
        XCTAssertEqual(store.pending?.sequence, snapshot.sequence,
                       "一個 request 都沒送成功，不可以把和牌機會當成處理完")

        // 通道恢復後的下一輪：同一批 oplist 仍然可以和
        sender.sendHandler = { _ in self.ok() }
        let recovered = await AutoPlayFailsafePipeline(
            store: store, sender: sender, recommendations: [], maxAttempts: 3).run()

        XCTAssertEqual(recovered.gate, .forceHora)
        XCTAssertEqual(recovered.outcome, .sent(action: .hora, tile: "5p", attempts: 1))
        XCTAssertNil(store.pending)
    }

    // MARK: - Fixture C：server [1,7,8] ＋ AI 想 discard

    /// CLAUDE.md 完成判準裡的那一手：oplist `[discard, riichi, tsumo]`，Mortal 回 dahai。
    /// 合法性與終局價值的權威在伺服器不在模型，resolver 必須覆蓋成和牌。
    @MainActor
    func testFixtureC_serverHoraOverridesAIDiscardRecommendation() async {
        let store = LiqiOperationStore()
        let sender = LiqiActionSender()
        var captured: [String] = []
        sender.sendHandler = { base64 in
            captured.append(base64)
            return self.ok()
        }

        store.record(seat: 0,
                     operations: [LiqiOperation(type: .discard),
                                  LiqiOperation(type: .riichi),
                                  LiqiOperation(type: .tsumo)],
                     timeFixed: 300,
                     contextTile: "3s",
                     source: "ActionDealTile")

        let aiWantsToDiscard = [
            Recommendation(tile: "1m", probability: 0.87, actionType: .discard),
            Recommendation(tile: "9p", probability: 0.09, actionType: .discard)
        ]

        let run = await AutoPlayFailsafePipeline(
            store: store, sender: sender, recommendations: aiWantsToDiscard).run()

        XCTAssertEqual(run.gate, .proceed, "有推薦時走一般路徑，覆蓋發生在 resolver")
        XCTAssertEqual(run.outcome, .sent(action: .hora, tile: "3s", attempts: 1))
        XCTAssertEqual(run.overrode?.requested, .discard)
        XCTAssertEqual(run.overrode?.resolved, .hora)
        XCTAssertTrue(run.log.contains { $0.contains("決策覆蓋") }, "覆蓋必須留下可追的 log")

        XCTAssertEqual(captured.count, 1)
        XCTAssertTrue(hex(captured.first).hasSuffix(tsumoPayloadSuffix),
                      "送出的必須是自摸，不是 AI 想打的那張牌，實際 bytes=\(hex(captured.first))")
        XCTAssertNil(store.pending)
    }

    /// `.recommend` 模式下手動觸發：resolver 仍然把和牌排在 AI 推薦之上，
    /// 但只呈現不送出——「覆蓋」不等於「強制送出」。
    ///
    /// 走手動觸發是因為閘門在非自動模式直接 `.skip(.notAutoMode)`（上面 `.off` 那個
    /// 測試鎖住的就是這件事），resolver 的模式閘門只有在不經閘門的那條路上看得到。
    @MainActor
    func testFixtureC_recommendModeSurfacesHoraWithoutSending() async {
        let store = LiqiOperationStore()
        let sender = LiqiActionSender()
        var sendCount = 0
        sender.sendHandler = { _ in
            sendCount += 1
            return self.ok()
        }
        let snapshot = store.record(seat: 0,
                                    operations: [LiqiOperation(type: .discard),
                                                 LiqiOperation(type: .riichi),
                                                 LiqiOperation(type: .tsumo)],
                                    contextTile: "3s",
                                    source: "ActionDealTile")

        var pipeline = AutoPlayFailsafePipeline(
            store: store, sender: sender,
            recommendations: [Recommendation(tile: "1m", probability: 0.87, actionType: .discard)])
        pipeline.mode = .recommend

        let gated = await pipeline.run()
        XCTAssertEqual(gated.gate, .skip(.notAutoMode), "輪詢路徑在非自動模式一律不動")

        let manual = await pipeline.runManualTrigger()
        XCTAssertNil(manual.gate, "手動觸發不經閘門")
        XCTAssertEqual(manual.outcome, .surfaced(.hora), "resolver 仍把和牌排在 AI 推薦之上")
        XCTAssertEqual(sendCount, 0, "非自動模式一個 request 都不能送")
        XCTAssertEqual(store.pending?.sequence, snapshot.sequence)
    }

    // MARK: - 注入式（只有 DEBUG build 有這些入口）

    #if DEBUG

    /// Fixture D：碰＋榮和同時可用、寬限期已過、模型仍然沒有意見。
    ///
    /// `[3,9]` 兩者都是 `isCallOpportunity`：過了寬限期的舊路徑會走「主動送過」，
    /// 等於自己棄和。要擺出「3 秒前到達」只能注入 `capturedAt`（`record` 一律用當下）。
    @MainActor
    func testFixtureD_agedRonOpportunityWithoutRecommendationStillDeclaresHora() async {
        let store = LiqiOperationStore()
        let sender = LiqiActionSender()
        var captured: [String] = []
        sender.sendHandler = { base64 in
            captured.append(base64)
            return self.ok()
        }

        store.injectForTesting(LiqiOperationSnapshot(
            sequence: 7,
            seat: 0,
            operations: [LiqiOperation(type: .pon, combination: ["5m|5m"]),
                         LiqiOperation(type: .ron)],
            timeAdd: 0,
            timeFixed: 300,
            contextTile: "5m",
            source: "ActionDiscardTile",
            capturedAt: Date(timeIntervalSinceNow: -3.0)))

        let run = await AutoPlayFailsafePipeline(
            store: store, sender: sender, recommendations: []).run()

        XCTAssertEqual(run.gate, .forceHora,
                       "過了寬限期也不可以把伺服器給的和牌當成『模型判斷不做』")
        XCTAssertEqual(run.outcome, .sent(action: .hora, tile: "5m", attempts: 1))
        XCTAssertTrue(hex(captured.first).hasSuffix(ronPayloadSuffix),
                      "榮和是 type=9，實際 bytes=\(hex(captured.first))")
        XCTAssertNil(store.pending)
    }

    /// Fixture E：推薦來自真的 `NativeBotController`（注入，不跑 Core ML）。
    ///
    /// 驗的是「模型輸出 → 決策層」這一段接得起來，而不是把推薦寫死在測試裡。
    @MainActor
    func testFixtureE_controllerInjectedDiscardIsStillOverriddenByServerHora() async {
        let controller = NativeBotController()
        controller.injectRecommendationsForTesting([
            Recommendation(tile: "1m", probability: 0.91, actionType: .discard)
        ])
        XCTAssertEqual(controller.lastRecommendations.first?.actionType, .discard)

        let store = LiqiOperationStore()
        let sender = LiqiActionSender()
        var captured: [String] = []
        sender.sendHandler = { base64 in
            captured.append(base64)
            return self.ok()
        }
        store.record(seat: 0,
                     operations: [LiqiOperation(type: .discard),
                                  LiqiOperation(type: .riichi),
                                  LiqiOperation(type: .tsumo)],
                     contextTile: "3s",
                     source: "ActionDealTile")

        let run = await AutoPlayFailsafePipeline(
            store: store, sender: sender,
            recommendations: controller.lastRecommendations).run()

        XCTAssertEqual(run.outcome, .sent(action: .hora, tile: "3s", attempts: 1))
        XCTAssertEqual(run.overrode?.resolved, .hora)
        XCTAssertTrue(hex(captured.first).hasSuffix(tsumoPayloadSuffix))
    }

    /// Fixture D'：一模一樣的老化條件，但 oplist 裡**沒有**和牌 → 才可以送「過」。
    ///
    /// 跟 D 對照著看才有意義：同樣是「寬限期已過 ＋ 模型沒意見」，
    /// 有和牌就必須和、沒有才送過。閘門把這兩者分開，是 §18 那個
    /// 「把 85.9% 的碰蓋成過」的直接教訓。
    @MainActor
    func testFixtureD_agedCallOpportunityWithoutHoraSendsPassInstead() async {
        let store = LiqiOperationStore()
        let sender = LiqiActionSender()
        var captured: [String] = []
        sender.sendHandler = { base64 in
            captured.append(base64)
            return self.ok()
        }

        store.injectForTesting(LiqiOperationSnapshot(
            sequence: 3,
            seat: 0,
            operations: [LiqiOperation(type: .pon, combination: ["5m|5m"])],
            timeAdd: 0,
            timeFixed: 300,
            contextTile: "5m",
            source: "ActionDiscardTile",
            capturedAt: Date(timeIntervalSinceNow: -3.0)))

        let run = await AutoPlayFailsafePipeline(
            store: store, sender: sender, recommendations: [], maxAttempts: 3).run()

        XCTAssertEqual(run.gate, .sendPass)
        XCTAssertEqual(run.outcome, .passed(attempts: 1, handled: true))
        XCTAssertEqual(sender.lastResult?.method, ".lq.FastTest.inputChiPengGang",
                       "回應他家打牌的『過』走 inputChiPengGang")
        XCTAssertTrue(hex(captured.first).hasSuffix("12021801"),
                      "ReqChiPengGang.cancel_operation 是 field 3，實際 bytes=\(hex(captured.first))")
        XCTAssertNil(store.pending)
    }

    /// 注入不得破壞 store 的既有不變量：注入之後 `record` 的新快照仍要贏過舊的
    @MainActor
    func testInjectionKeepsSequenceMonotonic() {
        let store = LiqiOperationStore()
        store.injectForTesting(LiqiOperationSnapshot(
            sequence: 42, seat: 0,
            operations: [LiqiOperation(type: .tsumo)],
            timeAdd: 0, timeFixed: 300,
            contextTile: "5p", source: "injected", capturedAt: Date()))
        XCTAssertEqual(store.pending?.sequence, 42)

        store.markHandled(42)
        XCTAssertNil(store.pending, "注入的快照照樣受 markHandled 管")

        let next = store.record(seat: 0, operations: [LiqiOperation(type: .discard)], source: "next")
        XCTAssertGreaterThan(next.sequence, 42, "新到的 oplist 不可以被當成舊的")
        XCTAssertEqual(store.pending?.sequence, next.sequence)
    }

    #endif
}
