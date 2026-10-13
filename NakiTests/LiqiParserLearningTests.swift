//
//  LiqiParserLearningTests.swift
//  NakiTests
//
//  LiqiParser 的 REQUEST 側副作用：取消匹配清待回填、憑證類 trace 遮蔽。
//

import XCTest

@testable import Naki

@MainActor
final class LiqiParserLearningTests: XCTestCase {

    private func parseRequest(_ method: String, payload: [UInt8], msgId: UInt16 = 142) async {
        _ = LiqiParser().parse(Data(LiqiEncoder.encodeRequest(method: method, payload: payload, msgId: msgId)))
        for _ in 0..<8 { await Task.yield() }
    }

    // MARK: 取消匹配

    func testCancelRequestsClearAwaitingGameKindForBothMethods() async {
        isolateSharedObservedMatchSids(self)
        for spec in [LiqiRequestBuilder.cancelUnifiedMatch(matchSid: "ranked"), LiqiRequestBuilder.cancelMatch(matchMode: 2)] {
            ObservedMatchSids.shared.record(sid: "ranked", clientVersionString: "v1")
            await parseRequest(spec.method, payload: spec.payload)
            ObservedMatchSids.shared.gameDidStart(is3P: true)
            XCTAssertNil(ObservedMatchSids.shared.observations[0].is3P, spec.method)
            ObservedMatchSids.shared.reset()
        }
    }

    /// 取消匹配在 `parse` 內同步生效（WP6 時序）：不 yield 直接斷言
    func testCancelTakesEffectWithoutYield() {
        isolateSharedObservedMatchSids(self)
        let parser = LiqiParser()

        ObservedMatchSids.shared.record(sid: "ranked", clientVersionString: "v1")
        let cancel = LiqiRequestBuilder.cancelUnifiedMatch(matchSid: "ranked")
        _ = parser.parse(Data(LiqiEncoder.encodeRequest(method: cancel.method, payload: cancel.payload, msgId: 142)))
        ObservedMatchSids.shared.gameDidStart(is3P: true)
        XCTAssertNil(ObservedMatchSids.shared.observations[0].is3P)
    }

    func testOtherRequestsKeepAwaitingGameKind() async {
        isolateSharedObservedMatchSids(self)
        ObservedMatchSids.shared.record(sid: "ranked", clientVersionString: "v1")
        await parseRequest(".lq.Lobby.fetchServerTime", payload: [])
        ObservedMatchSids.shared.gameDidStart(is3P: true)
        XCTAssertEqual(ObservedMatchSids.shared.observations[0].is3P, true)
    }

    // MARK: trace 遮蔽

    private func traceLog() -> String {
        (try? String(contentsOfFile: LogManager.shared.categoryLogPaths[LogCategory.liqi.rawValue] ?? "", encoding: .utf8)) ?? ""
    }

    private func flushed(_ marker: String) async -> String {
        liqiLog("flush-\(marker)")
        for _ in 0..<100 {
            let log = traceLog()
            if log.contains("flush-\(marker)") { return log }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return traceLog()
    }

    func testTraceRedactsCredentialPayloadButKeepsOrdinaryStrings() async {
        let manager = LogManager.shared
        let previous = manager.traceToCategoryFiles
        manager.traceToCategoryFiles = true
        addTeardownBlock { @MainActor in manager.traceToCategoryFiles = previous }
        isolateSharedObservedMatchSids(self)

        let secret = "SECRET\(UUID().uuidString.prefix(8))"
        let ordinary = "ORDINARY\(UUID().uuidString.prefix(8))"
        let preview = { (payload: [UInt8]) in "raw: " + liqiHexPreview(Data(payload), limit: 80) }
        let secretPayload = LiqiRequestBuilder.loginBeat(contract: secret).payload
        let ordinaryPayload = LiqiRequestBuilder.cancelUnifiedMatch(matchSid: ordinary).payload
        await parseRequest(LiqiRequestBuilder.loginBeatMethod, payload: secretPayload, msgId: 143)
        await parseRequest(LiqiRequestBuilder.cancelUnifiedMatchMethod, payload: ordinaryPayload, msgId: 144)

        let marker = UUID().uuidString
        let log = await flushed(marker)
        XCTAssertTrue(log.contains("string: \(ordinary)"), "一般字串照記")
        XCTAssertTrue(log.contains(preview(ordinaryPayload)), "一般 hex 照記")
        XCTAssertFalse(log.contains(secret), "憑證字串不得進 log")
        XCTAssertFalse(log.contains(preview(secretPayload).prefix(30)), "憑證 hex 不得進 log")
        XCTAssertTrue(log.contains("method=\(LiqiRequestBuilder.loginBeatMethod), dataSize="), "method 與長度仍記")
    }
}
