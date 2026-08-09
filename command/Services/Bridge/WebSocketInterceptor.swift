//
//  WebSocketInterceptor.swift
//  Naki
//
//  Created by Suoie on 2025/11/30.
//  WebSocket 攔截器 - 透過 JavaScript 注入監聽雀魂的 WebSocket 通訊
//  Updated: 2025/12/01 - 新增自動打牌支援
//  Updated: 2025/12/03 - 重構為從外部 JS 檔案載入
//  Updated: 2025/12/04 - 支援 WebPage API (macOS 26.0+)
//  Updated: 2026/08/02 - 刪除 fallback inlineScript，載入失敗改為 fail loud
//  Updated: 2026/08/02 - JS↔Swift 訊息契約收斂成 BridgeMessageType，未知 type 改為 warning
//

import Foundation
import Observation
import WebKit
import os.log

// 使用 LogManager 的 wsLog 函式

// MARK: - JS 模組載入失敗模型

/// 單一 JS 模組載不進來的原因。
///
/// 分三種而不是一個 bool，因為處置完全不同：
/// - `notFound`：幾乎都是打包漏檔（`Naki.xcodeproj` 的 `membershipExceptions`
///   是**包含清單**，新增的 resource 沒加就不會進 bundle）。
/// - `unreadable`：檔在但讀不出來（權限／編碼／IO）。
/// - `empty`：讀得到但內容是空的。這種最陰險——注入「成功」，頁面上卻什麼都沒有。
nonisolated enum JSModuleFailureReason: String, Sendable {
    case notFound = "not_found"
    case unreadable = "unreadable"
    case empty = "empty"

    /// 給人看的說明
    var text: String {
        switch self {
        case .notFound: return "Bundle 內找不到檔案"
        case .unreadable: return "檔案存在但讀取失敗"
        case .empty: return "檔案內容為空"
        }
    }
}

/// 一個模組的載入失敗紀錄
nonisolated struct JSModuleFailure: Error, Sendable, Equatable {
    /// 模組名（不含 `.js`）
    let module: String
    let reason: JSModuleFailureReason
    /// 底層錯誤描述；只有 `unreadable` 會有
    let detail: String?

    init(module: String, reason: JSModuleFailureReason, detail: String? = nil) {
        self.module = module
        self.reason = reason
        self.detail = detail
    }

    /// 單行人類可讀說明
    var text: String {
        if let detail, !detail.isEmpty {
            return "\(module).js：\(reason.text)（\(detail)）"
        }
        return "\(module).js：\(reason.text)"
    }

    /// `/status` 用的機械可判讀欄位
    var payload: [String: String] {
        var dict = ["module": "\(module).js", "reason": reason.rawValue]
        if let detail, !detail.isEmpty { dict["detail"] = detail }
        return dict
    }
}

/// 組注入腳本的結果。
///
/// 沒有「部分成功」這個選項：只要有一個模組缺，就整批不注入。
/// 舊版是「載到幾個算幾個，全掛才退回內嵌腳本」，於是
/// `naki-core` 有、`naki-websocket` 沒有的情況會得到一個
/// 「會高亮但送不出任何動作」的半套 App，而 UI 完全看不出來。
nonisolated enum JSInjectionOutcome: Sendable {
    case ready(source: String, modules: [String])
    case failed(loaded: [String], failures: [JSModuleFailure])
}

/// 注入狀態快照（可安全跨 isolation 傳遞）
nonisolated struct JSInjectionReport: Sendable {
    /// 是否已經嘗試過建立注入腳本（false = WebView 還沒建起來）
    let attempted: Bool
    /// 成功載入的模組
    let loadedModules: [String]
    /// 失敗的模組
    let failures: [JSModuleFailure]

    static let notAttempted = JSInjectionReport(attempted: false, loadedModules: [], failures: [])

    /// 注入是否失敗（沒嘗試過不算失敗）
    var isFailed: Bool { attempted && !failures.isEmpty }

    /// 給 UI 的單行摘要；沒失敗回 nil
    var failureSummary: String? {
        guard isFailed else { return nil }
        return failures.map(\.text).joined(separator: "；")
    }

    /// `get_status` / `GET /status` 用的欄位
    var statusPayload: [String: Any] {
        var payload: [String: Any] = [
            "jsInjectionFailed": isFailed,
            "jsInjectionAttempted": attempted,
            "jsModulesLoaded": loadedModules
        ]
        if isFailed {
            payload["jsInjectionFailures"] = failures.map(\.payload)
            payload["jsInjectionNote"] =
                "JavaScript 注入腳本沒有建立成功，且沒有 fallback。"
                + "Naki 不會收到任何 WebSocket 封包，也送不出任何 Liqi 動作；"
                + "此時所有 game_* / bot_* / room_* / lobby_* 工具的結果都不可信。"
        }
        return payload
    }
}

/// 注入狀態的唯一真相來源。
///
/// `@Observable`：UI 要能在載入失敗時立刻掛出紅色橫幅，而不是等下一次狀態更新。
@Observable
final class JSInjectionState {

    static let shared = JSInjectionState()

    /// MainActor class 在 NakiTests host 釋放會 SIGABRT（見 CLAUDE.md「專案結構的坑」）
    nonisolated deinit { }

    private(set) var report: JSInjectionReport = .notAttempted

    /// 記錄一次注入嘗試的結果
    func record(_ outcome: JSInjectionOutcome) {
        switch outcome {
        case .ready(_, let modules):
            report = JSInjectionReport(attempted: true, loadedModules: modules, failures: [])
        case .failed(let loaded, let failures):
            report = JSInjectionReport(attempted: true, loadedModules: loaded, failures: failures)
        }
    }

    /// 回到「還沒嘗試過」（測試用）
    func reset() {
        report = .notAttempted
    }
}

// MARK: - WebSocket Interceptor

/// WebSocket 攔截器，用於監聽 WebPage 中的 WebSocket 通訊
/// 透過 WKUserScript 注入 JavaScript 程式碼
class WebSocketInterceptor {

    /// JavaScript 模組文件名稱（按載入順序）
    ///
    /// 只剩兩個模組。`naki-autoplay` / `naki-game-api` / `naki-coordinator` 已整檔刪除：
    /// 它們的每一條路徑都走 `Laya` / `GameMgr` / `app.NetAgent` / `view.DesktopMgr`，
    /// 而 Unity WebGL 客戶端沒有這些物件，所以那 2,900 行在 runtime 只會靜默失敗。
    /// 注入腳本是 `forMainFrameOnly: false`，每個 iframe 都要 parse 一次，留著只有成本。
    ///
    /// 順序仍然重要：`naki-websocket` 會取 `naki-core` 的 base64／sendToSwift；
    /// `naki-plugins` 提供 `window.__nakiPlugins`，`naki-websocket` 的 handleMessage
    /// 在中段呼叫它的 `dispatch`——runtime 查找，所以載入順序排在最後也安全。
    ///
    /// 這三個是 **bundled**（全有或全無，見 `buildInjection`）。第三方插件的原始碼
    /// 不在這裡——它們走「第二個 WKUserScript」，任一插件壞掉只停用該插件，不影響本體。
    static let jsModules = [
        "naki-core",
        "naki-websocket",
        "naki-plugins"
    ]

    /// 從 Bundle 載入單一 JavaScript 模組。
    ///
    /// 舊版是 `try?` + 回 `nil`，於是「檔不存在」與「檔在但讀不出來」長得一模一樣，
    /// 而後者代表打包是對的、環境壞了——兩者要查的地方完全不同。
    ///
    /// - Throws: `JSModuleFailure`
    static func loadJavaScript(named filename: String, in bundle: Bundle = .main) throws -> String {
        // 先找 Resources/JavaScript 子目錄，再退回 bundle 根目錄
        let url = bundle.url(forResource: filename, withExtension: "js", subdirectory: "Resources/JavaScript")
            ?? bundle.url(forResource: filename, withExtension: "js")

        guard let url else {
            throw JSModuleFailure(module: filename, reason: .notFound)
        }

        let source: String
        do {
            source = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw JSModuleFailure(
                module: filename,
                reason: .unreadable,
                detail: "\(url.lastPathComponent): \(error.localizedDescription)")
        }

        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw JSModuleFailure(module: filename, reason: .empty)
        }
        return source
    }

    /// 組出要注入的腳本。全有或全無——任何一個模組失敗就不注入。
    static func buildInjection(modules: [String] = jsModules, in bundle: Bundle = .main) -> JSInjectionOutcome {
        guard !modules.isEmpty else {
            // 不可能在正常組態下發生；真的發生就是有人把 jsModules 清空了，
            // 這同樣是「什麼都沒注入」，必須走失敗路徑而不是回一個空腳本。
            return .failed(
                loaded: [],
                failures: [JSModuleFailure(module: "(none)", reason: .notFound,
                                           detail: "沒有列出任何 JS 模組")])
        }

        var sources: [String] = []
        var loaded: [String] = []
        var failures: [JSModuleFailure] = []

        for module in modules {
            do {
                let source = try loadJavaScript(named: module, in: bundle)
                sources.append("// === \(module).js ===")
                sources.append(source)
                loaded.append(module)
            } catch let failure as JSModuleFailure {
                failures.append(failure)
            } catch {
                failures.append(
                    JSModuleFailure(module: module, reason: .unreadable, detail: "\(error)"))
            }
        }

        guard failures.isEmpty, !loaded.isEmpty else {
            return .failed(loaded: loaded, failures: failures)
        }
        return .ready(source: sources.joined(separator: "\n\n"), modules: loaded)
    }

    /// 創建用於注入的 `WKUserScript`。
    ///
    /// **回傳 nil 代表注入失敗，而且沒有 fallback。**
    /// 舊版在這裡會退回一份內嵌的簡化攔截器：它有自己的 majsoul URL 判定、
    /// socketId 從 0 起算（模組版從 1），而且**沒有 `sendRaw`**。
    /// 一旦踩到，App 表象只是「不會自動打牌」——沒有任何錯誤、沒有 UI 提示，
    /// 而所有 Liqi 動作（打牌、副露、和牌、開房、匹配）全部靜默失效。
    /// 半套的 fallback 比沒有 fallback 危險，所以整段刪掉，改成大聲失敗。
    ///
    /// 呼叫端必須處理 nil：不要注入、並讓失敗在 UI 上看得見
    /// （`JSInjectionState.shared.report` 已同步更新，`/status` 會帶 `jsInjectionFailed`）。
    static func createUserScript() -> WKUserScript? {
        let outcome = buildInjection()
        JSInjectionState.shared.record(outcome)

        switch outcome {
        case .ready(let source, let modules):
            wsLog("[JS] 注入 \(modules.count) 個模組：\(modules.map { "\($0).js" }.joined(separator: ", "))")
            return WKUserScript(
                source: source,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )

        case .failed(let loaded, let failures):
            let detail = failures.map(\.text).joined(separator: "；")
            wsLog("[JS] ❌ JavaScript 注入中止：\(detail)", level: .event)
            wsLog("[JS] ❌ 沒有 fallback：Naki 不會收到任何 WebSocket 封包，也送不出任何 Liqi 動作。",
                  level: .event)
            if !loaded.isEmpty {
                wsLog("[JS] 已載入但一併放棄的模組：\(loaded.joined(separator: ", "))"
                    + "（部分注入會產生「能高亮但送不出動作」的半套狀態，故整批不注入）",
                      level: .event)
            }
            systemLog("[JS] ❌ JavaScript 注入失敗：\(detail)。請檢查 App bundle 是否含 "
                + "Resources/JavaScript/*.js（Xcode membershipExceptions 是包含清單）。")
            return nil
        }
    }
}

// MARK: - JS ↔ Swift 訊息契約

/// `websocketBridge` 這個 message handler 收得懂的全部 type。
///
/// **這個 enum 是契約的唯一真相來源。**
///
/// 訊息 envelope 固定是 `naki-core.js` 的 `sendToSwift(type, data)` 產生的
/// `{ type: String, data: Object, timestamp: Number }`；下表的 schema 指的是
/// `data` 內的欄位（Swift 端一律從 `body["data"]` 取，缺欄位就整筆略過）。
///
/// | type | data schema | Swift 行為 |
/// |------|-------------|-----------|
/// | `websocket_connect` | `socketId: Int`, `url: String`, `isMajsoul: Bool` | log 連線建立（`new WebSocket()` 當下，還沒 open） |
/// | `websocket_connected` | `socketId: Int`, `url: String`, `isMajsoul: Bool` | 雀魂線才記入 `connectedSockets`；**由空轉非空**才轉 connected |
/// | `websocket_message` | `socketId: Int`, `direction: "send"｜"receive"`, `data: String`（binary 為 base64）, `type: "binary"｜"blob"｜"text"`, `size: Int` | 解 base64 → `MajsoulBridge` → MJAI 事件 |
/// | `websocket_close` | `socketId: Int`, `code: Int`, `reason: String`, `isMajsoul: Bool` | 雀魂線才從 `connectedSockets` 移除；全空則轉 disconnected |
/// | `websocket_error` | `socketId: Int`, `error: String` | log |
/// | `force_reconnect` | `closedCount: Int` | log：接下來那幾筆 `websocket_close` 是 Naki 自己關的 |
/// | `plugin_event` | `id: String`, `kind: String`, `msg: String` | 插件經 `ctx.log()` 送出的事件（唯一的插件→Swift 通道，見 `naki-plugins.js`） |
///
/// 兩個機械保證，缺一契約就會再漂：
/// 1. `WebSocketMessageHandler` 的 switch **不寫 `default`**——新增 case 沒處理就編不過。
/// 2. `BridgeMessageContractTests` 從 bundle 內的 JS 原始碼抓出所有
///    `sendToSwift('…')` 的 type，與 `allCases` 做雙向比對：
///    JS 送了但這裡沒有 → 訊息被丟掉；這裡有但 JS 不送 → 死 case。
///
/// 已刪除的舊 type（別再加回來，除非同時補上活的送出端）：
/// `websocket_open`（與 `websocket_connected` 同一個 open 事件送兩份）、
/// `websocket_closed`（`websocket_close` 的別名，零送出端）、
/// `websocket_debug`／`interceptor_ready`（零送出端）、
/// `console_log`（JS 送 `{level,args}`、Swift 讀 `data["message"]`，欄位從來沒對上）、
/// `addHandPai` 與 `autoplay_*`（送出端在 `naki-autoplay.js`，該檔已整檔刪除）。
nonisolated enum BridgeMessageType: String, CaseIterable, Sendable {
    case websocketConnect = "websocket_connect"
    case websocketConnected = "websocket_connected"
    case websocketMessage = "websocket_message"
    case websocketClose = "websocket_close"
    case websocketError = "websocket_error"
    case forceReconnect = "force_reconnect"
    case pluginEvent = "plugin_event"
}

/// 未知／畸形訊息的 warning 去重器。
///
/// 契約漂掉的症狀是「JS 一直送、Swift 一直丟」，一秒可以發生幾十次；
/// 每次都寫 log 會把對局時間軸淹掉，所以同一個 type 只吐一次。
///
/// 但也不能無上限記住：頁面上任何腳本都能對 `websocketBridge` postMessage，
/// 亂送 type 就會讓這個 Set 無限長大。撞到上限後整個閉嘴（`isSaturated`），
/// 由呼叫端補一行「後續不再報」的說明。
nonisolated struct UnknownBridgeTypeReporter {

    /// 最多記住幾種不同的未知 type
    let limit: Int

    private var seen: Set<String> = []

    init(limit: Int = 32) {
        self.limit = limit
    }

    /// 這個 type 是不是第一次看到（第一次才值得寫 log）
    mutating func shouldWarn(_ type: String) -> Bool {
        guard seen.count < limit else { return false }
        return seen.insert(type).inserted
    }

    /// 已經記滿，之後一律不再報
    var isSaturated: Bool { seen.count >= limit }

    /// 目前記住的種類數
    var count: Int { seen.count }
}

// MARK: - WebSocket Message Handler

/// 處理從 JavaScript 傳來的 WebSocket 消息
///
/// 契約表在 `BridgeMessageType`。
class WebSocketMessageHandler: NSObject, WKScriptMessageHandler {

    /// `@MainActor` 隔離的 class 在 NakiTests host 釋放會 SIGABRT（見 CLAUDE.md
    /// 「專案結構的坑」）。app target 開了 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
    /// 而測試 target 沒開，所以要單測這個型別就得補這一行。
    nonisolated deinit { }

    // MARK: - Properties

    /// 雀魂協議橋接器
    private let majsoulBridge = MajsoulBridge()

    /// 目前登入帳號的 account_id（由 MajsoulBridge 從登入／authGame 回應解析）。
    /// `ReqAccountInfo.account_id` 為必填，MCP 的帳號查詢工具需要它當預設值。
    ///
    /// 對外的讀取面是 `NakiAccountIdSource`（見檔案末尾的 conformance）：
    /// MCP 的快照 Action 只需要這一個數字，不該因此認得整個 message handler。
    var majsoulAccountId: Int { majsoulBridge.accountId }

    /// MJAI 事件回調
    var onMJAIEvent: (([String: Any]) -> Void)?

    /// WebSocket 狀態回調
    var onWebSocketStatusChanged: ((Bool) -> Void)?

    /// 連接的 WebSocket 數量
    private var connectedSockets: Set<Int> = []

    /// 未知 type 的 warning 去重
    private var unknownTypes = UnknownBridgeTypeReporter()

    // MARK: - WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController,
                              didReceive message: WKScriptMessage) {

        guard let body = message.body as? [String: Any] else {
            warnMalformed("body 不是 dictionary（實際型別 \(Swift.type(of: message.body))）")
            return
        }
        guard let type = body["type"] as? String else {
            warnMalformed("缺少 type 欄位（keys=\(body.keys.sorted().joined(separator: ","))）")
            return
        }

        dispatch(type: type, data: body["data"] as? [String: Any] ?? [:])
    }

    /// 已解出 `type` / `data` 之後的分派。
    ///
    /// 與 `userContentController` 分開的唯一理由是**可測**：`WKScriptMessage` 沒有
    /// 公開的 initializer，測試造不出來，於是連線狀態的轉換規則過去一條都驗不到
    /// （`onWebSocketStatusChanged` 在 NakiTests 曾經零命中）。
    func dispatch(type: String, data: [String: Any]) {
        // 認不得就出聲。舊版是 `default: break`——JS 改了 type、Swift 沒跟上時，
        // 訊息會安靜地掉進地上，表象只是「某個功能不動」，log 裡一個字都沒有。
        guard let messageType = BridgeMessageType(rawValue: type) else {
            warnUnknown(type)
            return
        }

        // 刻意不寫 `default`：這樣 `BridgeMessageType` 加了新 case 而沒人處理時，
        // 會在編譯期就爆，而不是等 live 對局才發現訊息被吃掉。
        switch messageType {
        case .websocketConnect:
            handleWebSocketConnect(data)

        case .websocketConnected:
            handleWebSocketConnected(data)

        case .websocketMessage:
            handleWebSocketMessage(data)

        case .websocketClose:
            handleWebSocketClose(data)

        case .websocketError:
            handleWebSocketError(data)

        case .forceReconnect:
            handleForceReconnect(data)

        case .pluginEvent:
            handlePluginEvent(data)
        }
    }

    // MARK: - 契約違規

    /// 收到不在契約裡的 type
    private func warnUnknown(_ type: String) {
        guard unknownTypes.shouldWarn(type) else { return }
        wsLog("[JS] ⚠️ 未知的 bridge 訊息 type：'\(type)'（已丟棄）。"
            + "JS 端送了 Swift 不認得的 type——契約表在 BridgeMessageType，兩端要一起改。",
              level: .event)
        if unknownTypes.isSaturated {
            wsLog("[JS] ⚠️ 未知 type 已達 \(unknownTypes.limit) 種上限，後續不再逐一回報。",
                  level: .event)
        }
    }

    /// 收到連 envelope 都不對的東西（同樣只報一次，避免洗版）
    private func warnMalformed(_ detail: String) {
        guard unknownTypes.shouldWarn("(malformed) \(detail)") else { return }
        wsLog("[JS] ⚠️ bridge 訊息格式錯誤，已丟棄：\(detail)", level: .event)
    }

    // MARK: - Message Handlers

    /// `new WebSocket()` 當下（還沒 open）。
    ///
    /// 留著它是為了看見「連了但從來沒 open」的連線——這種只會在 connect 出現、
    /// 不會有 connected，是握手失敗的唯一線索。
    private func handleWebSocketConnect(_ data: [String: Any]) {
        guard let socketId = data["socketId"] as? Int,
              let url = data["url"] as? String else { return }

        let isMajsoul = data["isMajsoul"] as? Bool ?? false
        wsLog("[WS] WebSocket connecting: \(socketId) - \(url)\(isMajsoul ? " (雀魂)" : "")")
    }

    /// 某條 WebSocket 完成 open。
    ///
    /// **只有由空轉非空才報 connected**——與 `handleWebSocketClose` 的「全空才報
    /// disconnected」對稱。這裡曾經無條件呼叫回調，而回調做的是
    /// `MajsoulBridge.reset()`（清掉 oplist、parser 的 msgId 對照表、doras、
    /// lastDiscard）加上重建 Bot。
    ///
    /// 雀魂一個分頁會反覆開關 route 探測與大廳連線，對局那條 `game-gateway` 從頭到尾
    /// 沒動；於是**對局進行中**每開一條就重置一次。2026-08-06 的 log 裡同一個 session
    /// 重置 9 次、其中 5 次在對局中，緊接著就是 `skip:noOplist`——自動打牌在那個窗口
    /// 沒有決策來源。
    private func handleWebSocketConnected(_ data: [String: Any]) {
        guard let socketId = data["socketId"] as? Int else { return }

        wsLog("[WS] WebSocket connected: \(socketId)")

        // 非雀魂的連線只記 log，不進集合：`connectedSockets` 的語意是「還連著幾條
        // 雀魂線」，混進第三方 socket 會讓「連上雀魂」這個狀態失去意義。
        guard data["isMajsoul"] as? Bool ?? false else { return }

        let wasEmpty = connectedSockets.isEmpty
        connectedSockets.insert(socketId)
        if wasEmpty {
            onWebSocketStatusChanged?(true)
        }
    }

    private func handleWebSocketMessage(_ data: [String: Any]) {
        guard let base64Data = data["data"] as? String,
              let direction = data["direction"] as? String else { return }

        // 解碼 Base64 數據
        guard let binaryData = Data(base64Encoded: base64Data) else {
            wsLog("[WS] Failed to decode base64 data")
            return
        }

        // 打印數據大小用於調試
        let dirSymbol = direction == "receive" ? "←" : "→"
        wsLog("[WS] \(dirSymbol) \(binaryData.count) bytes")

        // 處理發送的消息（用於跟蹤請求）
        if direction == "send" {
            // 發送的消息是請求，需要解析以跟蹤 msgId
            if let parsed = majsoulBridge.parseRaw(binaryData),
               let method = parsed["method"] as? String {
                wsLog("[WS] Sent request: \(method)")
            }
            return
        }

        // 處理接收的消息
        guard direction == "receive" else { return }

        // 使用 MajsoulBridge 解析消息
        if let mjaiEvents = majsoulBridge.parse(binaryData) {
            for event in mjaiEvents {
                if let eventType = event["type"] as? String {
                    wsLog("[MJAI] \(eventType): \(formatEvent(event))")
                }
                onMJAIEvent?(event)
            }
            return
        }

        // 轉不成 MJAI 事件（心跳、大廳 RPC、未知 notify…）：用**剛才那一次**解析的結果
        // 寫診斷 log。不要在這裡新建 `LiqiParser` 重解一次——新實例沒有 `pendingRequests`，
        // 所有 RESPONSE 必然回 nil，等於為了寫一行 log 而產生一份錯的解析結果。
        guard let parsed = majsoulBridge.lastParsed else {
            if let failure = majsoulBridge.lastEnvelopeFailure {
                wsLog("[Liqi] envelope 解不開：\(failure)")
            }
            return
        }
        guard let method = parsed["method"] as? String else { return }

        wsLog("[Liqi] \(method)")

        // 調試 ActionPrototype
        if method == ".lq.ActionPrototype",
           let data = parsed["data"] as? [String: Any] {
            if let actionName = data["name"] as? String {
                wsLog("[Action] \(actionName): \(data)")
            } else {
                wsLog("[Action] No name found in data: \(data)")
            }
        }
    }

    /// 格式化事件用於日誌
    private func formatEvent(_ event: [String: Any]) -> String {
        var parts: [String] = []

        if let actor = event["actor"] as? Int {
            parts.append("actor=\(actor)")
        }
        if let pai = event["pai"] as? String {
            parts.append("pai=\(pai)")
        }
        if let target = event["target"] as? Int {
            parts.append("target=\(target)")
        }
        if let consumed = event["consumed"] as? [String] {
            parts.append("consumed=\(consumed.joined(separator: ","))")
        }
        if let bakaze = event["bakaze"] as? String {
            parts.append("bakaze=\(bakaze)")
        }
        if let kyoku = event["kyoku"] as? Int {
            parts.append("kyoku=\(kyoku)")
        }

        return parts.isEmpty ? "" : "[\(parts.joined(separator: ", "))]"
    }

    private func handleWebSocketClose(_ data: [String: Any]) {
        guard let socketId = data["socketId"] as? Int else { return }

        wsLog("[WS] WebSocket closed: \(socketId)")

        // 與 `handleWebSocketConnected` 同一個判準：沒進過集合的就不該影響狀態，
        // 否則第三方 socket 關閉會在雀魂線全斷之後再多報一次 disconnected。
        guard data["isMajsoul"] as? Bool ?? false else { return }

        connectedSockets.remove(socketId)

        if connectedSockets.isEmpty {
            onWebSocketStatusChanged?(false)
        }
    }

    private func handleWebSocketError(_ data: [String: Any]) {
        if let socketId = data["socketId"] as? Int {
            wsLog("[WS] WebSocket error: \(socketId)")
        }
    }

    /// Naki 自己呼叫 `__nakiWebSocket.forceReconnect()` 關掉連線。
    ///
    /// 關閉數本身已經由 `NakiWebSocketScript.forceReconnect` 的回傳值交給呼叫端
    /// 這裡不是為了取值，是為了**歸因**：緊接著進來的那幾筆
    /// `websocket_close` 是預期內的，不是斷線。少了這一行，log 上主動重連與
    /// 網路掉線長得一模一樣。
    private func handleForceReconnect(_ data: [String: Any]) {
        guard let closedCount = data["closedCount"] as? Int else { return }

        wsLog("[WS] Naki 主動強制重連：已關閉 \(closedCount) 條連線"
            + "（接下來的 websocket_close 是預期內的）", level: .event)
    }

    /// 插件經 `ctx.log()` 送出的事件。
    ///
    /// **第三方插件不可自呼 `sendToSwift`**（未知 type 會被 `warnUnknown` 丟掉）。
    /// bundled 的 `naki-plugins.js` 用這個固定 type `plugin_event` 統一轉發，
    /// 這是唯一的插件→Swift 通道。data schema：`id` / `kind` / `msg`。
    /// 只記插件 id 與訊息，**不記錄封包內容**（可能含 session token，CLAUDE.md 第 8 條）。
    private func handlePluginEvent(_ data: [String: Any]) {
        guard let id = data["id"] as? String else { return }
        let msg = data["msg"] as? String ?? ""
        wsLog("[Plugin] \(id)：\(msg)")
    }

    // MARK: - Public Methods

    /// 重置橋接器狀態（開始新遊戲時調用）
    func reset() {
        majsoulBridge.reset()
    }

    /// 完整重置橋接器狀態（頁面重新載入時調用）
    func fullReset() {
        majsoulBridge.fullReset()
        connectedSockets.removeAll()
    }
}

// MARK: - Account ID Source

/// MCP 的協定層快照需要「現在登入的是誰」。
///
/// 只暴露這一個唯讀值：`GameSnapshotAction` 因此不必認得 `WebSocketMessageHandler`、
/// 更不必認得 `NakiWebCoordinator`——那是 View 層。
extension WebSocketMessageHandler: NakiAccountIdSource {}
