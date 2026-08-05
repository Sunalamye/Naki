//
//  LiqiResponseStore.swift
//  Naki
//
//  Naki 自己送出的 REQUEST 對應 RESPONSE 的接收端快照，
//  以及 `.lq.NotifyGameBroadcast`（遊戲內表情廣播）的紀錄。
//
//  背景：Unity WebGL 客戶端沒有 `app.NetAgent`，舊的「掛 handler 讀回應」路徑已死。
//  但 RESPONSE 本來就會經過 WebSocket 攔截 →`LiqiParser.parse` →`MajsoulBridge.parse`，
//  只是既有流程只在意能轉成 MJAI 的訊息，其餘一律丟棄。
//
//  本檔把兩類「丟棄掉但有用」的訊息接住：
//
//    1. type=3 且 msgId 落在 Naki 號段（60000+）→ 這是**我們自己送出的請求**的回應。
//       LiqiParser 用 `pendingRequests[msgId]` 配對方法名，所以連方法名都有。
//    2. `.lq.NotifyGameBroadcast` → 表情廣播（seat + content）。
//
//  ⚠️ 驗收語彙：
//  - **已驗證（編碼/結構層）**：msgId 配對規則、欄位編號取自 docs/protocol/liqi.json；
//    capture 的路由邏輯有單元測試。
//  - **未驗證（需真實登入／對局）**：實際收到的 payload 形狀。
//    `LiqiParser` 對未知方法只做通用 `blocksToDict`，回來的是 `field1` / `field2` 這種
//    以欄位編號為 key 的原始字典，**不是**具名欄位。要對照語意請查 liqi.json。
//

import Foundation

// MARK: - 回應紀錄

/// 一筆 Naki 自送請求的伺服器回應
///
/// `fields` 是 `LiqiParser` 的通用解析結果（key 形如 `field1`、`field2`），
/// 不是具名欄位；語意請對照 docs/protocol/liqi.json 的 `Res*` 定義。
nonisolated struct LiqiResponseRecord {
    /// 對應的請求 msgId（Naki 號段 60000+）
    let msgId: Int
    /// 方法全名（由 LiqiParser 以 msgId 配對得出）
    let method: String
    /// 通用解析結果（field 編號為 key）
    let fields: [String: Any]
    /// 收到時間
    let receivedAt: Date

    /// 所有雀魂 `Res*` 的 field 1 都是 `Error error`；出現代表伺服器拒絕了這個請求。
    var hasError: Bool { fields["field1"] != nil }

    /// 伺服器回的錯誤碼（`Error.code`，field 1 的 varint）
    ///
    /// 通用解析把巢狀 message 轉成 base64，所以這裡要自己解一層。
    /// 不解的話，每次排查都要人工 base64 → hex → varint——2026-08-01 那輪
    /// 為了找出四個錯誤碼手工解了四次，而每一次都是「`sendRaw` 回 success:true
    /// 但伺服器其實拒絕了」，肉眼完全看不出來。
    ///
    /// varint 一律走 `LiqiWire.decodeVarint`（全專案唯一一份），不要在這裡自己寫迴圈：
    /// 兩份實作的溢位上限會漂開。
    var errorCode: Int? {
        guard let b64 = fields["field1"] as? String,
              let data = Data(base64Encoded: b64),
              data.count >= 2,
              data[0] == 0x08                      // field 1, wire type 0 (varint)
        else { return nil }

        return LiqiWire.decodeVarint(data, offset: 1)?.value
    }

    /// 已知錯誤碼的語意
    ///
    /// ⚠️ 全部由 2026-08-01 的實測歸納，**不是官方文件**，也不完整。
    /// 不在表內的碼會如實回報數字，不要猜。
    static let knownErrors: [Int: String] = [
        1004: "該 socket 未完成登入（送到沒做過 oauth2Login 的那條 /gateway），或已在對局中",
        1023: "對局進行中，不能建房／離房",
        1105: "已在友人房中，不能再建房",
        1306: "match_mode 不存在（對照表偏移，見 lobby_match_modes 的 warning）"
    ]

    /// 人看得懂的錯誤描述
    var errorDescription: String? {
        guard let code = errorCode else { return nil }
        if let known = Self.knownErrors[code] {
            return "error \(code): \(known)"
        }
        return "error \(code)（未收錄；語意未知，不要猜）"
    }

    /// 給 MCP 工具輸出用的字典
    var dictionary: [String: Any] {
        var d: [String: Any] = [
            "msgId": msgId,
            "method": method,
            "hasError": hasError,
            "fields": fields,
            "receivedAt": ISO8601DateFormatter().string(from: receivedAt),
            "note": "fields 的 key 是 protobuf 欄位編號（fieldN），語意請查 docs/protocol/liqi.json"
        ]
        if let code = errorCode { d["errorCode"] = code }
        if let desc = errorDescription { d["errorDescription"] = desc }
        return d
    }
}

// MARK: - 廣播紀錄

/// 一筆 `.lq.NotifyGameBroadcast`（遊戲內表情／訊息廣播）
nonisolated struct LiqiBroadcastRecord {
    /// 發送者座位
    let seat: Int
    /// 廣播內容（雀魂表情為 JSON 字串 `{"emo":N}`）
    let content: String
    /// 解析出的表情 id（非表情廣播為 nil）
    let emoId: Int?
    /// 收到時間
    let receivedAt: Date

    var dictionary: [String: Any] {
        [
            "seat": seat,
            "content": content,
            "emoId": emoId ?? NSNull(),
            "receivedAt": ISO8601DateFormatter().string(from: receivedAt)
        ]
    }
}

// MARK: - 快照儲存

/// Naki 自送請求的回應 + 表情廣播的儲存體（thread-safe）
///
/// - 寫入端：`MajsoulBridge.parse`（每個收到的 frame 都餵一次 `capture`）
/// - 讀取端：MCP 工具（`LiqiActionSender.sendAwaitingResponse` 會輪詢這裡）
///
/// `nonisolated`：專案設 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，
/// 未標注的 class 會帶 isolated deinit，在同步 XCTest 釋放時會讓 host app abort
/// （與 `LiqiOperationStore` / `LiqiMsgIdAllocator` 同樣理由）。
nonisolated final class LiqiResponseStore: @unchecked Sendable {

    /// 全域共用實例
    static let shared = LiqiResponseStore()

    /// 只接住 msgId >= 這個值的回應（Naki 注入號段；遊戲自己用低位遞增號）
    static let nakiMsgIdFloor = Int(LiqiMsgIdAllocator.rangeStart)

    /// 表情廣播的方法全名
    static let broadcastMethod = ".lq.NotifyGameBroadcast"

    /// 回應保留上限
    private let responseLimit = 32
    /// 廣播保留上限
    private let broadcastLimit = 50

    private let lock = NSLock()
    private var responses: [Int: LiqiResponseRecord] = [:]
    private var responseOrder: [Int] = []
    private var broadcastBuffer: [LiqiBroadcastRecord] = []

    init() {}

    // MARK: - 寫入

    /// 餵入一筆 `LiqiParser.parse` 的結果，路由到回應或廣播。
    ///
    /// - Returns: 有接住東西回 true（純診斷用）
    @discardableResult
    func capture(_ parsed: [String: Any]) -> Bool {
        guard let method = parsed["method"] as? String else { return false }
        let type = parsed["type"] as? String ?? ""
        let data = parsed["data"] as? [String: Any] ?? [:]

        if type == "response", let msgId = parsed["id"] as? Int,
           msgId >= LiqiResponseStore.nakiMsgIdFloor {
            recordResponse(msgId: msgId, method: method, fields: data)
            return true
        }

        if type == "notify", method == LiqiResponseStore.broadcastMethod {
            recordBroadcast(fields: data)
            return true
        }

        return false
    }

    /// 記錄一筆回應
    func recordResponse(msgId: Int, method: String, fields: [String: Any]) {
        let record = LiqiResponseRecord(msgId: msgId, method: method,
                                        fields: fields, receivedAt: Date())
        lock.lock()
        defer { lock.unlock() }
        if responses[msgId] == nil {
            responseOrder.append(msgId)
        }
        responses[msgId] = record
        while responseOrder.count > responseLimit {
            let evicted = responseOrder.removeFirst()
            responses.removeValue(forKey: evicted)
        }
    }

    /// 記錄一筆表情廣播（`fields` 為 `NotifyGameBroadcast` 的通用解析結果）
    ///
    /// `NotifyGameBroadcast { seat = 1, content = 2 }`（liqi.json 已確認）。
    /// `content` 經通用解析可能是明文字串，也可能因含 `{`／`"` 被轉成 base64，兩種都試。
    func recordBroadcast(fields: [String: Any]) {
        let seat = fields["field1"] as? Int ?? -1
        let raw = fields["field2"] as? String ?? ""
        let content = LiqiResponseStore.decodeBroadcastContent(raw)
        let record = LiqiBroadcastRecord(seat: seat,
                                         content: content,
                                         emoId: LiqiResponseStore.emojiId(from: content),
                                         receivedAt: Date())
        lock.lock()
        defer { lock.unlock() }
        broadcastBuffer.append(record)
        if broadcastBuffer.count > broadcastLimit {
            broadcastBuffer.removeFirst(broadcastBuffer.count - broadcastLimit)
        }
    }

    // MARK: - 讀取

    /// 取指定 msgId 的回應（沒收到回 nil）
    func response(forMsgId msgId: UInt16) -> LiqiResponseRecord? {
        lock.lock()
        defer { lock.unlock() }
        return responses[Int(msgId)]
    }

    /// 最近收到的回應（新到舊）
    var recentResponses: [LiqiResponseRecord] {
        lock.lock()
        defer { lock.unlock() }
        return responseOrder.reversed().compactMap { responses[$0] }
    }

    /// 表情廣播紀錄（舊到新）
    var broadcasts: [LiqiBroadcastRecord] {
        lock.lock()
        defer { lock.unlock() }
        return broadcastBuffer
    }

    /// 清空廣播紀錄
    func clearBroadcasts() {
        lock.lock()
        defer { lock.unlock() }
        broadcastBuffer.removeAll(keepingCapacity: true)
    }

    /// 全部清空（重連 / 測試用）
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        responses.removeAll(keepingCapacity: true)
        responseOrder.removeAll(keepingCapacity: true)
        broadcastBuffer.removeAll(keepingCapacity: true)
    }

    // MARK: - 內容解碼

    /// 通用解析可能把含特殊字元的字串轉成 base64；能還原成 UTF-8 就還原，否則原樣回傳。
    static func decodeBroadcastContent(_ raw: String) -> String {
        guard !raw.isEmpty else { return raw }
        // 已經是明文 JSON 就不用還原
        if raw.hasPrefix("{") { return raw }
        guard let data = Data(base64Encoded: raw),
              let decoded = String(data: data, encoding: .utf8),
              !decoded.isEmpty else {
            return raw
        }
        return decoded
    }

    /// 從廣播內容取表情 id（雀魂表情格式為 `{"emo": N}`）
    static func emojiId(from content: String) -> Int? {
        guard let data = content.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let value = json["emo"] as? Int { return value }
        if let value = json["emo"] as? Double { return Int(value) }
        return nil
    }
}
