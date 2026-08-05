//
//  ReplayFingerprintTests.swift
//  NakiTests
//
//  protocol 重構（2026-08-05）的核心安全網：把改動**之前**的舊 Release binary
//  對兩局實錄算出的決策指紋（`note/replay-baseline-pre-cloud-*.txt`，
//  2026-08-04 產出）當作 baseline，用當前程式碼重放同樣的錄影，指紋必須
//  完全一致——證明「MahjongBot 抽象＋BundledCoreMLBot 搬移」沒有改變任何決策。
//
//  指紋計算刻意**不用 Swift 重寫**：`scripts/replay-check.sh` 的哈希是
//  python `json.dumps(sort_keys=True)` 的位元組格式（`", "`／`": "` 分隔、
//  ensure_ascii），Swift 序列化器逐位元組復刻它是白費工又易錯——直接用
//  `Process` 跑同一段 python 片段，同源保證同格式。
//
//  ⚠️ 本機驗證測試：依賴 `~/Library/Logs/Naki/<session>/games/` 的實錄與
//  repo `note/` 的 baseline，任一缺席就 XCTSkip（換機器不會紅）。
//

import XCTest

@testable import Naki

@MainActor
final class ReplayFingerprintTests: XCTestCase {

    /// 20260803-013133 的錄影已被 log 輪替（保留 8 次啟動——**跑一次測試就是
    /// 一次啟動**）清掉，baseline 留著但無法重放。倖存的一局已備份到
    /// `note/replay-fixture-*.mjai.jsonl`（note/ 不受輪替影響、gitignored
    /// 不進 repo——錄影含其他玩家暱稱）。
    private let fixtures: [(session: String, file: String)] = [
        ("20260803-020246", "20260803-020304.mjai.jsonl"),
    ]

    func test_replayFingerprints_matchPreRefactorBaselines() async throws {
        // #filePath = <repo>/NakiTests/ReplayFingerprintTests.swift → repo 根
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let logsRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Naki", isDirectory: true)

        for (session, file) in fixtures {
            // 優先讀 note/ 的備份；退回 Logs 原位（老備份遺失時仍可跑）
            let backup = repoRoot
                .appendingPathComponent("note", isDirectory: true)
                .appendingPathComponent("replay-fixture-\(file)")
            let original = logsRoot
                .appendingPathComponent(session, isDirectory: true)
                .appendingPathComponent("games", isDirectory: true)
                .appendingPathComponent(file)
            let recording = FileManager.default.fileExists(atPath: backup.path)
                ? backup : original
            let baselineFile = repoRoot
                .appendingPathComponent("note", isDirectory: true)
                .appendingPathComponent("replay-baseline-pre-cloud-\(session).txt")

            guard FileManager.default.fileExists(atPath: recording.path),
                  FileManager.default.fileExists(atPath: baselineFile.path) else {
                throw XCTSkip("錄影或 baseline 不存在（本機驗證測試）: \(session)")
            }

            let events = try GameRecorder.load(recording)
            let result = try await ReplaySupport.run(events: events, limit: 500,
                                                     source: file)
            guard let dict = result as? [String: Any] else {
                return XCTFail("ReplaySupport.run 回傳非字典")
            }

            let line = try summaryLine(result: dict, name: file)
            let baseline = try String(contentsOf: baselineFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertEqual(line, baseline,
                           "決策指紋必須與重構前 baseline 完全一致（\(session)）——"
                         + "不一致代表 protocol 抽象改變了決策，逐格檢查 diff")
        }
    }

    /// 與 `scripts/replay-check.sh` 完全相同的 python 片段算 summary 行：
    /// `<name>\t<events>\t<decisions>\t<errors>\t<fp16>`
    private func summaryLine(result: [String: Any], name: String) throws -> String {
        let json = try JSONSerialization.data(withJSONObject: result)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("naki-replay-fp-\(UUID().uuidString).json")
        try json.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let script = """
        import json, sys, hashlib
        path, name = sys.argv[1], sys.argv[2]
        o = json.load(open(path))
        ds = o["decisions"]
        fp = hashlib.sha256(
            "\\n".join(f"{d['index']}:{d['event']}:{json.dumps(d['action'], sort_keys=True)}" for d in ds)
            .encode()
        ).hexdigest()[:16]
        print(f"{name}\\t{o['events']}\\t{len(ds)}\\t{len(o.get('errors', []))}\\t{fp}")
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-c", script, tmp.path, name]
        let stdout = Pipe()
        process.standardOutput = stdout
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw XCTSkip("python3 不可用（指紋片段需要它）")
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
