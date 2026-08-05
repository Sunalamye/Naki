//
//  MCPProtocolSpec.swift
//  Naki
//
//  MCP 協定語意的單一來源（2026-07-28 stateless ＋ legacy handshake 並存）
//

import Foundation

// MARK: - 協定常數與 envelope

/// MCP 協定的單一來源：版本、`_meta` key、錯誤碼、快取提示、result envelope。
///
/// 為什麼整組是 `nonisolated static` 純函式：`MCPHandler` / `DebugServer` 是 MainActor
/// class，NakiTests（沒開 `SWIFT_DEFAULT_ACTOR_ISOLATION`）裡建實例會 SIGABRT 把 test host
/// 打掉（見 CLAUDE.md）。協定長什麼樣必須能在**不起 server** 的情況下被測到，
/// 否則「升級到 2026-07-28」就只剩人工 curl 一次的印象。
///
/// 雙版本並存的理由：Naki 的消費者（Claude Code 的 MCP client、skill 腳本、curl）
/// 不會同時升級。規格明文允許 dual-era server，選擇條件也由規格定義：
/// **請求帶 modern `_meta` → stateless 語意；請求是 `initialize` → legacy 語意**。
enum NakiMCPProtocol {

    // MARK: - 版本

    /// 現行版：stateless、無 handshake、result 帶 `resultType`
    nonisolated static let current = "2026-07-28"

    /// 支援的協定版本（新 → 舊）。
    ///
    /// `server/discover` 的 `supportedVersions` 與 `-32022` 的 `data.supported`
    /// 都讀這一份，不存在第二張會漂移的表。
    nonisolated static let supportedVersions = [
        "2026-07-28",
        "2025-11-25",
        "2025-06-18",
        "2025-03-26"
    ]

    /// 走 `initialize` handshake 的舊版（`initialize` 在 2026-07-28 被移除）
    nonisolated static var legacyVersions: [String] {
        supportedVersions.filter { $0 != current }
    }

    /// handshake 沒帶（或帶了不認識的）版本時回報的版本。
    ///
    /// 客戶端有帶且我們支援時一律**原樣回報**——回一個對方沒要求的版本
    /// 等於要對方猜語意。
    nonisolated static let preferredLegacy = "2025-11-25"

    // MARK: - `_meta` key（規格保留字，不可自己改寫）

    nonisolated static let metaProtocolVersion = "io.modelcontextprotocol/protocolVersion"
    nonisolated static let metaServerInfo = "io.modelcontextprotocol/serverInfo"

    // MARK: - HTTP header（Streamable HTTP；比對一律小寫）

    nonisolated static let protocolVersionHeader = "mcp-protocol-version"
    nonisolated static let methodHeader = "mcp-method"
    nonisolated static let nameHeader = "mcp-name"

    // MARK: - 錯誤碼

    /// `-32020`：header 與 body 不一致
    nonisolated static let headerMismatchCode = -32020
    /// `-32022`：不支援請求的協定版本
    nonisolated static let unsupportedProtocolVersionCode = -32022

    /// `-32020…-32099` 是規格保留區。
    ///
    /// 用途不是「我們要用它」，而是**證明我們沒有把自訂碼放進去**——
    /// 規格明文禁止在此區發出未定義的碼，單測會對這條做回歸。
    nonisolated static let specReservedErrorCodes = (-32099)...(-32020)

    // MARK: - 快取提示（CacheableResult）

    /// `tools/list` 的 TTL。registry 在啟動時註冊一次就不再變動，
    /// 但仍給一個有限值——升版換 binary 後客戶端不該還吃舊清單。
    nonisolated static let toolsListTTLMs = 300_000
    /// `server/discover` 的 TTL
    nonisolated static let discoverTTLMs = 3_600_000
    /// 工具清單不含使用者資料（帳號資訊只出現在工具**結果**裡）
    nonisolated static let cacheScope = "public"

    // MARK: - 身分與能力

    /// `_meta['io.modelcontextprotocol/serverInfo']` 與 legacy `serverInfo` 共用這一份。
    /// 版本讀 App bundle（`NakiAppVersion`），不寫死。
    nonisolated static var serverInfo: [String: Any] {
        [
            "name": "naki",
            "title": "Naki 麻將 AI 助手",
            "version": NakiAppVersion.short
        ]
    }

    /// Naki 只有 tools：沒有 resources / prompts / logging / sampling / roots。
    /// `listChanged: false` 是事實——registry 在 `MCPHandler.init` 註冊一次後不再變動，
    /// 也沒有推播通道（無 `subscriptions/listen`）。
    nonisolated static var capabilities: [String: Any] {
        ["tools": ["listChanged": false]]
    }

    nonisolated static let instructions = """
        Naki 是本機 loopback 的雀魂 AI 助手。狀態類工具讀 Swift 協定層快照（不是向伺服器查詢），\
        動作類工具會真的送出 Liqi request 並影響帳號與對局，只在測試帳號使用。\
        每次都先 tools/list 取得現行工具與 schema，不要依舊 catalog 猜名稱。
        """

    // MARK: - Era

    /// 這次請求要用哪一版語意
    enum Era {
        /// 2026-07-28：`_meta` 帶版本、result 帶 `resultType` 與 serverInfo
        case modern
        /// 2025-03-26 ～ 2025-11-25：`initialize` handshake
        case legacy
    }

    /// 依規格的 dual-era 規則判斷 era。
    ///
    /// era 由**宣告的版本值**決定，不是「有沒有宣告」——因為 2025-06-18 起
    /// 的 legacy client 也會帶 `MCP-Protocol-Version` header，而 2026-07-28 的
    /// modern client 可以只把版本放在 header（官方 Streamable HTTP 範例即如此）。
    /// 只看「有無宣告」會把合法的 header-only modern 請求誤判成 legacy，
    /// 也會把帶舊版值的 `_meta` 誤判成 modern。
    ///
    /// - 宣告版本（body `_meta` 優先，其次 header）== `current` → modern
    /// - `server/discover` → modern（它本來就是 modern-only 的方法，
    ///   而且客戶端正是用它來問「你是哪個世代」，要求它先自報版本沒有意義）
    /// - 其餘（含 `initialize` 與所有 legacy 版本值） → legacy
    nonisolated static func era(method: String,
                                params: [String: Any],
                                headerVersion: String? = nil) -> Era {
        if let declared = requestedVersion(params: params) ?? headerVersion,
           declared == current {
            return .modern
        }
        if method == Method.discover { return .modern }
        return .legacy
    }

    /// 取出請求 `_meta` 裡的協定版本
    nonisolated static func requestedVersion(params: [String: Any]) -> String? {
        guard let meta = params["_meta"] as? [String: Any] else { return nil }
        return meta[metaProtocolVersion] as? String
    }

    nonisolated static func isSupported(version: String) -> Bool {
        supportedVersions.contains(version)
    }

    // MARK: - 方法名稱

    enum Method {
        nonisolated static let discover = "server/discover"
        nonisolated static let initialize = "initialize"
        nonisolated static let initialized = "initialized"
        nonisolated static let notificationsInitialized = "notifications/initialized"
        nonisolated static let ping = "ping"
        nonisolated static let toolsList = "tools/list"
        nonisolated static let toolsCall = "tools/call"
    }

    // MARK: - Result envelope

    /// 補上 2026-07-28 要求的 envelope 欄位（`resultType` ＋ `_meta.serverInfo`）。
    ///
    /// legacy era 原樣返回：舊版沒有 `resultType`，而規格要求舊 client 把缺席
    /// 視為 `"complete"`——多塞欄位對它們沒有好處，只會多一份要解釋的差異。
    nonisolated static func decorate(_ result: [String: Any], era: Era) -> [String: Any] {
        guard era == .modern else { return result }
        var decorated = result
        decorated["resultType"] = "complete"
        var meta = decorated["_meta"] as? [String: Any] ?? [:]
        meta[metaServerInfo] = serverInfo
        decorated["_meta"] = meta
        return decorated
    }

    /// `server/discover` 的結果（規格列為 MUST 實作）
    nonisolated static func discoverResult() -> [String: Any] {
        decorate([
            "supportedVersions": supportedVersions,
            "capabilities": capabilities,
            "instructions": instructions,
            "ttlMs": discoverTTLMs,
            "cacheScope": cacheScope
        ], era: .modern)
    }

    /// legacy `initialize` 的結果。
    ///
    /// - Parameter requestedVersion: client 在 params 裡宣告的版本；支援就原樣回報。
    nonisolated static func initializeResult(requestedVersion: String? = nil) -> [String: Any] {
        let negotiated: String
        if let requestedVersion, legacyVersions.contains(requestedVersion) {
            negotiated = requestedVersion
        } else {
            negotiated = preferredLegacy
        }
        return [
            "protocolVersion": negotiated,
            "serverInfo": serverInfo,
            "capabilities": capabilities
        ]
    }

    /// `tools/list` 的結果。modern era 另外帶 CacheableResult 的兩個欄位。
    ///
    /// 順序由 `MCPToolRegistry.toolOrder` 決定（註冊順序），符合規格的
    /// deterministic ordering 要求。
    nonisolated static func toolsListResult(tools: [[String: Any]], era: Era) -> [String: Any] {
        var result: [String: Any] = ["tools": tools]
        if era == .modern {
            result["ttlMs"] = toolsListTTLMs
            result["cacheScope"] = cacheScope
        }
        return decorate(result, era: era)
    }

    /// 工具成功結果。
    ///
    /// `structuredContent` 是機械消費面：腳本與 client 直接讀真的 JSON 物件，
    /// 不必再解一層跳脫字串（CLAUDE.md 記載的 `tr -d '\\'` 痛點就是這麼來的）。
    /// `content[0].text` 保留同一份 JSON 的字串化——規格建議這麼做以相容舊 client，
    /// 而且既有腳本不會因為升級而一次全斷。
    nonisolated static func toolSuccessPayload(content: Any, era: Era) -> [String: Any] {
        let structured = structuredContent(from: content)
        return decorate([
            "content": [["type": "text", "text": jsonText(structured)]],
            "structuredContent": structured,
            "isError": false
        ], era: era)
    }

    /// 工具執行錯誤（Tool Execution Error）。
    ///
    /// 參數驗證失敗走這條而不是 JSON-RPC protocol error：規格 2025-11-25 起
    /// 要求可自我修正的錯誤回 `isError`，模型才有機會自己改參數重試。
    nonisolated static func toolErrorPayload(message: String, era: Era) -> [String: Any] {
        decorate([
            "content": [["type": "text", "text": message]],
            "structuredContent": ["success": false, "error": message],
            "isError": true
        ], era: era)
    }

    /// 工具回傳值 → `structuredContent`。
    ///
    /// 工具目前一律回 dictionary；非 dictionary 包一層 `result`，
    /// 這樣 `outputSchema` 宣告的 `type: object` 永遠成立
    /// （規格：宣告了 outputSchema 就 MUST 提供符合它的結構化結果）。
    nonisolated static func structuredContent(from content: Any) -> [String: Any] {
        if let dict = content as? [String: Any] {
            return JSONSanitizer.sanitize(dict)
        }
        return ["result": JSONSanitizer.sanitize(content)]
    }

    /// 把 structuredContent 字串化成人類可讀的 fallback text
    nonisolated static func jsonText(_ value: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    // MARK: - 錯誤

    /// 版本不合：規格要求回 -32022，並列出我們支援哪些版本，
    /// 讓 client 自己挑一個重送（沒有 handshake 可以協商了）。
    nonisolated static func unsupportedVersionFailure(requested: String) -> NakiMCPFailure {
        NakiMCPFailure(
            code: unsupportedProtocolVersionCode,
            message: "Unsupported protocol version: \(requested)",
            data: ["supported": supportedVersions, "requested": requested],
            httpStatus: 400
        )
    }

    /// header 與 body 不一致：中介層依 header 路由、server 依 body 執行，
    /// 兩者不同就是安全問題，不是可以「以 body 為準」帶過的小事。
    nonisolated static func headerMismatchFailure(header: String,
                                                  headerValue: String,
                                                  bodyValue: String) -> NakiMCPFailure {
        NakiMCPFailure(
            code: headerMismatchCode,
            message: "Header mismatch: \(header) header value '\(headerValue)' "
                + "does not match body value '\(bodyValue)'",
            data: nil,
            httpStatus: 400
        )
    }
}

// MARK: - Failure

/// 一次請求要回的 JSON-RPC 錯誤（含 HTTP status）
struct NakiMCPFailure {
    let code: Int
    let message: String
    let data: [String: Any]?
    /// modern era 的 status 由規格指定（400 / 403 / 404）；legacy era 一律 200 + JSON-RPC error
    let httpStatus: Int

    init(code: Int, message: String, data: [String: Any]? = nil, httpStatus: Int = 200) {
        self.code = code
        self.message = message
        self.data = data
        self.httpStatus = httpStatus
    }

    /// JSON-RPC error 物件（不含 id）
    var errorObject: [String: Any] {
        var error: [String: Any] = ["code": code, "message": message]
        if let data { error["data"] = data }
        return error
    }
}

// MARK: - Origin 驗證

/// Streamable HTTP 的 Origin 檢查（DNS rebinding 防護）。
///
/// 為什麼 loopback server 也要擋：`127.0.0.1:8765` 對任何**瀏覽器分頁**都是可達的位址，
/// 惡意頁面可以直接 `fetch()` 這個能執行 JS、送出遊戲動作的 server。
/// 規格對非法 Origin 的要求是 403，不是忽略。
///
/// 沒有 Origin header 的請求放行：curl、Claude Code 的 MCP client 與 skill 腳本
/// 都不送 Origin，擋掉它們等於把整條驗證面關掉。
enum NakiMCPOriginPolicy {

    /// 允許的 host（瀏覽器只會把 loopback 頁面標成這幾種）
    nonisolated static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "::1", "[::1]"]

    nonisolated static func isAllowed(_ origin: String?) -> Bool {
        guard let raw = origin?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            // 非瀏覽器 client（curl / MCP client）不送 Origin
            return true
        }
        // `null` 是 sandboxed iframe / file:// 的 opaque origin，不可信
        guard raw.lowercased() != "null" else { return false }
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host?.lowercased() else {
            return false
        }
        return loopbackHosts.contains(host)
    }

    /// 被擋下時的回應 body（規格允許放一個沒有 id 的 JSON-RPC error）
    nonisolated static func forbiddenBody(origin: String?) -> String {
        let failure = NakiMCPFailure(
            code: -32600,
            message: "Forbidden origin: \(origin ?? "unknown")",
            data: nil,
            httpStatus: 403
        )
        let payload: [String: Any] = ["jsonrpc": "2.0", "error": failure.errorObject]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let text = String(data: data, encoding: .utf8) else {
            return "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32600,\"message\":\"Forbidden origin\"}}"
        }
        return text
    }
}

// MARK: - HTTP header

/// 從原始 request 行裡取 header（名稱大小寫不敏感，規格要求）
///
/// 傳進來的 `lines` 是整條 request（header ＋ body），所以**掃到第一個空行就停**：
/// body 是呼叫端可以控制的內容，讓它有機會被讀成 header 是不必要的風險。
enum NakiHTTPHeaderReader {
    nonisolated static func value(_ name: String, in lines: [String]) -> String? {
        let target = name.lowercased()
        for line in lines {
            if line.isEmpty { return nil }  // header 區塊結束
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard key == target else { continue }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        return nil
    }
}

// MARK: - Router

/// 純函式路由：把「一段 HTTP body ＋ header」變成「要回什麼」。
///
/// 不碰連線、不執行工具，所以整條協定決策（era、版本檢查、方法路由、錯誤碼與
/// HTTP status）都能在單測裡對拍。`MCPHandler` 只負責執行這份決策。
enum NakiMCPRouter {

    /// 這次請求要做的事
    enum Outcome {
        /// 已經可以回覆的 result（已 decorate 過）
        case result([String: Any])
        /// 要執行工具（結果由呼叫端 decorate）
        case toolCall(name: String, arguments: [String: Any])
        /// 通知（無 id）：HTTP 202、無 body
        case accepted
        /// 錯誤
        case failure(NakiMCPFailure)
    }

    struct Plan {
        let id: Any?
        let era: NakiMCPProtocol.Era
        let outcome: Outcome
    }

    /// 解析請求並決定回應
    nonisolated static func plan(body: String,
                                 headers: [String],
                                 toolDefinitions: @autoclosure () -> [[String: Any]]) -> Plan {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else {
            return Plan(id: nil, era: .legacy, outcome: .failure(
                NakiMCPFailure(code: -32700, message: "Parse error", httpStatus: 400)))
        }

        // JSON-RPC batching 在 2025-06-18 被移除：明確拒絕，不要默默只處理第一筆
        if json is [Any] {
            return Plan(id: nil, era: .legacy, outcome: .failure(
                NakiMCPFailure(code: -32600,
                               message: "JSON-RPC batching was removed in MCP 2025-06-18; send one request per POST",
                               httpStatus: 400)))
        }

        guard let object = json as? [String: Any],
              let method = object["method"] as? String else {
            return Plan(id: nil, era: .legacy, outcome: .failure(
                NakiMCPFailure(code: -32600, message: "Invalid Request: missing method", httpStatus: 400)))
        }

        let id = object["id"]
        let params = object["params"] as? [String: Any] ?? [:]
        let headerVersion = NakiHTTPHeaderReader.value(NakiMCPProtocol.protocolVersionHeader, in: headers)
        let bodyVersion = NakiMCPProtocol.requestedVersion(params: params)
        // era 要看 header 宣告的版本，否則 header-only 的 modern 請求會被誤判成 legacy
        let era = NakiMCPProtocol.era(method: method, params: params, headerVersion: headerVersion)

        // header 與 body 都宣告版本時必須一致
        if let bodyVersion, let headerVersion, bodyVersion != headerVersion {
            return Plan(id: id, era: era, outcome: .failure(
                NakiMCPProtocol.headerMismatchFailure(header: "MCP-Protocol-Version",
                                                      headerValue: headerVersion,
                                                      bodyValue: bodyVersion)))
        }

        // 版本檢查：任一來源宣告了我們不支援的版本就 -32022
        if let declared = bodyVersion ?? headerVersion, !NakiMCPProtocol.isSupported(version: declared) {
            return Plan(id: id, era: era, outcome: .failure(
                NakiMCPProtocol.unsupportedVersionFailure(requested: declared)))
        }

        // Streamable HTTP 把 JSON-RPC method 鏡射到 Mcp-Method header 供中介層路由；
        // 帶了但與 body 的 method 不一致代表請求在傳輸途中被改寫，拒絕（與 Mcp-Name 同語意）
        if let headerMethod = NakiHTTPHeaderReader.value(NakiMCPProtocol.methodHeader, in: headers),
           headerMethod != method {
            return Plan(id: id, era: era, outcome: .failure(
                NakiMCPProtocol.headerMismatchFailure(header: "Mcp-Method",
                                                      headerValue: headerMethod,
                                                      bodyValue: method)))
        }

        switch method {
        case NakiMCPProtocol.Method.discover:
            return Plan(id: id, era: .modern, outcome: .result(NakiMCPProtocol.discoverResult()))

        case NakiMCPProtocol.Method.initialize:
            // handshake 在 2026-07-28 被移除；modern client 不該送它
            guard era == .legacy else {
                return Plan(id: id, era: era, outcome: .failure(methodNotFound(method, era: era)))
            }
            let requested = params["protocolVersion"] as? String
            return Plan(id: id, era: era, outcome: .result(
                NakiMCPProtocol.initializeResult(requestedVersion: requested)))

        case NakiMCPProtocol.Method.initialized, NakiMCPProtocol.Method.notificationsInitialized:
            // 真的是通知（沒有 id）就回 202 無 body；有 id 的 client 仍給一個空 result
            guard id != nil else { return Plan(id: nil, era: era, outcome: .accepted) }
            return Plan(id: id, era: era, outcome: .result(NakiMCPProtocol.decorate([:], era: era)))

        case NakiMCPProtocol.Method.ping:
            // `ping` 在 2026-07-28 移除；legacy client 仍可用
            guard era == .legacy else {
                return Plan(id: id, era: era, outcome: .failure(methodNotFound(method, era: era)))
            }
            return Plan(id: id, era: era, outcome: .result([:]))

        case NakiMCPProtocol.Method.toolsList:
            return Plan(id: id, era: era, outcome: .result(
                NakiMCPProtocol.toolsListResult(tools: toolDefinitions(), era: era)))

        case NakiMCPProtocol.Method.toolsCall:
            guard let name = params["name"] as? String, !name.isEmpty else {
                // 缺 name 是 malformed request，不是模型可以改參數修好的錯 → protocol error
                return Plan(id: id, era: era, outcome: .failure(
                    NakiMCPFailure(code: -32602,
                                   message: "Invalid params: missing tool name",
                                   httpStatus: era == .modern ? 400 : 200)))
            }
            // Streamable HTTP 把 params.name 鏡射到 Mcp-Name；不一致代表中介層與
            // server 對「呼叫的是哪個工具」看法不同，必須擋下
            if let headerName = NakiHTTPHeaderReader.value(NakiMCPProtocol.nameHeader, in: headers),
               headerName != name {
                return Plan(id: id, era: era, outcome: .failure(
                    NakiMCPProtocol.headerMismatchFailure(header: "Mcp-Name",
                                                          headerValue: headerName,
                                                          bodyValue: name)))
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            return Plan(id: id, era: era, outcome: .toolCall(name: name, arguments: arguments))

        default:
            // 其餘 notifications 一律接受但不處理（沒有 id 就沒有可回的 response）
            if method.hasPrefix("notifications/"), id == nil {
                return Plan(id: nil, era: era, outcome: .accepted)
            }
            return Plan(id: id, era: era, outcome: .failure(methodNotFound(method, era: era)))
        }
    }

    /// 未知方法。modern era 的 HTTP status 由規格指定為 404
    /// （body 仍是 JSON-RPC `-32601`，用來與「沒有這個 endpoint」的 404 區分）。
    nonisolated static func methodNotFound(_ method: String, era: NakiMCPProtocol.Era) -> NakiMCPFailure {
        NakiMCPFailure(code: -32601,
                       message: "Method not found: \(method)",
                       data: nil,
                       httpStatus: era == .modern ? 404 : 200)
    }
}
