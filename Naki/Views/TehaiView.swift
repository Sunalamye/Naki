//
//  TehaiView.swift
//  akagi
//
//  Created by Suoie on 2025/11/30.
//  手牌顯示元件 - 13張手牌 + 1張自摸牌
//  Updated: 2025/12/01 - 使用 GameModels 中的 MahjongTile
//

import SwiftUI
import MortalSwift

// MahjongTile 已移至 GameModels.swift

// MARK: - Single Tile View

struct TileView: View {
    let tile: MahjongTile
    var isHighlighted: Bool = false
    var showLabel: Bool = false

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                // 牌背景
                RoundedRectangle(cornerRadius: 4)
                    .fill(tileBackground)
                    .shadow(color: .black.opacity(0.2), radius: 2, x: 1, y: 1)

                // 牌面
                Text(tile.unicode)
                    .font(.system(size: 28))
                    .foregroundColor(tile.isRed ? .red : .primary)
            }
            .frame(width: 36, height: 48)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isHighlighted ? Color.yellow : Color.clear, lineWidth: 2)
            )

            // 標籤
            if showLabel {
                Text(tile.mjai)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
    }

    private var tileBackground: Color {
        if isHighlighted {
            return Color.yellow.opacity(0.3)
        }
        return Color(NSColor.controlBackgroundColor)
    }
}

// MARK: - Tehai View (手牌顯示)

struct TehaiView: View {
    var tiles: [String]           // 13 張手牌 (MJAI 格式)
    var tsumo: String?            // 自摸牌 (可選)
    var highlightedTile: String?  // 高亮的推薦牌
    var showLabels: Bool = false

    var body: some View {
        HStack(spacing: 0) {
            // 手牌 (13張)
            HStack(spacing: 2) {
                ForEach(Array(tiles.enumerated()), id: \.offset) { index, mjaiTile in
                    let tile = MahjongTile(mjai: mjaiTile)
                    TileView(
                        tile: tile,
                        isHighlighted: highlightedTile == mjaiTile,
                        showLabel: showLabels
                    )
                }
            }

            // 分隔線
            if tsumo != nil {
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 8)
            }

            // 自摸牌 (1張)
            if let tsumoTile = tsumo {
                TileView(
                    tile: MahjongTile(mjai: tsumoTile),
                    isHighlighted: highlightedTile == tsumoTile,
                    showLabel: showLabels
                )
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.windowBackgroundColor))
                .shadow(color: .black.opacity(0.1), radius: 4)
        )
    }
}

// MARK: - Compact Tehai View (緊湊版)

struct CompactTehaiView: View {
    var tiles: [String]
    var tsumo: String?
    var highlightedTile: String?

    var body: some View {
        HStack(spacing: 0) {
            // 手牌
            ForEach(Array(tiles.enumerated()), id: \.offset) { index, mjaiTile in
                let tile = MahjongTile(mjai: mjaiTile)
                Text(tile.unicode)
                    .font(.title2)
                    .foregroundColor(tile.isRed ? .red : .primary)
                    .padding(.horizontal, 1)
                    .background(
                        highlightedTile == mjaiTile ?
                        Color.yellow.opacity(0.3) : Color.clear
                    )
            }

            // 分隔
            if tsumo != nil {
                Text(" ")
            }

            // 自摸牌
            if let tsumoTile = tsumo {
                let tile = MahjongTile(mjai: tsumoTile)
                Text(tile.unicode)
                    .font(.title2)
                    .foregroundColor(tile.isRed ? .red : .primary)
                    .background(
                        highlightedTile == tsumoTile ?
                        Color.yellow.opacity(0.3) : Color.clear
                    )
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(NSColor.controlBackgroundColor))
        )
    }
}

// MARK: - Preview

#Preview("TehaiView - Full") {
    VStack(spacing: 20) {
        TehaiView(
            tiles: ["1m", "2m", "3m", "4p", "5pr", "6p", "7s", "8s", "9s", "E", "E", "S", "S"],
            tsumo: "C",
            highlightedTile: "5pr",
            showLabels: true
        )

        TehaiView(
            tiles: ["1m", "1m", "1m", "2m", "3m", "4m", "5mr", "6m", "7m", "8m", "9m", "9m", "9m"],
            tsumo: nil,
            highlightedTile: "5mr"
        )
    }
    .padding()
    .frame(width: 600)
}

#Preview("CompactTehaiView") {
    CompactTehaiView(
        tiles: ["1m", "2m", "3m", "4p", "5pr", "6p", "7s", "8s", "9s", "E", "E", "S", "S"],
        tsumo: "C",
        highlightedTile: "5pr"
    )
    .padding()
}
