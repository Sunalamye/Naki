//
//  AutoPlayActionExecutorTests.swift
//  NakiTests
//
//  7-case 動作 switch 收斂成單一 executor 之後的回歸鎖（p2-1）。
//
//  收斂前這個 switch 有三份拷貝，而且已經漂移——Legacy 那份沒有任何診斷輸出、
//  沒有「吃的組合對照不到」的警告。要防止它再度分岔，唯一有效的手段是讓
//  **兩條路徑呼叫的是同一個有測試的函式**，而不是「請下次記得同步改」。
//
//  斷言刻意落在**位元組**上：「呼叫過 sender」不等於「送出的是那個動作」。
//  payload hex 對照 docs/protocol/liqi.json 的欄位編號（與 LiqiActionSenderTests 同一組）。
//

import XCTest

@testable import Naki

final class AutoPlayActionExecutorTests: XCTestCase {

    // MARK: - 共用

    /// 送出成功時 JS 端的回報形狀（實測 `{success:true, bytes, socketId}`）
    private func ok() -> LiqiRawSendResult {
        LiqiRawSendResult(success: true, detail: "socket=0 bytes=26")
    }

    /// base64 → hex。吃 optional：一個 request 都沒送出去時不要 index out of range
    /// 把 test host 打掉，那會讓「哪一條斷言先破」看不出來。
    private func hex(_ base64: String?) -> String {
        guard let base64 else { return "(未送出)" }
        return LiqiEncoder.hexString([UInt8](Data(base64Encoded: base64) ?? Data()))
    }

    /// 建一個會記下每次送出 base64 的 sender
    @MainActor
    private func recordingSender(success: Bool = true,
                                 captured: @escaping (String) -> Void) -> LiqiActionSender {
        let sender = LiqiActionSender()
        sender.sendHandler = { base64 in
            captured(base64)
            return success ? self.ok() : .failure("no_open_majsoul_connection")
        }
        return sender
    }

    // MARK: - 每一個 case 送出的是哪一種 request

    /// 打牌：MJAI `5m` → 雀魂 `5m`；tsumoTile 相同時 moqie=true（field 5 = `28 01`）
    @MainActor
    func testDiscardSendsSelfOperationAndHonoursMoqie() async {
        let store = LiqiOperationStore()
        var captured: [String] = []
        let sender = recordingSender { captured.append($0) }
        let snapshot = store.record(seat: 0,
                                    operations: [LiqiOperation(type: .discard)],
                                    source: "test")

        let result = await AutoPlayActionExecutor.execute(
            action: .discard, tile: "5m", snapshot: snapshot, recommendations: [],
            tsumoTile: "5m", sender: sender, store: store)

        XCTAssertEqual(result?.success, true)
        XCTAssertEqual(sender.lastResult?.method, ".lq.FastTest.inputOperation")
        XCTAssertTrue(hex(captured.first).hasSuffix("08011a02356d2801"),
                      "摸切必須帶 moqie=true，實際 bytes=\(hex(captured.first))")
        XCTAssertNil(store.pending, "送出成功才消化這批 oplist")
    }

    /// 非摸切：tsumoTile 不同就不能帶 moqie（proto3 省略 false）
    @MainActor
    func testDiscardWithoutMoqieOmitsField() async {
        let store = LiqiOperationStore()
        var captured: [String] = []
        let sender = recordingSender { captured.append($0) }
        let snapshot = store.record(seat: 0,
                                    operations: [LiqiOperation(type: .discard)],
                                    source: "test")

        await AutoPlayActionExecutor.execute(
            action: .discard, tile: "5m", snapshot: snapshot, recommendations: [],
            tsumoTile: "1p", sender: sender, store: store)

        XCTAssertTrue(hex(captured.first).hasSuffix("08011a02356d"),
                      "手切不可以宣稱摸切，實際 bytes=\(hex(captured.first))")
    }

    /// 立直：宣言牌取推薦裡機率最高的打牌（type=7 + tile）
    @MainActor
    func testRiichiUsesTopDiscardRecommendationAsDeclarationTile() async {
        let store = LiqiOperationStore()
        var captured: [String] = []
        let sender = recordingSender { captured.append($0) }
        let snapshot = store.record(seat: 0,
                                    operations: [LiqiOperation(type: .discard),
                                                 LiqiOperation(type: .riichi)],
                                    source: "test")

        let result = await AutoPlayActionExecutor.execute(
            action: .riichi, tile: "riichi", snapshot: snapshot,
            recommendations: [Recommendation(tile: "3s", probability: 0.9, actionType: .discard)],
            sender: sender, store: store)

        XCTAssertEqual(result?.success, true)
        XCTAssertTrue(hex(captured.first).hasSuffix("08071a023373"),
                      "立直必須帶宣言牌 3s，實際 bytes=\(hex(captured.first))")
        XCTAssertNil(store.pending)
    }

    /// 吃：`chi_1`（被吃的牌在中間）要對到 combination 裡的正確索引，不是照 mortal 的序號
    @MainActor
    func testChiMapsMortalVariantToMajsoulCombinationIndex() async {
        let store = LiqiOperationStore()
        var captured: [String] = []
        let sender = recordingSender { captured.append($0) }
        // 吃 3m：索引 0 是 chi_high(1m|2m)、索引 1 是 chi_mid(2m|4m)
        let snapshot = store.record(
            seat: 0,
            operations: [LiqiOperation(type: .chi, combination: ["1m|2m", "2m|4m"])],
            contextTile: "3m",
            source: "test")

        await AutoPlayActionExecutor.execute(
            action: .chi, tile: "chi_1", snapshot: snapshot, recommendations: [],
            sender: sender, store: store)

        XCTAssertEqual(sender.lastResult?.method, ".lq.FastTest.inputChiPengGang")
        XCTAssertTrue(hex(captured.first).hasSuffix("08021001"),
                      "chi_1 必須對到 index=1，實際 bytes=\(hex(captured.first))")
    }

    /// 對照不到組合時退回索引 0，而且**必須留下警告**——Legacy 那份漏的就是這行
    @MainActor
    func testChiWithoutMatchingCombinationFallsBackToZeroAndWarns() async {
        let store = LiqiOperationStore()
        var captured: [String] = []
        var logs: [String] = []
        let sender = recordingSender { captured.append($0) }
        let snapshot = store.record(
            seat: 0,
            operations: [LiqiOperation(type: .chi, combination: ["1m|2m"])],
            contextTile: "3m",
            source: "test")

        await AutoPlayActionExecutor.execute(
            action: .chi, tile: "chi_1", snapshot: snapshot, recommendations: [],
            sender: sender, store: store, log: { logs.append($0) })

        XCTAssertTrue(hex(captured.first).hasSuffix("0802"),
                      "退回索引 0（proto3 省略），實際 bytes=\(hex(captured.first))")
        XCTAssertTrue(logs.contains { $0.contains("無法對照組合") },
                      "退回保守索引是猜的，不可以靜默")
    }

    /// 槓型由 oplist 決定：只有加槓可用時就送加槓（type=6），不是預設的暗槓
    @MainActor
    func testKanTypeComesFromOplistNotDefault() async {
        let store = LiqiOperationStore()
        var captured: [String] = []
        let sender = recordingSender { captured.append($0) }
        let snapshot = store.record(seat: 0,
                                    operations: [LiqiOperation(type: .kakan)],
                                    source: "test")

        await AutoPlayActionExecutor.execute(
            action: .kan, tile: "", snapshot: snapshot, recommendations: [],
            sender: sender, store: store)

        XCTAssertEqual(sender.lastResult?.method, ".lq.FastTest.inputOperation")
        XCTAssertTrue(hex(captured.first).hasSuffix("12020806"),
                      "加槓是 type=6，實際 bytes=\(hex(captured.first))")
    }

    /// 和牌型也由 oplist 決定：oplist 只給榮和就送 type=9
    @MainActor
    func testHoraSendsRonWhenOplistOffersRon() async {
        let store = LiqiOperationStore()
        var captured: [String] = []
        let sender = recordingSender { captured.append($0) }
        let snapshot = store.record(seat: 0,
                                    operations: [LiqiOperation(type: .ron)],
                                    source: "test")

        await AutoPlayActionExecutor.execute(
            action: .hora, tile: "5p", snapshot: snapshot, recommendations: [],
            sender: sender, store: store)

        XCTAssertTrue(hex(captured.first).hasSuffix("12020809"),
                      "榮和是 type=9，實際 bytes=\(hex(captured.first))")
    }

    /// 「過」的通道由這批機會的類型決定：副露機會走 inputChiPengGang
    @MainActor
    func testPassChannelFollowsCallOpportunity() async {
        let store = LiqiOperationStore()
        var captured: [String] = []
        let sender = recordingSender { captured.append($0) }
        let call = store.record(seat: 0,
                                operations: [LiqiOperation(type: .pon, combination: ["5m|5m"])],
                                source: "test")

        await AutoPlayActionExecutor.execute(
            action: .none, tile: "", snapshot: call, recommendations: [],
            sender: sender, store: store)
        XCTAssertEqual(sender.lastResult?.method, ".lq.FastTest.inputChiPengGang")
        XCTAssertTrue(hex(captured.first).hasSuffix("12021801"),
                      "ReqChiPengGang.cancel_operation 是 field 3，實際 bytes=\(hex(captured.first))")

        // 自家回合的選項（例如只有暗槓可做）則走 inputOperation
        let selfTurn = store.record(seat: 0,
                                    operations: [LiqiOperation(type: .ankan)],
                                    source: "test")
        await AutoPlayActionExecutor.execute(
            action: .none, tile: "", snapshot: selfTurn, recommendations: [],
            sender: sender, store: store)
        XCTAssertEqual(sender.lastResult?.method, ".lq.FastTest.inputOperation")
        XCTAssertTrue(hex(captured.last).hasSuffix("12022001"),
                      "ReqSelfOperation.cancel_operation 是 field 4，實際 bytes=\(hex(captured.last))")
    }

    // MARK: - 沒送出去的路徑不可以消化 oplist（p0-1 的語意）

    /// 送出失敗 → oplist 必須仍然 pending，才可能重試
    @MainActor
    func testFailedSendKeepsOplistPending() async {
        let store = LiqiOperationStore()
        var captured: [String] = []
        let sender = recordingSender(success: false) { captured.append($0) }
        let snapshot = store.record(seat: 0,
                                    operations: [LiqiOperation(type: .discard)],
                                    source: "test")

        let result = await AutoPlayActionExecutor.execute(
            action: .discard, tile: "5m", snapshot: snapshot, recommendations: [],
            sender: sender, store: store)

        XCTAssertEqual(result?.success, false)
        XCTAssertEqual(captured.count, 1, "失敗也要真的送過一次")
        XCTAssertEqual(store.pending?.sequence, snapshot.sequence,
                       "送出失敗不可以把這批機會當成處理完")
    }

    /// 牌字串轉不了 → 一個 request 都沒送出，回 nil、保留 oplist、留下 event
    @MainActor
    func testUnconvertibleDiscardTileSendsNothingAndKeepsOplist() async {
        let store = LiqiOperationStore()
        var sendCount = 0
        var events: [String] = []
        let sender = recordingSender { _ in sendCount += 1 }
        let snapshot = store.record(seat: 0,
                                    operations: [LiqiOperation(type: .discard)],
                                    source: "test")

        let result = await AutoPlayActionExecutor.execute(
            action: .discard, tile: "not-a-tile", snapshot: snapshot, recommendations: [],
            sender: sender, store: store, event: { events.append($0) })

        XCTAssertNil(result, "組不出 request 與送出失敗要分得開")
        XCTAssertEqual(sendCount, 0)
        XCTAssertEqual(store.pending?.sequence, snapshot.sequence)
        XCTAssertTrue(events.contains { $0.contains("保留 oplist") }, "不能靜默吃掉這批機會")
    }

    /// 立直找不到宣言牌 → 同上（Legacy 那份原本是直接 return，連 log 都沒有）
    @MainActor
    func testRiichiWithoutDiscardRecommendationSendsNothingAndKeepsOplist() async {
        let store = LiqiOperationStore()
        var sendCount = 0
        var events: [String] = []
        let sender = recordingSender { _ in sendCount += 1 }
        let snapshot = store.record(seat: 0,
                                    operations: [LiqiOperation(type: .riichi)],
                                    source: "test")

        let result = await AutoPlayActionExecutor.execute(
            action: .riichi, tile: "riichi", snapshot: snapshot,
            recommendations: [Recommendation(actionType: .pon, probability: 0.5)],
            sender: sender, store: store, event: { events.append($0) })

        XCTAssertNil(result)
        XCTAssertEqual(sendCount, 0)
        XCTAssertEqual(store.pending?.sequence, snapshot.sequence)
        XCTAssertTrue(events.contains { $0.contains("立直") })
    }

    /// 未知動作 → 不送、不消化，而且要出聲（舊版只寫進 bridgeLog，events.log 看不到）
    @MainActor
    func testUnknownActionSendsNothing() async {
        let store = LiqiOperationStore()
        var sendCount = 0
        var events: [String] = []
        let sender = recordingSender { _ in sendCount += 1 }
        let snapshot = store.record(seat: 0,
                                    operations: [LiqiOperation(type: .discard)],
                                    source: "test")

        let result = await AutoPlayActionExecutor.execute(
            action: .unknown, tile: "", snapshot: snapshot, recommendations: [],
            sender: sender, store: store, event: { events.append($0) })

        XCTAssertNil(result)
        XCTAssertEqual(sendCount, 0)
        XCTAssertEqual(store.pending?.sequence, snapshot.sequence)
        XCTAssertFalse(events.isEmpty)
    }

    /// 沒有 snapshot 時仍可送出（手動觸發），但沒有任何一批機會可以被消化
    @MainActor
    func testSendWithoutSnapshotDoesNotTouchStore() async {
        let store = LiqiOperationStore()
        let sender = recordingSender { _ in }
        let snapshot = store.record(seat: 0,
                                    operations: [LiqiOperation(type: .discard)],
                                    source: "test")

        let result = await AutoPlayActionExecutor.execute(
            action: .discard, tile: "5m", snapshot: nil, recommendations: [],
            sender: sender, store: store)

        XCTAssertEqual(result?.success, true)
        XCTAssertEqual(store.pending?.sequence, snapshot.sequence,
                       "沒有指名快照就不可以順手消化現有的那批")
    }

    // MARK: - 第 2 層驗證（RESPONSE）：送成功但伺服器拒絕 ≠ 打成（p5-verify）

    /// 從送出的 base64 envelope 解出 msgId（[type][msgId LE][protobuf]），
    /// 注入一筆 RESPONSE 到 shared store，讓 `sendAwaitingResponse` 的輪詢查得到。
    @MainActor
    private func injectResponseForSend(hasError: Bool) -> LiqiActionSender {
        let sender = LiqiActionSender()
        sender.sendHandler = { base64 in
            if let data = Data(base64Encoded: base64), data.count >= 3 {
                let msgId = Int(data[1]) | (Int(data[2]) << 8)
                // field1 存在＝有 error（見 LiqiResponseRecord.hasError）
                let fields: [String: Any] = hasError ? ["field1": Data([0x08, 0xEC, 0x07])] : [:]
                LiqiResponseStore.shared.recordResponse(
                    msgId: msgId, method: ".lq.FastTest.inputOperation", fields: fields)
            }
            return self.ok()
        }
        return sender
    }

    /// sendRaw 成功但 RESPONSE 帶 error（模擬 1004 靜默拒絕）→ 不算成功、**不**消化 oplist。
    /// 這正是「東1莊家第一打送出去卻沒打成、要手動點」的根因。
    @MainActor
    func testServerRejectedDiscardIsNotConfirmedAndKeepsOplist() async {
        LiqiResponseStore.shared.reset()
        let store = LiqiOperationStore()
        let snapshot = store.record(seat: 0, operations: [LiqiOperation(type: .discard)], source: "test")
        let sender = injectResponseForSend(hasError: true)

        let result = await AutoPlayActionExecutor.execute(
            action: .discard, tile: "5m", snapshot: snapshot, recommendations: [],
            tsumoTile: "5m", sender: sender, store: store, awaitResponseMs: 500)

        XCTAssertEqual(result?.success, false, "sendRaw 成功但伺服器拒絕，不能算打成")
        XCTAssertNotNil(store.pending, "被拒絕就保留 oplist，交給重試框架再送")
        LiqiResponseStore.shared.reset()
    }

    /// sendRaw 成功且 RESPONSE 無 error → 第 2 層達成 → 消化 oplist。
    @MainActor
    func testServerAcceptedDiscardIsConfirmedAndConsumesOplist() async {
        LiqiResponseStore.shared.reset()
        let store = LiqiOperationStore()
        let snapshot = store.record(seat: 0, operations: [LiqiOperation(type: .discard)], source: "test")
        let sender = injectResponseForSend(hasError: false)

        let result = await AutoPlayActionExecutor.execute(
            action: .discard, tile: "5m", snapshot: snapshot, recommendations: [],
            tsumoTile: "5m", sender: sender, store: store, awaitResponseMs: 500)

        XCTAssertEqual(result?.success, true, "RESPONSE 無 error＝伺服器受理")
        XCTAssertNil(store.pending, "受理才消化這批 oplist")
        LiqiResponseStore.shared.reset()
    }
}
