//
//  WebViewModel.swift
//  akagi
//
//  Created by Suoie on 2025/11/29.
//  Updated: 2025/11/30 - 移除 Python 依賴，純 Swift 實現
//

import MortalSwift
import SwiftUI
import WebKit

@Observable
class WebViewModel {
    var statusMessage = ""

    // 連接狀態
    var isConnected = false
    var recommendationCount = 0

    // 遊戲狀態
    var gameState = GameState()
    var botStatus = BotStatus()
    var recommendations: [Recommendation] = []
    var tehaiTiles: [String] = []
    var tsumoTile: String?
    var highlightedTile: String?

    // 原生 Bot 控制器 (MortalSwift)
    private var nativeBotController: NativeBotController?

    // 自動打牌控制器
    private var autoPlayController: AutoPlayController?

    // Debug Server
    private var debugServer: DebugServer?
    var isDebugServerRunning = false
    var debugServerPort: UInt16 = 8765

    // 方案 1: 原生 WebPage（僅顯示網頁）
    var webPage: WebPage?

    // 方案 2: WKWebView（完整功能 + JavaScript Bridge）
    var wkWebView: WKWebView? {
        didSet {
            // 當 WKWebView 設置時，也設置給 AutoPlayController
            if let webView = wkWebView {
                autoPlayController?.setWebView(webView)
            }
        }
    }

    // 已棄用 - 保留屬性以兼容舊代碼
    var botEngineMode: String = "native"
    var isProxyRunning: Bool = false

    /// 防止重複觸發自動打牌
    private var lastAutoPlayTriggerTime: Date = .distantPast
    private var lastAutoPlayActionType: Recommendation.ActionType?

    init() {
        // 初始化 WebPage（用於簡單顯示）
        webPage = WebPage()

        // 初始化原生 Bot 控制器
        nativeBotController = NativeBotController()

        // 初始化自動打牌控制器
        autoPlayController = AutoPlayController()

        // ⭐ 自動啟動 Debug Server
        startDebugServer()

        // ⭐ 自動設置全自動打牌模式
        autoPlayController?.setMode(.auto)

        statusMessage = "準備就緒 (全自動模式)"
    }

    // MARK: - Native Bot Methods

    /// 使用原生 MortalSwift 創建 Bot
    func createNativeBot(playerId: Int, is3P: Bool = false) async throws {
        guard let controller = nativeBotController else {
            throw NativeBotError.botNotInitialized
        }

        try controller.createBot(playerId: UInt8(playerId), is3P: is3P)
        botStatus = controller.botState
        statusMessage = "Bot 已創建 (Player \(playerId))"
    }

    /// 使用原生 Bot 處理 MJAI 事件
    /// ⭐ MortalBot 是 actor，內部自動在背景執行 Core ML 推理
    func processNativeEvent(_ event: [String: Any]) async throws -> [String: Any]? {
        guard let controller = nativeBotController else {
            throw NativeBotError.botNotInitialized
        }

        // ⭐ NativeBotController.react() 現在是 async
        // MortalBot actor 內部會自動在背景執行 Core ML 推理
        let response = try await controller.react(event: event)

        // 獲取狀態
        let newGameState = controller.gameState
        let newBotStatus = controller.botState
        let newTehaiTiles = controller.tehaiMjai
        let newTsumoTile = controller.lastTsumo
        let newRecommendations = controller.lastRecommendations

        // 獲取自動打牌所需資料
        let lastAction = controller.lastAction
        let tehaiForAutoPlay = controller.tehai
        let tsumoForAutoPlay = controller.tsumo

        // 更新 UI 狀態（在主線程）
        await MainActor.run {
            self.gameState = newGameState
            self.botStatus = newBotStatus
            self.tehaiTiles = newTehaiTiles
            self.tsumoTile = newTsumoTile
            self.recommendations = newRecommendations
            self.recommendationCount = newRecommendations.count

            if let firstRec = newRecommendations.first {
                self.highlightedTile = firstRec.displayTile
            }

            // ⭐ 觸發自動打牌（全自動模式下使用 JS 查找正確的牌索引）
            let autoMode = self.autoPlayController?.state.mode
            let hasRecs = !newRecommendations.isEmpty
            self.debugServer?.addLog("AutoCheck: mode=\(autoMode?.rawValue ?? "nil"), hasRecs=\(hasRecs), count=\(newRecommendations.count)")

            if autoMode == .auto, hasRecs {
                // ⭐ 根據動作類型決定延遲時間
                let firstAction = newRecommendations.first?.actionType
                let delay: TimeInterval
                // 注意：.none 會跟 Optional.none 衝突，所以要用 .some(.none)
                switch firstAction {
                case .hora:
                    delay = 1.0  // 和牌: 等待遊戲 oplist 更新
                case .chi, .pon, .kan:
                    delay = 1.5  // 副露: 等待遊戲 UI 完全準備好
                case .some(.none):
                    delay = 0.5  // 跳過: 不能太慢，會被遊戲自動跳過
                default:
                    delay = 1.8  // 打牌: 較長延遲確保穩定
                }
                self.debugServer?.addLog("Auto-triggering \(firstAction?.rawValue ?? "?") (delay: \(delay)s)...")
                self.triggerAutoPlayNow(delay: delay)
            }
        }

        return response
    }

    /// 批量處理 MJAI 事件
    /// ⭐ MortalBot 是 actor，內部自動在背景執行 Core ML 推理
    func processNativeEvents(_ events: [[String: Any]]) async throws -> [String: Any]? {
        guard let controller = nativeBotController else {
            throw NativeBotError.botNotInitialized
        }

        // ⭐ NativeBotController.react() 現在是 async
        // MortalBot actor 內部會自動在背景執行 Core ML 推理
        let response = try await controller.react(events: events)

        // 獲取狀態
        let newGameState = controller.gameState
        let newBotStatus = controller.botState
        let newTehaiTiles = controller.tehaiMjai
        let newTsumoTile = controller.lastTsumo
        let newRecommendations = controller.lastRecommendations

        // 獲取自動打牌所需資料
        let lastAction = controller.lastAction
        let tehaiForAutoPlay = controller.tehai
        let tsumoForAutoPlay = controller.tsumo

        // 更新 UI 狀態（在主線程）
        await MainActor.run {
            self.gameState = newGameState
            self.botStatus = newBotStatus
            self.tehaiTiles = newTehaiTiles
            self.tsumoTile = newTsumoTile
            self.recommendations = newRecommendations
            self.recommendationCount = newRecommendations.count

            if let firstRec = newRecommendations.first {
                self.highlightedTile = firstRec.displayTile
            }

            // ⭐ 觸發自動打牌（全自動模式下使用 JS 查找正確的牌索引）
            let autoMode = self.autoPlayController?.state.mode
            let hasRecs = !newRecommendations.isEmpty
            self.debugServer?.addLog("AutoCheck2: mode=\(autoMode?.rawValue ?? "nil"), hasRecs=\(hasRecs), count=\(newRecommendations.count)")

            if autoMode == .auto, hasRecs {
                // ⭐ 根據動作類型決定延遲時間
                let firstAction = newRecommendations.first?.actionType
                let delay: TimeInterval
                // 注意：.none 會跟 Optional.none 衝突，所以要用 .some(.none)
                switch firstAction {
                case .hora:
                    delay = 1.0  // 和牌: 等待遊戲 oplist 更新
                case .chi, .pon, .kan:
                    delay = 1.5  // 副露: 等待遊戲 UI 完全準備好
                case .some(.none):
                    delay = 0.5  // 跳過: 不能太慢，會被遊戲自動跳過
                default:
                    delay = 1.8  // 打牌: 較長延遲確保穩定
                }
                self.debugServer?.addLog("Auto-triggering2 \(firstAction?.rawValue ?? "?") (delay: \(delay)s)...")
                self.triggerAutoPlayNow(delay: delay)
            }
        }

        return response
    }

    /// 刪除原生 Bot
    func deleteNativeBot() {
        nativeBotController?.deleteBot()
        botStatus = BotStatus()
        recommendations = []
        tehaiTiles = []
        tsumoTile = nil
        bridgeLog("[WebViewModel] Bot deleted and state cleared")
    }

    // MARK: - Auto Play Methods

    /// 設置自動打牌模式
    func setAutoPlayMode(_ mode: AutoPlayMode) {
        autoPlayController?.setMode(mode)
        bridgeLog("[WebViewModel] Auto-play mode set to: \(mode.rawValue)")
        debugServer?.addLog("Mode changed: \(mode.rawValue), recs: \(recommendations.count)")

        // ⭐ 當啟用全自動模式且有現有推薦時，立即觸發
        if mode == .auto, !recommendations.isEmpty {
            let firstAction = recommendations.first?.actionType
            let delay: TimeInterval
            // 注意：.none 會跟 Optional.none 衝突，所以要用完整類型名
            switch firstAction {
            case .hora:
                delay = 0  // 和牌: 立即執行，時間窗口極短
            case .chi, .pon, .kan:
                delay = 1.5  // 副露: 等待遊戲 UI 完全準備好
            case .some(.none):
                delay = 1.2  // 跳過: 等待其他玩家動作完成
            default:
                delay = 1.8  // 打牌: 較長延遲確保穩定
            }
            debugServer?.addLog("Auto-triggering on mode change: \(firstAction?.rawValue ?? "?") (delay: \(delay)s)")
            triggerAutoPlayNow(delay: delay)
        }
    }

    /// 設置自動打牌延遲
    func setAutoPlayDelay(_ delay: TimeInterval) {
        autoPlayController?.setActionDelay(delay)
    }

    /// 確認待處理的自動打牌動作
    func confirmAutoPlayAction() {
        autoPlayController?.confirmPendingAction()
    }

    /// 取消待處理的自動打牌動作
    func cancelAutoPlayAction() {
        autoPlayController?.cancelPendingAction()
    }

    /// 手動觸發自動打牌（使用當前推薦）
    /// - Parameter delay: 延遲執行的秒數（預設 1.2 秒）
    func triggerAutoPlayNow(delay: TimeInterval = 1.2) {
        guard let webView = wkWebView,
              let firstRec = recommendations.first else {
            bridgeLog("[WebViewModel] Cannot trigger: no WebView or recommendations")
            return
        }

        let actionType = firstRec.actionType
        let tileName = firstRec.displayTile

        bridgeLog("[WebViewModel] Triggering: \(actionType.rawValue) - \(tileName) (delay: \(delay)s)")
        debugServer?.addLog("Trigger: \(actionType.rawValue) - \(tileName)")

        // 延遲執行避免太快
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            // ⭐ hora 不使用重試機制，直接執行（時間窗口很短）
            if actionType == .hora {
                self?.debugServer?.addLog("Hora: direct exec (no retry)")
                self?.executeAutoPlayAction(webView: webView, actionType: actionType, tileName: tileName)
            } else {
                self?.executeAutoPlayActionWithRetry(webView: webView, actionType: actionType, tileName: tileName, attempt: 1)
            }
        }
    }

    /// 最大重試次數
    private let maxRetryAttempts = 30  // 30 次 x 0.1s = 最多等 3 秒

    /// 帶重試的自動打牌執行
    /// - Parameters:
    ///   - webView: WKWebView 實例
    ///   - actionType: 動作類型
    ///   - tileName: 牌名
    ///   - attempt: 當前嘗試次數
    private func executeAutoPlayActionWithRetry(webView: WKWebView, actionType: Recommendation.ActionType, tileName: String, attempt: Int) {

        // 先檢查是否還有操作可執行
        let checkScript = """
        (function() {
            var dm = window.view.DesktopMgr.Inst;
            if (!dm) return {hasOp: false, reason: 'no dm'};
            if (!dm.oplist || dm.oplist.length === 0) return {hasOp: false, reason: 'no oplist'};

            // 檢查是否還有待處理的操作
            var opTypes = dm.oplist.map(o => o.type);
            return {hasOp: true, opTypes: opTypes, count: dm.oplist.length};
        })()
        """

        webView.evaluateJavaScript(checkScript) { [weak self] result, _ in
            guard let self = self else { return }

            // 解析結果
            if let dict = result as? [String: Any],
               let hasOp = dict["hasOp"] as? Bool {

                if !hasOp {
                    // 沒有操作可執行了，可能已經成功或狀態改變
                    let reason = dict["reason"] as? String ?? "unknown"
                    self.debugServer?.addLog("Retry check: no op (\(reason)), stopping")
                    return
                }

                // 還有操作，執行動作
                let opInfo = dict["opTypes"] as? [Int] ?? []
                self.debugServer?.addLog("Attempt \(attempt): ops=\(opInfo)")

                // 執行動作
                self.executeAutoPlayAction(webView: webView, actionType: actionType, tileName: tileName)

                // 0.1 秒後檢查是否成功
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.checkAndRetryIfNeeded(webView: webView, actionType: actionType, tileName: tileName, attempt: attempt)
                }
            } else {
                // 無法解析，直接執行一次
                self.debugServer?.addLog("Attempt \(attempt): check failed, exec anyway")
                self.executeAutoPlayAction(webView: webView, actionType: actionType, tileName: tileName)
            }
        }
    }

    /// 檢查動作是否成功，失敗則重試
    private func checkAndRetryIfNeeded(webView: WKWebView, actionType: Recommendation.ActionType, tileName: String, attempt: Int) {

        let checkScript = """
        (function() {
            var dm = window.view.DesktopMgr.Inst;
            if (!dm) return {success: true, reason: 'no dm'};
            if (!dm.oplist || dm.oplist.length === 0) return {success: true, reason: 'oplist cleared'};

            // 還有操作，表示上次可能沒成功
            var opTypes = dm.oplist.map(o => o.type);
            return {success: false, opTypes: opTypes, count: dm.oplist.length};
        })()
        """

        webView.evaluateJavaScript(checkScript) { [weak self] result, _ in
            guard let self = self else { return }

            if let dict = result as? [String: Any],
               let success = dict["success"] as? Bool {

                if success {
                    let reason = dict["reason"] as? String ?? "ok"
                    self.debugServer?.addLog("✅ Action success after \(attempt) attempts (\(reason))")
                    return
                }

                // 失敗，需要重試
                let opInfo = dict["opTypes"] as? [Int] ?? []

                if attempt >= self.maxRetryAttempts {
                    self.debugServer?.addLog("❌ Max retries reached (\(attempt)), ops=\(opInfo)")
                    return
                }

                // 重試
                self.debugServer?.addLog("Retry \(attempt + 1): ops still present \(opInfo)")
                self.executeAutoPlayActionWithRetry(webView: webView, actionType: actionType, tileName: tileName, attempt: attempt + 1)
            }
        }
    }

    /// 實際執行自動打牌動作
    private func executeAutoPlayAction(webView: WKWebView, actionType: Recommendation.ActionType, tileName: String) {

        switch actionType {
        case .riichi:
            // ⭐ 立直：需要找到要打的牌（從其他推薦中找，或用第二高機率的打牌推薦）
            // 先嘗試用遊戲 API 執行立直
            debugServer?.addLog("Exec: riichi...")
            let script = """
            (function() {
                var dm = window.view.DesktopMgr.Inst;
                if (!dm || !dm.oplist) return {success: false, error: 'no oplist'};

                // 找到立直操作 (type 7)
                var riichiOp = dm.oplist.find(o => o.type === 7);
                if (!riichiOp) return {success: false, error: 'no riichi op'};

                // 使用 NetAgent 發送立直請求
                if (window.app && window.app.NetAgent) {
                    // 立直需要指定打哪張牌，找第一個可以立直的牌
                    var combination = riichiOp.combination || [];
                    var tileToDiscard = combination.length > 0 ? combination[0] : null;

                    window.app.NetAgent.sendReq2MJ('FastTest', 'inputOperation', {
                        type: 7,
                        tile: tileToDiscard,
                        timeuse: 1
                    });
                    return {success: true, tile: tileToDiscard, combinations: combination};
                }
                return {success: false, error: 'no NetAgent'};
            })()
            """
            webView.evaluateJavaScript(script) { [weak self] result, error in
                if let error = error {
                    self?.debugServer?.addLog("riichi error: \(error.localizedDescription)")
                } else if let dict = result as? [String: Any] {
                    self?.debugServer?.addLog("riichi result: \(dict)")
                }
            }

        case .discard:
            // 改進的牌匹配邏輯：處理紅寶牌 (5mr, 5pr, 5sr)
            // 先查詢遊戲內部的牌映射
            let findScript = """
            (function() {
                var mr = window.view.DesktopMgr.Inst.mainrole;
                if (!mr || !mr.hand) return {index: -1, debug: 'no mainrole'};

                var target = '\(tileName)';

                // 先輸出手牌資訊以供調試
                var handInfo = [];
                for (var i = 0; i < mr.hand.length; i++) {
                    var t = mr.hand[i];
                    if (t && t.val) {
                        handInfo.push('i' + i + ':t' + t.val.type + 'v' + t.val.index + (t.val.dora ? 'r' : ''));
                    }
                }

                // 雀魂的 type 映射：0=筒, 1=萬, 2=索, 3=字牌
                var typeMap = {'m': 1, 'p': 0, 's': 2};
                var honorMap = {'E': [3,1], 'S': [3,2], 'W': [3,3], 'N': [3,4], 'P': [3,5], 'F': [3,6], 'C': [3,7]};

                var tileType, tileValue, isRed = false;

                // 處理字牌
                if (honorMap[target]) {
                    tileType = honorMap[target][0];
                    tileValue = honorMap[target][1];
                } else {
                    // 處理數牌：1m, 5mr, etc.
                    tileValue = parseInt(target[0]);
                    var suitChar = target[1];
                    tileType = typeMap[suitChar];
                    isRed = target.length > 2 && target[2] === 'r';
                }

                var debugInfo = 'want:' + target + '(t' + tileType + 'v' + tileValue + ') hand:[' + handInfo.join(',') + ']';

                // 在手牌中查找
                for (var i = 0; i < mr.hand.length; i++) {
                    var t = mr.hand[i];
                    if (t && t.val && t.val.type === tileType && t.val.index === tileValue) {
                        // 如果是紅寶牌，檢查 dora 標記
                        if (isRed) {
                            if (t.val.dora) return {index: i, debug: debugInfo + ' =>found red@' + i};
                        } else {
                            if (!t.val.dora) return {index: i, debug: debugInfo + ' =>found@' + i};
                        }
                    }
                }

                // 如果沒找到精確匹配，再找一次不考慮紅寶牌
                for (var i = 0; i < mr.hand.length; i++) {
                    var t = mr.hand[i];
                    if (t && t.val && t.val.type === tileType && t.val.index === tileValue) {
                        return {index: i, debug: debugInfo + ' =>found(any)@' + i};
                    }
                }

                // 檢查摸牌
                if (mr.drewPai && mr.drewPai.val) {
                    var t = mr.drewPai;
                    debugInfo += ' tsumo:t' + t.val.type + 'v' + t.val.index;
                    if (t.val.type === tileType && t.val.index === tileValue) {
                        return {index: mr.hand.length, debug: debugInfo + ' =>tsumo'};
                    }
                }

                return {index: -1, debug: debugInfo + ' =>NOT_FOUND'};
            })()
            """
            webView.evaluateJavaScript(findScript) { [weak self] result, error in
                if let dict = result as? [String: Any],
                   let tileIndex = dict["index"] as? Int,
                   let debug = dict["debug"] as? String {
                    self?.debugServer?.addLog("Find: \(debug)")

                    if tileIndex >= 0 {
                        let script = "window.__nakiGameAPI.smartExecute('discard', {tileIndex: \(tileIndex)})"
                        webView.evaluateJavaScript(script) { _, error in
                            if let error = error {
                                self?.debugServer?.addLog("discard error: \(error.localizedDescription)")
                            } else {
                                self?.debugServer?.addLog("discard idx=\(tileIndex) OK")
                            }
                        }
                    } else {
                        self?.debugServer?.addLog("Tile not found, skipping")
                    }
                } else if let error = error {
                    self?.debugServer?.addLog("Find error: \(error.localizedDescription)")
                }
            }

        case .chi:
            // ⭐ 吃操作：chi_0=chiLow(被吃牌最小), chi_1=chiMid(中間), chi_2=chiHigh(最大)
            var chiType = 0  // 0=low, 1=mid, 2=high
            if tileName.hasPrefix("chi_"), let idx = Int(String(tileName.dropFirst(4))) {
                chiType = idx
            }
            // 查詢可用的吃組合，找到正確的 combination index
            let queryScript = """
            (function() {
                var dm = window.view.DesktopMgr.Inst;
                if (!dm || !dm.oplist) return {available: false, error: 'no oplist'};
                var chiOp = dm.oplist.find(o => o.type === 2);
                if (!chiOp) return {available: false, error: 'no chi op'};

                // 組合格式: ["3p|4p", "4p|6p"] 表示可用的手牌組合
                var combinations = chiOp.combination || [];

                // 獲取被吃的牌 (上家打出的牌)
                var targetPai = null;
                if (dm.lastpai && dm.lastpai.val) {
                    targetPai = {type: dm.lastpai.val.type, index: dm.lastpai.val.index};
                }

                return {
                    available: true,
                    combinations: combinations,
                    count: combinations.length,
                    targetPai: targetPai
                };
            })()
            """
            webView.evaluateJavaScript(queryScript) { [weak self] result, _ in
                guard let dict = result as? [String: Any],
                      let available = dict["available"] as? Bool, available,
                      let combinations = dict["combinations"] as? [String] else {
                    self?.debugServer?.addLog("Chi: no combinations available")
                    return
                }

                // 如果只有一個組合，直接用 0
                let combIndex = combinations.count == 1 ? 0 : chiType
                let combInfo = combinations.isEmpty ? "" : " [\(combinations.joined(separator: ", "))]"
                self?.debugServer?.addLog("Chi: type=\(chiType) combIdx=\(combIndex)\(combInfo)")

                // 執行吃操作
                let script = "window.__nakiGameAPI.smartExecute('chi', {chiIndex: \(combIndex)})"
                self?.wkWebView?.evaluateJavaScript(script) { result, error in
                    if let error = error {
                        self?.debugServer?.addLog("chi error: \(error.localizedDescription)")
                    } else {
                        self?.debugServer?.addLog("chi result: \(String(describing: result))")
                    }
                }
            }

        case .pon, .kan, .hora:
            let action = actionType.rawValue
            debugServer?.addLog("Exec: \(action)...")
            let script = "window.__nakiGameAPI.smartExecute('\(action)', {})"
            webView.evaluateJavaScript(script) { [weak self] result, error in
                if let error = error {
                    self?.debugServer?.addLog("\(action) error: \(error.localizedDescription)")
                } else {
                    self?.debugServer?.addLog("\(action) result: \(String(describing: result))")
                }
            }

        case .none:
            debugServer?.addLog("Exec: pass...")
            let script = "window.__nakiGameAPI.smartExecute('pass', {})"
            webView.evaluateJavaScript(script) { [weak self] result, error in
                if let error = error {
                    self?.debugServer?.addLog("pass error: \(error.localizedDescription)")
                } else {
                    self?.debugServer?.addLog("pass result: \(String(describing: result))")
                }
            }

        case .unknown:
            bridgeLog("[WebViewModel] Unknown action type, skipping")
        }
    }

    /// 測試自動打牌指示器 - 顯示所有可能的點擊位置
    func testAutoPlayIndicators() {
        guard let webView = wkWebView else {
            statusMessage = "WebView 不可用"
            return
        }

        webView.evaluateJavaScript("window.__nakiTestIndicators ? __nakiTestIndicators() : 'Not loaded'") { [weak self] result, error in
            if let error = error {
                self?.statusMessage = "測試失敗: \(error.localizedDescription)"
            } else if let result = result as? String, result == "Not loaded" {
                self?.statusMessage = "自動打牌腳本尚未載入"
            } else {
                self?.statusMessage = "已顯示測試指示器"
            }
        }
    }

    /// 測試單次點擊 - 在畫面中央顯示點擊指示器
    func testSingleClick() {
        guard let webView = wkWebView else {
            statusMessage = "WebView 不可用"
            return
        }

        webView.evaluateJavaScript("window.__nakiTestClick ? __nakiTestClick(960, 540, '測試點擊') : 'Not loaded'") { [weak self] result, error in
            if let error = error {
                self?.statusMessage = "測試失敗: \(error.localizedDescription)"
            } else if let result = result as? String, result == "Not loaded" {
                self?.statusMessage = "自動打牌腳本尚未載入"
            } else {
                self?.statusMessage = "已顯示測試點擊"
            }
        }
    }

    /// 探測遊戲 API（尋找可用的座標系統）
    func detectGameAPI() {
        guard let webView = wkWebView else {
            statusMessage = "WebView 不可用"
            return
        }

        webView.evaluateJavaScript("window.__nakiDetectGameAPI ? __nakiDetectGameAPI() : null") { [weak self] result, error in
            if let error = error {
                self?.statusMessage = "探測失敗: \(error.localizedDescription)"
            } else if result == nil {
                self?.statusMessage = "探測腳本尚未載入"
            } else {
                self?.statusMessage = "已探測遊戲 API，請查看 Log"
            }
        }
    }

    /// 深度探索遊戲物件結構
    func exploreGameObjects() {
        guard let webView = wkWebView else {
            statusMessage = "WebView 不可用"
            return
        }

        webView.evaluateJavaScript("window.__nakiExploreGameObjects ? __nakiExploreGameObjects() : null") { [weak self] result, error in
            if let error = error {
                self?.statusMessage = "探索失敗: \(error.localizedDescription)"
            } else if result == nil {
                self?.statusMessage = "探索腳本尚未載入"
            } else {
                self?.statusMessage = "已探索遊戲物件，請查看 Log"
            }
        }
    }

    /// 尋找手牌座標
    func findHandTiles() {
        guard let webView = wkWebView else {
            statusMessage = "WebView 不可用"
            return
        }

        webView.evaluateJavaScript("window.__nakiFindHandTiles ? __nakiFindHandTiles() : null") { [weak self] result, error in
            if let error = error {
                self?.statusMessage = "搜尋失敗: \(error.localizedDescription)"
            } else if result == nil {
                self?.statusMessage = "搜尋腳本尚未載入"
            } else {
                self?.statusMessage = "已搜尋手牌資訊，請查看 Log"
            }
        }
    }

    // MARK: - Debug Server

    /// 啟動 Debug Server
    func startDebugServer() {
        guard debugServer == nil else {
            statusMessage = "Debug Server 已在運行"
            return
        }

        debugServer = DebugServer(port: debugServerPort)

        // 設置 JavaScript 執行回調
        debugServer?.executeJavaScript = { [weak self] script, completion in
            guard let webView = self?.wkWebView else {
                completion(nil, NSError(domain: "Naki", code: -1, userInfo: [NSLocalizedDescriptionKey: "WebView not available"]))
                return
            }

            DispatchQueue.main.async {
                webView.evaluateJavaScript(script) { result, error in
                    completion(result, error)
                }
            }
        }

        // 設置日誌回調
        debugServer?.onLog = { [weak self] message in
            bridgeLog(message)
            DispatchQueue.main.async {
                self?.statusMessage = message
            }
        }

        // ⭐ 設置 Bot 狀態回調
        debugServer?.getBotStatus = { [weak self] in
            guard let self = self else { return [:] }

            // 使用基本類型確保 JSON 序列化成功
            let recs: [[String: Any]] = self.recommendations.map { rec in
                return [
                    "tile": rec.displayTile,
                    "prob": rec.probability
                ]
            }

            var result: [String: Any] = [
                "botStatus": [
                    "isActive": self.botStatus.isActive,
                    "playerId": self.botStatus.playerId
                ],
                "gameState": [
                    "bakaze": self.gameState.bakazeDisplay,  // 用 String 而不是 enum
                    "kyoku": self.gameState.kyoku,
                    "honba": self.gameState.honba
                ],
                "autoPlay": [
                    "mode": self.autoPlayController?.state.mode.rawValue ?? "unknown",
                    "isMyTurn": self.autoPlayController?.state.isMyTurn ?? false,
                    "hasPendingAction": self.autoPlayController?.state.pendingAction != nil
                ],
                "recommendations": recs,
                "tehaiCount": self.tehaiTiles.count,
                "tsumoTile": self.tsumoTile ?? NSNull()
            ]

            return result
        }

        // ⭐ 設置手動觸發自動打牌回調
        debugServer?.triggerAutoPlay = { [weak self] in
            guard let self = self else { return }

            // 優先使用 lastAction (通過 AutoPlayController)
            if let controller = self.nativeBotController,
               let lastAction = controller.lastAction {
                self.debugServer?.addLog("Triggering with lastAction")
                self.autoPlayController?.handleRecommendedAction(
                    lastAction,
                    tehai: controller.tehai,
                    tsumo: controller.tsumo
                )
            } else {
                // 使用當前推薦
                self.triggerAutoPlayNow()
            }
        }

        // ⭐ 設置 JavaScript 執行回調
        debugServer?.evaluateJS = { [weak self] script, completion in
            guard let webView = self?.wkWebView else {
                completion(nil, NSError(domain: "WebView", code: -1, userInfo: [NSLocalizedDescriptionKey: "WebView not available"]))
                return
            }
            webView.evaluateJavaScript(script, completionHandler: completion)
        }

        debugServer?.start()
        isDebugServerRunning = true
        statusMessage = "Debug Server 已啟動: http://localhost:\(debugServerPort)"
    }

    /// 停止 Debug Server
    func stopDebugServer() {
        debugServer?.stop()
        debugServer = nil
        isDebugServerRunning = false
        statusMessage = "Debug Server 已停止"
    }

    /// 切換 Debug Server
    func toggleDebugServer() {
        if isDebugServerRunning {
            stopDebugServer()
        } else {
            startDebugServer()
        }
    }

    /// 更新點擊位置校準參數
    func updateClickCalibration(tileSpacing: Double, offsetX: Double, offsetY: Double) {
        guard let webView = wkWebView else {
            statusMessage = "WebView 不可用"
            return
        }

        let script = """
        if (window.__nakiAutoPlay) {
            window.__nakiAutoPlay.calibration = {
                tileSpacing: \(tileSpacing),
                offsetX: \(offsetX),
                offsetY: \(offsetY)
            };
            console.log('[Naki] Calibration updated:', window.__nakiAutoPlay.calibration);
            true;
        } else {
            false;
        }
        """

        webView.evaluateJavaScript(script) { [weak self] result, error in
            if let error = error {
                self?.statusMessage = "校準失敗: \(error.localizedDescription)"
            } else if let success = result as? Bool, success {
                self?.statusMessage = "校準已更新: 間距=\(Int(tileSpacing)), X=\(Int(offsetX)), Y=\(Int(offsetY))"
            } else {
                self?.statusMessage = "自動打牌腳本尚未載入"
            }
        }
    }

    // MARK: - Load HTML

    // WKWebView 載入方法
    func loadHTMLInWKWebView() async {
        guard let webView = wkWebView else { return }

        await MainActor.run {
            // 載入雀魂麻將遊戲
            if let url = URL(string: "https://game.maj-soul.com/1/") {
                webView.load(URLRequest(url: url))
                statusMessage = "正在加載雀魂麻將..."
            }
        }
    }

    // 載入本地 HTML 檔案
    func loadLocalHTML() async {
        guard let webView = wkWebView else { return }

        await MainActor.run {
            if let htmlPath = Bundle.main.path(forResource: "index", ofType: "html"),
               let htmlURL = URL(string: "file://\(htmlPath)") {
                webView.loadFileURL(htmlURL, allowingReadAccessTo: htmlURL.deletingLastPathComponent())
                statusMessage = "已加載本地界面"
            }
        }
    }

    // 載入指定 URL
    func loadURL(_ urlString: String) async {
        guard let webView = wkWebView else { return }

        await MainActor.run {
            if let url = URL(string: urlString) {
                webView.load(URLRequest(url: url))
                statusMessage = "正在加載 \(urlString)"
            }
        }
    }

    // 原生 WebPage 載入方法（簡化版，僅供參考）
    func loadHTML() async {
        guard let webPage = webPage else { return }

        // 載入雀魂麻將遊戲
        if let url = URL(string: "https://game.maj-soul.com/1/") {
            webPage.load(url)
            statusMessage = "正在加載雀魂麻將..."
        }
    }

    // MARK: - Call JavaScript

    func callJS(function: String, params: [String: Any]) async {
        // 使用 WKWebView 執行 JavaScript
        guard let webView = wkWebView else {
            print("WKWebView not ready")
            return
        }

        await MainActor.run {
            do {
                let jsonData = try JSONSerialization.data(withJSONObject: params)
                let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"

                let script = "\(function)(\(jsonString));"

                webView.evaluateJavaScript(script) { result, error in
                    if let error = error {
                        print("JavaScript Error: \(error.localizedDescription)")
                    }
                }
            } catch {
                print("JSON Serialization Error: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Deprecated Methods (保留接口以兼容舊代碼)

    func createBot(playerId: Int) async -> Result<Void, Error> {
        do {
            try await createNativeBot(playerId: playerId)
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    func sendEvent(playerId: Int, event: [String: Any]) async -> Result<[String: Any]?, Error> {
        do {
            let response = try await processNativeEvent(event)
            return .success(response)
        } catch {
            return .failure(error)
        }
    }

    func deleteBot(playerId: Int) async -> Result<Void, Error> {
        deleteNativeBot()
        return .success(())
    }
}
