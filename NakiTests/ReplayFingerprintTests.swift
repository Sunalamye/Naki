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
    /// 一次啟動**）清掉，baseline 留著但無法重放。
    ///
    /// 倖存的一局在 `NakiTests/Fixtures/`，**在版控裡**。
    ///
    /// 它以前放在 `note/`，而 `.gitignore` 忽略整個 `note`——所以這條測試在這台
    /// 機器以外的任何地方都是 `XCTSkip`，報告卻一直是綠的。它是 `MajsoulBridge`
    /// （959 行的 Liqi→MJAI 核心）唯一接近的保護，等於在別人的機器上完全不存在。
    ///
    /// 進版控的前提是**匿名化**：原始錄影的 `start_game.names` 是四個真實玩家暱稱。
    /// 名字不進 observation（Mortal 吃的是 1012×34 的牌局張量），所以換成 P1–P4
    /// 不影響決策指紋——而這件事由這條測試自己驗證：改完之後指紋必須與 baseline 相同。
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
            // 優先讀版控裡的 fixture；退回 Logs 原位（新錄影還沒搬進來時仍可跑）
            let backup = repoRoot
                .appendingPathComponent("NakiTests/Fixtures", isDirectory: true)
                .appendingPathComponent("replay-\(file)")
            let original = logsRoot
                .appendingPathComponent(session, isDirectory: true)
                .appendingPathComponent("games", isDirectory: true)
                .appendingPathComponent(file)
            let recording = FileManager.default.fileExists(atPath: backup.path)
                ? backup : original
            let baselineFile = repoRoot
                .appendingPathComponent("NakiTests/Fixtures", isDirectory: true)
                .appendingPathComponent("baseline-\(session).txt")

            guard FileManager.default.fileExists(atPath: recording.path),
                  FileManager.default.fileExists(atPath: baselineFile.path) else {
                // 這裡**不再**是「本機驗證測試」：fixture 與 baseline 都在版控裡，
                // 缺席代表有人刪了它們，而不是「這台機器剛好沒有」。
                return XCTFail("fixture 或 baseline 不存在（兩者都應在 NakiTests/Fixtures/）: "
                               + "\(recording.path) / \(baselineFile.path)")
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
