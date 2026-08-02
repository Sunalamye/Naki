//
//  WebViewMCPContextTests.swift
//  NakiTests
//
//  p1-1 回歸鎖：`WebViewMCPContext` 從 MCPWebKit 內聯進 Naki 之後，行為要跟上游一樣。
//
//  這個型別以前是遠端套件的一部分，Naki 這邊沒有任何 test 蓋到它；內聯之後如果只靠
//  「build 過了」當驗收，等於把 MCP 的 JS 通道與 log fallback 放進無人看管區。
//  這裡鎖住四件事：沒注入 JS 回調要 throw、有回調要把 completion-handler 橋成 async、
//  error 要原樣傳回、以及外部 log／logs 回調優先於內部 buffer。
//

import XCTest

@testable import Naki

@MainActor
final class WebViewMCPContextTests: XCTestCase {

    // MARK: - executeJavaScript

    /// 沒有注入 `executeJavaScriptCallback` 時必須 throw，而不是回 nil 假裝成功——
    /// MCP 的 `execute_js` 靠這個錯誤把「頁面還沒接上」跟「腳本回 null」分開。
    func testExecuteJavaScriptThrowsWhenCallbackMissing() async {
        let context = WebViewMCPContext()

        do {
            _ = try await context.executeJavaScript("return 1")
            XCTFail("沒有注入回調時不應該成功回傳")
        } catch {
            // 不直接比對 MCPKit 的 `MCPToolError`（NakiTests 沒有連那個 module），
            // 改比對它的 `errorDescription`：`notAvailable("JavaScript execution")`。
            XCTAssertTrue(
                error.localizedDescription.contains("JavaScript execution"),
                "錯誤訊息應指出 JS 通道不可用，實際是 \(error.localizedDescription)"
            )
        }
    }

    /// 回調是 completion-handler 形式，這裡確認它被橋成 async 回傳值。
    func testExecuteJavaScriptBridgesCallbackResult() async throws {
        let context = WebViewMCPContext()
        var receivedScript: String?
        context.executeJavaScriptCallback = { script, completion in
            receivedScript = script
            completion("ok", nil)
        }

        let result = try await context.executeJavaScript("return 'ok'")

        XCTAssertEqual(result as? String, "ok")
        XCTAssertEqual(receivedScript, "return 'ok'")
    }

    /// 回調給 error 時要原樣往外拋，不能被吞成 nil 結果。
    func testExecuteJavaScriptPropagatesCallbackError() async {
        let context = WebViewMCPContext()
        let expected = NSError(domain: "NakiTests", code: 42)
        context.executeJavaScriptCallback = { _, completion in
            completion(nil, expected)
        }

        do {
            _ = try await context.executeJavaScript("boom")
            XCTFail("回調回報 error 時不應該成功回傳")
        } catch {
            XCTAssertEqual((error as NSError).code, 42)
        }
    }

    // MARK: - log 通道

    /// Naki 正式路徑會注入 `logCallback`（寫進 LogManager）；注入後內部 buffer 必須完全不參與，
    /// 否則同一條訊息會同時進 LogManager 與這裡的 buffer，變成第二條 log 通道。
    func testLogCallbackTakesPrecedenceOverInternalBuffer() {
        let context = WebViewMCPContext()
        var captured: [String] = []
        context.logCallback = { captured.append($0) }

        context.log("hello")

        XCTAssertEqual(captured, ["hello"])
        XCTAssertTrue(context.getLogs().isEmpty, "有外部回調時不應該再寫內部 buffer")
    }

    /// 沒有注入任何回調時才用內部 buffer，且讀得回來（帶 timestamp 前綴）。
    func testInternalBufferIsUsedWhenNoCallbacks() {
        let context = WebViewMCPContext()

        context.log("fallback")
        let logs = context.getLogs()

        XCTAssertEqual(logs.count, 1)
        XCTAssertTrue(logs[0].hasSuffix("fallback"), logs[0])

        context.clearLogs()
        XCTAssertTrue(context.getLogs().isEmpty)
    }

    /// `getLogs()` 有外部來源時要讀外部來源（Naki 讀的是 LogManager），不是內部 buffer。
    func testGetLogsPrefersExternalSource() {
        let context = WebViewMCPContext()
        context.log("internal-only")
        context.getLogsCallback = { ["external"] }

        XCTAssertEqual(context.getLogs(), ["external"])
    }
}
