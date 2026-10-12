//
//  NativeBotControllerTests.swift
//  NakiTests
//
//  createBot 的伺服器授權接線、react 的推薦／決策來源保持規則、暗槓後手牌排序。
//  雲端端點用本機 loopback 假伺服器（controller 不暴露 URLSession 注入點）。
//

import Network
import XCTest

@testable import Naki

private final class LoopbackServer: @unchecked Sendable {
    private let listener = try! NWListener(using: .tcp, on: .any)
    private let lock = NSLock()
    private var _body = "{}"
    private var _requests = 0

    var body: String { get { lock.withLock { _body } } set { lock.withLock { _body = newValue } } }
    var requests: Int { lock.withLock { _requests } }
    var port: UInt16 { listener.port?.rawValue ?? 0 }

    init() async {
        listener.newConnectionHandler = { [weak self] conn in
            conn.start(queue: .global())
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, _, _ in
                guard let self else { return }
                self.lock.withLock { self._requests += 1 }
                let payload = self.body
                let head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
                    + "Content-Length: \(payload.utf8.count)\r\nConnection: close\r\n\r\n\(payload)"
                conn.send(content: Data(head.utf8), completion: .contentProcessed { _ in conn.cancel() })
            }
        }
        await withCheckedContinuation { cont in
            listener.stateUpdateHandler = { if $0 == .ready { cont.resume() } }
            listener.start(queue: .global())
        }
    }

    deinit { listener.cancel() }
}

/// 在 `react` 內暫停、由測試放行的引擎：讓「await 期間換了 bot」可以確定性地重現
@MainActor
private final class GatedBot: MahjongBot {
    let identity = BotIdentity(name: "gated", displayName: "Gated", supports3P: false, isLocal: true)
    private let outcome: Result<BotReaction?, Error>
    private var gate: CheckedContinuation<Void, Never>?

    init(outcome: Result<BotReaction?, Error>) { self.outcome = outcome }

    /// react 已進入並停在閘門上
    var isWaiting: Bool { gate != nil }

    func react(events: [[String: Any]]) async throws -> BotReaction? {
        await withCheckedContinuation { gate = $0 }
        return try outcome.get()
    }

    func open() {
        gate?.resume()
        gate = nil
    }

    func reset() {}

    nonisolated deinit {}
}

private struct GatedBotError: Error {}

@MainActor
final class NativeBotControllerTests: XCTestCase {

    private var server: LoopbackServer!
    private let operations = LiqiOperationStore()
    private let cloudDahai = #"{"reaction":{"type":"dahai","actor":0,"pai":"5p","tsumogiri":true},"candidates":[],"model":"4p-x"}"#
    private let cloudKita = #"{"reaction":{"type":"kita","actor":0,"pai":"N"},"candidates":[],"model":"3p-x"}"#

    override func setUp() async throws {
        server = await LoopbackServer()
    }

    override func tearDown() async throws {
        server = nil
    }

    private func makeController(is3P: Bool) throws -> NativeBotController {
        let controller = NativeBotController(operations: operations)
        let url = "http://127.0.0.1:\(server.port)"
        controller.cloudConfigProvider = {
            CloudInferenceConfig(enabled: true, baseURL: url, apiKey: "K", model4P: "4p-x", model3P: "3p-x")
        }
        try controller.createBot(playerId: 0, is3P: is3P)
        return controller
    }

    private func openKyoku(_ controller: NativeBotController, hand: [String]? = nil) async throws {
        let is3P = controller.is3P
        _ = try await controller.react(event: ["type": "start_game", "id": 0,
                                               "names": is3P ? ["A", "B", "C"] : ["A", "B", "C", "D"]])
        let hand = hand ?? ["1m", "2m", "3m", "4p", "5p", "6p", "7s", "8s", "9s", "E", "E", "S", "S"]
        let filler = [String](repeating: "?", count: 13)
        _ = try await controller.react(event: [
            "type": "start_kyoku", "bakaze": "E", "kyoku": 1, "honba": 0, "kyotaku": 0,
            "scores": is3P ? [35000, 35000, 35000] : [25000, 25000, 25000, 25000],
            "dora_marker": "C", "oya": 0,
            "tehais": is3P ? [hand, filler, filler] : [hand, filler, filler, filler]])
    }

    private func pendingSequence() -> UInt64 {
        operations.record(seat: 0, operations: [LiqiOperation(type: .discard)], source: "test").sequence
    }

    private func tsumo(seq: UInt64, pai: String = "1p") -> [String: Any] {
        ["type": "tsumo", "actor": 0, "pai": pai, MJAIEventKey.oplistSequence: seq]
    }

    // MARK: 授權接線

    func testSanmaConsultsCloudOnlyForPendingAuthorization() async throws {
        server.body = cloudKita
        let controller = try makeController(is3P: true)
        try await openKyoku(controller)
        let pending = pendingSequence()

        _ = try await controller.react(event: tsumo(seq: pending + 1, pai: "N"))
        XCTAssertEqual(server.requests, 0, "授權已被取代的決策點不問雲端")
        XCTAssertEqual(controller.lastDecisionSource, AkagiSanmaBot.source, "改由本地 Akagi 三麻回答")

        _ = try await controller.react(event: tsumo(seq: pending, pai: "N"))
        XCTAssertEqual(server.requests, 1)
        XCTAssertEqual(controller.lastDecisionSource, "cloud:3p-x")
    }

    func testYonmaConsultsCloudOnlyForPendingAuthorization() async throws {
        server.body = cloudDahai
        let controller = try makeController(is3P: false)
        try await openKyoku(controller)
        let pending = pendingSequence()

        _ = try await controller.react(event: tsumo(seq: pending + 1))
        XCTAssertEqual(server.requests, 0, "syncGame 重放的過期決策點沿用本地")
        XCTAssertEqual(controller.lastDecisionSource, "local")

        _ = try await controller.react(event: tsumo(seq: pending))
        XCTAssertEqual(server.requests, 1)
        XCTAssertEqual(controller.lastDecisionSource, "cloud:4p-x")
    }

    func testAvailableActionsFollowInjectedStore() throws {
        let controller = try makeController(is3P: true)
        operations.record(seat: 0, operations: [LiqiOperation(type: .pon)], source: "test")

        XCTAssertTrue(controller.availableActions.canPon)
    }

    // MARK: 決策來源不黏著

    func testSanmaNilReactionOnNewAuthorizationResetsSourceButSameSequenceKeepsIt() async throws {
        server.body = cloudKita
        let controller = try makeController(is3P: true)
        try await openKyoku(controller)
        let first = pendingSequence()
        _ = try await controller.react(event: tsumo(seq: first, pai: "N"))
        XCTAssertEqual(controller.lastDecisionSource, "cloud:3p-x")

        _ = try await controller.react(event: tsumo(seq: first, pai: "N"))
        XCTAssertEqual(controller.lastDecisionSource, "cloud:3p-x", "同一批授權的後續事件不改來源")

        server.body = "{}"
        _ = try await controller.react(event: tsumo(seq: pendingSequence(), pai: "N"))
        XCTAssertEqual(controller.lastDecisionSource, AkagiSanmaBot.source, "新授權沒有雲端決策＝不得黏著 cloud:，改標本地 Akagi 三麻")
    }

    // MARK: react 丟錯

    func testReactErrorClearsStaleRecommendations() async throws {
        let controller = try makeController(is3P: false)
        try await openKyoku(controller)
        controller.injectRecommendationsForTesting([Recommendation(tile: "1m", probability: 0.9, actionType: .discard)])

        do {
            _ = try await controller.react(event: ["type": "bogus_event_type"])
            XCTFail("應丟錯")
        } catch {
            XCTAssertTrue(controller.lastRecommendations.isEmpty)
            XCTAssertNil(controller.lastRecommendationsOplistSequence)
        }
    }

    // MARK: 世代守衛

    /// 讓 `react` 停在引擎內，換掉 bot（世代 +1）並給新局一組推薦，再放行引擎；回傳 react 的結果
    private func reactAcrossBotReplacement(
        _ outcome: Result<BotReaction?, Error>
    ) async throws -> (controller: NativeBotController, response: [String: Any]?) {
        let controller = try makeController(is3P: false)
        let gated = GatedBot(outcome: outcome)
        controller.injectBotForTesting(gated)
        let task = Task { try await controller.react(event: ["type": "tsumo", "actor": 0, "pai": "1p"]) }
        while !gated.isWaiting { await Task.yield() }
        controller.deleteBot()
        controller.injectRecommendationsForTesting([Recommendation(tile: "1m", probability: 0.9, actionType: .discard)])
        gated.open()
        return (controller, try await task.value)
    }

    /// inflight 推論在換 bot 之後才回來：結果丟棄，不得寫進新局的推薦與決策來源
    func testStaleGenerationResultIsDiscarded() async throws {
        let stale = BotReaction(action: ["type": "dahai", "actor": 0, "pai": "5p", "tsumogiri": false],
                                recommendations: [Recommendation(tile: "5p", probability: 0.9, actionType: .discard)],
                                source: "cloud:stale")
        let (controller, response) = try await reactAcrossBotReplacement(.success(stale))

        XCTAssertNil(response, "過期結果不得回給呼叫端")
        XCTAssertEqual(controller.lastRecommendations.map(\.displayTile), ["1m"], "過期結果不得覆寫新局推薦")
        XCTAssertEqual(controller.lastDecisionSource, "local")
    }

    /// inflight 推論在換 bot 之後才丟錯：與新局無關，不 rethrow、不清新局推薦
    func testStaleGenerationErrorIsNotRethrown() async throws {
        let (controller, response) = try await reactAcrossBotReplacement(.failure(GatedBotError()))

        XCTAssertNil(response)
        XCTAssertEqual(controller.lastRecommendations.map(\.displayTile), ["1m"], "舊世代的錯誤不得清掉新局推薦")
    }

    // MARK: 暗槓後手牌

    func testAnkanFromHandKeepsTehaiSortedWithDrawnTileMerged() async throws {
        let controller = try makeController(is3P: true)
        try await openKyoku(controller, hand: ["1m", "1m", "1m", "1m", "2m", "3m", "4p", "5p", "6p", "7s", "8s", "9s", "E"])
        _ = try await controller.react(event: ["type": "tsumo", "actor": 0, "pai": "S"])
        _ = try await controller.react(event: ["type": "ankan", "actor": 0, "consumed": ["1m", "1m", "1m", "1m"]])
        XCTAssertEqual(controller.tehaiMjai, ["2m", "3m", "4p", "5p", "6p", "7s", "8s", "9s", "E", "S"])
    }
}
