//
//  ReplayTools.swift
//  Naki
//
//  對局錄影的列出與離線 replay。
//

import Foundation
import MCPKit

// MARK: - 列出錄影

/// 列出已錄下的對局
struct ListRecordingsTool: MCPTool {
    static let name = "replay_list"
    static let description = """
        列出已錄下的對局（每局一個 .mjai.jsonl）。錄影存在當次 session 的 log 目錄下 \
        games/，只有產生 end_game 的完整對局才會落盤——中途斷線的半截緩衝直接丟棄。
        """
    static let inputSchema = MCPInputSchema(
        properties: ["session": .string("要看哪一次執行的錄影目錄（預設當次）")],
        required: []
    )

    private let context: MCPContext
    init(context: MCPContext) { self.context = context }

    func execute(arguments: [String: Any]) async throws -> Any {
        let dir = try await ReplaySupport.gamesDirectory(session: arguments["session"] as? String)
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasSuffix(".mjai.jsonl") }
            .sorted()

        let games: [[String: Any]] = files.map { name in
            let url = dir.appendingPathComponent(name)
            let count = (try? GameRecorder.load(url).count) ?? -1
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int ?? 0
            return ["file": name, "events": count, "bytes": size, "path": url.path]
        }

        return [
            "directory": dir.path,
            "count": games.count,
            "games": games,
            "note": games.isEmpty
                ? "還沒有完整對局。錄影在收到 end_game 時才寫檔。"
                : "用 replay_game 把某一局餵回 Bot 重跑決策"
        ]
    }
}

// MARK: - Replay

/// 把錄下的一局重新餵給 Bot，輸出每一步的決策
///
/// 用途是**離線重現**：不必真的打一局就能驗證 encoder／resolver 的改動。
/// 2026-08-01 那輪查「莊家第一打不會自動」時，正是因為沒有這個能力，
/// 只能加診斷等 bug 下次自己發生。
struct ReplayGameTool: MCPTool {
    static let name = "replay_game"
    static let description = """
        把錄下的一局重新餵給 Bot，回傳每一步的決策。不會送出任何 Liqi 請求，\
        純離線重跑。⚠️ 會建立一個獨立的 replay Bot，不影響正在進行的對局。
        """
    static let inputSchema = MCPInputSchema(
        properties: [
            "file": .string("錄影檔名或完整路徑（用 replay_list 取得）"),
            "session": .string("錄影所在的 session 目錄（預設當次）"),
            "limit": .integer("最多回傳幾步決策（預設 40）")
        ],
        required: ["file"]
    )

    private let context: MCPContext
    init(context: MCPContext) { self.context = context }

    func execute(arguments: [String: Any]) async throws -> Any {
        guard let file = arguments["file"] as? String, !file.isEmpty else {
            throw MCPToolError.missingParameter("file")
        }
        let limit = arguments["limit"] as? Int ?? 40

        let url: URL
        if file.hasPrefix("/") {
            url = URL(fileURLWithPath: file)
        } else {
            let dir = try await ReplaySupport.gamesDirectory(session: arguments["session"] as? String)
            url = dir.appendingPathComponent(file)
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MCPToolError.invalidParameter("file", expected: "存在的錄影檔；用 replay_list 確認")
        }

        let events = try GameRecorder.load(url)
        guard !events.isEmpty else {
            throw MCPToolError.invalidParameter("file", expected: "非空的錄影")
        }

        return try await ReplaySupport.run(events: events, limit: limit, source: url.lastPathComponent)
    }
}

// MARK: - 共用

enum ReplaySupport {

    /// 錄影目錄。`session` 給 nil 代表當次執行。
    @MainActor
    static func gamesDirectory(session: String?) throws -> URL {
        let current = LogManager.shared.logDirectory
        guard let session, !session.isEmpty else {
            return current.appendingPathComponent("games", isDirectory: true)
        }
        // session 是同一層的兄弟目錄；不接受路徑分隔避免跳出去
        guard !session.contains("/") else {
            throw MCPToolError.invalidParameter("session", expected: "目錄名稱，不含 /")
        }
        return current.deletingLastPathComponent()
            .appendingPathComponent(session, isDirectory: true)
            .appendingPathComponent("games", isDirectory: true)
    }

    /// 用一個獨立的 Bot 重跑事件流
    ///
    /// **不重用正在對局的 controller**：replay 會把狀態機從頭走一遍，
    /// 混進 live 對局會直接毀掉當前那局。
    @MainActor
    static func run(events: [[String: Any]], limit: Int, source: String) async throws -> Any {
        // 從 start_game 取座位；沒有就無法建立 Bot
        guard let startGame = events.first(where: { ($0["type"] as? String) == "start_game" }),
              let playerId = startGame["id"] as? Int
        else {
            throw MCPToolError.invalidParameter("file", expected: "含 start_game 且帶 id 的錄影")
        }
        let is3P = (startGame["is3P"] as? Bool) ?? false

        let controller = NativeBotController()
        try controller.createBot(playerId: UInt8(playerId), is3P: is3P)
        defer { controller.deleteBot() }

        var decisions: [[String: Any]] = []
        var errors: [[String: Any]] = []

        for (index, event) in events.enumerated() {
            do {
                let response = try await controller.react(event: event)
                guard let response else { continue }
                if decisions.count < limit {
                    decisions.append([
                        "index": index,
                        "event": event["type"] as? String ?? "?",
                        "action": response
                    ])
                }
            } catch {
                errors.append([
                    "index": index,
                    "event": event["type"] as? String ?? "?",
                    "error": "\(error)"
                ])
            }
        }

        return [
            "source": source,
            "events": events.count,
            "playerId": playerId,
            "is3P": is3P,
            "decisions": decisions,
            "decisionCount": decisions.count,
            "truncated": decisions.count >= limit,
            "errors": errors,
            "note": "純離線重跑，沒有送出任何 Liqi 請求。"
                + "決策是模型對錄影中該局面的回應，可與當時的實際送出比對。"
        ]
    }
}
