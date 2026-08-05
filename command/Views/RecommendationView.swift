//
//  RecommendationView.swift
//  Naki
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
                .accessibilityLabel(rankAccessibilityLabel)

            // 動作類型標籤
            Text(recommendation.actionType.displayName)
                .font(.caption2)
                .fontWeight(.medium)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(recommendation.actionType.color.opacity(0.2))
                .foregroundColor(recommendation.actionType.color)
                .cornerRadius(3)

            // 牌面（放大顯示）。
            // 只有打牌列有牌面可畫：立直推薦從不帶牌（宣言牌是同批的第一個打牌列，
            // executor 也是這樣取），走牌面分支只會 fallback 成 raw 標籤「reach」
            // ——2026-08-05 顯示掃描抓到的問題，改走 displayLabel 顯示「立直」。
            if recommendation.actionType == .discard {
                // 固定字級 28/22 保留：此列為固定 40pt 寬版面，改用 Dynamic Type 會與機率條/百分比欄位錯位，風險高故僅補 a11y
                Text(recommendation.tileUnicode)
                    .font(.system(size: isTop ? 28 : 22))
                    .foregroundColor(recommendation.isRed ? .red : .primary)
                    // glyph 對 VoiceOver 無意義，改用共用牌名
                    .accessibilityLabel(tileAccessibleName)
            } else {
                // ⭐ 使用 displayLabel 來顯示友好的標籤（如 吃①, 吃②, 吃③）
                Text(recommendation.displayLabel)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // 實際牌組補充（雲端 reaction 帶 consumed 時才有：
            // 「用 4m·5m 吃 3m」）；本地 mask 只有粗變體 ⇒ 無此行
            if let detail = recommendation.detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            // 機率
            ViewThatFits(in: .horizontal) {
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
                    .accessibilityHidden(true)  // 純視覺 meter，語意由相鄰百分比欄位承載
                    
                    // 百分比
                    Text(recommendation.percentageString)
                        .font(.system(.caption2, design: .monospaced))
                        .fontWeight(isTop ? .bold : .regular)
                        .foregroundColor(isTop ? .primary : .secondary)
                        .frame(width: 40, alignment: .trailing)
                        // 機率顏色分級（綠/橙/紅）本身無文字，合併成「推薦度高/中/低，百分比」給 VoiceOver
                        .accessibilityLabel(probabilityAccessibilityLabel)
                }
                
                // 百分比
                Text(recommendation.percentageString)
                    .font(.system(.caption2, design: .monospaced))
                    .fontWeight(isTop ? .bold : .regular)
                    .foregroundColor(isTop ? .primary : .secondary)
                    .frame(width: 40, alignment: .trailing)
                    // 窄版面（無機率條）同樣補顏色分級文字，讓推薦度讀得出
                    .accessibilityLabel(probabilityAccessibilityLabel)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(isTop ? Color.yellow.opacity(0.15) : Color.clear)
        .cornerRadius(6)
        // 整列由多個碎片組成，合併成單一可讀元素（理想讀成：第N推薦，打五萬，45%，最佳）
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("recommendation-row-\(rank - 1)")
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

    // MARK: - Accessibility

    /// 牌的可讀名稱（VoiceOver 用），共用 MahjongTile.accessibleName
    private var tileAccessibleName: String {
        MahjongTile(mjai: recommendation.displayTile).accessibleName
    }

    /// 排名可讀標籤，最佳（top）推薦補「最佳」文字線索（原本只靠黃底 + 粗體）
    private var rankAccessibilityLabel: String {
        isTop ? "第 \(rank) 推薦，最佳" : "第 \(rank) 推薦"
    }

    /// 機率顏色分級對應的文字 + 百分比（門檻與 probabilityColor 一致）
    private var probabilityAccessibilityLabel: String {
        let grade: String
        if recommendation.probability > 0.5 {
            grade = "推薦度高"
        } else if recommendation.probability > 0.2 {
            grade = "推薦度中"
        } else {
            grade = "推薦度低"
        }
        return "\(grade)，\(recommendation.percentageString)"
    }
}

// MARK: - Recommendation List View

/// AI 推薦列表。
///
/// 這個 View 不認得任何 service：目前模式與「重新載入 Bot」的行為都是參數
/// ——模式是一個 Bool，動作是一個可 stub 的 `ForceReconnectAction`。
/// 改成從環境撈的話，「按下去到底會發生什麼」就無法在不啟動整個 App 的情況下換掉，
/// Preview 也只剩靜態畫面。
struct RecommendationView: View {

    var recommendations: [Recommendation]
    var maxDisplay: Int = 5

    /// `.off` 模式下不顯示推薦。
    ///
    /// 這裡是 `AutoPlayMode.showRecommendation` 在側欄的讀取端。少了它，選「關閉」
    /// 只會擋掉送出，側欄照樣一列一列列出推薦——介面因此在說謊，關掉的功能還在畫面上動。
    ///
    /// 預設 true：Preview 不必先接上真的狀態就能看見內容。
    var showsRecommendations: Bool = true

    /// 「重新載入 Bot」按鈕做的事（強制斷線重連）。
    ///
    /// 預設是 `.unavailable`（什麼都不做並回報 not_wired），所以 Preview 按下去
    /// 不會有副作用；正式路徑由 `ContentView` 注入 `ForceReconnectAction(viewModel:)`。
    var reloadBot: ForceReconnectAction = .unavailable

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

                if !showsRecommendations {
                    Text("已關閉")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .accessibilityIdentifier("recommendation-off-badge")
                } else if recommendations.isEmpty {
                    Button(action: {
                        Task { await reloadBot() }
                    }) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("重新載入 Bot")
                    .accessibilityLabel("重新載入 Bot")
                    .accessibilityIdentifier("recommendation-reload-button")
                }else{
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
            if !showsRecommendations {
                RecommendationsDisabledView()
            } else if recommendations.isEmpty {
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

// MARK: - Disabled State（模式 = 關閉）

/// 「關閉」模式的空狀態。
///
/// 刻意跟 `EmptyRecommendationView`（等待資料）分開：兩者都是空白，但成因完全不同，
/// 用同一個畫面會讓「我關掉了」跟「Bot 還沒算出來」看不出差別。
struct RecommendationsDisabledView: View {
    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "eye.slash")
                .font(.body)
                .foregroundColor(.secondary)
            Text("推薦顯示已關閉")
                .font(.caption2)
                .foregroundColor(.secondary)
            Text("切換到「推薦」或「自動」可恢復")
                .font(.caption2)
                .foregroundColor(.secondary.opacity(0.7))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("recommendation-disabled-state")
        .accessibilityLabel("AI 推薦")
        .accessibilityValue("推薦顯示已關閉")
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

/// 這個 View 能只靠 stub Action 拉起來。
///
/// 空推薦時標題列會出現「重新載入 Bot」按鈕，正式路徑上它會真的關掉 WebSocket；
/// 這裡換成一個只印字的 stub，Preview 因此可以按而不會有任何副作用。
///
/// ⚠️ `#if DEBUG` 是必要的，不是保守：`ENABLE_PREVIEWS = YES` 在 Release 也成立，
/// 所以 `#Preview` 的內容**會被 Release 編譯**，而 `ForceReconnectAction(stub:)`
/// 本身是 `#if DEBUG`。少了這個 guard，`xcodebuild -configuration Release` 會以
/// 「argument passed to call that takes no arguments」失敗。
#if DEBUG
    #Preview("RecommendationView - stub Action") {
        RecommendationView(
            recommendations: [],
            reloadBot: ForceReconnectAction(stub: {
                print("[Preview] forceReconnect stub 被呼叫")
                return .closed(2)
            }))
            .frame(width: 300, height: 150)
            .padding()
    }
#endif

/// 模式 = 關閉：與「等待遊戲數據」刻意分成兩個空狀態
#Preview("RecommendationView - 已關閉") {
    RecommendationView(
        recommendations: [
            Recommendation(tile: "5mr", probability: 0.45, actionType: .discard)
        ],
        showsRecommendations: false)
        .frame(width: 300, height: 150)
        .padding()
}

#Preview("CompactRecommendationView") {
    CompactRecommendationView(recommendations: [
        Recommendation(tile: "5mr", probability: 0.45, actionType: .discard),
    ])
    .padding()
}
