//
//  LiqiResponseStoreTests.swift
//  NakiTests
//
//  Naki 自送請求的回應以「配發登記」認領，而不是看 msgId 號段：
//  遊戲自己的 msgId 跑久了也會進入 60000+。
//

import XCTest

@testable import Naki

final class LiqiResponseStoreTests: XCTestCase {

    private func response(_ msgId: Int, socketId: Int = 0) -> [String: Any] {
        ["type": "response", "id": msgId, "socketId": socketId, "method": ".lq.Lobby.fetchServerTime", "data": [:] as [String: Any]]
    }

    func testCapturesOnlyIssuedMsgIdsOnce() {
        let allocator = LiqiMsgIdAllocator()
        let store = LiqiResponseStore(allocator: allocator)
        let issued = Int(allocator.next())

        XCTAssertFalse(store.capture(response(issued + 100)), "沒配發過的號段內 msgId 是遊戲自己的")
        XCTAssertTrue(store.capture(response(issued)))
        XCTAssertNotNil(store.response(forMsgId: UInt16(issued)))
        XCTAssertFalse(store.capture(response(issued)), "同一筆只認領一次")
    }

    func testIgnoresLowMsgIds() {
        let allocator = LiqiMsgIdAllocator()
        let store = LiqiResponseStore(allocator: allocator)
        _ = allocator.next()
        XCTAssertFalse(store.capture(response(141)))
        XCTAssertFalse(store.capture(response(70000)), "超出 UInt16 也不能 trap")
    }

    func testRegistryKeepsOnlyRecentIssues() {
        let allocator = LiqiMsgIdAllocator()
        let first = allocator.next()
        for _ in 0..<300 { _ = allocator.next() }
        XCTAssertFalse(allocator.claim(first), "超過登記上限的舊筆被淘汰")
        XCTAssertTrue(allocator.claim(allocator.peek &- 1))
    }

    func testIsIssuedDoesNotConsumeRegistration() {
        let allocator = LiqiMsgIdAllocator()
        let issued = allocator.next()
        XCTAssertTrue(allocator.isIssued(issued))
        XCTAssertTrue(allocator.isIssued(issued), "查詢不消耗登記")
        XCTAssertFalse(allocator.isIssued(issued &+ 1))
        XCTAssertTrue(allocator.claim(issued), "查詢後仍可認領")
        XCTAssertFalse(allocator.isIssued(issued))
    }

    /// 學 match_sid 時判斷「是不是 Naki 送的」：看登記而不是號段，插件區段仍排除
    func testIsNakiSentFollowsRegistryNotMsgIdRange() {
        let issued = LiqiMsgIdAllocator.shared.next()
        defer { _ = LiqiMsgIdAllocator.shared.claim(issued) }
        XCTAssertTrue(LiqiParser.isNakiSent(msgId: Int(issued), socketId: 1))
        XCTAssertFalse(LiqiParser.isNakiSent(msgId: 141, socketId: 1), "遊戲自己的低位號")
        XCTAssertFalse(LiqiParser.isNakiSent(msgId: 63000, socketId: 1),
                       "遊戲號碼跑進 60000+ 但沒登記過，仍是遊戲自己的")
        XCTAssertTrue(LiqiParser.isNakiSent(msgId: Int(LiqiMsgIdAllocator.pluginRangeStart), socketId: 1))
        XCTAssertFalse(LiqiParser.isNakiSent(msgId: 70000, socketId: 1), "超出 UInt16 不能 trap")
    }

    /// D22：送出後綁定連線，之後只認那條連線上的同號；綁定前（送出結果還沒回來）任一連線都認
    func testBoundRegistrationMatchesOnlyItsSocket() {
        let allocator = LiqiMsgIdAllocator()
        let issued = allocator.next()
        XCTAssertTrue(allocator.isIssued(issued, socketId: 9), "未綁定")
        allocator.bind(issued, socketId: 3)
        XCTAssertFalse(allocator.isIssued(issued, socketId: 9))
        XCTAssertTrue(allocator.isIssued(issued, socketId: 3))
        XCTAssertFalse(allocator.claim(issued, socketId: 9), "別條連線的同號是遊戲自己的")
        XCTAssertTrue(allocator.claim(issued, socketId: 3))
    }

    func testCaptureClaimsOnlyOnTheBoundSocket() {
        let allocator = LiqiMsgIdAllocator()
        let store = LiqiResponseStore(allocator: allocator)
        let issued = Int(allocator.next())
        allocator.bind(UInt16(issued), socketId: 3)
        XCTAssertFalse(store.capture(response(issued, socketId: 9)))
        XCTAssertTrue(store.capture(response(issued, socketId: 3)))
    }

    func testIsNakiSentRespectsTheBoundSocket() {
        let issued = LiqiMsgIdAllocator.shared.next()
        defer { LiqiMsgIdAllocator.shared.revoke(issued) }
        LiqiMsgIdAllocator.shared.bind(issued, socketId: 3)
        XCTAssertTrue(LiqiParser.isNakiSent(msgId: Int(issued), socketId: 3))
        XCTAssertFalse(LiqiParser.isNakiSent(msgId: Int(issued), socketId: 4))
    }

    /// 送出成功後以 JS 回報的連線綁定登記
    @MainActor
    func testSenderBindsTheReportedSocket() async {
        let sender = LiqiActionSender()
        sender.sendHandler = { _ in LiqiRawSendResult(success: true, detail: "socket=7 bytes=26", socketId: 7) }
        let result = await sender.send(LiqiRequestBuilder.pon())
        defer { LiqiMsgIdAllocator.shared.revoke(result.msgId) }
        XCTAssertFalse(LiqiMsgIdAllocator.shared.isIssued(result.msgId, socketId: 8))
        XCTAssertTrue(LiqiMsgIdAllocator.shared.isIssued(result.msgId, socketId: 7))
    }

    /// 解析結果帶連線，`capture` 才分得出是哪條線的回應
    func testParsedResponseCarriesSocketId() {
        let parser = LiqiParser()
        _ = parser.parse(Data(LiqiEncoder.encodeRequest(method: ".lq.Lobby.fetchServerTime", payload: [], msgId: 142)), socketId: 5)
        let parsed = parser.parse(Data(LiqiEncoder.encodeEnvelope(type: .response, msgId: 142, method: "", payload: [])), socketId: 5)
        XCTAssertEqual(parsed?["socketId"] as? Int, 5)
    }
}
