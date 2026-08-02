//
//  JSONSanitizer.swift
//  Naki
//
//  JSON 序列化前的 NaN／Infinity 清理——單一來源
//

import Foundation

/// `JSONSerialization` 碰到 NaN／Infinity 會直接 throw，整個回應變成 500。
/// 推薦機率、期望值這類 Double 有機會算出 NaN，所以送出前一律先過這裡換成 `null`。
///
/// 先前 `DebugServer` 與 `MCPHandler` 各有一份逐字相同的 `private func sanitizeForJSON`：
/// 兩處都在同一條 HTTP 回應鏈上，改一邊另一邊不會跟著動。收斂成這一份。
enum JSONSanitizer {

    /// 遞迴清理任意 JSON 值
    nonisolated static func sanitize(_ value: Any) -> Any {
        switch value {
        case let dict as [String: Any]:
            return dict.mapValues { sanitize($0) }
        case let array as [Any]:
            return array.map { sanitize($0) }
        case let d as Double where d.isNaN || d.isInfinite:
            return NSNull()
        case let f as Float where f.isNaN || f.isInfinite:
            return NSNull()
        case let n as NSNumber:
            let d = n.doubleValue
            if d.isNaN || d.isInfinite {
                return NSNull()
            }
            return n
        default:
            return value
        }
    }

    /// dictionary 版本。
    ///
    /// 呼叫端原本寫 `sanitizeForJSON(data) as! [String: Any]`——`sanitize` 對 dictionary
    /// 一定回 dictionary，所以那個 `as!` 只是把型別資訊丟掉再強轉回來。這裡直接保型別。
    nonisolated static func sanitize(_ dict: [String: Any]) -> [String: Any] {
        dict.mapValues { sanitize($0) }
    }
}
