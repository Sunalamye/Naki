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
/// View 由 `WebViewAction` 交出來。在這裡再寫一次 `#available` 就是第二個真相：
/// 兩處挑出不相配的 backend 與 View 時是靜默失敗——沒有編譯錯誤也沒有執行期例外，
/// 畫面只停在一片「正在初始化…」。
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
