//
//  NakiWebCoordinatorTests.swift
//  NakiTests
//
//  連線狀態文案，以及消費者對重複錯誤只記第一次 log。
//

import XCTest

@testable import Naki

@MainActor
final class NakiWebCoordinatorTests: XCTestCase {

    private var store: GameStore!
    private var coordinator: NakiWebCoordinator!

    override func setUp() async throws {
        store = GameStore()
        coordinator = NakiWebCoordinator(store: store)
    }

    override func tearDown() async throws {
        coordinator.eventStream.stopConsumer()
        coordinator = nil
        store = nil
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return condition()
    }

    func testStatusMessageFollowsConnectionState() async {
        coordinator.websocketHandler.onWebSocketStatusChanged?(true)
        let connected = await waitUntil { self.store.statusMessage == L10n.text("已連線到雀魂伺服器") }
        XCTAssertTrue(connected, store.statusMessage)

        coordinator.websocketHandler.onWebSocketStatusChanged?(false)
        let disconnected = await waitUntil { self.store.statusMessage == L10n.text("已斷開連線") }
        XCTAssertTrue(disconnected, store.statusMessage)
    }

    private func errorLogCount(_ eventType: String) -> Int {
        LogManager.shared.entries.filter { $0.message.contains("處理 \(eventType) 時發生錯誤") }.count
    }

    /// 同一個錯誤連續出現只記一次；換了錯誤訊息就再記
    func testConsumerLogsRepeatedErrorOnlyOnce() async {
        let a = "bogus_a_\(UUID().uuidString.prefix(6))", b = "bogus_b_\(UUID().uuidString.prefix(6))"
        let emit = { (type: String) in self.coordinator.websocketHandler.onMJAIEvent?(["type": type]) }
        coordinator.websocketHandler.onMJAIEvent?(["type": "start_game", "id": 0, "names": ["A", "B", "C", "D"]])
        let ready = await waitUntil { self.store.botStatus.isActive }
        XCTAssertTrue(ready)

        emit(a); emit(a); emit(b)
        let done = await waitUntil { self.errorLogCount(b) >= 1 }
        XCTAssertTrue(done)
        XCTAssertEqual(errorLogCount(a), 1, "第二次同樣的錯誤不再記")
        XCTAssertEqual(errorLogCount(b), 1, "換了錯誤訊息要再記")
    }
}
