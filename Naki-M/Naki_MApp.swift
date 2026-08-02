//
//  Naki_MApp.swift
//  Naki-M
//
//  Created by Suoie on 2025/12/4.
//

import SwiftUI

@main
struct Naki_MApp: App {
    init() {
        // 與 NakiApp 同一個理由：先把舊的 "AutoPlayMode" key 併進 naki.autoPlayMode，
        // 再讓 ContentView 的 @AppStorage 去讀。
        AutoPlayModeStore.migrateLegacyKeyIfNeeded()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
