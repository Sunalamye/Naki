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

    func setHighlightSettings(showRotatingEffect: Bool)
    func setHidePlayerNames(_ hide: Bool)
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

    // MARK: - Game Events

    func onAddHandPai(handCount: Int) async
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
        // 暫時強制使用 Legacy 版本，因為新版 WebPage API 尚未完全測試
        // 與 AdaptiveNakiWebView 的 `if false` 邏輯保持一致
        if false, #available(macOS 26.0, iOS 26.0, *) {
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
