//
//  BridgeMessageContractTests.swift
//  NakiTests
//
//  p1-5 回歸鎖：JS↔Swift 的 `websocketBridge` 訊息契約必須兩端對得上。
//
//  舊狀態是兩端各自演化：
//  - JS 送 `websocket_connect` / `force_reconnect`，Swift 沒有 case → 靜默丟棄。
//  - Swift 有 `interceptor_ready` / `websocket_debug` / `websocket_closed` 的 case，
//    沒有任何 JS 送出端 → 永遠不會執行的死碼。
//  - `console_log` 兩端欄位不同（JS `{level,args}` vs Swift `data["message"]`），
//    看起來有接上，實際上永遠取不到值。
//  而 `default: break` 讓上述每一種都不留痕跡。
//
//  這批 test 鎖四件事：
//  1. JS 原始碼裡 `sendToSwift('…')` 的 type 集合 == `BridgeMessageType.allCases`（雙向）。
//  2. 已刪除的舊 type 不會偷偷回到 JS。
//  3. 未知 type 的 warning 去重器：同一種只報一次、種類數有上限。
//  4. 每個 type 的 payload 帶齊 Swift 讀的欄位；缺欄位走 `warnMalformed`，不靜默 return。
//
//  註：switch 是否處理了每個 case 不需要 test——`WebSocketMessageHandler` 的 switch
//  沒有 `default`，漏掉會直接編譯失敗。
//

import XCTest

@testable import Naki

@MainActor
final class BridgeMessageContractTests: XCTestCase {

    // MARK: - JS 端實際送出的 type

    /// 從注入的 JS 模組原始碼抓出所有 `sendToSwift('<type>'` 的字面 type。
    ///
    /// 讀的是 bundle 內容而不是 repo 路徑：契約要鎖的是**真的會被注入的那份**。
    private func typesSentByJavaScript() throws -> Set<String> {
        var found: Set<String> = []
        let pattern = #"sendToSwift\(\s*['"]([A-Za-z0-9_]+)['"]"#
        let regex = try NSRegularExpression(pattern: pattern)

        for module in WebSocketInterceptor.jsModules {
            let source = try WebSocketInterceptor.loadJavaScript(named: module)
            let range = NSRange(source.startIndex..<source.endIndex, in: source)
            for match in regex.matches(in: source, range: range) {
                guard match.numberOfRanges > 1,
                      let r = Range(match.range(at: 1), in: source) else { continue }
                found.insert(String(source[r]))
            }
        }
        return found
    }

    /// 抽取邏輯本身要能抓到東西——不然下面兩條「集合相等」會因為兩邊都空而假綠。
    func testExtractionFindsSenders() throws {
        let sent = try typesSentByJavaScript()
        XCTAssertFalse(sent.isEmpty, "JS 裡一定有 sendToSwift 呼叫；抓不到代表 regex 或 bundle 壞了")
        XCTAssertTrue(sent.contains("websocket_message"),
                      "websocket_message 是主要資料通道，抓不到就是抽取邏輯有問題")
    }

    /// JS 送的每個 type 都必須有 Swift case，否則訊息被丟掉。
    func testEverySentTypeIsHandled() throws {
        let sent = try typesSentByJavaScript()
        let handled = Set(BridgeMessageType.allCases.map(\.rawValue))
        let unhandled = sent.subtracting(handled).sorted()

        XCTAssertTrue(unhandled.isEmpty,
                      "JS 送了 Swift 不認得的 type：\(unhandled)。"
                      + "這些訊息會被丟掉——要嘛加進 BridgeMessageType，要嘛 JS 停送。")
    }

    /// Swift 的每個 case 都必須有活的 JS 送出端，否則就是死碼。
    func testEveryHandledTypeHasLiveSender() throws {
        let sent = try typesSentByJavaScript()
        let handled = Set(BridgeMessageType.allCases.map(\.rawValue))
        let dead = handled.subtracting(sent).sorted()

        XCTAssertTrue(dead.isEmpty,
                      "BridgeMessageType 有沒人送的 case：\(dead)。"
                      + "沒有送出端的 case 永遠不會執行，應該刪掉。")
    }

    /// 契約是精確相等，不只是互相包含（上面兩條合起來即此，這條是可讀的整體斷言）。
    func testContractIsExactlySymmetric() throws {
        let sent = try typesSentByJavaScript()
        let handled = Set(BridgeMessageType.allCases.map(\.rawValue))
        XCTAssertEqual(sent, handled)
    }

    /// 這幾個 type 是這次刪掉的：要嘛兩端欄位從來沒對上，要嘛送出端整檔不存在。
    /// 任何一個回到 JS 而 Swift 沒有對應處理，都會再變成靜默丟棄。
    func testRemovedLegacyTypesStayRemoved() throws {
        let removed = [
            "websocket_open",       // 與 websocket_connected 同一個 open 事件送兩份
            "websocket_closed",     // websocket_close 的別名，零送出端
            "websocket_debug",
            "interceptor_ready",
            "console_log",          // JS {level,args} vs Swift data["message"]，欄位對不上
            "addHandPai",           // 依賴不存在的 Laya
            "autoplay_click",
            "autoplay_tile_click",
            "autoplay_button_click",
            "autoplay_error"
        ]
        let sent = try typesSentByJavaScript()
        let handled = Set(BridgeMessageType.allCases.map(\.rawValue))

        for type in removed {
            XCTAssertFalse(sent.contains(type), "JS 不該再送已刪除的 \(type)")
            XCTAssertFalse(handled.contains(type), "Swift 不該再收已刪除的 \(type)")
        }
    }

    // MARK: - 未知 type 的 warning 去重

    func testUnknownTypeWarnsOncePerType() {
        var reporter = UnknownBridgeTypeReporter()

        XCTAssertTrue(reporter.shouldWarn("mystery"), "第一次看到要報")
        XCTAssertFalse(reporter.shouldWarn("mystery"), "同一種不重複報，否則會洗掉對局時間軸")
        XCTAssertTrue(reporter.shouldWarn("another"), "不同種類要各報一次")
        XCTAssertEqual(reporter.count, 2)
    }

    /// 頁面上任何腳本都能亂送 type；記憶體不能跟著無限長大。
    func testUnknownTypeReporterSaturates() {
        var reporter = UnknownBridgeTypeReporter(limit: 3)

        XCTAssertTrue(reporter.shouldWarn("a"))
        XCTAssertTrue(reporter.shouldWarn("b"))
        XCTAssertFalse(reporter.isSaturated)
        XCTAssertTrue(reporter.shouldWarn("c"))
        XCTAssertTrue(reporter.isSaturated, "撞到上限")

        XCTAssertFalse(reporter.shouldWarn("d"), "滿了之後一律閉嘴")
        XCTAssertEqual(reporter.count, 3, "滿了之後也不再長大")
    }

    // MARK: - JS 端欄位名

    /// 取出每一個 `sendToSwift('<type>', { … })` 的 payload 物件字面（皆為單層，無巢狀括號）
    private func senderPayloads(modules: [String] = ["naki-websocket"]) throws -> [(type: String, body: String)] {
        let regex = try NSRegularExpression(
            pattern: #"sendToSwift\(\s*['"]([A-Za-z0-9_]+)['"]\s*,\s*\{([^}]*)\}"#)

        return try modules.flatMap { module in
            let source = try WebSocketInterceptor.loadJavaScript(named: module)
            let range = NSRange(source.startIndex..<source.endIndex, in: source)
            return regex.matches(in: source, range: range).compactMap { match -> (type: String, body: String)? in
                guard match.numberOfRanges > 2,
                      let typeRange = Range(match.range(at: 1), in: source),
                      let bodyRange = Range(match.range(at: 2), in: source) else { return nil }
                return (String(source[typeRange]), String(source[bodyRange]))
            }
        }
    }

    private func declaresKey(_ key: String, in body: String) -> Bool {
        body.range(of: #"(^|[\s,])"# + key + #"\s*:"#, options: .regularExpression) != nil
    }

    /// Swift 的 handler 一律 `data["socketId"]`；JS 以前每筆同時帶 `id` 與 `socketId`
    /// 兩個同義欄位，於是「改欄位名」這件事永遠只改對一半，而症狀是
    /// 「有 case 但 guard 直接 return」的靜默失效。現在只留 `socketId` 一個。
    func testSenderPayloadsUseSocketIdField() throws {
        let calls = try senderPayloads()
        XCTAssertGreaterThanOrEqual(calls.count, 5, "抓不到 payload 代表 regex 壞了")

        let legacyIdKey = try NSRegularExpression(pattern: #"(^|[\s,{])id\s*:"#)

        for call in calls {
            let range = NSRange(call.body.startIndex..<call.body.endIndex, in: call.body)
            XCTAssertNil(legacyIdKey.firstMatch(in: call.body, range: range),
                         "\(call.type) 的 payload 不該再帶舊的同義欄位 `id`")

            if call.type != BridgeMessageType.forceReconnect.rawValue {
                XCTAssertTrue(call.body.contains("socketId"),
                              "\(call.type) 的 payload 必須帶 socketId，Swift 端靠它辨識連線")
            }
        }
    }

    /// Swift handler 對每個 type 讀的欄位（`WebSocketMessageHandler` 裡的 `data["…"]`）。
    /// handler 多讀一個欄位時這張表要跟著加，JS 少送就會在這裡紅，而不是 guard 靜默 return。
    private static let fieldsSwiftReads: [BridgeMessageType: [String]] = [
        .websocketConnect: ["socketId", "url", "isMajsoul"],
        .websocketConnected: ["socketId", "isMajsoul"],
        .websocketMessage: ["socketId", "direction", "data", "type"],
        .websocketClose: ["socketId", "isMajsoul"],
        .websocketError: ["socketId"],
        .forceReconnect: ["closedCount"],
        .pluginEvent: ["id", "msg"]
    ]

    func testEveryTypeDeclaresFieldsSwiftReads() throws {
        let calls = try senderPayloads(modules: WebSocketInterceptor.jsModules)

        for type in BridgeMessageType.allCases {
            let fields = try XCTUnwrap(Self.fieldsSwiftReads[type], "\(type.rawValue) 沒有列出 Swift 讀的欄位")
            let senders = calls.filter { $0.type == type.rawValue }
            XCTAssertFalse(senders.isEmpty, "\(type.rawValue) 找不到帶 payload 的送出端")
            for call in senders {
                for field in fields {
                    XCTAssertTrue(declaresKey(field, in: call.body), "\(type.rawValue) 的 payload 缺 \(field)：\(call.body)")
                }
            }
        }
    }

    // MARK: - 缺欄位與 text frame

    private func malformedLogCount() -> Int {
        LogManager.shared.entries.filter { $0.message.contains("websocket_message 缺少 direction 或 data") }.count
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return condition()
    }

    /// 缺 direction／data 以前直接 return，連一行 log 都沒有
    func testMissingDirectionGoesThroughWarnMalformed() async {
        let handler = WebSocketMessageHandler()
        let before = malformedLogCount()

        handler.dispatch(type: "websocket_message", data: ["socketId": 1, "data": "AAAA", "type": "binary"])
        handler.dispatch(type: "websocket_message", data: ["socketId": 1, "direction": "receive", "type": "binary"])

        let logged = await waitUntil { self.malformedLogCount() > before }
        XCTAssertTrue(logged, "缺欄位要走 warnMalformed")
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(malformedLogCount(), before + 1, "同一種格式錯誤只報一次")
    }

    /// text frame 是原始字串：不得當 base64 解（每筆失敗洗版，或把字串當封包解）
    func testTextFrameIsNotDecodedAsBase64() async {
        let handler = WebSocketMessageHandler()
        let failure = "Failed to decode base64"
        let failuresBefore = LogManager.shared.entries.filter { $0.message.contains(failure) }.count
        let fenceBefore = malformedLogCount()

        handler.dispatch(type: "websocket_message",
                         data: ["socketId": 1, "direction": "receive", "data": "{\"hello\"}", "type": "text"])
        // 圍欄：log 依序進 main queue，看到它就代表前一筆該寫的 log 都已寫入
        handler.dispatch(type: "websocket_message", data: ["socketId": 1])

        let fenced = await waitUntil { self.malformedLogCount() > fenceBefore }
        XCTAssertTrue(fenced)
        XCTAssertEqual(LogManager.shared.entries.filter { $0.message.contains(failure) }.count, failuresBefore)
    }
}
