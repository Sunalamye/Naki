//
//  LiqiToolResult.swift
//  Naki
//
//  「送出一筆 Liqi request」在 MCP 工具面的呈現層。
//
//  p4-2 把它從 `LiqiActionSender.swift` 搬出來，並且**搬到 MCP 目錄底下**：
//  它唯一的用途是把送出結果轉成工具回傳的 JSON，而且會寫 `eventLog`。
//  留在協定層的後果不只是檔案變長——協定層一旦開始寫 log，
//  「送出」與「怎麼把送出講給人聽」就綁死，單元測試也跟著要吃 log 副作用。
//  現在協定層（`LiqiActionSender` / `LiqiRequestBuilder` / `LiqiEncoder`）
//  完全不呼叫任何 log 函式，log 一律發生在呼叫端（本檔與各 `*Tools.swift`）。
//

import Foundation

// MARK: - 工具層送出結果

/// 「送出 + （可選）等待回應」的完整結果，供 MCP 工具轉成 JSON。
///
/// 三種狀態要分清楚：
/// - `unavailableReason != nil`：連送都沒送（沒有 WebViewModel / 沒有送出通道）
/// - `sent?.success == false`：送出被 JS 端拒絕（沒有 OPEN 的雀魂連線等）
/// - `sent?.success == true && response == nil`：**送出去了，但沒等到回應**
///   （可能是伺服器沒回、也可能是等待時間不夠；不可當成失敗，也不可當成成功）
struct LiqiToolSendOutcome {
    let sent: LiqiSendResult?
    let response: LiqiResponseRecord?
    let unavailableReason: String?

    init(sent: LiqiSendResult? = nil,
         response: LiqiResponseRecord? = nil,
         unavailableReason: String? = nil) {
        self.sent = sent
        self.response = response
        self.unavailableReason = unavailableReason
    }

    /// 沒有送出通道時的結果
    static func unavailable(_ reason: String) -> LiqiToolSendOutcome {
        LiqiToolSendOutcome(unavailableReason: reason)
    }
}

/// 把送出結果轉成 MCP 工具的回傳字典
enum LiqiToolResult {

    /// - Parameters:
    ///   - outcome: 送出結果
    ///   - spec: 送出的請求（用來附上 method 與 payload hex，方便對拍）
    ///   - extra: 額外欄位（例如工具自己的參數回顯）
    static func dictionary(_ outcome: LiqiToolSendOutcome,
                           spec: LiqiRequestSpec,
                           extra: [String: Any] = [:]) -> [String: Any] {
        var result: [String: Any] = [
            "method": spec.method,
            "payloadHex": LiqiEncoder.hexString(spec.payload)
        ]
        result.merge(extra) { current, _ in current }

        guard let sent = outcome.sent else {
            result["success"] = false
            result["error"] = "liqi_sender_unavailable"
            result["reason"] = outcome.unavailableReason ?? "unknown"
            return result
        }

        result["success"] = sent.success
        result["msgId"] = Int(sent.msgId)
        result["bytes"] = sent.byteCount
        if let detail = sent.detail { result["detail"] = detail }

        if !sent.success {
            result["error"] = "send_failed"
            return result
        }

        if let response = outcome.response {
            result["response"] = response.dictionary
            result["serverAccepted"] = !response.hasError
            // 被拒絕時直接把碼寫進 log。以前只記 `✅ 已送出`（那只代表 bytes 出去了），
            // 要知道伺服器其實拒絕了得去翻 MCP 回應再手工解 base64。
            if let desc = response.errorDescription {
                eventLog("[Liqi] ❌ \(response.method) msgId=\(response.msgId) 被伺服器拒絕: \(desc)")
            }
        } else {
            result["response"] = NSNull()
            result["note"] = "請求已送出但尚未收到對應 msgId 的 RESPONSE；"
                + "可稍後用 get_logs 觀察，或提高 awaitResponseMs。"
                + "「送出成功」不等於「伺服器接受」。"
        }
        return result
    }
}
