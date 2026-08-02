//
//  NakiWebViewHost.swift
//  Naki
//
//  雀魂頁面在 SwiftUI 樹裡的位置。
//

import SwiftUI

/// 自適應 WebView —— **不自己判版本，也不認得任何 WebView 型別**。
///
/// 版本分歧只在 `WebSession.init` 判一次（`PlatformDivergenceTests` 鎖著），
/// View 由 `WebViewAction` 交出來。先前這裡與 `WebViewModelFactory` 各寫一次
/// `#available`，靠註解要求一致；改一處忘另一處只會得到一個永遠轉型失敗的 `as?`
/// 和一片「正在初始化…」，沒有編譯錯誤也沒有執行期例外。
struct AdaptiveNakiWebView: View {

    @Environment(\.naki) private var naki

    var body: some View {
        naki.actions.webView()
    }
}

#Preview("AdaptiveNakiWebView - 未注入（Preview 預設）") {
    // 預設 Action 是 `.placeholder`：Preview 不會真的連上雀魂
    AdaptiveNakiWebView()
        .frame(width: 400, height: 300)
}
