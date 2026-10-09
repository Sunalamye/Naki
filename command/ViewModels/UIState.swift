//
//  UIState.swift
//  Naki
//
//  畫面開關（側欄與四張 sheet）。放進 `NakiEnvironment` 讓 View 與 DEBUG 端點讀寫同一份。
//

import Observation

@MainActor
@Observable
final class UIState {

    /// 決策面板／HUD 是否顯示。iOS 是浮在 WebView 上的 HUD，預設藏起來會讓人以為 Naki 沒在運作。
    var showGamePanel = true
    var showAdvancedSettings = false
    var showPlugins = false
    var showLog = false
    /// 全自動確認表；只是畫面，不代表已啟動全自動。
    var showFullAutoKindChoice = false

    /// 可由外部指定的畫面；互斥，一次只開一個。
    enum Screen: String, CaseIterable {
        case settings, plugins, log, fullauto, none
    }

    /// 開指定畫面並關閉其餘（`none` 全關）；不動 `showGamePanel`。
    func apply(screen: Screen) {
        showAdvancedSettings = screen == .settings
        showPlugins = screen == .plugins
        showLog = screen == .log
        showFullAutoKindChoice = screen == .fullauto
    }

    nonisolated init() { }
}
