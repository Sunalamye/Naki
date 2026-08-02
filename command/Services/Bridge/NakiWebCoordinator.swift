//
//  NakiWebCoordinator.swift
//  Naki
//
//  WebSocket → MJAI → Bot → `GameStore` 這條線的協調器。
//
//  p3-4 的兩個改動：
//
//  1. **不再持有 view model。** 先前是 `weak var viewModel: WebViewModel?`，
//     所有狀態寫入都經 `viewModel?.store.xxx`，bot 生命週期則是
//     `viewModel?.createNativeBot(...)` / `viewModel?.deleteNativeBot()`
//     ——view model 在中間只做轉發，卻讓「誰擁有 bot」這件事變成 optional chain。
//     現在 coordinator 直接持有 `NativeBotController`、直接寫 `GameStore`。
//  2. **兩條 WebView path 共用同一份。** 先前 `NakiWebCoordinator`（WebPage）與
//     `LegacyWebViewCoordinator`（WKWebView）各抄一份 MJAI pipeline，
//     差別只有 log 前綴、`is3P` 的取法（一份讀 bridge 帶下來的旗標、
//     一份自己數 `names.count`）與少了 `systemLog`。抄兩份的代價是
//     「哪一份先修好」——p2-2 才剛把 `SerialEventIntake` 補到 Legacy 上。
//

import Foundation
import MortalSwift

/// Bot 有新結果時要被通知的一方（正式路徑是 `NakiRuntime`：同步高亮 + 叫醒引擎）。
///
/// 用協定而不是 closure：coordinator 不該認得 `WebSession` 或 `AutoPlayEngine`
/// （它已經因為持有 view model 而認得過一次整個 App）。
@MainActor
protocol BotResponseObserving: AnyObject {
    /// 模型剛跑完推論，快照已經寫進 `GameStore`
    func botDidRespond()
    /// Bot 被刪除，本局資料已清空
    func botDidReset()

    // 對局流程生命週期（p2-5）：coordinator 看到 MJAI 事件邊界時通知，
    // `NakiRuntime` 轉給 `AutoPlayEngine` 決定要不要自動送 confirmNewRound。
    /// 一局結束（`end_kyoku`：ActionHule / ActionNoTile / ActionLiuJu）
    func roundDidEnd()
    /// 下一局開始（`start_kyoku`：ActionNewRound）
    func roundDidBegin()
    /// 整場對局結束（`end_game`：NotifyGameEndResult / NotifyGameTerminate）
    func gameDidEnd()
}

/// 生命週期回調預設 no-op：只有需要接自動確認的一方（`NakiRuntime`）才實作。
extension BotResponseObserving {
    func roundDidEnd() {}
    func roundDidBegin() {}
    func gameDidEnd() {}
}

/// WebSocket → MJAI → Bot → `GameStore`。
@MainActor
final class NakiWebCoordinator {

    /// WebSocket 訊息處理器（同時是 `NakiAccountIdSource`）
    let websocketHandler = WebSocketMessageHandler()

    /// MJAI 事件流管理器
    let eventStream = MJAIEventStream()

    /// 原生 Bot 控制器（MortalSwift + Core ML）
    let bot = NativeBotController()

    private let store: GameStore

    /// 高亮同步與自動打牌引擎的喚醒（由 `NakiRuntime` 注入）
    weak var observer: (any BotResponseObserving)?

    /// 事件序列化入口（intake）。
    ///
    /// 過去每則 WS MJAI 事件各包一個獨立 `Task { @MainActor }`，獨立 Task 間無順序保證、
    /// 各自內部 await 會亂序；且 `start_game` 在 `await createBot` 期間，後續事件的 Task
    /// 可能先跑 → 事件亂序 / 早於 bot 建立。改為單一 buffered AsyncStream + 單一 consumer
    /// 依序 `await handleMJAIEvent`，保證：
    ///   (1) FIFO：單一 stream / 單一 consumer，事件依到達順序處理；
    ///   (2) bot-ready-before-consume：`start_game` 的 handleMJAIEvent 會 `await createBot`
    ///       並啟動 eventStream consumer 後才返回。
    private var intake: SerialEventIntake?

    init(store: GameStore) {
        self.store = store
        setupEventIntake()
        setupWebSocketCallbacks()
    }

    /// `@MainActor` class 在 NakiTests host 釋放會 SIGABRT（見 CLAUDE.md「專案結構的坑」）
    nonisolated deinit {}

    // MARK: - 接線

    private func setupEventIntake() {
        intake = SerialEventIntake { [weak self] event in
            await self?.handleMJAIEvent(event)
        }
    }

    private func setupWebSocketCallbacks() {
        // 不再每則事件各開一個 Task（亂序 + 可能早於 bot 建立）：改為 yield 進序列化入口。
        // intake 是 nonisolated，可安全從 `WKScriptMessageHandler` 回調呼叫。
        let intake = self.intake
        websocketHandler.onMJAIEvent = { event in
            intake?.yield(event)
        }

        websocketHandler.onWebSocketStatusChanged = { [weak self] connected in
            guard let self else { return }

            Task { @MainActor in
                self.store.isConnected = connected
                self.store.statusMessage = connected ? "已連線到雀魂服务器" : "已斷開連線"

                if connected {
                    self.websocketHandler.reset()

                    if self.eventStream.canResync() {
                        print("[協調器] WebSocket 已重連, 嘗試重新同步 Bot...")
                        await self.resyncBot()
                    } else {
                        // `deleteBot()` 已經清空本局資料（同一個 store）
                        self.deleteBot()
                        print("[協調器] WebSocket 連線時重置狀態 (無進行中的遊戲)")
                    }
                } else {
                    self.eventStream.stopConsumer()
                    print("[協調器] WebSocket 已斷線, 消費者已停止 (歷史記錄已保留)")
                }
            }
        }
    }

    // MARK: - Bot 生命週期

    /// 建立 Bot 並把狀態寫進 store。
    func createBot(playerId: Int, is3P: Bool) throws {
        try bot.createBot(playerId: UInt8(playerId), is3P: is3P)
        store.botStatus = bot.botState
        store.statusMessage = "Bot 已建立 (Player \(playerId))"
    }

    /// 刪除 Bot 並清掉屬於這一局的資料。
    ///
    /// `gameState` 刻意保留（座位來源，見 `GameStore.clearAfterBotDeleted`）。
    func deleteBot() {
        bot.deleteBot()
        store.clearAfterBotDeleted()
        observer?.botDidReset()   // 推薦已清空 → 高亮送出 clear()，標記不會留在畫面上
        bridgeLog("[協調器] Bot 已刪除並清除狀態")
    }

    /// 處理單一 MJAI 事件，並把推論結果寫進 store。
    @discardableResult
    func process(event: [String: Any]) async throws -> [String: Any]? {
        // event 帶著它那批 oplist 的 sequence（MajsoulBridge 在 parse 時標的）。
        // react 內部會在推薦真的刷新時把它綁到 controller.lastRecommendationsOplistSequence，
        // GameStore.apply 再從 controller 讀——所以這裡不需要自己傳 sequence（p5 #1）。
        let response = try await bot.react(event: event)

        // 一次寫完整份快照（`GameStore.apply` 是牌局資料唯一的寫入點）。
        // 側欄的顯示閘門在 `RecommendationView`（讀 `autoPlayMode.showRecommendation`）：
        // 資料層保持真實，`/bot/status` 仍看得到模型實際算出什麼；只有
        // `highlightedTile`（現在標了哪一張）在 `.off` 時必須是 nil。
        store.apply(controller: bot,
                    showRecommendation: store.autoPlayMode.showRecommendation)

        // 高亮同步 + 通知自動打牌引擎「有新推薦了，不必等下一拍輪詢」。
        observer?.botDidRespond()
        return response
    }

    // MARK: - MJAI 事件

    private func handleMJAIEvent(_ event: [String: Any]) async {
        guard let eventType = event["type"] as? String else { return }

        mjaiLog("[協調器] MJAI 事件: \(eventType)")

        switch eventType {
        case "start_game":
            guard let playerId = event["id"] as? Int else {
                bridgeLog("[協調器] 錯誤: start_game 沒有 id 欄位!")
                return
            }

            // 三麻旗標：優先用 bridge 依 seatList 判定後帶下來的 `is3P`；
            // 沒有的話退回數 `names`（Legacy 協調器先前唯一的判法）。
            let is3P = (event["is3P"] as? Bool) ?? ((event["names"] as? [String])?.count == 3)

            bridgeLog("[協調器] start_game: 為玩家 \(playerId) 開始新遊戲 (is3P=\(is3P))")

            eventStream.startNewGame()
            eventStream.emit(event)
            deleteBot()

            do {
                try createBot(playerId: playerId, is3P: is3P)
                bridgeLog("[協調器] 已為玩家 \(playerId) 建立 Bot")
                systemLog("[生命週期] 對局開始，Bot 已建立 (Player \(playerId))")
                startEventConsumer()
            } catch {
                bridgeLog("[協調器] 錯誤: 建立 Bot 失敗: \(error)")
            }

        case "end_game":
            bridgeLog("[協調器] end_game: 清理中")
            systemLog("[生命週期] 對局結束，清除 Bot 與 UI 狀態")
            observer?.gameDidEnd()   // 終局：取消任何待送的 confirmNewRound
            eventStream.emit(event)
            eventStream.endGame()
            deleteBot()   // 手牌／推薦／botStatus 一併清空
            store.statusMessage = "遊戲結束"

        case "end_kyoku":
            // 局間結算：伺服器停在結算窗口等 confirmNewRound。通知引擎（受閘門控制）。
            observer?.roundDidEnd()
            eventStream.emit(event)

        case "start_kyoku":
            // 下一局的權威 action 已到 → 局間確認已生效，清掉待確認。
            observer?.roundDidBegin()
            eventStream.emit(event)

        default:
            eventStream.emit(event)
        }
    }

    private func startEventConsumer() {
        bridgeLog("[協調器] 啟動事件消費者...")

        eventStream.startConsumer { [weak self] event in
            guard let self else { return }

            let eventType = event["type"] as? String ?? "unknown"

            do {
                if let response = try await self.process(event: event) {
                    bridgeLog("[消費者] \(eventType) → 回應: \(response)")
                } else {
                    bridgeLog("[消費者] \(eventType) → 回應: 無")
                }
            } catch {
                bridgeLog("[消費者] 處理 \(eventType) 時發生錯誤: \(error)")
            }
        }
    }

    /// 重新同步 Bot（WebSocket 重連時使用）。
    ///
    /// 會用 EventStream 重放歷史事件，讓新 Bot 恢復到當前遊戲狀態。
    func resyncBot() async {
        guard let playerId = eventStream.getPlayerId() else {
            bridgeLog("[協調器] 無法重新同步: 歷史記錄中找不到 playerId")
            return
        }

        // 重連重建時，由歷史中的 start_game 取回三麻旗標，保持與原局一致
        let is3P = eventStream.getIs3P()

        bridgeLog("[協調器] 為玩家 \(playerId) 重新同步 Bot, 歷史事件數: \(eventStream.eventCount), is3P=\(is3P)")

        deleteBot()

        do {
            try createBot(playerId: playerId, is3P: is3P)
            store.statusMessage = "Bot 已重新同步 (Player \(playerId))"
            startEventConsumer()
            bridgeLog("[協調器] Bot 重新同步成功")
        } catch {
            bridgeLog("[協調器] 錯誤: Bot 重新同步失敗: \(error)")
        }
    }
}

// MARK: - 頁面導覽

extension NakiWebCoordinator: WebNavigationLifecycle {

    /// 頁面開始重新載入 → 丟掉本局的一切。
    ///
    /// 狀態列與「隱藏名稱要重推」由 `WebSession` 自己處理；這裡只管牌局側。
    func webNavigationDidStart() {
        websocketHandler.fullReset()
        eventStream.endGame()
        deleteBot()   // 手牌／推薦／botStatus 一併清空
        store.isConnected = false
        print("[協調器] 導覽開始時完整重置 (包含 EventStream)")
    }
}
