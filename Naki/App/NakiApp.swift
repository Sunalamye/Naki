//
//  NakiApp.swift
//  Naki
//
//  Created by Suoie on 2025/11/29.
//

import SwiftUI

@main
struct NakiApp: App {

    /// App 的全部活物件（store／settings／session／coordinator／engine／MCP server）。
    ///
    /// 必須由 Scene 持有、不可讓 View 自建：View 建的話 Preview 會真的開 WebView
    /// 並綁 loopback 8765，而「誰擁有它」取決於 SwiftUI 的 diffing 規則。
    /// 建構 `NakiRuntime.init()` 時會先跑 `AutoPlayModeStore.migrateLegacyKeyIfNeeded()`
    /// ——必須早於任何 View 的 @AppStorage 讀取
    @State private var runtime = NakiRuntime()

    var body: some Scene {
        WindowGroup {
            ContentView()
                // `NakiEnvironment` 的預設值只給 Preview；正式 Scene 一律顯式注入，
                // 否則 View 會讀到第二個空 `GameStore`（雙重真實來源）。
                .environment(\.naki, runtime.environment)
        }
    }
}
