//
//  LobbyTools.swift
//  Naki
//
//  Created by Claude on 2025/12/06.
//  大廳相關 MCP 工具 - 自動開始遊戲功能
//

import Foundation

// MARK: - Lobby Status Tool

/// 獲取大廳狀態
struct LobbyStatusTool: MCPTool {
    static let name = "lobby_status"
    static let description = "獲取大廳狀態，包含當前頁面、匹配狀態、帳號等級等信息"
    static let inputSchema = MCPInputSchema.empty

    private let context: MCPContext

    init(context: MCPContext) {
        self.context = context
    }

    func execute(arguments: [String: Any]) async throws -> Any {
        let script = """
        (function() {
            var gm = window.GameMgr;
            if (!gm || !gm.Inst) return JSON.stringify({error: "GameMgr not available"});

            var uimgr = gm.Inst.uimgr;
            var lobby = uimgr ? uimgr._ui_lobby : null;
            var matchUI = uimgr ? uimgr._uis[105] : null;
            var account = gm.Inst.account_data;

            var result = {
                inLobby: !!lobby,
                nowpage: lobby ? lobby.nowpage : -1,
                locking: lobby ? lobby.locking : false,
                matching: {
                    available: !!matchUI,
                    inopen: matchUI ? matchUI.inopen : false,
                    current_count: matchUI ? matchUI.current_count : 0,
                    cells: []
                },
                account: null
            };

            // 匹配隊列信息
            if (matchUI && matchUI.cells) {
                for (var i = 0; i < matchUI.cells.length; i++) {
                    var cell = matchUI.cells[i];
                    if (cell && cell.match_id) {
                        result.matching.cells.push({
                            index: i,
                            match_id: cell.match_id,
                            match_mode: cell.match_mode || 0
                        });
                    }
                }
            }

            // 帳號信息
            if (account) {
                var level = account.level || {};
                result.account = {
                    nickname: account.nickname || "",
                    level_id: level.id || 0,
                    level_score: level.score || 0
                };
            }

            return JSON.stringify(result);
        })()
        """

        let result = try await context.executeJavaScript("return " + script)

        if let jsonString = result as? String,
           let data = jsonString.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) {
            return json
        }
        return ["result": result ?? NSNull()]
    }
}

// MARK: - Match Mode List Tool

/// 獲取可用的匹配模式列表
struct MatchModeListTool: MCPTool {
    static let name = "lobby_match_modes"
    static let description = "獲取所有可用的匹配模式列表，包含段位場信息和級別限制"
    static let inputSchema = MCPInputSchema.empty

    private let context: MCPContext

    init(context: MCPContext) {
        self.context = context
    }

    func execute(arguments: [String: Any]) async throws -> Any {
        // 返回靜態的匹配模式對照表
        let modes: [[String: Any]] = [
            ["id": 1, "room": "銅之間", "type": "東風", "minLevel": 0, "description": "銅之間 - 東風戰"],
            ["id": 2, "room": "銅之間", "type": "半莊", "minLevel": 0, "description": "銅之間 - 半莊戰"],
            ["id": 4, "room": "銀之間", "type": "東風", "minLevel": 10200, "description": "銀之間 - 東風戰"],
            ["id": 5, "room": "銀之間", "type": "半莊", "minLevel": 10200, "description": "銀之間 - 半莊戰"],
            ["id": 7, "room": "金之間", "type": "東風", "minLevel": 10300, "description": "金之間 - 東風戰"],
            ["id": 8, "room": "金之間", "type": "半莊", "minLevel": 10300, "description": "金之間 - 半莊戰"],
            ["id": 10, "room": "玉之間", "type": "東風", "minLevel": 10400, "description": "玉之間 - 東風戰"],
            ["id": 11, "room": "玉之間", "type": "半莊", "minLevel": 10400, "description": "玉之間 - 半莊戰"],
            ["id": 13, "room": "王座之間", "type": "東風", "minLevel": 10501, "description": "王座之間 - 東風戰"],
            ["id": 14, "room": "王座之間", "type": "半莊", "minLevel": 10501, "description": "王座之間 - 半莊戰"]
        ]

        return [
            "modes": modes,
            "levelEncoding": [
                "10xxx": "四麻 (4-player)",
                "20xxx": "三麻 (3-player)",
                "x01xx": "初心",
                "x02xx": "雀士",
                "x03xx": "雀傑",
                "x04xx": "雀豪",
                "x05xx": "雀聖",
                "x06xx": "魂天"
            ]
        ]
    }
}

// MARK: - Start Match Tool

/// 開始匹配
struct StartMatchTool: MCPTool {
    static let name = "lobby_start_match"
    static let description = "開始段位場匹配。match_mode: 1=銅東, 2=銅半, 4=銀東, 5=銀半, 7=金東, 8=金半, 10=玉東, 11=玉半, 13=王座東, 14=王座半"
    static let inputSchema = MCPInputSchema(
        properties: [
            "match_mode": .integer("匹配模式 ID (1=銅東, 2=銅半, 4=銀東, 5=銀半, 7=金東, 8=金半, 10=玉東, 11=玉半, 13=王座東, 14=王座半)")
        ],
        required: ["match_mode"]
    )

    private let context: MCPContext

    init(context: MCPContext) {
        self.context = context
    }

    func execute(arguments: [String: Any]) async throws -> Any {
        guard let matchMode = arguments["match_mode"] as? Int else {
            throw MCPToolError.missingParameter("match_mode")
        }

        // 驗證 match_mode 是否有效
        let validModes = [1, 2, 4, 5, 7, 8, 10, 11, 13, 14]
        guard validModes.contains(matchMode) else {
            throw MCPToolError.invalidParameter("match_mode", expected: "1, 2, 4, 5, 7, 8, 10, 11, 13, 14")
        }

        let script = """
        (function() {
            var gm = window.GameMgr;
            if (!gm || !gm.Inst) return JSON.stringify({success: false, error: "GameMgr not available"});

            var matchUI = gm.Inst.uimgr._uis[105];
            if (!matchUI) return JSON.stringify({success: false, error: "Match UI not available"});

            // 檢查是否已在匹配中
            if (matchUI.inopen) {
                return JSON.stringify({success: false, error: "Already matching", current_count: matchUI.current_count});
            }

            // 開始匹配
            matchUI.addMatch(\(matchMode));

            // 驗證結果
            var result = {
                success: matchUI.current_count >= 1,
                inopen: matchUI.inopen,
                current_count: matchUI.current_count,
                match_mode: \(matchMode)
            };

            return JSON.stringify(result);
        })()
        """

        let result = try await context.executeJavaScript("return " + script)

        if let jsonString = result as? String,
           let data = jsonString.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {

            // 記錄日誌
            let success = json["success"] as? Bool ?? false
            if success {
                context.log("🎮 Started matching with mode \(matchMode)")
            } else {
                let error = json["error"] as? String ?? "Unknown error"
                context.log("❌ Failed to start match: \(error)")
            }

            return json
        }
        return ["success": false, "error": "Failed to parse result"]
    }
}

// MARK: - Cancel Match Tool

/// 取消匹配
struct CancelMatchTool: MCPTool {
    static let name = "lobby_cancel_match"
    static let description = "取消當前的段位場匹配"
    static let inputSchema = MCPInputSchema.empty

    private let context: MCPContext

    init(context: MCPContext) {
        self.context = context
    }

    func execute(arguments: [String: Any]) async throws -> Any {
        let script = """
        (function() {
            var gm = window.GameMgr;
            if (!gm || !gm.Inst) return JSON.stringify({success: false, error: "GameMgr not available"});

            var matchUI = gm.Inst.uimgr._uis[105];
            if (!matchUI) return JSON.stringify({success: false, error: "Match UI not available"});

            // 檢查是否在匹配中
            if (!matchUI.inopen && matchUI.current_count === 0) {
                return JSON.stringify({success: false, error: "Not currently matching"});
            }

            // 取消匹配
            matchUI.cancelPiPei();

            // 驗證結果
            var result = {
                success: true,
                inopen: matchUI.inopen,
                current_count: matchUI.current_count
            };

            return JSON.stringify(result);
        })()
        """

        let result = try await context.executeJavaScript("return " + script)

        if let jsonString = result as? String,
           let data = jsonString.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {

            let success = json["success"] as? Bool ?? false
            if success {
                context.log("⏹️ Cancelled matching")
            }

            return json
        }
        return ["success": false, "error": "Failed to parse result"]
    }
}

// MARK: - Match Status Tool

/// 獲取當前匹配狀態
struct MatchStatusTool: MCPTool {
    static let name = "lobby_match_status"
    static let description = "獲取當前匹配狀態，包含是否在匹配中、隊列數量等信息"
    static let inputSchema = MCPInputSchema.empty

    private let context: MCPContext

    init(context: MCPContext) {
        self.context = context
    }

    func execute(arguments: [String: Any]) async throws -> Any {
        let script = """
        (function() {
            var gm = window.GameMgr;
            if (!gm || !gm.Inst) return JSON.stringify({available: false, error: "GameMgr not available"});

            var matchUI = gm.Inst.uimgr._uis[105];
            if (!matchUI) return JSON.stringify({available: false, error: "Match UI not available"});

            var result = {
                available: true,
                inopen: matchUI.inopen,
                current_count: matchUI.current_count,
                queues: []
            };

            // 獲取隊列詳情
            if (matchUI.cells) {
                for (var i = 0; i < matchUI.cells.length; i++) {
                    var cell = matchUI.cells[i];
                    if (cell && cell.match_id) {
                        result.queues.push({
                            index: i,
                            match_id: cell.match_id,
                            match_mode: cell.match_mode || 0
                        });
                    }
                }
            }

            return JSON.stringify(result);
        })()
        """

        let result = try await context.executeJavaScript("return " + script)

        if let jsonString = result as? String,
           let data = jsonString.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) {
            return json
        }
        return ["available": false, "error": "Failed to parse result"]
    }
}

// MARK: - Navigate Lobby Tool

/// 導航到大廳頁面
struct NavigateLobbyTool: MCPTool {
    static let name = "lobby_navigate"
    static let description = "導航到大廳的指定頁面。page: 0=主頁, 1=段位場, 2=友人場, 3=比賽場"
    static let inputSchema = MCPInputSchema(
        properties: [
            "page": .integer("頁面索引 (0=主頁, 1=段位場, 2=友人場, 3=比賽場)")
        ],
        required: ["page"]
    )

    private let context: MCPContext

    init(context: MCPContext) {
        self.context = context
    }

    func execute(arguments: [String: Any]) async throws -> Any {
        guard let page = arguments["page"] as? Int else {
            throw MCPToolError.missingParameter("page")
        }

        // 驗證頁面索引
        guard page >= 0 && page <= 3 else {
            throw MCPToolError.invalidParameter("page", expected: "0-3")
        }

        let pageNames = ["主頁", "段位場", "友人場", "比賽場"]

        let script = """
        (function() {
            var gm = window.GameMgr;
            if (!gm || !gm.Inst) return JSON.stringify({success: false, error: "GameMgr not available"});

            var lobby = gm.Inst.uimgr._ui_lobby;
            if (!lobby) return JSON.stringify({success: false, error: "Lobby UI not available"});

            var prevPage = lobby.nowpage;
            lobby.setPage(\(page));

            return JSON.stringify({
                success: true,
                previousPage: prevPage,
                currentPage: lobby.nowpage
            });
        })()
        """

        let result = try await context.executeJavaScript("return " + script)

        if let jsonString = result as? String,
           let data = jsonString.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {

            let success = json["success"] as? Bool ?? false
            if success {
                context.log("📍 Navigated to \(pageNames[page])")
            }

            return json
        }
        return ["success": false, "error": "Failed to parse result"]
    }
}

// MARK: - Heartbeat Tool

/// 發送心跳防止閒置登出
struct HeartbeatTool: MCPTool {
    static let name = "lobby_heartbeat"
    static let description = "發送心跳信號防止閒置自動登出。遊戲會在閒置 50 分鐘後彈出警告，可定期調用此工具保持活躍"
    static let inputSchema = MCPInputSchema.empty

    private let context: MCPContext

    init(context: MCPContext) {
        self.context = context
    }

    func execute(arguments: [String: Any]) async throws -> Any {
        let script = """
        (function() {
            var gm = window.GameMgr;
            if (!gm || !gm.Inst) return JSON.stringify({success: false, error: "GameMgr not available"});

            var inst = gm.Inst;

            // 記錄心跳前的時間
            var beforeTime = inst._last_heatbeat_time;

            // 調用心跳函數
            if (typeof inst.clientHeatBeat === 'function') {
                inst.clientHeatBeat();
            } else {
                return JSON.stringify({success: false, error: "clientHeatBeat function not found"});
            }

            // 記錄心跳後的時間
            var afterTime = inst._last_heatbeat_time;
            var now = Date.now();

            return JSON.stringify({
                success: true,
                previousHeartbeat: beforeTime,
                currentHeartbeat: afterTime,
                updated: beforeTime !== afterTime,
                serverTime: now,
                message: "Heartbeat sent successfully"
            });
        })()
        """

        let result = try await context.executeJavaScript("return " + script)

        if let jsonString = result as? String,
           let data = jsonString.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {

            let success = json["success"] as? Bool ?? false
            if success {
                context.log("💓 Heartbeat sent")
            }

            return json
        }
        return ["success": false, "error": "Failed to parse result"]
    }
}

// MARK: - Idle Status Tool

/// 獲取閒置狀態
struct IdleStatusTool: MCPTool {
    static let name = "lobby_idle_status"
    static let description = "獲取當前的閒置狀態，包含距離上次心跳的時間、閒置警告閾值等信息"
    static let inputSchema = MCPInputSchema.empty

    private let context: MCPContext

    init(context: MCPContext) {
        self.context = context
    }

    func execute(arguments: [String: Any]) async throws -> Any {
        let script = """
        (function() {
            var gm = window.GameMgr;
            if (!gm || !gm.Inst) return JSON.stringify({available: false, error: "GameMgr not available"});

            var inst = gm.Inst;
            var now = Date.now();

            // 計算閒置時間
            var lastHeartbeat = inst._last_heatbeat_time || 0;
            var idleSeconds = Math.floor((now - lastHeartbeat) / 1000);

            // 閒置檢測配置（從 360 秒定時器代碼分析得出）
            var warnThreshold = 3000;  // 50 分鐘後顯示警告
            var checkInterval = 360;    // 每 6 分鐘檢查一次

            // 檢查警告 UI 是否顯示
            var hangupWarnVisible = false;
            var hangupLogoutVisible = false;

            try {
                if (window.uiscript && window.uiscript.UI_Hangup_Warn && window.uiscript.UI_Hangup_Warn.Inst) {
                    hangupWarnVisible = window.uiscript.UI_Hangup_Warn.Inst.me && window.uiscript.UI_Hangup_Warn.Inst.me.visible;
                }
                if (window.uiscript && window.uiscript.UI_Hanguplogout && window.uiscript.UI_Hanguplogout.Inst) {
                    hangupLogoutVisible = window.uiscript.UI_Hanguplogout.Inst.me && window.uiscript.UI_Hanguplogout.Inst.me.visible;
                }
            } catch(e) {}

            return JSON.stringify({
                available: true,
                lastHeartbeat: lastHeartbeat,
                lastHeartbeatISO: new Date(lastHeartbeat).toISOString(),
                idleSeconds: idleSeconds,
                idleMinutes: Math.floor(idleSeconds / 60),
                warnThreshold: warnThreshold,
                warnThresholdMinutes: Math.floor(warnThreshold / 60),
                checkInterval: checkInterval,
                timeUntilWarn: Math.max(0, warnThreshold - idleSeconds),
                timeUntilWarnMinutes: Math.max(0, Math.floor((warnThreshold - idleSeconds) / 60)),
                hangupWarnVisible: hangupWarnVisible,
                hangupLogoutVisible: hangupLogoutVisible,
                recommendation: idleSeconds > 2400 ? "建議立即發送心跳" : (idleSeconds > 1800 ? "建議在 10 分鐘內發送心跳" : "狀態正常")
            });
        })()
        """

        let result = try await context.executeJavaScript("return " + script)

        if let jsonString = result as? String,
           let data = jsonString.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) {
            return json
        }
        return ["available": false, "error": "Failed to parse result"]
    }
}

// MARK: - Account Level Tool

/// 獲取帳號等級信息
struct AccountLevelTool: MCPTool {
    static let name = "lobby_account_level"
    static let description = "獲取當前帳號的段位等級信息"
    static let inputSchema = MCPInputSchema.empty

    private let context: MCPContext

    init(context: MCPContext) {
        self.context = context
    }

    func execute(arguments: [String: Any]) async throws -> Any {
        let script = """
        (function() {
            var gm = window.GameMgr;
            if (!gm || !gm.Inst) return JSON.stringify({available: false, error: "GameMgr not available"});

            var account = gm.Inst.account_data;
            if (!account) return JSON.stringify({available: false, error: "Account data not available"});

            var level = account.level || {};
            var level3 = account.level3 || {};

            // 解析段位
            function parseLevel(id) {
                if (!id) return null;
                var mode = Math.floor(id / 10000);  // 1=四麻, 2=三麻
                var rank = Math.floor((id % 10000) / 100);  // 1=初心, 2=雀士, ...
                var tier = id % 100;  // 段位內等級

                var rankNames = {1: "初心", 2: "雀士", 3: "雀傑", 4: "雀豪", 5: "雀聖", 6: "魂天"};

                return {
                    id: id,
                    mode: mode === 1 ? "四麻" : "三麻",
                    rank: rankNames[rank] || "unknown",
                    tier: tier,
                    displayName: rankNames[rank] + " " + tier + " 段"
                };
            }

            return JSON.stringify({
                available: true,
                nickname: account.nickname || "",
                level4p: parseLevel(level.id),
                level3p: parseLevel(level3.id),
                score4p: level.score || 0,
                score3p: level3.score || 0
            });
        })()
        """

        let result = try await context.executeJavaScript("return " + script)

        if let jsonString = result as? String,
           let data = jsonString.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) {
            return json
        }
        return ["available": false, "error": "Failed to parse result"]
    }
}
