import XCTest
@testable import Naki

/// p1-6：log 雙寫、版本／端點清單漂移、`sanitizeForJSON` 重複實作的回歸測試。
///
/// 這裡刻意只測**純函式與 static 表**：`DebugServer` / `MCPHandler` 都是 app target
/// 的 MainActor 類別，在 NakiTests（沒開 `SWIFT_DEFAULT_ACTOR_ISOLATION`）裡釋放
/// 會 SIGABRT 把 test host 打掉（見 CLAUDE.md），所以不在單測裡建實例。
/// 「/logs 同一事件只出現一次」的端到端證明需要 live server，屬未驗證項。
final class LogAndVersionSingleSourceTests: XCTestCase {

    // MARK: - log 排序與去重

    /// 條目進來的順序與時間順序不一致時，輸出必須依 timestamp 排。
    func testFormatLinesSortsByTimestamp() {
        let base = Date(timeIntervalSince1970: 1_770_000_000)
        let entries = [
            LogEntry(timestamp: base.addingTimeInterval(2), category: .bot, level: .info, message: "third"),
            LogEntry(timestamp: base, category: .ws, level: .info, message: "first"),
            LogEntry(timestamp: base.addingTimeInterval(1), category: .liqi, level: .info, message: "second")
        ]

        let lines = LogManager.formatLines(entries)

        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].hasSuffix("first"), lines[0])
        XCTAssertTrue(lines[1].hasSuffix("second"), lines[1])
        XCTAssertTrue(lines[2].hasSuffix("third"), lines[2])
    }

    /// 舊實作是對「整行字串」做 `.sorted()`——只因每行都以 ISO8601 開頭才碰巧近似時間序。
    /// 時間戳字串相同（毫秒以下的差異）時，字典序會改用訊息內容排，時間序不會。
    func testFormatLinesIsNotLexicographicOnMessage() {
        let base = Date(timeIntervalSince1970: 1_770_000_000)
        let entries = [
            LogEntry(timestamp: base, category: .bridge, level: .info, message: "zzz-earlier"),
            LogEntry(timestamp: base.addingTimeInterval(0.0001), category: .bridge, level: .info, message: "aaa-later")
        ]

        let lines = LogManager.formatLines(entries)

        // 兩行的格式化時間戳相同，字典序會把 aaa 排前面；依 timestamp 排則 zzz 在前
        XCTAssertTrue(lines[0].hasSuffix("zzz-earlier"), lines[0])
        XCTAssertTrue(lines[1].hasSuffix("aaa-later"), lines[1])
        XCTAssertNotEqual(lines, lines.sorted(), "若與字典序一致，這個測試就證明不了東西")
    }

    /// 一個條目就是一行——`/logs` 不再把 DebugServer buffer 與 LogManager 兩份合併
    func testFormatLinesEmitsOneLinePerEntry() {
        let base = Date(timeIntervalSince1970: 1_770_000_000)
        let message = "MCP Server started on http://localhost:8765"
        let entries = [LogEntry(timestamp: base, category: .bridge, level: .info, message: message)]

        let lines = LogManager.formatLines(entries)

        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines.filter { $0.contains(message) }.count, 1)
        XCTAssertTrue(lines[0].contains("[Bridge]"), lines[0])
    }

    /// 時間戳要帶毫秒，消費端才有辦法自己再排序
    func testFormatLineTimestampHasMillisecondResolution() {
        let entry = LogEntry(timestamp: Date(timeIntervalSince1970: 1_770_000_000.123),
                             category: .system, level: .info, message: "x")

        let line = LogManager.formatLines([entry])[0]

        XCTAssertTrue(line.hasPrefix("["), line)
        XCTAssertTrue(line.contains(".123"), line)
    }

    // MARK: - trace 的 lazy 化（p4-3）

    /// `.trace` 只會進各類別檔案，所以那兩個開關關掉時整級都沒人要。
    /// `.info` 以上永遠有人要（UI／console），不受檔案開關影響。
    @MainActor
    func testTraceIsOnlyEnabledWhenSomethingConsumesIt() {
        let manager = LogManager.shared
        let previousTrace = manager.traceToCategoryFiles
        let previousFile = manager.fileLoggingEnabled
        defer {
            manager.traceToCategoryFiles = previousTrace
            manager.fileLoggingEnabled = previousFile
        }

        manager.fileLoggingEnabled = true
        manager.traceToCategoryFiles = true
        XCTAssertTrue(manager.isEnabled(.trace))

        manager.traceToCategoryFiles = false
        XCTAssertFalse(manager.isEnabled(.trace), "沒有任何 sink 要 trace 了")
        XCTAssertTrue(manager.isEnabled(.info), "info 進 UI 與 console，跟檔案開關無關")
        XCTAssertTrue(manager.isEnabled(.event))

        manager.traceToCategoryFiles = true
        manager.fileLoggingEnabled = false
        XCTAssertFalse(manager.isEnabled(.trace), "檔案日誌關掉時 trace 沒有去處")
        XCTAssertTrue(manager.isEnabled(.info))
    }

    /// trace 關掉時，訊息**不會被組出來**。
    ///
    /// 這條鎖的是 `@autoclosure`：p4-3 之前每個 protobuf 欄位都會先做一次
    /// `String(format:"%02x")` 的字串組裝，然後才發現這一級沒人要。
    /// 一局 `liqi.log` 191KB 全是這種訊息，而組裝全在 MainActor 上。
    @MainActor
    func testTraceMessageIsNotEvaluatedWhenTraceIsOff() {
        let manager = LogManager.shared
        let previousTrace = manager.traceToCategoryFiles
        defer { manager.traceToCategoryFiles = previousTrace }

        var evaluations = 0
        func expensiveMessage() -> String {
            evaluations += 1
            return "[test] p4-3 lazy trace"
        }

        manager.traceToCategoryFiles = false
        liqiLog(expensiveMessage())
        XCTAssertEqual(evaluations, 0, "trace 關掉時連字串都不該組")

        manager.traceToCategoryFiles = true
        liqiLog(expensiveMessage())
        XCTAssertEqual(evaluations, 1, "trace 開著就要照常求值，否則訊息會消失")
    }

    /// `.info` 以上不受影響：關掉 trace 不能順手把真的要看的訊息也吃掉。
    @MainActor
    func testInfoMessagesAreStillEvaluatedWhenTraceIsOff() {
        let manager = LogManager.shared
        let previousTrace = manager.traceToCategoryFiles
        defer { manager.traceToCategoryFiles = previousTrace }
        manager.traceToCategoryFiles = false

        var evaluations = 0
        func message() -> String {
            evaluations += 1
            return "[test] p4-3 info still logged"
        }

        liqiLog(message(), level: .info)
        XCTAssertEqual(evaluations, 1)
    }

    // MARK: - 版本單一來源

    /// MCP `initialize` 回報的版本必須就是 App 版本（先前寫死 2.1.0，App 已是 2.6.0）
    func testMCPServerInfoVersionMatchesAppBundle() {
        let bundleVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String

        let serverInfo = MCPHandler.initializeResult()["serverInfo"] as? [String: Any]
        let reported = serverInfo?["version"] as? String

        XCTAssertNotNil(bundleVersion, "test host 應為 Naki.app")
        XCTAssertEqual(reported, bundleVersion)
        XCTAssertEqual(reported, NakiAppVersion.short)
        XCTAssertNotEqual(reported, "unknown", "讀不到 Info.plist 就等於版本又變成假的")
    }

    func testAppVersionFullCombinesShortAndBuild() {
        XCTAssertEqual(NakiAppVersion.full, "\(NakiAppVersion.short) (\(NakiAppVersion.build))")
        XCTAssertFalse(NakiAppVersion.short.isEmpty)
    }

    // MARK: - Endpoint 表 = 首頁的唯一來源

    @MainActor
    func testEndpointTableCoversEveryRoutedPath() {
        let actual = Set(DebugServer.endpoints.map { "\($0.method) \($0.path)" })
        var expected: Set<String> = [
            "GET /", "GET /help", "GET /status", "POST /mcp",
            "POST /js", "GET /screenshot", "GET /logs", "DELETE /logs",
            "GET /game/state", "GET /game/hand", "GET /game/ops",
            "POST /game/discard", "POST /game/action",
            "GET /bot/status", "GET /bot/ops", "GET /bot/deep",
            "POST /bot/trigger", "POST /bot/chi", "POST /bot/pon"
        ]
        // 顯示層注入只存在於 DEBUG build（Release 查表 404，見 DebugServer）
        #if DEBUG
        expected.insert("POST /debug/ui")
        #endif

        XCTAssertEqual(actual, expected)
        XCTAssertEqual(actual.count, DebugServer.endpoints.count, "(method, path) 不可重複")
    }

    /// 首頁先前漏列 `/screenshot`：現在首頁由同一份表產生，漏列在結構上不可能
    @MainActor
    func testRootHTMLListsEveryEndpoint() {
        let html = DebugServer.rootHTML(port: 8765)

        for endpoint in DebugServer.endpoints {
            XCTAssertTrue(html.contains("\(endpoint.method) \(endpoint.path)"),
                          "首頁漏列 \(endpoint.method) \(endpoint.path)")
        }
        XCTAssertTrue(html.contains("GET /screenshot"))
    }

    @MainActor
    func testRootHTMLMarksAccountAffectingEndpointsAndEscapesSummaries() {
        let html = DebugServer.rootHTML(port: 8765)

        XCTAssertTrue(html.contains("⚠️ 會影響帳號"))
        // `POST /game/discard` 的說明含 JSON 範例，必須被 escape，否則 HTML 會壞掉
        XCTAssertTrue(html.contains("&quot;tile&quot;"), "summary 的引號沒有 escape")
        XCTAssertFalse(html.contains("{\"tile\""))
    }

    @MainActor
    func testRootHTMLReportsAppVersionAndPort() {
        let html = DebugServer.rootHTML(port: 9123)

        XCTAssertTrue(html.contains(NakiAppVersion.full))
        XCTAssertTrue(html.contains("port 9123"))
    }

    // MARK: - JSONSanitizer（原本 DebugServer 與 MCPHandler 各一份）

    func testSanitizerReplacesNonFiniteNumbersWithNull() {
        let dirty: [String: Any] = [
            "nan": Double.nan,
            "inf": Double.infinity,
            "negInf": -Double.infinity,
            "floatNan": Float.nan,
            "ok": 0.5
        ]

        let clean = JSONSanitizer.sanitize(dirty)

        XCTAssertTrue(clean["nan"] is NSNull)
        XCTAssertTrue(clean["inf"] is NSNull)
        XCTAssertTrue(clean["negInf"] is NSNull)
        XCTAssertTrue(clean["floatNan"] is NSNull)
        XCTAssertEqual(clean["ok"] as? Double, 0.5)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(clean))
    }

    func testSanitizerRecursesIntoNestedContainers() {
        let dirty: [String: Any] = [
            "recommendations": [
                ["tile": "5m", "prob": Double.nan],
                ["tile": "1p", "prob": 0.25]
            ],
            "nested": ["deep": ["value": Double.infinity]]
        ]

        let clean = JSONSanitizer.sanitize(dirty)

        XCTAssertTrue(JSONSerialization.isValidJSONObject(clean))
        let recs = clean["recommendations"] as? [[String: Any]]
        XCTAssertTrue(recs?[0]["prob"] is NSNull)
        XCTAssertEqual(recs?[1]["prob"] as? Double, 0.25)
        let deep = (clean["nested"] as? [String: Any])?["deep"] as? [String: Any]
        XCTAssertTrue(deep?["value"] is NSNull)
    }

    func testSanitizerLeavesCleanPayloadUntouched() {
        let payload: [String: Any] = ["status": "running", "port": 8765, "flag": true]

        let clean = JSONSanitizer.sanitize(payload)

        XCTAssertEqual(clean["status"] as? String, "running")
        XCTAssertEqual(clean["port"] as? Int, 8765)
        XCTAssertEqual(clean["flag"] as? Bool, true)
    }
}
