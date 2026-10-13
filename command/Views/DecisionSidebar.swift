//
//  DecisionSidebar.swift
//  Naki
//
//  即時決策側欄 —— 依 docs/ui-reference/action-states/prototype.html 實作。
//

import SwiftUI

// MARK: - Decision Sidebar

/// 對局中的決策側欄。
///
/// 取代原本「Bot 狀態卡在上、AI 推薦卡在下」的排法。那個順序把使用者唯一
/// 每手都要看的東西（這手打什麼）壓在約 260pt 的狀態資訊底下，而狀態資訊
/// （模型名、本場、供託）大多數時候是不變的常數。
///
/// 現在的順序是：**答案 → 次選 → 細節（收合）**。局況與模型收進摘要條，
/// 點開才展開——摘要條本身就是那份資料的 summary，不再是兩列講同一件事。
///
/// `compact` 給 iPhone 橫向的右側常駐欄用（220pt 欄寬，內容約 200pt）。它不是
/// 等比縮小：摘要條在窄寬度下只留局況與自風，點數與模型降級到展開層，否則四欄
/// 會各自縮到 10pt 而全部不可讀。
struct DecisionSidebar: View {

    @Environment(\.naki) private var naki

    /// 窄版（iPhone HUD）。影響字級、牌面尺寸與摘要條的欄位數。
    var compact: Bool = false

    @State private var detailsExpanded = false

    private var store: GameStore { naki.store }
    private var showsRecommendations: Bool { store.autoPlayMode.showRecommendation }
    private var recommendations: [Recommendation] { store.recommendations }

    /// 次選最多顯示幾個。
    ///
    /// iPhone 橫向的欄位扣掉控制列與狀態訊息只剩約 300pt，三個次選要捲才看得完。
    /// 側欄現在是可捲的，所以這不再是「會被裁掉」的問題，而是「掃一眼要看幾個」——
    /// 第三順位的期望值差距通常已經小於決策雜訊，把它收在捲軸外面換取不必捲。
    private var maxOptions: Int { compact ? 2 : 3 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SidebarHeader(isActive: store.botStatus.isActive, compact: compact)

            GameSummaryDisclosure(
                gameState: store.gameState,
                botStatus: store.botStatus,
                cloudConfigured: naki.settings.cloudConfig.missingRequirements.isEmpty,
                inGame: store.isInGame,
                compact: compact,
                isExpanded: $detailsExpanded
            )
            .padding(.bottom, compact ? PanelLayout.Spacing.s8 : PanelLayout.Spacing.s12)

            DecisionAlerts(botStatus: store.botStatus,
                           autoPlayStall: store.autoPlayStall,
                           compact: compact)

            if !showsRecommendations {
                RecommendationsDisabledView()
            } else if let top = recommendations.first {
                SectionLabel("最佳選擇", compact: compact)
                DecisionCard(recommendation: top, compact: compact)

                // 展開細節時「其他選項」讓位：側欄容不下兩者，而次選是可犧牲的
                // 那個——決策卡不讓位，那是掃一眼要的答案。
                if !detailsExpanded {
                    let others = Array(recommendations.dropFirst())
                    if !others.isEmpty {
                        SectionLabel("其他選項", compact: compact)
                        OptionList(options: others, maxDisplay: maxOptions, compact: compact)
                    }
                }
            } else {
                EmptyRecommendationView()
            }

            // 窄版不放 Spacer：它現在活在 `ScrollView` 裡（iOS 右側欄），而
            // ScrollView 內的 Spacer 會把可捲內容撐成無限高。
            // macOS 側欄版要 Spacer 把內容釘在頂端（固定寬度，撐滿是預期的）。
            if !compact {
                Spacer(minLength: 0)
            }
        }
        .padding(compact ? PanelLayout.Spacing.s10 : PanelLayout.Spacing.s16)
    }
}

// MARK: - Header

struct SidebarHeader: View {
    var isActive: Bool
    var compact: Bool = false

    var body: some View {
        HStack(spacing: PanelLayout.Spacing.s6) {
            Text("即時決策")
                .font(compact ? .subheadline : .title3)
                .bold()

            Spacer()

            Circle()
                .fill(isActive ? PanelLayout.success : PanelLayout.neutral)
                .frame(width: 7, height: 7)
            (isActive ? Text("運行中") : Text("待機"))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, compact ? PanelLayout.Spacing.s8 : PanelLayout.Spacing.s12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Bot 運行狀態")
        .accessibilityValue(isActive ? Text("運行中") : Text("待機"))
    }
}

// MARK: - Section Label

struct SectionLabel: View {
    let text: LocalizedStringKey
    var compact: Bool = false

    init(_ text: LocalizedStringKey, compact: Bool = false) {
        self.text = text
        self.compact = compact
    }

    var body: some View {
        Text(text)
            .font(compact ? .caption2 : .caption)
            .bold()
            .foregroundStyle(.secondary)
            .padding(.top, compact ? PanelLayout.Spacing.s8 : PanelLayout.Spacing.s12)
            .padding(.bottom, compact ? PanelLayout.Spacing.s6 : PanelLayout.Spacing.s8)
    }
}

// MARK: - Summary Disclosure

/// 摘要條＝細節的展開器。
///
/// 舊版側欄有兩列在講同一份資料：一列摘要（局況／自風／點數／模型），
/// 另一列「牌局與模型資訊」在很下面負責展開它。合併之後收合狀態少一列，
/// 而細節長在自己的摘要正下方。
struct GameSummaryDisclosure: View {
    var gameState: GameState
    var botStatus: BotStatus
    var cloudConfigured: Bool
    /// 是否真的在對局中。
    ///
    /// `GameState` 的預設值是「東1局・東家・25,000」，在大廳時照樣會被畫出來——
    /// 2026-08-09 實測時 App 停在大廳，側欄卻宣稱正在打東 1 局。摘要條寧可說
    /// 「未在對局」，也不能顯示一個不存在的牌局。
    var inGame: Bool
    var compact: Bool
    @Binding var isExpanded: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(PanelLayout.animation(PanelLayout.standard, reduceMotion: reduceMotion)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: compact ? PanelLayout.Spacing.s10 : PanelLayout.Spacing.s6) {
                    if inGame {
                        Text(gameState.kyokuDisplayKey)
                            .fontWeight(.semibold)
                        Spacer(minLength: PanelLayout.Spacing.s4)
                        // `jikazeDisplay` 已經含「家」（「北家」），再加「自風」前綴會變成
                        // 「自風 北家」——實測畫面上讀起來是兩個詞疊在一起
                        Text(gameState.jikazeDisplayKey)
                        // 窄版只留局況與自風：190pt 塞四欄會讓每欄縮到讀不了
                        if !compact {
                            Spacer(minLength: PanelLayout.Spacing.s4)
                            Text(myScore).monospacedDigit()
                                .contentTransition(.numericText(value: Double(myScoreValue ?? 0)))
                                .animation(PanelLayout.animation(PanelLayout.valueChange, reduceMotion: reduceMotion), value: myScoreValue)
                            Spacer(minLength: PanelLayout.Spacing.s4)
                            Text(botStatus.modelDisplayKey)
                        }
                    } else {
                        Text("未在對局")
                            .foregroundStyle(.secondary)
                        Spacer(minLength: PanelLayout.Spacing.s4)
                        Text(botStatus.modelDisplayKey)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: PanelLayout.Spacing.s4)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                        .foregroundStyle(.secondary)
                }
                .font(compact ? .caption2 : .caption)
                .padding(.horizontal, PanelLayout.Spacing.s10)
                .padding(.vertical, compact ? PanelLayout.Spacing.s6 : PanelLayout.Spacing.s10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("game-summary-disclosure")
            .accessibilityLabel("牌局資訊")
            .accessibilityValue(isExpanded ? Text("已展開") : Text("已收合"))
            .accessibilityHint("展開後顯示四家點數、寶牌與模型來源")

            // 授權動作常駐在摘要條底下，不再藏進展開層。
            //
            // 它回答的是「現在能做什麼」——那跟局況同屬「此刻的狀態」，要點開才看得到
            // 就等於每一手都要多一次互動。放進同一張卡片（而不是卡片外另起一塊）是因為
            // 兩者是同一個資訊塊，多一圈邊框只會多吃 iOS 右側欄稀缺的垂直空間。
            //
            // `inGame` 是必要的：不在對局時六個 badge 全灰、永遠不會亮，常駐顯示只是
            // 噪音——與「拔北只在三麻出現」同一個判斷。
            if inGame {
                Divider()
                AuthorizedActionsRow(botStatus: botStatus)
                    .padding(.horizontal, PanelLayout.Spacing.s10)
                    .padding(.top, compact ? PanelLayout.Spacing.s8 : PanelLayout.Spacing.s10)
                    .padding(.bottom, compact ? PanelLayout.Spacing.s8 : PanelLayout.Spacing.s10)
            }

            if isExpanded {
                Divider()
                GameDetailsPanel(gameState: gameState,
                                 inGame: inGame,
                                 botStatus: botStatus,
                                 cloudConfigured: cloudConfigured,
                                 compact: compact)
            }
        }
        .background(Color.contentBackground)
        .clipShape(RoundedRectangle(cornerRadius: PanelLayout.Radius.row))
        .overlay {
            RoundedRectangle(cornerRadius: PanelLayout.Radius.row)
                .strokeBorder(Color.secondary.opacity(PanelLayout.Opacity.neutral), lineWidth: 1)
        }
    }

    private var myScoreValue: Int? {
        let id = gameState.playerId
        guard id >= 0, id < gameState.scores.count else { return nil }
        return gameState.scores[id]
    }

    private var myScore: String { myScoreValue?.formatted(.number) ?? "—" }
}

// MARK: - Details Panel

struct GameDetailsPanel: View {
    var gameState: GameState
    var inGame: Bool = true
    var botStatus: BotStatus
    var cloudConfigured: Bool
    var compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: PanelLayout.Spacing.s10) {
            if !inGame {
                Text("目前不在對局中，以下牌局欄位沒有實際資料。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            group("牌局") {
                pair("局況", Text("\(Text(gameState.kyokuDisplayKey))・\(gameState.honba) 本場"))
                pair("供託", Text("\(gameState.riichiBou) 本"))
                pair("我的座位", Text("Player \(gameState.playerId)・\(Text(gameState.jikazeDisplayKey))"))
                pair("規則", gameState.is3P ? Text("三人麻將") : Text("四人麻將"))
            }

            ScoreRow(gameState: gameState)

            if !gameState.doraIndicators.isEmpty {
                HStack(spacing: PanelLayout.Spacing.s6) {
                    Text("寶牌指示牌")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    ForEach(Array(gameState.doraIndicators.enumerated()), id: \.offset) { _, t in
                        TileImage(mjai: t, size: .tiny)
                    }
                }
            }

            Divider()

            // 授權動作**不在這裡**：它移到摘要條底下常駐顯示了（見
            // `GameSummaryDisclosure`）。這裡再放一份就是同一份資料出現兩次，
            // 而展開層本來的用途就是收那些「不必每手都看」的東西。
            group("模型與資料來源") {
                pair("模型", Text(botStatus.modelDisplayKey))
                pair("建議來源", Text(verbatim: botStatus.decisionSource))
                pair("計算位置", botStatus.cloudHost.map { Text(verbatim: $0) } ?? Text("本機"))
                pair("雲端狀態", Text(cloudState))
            }
        }
        .padding(compact ? PanelLayout.Spacing.s10 : PanelLayout.Spacing.s12)
    }

    private var cloudState: LocalizedStringKey {
        if botStatus.cloudDegraded { return "改用本機" }
        if botStatus.cloudHost != nil { return "已連線" }
        return cloudConfigured ? "已設定・未使用" : "未啟用"
    }

    @ViewBuilder
    private func group(_ title: LocalizedStringKey, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: PanelLayout.Spacing.s6) {
            Text(title)
                .font(.caption2)
                .bold()
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func pair(_ label: LocalizedStringKey, _ value: Text) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: PanelLayout.Spacing.s8)
            value.fontWeight(.medium)
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Scores

struct ScoreRow: View {
    var gameState: GameState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: PanelLayout.Spacing.s6) {
            ForEach(0..<min(gameState.scores.count, gameState.is3P ? 3 : 4), id: \.self) { i in
                VStack(spacing: PanelLayout.Spacing.s2) {
                    seatWind(i)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(gameState.scores[i].formatted(.number))
                        .font(.caption2)
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(gameState.scores[i])))
                        .animation(PanelLayout.animation(PanelLayout.valueChange, reduceMotion: reduceMotion), value: gameState.scores[i])
                        .fontWeight(i == gameState.playerId ? .bold : .regular)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, PanelLayout.Spacing.s4)
                .background(i == gameState.playerId ? Color.accentColor.opacity(PanelLayout.Opacity.tint) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: PanelLayout.Radius.badge))
                .accessibilityElement(children: .combine)
                .accessibilityLabel(i == gameState.playerId ? Text("\(seatWind(i))（我）") : seatWind(i))
                .accessibilityValue("\(gameState.scores[i]) 點")
            }
        }
    }

    private func seatWind(_ i: Int) -> Text {
        Text(LocalizedStringKey(SeatWind.name(seat: i, kyoku: gameState.kyoku, is3P: gameState.is3P)))
    }
}

// MARK: - Seat Wind

/// 座位 → 這一局的自風。
///
/// **座位不是風位。** 點數陣列的 index 是座位，直接拿它當風（`winds[i]`）只有
/// 東 1 局剛好對，之後每過一局就錯一位——2026-08-09 人機場實測東 2 局時，
/// 摘要條說我是「南家」，而同一畫面的點數列把我的 33,000 標成「西」。
///
/// 風位從莊家算起，莊家是 `(kyoku - 1) % 家數`（`kyokuDisplayName` 只顯示場風與局數，不推莊家）。抽出來是為了讓 `SeatWindTests` 直接鎖住它：
/// 這種「差一位」的錯誤在東 1 局看不出來，而東 1 局正是所有 Preview 的預設值。
enum SeatWind {
    private static let winds = ["東", "南", "西", "北"]

    static func name(seat: Int, kyoku: Int, is3P: Bool) -> String {
        let count = is3P ? 3 : 4
        guard seat >= 0, seat < count, kyoku > 0 else { return "?" }
        let oya = (kyoku - 1) % count
        return winds[(seat - oya + count) % count]
    }
}

// MARK: - Authorized Actions

/// 伺服器目前授權的動作。
///
/// 「可用／不可用」不只靠顏色——但線索換過一輪：原本每個 badge 帶 ✓／✗ 符號，
/// 那讓 badge 寬到一列擺不下（見 `body` 的裁字問題）。現在改用**字重與底色深淺**
/// （可用 semibold＋較實的底，不可用 regular＋幾乎透明的底），完整措辭仍在
/// `accessibilityValue`。這比符號弱，是為了寬度做的取捨。
struct AuthorizedActionsRow: View {
    var botStatus: BotStatus

    private var items: [(LocalizedStringKey, Bool)] {
        var list: [(LocalizedStringKey, Bool)] = [
            ("打", botStatus.canDiscard),
            ("立直", botStatus.canRiichi),
            ("吃", botStatus.canChi),
            ("碰", botStatus.canPon),
            ("槓", botStatus.canKan),
            ("和", botStatus.canAgari),
        ]
        // 拔北只在三麻存在，四麻常駐一個永遠不會亮的 badge 只是噪音
        if botStatus.is3P { list.append(("拔北", botStatus.canKita)) }
        return list
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PanelLayout.Spacing.s6) {
            Text("可用動作")
                .font(.caption2)
                .bold()
                .foregroundStyle(.secondary)

            // 一列擺得下就一列，擺不下自動折兩列。
            //
            // 為什麼需要它：iOS 右側欄只有 220pt（內容約 200pt）。而 SwiftUI 在放不下
            // 時的預設行為既不是換行也不是省略號，是**把 `Text` 壓到字形被裁掉一半**
            // ——實測「打」只剩「扌」、「立直」兩字疊在一起，讀不出是哪個動作。
            // `ViewThatFits` 把那個失敗模式換成換行。
            //
            // 拿掉 ✓／✗ 之後四麻的 6 個單列就夠，三麻多一個「拔北」才會折——所以這
            // 不是兩種寬度寫死，是讓它自己量。
            ViewThatFits(in: .horizontal) {
                badgeRow(items)

                VStack(alignment: .leading, spacing: PanelLayout.Spacing.s4) {
                    let half = (items.count + 1) / 2
                    badgeRow(Array(items.prefix(half)))
                    badgeRow(Array(items.dropFirst(half)))
                }
            }
        }
        .accessibilityIdentifier("authorized-actions-row")
    }

    private func badgeRow(_ row: [(LocalizedStringKey, Bool)]) -> some View {
        HStack(spacing: PanelLayout.Spacing.s4) {
            ForEach(Array(row.enumerated()), id: \.offset) { _, item in
                badge(name: item.0, available: item.1)
            }
        }
    }

    private func badge(name: LocalizedStringKey, available: Bool) -> some View {
        Text(name)
            .font(.caption2)
            // 字重是「可用」的非顏色線索之一（另一個是底色深淺）
            .fontWeight(available ? .semibold : .regular)
            // 寧可溢出也不要被壓縮。`ViewThatFits` 是靠「量得出真實寬度」來選版面的，
            // 少了這行，第一個候選永遠「擠得下」——擠的方式就是裁掉字形。
            .fixedSize()
            .padding(.horizontal, PanelLayout.Spacing.s6)
            .padding(.vertical, PanelLayout.Spacing.s4)
            .foregroundStyle(available ? PanelLayout.success : PanelLayout.neutral)
            .background(available ? PanelLayout.success.opacity(PanelLayout.Opacity.tint) : PanelLayout.neutral.opacity(PanelLayout.Opacity.subtle))
            .clipShape(RoundedRectangle(cornerRadius: PanelLayout.Radius.badge))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(name)
            .accessibilityValue(available ? Text("可用") : Text("不可用"))
    }
}

// MARK: - Decision Card

/// 最佳選擇。側欄的主體，也是使用者唯一每手都要看的東西。
struct DecisionCard: View {
    let recommendation: Recommendation
    var compact: Bool = false

    private var tone: Color { recommendation.actionType.color }

    /// 只有打牌帶得出牌面。
    ///
    /// 立直推薦從不帶牌（宣言牌是同批的第一個打牌列）；副露的牌組只有雲端
    /// 會給，而且是 `detail` 那個字串（「用 4m·5m 吃 3m」），本地 mapper
    /// 完全不產。所以這裡不畫「三張副露牌」——那在目前的資料下是假的。
    private var showsTile: Bool { recommendation.actionType == .discard }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? PanelLayout.Spacing.s8 : PanelLayout.Spacing.s10) {
            HStack(spacing: compact ? PanelLayout.Spacing.s8 : PanelLayout.Spacing.s16) {
                if showsTile {
                    TileImage(mjai: recommendation.displayTile,
                              size: compact ? .medium : .large)
                }

                Text(recommendation.actionNameKey)
                    .font(compact ? .caption : .headline)
                    .bold()
                    .foregroundStyle(tone)
                    .padding(.horizontal, compact ? PanelLayout.Spacing.s8 : PanelLayout.Spacing.s10)
                    .padding(.vertical, compact ? PanelLayout.Spacing.s4 : PanelLayout.Spacing.s6)
                    .overlay {
                        RoundedRectangle(cornerRadius: PanelLayout.Radius.control)
                            .strokeBorder(tone.opacity(PanelLayout.Opacity.stroke), lineWidth: 1)
                    }

                Spacer(minLength: PanelLayout.Spacing.s4)

                Text(recommendation.percentageString)
                    .font(.system(compact ? .title3 : .largeTitle, design: .monospaced))
                    .bold()
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
            }

            if let detail = recommendation.detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ProbabilityBar(value: recommendation.probability, tone: tone)
        }
        .padding(compact ? PanelLayout.Spacing.s10 : PanelLayout.Spacing.s16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tone.opacity(PanelLayout.Opacity.subtle))
        .clipShape(RoundedRectangle(cornerRadius: PanelLayout.Radius.card))
        .overlay {
            RoundedRectangle(cornerRadius: PanelLayout.Radius.card)
                .strokeBorder(tone.opacity(PanelLayout.Opacity.stroke), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("decision-card")
        .accessibilityLabel("最佳選擇")
        .accessibilityValue(Text("\(Text(recommendation.displayLabelKey))，\(recommendation.percentageString)"))
    }
}

// MARK: - Probability Bar

struct ProbabilityBar: View {
    var value: Double
    var tone: Color
    var height: CGFloat = 7

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(PanelLayout.neutral.opacity(PanelLayout.Opacity.neutral))
                Capsule()
                    .fill(tone)
                    .frame(width: max(0, min(1, value)) * geo.size.width)
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)   // 語意由相鄰的百分比文字承載
    }
}

// MARK: - Options

struct OptionList: View {
    var options: [Recommendation]
    var maxDisplay: Int
    var compact: Bool

    private var shown: [Recommendation] { Array(options.prefix(maxDisplay)) }
    private var hidden: Int { max(0, options.count - maxDisplay) }

    var body: some View {
        VStack(spacing: compact ? PanelLayout.Spacing.s6 : PanelLayout.Spacing.s8) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, rec in
                OptionRow(recommendation: rec, rank: index + 2, compact: compact)
            }
            // 截斷要說出來。畫面上少了幾個選項而不講，跟「AI 只想到這些」無法區分。
            if hidden > 0 {
                Text("還有 \(hidden) 個")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("options-truncated-note")
            }
        }
    }
}

struct OptionRow: View {
    let recommendation: Recommendation
    let rank: Int
    var compact: Bool = false

    private var tone: Color { recommendation.actionType.color }

    var body: some View {
        HStack(spacing: compact ? PanelLayout.Spacing.s6 : PanelLayout.Spacing.s10) {
            Text("#\(rank)")
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .leading)

            if recommendation.actionType == .discard {
                TileImage(mjai: recommendation.displayTile, size: compact ? .tiny : .small)
            }

            Text(recommendation.actionNameKey)
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundStyle(tone)
                .padding(.horizontal, PanelLayout.Spacing.s6)
                .padding(.vertical, PanelLayout.Spacing.s2)
                .background(tone.opacity(PanelLayout.Opacity.tint))
                .clipShape(RoundedRectangle(cornerRadius: PanelLayout.Radius.badge))

            Spacer(minLength: PanelLayout.Spacing.s4)

            Text(recommendation.percentageString)
                .font(.system(.caption2, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.secondary)

            if !compact {
                ProbabilityBar(value: recommendation.probability, tone: tone, height: 5)
                    .frame(width: 44)
            }
        }
        .padding(.horizontal, compact ? PanelLayout.Spacing.s8 : PanelLayout.Spacing.s10)
        .padding(.vertical, compact ? PanelLayout.Spacing.s6 : PanelLayout.Spacing.s8)
        .background(Color.contentBackground)
        .clipShape(RoundedRectangle(cornerRadius: PanelLayout.Radius.row))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("option-row-\(rank)")
    }
}

// MARK: - Alerts

/// 需要一直看得到的異常：雲端退化、自動打牌停滯、三麻不支援。
///
/// 這些原本散在 Bot 狀態卡裡。它們與「這手打什麼」是不同性質的訊息——
/// 前者是「Naki 現在能不能信」，所以排在決策卡之前。
struct DecisionAlerts: View {
    var botStatus: BotStatus
    var autoPlayStall: AutoPlayStall?
    var compact: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: PanelLayout.Spacing.s6) {
            if cloudDegraded {
                alert(icon: "icloud.slash.fill",
                      tone: PanelLayout.danger,
                      text: botStatus.is3P
                        ? "雲端失敗，改用本機三麻（已 \(botStatus.cloudFallbackStreak) 手）"
                        : "雲端失敗，改用本機（已 \(botStatus.cloudFallbackStreak) 手）")
                    .accessibilityIdentifier("cloud-degraded-indicator")
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else if let host = botStatus.cloudHost {
                HStack(spacing: PanelLayout.Spacing.s4) {
                    Image(systemName: "icloud.and.arrow.up").font(.caption2)
                    Text("對局資料送往 \(host)")
                        .font(.caption2)
                        .lineLimit(1)
                }
                .foregroundStyle(PanelLayout.warning)
                .accessibilityIdentifier("cloud-inference-indicator")
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if let stall = autoPlayStall {
                alert(icon: "pause.circle.fill",
                      tone: PanelLayout.danger,
                      text: "自動打牌卡住 \(stall.elapsedSeconds) 秒：該出手卻沒送出（\(stall.reason)）")
                    .accessibilityIdentifier("autoplay-stall-indicator")
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if sanmaNotice {
                alert(icon: "exclamationmark.triangle.fill",
                      tone: PanelLayout.warning,
                      text: "三麻建議下一手才會出現")
                    .accessibilityIdentifier("sanma-unsupported-notice")
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.bottom, hasAny ? (compact ? PanelLayout.Spacing.s8 : PanelLayout.Spacing.s10) : 0)
        .animation(PanelLayout.animation(PanelLayout.valueChange, reduceMotion: reduceMotion), value: shown)
    }

    /// 哪幾列在畫面上；只看有無，停滯秒數每秒變動不該觸發動畫。
    private var shown: [Bool] {
        [cloudDegraded, botStatus.cloudHost != nil, autoPlayStall != nil, sanmaNotice]
    }

    private var cloudDegraded: Bool {
        botStatus.cloudHost != nil && (botStatus.cloudDegraded || botStatus.cloudFallbackStreak > 0)
    }

    private var sanmaNotice: Bool { botStatus.is3P && !botStatus.isSanmaCapableDecision }

    private var hasAny: Bool {
        botStatus.cloudHost != nil || autoPlayStall != nil || sanmaNotice
    }

    private func alert(icon: String, tone: Color, text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: PanelLayout.Spacing.s6) {
            Image(systemName: icon).font(.caption)
            Text(text)
                .font(.caption)
                .fontWeight(.semibold)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(tone)
        .padding(PanelLayout.Spacing.s6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tone.opacity(PanelLayout.Opacity.subtle))
        .clipShape(RoundedRectangle(cornerRadius: PanelLayout.Radius.control))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Empty States

// 從 `RecommendationView.swift` 搬過來的——那個檔案的其餘內容在側欄重排之後
// 沒有任何使用者了。這兩個空狀態仍然要：它們刻意分開，因為「還沒算出來」與
// 「我把顯示關掉了」都是空白畫面，但成因完全不同。

struct EmptyRecommendationView: View {
    var body: some View {
        VStack(spacing: PanelLayout.Spacing.s4) {
            Image(systemName: "questionmark.circle")
                .font(.body)
                .foregroundStyle(.secondary)
            Text("等待牌局資料…")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, PanelLayout.Spacing.s8)
    }
}

/// 「關閉」模式的空狀態。
///
/// 刻意跟 `EmptyRecommendationView`（等待資料）分開：兩者都是空白，但成因完全不同，
/// 用同一個畫面會讓「我關掉了」跟「Bot 還沒算出來」看不出差別。
struct RecommendationsDisabledView: View {
    var body: some View {
        VStack(spacing: PanelLayout.Spacing.s4) {
            Image(systemName: "eye.slash")
                .font(.body)
                .foregroundStyle(.secondary)
            Text("推薦顯示已關閉")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("切換到「推薦」或「自動」可恢復")
                .font(.caption2)
                .foregroundStyle(Color.secondary.opacity(PanelLayout.Opacity.textDim))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, PanelLayout.Spacing.s8)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("recommendation-disabled-state")
        .accessibilityLabel("AI 推薦")
        .accessibilityValue("推薦顯示已關閉")
    }
}

// MARK: - Preview

#Preview("DecisionSidebar - 寬版") {
    DecisionSidebar()
        .frame(width: 380, height: 700)
}

#Preview("DecisionCard") {
    VStack(spacing: PanelLayout.Spacing.s12) {
        DecisionCard(recommendation: Recommendation(tile: "8p", probability: 0.936,
                                                    actionType: .discard))
        DecisionCard(recommendation: Recommendation(actionType: .riichi, probability: 0.684,
                                                    label: "reach"))
        DecisionCard(recommendation: Recommendation(actionType: .chi, probability: 0.742,
                                                    label: "chi_1",
                                                    detail: "用 3m·5m 吃 4m"))
        DecisionCard(recommendation: Recommendation(tile: "5mr", probability: 0.41,
                                                    actionType: .discard), compact: true)
    }
    .padding()
    .frame(width: 380)
}
