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

    var body: some Scene {
        WindowGroup {
            ContentView()
                // 預設值只給 Preview；正式 Scene 顯式注入（見 `NakiEnvironment`）
                .environment(\.naki, runtime.environment)
        }
    }
}
