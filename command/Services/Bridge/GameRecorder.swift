//
//  GameRecorder.swift
//  Naki
//
//  把一局的 MJAI 事件流落盤成 JSONL，供離線 replay。
//

import Foundation

/// 對局錄影：一局一個 `.mjai.jsonl`
///
/// 為什麼需要這個：
///
/// 2026-08-01 那輪查「莊家第一打不會自動」時，追到 `ActionNewRound` 帶了
/// `operation` 但建不出 oplist 快照——然後**沒有那個封包可以再看一次**，
/// 只能加診斷等它下次發生。同一輪的 soak test 只跑完 5 局，因為每次驗證
/// 都要真的打一局 12–14 分鐘。
///
/// 有了錄影，bug 可以重現、回歸測試從「跑 10 局看看」變成
/// 「replay 20 局錄影，diff 決策」。
///
/// **只有產生 `end_game` 的完整對局才落盤。** 中途斷線留下的半截緩衝直接丟棄——
/// 半局的錄影 replay 出來的結果無法解讀，留著只會讓人以為有資料可用。
@MainActor
final class GameRecorder {

    /// 錄影存放目錄（當次 session 的 log 目錄下）
    private let directory: URL

    /// 當前這局累積的事件；`end_game` 之前不寫檔
    private var buffer: [[String: Any]] = []

    /// 這局的識別碼（開局時間戳）
    private var gameId: String?

    private static let idFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f
    }()

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// 目前是否正在錄
    var isRecording: Bool { gameId != nil }

    /// 這局已累積幾個事件
    var bufferedCount: Int { buffer.count }

    func startGame() {
        // 上一局若沒收到 end_game，這裡直接丟棄——見類型註解
        if let id = gameId, !buffer.isEmpty {
            systemLog("[錄影] 丟棄未完成的對局 \(id)（\(buffer.count) 個事件，沒有 end_game）")
        }
        buffer = []
        gameId = Self.idFormatter.string(from: Date())
    }

    func record(_ event: [String: Any]) {
        guard gameId != nil else { return }
        buffer.append(event)
    }

    /// 收到 `end_game` 時呼叫；把整局寫成一個 JSONL 檔
    /// - Returns: 寫出的檔案路徑，沒有東西可寫時回 nil
    @discardableResult
    func finishGame() -> URL? {
        guard let id = gameId else { return nil }
        defer { gameId = nil; buffer = [] }
        guard !buffer.isEmpty else { return nil }

        let url = directory.appendingPathComponent("\(id).mjai.jsonl")
        var text = ""
        for event in buffer {
            // 一行一個事件。單一事件序列化失敗時跳過那一行而不是整局作廢——
            // 少一個事件的錄影仍然有用，沒有錄影就什麼都沒有。
            guard let data = try? JSONSerialization.data(withJSONObject: event,
                                                         options: [.sortedKeys]),
                  let line = String(data: data, encoding: .utf8)
            else {
                systemLog("[錄影] 事件序列化失敗，已跳過一行")
                continue
            }
            text += line + "\n"
        }

        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            systemLog("[錄影] 對局已存檔: \(url.lastPathComponent)（\(buffer.count) 個事件）")
            return url
        } catch {
            systemLog("[錄影] 存檔失敗: \(error.localizedDescription)")
            return nil
        }
    }

    /// 列出這次 session 已錄下的對局
    func recordedGames() -> [String] {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return entries.filter { $0.hasSuffix(".mjai.jsonl") }.sorted()
    }

    /// 讀回一局的事件（replay 用）
    static func load(_ url: URL) throws -> [[String: Any]] {
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n").compactMap { line in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
    }
}
