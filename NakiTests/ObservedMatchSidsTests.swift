//
//  ObservedMatchSidsTests.swift
//  NakiTests
//
//  match_sid 從流量學習 + 統一匹配 request 組裝的測試。
//
//  背景（2026-08-09 實測）：對 `.lq.Lobby.matchGame` 送 match_mode 1／2／3
//  一律回 error 1306，而同一個帳號在同一分鐘內由客戶端送出的
//  `.lq.Lobby.startUnifiedMatch` 開局成功。段位場入口已經換人。
//
//  `match_sid` 是 string 且 `docs/protocol/liqi.json` 裡沒有任何訊息會產生它，
//  所以只能攔客戶端自己送的那一筆。
//

import XCTest

@testable import Naki

/// parser 只寫 `.shared`（預設落點 `SettingsStore.standard`），所以把它的落點換成獨立 suite，結束後還原。
@MainActor
func isolateSharedObservedMatchSids(_ testCase: XCTestCase) {
    let suite = "naki.tests.sids.shared.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    ObservedMatchSids.shared.redirect(to: defaults)
    testCase.addTeardownBlock { @MainActor in
        ObservedMatchSids.shared.redirect(to: SettingsStore.standard)
        defaults.removePersistentDomain(forName: suite)
    }
}

final class ObservedMatchSidsTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: ObservedMatchSids!

    @MainActor
    override func setUp() {
        super.setUp()
        suiteName = "naki.tests.sids.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = ObservedMatchSids.makeForTesting(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        store = nil
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    @MainActor
    func testRecordsObservation() {
        store.record(sid: "sid-abc", clientVersionString: "web-4.0.45")
        XCTAssertEqual(store.knownSids, ["sid-abc"])
        XCTAssertEqual(store.observations.count, 1)
        XCTAssertEqual(store.observations[0].count, 1)
    }

    /// 同一組重複出現要累加，不是塞出一堆重複紀錄
    @MainActor
    func testRepeatedObservationIncrementsCount() {
        for _ in 0..<4 { store.record(sid: "sid-abc", clientVersionString: "web-4.0.45") }
        XCTAssertEqual(store.observations.count, 1)
        XCTAssertEqual(store.observations[0].count, 4)
    }

    /// 同一個 sid 但版本字串不同要分開記：送出時兩個欄位是一組的
    @MainActor
    func testDifferentVersionRecordedSeparately() {
        store.record(sid: "sid-abc", clientVersionString: "web-4.0.45")
        store.record(sid: "sid-abc", clientVersionString: "web-4.0.46")
        XCTAssertEqual(store.observations.count, 2)
        XCTAssertEqual(store.knownSids, ["sid-abc"])
    }

    @MainActor
    func testEmptySidIsIgnored() {
        store.record(sid: "", clientVersionString: "web-4.0.45")
        XCTAssertTrue(store.observations.isEmpty)
    }

    /// 沒有觀察時必須說「還沒觀察到」，不能回一個猜的 sid
    @MainActor
    func testEmptyStateSaysSo() {
        let d = store.dictionary
        XCTAssertEqual((d["knownSids"] as? [String])?.isEmpty, true)
        XCTAssertTrue((d["note"] as? String)?.contains("還沒觀察到") == true)
        XCTAssertNil(d["latest"])
    }

    /// `latest` 是 `lobby_start_unified_match` 不帶參數時的唯一預設來源
    @MainActor
    func testLatestReturnsMostRecent() {
        store.record(sid: "old", clientVersionString: "v1")
        store.record(sid: "new", clientVersionString: "v2")
        XCTAssertEqual(store.latest?.sid, "new")
        XCTAssertEqual(store.latest?.clientVersionString, "v2")
    }

    /// 不得宣稱 sid 對應哪個場次——猜錯會把人送進錯的段位場
    @MainActor
    func testDoesNotClaimRoomMapping() {
        store.record(sid: "sid-abc", clientVersionString: "v1")
        let note = (store.dictionary["note"] as? String) ?? ""
        XCTAssertTrue(note.contains("不宣稱"))
    }

    // MARK: - Request 組裝

    /// `match_sid` 必須編成 protobuf **string**（wire type 2），不是舊的 varint match_mode
    func testStartUnifiedMatchEncodesStringFields() {
        let spec = LiqiRequestBuilder.startUnifiedMatch(
            matchSid: "abc", clientVersionString: "web-1")

        XCTAssertEqual(spec.method, ".lq.Lobby.startUnifiedMatch")
        // field1 = tag 0x0A(1<<3|2) len 3 "abc"；field2 = tag 0x12(2<<3|2) len 5 "web-1"
        XCTAssertEqual(LiqiEncoder.hexString(spec.payload), "0a0361626312057765622d31")
    }

    /// 版本字串留空時不送 field 2（proto3 省略空值，與 matchGame 同一慣例）
    func testStartUnifiedMatchOmitsEmptyVersion() {
        let spec = LiqiRequestBuilder.startUnifiedMatch(matchSid: "abc")
        XCTAssertEqual(LiqiEncoder.hexString(spec.payload), "0a03616263")
    }

    func testCancelUnifiedMatchEncodesSid() {
        let spec = LiqiRequestBuilder.cancelUnifiedMatch(matchSid: "abc")
        XCTAssertEqual(spec.method, ".lq.Lobby.cancelUnifiedMatch")
        XCTAssertEqual(LiqiEncoder.hexString(spec.payload), "0a03616263")
    }

    /// sid 為空時整個 payload 為空——不要送出一個「field 1 = 空字串」的假請求
    func testEmptySidProducesEmptyPayload() {
        let spec = LiqiRequestBuilder.startUnifiedMatch(matchSid: "")
        XCTAssertTrue(spec.payload.isEmpty)
    }
}

// MARK: - Parser 只寫 `.shared`（無法注入）

final class ObservedMatchSidsParserTests: XCTestCase {

    // MARK: - 只學遊戲自己送的

    /// Naki 自己送的 startUnifiedMatch **不得**進觀察表。
    ///
    /// 2026-08-09 實測踩過：用 `lobby_start_unified_match` 連試 8 個猜的 sid，
    /// 全部失敗（error 1303），卻全被記成「觀察到的真值」——而該工具不帶參數時
    /// 正是拿這份資料當預設，等於讓錯誤自我餵養。
    @MainActor
    func testDoesNotLearnFromNakiOwnRequest() async {
        isolateSharedObservedMatchSids(self)
        let parser = LiqiParser()
        let spec = LiqiRequestBuilder.startUnifiedMatch(matchSid: "naki-guess")

        // Naki 號段（60000+）＝ 這是我們自己送出去的
        _ = parser.parse(Data(LiqiEncoder.encodeRequest(
            method: spec.method, payload: spec.payload,
            msgId: LiqiMsgIdAllocator.rangeStart)))
        for _ in 0..<8 { await Task.yield() }

        XCTAssertTrue(ObservedMatchSids.shared.observations.isEmpty,
                      "Naki 自己送的猜測值不得被記成觀察結果")
    }

    /// 遊戲自己送的（低位遞增 msgId）才是真憑據
    @MainActor
    func testLearnsFromGameRequest() async {
        isolateSharedObservedMatchSids(self)
        let parser = LiqiParser()
        let spec = LiqiRequestBuilder.startUnifiedMatch(
            matchSid: "real-sid", clientVersionString: "0.11.252.w")

        // 遊戲自己用低位遞增號（實測 141、142…）
        _ = parser.parse(Data(LiqiEncoder.encodeRequest(
            method: spec.method, payload: spec.payload, msgId: 142)))
        for _ in 0..<8 { await Task.yield() }

        XCTAssertEqual(ObservedMatchSids.shared.latest?.sid, "real-sid")
        XCTAssertEqual(ObservedMatchSids.shared.latest?.clientVersionString, "0.11.252.w")
    }

    /// parser 寫觀察表是同步的（WP6 拿掉 actor hop）：`parse` 一回來就讀得到，不必 yield。
    /// 改回非同步時 `gameDidStart` 可能讀不到剛學到的 sid，這條會紅。
    @MainActor
    func testLearnsSynchronouslyWithoutYield() {
        isolateSharedObservedMatchSids(self)
        let spec = LiqiRequestBuilder.startUnifiedMatch(matchSid: "sync-sid", clientVersionString: "v1")

        _ = LiqiParser().parse(Data(LiqiEncoder.encodeRequest(
            method: spec.method, payload: spec.payload, msgId: 142)))

        XCTAssertEqual(ObservedMatchSids.shared.latest?.sid, "sync-sid")
    }

    // MARK: - 取消匹配與 seenAt（獨立 UserDefaults，不碰 .standard／.shared）

    @MainActor
    private func makeIsolatedStore(_ name: String) -> ObservedMatchSids {
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return ObservedMatchSids.makeForTesting(defaults: defaults)
    }

    /// 取消匹配後開出的友人房不得被回填成該 sid 的人數
    @MainActor
    func testCancelClearsAwaitingGameKind() {
        let store = makeIsolatedStore("naki.test.sids.cancel")
        store.record(sid: "ranked", clientVersionString: "v1")

        store.cancelAwaitingGameKind()
        store.gameDidStart(is3P: true)

        XCTAssertNil(store.observations[0].is3P)
    }

    @MainActor
    func testWithoutCancelGameStartBackfillsKind() {
        let store = makeIsolatedStore("naki.test.sids.backfill")
        store.record(sid: "ranked", clientVersionString: "v1")

        store.gameDidStart(is3P: true)

        XCTAssertEqual(store.observations[0].is3P, true)
    }

    /// 重複觀察舊的 sid 要讓它變成 `latest`
    @MainActor
    func testReobservingUpdatesSeenAtSoLatestIsMostRecentlyPlayed() {
        let store = makeIsolatedStore("naki.test.sids.latest")
        store.record(sid: "a", clientVersionString: "v1")
        Thread.sleep(forTimeInterval: 0.01)
        store.record(sid: "b", clientVersionString: "v1")
        Thread.sleep(forTimeInterval: 0.01)
        store.record(sid: "a", clientVersionString: "v1")

        XCTAssertEqual(store.latest?.sid, "a")
        XCTAssertEqual(store.observations.count, 2)
    }
}
