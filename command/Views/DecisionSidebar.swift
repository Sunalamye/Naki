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
            .padding(.bottom, compact ? 8 : 12)

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
        .padding(compact ? 10 : 16)
    }
}

// MARK: - Header

struct SidebarHeader: View {
    var isActive: Bool
    var compact: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            Text("即時決策")
                .font(compact ? .subheadline : .title3)
                .fontWeight(.bold)

            Spacer()

            Circle()
                .fill(isActive ? Color.green : Color.gray)
                .frame(width: 7, height: 7)
            Text(isActive ? "運行中" : "待機")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, compact ? 7 : 12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Bot 運行狀態")
        .accessibilityValue(isActive ? "運行中" : "待機")
    }
}

// MARK: - Section Label

struct SectionLabel: View {
    let text: String
    var compact: Bool = false

    init(_ text: String, compact: Bool = false) {
        self.text = text
        self.compact = compact
    }

    var body: some View {
        Text(text)
            .font(compact ? .caption2 : .caption)
            .fontWeight(.bold)
            .foregroundStyle(.secondary)
            .padding(.top, compact ? 8 : 12)
            .padding(.bottom, compact ? 5 : 8)
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

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: compact ? 10 : 6) {
                    if inGame {
                        Text(gameState.kyokuDisplayName)
                            .fontWeight(.semibold)
                        Spacer(minLength: 4)
                        // `jikazeDisplay` 已經含「家」（「北家」），再加「自風」前綴會變成
                        // 「自風 北家」——實測畫面上讀起來是兩個詞疊在一起
                        Text(gameState.jikazeDisplay)
                        // 窄版只留局況與自風：190pt 塞四欄會讓每欄縮到讀不了
                        if !compact {
                            Spacer(minLength: 4)
                            Text(myScore).monospacedDigit()
                            Spacer(minLength: 4)
                            Text(botStatus.modelDisplayName)
                        }
                    } else {
                        Text("未在對局")
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        Text(botStatus.modelDisplayName)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                        .foregroundStyle(.secondary)
                }
                .font(compact ? .caption2 : .caption)
                .padding(.horizontal, 10)
                .padding(.vertical, compact ? 6 : 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("game-summary-disclosure")
            .accessibilityLabel("牌局與模型資訊")
            .accessibilityValue(isExpanded ? "已展開" : "已收合")
            .accessibilityHint("展開後顯示局況、四家點數、寶牌與模型來源")

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
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.secondary.opacity(0.22), lineWidth: 1)
        )
    }

    private var myScore: String {
        let id = gameState.playerId
        guard id >= 0, id < gameState.scores.count else { return "—" }
        return gameState.scores[id].formatted(.number)
    }
}

// MARK: - Details Panel

struct GameDetailsPanel: View {
    var gameState: GameState
    var inGame: Bool = true
    var botStatus: BotStatus
    var cloudConfigured: Bool
    var compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !inGame {
                Text("目前不在對局中，以下牌局欄位沒有實際資料。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            group("牌局") {
                pair("局況", "\(gameState.kyokuDisplayName)・\(gameState.honba) 本場")
                pair("供託", "\(gameState.riichiBou) 本")
                pair("我的座位", "Player \(gameState.playerId)・\(gameState.jikazeDisplay)")
                pair("規則", gameState.is3P ? "三人麻將" : "四人麻將")
            }

            ScoreRow(gameState: gameState)

            if !gameState.doraIndicators.isEmpty {
                HStack(spacing: 6) {
                    Text("寶牌指示牌")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    ForEach(Array(gameState.doraIndicators.enumerated()), id: \.offset) { _, t in
                        TileImage(mjai: t, size: .tiny)
                    }
                }
            }

            Divider()

            group("模型與資料來源") {
                pair("模型", botStatus.modelDisplayName)
                pair("決策來源", botStatus.decisionSource)
                pair("推論位置", botStatus.cloudHost ?? "本機 Core ML")
                pair("雲端狀態", cloudState)
            }

            Divider()

            AuthorizedActionsRow(botStatus: botStatus)
        }
        .padding(compact ? 10 : 12)
    }

    private var cloudState: String {
        if botStatus.cloudDegraded { return "退化中" }
        if botStatus.cloudHost != nil { return "已連線" }
        return cloudConfigured ? "已設定・未使用" : "未啟用"
    }

    @ViewBuilder
    private func group(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption2)
                .fontWeight(.bold)
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func pair(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).fontWeight(.medium)
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Scores

struct ScoreRow: View {
    var gameState: GameState

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<min(gameState.scores.count, gameState.is3P ? 3 : 4), id: \.self) { i in
                VStack(spacing: 1) {
                    Text(seatWind(i))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(gameState.scores[i].formatted(.number))
                        .font(.caption2)
                        .monospacedDigit()
                        .fontWeight(i == gameState.playerId ? .bold : .regular)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background(i == gameState.playerId ? Color.accentColor.opacity(0.16) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .accessibilityElement(children: .combine)
                .accessibilityLabel(i == gameState.playerId ? "\(seatWind(i))（我）" : seatWind(i))
                .accessibilityValue("\(gameState.scores[i]) 點")
            }
        }
    }

    private func seatWind(_ i: Int) -> String {
        SeatWind.name(seat: i, kyoku: gameState.kyoku, is3P: gameState.is3P)
    }
}

// MARK: - Seat Wind

/// 座位 → 這一局的自風。
///
/// **座位不是風位。** 點數陣列的 index 是座位，直接拿它當風（`winds[i]`）只有
/// 東 1 局剛好對，之後每過一局就錯一位——2026-08-09 人機場實測東 2 局時，
/// 摘要條說我是「南家」，而同一畫面的點數列把我的 33,000 標成「西」。
///
/// 風位從莊家算起，莊家是 `(kyoku - 1) % 家數`——與 `GameState.kyokuDisplayName`
/// 推局數用的是同一個式子。抽出來是為了讓 `SeatWindTests` 直接鎖住它：
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

    private var items: [(String, Bool)] {
        var list: [(String, Bool)] = [
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
        VStack(alignment: .leading, spacing: 5) {
            Text("伺服器目前授權動作")
                .font(.caption2)
                .fontWeight(.bold)
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

                VStack(alignment: .leading, spacing: 4) {
                    let half = (items.count + 1) / 2
                    badgeRow(Array(items.prefix(half)))
                    badgeRow(Array(items.dropFirst(half)))
                }
            }
        }
        .accessibilityIdentifier("authorized-actions-row")
    }

    private func badgeRow(_ row: [(String, Bool)]) -> some View {
        HStack(spacing: 4) {
            ForEach(row, id: \.0) { name, available in
                badge(name: name, available: available)
            }
        }
    }

    private func badge(name: String, available: Bool) -> some View {
        Text(name)
            .font(.caption2)
            // 字重是「可用」的非顏色線索之一（另一個是底色深淺）
            .fontWeight(available ? .semibold : .regular)
            // 寧可溢出也不要被壓縮。`ViewThatFits` 是靠「量得出真實寬度」來選版面的，
            // 少了這行，第一個候選永遠「擠得下」——擠的方式就是裁掉字形。
            .fixedSize()
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .foregroundStyle(available ? Color.green : Color.secondary)
            .background(available ? Color.green.opacity(0.18) : Color.gray.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(name)
            .accessibilityValue(available ? "可用" : "不可用")
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

    /// 動作名。
    ///
    /// **不能直接用 `displayLabel`**：它對打牌回傳的是牌名（`8p`），實測時決策卡
    /// 因此顯示成「[八筒圖] 8p 40.0%」——牌面已經畫在旁邊，這個 badge 卻又說了
    /// 一次同一張牌，而「要拿它做什麼」反而沒人講。其餘動作的 `displayLabel`
    /// 是對的（吃①／立直／九種九牌），那些要保留。
    private var actionName: String {
        recommendation.actionType == .discard
            ? recommendation.actionType.displayName
            : recommendation.displayLabel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 7 : 10) {
            HStack(spacing: compact ? 8 : 14) {
                if showsTile {
                    TileImage(mjai: recommendation.displayTile,
                              size: compact ? .medium : .large)
                }

                Text(actionName)
                    .font(compact ? .caption : .headline)
                    .fontWeight(.bold)
                    .foregroundStyle(tone)
                    .padding(.horizontal, compact ? 7 : 10)
                    .padding(.vertical, compact ? 3 : 6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(tone.opacity(0.7), lineWidth: 1)
                    )

                Spacer(minLength: 4)

                Text(recommendation.percentageString)
                    .font(.system(compact ? .title3 : .largeTitle, design: .monospaced))
                    .fontWeight(.bold)
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
        .padding(compact ? 10 : 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tone.opacity(0.09))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(tone.opacity(0.45), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("decision-card")
        .accessibilityLabel("最佳選擇")
        .accessibilityValue("\(recommendation.displayLabel)，\(recommendation.percentageString)")
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
                Capsule().fill(Color.gray.opacity(0.25))
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
        VStack(spacing: compact ? 5 : 7) {
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
        HStack(spacing: compact ? 6 : 9) {
            Text("#\(rank)")
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .leading)

            if recommendation.actionType == .discard {
                TileImage(mjai: recommendation.displayTile, size: compact ? .tiny : .small)
            }

            // 與 `DecisionCard.actionName` 同一個理由：打牌的 displayLabel 是牌名
            Text(recommendation.actionType == .discard
                 ? recommendation.actionType.displayName
                 : recommendation.displayLabel)
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundStyle(tone)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(tone.opacity(0.16))
                .clipShape(RoundedRectangle(cornerRadius: 4))

            Spacer(minLength: 4)

            Text(recommendation.percentageString)
                .font(.system(.caption2, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.secondary)

            if !compact {
                ProbabilityBar(value: recommendation.probability, tone: tone, height: 5)
                    .frame(width: 44)
            }
        }
        .padding(.horizontal, compact ? 7 : 10)
        .padding(.vertical, compact ? 5 : 7)
        .background(Color.contentBackground)
        .clipShape(RoundedRectangle(cornerRadius: 7))
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if botStatus.cloudHost != nil,
               botStatus.cloudDegraded || botStatus.cloudFallbackStreak > 0 {
                alert(icon: "icloud.slash.fill",
                      tone: .red,
                      text: botStatus.is3P
                        ? "雲端失敗——本手無推薦（三麻不用本地，連續 \(botStatus.cloudFallbackStreak) 手）"
                        : "雲端失敗——正在用本地模型（連續 \(botStatus.cloudFallbackStreak) 手）")
                    .accessibilityIdentifier("cloud-degraded-indicator")
            } else if let host = botStatus.cloudHost {
                HStack(spacing: 4) {
                    Image(systemName: "icloud.and.arrow.up").font(.caption2)
                    Text("對局資料送往 \(host)")
                        .font(.caption2)
                        .lineLimit(1)
                }
                .foregroundStyle(.orange)
                .accessibilityIdentifier("cloud-inference-indicator")
            }

            if let stall = autoPlayStall {
                alert(icon: "pause.circle.fill",
                      tone: .red,
                      text: "自動打牌停滯 \(stall.consecutiveTicks) 秒——伺服器已給機會但沒送出（\(stall.reason)）")
                    .accessibilityIdentifier("autoplay-stall-indicator")
            }

            if botStatus.is3P && !botStatus.isCloudDecision {
                alert(icon: "exclamationmark.triangle.fill",
                      tone: .orange,
                      text: "三麻僅雲端推論：本地四麻模型不啟動，雲端未生效時沒有推薦。")
                    .accessibilityIdentifier("sanma-unsupported-notice")
            }
        }
        .padding(.bottom, hasAny ? (compact ? 7 : 10) : 0)
    }

    private var hasAny: Bool {
        botStatus.cloudHost != nil || autoPlayStall != nil
            || (botStatus.is3P && !botStatus.isCloudDecision)
    }

    private func alert(icon: String, tone: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: icon).font(.caption2)
            Text(text)
                .font(.caption2)
                .fontWeight(.semibold)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(tone)
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tone.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Empty States

// 從 `RecommendationView.swift` 搬過來的——那個檔案的其餘內容在側欄重排之後
// 沒有任何使用者了。這兩個空狀態仍然要：它們刻意分開，因為「還沒算出來」與
// 「我把顯示關掉了」都是空白畫面，但成因完全不同。

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

// MARK: - Preview

#Preview("DecisionSidebar - 寬版") {
    DecisionSidebar()
        .frame(width: 380, height: 700)
}

#Preview("DecisionCard") {
    VStack(spacing: 12) {
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
