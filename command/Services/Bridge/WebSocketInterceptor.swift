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

    /// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` 會給這個 class 一個 isolated deinit，
    /// 單元測試釋放它時會 SIGABRT（見 CLAUDE.md）。singleton 實務上不會釋放，
    /// 但測試可能建臨時實例，所以照樣補上。
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
    /// 順序仍然重要：`naki-websocket` 會取 `naki-core` 的 base64／sendToSwift。
    static let jsModules = [
        "naki-core",
        "naki-websocket"
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

// MARK: - WebSocket Message Handler

/// 處理從 JavaScript 傳來的 WebSocket 消息
class WebSocketMessageHandler: NSObject, WKScriptMessageHandler {

    // MARK: - Properties

    /// 雀魂協議橋接器
    private let majsoulBridge = MajsoulBridge()

    /// 目前登入帳號的 account_id（由 MajsoulBridge 從登入／authGame 回應解析）。
    /// `ReqAccountInfo.account_id` 為必填，MCP 的帳號查詢工具需要它當預設值。
    var majsoulAccountId: Int { majsoulBridge.accountId }

    /// MJAI 事件回調
    var onMJAIEvent: (([String: Any]) -> Void)?

    /// WebSocket 狀態回調
    var onWebSocketStatusChanged: ((Bool) -> Void)?

    /// 連接的 WebSocket 數量
    private var connectedSockets: Set<Int> = []

    // MARK: - WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController,
                              didReceive message: WKScriptMessage) {

        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String else {
            return
        }

        let data = body["data"] as? [String: Any] ?? [:]

        switch type {
        case "interceptor_ready":
            let version = data["version"] as? String ?? "unknown"
            let autoplay = data["autoplay"] as? Bool ?? false
            wsLog("[JS] WebSocket interceptor is ready (v\(version), autoplay=\(autoplay))")

        case "websocket_debug":
            if let url = data["url"] as? String,
               let msg = data["message"] as? String {
                wsLog("[WS] DEBUG: \(msg) - \(url)")
            }

        case "websocket_open":
            handleWebSocketOpen(data)

        case "websocket_connected":
            handleWebSocketConnected(data)

        case "websocket_message":
            handleWebSocketMessage(data)

        case "websocket_close", "websocket_closed":
            handleWebSocketClose(data)

        case "websocket_error":
            handleWebSocketError(data)

        // 註：`autoplay_click` / `autoplay_tile_click` / `autoplay_button_click` /
        // `autoplay_error` / `addHandPai` / `console_log` 這幾個 case 已移除。
        // 它們唯一的送出端是 naki-autoplay.js（座標點擊、Laya `_AddHandPai` hook）
        // 與 naki-websocket.js 的 `interceptConsole`，前者整檔刪除、後者零呼叫者，
        // 所以這些訊息在現行客戶端永遠不會抵達。

        default:
            break
        }
    }

    // MARK: - Message Handlers

    private func handleWebSocketOpen(_ data: [String: Any]) {
        guard let socketId = data["socketId"] as? Int,
              let url = data["url"] as? String else { return }

        wsLog("[WS] WebSocket opening: \(socketId) - \(url)")
    }

    private func handleWebSocketConnected(_ data: [String: Any]) {
        guard let socketId = data["socketId"] as? Int else { return }

        connectedSockets.insert(socketId)
        wsLog("[WS] WebSocket connected: \(socketId)")
        onWebSocketStatusChanged?(true)
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
        } else {
            // 調試：顯示解析結果
            let parser = LiqiParser()
            if let parsed = parser.parse(binaryData),
               let method = parsed["method"] as? String {
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

        connectedSockets.remove(socketId)
        wsLog("[WS] WebSocket closed: \(socketId)")

        if connectedSockets.isEmpty {
            onWebSocketStatusChanged?(false)
        }
    }

    private func handleWebSocketError(_ data: [String: Any]) {
        if let socketId = data["socketId"] as? Int {
            wsLog("[WS] WebSocket error: \(socketId)")
        }
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
