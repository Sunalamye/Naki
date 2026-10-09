//
//  MCPTestSupport.swift
//  NakiTests
//
//  測試共用：全部 Action 都是 stub 的 `NakiMCPDependencies`。
//

import Foundation

@testable import Naki

@MainActor
func makeTestDependencies(store: GameStore,
                          executeJavaScript: ExecuteJavaScriptAction = .unavailable) -> NakiMCPDependencies {
    let send: SendActionAction = .unavailable("test_not_wired")
    return NakiMCPDependencies(
        store: store, ui: UIState(), settings: SettingsStore(), executeJavaScript: executeJavaScript, captureScreenshot: .unavailable,
        sendAction: send, startMatch: StartMatchAction(send: send),
        cancelMatch: CancelMatchAction(send: send),
        startUnifiedMatch: StartUnifiedMatchAction(send: send),
        cancelUnifiedMatch: CancelUnifiedMatchAction(send: send),
        triggerAutoPlay: .unavailable, setAntiIdle: .unavailable,
        gameSnapshot: GameSnapshotAction(store: store, accountSource: nil),
        forceReconnect: .unavailable)
}
