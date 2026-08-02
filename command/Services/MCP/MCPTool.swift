//
//  MCPTool.swift
//  Naki
//
//  Created by Claude on 2025/12/05.
//  Naki 專用的 MCP 工具 Protocol
//

import Foundation
import MCPKit

// MARK: - Re-export MCPKit types

// MCPKit 提供的類型已通過 import MCPKit 可用：
// - MCPTool (protocol)
// - MCPInputSchema
// - MCPPropertySchema
// - MCPToolResult
// - MCPToolError
// - MCPContext (protocol)

// MARK: - Naki MCP Tool Protocol

/// Naki 專用的 MCP 工具協議
/// 擴展 MCPKit 的 MCPTool，使用 NakiMCPContext
protocol NakiMCPTool: MCPTool {
    /// Naki 專用上下文
    var nakiContext: NakiMCPContext { get }
}

// MARK: - Unity 遷移後不再可行的工具

/// 「這個能力在 Unity 客戶端下不存在」的統一失敗結構。
///
/// 為什麼要有統一結構：舊的 HighlightTools 會回 `{"success": {"success": false, ...}}`
/// ——外層把「失敗物件」直接塞進 `success` 欄位，機械判斷 `result.success` 會拿到一個
/// **truthy 的字典**，於是失敗被讀成成功。這是最糟的一種錯（沉默的假陽性）。
///
/// 這裡固定回：`success` 一定是 `Bool`，且失敗時一定有 `error` / `reason`。
enum NakiUnsupported {

    /// 失敗代碼（機械判斷用；人看 `reason`）
    static let errorCode = "unsupported_on_unity_client"

    /// - Parameters:
    ///   - reason: 為什麼不可行（要講到具體失效的物件，不要只說「不支援」）
    ///   - alternative: 替代做法（沒有就傳 nil）
    static func result(reason: String, alternative: String? = nil) -> [String: Any] {
        var payload: [String: Any] = [
            "success": false,
            "error": errorCode,
            "reason": reason,
            "client": "unity-webgl"
        ]
        if let alternative {
            payload["alternative"] = alternative
        }
        return payload
    }
}

// MARK: - Naki Tool Base

/// Naki 工具基礎類別
/// 提供 NakiMCPContext 的便利存取
class NakiToolBase {
    let context: MCPContext

    /// 獲取 Naki 專用上下文
    var nakiContext: NakiMCPContext? {
        context as? NakiMCPContext
    }

    required init(context: MCPContext) {
        self.context = context
    }
}
