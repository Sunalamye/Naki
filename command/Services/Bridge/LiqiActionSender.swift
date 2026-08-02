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
//  p4-2 之前本檔還兼著牌碼轉換（→ `LiqiTile.swift`）、請求組裝
//  （→ `LiqiRequestBuilder.swift`）與 MCP 呈現層（→ `Services/MCP/LiqiToolResult.swift`）。
//  拆開之後這一層不再呼叫任何全域 log 函式：要寫 log 的呼叫端自己注入 `logHandler`。
//
//  ## msgId → method 對照表只有一份
//
//  本類別**不再**自己記一份 `pendingMethods`。收到 RESPONSE 時要知道那是哪個方法，
//  唯一的來源是 `LiqiParser.pendingRequests`：Naki 送出的 frame 會經過 JS 端
//  `ws.send` 的 hook 回到 `MajsoulBridge.parseRaw`，所以自送請求與遊戲自己的請求
//  都在那一份表裡（`LiqiResponseStore` 正是靠它拿到方法名）。
//  以前這裡另存一份，卻沒有任何讀取端使用它來配對回應——只是一個會漂的第二份事實。
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
    /// 刻意不寫 `deinit` 來 invalidate：本專案設 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，
    /// 為 MainActor class 加 deinit 會產生 isolated deinit，在同步 XCTest 釋放時會讓 host app abort。
    /// 計時器 closure 以 weak self 捕獲，self 消失後會自行 invalidate。
    private var antiIdleTimer: Timer?

    init(sendHandler: SendHandler? = nil) {
        self.sendHandler = sendHandler
    }

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

    /// 打牌
    /// - Parameter tile: **雀魂格式**（`5m` / `0m` / `1z`）
    @discardableResult
    func discard(tile: String, moqie: Bool, timeuse: UInt32 = 0) async -> LiqiSendResult {
        await send(LiqiRequestBuilder.discard(tile: tile, moqie: moqie, timeuse: timeuse))
    }

    /// 立直（需附帶要打出的牌，雀魂格式）
    @discardableResult
    func riichi(tile: String, moqie: Bool = false, timeuse: UInt32 = 0) async -> LiqiSendResult {
        await send(LiqiRequestBuilder.riichi(tile: tile, moqie: moqie, timeuse: timeuse))
    }

    /// 吃（index 為 oplist combination 的索引）
    @discardableResult
    func chi(index: UInt32, timeuse: UInt32 = 0) async -> LiqiSendResult {
        await send(LiqiRequestBuilder.chi(index: index, timeuse: timeuse))
    }

    /// 碰
    @discardableResult
    func pon(index: UInt32 = 0, timeuse: UInt32 = 0) async -> LiqiSendResult {
        await send(LiqiRequestBuilder.pon(index: index, timeuse: timeuse))
    }

    /// 槓（暗槓 / 加槓 / 大明槓由 type 決定走哪個方法）
    @discardableResult
    func kan(type: LiqiOperationType, index: UInt32 = 0, tile: String? = nil,
             timeuse: UInt32 = 0) async -> LiqiSendResult {
        await send(LiqiRequestBuilder.kan(type: type, index: index, tile: tile, timeuse: timeuse))
    }

    /// 自摸和
    @discardableResult
    func tsumo(timeuse: UInt32 = 0) async -> LiqiSendResult {
        await send(LiqiRequestBuilder.tsumo(timeuse: timeuse))
    }

    /// 榮和
    @discardableResult
    func ron(timeuse: UInt32 = 0) async -> LiqiSendResult {
        await send(LiqiRequestBuilder.ron(timeuse: timeuse))
    }

    /// 九種九牌
    @discardableResult
    func kyushu(timeuse: UInt32 = 0) async -> LiqiSendResult {
        await send(LiqiRequestBuilder.kyushu(timeuse: timeuse))
    }

    /// 拔北（三麻）
    @discardableResult
    func babei(timeuse: UInt32 = 0) async -> LiqiSendResult {
        await send(LiqiRequestBuilder.babei(timeuse: timeuse))
    }

    /// 跳過（cancel_operation = true）
    /// - Parameter channel: 預設 `.chiPengGang`（跳過的情境幾乎都是回應他家打牌）
    @discardableResult
    func pass(channel: LiqiActionChannel = .chiPengGang, timeuse: UInt32 = 0) async -> LiqiSendResult {
        await send(LiqiRequestBuilder.cancel(channel: channel, timeuse: timeuse))
    }

    // MARK: - ③ 大廳層 API

    /// 建立好友房
    @discardableResult
    func createFriendRoom(config: LiqiFriendRoomConfig) async -> LiqiSendResult {
        await send(LiqiRequestBuilder.createRoom(config: config))
    }

    /// 建立好友房（常用參數版）
    @discardableResult
    func createFriendRoom(playerCount: Int = 4,
                          mode: UInt32 = 1,
                          timeFixed: UInt32 = 60,
                          timeAdd: UInt32 = 5,
                          aiLevel: UInt32? = nil,
                          enableAI: Bool = false,
                          publicLive: Bool = false,
                          clientVersionString: String = "") async -> LiqiSendResult {
        var config = LiqiFriendRoomConfig()
        config.playerCount = UInt32(max(0, playerCount))
        config.mode = mode
        config.timeFixed = timeFixed
        config.timeAdd = timeAdd
        config.aiLevel = aiLevel
        config.enableAI = enableAI
        config.publicLive = publicLive
        config.clientVersionString = clientVersionString
        return await createFriendRoom(config: config)
    }

    /// 加機器人到指定座位
    @discardableResult
    func addRobot(position: UInt32) async -> LiqiSendResult {
        await send(LiqiRequestBuilder.addRoomRobot(position: position))
    }

    /// 開始對局
    @discardableResult
    func startRoom() async -> LiqiSendResult {
        await send(LiqiRequestBuilder.startRoom())
    }

    /// 加入房間
    @discardableResult
    func joinRoom(roomId: UInt32, clientVersionString: String = "") async -> LiqiSendResult {
        await send(LiqiRequestBuilder.joinRoom(roomId: roomId,
                                               clientVersionString: clientVersionString))
    }

    /// 離開房間
    @discardableResult
    func leaveRoom() async -> LiqiSendResult {
        await send(LiqiRequestBuilder.leaveRoom())
    }

    /// 查詢目前房間
    @discardableResult
    func fetchRoom() async -> LiqiSendResult {
        await send(LiqiRequestBuilder.fetchRoom())
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

    // MARK: - ③ 大廳層：匹配 / 帳號 / 保活 API

    /// 段位場排隊
    @discardableResult
    func matchGame(matchMode: UInt32, clientVersionString: String = "") async -> LiqiSendResult {
        await send(LiqiRequestBuilder.matchGame(matchMode: matchMode,
                                                clientVersionString: clientVersionString))
    }

    /// 取消排隊
    @discardableResult
    func cancelMatch(matchMode: UInt32) async -> LiqiSendResult {
        await send(LiqiRequestBuilder.cancelMatch(matchMode: matchMode))
    }

    /// 查詢帳號資訊（account_id 必填）
    @discardableResult
    func fetchAccountInfo(accountId: UInt32) async -> LiqiSendResult {
        await send(LiqiRequestBuilder.fetchAccountInfo(accountId: accountId))
    }

    /// 查詢目前對局／房間狀態
    @discardableResult
    func fetchGamingInfo() async -> LiqiSendResult {
        await send(LiqiRequestBuilder.fetchGamingInfo())
    }

    /// 查詢伺服器時間
    @discardableResult
    func fetchServerTime() async -> LiqiSendResult {
        await send(LiqiRequestBuilder.fetchServerTime())
    }

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

    /// 登入保活
    @discardableResult
    func loginBeat(contract: String) async -> LiqiSendResult {
        await send(LiqiRequestBuilder.loginBeat(contract: contract))
    }

    /// 對局內廣播表情
    @discardableResult
    func sendEmoji(emoId: Int, exceptSelf: Bool = false) async -> LiqiSendResult {
        await send(LiqiRequestBuilder.emoji(emoId: emoId, exceptSelf: exceptSelf))
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
