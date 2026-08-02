//
//  Naki_MApp.swift
//  Naki-M
//
//  Created by Suoie on 2025/12/4.
//

import SwiftUI

@main
struct Naki_MApp: App {

    /// 與 `NakiApp` 同一份組裝（見 `NakiRuntime`）。
    @State private var runtime = NakiRuntime()

    init() {
        // 與 NakiApp 同一個理由：先把舊的 "AutoPlayMode" key 併進 naki.autoPlayMode，
        // 再讓 ContentView 的 @AppStorage 去讀（實際最早的呼叫點在 `NakiRuntime.init()`，
        // 因為 stored property 的預設值先於 init 本體求值；該函式冪等）。
        AutoPlayModeStore.migrateLegacyKeyIfNeeded()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                // 預設值只給 Preview；正式 Scene 顯式注入（見 `NakiEnvironment`）
                .environment(\.naki, runtime.environment)
        }
    }
}
