//
//  NakiEnvironment.swift
//  Naki
//
//  View 層看得到的整個 Naki（狀態＋設定＋副作用），一個 Environment 值。
//
//  View 只讀這些：狀態（`GameStore`）、設定（`SettingsStore`）、
//  副作用（`NakiActions`）、插件清單（`PluginStore`）、畫面開關（`UIState`），
//  以及三個 service 狀態的唯讀 ref（log、JS 注入、封包解析失敗）。
//  全是具體型別，**沒有 optional，也沒有向下轉型**
//  ——一顆按鈕的行為因此不必把整個 App 的型別拖進 View 的簽章，也不會有
//  「轉型失敗於是什麼都沒發生」這種沒有編譯錯誤、沒有例外的失敗。
//

import SwiftUI

// MARK: - Plugin Store

/// 插件清單的 reactive 容器。
///
/// **為什麼要它**：`NakiEnvironment` 是 struct 值，透過 `.environment(\.naki, …)`
/// 注入一次快照。App（`App` protocol）的 body 不像 View 會因 `@Observable` 變化
/// 重新求值，所以 `NakiRuntime.pluginDescriptors` 變了也不會重新注入 environment
/// ——UI 讀到的是舊快照（引入插件後清單還是 0）。把清單放進 `@Observable` class，
/// environment 持有它的 **ref**，UI 讀 `naki.pluginDescriptors`（＝這個 class 的
/// 屬性）就會建立對 class 的依賴，rescan 更新它時 UI 自動重繪。
@Observable
final class PluginStore {
    /// `@MainActor` class 在 NakiTests host 釋放會 SIGABRT（見 CLAUDE.md「專案結構的坑」）
    nonisolated deinit { }
    var descriptors: [PluginDescriptor] = []
    nonisolated init() { }
}

// MARK: - Naki Environment

/// SwiftUI 這一側的 Naki。
///
/// - `store`：牌局／連線／狀態列的唯一真實來源（MCP 讀同一個物件）
/// - `settings`：使用者設定與這條 WebView path 的能力
/// - `actions`：副作用的型別化入口
/// - `pluginStore`：插件清單的 reactive 容器；`ui`：畫面開關
/// - log、JS 注入結果、封包解析失敗：三個 service 狀態的唯讀 ref
struct NakiEnvironment {

    var store: GameStore
    var settings: SettingsStore
    var actions: NakiActions

    /// 插件清單的 reactive 容器（ref）。UI 讀 `pluginDescriptors` ⇒ 觀察這個 class
    /// ⇒ rescan 更新時自動重繪（見 `PluginStore` 檔頭為什麼不能用 struct 快照）。
    var pluginStore: PluginStore

    /// 畫面開關（側欄與 sheet）；DEBUG 的 `/debug/ui` 寫同一份。
    var ui: UIState

    /// 掃描到的插件（唯讀顯示用；開關寫進 `settings.enabledPluginIds`）。
    /// 讀的是 `pluginStore.descriptors`（class ref）⇒ reactive。
    var pluginDescriptors: [PluginDescriptor] { pluginStore.descriptors }

    /// 記憶體 log（唯讀；清除走 `actions.clearLogs`）。
    var logManager: LogManager { injectedLogManager ?? .shared }
    /// JS 注入結果（寫入端是 `WebSocketInterceptor.createUserScript()`）。
    var jsInjection: JSInjectionState { injectedJSInjection ?? .shared }
    /// 封包解析失敗（寫入端是 `MajsoulBridge`）。
    var parseFault: LiqiParseFaultState { injectedParseFault ?? .shared }

    /// Preview 為 nil，讀取時才解析成 `.shared`：三者的 init 與 `.shared` 都是 MainActor 隔離，
    /// 下面 nonisolated 的 Preview init 碰不到；View 只讀它們，寫入端不經 environment。
    private let injectedLogManager: LogManager?
    private let injectedJSInjection: JSInjectionState?
    private let injectedParseFault: LiqiParseFaultState?

    /// 常駐橫幅讀的四個故障來源任一成立。`statusMessage` 不帶類型，不能靠文字猜
    /// （翻成別的語言就失效），狀態列以此決定圖示與顏色。
    var hasFault: Bool {
        store.botFailure != nil
            || store.pageLoadFailure != nil
            || jsInjection.report.failureSummary != nil
            || parseFault.bannerSummary != nil
    }

    /// 正式路徑：由 `NakiRuntime` 全部顯式提供。
    init(store: GameStore, settings: SettingsStore, actions: NakiActions,
         pluginStore: PluginStore, ui: UIState,
         logManager: LogManager, jsInjection: JSInjectionState, parseFault: LiqiParseFaultState) {
        self.store = store
        self.settings = settings
        self.actions = actions
        self.pluginStore = pluginStore
        self.ui = ui
        self.injectedLogManager = logManager
        self.injectedJSInjection = jsInjection
        self.injectedParseFault = parseFault
    }

    /// **預設值只給 Preview。**
    ///
    /// 正式 Scene 一律由 App 層顯式注入（`NakiApp` / `Naki_MApp` 的
    /// `.environment(\.naki, runtime.environment)`）。這裡的預設值是一組全新的
    /// 空 `GameStore`/`SettingsStore`/`PluginStore`/`UIState` 與**沒有任何副作用**的 Action：
    /// Preview 按下按鈕不會送出動作、不會建立 WebView、不會綁 loopback 8765。
    /// log、JS 注入、封包解析失敗三個唯讀 ref 是例外：讀取時解析成 `.shared`，不是新實例。
    /// 正式路徑若忘了注入，畫面會是空的
    /// ——那比「悄悄用了第二個 `GameStore` 於是側欄永遠不更新」好排查得多。
    ///
    /// `nonisolated`：`@Entry` 生成的 `EnvironmentKey.defaultValue` 是 nonisolated 的
    /// static，叫不動 `@MainActor` 的 init。這幾個型別因此都提供 nonisolated 的
    /// 「空值」建構子（它們只寫值型別欄位與無副作用的 closure）。
    nonisolated init() {
        self.store = GameStore()
        self.settings = SettingsStore()
        self.actions = NakiActions()
        self.pluginStore = PluginStore()
        self.ui = UIState()
        self.injectedLogManager = nil
        self.injectedJSInjection = nil
        self.injectedParseFault = nil
    }

    /// `@Entry` 的預設值每讀一次都會重新求值；用同一份共用實例，讀取之間才相等，
    /// 也不會每次都重建四個 reference type。
    nonisolated static let preview = NakiEnvironment()
}

// MARK: - Environment Key

extension EnvironmentValues {
    /// 預設值僅供 Preview；正式 Scene 由 App 層顯式注入。
    @Entry var naki: NakiEnvironment = .preview
}
