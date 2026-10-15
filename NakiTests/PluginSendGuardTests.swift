//
//  PluginSendGuardTests.swift
//  NakiTests
//
//  manifest `sendGuard`（docs/plan/plugin-v2-b2.md §3）：只收 methods 內的 .lq.Lobby.* 方法，並原樣進 grant。
//  守衛擋下時 Swift 收到的順序（原 REQUEST 緊接合成 RESPONSE）由 LiqiParser 正確配對。
//  守衛本身的行為在 scripts/plugin-v2-b2-regression.cjs。
//

import XCTest

@testable import Naki

@MainActor
final class PluginSendGuardTests: XCTestCase {

    private func manifest(sendGuard: String?, methods: String = #"[".lq.Lobby.changeCharacterSkin"]"#) throws -> PluginManifest {
        let guarded = sendGuard.map { ",\"sendGuard\":\($0)" } ?? ""
        return try JSONDecoder().decode(PluginManifest.self, from: Data("""
        {"schemaVersion":1,"apiVersion":1,"id":"p","name":"n","version":"1","entry":"plugin.js",
        "capabilities":["observe"],"methods":\(methods)\(guarded)}
        """.utf8))
    }

    func testSendGuardAcceptsLobbyMethodsListedInMethods() throws {
        XCTAssertNil(try manifest(sendGuard: #"[".lq.Lobby.changeCharacterSkin"]"#).validate())
        XCTAssertNil(try manifest(sendGuard: nil).validate())
    }

    func testSendGuardRejectsEmptyNonLobbyOrUnlistedMethods() throws {
        let bad = [
            ("[]", #"[".lq.Lobby.changeCharacterSkin"]"#),
            (#"[".lq.FastTest.inputOperation"]"#, #"[".lq.FastTest.inputOperation"]"#),
            (#"[".lq.Lobby.useTitle"]"#, #"[".lq.Lobby.changeCharacterSkin"]"#)
        ]
        for (guarded, methods) in bad {
            guard case .manifestInvalid = try manifest(sendGuard: guarded, methods: methods).validate() else {
                return XCTFail("sendGuard=\(guarded) methods=\(methods) 應被拒")
            }
        }
    }

    func testSendGuardIsPassedToTheGrant() throws {
        let grant = PluginRegistry.grantDict(for: try manifest(sendGuard: #"[".lq.Lobby.changeCharacterSkin"]"#))
        XCTAssertEqual(grant["sendGuard"] as? [String], [".lq.Lobby.changeCharacterSkin"])
        XCTAssertNil(PluginRegistry.grantDict(for: try manifest(sendGuard: nil))["sendGuard"])
    }

    // MARK: - LiqiParser 配對（審查第 7、9 條）

    private func request(_ msgId: Int, _ method: String, _ payload: [UInt8] = [0x08, 0x01]) -> Data {
        let m = Array(method.utf8)
        return Data([2, UInt8(msgId & 0xff), UInt8(msgId >> 8), 0x0a, UInt8(m.count)] + m + [0x12, UInt8(payload.count)] + payload)
    }

    /// naki-plugins.js 的 guardErrorResponse：field 1 空字串、payload 只有 Error{code 6}
    private func guardError(_ msgId: Int) -> Data {
        Data([3, UInt8(msgId & 0xff), UInt8(msgId >> 8), 0x0a, 0x00, 0x12, 0x04, 0x0a, 0x02, 0x08, 0x06])
    }

    func testGuardErrorResponsePairsWithTheOriginalRequest() {
        let parser = LiqiParser()
        _ = parser.parse(request(206, ".lq.Lobby.changeCharacterSkin"))
        let res = parser.parse(guardError(206))
        XCTAssertEqual(res?["method"] as? String, ".lq.Lobby.changeCharacterSkin")
        XCTAssertEqual(res?["type"] as? String, "response")
        XCTAssertEqual(parser.unmatchedResponseCount, 0)
    }

    /// 反例：交給 Swift 的若是 hook 就地改過 msgId 的 REQUEST（222），合成回應 206 配不上、222 留在 pending
    func testMutatedRequestIdWouldLeaveTheGuardResponseUnmatched() {
        let parser = LiqiParser()
        _ = parser.parse(request(222, ".lq.Lobby.changeCharacterSkin"))
        XCTAssertNil(parser.parse(guardError(206)))
        XCTAssertEqual(parser.unmatchedResponseCount, 1)
    }

    /// 另一條連線隨後以同一個 msgId 送出：因為原 REQUEST 與合成 RESPONSE 已連續送進 Swift，
    /// 後來那筆的真回應仍配到它自己的方法。
    func testBackToBackDeliveryKeepsALaterSameIdRequestPaired() {
        let parser = LiqiParser()
        _ = parser.parse(request(206, ".lq.Lobby.changeCharacterSkin"))
        _ = parser.parse(guardError(206))
        _ = parser.parse(request(206, ".lq.Lobby.loginBeat", []))
        let real = parser.parse(Data([3, 206, 0, 0x0a, 0x00, 0x12, 0x00]))
        XCTAssertEqual(real?["method"] as? String, ".lq.Lobby.loginBeat")
        XCTAssertEqual(parser.unmatchedResponseCount, 0)
    }

    /// 第二輪第 2 條：B 先送 loginBeat(303) 等回應，A 的 changeCharacterSkin(303) 被擋下並本地結案。
    /// B 的真回應必須仍配到 loginBeat。
    func testLocalExchangeOnOneSocketDoesNotConsumeAnotherSocketsPending() {
        let bridge = MajsoulBridge(faultState: LiqiParseFaultState(), operations: LiqiOperationStore())
        _ = bridge.observeOutgoing(request(303, ".lq.Lobby.loginBeat", []), socketId: 2)
        _ = bridge.observeOutgoing(request(303, ".lq.Lobby.changeCharacterSkin"), socketId: 1)
        _ = bridge.parse(guardError(303), socketId: 1)
        XCTAssertEqual(bridge.lastParsed?["method"] as? String, ".lq.Lobby.changeCharacterSkin")
        _ = bridge.parse(Data([3, 0x2f, 0x01, 0x0a, 0x00, 0x12, 0x00]), socketId: 2)
        XCTAssertEqual(bridge.lastParsed?["method"] as? String, ".lq.Lobby.loginBeat")
    }

    /// 同一條連線的配對行為不變：RESPONSE 回到別條連線時配不上
    func testResponseOnADifferentSocketIsUnmatched() {
        let parser = LiqiParser()
        _ = parser.parse(request(304, ".lq.Lobby.loginBeat", []), socketId: 1)
        XCTAssertNil(parser.parse(Data([3, 0x30, 0x01, 0x0a, 0x00, 0x12, 0x00]), socketId: 2))
        XCTAssertEqual(parser.parse(Data([3, 0x30, 0x01, 0x0a, 0x00, 0x12, 0x00]), socketId: 1)?["method"] as? String, ".lq.Lobby.loginBeat")
    }

    // MARK: - bridge 層：本地交易成對處理、socketId 契約（審查第三輪第 3、6 條）

    private let skin = ".lq.Lobby.changeCharacterSkin", beat = ".lq.Lobby.loginBeat"

    private func message(_ data: Data, _ direction: String, socketId: Int?, localResponse: String? = nil) -> [String: Any] {
        var d: [String: Any] = ["direction": direction, "data": data.base64EncodedString(), "type": "binary"]
        if let socketId { d["socketId"] = socketId }
        if let localResponse { d["localResponse"] = localResponse }
        return d
    }

    private func empty(_ msgId: Int) -> Data { Data([3, UInt8(msgId & 0xff), UInt8(msgId >> 8), 0x0a, 0x00, 0x12, 0x00]) }

    func testLocalExchangeMessageIsProcessedAsOnePair() {
        let handler = WebSocketMessageHandler()
        handler.dispatch(type: "websocket_message", data: message(request(303, beat, []), "send", socketId: 2))
        handler.dispatch(type: "websocket_message",
                         data: message(request(303, skin), "send", socketId: 1, localResponse: guardError(303).base64EncodedString()))
        XCTAssertEqual(handler.majsoulBridge.lastParsed?["type"] as? String, "response")
        XCTAssertEqual(handler.majsoulBridge.lastParsed?["method"] as? String, skin)
        handler.dispatch(type: "websocket_message", data: message(empty(303), "receive", socketId: 1))
        XCTAssertNil(handler.majsoulBridge.lastParsed, "A's pending was consumed by the paired response")
        handler.dispatch(type: "websocket_message", data: message(empty(303), "receive", socketId: 2))
        XCTAssertEqual(handler.majsoulBridge.lastParsed?["method"] as? String, beat)
    }

    func testUndecodableLocalResponseDropsTheWholeExchange() {
        let handler = WebSocketMessageHandler()
        handler.dispatch(type: "websocket_message", data: message(request(305, skin), "send", socketId: 1, localResponse: "%%%"))
        handler.dispatch(type: "websocket_message", data: message(guardError(305), "receive", socketId: 1))
        XCTAssertNil(handler.majsoulBridge.lastParsed, "the REQUEST half must not have been registered")
    }

    /// socketId 契約：直接呼叫兩端都省略 ⇒ 都是 0；bridge 兩端都缺 ⇒ 都是 -1；兩者各自配得上。只有一端缺值 ⇒ 配不上
    func testSocketIdDefaultsAndMissingValues() {
        let parser = LiqiParser()
        _ = parser.parse(request(306, beat, []))
        XCTAssertEqual(parser.parse(empty(306))?["method"] as? String, beat)

        let both = WebSocketMessageHandler()
        both.dispatch(type: "websocket_message", data: message(request(307, beat, []), "send", socketId: nil))
        both.dispatch(type: "websocket_message", data: message(empty(307), "receive", socketId: nil))
        XCTAssertEqual(both.majsoulBridge.lastParsed?["method"] as? String, beat)

        let one = WebSocketMessageHandler()
        one.dispatch(type: "websocket_message", data: message(request(308, beat, []), "send", socketId: 1))
        one.dispatch(type: "websocket_message", data: message(empty(308), "receive", socketId: nil))
        XCTAssertNil(one.majsoulBridge.lastParsed)
    }
}
