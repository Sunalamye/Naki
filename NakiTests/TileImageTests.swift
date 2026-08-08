import XCTest
import SwiftUI
@testable import Naki

/// `TileImage` 的資產對應測試。
///
/// 這裡有兩件不同的事要驗，混在一起就會漏掉第二件：
///
/// 1. MJAI 字串**映射**到哪個資產名——純字串邏輯。
/// 2. 那個資產**是否真的在 bundle 裡**。
///
/// 只驗第 1 件的話，imageset 改名、漏進 target、或 asset catalog 的
/// `provides-namespace` 被關掉時，測試照樣全綠，而畫面上是一塊空白——
/// SwiftUI 的 `Image(_:)` 找不到資產不會拋錯，也不會留下任何執行期痕跡。
final class TileImageTests: XCTestCase {

    /// 資產齊全的定義（40 張）。與 `scripts/build-tile-sprite.py` 的 `EXPECTED` 同一份清單。
    private static let allCodes: [String] =
        (1...9).flatMap { n in ["m", "p", "s"].map { "\(n)\($0)" } }
        + ["5mr", "5pr", "5sr"]
        + ["E", "S", "W", "N", "P", "F", "C"]
        + ["back", "blank", "front"]

    // MARK: - 映射

    func testNumberedSuitsMapToTheirGroups() {
        XCTAssertEqual(TileImage.assetName(for: "1m"), "MahjongTiles/Manzu/1m")
        XCTAssertEqual(TileImage.assetName(for: "9m"), "MahjongTiles/Manzu/9m")
        XCTAssertEqual(TileImage.assetName(for: "3p"), "MahjongTiles/Pinzu/3p")
        XCTAssertEqual(TileImage.assetName(for: "8s"), "MahjongTiles/Souzu/8s")
    }

    /// 赤五是**獨立資產**，不是「5m 塗紅」。
    ///
    /// 舊的 Unicode 路徑做不到這件事：`5mr` 與 `5m` 共用同一個 code point，
    /// 只能把整張牌染紅。資產的 imageset 直接以 MJAI 命名，所以這裡是恆等映射。
    func testRedFivesHaveTheirOwnAssets() {
        XCTAssertEqual(TileImage.assetName(for: "5mr"), "MahjongTiles/Manzu/5mr")
        XCTAssertEqual(TileImage.assetName(for: "5pr"), "MahjongTiles/Pinzu/5pr")
        XCTAssertEqual(TileImage.assetName(for: "5sr"), "MahjongTiles/Souzu/5sr")
    }

    func testHonorsMapToHonorsGroup() {
        for code in ["E", "S", "W", "N", "P", "F", "C"] {
            XCTAssertEqual(TileImage.assetName(for: code), "MahjongTiles/Honors/\(code)")
        }
    }

    func testUtilitiesMapToUtilityGroup() {
        XCTAssertEqual(TileImage.assetName(for: "back"), "MahjongTiles/Utility/back")
        XCTAssertEqual(TileImage.assetName(for: "blank"), "MahjongTiles/Utility/blank")
        XCTAssertEqual(TileImage.assetName(for: "front"), "MahjongTiles/Utility/front")
    }

    /// 認不得的字串**回 nil**，不猜。
    ///
    /// `0m` 是天鳳／雀魂的赤五慣例，不是 Naki 的（`Tile.mjaiString` 產出 `5mr`）。
    /// 猜成赤五的話，畫面上會出現一張手牌裡不存在的牌，而使用者沒有任何線索
    /// 看出那是轉換錯誤——走 fallback 至少會把原字串顯示出來。
    func testUnknownStringsFallBackRatherThanGuess() {
        XCTAssertNil(TileImage.assetName(for: "0m"), "天鳳慣例不該被猜成赤五")
        XCTAssertNil(TileImage.assetName(for: "reach"))
        XCTAssertNil(TileImage.assetName(for: ""))
        XCTAssertNil(TileImage.assetName(for: "1mr"), "赤牌只有五")
        XCTAssertNil(TileImage.assetName(for: "10m"))
        XCTAssertNil(TileImage.assetName(for: "5z"), "字牌不走數牌花色")
    }

    // MARK: - 資產存在性

    @MainActor
    func testEveryMappedAssetExistsInBundle() {
        XCTAssertEqual(Self.allCodes.count, 40, "清單本身應該是 40 張")

        for code in Self.allCodes {
            guard let name = TileImage.assetName(for: code) else {
                XCTFail("\(code) 映射不到資產名")
                continue
            }
            XCTAssertTrue(Self.assetExists(name), "資產不在 bundle：\(name)")
        }
    }

    /// 牌身資產單獨驗一次。
    ///
    /// `TileImage.body` 直接寫死這個名字來疊牌身，**不經過** `assetName(for:)`，
    /// 所以上面那個迴圈驗不到它。少了它，所有數牌與字牌都會變成深色背景上的
    /// 透明花紋——每一張牌都壞掉，但每一個映射測試都還是綠的。
    @MainActor
    func testTileBodyAssetExists() {
        XCTAssertTrue(Self.assetExists("MahjongTiles/Utility/front"),
                      "牌身資產缺失會讓所有數牌與字牌失去白色底板")
    }

    /// `back`／`blank`／`front` 自己就是完整的牌，疊上牌身會蓋掉圖案。
    func testSelfContainedSetMatchesUtilities() {
        XCTAssertEqual(TileImage.selfContained, ["back", "blank", "front"])
    }

    @MainActor
    private static func assetExists(_ name: String) -> Bool {
        #if os(macOS)
        return NSImage(named: name) != nil
        #else
        return UIImage(named: name) != nil
        #endif
    }
}
