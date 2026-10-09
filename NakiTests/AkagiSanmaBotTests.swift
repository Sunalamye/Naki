//
//  AkagiSanmaBotTests.swift
//  NakiTests
//
//  三麻本地引擎：oplist 授權映射、授權閘（捨牌／和牌／pending 缺失）、forced，
//  以及「來源 → 三麻放行」的三層 fail-closed 判準。
//  logits 用固定 stub，鎖的是 Naki 這一層的接線，不是模型強度。
//

import XCTest
import AkagiSanma

@testable import Naki

@MainActor
final class AkagiSanmaBotTests: XCTestCase {

    // MARK: - Fixtures

    /// 聽 2s／3s 的一手：123p 456p 789p 111s 2s
    private let tenpaiHand = ["1p", "2p", "3p", "4p", "5p", "6p", "7p", "8p", "9p", "1s", "1s", "1s", "2s"]

    private func startEvents(hand: [String]) -> [[String: Any]] {
        [["type": "start_game"],
         ["type": "start_kyoku", "bakaze": "E", "dora_marker": "7p", "honba": 0, "kyoku": 1,
          "kyotaku": 0, "oya": 0, "scores": [35000, 35000, 35000],
          "tehais": [hand, Array(repeating: "?", count: 13), Array(repeating: "?", count: 13)]]]
    }

    private func snapshot(_ types: [LiqiOperationType], seat: Int = 0) -> LiqiOperationSnapshot {
        LiqiOperationSnapshot(sequence: 1, seat: seat,
                              operations: types.map { LiqiOperation(type: $0) },
                              timeAdd: 0, timeFixed: 300_000, contextTile: nil,
                              source: "test", capturedAt: Date())
    }

    /// 偏好 `favored` 緊湊動作索引（20＝東、56＝和、58＝pass）
    private func bot(favoring favored: Int,
                     snapshot: @escaping () -> LiqiOperationSnapshot?) throws -> AkagiSanmaBot {
        var logits = [Float](repeating: 0, count: SanmaActionCodec.count)
        logits[favored] = 10
        return try AkagiSanmaBot(playerId: 0, snapshot: snapshot,
                                 engine: SanmaEngine(seat: 0, forward: { _ in logits }))
    }

    // MARK: - 授權映射

    func testAuthorizedKindsMapsEveryOplistType() {
        let all = snapshot([.none, .discard, .chi, .pon, .ankan, .minkan, .kakan,
                            .riichi, .tsumo, .ron, .kyushu, .babei])
        XCTAssertEqual(AkagiSanmaBot.authorizedKinds(all, seat: 0),
                       [.discard, .pon, .ankan, .daiminkan, .kakan,
                        .riichi, .tsumo, .ron, .kyushu, .kita])
    }

    func testAuthorizedKindsIsEmptyWithoutPendingOrForForeignSeat() {
        XCTAssertEqual(AkagiSanmaBot.authorizedKinds(nil, seat: 0), [])
        XCTAssertEqual(AkagiSanmaBot.authorizedKinds(snapshot([.discard, .tsumo], seat: 1), seat: 0), [])
    }

    // MARK: - react

    func testDiscardAuthorizedReturnsDiscardRecommendationAndAction() async throws {
        let bot = try bot(favoring: 20) { self.snapshot([.discard]) }
        var events = startEvents(hand: ["1p", "2p", "3p", "5p", "8p", "3s", "3s", "7s", "8s", "9s", "E", "W", "C"])
        events.append(["type": "tsumo", "actor": 0, "pai": "4p"])

        let reaction = try await bot.react(events: events)

        XCTAssertEqual(reaction?.source, "local-akagi3p")
        XCTAssertEqual(reaction?.forced, false)
        XCTAssertEqual(reaction?.action?["type"] as? String, "dahai")
        XCTAssertEqual(reaction?.action?["pai"] as? String, "E")
        XCTAssertEqual(reaction?.action?["actor"] as? Int, 0)
        XCTAssertEqual(reaction?.action?["tsumogiri"] as? Bool, false)
        XCTAssertEqual(reaction?.recommendations.first?.actionType, .discard)
        XCTAssertEqual(reaction?.recommendations.first?.tile?.mjaiString, "E")
    }

    func testNotMyTurnIsNotDecisionPoint() async throws {
        let bot = try bot(favoring: 20) { self.snapshot([.discard]) }
        var events = startEvents(hand: tenpaiHand)
        events.append(["type": "tsumo", "actor": 1, "pai": "?"])
        let reaction = try await bot.react(events: events)
        XCTAssertNil(reaction)
    }

    func testTsumoAuthorizedAndShapeCompleteReturnsHora() async throws {
        let bot = try bot(favoring: 56) { self.snapshot([.discard, .tsumo]) }
        var events = startEvents(hand: tenpaiHand)
        events.append(["type": "tsumo", "actor": 0, "pai": "2s"])

        let reaction = try await bot.react(events: events)

        XCTAssertEqual(reaction?.action?["type"] as? String, "hora")
        XCTAssertEqual(reaction?.action?["target"] as? Int, 0)
        XCTAssertEqual(reaction?.recommendations.first?.actionType, .hora)
    }

    func testTsumoNotAuthorizedFallsBackToDiscard() async throws {
        let bot = try bot(favoring: 56) { self.snapshot([.discard]) }
        var events = startEvents(hand: tenpaiHand)
        events.append(["type": "tsumo", "actor": 0, "pai": "2s"])

        let reaction = try await bot.react(events: events)

        XCTAssertEqual(reaction?.action?["type"] as? String, "dahai")
        XCTAssertFalse(reaction?.recommendations.contains { $0.actionType == .hora } ?? true)
    }

    func testMissingPendingKeepsOnlyDiscards() async throws {
        let bot = try bot(favoring: 56) { nil }
        var events = startEvents(hand: tenpaiHand)
        events.append(["type": "tsumo", "actor": 0, "pai": "2s"])

        let reaction = try await bot.react(events: events)

        XCTAssertEqual(reaction?.action?["type"] as? String, "dahai")
        XCTAssertEqual(reaction?.recommendations.allSatisfy { $0.actionType == .discard }, true)
        XCTAssertEqual(reaction?.forced, false)
    }

    /// 他家打出可榮的牌：授權榮和時有 hora 與過兩個選項；沒授權時只剩過，forced
    func testRonWindowForcedOnlyWhenUnauthorized() async throws {
        var events = startEvents(hand: tenpaiHand)
        events += [["type": "tsumo", "actor": 1, "pai": "?"],
                   ["type": "dahai", "actor": 1, "pai": "2s", "tsumogiri": false]]

        let authorized = try bot(favoring: 56) { self.snapshot([.ron]) }
        let ron = try await authorized.react(events: events)
        XCTAssertEqual(ron?.action?["type"] as? String, "hora")
        XCTAssertEqual(ron?.action?["target"] as? Int, 1)
        XCTAssertEqual(ron?.forced, false)

        let unauthorized = try bot(favoring: 56) { nil }
        let pass = try await unauthorized.react(events: events)
        XCTAssertEqual(pass?.action?["type"] as? String, "none")
        XCTAssertEqual(pass?.forced, true)
        XCTAssertEqual(pass?.recommendations.map(\.actionType), [.none])
    }

    private let ponHand = ["1p", "2p", "3p", "5p", "8p", "3s", "3s", "7s", "8s", "9s", "E", "W", "C"]

    /// 碰牌窗口：action 帶 target／pai／consumed，推薦 detail 帶 consumed
    func testPonActionCarriesTargetAndConsumed() async throws {
        let bot = try bot(favoring: 28) { self.snapshot([.pon]) }
        var events = startEvents(hand: ponHand)
        events += [["type": "tsumo", "actor": 1, "pai": "?"],
                   ["type": "dahai", "actor": 1, "pai": "3s", "tsumogiri": false]]

        let reaction = try await bot.react(events: events)

        XCTAssertEqual(reaction?.action?["type"] as? String, "pon")
        XCTAssertEqual(reaction?.action?["target"] as? Int, 1)
        XCTAssertEqual(reaction?.action?["pai"] as? String, "3s")
        XCTAssertEqual(reaction?.action?["consumed"] as? [String], ["3s", "3s"])
        XCTAssertEqual(reaction?.recommendations.first?.actionType, .pon)
        XCTAssertEqual(reaction?.recommendations.first?.detail, "3s·3s")
    }

    /// 自家碰完：沒有動作要回，但要有新的捨牌建議；他家碰不是我的決策點
    func testOwnPonRefreshesDiscardRecommendationsWithoutAction() async throws {
        var events = startEvents(hand: ponHand)
        events += [["type": "tsumo", "actor": 1, "pai": "?"],
                   ["type": "dahai", "actor": 1, "pai": "3s", "tsumogiri": false]]
        let bot = try bot(favoring: 20) { self.snapshot([.pon]) }
        _ = try await bot.react(events: events)

        let reaction = try await bot.react(events: [
            ["type": "pon", "actor": 0, "target": 1, "pai": "3s", "consumed": ["3s", "3s"]]])

        XCTAssertNotNil(reaction)
        XCTAssertNil(reaction?.action)
        XCTAssertEqual(reaction?.recommendations.first?.actionType, .discard)
    }

    /// 立直：第一列立直，第二列是宣言牌（executor 取清單順序第一個 discard）
    func testRiichiRecommendationCarriesDeclaredDiscardRow() async throws {
        let bot = try bot(favoring: 27) { self.snapshot([.discard, .riichi]) }
        var events = startEvents(hand: tenpaiHand)
        events.append(["type": "tsumo", "actor": 0, "pai": "9s"])

        let reaction = try await bot.react(events: events)

        XCTAssertEqual(reaction?.action?["type"] as? String, "reach")
        XCTAssertEqual(reaction?.recommendations.prefix(2).map(\.actionType), [.riichi, .discard])
        XCTAssertEqual(reaction?.recommendations[1].tile?.mjaiString, reaction?.action?["pai"] as? String)
    }

    /// 槓推薦帶槓種：暗槓／大明槓／加槓各對應 oplist type（31＝1p 槓、42＝3s 槓）
    func testKanRecommendationCarriesKanKind() async throws {
        let ankanBot = try bot(favoring: 31) { self.snapshot([.discard, .ankan]) }
        var closed = startEvents(hand: ["1p", "1p", "1p", "1p", "2p", "3p", "4p", "5p", "6p", "7p", "8p", "9p", "E"])
        closed.append(["type": "tsumo", "actor": 0, "pai": "W"])
        let ankan = try await ankanBot.react(events: closed)
        XCTAssertEqual(ankan?.recommendations.first?.actionType, .kan)
        XCTAssertEqual(ankan?.recommendations.first?.kanKind, .ankan)

        let daiminkanBot = try bot(favoring: 42) { self.snapshot([.minkan]) }
        var open = startEvents(hand: ["3s", "3s", "3s", "1p", "2p", "3p", "5p", "8p", "7s", "8s", "9s", "E", "W"])
        open += [["type": "tsumo", "actor": 1, "pai": "?"],
                 ["type": "dahai", "actor": 1, "pai": "3s", "tsumogiri": false]]
        let daiminkan = try await daiminkanBot.react(events: open)
        XCTAssertEqual(daiminkan?.recommendations.first?.actionType, .kan)
        XCTAssertEqual(daiminkan?.recommendations.first?.kanKind, .minkan)

        let kakanBot = try bot(favoring: 42) { self.snapshot([.discard, .kakan]) }
        var pon = startEvents(hand: ponHand)
        pon += [["type": "tsumo", "actor": 1, "pai": "?"],
                ["type": "dahai", "actor": 1, "pai": "3s", "tsumogiri": false],
                ["type": "pon", "actor": 0, "target": 1, "pai": "3s", "consumed": ["3s", "3s"]],
                ["type": "dahai", "actor": 0, "pai": "C", "tsumogiri": false],
                ["type": "tsumo", "actor": 1, "pai": "?"],
                ["type": "dahai", "actor": 1, "pai": "?", "tsumogiri": true],
                ["type": "tsumo", "actor": 2, "pai": "?"],
                ["type": "dahai", "actor": 2, "pai": "?", "tsumogiri": true],
                ["type": "tsumo", "actor": 0, "pai": "3s"]]
        let kakan = try await kakanBot.react(events: pon)
        XCTAssertEqual(kakan?.recommendations.first?.actionType, .kan)
        XCTAssertEqual(kakan?.recommendations.first?.kanKind, .kakan)
    }

    /// 自家槓之後、嶺上牌之前不是決策點（槓事件沒有 oplist seq，stale guard 擋不住）
    func testOwnKanBeforeRinshanIsNotDecisionPoint() async throws {
        let kanSnapshot = snapshot([.discard, .ankan, .kakan, .pon, .minkan])
        let ankanHand = ["1p", "1p", "1p", "1p", "2p", "3p", "4p", "5p", "6p", "7p", "8p", "9p", "E"]
        let ankanBot = try bot(favoring: 20) { kanSnapshot }
        var events = startEvents(hand: ankanHand)
        events.append(["type": "tsumo", "actor": 0, "pai": "W"])
        let drawn = try await ankanBot.react(events: events)
        XCTAssertNotNil(drawn)
        let ankan = try await ankanBot.react(events: [
            ["type": "ankan", "actor": 0, "consumed": ["1p", "1p", "1p", "1p"]]])
        XCTAssertNil(ankan)

        let daiminkanBot = try bot(favoring: 20) { kanSnapshot }
        var open = startEvents(hand: ["3s", "3s", "3s", "1p", "2p", "3p", "5p", "8p", "7s", "8s", "9s", "E", "W"])
        open += [["type": "tsumo", "actor": 1, "pai": "?"],
                 ["type": "dahai", "actor": 1, "pai": "3s", "tsumogiri": false]]
        _ = try await daiminkanBot.react(events: open)
        let daiminkan = try await daiminkanBot.react(events: [
            ["type": "daiminkan", "actor": 0, "target": 1, "pai": "3s", "consumed": ["3s", "3s", "3s"]]])
        XCTAssertNil(daiminkan)

        let kakanBot = try bot(favoring: 20) { kanSnapshot }
        var pon = startEvents(hand: ponHand)
        pon += [["type": "tsumo", "actor": 1, "pai": "?"],
                ["type": "dahai", "actor": 1, "pai": "3s", "tsumogiri": false],
                ["type": "pon", "actor": 0, "target": 1, "pai": "3s", "consumed": ["3s", "3s"]],
                ["type": "dahai", "actor": 0, "pai": "C", "tsumogiri": false],
                ["type": "tsumo", "actor": 1, "pai": "?"],
                ["type": "dahai", "actor": 1, "pai": "?", "tsumogiri": true],
                ["type": "tsumo", "actor": 2, "pai": "?"],
                ["type": "dahai", "actor": 2, "pai": "?", "tsumogiri": true],
                ["type": "tsumo", "actor": 0, "pai": "3s"]]
        _ = try await kakanBot.react(events: pon)
        let kakan = try await kakanBot.react(events: [
            ["type": "kakan", "actor": 0, "pai": "3s", "consumed": ["3s", "3s", "3s"]]])
        XCTAssertNil(kakan)
    }

    func testResetClearsEngineState() async throws {
        let bot = try bot(favoring: 20) { self.snapshot([.discard]) }
        var events = startEvents(hand: tenpaiHand)
        events.append(["type": "tsumo", "actor": 0, "pai": "2s"])
        _ = try await bot.react(events: events)

        bot.reset()

        let after = try await bot.react(events: [["type": "tsumo", "actor": 0, "pai": "2s"]])
        XCTAssertNil(after, "reset 後沒有 start_kyoku 就不是決策點")
    }

    func testIdentity() throws {
        let id = try bot(favoring: 20) { nil }.identity
        XCTAssertEqual(id.name, "akagi-sanma-bc")
        XCTAssertTrue(id.supports3P)
        XCTAssertTrue(id.isLocal)
    }

    // MARK: - NativeBotController 接線

    func testSanmaControllerUsesAkagiLocalEngineEndToEnd() async throws {
        let controller = NativeBotController()
        try controller.createBot(playerId: 0, is3P: true)
        XCTAssertEqual(controller.botState.modelName, "akagi-sanma-bc")

        var events = startEvents(hand: ["1p", "2p", "3p", "5p", "8p", "3s", "3s", "7s", "8s", "9s", "E", "W", "C"])
        events.append(["type": "tsumo", "actor": 0, "pai": "4p"])
        for event in events { _ = try await controller.react(event: event) }

        XCTAssertEqual(controller.botState.decisionSource, AkagiSanmaBot.source)
        XCTAssertTrue(controller.botState.isSanmaCapableDecision)
        XCTAssertFalse(controller.lastRecommendations.isEmpty)
    }

    /// 本地三麻引擎建不起來：退回雲端-only，三麻仍建得起來；沒有雲端 3p 模型就不支援三麻
    func testSanmaLocalConstructionFailureFallsBackToCloudOnly() throws {
        struct Boom: Error {}
        let c = NativeBotController()
        c.makeSanmaLocal = { _ in throw Boom() }
        c.cloudConfigProvider = { nil }
        try c.createBot(playerId: 0, is3P: true)
        XCTAssertTrue(c.isInitialized)
        XCTAssertEqual(c.botState.modelName, "cloud-only")
        XCTAssertFalse(c.supports3P)
    }

    func testSupports3PWithLocalEngineOrBeforeBotExists() throws {
        let c = NativeBotController()
        XCTAssertTrue(c.supports3P)
        try c.createBot(playerId: 0, is3P: true)
        XCTAssertTrue(c.supports3P)
    }

    // MARK: - 來源 → 三麻放行（三層 fail-closed）

    private func status(source: String) -> BotStatus {
        var s = BotStatus(isActive: true, modelName: "akagi-sanma-bc", playerId: 0, is3P: true)
        s.decisionSource = source
        return s
    }

    /// 非三麻引擎的三麻推薦在側欄標警告；三麻引擎的不標
    func testModelDisplayWarnsOnlyWhenNotSanmaCapable() {
        func key(_ source: String) -> String {
            var s = status(source: source)
            s.modelName = "mortal"
            return "\(s.modelDisplayKey)"
        }
        XCTAssertTrue(key("local").contains("三麻無專用模型"))
        XCTAssertFalse(key(AkagiSanmaBot.source).contains("三麻無專用模型"))
    }

    /// 三麻本地顯示 Akagi 與強度；雲端算的那一手標雲端 3p
    func testModelDisplayShowsAkagiStrengthOrCloud() {
        func key(name: String, source: String) -> String {
            var s = status(source: source)
            s.modelName = name
            return "\(s.modelDisplayKey)"
        }
        XCTAssertTrue(key(name: "akagi-sanma-bc", source: AkagiSanmaBot.source).contains("default strength"))
        XCTAssertTrue(key(name: "cloud+akagi-sanma-bc", source: AkagiSanmaBot.source).contains("default strength"))
        XCTAssertTrue(key(name: "cloud+akagi-sanma-bc", source: "cloud:m").contains("雲端推論 (3P)"))
        XCTAssertFalse(key(name: "cloud+akagi-sanma-bc", source: "cloud:m").contains("default strength"))
        XCTAssertTrue(key(name: "cloud-only", source: "local").contains("未生效"))
        XCTAssertFalse(key(name: "cloud-only", source: "cloud:m").contains("未生效"))
    }

    func testSanmaCapableDecisionBySource() {
        XCTAssertTrue(status(source: AkagiSanmaBot.source).isSanmaCapableDecision)
        XCTAssertTrue(status(source: "cloud:akagi-3p").isSanmaCapableDecision)
        XCTAssertFalse(status(source: "local").isSanmaCapableDecision)
        XCTAssertFalse(status(source: "local-akagi4p").isSanmaCapableDecision)
    }

    private func gateDecision(source: String) -> AutoPlayGate.Decision {
        AutoPlayGate.evaluate(.init(
            isAutoMode: true, isSanma: true,
            sanmaCapableDecision: status(source: source).isSanmaCapableDecision,
            hasActionInFlight: false, snapshot: snapshot([.discard]),
            recommendations: [Recommendation(tile: "9s", probability: 0.9, actionType: .discard)],
            now: Date(), callPassGrace: 2))
    }

    func testGateLetsLocalSanmaSourceThroughAndBlocksLocalFourPlayer() {
        XCTAssertEqual(gateDecision(source: AkagiSanmaBot.source), .proceed)
        XCTAssertEqual(gateDecision(source: "local"), .skip(.sanmaUnsupported))
    }

    private func resolve(source: String) -> AutoPlayDecision {
        AutoPlayDecisionResolver.resolve(
            snapshot: snapshot([.discard]),
            recommendations: [Recommendation(tile: "9s", probability: 0.9, actionType: .discard)],
            mode: .auto, seat: 0, isSanma: true,
            sanmaCapableDecision: status(source: source).isSanmaCapableDecision)
    }

    func testResolverSendsLocalSanmaSourceAndDowngradesLocalFourPlayer() {
        XCTAssertEqual(resolve(source: AkagiSanmaBot.source), .send(action: .discard, tile: "9s"))
        XCTAssertEqual(resolve(source: "local"), .surfaceOnly(action: .discard, tile: "9s"))
    }
}
