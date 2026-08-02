//
//  SystemTools.swift
//  Naki
//
//  Created by Claude on 2025/12/05.
//  系統類 MCP 工具
//

#if os(macOS)

import Foundation
import MCPKit

// MARK: - Get Status Tool

/// 獲取 MCP Server 狀態
struct GetStatusTool: MCPTool {
    static let name = "get_status"
    static let description = "獲取 MCP Server 狀態和埠號"
    static let inputSchema = MCPInputSchema.empty

    private let context: MCPContext

    init(context: MCPContext) {
        self.context = context
    }

    func execute(arguments: [String: Any]) async throws -> Any {
        // JS 注入失敗是「所有其他欄位都不可信」的前置條件，所以放在 status 裡，
        // 而不是等使用者自己去翻 log。沒有 fallback 攔截器可以掩蓋這件事。
        let injection = await JSInjectionState.shared.report

        // 帶上檔案日誌路徑：`/logs` 只回記憶體裡的近期條目，跨重啟或回查上一局要直接讀檔。
        var payload: [String: Any] = [
            "status": "running",
            "port": context.serverPort,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            // 每次啟動一個獨立目錄；要回報問題就整包送出，不必挑檔案
            "logDir": await LogManager.shared.logDirectory.path,
            "logFile": await LogManager.shared.logFilePath,
            "logFileNote": "合併日誌（不含解析細節）。每次啟動一個 <timestamp> 目錄，"
                + "同一層的其他目錄是前幾次執行（保留 8 次）",
            // 查「剛剛發生什麼」看這個——只有對局事件，一行一件
            "eventLog": await LogManager.shared.eventLogPath,
            "categoryLogs": await LogManager.shared.categoryLogPaths
        ]
        payload.merge(injection.statusPayload) { _, new in new }
        return payload
    }
}

// MARK: - Get Help Tool

/// 獲取 API 文檔
///
/// 說明文字以 2026-08-01 的 live `tools/list`、Unity probe 與現行程式為準。
struct GetHelpTool: MCPTool {
    static let name = "get_help"
    static let description = "獲取完整的 API 文檔（JSON 格式），含 Unity 架構下的工具分層與注意事項"
    static let inputSchema = MCPInputSchema.empty

    private let context: MCPContext

    init(context: MCPContext) {
        self.context = context
    }

    func execute(arguments: [String: Any]) async throws -> Any {
        return NakiHelpContent.build(serverPort: context.serverPort)
    }
}

// MARK: - Help 內容

/// `get_help` 與 `MCPHandler.buildHelpContent()` 共用的說明內容（避免兩邊不同步）
enum NakiHelpContent {

    static func build(serverPort: UInt16) -> [String: Any] {
        [
            "name": "Naki Debug API",
            "version": "3.1",
            "description": "Naki 麻將 AI 助手的 Debug / MCP API。"
                + "雀魂客戶端已從 Laya 改為 Unity WebGL，所有遊戲狀態與動作改走 Liqi protobuf 協定層。",
            "base_url": "http://localhost:\(serverPort)",
            "mcp_endpoint": "http://localhost:\(serverPort)/mcp",
            "tools_count": MCPToolRegistry.shared.registeredToolNames.count,
            "architecture": [
                "client": "Unity WebGL（chs_t-WebGL-release-4.0.45(45)）——window.Laya / GameMgr / uiscript / view.DesktopMgr / cfg 全部不存在",
                "state": "狀態類工具（game_state / game_hand / game_ops / bot_*）讀 Swift 協定層："
                    + "WebSocket 攔截 → LiqiParser → MajsoulBridge → NativeBotController / LiqiOperationStore",
                "action": "動作類工具（game_action / game_discard / bot_chi / bot_pon / room_* / lobby_*）"
                    + "組 Liqi REQUEST 經 window.__nakiWebSocket.sendRaw 送出（msgId 使用 60000+ 號段）",
                "highlight": "App 內建 __nakiHighlight 會攔截 WebGL draw 做自動推薦染色；"
                    + "6 個 MCP 手動 highlight_* 工具尚未接到這個新 hook，仍回明確 unavailable"
            ],
            "workflows": [
                "友人房一條龍": ["room_create（time_fixed=300, time_add=0）", "room_add_robot ×3", "room_start"],
                "段位場": ["lobby_match_modes", "lobby_start_match", "（要取消）lobby_cancel_match"],
                "對局中": ["game_ops 看可用操作", "bot_status 看 AI 推薦", "game_action 送出動作"],
                "連線自檢": ["lobby_server_time（最無害的請求，有 RESPONSE 即代表注入通道通到伺服器）"]
            ],
            "caveats": [
                "「送出成功」只代表封包進了 WebSocket，不代表伺服器接受；請看回傳的 response 欄位",
                "RESPONSE 以 protobuf 欄位編號（fieldN）呈現，語意請查 docs/protocol/liqi.json",
                "operation type 已有 discard / pon / riichi / tsumo request / ron 的 runtime 證據；"
                    + "chi variants、赤五 combination 與三種槓仍需 live 驗證",
                "server-authoritative 自摸 resolver 尚有 integration gap；不得只看 sendRaw 成功就宣稱漏和已修復",
                "動作類工具會真的影響帳號，請只在測試帳號使用"
            ],
            "tile_notation": [
                "數牌（Suited）": "1-9 + m(萬)/p(筒)/s(索)，如 1m, 5p, 9s",
                "紅寶牌（Red 5s）": "MJAI 記法 5mr / 5pr / 5sr；雀魂記法 0m / 0p / 0s",
                "字牌（Honor）": "MJAI 記法 E(東), S(南), W(西), N(北), P(白), F(發), C(中)；雀魂記法 1z-7z",
                "note": "game_action / game_discard 的 tile 參數兩種記法都接受"
            ]
        ]
    }
}

// MARK: - Get Logs Tool

/// 獲取 Debug 日誌
struct GetLogsTool: MCPTool {
    static let name = "get_logs"
    static let description = "獲取 Debug 日誌（最多 10,000 條）"
    static let inputSchema = MCPInputSchema.empty

    private let context: MCPContext

    init(context: MCPContext) {
        self.context = context
    }

    func execute(arguments: [String: Any]) async throws -> Any {
        let logs = context.getLogs()
        return [
            "logs": logs,
            "count": logs.count
        ]
    }
}

// MARK: - Clear Logs Tool

/// 清空日誌
struct ClearLogsTool: MCPTool {
    static let name = "clear_logs"
    static let description = "清空所有日誌"
    static let inputSchema = MCPInputSchema.empty

    private let context: MCPContext

    init(context: MCPContext) {
        self.context = context
    }

    func execute(arguments: [String: Any]) async throws -> Any {
        context.clearLogs()
        return [
            "success": true,
            "message": "Logs cleared"
        ]
    }
}

#endif  // os(macOS)
