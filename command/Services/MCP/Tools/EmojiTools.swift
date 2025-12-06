//
//  EmojiTools.swift
//  Naki
//
//  Created by Claude on 2025/12/06.
//  表情相關 MCP 工具
//

import Foundation

// MARK: - Send Emoji Tool

/// 發送遊戲內表情
struct SendEmojiTool: MCPTool {
    static let name = "game_emoji"
    static let description = "在遊戲中發送表情。emo_id: 表情索引 (0-8)，可選 count 參數設定連續發送次數 (1-5)"
    static let inputSchema = MCPInputSchema(
        properties: [
            "emo_id": .integer("表情索引 (0-8)，對應當前角色的 9 個表情"),
            "count": .integer("連續發送次數 (1-5)，預設為 1")
        ],
        required: ["emo_id"]
    )

    private let context: MCPContext

    init(context: MCPContext) {
        self.context = context
    }

    func execute(arguments: [String: Any]) async throws -> Any {
        guard let emoId = arguments["emo_id"] as? Int else {
            throw MCPToolError.missingParameter("emo_id")
        }

        // 驗證 emo_id 範圍
        guard emoId >= 0 && emoId <= 8 else {
            throw MCPToolError.invalidParameter("emo_id", expected: "0-8")
        }

        // 獲取發送次數，預設為 1
        var count = (arguments["count"] as? Int) ?? 1
        count = max(1, min(5, count))  // 限制在 1-5 之間

        let script = """
        (function() {
            if (!window.app || !window.app.NetAgent) {
                return JSON.stringify({ success: false, error: 'NetAgent not available' });
            }

            var emoId = \(emoId);
            var count = \(count);
            var sent = 0;

            for (var i = 0; i < count; i++) {
                window.app.NetAgent.sendReq2MJ('FastTest', 'broadcastInGame', {
                    content: JSON.stringify({ emo: emoId }),
                    except_self: false
                }, function(err, res) {
                    sent++;
                });
            }

            return JSON.stringify({
                success: true,
                emo_id: emoId,
                count: count,
                message: '已發送 ' + count + ' 次表情 #' + emoId
            });
        })();
        """

        let result = try await context.executeJavaScript(script)

        // 解析 JSON 結果
        if let jsonString = result as? String,
           let data = jsonString.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) {
            return json
        }
        return ["result": result ?? NSNull()]
    }
}

// MARK: - List Emoji Tool

/// 獲取當前角色的表情列表
struct ListEmojiTool: MCPTool {
    static let name = "game_emoji_list"
    static let description = "獲取當前角色可用的表情列表"
    static let inputSchema = MCPInputSchema.empty

    private let context: MCPContext

    init(context: MCPContext) {
        self.context = context
    }

    func execute(arguments: [String: Any]) async throws -> Any {
        let script = """
        (function() {
            var emojiUI = window.uiscript?.UI_MJ_Emoji?.Inst;

            if (!emojiUI || !emojiUI.emos) {
                return JSON.stringify({
                    success: false,
                    error: 'Emoji UI not available (may not be in game)'
                });
            }

            var emos = emojiUI.emos.map(function(e, i) {
                return {
                    index: i,
                    sub_id: e.sub_id,
                    path: e.path
                };
            });

            var charId = null;
            if (emojiUI.emo_infos && emojiUI.emo_infos.char_id) {
                charId = emojiUI.emo_infos.char_id;
            } else if (emos.length > 0) {
                // 從 path 提取 char_id: "extendRes/emo/e200002/0.png"
                var match = emos[0].path.match(/e(\\d+)/);
                if (match) charId = parseInt(match[1]);
            }

            return JSON.stringify({
                success: true,
                char_id: charId,
                emoji_count: emos.length,
                emojis: emos
            });
        })();
        """

        let result = try await context.executeJavaScript(script)

        // 解析 JSON 結果
        if let jsonString = result as? String,
           let data = jsonString.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) {
            return json
        }
        return ["result": result ?? NSNull()]
    }
}
