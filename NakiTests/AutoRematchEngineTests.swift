//
//  AutoRematchEngineTests.swift
//  NakiTests
//
//  「全自動」模式的續局引擎與選房決策。
//
//  重點不是「會不會排隊」，而是**什麼時候絕對不排**：續局會主動把帳號送進
//  伺服器隊列，是所有自動行為裡唯一一個在對局之外造成後果的。
//

import XCTest

@testable import Naki

final class AutoRematchEngineTests: XCTestCase {

    private static func obs(_ sid: String,
                            is3P: Bool?,
                            at seconds: TimeInterval = 0) -> ObservedMatchSids.Observation {
        ObservedMatchSids.Observation(
            sid: sid,
            clientVersionString: "WebGL_2022-0.16.257",
            seenAt: Date(timeIntervalSince1970: seconds),
            count: 1,
            is3P: is3P)
    }

    /// 測試用：時間常數全部壓到最小，避免測試真的睡 45 秒
    @MainActor
    private func makeEngine(
        mode: AutoPlayMode = .fullAuto,
        isReady: Bool = true,
        prefersSanma: Bool = false,
        cloudActive: Bool = true,
        room: RoomPreference = .lowest,
        // 雀士1／三麻初心2：實測帳號的段位
        yonmaLevel: Int? = 10201,
        sanmaLevel: Int? = 20102,
        sids: [ObservedMatchSids.Observation] = [obs("1:2", is3P: false)],
        lobbyReady: Bool = true,
        accepts: @escaping (String, String) async -> Bool = { _, _ in true },
        modeBox: (() -> AutoPlayMode)? = nil,
        log: @escaping (String) -> Void = { _ in }
    ) -> AutoRematchEngine {
        AutoRematchEngine(
            context: {
                .init(mode: modeBox?() ?? mode,
                      isReady: isReady,
                      prefersSanma: prefersSanma,
                      cloudInferenceActive: cloudActive,
                      roomPreference: room)
            },
            observations: { sids },
            accountLevel: { sanma in sanma ? sanmaLevel : yonmaLevel },
            startMatch: accepts,
            lobbyProbe: { lobbyReady },
            log: log,
            settleDelay: .milliseconds(1),
            probeInterval: .milliseconds(1),
            maxProbes: 3,
            retryInterval: .milliseconds(1),
            maxAttempts: 3)
    }

    // MARK: - 不該排隊的情況

    /// 只有 `.fullAuto` 會續局：`.auto` 是「幫我打這一局」，不是「一直打下去」
    @MainActor
    func testAutoModeDoesNotRematch() async {
        for mode in [AutoPlayMode.off, .recommend, .auto] {
            let engine = makeEngine(mode: mode)
            let outcome = await engine.run()
            XCTAssertEqual(outcome, .notFullAuto, "\(mode.rawValue) 不該續局")
        }
    }

    /// 一次都沒觀察過 → 什麼都不送。
    ///
    /// 沒有任何 sid 就沒有 `match_group` 可以借，而 group 猜不出來
    /// （見 ObservedMatchSids）。這是最終的 fail-closed。
    @MainActor
    func testNoObservationAtAllNeverSends() async {
        var sent = false
        let engine = makeEngine(sids: [], accepts: { _, _ in sent = true; return true })
        let outcome = await engine.run()
        XCTAssertEqual(outcome, .noObservedSid(sanma: false))
        XCTAssertFalse(sent, "沒有任何觀察時不得送出任何請求")
    }

    /// 三麻是雲端-only：雲端沒開就不排三麻，排進去也一手都不會打
    @MainActor
    func testSanmaWithoutCloudDoesNotSend() async {
        var sent = false
        let engine = makeEngine(prefersSanma: true,
                                cloudActive: false,
                                sids: [Self.obs("1:17", is3P: true)],
                                accepts: { _, _ in sent = true; return true })
        let outcome = await engine.run()
        XCTAssertEqual(outcome, .sanmaWithoutCloud)
        XCTAssertFalse(sent)
    }

    /// 四麻不受雲端設定影響（bundled 模型就是四麻）
    @MainActor
    func testYonmaWorksWithoutCloud() async {
        let engine = makeEngine(cloudActive: false, sids: [Self.obs("1:2", is3P: false)])
        let outcome = await engine.run()
        XCTAssertEqual(outcome, .queued(sid: "1:2", attempts: 1))
    }

    /// 送出通道沒就緒時不排隊
    @MainActor
    func testNotReadyDoesNotSend() async {
        var sent = false
        let engine = makeEngine(isReady: false, accepts: { _, _ in sent = true; return true })
        let outcome = await engine.run()
        XCTAssertEqual(outcome, .notReady)
        XCTAssertFalse(sent)
    }

    /// 大廳 session 探針不通時不排隊（剛回大廳那條 socket 還沒完成登入）
    @MainActor
    func testLobbyNotReadyDoesNotSend() async {
        var sent = false
        let engine = makeEngine(lobbyReady: false,
                                accepts: { _, _ in sent = true; return true })
        let outcome = await engine.run()
        XCTAssertEqual(outcome, .lobbyNotReady)
        XCTAssertFalse(sent)
    }

    /// 等待期間使用者切走模式 → 不排隊。
    ///
    /// 用呼叫次數而不是外部改值來模擬切走的時機：`run()` 第一行就讀一次 mode，
    /// 靠 `async let` 之後再改是競態的。
    @MainActor
    func testModeChangedDuringWaitCancels() async {
        var reads = 0
        var sent = false
        let engine = makeEngine(
            accepts: { _, _ in sent = true; return true },
            modeBox: {
                reads += 1
                return reads <= 1 ? .fullAuto : .recommend
            })

        let result = await engine.run()
        XCTAssertEqual(result, .cancelled)
        XCTAssertFalse(sent, "模式已切走就不該送出")
    }

    // MARK: - 該排隊的情況

    /// 正常路徑：段位雀士1 + 偏好最低 → 銅之間四人東（已觀察過的 1:2）
    @MainActor
    func testQueuesLowestRoom() async {
        var seen: (String, String)?
        let engine = makeEngine(accepts: { sid, ver in seen = (sid, ver); return true })

        let outcome = await engine.run()
        XCTAssertEqual(outcome, .queued(sid: "1:2", attempts: 1))
        XCTAssertEqual(seen?.0, "1:2")
        XCTAssertEqual(seen?.1, "WebGL_2022-0.16.257", "版本字串要原樣沿用觀察到的那一份")
    }

    /// 偏好最高 → 雀士1 能進的最高是銀之間（id 5），沿用觀察到的 group 組 "1:5"
    @MainActor
    func testQueuesHighestRoom() async {
        var seen: String?
        let engine = makeEngine(room: .highest,
                                accepts: { sid, _ in seen = sid; return true })

        let outcome = await engine.run()
        XCTAssertEqual(outcome, .queued(sid: "1:5", attempts: 1))
        XCTAssertEqual(seen, "1:5", "雀士1 能進銀之間，偏好最高就該挑它")
    }

    /// 選三麻時挑三麻的房間（初心2 → 銅之間三人東 id 17）
    @MainActor
    func testSanmaPicksSanmaRoom() async {
        var seen: String?
        let engine = makeEngine(prefersSanma: true,
                                sids: [Self.obs("1:2", is3P: false, at: 100),
                                       Self.obs("1:17", is3P: true, at: 50)],
                                accepts: { sid, _ in seen = sid; return true })

        let outcome = await engine.run()
        XCTAssertEqual(outcome, .queued(sid: "1:17", attempts: 1))
        XCTAssertEqual(seen, "1:17", "選三麻時不得挑到四麻的 sid")
    }

    /// 段位取不到時退回「沿用上次打過的那個房間」，而不是停擺或亂猜
    @MainActor
    func testUnknownLevelFallsBackToLastConfirmed() async {
        var seen: String?
        let engine = makeEngine(yonmaLevel: nil,
                                sids: [Self.obs("1:3", is3P: false, at: 10)],
                                accepts: { sid, _ in seen = sid; return true })

        let outcome = await engine.run()
        XCTAssertEqual(outcome, .queued(sid: "1:3", attempts: 1))
        XCTAssertEqual(seen, "1:3")
    }

    /// 第一次被拒、第二次成功 → 仍然算排進去
    @MainActor
    func testRetriesUntilAccepted() async {
        var calls = 0
        let engine = makeEngine(accepts: { _, _ in calls += 1; return calls >= 2 })

        let outcome = await engine.run()
        XCTAssertEqual(outcome, .queued(sid: "1:2", attempts: 2))
        XCTAssertEqual(calls, 2)
    }

    /// 一直被拒就停手，不無限重試
    @MainActor
    func testGivesUpAfterMaxAttempts() async {
        var calls = 0
        let engine = makeEngine(accepts: { _, _ in calls += 1; return false })

        let outcome = await engine.run()
        XCTAssertEqual(outcome, .rejected(attempts: 3))
        XCTAssertEqual(calls, 3, "不得超過 maxAttempts")
    }

    /// 用表推導出來的候選要在 log 標明「尚未驗證」，不能讓推論看起來像事實
    @MainActor
    func testUnverifiedTargetIsLogged() async {
        var lines: [String] = []
        let engine = makeEngine(room: .highest, log: { lines.append($0) })
        _ = await engine.run()
        XCTAssertTrue(lines.contains { $0.contains("尚未驗證") },
                      "推導出來的 sid 要標明未驗證，實際輸出：\(lines)")
    }
}

// MARK: - 選房決策

final class MatchModeTableTests: XCTestCase {

    /// 雀士1（10201）能進銅之間與銀之間，進不了金之間
    func testEligibleRoomsForYonmaLevel() {
        let rooms = MatchModeTable.eligible(level: 10201, sanma: false, east: true)
        XCTAssertEqual(rooms.map(\.roomName), ["銅之間", "銀之間"])
    }

    /// 初心1（10101）只進得了銅之間
    func testBeginnerOnlyBronze() {
        let rooms = MatchModeTable.eligible(level: 10101, sanma: false, east: true)
        XCTAssertEqual(rooms.map(\.roomName), ["銅之間"])
    }

    /// 偏好最低／最高各挑到正確的房間
    func testPreferencePicksCorrectRoom() {
        let lowest = MatchModeTable.pick(level: 10201, sanma: false, east: true,
                                         preference: .lowest)
        let highest = MatchModeTable.pick(level: 10201, sanma: false, east: true,
                                          preference: .highest)
        XCTAssertEqual(lowest?.id, 2, "最低＝銅之間四人東")
        XCTAssertEqual(highest?.id, 5, "最高＝銀之間四人東")
    }

    /// 三麻走自己那組門檻（2xxxx），不會跟四麻混在一起
    func testSanmaUsesOwnLevels() {
        let rooms = MatchModeTable.eligible(level: 20102, sanma: true, east: true)
        XCTAssertEqual(rooms.map(\.id), [17], "三麻初心2 只進得了銅之間三人東")
        XCTAssertTrue(MatchModeTable.eligible(level: 20102, sanma: false, east: true).isEmpty,
                      "三麻段位不該對應到任何四麻房間")
    }

    /// 半莊與東風是不同入口
    func testEastAndSouthAreDistinct() {
        XCTAssertEqual(MatchModeTable.pick(level: 10101, sanma: false, east: true,
                                           preference: .lowest)?.id, 2)
        XCTAssertEqual(MatchModeTable.pick(level: 10101, sanma: false, east: false,
                                           preference: .lowest)?.id, 3)
    }

    /// 段位進不了任何房間時回 nil，不硬塞一個
    func testNoRoomForImpossibleLevel() {
        XCTAssertNil(MatchModeTable.pick(level: 1, sanma: false, east: true,
                                         preference: .lowest))
    }

    /// sid 的形狀：`{group}:{modeId}`
    func testMatchSidParsing() {
        XCTAssertEqual(MatchSid.group(of: "1:2"), "1")
        XCTAssertEqual(MatchSid.modeId(of: "1:2"), 2)
        XCTAssertEqual(MatchSid.make(group: "1", modeId: 5), "1:5")
        XCTAssertNil(MatchSid.group(of: "nocolon"))
        XCTAssertNil(MatchSid.modeId(of: "1:abc"))
    }
}

// MARK: - 人數回填

final class ObservedMatchSidKindTests: XCTestCase {

    @MainActor
    override func setUp() {
        super.setUp()
        ObservedMatchSids.shared.reset()
    }

    /// 剛記錄時人數未知；打過一場才確認
    @MainActor
    func testKindIsUnknownUntilGameStarts() {
        let store = ObservedMatchSids.shared
        store.record(sid: "1:2", clientVersionString: "v")
        XCTAssertNil(store.observations.first?.is3P)
        XCTAssertNil(store.latest(sanma: false), "未確認的不得被挑中")

        store.gameDidStart(is3P: false)
        XCTAssertEqual(store.observations.first?.is3P, false)
        XCTAssertEqual(store.latest(sanma: false)?.sid, "1:2")
        XCTAssertNil(store.latest(sanma: true))
    }

    /// 三麻的 sid 標成三麻
    @MainActor
    func testSanmaKindRecorded() {
        let store = ObservedMatchSids.shared
        store.record(sid: "1:17", clientVersionString: "v")
        store.gameDidStart(is3P: true)
        XCTAssertEqual(store.latest(sanma: true)?.sid, "1:17")
        XCTAssertNil(store.latest(sanma: false))
    }

    /// 沒有待回填的 sid 時（友人房、重連 replay）不得污染既有紀錄
    @MainActor
    func testStrayGameStartDoesNotPollute() {
        let store = ObservedMatchSids.shared
        store.record(sid: "1:2", clientVersionString: "v")
        store.gameDidStart(is3P: false)
        store.gameDidStart(is3P: true)   // 友人房三麻：此時已無待回填
        XCTAssertEqual(store.latest(sanma: false)?.sid, "1:2")
        XCTAssertNil(store.latest(sanma: true), "友人房的 start_game 不得標到段位場 sid 上")
    }
}

// MARK: - 段位解析

final class AccountLevelParserTests: XCTestCase {

    /// 依 2026-08-09 實測封包組出來的 account payload：
    /// field21 = { 1: 10201, 2: 550 }（四麻雀士1）、field22 = { 1: 20102 }（三麻初心2）
    func testParsesBothLevels() {
        var payload = Data()
        payload.append(contentsOf: [0xAA, 0x01, 0x06])          // field21, len 6
        payload.append(contentsOf: [0x08, 0xD9, 0x4F])          // 1 = 10201
        payload.append(contentsOf: [0x10, 0x9D, 0x04])          // 2 = 541
        payload.append(contentsOf: [0xB2, 0x01, 0x04])          // field22, len 4
        payload.append(contentsOf: [0x08, 0x86, 0x9D, 0x01])    // 1 = 20102

        let levels = AccountLevelParser.levels(from: payload)
        XCTAssertEqual(levels.yonma, 10201)
        XCTAssertEqual(levels.sanma, 20102)
    }

    /// 解不出來一律 nil——不要拿 0 當預設，0 分不出「初心」還是「查無資料」
    func testGarbageReturnsNil() {
        let levels = AccountLevelParser.levels(from: Data([0xFF, 0xFF]))
        XCTAssertNil(levels.yonma)
        XCTAssertNil(levels.sanma)
    }
}

// MARK: - 模式本身

final class FullAutoModeTests: XCTestCase {

    /// `.fullAuto` 必須也算「自動送出」，否則閘門會把它當手動模式擋掉
    func testFullAutoSendsActions() {
        XCTAssertTrue(AutoPlayMode.fullAuto.isFullAuto)
        XCTAssertTrue(AutoPlayMode.auto.isFullAuto)
        XCTAssertFalse(AutoPlayMode.recommend.isFullAuto)
        XCTAssertFalse(AutoPlayMode.off.isFullAuto)
    }

    /// 只有 `.fullAuto` 續局：自動打「這一手」與自動開「下一場」是兩種授權
    func testOnlyFullAutoRematches() {
        XCTAssertTrue(AutoPlayMode.fullAuto.autoRematch)
        XCTAssertFalse(AutoPlayMode.auto.autoRematch)
        XCTAssertFalse(AutoPlayMode.recommend.autoRematch)
        XCTAssertFalse(AutoPlayMode.off.autoRematch)
    }

    /// 全自動也要顯示推薦（否則畫面上看不出它在想什麼）
    func testFullAutoShowsRecommendation() {
        XCTAssertTrue(AutoPlayMode.fullAuto.showRecommendation)
    }

    /// Legacy 路徑不支援自動送出時，`.fullAuto` 必須跟 `.auto` 一樣被降級。
    func testLegacyPathClampsFullAuto() {
        XCTAssertEqual(AutoPlayAvailability.clamp(.fullAuto, autoPlaySupported: false), .recommend)
        XCTAssertEqual(AutoPlayAvailability.clamp(.fullAuto, autoPlaySupported: true), .fullAuto)
        XCTAssertFalse(AutoPlayAvailability.modes(autoPlaySupported: false).contains(.fullAuto))
        XCTAssertTrue(AutoPlayAvailability.modes(autoPlaySupported: true).contains(.fullAuto))
    }

    /// picker 上要有標籤，而且四個模式各不相同
    func testPickerLabelsAreDistinct() {
        let labels = AutoPlayMode.allCases.map(\.pickerLabel)
        XCTAssertEqual(labels.count, Set(labels).count, "標籤重複會讓 picker 分不出來：\(labels)")
        XCTAssertEqual(AutoPlayMode.fullAuto.pickerLabel, "全自動")
    }

    /// 預設四麻、預設最低房：兩個預設都選「不會愈打愈糟」的那一邊
    func testDefaults() {
        let defaults = UserDefaults(suiteName: "naki.tests.fullauto")!
        defaults.removePersistentDomain(forName: "naki.tests.fullauto")
        XCTAssertFalse(SettingsStore.loadFullAutoPrefersSanma(from: defaults))
        XCTAssertEqual(SettingsStore.loadFullAutoRoomPreference(from: defaults), .lowest)
    }
}

// MARK: - 跨啟動保留

final class ObservedMatchSidPersistenceTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "naki.tests.sids.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    /// 觀察到的 sid 必須跨啟動保留。
    ///
    /// 這份資料只能靠使用者自己點一次段位場取得；不保留的話，每次重開 App
    /// 全自動都要先手動點一次才能用（2026-08-09 實測踩到）。
    @MainActor
    func testObservationsSurviveRelaunch() {
        let first = ObservedMatchSids.makeForTesting(defaults: defaults)
        first.record(sid: "1:2", clientVersionString: "WebGL_2022-0.16.257")
        first.gameDidStart(is3P: false)

        // 重開 App＝新的實例讀同一份 defaults
        let second = ObservedMatchSids.makeForTesting(defaults: defaults)
        XCTAssertEqual(second.latest(sanma: false)?.sid, "1:2")
        XCTAssertEqual(second.latest(sanma: false)?.clientVersionString,
                       "WebGL_2022-0.16.257")
    }

    /// 「剛送出、還沒開局」的暫態不得跨啟動保留——否則下一局的人數會被標到上次那個 sid
    @MainActor
    func testPendingKindIsNotPersisted() {
        let first = ObservedMatchSids.makeForTesting(defaults: defaults)
        first.record(sid: "1:2", clientVersionString: "v")   // 尚未 gameDidStart

        let second = ObservedMatchSids.makeForTesting(defaults: defaults)
        second.gameDidStart(is3P: true)   // 新啟動後的第一局（可能是友人房三麻）
        XCTAssertNil(second.latest(sanma: true),
                     "跨啟動的 start_game 不得回填到上次待確認的 sid")
    }

    /// 壞掉的資料當作沒有，不要帶著錯的 sid 去排隊
    @MainActor
    func testCorruptStorageIsIgnored() {
        defaults.set(Data([0x00, 0x01]), forKey: ObservedMatchSids.storageKey)
        let store = ObservedMatchSids.makeForTesting(defaults: defaults)
        XCTAssertTrue(store.observations.isEmpty)
    }
}

// MARK: - 大廳立刻開始

extension AutoRematchEngineTests {

    /// 在大廳按「開始」要立刻排一場，不等結算緩衝。
    ///
    /// 續局引擎本身是 `end_game` 驅動的，而大廳根本沒有 `end_game` 可等——
    /// 少了這條路徑，使用者按下「開始」會什麼都不發生。
    @MainActor
    func testStartNowSkipsSettleDelay() async {
        var lines: [String] = []
        var sent = false
        let engine = makeEngine(accepts: { _, _ in sent = true; return true },
                                log: { lines.append($0) })

        let outcome = await engine.run(skipSettle: true)

        XCTAssertEqual(outcome, .queued(sid: "1:2", attempts: 1))
        XCTAssertTrue(sent)
        XCTAssertTrue(lines.contains { $0.contains("立刻排一場") },
                      "應走立刻排隊那條訊息，實際：\(lines)")
        XCTAssertFalse(lines.contains { $0.contains("秒後排下一場") },
                       "不該再等結算緩衝")
    }

    /// 立刻排隊一樣受所有守衛約束：不是全自動就什麼都不做
    @MainActor
    func testStartNowStillRespectsMode() async {
        var sent = false
        let engine = makeEngine(mode: .auto,
                                accepts: { _, _ in sent = true; return true })
        let outcome = await engine.run(skipSettle: true)
        XCTAssertEqual(outcome, .notFullAuto)
        XCTAssertFalse(sent)
    }

    /// 立刻排隊一樣 fail-closed：沒有觀察過的 sid 就不送
    @MainActor
    func testStartNowStillFailsClosed() async {
        var sent = false
        let engine = makeEngine(sids: [], accepts: { _, _ in sent = true; return true })
        let outcome = await engine.run(skipSettle: true)
        XCTAssertEqual(outcome, .noObservedSid(sanma: false))
        XCTAssertFalse(sent)
    }
}
