//
//  TileImage.swift
//  Naki
//
//  麻將牌圖像 —— 取代 Unicode glyph。
//

import SwiftUI

// MARK: - Tile Image

/// 一張麻將牌的圖像。
///
/// **為什麼不用 `MahjongTile.unicode`**：`🀇🀙🀐` 在 macOS／iOS 系統字型下被渲染成
/// 黑白線稿，在推薦列那種 22–28pt 的尺寸上，使用者得先「認出」線稿代表哪張牌，
/// 才能對到牌桌上的立體彩色牌——而那正是這個介面唯一要做的事。
///
/// 更硬的問題是**赤五在 Unicode 裡不存在**：`5mr` 與 `5m` 共用同一個 code point
/// （見 `MahjongTile.mjaiToUnicode`），舊版只能靠 `.foregroundColor(.red)` 把整張牌
/// 染紅，而「紅色線稿」與「黑色線稿」在小尺寸下幾乎分不出來。改用圖像之後赤五是
/// 獨立資產（`Manzu/5mr`），染色 hack 一併移除。
///
/// 資產來自 FluffyStuff/riichi-mahjong-tiles（CC0，見
/// `docs/third-party/riichi-mahjong-tiles.md`）。imageset 名稱**直接就是 MJAI 字串**
/// （含 `5mr`／`5pr`／`5sr`），所以這裡沒有第二套命名要轉——上游若改用別的慣例
/// （例如天鳳的 `0m`），走的是 `fallback` 而不是被猜成普通五萬。
struct TileImage: View {

    /// 語意尺寸。只給**寬度**，高度一律由 `aspectRatio` 導出。
    ///
    /// 不讓呼叫端各自指定寬高：資產是 300×400，任何一處寫錯比例牌就會變形，
    /// 而變形的牌在對局中比沒有牌更糟（會對到錯的手牌）。
    enum Size {
        /// 寶牌指示牌、九種九牌這類並排小圖
        case tiny
        /// 次選推薦列
        case small
        /// 推薦列主要牌面
        case medium
        /// 最佳選擇大卡
        case large

        var baseWidth: CGFloat {
            switch self {
            case .tiny: return 18
            case .small: return 24
            case .medium: return 32
            case .large: return 48
            }
        }
    }

    /// 資產原始尺寸 300 × 400。
    static let aspectRatio: CGFloat = 300.0 / 400.0

    var tile: MahjongTile
    var size: Size = .medium

    /// 跟著 Dynamic Type 縮放，但**封頂 1.6×**。
    ///
    /// 側欄是固定寬度（macOS 320pt、iOS 140pt），不封頂的話最大字級會把整列推爆。
    /// 舊版是用寫死的 `.font(.system(size: 28))` 迴避這件事（`RecommendationView`
    /// 當時的註解就說「改用 Dynamic Type 會與機率條錯位」）——那等於完全不支援。
    /// 封頂讓牌面在放大字級下仍然跟著長大，只是不會無限長。
    @ScaledMetric(relativeTo: .body) private var typeScale: CGFloat = 1

    private var width: CGFloat { size.baseWidth * min(typeScale, 1.6) }

    var body: some View {
        Group {
            if let asset = Self.assetName(for: tile.mjai) {
                ZStack {
                    // 這套資產把「牌身」與「牌面圖案」拆成兩個檔案：`Front` 是米白色的牌，
                    // `Manzu/5m` 之類只有圖案、背景透明。少了這層底，深色側欄會直接透出來，
                    // 畫面上是一堆浮空的花紋而不是牌。
                    if !Self.selfContained.contains(tile.mjai) {
                        layer("MahjongTiles/Utility/front")
                    }
                    layer(asset)
                }
            } else {
                fallback
            }
        }
        .frame(width: width, height: width / Self.aspectRatio)
        .accessibilityLabel(tile.accessibleName)
    }

    private func layer(_ assetName: String) -> some View {
        Image(assetName)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
    }

    /// 認不得的牌：畫一張帶字的白牌，不留白也不畫問號。
    ///
    /// `Recommendation.label` 在 `ActionType.unknown` 那條路上可以是任何字串
    /// （模型或雲端送來的未知動作名）。畫面上「空一塊」與「圖還沒載入」在使用者
    /// 眼裡是同一件事，所以這裡寧可把原字串顯示出來——看得出是哪裡不對。
    private var fallback: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Color.white)
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(Color.secondary.opacity(0.45), lineWidth: 1)
            )
            .overlay(
                Text(tile.displayName)
                    .font(.system(size: max(7, width * 0.34), weight: .semibold))
                    .foregroundStyle(.black)
                    .minimumScaleFactor(0.5)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(1)
            )
    }

    // MARK: - Asset Mapping

    private static let honors: Set<String> = ["E", "S", "W", "N", "P", "F", "C"]
    private static let utilities: Set<String> = ["back", "blank", "front"]
    /// 自己就是一整張牌、不需要疊 `Front` 的資產。
    static let selfContained: Set<String> = ["back", "blank", "front"]
    private static let suitGroups: [Character: String] = [
        "m": "Manzu", "p": "Pinzu", "s": "Souzu",
    ]

    /// MJAI 字串 → Asset Catalog 路徑；認不得回 `nil`（呼叫端走 `fallback`）。
    ///
    /// 兩個 catalog（macOS `command/Resources`、iOS `Naki-M`）內容相同，所以同一個
    /// 路徑兩邊都解析得到。`TileImageTests` 逐張確認資產真的在 bundle 裡——
    /// 這個函式回傳合法字串不代表圖存在（imageset 沒被 build 進去時 `Image` 會靜靜
    /// 畫一塊空白，畫面上看起來就只是「牌不見了」）。
    static func assetName(for mjai: String) -> String? {
        if utilities.contains(mjai) { return "MahjongTiles/Utility/\(mjai)" }
        if honors.contains(mjai) { return "MahjongTiles/Honors/\(mjai)" }

        // 數牌：`1m`–`9m`／`1p`–`9p`／`1s`–`9s`，外加赤五 `5mr`／`5pr`／`5sr`。
        let isRed = mjai.hasSuffix("r")
        let body = isRed ? String(mjai.dropLast()) : mjai
        guard body.count == 2,
              let rank = body.first, rank.isNumber, rank != "0",
              let suit = body.last,
              let group = suitGroups[suit]
        else { return nil }
        // 赤牌只有五：`1mr` 之類的字串不該被當成某張紅牌畫出來。
        if isRed && rank != "5" { return nil }

        return "MahjongTiles/\(group)/\(mjai)"
    }
}

// MARK: - Convenience

extension TileImage {

    /// 從 MJAI 字串直接建立（呼叫端多半只有字串，不想每次自己包 `MahjongTile`）。
    init(mjai: String, size: Size = .medium) {
        self.init(tile: MahjongTile(mjai: mjai), size: size)
    }

    /// 牌背。副露展示裡的暗槓蓋牌用。
    static func back(size: Size = .medium) -> TileImage {
        TileImage(mjai: "back", size: size)
    }
}

// MARK: - Preview

#Preview("TileImage - 花色") {
    VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 4) {
            ForEach(1...9, id: \.self) { TileImage(mjai: "\($0)m", size: .medium) }
        }
        HStack(spacing: 4) {
            ForEach(1...9, id: \.self) { TileImage(mjai: "\($0)p", size: .medium) }
        }
        HStack(spacing: 4) {
            ForEach(1...9, id: \.self) { TileImage(mjai: "\($0)s", size: .medium) }
        }
        HStack(spacing: 4) {
            ForEach(["E", "S", "W", "N", "P", "F", "C"], id: \.self) {
                TileImage(mjai: $0, size: .medium)
            }
        }
    }
    .padding()
}

#Preview("TileImage - 赤五與牌背") {
    HStack(alignment: .bottom, spacing: 10) {
        // 赤五是獨立資產，不再靠 foregroundColor 染紅
        TileImage(mjai: "5m", size: .large)
        TileImage(mjai: "5mr", size: .large)
        TileImage(mjai: "5pr", size: .large)
        TileImage(mjai: "5sr", size: .large)
        TileImage.back(size: .large)
    }
    .padding()
}

#Preview("TileImage - 尺寸階梯") {
    HStack(alignment: .bottom, spacing: 10) {
        TileImage(mjai: "5mr", size: .tiny)
        TileImage(mjai: "5mr", size: .small)
        TileImage(mjai: "5mr", size: .medium)
        TileImage(mjai: "5mr", size: .large)
    }
    .padding()
}

#Preview("TileImage - 認不得的牌（fallback）") {
    HStack(alignment: .bottom, spacing: 10) {
        // 天鳳慣例的 0m 不是 Naki 的表示法，走 fallback 而不是被猜成 5m
        TileImage(mjai: "0m", size: .large)
        TileImage(mjai: "reach", size: .large)
    }
    .padding()
}
