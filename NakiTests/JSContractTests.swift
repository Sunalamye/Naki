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
        var WebSocket = function () {};
        """

    private func loadedPage() throws -> JSContext {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(Self.pageShim)
        for module in WebSocketInterceptor.jsModules {
            context.evaluateScript(try WebSocketInterceptor.loadJavaScript(named: module))
            XCTAssertNil(context.exception, "\(module) 載入丟例外：\(String(describing: context.exception))")
        }
        return context
    }

    /// 掃原始碼而不是列舉常數：新字串寫在哪個檔都會被看到，含 `NakiRuntime`／`PluginRegistry`。
    private func swiftCalls() throws -> Set<String> {
        let command = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("command")
        let regex = try NSRegularExpression(pattern: #"window\.(__naki\w+)\??\.(\w+)"#)
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

    func testEverySwiftCallResolvesToAJavaScriptFunction() throws {
        let page = try loadedPage()
        let missing = try swiftCalls().sorted().filter {
            page.evaluateScript("typeof window.\($0)")?.toString() != "function"
        }
        XCTAssertEqual(missing, [], "Swift 呼叫了注入的 JS 裡不存在的方法")
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
