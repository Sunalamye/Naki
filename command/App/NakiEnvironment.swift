//
//  NakiEnvironment.swift
//  Naki
//
//  p3-4：View 層看得到的整個 Naki（狀態＋設定＋副作用），一個 Environment 值。
//
//  由來：先前是 `@Environment(\.webViewModel) var viewModel: (any WebViewModelProtocol)?`。
//  三個後果：
//
//  1. **View 認得 view model 的全部。** 一顆「重新載入」按鈕會把整個 1,400 行的
//     協定拖進 View 的型別簽章裡；要換掉那顆按鈕的行為就得換掉整個 view model。
//  2. **optional 是假的。** 正式路徑一定有值，但每個讀取點都要寫 `?.`／`?? 預設值`，
//     於是「沒有 view model 時畫面長什麼樣」是一堆散在各處、沒人驗過的預設值。
//  3. **具體型別靠 `as?` 撈回來。** `NakiWebView` 要 `viewModelProtocol as? WebViewModel`
//     才拿得到 `webPage`——轉型失敗沒有編譯錯誤也沒有例外，畫面只剩「正在初始化…」。
//
//  現在 View 讀三樣東西：狀態（`GameStore`）、設定（`SettingsStore`）、
//  副作用（`NakiActions`）。三者都是具體型別，沒有 optional，也沒有向下轉型。
//

import SwiftUI

// MARK: - Naki Environment

/// SwiftUI 這一側的 Naki。
///
/// - `store`：牌局／連線／狀態列的唯一真實來源（MCP 讀同一個物件，p3-1）
/// - `settings`：使用者設定與這條 WebView path 的能力（p3-4）
/// - `actions`：副作用的型別化入口（p3-3）
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
    /// ——那比「悄悄用了第二個 `GameStore` 於是側欄永遠不更新」好排查得多
    /// （雙重真實來源正是 p3-1 修掉的東西）。
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
