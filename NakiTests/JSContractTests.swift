//
//  JSContractTests.swift
//  NakiTests
//
//  bridge D8：Swift 以字串呼叫頁面 API，JS 改名時 `?.` 會讓呼叫靜默變成 no-op。
//  這裡用 JavaScriptCore 依注入順序真的載入 bundle 的三個模組，再確認 `command/`
//  任何 Swift 檔裡出現的 `window.__nakiX.method` 在載入後都是 function。
//

import JavaScriptCore
import XCTest

@testable import Naki

@MainActor
final class JSContractTests: XCTestCase {

    /// 模組載入時會碰到的最小頁面環境（不模擬行為，只讓載入走完）。
    private static let pageShim = """
        var window = this; window.top = window;
        if (typeof console === 'undefined') var console = { log: function () {}, error: function () {} };
        if (typeof WebAssembly === 'undefined') var WebAssembly = {};
        function Document() {}
        Object.defineProperty(Document.prototype, 'hidden', { get: function () { return false; } });
        Object.defineProperty(Document.prototype, 'visibilityState', { get: function () { return 'visible'; } });
        var document = Object.create(Document.prototype);
        document.addEventListener = function () {};
        document.getElementById = function () { return null; };
        var requestAnimationFrame = function () { return 0; };
        var setTimeout = function () { return 0; }, clearTimeout = function () {};
        var WebSocket = function (url) { this.url = url; this.readyState = 1; this.sent = []; };
        WebSocket.prototype.addEventListener = function () {};
        WebSocket.prototype.send = function (data) { this.sent.push(data); };
        WebSocket.CONNECTING = 0; WebSocket.OPEN = 1; WebSocket.CLOSING = 2; WebSocket.CLOSED = 3;
        var atob = function (input) {
            var alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
            var text = String(input).replace(/[\\t\\n\\f\\r ]+/g, "");
            if (text.length % 4 === 0) text = text.replace(/==?$/, "");
            if (text.length % 4 === 1 || /[^A-Za-z0-9+\\/]/.test(text)) throw new Error("InvalidCharacterError");
            var out = "", buffer = 0, bits = 0;
            for (var i = 0; i < text.length; i++) {
                buffer = ((buffer << 6) | alphabet.indexOf(text.charAt(i))) & 0xffff;
                bits += 6;
                if (bits >= 8) { bits -= 8; out += String.fromCharCode((buffer >> bits) & 0xff); }
            }
            return out;
        };
        """

    private func loadedPage() throws -> JSContext {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(Self.pageShim)
        for module in WebSocketInterceptor.jsModules {
            context.evaluateScript(try WebSocketInterceptor.loadJavaScript(named: module))
            XCTAssertNil(context.exception, "\(module) 載入丟例外：\(String(describing: context.exception))")
            context.exception = nil   // 不清的話，一個模組丟例外會讓後面每個模組都報同一個例外
        }
        return context
    }

    /// 掃原始碼而不是列舉常數：新字串寫在哪個檔都會被看到，含 `NakiRuntime`／`PluginRegistry`。
    private func swiftCalls() throws -> Set<String> {
        let command = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("command")
        // 賦值（`window.__nakiX = …`、`window.__nakiX.prop = …`）不是呼叫，另由 `swiftAssignedGlobals` 管。
        let regex = try NSRegularExpression(pattern: #"window\.(__naki\w+)\??\.(\w+)\b(?!\s*=(?!=))"#)
        let files = try XCTUnwrap(FileManager.default.enumerator(at: command, includingPropertiesForKeys: nil))
        var calls: Set<String> = []
        for case let url as URL in files where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let object = Range(match.range(at: 1), in: text),
                      let method = Range(match.range(at: 2), in: text) else { continue }
                calls.insert("\(text[object]).\(text[method])")
            }
        }
        return calls
    }

    /// Swift 字串裡對頁面全域的賦值，回被賦值的全域名（`window.__nakiX.prop = …` 取 `__nakiX`）。
    private func swiftAssignedGlobals() throws -> Set<String> {
        let command = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("command")
        let regex = try NSRegularExpression(pattern: #"window\.(__naki\w+)(?:\.\w+)?\s*=(?!=)"#)
        let files = try XCTUnwrap(FileManager.default.enumerator(at: command, includingPropertiesForKeys: nil))
        var names: Set<String> = []
        for case let url as URL in files where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let name = Range(match.range(at: 1), in: text) { names.insert(String(text[name])) }
            }
        }
        return names
    }

    func testEverySwiftCallResolvesToAJavaScriptFunction() throws {
        let page = try loadedPage()
        let missing = try swiftCalls().sorted().filter {
            page.evaluateScript("typeof window.\($0)")?.toString() != "function"
        }
        XCTAssertEqual(missing, [], "Swift 呼叫了注入的 JS 裡不存在的方法")
    }

    /// 賦值寫進去就沒有「呼叫不到」的錯誤，JS 改名後只是沒人讀：被賦值的全域必須在注入的 JS 裡出現過。
    /// 只比對名稱出現（定義或讀取都算，純註解行不算），不證明讀的行為正確。
    func testEverySwiftAssignedGlobalAppearsInJavaScript() throws {
        let source = try WebSocketInterceptor.jsModules
            .map { try WebSocketInterceptor.loadJavaScript(named: $0) }.joined(separator: "\n")
            .split(separator: "\n").filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !(trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*"))
            }.joined(separator: "\n")
        let assigned = try swiftAssignedGlobals()
        for known in ["__nakiPluginsMayModifyOutbound", "__nakiPluginGrants",
                      "__nakiRecommendations", "__nakiRecommendationContext"] {
            XCTAssertTrue(assigned.contains(known), "抓不到 \(known) 的賦值，regex 或掃描路徑壞了")
        }
        let unknown = assigned.sorted().filter {
            source.range(of: #"\b\#($0)\b"#, options: .regularExpression) == nil
        }
        XCTAssertEqual(unknown, [], "Swift 賦值的全域在注入的 JS 裡完全沒出現（JS 改名後這個賦值沒人讀）")
    }

    /// Naki 自送登記（D9）：sendRaw 要真的登記 msgId，`isNakiSent` 才認得；沒送過的 id 不能認。
    /// 需要 `atob`（JSContext 沒有）與一條 OPEN 的雀魂連線，所以頁面環境補了假的。
    func testSendRawRegistersTheSentMsgId() throws {
        let page = try loadedPage()
        // REQUEST envelope：[2][msgId:2 LE][0a][len][method]
        let method = Array(".lq.Lobby.heatbeat".utf8)
        let bytes: [UInt8] = [2, 0x48, 0xEE, 0x0a, UInt8(method.count)] + method   // msgId 0xEE48 = 61000
        _ = page.evaluateScript("var ws = new window.WebSocket(\"wss://example.invalid/gateway\");")
        let sent = page.evaluateScript(
            "(function () { \(NakiWebSocketScript.sendRaw(base64: Data(bytes).base64EncodedString())) })()")?.toString()
        XCTAssertNil(page.exception)

        XCTAssertEqual(NakiWebSocketScript.sendResult(from: sent).success, true, "送出失敗：\(sent ?? "nil")")
        let socketId = NakiWebSocketScript.sendResult(from: sent).socketId ?? -1
        XCTAssertEqual(page.evaluateScript("window.__nakiWebSocket.isNakiSent(61000, \(socketId))")?.toBool(), true)
        XCTAssertEqual(page.evaluateScript("window.__nakiWebSocket.isNakiSent(61000, \(socketId + 1))")?.toBool(), false)
        XCTAssertEqual(page.evaluateScript("window.__nakiWebSocket.isNakiSent(61000)")?.toBool(), true)
        XCTAssertEqual(page.evaluateScript("window.__nakiWebSocket.isNakiSent(61001)")?.toBool(), false)
        XCTAssertEqual(page.evaluateScript("ws.sent.length")?.toInt32(), 1, "假連線要真的收到那一筆")
    }

    /// 模組缺席或 sendRaw 不見時回可辨識的短碼；模組在時照常呼叫進去。
    func testSendRawScriptReportsMissingModule() throws {
        let script = "(function () { \(NakiWebSocketScript.sendRaw(base64: "AAEC")) })()"
        for page in ["var window = this;", "var window = this; window.__nakiWebSocket = {};"] {
            let context = try XCTUnwrap(JSContext())
            context.evaluateScript(page)
            let result = context.evaluateScript(script)?.toString()
            XCTAssertNil(context.exception, page)
            XCTAssertEqual(NakiWebSocketScript.sendResult(from: result).detail, "no_websocket_module", page)
        }
        let reached = try loadedPage().evaluateScript(
            "(function () { \(NakiWebSocketScript.sendRaw(base64: "A")) })()")?.toString()
        XCTAssertEqual(NakiWebSocketScript.sendResult(from: reached).detail, "invalid_base64")
    }

    /// Phase 4：message listener 以 capture 註冊，且只有一個（攔原事件、重派合成事件的前提，docs/plan/plugin-v2-phase4.md §2）。
    func testMessageListenerIsRegisteredInCapturePhase() throws {
        let page = try loadedPage()
        _ = page.evaluateScript("""
            var registered = [];
            WebSocket.prototype.addEventListener = function (type, fn, capture) { registered.push(type + ':' + (capture === true)); };
            new window.WebSocket("wss://example.invalid/gateway");
            """)
        XCTAssertNil(page.exception)
        XCTAssertEqual(page.evaluateScript(
            "registered.filter(function (r) { return r.indexOf('message:') === 0; }).join()")?.toString(), "message:true")
    }

    /// 抽取與查找都不能空轉：已知呼叫要抓得到，別的物件的同名方法不能算數。
    func testExtractionIsNotVacuous() throws {
        let calls = try swiftCalls()
        for known in ["__nakiWebSocket.sendRaw", "__nakiWebSocket.forceReconnect", "__nakiKeepAlive.tick",
                      "__nakiPlugins.recommendationsChanged", "__nakiHighlight.clear"] {
            XCTAssertTrue(calls.contains(known), "抓不到 \(known)，regex 或掃描路徑壞了")
        }
        let page = try loadedPage()
        XCTAssertEqual(page.evaluateScript("typeof window.__nakiKeepAlive.tick")?.toString(), "function")
        XCTAssertEqual(page.evaluateScript("typeof window.__nakiKeepAlive.uninstall")?.toString(), "undefined",
                       "uninstall 屬於 __nakiHighlight")
    }
}
