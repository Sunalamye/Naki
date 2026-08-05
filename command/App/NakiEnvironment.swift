//
//  NakiEnvironment.swift
//  Naki
//
//  View 層看得到的整個 Naki（狀態＋設定＋副作用），一個 Environment 值。
//
//  View 只讀三樣東西：狀態（`GameStore`）、設定（`SettingsStore`）、
//  副作用（`NakiActions`）。三者都是具體型別，**沒有 optional，也沒有向下轉型**
//  ——一顆按鈕的行為因此不必把整個 App 的型別拖進 View 的簽章，也不會有
//  「轉型失敗於是什麼都沒發生」這種沒有編譯錯誤、沒有例外的失敗。
//

import SwiftUI

// MARK: - Naki Environment

/// SwiftUI 這一側的 Naki。
///
/// - `store`：牌局／連線／狀態列的唯一真實來源（MCP 讀同一個物件）
/// - `settings`：使用者設定與這條 WebView path 的能力
/// - `actions`：副作用的型別化入口
struct NakiEnvironment {

    var store: GameStore
    var settings: SettingsStore
    var actions: NakiActions

    /// 正式路徑：由 `NakiRuntime` 顯式提供三者。
    init(store: GameStore, settings: SettingsStore, actions: NakiActions) {
        self.store = store
        self.settings = settings
        self.actions = actions
    }

    /// **預設值只給 Preview。**
    ///
    /// 正式 Scene 一律由 App 層顯式注入（`NakiApp` / `Naki_MApp` 的
    /// `.environment(\.naki, runtime.environment)`）。這裡的預設值是一組全新的
    /// 空 store 與**沒有任何副作用**的 Action：Preview 按下按鈕不會送出動作、
    /// 不會建立 WebView、不會綁 loopback 8765；而正式路徑若忘了注入，畫面會是空的
    /// ——那比「悄悄用了第二個 `GameStore` 於是側欄永遠不更新」好排查得多。
    ///
    /// `nonisolated`：`@Entry` 生成的 `EnvironmentKey.defaultValue` 是 nonisolated 的
    /// static，叫不動 `@MainActor` 的 init。三個型別因此都提供 nonisolated 的
    /// 「空值」建構子（它們只寫值型別欄位與無副作用的 closure）。
    nonisolated init() {
        self.store = GameStore()
        self.settings = SettingsStore()
        self.actions = NakiActions()
    }
}

// MARK: - Environment Key

extension EnvironmentValues {
    /// 預設值僅供 Preview；正式 Scene 由 App 層顯式注入。
    @Entry var naki: NakiEnvironment = NakiEnvironment()
}
