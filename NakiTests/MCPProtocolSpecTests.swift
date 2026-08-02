import XCTest
@testable import Naki

/// p2-4：MCP 協定升級到 2026-07-28（stateless）＋ legacy handshake 並存的回歸測試。
///
/// 這裡只測**純函式**：`MCPHandler` / `DebugServer` 是 app target 的 MainActor 類別，
/// 在 NakiTests（沒開 `SWIFT_DEFAULT_ACTOR_ISOLATION`）裡釋放會 SIGABRT 把 test host
/// 打掉（見 CLAUDE.md）。協定決策因此全部放在 `NakiMCPProtocol` / `NakiMCPRouter`，
/// 讓「升級到底改了什麼」可以被機械檢查，而不是只靠 curl 一次的印象。
///
/// live 面（真的 HTTP 403、Claude Code 連線不回歸）需要跑中的 App，屬未驗證項。
final class MCPProtocolSpecTests: XCTestCase {

    // MARK: - 版本

    func testCurrentVersionIsSpecCurrentAndListedFirst() {
        XCTAssertEqual(NakiMCPProtocol.current, "2026-07-28")
        XCTAssertEqual(NakiMCPProtocol.supportedVersions.first, "2026-07-28")
        XCTAssertEqual(NakiMCPProtocol.supportedVersions,
                       ["2026-07-28", "2025-11-25", "2025-06-18", "2025-03-26"])
    }

    /// legacy 版＝支援清單扣掉 modern 版；`initialize` 只服務這些版本
    func testLegacyVersionsExcludeCurrent() {
        XCTAssertFalse(NakiMCPProtocol.legacyVersions.contains(NakiMCPProtocol.current))
        XCTAssertTrue(NakiMCPProtocol.legacyVersions.contains("2025-03-26"))
        XCTAssertTrue(NakiMCPProtocol.legacyVersions.contains(NakiMCPProtocol.preferredLegacy))
    }

    // MARK: - server/discover（規格 MUST）

    func testDiscoverResultCarriesVersionsCapabilitiesAndIdentity() {
        let result = NakiMCPProtocol.discoverResult()

        XCTAssertEqual(result["resultType"] as? String, "complete")
        XCTAssertEqual(result["supportedVersions"] as? [String], NakiMCPProtocol.supportedVersions)
        XCTAssertNotNil((result["capabilities"] as? [String: Any])?["tools"])
        XCTAssertFalse((result["instructions"] as? String ?? "").isEmpty)

        // CacheableResult：規格對 server/discover 與 tools/list 是 MUST
        XCTAssertEqual(result["cacheScope"] as? String, "public")
        let ttl = result["ttlMs"] as? Int
        XCTAssertNotNil(ttl)
        XCTAssertGreaterThanOrEqual(ttl ?? -1, 0, "ttlMs 必須 >= 0")

        let meta = result["_meta"] as? [String: Any]
        let serverInfo = meta?[NakiMCPProtocol.metaServerInfo] as? [String: Any]
        XCTAssertEqual(serverInfo?["name"] as? String, "naki")
        XCTAssertEqual(serverInfo?["version"] as? String, NakiAppVersion.short)
    }

    /// Naki 只有 tools。Roots／Sampling／Logging 在 2026-07-28 已 Deprecated，
    /// 本來就沒實作，也不該在 capabilities 裡出現。
    func testCapabilitiesDeclareOnlyTools() {
        let capabilities = NakiMCPProtocol.capabilities
        XCTAssertEqual(Set(capabilities.keys), ["tools"])
        XCTAssertEqual((capabilities["tools"] as? [String: Any])?["listChanged"] as? Bool, false)
    }

    // MARK: - result envelope

    func testModernResultsCarryResultTypeAndServerInfo() {
        let decorated = NakiMCPProtocol.decorate(["tools": []], era: .modern)

        XCTAssertEqual(decorated["resultType"] as? String, "complete")
        let serverInfo = (decorated["_meta"] as? [String: Any])?[NakiMCPProtocol.metaServerInfo] as? [String: Any]
        XCTAssertEqual(serverInfo?["version"] as? String, NakiAppVersion.short)
    }

    /// 舊 client 沒有 `resultType` 的概念，規格要它們把缺席視為 "complete"。
    /// 多塞欄位只會多一份要解釋的差異。
    func testLegacyResultsAreLeftAlone() {
        let decorated = NakiMCPProtocol.decorate(["tools": []], era: .legacy)

        XCTAssertNil(decorated["resultType"])
        XCTAssertNil(decorated["_meta"])
    }

    // MARK: - structured tool output（本次升級最大實益）

    func testToolSuccessCarriesStructuredContentAndTextFallback() {
        let payload = NakiMCPProtocol.toolSuccessPayload(
            content: ["serverAccepted": false, "msgId": 60001], era: .modern)

        let structured = payload["structuredContent"] as? [String: Any]
        XCTAssertEqual(structured?["serverAccepted"] as? Bool, false)
        XCTAssertEqual(structured?["msgId"] as? Int, 60001)
        XCTAssertEqual(payload["isError"] as? Bool, false)
        XCTAssertEqual(payload["resultType"] as? String, "complete")

        // content[0].text 仍是同一份 JSON 的字串化（規格建議，且既有腳本不會一次全斷）
        let content = payload["content"] as? [[String: Any]]
        let text = content?.first?["text"] as? String ?? ""
        let reparsed = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
        XCTAssertEqual(reparsed?["serverAccepted"] as? Bool, false)
    }

    /// 舊 client 也拿得到 structuredContent（多一個欄位不會壞），
    /// 差別只在沒有 modern envelope
    func testLegacyToolResultStillCarriesStructuredContent() {
        let payload = NakiMCPProtocol.toolSuccessPayload(content: ["success": true], era: .legacy)

        XCTAssertNotNil(payload["structuredContent"])
        XCTAssertNil(payload["resultType"])
    }

    /// 宣告了 outputSchema（type: object）就 MUST 相符：非 dictionary 一律包一層
    func testStructuredContentWrapsNonDictionaryResults() {
        let wrapped = NakiMCPProtocol.structuredContent(from: [1, 2, 3])
        XCTAssertEqual(wrapped["result"] as? [Int], [1, 2, 3])
    }

    /// NaN 會讓 JSONSerialization 直接 throw，整個回應變 500
    func testStructuredContentSanitizesNonFiniteNumbers() {
        let structured = NakiMCPProtocol.structuredContent(from: ["prob": Double.nan])
        XCTAssertTrue(structured["prob"] is NSNull)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(structured))
    }

    /// 參數錯誤要回 Tool Execution Error（`isError`），不是 protocol error——
    /// 模型才有機會自己改參數重試（2025-11-25 起的規格要求）
    func testToolErrorIsExecutionErrorNotProtocolError() {
        let payload = NakiMCPProtocol.toolErrorPayload(message: "Missing required parameter: tile",
                                                       era: .modern)

        XCTAssertEqual(payload["isError"] as? Bool, true)
        XCTAssertEqual(payload["resultType"] as? String, "complete")
        XCTAssertEqual((payload["structuredContent"] as? [String: Any])?["success"] as? Bool, false)
    }

    // MARK: - tools/list

    func testToolsListCarriesCacheHintsOnlyInModernEra() {
        let modern = NakiMCPProtocol.toolsListResult(tools: [], era: .modern)
        XCTAssertEqual(modern["ttlMs"] as? Int, NakiMCPProtocol.toolsListTTLMs)
        XCTAssertEqual(modern["cacheScope"] as? String, "public")
        XCTAssertEqual(modern["resultType"] as? String, "complete")

        let legacy = NakiMCPProtocol.toolsListResult(tools: [], era: .legacy)
        XCTAssertNil(legacy["ttlMs"], "舊版沒有 CacheableResult，不要塞它看不懂的欄位")
        XCTAssertNil(legacy["cacheScope"])
    }

    // MARK: - 錯誤碼

    func testUnsupportedVersionFailureListsSupportedVersions() {
        let failure = NakiMCPProtocol.unsupportedVersionFailure(requested: "1900-01-01")

        XCTAssertEqual(failure.code, -32022)
        XCTAssertEqual(failure.httpStatus, 400)
        XCTAssertEqual(failure.data?["supported"] as? [String], NakiMCPProtocol.supportedVersions)
        XCTAssertEqual(failure.data?["requested"] as? String, "1900-01-01")
    }

    /// `-32020…-32099` 是規格保留區：只能出現規格定義的碼。
    /// 這條測的是「Naki 沒有把自訂碼放進去」。
    func testEmittedErrorCodesRespectSpecReservedRange() {
        let bodies: [(String, [String])] = [
            ("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"nope\"}", []),
            ("[{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}]", []),
            ("not json", []),
            ("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{}}", []),
            ("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\",\"params\":"
                + "{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"1900-01-01\"}}}", [])
        ]

        let specDefined: Set<Int> = [-32020, -32021, -32022]
        for (body, headers) in bodies {
            let plan = NakiMCPRouter.plan(body: body, headers: headers, toolDefinitions: [])
            guard case .failure(let failure) = plan.outcome else {
                XCTFail("預期失敗：\(body)")
                continue
            }
            if NakiMCPProtocol.specReservedErrorCodes.contains(failure.code) {
                XCTAssertTrue(specDefined.contains(failure.code),
                              "自訂錯誤碼 \(failure.code) 落在規格保留區")
            }
        }
    }

    // MARK: - Router：era 判斷

    /// 帶 modern `_meta` → stateless 語意
    func testRequestWithMetaProtocolVersionIsModern() {
        let plan = NakiMCPRouter.plan(body: modernBody(method: "tools/list"),
                                      headers: [],
                                      toolDefinitions: [])

        guard case .result(let result) = plan.outcome else { return XCTFail("預期 result") }
        XCTAssertEqual(result["resultType"] as? String, "complete")
        XCTAssertEqual(result["cacheScope"] as? String, "public")
    }

    /// 沒有 `_meta` 的舊請求維持舊語意——這是「不回歸」的機械證明
    func testRequestWithoutMetaStaysLegacy() {
        let plan = NakiMCPRouter.plan(body: "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/list\"}",
                                      headers: [],
                                      toolDefinitions: [["name": "get_status"]])

        guard case .result(let result) = plan.outcome else { return XCTFail("預期 result") }
        XCTAssertNil(result["resultType"])
        XCTAssertNil(result["ttlMs"])
        XCTAssertEqual((result["tools"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(plan.id as? Int, 7)
    }

    /// `server/discover` 是 modern-only 的方法，也是 client 用來問「你是哪個世代」的入口
    func testDiscoverIsAnsweredWithoutClientMeta() {
        let plan = NakiMCPRouter.plan(body: "{\"jsonrpc\":\"2.0\",\"id\":\"d1\",\"method\":\"server/discover\"}",
                                      headers: [],
                                      toolDefinitions: [])

        guard case .result(let result) = plan.outcome else { return XCTFail("預期 result") }
        XCTAssertEqual(result["supportedVersions"] as? [String], NakiMCPProtocol.supportedVersions)
        XCTAssertEqual(plan.id as? String, "d1")
    }

    // MARK: - Router：版本檢查

    func testUnsupportedVersionInMetaIsRejectedWith32022() {
        let body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\",\"params\":"
            + "{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2027-01-01\"}}}"

        let plan = NakiMCPRouter.plan(body: body, headers: [], toolDefinitions: [])

        guard case .failure(let failure) = plan.outcome else { return XCTFail("預期 failure") }
        XCTAssertEqual(failure.code, -32022)
        XCTAssertEqual(failure.httpStatus, 400)
        XCTAssertEqual(failure.data?["supported"] as? [String], NakiMCPProtocol.supportedVersions)
    }

    /// HTTP header 也是版本來源（2025-06-18 起）
    func testUnsupportedVersionInHeaderIsRejected() {
        let plan = NakiMCPRouter.plan(body: "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}",
                                      headers: ["MCP-Protocol-Version: 1999-01-01"],
                                      toolDefinitions: [])

        guard case .failure(let failure) = plan.outcome else { return XCTFail("預期 failure") }
        XCTAssertEqual(failure.code, -32022)
    }

    func testSupportedLegacyVersionInHeaderIsAccepted() {
        let plan = NakiMCPRouter.plan(body: "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}",
                                      headers: ["mcp-protocol-version: 2025-06-18"],
                                      toolDefinitions: [])

        guard case .result = plan.outcome else { return XCTFail("2025-06-18 必須照常服務") }
    }

    // MARK: - p5 #2：era 由版本值決定，且 header 也算一個來源

    /// header-only 的 modern 請求（版本放 `MCP-Protocol-Version` header、body 無 `_meta`）
    /// 是官方 Streamable HTTP 的合法形式——必須拿到 modern response（帶 `resultType`），
    /// 不能因為「body 沒有 `_meta`」就被當 legacy（修正前正是如此）。
    func testHeaderOnlyCurrentVersionGetsModernResponse() {
        let plan = NakiMCPRouter.plan(
            body: "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}",
            headers: ["MCP-Protocol-Version: \(NakiMCPProtocol.current)"],
            toolDefinitions: [])

        guard case .result(let result) = plan.outcome else { return XCTFail("預期 result") }
        XCTAssertEqual(result["resultType"] as? String, "complete",
                       "header 宣告的 current 版本就是 modern，result 必須帶 resultType")
        XCTAssertEqual(result["cacheScope"] as? String, "public")
    }

    /// era 由**版本值**決定，不是「有沒有宣告」：帶著舊版值的 `_meta`
    /// （雙棧 client 回退到 2025-11-25）走 legacy——不能因為「有這個 key」就塞成 modern。
    func testMetaWithLegacyVersionValueStaysLegacy() {
        let body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\",\"params\":"
            + "{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2025-11-25\"}}}"
        let plan = NakiMCPRouter.plan(body: body, headers: [], toolDefinitions: [])

        guard case .result(let result) = plan.outcome else { return XCTFail("預期 result") }
        XCTAssertNil(result["resultType"],
                     "帶舊版值的 _meta 是 legacy，不該被塞 resultType")
    }

    /// `Mcp-Method` header 鏡射 JSON-RPC method 供中介層路由；不一致代表請求在傳輸途中
    /// 被改寫，拒絕（與 `Mcp-Name` 同語意——修正前只驗了 Mcp-Name）。
    func testMcpMethodHeaderMismatchIsRejected() {
        let plan = NakiMCPRouter.plan(
            body: "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}",
            headers: ["Mcp-Method: tools/call"],
            toolDefinitions: [])

        guard case .failure(let failure) = plan.outcome else { return XCTFail("預期 failure") }
        XCTAssertEqual(failure.httpStatus, 400)
    }

    /// 一致的 `Mcp-Method` 不受影響（證明擋的是不一致，不是全擋）。
    func testMatchingMcpMethodHeaderPasses() {
        let plan = NakiMCPRouter.plan(
            body: "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}",
            headers: ["Mcp-Method: tools/list"],
            toolDefinitions: [])

        guard case .result = plan.outcome else { return XCTFail("一致的 Mcp-Method 必須照常服務") }
    }

    /// header 與 body 不一致：中介層依 header 路由、server 依 body 執行，
    /// 兩邊看法不同就是安全問題
    func testProtocolVersionHeaderBodyMismatchIsRejected() {
        let plan = NakiMCPRouter.plan(body: modernBody(method: "tools/list"),
                                      headers: ["MCP-Protocol-Version: 2025-06-18"],
                                      toolDefinitions: [])

        guard case .failure(let failure) = plan.outcome else { return XCTFail("預期 failure") }
        XCTAssertEqual(failure.code, -32020)
        XCTAssertEqual(failure.httpStatus, 400)
    }

    func testMcpNameHeaderMismatchIsRejected() {
        let body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":"
            + "{\"name\":\"get_status\",\"arguments\":{}}}"

        let plan = NakiMCPRouter.plan(body: body,
                                      headers: ["Mcp-Name: game_discard"],
                                      toolDefinitions: [])

        guard case .failure(let failure) = plan.outcome else { return XCTFail("預期 failure") }
        XCTAssertEqual(failure.code, -32020)
    }

    // MARK: - Router：方法路由

    func testLegacyInitializeEchoesRequestedVersion() {
        let body = "{\"jsonrpc\":\"2.0\",\"id\":0,\"method\":\"initialize\",\"params\":"
            + "{\"protocolVersion\":\"2025-06-18\"}}"

        let plan = NakiMCPRouter.plan(body: body, headers: [], toolDefinitions: [])

        guard case .result(let result) = plan.outcome else { return XCTFail("預期 result") }
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-06-18")
        XCTAssertEqual((result["serverInfo"] as? [String: Any])?["version"] as? String,
                       NakiAppVersion.short)
    }

    func testInitializeWithUnknownVersionFallsBackToPreferredLegacy() {
        let body = "{\"jsonrpc\":\"2.0\",\"id\":0,\"method\":\"initialize\",\"params\":"
            + "{\"protocolVersion\":\"2024-11-05\"}}"

        let plan = NakiMCPRouter.plan(body: body, headers: [], toolDefinitions: [])

        guard case .result(let result) = plan.outcome else { return XCTFail("預期 result") }
        XCTAssertEqual(result["protocolVersion"] as? String, NakiMCPProtocol.preferredLegacy)
    }

    /// handshake 在 2026-07-28 被移除：modern client 不該送它
    func testInitializeIsNotFoundForModernClients() {
        let plan = NakiMCPRouter.plan(body: modernBody(method: "initialize"),
                                      headers: [],
                                      toolDefinitions: [])

        guard case .failure(let failure) = plan.outcome else { return XCTFail("預期 failure") }
        XCTAssertEqual(failure.code, -32601)
        XCTAssertEqual(failure.httpStatus, 404, "modern era 的未知方法規格指定 404")
    }

    /// `ping` 在 2026-07-28 被移除，legacy client 仍可用
    func testPingSurvivesOnlyInLegacyEra() {
        let legacy = NakiMCPRouter.plan(body: "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}",
                                        headers: [],
                                        toolDefinitions: [])
        guard case .result = legacy.outcome else { return XCTFail("legacy ping 應該還在") }

        let modern = NakiMCPRouter.plan(body: modernBody(method: "ping"),
                                        headers: [],
                                        toolDefinitions: [])
        guard case .failure(let failure) = modern.outcome else { return XCTFail("預期 failure") }
        XCTAssertEqual(failure.code, -32601)
    }

    /// `logging/setLevel` 已被移除（log level 改走每請求 `_meta`）
    func testLoggingSetLevelIsNotFound() {
        let plan = NakiMCPRouter.plan(body: modernBody(method: "logging/setLevel"),
                                      headers: [],
                                      toolDefinitions: [])

        guard case .failure(let failure) = plan.outcome else { return XCTFail("預期 failure") }
        XCTAssertEqual(failure.code, -32601)
    }

    /// 通知沒有 id，就沒有可回的 response——回 202 無 body
    func testInitializedNotificationIsAccepted() {
        let plan = NakiMCPRouter.plan(body: "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}",
                                      headers: [],
                                      toolDefinitions: [])

        guard case .accepted = plan.outcome else { return XCTFail("預期 accepted") }
        XCTAssertNil(plan.id)
    }

    /// 帶 id 的舊 client（把 initialized 當成請求送）仍要拿到一個 result
    func testInitializedWithIdStillGetsResult() {
        let plan = NakiMCPRouter.plan(body: "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"initialized\"}",
                                      headers: [],
                                      toolDefinitions: [])

        guard case .result = plan.outcome else { return XCTFail("預期 result") }
    }

    func testToolsCallPlansToolExecution() {
        let body = "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":"
            + "{\"name\":\"game_discard\",\"arguments\":{\"tile\":\"5m\"},"
            + "\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\"}}}"

        let plan = NakiMCPRouter.plan(body: body, headers: [], toolDefinitions: [])

        guard case .toolCall(let name, let arguments) = plan.outcome else {
            return XCTFail("預期 toolCall")
        }
        XCTAssertEqual(name, "game_discard")
        XCTAssertEqual(arguments["tile"] as? String, "5m")
        XCTAssertEqual(plan.era, .modern)
    }

    func testToolsCallWithoutNameIsInvalidParams() {
        let plan = NakiMCPRouter.plan(
            body: "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{}}",
            headers: [],
            toolDefinitions: [])

        guard case .failure(let failure) = plan.outcome else { return XCTFail("預期 failure") }
        XCTAssertEqual(failure.code, -32602)
    }

    /// JSON-RPC batching 在 2025-06-18 被移除：要明確拒絕，不能默默只處理第一筆
    func testBatchRequestIsRejected() {
        let plan = NakiMCPRouter.plan(
            body: "[{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}]",
            headers: [],
            toolDefinitions: [])

        guard case .failure(let failure) = plan.outcome else { return XCTFail("預期 failure") }
        XCTAssertEqual(failure.code, -32600)
        XCTAssertTrue(failure.message.lowercased().contains("batch"), failure.message)
    }

    func testGarbageBodyIsParseError() {
        let plan = NakiMCPRouter.plan(body: "<html>", headers: [], toolDefinitions: [])

        guard case .failure(let failure) = plan.outcome else { return XCTFail("預期 failure") }
        XCTAssertEqual(failure.code, -32700)
    }

    // MARK: - Origin 驗證

    func testLoopbackOriginsAreAllowed() {
        XCTAssertTrue(NakiMCPOriginPolicy.isAllowed(nil), "curl／MCP client 不送 Origin")
        XCTAssertTrue(NakiMCPOriginPolicy.isAllowed(""))
        XCTAssertTrue(NakiMCPOriginPolicy.isAllowed("http://127.0.0.1:8765"))
        XCTAssertTrue(NakiMCPOriginPolicy.isAllowed("http://localhost:8765"))
        XCTAssertTrue(NakiMCPOriginPolicy.isAllowed("http://localhost"))
    }

    func testRemoteOriginsAreRejected() {
        XCTAssertFalse(NakiMCPOriginPolicy.isAllowed("https://game.maj-soul.com"))
        XCTAssertFalse(NakiMCPOriginPolicy.isAllowed("http://evil.example"))
        XCTAssertFalse(NakiMCPOriginPolicy.isAllowed("null"), "sandboxed iframe 的 opaque origin")
        XCTAssertFalse(NakiMCPOriginPolicy.isAllowed("file://"))
        // 前綴像 loopback 但其實是外部網域，是 DNS rebinding 的典型手法
        XCTAssertFalse(NakiMCPOriginPolicy.isAllowed("http://localhost.evil.example"))
        XCTAssertFalse(NakiMCPOriginPolicy.isAllowed("http://127.0.0.1.evil.example"))
    }

    func testForbiddenBodyIsJSONRPCErrorWithoutId() {
        let body = NakiMCPOriginPolicy.forbiddenBody(origin: "https://evil.example")
        let json = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]

        XCTAssertEqual(json?["jsonrpc"] as? String, "2.0")
        XCTAssertNil(json?["id"])
        XCTAssertNotNil((json?["error"] as? [String: Any])?["code"])
    }

    // MARK: - Header 讀取

    func testHeaderLookupIsCaseInsensitive() {
        let lines = ["POST /mcp HTTP/1.1", "Content-Type: application/json", "ORIGIN: http://localhost:8765"]

        XCTAssertEqual(NakiHTTPHeaderReader.value("origin", in: lines), "http://localhost:8765")
        XCTAssertEqual(NakiHTTPHeaderReader.value("Content-Type", in: lines), "application/json")
        XCTAssertNil(NakiHTTPHeaderReader.value("mcp-method", in: lines))
    }

    /// `lines` 含 body（`/js` 的 body 是呼叫端給的純文字），
    /// 掃到空行就停，body 不會被讀成 header
    func testHeaderLookupStopsAtBody() {
        let lines = ["POST /js HTTP/1.1", "Content-Type: text/plain", "", "origin: http://localhost"]

        XCTAssertNil(NakiHTTPHeaderReader.value("origin", in: lines))
    }

    // MARK: - outputSchema

    /// 新增工具忘了補 outputSchema 會在這裡爆，而不是等 client 發現
    @MainActor
    func testEveryRegisteredToolDeclaresOutputSchema() {
        MCPToolRegistry.shared.registerBuiltInTools()
        let registered = Set(MCPToolRegistry.shared.registeredToolNames)

        XCTAssertFalse(registered.isEmpty)
        let missing = registered.subtracting(NakiToolOutputSchemas.declaredToolNames)
        XCTAssertTrue(missing.isEmpty, "這些工具沒有 outputSchema：\(missing.sorted())")
    }

    @MainActor
    func testToolDefinitionsCarryOutputSchemaAndKeepOrder() {
        MCPToolRegistry.shared.registerBuiltInTools()
        let definitions = MCPToolRegistry.shared.allToolDefinitions()

        XCTAssertEqual(definitions.count, MCPToolRegistry.shared.registeredToolNames.count)
        for definition in definitions {
            let name = definition["name"] as? String ?? "?"
            let output = definition["outputSchema"] as? [String: Any]
            XCTAssertNotNil(output, "\(name) 缺 outputSchema")
            XCTAssertEqual(output?["type"] as? String, "object", "\(name) 的 outputSchema 型別不是 object")
            XCTAssertNotNil(definition["inputSchema"] as? [String: Any], "\(name) 缺 inputSchema")
        }

        // deterministic ordering：規格 SHOULD，且 client 靠它做 prompt cache
        let again = MCPToolRegistry.shared.allToolDefinitions().map { $0["name"] as? String }
        XCTAssertEqual(definitions.map { $0["name"] as? String }, again)
    }

    /// 送 Liqi 的工具共用同一份 schema，且都保證有 `success`
    func testLiqiSendSchemaRequiresSuccess() {
        for name in ["game_discard", "game_action", "bot_chi", "room_create", "lobby_heartbeat"] {
            let schema = NakiToolOutputSchemas.schema(for: name)
            XCTAssertEqual(schema["required"] as? [String], ["success"], name)
            XCTAssertEqual(schema["additionalProperties"] as? Bool, true, name)
            let properties = schema["properties"] as? [String: Any]
            XCTAssertNotNil(properties?["serverAccepted"], "\(name) 應該說明 serverAccepted")
        }
    }

    func testSchemasAreSerializableJSON() {
        for (name, schema) in NakiToolOutputSchemas.all {
            XCTAssertTrue(JSONSerialization.isValidJSONObject(schema), "\(name) 的 schema 不是合法 JSON")
        }
    }

    // MARK: - Helper

    private func modernBody(method: String) -> String {
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"\(method)\",\"params\":{\"_meta\":"
            + "{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\","
            + "\"io.modelcontextprotocol/clientCapabilities\":{}}}}"
    }
}
