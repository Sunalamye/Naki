//
//  StatusBanners.swift
//  Naki
//
//  常駐錯誤／更新橫幅與底部 StatusBar。
//

import SwiftUI

// MARK: - 頁面載入失敗橫幅

/// 頁面載不起來時的常駐橫幅。
///
/// 在此之前這件事只寫進 `store.statusMessage`——那會被下一個事件蓋掉，
/// 使用者看到的是一個空白頁面加一句稍縱即逝的文字。頁面沒載起來 Naki 什麼都做不了，
/// 這個狀態必須掛著直到重新載入成功（`webDidFinishNavigation` 會清掉）。
struct PageLoadFailureBanner: View {

    @Environment(\.naki) private var naki

    var body: some View {
        if let reason = naki.store.pageLoadFailure {
            HStack(alignment: .top, spacing: PanelLayout.Spacing.s8) {
                Image(systemName: "wifi.exclamationmark")
                    .imageScale(.large)

                VStack(alignment: .leading, spacing: PanelLayout.Spacing.s2) {
                    Text("頁面沒載入，讀不到牌局")
                        .fontWeight(.semibold)
                    Text(reason)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: PanelLayout.Spacing.s8)

                Button("重新載入") { naki.actions.reloadPage() }
                    .buttonStyle(.bordered)
            }
            .padding(PanelLayout.Spacing.s10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PanelLayout.warning.opacity(PanelLayout.Opacity.tint))
            .accessibilityIdentifier("page-load-failure-banner")
        }
    }
}

/// 有新版時的橫幅：只導向 release 頁，不下載、不安裝。
struct UpdateAvailableBanner: View {

    @Environment(\.naki) private var naki
    @Environment(\.openURL) private var openURL

    var body: some View {
        if let update = naki.store.availableUpdate {
            HStack(spacing: PanelLayout.Spacing.s8) {
                Image(systemName: "arrow.down.circle")
                    .imageScale(.large)
                Text("有新版本 \(update.version)")
                    .fontWeight(.semibold)

                Spacer(minLength: PanelLayout.Spacing.s8)

                Button("前往下載") { openURL(update.url) }
                    .buttonStyle(.borderedProminent)
                Button("略過此版本") { naki.actions.dismissUpdate(skip: true) }
                    .buttonStyle(.bordered)
                Button("關閉提示", systemImage: "xmark") { naki.actions.dismissUpdate(skip: false) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
            }
            .padding(PanelLayout.Spacing.s10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PanelLayout.info.opacity(PanelLayout.Opacity.tint))
            .accessibilityIdentifier("update-available-banner")
        }
    }
}

/// Bot 推論失敗的常駐橫幅（`botFailure` 在下一次成功的 bot 回應時清掉）。
struct BotFailureBanner: View {

    @Environment(\.naki) private var naki

    var body: some View {
        if let reason = naki.store.botFailure {
            HStack(alignment: .top, spacing: PanelLayout.Spacing.s8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .imageScale(.large)
                Text(reason)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(PanelLayout.Spacing.s10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PanelLayout.warning.opacity(PanelLayout.Opacity.tint))
            .accessibilityIdentifier("bot-failure-banner")
        }
    }
}

// MARK: - JS 注入失敗橫幅

/// JavaScript 模組載入失敗時的常駐紅色橫幅。
///
/// 為什麼要獨立於 `StatusBar`：`statusMessage` 會被載入、連線、Bot 建立等事件
/// 一路覆蓋掉，錯誤看一眼就消失。而注入失敗是**不會自己好**的狀態
/// ——在這個狀態下 Naki 收不到任何封包、送不出任何動作，
/// 側欄的推薦、`/game/*`、`/bot/*` 全部不可信，所以必須一直掛著。
///
/// 資料來源是 `naki.jsInjection`（`@Observable`），
/// 由 `WebSocketInterceptor.createUserScript()` 在建立 WebView 時寫入。
struct JSInjectionFailureBanner: View {

    @Environment(\.naki) private var naki

    var body: some View {
        if let summary = naki.jsInjection.report.failureSummary {
            HStack(alignment: .top, spacing: PanelLayout.Spacing.s8) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .imageScale(.large)

                VStack(alignment: .leading, spacing: PanelLayout.Spacing.s2) {
                    Text("App 元件載入失敗")
                        .font(.headline)
                    Text(summary)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    Text("這不是暫時性錯誤，重新載入頁面不會修好；請重新安裝／重新建置 App。")
                        .font(.caption)
                        .opacity(PanelLayout.Opacity.textDim)
                }

                Spacer(minLength: 0)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, PanelLayout.Spacing.s12)
            .padding(.vertical, PanelLayout.Spacing.s8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PanelLayout.danger)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("js-injection-failure-banner")
            .accessibilityLabel("App 元件載入失敗")
            .accessibilityValue(summary)
        }
    }
}

// MARK: - Liqi 解析失敗橫幅

/// 封包解析失敗到「這一局不會運作」程度時的常駐橫幅。
///
/// 為什麼要有它：沒有橫幅時，authGame 回應少了 seatList 只會寫一行 log，
/// `start_game` 不發、Bot 不建立、推薦永遠是空的——而畫面上顯示的是
/// 「已連線到雀魂服务器」。使用者唯一的線索是「怎麼都沒有推薦」。
///
/// 與 `JSInjectionFailureBanner` 的分工：那個是「Naki 根本沒接上頁面」，
/// 這個是「接上了，但這一局的關鍵欄位解不開」。後者會自己好
/// （下一局 authGame／start_kyoku 成功就 `clearBlocking()`），所以不寫
/// 「重裝 App」那種指示。
struct LiqiParseFailureBanner: View {

    @Environment(\.naki) private var naki

    var body: some View {
        if let summary = naki.parseFault.bannerSummary {
            HStack(alignment: .top, spacing: PanelLayout.Spacing.s8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .imageScale(.large)

                VStack(alignment: .leading, spacing: PanelLayout.Spacing.s2) {
                    Text("這局資料讀不懂：本局不給建議、不自動打")
                        .font(.headline)
                    Text(summary)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    Text("下一局（或重連）解析成功就會自動消失；持續出現代表雀魂改了協定欄位。")
                        .font(.caption)
                        .opacity(PanelLayout.Opacity.textDim)
                }

                Spacer(minLength: 0)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, PanelLayout.Spacing.s12)
            .padding(.vertical, PanelLayout.Spacing.s8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PanelLayout.warning)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("liqi-parse-failure-banner")
            .accessibilityLabel("這局資料讀不懂：本局不給建議、不自動打")
            .accessibilityValue(summary)
        }
    }
}

// MARK: - Status Bar

struct StatusBar: View {
    @Environment(\.naki) private var naki

    private var message: String { naki.store.statusMessage }

    var body: some View {
        if !message.isEmpty {
            HStack(spacing: PanelLayout.Spacing.s8) {
                Image(systemName: statusIcon)
                    .foregroundStyle(statusColor)
                Text(message)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                Spacer()

                // 顯示推薦數量
                if naki.store.showsRecommendationBadge {
                    Text("\(naki.store.recommendationCount) 推薦")
                        .font(.caption)
                        .padding(.horizontal, PanelLayout.Spacing.s8)
                        .padding(.vertical, PanelLayout.Spacing.s2)
                        .background(PanelLayout.success.opacity(PanelLayout.Opacity.tint), in: .rect(cornerRadius: PanelLayout.Radius.badge))
                }
            }
            .padding(.horizontal, PanelLayout.Spacing.s12)
            .padding(.vertical, PanelLayout.Spacing.s6)
            .background(statusColor.opacity(PanelLayout.Opacity.subtle))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("status-bar")
        }
    }

    private var statusIcon: String {
        naki.hasFault ? "exclamationmark.triangle.fill" : "info.circle.fill"
    }

    private var statusColor: Color { naki.hasFault ? PanelLayout.danger : PanelLayout.info }
}
