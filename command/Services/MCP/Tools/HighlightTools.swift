//
//  HighlightTools.swift
//  Naki
//
//  Created by Claude on 2025/12/07.
//  手牌高亮 MCP 工具
//

import Foundation

// MARK: - Highlight Tile Tool

/// 高亮指定手牌（設置顏色）
struct HighlightTileTool: MCPTool {
    static let name = "highlight_tile"
    static let description = "高亮指定手牌。可設置顏色：green（綠色，推薦度高）、orange（橘色，推薦度中）、red（紅色，推薦度低）、white（白色，重置）。也可使用自定義 RGBA 顏色。"
    static let inputSchema = MCPInputSchema(
        properties: [
            "tileIndex": .integer("手牌索引 (0-13)"),
            "color": .string("顏色名稱: green/orange/red/white，或自定義 RGBA 如 '0.5,0.8,0.3,1'")
        ],
        required: ["tileIndex"]
    )

    private let context: MCPContext

    init(context: MCPContext) {
        self.context = context
    }

    func execute(arguments: [String: Any]) async throws -> Any {
        guard let tileIndex = arguments["tileIndex"] as? Int else {
            throw MCPToolError.missingParameter("tileIndex")
        }

        let colorName = arguments["color"] as? String ?? "green"

        // 解析顏色
        let colorScript: String
        if colorName.contains(",") {
            // 自定義 RGBA
            let parts = colorName.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            if parts.count >= 3 {
                let r = parts[0]
                let g = parts[1]
                let b = parts[2]
                let a = parts.count >= 4 ? parts[3] : 1.0
                colorScript = "{ r: \(r), g: \(g), b: \(b), a: \(a) }"
            } else {
                colorScript = "window.__nakiRecommendHighlight.colors.green"
            }
        } else {
            // 預設顏色名稱
            colorScript = "window.__nakiRecommendHighlight.colors.\(colorName) || window.__nakiRecommendHighlight.colors.green"
        }

        let script = """
        (function() {
            var highlight = window.__nakiRecommendHighlight;
            if (!highlight) return { success: false, error: '高亮模組未載入' };

            var color = \(colorScript);
            var result = highlight.setTileColor(\(tileIndex), color);

            return {
                success: result,
                tileIndex: \(tileIndex),
                color: '\(colorName)'
            };
        })()
        """

        let result = try await context.executeJavaScript(script)
        return result ?? ["success": false, "error": "執行失敗"]
    }
}

// MARK: - Reset Tile Color Tool

/// 重置手牌顏色
struct ResetTileColorTool: MCPTool {
    static let name = "reset_tile_color"
    static let description = "重置指定手牌的顏色為白色（原始顏色）。如果不指定索引，則重置所有手牌。"
    static let inputSchema = MCPInputSchema(
        properties: [
            "tileIndex": .integer("手牌索引 (0-13)，不指定則重置所有")
        ],
        required: []
    )

    private let context: MCPContext

    init(context: MCPContext) {
        self.context = context
    }

    func execute(arguments: [String: Any]) async throws -> Any {
        let tileIndex = arguments["tileIndex"] as? Int

        let script: String
        if let index = tileIndex {
            script = """
            (function() {
                var highlight = window.__nakiRecommendHighlight;
                if (!highlight) return { success: false, error: '高亮模組未載入' };

                var result = highlight.resetTileColor(\(index));
                return { success: result, tileIndex: \(index) };
            })()
            """
        } else {
            script = """
            (function() {
                var highlight = window.__nakiRecommendHighlight;
                if (!highlight) return { success: false, error: '高亮模組未載入' };

                highlight.resetAllTileColors();
                return { success: true, message: '已重置所有手牌顏色' };
            })()
            """
        }

        let result = try await context.executeJavaScript(script)
        return result ?? ["success": false, "error": "執行失敗"]
    }
}

// MARK: - Highlight Status Tool

/// 獲取高亮狀態
struct HighlightStatusTool: MCPTool {
    static let name = "highlight_status"
    static let description = "獲取當前高亮狀態，包括已高亮的牌、設定等"
    static let inputSchema = MCPInputSchema.empty

    private let context: MCPContext

    init(context: MCPContext) {
        self.context = context
    }

    func execute(arguments: [String: Any]) async throws -> Any {
        let script = """
        (function() {
            var highlight = window.__nakiRecommendHighlight;
            if (!highlight) return { available: false, error: '高亮模組未載入' };

            return {
                available: true,
                status: highlight.getStatus()
            };
        })()
        """

        let result = try await context.executeJavaScript(script)
        return result ?? ["available": false, "error": "執行失敗"]
    }
}

// MARK: - Highlight Settings Tool

/// 設置高亮選項
struct HighlightSettingsTool: MCPTool {
    static let name = "highlight_settings"
    static let description = "設置高亮選項。showTileColor: 是否使用牌顏色高亮；showNativeEffect: 是否顯示原生光暈效果；showRotatingEffect: 是否顯示旋轉效果"
    static let inputSchema = MCPInputSchema(
        properties: [
            "showTileColor": .boolean("是否使用牌顏色高亮（預設 true）"),
            "showNativeEffect": .boolean("是否顯示原生光暈效果（預設 true）"),
            "showRotatingEffect": .boolean("是否顯示旋轉效果（預設 false）")
        ],
        required: []
    )

    private let context: MCPContext

    init(context: MCPContext) {
        self.context = context
    }

    func execute(arguments: [String: Any]) async throws -> Any {
        var settingsObj: [String: Any] = [:]

        if let showTileColor = arguments["showTileColor"] as? Bool {
            settingsObj["showTileColor"] = showTileColor
        }
        if let showNativeEffect = arguments["showNativeEffect"] as? Bool {
            settingsObj["showNativeEffect"] = showNativeEffect
        }
        if let showRotatingEffect = arguments["showRotatingEffect"] as? Bool {
            settingsObj["showRotatingEffect"] = showRotatingEffect
        }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: settingsObj),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return ["success": false, "error": "無法序列化設定"]
        }

        let script = """
        (function() {
            var highlight = window.__nakiRecommendHighlight;
            if (!highlight) return { success: false, error: '高亮模組未載入' };

            highlight.setSettings(\(jsonString));
            return {
                success: true,
                settings: highlight.settings
            };
        })()
        """

        let result = try await context.executeJavaScript(script)
        return result ?? ["success": false, "error": "執行失敗"]
    }
}

// MARK: - Show Recommendations Tool

/// 顯示推薦高亮
struct ShowRecommendationsTool: MCPTool {
    static let name = "show_recommendations"
    static let description = "顯示多個推薦牌的高亮效果。根據機率自動選擇顏色：>50% 綠色、20-50% 橘色、<20% 紅色"
    static let inputSchema = MCPInputSchema(
        properties: [
            "recommendations": .string("推薦列表 JSON，格式: [{\"tileIndex\": 0, \"probability\": 0.8}, ...]")
        ],
        required: ["recommendations"]
    )

    private let context: MCPContext

    init(context: MCPContext) {
        self.context = context
    }

    func execute(arguments: [String: Any]) async throws -> Any {
        guard let recsString = arguments["recommendations"] as? String else {
            throw MCPToolError.missingParameter("recommendations")
        }

        let script = """
        (function() {
            var highlight = window.__nakiRecommendHighlight;
            if (!highlight) return { success: false, error: '高亮模組未載入' };

            var recs = \(recsString);
            var count = highlight.showMultiple(recs);
            return {
                success: count > 0,
                highlightedCount: count,
                status: highlight.getStatus()
            };
        })()
        """

        let result = try await context.executeJavaScript(script)
        return result ?? ["success": false, "error": "執行失敗"]
    }
}

// MARK: - Hide Highlight Tool

/// 隱藏所有高亮
struct HideHighlightTool: MCPTool {
    static let name = "hide_highlight"
    static let description = "隱藏所有高亮效果，重置所有手牌顏色"
    static let inputSchema = MCPInputSchema.empty

    private let context: MCPContext

    init(context: MCPContext) {
        self.context = context
    }

    func execute(arguments: [String: Any]) async throws -> Any {
        let script = """
        (function() {
            var highlight = window.__nakiRecommendHighlight;
            if (!highlight) return { success: false, error: '高亮模組未載入' };

            var result = highlight.hide();
            return { success: result };
        })()
        """

        let result = try await context.executeJavaScript(script)
        return result ?? ["success": false, "error": "執行失敗"]
    }
}
