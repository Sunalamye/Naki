//
//  WebSocketInjectionTests.swift
//  NakiTests
//
//  p1-2 回歸鎖：JS 模組載入失敗時**不得**有 fallback，而且必須大聲失敗。
//
//  舊行為：`WebSocketInterceptor.injectionScript` 在模組全掛時退回一份內嵌的
//  簡化攔截器。那份 fallback 是獨立演化的第二套實作——不同的 majsoul URL 判定、
//  socketId 從 0 起算（模組版從 1）、而且**沒有 sendRaw**。
//  一旦踩到，App 表象只是「不會自動打牌」：沒有錯誤、沒有 UI 提示，
//  但所有 Liqi 動作（打牌／副露／和牌／開房／匹配）全部靜默失效。
//
//  這批 test 鎖三件事：
//  1. 缺任何一個模組 → 一定 `.failed`，永遠不會生出可注入的腳本（無 fallback）。
//  2. 失敗原因要分得出「檔不存在 / 讀不出來 / 內容為空」。
//  3. 失敗狀態要能被 UI 與 `/status` 看見（`failureSummary` / `statusPayload`）。
//

import XCTest

@testable import Naki

@MainActor
final class WebSocketInjectionTests: XCTestCase {

    // MARK: - 正常路徑

    /// App bundle 裡兩個模組都在時要能組出腳本，且不得被標成失敗。
    /// 這條同時是「p1-2 沒有把正常路徑弄壞」的機械證據。
    func testAppBundleProducesInjectableScript() {
        let outcome = WebSocketInterceptor.buildInjection()

        switch outcome {
        case .ready(let source, let modules):
            XCTAssertEqual(modules, WebSocketInterceptor.jsModules, "模組順序必須維持（naki-websocket 依賴 naki-core）")
            XCTAssertTrue(source.contains("// === naki-core.js ==="))
            XCTAssertTrue(source.contains("// === naki-websocket.js ==="))
            XCTAssertTrue(source.contains("sendRaw"), "沒有 sendRaw 就送不出任何 Liqi 動作")
        case .failed(let loaded, let failures):
            XCTFail("App bundle 應該含全部 JS 模組，實際 loaded=\(loaded) failures=\(failures.map(\.text))")
        }
    }

    /// 成功時 `createUserScript()` 要回一個真的 WKUserScript，並把狀態記成「沒失敗」。
    func testCreateUserScriptRecordsSuccess() {
        let script = WebSocketInterceptor.createUserScript()

        XCTAssertNotNil(script, "App bundle 完整時不該回 nil")
        XCTAssertEqual(script?.injectionTime, .atDocumentStart)
        XCTAssertFalse(script?.isForMainFrameOnly ?? true, "iframe 也要攔（forMainFrameOnly: false）")

        let report = JSInjectionState.shared.report
        XCTAssertTrue(report.attempted)
        XCTAssertFalse(report.isFailed)
        XCTAssertNil(report.failureSummary)
        XCTAssertEqual(report.loadedModules, WebSocketInterceptor.jsModules)
    }

    // MARK: - 沒有 fallback（本 task 的主鎖）

    /// 全部模組都缺 → 一定是 `.failed`。
    /// 舊版在這個分支會回一份內嵌腳本，於是「注入成功」但 sendRaw 不存在。
    func testAllModulesMissingNeverProducesScript() {
        let outcome = WebSocketInterceptor.buildInjection(
            modules: ["naki-no-such-module-a", "naki-no-such-module-b"])

        guard case .failed(let loaded, let failures) = outcome else {
            return XCTFail("模組全缺時不得產生任何可注入腳本（fallback 已刪除）")
        }
        XCTAssertTrue(loaded.isEmpty)
        XCTAssertEqual(failures.count, 2)
        XCTAssertTrue(failures.allSatisfy { $0.reason == .notFound })
    }

    /// 只缺一個也不注入：部分注入會產生「能高亮但送不出動作」的半套狀態，
    /// 而那正是舊 fallback 最難察覺的失效形態。
    func testPartialLoadIsAlsoFailure() {
        let outcome = WebSocketInterceptor.buildInjection(
            modules: ["naki-core", "naki-no-such-module"])

        guard case .failed(let loaded, let failures) = outcome else {
            return XCTFail("少一個模組就不能注入")
        }
        XCTAssertEqual(loaded, ["naki-core"], "要記下已載入的是哪些，方便判斷是打包漏檔還是全壞")
        XCTAssertEqual(failures.map(\.module), ["naki-no-such-module"])
    }

    /// 模組清單被清空同樣算失敗，不能回一份空腳本假裝成功。
    func testEmptyModuleListIsFailure() {
        guard case .failed(_, let failures) = WebSocketInterceptor.buildInjection(modules: []) else {
            return XCTFail("沒有模組可注入時必須走失敗路徑")
        }
        XCTAssertEqual(failures.count, 1)
    }

    // MARK: - 失敗原因要分得出來

    func testMissingFileIsNotFound() {
        XCTAssertThrowsError(try WebSocketInterceptor.loadJavaScript(named: "naki-no-such-module")) { error in
            guard let failure = error as? JSModuleFailure else {
                return XCTFail("應該丟 JSModuleFailure，實際是 \(error)")
            }
            XCTAssertEqual(failure.reason, .notFound)
            XCTAssertNil(failure.detail, "找不到檔就沒有底層錯誤可報")
        }
    }

    /// 檔在、但內容是空的——這種最陰險：注入「成功」而頁面上什麼都沒有。
    func testEmptyFileIsReportedAsEmpty() throws {
        let bundle = try makeTemporaryBundle(files: ["naki-core.js": "   \n\t\n"])

        XCTAssertThrowsError(try WebSocketInterceptor.loadJavaScript(named: "naki-core", in: bundle)) { error in
            XCTAssertEqual((error as? JSModuleFailure)?.reason, .empty)
        }
    }

    /// 同一個暫存 bundle 讀得到非空檔案時要正常回傳——確認上一條測到的是「空」而不是「找不到」。
    func testTemporaryBundleReadsNonEmptyFile() throws {
        let bundle = try makeTemporaryBundle(files: ["naki-core.js": "console.log('x');"])

        let source = try WebSocketInterceptor.loadJavaScript(named: "naki-core", in: bundle)
        XCTAssertEqual(source, "console.log('x');")
    }

    // MARK: - 失敗要看得見

    func testFailureSummaryListsEveryModule() {
        let report = JSInjectionReport(
            attempted: true,
            loadedModules: [],
            failures: [
                JSModuleFailure(module: "naki-core", reason: .notFound),
                JSModuleFailure(module: "naki-websocket", reason: .unreadable, detail: "boom")
            ])

        XCTAssertTrue(report.isFailed)
        let summary = try? XCTUnwrap(report.failureSummary)
        XCTAssertTrue(summary?.contains("naki-core.js") ?? false)
        XCTAssertTrue(summary?.contains("naki-websocket.js") ?? false)
        XCTAssertTrue(summary?.contains("boom") ?? false, "底層錯誤要帶出來，否則無從查起")
    }

    /// `/status` 必須帶 `jsInjectionFailed: true`，否則外部工具會拿 `/game/*`、`/bot/*`
    /// 的空資料當成「這局沒事」。
    func testStatusPayloadFlagsFailure() {
        let report = JSInjectionReport(
            attempted: true,
            loadedModules: ["naki-core"],
            failures: [JSModuleFailure(module: "naki-websocket", reason: .notFound)])

        let payload = report.statusPayload
        XCTAssertEqual(payload["jsInjectionFailed"] as? Bool, true)
        XCTAssertEqual(payload["jsInjectionAttempted"] as? Bool, true)
        XCTAssertEqual(payload["jsModulesLoaded"] as? [String], ["naki-core"])
        XCTAssertNotNil(payload["jsInjectionNote"])

        let failures = payload["jsInjectionFailures"] as? [[String: String]]
        XCTAssertEqual(failures?.count, 1)
        XCTAssertEqual(failures?.first?["module"], "naki-websocket.js")
        XCTAssertEqual(failures?.first?["reason"], "not_found")
    }

    func testStatusPayloadIsCleanWhenHealthy() {
        let payload = JSInjectionReport(
            attempted: true, loadedModules: ["naki-core", "naki-websocket"], failures: []
        ).statusPayload

        XCTAssertEqual(payload["jsInjectionFailed"] as? Bool, false)
        XCTAssertNil(payload["jsInjectionFailures"])
        XCTAssertNil(payload["jsInjectionNote"])
    }

    /// 還沒建 WebView 就不算失敗——否則啟動瞬間會閃一次紅色橫幅。
    func testNotAttemptedIsNotAFailure() {
        let report = JSInjectionReport.notAttempted
        XCTAssertFalse(report.isFailed)
        XCTAssertNil(report.failureSummary)
        XCTAssertEqual(report.statusPayload["jsInjectionAttempted"] as? Bool, false)
    }

    func testStateRecordsFailure() {
        let state = JSInjectionState()
        XCTAssertFalse(state.report.attempted)

        state.record(.failed(loaded: [], failures: [JSModuleFailure(module: "naki-core", reason: .empty)]))
        XCTAssertTrue(state.report.isFailed)

        state.reset()
        XCTAssertFalse(state.report.attempted)
    }

    // MARK: - naki-core.js 熱路徑契約（p4-3）
    //
    // 這幾條鎖的是「每幀幾百次的那段程式碼裡不准有什麼」。真正的視覺效果只能 live 驗，
    // 但「有沒有把同步狀態查詢加回 draw 迴圈」「基準線有沒有上限」是可以機械檢查的，
    // 而這正是 p4-3 之前踩到的三個坑。

    /// `drawElements` wrapper 內不得再出現任何 `gl.getParameter`。
    ///
    /// live 實測一幀約 356 個 draw call，舊版每一個都問兩次 GL 狀態
    /// （`CURRENT_PROGRAM` + `TEXTURE_BINDING_2D`）。現在這兩個值由
    /// `useProgram` / `bindTexture` / `activeTexture` 的 hook 維護，
    /// `getParameter` 只在 `install()` 取初值時出現。
    func testDrawElementsHookHasNoPerDrawStateQueries() throws {
        let source = try WebSocketInterceptor.loadJavaScript(named: "naki-core")

        let marker = "hookMethod(gl, 'drawElements'"
        let parts = source.components(separatedBy: marker)
        XCTAssertEqual(parts.count, 2, "找不到 drawElements hook（或裝了不只一份）")

        XCTAssertFalse(parts[1].contains("getParameter"),
                       "drawElements hook 之後不得再有 getParameter——那是每幀幾百次的同步狀態查詢")

        // 狀態要有人維護，否則快取就是舊值
        for method in ["useProgram", "activeTexture", "bindTexture"] {
            XCTAssertTrue(source.contains("hookMethod(gl, '\(method)'"),
                          "\(method) 沒被攔，快取的 GL 狀態會漂掉")
        }
    }

    /// `baselineFrames` 必須在 rAF 回呼裡加，不能在 drawElements 裡加。
    ///
    /// 舊版加在 draw 上，數出來的是 draw call 數（live 實測 1,197 萬）而不是幀數
    /// （3.4 萬）——於是「基準線 >120」在開頁後不到一幀就滿足，保護等於不存在。
    func testBaselineFramesAreCountedPerFrameNotPerDraw() throws {
        let source = try WebSocketInterceptor.loadJavaScript(named: "naki-core")

        let increments = source.components(separatedBy: "baselineFrames++").count - 1
        XCTAssertEqual(increments, 1, "幀計數只能有一處")

        let rafIndex = try XCTUnwrap(source.range(of: "hookMethod(window, 'requestAnimationFrame'"))
        let incIndex = try XCTUnwrap(source.range(of: "baselineFrames++"))
        XCTAssertTrue(incIndex.lowerBound > rafIndex.lowerBound,
                      "baselineFrames 必須在 requestAnimationFrame hook 裡加，否則數的是 draw call")
    }

    /// 基準線簽章要有上限（簽章含 objId，資源重建會一直產生新的），
    /// 而且上限要在 `state()` 裡看得到——否則沒辦法從外面驗收「有沒有封頂」。
    func testBaselineSignaturesAreBounded() throws {
        let source = try WebSocketInterceptor.loadJavaScript(named: "naki-core")

        XCTAssertTrue(source.contains("BASELINE_SIG_LIMIT"), "基準線簽章沒有上限")
        XCTAssertTrue(source.contains("baselineSigLimit"), "state() 要回報上限，驗收才查得到")
        XCTAssertFalse(source.contains("new Set()"), "簽章集合改用 Map 保插入序當 LRU")
    }

    /// hook 必須拆得掉：`install()` 以前是單向的，連「關掉之後跑得一樣快嗎」都驗不了。
    func testHighlightHookIsReversible() throws {
        let source = try WebSocketInterceptor.loadJavaScript(named: "naki-core")

        XCTAssertTrue(source.contains("function uninstall()"))
        XCTAssertTrue(source.contains("uninstall: function"), "__nakiHighlight 要對外暴露 uninstall")
        XCTAssertTrue(source.contains("clear: function (full)"), "clear(true) 要能連 hook 一起拆")
    }

    /// Swift 端送的仍然是不帶參數的 `clear()`——那條路**不能**變成完全解除，
    /// 否則每次切 `.off` 都要重新收 120 幀基準線才會恢復副露面板判斷。
    @MainActor
    func testSwiftClearScriptDoesNotUninstallTheHook() {
        XCTAssertEqual(GameHighlightScript.clear, "window.__nakiHighlight?.clear();")
        XCTAssertFalse(GameHighlightScript.clear.contains("true"))
    }

    // MARK: - Helpers

    /// 建一個只含指定檔案的暫存 bundle（macOS `Contents/Resources` 佈局）
    private func makeTemporaryBundle(files: [String: String]) throws -> Bundle {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("NakiInjectionTests-\(UUID().uuidString).bundle")
        let resources = root.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        for (name, contents) in files {
            try contents.write(to: resources.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        return try XCTUnwrap(Bundle(url: root), "無法建立暫存 bundle")
    }
}
