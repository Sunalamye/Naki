//
//  EmojiTools.swift
//  Naki
//
//  Created by Claude on 2025/12/06.
//  表情相關 MCP 工具
//

import Foundation
import MCPKit

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

// MARK: - Emoji Auto Reply Tool

/// 自動回應表情功能
struct EmojiAutoReplyTool: MCPTool {
    static let name = "game_emoji_auto_reply"
    static let description = "切換自動回應表情功能（預設開啟）。啟用後，當其他玩家發送表情時，會在 5 秒後以 50% 機率回應相同表情，並有 60 秒冷卻時間。5 秒內多人發表情只會回應一次"
    static let inputSchema = MCPInputSchema(
        properties: [
            "enabled": .boolean("是否啟用自動回應（不提供則返回當前狀態）")
        ],
        required: []
    )

    private let context: MCPContext

    init(context: MCPContext) {
        self.context = context
    }

    func execute(arguments: [String: Any]) async throws -> Any {
        let enabled = arguments["enabled"] as? Bool

        let script: String
        if let enabled = enabled {
            script = """
            (function() {
                if (!window.__nakiEmojiAutoReply) {
                    return JSON.stringify({ success: false, error: 'Emoji auto-reply module not loaded' });
                }

                if (\(enabled)) {
                    window.__nakiEmojiAutoReply.enable();
                } else {
                    window.__nakiEmojiAutoReply.disable();
                }

                return JSON.stringify(window.__nakiEmojiAutoReply.status());
            })();
            """
        } else {
            script = """
            (function() {
                if (!window.__nakiEmojiAutoReply) {
                    return JSON.stringify({ success: false, error: 'Emoji auto-reply module not loaded' });
                }
                return JSON.stringify(window.__nakiEmojiAutoReply.status());
            })();
            """
        }

        let result = try await context.executeJavaScript(script)

        if let jsonString = result as? String,
           let data = jsonString.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) {
            return json
        }
        return ["result": result ?? NSNull()]
    }
}

// MARK: - Emoji Listen Tool

/// 獲取收到的表情廣播記錄
struct EmojiListenTool: MCPTool {
    static let name = "game_emoji_listen"
    static let description = "獲取收到的表情廣播記錄（包含其他玩家發送的表情）。首次調用會自動啟用監聽，可透過 clear 參數清空記錄"
    static let inputSchema = MCPInputSchema(
        properties: [
            "clear": .boolean("是否清空記錄後返回 (預設 false)")
        ],
        required: []
    )

    private let context: MCPContext

    init(context: MCPContext) {
        self.context = context
    }

    func execute(arguments: [String: Any]) async throws -> Any {
        let clear = (arguments["clear"] as? Bool) ?? false

        let script = """
        (function() {
            // 確保監聽器已設置
            if (!window.__nakiEmojiListenerInstalled) {
                var netAgent = window.app?.NetAgent;
                var routeGroup = netAgent?.netRouteGroup_mj;
                var handlers = routeGroup?.notifyHander?.handlers;
                var originalHandler = handlers?.['.lq.NotifyGameBroadcast'];

                if (originalHandler && originalHandler[0] && !originalHandler[0].__nakiHooked) {
                    window.__nakiEmojiBroadcasts = [];
                    var origMethod = originalHandler[0].method;

                    originalHandler[0].method = function(data) {
                        // 記錄廣播
                        window.__nakiEmojiBroadcasts.push({
                            timestamp: Date.now(),
                            data: data
                        });

                        // 只保留最近 50 條
                        if (window.__nakiEmojiBroadcasts.length > 50) {
                            window.__nakiEmojiBroadcasts.shift();
                        }

                        // 調用原始方法
                        if (origMethod) {
                            origMethod.call(this, data);
                        }
                    };

                    originalHandler[0].__nakiHooked = true;
                    window.__nakiEmojiListenerInstalled = true;
                }
            }

            // 初始化記錄陣列
            if (!window.__nakiEmojiBroadcasts) {
                window.__nakiEmojiBroadcasts = [];
            }

            var broadcasts = window.__nakiEmojiBroadcasts;

            // 解析記錄
            var parsed = broadcasts.map(function(b) {
                var content = null;
                try {
                    content = JSON.parse(b.data.content);
                } catch(e) {}

                return {
                    timestamp: b.timestamp,
                    seat: b.data.seat,
                    emo_id: content ? content.emo : null
                };
            });

            var result = {
                success: true,
                listener_installed: !!window.__nakiEmojiListenerInstalled,
                count: parsed.length,
                broadcasts: parsed
            };

            // 清空記錄
            if (\(clear ? "true" : "false")) {
                window.__nakiEmojiBroadcasts = [];
                result.cleared = true;
            }

            return JSON.stringify(result);
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
