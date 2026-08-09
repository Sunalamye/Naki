//
//  CloudBotTests.swift
//  NakiTests
//
//  `CloudBot` 裝飾器的整合測試：stub 本地引擎＋mock HTTP，驗整條 overlay
//  流程——本地閘門、覆蓋、fallback、斷路器、立直兩段、null reaction、
//  重連重放抑制。這是 protocol 抽象的直接紅利：前一版 overlay 住在
//  `NativeBotController` 裡時，這些路徑只能拆成元件各測一角。
//

import XCTest

@testable import Naki

// MARK: - Stub 本地引擎

@MainActor
private final class StubEngine: MahjongBot {
    var identity = BotIdentity(name: "stub", displayName: "Stub",
                               supports3P: false, isLocal: true)
    /// 依呼叫順序回放；用完回 nil（非決策點）
    var script: [BotReaction] = []
    private(set) var reactCalls = 0
    private(set) var resetCalls = 0

    func react(events: [[String: Any]]) async throws -> BotReaction? {
        reactCalls += 1
        return script.isEmpty ? nil : script.removeFirst()
    }

    func reset() { resetCalls += 1 }

    nonisolated deinit {}
}

// MARK: - Tests

@MainActor
final class CloudBotTests: XCTestCase {

    private func makeCloudBot(local: StubEngine, enabled: Bool = true,
                              model4P: String = "4p-x") -> CloudBot {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CloudMockURLProtocol.self]
        return CloudBot(
            local: local, playerId: 0, is3P: false,
            configProvider: {
                CloudInferenceConfig(enabled: enabled,
                                     baseURL: "http://mock.test",
                                     apiKey: "SECRETKEY",
                                     model4P: model4P, model3P: "")
            },
            clientConfiguration: config)
    }

    private func localDahai(_ pai: String) -> BotReaction {
        BotReaction(action: ["type": "dahai", "actor": 0, "pai": pai, "tsumogiri": false],
                    recommendations: [Recommendation(tile: pai, probability: 0.5,
                                                     actionType: .discard)],
                    source: "local")
    }

    /// 餵開局（start_game + start_kyoku）讓視窗可上傳；stub 對它們回 nil
    private func feedOpening(_ bot: CloudBot) async throws {
        _ = try await bot.react(events: [["type": "start_game", "id": 0,
                                          "names": ["A", "B", "C", "D"]]])
        _ = try await bot.react(events: [["type": "start_kyoku", "kyoku": 1,
                                          "bakaze": "E"]])
    }

    private func decide(_ bot: CloudBot, local: StubEngine,
                        reaction: BotReaction? = nil) async throws -> BotReaction? {
        if let reaction { local.script.append(reaction) }
        return try await bot.react(events: [["type": "tsumo", "actor": 0, "pai": "1m"]])
    }

    // MARK: 閘門

    func test_nonDecisionPoints_neverCallAPI() async throws {
        CloudMockURLProtocol.reset(script: [])
        let local = StubEngine()
        let bot = makeCloudBot(local: local)
        try await feedOpening(bot)
        XCTAssertTrue(CloudMockURLProtocol.captured.isEmpty,
                      "本地回 nil＝非決策點，連 API 都不該打")
    }

    func test_disabledConfig_staysFullyLocal() async throws {
        CloudMockURLProtocol.reset(script: [])
        let local = StubEngine()
        let bot = makeCloudBot(local: local, enabled: false)
        try await feedOpening(bot)
        let result = try await decide(bot, local: local, reaction: localDahai("1m"))
        XCTAssertEqual(result?.source, "local")
        XCTAssertTrue(CloudMockURLProtocol.captured.isEmpty)
        XCTAssertNil(bot.cloudHost)
    }

    /// 強制手（完整合法集單元素，最常見＝立直後的摸切）：本地回答、零 API
    /// 呼叫、斷路器與 fallback 可視化全不動；下一個非強制決策照常問雲端
    ///（Akagi #227/#228）
    func test_forcedMove_answersLocally_withoutAPICall() async throws {
        CloudMockURLProtocol.reset(script: [
            (200, #"{"reaction":{"type":"dahai","actor":0,"pai":"5p","tsumogiri":true},"#
                + #""candidates":[],"model":"4p-x"}"#, [:]),
        ])
        let local = StubEngine()
        let bot = makeCloudBot(local: local)
        try await feedOpening(bot)

        let forced = try await decide(
            bot, local: local,
            reaction: BotReaction(
                action: ["type": "dahai", "actor": 0, "pai": "1m", "tsumogiri": true],
                recommendations: [Recommendation(tile: "1m", probability: 1.0,
                                                 actionType: .discard)],
                source: "local", forced: true))
        XCTAssertEqual(forced?.source, "local")
        XCTAssertEqual(forced?.recommendations.first?.displayTile, "1m")
        XCTAssertTrue(CloudMockURLProtocol.captured.isEmpty, "強制手不得花 API call")
        XCTAssertEqual(bot.cloudFallbackStreak, 0, "本地回答強制手不是 fallback")
        XCTAssertFalse(bot.cloudDegraded)

        // 跳過只限強制手本身：下一個非強制決策照常問雲端
        let normal = try await decide(bot, local: local, reaction: localDahai("2m"))
        XCTAssertEqual(normal?.source, "cloud:4p-x")
        XCTAssertEqual(CloudMockURLProtocol.captured.count, 1)
    }

    func test_incompleteWindow_neverCallsAPI() async throws {
        CloudMockURLProtocol.reset(script: [])
        let local = StubEngine()
        let bot = makeCloudBot(local: local)
        // 局中途啟動：沒有 start_game
        _ = try await bot.react(events: [["type": "start_kyoku", "kyoku": 3]])
        let result = try await decide(bot, local: local, reaction: localDahai("1m"))
        XCTAssertEqual(result?.source, "local", "殘缺視窗寧可本地，不上傳偽裝完整的流")
        XCTAssertTrue(CloudMockURLProtocol.captured.isEmpty)
    }

    // MARK: 覆蓋與請求塑形

    func test_decisionPoint_overridesWithCloudDecision() async throws {
        CloudMockURLProtocol.reset(script: [
            (200, #"{"reaction":{"type":"dahai","actor":0,"pai":"5p","tsumogiri":false},"#
                + #""candidates":[{"action":"dahai:5p","prob":0.9}],"model":"4p-x"}"#, [:]),
        ])
        let local = StubEngine()
        let bot = makeCloudBot(local: local)
        try await feedOpening(bot)
        let result = try await decide(bot, local: local, reaction: localDahai("1m"))

        XCTAssertEqual(result?.source, "cloud:4p-x")
        XCTAssertEqual(result?.recommendations.first?.displayTile, "5p")
        XCTAssertEqual(result?.action?["type"] as? String, "dahai")
        XCTAssertEqual(bot.cloudHost, "mock.test")

        // 請求塑形：內部欄位被剝除、批次含決策點、bearer 在 header
        let (request, body) = CloudMockURLProtocol.captured[0]
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"),
                       "Bearer SECRETKEY")
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let events = json?["events"] as? [[String: Any]]
        XCTAssertEqual(events?.count, 3, "start_game + start_kyoku + tsumo")
        XCTAssertNil(events?[0]["id"], "start_game 的 Naki 內部座位欄位不上傳")
        XCTAssertEqual(events?[2]["type"] as? String, "tsumo")
    }

    // MARK: fallback 與斷路器

    func test_apiFailure_fallsBackToLocal_andBreakerSuppressesNextDecision() async throws {
        CloudMockURLProtocol.reset(script: [
            (500, #"{"error":"boom"}"#, [:]),
        ])
        let local = StubEngine()
        let bot = makeCloudBot(local: local)
        try await feedOpening(bot)

        let first = try await decide(bot, local: local, reaction: localDahai("1m"))
        XCTAssertEqual(first?.source, "local", "API 失敗必須沿用本地決策")
        XCTAssertEqual(first?.recommendations.first?.displayTile, "1m")
        XCTAssertEqual(CloudMockURLProtocol.captured.count, 1)

        // 斷路器（5s 視窗）內的下一個決策：不再打 API、照走本地
        let second = try await decide(bot, local: local, reaction: localDahai("2m"))
        XCTAssertEqual(second?.source, "local")
        XCTAssertEqual(CloudMockURLProtocol.captured.count, 1,
                       "退避視窗內不得再付一次逾時")
    }

    func test_nullReaction_fallsBackToLocal_withoutTrippingBreaker() async throws {
        CloudMockURLProtocol.reset(script: [
            (200, "{}", [:]),
            (200, #"{"reaction":{"type":"dahai","actor":0,"pai":"5p","tsumogiri":true},"#
                + #""candidates":[],"model":"4p-x"}"#, [:]),
        ])
        let local = StubEngine()
        let bot = makeCloudBot(local: local)
        try await feedOpening(bot)

        let first = try await decide(bot, local: local, reaction: localDahai("1m"))
        XCTAssertEqual(first?.source, "local", "null reaction＝事件流不同步 → 本地")

        // HTTP 有來回＝伺服器可達，不開斷路器：下一個決策照打 API
        let second = try await decide(bot, local: local, reaction: localDahai("2m"))
        XCTAssertEqual(second?.source, "cloud:4p-x")
        XCTAssertEqual(CloudMockURLProtocol.captured.count, 2)
    }

    // MARK: 立直兩段式

    func test_reachTwoStep_insertsCloudDiscard() async throws {
        CloudMockURLProtocol.reset(script: [
            (200, #"{"reaction":{"type":"reach","actor":0},"#
                + #""candidates":[{"action":"reach","prob":0.9}],"model":"4p-x"}"#, [:]),
            (200, #"{"reaction":{"type":"dahai","actor":0,"pai":"9p","tsumogiri":false},"#
                + #""candidates":[{"action":"dahai:9p","prob":0.8}],"model":"4p-x"}"#, [:]),
        ])
        let local = StubEngine()
        let bot = makeCloudBot(local: local)
        try await feedOpening(bot)
        let result = try await decide(bot, local: local, reaction: localDahai("1m"))

        XCTAssertEqual(result?.source, "cloud:4p-x")
        XCTAssertEqual(result?.recommendations.first?.actionType, .riichi)
        let firstDiscard = result?.recommendations.first { $0.actionType == .discard }
        XCTAssertEqual(firstDiscard?.displayTile, "9p",
                       "executor 的宣言牌取第一個 discard——必須是第二段解出的那張")

        // 第二段請求：事件流尾端附上裸 reach
        XCTAssertEqual(CloudMockURLProtocol.captured.count, 2)
        let (_, body) = CloudMockURLProtocol.captured[1]
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let last = (json?["events"] as? [[String: Any]])?.last
        XCTAssertEqual(last?["type"] as? String, "reach")
        XCTAssertEqual(last?["actor"] as? Int, 0)
    }

    func test_reachSecondCallFailure_abandonsCloudEntirely() async throws {
        CloudMockURLProtocol.reset(script: [
            (200, #"{"reaction":{"type":"reach","actor":0},"candidates":[],"model":"4p-x"}"#, [:]),
            (500, #"{"error":"flaky"}"#, [:]),
        ])
        let local = StubEngine()
        let bot = makeCloudBot(local: local)
        try await feedOpening(bot)
        let result = try await decide(bot, local: local, reaction: localDahai("1m"))
        XCTAssertEqual(result?.source, "local",
                       "第二段失敗＝整個決策退回本地（不做半雲半本地拼裝，decisions D3）")
        XCTAssertEqual(result?.recommendations.first?.displayTile, "1m")

        // 非 429 的第二段失敗＝伺服器不穩：斷路器要開，退避視窗內不再打 API
        XCTAssertTrue(bot.cloudDegraded, "500 跟進失敗必須開斷路器")
        let second = try await decide(bot, local: local, reaction: localDahai("2m"))
        XCTAssertEqual(second?.source, "local")
        XCTAssertEqual(CloudMockURLProtocol.captured.count, 2,
                       "退避視窗內不得再付一次逾時")
    }

    /// 立直兩段是毫秒內連發：第二段 429＝burst rate-limit，不是伺服器掛
    ///（Akagi #227）。短暫等待重試一次，成功則雲端決策照用、不留退化痕跡。
    func test_reachSecondCall429_retriesOnce_andKeepsCloudDecision() async throws {
        CloudMockURLProtocol.reset(script: [
            (200, #"{"reaction":{"type":"reach","actor":0},"#
                + #""candidates":[{"action":"reach","prob":0.9}],"model":"4p-x"}"#, [:]),
            (429, #"{"error":"rate limited"}"#, ["Retry-After": "0"]),
            (200, #"{"reaction":{"type":"dahai","actor":0,"pai":"9p","tsumogiri":false},"#
                + #""candidates":[{"action":"dahai:9p","prob":0.8}],"model":"4p-x"}"#, [:]),
        ])
        let local = StubEngine()
        let bot = makeCloudBot(local: local)
        try await feedOpening(bot)
        let result = try await decide(bot, local: local, reaction: localDahai("1m"))

        XCTAssertEqual(result?.source, "cloud:4p-x")
        let firstDiscard = result?.recommendations.first { $0.actionType == .discard }
        XCTAssertEqual(firstDiscard?.displayTile, "9p", "重試成功＝第二段解出的捨牌照用")
        XCTAssertEqual(CloudMockURLProtocol.captured.count, 3, "429 之後恰重試一次")
        XCTAssertFalse(bot.cloudDegraded, "burst 429 不是伺服器掛，不得留下退化痕跡")
    }

    /// 二連 429：這一手退回本地（D3 不變），但斷路器不開——rate limit 的
    /// 伺服器是可達的，開退避會把接下來幾手一起賠進去（Akagi #227 的損害鏈）
    func test_reachSecondCallDouble429_fallsBackLocally_withoutTrippingBreaker() async throws {
        CloudMockURLProtocol.reset(script: [
            (200, #"{"reaction":{"type":"reach","actor":0},"candidates":[],"model":"4p-x"}"#, [:]),
            (429, #"{"error":"rate limited"}"#, ["Retry-After": "0"]),
            (429, #"{"error":"rate limited"}"#, ["Retry-After": "0"]),
            (200, #"{"reaction":{"type":"dahai","actor":0,"pai":"5p","tsumogiri":true},"#
                + #""candidates":[],"model":"4p-x"}"#, [:]),
        ])
        let local = StubEngine()
        let bot = makeCloudBot(local: local)
        try await feedOpening(bot)

        let first = try await decide(bot, local: local, reaction: localDahai("1m"))
        XCTAssertEqual(first?.source, "local", "二連 429＝這一手退回本地（D3）")
        XCTAssertFalse(bot.cloudDegraded, "429 不得開斷路器")

        let second = try await decide(bot, local: local, reaction: localDahai("2m"))
        XCTAssertEqual(second?.source, "cloud:4p-x", "下一手照常問雲端——斷路器沒開的直接證據")
        XCTAssertEqual(CloudMockURLProtocol.captured.count, 4)
    }

    // MARK: 重連重放抑制

    func test_resyncSuppression_skipsCloudForReplayedEvents_thenResumes() async throws {
        CloudMockURLProtocol.reset(script: [
            (200, #"{"reaction":{"type":"dahai","actor":0,"pai":"5p","tsumogiri":true},"#
                + #""candidates":[],"model":"4p-x"}"#, [:]),
        ])
        let local = StubEngine()
        let bot = makeCloudBot(local: local)
        try await feedOpening(bot)

        // 接下來 1 個事件是重放：即使是決策點也不打 API
        bot.suppressCloud(forNextEvents: 1)
        let replayed = try await decide(bot, local: local, reaction: localDahai("1m"))
        XCTAssertEqual(replayed?.source, "local")
        XCTAssertTrue(CloudMockURLProtocol.captured.isEmpty,
                      "重放期間的決策不得重問伺服器")

        // 重放結束：下一個 live 決策恢復雲端
        let live = try await decide(bot, local: local, reaction: localDahai("2m"))
        XCTAssertEqual(live?.source, "cloud:4p-x")
        XCTAssertEqual(CloudMockURLProtocol.captured.count, 1)
    }

    // MARK: fallback 可視化（cloudDegraded / cloudFallbackStreak）

    /// 失敗→streak 累加＋degraded 亮；恢復→雙雙歸零（rollback 狀態要讓人看得到）。
    /// 恢復路徑用「改設定＝明確重試」觸發（reconcile 會 reset 斷路器），
    /// 不能靠真的等 5 秒退避視窗。
    func test_fallbackStreak_countsFailures_andResetsOnSuccess() async throws {
        CloudMockURLProtocol.reset(script: [
            (500, #"{"error":"boom"}"#, [:]),
            (200, #"{"reaction":{"type":"dahai","actor":0,"pai":"5p","tsumogiri":true},"#
                + #""candidates":[],"model":"4p-x"}"#, [:]),
        ])
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CloudMockURLProtocol.self]
        var model = "4p-x"
        let local = StubEngine()
        let bot = CloudBot(
            local: local, playerId: 0, is3P: false,
            configProvider: {
                CloudInferenceConfig(enabled: true, baseURL: "http://mock.test",
                                     apiKey: "SECRETKEY",
                                     model4P: model, model3P: "")
            },
            clientConfiguration: config)
        try await feedOpening(bot)
        XCTAssertEqual(bot.cloudFallbackStreak, 0)

        _ = try await decide(bot, local: local, reaction: localDahai("1m"))
        XCTAssertEqual(bot.cloudFallbackStreak, 1, "雲端失敗的決策要累計")
        XCTAssertTrue(bot.cloudDegraded, "斷路器開了＝退化中")

        // 斷路器 5s 視窗內的下一手：不打 API、照樣算 fallback
        _ = try await decide(bot, local: local, reaction: localDahai("2m"))
        XCTAssertEqual(bot.cloudFallbackStreak, 2)

        // 改設定＝明確的「現在再試一次」→ 斷路器歸零 → 下一手成功 → 全部復位
        model = "4p-y"
        _ = try await decide(bot, local: local, reaction: localDahai("3m"))
        XCTAssertEqual(bot.cloudFallbackStreak, 0, "雲端恢復後 streak 歸零")
        XCTAssertFalse(bot.cloudDegraded)
    }

    /// 雲端未設定（disabled）不算 fallback——streak 恆 0、無退化警示
    func test_fallbackStreak_staysZeroWhenCloudNotConfigured() async throws {
        CloudMockURLProtocol.reset(script: [])
        let local = StubEngine()
        let bot = makeCloudBot(local: local, enabled: false)
        try await feedOpening(bot)
        _ = try await decide(bot, local: local, reaction: localDahai("1m"))
        XCTAssertEqual(bot.cloudFallbackStreak, 0)
        XCTAssertFalse(bot.cloudDegraded)
    }

    // MARK: 雲端-only（三麻，2026-08-05：本地模型不啟動）

    private func makeCloudOnlyBot(authorized: Bool = true) -> CloudBot {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CloudMockURLProtocol.self]
        return CloudBot(
            local: nil, playerId: 0, is3P: true,
            configProvider: {
                CloudInferenceConfig(enabled: true,
                                     baseURL: "http://mock.test",
                                     apiKey: "SECRETKEY",
                                     model4P: "", model3P: "3p-x")
            },
            serverAuthorization: { authorized },
            clientConfiguration: config)
    }

    private func feedSanmaOpening(_ bot: CloudBot) async throws {
        _ = try await bot.react(events: [["type": "start_game", "id": 0,
                                          "names": ["A", "B", "C"]]])
        _ = try await bot.react(events: [["type": "start_kyoku", "kyoku": 1]])
    }

    /// 決策點由 oplist 驅動：帶 oplistSequence 的事件恰觸發一次雲端；
    /// 同授權 pending 期間的後續事件不重複觸發
    func test_cloudOnly_consultsExactlyOncePerOplistSequence() async throws {
        CloudMockURLProtocol.reset(script: [
            (200, #"{"reaction":{"type":"kita","actor":0,"pai":"N"},"#
                + #""candidates":[{"action":"nukidora","prob":0.5}],"model":"3p-x"}"#, [:]),
        ])
        let bot = makeCloudOnlyBot()
        try await feedSanmaOpening(bot)
        XCTAssertTrue(CloudMockURLProtocol.captured.isEmpty,
                      "沒有伺服器授權的事件不觸發雲端")

        let reaction = try await bot.react(events: [
            ["type": "tsumo", "actor": 0, "pai": "N",
             MJAIEventKey.oplistSequence: UInt64(7)]])
        XCTAssertEqual(reaction?.source, "cloud:3p-x")
        XCTAssertEqual(reaction?.recommendations.first?.actionType, .kita)
        XCTAssertEqual(CloudMockURLProtocol.captured.count, 1)

        // 同一批授權（同 seq）不重問；無 seq 的事件也不問
        _ = try await bot.react(events: [
            ["type": "tsumo", "actor": 0, "pai": "1m",
             MJAIEventKey.oplistSequence: UInt64(7)]])
        _ = try await bot.react(events: [["type": "dahai", "actor": 1, "pai": "2m",
                                          "tsumogiri": true]])
        XCTAssertEqual(CloudMockURLProtocol.captured.count, 1)
    }

    /// 雲端失敗＝本手誠實沒有推薦（不會有本地無效輸出頂上）
    func test_cloudOnly_failureYieldsNoRecommendation() async throws {
        CloudMockURLProtocol.reset(script: [(500, #"{"error":"boom"}"#, [:])])
        let bot = makeCloudOnlyBot()
        try await feedSanmaOpening(bot)
        let reaction = try await bot.react(events: [
            ["type": "tsumo", "actor": 0, "pai": "N",
             MJAIEventKey.oplistSequence: UInt64(3)]])
        XCTAssertNil(reaction, "三麻雲端失敗不得產生任何推薦")
    }

    /// 授權已被消化（autopass 競態）→ 不問雲端
    func test_cloudOnly_consumedAuthorizationSkipsCloud() async throws {
        CloudMockURLProtocol.reset(script: [])
        let bot = makeCloudOnlyBot(authorized: false)
        try await feedSanmaOpening(bot)
        let reaction = try await bot.react(events: [
            ["type": "tsumo", "actor": 0, "pai": "N",
             MJAIEventKey.oplistSequence: UInt64(3)]])
        XCTAssertNil(reaction)
        XCTAssertTrue(CloudMockURLProtocol.captured.isEmpty)
    }

    // MARK: reset

    func test_reset_forwardsToLocal_andClearsWindow() async throws {
        CloudMockURLProtocol.reset(script: [])
        let local = StubEngine()
        let bot = makeCloudBot(local: local)
        try await feedOpening(bot)
        bot.reset()
        XCTAssertEqual(local.resetCalls, 1)
        // 視窗清掉之後就是殘缺流：決策點不打 API
        let result = try await decide(bot, local: local, reaction: localDahai("1m"))
        XCTAssertEqual(result?.source, "local")
        XCTAssertTrue(CloudMockURLProtocol.captured.isEmpty)
    }
}
