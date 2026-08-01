//
//  ObservedMatchModesTests.swift
//  NakiTests
//
//  match_mode 從流量學習的測試。
//
//  payload 取自 2026-08-01 實際攔到的 `.lq.Lobby.fetchCurrentMatchInfo`：
//  玩家停在銅之間畫面時，客戶端持續送 `12 08 08 02 08 03 08 11 08 12`，
//  也就是 wrapper field 2 裡包著 mode_list = [2, 3, 17, 18]，
//  正好對應該畫面的四人東／四人南／三人東／三人南。
//
//  舊的靜態對照表寫成 1/2，送出去伺服器回 error 1306。
//

import XCTest

@testable import Naki

final class ObservedMatchModesTests: XCTestCase {

    @MainActor
    override func setUp() {
        super.setUp()
        ObservedMatchModes.shared.reset()
    }

    @MainActor
    func testRecordsObservation() {
        let store = ObservedMatchModes.shared
        store.record(modes: [2, 3, 17, 18])
        XCTAssertEqual(store.knownModes, [2, 3, 17, 18])
        XCTAssertEqual(store.observations.count, 1)
        XCTAssertEqual(store.observations[0].count, 1)
    }

    /// 同一組重複出現要累加，不是塞出一堆重複紀錄
    @MainActor
    func testRepeatedObservationIncrementsCount() {
        let store = ObservedMatchModes.shared
        for _ in 0..<5 { store.record(modes: [2, 3, 17, 18]) }
        XCTAssertEqual(store.observations.count, 1)
        XCTAssertEqual(store.observations[0].count, 5)
    }

    /// 順序不同視為同一組（畫面上的入口集合才是重點）
    @MainActor
    func testOrderDoesNotCreateDuplicate() {
        let store = ObservedMatchModes.shared
        store.record(modes: [18, 2, 17, 3])
        store.record(modes: [2, 3, 17, 18])
        XCTAssertEqual(store.observations.count, 1)
    }

    @MainActor
    func testDifferentScreensRecordedSeparately() {
        let store = ObservedMatchModes.shared
        store.record(modes: [2, 3, 17, 18])      // 銅之間
        store.record(modes: [5, 6, 20, 21])      // 另一個場次畫面
        XCTAssertEqual(store.observations.count, 2)
        XCTAssertEqual(store.knownModes, [2, 3, 5, 6, 17, 18, 20, 21])
    }

    @MainActor
    func testEmptyIsIgnored() {
        let store = ObservedMatchModes.shared
        store.record(modes: [])
        XCTAssertTrue(store.observations.isEmpty)
    }

    /// 沒有觀察時必須說「還沒觀察到」，不能回一張猜的表
    @MainActor
    func testEmptyStateSaysSo() {
        let d = ObservedMatchModes.shared.dictionary
        XCTAssertEqual((d["knownModes"] as? [Int])?.isEmpty, true)
        XCTAssertTrue((d["note"] as? String)?.contains("還沒觀察到") == true)
    }

    /// 有觀察時不得宣稱哪個值對應哪個房間——猜錯會把人送進錯的段位場
    @MainActor
    func testDoesNotClaimRoomMapping() {
        let store = ObservedMatchModes.shared
        store.record(modes: [2, 3, 17, 18])
        let note = (store.dictionary["note"] as? String) ?? ""
        XCTAssertTrue(note.contains("不宣稱"))
    }
}
