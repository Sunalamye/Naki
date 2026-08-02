//
//  WebViewModelProtocol.swift
//  Naki
//
//  定義 WebViewModel 的共同接口
//  讓新版 (WebPage) 和舊版 (WKWebView) 實現相同的協議
//

import SwiftUI
import WebKit

// MARK: - WebViewModel Protocol

/// WebViewModel 的共同接口
@MainActor
protocol WebViewModelProtocol: AnyObject, Observable {
    // MARK: - State Properties

    var statusMessage: String { get set }
    var isConnected: Bool { get set }
    var recommendationCount: Int { get set }

    var gameState: GameState { get set }
    var botStatus: BotStatus { get set }
    var recommendations: [Recommendation] { get set }
    var tehaiTiles: [String] { get set }
    var tsumoTile: String? { get set }
    var highlightedTile: String? { get set }

    var gameStateManager: GameStateManager { get }
    var isDebugServerRunning: Bool { get set }
    var debugServerPort: UInt16 { get set }

    // MARK: - Bot Methods

    func createNativeBot(playerId: Int, is3P: Bool) async throws
    func processNativeEvent(_ event: [String: Any]) async throws -> [String: Any]?
    func processNativeEvents(_ events: [[String: Any]]) async throws -> [String: Any]?
    func deleteNativeBot()
    func resyncBot() async
    func forceReconnect() async

    // MARK: - Auto Play Methods

    /// 目前生效中的自動打牌模式（持久化見 `AutoPlayModeStore`）
    var autoPlayMode: AutoPlayMode { get }

    /// 這條 WebView 路徑是否提供自動送出。
    ///
    /// WebPage 路徑（macOS/iOS 26+）是 true；Legacy 路徑（iOS 17–25 的 WKWebView）是 false
    /// ——那條路缺輪詢閘門與重試保護，而且沒有任何實機對局驗證（見 `AutoPlayAvailability`）。
    /// UI 依它決定 picker 上有沒有「自動」，ViewModel 依它收斂模式。
    var supportsAutoPlay: Bool { get }

    func setAutoPlayMode(_ mode: AutoPlayMode)
    func triggerAutoPlayNow(delay: TimeInterval)

    // 註：`setAutoPlayDelay(_:)`、`confirmAutoPlayAction()`、`cancelAutoPlayAction()` 已移除。
    // 三個都是空殼：延遲值沒有讀取者（真正的送出延遲由 `ActionDelayModel` 決定），
    // 而「待確認／待取消的動作」這個狀態從來沒有被建立過。

    // MARK: - Settings

    // 註：`setHighlightSettings(showRotatingEffect:)` 已移除。它唯一做的事是呼叫
    // `__nakiRecommendHighlight.setSettings`，而那個物件隨 naki-autoplay.js 一起刪掉了；
    // 它背後的旋轉特效本來就建立在 Laya `effect_recommend` 上，Unity 客戶端沒有。
    // 遊戲內高亮的唯一實作是 naki-core.js 的 `__nakiHighlight` WebGL draw hook。
    func setHidePlayerNames(_ hide: Bool)
    /// 頁面載入完成後重推持久化的隱藏名稱設定（JS 端的開關會被 reload 清掉）
    func applyHideNamesSettingsIfNeeded()
    func getPlayerNamesStatus() async -> [String: Any]?
    func resetHideNamesSettings()

    // MARK: - Debug Server

    // 兩個平台都有：`scripts/soak-test.sh`、`action-shots.sh`、`replay-check.sh` 與所有
    // MCP 工具都只透過 loopback 8765 說話，iOS 少了它就等於少了整個外部驗證面。
    // 先前這三個方法包在 `#if os(macOS)` 裡，但 `WebViewModel.init()` 無條件呼叫
    // `startDebugServer()`、`LegacyWebViewModel` 又遵守條件編譯——結果「iOS 上有沒有 MCP」
    // 取決於 **OS 版本**（26+ 走哪條 VM）而不是平台意圖。現在兩條 path、兩個平台一律啟動。
    func startDebugServer()
    func stopDebugServer()
    func toggleDebugServer()

    // MARK: - View

    /// 建立這條 path 對應的 WebView。
    ///
    /// **版本分歧只在 `WebViewModelFactory` 判一次**：VM 由 factory 挑，View 由 VM 自己給，
    /// 兩者不可能配錯。先前 factory 與 `AdaptiveNakiWebView` 各寫一次
    /// `if #available(macOS 26.0, iOS 26.0, *)`，靠註解要求兩處一致——改一處忘另一處會拿到
    /// `WebViewModel` + `LegacyNakiWebView`（或反過來）的組合，View 層的 `as?` 轉型靜靜失敗，
    /// 畫面只剩「正在初始化…」，沒有任何編譯期或執行期的錯誤訊息。
    func makeWebView() -> AnyView

    // MARK: - JavaScript Execution

    func executeJavaScript(_ script: String) async throws -> Any?

    // MARK: - URL Loading

    func loadMajsoul() async
    func loadURL(_ urlString: String) async
    func reload()
}

// MARK: - Default Implementations

extension WebViewModelProtocol {
    /// 預設提供自動送出；只有 `LegacyWebViewModel` 覆寫成 false。
    var supportsAutoPlay: Bool { true }

    /// 送給 `AutoPlayDecisionResolver` 的自家座位，**兩條 path 唯一的定義點**。
    ///
    /// 先前 Legacy 讀 `botStatus.playerId`、主路徑讀 `gameState.playerId`。兩者雖然都源自
    /// `NativeBotController.playerId`，但重置時機不同（`deleteNativeBot()` 只把 `botStatus`
    /// 打回預設值），所以「座位對不對」在兩條路上可以得到不同答案，而 resolver 的
    /// `seat_mismatch` 是 fail-closed——判錯就整批 oplist 不動作。收斂成一份（p2-2 缺口 3）。
    var autoPlaySeat: Int { gameState.playerId }

    func createNativeBot(playerId: Int) async throws {
        try await createNativeBot(playerId: playerId, is3P: false)
    }

    func triggerAutoPlayNow() {
        triggerAutoPlayNow(delay: 1.2)
    }
}

// MARK: - Factory

/// 根據系統版本創建適當的 WebViewModel。
///
/// **這是全專案唯一的 `#available(macOS 26.0, iOS 26.0, *)`**（`AdaptiveNakiWebView`
/// 不再自己判版本，改問 VM 要 `makeWebView()`）。要驗這件事：
///
/// ```
/// grep -rn '#available' --include='*.swift' command   # 只能有這一行
/// ```
@MainActor
enum WebViewModelFactory {
    static func create() -> any WebViewModelProtocol {
        if #available(macOS 26.0, iOS 26.0, *) {
            return WebViewModel()
        } else {
            return LegacyWebViewModel()
        }
    }
}

// MARK: - Environment Key

/// WebViewModel 的 Environment Key（支援協議類型）
struct WebViewModelKey: EnvironmentKey {
    static let defaultValue: (any WebViewModelProtocol)? = nil
}

extension EnvironmentValues {
    var webViewModel: (any WebViewModelProtocol)? {
        get { self[WebViewModelKey.self] }
        set { self[WebViewModelKey.self] = newValue }
    }
}
