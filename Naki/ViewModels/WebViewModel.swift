//
//  WebViewModel.swift
//  Naki - 雀魂麻將 AI 助手
//
//  Created by Suoie on 2025/11/29.
//
//  核心視圖模型，負責：
//  - 遊戲狀態管理 (GameState, BotStatus)
//  - Bot 控制 (NativeBotController + MortalSwift)
//  - 自動打牌邏輯 (AutoPlayController)
//  - Debug Server (HTTP API)
//  - WebView 整合 (JavaScript Bridge)
//
//  更新日誌:
//  - 2025/11/30: 移除 Python 依賴，純 Swift 實現
//  - 2025/12/02: v1.1.2 重構 - 提取重複代碼，清理未使用變數
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

    /// 當前正在執行的動作ID（用於追蹤而非阻擋）
    private var currentExecutionId: UUID?

    /// 上次觸發的動作和時間（防抖動）
    private var lastTriggerKey: String?
    private var lastTriggerTime: Date?

    /// 定期檢查計時器
    private var autoPlayCheckTimer: Timer?

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

        // ⭐ 啟動定期檢查計時器（每 2 秒檢查一次）
        startAutoPlayCheckTimer()

        statusMessage = "準備就緒 (全自動模式)"
    }

    /// 啟動定期檢查計時器
    private func startAutoPlayCheckTimer() {
        autoPlayCheckTimer?.invalidate()
        autoPlayCheckTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.checkAndRetriggerAutoPlay()
        }
    }

    /// 定期檢查：如果有推薦且沒有正在執行的動作，重新觸發
    private func checkAndRetriggerAutoPlay() {
        guard autoPlayController?.state.mode == .auto,
              !recommendations.isEmpty,
              currentExecutionId == nil,  // 沒有正在執行的動作
              let webView = wkWebView else { return }

        // 檢查遊戲是否有可用操作
        let checkScript = """
        (function() {
            var dm = window.view.DesktopMgr.Inst;
            if (!dm || !dm.oplist || dm.oplist.length === 0) return false;
            return true;
        })()
        """

        webView.evaluateJavaScript(checkScript) { [weak self] result, _ in
            guard let self = self,
                  let hasOp = result as? Bool, hasOp else { return }

            // 有 oplist 且有推薦，重新觸發
            self.debugServer?.addLog("⏰ Timer: retrigger auto-play")
            self.triggerAutoPlayNow(delay: 0.1)  // 短延遲立即執行
        }
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

    /// 處理單一 MJAI 事件
    func processNativeEvent(_ event: [String: Any]) async throws -> [String: Any]? {
        guard let controller = nativeBotController else {
            throw NativeBotError.botNotInitialized
        }
        let response = try await controller.react(event: event)
        await MainActor.run { updateUIAfterBotResponse(from: controller) }
        return response
    }

    /// 批量處理多個 MJAI 事件
    func processNativeEvents(_ events: [[String: Any]]) async throws -> [String: Any]? {
        guard let controller = nativeBotController else {
            throw NativeBotError.botNotInitialized
        }
        let response = try await controller.react(events: events)
        await MainActor.run { updateUIAfterBotResponse(from: controller) }
        return response
    }

    /// 從 Bot 控制器更新 UI 狀態並觸發自動打牌
    private func updateUIAfterBotResponse(from controller: NativeBotController) {
        // 更新遊戲狀態
        gameState = controller.gameState
        botStatus = controller.botState
        tehaiTiles = controller.tehaiMjai
        tsumoTile = controller.lastTsumo
        recommendations = controller.lastRecommendations
        recommendationCount = recommendations.count

        // 更新高亮牌
        if let firstRec = recommendations.first {
            highlightedTile = firstRec.displayTile
        }

        // 觸發自動打牌
        triggerAutoPlayIfNeeded()
    }

    /// 根據當前推薦觸發自動打牌
    private func triggerAutoPlayIfNeeded() {
        let autoMode = autoPlayController?.state.mode
        let hasRecs = !recommendations.isEmpty

        guard autoMode == .auto, hasRecs else { return }

        // 根據動作類型決定延遲時間
        guard let firstRec = recommendations.first else { return }
        let firstAction = firstRec.actionType
        let tileName = firstRec.displayTile
        let delay: TimeInterval = calculateDelay(for: firstAction)

        // ⭐ 防抖動：如果同一個動作在短時間內已經觸發過，跳過
        // 但對於 none (pass) 動作，不使用防抖動，因為每次有新的副露機會都需要響應
        let triggerKey = "\(firstAction.rawValue)-\(tileName)"
        let now = Date()
        let isPassAction = firstAction == .none

        if !isPassAction,  // pass 動作不受防抖動限制
           let lastKey = lastTriggerKey,
           let lastTime = lastTriggerTime,
           lastKey == triggerKey,
           now.timeIntervalSince(lastTime) < delay + 0.5 {
            // 同一個動作在 delay + 0.5 秒內已觸發過，跳過
            return
        }

        // 記錄這次觸發
        lastTriggerKey = triggerKey
        lastTriggerTime = now

        debugServer?.addLog("AutoCheck: \(firstAction.rawValue)-\(tileName) (delay: \(delay)s)")
        triggerAutoPlayNow(delay: delay)
    }

    /// 計算動作延遲時間
    private func calculateDelay(for actionType: Recommendation.ActionType?) -> TimeInterval {
        // 注意：.none 會跟 Optional.none 衝突，所以要用 .some(.none)
        switch actionType {
        case .hora:
            return 1.0   // 和牌: 等待遊戲 oplist 更新
        case .chi, .pon, .kan:
            return 1.5   // 副露: 等待遊戲 UI 完全準備好
        case .some(.none):
            return 1.0   // 跳過: 等待遊戲 oplist 準備好（太短會在 oplist 出現前執行）
        default:
            return 1.8   // 打牌: 較長延遲確保穩定
        }
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

        // 生成執行 ID 用於追蹤
        let executionId = UUID()
        currentExecutionId = executionId

        bridgeLog("[WebViewModel] Triggering: \(actionType.rawValue) - \(tileName) (delay: \(delay)s)")
        debugServer?.addLog("Trigger: \(actionType.rawValue) - \(tileName)")

        // 延遲執行避免太快
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }

            // 檢查是否被更新的觸發取代
            if self.currentExecutionId != executionId {
                self.debugServer?.addLog("Skip: superseded by newer trigger")
                return
            }

            // ⭐ hora 不使用重試機制，直接執行（時間窗口很短）
            if actionType == .hora {
                self.debugServer?.addLog("Hora: direct exec (no retry)")
                self.executeAutoPlayAction(webView: webView, actionType: actionType, tileName: tileName)
            } else {
                self.executeAutoPlayActionWithRetry(webView: webView, actionType: actionType, tileName: tileName, attempt: 1, executionId: executionId)
            }
        }
    }

    /// 最大重試次數
    private let maxRetryAttempts = 50  // 50 次 x 0.1s = 最多等 5 秒

    /// 帶重試的自動打牌執行
    /// ⭐ 改進版：如果 oplist 還沒準備好，會等待並重試
    /// - Parameters:
    ///   - webView: WKWebView 實例
    ///   - actionType: 動作類型
    ///   - tileName: 牌名
    ///   - attempt: 當前嘗試次數
    ///   - executionId: 執行 ID，用於檢查是否被取代
    private func executeAutoPlayActionWithRetry(webView: WKWebView, actionType: Recommendation.ActionType, tileName: String, attempt: Int, executionId: UUID) {

        // ⭐ 檢查是否被新的觸發取代
        if currentExecutionId != executionId {
            debugServer?.addLog("⏭️ Retry cancelled: superseded (attempt \(attempt))")
            return
        }

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

            // ⭐ 再次檢查是否被取代（JS 回調後）
            if self.currentExecutionId != executionId {
                self.debugServer?.addLog("⏭️ Retry cancelled after JS: superseded")
                return
            }

            // 解析結果
            if let dict = result as? [String: Any],
               let hasOp = dict["hasOp"] as? Bool {

                if !hasOp {
                    // ⭐ 沒有 oplist
                    let reason = dict["reason"] as? String ?? "unknown"

                    // ⭐ 打牌 (discard) 不需要等待 oplist，直接執行
                    // 因為打牌只需要輪到自己，不需要特定的 oplist
                    if actionType == .discard {
                        self.debugServer?.addLog("Discard: no oplist, exec directly")
                        self.executeAutoPlayAction(webView: webView, actionType: actionType, tileName: tileName)
                        // 檢查是否成功（延遲後檢查 oplist 是否清空）
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                            self?.debugServer?.addLog("✅ Discard sent")
                            self?.currentExecutionId = nil
                        }
                        return
                    }

                    // ⭐ 其他動作（pass/chi/pon/kan/hora/riichi）需要等待 oplist
                    if attempt < self.maxRetryAttempts {
                        // 繼續等待 oplist
                        if attempt == 1 || attempt % 10 == 0 {
                            self.debugServer?.addLog("Wait oplist \(attempt)/\(self.maxRetryAttempts) (\(reason))")
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                            self?.executeAutoPlayActionWithRetry(webView: webView, actionType: actionType, tileName: tileName, attempt: attempt + 1, executionId: executionId)
                        }
                    } else {
                        // 超過最大嘗試次數
                        // 對於 pass，如果等了很久還沒有 oplist，可能真的沒有機會
                        if actionType == .none {
                            self.debugServer?.addLog("✅ Pass: no oplist after \(attempt) attempts, no opportunity")
                        } else {
                            self.debugServer?.addLog("❌ No oplist after \(attempt) attempts, giving up")
                        }
                        // ⭐ 清除執行 ID，讓定期檢查可以重新觸發
                        self.currentExecutionId = nil
                    }
                    return
                }

                // 還有操作，執行動作
                let opInfo = dict["opTypes"] as? [Int] ?? []
                self.debugServer?.addLog("Attempt \(attempt): ops=\(opInfo)")

                // 執行動作
                self.executeAutoPlayAction(webView: webView, actionType: actionType, tileName: tileName)

                // ⭐ pass 操作：較長間隔 (0.5s)，最多重試 5 次
                if actionType == .none {
                    let maxPassRetries = 5
                    if attempt >= maxPassRetries {
                        self.debugServer?.addLog("✅ Pass sent (\(attempt) attempts)")
                        return
                    }
                    // 0.5 秒後檢查，給伺服器足夠時間處理
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        self?.checkAndRetryIfNeeded(webView: webView, actionType: actionType, tileName: tileName, attempt: attempt, executionId: executionId)
                    }
                    return
                }

                // 其他操作：0.1 秒後檢查是否成功
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.checkAndRetryIfNeeded(webView: webView, actionType: actionType, tileName: tileName, attempt: attempt, executionId: executionId)
                }
            } else {
                // 無法解析，直接執行一次
                self.debugServer?.addLog("Attempt \(attempt): check failed, exec anyway")
                self.executeAutoPlayAction(webView: webView, actionType: actionType, tileName: tileName)
            }
        }
    }

    /// 檢查動作是否成功，失敗則重試
    /// ⭐ 改進版：檢查畫面狀態而不只是 oplist
    private func checkAndRetryIfNeeded(webView: WKWebView, actionType: Recommendation.ActionType, tileName: String, attempt: Int, executionId: UUID) {

        // ⭐ 檢查是否被新的觸發取代
        if currentExecutionId != executionId {
            debugServer?.addLog("⏭️ Check cancelled: superseded")
            return
        }

        // 根據動作類型使用不同的驗證腳本
        let checkScript = """
        (function() {
            var dm = window.view.DesktopMgr.Inst;
            if (!dm) return {success: true, reason: 'no dm'};

            var actionType = '\(actionType.rawValue)';
            var tileName = '\(tileName)';

            // ⭐ 檢查 oplist 是否還有我們要執行的操作
            if (dm.oplist && dm.oplist.length > 0) {
                var opTypes = dm.oplist.map(o => o.type);

                // 根據動作類型檢查
                if (actionType === 'discard') {
                    // 打牌：檢查是否還有 type 1 (dapai)
                    if (opTypes.includes(1)) {
                        return {success: false, reason: 'discard op still present', opTypes: opTypes};
                    }
                } else if (actionType === 'chi') {
                    if (opTypes.includes(2)) {
                        return {success: false, reason: 'chi op still present', opTypes: opTypes};
                    }
                } else if (actionType === 'pon') {
                    if (opTypes.includes(3)) {
                        return {success: false, reason: 'pon op still present', opTypes: opTypes};
                    }
                } else if (actionType === 'kan') {
                    if (opTypes.includes(4) || opTypes.includes(5) || opTypes.includes(6)) {
                        return {success: false, reason: 'kan op still present', opTypes: opTypes};
                    }
                } else if (actionType === 'hora') {
                    if (opTypes.includes(8) || opTypes.includes(9)) {
                        return {success: false, reason: 'hora op still present', opTypes: opTypes};
                    }
                } else if (actionType === 'none') {
                    // 跳過：如果還有吃碰槓和的選項，表示還沒跳過
                    var hasCallOp = opTypes.some(t => t >= 2 && t <= 9);
                    if (hasCallOp) {
                        return {success: false, reason: 'call ops still present', opTypes: opTypes};
                    }
                }
            }

            // oplist 空了或不包含我們的操作，認為成功
            return {success: true, reason: 'oplist cleared or action done'};
        })()
        """

        webView.evaluateJavaScript(checkScript) { [weak self] result, _ in
            guard let self = self else { return }

            if let dict = result as? [String: Any],
               let success = dict["success"] as? Bool {

                if success {
                    let reason = dict["reason"] as? String ?? "ok"
                    self.debugServer?.addLog("✅ Action success after \(attempt) attempts (\(reason))")
                    self.currentExecutionId = nil  // ⭐ 清除執行 ID
                    return
                }

                // 失敗，需要重試
                let opInfo = dict["opTypes"] as? [Int] ?? []

                if attempt >= self.maxRetryAttempts {
                    self.debugServer?.addLog("❌ Max retries reached (\(attempt)), ops=\(opInfo)")
                    self.currentExecutionId = nil  // ⭐ 清除執行 ID
                    return
                }

                // 重試
                self.debugServer?.addLog("Retry \(attempt + 1): ops still present \(opInfo)")
                self.executeAutoPlayActionWithRetry(webView: webView, actionType: actionType, tileName: tileName, attempt: attempt + 1, executionId: executionId)
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
            //
            // Mortal 的 chi 類型定義：
            //   chi_0 (chiLow)  = 被吃的牌在順子中最小 (例如吃 1，用 2-3 組成 1-2-3)
            //   chi_1 (chiMid)  = 被吃的牌在順子中間 (例如吃 2，用 1-3 組成 1-2-3)
            //   chi_2 (chiHigh) = 被吃的牌在順子中最大 (例如吃 3，用 1-2 組成 1-2-3)
            //
            // 遊戲的 combination 陣列按手牌順序排列（從小到大）：
            //   例如吃 3p，combinations = ["1p|2p", "2p|4p", "4p|5p"]
            //   - index 0: 1p|2p → 1-2-3，被吃牌 3 是最大 → chi_2
            //   - index 1: 2p|4p → 2-3-4，被吃牌 3 是中間 → chi_1
            //   - index 2: 4p|5p → 3-4-5，被吃牌 3 是最小 → chi_0
            //
            // 所以映射是反轉的：gameIndex = count - 1 - chiType
            //
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

                // 組合格式: ["1p|2p", "2p|4p", "4p|5p"] 表示可用的手牌組合（按數值從小到大）
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

                // ⭐ 反轉映射：chi_0 → 最後一個，chi_2 → 第一個
                // 如果只有一個組合，直接用 0
                let combIndex: Int
                if combinations.count == 1 {
                    combIndex = 0
                } else {
                    // gameIndex = count - 1 - chiType
                    combIndex = max(0, combinations.count - 1 - chiType)
                }
                let combInfo = combinations.isEmpty ? "" : " [\(combinations.joined(separator: ", "))]"
                self?.debugServer?.addLog("Chi: mortal=chi_\(chiType) → gameIdx=\(combIndex)\(combInfo)")

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
                } else if let resultNum = result as? Int, resultNum > 0 {
                    self?.debugServer?.addLog("pass OK")
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

            let result: [String: Any] = [
                "botStatus": [
                    "isActive": self.botStatus.isActive,
                    "playerId": self.botStatus.playerId
                ],
                "gameState": [
                    "bakaze": self.gameState.bakazeDisplay,
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
