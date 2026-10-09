//
//  BundledCoreMLBotTests.swift
//  NakiTests
//
//  自己副露後沒有 MJAI 事件可觸發推論，推薦要對當前狀態重新推論（用內建模型）。
//

import MortalSwift
import XCTest

@testable import Naki

@MainActor
final class BundledCoreMLBotTests: XCTestCase {

    func testOwnPonRefreshesDiscardRecommendationsFromCurrentState() async throws {
        let afterPon = ["2m", "3m", "4p", "5p", "6p", "7s", "8s", "9s", "E", "E", "S"].compactMap { Tile(mjaiString: $0) }
        let bot = try BundledCoreMLBot(playerId: 0, is3P: false, hand: { (afterPon, nil) })
        let hand = ["1m", "1m", "2m", "3m", "4p", "5p", "6p", "7s", "8s", "9s", "E", "E", "S"]
        let unknown = [String](repeating: "?", count: 13)
        let events: [[String: Any]] = [
            ["type": "start_game", "id": 0, "names": ["A", "B", "C", "D"]],
            ["type": "start_kyoku", "bakaze": "E", "kyoku": 1, "honba": 0, "kyotaku": 0, "oya": 1,
             "scores": [25000, 25000, 25000, 25000], "dora_marker": "C", "tehais": [hand, unknown, unknown, unknown]],
            ["type": "tsumo", "actor": 1, "pai": "?"],
            ["type": "dahai", "actor": 1, "pai": "1m", "tsumogiri": false],
            ["type": "pon", "actor": 0, "target": 1, "pai": "1m", "consumed": ["1m", "1m"]],
        ]
        var last: BotReaction?
        for event in events { last = try await bot.react(events: [event]) }

        XCTAssertNil(last?.action, "副露後只刷新推薦，沒有動作要回")
        XCTAssertFalse(last?.recommendations.isEmpty ?? true)
        XCTAssertTrue(last?.recommendations.allSatisfy { $0.actionType == .discard } ?? false)
    }
}
