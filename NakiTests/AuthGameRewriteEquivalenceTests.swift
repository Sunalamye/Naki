//
//  AuthGameRewriteEquivalenceTests.swift
//  NakiTests
//
//  N7：插件只改 authGame 回應中「自家那筆」PlayerGameView 的外觀欄位（avatar_id=2、title=3、
//  character=6、avatar_frame=8、views=10）時，Naki 的解析結果與 MJAI 事件流必須與改寫前完全相同。
//  封包全部在測試中組出，帳號 id 與暱稱都是匿名測試值。
//
//  - 等長改寫（模擬 v0.1 插件）：每個 varint 的值換成長度相同的值，整包 bytes 長度不變。
//  - 變長改寫（模擬日後 v1，僅供參考）：值變大、varint 變長，外層 length prefix 隨之改變。
//

import XCTest

@testable import Naki

@MainActor
final class AuthGameRewriteEquivalenceTests: XCTestCase {

    // MARK: - 最小 protobuf 走訪（只供改寫用）

    private struct Entry {
        var field: Int
        var wire: Int
        var varint: UInt64 = 0
        var bytes: [UInt8] = []
    }

    private func readVarint(_ b: [UInt8], _ i: inout Int) -> UInt64 {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while i < b.count {
            let byte = b[i]
            i += 1
            value |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { break }
            shift += 7
        }
        return value
    }

    private func walk(_ b: [UInt8]) -> [Entry] {
        var out: [Entry] = []
        var i = 0
        while i < b.count {
            let tag = readVarint(b, &i)
            var e = Entry(field: Int(tag >> 3), wire: Int(tag & 7))
            switch e.wire {
            case 0: e.varint = readVarint(b, &i)
            case 2:
                let n = Int(readVarint(b, &i))
                e.bytes = Array(b[i..<(i + n)])
                i += n
            default: XCTFail("測試封包不應出現 wire type \(e.wire)"); return out
            }
            out.append(e)
        }
        return out
    }

    private func serialize(_ entries: [Entry]) -> [UInt8] {
        entries.flatMap { e -> [UInt8] in
            e.wire == 0 ? LiqiEncoder.encodeVarintField(field: e.field, value: e.varint)
                        : LiqiEncoder.encodeLengthDelimited(field: e.field, bytes: e.bytes)
        }
    }

    // MARK: - 外觀欄位改寫

    /// 對 PlayerGameView 的外觀欄位套用 `f`：avatar_id(2)、title(3)、avatar_frame(8)、
    /// views(10).item_id、character(6).skin(5) 與 character.views(4).item_id。
    private func remapAppearance(_ player: [Entry], _ f: (UInt64) -> UInt64) -> [Entry] {
        func viewSlot(_ bytes: [UInt8]) -> [UInt8] {
            serialize(walk(bytes).map { var e = $0; if e.field == 2 { e.varint = f(e.varint) }; return e })
        }
        return player.map { entry in
            var e = entry
            switch (e.field, e.wire) {
            case (2, 0), (3, 0), (8, 0): e.varint = f(e.varint)
            case (10, 2): e.bytes = viewSlot(e.bytes)
            case (6, 2):
                e.bytes = serialize(walk(e.bytes).map { inner in
                    var c = inner
                    if c.field == 5 { c.varint = f(c.varint) }
                    if c.field == 4 { c.bytes = viewSlot(c.bytes) }
                    return c
                })
            default: break
            }
            return e
        }
    }

    /// 只改 account_id 等於 `selfId` 的那筆 players，其餘 bytes 原樣。
    private func rewriteSelfPlayer(_ auth: [UInt8], selfId: Int, _ edit: ([Entry]) -> [Entry]) -> [UInt8] {
        serialize(walk(auth).map { top in
            guard top.field == 2, top.wire == 2 else { return top }
            let player = walk(top.bytes)
            guard player.first(where: { $0.field == 1 })?.varint == UInt64(selfId) else { return top }
            var e = top
            e.bytes = serialize(edit(player))
            return e
        })
    }

    /// 等長：XOR 1 只翻最低位元，值仍落在同一個 2 的冪區間，varint 長度必定不變。
    private let equalLength: (UInt64) -> UInt64 = { $0 ^ 1 }
    /// 變長：外觀 id 原為 3 bytes（< 2_097_152），加 1 億後為 4 bytes。
    private let variableLength: (UInt64) -> UInt64 = { $0 + 100_000_000 }

    // MARK: - 封包組裝

    private static let selfId = 90_003
    private static let selfNickname = "TestSelf"

    private struct Table {
        let name: String
        let ids: [Int]            // 依座位順序
        let selfIndex: Int
        let withSeatList: Bool
        var reconnect = false
        var is3P: Bool { ids.count == 3 }
    }

    private static let tables = [
        Table(name: "four", ids: [90_001, 90_002, selfId, 90_004], selfIndex: 2, withSeatList: true),
        Table(name: "three", ids: [90_001, selfId, 90_003 + 7], selfIndex: 1, withSeatList: true),
        Table(name: "noSeatList", ids: [90_001, 90_002, 90_005, selfId], selfIndex: 3, withSeatList: false),
        Table(name: "reconnect", ids: [selfId, 90_002, 90_005, 90_004], selfIndex: 0, withSeatList: true, reconnect: true)
    ]

    private func playerView(id: Int, nickname: String, seed: UInt64) -> LiqiField {
        .message(field: 2, fields: [
            .varint(field: 1, value: UInt64(id)),
            .varint(field: 2, value: 400_101 + seed),
            .varint(field: 3, value: 600_001 + seed),
            .string(field: 4, value: nickname),
            .message(field: 5, fields: [.varint(field: 1, value: 10_301), .varint(field: 2, value: 1_200)]),
            .message(field: 6, fields: [
                .varint(field: 1, value: 200_001 + seed), .varint(field: 2, value: 5),
                .message(field: 4, fields: [.varint(field: 1, value: 1), .varint(field: 2, value: 305_500 + seed)]),
                .varint(field: 5, value: 400_101 + seed)]),
            .varint(field: 8, value: 305_001 + seed),
            .message(field: 10, fields: [.varint(field: 1, value: 0), .varint(field: 2, value: 305_700 + seed)]),
            .message(field: 10, fields: [.varint(field: 1, value: 1), .varint(field: 2, value: 305_800 + seed)])
        ])
    }

    private func authBytes(_ t: Table, isGameStart: Bool = false) -> [UInt8] {
        var fields = t.ids.enumerated().map { index, id in
            playerView(id: id, nickname: id == Self.selfId ? Self.selfNickname : "TestPlayer\(index)", seed: UInt64(index))
        }
        if t.withSeatList { fields.append(.bytes(field: 3, value: packed(t.ids))) }
        fields.append(.bool(field: 4, value: isGameStart))
        return LiqiEncoder.encodeFields(fields)
    }

    private func packed(_ values: [Int]) -> [UInt8] {
        values.flatMap { LiqiEncoder.encodeVarint(UInt64($0)) }
    }

    private func response(msgId: UInt16, payload: [UInt8]) -> Data {
        Data(LiqiEncoder.encodeEnvelope(type: .response, msgId: msgId, method: "", payload: payload))
    }

    private func authGameRequest(msgId: UInt16) -> Data {
        Data(LiqiEncoder.encodeRequest(
            method: ".lq.FastTest.authGame",
            fields: [.varint(field: 1, value: UInt64(Self.selfId)), .string(field: 2, value: "token"),
                     .string(field: 3, value: "game-uuid")],
            msgId: msgId))
    }

    private func prototype(_ name: String, _ fields: [LiqiField]) -> Data {
        var out: [UInt8] = [LiqiMsgType.notify.rawValue]
        out += LiqiEncoder.encodeStringField(field: 1, value: ".lq.ActionPrototype")
        let proto = LiqiEncoder.encodeFields([
            .varint(field: 1, value: 7), .string(field: 2, value: name),
            .bytes(field: 3, value: Array(liqiDecode(Data(LiqiEncoder.encodeFields(fields)))))
        ])
        out += LiqiEncoder.encodeLengthDelimited(field: 2, bytes: proto)
        return Data(out)
    }

    private func newRound(players: Int) -> Data {
        let hand = ["1m", "2m", "3m", "4m", "6m", "7m", "8m", "9m", "1p", "2p", "3p", "4p", "5s"]
        var fields: [LiqiField] = [.varint(field: 1, value: 0), .varint(field: 2, value: 0), .varint(field: 3, value: 0)]
        fields += hand.map { .string(field: 4, value: $0) }
        fields.append(.string(field: 5, value: "3z"))
        fields.append(.bytes(field: 6, value: packed(Array(repeating: 25_000, count: players))))
        fields.append(.varint(field: 8, value: 0))
        return prototype("ActionNewRound", fields)
    }

    private func discard(seat: Int, tile: String) -> Data {
        prototype("ActionDiscardTile", [.varint(field: 1, value: UInt64(seat)), .string(field: 2, value: tile)])
    }

    // MARK: - 驅動 bridge

    /// 把整桌流程餵給全新的 bridge：登入 → authGame → 開局 → 打牌（重連桌再 reset 後重來一次）。
    /// `rewrite` 套用在每一個 authGame 回應的 payload 上；回傳可用 `isEqual` 比對的快照。
    private func play(_ t: Table, rewrite: (([UInt8]) -> [UInt8])? = nil) -> NSDictionary {
        let state = LiqiParseFaultState()
        let bridge = MajsoulBridge(faultState: state, operations: LiqiOperationStore())
        _ = bridge.observeOutgoing(Data(LiqiEncoder.encodeRequest(method: ".lq.Lobby.oauth2Login", fields: [], msgId: 1)))
        _ = bridge.parse(response(msgId: 1, payload: LiqiEncoder.encodeFields([.varint(field: 2, value: UInt64(Self.selfId))])))

        var authEvents: [Any] = []
        var parsedAuth: [Any] = []
        var laterEvents: [Any] = []

        func authenticate(msgId: UInt16, isGameStart: Bool) {
            _ = bridge.observeOutgoing(authGameRequest(msgId: msgId))
            let original = authBytes(t, isGameStart: isGameStart)
            authEvents.append(bridge.parse(response(msgId: msgId, payload: rewrite?(original) ?? original)) ?? [])
            parsedAuth.append(bridge.lastParsed?["data"] ?? [:])
            laterEvents.append(bridge.parse(newRound(players: t.ids.count)) ?? [])
            laterEvents.append(bridge.parse(discard(seat: 0, tile: "5s")) ?? [])
        }

        authenticate(msgId: 41, isGameStart: false)
        if t.reconnect {
            bridge.reset()
            authenticate(msgId: 42, isGameStart: true)
        }
        return [
            "authEvents": authEvents,
            "parsedAuth": parsedAuth,
            "laterEvents": laterEvents,
            "faults": state.recent.map { "\($0.severity)|\($0.site)|\($0.reason)" },
            "blocking": state.blocking?.site ?? "none"
        ]
    }

    private func startGame(_ snapshot: NSDictionary) -> [String: Any]? {
        ((snapshot["authEvents"] as? [[[String: Any]]])?.first ?? []).first { $0["type"] as? String == "start_game" }
    }

    // MARK: - 差異範圍

    /// 改寫前後：頂層 entry 數相同；除自家那筆 players 外 bytes 逐字相同；
    /// 自家那筆的 account_id(1) 與 nickname(4) 不動，且至少一個外觀欄位不同。
    private func assertDiffConfinedToSelfAppearance(_ before: [UInt8], _ after: [UInt8], file: StaticString = #filePath, line: UInt = #line) {
        let a = walk(before), b = walk(after)
        XCTAssertEqual(a.count, b.count, "頂層 entry 數", file: file, line: line)
        var selfPlayerChanged = false
        for (x, y) in zip(a, b) {
            let isSelf = x.field == 2 && walk(x.bytes).first(where: { $0.field == 1 })?.varint == UInt64(Self.selfId)
            if !isSelf {
                XCTAssertEqual(serialize([x]), serialize([y]), "非自家那筆的欄位 \(x.field) 被改動", file: file, line: line)
                continue
            }
            let px = walk(x.bytes), py = walk(y.bytes)
            for field in [1, 4] {
                XCTAssertEqual(serialize(px.filter { $0.field == field }), serialize(py.filter { $0.field == field }),
                               "自家 players 的欄位 \(field) 不可動", file: file, line: line)
            }
            selfPlayerChanged = x.bytes != y.bytes
        }
        XCTAssertTrue(selfPlayerChanged, "改寫沒有動到自家外觀欄位，測試無鑑別力", file: file, line: line)
    }

    // MARK: - 基準情境（非空轉）

    func testBaselineScenariosProduceExpectedStartGame() throws {
        for t in Self.tables {
            let start = try XCTUnwrap(startGame(play(t)), "\(t.name) 基準沒有 start_game")
            XCTAssertEqual(start["id"] as? Int, t.selfIndex, t.name)
            XCTAssertEqual(start["is3P"] as? Bool, t.is3P, t.name)
            XCTAssertEqual((start["names"] as? [String])?.count, t.ids.count, t.name)
            XCTAssertEqual((start["names"] as? [String])?[t.selfIndex], Self.selfNickname, t.name)
        }
        let heuristic = play(Self.tables[2])
        XCTAssertTrue((heuristic["faults"] as? [String] ?? []).contains { $0.contains("ResAuthGame.seat_list") },
                      "缺 seat_list 要留下 heuristic fault")
        XCTAssertEqual(play(Self.tables[0])["blocking"] as? String, "none")
    }

    // MARK: - 等長改寫（v0.1）

    func testEqualLengthAppearanceRewriteLeavesBridgeOutputUnchanged() {
        for t in Self.tables {
            let rewrite: ([UInt8]) -> [UInt8] = { auth in
                self.rewriteSelfPlayer(auth, selfId: Self.selfId) { self.remapAppearance($0, self.equalLength) }
            }
            let original = authBytes(t), rewritten = rewrite(original)
            XCTAssertEqual(original.count, rewritten.count, "\(t.name) 等長改寫後整包長度必須相同")
            assertDiffConfinedToSelfAppearance(original, rewritten)
            let before = play(t), after = play(t, rewrite: rewrite)
            XCTAssertTrue(before.isEqual(to: after as! [AnyHashable: Any]), "\(t.name) 改寫前後的解析或事件流不同")
        }
    }

    // MARK: - 變長改寫（日後 v1，僅供參考）

    /// 參考：v0.1 不需要。變長改寫會讓自家 players 與外層 length prefix 變長，Naki 的解析仍須不變。
    func testVariableLengthAppearanceRewriteLeavesBridgeOutputUnchanged_reference() {
        for t in Self.tables {
            let rewrite: ([UInt8]) -> [UInt8] = { auth in
                self.rewriteSelfPlayer(auth, selfId: Self.selfId) { self.remapAppearance($0, self.variableLength) }
            }
            let original = authBytes(t), rewritten = rewrite(original)
            XCTAssertGreaterThan(rewritten.count, original.count, "\(t.name) 變長改寫應使整包變長")
            assertDiffConfinedToSelfAppearance(original, rewritten)
            XCTAssertTrue(play(t).isEqual(to: play(t, rewrite: rewrite) as! [AnyHashable: Any]), "\(t.name) 變長改寫後輸出不同")
        }
    }

    // MARK: - 反向鎖：誤動 account_id／seat_list／nickname 必須被這組斷言抓到

    func testMisrewritingAccountIdIsDetected() {
        for t in [Self.tables[0], Self.tables[2]] {
            let bad: ([UInt8]) -> [UInt8] = { auth in
                self.rewriteSelfPlayer(auth, selfId: Self.selfId) { player in
                    player.map { var e = $0; if e.field == 1 { e.varint += 1 }; return e }
                }
            }
            XCTAssertFalse(play(t).isEqual(to: play(t, rewrite: bad) as! [AnyHashable: Any]),
                           "\(t.name) 誤改 account_id 沒被偵測到")
        }
        // 缺 seat_list 時座位由 players 順序推出，自家 account_id 被改後找不到座位 → 不發 start_game。
        let bad: ([UInt8]) -> [UInt8] = { auth in
            self.rewriteSelfPlayer(auth, selfId: Self.selfId) { $0.map { var e = $0; if e.field == 1 { e.varint += 1 }; return e } }
        }
        XCTAssertNil(startGame(play(Self.tables[2], rewrite: bad)))
    }

    func testMisrewritingSeatListIsDetected() {
        let t = Self.tables[0]
        let bad: ([UInt8]) -> [UInt8] = { auth in
            self.serialize(self.walk(auth).map { top in
                guard top.field == 3 else { return top }
                var e = top
                e.bytes = self.packed(Array(t.ids.reversed()))
                return e
            })
        }
        let after = play(t, rewrite: bad)
        XCTAssertFalse(play(t).isEqual(to: after as! [AnyHashable: Any]))
        XCTAssertEqual(startGame(after)?["id"] as? Int, 1, "seat_list 反轉後自家座位應從 2 變成 1")
    }

    func testMisrewritingNicknameIsDetected() {
        let t = Self.tables[0]
        let bad: ([UInt8]) -> [UInt8] = { auth in
            self.rewriteSelfPlayer(auth, selfId: Self.selfId) { player in
                player.map { var e = $0; if e.field == 4 { e.bytes = Array("Changed".utf8) }; return e }
            }
        }
        XCTAssertFalse(play(t).isEqual(to: play(t, rewrite: bad) as! [AnyHashable: Any]))
    }

    // MARK: - varint 長度邊界

    /// 等長改寫可行與否取決於「實際值」的 varint 長度，不是欄位型別。
    func testVarintLengthDependsOnValueAndCrossesAt16384() {
        let lengths: [(UInt64, Int)] = [(127, 1), (128, 2), (16_383, 2), (16_384, 3), (2_097_151, 3), (2_097_152, 4)]
        for (value, length) in lengths {
            XCTAssertEqual(LiqiEncoder.encodeVarint(value).count, length, "\(value)")
        }
        func inPlacePossible(_ old: UInt64, _ new: UInt64) -> Bool {
            LiqiEncoder.encodeVarint(old).count == LiqiEncoder.encodeVarint(new).count
        }
        XCTAssertTrue(inPlacePossible(16_382, 16_383))
        XCTAssertFalse(inPlacePossible(16_383, 16_384), "跨 16383／16384 邊界，等長改寫不可行")
        XCTAssertFalse(inPlacePossible(16_384, 16_383))
        XCTAssertTrue(inPlacePossible(16_384, 16_385))
        for value in [0, 1, 127, 128, 16_383, 16_384, 2_097_152, 305_001] as [UInt64] {
            XCTAssertTrue(inPlacePossible(value, value ^ 1), "\(value) ^ 1 應與原值同長")
        }
    }

    /// title 從 16383 換成 16384：整包多 1 byte，自家 players 的 length prefix 隨之重算，
    /// Naki 的解析仍不變。插件端若以 in-place 補丁處理，這個案例必須走變長路徑。
    func testTitleCrossingVarintBoundaryChangesPacketLengthButNotBridgeOutput() {
        var t = Self.tables[0]
        t = Table(name: "boundary", ids: t.ids, selfIndex: t.selfIndex, withSeatList: true)
        let setTitle: (UInt64) -> ([UInt8]) -> [UInt8] = { value in
            { auth in
                self.rewriteSelfPlayer(auth, selfId: Self.selfId) { player in
                    player.map { var e = $0; if e.field == 3 { e.varint = value }; return e }
                }
            }
        }
        let low = setTitle(16_383)(authBytes(t)), high = setTitle(16_384)(authBytes(t))
        XCTAssertEqual(high.count, low.count + 1, "16383 → 16384 讓整包多 1 byte")
        XCTAssertTrue(play(t, rewrite: setTitle(16_383)).isEqual(to: play(t, rewrite: setTitle(16_384)) as! [AnyHashable: Any]))
    }
}
