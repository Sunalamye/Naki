//
//  UITools.swift
//  Naki
//
//  Created by Claude on 2025/12/05.
//  UI 操作類 MCP 工具
//

import Foundation
import MCPKit

// MARK: - Execute JS Tool

/// 執行 JavaScript
struct ExecuteJSTool: MCPTool {
    static let name = "execute_js"
    static let description = "在遊戲 WebView 中執行 JavaScript 代碼。⚠️ 重要：必須使用 return 語句才能獲取返回值！例如：'return 1+1' 返回 2，'return document.title' 返回標題。返回 Object 時使用 JSON.stringify()。"
    static let inputSchema = MCPInputSchema(
        properties: [
            "code": .string("要執行的 JavaScript 代碼（函數體格式，需要 return 語句才能獲取返回值）")
        ],
        required: ["code"]
    )

    private let context: MCPContext

    init(context: MCPContext) {
        self.context = context
    }

    func execute(arguments: [String: Any]) async throws -> Any {
        guard let code = arguments["code"] as? String, !code.isEmpty else {
            throw MCPToolError.missingParameter("code")
        }

        let result = try await context.executeJavaScript(code)
        return ["result": result ?? NSNull()]
    }
}

// MARK: - Detect Tool

/// 檢測遊戲 API
struct DetectTool: MCPTool {
    static let name = "detect"
    static let description = "檢測遊戲 API 是否可用"
    static let inputSchema = MCPInputSchema.empty

    private let context: MCPContext

    init(context: MCPContext) {
        self.context = context
    }

    func execute(arguments: [String: Any]) async throws -> Any {
        let script = "window.__nakiDetectGameAPI ? __nakiDetectGameAPI() : {error: 'Not loaded'}"
        let result = try await context.executeJavaScript(script)
        return ["result": result ?? NSNull()]
    }
}

// MARK: - Explore Tool

/// 探索遊戲物件
struct ExploreTool: MCPTool {
    static let name = "explore"
    static let description = "探索遊戲物件結構"
    static let inputSchema = MCPInputSchema.empty

    private let context: MCPContext

    init(context: MCPContext) {
        self.context = context
    }

    func execute(arguments: [String: Any]) async throws -> Any {
        let script = "window.__nakiExploreGameObjects ? __nakiExploreGameObjects() : {error: 'Not loaded'}"
        let result = try await context.executeJavaScript(script)
        return ["result": result ?? NSNull()]
    }
}

// MARK: - Test Indicators Tool

/// 顯示測試指示器
struct TestIndicatorsTool: MCPTool {
    static let name = "test_indicators"
    static let description = "顯示測試指示器（用於調試點擊位置）"
    static let inputSchema = MCPInputSchema.empty

    private let context: MCPContext

    init(context: MCPContext) {
        self.context = context
    }

    func execute(arguments: [String: Any]) async throws -> Any {
        let script = "window.__nakiTestIndicators ? (__nakiTestIndicators(), 'OK') : 'Not loaded'"
        let result = try await context.executeJavaScript(script)
        return ["result": result ?? NSNull()]
    }
}

// MARK: - Click Tool

/// 在指定座標點擊
struct ClickTool: MCPTool {
    static let name = "click"
    static let description = "在指定座標點擊"
    static let inputSchema = MCPInputSchema(
        properties: [
            "x": .number("X 座標"),
            "y": .number("Y 座標"),
            "label": .string("點擊標籤（可選）")
        ],
        required: ["x", "y"]
    )

    private let context: MCPContext

    init(context: MCPContext) {
        self.context = context
    }

    func execute(arguments: [String: Any]) async throws -> Any {
        guard let x = arguments["x"] as? Double else {
            throw MCPToolError.missingParameter("x")
        }
        guard let y = arguments["y"] as? Double else {
            throw MCPToolError.missingParameter("y")
        }

        let label = arguments["label"] as? String ?? "MCP Click"
        let script = "window.__nakiAutoPlay.click(\(x), \(y), '\(label)')"
        _ = try await context.executeJavaScript(script)

        return [
            "result": "clicked",
            "x": x,
            "y": y
        ]
    }
}

// MARK: - Calibrate Tool

/// 設定校準參數
struct CalibrateTool: MCPTool {
    static let name = "calibrate"
    static let description = "設定校準參數"
    static let inputSchema = MCPInputSchema(
        properties: [
            "tileSpacing": .number("牌間距（默認 96）"),
            "offsetX": .number("X 偏移（默認 -200）"),
            "offsetY": .number("Y 偏移（默認 0）")
        ],
        required: []
    )

    private let context: MCPContext

    init(context: MCPContext) {
        self.context = context
    }

    func execute(arguments: [String: Any]) async throws -> Any {
        let tileSpacing = arguments["tileSpacing"] as? Double ?? 96
        let offsetX = arguments["offsetX"] as? Double ?? -200
        let offsetY = arguments["offsetY"] as? Double ?? 0

        let script = """
        if (window.__nakiAutoPlay) {
            window.__nakiAutoPlay.calibration = {
                tileSpacing: \(tileSpacing),
                offsetX: \(offsetX),
                offsetY: \(offsetY)
            };
            JSON.stringify(window.__nakiAutoPlay.calibration);
        } else {
            'Not loaded';
        }
        """
        _ = try await context.executeJavaScript(script)

        return [
            "result": "calibrated",
            "tileSpacing": tileSpacing,
            "offsetX": offsetX,
            "offsetY": offsetY
        ]
    }
}

// MARK: - UI Name Status Tool

/// 獲取玩家名稱狀態
struct UINameStatusTool: MCPTool {
    static let name = "ui_names_status"
    static let description = "獲取玩家名稱的顯示狀態"
    static let inputSchema = MCPInputSchema.empty

    private let context: MCPContext

    init(context: MCPContext) {
        self.context = context
    }

    func execute(arguments: [String: Any]) async throws -> Any {
        let script = "JSON.stringify(window.__nakiPlayerNames?.getStatus() || {available: false})"
        let result = try await context.executeJavaScript(script)

        // 嘗試解析 JSON
        if let jsonString = result as? String,
           let data = jsonString.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) {
            return json
        }
        return ["result": result ?? NSNull()]
    }
}

// MARK: - UI Name Hide Tool

/// 隱藏玩家名稱
struct UINameHideTool: MCPTool {
    static let name = "ui_names_hide"
    static let description = "隱藏所有玩家名稱"
    static let inputSchema = MCPInputSchema.empty

    private let context: MCPContext

    init(context: MCPContext) {
        self.context = context
    }

    func execute(arguments: [String: Any]) async throws -> Any {
        let script = "window.__nakiPlayerNames?.hide() || false"
        let result = try await context.executeJavaScript(script)
        let success = result as? Bool ?? false

        return [
            "success": success,
            "hidden": true
        ]
    }
}

// MARK: - UI Name Show Tool

/// 顯示玩家名稱
struct UINameShowTool: MCPTool {
    static let name = "ui_names_show"
    static let description = "顯示所有玩家名稱"
    static let inputSchema = MCPInputSchema.empty

    private let context: MCPContext

    init(context: MCPContext) {
        self.context = context
    }

    func execute(arguments: [String: Any]) async throws -> Any {
        let script = "window.__nakiPlayerNames?.show() || false"
        let result = try await context.executeJavaScript(script)
        let success = result as? Bool ?? false

        return [
            "success": success,
            "hidden": false
        ]
    }
}

// MARK: - UI Name Toggle Tool

/// 切換玩家名稱顯示
struct UINameToggleTool: MCPTool {
    static let name = "ui_names_toggle"
    static let description = "切換玩家名稱的顯示狀態"
    static let inputSchema = MCPInputSchema.empty

    private let context: MCPContext

    init(context: MCPContext) {
        self.context = context
    }

    func execute(arguments: [String: Any]) async throws -> Any {
        // 先 toggle
        let toggleScript = "window.__nakiPlayerNames?.toggle() || false"
        let toggleResult = try await context.executeJavaScript(toggleScript)
        let success = toggleResult as? Bool ?? false

        // 再獲取當前狀態
        let statusScript = "window.__nakiPlayerNames?.hidden || false"
        let statusResult = try await context.executeJavaScript(statusScript)
        let hidden = statusResult as? Bool ?? false

        return [
            "success": success,
            "hidden": hidden
        ]
    }
}
