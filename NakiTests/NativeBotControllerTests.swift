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

@MainActor
final class NativeBotControllerTests: XCTestCase {

    private var server: LoopbackServer!
    private let cloudDahai = #"{"reaction":{"type":"dahai","actor":0,"pai":"5p","tsumogiri":true},"candidates":[],"model":"4p-x"}"#
    private let cloudKita = #"{"reaction":{"type":"kita","actor":0,"pai":"N"},"candidates":[],"model":"3p-x"}"#

    override func setUp() async throws {
        server = await LoopbackServer()
        LiqiOperationStore.shared.reset()
    }

    override func tearDown() async throws {
        LiqiOperationStore.shared.reset()
        server = nil
    }

    private func makeController(is3P: Bool) throws -> NativeBotController {
        let controller = NativeBotController()
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
        LiqiOperationStore.shared.record(seat: 0, operations: [LiqiOperation(type: .discard)], source: "test").sequence
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
        XCTAssertEqual(controller.lastDecisionSource, "local")

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
        XCTAssertEqual(controller.lastDecisionSource, "local", "新授權沒有雲端決策＝不得黏著 cloud:")
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

    // MARK: 暗槓後手牌

    func testAnkanFromHandKeepsTehaiSortedWithDrawnTileMerged() async throws {
        let controller = try makeController(is3P: true)
        try await openKyoku(controller, hand: ["1m", "1m", "1m", "1m", "2m", "3m", "4p", "5p", "6p", "7s", "8s", "9s", "E"])
        _ = try await controller.react(event: ["type": "tsumo", "actor": 0, "pai": "S"])
        _ = try await controller.react(event: ["type": "ankan", "actor": 0, "consumed": ["1m", "1m", "1m", "1m"]])
        XCTAssertEqual(controller.tehaiMjai, ["2m", "3m", "4p", "5p", "6p", "7s", "8s", "9s", "E", "S"])
    }
}
