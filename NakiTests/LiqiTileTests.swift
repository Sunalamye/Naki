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
}
