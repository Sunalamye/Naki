//
//  RecommendationTests.swift
//  NakiTests
//
//  吃的變體從 `label` 字串前綴搬到 `chiVariant` 欄位。這裡把搬移前的三個解析點
//  （`displayLabel`、`WebSession.syncHighlight`、`AutoPlayActionExecutor`）原文留在測試內，
//  對每個產生點的輸出逐一確認：欄位值 == 舊解析結果，`label` 字串內容不變。
//

import XCTest
import MortalSwift

@testable import Naki

@MainActor
final class RecommendationTests: XCTestCase {

    // MARK: 搬移前的解析（原文）

    /// 搬移前 `Recommendation.displayLabel` 的 chi 分支
    private func legacyChiDisplayLabel(_ label: String) -> String {
        if label.hasPrefix("chi_"), let idx = Int(String(label.dropFirst(4))) {
            let symbols = ["①", "②", "③"]
            return "吃\(symbols[max(0, min(idx, 2))])"
        }
        return "吃"
    }

    /// 搬移前 `WebSession.syncHighlight` 的變體（nil＝前綴在但數字解不出）
    private func legacyWebSessionVariant(_ label: String) -> Int? {
        label.hasPrefix("chi_") ? Int(label.dropFirst(4)) : 0
    }

    /// 搬移前 `AutoPlayActionExecutor` 的變體（解不出退回 0）
    private func legacyExecutorVariant(_ tile: String) -> Int {
        var variant = 0
        if tile.hasPrefix("chi_"), let index = Int(String(tile.dropFirst(4))) {
            variant = index
        }
        return variant
    }

    /// 前綴解析本身（無前綴或數字解不出回 nil）
    private func legacyParsedVariant(_ label: String) -> Int? {
        label.hasPrefix("chi_") ? Int(label.dropFirst(4)) : nil
    }

    // MARK: 產生點

    private typealias AI = PlayerState.ActionIndex

    /// 三個產生點的輸出，附來源名稱
    private func producedRecommendations() -> [(source: String, rec: Recommendation)] {
        var rows: [(String, Recommendation)] = []

        let mapper = MortalActionMapper()
        for index in 0..<46 {
            if let rec = mapper.actionIndexToRecommendation(index, probability: 0.5) {
                rows.append(("MortalActionMapper[\(index)]", rec))
            }
        }

        // 被吃的 3m：consumed 4m5m → 0、2m4m → 1、1m2m → 2
        let chiConsumed: [[String]] = [["4m", "5m"], ["2m", "4m"], ["1m", "2m"]]
        var reactions: [[String: Any]] = chiConsumed.map {
            ["type": "chi", "actor": 1, "pai": "3m", "consumed": $0, "target": 0]
        }
        reactions += [
            ["type": "dahai", "pai": "5p"],
            ["type": "reach"],
            ["type": "pon", "pai": "3m"],
            ["type": "daiminkan", "consumed": ["1m", "1m", "1m"]],
            ["type": "ankan", "consumed": ["1m", "1m", "1m", "1m"]],
            ["type": "kakan", "consumed": ["1m"]],
            ["type": "hora"], ["type": "none"], ["type": "kita"], ["type": "ryukyoku"],
        ]
        for reaction in reactions {
            let recs = CloudDecisionMapper.recommendations(reaction: reaction, candidates: [],
                                                           reachDiscard: "5p")
            for rec in recs ?? [] { rows.append(("Cloud reaction \(reaction["type"] ?? "")", rec)) }
        }

        let candidates = ["dahai:5p", "reach", "pon", "chi_low", "chi_mid", "chi_high", "kan",
                          "hora", "nukidora", "ryukyoku", "none"]
        for action in candidates {
            if let rec = CloudDecisionMapper.recommendation(fromCandidate: action, prob: 0.5) {
                rows.append(("Cloud candidate \(action)", rec))
            }
        }

        // Legacy 字典入口（DebugServer 注入畫面狀態用）
        for (tile, type) in [("chi_0", "chi"), ("chi_1", "chi"), ("chi_2", "chi"), ("chi_x", "chi"),
                             ("pon", "pon"), ("5p", "discard")] {
            rows.append(("dict \(tile)", Recommendation(from: ["tile": tile, "prob": 0.5,
                                                               "action_type": type])))
        }
        return rows
    }

    func testChiVariantFieldMatchesLegacyLabelParsing() {
        let rows = producedRecommendations()
        XCTAssertGreaterThan(rows.count, 40)

        for (source, rec) in rows {
            XCTAssertEqual(rec.chiVariant, legacyParsedVariant(rec.label), source)
            guard rec.actionType == .chi else {
                XCTAssertNil(rec.chiVariant, "\(source)：非吃的動作不得有變體")
                continue
            }
            XCTAssertEqual(rec.displayLabel, legacyChiDisplayLabel(rec.label), source)
            XCTAssertEqual(rec.chiVariant ?? 0, legacyExecutorVariant(rec.displayTile), source)
            XCTAssertEqual(rec.chiVariant ?? 0, legacyWebSessionVariant(rec.label) ?? 0, source)
        }
    }

    func testEveryVariantIsProducedAndLabelIsUnchanged() {
        let rows = producedRecommendations()
        for variant in 0...2 {
            for prefix in ["MortalActionMapper", "Cloud reaction chi", "Cloud candidate"] {
                let hits = rows.filter {
                    $0.source.hasPrefix(prefix) && $0.rec.actionType == .chi && $0.rec.chiVariant == variant
                }
                XCTAssertFalse(hits.isEmpty, "\(prefix) 沒有產生 variant \(variant)")
                for hit in hits {
                    XCTAssertEqual(hit.rec.label, "chi_\(variant)", hit.source)
                    XCTAssertEqual(hit.rec.id, "chi_chi_\(variant)", hit.source)
                    XCTAssertEqual(hit.rec.displayLabel, "吃" + ["①", "②", "③"][variant], hit.source)
                }
            }
        }
    }

    func testMortalChiIndexesMapToVariants() {
        let mapper = MortalActionMapper()
        XCTAssertEqual(mapper.actionIndexToRecommendation(AI.chiLow, probability: 1)?.chiVariant, 0)
        XCTAssertEqual(mapper.actionIndexToRecommendation(AI.chiMid, probability: 1)?.chiVariant, 1)
        XCTAssertEqual(mapper.actionIndexToRecommendation(AI.chiHigh, probability: 1)?.chiVariant, 2)
    }

    /// 顯示讀欄位，不看 `label`：兩者不一致時以欄位為準
    func testDisplayLabelReadsFieldNotLabel() {
        let rec = Recommendation(tile: "chi_0", probability: 1, actionType: .chi, chiVariant: 2)
        XCTAssertEqual(rec.displayLabel, "吃③")
    }

    /// 欄位為 nil 的吃：顯示退回「吃」，與搬移前 label 沒有 `chi_` 前綴時一致
    func testChiWithoutVariantFallsBackToPlainLabel() {
        let rec = Recommendation(tile: "chi", probability: 1, actionType: .chi)
        XCTAssertNil(rec.chiVariant)
        XCTAssertEqual(rec.displayLabel, legacyChiDisplayLabel("chi"))
    }
}
