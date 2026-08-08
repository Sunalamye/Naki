//
//  WebSocketConnectionStateTests.swift
//  NakiTests
//
//  連線狀態轉換的回歸鎖。
//
//  `onWebSocketStatusChanged` 過去在 NakiTests 是零命中，而它的 true 分支做的是
//  `MajsoulBridge.reset()`——清掉 oplist（自動打牌唯一的決策授權來源）、parser 的
//  msgId 對照表、doras、lastDiscard——再重建 Bot 並重放整局歷史事件。
//
//  舊行為是「任何一條 WebSocket open 就報 connected」。雀魂一個分頁會反覆開關 route
//  探測與大廳連線，而對局跑在另一條 `game-gateway` 上從頭到尾沒動；於是**對局進行中**
//  每開一條就重置一次。2026-08-06 的 log 裡同一個 session 重置 9 次、5 次在對局中，
//  緊接著就是 `skip:noOplist`。
//
//  這批 test 鎖三件事：
//  1. 只有**由空轉非空**才報 connected（對稱於 close 側的「全空才報 disconnected」）。
//  2. 非雀魂的 WebSocket 完全不參與這個狀態。
//  3. 對局中開一條大廳線，不得產生任何狀態通知。
//

import XCTest

@testable import Naki

@MainActor
final class WebSocketConnectionStateTests: XCTestCase {

    /// 對局用的連線；`.lq.FastTest.*` 只有這條認得。
    private static let gameSocket = "wss://game-gateway-zone.maj-soul.com/game-gateway"
    /// 大廳／route 探測，雀魂每隔幾分鐘就換一條。
    private static let lobbySocket = "wss://route-5.maj-soul.com:443/gateway"

    /// 收集每一次 `onWebSocketStatusChanged`。用 class 是為了讓 escaping closure
    /// 寫得進去（捕獲區域 `var` 在這裡讀不回來）。
    private final class StatusLog {
        var events: [Bool] = []
    }

    private func makeInterceptor() -> (WebSocketMessageHandler, StatusLog) {
        let interceptor = WebSocketMessageHandler()
        let log = StatusLog()
        interceptor.onWebSocketStatusChanged = { log.events.append($0) }
        return (interceptor, log)
    }

    private func open(_ interceptor: WebSocketMessageHandler,
                      id: Int, url: String, isMajsoul: Bool = true) {
        interceptor.dispatch(type: "websocket_connected",
                             data: ["socketId": id, "url": url, "isMajsoul": isMajsoul])
    }

    private func close(_ interceptor: WebSocketMessageHandler,
                       id: Int, isMajsoul: Bool = true) {
        interceptor.dispatch(type: "websocket_close",
                             data: ["socketId": id, "code": 1000, "reason": "",
                                    "isMajsoul": isMajsoul])
    }

    // MARK: - 由空轉非空

    /// 第一條雀魂線要報 connected，否則 Bot 永遠不會建立。
    func testFirstMajsoulSocketAnnouncesConnected() {
        let (interceptor, log) = makeInterceptor()

        open(interceptor, id: 1, url: Self.gameSocket)

        XCTAssertEqual(log.events, [true], "第一條雀魂線必須報 connected")
    }

    /// **本檔的主鎖**：已經連著的時候再開一條，不得再報一次 connected。
    ///
    /// 拿掉 `handleWebSocketConnected` 的 `wasEmpty` 判斷，這條會轉紅。
    func testSecondMajsoulSocketDoesNotReAnnounceConnected() {
        let (interceptor, log) = makeInterceptor()

        open(interceptor, id: 1, url: Self.gameSocket)
        open(interceptor, id: 2, url: Self.lobbySocket)
        open(interceptor, id: 3, url: Self.lobbySocket)

        XCTAssertEqual(log.events, [true],
                       "只有由空轉非空才算連上；後續連線不得再觸發 reset")
    }

    /// 重現 2026-08-06 的 live 情境：對局跑在 game-gateway 上，雀魂輪換 route 探測。
    /// 那些開關都不該讓對局狀態被清掉。
    func testRouteRotationDuringGameProducesNoStatusChange() {
        let (interceptor, log) = makeInterceptor()

        open(interceptor, id: 1, url: Self.gameSocket)
        XCTAssertEqual(log.events, [true])

        // 三輪探測：開了又關，game socket 全程沒動。
        for probe in 2...4 {
            open(interceptor, id: probe, url: Self.lobbySocket)
            close(interceptor, id: probe)
        }

        XCTAssertEqual(log.events, [true],
                       "route 輪換期間對局連線始終在，不該有任何狀態轉換")
    }

    // MARK: - 非雀魂連線

    /// 頁面上的第三方 WebSocket 不該參與「是否連上雀魂」。
    func testNonMajsoulSocketNeverAffectsState() {
        let (interceptor, log) = makeInterceptor()

        open(interceptor, id: 1, url: "wss://analytics.example.com/collect", isMajsoul: false)
        close(interceptor, id: 1, isMajsoul: false)

        XCTAssertTrue(log.events.isEmpty, "非雀魂連線不得產生任何狀態通知")
    }

    /// 第三方 socket 開在雀魂線之後，也不得被算進集合——否則它關閉時
    /// 會讓「還剩幾條雀魂線」的判斷失準。
    func testNonMajsoulSocketDoesNotKeepConnectionAlive() {
        let (interceptor, log) = makeInterceptor()

        open(interceptor, id: 1, url: Self.gameSocket)
        open(interceptor, id: 2, url: "wss://analytics.example.com/collect", isMajsoul: false)
        close(interceptor, id: 1)

        XCTAssertEqual(log.events, [true, false],
                       "雀魂線全關就該報 disconnected，不受殘留的第三方連線影響")
    }

    // MARK: - 全空才報 disconnected

    /// 還有其他雀魂線活著時，關掉一條不算斷線。
    func testDisconnectOnlyWhenLastMajsoulSocketCloses() {
        let (interceptor, log) = makeInterceptor()

        open(interceptor, id: 1, url: Self.gameSocket)
        open(interceptor, id: 2, url: Self.lobbySocket)

        close(interceptor, id: 2)
        XCTAssertEqual(log.events, [true], "還剩一條雀魂線，不該報 disconnected")

        close(interceptor, id: 1)
        XCTAssertEqual(log.events, [true, false], "最後一條關掉才報 disconnected")
    }

    /// 斷線後重連要能再報一次 connected（否則修完 open 側會換成「永遠連不回來」）。
    func testReconnectAfterFullDisconnectAnnouncesAgain() {
        let (interceptor, log) = makeInterceptor()

        open(interceptor, id: 1, url: Self.gameSocket)
        close(interceptor, id: 1)
        open(interceptor, id: 2, url: Self.gameSocket)

        XCTAssertEqual(log.events, [true, false, true],
                       "集合回到空之後，下一條連線必須重新報 connected")
    }

    /// 同一個 socketId 重複送 connected（JS 端理論上不會，但契約沒禁止）
    /// 不得被當成兩條線。
    func testDuplicateConnectedForSameSocketIdIsIdempotent() {
        let (interceptor, log) = makeInterceptor()

        open(interceptor, id: 1, url: Self.gameSocket)
        open(interceptor, id: 1, url: Self.gameSocket)
        close(interceptor, id: 1)

        XCTAssertEqual(log.events, [true, false],
                       "重複的 connected 不該讓集合多出一條，否則關閉後會卡在 connected")
    }
}
