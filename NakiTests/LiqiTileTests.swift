//
//  LiqiTileTests.swift
//  NakiTests
//
//  字牌表與牌號只有 `LiqiTile` 一份。這裡鎖兩件事：
//  1. 34 種牌（加赤五）與非法輸入的回傳值。
//  2. 收斂前各處自己的實作（測試內原文保留）與 `LiqiTile` 對同一輸入回同一輸出。
//

import XCTest

@testable import Naki

@MainActor
final class LiqiTileTests: XCTestCase {

    private static let suits = ["m", "p", "s"]

    /// (雀魂寫法, MJAI 寫法, 牌號)：34 種牌加三張赤五
    private static let tiles: [(majsoul: String, mjai: String, number: Int?)] =
        suits.flatMap { suit in (1...9).map { ("\($0)\(suit)", "\($0)\(suit)", $0) } }
        + suits.map { ("0\($0)", "5\($0)r", 5) }
        + [("1z", "E", nil), ("2z", "S", nil), ("3z", "W", nil), ("4z", "N", nil),
           ("5z", "P", nil), ("6z", "F", nil), ("7z", "C", nil)]

    // MARK: 逐張

    func testTableCoversEveryTile() {
        XCTAssertEqual(Self.tiles.count, 34 + 3)
        XCTAssertEqual(Set(Self.tiles.map(\.majsoul)).count, 37)
        XCTAssertEqual(Set(Self.tiles.map(\.mjai)).count, 37)
    }

    func testHonorsAreEastSouthWestNorthWhiteGreenRed() {
        XCTAssertEqual(LiqiTile.honors, ["E", "S", "W", "N", "P", "F", "C"])
    }

    func testEveryTileConvertsAndHasItsNumber() {
        for tile in Self.tiles {
            XCTAssertEqual(LiqiTile.mjai(fromMajsoul: tile.majsoul), tile.mjai, tile.majsoul)
            XCTAssertEqual(LiqiTile.majsoul(fromMJAI: tile.mjai), tile.majsoul, tile.mjai)
            XCTAssertEqual(LiqiTile.number(of: tile.majsoul), tile.number, tile.majsoul)
            XCTAssertEqual(LiqiTile.number(of: tile.mjai), tile.number, tile.mjai)
        }
    }

    func testNumberOfRejectsInvalidInput() {
        for bad in ["", "5", "0", "m", "zz", "5x", "x5", "?", "back"] {
            XCTAssertNil(LiqiTile.number(of: bad), bad)
        }
        XCTAssertNil(LiqiTile.number(of: nil))
    }

    // MARK: 與收斂前的實作對照

    /// 收斂前 `LiqiOperationSnapshot.tileNumber`（原文）
    private func legacyStoreTileNumber(_ tile: String?) -> Int? {
        guard let tile, tile.count >= 2 else { return nil }
        let chars = Array(tile)
        guard let digit = chars.first.flatMap({ Int(String($0)) }) else { return nil }
        let suit = chars[1]
        guard suit == "m" || suit == "p" || suit == "s" else { return nil }
        return digit == 0 ? 5 : digit
    }

    /// 收斂前 `CloudDecisionMapper.tileNumber`（原文）
    private func legacyCloudTileNumber(_ tile: String) -> Int? {
        guard let first = tile.first, let number = first.wholeNumberValue,
              (1...9).contains(number) else { return nil }
        return number
    }

    func testNumberOfMatchesLegacyStoreImplementation() {
        let inputs = Self.tiles.map(\.majsoul) + Self.tiles.map(\.mjai)
            + ["", "5", "0", "zz", "5x", "?", "8z", "9z", "0z"]
        for input in inputs {
            XCTAssertEqual(LiqiTile.number(of: input), legacyStoreTileNumber(input), input)
        }
    }

    func testNumberOfMatchesLegacyCloudImplementationOnMJAITiles() {
        for tile in Self.tiles.map(\.mjai) + ["?"] {
            XCTAssertEqual(LiqiTile.number(of: tile), legacyCloudTileNumber(tile), tile)
        }
    }

    /// 兩份舊實作只在「不是 MJAI 寫法」的輸入上分歧；收斂後採雀魂版（有驗花色）。
    /// 雲端回應只會給 MJAI 寫法，所以這些輸入走不到，但行為差異要明文鎖住。
    func testNumberOfDivergesFromLegacyCloudOnlyOffMJAIInputs() {
        XCTAssertEqual(legacyCloudTileNumber("0m"), nil)
        XCTAssertEqual(LiqiTile.number(of: "0m"), 5)
        for honor in ["1z", "7z"] {
            XCTAssertNotNil(legacyCloudTileNumber(honor))
            XCTAssertNil(LiqiTile.number(of: honor))
        }
        XCTAssertEqual(legacyCloudTileNumber("5x"), 5)
        XCTAssertNil(LiqiTile.number(of: "5x"))
    }

    // MARK: 呼叫端

    func testEveryHonorSiteResolvesToTheSharedTable() {
        for (i, honor) in LiqiTile.honors.enumerated() {
            XCTAssertEqual(AkagiSanmaBot.mjai(tile: UInt8(108 + 4 * i)), honor, "AkagiSanmaBot")
            XCTAssertEqual(MortalActionMapper().actionIndexToRecommendation(27 + i, probability: 1)?.displayTile,
                           honor, "MortalActionMapper")
            XCTAssertEqual(ActionDelayModel.tileClass(of: honor), .honor, "ActionDelayModel")
            XCTAssertEqual(TileImage.assetName(for: honor), "MahjongTiles/Honors/\(honor)", "TileImage")
        }
    }

    // MARK: 吃的變體

    /// 收斂前 `CloudDecisionMapper.chiVariant`（原文，改用上面的舊 `tileNumber`）
    private func legacyCloudChiVariant(called: String, consumed: [String]) -> Int? {
        guard let calledNumber = legacyCloudTileNumber(called),
              consumed.count == 2 else { return nil }
        let numbers = consumed.compactMap(legacyCloudTileNumber)
        guard numbers.count == 2 else { return nil }

        let below = numbers.filter { $0 < calledNumber }.count
        let above = numbers.filter { $0 > calledNumber }.count
        if above == 2 { return 0 }
        if below == 2 { return 2 }
        if below == 1 && above == 1 { return 1 }
        return nil
    }

    /// 收斂前 `LiqiOperationSnapshot.chiCombinationIndex` 對單一 combination 字串的分類（原文）
    private func legacyStoreComboVariant(called: String?, combo: String) -> Int? {
        guard let called = legacyStoreTileNumber(called) else { return nil }
        let numbers = combo.split(separator: "|").compactMap { legacyStoreTileNumber(String($0)) }
        guard numbers.count == 2 else { return nil }

        let below = numbers.filter { $0 < called }.count
        let above = numbers.filter { $0 > called }.count
        if above == 2 { return 0 }
        if below == 2 { return 2 }
        if below == 1 && above == 1 { return 1 }
        return nil
    }

    /// (被吃的牌, consumed, 變體)：含赤五、長度不是 2、不同花色、不相連、字牌
    private static let chiCases: [(called: String?, consumed: [String], variant: Int?)] = [
        ("3m", ["4m", "5m"], 0), ("3m", ["2m", "4m"], 1), ("3m", ["1m", "2m"], 2),
        ("5s", ["4s", "6s"], 1),
        // 赤五：MJAI `5mr`、雀魂 `0m` 都算 5
        ("3m", ["4m", "5mr"], 0), ("4m", ["5mr", "6m"], 0),
        ("5mr", ["3m", "4m"], 2), ("0m", ["6m", "7m"], 0), ("6m", ["0m", "7m"], 1),
        // consumed 長度不是 2
        ("3m", [], nil), ("3m", ["4m"], nil), ("3m", ["4m", "5m", "6m"], nil),
        // 不驗花色、不驗相連（沿用舊行為）
        ("3m", ["4p", "5s"], 0), ("3m", ["5m", "6m"], 0), ("5m", ["1m", "2m"], 2),
        // 同號、同側各一不成立
        ("3m", ["3m", "4m"], nil), ("3m", ["3p", "3s"], nil), ("3m", ["2m", "2m"], 2),
        // 字牌與無法辨識
        ("E", ["1m", "2m"], nil), ("3m", ["E", "S"], nil), ("3m", ["4m", "S"], nil),
        ("?", ["4m", "5m"], nil), (nil, ["4m", "5m"], nil),
    ]

    func testChiVariantBoundaryCases() {
        for c in Self.chiCases {
            XCTAssertEqual(LiqiTile.chiVariant(called: c.called, consumed: c.consumed), c.variant,
                           "called=\(c.called ?? "nil") consumed=\(c.consumed)")
        }
    }

    /// 對全部 MJAI 牌 × 全部 consumed 長度 0–3 的組合，與舊雲端分類逐一相同
    func testChiVariantMatchesLegacyCloudOnEveryMJAIInput() {
        let tiles = Self.tiles.map(\.mjai) + ["?"]
        var consumedLists: [[String]] = [[]] + tiles.map { [$0] }
        for a in tiles { for b in tiles { consumedLists.append([a, b]) } }
        consumedLists += [["4m", "5m", "6m"], ["3m", "E", "4m"]]
        for called in tiles {
            for consumed in consumedLists {
                XCTAssertEqual(LiqiTile.chiVariant(called: called, consumed: consumed),
                               legacyCloudChiVariant(called: called, consumed: consumed),
                               "called=\(called) consumed=\(consumed)")
            }
        }
    }

    /// 對全部雀魂牌 × 全部兩張 combination，與舊 Bridge 分類逐一相同
    func testChiVariantMatchesLegacyStoreOnEveryMajsoulCombination() {
        let tiles = Self.tiles.map(\.majsoul)
        for called in tiles + [nil] {
            for a in tiles {
                for b in tiles {
                    XCTAssertEqual(
                        LiqiTile.chiVariant(called: called, consumed: [a, b]),
                        legacyStoreComboVariant(called: called, combo: "\(a)|\(b)"),
                        "called=\(called ?? "nil") combo=\(a)|\(b)")
                }
            }
        }
    }

    /// 兩份舊分類只在「combination 含非牌號的第三段」分歧：Bridge 舊版略過非牌號後仍分類，
    /// 雲端舊版先看長度。收斂後採雲端版（長度先擋）；雀魂 combination 恆為兩張，走不到。
    func testChiVariantRejectsThreePartCombinationUnlikeLegacyStore() {
        XCTAssertEqual(legacyStoreComboVariant(called: "3m", combo: "4m|E|5m"), 0)
        XCTAssertNil(LiqiTile.chiVariant(called: "3m", consumed: ["4m", "E", "5m"]))
    }
}
