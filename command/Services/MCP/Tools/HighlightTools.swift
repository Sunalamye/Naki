//
//  HighlightTools.swift
//  Naki
//
//  Created by Claude on 2025/12/07.
//  Updated 2026-07-31：Unity 遷移，整檔改為明確失敗。
//
//  為什麼全部失效：高亮實作是 `window.__nakiRecommendHighlight`，它對 Laya 場景圖動手——
//  取 `view.DesktopMgr.Inst.mainrole.hand[i]` 的牌 sprite 改 `material.color`，
//  並 clone `effect_doraPlane` 做光暈。Unity WebGL 客戶端把整個渲染搬進 wasm，
//  JS 端只看得到一張 `<canvas id="unity-canvas">`，**沒有任何 per-tile 物件可改**。
//  （實測見 docs/majsoul-unity-protocol.md）
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

import Foundation
import MCPKit

// MARK: - 共用失敗訊息

/// 高亮類工具的共用失敗說明
private enum HighlightUnsupported {
    static let reason = """
        unity-client: 手牌高亮依賴 Laya 場景圖（view.DesktopMgr.Inst.mainrole.hand 的牌 sprite \
        與 effect_doraPlane 特效），雀魂改用 Unity WebGL 後渲染全在 wasm 內，\
        JS 端只有單一 <canvas>，無法注入或修改任何牌面物件。
        """
    static let alternative = """
        改用 Naki 原生推薦面板（RecommendationView，App 視窗內顯示 AI 推薦與機率）；\
        程式化取得同樣資訊請用 bot_status / game_hand。
        """

    static func result() -> [String: Any] {
        NakiUnsupported.result(reason: reason, alternative: alternative)
    }
}

// MARK: - Highlight Tile Tool

/// 高亮指定手牌（Unity 下不可行）
struct HighlightTileTool: MCPTool {
    static let name = "highlight_tile"
    static let description = "⛔ Unity 客戶端不可用：手牌高亮需要修改 Laya 牌面物件，Unity WebGL 下不存在。改用 Naki 原生推薦面板 / bot_status"
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

/// 重置手牌顏色（Unity 下不可行）
struct ResetTileColorTool: MCPTool {
    static let name = "reset_tile_color"
    static let description = "⛔ Unity 客戶端不可用：沒有可修改的牌面物件，也就沒有顏色需要重置"
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

/// 高亮狀態（Unity 下永遠不可用）
struct HighlightStatusTool: MCPTool {
    static let name = "highlight_status"
    static let description = "⛔ Unity 客戶端不可用：高亮模組沒有可操作對象，狀態恆為不可用"
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

/// 高亮設定（Unity 下不可行）
struct HighlightSettingsTool: MCPTool {
    static let name = "highlight_settings"
    static let description = "⛔ Unity 客戶端不可用：沒有可套用設定的高亮模組"
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

/// 顯示推薦高亮（Unity 下不可行）
struct ShowRecommendationsTool: MCPTool {
    static let name = "show_recommendations"
    static let description = "⛔ Unity 客戶端不可用：無法在遊戲畫面上疊加推薦高亮。推薦內容請用 bot_status / game_hand 取得，畫面顯示改看 Naki 原生推薦面板"
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

/// 隱藏高亮（Unity 下不可行）
struct HideHighlightTool: MCPTool {
    static let name = "hide_highlight"
    static let description = "⛔ Unity 客戶端不可用：沒有高亮存在，也就沒有東西可隱藏"
    static let inputSchema = MCPInputSchema.empty

    private let context: MCPContext

    init(context: MCPContext) {
        self.context = context
    }

    func execute(arguments: [String: Any]) async throws -> Any {
        HighlightUnsupported.result()
    }
}
