//
//  Naki.swift
//  akagi
//
//  Created by Suoie on 2025/11/29.
//

import SwiftUI

@main
struct NakiApp: App {
    init() {
        // 自動打牌模式的兩個舊 key 合併成一個。必須在任何 View 建立之前跑完，
        // 否則 ContentView 的 @AppStorage 會先讀到還沒搬過來的空值。
        AutoPlayModeStore.migrateLegacyKeyIfNeeded()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
