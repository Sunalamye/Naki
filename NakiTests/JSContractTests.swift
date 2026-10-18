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

    /// Phase 4：主 listener 以 capture 註冊（攔原事件、重派合成事件的前提），另有一個非 capture 哨兵偵測攔截失效
    /// （docs/archive/plan/plugin-v2-phase4.md §1、§5）。
    func testMessageListenerIsRegisteredInCapturePhase() throws {
        let page = try loadedPage()
        _ = page.evaluateScript("""
            var registered = [];
            WebSocket.prototype.addEventListener = function (type, fn, capture) { registered.push(type + ':' + (capture === true)); };
            new window.WebSocket("wss://example.invalid/gateway");
            """)
        XCTAssertNil(page.exception)
        XCTAssertEqual(page.evaluateScript(
            "registered.filter(function (r) { return r.indexOf('message:') === 0; }).join()")?.toString(), "message:true,message:false")
    }

    private static let servicesRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("command/Services")
    private static let builderFile = servicesRoot.appendingPathComponent("Bridge/LiqiRequestBuilder.swift")

    private func captures(_ pattern: String, _ text: String) throws -> [String] {
        try NSRegularExpression(pattern: pattern).matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { Range($0.range(at: 1), in: text).map { String(text[$0]) } }
    }

    private static let builderDeclaration =
        #"^(?:(?:private|fileprivate|internal|public|nonisolated)\s+)*static\s+(?:let|var)\s+(\w+)\s*(?::\s*String\s*)?=\s*([^{]+)$"#
    private static let builderSend = #"^(?:return )?LiqiRequestSpec\(method: \w+, fields: [^)]*\)$"#

    /// `enum LiqiRequestBuilder` 本體的常數名 → 值（第五輪第 2 條）。支援 `static let／var 名稱 [: String] = 值`；
    /// 值不是字面值的（動作頻道）為 nil，一律當成不在集合內。本體裡其他 `static let／var` 宣告、或不在這種宣告上的
    /// `.lq.` 字面值，列進 `unsupported`：解析器認不出的形式要明確報紅，不能靜默漏掉。
    private func builderMethodValues() throws -> (table: [String: String?], unsupported: [String]) {
        let text = try String(contentsOf: Self.builderFile, encoding: .utf8)
        let lines = text.components(separatedBy: .newlines)
        let start = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("enum LiqiRequestBuilder {") })
        var table: [String: String?] = [:], unsupported: [String] = []
        for line in lines[(start + 1)...] {
            let t = line.trimmingCharacters(in: .whitespaces)
            let parts = try NSRegularExpression(pattern: Self.builderDeclaration).firstMatch(in: t, range: NSRange(t.startIndex..., in: t))
            if let parts, let name = Range(parts.range(at: 1), in: t), let value = Range(parts.range(at: 2), in: t) {
                table[String(t[name])] = try captures(#"^"([^"]*)"\s*$"#, String(t[value])).first
            } else if t.range(of: #"^(?:\w+\s+)*static\s+(?:let|var)\b"#, options: .regularExpression) != nil
                        || t.range(of: #""\.lq\."#, options: .regularExpression) != nil {
                unsupported.append(t)
            }
        }
        return (table, unsupported)
    }

    /// `LiqiSideEffectMethods` 宣告的每個方法常數都併進 `consumed` 或 `all`（inject-receive 第四輪第 4 條）：
    /// 新增常數卻漏加集合就紅。集合定義裡的字面值與引用的 builder 常數，值都必須在 `all`。
    /// builder 本體的常數宣告形式也在這裡檢查（第五輪第 2 條），本體的逐行內容由下一條掃描。
    func testEverySideEffectConstantIsInTheSet() throws {
        let text = try String(contentsOf: Self.builderFile, encoding: .utf8)
        let head = try XCTUnwrap(text.range(of: "enum LiqiSideEffectMethods {"))
        let tail = try XCTUnwrap(text.range(of: "\n}\n", range: head.upperBound..<text.endIndex))
        let body = String(text[head.upperBound..<tail.lowerBound])
        let composition = String(body[try XCTUnwrap(body.range(of: "static let consumed")).lowerBound...])
        let names = try captures(#"static\s+(?:let|var)\s+(\w+)"#, body).filter { $0 != "consumed" && $0 != "all" }
        XCTAssertGreaterThan(names.count, 8, "解析壞了")
        let missing: [String] = try names.filter { name in try captures("\\b(\(name))\\b", composition).isEmpty }
        XCTAssertEqual(missing, [], "LiqiSideEffectMethods 的常數沒併進 consumed／all")
        let (builder, unsupported) = try builderMethodValues()
        XCTAssertEqual(unsupported, [], "LiqiRequestBuilder 有解析器認不出的宣告形式：改寫成 static let／var 名稱 [: String] = 值")
        let strayLiterals = Set(try captures(#""(\.lq\.[^"]*)""#, body)).subtracting(LiqiSideEffectMethods.all)
        let strayConstants = try captures(#"\b(\w+Method)\b"#, body).filter { name in
            !(builder[name].flatMap { $0 }.map { LiqiSideEffectMethods.all.contains($0) } ?? false)
        }
        XCTAssertEqual(strayLiterals.sorted(), [])
        XCTAssertEqual(strayConstants, [])
    }

    /// Swift 依 method 分支的方法只來自 `LiqiSideEffectMethods`（inject-receive 第三輪第 1 條、第四輪第 4 條）。
    /// 規則（不是「任何語法都抓得到」）：`command/Services` 下的每一行（builder 本體只略過常數宣告與 `LiqiRequestSpec(method:)`
    /// 送出定義，第五輪第 2 條），若有值不在 `all` 的 `.lq.` 字面值，
    /// 或提到值不在 `all` 的 `LiqiRequestBuilder` 方法常數名（不論前綴、typealias 或跨行），就必須是逐檔列出的例外行
    /// （比對整行內容，每個例外只能用一次，用不到的例外也紅）。字面值寫在註解裡也算（寧可誤紅）。
    /// 抓不到的：字串拼接或插值組出的方法名、以別名常數再轉手的值。
    func testServicesBranchOnlyOnTheSideEffectMethodSet() throws {
        let builder = try builderMethodValues().table
        XCTAssertGreaterThan(builder.count, 15, "builder 常數解析壞了")
        let names = try NSRegularExpression(pattern: "\\b(" + builder.keys.sorted().joined(separator: "|") + ")\\b")
        func normalized(_ line: String) -> String {
            let t = line.trimmingCharacters(in: .whitespaces)
            return t.hasSuffix(",") ? String(t.dropLast()) : t
        }
        var allowed: [String: [String]] = [
            // error 欄位表：只用於 Naki 自送的回應
            "LiqiResponseStore.swift": LiqiResponseRecord.errorFieldNumbers.map { "\"\($0.key)\": \($0.value)" },
            // 動作頻道的方法名定義
            "LiqiOperationStore.swift": [#"case .selfOperation: return ".lq.FastTest.inputOperation""#,
                                         #"case .chiPengGang: return ".lq.FastTest.inputChiPengGang""#],
            // 保活狀態回報的方法名
            "LiqiActionSender.swift": [#""method": LiqiRequestBuilder.heatbeatMethod"#],
            // MCP 輸出 schema 的說明值
            "MCPToolOutputSchema.swift": [#""method": string(".lq.FastTest.broadcastInGame")"#],
            // manifest 的 sendGuard 前綴檢查
            "PluginRegistry.swift": [#"if let sendGuard, sendGuard.isEmpty || sendGuard.contains(where: { !$0.hasPrefix(".lq.Lobby.") || !methods.contains($0) }) {"#],
        ]
        var stray: [String] = [], scanned = 0
        let files = try XCTUnwrap(FileManager.default.enumerator(at: Self.servicesRoot, includingPropertiesForKeys: nil))
        for case let url as URL in files where url.pathExtension == "swift" {
            let file = url.lastPathComponent
            scanned += 1
            var inBuilder = false
            for line in try String(contentsOf: url, encoding: .utf8).components(separatedBy: .newlines) {
                if file == Self.builderFile.lastPathComponent {
                    inBuilder = inBuilder || line.hasPrefix("enum LiqiRequestBuilder {")
                    let t = line.trimmingCharacters(in: .whitespaces)
                    if inBuilder && (t.range(of: Self.builderDeclaration, options: .regularExpression) != nil
                                     || t.range(of: Self.builderSend, options: .regularExpression) != nil) { continue }
                }
                let literals = try captures(#""(\.lq\.[^"]*)""#, line).filter { !LiqiSideEffectMethods.all.contains($0) }
                let constants = names.matches(in: line, range: NSRange(line.startIndex..., in: line))
                    .compactMap { Range($0.range(at: 1), in: line).map { String(line[$0]) } }
                    .filter { !(builder[$0].flatMap { $0 }.map { LiqiSideEffectMethods.all.contains($0) } ?? false) }
                guard !literals.isEmpty || !constants.isEmpty else { continue }
                if let at = allowed[file]?.firstIndex(of: normalized(line)) { allowed[file]?.remove(at: at); continue }
                stray.append("\(file): \(normalized(line))")
            }
        }
        XCTAssertGreaterThan(scanned, 40, "掃描路徑壞了")
        XCTAssertEqual(stray, [], "用了 LiqiSideEffectMethods 以外的方法：有副作用就加進集合，否則列進該檔例外（整行）")
        XCTAssertEqual(allowed.filter { !$0.value.isEmpty }.mapValues { $0.sorted() }, [:], "例外行已不存在：刪掉過期例外")
    }

    /// Phase 4 變長 replace／drop 的禁改名單涵蓋 Swift 會消費的回應與通知（`LiqiSideEffectMethods.consumed`），缺一即紅
    /// （docs/archive/plan/plugin-v2-phase4.md §4）。
    func testReshapeForbiddenListCoversEverySwiftConsumedMethod() throws {
        XCTAssertTrue(LiqiSideEffectMethods.consumed.isSuperset(of: [".lq.NotifyGameTerminate", ".lq.ActionPrototype",
                                                                     ".lq.Lobby.oauth2Login", ".lq.Lobby.oauth2Auth"]))
        let page = try loadedPage()
        let missing = LiqiSideEffectMethods.consumed.sorted().filter {
            page.evaluateScript("window.__nakiPlugins.isReshapeForbidden('\($0)')")?.toBool() != true
        }
        XCTAssertEqual(missing, [], "Swift 會消費的 method 沒進 JS 的變長改寫禁改名單")
    }

    /// respondLocally 的禁用名單涵蓋 Swift 依 method 分支的全部方法（`LiqiSideEffectMethods.all`）：本地回應這些請求
    /// 會讓 Swift 的匹配、牌局或帳號狀態與伺服器分岔，缺一即紅（plugin-v2-b2.md §5.3）。
    func testRespondForbiddenListCoversEverySwiftSideEffectMethod() throws {
        XCTAssertTrue(LiqiSideEffectMethods.all.isSuperset(of: [LiqiRequestBuilder.startUnifiedMatchMethod,
            LiqiRequestBuilder.cancelUnifiedMatchMethod, LiqiRequestBuilder.cancelMatchMethod, ".lq.Lobby.login"]))
        let page = try loadedPage()
        let missing = LiqiSideEffectMethods.all.sorted().filter {
            page.evaluateScript("window.__nakiPlugins.isRespondForbidden('\($0)')")?.toBool() != true
        }
        XCTAssertEqual(missing, [], "Swift 依 method 分支的方法沒進 JS 的 respondLocally 禁用名單")
        XCTAssertEqual(page.evaluateScript("window.__nakiPlugins.isRespondForbidden('.lq.Lobby.fetchServerTime')")?.toBool(), false,
                       "名單不能空轉成全禁")
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
