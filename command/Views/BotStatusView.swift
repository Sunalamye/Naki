//
//  BotStatusView.swift
//  akagi
//
//  Created by Suoie on 2025/11/30.
//  Bot 狀態顯示元件
//  Updated: 2025/12/01 - 使用 GameModels 強類型
//

import SwiftUI
import MortalSwift

// MARK: - Bot Status View

struct BotStatusView: View {
    var botStatus: BotStatus
    var gameState: GameState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 標題
            HStack {
                Image(systemName: "cpu")
                    .foregroundColor(.orange)
                Text("Bot 狀態")
                    .font(.headline)

                Spacer()

                // 運行狀態指示
                HStack(spacing: 4) {
                    Circle()
                        .fill(botStatus.isActive ? Color.green : Color.gray)
                        .frame(width: 8, height: 8)
                    Text(botStatus.isActive ? "運行中" : "待機")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.contentBackground)

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                // 模型信息
                HStack {
                    Label(botStatus.modelDisplayName, systemImage: "brain")
                        .font(.subheadline)

                    Spacer()

                    Text("Player \(botStatus.playerId)")
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.2))
                        .cornerRadius(4)
                }

                Divider()

                // 遊戲信息
                GameInfoRow(gameState: gameState)

                Divider()

                // 可用動作
                AvailableActionsView(botStatus: botStatus)

                // 寶牌
                if !gameState.doraIndicators.isEmpty {
                    Divider()
                    DoraIndicatorsView(indicators: gameState.doraIndicators)
                }
            }
            .padding(12)
        }
        .background(Color.windowBackground)
        .cornerRadius(8)
        .shadow(color: .black.opacity(0.1), radius: 4)
    }
}

// MARK: - Game Info Row

struct GameInfoRow: View {
    var gameState: GameState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                // 局數
                VStack(alignment: .leading, spacing: 2) {
                    Text("局")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(gameState.kyokuDisplayName)
                        .font(.subheadline)
                        .fontWeight(.medium)
                }

                Spacer()

                // 本場
                VStack(alignment: .center, spacing: 2) {
                    Text("本場")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text("\(gameState.honba)")
                        .font(.subheadline)
                }

                Spacer()

                // 供託
                VStack(alignment: .center, spacing: 2) {
                    Text("供託")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text("\(gameState.riichiBou)")
                        .font(.subheadline)
                }

                Spacer()

                // 自風
                VStack(alignment: .trailing, spacing: 2) {
                    Text("自風")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(gameState.jikazeDisplay)
                        .font(.subheadline)
                        .fontWeight(.medium)
                }
            }

            // 點數 (限制最多 4 人)
            HStack(spacing: 8) {
                ForEach(0..<min(gameState.scores.count, 4), id: \.self) { index in
                    ScoreLabel(
                        index: index,
                        score: gameState.scores[index],
                        isPlayer: index == gameState.playerId
                    )
                }
            }
        }
    }
}

// MARK: - Score Label

struct ScoreLabel: View {
    var index: Int
    var score: Int
    var isPlayer: Bool

    var body: some View {
        VStack(spacing: 2) {
            Text(windName)
                .font(.caption2)
                .foregroundColor(.secondary)
            Text(formattedScore)
                .font(.system(.caption, design: .monospaced))
                .fontWeight(isPlayer ? .bold : .regular)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .background(isPlayer ? Color.blue.opacity(0.1) : Color.clear)
        .cornerRadius(4)
    }

    private var windName: String {
        let winds = ["東", "南", "西", "北"]
        guard index >= 0 && index < winds.count else { return "?" }
        return winds[index]
    }

    private var formattedScore: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: score)) ?? "\(score)"
    }
}

// MARK: - Available Actions View

struct AvailableActionsView: View {
    var botStatus: BotStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("可用動作")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack(spacing: 6) {
                ActionBadge(name: "打", isAvailable: botStatus.canDiscard)
                ActionBadge(name: "立直", isAvailable: botStatus.canRiichi, color: .orange)
                ActionBadge(name: "吃", isAvailable: botStatus.canChi, color: .green)
                ActionBadge(name: "碰", isAvailable: botStatus.canPon, color: .purple)
                ActionBadge(name: "槓", isAvailable: botStatus.canKan, color: .red)
                ActionBadge(name: "和", isAvailable: botStatus.canAgari, color: .yellow)
            }
        }
    }
}

// MARK: - Action Badge

struct ActionBadge: View {
    var name: String
    var isAvailable: Bool
    var color: Color = .blue

    var body: some View {
        Text(name)
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(isAvailable ? color.opacity(0.2) : Color.gray.opacity(0.1))
            .foregroundColor(isAvailable ? color : .secondary.opacity(0.5))
            .cornerRadius(4)
    }
}

// MARK: - Dora Indicators View

struct DoraIndicatorsView: View {
    var indicators: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("寶牌指示牌")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack(spacing: 4) {
                ForEach(Array(indicators.enumerated()), id: \.offset) { _, tile in
                    let mahjongTile = MahjongTile(mjai: tile)
                    Text(mahjongTile.unicode)
                        .font(.title3)
                        .foregroundColor(mahjongTile.isRed ? .red : .primary)
                }
            }
        }
    }
}

// MARK: - Compact Bot Status

struct CompactBotStatusView: View {
    var botStatus: BotStatus
    var gameState: GameState

    var body: some View {
        HStack(spacing: 12) {
            // Bot 狀態
            HStack(spacing: 4) {
                Circle()
                    .fill(botStatus.isActive ? Color.green : Color.gray)
                    .frame(width: 6, height: 6)
                Text(botStatus.modelDisplayName)
                    .font(.caption)
            }

            Divider()
                .frame(height: 12)

            // 局數
            Text(gameState.kyokuDisplayName)
                .font(.caption)
                .fontWeight(.medium)

            // 自風
            Text(gameState.jikazeDisplay)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.contentBackground)
        )
    }
}

// MARK: - Preview

#Preview("BotStatusView") {
    BotStatusView(
        botStatus: BotStatus(
            isActive: true,
            modelName: "mortal",
            playerId: 0,
            canDiscard: true,
            canRiichi: true,
            canChi: false,
            canPon: true,
            canKan: false,
            canAgari: false
        ),
        gameState: GameState(
            kyoku: 1,
            honba: 1,
            kyotaku: 2,
            bakaze: .east,
            jikaze: .south,
            scores: [25000, 24000, 26000, 25000],
            playerId: 0,
            doraMarkers: [.man(5), .pin(3)]
        )
    )
    .frame(width: 320)
    .padding()
}

#Preview("CompactBotStatusView") {
    CompactBotStatusView(
        botStatus: BotStatus(isActive: true, modelName: "mortal"),
        gameState: GameState(kyoku: 1, jikaze: .south)
    )
    .padding()
}
