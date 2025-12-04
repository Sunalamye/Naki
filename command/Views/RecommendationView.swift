//
//  RecommendationView.swift
//  akagi
//
//  Created by Suoie on 2025/11/30.
//  AI 推薦列表元件 - 顯示 Bot 推薦的動作
//  Updated: 2025/12/01 - 使用 GameModels 強類型
//

import SwiftUI
import MortalSwift

// MARK: - Single Recommendation Row

struct RecommendationRow: View {
    let recommendation: Recommendation
    let rank: Int
    var isTop: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            // 排名
            Text("#\(rank)")
                .font(.system(.caption2, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 18)

            // 動作類型標籤
            Text(recommendation.actionType.displayName)
                .font(.caption2)
                .fontWeight(.medium)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(recommendation.actionType.color.opacity(0.2))
                .foregroundColor(recommendation.actionType.color)
                .cornerRadius(3)

            // 牌面（放大顯示）
            if recommendation.actionType == .discard || recommendation.actionType == .riichi {
                Text(recommendation.tileUnicode)
                    .font(.system(size: isTop ? 28 : 22))
                    .foregroundColor(recommendation.isRed ? .red : .primary)
            } else {
                // ⭐ 使用 displayLabel 來顯示友好的標籤（如 吃①, 吃②, 吃③）
                Text(recommendation.displayLabel)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            // 機率
            HStack(spacing: 3) {
                // 機率條
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(Color.gray.opacity(0.2))
                            .frame(height: 4)
                            .cornerRadius(2)

                        Rectangle()
                            .fill(probabilityColor)
                            .frame(width: geometry.size.width * recommendation.probability, height: 4)
                            .cornerRadius(2)
                    }
                }
                .frame(width: 40, height: 4)

                // 百分比
                Text(recommendation.percentageString)
                    .font(.system(.caption2, design: .monospaced))
                    .fontWeight(isTop ? .bold : .regular)
                    .foregroundColor(isTop ? .primary : .secondary)
                    .frame(width: 40, alignment: .trailing)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(isTop ? Color.yellow.opacity(0.15) : Color.clear)
        .cornerRadius(6)
    }

    private var probabilityColor: Color {
        if recommendation.probability > 0.5 {
            return .green
        } else if recommendation.probability > 0.2 {
            return .orange
        } else {
            return .red
        }
    }
}

// MARK: - Recommendation List View

struct RecommendationView: View {
    var recommendations: [Recommendation]
    var maxDisplay: Int = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 標題
            HStack {
                Image(systemName: "brain.head.profile")
                    .font(.caption)
                    .foregroundColor(.purple)
                Text("AI 推薦")
                    .font(.caption)
                    .fontWeight(.semibold)

                Spacer()

                if !recommendations.isEmpty {
                    Text("\(recommendations.count) 選項")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.contentBackground)

            Divider()

            // 推薦列表
            if recommendations.isEmpty {
                EmptyRecommendationView()
            } else {
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(Array(displayRecommendations.enumerated()), id: \.element.id) { index, rec in
                            RecommendationRow(
                                recommendation: rec,
                                rank: index + 1,
                                isTop: index == 0
                            )
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .background(Color.windowBackground)
        .cornerRadius(6)
        .shadow(color: .black.opacity(0.1), radius: 2)
    }

    private var displayRecommendations: [Recommendation] {
        Array(recommendations.prefix(maxDisplay))
    }
}

// MARK: - Empty State

struct EmptyRecommendationView: View {
    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "questionmark.circle")
                .font(.body)
                .foregroundColor(.secondary)
            Text("等待遊戲數據...")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}

// MARK: - Compact Recommendation View (單行顯示)

struct CompactRecommendationView: View {
    var recommendations: [Recommendation]

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "brain")
                .foregroundColor(.purple)

            if let top = recommendations.first {
                HStack(spacing: 4) {
                    Text(top.actionType.displayName)
                        .font(.caption)
                        .fontWeight(.medium)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(top.actionType.color.opacity(0.2))
                        .foregroundColor(top.actionType.color)
                        .cornerRadius(3)

                    if top.actionType == .discard || top.actionType == .riichi {
                        Text(top.tileUnicode)
                            .font(.body)
                            .foregroundColor(top.isRed ? .red : .primary)
                    }

                    Text(top.percentageString)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            } else {
                Text("無推薦")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
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

#Preview("RecommendationView") {
    RecommendationView(recommendations: [
        Recommendation(tile: "5mr", probability: 0.45, actionType: .discard),
        Recommendation(tile: "9s", probability: 0.25, actionType: .discard),
        Recommendation(tile: "E", probability: 0.15, actionType: .discard),
        Recommendation(tile: "1m", probability: 0.10, actionType: .discard),
        Recommendation(tile: "N", probability: 0.05, actionType: .discard),
    ])
    .frame(width: 300, height: 250)
    .padding()
}

#Preview("RecommendationView - Actions") {
    RecommendationView(recommendations: [
        Recommendation(tile: "reach", probability: 0.60, actionType: .riichi),
        Recommendation(tile: "5mr", probability: 0.30, actionType: .discard),
        Recommendation(tile: "none", probability: 0.10, actionType: .none),
    ])
    .frame(width: 300, height: 200)
    .padding()
}

#Preview("RecommendationView - Empty") {
    RecommendationView(recommendations: [])
        .frame(width: 300, height: 150)
        .padding()
}

#Preview("CompactRecommendationView") {
    CompactRecommendationView(recommendations: [
        Recommendation(tile: "5mr", probability: 0.45, actionType: .discard),
    ])
    .padding()
}
