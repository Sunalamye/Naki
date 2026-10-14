//
//  BridgeCharacterizationTests.swift
//  NakiTests
//
//  鎖住 `MajsoulBridge` 的 start_kyoku／鳴牌／oplist 現況：Liqi bytes 進，MJAI 事件、fault、oplist 快照出，
//  與版控內的 `Fixtures/bridge-characterization.json` 逐字比對。
//  `ReplayFingerprintTests` 重放的是 MJAI 事件流，不經 LiqiParser／MajsoulBridge，所以重構前後的等價由這裡鎖。
//
//  fixture 缺席時寫入實際輸出並失敗（第一次錄製）；有意改變行為時，刪掉 fixture 重錄並在 diff 看清楚差在哪。
//

import XCTest

@testable import Naki

@MainActor
final class BridgeCharacterizationTests: XCTestCase {

    private let accountId = 123456
    private static let hand13 = ["1m", "2m", "3m", "4m", "5m", "6m", "7m", "8m", "9m", "1p", "2p", "3p", "4p"]

    private func packed(_ values: [Int]) -> [UInt8] {
        values.flatMap { LiqiEncoder.encodeVarint(UInt64(bitPattern: Int64($0))) }
    }

    private func action(_ name: String, _ fields: [LiqiField]) -> Data {
        var out: [UInt8] = [LiqiMsgType.notify.rawValue]
        out += LiqiEncoder.encodeStringField(field: 1, value: ".lq.ActionPrototype")
        let proto = LiqiEncoder.encodeFields([
            .varint(field: 1, value: 7), .string(field: 2, value: name),
            .bytes(field: 3, value: Array(liqiDecode(Data(LiqiEncoder.encodeFields(fields)))))
        ])
        out += LiqiEncoder.encodeLengthDelimited(field: 2, bytes: proto)
        return Data(out)
    }

    private func response(msgId: UInt16, fields: [LiqiField]) -> Data {
        Data(LiqiEncoder.encodeEnvelope(type: .response, msgId: msgId, method: "",
                                        payload: LiqiEncoder.encodeFields(fields)))
    }

    private func newRound(chang: Int? = 0, ju: Int? = 0, tiles: [String] = BridgeCharacterizationTests.hand13,
                          dora: String? = nil, doras: [String] = [], scores: LiqiField? = .bytes(field: 6, value: [0xa8, 0xc4, 0x01, 0xa8, 0xc4, 0x01, 0xa8, 0xc4, 0x01, 0xa8, 0xc4, 0x01]),
                          operation: LiqiField? = nil) -> Data {
        var f: [LiqiField] = []
        if let chang { f.append(.varint(field: 1, value: UInt64(bitPattern: Int64(chang)))) }
        if let ju { f.append(.varint(field: 2, value: UInt64(bitPattern: Int64(ju)))) }
        f.append(.varint(field: 3, value: 2))
        f += tiles.map { .string(field: 4, value: $0) }
        if let dora { f.append(.string(field: 5, value: dora)) }
        if let scores { f.append(scores) }
        if let operation { f.append(operation) }
        f.append(.varint(field: 8, value: 1))
        f += doras.map { .string(field: 14, value: $0) }
        return action("ActionNewRound", f)
    }

    private func oplist(seat: Int, types: [(Int, [String])]) -> LiqiField {
        .message(field: 7, fields: [.varint(field: 1, value: UInt64(seat))] + types.map { type, combo in
            .message(field: 2, fields: [.varint(field: 1, value: UInt64(type))] + combo.map { .string(field: 2, value: $0) })
        })
    }

    private func snapshotSync(msgId: UInt16, snapshot: [LiqiField]?, actions: [(String, [LiqiField])] = []) -> [Data] {
        let restore: [LiqiField] = (snapshot.map { [.bytes(field: 1, value: LiqiEncoder.encodeFields($0))] } ?? [])
            + actions.map { name, data in
                .message(field: 2, fields: [.varint(field: 1, value: 1), .string(field: 2, value: name),
                                            .bytes(field: 3, value: LiqiEncoder.encodeFields(data))])
            }
        return [
            Data(LiqiEncoder.encodeRequest(method: ".lq.FastTest.syncGame", fields: [], msgId: msgId)),
            response(msgId: msgId, fields: [.message(field: 4, fields: restore)])
        ]
    }

    private func snap(chang: Int = 1, ju: Int = 2, hands: [String], doras: [String] = [], scores: [Int?] = [28000, 26000, 24000, 22000]) -> [LiqiField] {
        [.varint(field: 1, value: UInt64(chang)), .varint(field: 2, value: UInt64(ju)), .varint(field: 3, value: 3),
         .varint(field: 4, value: 1)]
        + hands.map { .string(field: 6, value: $0) } + doras.map { .string(field: 7, value: $0) }
        + [.varint(field: 8, value: 1)]
        + scores.map { s in .message(field: 9, fields: s.map { [.int(field: 1, value: $0)] } ?? []) }
    }

    private func meld(_ seat: Int, type: Int?, tiles: [String], froms: [Int]?) -> Data {
        var f: [LiqiField] = [.varint(field: 1, value: UInt64(seat))]
        if let type { f.append(.varint(field: 2, value: UInt64(type))) }
        f += tiles.map { .string(field: 3, value: $0) }
        if let froms { f.append(.bytes(field: 4, value: packed(froms))) }
        return action("ActionChiPengGang", f)
    }

    private func gang(_ seat: Int, type: Int, tile: String) -> Data {
        action("ActionAnGangAddGang", [.varint(field: 1, value: UInt64(seat)), .varint(field: 2, value: UInt64(type)),
                                       .string(field: 3, value: tile)])
    }

    private func discard(_ seat: Int, _ tile: String) -> Data {
        action("ActionDiscardTile", [.varint(field: 1, value: UInt64(seat)), .string(field: 2, value: tile)])
    }

    private func dealWithOplist(_ seat: Int, _ tile: String, operation: LiqiField) -> Data {
        action("ActionDealTile", [.varint(field: 1, value: UInt64(seat)), .string(field: 2, value: tile), operation])
    }

    private func op(seat: Int, entries: [LiqiField]) -> LiqiField {
        .message(field: 4, fields: [.varint(field: 1, value: UInt64(seat))] + entries)
    }

    private func opEntry(_ type: Int?, _ combo: [String] = []) -> LiqiField {
        .message(field: 2, fields: (type.map { [LiqiField.varint(field: 1, value: UInt64($0))] } ?? [])
                 + combo.map { .string(field: 2, value: $0) })
    }

    private struct Scenario {
        let name: String
        var seatList: [Int]? = nil
        var frames: [Data]
    }

    private func scenarios() -> [Scenario] {
        let h = Self.hand13
        let sanma = [2, 3, accountId]
        var out: [Scenario] = []
        func add(_ name: String, seatList: [Int]? = nil, _ frames: [Data]) {
            out.append(Scenario(name: name, seatList: seatList, frames: frames))
        }

        // ActionNewRound
        add("newRound.plain", [newRound()])
        add("newRound.oya14", [newRound(ju: 2, tiles: h + ["7z"])])
        add("newRound.dora5", [newRound(dora: "4p")])
        add("newRound.doras14", [newRound(doras: ["3p", "4p"])])
        add("newRound.dora5AndDoras14", [newRound(dora: "3p", doras: ["3p"]), gang(0, type: 2, tile: "1m")])
        add("newRound.doraInvalid", [newRound(doras: ["8z"])])
        add("newRound.kanDoraAfter", [newRound(doras: ["3p"]),
                                      action("ActionDealTile", [.varint(field: 1, value: 1), .string(field: 2, value: "5p"),
                                                                .string(field: 6, value: "3p"), .string(field: 6, value: "4p")])])
        add("newRound.changOut", [newRound(chang: 4)])
        add("newRound.changNegative", [newRound(chang: -1)])
        add("newRound.juOut", [newRound(ju: 4)])
        add("newRound.changJuAbsent", [newRound(chang: nil, ju: nil)])
        add("newRound.scoresAbsent", [newRound(scores: nil)])
        add("newRound.scoresThree4P", [newRound(scores: .bytes(field: 6, value: packed([25000, 25000, 25000])))])
        add("newRound.scoresGarbage", [newRound(scores: .bytes(field: 6, value: [0xff, 0xff]))])
        add("newRound.scoresNegative", [newRound(scores: .bytes(field: 6, value: packed([-100, 25000, 25000, 50100])))])
        add("newRound.tiles12", [newRound(tiles: Array(h.prefix(12)))])
        add("newRound.tiles15", [newRound(tiles: h + ["7z", "6z"])])
        add("newRound.blockedThenHealthy", [newRound(scores: nil), newRound()])
        add("newRound.blockedDropsEvents", [newRound(chang: 9),
                                            action("ActionDealTile", [.varint(field: 1, value: 1), .string(field: 2, value: "5p")])])
        add("newRound.sanma", seatList: sanma,
            [newRound(scores: .bytes(field: 6, value: packed([35000, 35000, 35000])))])
        add("newRound.sanmaFourScores", seatList: sanma, [newRound()])
        add("newRound.sanmaOya", seatList: sanma,
            [newRound(ju: 1, tiles: h + ["7z"], scores: .bytes(field: 6, value: packed([35000, 35000, 35000])))])
        add("newRound.opEmpty", [newRound(operation: oplist(seat: 2, types: []))])
        add("newRound.opValid", [newRound(ju: 2, tiles: h + ["7z"], operation: oplist(seat: 2, types: [(1, []), (9, [])]))])
        add("newRound.opWithoutType", [newRound(operation: .message(field: 7, fields: [
            .varint(field: 1, value: 2), .message(field: 2, fields: [.string(field: 2, value: "1m|2m")])]))])

        // 重連快照
        add("snapshot.plain13", snapshotSync(msgId: 100, snapshot: snap(hands: h, doras: ["3p", "4p", "5p"])))
        add("snapshot.tsumo14", snapshotSync(msgId: 100, snapshot: snap(hands: h + ["7z"], doras: ["3p"])))
        add("snapshot.withMeld11", snapshotSync(msgId: 100, snapshot: snap(hands: Array(h.prefix(11)), doras: ["3p"])))
        add("snapshot.noDoras", snapshotSync(msgId: 100, snapshot: snap(hands: h)))
        add("snapshot.doraInvalid", snapshotSync(msgId: 100, snapshot: snap(hands: h, doras: ["8z", "3p"])))
        add("snapshot.noTiles", snapshotSync(msgId: 100, snapshot: snap(hands: [])))
        add("snapshot.changOut", snapshotSync(msgId: 100, snapshot: snap(chang: 5, hands: h)))
        add("snapshot.juOut", snapshotSync(msgId: 100, snapshot: snap(ju: 6, hands: h)))
        add("snapshot.scoresThree4P", snapshotSync(msgId: 100, snapshot: snap(hands: h, scores: [1, 2, 3])))
        add("snapshot.scoresZeroOmitted", snapshotSync(msgId: 100, snapshot: snap(hands: h, scores: [28000, nil, 24000, 22000])))
        add("snapshot.sanma", seatList: sanma, snapshotSync(msgId: 100, snapshot: snap(hands: h, scores: [35000, 35000, 35000])))
        add("snapshot.sanmaTsumo", seatList: sanma,
            snapshotSync(msgId: 100, snapshot: snap(hands: h + ["7z"], doras: ["3p", "4p"], scores: [35000, 35000, 35000])))
        add("snapshot.seatBeyondCount", seatList: [5, 6, 7, 8, accountId], snapshotSync(msgId: 100, snapshot: snap(hands: h)))
        add("snapshot.withActionsDealDiscard", snapshotSync(msgId: 100, snapshot: snap(hands: h, doras: ["3p", "4p"]), actions: [
            ("ActionDealTile", [.varint(field: 1, value: 1), .string(field: 6, value: "3p"), .string(field: 6, value: "4p")]),
            ("ActionDiscardTile", [.varint(field: 1, value: 1), .string(field: 2, value: "5p")])]))
        add("snapshot.actionsWithNewRound", snapshotSync(msgId: 100, snapshot: snap(hands: ["9s"]), actions: [
            ("ActionNewRound", [.varint(field: 1, value: 0), .varint(field: 2, value: 0), .varint(field: 3, value: 0)]
                + h.map { .string(field: 4, value: $0) } + [.bytes(field: 6, value: packed([25000, 25000, 25000, 25000]))]),
            ("ActionDiscardTile", [.varint(field: 1, value: 0), .string(field: 2, value: "1m")])]))
        add("snapshot.blockedThenNewRound", snapshotSync(msgId: 100, snapshot: snap(hands: [])) + [newRound()])

        // 鳴牌
        let pre = [newRound()]
        add("meld.chiFroms", pre + [meld(0, type: 0, tiles: ["0p", "4p", "6p"], froms: [3, 0, 0])])
        add("meld.chiFromsPaiLast", pre + [meld(1, type: 0, tiles: ["4m", "5m", "3m"], froms: [1, 1, 0])])
        add("meld.chiNoFroms", pre + [meld(1, type: 0, tiles: ["4p", "5p", "6p"], froms: nil)])
        add("meld.chiNoFromsDuplicate", pre + [meld(1, type: 0, tiles: ["4p", "4p", "5p"], froms: nil)])
        add("meld.chiFromsMismatch", pre + [meld(1, type: 0, tiles: ["4p", "5p", "6p"], froms: [0, 1])])
        add("meld.chiAllSelf", pre + [meld(1, type: 0, tiles: ["4p", "5p", "6p"], froms: [1, 1, 1])])
        add("meld.chiNoTiles", pre + [meld(1, type: 0, tiles: [], froms: nil)])
        add("meld.chiTypeAbsentRed", pre + [meld(1, type: nil, tiles: ["4m", "0m", "6m"], froms: [0, 1, 1])])
        add("meld.chiTypeAbsentDropped", pre + [meld(1, type: nil, tiles: ["1m", "2m", "4m"], froms: [0, 1, 1])])
        add("meld.chiTypeAbsentSanma", seatList: sanma, [newRound()] + [meld(1, type: nil, tiles: ["1p", "2p", "3p"], froms: [0, 1, 1])])
        add("meld.ponFroms", pre + [meld(1, type: 1, tiles: ["5p", "0p", "5p"], froms: [0, 1, 1])])
        add("meld.ponNoFroms", pre + [discard(0, "7s"), meld(1, type: 1, tiles: ["7s", "7s", "7s"], froms: nil)])
        add("meld.ponNoFromsNoDiscard", pre + [meld(1, type: 1, tiles: ["7s"], froms: nil)])
        add("meld.ponSanmaNoFroms", seatList: sanma, [newRound(scores: .bytes(field: 6, value: packed([35000, 35000, 35000])))]
            + [meld(0, type: 1, tiles: ["7s"], froms: nil)])
        add("meld.daiminkanFroms", pre + [meld(3, type: 2, tiles: ["5s", "5s", "0s", "5s"], froms: [0, 3, 3, 3])])
        add("meld.daiminkanNoFroms", pre + [meld(3, type: 2, tiles: ["5s"], froms: nil)])
        add("meld.typeOutOfRange", pre + [meld(1, type: 7, tiles: ["1m", "2m", "3m"], froms: [0, 1, 1])])
        add("meld.invalidTile", pre + [meld(1, type: 0, tiles: ["1m", "2m", "8z"], froms: [0, 1, 1])])
        add("gang.ankan", pre + [gang(0, type: 3, tile: "5m"), gang(1, type: 3, tile: "7z"), gang(1, type: 3, tile: "0p")])
        add("gang.kakan", pre + [gang(0, type: 2, tile: "5m"), gang(0, type: 2, tile: "0m"), gang(1, type: 2, tile: "3s")])
        add("gang.unknownType", pre + [gang(0, type: 1, tile: "5m")])
        add("gang.noTile", pre + [action("ActionAnGangAddGang", [.varint(field: 1, value: 0), .varint(field: 2, value: 3)])])

        // oplist（BR-11）
        add("oplist.noOperation", pre + [discard(1, "5p")])
        add("oplist.valid", pre + [dealWithOplist(2, "5p", operation: op(seat: 2, entries: [opEntry(1), opEntry(9)]))])
        add("oplist.validThenCleared", pre + [dealWithOplist(2, "5p", operation: op(seat: 2, entries: [opEntry(1)])), discard(1, "6p")])
        add("oplist.emptyList", pre + [dealWithOplist(2, "5p", operation: op(seat: 2, entries: []))])
        add("oplist.seatAbsent", pre + [dealWithOplist(2, "5p", operation: .message(field: 4, fields: [opEntry(1)]))])
        add("oplist.entriesWithoutType", pre + [dealWithOplist(2, "5p", operation: op(seat: 2, entries: [opEntry(nil, ["1m|2m"])]))])
        add("oplist.mixedTypes", pre + [dealWithOplist(2, "5p", operation: op(seat: 2, entries: [opEntry(nil), opEntry(2, ["4p|6p"])]))])
        add("oplist.otherSeat", pre + [dealWithOplist(3, "5p", operation: op(seat: 3, entries: [opEntry(1)]))])
        return out
    }

    private func startedBridge(seatList: [Int]?, state: LiqiParseFaultState, operations: LiqiOperationStore) -> (bridge: MajsoulBridge, startGame: [[String: Any]]?) {
        let bridge = MajsoulBridge(faultState: state, operations: operations)
        _ = bridge.observeOutgoing(Data(LiqiEncoder.encodeRequest(method: ".lq.Lobby.oauth2Login", fields: [], msgId: 1)))
        _ = bridge.parse(response(msgId: 1, fields: [.varint(field: 2, value: UInt64(accountId))]))
        _ = bridge.observeOutgoing(Data(LiqiEncoder.encodeRequest(
            method: ".lq.FastTest.authGame",
            fields: [.varint(field: 1, value: UInt64(accountId)), .string(field: 2, value: "token"), .string(field: 3, value: "uuid")],
            msgId: 41)))
        let startGame = bridge.parse(response(msgId: 41, fields: [
            .bytes(field: 3, value: packed(seatList ?? [2, 3, accountId, 4]))]))
        return (bridge, startGame)
    }

    private func run(_ scenario: Scenario) -> [String: Any] {
        let state = LiqiParseFaultState()
        let operations = LiqiOperationStore()
        let (bridge, startGame) = startedBridge(seatList: scenario.seatList, state: state, operations: operations)

        var frames: [Any] = []
        var allEvents: [[String: Any]] = startGame ?? []
        for frame in scenario.frames {
            let events = bridge.parse(frame) ?? []
            allEvents += events
            frames.append(events)
        }
        let latest = operations.latest
        return [
            "events": allEvents,
            "frames": frames,
            "faults": state.recent.map { "\($0.severity)|\($0.site)|\($0.fieldId.map(String.init) ?? "-")" },
            "blocking": state.blocking?.site ?? "none",
            "oplist": latest.map { [
                "seat": $0.seat, "rawTypes": $0.rawTypes, "tile": $0.contextTile ?? "-", "source": $0.source,
                "combos": $0.operations.map(\.combination)
            ] as [String: Any] } ?? ["none": true],
            "pending": operations.pending != nil
        ]
    }

    func testBridgeOutputMatchesRecordedCharacterization() throws {
        var actual: [String: Any] = [:]
        for scenario in scenarios() {
            actual[scenario.name] = run(scenario)
        }
        let data = try JSONSerialization.data(withJSONObject: actual, options: [.sortedKeys, .prettyPrinted])
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/bridge-characterization.json")
        guard let recorded = try? Data(contentsOf: url) else {
            try data.write(to: url)
            return XCTFail("fixture 缺席，已錄製：\(url.path)")
        }
        if recorded != data {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("bridge-characterization-actual-\(UUID().uuidString).json")
            try? data.write(to: tmp)
            addTeardownBlock { try? FileManager.default.removeItem(at: tmp) }
            let old = (try? JSONSerialization.jsonObject(with: recorded) as? [String: Any]) ?? [:]
            let changed = actual.keys.filter { key in
                let a = try? JSONSerialization.data(withJSONObject: actual[key]!, options: [.sortedKeys])
                let b = old[key].flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
                return a != b
            }.sorted()
            XCTFail("與錄製的輸出不同：\(changed)（實際輸出：\(tmp.path)）")
        }
    }

    // MARK: - 可觀察輸出：fault.reason 與 log（與重構前 7c2fe26 逐字相同）

    /// 只數 `action` 執行期間（兩個 fence 之間）寫入的 log，不受 LogManager 條目上限影響。
    private func logCount(containing text: String, during action: () -> Void) async -> Int {
        func fence() async -> String {
            let message = "fence-\(UUID().uuidString)"
            bridgeLog(message)
            for _ in 0..<200 where !LogManager.shared.entries.contains(where: { $0.message == message }) {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            return message
        }
        let start = await fence()
        action()
        let end = await fence()
        let messages = LogManager.shared.entries.map(\.message)
        guard let from = messages.lastIndex(of: start), let to = messages.lastIndex(of: end), from < to else { return -1 }
        return messages[from..<to].filter { $0.contains(text) }.count
    }

    /// 把 LogManager 灌到上限，且舊條目含被數的文字：以總數相減的寫法會因舊條目被擠掉而漂移。
    private func floodLog() {
        for i in 0..<5100 { bridgeLog("flood parseNewRound: 場= 的 operation 是空的 \(i)") }
    }

    private func blockingReason(_ frames: [Data]) -> String? {
        let state = LiqiParseFaultState()
        let (bridge, _) = startedBridge(seatList: nil, state: state, operations: LiqiOperationStore())
        frames.forEach { _ = bridge.parse($0) }
        return state.blocking?.reason
    }

    func testBlockingFaultReasonsMatchPreRefactorText() {
        let h = Self.hand13
        let sync = { (snapshot: [LiqiField]) in self.snapshotSync(msgId: 100, snapshot: snapshot) }
        XCTAssertEqual(blockingReason([newRound(chang: 4)]),
                       "場風或莊家座位超出範圍（chang=4, ju=0） → 不發 start_kyoku，這一局不做推薦")
        XCTAssertEqual(blockingReason([newRound(scores: nil)]),
                       "拿不到本局起始點數（scores=nil，is3P=false） → 不發 start_kyoku，這一局不做推薦")
        XCTAssertEqual(blockingReason([newRound(tiles: Array(h.prefix(12)))]),
                       "起手牌張數不對（tiles.count=12） → 不發 start_kyoku，這一局不做推薦")
        XCTAssertEqual(blockingReason(sync(snap(chang: 5, hands: h))),
                       "重連快照的場風或莊家座位超出範圍（chang=5, ju=2）→ 不發 start_kyoku")
        XCTAssertEqual(blockingReason(sync(snap(hands: h, scores: []))),
                       "重連快照拿不到點數（scores=nil，is3P=false） → 不發 start_kyoku")
        XCTAssertEqual(blockingReason(sync(snap(hands: []))), "重連快照沒有手牌 → 不發 start_kyoku")
    }

    func testRoundLogPrintsAfterRangeGuardOnly() async {
        floodLog()
        let marker = "parseNewRound: 場="
        let (bridge, _) = startedBridge(seatList: nil, state: LiqiParseFaultState(), operations: LiqiOperationStore())

        var count = await logCount(containing: marker) { _ = bridge.parse(newRound(chang: 4)) }
        XCTAssertEqual(count, 0, "範圍守衛失敗時不得印「場=」")

        count = await logCount(containing: marker) { _ = bridge.parse(newRound(tiles: Array(Self.hand13.prefix(12)))) }
        XCTAssertEqual(count, 1, "守衛之後才失敗的路徑照印一行")

        count = await logCount(containing: marker) { _ = bridge.parse(newRound()) }
        XCTAssertEqual(count, 1)
    }

    func testEmptyOperationWarnsOnlyForActionNewRound() async {
        floodLog()
        let marker = "的 operation 是空的"
        let (bridge, _) = startedBridge(seatList: nil, state: LiqiParseFaultState(), operations: LiqiOperationStore())

        var count = await logCount(containing: marker) {
            _ = bridge.parse(dealWithOplist(2, "5m", operation: op(seat: 2, entries: [])))
        }
        XCTAssertEqual(count, 0, "別家動作附空 operation 是正常的，不得警告")

        count = await logCount(containing: marker) { _ = bridge.parse(newRound(operation: oplist(seat: 2, types: []))) }
        XCTAssertEqual(count, 1, "ActionNewRound 的空 operation 要警告")
    }
}
