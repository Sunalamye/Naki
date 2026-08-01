//
//  HighlightTools.swift
//  Naki
//
//  Created by Claude on 2025/12/07.
//  Updated 2026-08-01：釐清「MCP 手動工具未接線」與「App 內建 WebGL 高亮」是兩條路徑。
//
//  這 6 個 MCP tool 仍是相容失敗樁，因為它們的參數／回傳契約源自 Laya 牌物件，
//  尚未接到新的 `window.__nakiHighlight`。App 自動推薦高亮已改用 WebGL draw hook，
//  由 Swift 直接呼叫 `__nakiHighlight.set/clear`，不可把 MCP stub 的 unavailable
//  泛化成「Unity 下所有高亮都不可能」。
//
//  為什麼留下失敗樁而不是移除：高亮有明確的替代面（Naki 原生推薦面板 RecommendationView），
//  留著才能在 agent 呼叫時把它導過去；反之 UITools 那些純 Laya 探測工具沒有替代面，直接移除。
//
//  ⚠️ 修掉的既有 bug：舊實作是
//      let result = try await context.executeJavaScript(script)   // JS 回 {success:false, error:…}
//      return result ?? [...]                                      // 直接回 JS 物件
//  而 `highlight_tile` 那類又在 JS 內層包一次 `{ success: result }`，
//  於是失敗會變成 `{"success": {"success": false, "error": "高亮模組未載入"}}`。
//  機械判斷 `result.success` 拿到的是 **truthy 的字典**，失敗被讀成成功。
//  現在統一走 `NakiUnsupported.result(...)`：`success` 保證是 Bool，且必有 `error` / `reason`。
//

#if os(macOS)

import Foundation
import MCPKit

// MARK: - 共用失敗訊息

/// 高亮類工具的共用失敗說明
private enum HighlightUnsupported {
    static let reason = """
        unity-mcp-highlighter-not-wired: 這組 MCP 手動高亮 API 仍使用 Laya 時代的 \
        tileIndex / effect 設計，尚未接到現行 window.__nakiHighlight WebGL hook。
        """
    static let alternative = """
        App 的 AI 推薦會走內建 WebGL 自動高亮；程式化取得推薦請用 bot_status / game_hand。\
        手動指定 WebGL target 的 MCP contract 尚未實作。
        """

    static func result() -> [String: Any] {
        NakiUnsupported.result(reason: reason, alternative: alternative)
    }
}

// MARK: - Highlight Tile Tool

/// 高亮指定手牌（MCP contract 尚未接到新 WebGL hook）
struct HighlightTileTool: MCPTool {
    static let name = "highlight_tile"
    static let description = "⛔ MCP 手動高亮尚未接到 App 的 __nakiHighlight WebGL hook；推薦資料請用 bot_status / game_hand"
    static let inputSchema = MCPInputSchema(
        properties: [
            "tileIndex": .integer("（已無效）手牌索引"),
            "color": .string("（已無效）顏色名稱")
        ],
        required: []
    )

    private let context: MCPContext

    init(context: MCPContext) {
        self.context = context
    }

    func execute(arguments: [String: Any]) async throws -> Any {
        HighlightUnsupported.result()
    }
}

// MARK: - Reset Tile Color Tool

/// 重置手牌顏色（MCP contract 尚未接到新 WebGL hook）
struct ResetTileColorTool: MCPTool {
    static let name = "reset_tile_color"
    static let description = "⛔ MCP 手動重置尚未接到 App 的 __nakiHighlight.clear()"
    static let inputSchema = MCPInputSchema(
        properties: [
            "tileIndex": .integer("（已無效）手牌索引")
        ],
        required: []
    )

    private let context: MCPContext

    init(context: MCPContext) {
        self.context = context
    }

    func execute(arguments: [String: Any]) async throws -> Any {
        HighlightUnsupported.result()
    }
}

// MARK: - Highlight Status Tool

/// MCP 高亮狀態（contract 尚未接到新 WebGL hook）
struct HighlightStatusTool: MCPTool {
    static let name = "highlight_status"
    static let description = "⛔ MCP 手動高亮 contract 尚未實作；這不代表 App 內建 WebGL 高亮不存在"
    static let inputSchema = MCPInputSchema.empty

    private let context: MCPContext

    init(context: MCPContext) {
        self.context = context
    }

    func execute(arguments: [String: Any]) async throws -> Any {
        var result = HighlightUnsupported.result()
        // 舊呼叫端會讀 available；明確給 false，不要讓它 fallback 到 nil/未定義
        result["available"] = false
        return result
    }
}

// MARK: - Highlight Settings Tool

/// MCP 高亮設定（contract 尚未接到新 WebGL hook）
struct HighlightSettingsTool: MCPTool {
    static let name = "highlight_settings"
    static let description = "⛔ MCP 高亮設定尚未接到 App 的 __nakiHighlight WebGL hook"
    static let inputSchema = MCPInputSchema(
        properties: [
            "showTileColor": .boolean("（已無效）"),
            "showNativeEffect": .boolean("（已無效）"),
            "showRotatingEffect": .boolean("（已無效）")
        ],
        required: []
    )

    private let context: MCPContext

    init(context: MCPContext) {
        self.context = context
    }

    func execute(arguments: [String: Any]) async throws -> Any {
        HighlightUnsupported.result()
    }
}

// MARK: - Show Recommendations Tool

/// 顯示推薦高亮（MCP contract 尚未接到新 WebGL hook）
struct ShowRecommendationsTool: MCPTool {
    static let name = "show_recommendations"
    static let description = "⛔ MCP 批次高亮尚未接到 App 的 __nakiHighlight；推薦內容請用 bot_status / game_hand"
    static let inputSchema = MCPInputSchema(
        properties: [
            "recommendations": .string("（已無效）推薦列表 JSON")
        ],
        required: []
    )

    private let context: MCPContext

    init(context: MCPContext) {
        self.context = context
    }

    func execute(arguments: [String: Any]) async throws -> Any {
        HighlightUnsupported.result()
    }
}

// MARK: - Hide Highlight Tool

/// 隱藏高亮（MCP contract 尚未接到新 WebGL hook）
struct HideHighlightTool: MCPTool {
    static let name = "hide_highlight"
    static let description = "⛔ MCP hide contract 尚未接到 App 的 __nakiHighlight.clear()"
    static let inputSchema = MCPInputSchema.empty

    private let context: MCPContext

    init(context: MCPContext) {
        self.context = context
    }

    func execute(arguments: [String: Any]) async throws -> Any {
        HighlightUnsupported.result()
    }
}

#endif  // os(macOS)
