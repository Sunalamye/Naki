import XCTest

@testable import Naki

/// `LiqiRequestBuilder` / `LiqiActionSender` / `LiqiOperationStore` 單元測試。
///
/// 核心是**位元組層級對拍**：payload 的欄位編號、wire type、proto3 預設值省略，
/// 都必須與 docs/protocol/liqi.json 的定義一致，
/// 否則伺服器收到的是結構正確但語意錯誤的封包（最難除錯的一種錯）。
///
/// ⚠️ 這裡驗證的是「編碼正確」，**不是**「伺服器會接受」。
/// 操作 type 的數值語意、吃碰槓走哪個方法，仍需真實對局封包對拍。
final class LiqiActionSenderTests: XCTestCase {

    // MARK: - ② 動作層：payload 位元組

    /// 打牌：type=1 (08 01) + tile="5m" (1a 02 35 6d)，moqie=false 依 proto3 省略
    func testDiscardPayloadBytes() {
        let spec = LiqiRequestBuilder.discard(tile: "5m", moqie: false)

        XCTAssertEqual(spec.method, ".lq.FastTest.inputOperation")
        XCTAssertEqual(LiqiEncoder.hexString(spec.payload), "08011a02356d")
    }

    /// 摸切紅五：tile="0m"，moqie=true 才會出現 field 5（28 01）
    func testDiscardRedFiveMoqiePayloadBytes() {
        let spec = LiqiRequestBuilder.discard(tile: "0m", moqie: true)

        XCTAssertEqual(LiqiEncoder.hexString(spec.payload), "08011a02306d2801")
    }

    /// timeuse 是 field 6（30 0c = 12 秒）
    func testDiscardWithTimeuse() {
        let spec = LiqiRequestBuilder.discard(tile: "5m", moqie: false, timeuse: 12)

        XCTAssertEqual(LiqiEncoder.hexString(spec.payload), "08011a02356d300c")
    }

    /// 立直：type=7，並帶上宣言時要打出的牌
    func testRiichiPayloadBytes() {
        let spec = LiqiRequestBuilder.riichi(tile: "3s")

        XCTAssertEqual(spec.method, ".lq.FastTest.inputOperation")
        XCTAssertEqual(LiqiEncoder.hexString(spec.payload), "08071a023373")
    }

    /// 吃：走 inputChiPengGang，type=2 + index=2
    func testChiPayloadBytesAndMethod() {
        let spec = LiqiRequestBuilder.chi(index: 2)

        XCTAssertEqual(spec.method, ".lq.FastTest.inputChiPengGang")
        XCTAssertEqual(LiqiEncoder.hexString(spec.payload), "08021002")
    }

    /// 碰：index=0 為 proto3 預設值，省略後只剩 type
    func testPonPayloadOmitsDefaultIndex() {
        let spec = LiqiRequestBuilder.pon()

        XCTAssertEqual(spec.method, ".lq.FastTest.inputChiPengGang")
        XCTAssertEqual(LiqiEncoder.hexString(spec.payload), "0803")
    }

    /// 槓：暗槓/加槓走 inputOperation，大明槓走 inputChiPengGang
    func testKanRoutesByType() {
        let ankan = LiqiRequestBuilder.kan(type: .ankan)
        XCTAssertEqual(ankan.method, ".lq.FastTest.inputOperation")
        XCTAssertEqual(LiqiEncoder.hexString(ankan.payload), "0804")

        let kakan = LiqiRequestBuilder.kan(type: .kakan)
        XCTAssertEqual(kakan.method, ".lq.FastTest.inputOperation")
        XCTAssertEqual(LiqiEncoder.hexString(kakan.payload), "0806")

        let minkan = LiqiRequestBuilder.kan(type: .minkan)
        XCTAssertEqual(minkan.method, ".lq.FastTest.inputChiPengGang")
        XCTAssertEqual(LiqiEncoder.hexString(minkan.payload), "0805")
    }

    /// 自摸 / 榮和 / 九種九牌 / 拔北
    func testSelfOperationTypeValues() {
        XCTAssertEqual(LiqiEncoder.hexString(LiqiRequestBuilder.tsumo().payload), "0808")
        XCTAssertEqual(LiqiEncoder.hexString(LiqiRequestBuilder.ron().payload), "0809")
        XCTAssertEqual(LiqiEncoder.hexString(LiqiRequestBuilder.kyushu().payload), "080a")
        XCTAssertEqual(LiqiEncoder.hexString(LiqiRequestBuilder.babei().payload), "080b")
    }

    /// 跳過：cancel_operation 在兩個 message 裡是**不同欄位號**
    /// （ReqChiPengGang = 3 → 18 01，ReqSelfOperation = 4 → 20 01）
    func testCancelUsesDifferentFieldNumberPerMessage() {
        let call = LiqiRequestBuilder.cancel(channel: .chiPengGang)
        XCTAssertEqual(call.method, ".lq.FastTest.inputChiPengGang")
        XCTAssertEqual(LiqiEncoder.hexString(call.payload), "1801")

        let own = LiqiRequestBuilder.cancel(channel: .selfOperation)
        XCTAssertEqual(own.method, ".lq.FastTest.inputOperation")
        XCTAssertEqual(LiqiEncoder.hexString(own.payload), "2001")
    }

    // MARK: - ③ 大廳層：payload 位元組

    /// addRoomRobot：position=1 → 08 01
    func testAddRoomRobotPayloadBytes() {
        let spec = LiqiRequestBuilder.addRoomRobot(position: 1)

        XCTAssertEqual(spec.method, ".lq.Lobby.addRoomRobot")
        XCTAssertEqual(LiqiEncoder.hexString(spec.payload), "0801")
        XCTAssertEqual(LiqiEncoder.hexString(LiqiRequestBuilder.addRoomRobot(position: 3).payload),
                       "0803")
    }

    /// startRoom：ReqRoomStart 是空 message，payload 必須是 0 bytes，
    /// 但 envelope 仍要輸出 `12 00`（與實測 response 結構一致）
    func testStartRoomHasEmptyPayloadAndValidEnvelope() {
        let spec = LiqiRequestBuilder.startRoom()

        XCTAssertEqual(spec.method, ".lq.Lobby.startRoom")
        XCTAssertTrue(spec.payload.isEmpty)

        // msgId 60000 → little-endian 60 ea
        let bytes = spec.encoded(msgId: 60000)
        XCTAssertEqual(LiqiEncoder.hexString(bytes),
                       "0260ea0a132e6c712e4c6f6262792e7374617274526f6f6d1200")
    }

    /// leaveRoom / fetchRoom 同樣是空 payload 的 ReqCommon
    func testEmptyCommonRequests() {
        XCTAssertEqual(LiqiRequestBuilder.leaveRoom().method, ".lq.Lobby.leaveRoom")
        XCTAssertTrue(LiqiRequestBuilder.leaveRoom().payload.isEmpty)

        XCTAssertEqual(LiqiRequestBuilder.fetchRoom().method, ".lq.Lobby.fetchRoom")
        XCTAssertTrue(LiqiRequestBuilder.fetchRoom().payload.isEmpty)
    }

    /// joinRoom：room_id 為 varint（12345 → 08 b9 60）
    func testJoinRoomPayloadBytes() {
        let spec = LiqiRequestBuilder.joinRoom(roomId: 12345)

        XCTAssertEqual(spec.method, ".lq.Lobby.joinRoom")
        XCTAssertEqual(LiqiEncoder.hexString(spec.payload), "08b960")
    }

    /// createRoom：巢狀 GameMode(2) → GameDetailRule(6) 的長度前綴必須正確
    func testCreateRoomNestedPayloadBytes() {
        var config = LiqiFriendRoomConfig()
        config.playerCount = 4
        config.mode = 1
        config.timeFixed = 60
        config.timeAdd = 5
        config.doraCount = 3
        config.shiduan = 1
        config.initPoint = 25000
        config.fandian = 30000

        let spec = LiqiRequestBuilder.createRoom(config: config)

        XCTAssertEqual(spec.method, ".lq.Lobby.createRoom")
        // 08 04                      player_count = 4
        // 12 14                      mode（20 bytes）
        //    08 01                   GameMode.mode = 1
        //    32 10                   detail_rule（16 bytes）
        //       08 3c 10 05 18 03 20 01 28 a8 c3 01 30 b0 ea 01
        XCTAssertEqual(LiqiEncoder.hexString(spec.payload),
                       "0804121408013210083c10051803200128a8c30130b0ea01")
    }

    /// ai_level 是 field 38（>15 → tag 需要兩個 bytes：b0 02）
    func testCreateRoomAILevelUsesMultiByteTag() {
        var config = LiqiFriendRoomConfig()
        config.playerCount = 4
        config.mode = 1
        config.timeFixed = 0
        config.timeAdd = 0
        config.doraCount = 0
        config.shiduan = 0
        config.initPoint = 0
        config.fandian = 0
        config.aiLevel = 2

        let spec = LiqiRequestBuilder.createRoom(config: config)

        // 08 04                player_count = 4
        // 12 07                mode（7 bytes）
        //    08 01             GameMode.mode = 1
        //    32 03             detail_rule（3 bytes）
        //       b0 02 02       ai_level = 2（tag = 38<<3 = 304 → 兩個 bytes）
        XCTAssertEqual(LiqiEncoder.hexString(spec.payload), "0804120708013203b00202")
    }

    // MARK: - 牌字串轉換

    func testMJAIToMajsoulTileConversion() {
        XCTAssertEqual(LiqiTile.majsoul(fromMJAI: "5m"), "5m")
        XCTAssertEqual(LiqiTile.majsoul(fromMJAI: "5mr"), "0m")
        XCTAssertEqual(LiqiTile.majsoul(fromMJAI: "5pr"), "0p")
        XCTAssertEqual(LiqiTile.majsoul(fromMJAI: "5sr"), "0s")
        XCTAssertEqual(LiqiTile.majsoul(fromMJAI: "E"), "1z")
        XCTAssertEqual(LiqiTile.majsoul(fromMJAI: "N"), "4z")
        XCTAssertEqual(LiqiTile.majsoul(fromMJAI: "C"), "7z")

        XCTAssertNil(LiqiTile.majsoul(fromMJAI: "?"))
        XCTAssertNil(LiqiTile.majsoul(fromMJAI: "0m"), "MJAI 沒有 0m 這種寫法")
        XCTAssertNil(LiqiTile.majsoul(fromMJAI: "3mr"), "只有 5 有紅寶牌")
        XCTAssertNil(LiqiTile.majsoul(fromMJAI: "1zz"))
    }

    func testMajsoulToMJAITileConversion() {
        XCTAssertEqual(LiqiTile.mjai(fromMajsoul: "0m"), "5mr")
        XCTAssertEqual(LiqiTile.mjai(fromMajsoul: "5m"), "5m")
        XCTAssertEqual(LiqiTile.mjai(fromMajsoul: "1z"), "E")
        XCTAssertNil(LiqiTile.mjai(fromMajsoul: "zz"))
    }

    /// 兩個方向必須互為反函數（紅五也要 round-trip）
    func testTileConversionRoundTrip() {
        for suit in ["m", "p", "s"] {
            for number in 1...9 {
                let mjai = "\(number)\(suit)"
                let majsoul = LiqiTile.majsoul(fromMJAI: mjai)
                XCTAssertEqual(majsoul, mjai)
                XCTAssertEqual(LiqiTile.mjai(fromMajsoul: majsoul!), mjai)
            }
            let red = "5\(suit)r"
            XCTAssertEqual(LiqiTile.majsoul(fromMJAI: red), "0\(suit)")
            XCTAssertEqual(LiqiTile.mjai(fromMajsoul: "0\(suit)"), red)
        }
        for honor in ["E", "S", "W", "N", "P", "F", "C"] {
            let majsoul = LiqiTile.majsoul(fromMJAI: honor)
            XCTAssertNotNil(majsoul)
            XCTAssertEqual(LiqiTile.mjai(fromMajsoul: majsoul!), honor)
        }
    }

    // MARK: - oplist 快照

    /// pending 在 markHandled 之後就不該再回值（避免重試框架重送同一動作）
    func testOperationStorePendingLifecycle() {
        let store = LiqiOperationStore()
        XCTAssertNil(store.pending)

        let snapshot = store.record(seat: 0,
                                    operations: [LiqiOperation(type: .discard)],
                                    source: "ActionDealTile")
        XCTAssertEqual(store.pending?.sequence, snapshot.sequence)

        store.markHandled(snapshot.sequence)
        XCTAssertNil(store.pending)
        XCTAssertNotNil(store.latest, "已處理的快照仍保留供診斷")

        // 新的機會會有更大的 sequence，重新變成 pending
        let next = store.record(seat: 0, operations: [LiqiOperation(type: .pon)], source: "x")
        XCTAssertGreaterThan(next.sequence, snapshot.sequence)
        XCTAssertNotNil(store.pending)

        store.clear()
        XCTAssertNil(store.pending)
        XCTAssertNil(store.latest)
    }

    /// 從 LiqiParser 的字典建立快照（key 名稱必須與 parser 一致）
    func testOperationStoreFromParsedDictionary() {
        let store = LiqiOperationStore()
        let parsed: [String: Any] = [
            "seat": 2,
            "timeAdd": 20,
            "timeFixed": 5,
            "operationList": [
                ["type": 2, "combination": ["4m|5m", "2m|4m"]],
                ["type": 9]
            ]
        ]

        let snapshot = store.record(fromParsed: parsed, contextTile: "3m", source: "ActionDiscardTile")

        XCTAssertEqual(snapshot?.seat, 2)
        XCTAssertEqual(snapshot?.timeAdd, 20)
        XCTAssertEqual(snapshot?.timeFixed, 5)
        XCTAssertEqual(snapshot?.rawTypes, [2, 9])
        XCTAssertEqual(snapshot?.operation(of: .chi)?.combination, ["4m|5m", "2m|4m"])
        XCTAssertEqual(snapshot?.isCallOpportunity, true)
        XCTAssertEqual(snapshot?.horaOperation, .ron)

        // 空的 operationList 不建立快照（不覆蓋既有資料）
        XCTAssertNil(store.record(fromParsed: ["seat": 1, "operationList": [[String: Any]()]]))
        XCTAssertNil(store.record(fromParsed: ["seat": 1]))
    }

    /// 吃：用 combination 與被吃的牌反推 Mortal 的 chi_low/mid/high 對應索引
    func testChiCombinationIndexResolution() {
        let store = LiqiOperationStore()
        // 他家打 3m，可吃組合：1m|2m（3m 最大）、2m|4m（3m 在中間）、4m|5m（3m 最小）
        let snapshot = store.record(
            seat: 0,
            operations: [LiqiOperation(type: .chi, combination: ["1m|2m", "2m|4m", "4m|5m"])],
            contextTile: "3m",
            source: "ActionDiscardTile")

        XCTAssertEqual(snapshot.chiCombinationIndex(variant: 0), 2, "chi_low → 被吃的牌最小")
        XCTAssertEqual(snapshot.chiCombinationIndex(variant: 1), 1, "chi_mid → 被吃的牌在中間")
        XCTAssertEqual(snapshot.chiCombinationIndex(variant: 2), 0, "chi_high → 被吃的牌最大")
    }

    /// 紅五（0m）在組合中要當成 5 來比大小
    func testChiCombinationIndexHandlesRedFive() {
        let store = LiqiOperationStore()
        let snapshot = store.record(
            seat: 0,
            operations: [LiqiOperation(type: .chi, combination: ["0m|6m", "3m|4m"])],
            contextTile: "7m",
            source: "ActionDiscardTile")

        // 0m(=5m)|6m → 7m 最大 → chi_high；3m|4m 不成順，會被略過
        XCTAssertEqual(snapshot.chiCombinationIndex(variant: 2), 0)
        XCTAssertNil(snapshot.chiCombinationIndex(variant: 0))
    }

    func testChiCombinationIndexReturnsNilWithoutContext() {
        let store = LiqiOperationStore()
        let snapshot = store.record(seat: 0,
                                    operations: [LiqiOperation(type: .chi, combination: ["1m|2m"])],
                                    source: "x")

        XCTAssertNil(snapshot.chiCombinationIndex(variant: 0), "沒有被吃的牌就無法對照")
    }

    /// 槓型優先序：暗槓 → 加槓 → 大明槓
    func testKanOperationPriority() {
        let store = LiqiOperationStore()
        let both = store.record(seat: 0,
                                operations: [LiqiOperation(type: .kakan),
                                             LiqiOperation(type: .ankan)],
                                source: "x")
        XCTAssertEqual(both.kanOperation, .ankan)

        let minkanOnly = store.record(seat: 0,
                                      operations: [LiqiOperation(type: .minkan)],
                                      source: "x")
        XCTAssertEqual(minkanOnly.kanOperation, .minkan)
        XCTAssertEqual(minkanOnly.isCallOpportunity, true)

        let selfTurn = store.record(seat: 0,
                                    operations: [LiqiOperation(type: .discard),
                                                 LiqiOperation(type: .riichi)],
                                    source: "x")
        XCTAssertNil(selfTurn.kanOperation)
        XCTAssertEqual(selfTurn.isCallOpportunity, false)
    }

    /// 未知 type 不得硬塞進 enum，但仍要保留原始值
    func testUnknownOperationTypeIsPreserved() {
        let operation = LiqiOperation(rawType: 99)

        XCTAssertNil(operation.type)
        XCTAssertEqual(operation.rawType, 99)
    }

    // MARK: - Sender（用假送出閉包驅動）

    /// 送出鏈：spec → envelope → base64 → sendHandler，且 msgId 落在保留區段
    @MainActor
    func testSenderEncodesEnvelopeAndReportsSuccess() async {
        let sender = LiqiActionSender()
        var captured: [String] = []
        sender.sendHandler = { base64 in
            captured.append(base64)
            return LiqiRawSendResult(success: true, detail: "socket=0 bytes=26")
        }

        let result = await sender.startRoom()

        XCTAssertEqual(captured.count, 1)
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.method, ".lq.Lobby.startRoom")
        XCTAssertGreaterThanOrEqual(result.msgId, LiqiMsgIdAllocator.rangeStart)
        XCTAssertLessThanOrEqual(result.msgId, LiqiMsgIdAllocator.rangeEnd)

        // 解回 bytes，確認 envelope 與 msgId 對得上
        let bytes = [UInt8](Data(base64Encoded: captured[0])!)
        XCTAssertEqual(result.byteCount, bytes.count)
        XCTAssertEqual(bytes[0], 0x02, "REQUEST")
        XCTAssertEqual(bytes[1], UInt8(result.msgId & 0x00FF))
        XCTAssertEqual(bytes[2], UInt8((result.msgId >> 8) & 0x00FF))
        XCTAssertEqual(LiqiEncoder.hexString(Array(bytes.dropFirst(3))),
                       "0a132e6c712e4c6f6262792e7374617274526f6f6d1200")

        // p4-2：msgId→method 的對照表全 Swift 只有 `LiqiParser.pendingRequests` 一份。
        // sender 不再自己記一份——送出面的 frame 經過 JS `ws.send` hook 回到 parser，
        // RESPONSE 才配得回方法名。這裡直接演一次那條路徑當回歸鎖。
        let parser = LiqiParser()
        XCTAssertEqual(parser.parse(Data(bytes))?["method"] as? String, ".lq.Lobby.startRoom")
        let response = parser.parse(Data(LiqiEncoder.encodeEnvelope(type: .response,
                                                                    msgId: result.msgId,
                                                                    method: "",
                                                                    payload: [])))
        XCTAssertEqual(response?["method"] as? String, ".lq.Lobby.startRoom",
                       "RESPONSE 只帶 msgId；方法名要由 parser 那一份對照表配回來")
    }

    /// 打牌送出的完整 base64 必須等於「envelope(msgId) 的 base64」
    @MainActor
    func testSenderDiscardBase64MatchesEncodedEnvelope() async {
        let sender = LiqiActionSender()
        var captured: String?
        sender.sendHandler = { base64 in
            captured = base64
            return LiqiRawSendResult(success: true, detail: nil)
        }

        let result = await sender.discard(tile: "0m", moqie: true)
        let expected = LiqiEncoder.base64String(
            LiqiRequestBuilder.discard(tile: "0m", moqie: true).encoded(msgId: result.msgId))

        XCTAssertEqual(captured, expected)
    }

    /// 沒有注入送出通道時必須回報失敗，而不是假裝成功
    @MainActor
    func testSenderWithoutHandlerFails() async {
        let sender = LiqiActionSender()
        var logs: [String] = []
        sender.logHandler = { logs.append($0) }

        let result = await sender.pon()

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.detail, "no_send_handler")
        XCTAssertFalse(logs.isEmpty, "失敗也要留下日誌")
    }

    /// JS 端回報失敗時要如實往上傳
    @MainActor
    func testSenderPropagatesJSFailureReason() async {
        let sender = LiqiActionSender()
        sender.sendHandler = { _ in .failure("no_open_majsoul_connection") }

        let result = await sender.pass()

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.detail, "no_open_majsoul_connection")
        XCTAssertEqual(result.method, ".lq.FastTest.inputChiPengGang")
    }
}
