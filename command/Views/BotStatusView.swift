//
//  BotStatusView.swift
//  Naki
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

    /// 「重新載入」按鈕做的事（強制斷線重連）。
    ///
    /// 由外面交進來、可以 stub，而不是這個 View 自己去環境裡撈頁面 service：
    /// 一顆按鈕不該把整個 App 的型別拖進 View 的簽章，Preview 也才換得掉
    /// 「按下去會發生什麼」。
    var reloadBot: ForceReconnectAction = .unavailable

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
                // 運行狀態靠顏色（綠/灰）+ 文字，合併為單一無障礙元素並提供狀態值
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Bot 運行狀態")
                .accessibilityValue(botStatus.isActive ? "運行中" : "待機")
                Button(action: {
                    Task { await reloadBot() }
                }) {
                    Image(systemName: "arrow.clockwise")
                }
                .help("重新載入")
                .accessibilityLabel("重新載入")
                .accessibilityIdentifier("bot-status-reload-button")
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

                // ☁️ 雲端推論常駐指示（pluggable-bots-plan 安全節第 3 條）：
                // 只要對局資料正在送往外部主機，就必須一直看得到。
                // 退化時整行轉紅色警示——「現在是 rollback 的本地模型在服務」
                // 不能只靠一個小字 (local) 讓人自己發現（2026-08-06 使用者需求）。
                if let host = botStatus.cloudHost {
                    if botStatus.cloudDegraded || botStatus.cloudFallbackStreak > 0 {
                        HStack(alignment: .top, spacing: 4) {
                            Image(systemName: "icloud.slash.fill")
                                .font(.caption)
                            Text(botStatus.is3P
                                 ? "雲端失敗——本手無推薦（三麻不用本地，連續 \(botStatus.cloudFallbackStreak) 手，自動重試中）"
                                 : "雲端失敗——正在用本地模型（連續 \(botStatus.cloudFallbackStreak) 手，自動重試中）")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .foregroundColor(.red)
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.12))
                        .cornerRadius(6)
                        .accessibilityIdentifier("cloud-degraded-indicator")
                    } else {
                        HStack(spacing: 4) {
                            Image(systemName: "icloud.and.arrow.up")
                                .font(.caption)
                            Text("對局資料送往 \(host)（\(botStatus.decisionSource)）")
                                .font(.caption)
                        }
                        .foregroundColor(.orange)
                        .accessibilityIdentifier("cloud-inference-indicator")
                    }
                }

                // 三麻：明講不支援，而不是讓使用者以為 AI 正常運作；
                // 雲端 3p 決策服務中不顯示，fallback 手警告如實回來
                if botStatus.is3P && !botStatus.isCloudDecision {
                    SanmaUnsupportedNotice()
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

// MARK: - Sanma Notice

/// 三麻對局的能力聲明。
///
/// 內建 Core ML 只有四麻一份（obs 1012×34、action 46）。三麻的牌山、規則與
/// observation 佈局都不同（沒有 2m–8m、北是拔北寶牌、只有三家的分數與河），
/// 拿四麻模型推三麻不是「稍微偏差」而是**結構上無效**。
///
/// 因此自動送出在三麻一律停用（`AutoPlayGate` / `AutoPlayDecisionResolver` /
/// `AutoPlayEngine.runManualCycle` 三層 fail-closed），這裡負責把這件事說出來——
/// 「不能運作又不說」正是 AUDIT §13 要防的。
struct SanmaUnsupportedNotice: View {
    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundColor(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("三麻僅雲端推論")
                    .font(.caption)
                    .fontWeight(.semibold)
                Text("本地四麻模型不啟動；雲端未生效時沒有推薦、自動打牌停用。")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12))
        .cornerRadius(6)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("sanma-unsupported-notice")
        .accessibilityLabel("三麻不支援")
        .accessibilityValue("內建只有四麻模型，推薦結果無效；自動打牌已停用")
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
        // 「我」原本只靠粗體 + 藍底，補文字線索「（我）」讓 VoiceOver 讀得出座位歸屬
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isPlayer ? "\(windName)（我）" : windName)
        .accessibilityValue("\(formattedScore) 點")
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
                // 拔北只在三麻對局出現——四麻永遠不可能亮，常駐只是噪音
                if botStatus.is3P {
                    ActionBadge(name: "拔北", isAvailable: botStatus.canKita, color: .teal)
                }
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
            // 可用性原本只靠顏色/透明度，補 VoiceOver 可讀的可用/不可用值
            .accessibilityLabel(name)
            .accessibilityValue(isAvailable ? "可用" : "不可用")
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
                        // glyph 對 VoiceOver 無意義，改用共用牌名（紅牌名稱已含「紅」前綴，不僅靠顏色）
                        .accessibilityLabel(mahjongTile.accessibleName)
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

#Preview("BotStatusView - 三麻") {
    BotStatusView(
        botStatus: BotStatus(isActive: true, modelName: "mortal", playerId: 0, is3P: true),
        gameState: GameState(kyoku: 1, jikaze: .south, is3P: true)
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
