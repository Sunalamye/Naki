//
//  LiqiActionSender.swift
//  Naki
//
//  把 `LiqiRequestSpec` 送出去的那一層——只有這件事。
//
//  舊路徑（`window.naki.action.*` → Laya 物件）在 Unity WebGL 客戶端已完全失效，
//  現在走協定層：
//
//      LiqiRequestBuilder（LiqiRequestBuilder.swift，組 payload 欄位）
//          → LiqiEncoder.encodeRequest（配 msgId、組 envelope；格式定義在 LiqiEnvelope）
//          → base64
//          → window.__nakiWebSocket.sendRaw(base64)   // 已實測可送出
//
//  這一層不呼叫任何全域 log 函式：要寫 log 的呼叫端自己注入 `logHandler`。
//  牌碼轉換在 `LiqiTile.swift`、請求組裝在 `LiqiRequestBuilder.swift`、
//  MCP 呈現層在 `Services/MCP/LiqiToolResult.swift`，都不屬於本檔。
//
//  ## msgId → method 對照表只有一份
//
//  本類別**不再**自己記一份 `pendingMethods`。收到 RESPONSE 時要知道那是哪個方法，
//  唯一的來源是 `LiqiParser.pendingRequests`：Naki 送出的 frame 會經過 JS 端
//  `ws.send` 的 hook 回到 `MajsoulBridge.parseRaw`，所以自送請求與遊戲自己的請求
//  都在那一份表裡（`LiqiResponseStore` 正是靠它拿到方法名）。
//  在這裡另存一份不會有任何讀取端用它配對回應，只會多一份會漂的事實。
//

import Foundation

// MARK: - 送出結果

/// JS 端 `sendRaw` 的回報
struct LiqiRawSendResult {
    let success: Bool
    /// 成功時為 `socket=… bytes=…`；失敗時為 JS 回報的 reason 或本地錯誤
    let detail: String?

    static func failure(_ reason: String) -> LiqiRawSendResult {
        LiqiRawSendResult(success: false, detail: reason)
    }
}

/// 一次送出的完整結果（含 msgId，方便對照伺服器 RESPONSE）
struct LiqiSendResult {
    let method: String
    let msgId: UInt16
    let byteCount: Int
    let success: Bool
    let detail: String?

    var logLine: String {
        let state = success ? "✅" : "❌"
        return "\(state) \(method) msgId=\(msgId) bytes=\(byteCount)\(detail.map { " (\($0))" } ?? "")"
    }
}

// MARK: - Action Sender

/// 動作／大廳請求送出器。
///
/// 自己不碰 WebView：由 `WebSession` 注入「base64 → JS」的送出閉包，
/// 讓本類別可以在單元測試中以假閉包驅動。
@MainActor
final class LiqiActionSender {

    /// base64 → 送出結果（由呼叫端注入，內部呼叫
    /// `window.__nakiWebSocket.sendRaw(...)`）
    typealias SendHandler = (String) async -> LiqiRawSendResult

    /// 送出通道（未注入時所有送出都會失敗並記錄）
    var sendHandler: SendHandler?

    /// 日誌輸出（呼叫端會同時寫 bridgeLog 與 debug server）。
    /// 協定層自己不呼叫全域 log 函式——要不要留痕跡是呼叫端的決定。
    var logHandler: ((String) -> Void)?

    /// 最近一次送出結果（診斷用）
    private(set) var lastResult: LiqiSendResult?

    /// 自動心跳計時器（防閒置；預設關閉）
    ///
    /// 不在 deinit 裡 invalidate：計時器 closure 以 weak self 捕獲，self 消失後會自行 invalidate。
    private var antiIdleTimer: Timer?

    init(sendHandler: SendHandler? = nil) {
        self.sendHandler = sendHandler
    }

    /// MainActor class 在 NakiTests host 釋放會 SIGABRT（見 CLAUDE.md「專案結構的坑」）
    nonisolated deinit {}

    // MARK: - 核心送出

    /// 送出一筆請求：組 envelope → base64 → JS `sendRaw`
    @discardableResult
    func send(_ spec: LiqiRequestSpec) async -> LiqiSendResult {
        let (msgId, bytes) = LiqiEncoder.encodeRequest(method: spec.method, fields: spec.fields)
        let base64 = LiqiEncoder.base64String(bytes)

        guard let sendHandler else {
            let result = LiqiSendResult(method: spec.method, msgId: msgId,
                                        byteCount: bytes.count, success: false,
                                        detail: "no_send_handler")
            lastResult = result
            logHandler?("[Liqi] \(result.logLine)")
            return result
        }

        logHandler?("[Liqi] → \(spec.method) msgId=\(msgId) bytes=\(bytes.count) payload=\(LiqiEncoder.hexString(spec.payload))")

        let raw = await sendHandler(base64)
        let result = LiqiSendResult(method: spec.method, msgId: msgId,
                                    byteCount: bytes.count, success: raw.success,
                                    detail: raw.detail)
        lastResult = result
        logHandler?("[Liqi] \(result.logLine)")
        return result
    }

    // MARK: - ② 動作層 API

    /// 跳過（cancel_operation = true）
    /// - Parameter channel: 預設 `.chiPengGang`（跳過的情境幾乎都是回應他家打牌）
    @discardableResult
    func pass(channel: LiqiActionChannel = .chiPengGang, timeuse: UInt32 = 0) async -> LiqiSendResult {
        await send(LiqiRequestBuilder.cancel(channel: channel, timeuse: timeuse))
    }

    // MARK: - 送出 + 等待回應

    /// 送出一筆請求，並在指定時間內輪詢 `LiqiResponseStore` 等它的 RESPONSE。
    ///
    /// RESPONSE 只帶 msgId 不帶方法名，配對完全靠 msgId；`LiqiParser` 會在
    /// 我們自己送出的封包經過 `ws.send` hook 時記下 `msgId → method`，
    /// 收到回應時再配回來（見 LiqiResponseStore 檔頭）。
    ///
    /// - Parameter awaitResponseMs: 等待毫秒數；`<= 0` 表示不等（純射後不理）
    func sendAwaitingResponse(_ spec: LiqiRequestSpec,
                              awaitResponseMs: Int) async -> LiqiToolSendOutcome {
        let result = await send(spec)
        guard result.success, awaitResponseMs > 0 else {
            return LiqiToolSendOutcome(sent: result)
        }

        let pollIntervalMs = 50
        var waited = 0
        while waited < awaitResponseMs {
            if let record = LiqiResponseStore.shared.response(forMsgId: result.msgId) {
                return LiqiToolSendOutcome(sent: result, response: record)
            }
            try? await Task.sleep(nanoseconds: UInt64(pollIntervalMs) * 1_000_000)
            waited += pollIntervalMs
        }
        return LiqiToolSendOutcome(sent: result,
                                   response: LiqiResponseStore.shared.response(forMsgId: result.msgId))
    }

    // MARK: - 保活

    /// 大廳心跳（防閒置）
    @discardableResult
    func heatbeat(noOperationCounter: UInt32 = 0) async -> LiqiSendResult {
        let result = await send(LiqiRequestBuilder.heatbeat(noOperationCounter: noOperationCounter))
        if result.success {
            lastHeartbeatAt = Date()
            heartbeatCount += 1
        }
        return result
    }

    // MARK: - 防閒置（自動心跳）

    /// 是否啟用自動心跳
    private(set) var antiIdleEnabled = false
    /// 自動心跳間隔（秒）
    private(set) var antiIdleInterval: TimeInterval = 300
    /// 最近一次成功送出心跳的時間
    private(set) var lastHeartbeatAt: Date?
    /// 累計成功送出的心跳次數
    private(set) var heartbeatCount = 0

    /// 設定自動心跳。
    ///
    /// 取代 Unity 下已失效的 `window.__nakiAntiIdle`（它呼叫 `GameMgr.Inst.clientHeatBeat()`）。
    /// 這裡改為由 Swift 定期送 `.lq.Lobby.heatbeat`。
    ///
    /// ⚠️ **未驗證**：雀魂的閒置判定是否吃這個心跳、以及合適的間隔，都需要真實登入觀察。
    /// - Parameter intervalSeconds: 送出間隔，下限 30 秒（避免打太頻繁）
    func setAntiIdle(enabled: Bool, intervalSeconds: TimeInterval? = nil) {
        if let intervalSeconds {
            antiIdleInterval = max(30, intervalSeconds)
        }
        antiIdleEnabled = enabled

        antiIdleTimer?.invalidate()
        antiIdleTimer = nil
        guard enabled else { return }

        antiIdleTimer = Timer.scheduledTimer(withTimeInterval: antiIdleInterval,
                                             repeats: true) { [weak self] timer in
            guard self != nil else {
                timer.invalidate()
                return
            }
            Task { @MainActor [weak self] in
                guard let self, self.antiIdleEnabled else { return }
                await self.heatbeat()
            }
        }
    }

    /// 自動心跳狀態（給 MCP 工具輸出）
    var antiIdleStatus: [String: Any] {
        var status: [String: Any] = [
            "enabled": antiIdleEnabled,
            "intervalSeconds": Int(antiIdleInterval),
            "heartbeatCount": heartbeatCount,
            "method": LiqiRequestBuilder.heatbeatMethod
        ]
        if let lastHeartbeatAt {
            status["lastHeartbeatAt"] = ISO8601DateFormatter().string(from: lastHeartbeatAt)
            status["secondsSinceLastHeartbeat"] = Int(Date().timeIntervalSince(lastHeartbeatAt))
        } else {
            status["lastHeartbeatAt"] = NSNull()
            status["secondsSinceLastHeartbeat"] = NSNull()
        }
        return status
    }
}
