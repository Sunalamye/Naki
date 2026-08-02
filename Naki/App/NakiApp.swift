//
//  Naki.swift
//  akagi
//
//  Created by Suoie on 2025/11/29.
//

import SwiftUI

@main
struct NakiApp: App {

    /// App 的全部活物件（store／settings／session／coordinator／engine／MCP server）。
    ///
    /// p3-4：先前是 `ContentView` 自己 `@State` 建 view model
    /// （`WebViewModelFactory.create()`）。View 建 App 的生命週期有兩個問題：
    /// Preview 會真的去開一個 WebView 並綁 loopback 8765，而「誰擁有它」
    /// 取決於 SwiftUI 的 diffing 規則。現在由 Scene 持有並**顯式注入**。
    @State private var runtime = NakiRuntime()

    init() {
        // 自動打牌模式的兩個舊 key 合併成一個。必須在任何 View 建立之前跑完，
        // 否則 ContentView 的 @AppStorage 會先讀到還沒搬過來的空值。
        //
        // 註：`runtime` 是 stored property 的預設值，會在這個 init 本體**之前**求值，
        // 所以真正先跑的是 `NakiRuntime.init()` 裡那一份（同一個冪等函式）。
        // 這一行留著是為了「App 進入點看得到這件事」。
        AutoPlayModeStore.migrateLegacyKeyIfNeeded()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                // `NakiEnvironment` 的預設值只給 Preview；正式 Scene 一律顯式注入，
                // 否則 View 會讀到第二個空 `GameStore`（雙重真實來源正是 p3-1 修掉的東西）。
                .environment(\.naki, runtime.environment)
        }
    }
}
