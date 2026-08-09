//
//  WebSession.swift
//  Naki
//
//  雀魂頁面這一側的全部職責，一個 service。
//
//  牌局狀態住在 `GameStore`、自動打牌狀態機住在 `AutoPlayEngine`、MCP 依賴住在
//  `NakiMCPDependencies` + Action 層；這裡只有頁面本身：
//
//    · WebPage／WKWebView 的生命週期（建立、載入、重載、交出 View）
//    · JS 注入（`WebSocketInterceptor.createUserScript()` 與 bridge message handler）
//    · `callJavaScript` 封裝——**統一函式體語意**
//    · 導覽事件（開始／committed／完成／失敗）與狀態列文字
//    · 遊戲畫面內高亮同步
//    · 隱藏玩家名稱的推送與重載後補推
//
//  ## 為什麼「函式體語意」要收在這裡
//
//  `WebPage.callJavaScript` 的腳本是**函式體**（取值要自己寫 `return`），
//  `WKWebView.evaluateJavaScript` 的腳本是**運算式**。兩條 path 各自處理這件事的話，
//  「同一段腳本在這條 path 上要不要寫 return」就沒有一個地方講得清楚——漏寫 `return`
//  不會報錯，只會讓取回來的值恆為 nil（`closedCount` 恆為 0 就是這樣來的）。
//
//  只有一種語意：**傳進 `callJavaScript` 的字串一律是函式體，要值就寫 `return`**。
//  IIFE 包裝內聚在 `LegacyWebBackend` 裡，呼叫端看不到平台差別。
//
//  ## 平台分歧
//
//  全專案唯一的 `#available(macOS 26.0, iOS 26.0, *)` 在 `WebSession.init`；
//  `AdaptiveNakiWebView` 只轉發 `WebViewAction` 交出來的 View，不自己判版本。
//  **不要在別處再判一次**：兩個判斷點挑出不相配的 backend 與 View 是靜默失敗
//  ——沒有編譯錯誤也沒有執行期例外，畫面只停在「正在初始化…」。
//

import SwiftUI
import WebKit

// MARK: - Backend

/// 一條 WebView path 的最小能力面（WebPage 與 WKWebView 各一份實作）。
///
/// 這是**唯一**允許出現平台差異的地方（`WebSession` 之上的所有程式碼都看不到差別）。
@MainActor
protocol WebSessionBackend: AnyObject {

    /// 頁面物件已經建好、可以執行 JS 了嗎
    var isReady: Bool { get }

    /// 這條 path 是否提供自動送出。
    ///
    /// WebPage path 是 true；Legacy path 是 false——那條路沒有實機對局驗證
    /// （macOS deployment target 是 26，本機跑不到它），見 `AutoPlayAvailability`。
    var supportsAutoPlay: Bool { get }

    /// 導覽事件的收件人（由 `WebSession` 在建立後設定）
    var sink: (any WebNavigationSink)? { get set }

    /// 執行一段 **函式體** 語意的 JS（要值就自己寫 `return`）
    func callJavaScript(_ functionBody: String) async throws -> Any?

    func load(_ url: URL)
    func reload()

    /// 強制斷線重連的手段（WebPage 關 WebSocket、Legacy 整頁重載）
    func forceReconnect() async -> ForceReconnectOutcome

    /// 這條 path 對應的 SwiftUI View
    func makeView() -> AnyView
}

/// 導覽事件的收件人（`WebSession` 實作）。
///
/// 兩個 backend 的來源不同（WebPage 是 `page.navigations` 的 async stream，
/// Legacy 是 `WKNavigationDelegate` 回呼），但送到這裡就變成同一組四個事件。
@MainActor
protocol WebNavigationSink: AnyObject {
    func webDidStartNavigation()
    func webDidCommitNavigation()
    func webDidFinishNavigation()
    func webDidFailNavigation(_ message: String)
}

/// 頁面重新導覽時要跟著重置的牌局側（正式路徑是 `NakiWebCoordinator`）。
///
/// 用協定而不是 closure：`WebSession` 不該認得 bot、event stream 或 MJAI，
/// 而 coordinator 也不該認得 WebPage。
@MainActor
protocol WebNavigationLifecycle: AnyObject {
    /// 頁面開始重新載入 → 丟掉本局的一切（WS handler、event stream、bot）
    func webNavigationDidStart()
}

// MARK: - Web Session

/// 雀魂頁面。
@MainActor
final class WebSession {

    private let store: GameStore
    private let settings: SettingsStore
    private let backend: any WebSessionBackend

    /// 頁面重新導覽時要重置的牌局側（由 `NakiRuntime` 注入 coordinator）
    weak var lifecycle: (any WebNavigationLifecycle)?

    /// 這次載入是否已經把持久化的「隱藏名稱」推回 JS。
    ///
    /// JS 模組的開關是 closure 內的變數，reload 會歸零；不重推的話設定只在當次載入有效。
    private var hasAppliedHideNames = false

    /// 這條 path 是否提供自動送出（`SettingsStore.supportsAutoPlay` 由此而來）
    var supportsAutoPlay: Bool { backend.supportsAutoPlay }

    /// 頁面就緒（`AutoPlayEngine.Context.isReady`）
    var isReady: Bool { backend.isReady }

    // MARK: - 建立

    /// - Parameter messageHandler: JS bridge 的收件人（`NakiWebCoordinator.websocketHandler`）
    init(store: GameStore, settings: SettingsStore, messageHandler: WKScriptMessageHandler) {
        self.store = store
        self.settings = settings

        let controller = WKUserContentController()
        controller.add(messageHandler, name: "websocketBridge")

        // nil = 模組載入失敗且**沒有 fallback**：不注入任何東西。
        // 半套的內嵌 fallback（沒有 sendRaw、socketId 起算不同）比沒有 fallback 危險，
        // 見 `WebSocketInterceptor.createUserScript()`。
        if let websocketScript = WebSocketInterceptor.createUserScript() {
            controller.addUserScript(websocketScript)
        }

        // ⚠️ 全專案唯一的版本分歧點（回歸鎖：`PlatformDivergenceTests`）
        if #available(macOS 26.0, iOS 26.0, *) {
            self.backend = WebPageBackend(userContentController: controller)
        } else {
            self.backend = LegacyWebBackend(userContentController: controller)
        }

        backend.sink = self

        // JS 注入失敗時不要顯示「準備就緒」——那正是舊 fallback 最危險的地方：
        // 看起來一切正常，實際上一個封包都收不到、一個動作都送不出去。
        if let failure = JSInjectionState.shared.report.failureSummary {
            store.statusMessage = "錯誤：JavaScript 注入失敗，Naki 無法讀牌局也無法送出動作（\(failure)）"
        } else {
            store.statusMessage = "準備就緒"
        }
    }

    /// `@MainActor` class 在 NakiTests host 釋放會 SIGABRT（見 CLAUDE.md「專案結構的坑」）
    nonisolated deinit {}

    // MARK: - JavaScript

    /// 在遊戲頁面執行一段 JS。
    ///
    /// ⚠️ **函式體語意**：要取值必須自己寫 `return`（兩條 path 同一個規則，
    /// Debug Server 的 `POST /js` 與 MCP 的 `execute_js` 也是）。
    func callJavaScript(_ functionBody: String) async throws -> Any? {
        try await backend.callJavaScript(functionBody)
    }

    // MARK: - 載入

    /// 這次 App 生命週期內是否已經要求過首次載入
    private var hasRequestedInitialLoad = false

    /// 載入目前選定的區服（URL 的唯一定義點在 `MajsoulServer`）。
    func loadMajsoul() {
        let server = settings.majsoulServer
        guard let url = server.url else { return }
        hasRequestedInitialLoad = true
        backend.load(url)
        store.statusMessage = "正在載入\(server.displayName)…"
    }

    /// 換區服。
    ///
    /// 一定是**整頁重載**，不是 `reload()`：URL 換了，而各服的帳號不互通，
    /// 舊頁面的 WebSocket 與登入狀態全部作廢。這也是為什麼切換要由使用者明確觸發，
    /// 不會在對局中自己發生。
    func switchServer(to server: MajsoulServer) {
        settings.majsoulServer = server
        guard let url = server.url else { return }
        hasRequestedInitialLoad = true
        backend.load(url)
        store.statusMessage = "正在切換到\(server.regionName)…"
    }

    /// View 出現時的首次載入（重複呼叫無效果）。
    ///
    /// 刻意由 View 的 `.task` 觸發而不是在 `init` 裡就 `load`：頁面要等真的顯示了
    /// 才開始載入，兩條 path 共用這一個進入點。
    func loadMajsoulIfNeeded() {
        guard !hasRequestedInitialLoad else { return }
        loadMajsoul()
    }

    func reload() {
        backend.reload()
        store.statusMessage = "正在重新載入…"
    }

    /// 這條 path 對應的 SwiftUI View（`AdaptiveNakiWebView` 只轉發，不判版本）。
    ///
    /// 首次載入掛在這裡的 `.task` 上：兩條 path 共用這一份，backend 的 representable
    /// 只負責把既有的頁面物件放進 SwiftUI，不自己決定要不要載入。
    func makeView() -> AnyView {
        AnyView(backend.makeView().task { [weak self] in self?.loadMajsoulIfNeeded() })
    }

    // MARK: - 重連

    /// 強制斷線重連以重建 Bot 狀態。
    ///
    /// 手段由 backend 決定（WebPage 關掉所有雀魂 WebSocket，伺服器會以
    /// authGame + syncGame 重建；Legacy 只能整頁重載）。**結果的解讀與狀態列措辭
    /// 只有這一份**：UI 按鈕與 MCP `bot_sync` 都經 `ForceReconnectAction` 走到這裡，
    /// 不各自跑一次 JS、也不各自解讀 outcome。
    @discardableResult
    func forceReconnect() async -> ForceReconnectOutcome {
        guard backend.isReady else {
            bridgeLog("[WebSession] 無法強制重連: 頁面尚未就緒")
            store.statusMessage = "無法重連：WebView 不可用"
            return .failed("web_view_not_ready")
        }

        bridgeLog("[WebSession] 強制重連 WebSocket...")
        store.statusMessage = "正在強制重連..."

        let outcome = await backend.forceReconnect()
        bridgeLog("[WebSession] 強制重連: \(outcome.statusMessage)")
        store.statusMessage = outcome.statusMessage
        return outcome
    }

    // MARK: - 遊戲畫面內高亮

    /// 依目前模式與推薦，暫時改 Unity 畫該牌時的 tint。
    ///
    /// Unity WebGL 沒有 JS per-tile object；JS 從 `_MainTex_ST` atlas UV 辨識牌名。
    /// Swift 只傳牌 identity 與顏色，不推算螢幕位置或手牌 index。
    /// 腳本內容由純函式 `GameHighlightScript.make` 決定（唯一能對「`.off` 是不是
    /// 真的清空」寫機械測試的地方）。
    func syncHighlight() {
        guard backend.isReady else { return }

        let script = GameHighlightScript.make(
            mode: store.autoPlayMode,
            recommendations: store.recommendations,
            tehaiTiles: store.tehaiTiles,
            snapshot: LiqiOperationStore.shared.latest)

        Task { _ = try? await backend.callJavaScript(script) }
    }

    // MARK: - 隱藏玩家名稱

    /// 兩層一起開：
    ///
    /// - **協定層**（`__nakiHideNames`）在遊戲解析封包前改 `ResAuthGame` 的 nickname
    ///   bytes。只對「開啟之後才開始的對局」生效——名牌在 authGame 當下就設定完了。
    /// - **渲染層**（`__nakiNameMask`）把名字字型圖層的 draw alpha 設 0，**即時生效**，
    ///   中途開關也有效；認不到圖層就什麼都不遮（`locked: false`），不會遮錯東西。
    ///
    /// 兩層並存而不是二擇一：協定層連斷線重連後的 syncGame 也蓋得掉（名字根本沒進
    /// 客戶端），渲染層負責「現在就要看不到」。
    func setHidePlayerNames(_ hide: Bool) {
        settings.hidePlayerNames = hide
        Task {
            do {
                let result = try await backend.callJavaScript(
                    """
                    const proto = window.__nakiHideNames?.setEnabled(\(hide)) ?? null;
                    const mask = window.__nakiHighlight?.setNameMask(\(hide)) ?? null;
                    return JSON.stringify({ proto: proto, mask: mask });
                    """)
                bridgeLog("[WebSession] 隱藏玩家名稱: \(hide), 結果: \(String(describing: result))")
            } catch {
                bridgeLog("[WebSession] 設定隱藏名稱錯誤: \(error.localizedDescription)")
            }
        }
    }

    /// 頁面載入完成後把持久化的設定推回 JS（每次載入只推一次）
    private func applyHideNamesIfNeeded() {
        guard !hasAppliedHideNames else { return }
        hasAppliedHideNames = true
        guard settings.hidePlayerNames else { return }
        setHidePlayerNames(true)
    }
}

// MARK: - 導覽事件

extension WebSession: WebNavigationSink {

    func webDidStartNavigation() {
        // 牌局側的重置（WS handler、event stream、bot）交給 coordinator，
        // 這裡只管頁面與狀態列。
        lifecycle?.webNavigationDidStart()
        hasAppliedHideNames = false
        store.statusMessage = "正在加載雀魂..."
        systemLog("[生命週期] 頁面開始載入")
    }

    func webDidCommitNavigation() {
        store.statusMessage = "雀魂已加載，等待連接..."
    }

    func webDidFinishNavigation() {
        systemLog("[生命週期] 頁面載入完成")
        // 載起來了就把失敗橫幅收掉——它不該在成功之後還掛著
        store.pageLoadFailure = nil
        // JS 模組的開關是 closure 內的變數，reload 會歸零，必須重新套用
        applyHideNamesIfNeeded()
        if !store.isConnected {
            store.statusMessage = "已載入，等待 WebSocket 連接..."
        }
    }

    func webDidFailNavigation(_ message: String) {
        store.statusMessage = "加載失敗: \(message)"

        // `statusMessage` 會被下一個事件蓋掉，而頁面載不起來時 Naki 什麼都做不了
        // ——這件事必須留下**查得到**的痕跡，並且掛在畫面上直到重新載入成功。
        //
        // 在此之前這裡只有上面那一行：沒有 log、沒有重試、沒有橫幅，
        // 使用者看到的是一個空白頁面與一句稍縱即逝的狀態列文字。
        systemLog("[WebSession] ❌ 頁面載入失敗：\(message)")
        store.pageLoadFailure = message
    }
}
