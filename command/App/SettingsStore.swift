//
//  SettingsStore.swift
//  Naki
//
//  p3-4：使用者設定的單一持有者（`NakiEnvironment.settings`）。
//
//  先前這些值散在三處：`UserDefaults.standard` 的字串 key（兩個 view model 各寫一次）、
//  View 的 `@AppStorage("HidePlayerNames")`、以及「這條 path 支不支援自動送出」
//  這種只有 view model 知道的能力旗標。View 因此必須認得 view model 才問得到
//  「選單上要不要有『自動』」，而 key 字串在三個檔案裡各寫一次。
//

import Foundation
import SwiftUI

/// 使用者設定與「這條 WebView 路徑能做什麼」的唯一持有者。
///
/// 邊界：
/// - 自動打牌**模式**不在這裡。它的持久化權威是 `AutoPlayModeStore`、收斂權威是
///   `AutoPlayAvailability.commit`，而「現在生效的是哪一個」住在 `GameStore`（p3-3）。
///   這裡只放「這條 path 允不允許 `.auto` 這個選項」。
/// - 牌局資料不在這裡（`GameStore`）。
@Observable
@MainActor
final class SettingsStore {

    /// 隱藏玩家名稱的持久化 key。
    ///
    /// 先前這個字串在 `WebViewModel`、`LegacyWebViewModel`、`AdvancedSettingsSheet`
    /// 各寫一次（其中一份是 `WebViewModel.hidePlayerNamesKey` static、另外兩份是字面值）。
    nonisolated static let hidePlayerNamesKey = "HidePlayerNames"

    /// 在遊戲解析封包前把暱稱改寫成 Player 1–4（實作見 `naki-websocket.js` 的 `__nakiHideNames`）。
    ///
    /// 寫入即持久化：UI 的 Toggle 與 `WebSession.setHidePlayerNames` 讀寫同一份。
    /// 初值直接從 `UserDefaults` 取（stored property 的預設值運算式），這樣 `init` 就不必
    /// 走 setter——`@Entry` 的預設值要在 nonisolated 的 `defaultValue` 裡建起來。
    var hidePlayerNames: Bool = UserDefaults.standard
        .bool(forKey: SettingsStore.hidePlayerNamesKey)
    {
        didSet {
            guard hidePlayerNames != oldValue else { return }
            UserDefaults.standard.set(hidePlayerNames, forKey: Self.hidePlayerNamesKey)
        }
    }

    /// 目前這條 WebView 路徑是否提供自動送出。
    ///
    /// 不是使用者設定，而是「設定選單上有沒有這個選項」的依據：
    /// WebPage path（macOS/iOS 26+）是 true；Legacy path（iOS 17–25 的 WKWebView）是 false
    /// ——那條路缺輪詢閘門與重試保護，而且沒有任何實機對局驗證（見 `AutoPlayAvailability`）。
    ///
    /// **只由 `NakiRuntime` 在建立 `WebSession` 之後寫入一次**（能力由 backend 決定，
    /// 而 backend 要先有 settings 才能建；順序上必須是兩步）。
    private(set) var supportsAutoPlay = true

    /// `nonisolated`：`NakiEnvironment` 的 Preview 預設值要在 `@Entry` 生成的
    /// **nonisolated** `EnvironmentKey.defaultValue` 裡建起來。
    nonisolated init() {}

    /// `@MainActor` class 在 NakiTests host 釋放會 SIGABRT（見 CLAUDE.md「專案結構的坑」）
    nonisolated deinit {}

    /// 由 `NakiRuntime` 在選定 WebView backend 之後告知這條 path 的能力
    func adoptAutoPlaySupport(_ supported: Bool) {
        supportsAutoPlay = supported
    }
}
