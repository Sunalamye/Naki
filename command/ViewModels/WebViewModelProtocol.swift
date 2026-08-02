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

    func setAutoPlayMode(_ mode: AutoPlayMode)
    func setAutoPlayDelay(_ delay: TimeInterval)
    func confirmAutoPlayAction()
    func cancelAutoPlayAction()
    func triggerAutoPlayNow(delay: TimeInterval)

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

    #if os(macOS)
    func startDebugServer()
    func stopDebugServer()
    func toggleDebugServer()
    #endif

    // MARK: - JavaScript Execution

    func executeJavaScript(_ script: String) async throws -> Any?

    // MARK: - URL Loading

    func loadMajsoul() async
    func loadURL(_ urlString: String) async
    func reload()
}

// MARK: - Default Implementations

extension WebViewModelProtocol {
    func createNativeBot(playerId: Int) async throws {
        try await createNativeBot(playerId: playerId, is3P: false)
    }

    func triggerAutoPlayNow() {
        triggerAutoPlayNow(delay: 1.2)
    }
}

// MARK: - Factory

/// 根據系統版本創建適當的 WebViewModel
/// 注意：需要與 AdaptiveNakiWebView 的版本判斷保持一致
@MainActor
enum WebViewModelFactory {
    static func create() -> any WebViewModelProtocol {
        // 與 AdaptiveNakiWebView 的版本判斷保持一致
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
