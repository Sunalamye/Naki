//
//  AutoPlayService.swift
//  Naki
//
//  Created by Claude on 2025/12/03.
//  自動打牌服務 - 協調重試機制與動作執行
//

import Combine
import Foundation
import WebKit

// MARK: - Auto Play Service Delegate

/// 自動打牌服務的委託協議
protocol AutoPlayServiceDelegate: AnyObject {
    /// 記錄日誌
    func autoPlayService(_ service: AutoPlayService, didLog message: String)
    /// 動作執行成功
    func autoPlayService(_ service: AutoPlayService, didComplete actionType: Recommendation.ActionType)
    /// 動作執行失敗
    func autoPlayService(_ service: AutoPlayService, didFail actionType: Recommendation.ActionType, error: String)
}

// MARK: - Auto Play Service

/// 自動打牌服務
/// 負責協調動作執行、重試機制和狀態管理
final class AutoPlayService {

    // MARK: - Properties

    /// 委託
    weak var delegate: AutoPlayServiceDelegate?

    /// WebView 引用
    private weak var webView: WKWebView?

    /// 當前執行 ID（用於取消舊任務）
    private var currentExecutionId: UUID?

    /// 最大重試次數
    private let maxRetryAttempts = 50  // 50 次 x 0.1s = 最多等 5 秒

    /// 是否正在執行動作
    private(set) var isExecuting = false

    /// 日誌標籤
    private let logTag = "[AutoPlayService]"

    // MARK: - Initialization

    init() {
        bridgeLog("\(logTag) Service initialized")
    }

    // MARK: - Configuration

    /// 設置 WebView 引用
    func setWebView(_ webView: WKWebView?) {
        self.webView = webView
    }

    // MARK: - Action Execution

    /// 觸發自動打牌動作
    /// - Parameters:
    ///   - actionType: 動作類型
    ///   - tileName: 牌名（用於顯示和日誌）
    ///   - delay: 延遲執行的秒數
    func triggerAction(actionType: Recommendation.ActionType, tileName: String, delay: TimeInterval = 0) {
        guard let webView = webView else {
            log("Cannot trigger: no WebView")
            delegate?.autoPlayService(self, didFail: actionType, error: "WebView 不可用")
            return
        }

        // 生成執行 ID 用於追蹤
        let executionId = UUID()
        currentExecutionId = executionId
        isExecuting = true

        log("Trigger: \(actionType.rawValue) - \(tileName) (delay: \(delay)s)")

        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.startExecution(webView: webView, actionType: actionType, tileName: tileName, executionId: executionId)
            }
        } else {
            startExecution(webView: webView, actionType: actionType, tileName: tileName, executionId: executionId)
        }
    }

    /// 取消當前執行
    func cancelExecution() {
        if currentExecutionId != nil {
            log("Execution cancelled")
            currentExecutionId = nil
            isExecuting = false
        }
    }

    // MARK: - Private Methods

    /// 開始執行（檢查是否被取代）
    private func startExecution(webView: WKWebView, actionType: Recommendation.ActionType, tileName: String, executionId: UUID) {
        // 檢查是否被更新的觸發取代
        if currentExecutionId != executionId {
            log("Skip: superseded by newer trigger")
            return
        }

        executeWithRetry(webView: webView, actionType: actionType, tileName: tileName, attempt: 1, executionId: executionId)
    }

    /// 帶重試的執行邏輯
    /// - 如果 oplist 還沒準備好，會等待並重試
    private func executeWithRetry(webView: WKWebView, actionType: Recommendation.ActionType, tileName: String, attempt: Int, executionId: UUID) {

        // 檢查是否被新的觸發取代
        if currentExecutionId != executionId {
            log("⏭️ Retry cancelled: superseded (attempt \(attempt))")
            return
        }

        // 先檢查是否還有操作可執行
        let checkScript = """
        (function() {
            var dm = window.view.DesktopMgr.Inst;
            if (!dm) return {hasOp: false, reason: 'no dm'};
            if (!dm.oplist || dm.oplist.length === 0) return {hasOp: false, reason: 'no oplist'};

            var opTypes = dm.oplist.map(o => o.type);
            return {hasOp: true, opTypes: opTypes, count: dm.oplist.length};
        })()
        """

        webView.evaluateJavaScript(checkScript) { [weak self] result, _ in
            guard let self = self else { return }

            // 再次檢查是否被取代
            if self.currentExecutionId != executionId {
                self.log("⏭️ Retry cancelled after JS: superseded")
                return
            }

            self.handleCheckResult(
                result: result,
                webView: webView,
                actionType: actionType,
                tileName: tileName,
                attempt: attempt,
                executionId: executionId
            )
        }
    }

    /// 處理檢查結果
    private func handleCheckResult(result: Any?, webView: WKWebView, actionType: Recommendation.ActionType, tileName: String, attempt: Int, executionId: UUID) {

        guard let dict = result as? [String: Any],
              let hasOp = dict["hasOp"] as? Bool else {
            // 無法解析，直接執行一次
            log("Attempt \(attempt): check failed, exec anyway")
            executeAction(webView: webView, actionType: actionType, tileName: tileName)
            return
        }

        if !hasOp {
            handleNoOplist(
                reason: dict["reason"] as? String ?? "unknown",
                webView: webView,
                actionType: actionType,
                tileName: tileName,
                attempt: attempt,
                executionId: executionId
            )
            return
        }

        // 有操作，執行動作
        let opInfo = dict["opTypes"] as? [Int] ?? []
        log("Attempt \(attempt): ops=\(opInfo)")

        executeAction(webView: webView, actionType: actionType, tileName: tileName)

        // pass 操作：較長間隔 (0.5s)，最多重試 5 次
        if actionType == .none {
            let maxPassRetries = 5
            if attempt >= maxPassRetries {
                log("✅ Pass sent (\(attempt) attempts)")
                completeExecution(actionType: actionType)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.checkAndRetryIfNeeded(
                    webView: webView,
                    actionType: actionType,
                    tileName: tileName,
                    attempt: attempt,
                    executionId: executionId
                )
            }
            return
        }

        // 其他操作：0.1 秒後檢查是否成功
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.checkAndRetryIfNeeded(
                webView: webView,
                actionType: actionType,
                tileName: tileName,
                attempt: attempt,
                executionId: executionId
            )
        }
    }

    /// 處理沒有 oplist 的情況
    private func handleNoOplist(reason: String, webView: WKWebView, actionType: Recommendation.ActionType, tileName: String, attempt: Int, executionId: UUID) {

        // 打牌 (discard) 不需要等待 oplist，直接執行
        if actionType == .discard {
            log("Discard: no oplist, exec directly")
            executeAction(webView: webView, actionType: actionType, tileName: tileName)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.log("✅ Discard sent")
                self?.completeExecution(actionType: actionType)
            }
            return
        }

        // 其他動作需要等待 oplist
        if attempt < maxRetryAttempts {
            if attempt == 1 || attempt % 10 == 0 {
                log("Wait oplist \(attempt)/\(maxRetryAttempts) (\(reason))")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.executeWithRetry(
                    webView: webView,
                    actionType: actionType,
                    tileName: tileName,
                    attempt: attempt + 1,
                    executionId: executionId
                )
            }
        } else {
            // 超過最大嘗試次數
            if actionType == .none {
                log("✅ Pass: no oplist after \(attempt) attempts, no opportunity")
                completeExecution(actionType: actionType)
            } else {
                log("❌ No oplist after \(attempt) attempts, giving up")
                failExecution(actionType: actionType, error: "No oplist after \(attempt) attempts")
            }
        }
    }

    /// 檢查動作是否成功，失敗則重試
    private func checkAndRetryIfNeeded(webView: WKWebView, actionType: Recommendation.ActionType, tileName: String, attempt: Int, executionId: UUID) {

        // 檢查是否被新的觸發取代
        if currentExecutionId != executionId {
            log("⏭️ Check cancelled: superseded")
            return
        }

        let checkScript = generateVerificationScript(actionType: actionType, tileName: tileName)

        webView.evaluateJavaScript(checkScript) { [weak self] result, _ in
            guard let self = self else { return }

            guard let dict = result as? [String: Any],
                  let success = dict["success"] as? Bool else {
                return
            }

            if success {
                let reason = dict["reason"] as? String ?? "ok"
                self.log("✅ Action success after \(attempt) attempts (\(reason))")
                self.completeExecution(actionType: actionType)
                return
            }

            // 失敗，需要重試
            let opInfo = dict["opTypes"] as? [Int] ?? []

            if attempt >= self.maxRetryAttempts {
                self.log("❌ Max retries reached (\(attempt)), ops=\(opInfo)")
                self.failExecution(actionType: actionType, error: "Max retries reached")
                return
            }

            // 重試
            self.log("Retry \(attempt + 1): ops still present \(opInfo)")
            self.executeWithRetry(
                webView: webView,
                actionType: actionType,
                tileName: tileName,
                attempt: attempt + 1,
                executionId: executionId
            )
        }
    }

    /// 生成驗證腳本
    private func generateVerificationScript(actionType: Recommendation.ActionType, tileName: String) -> String {
        return """
        (function() {
            var dm = window.view.DesktopMgr.Inst;
            if (!dm) return {success: true, reason: 'no dm'};

            var actionType = '\(actionType.rawValue)';

            if (dm.oplist && dm.oplist.length > 0) {
                var opTypes = dm.oplist.map(o => o.type);

                if (actionType === 'discard') {
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
                    var hasCallOp = opTypes.some(t => t >= 2 && t <= 9);
                    if (hasCallOp) {
                        return {success: false, reason: 'call ops still present', opTypes: opTypes};
                    }
                }
            }

            return {success: true, reason: 'oplist cleared or action done'};
        })()
        """
    }

    /// 實際執行動作
    private func executeAction(webView: WKWebView, actionType: Recommendation.ActionType, tileName: String) {
        let script = generateActionScript(actionType: actionType, tileName: tileName)

        webView.evaluateJavaScript(script) { [weak self] result, error in
            if let error = error {
                self?.log("JS error: \(error.localizedDescription)")
            } else if let dict = result as? [String: Any] {
                self?.log("Result: \(dict)")
            }
        }
    }

    /// 生成動作腳本
    private func generateActionScript(actionType: Recommendation.ActionType, tileName: String) -> String {
        switch actionType {
        case .riichi:
            return generateRiichiScript()
        case .discard:
            return generateDiscardScript(tileName: tileName)
        case .chi:
            return generateChiScript(tileName: tileName)
        case .pon:
            return generatePonScript()
        case .kan:
            return generateKanScript()
        case .hora:
            return generateHoraScript()
        case .none:
            return generatePassScript()
        case .unknown:
            // 未知動作類型，跳過
            log("Unknown action type, skipping")
            return "console.log('[AutoPlayService] Unknown action type')"
        }
    }

    /// 完成執行
    private func completeExecution(actionType: Recommendation.ActionType) {
        currentExecutionId = nil
        isExecuting = false
        delegate?.autoPlayService(self, didComplete: actionType)
    }

    /// 執行失敗
    private func failExecution(actionType: Recommendation.ActionType, error: String) {
        currentExecutionId = nil
        isExecuting = false
        delegate?.autoPlayService(self, didFail: actionType, error: error)
    }

    /// 記錄日誌
    private func log(_ message: String) {
        bridgeLog("\(logTag) \(message)")
        delegate?.autoPlayService(self, didLog: message)
    }

    // MARK: - Script Generators

    private func generateRiichiScript() -> String {
        return """
        (function() {
            var dm = window.view.DesktopMgr.Inst;
            if (!dm || !dm.oplist) return {success: false, error: 'no oplist'};

            var riichiOp = dm.oplist.find(o => o.type === 7);
            if (!riichiOp) return {success: false, error: 'no riichi op'};

            if (window.app && window.app.NetAgent) {
                var combination = riichiOp.combination || [];
                var tileToDiscard = combination.length > 0 ? combination[0] : null;

                window.app.NetAgent.sendReq2MJ('FastTest', 'inputOperation', {
                    type: 7,
                    tile: tileToDiscard,
                    timeuse: 1
                });
                return {success: true, tile: tileToDiscard};
            }
            return {success: false, error: 'no NetAgent'};
        })()
        """
    }

    private func generateDiscardScript(tileName: String) -> String {
        return """
        (function() {
            var dm = window.view.DesktopMgr.Inst;
            if (!dm) return {success: false, error: 'no dm'};

            var mr = dm.mainrole;
            if (!mr) return {success: false, error: 'no mainrole'};

            var tileName = '\(tileName)';
            var foundTile = null;
            var foundIndex = -1;
            var isRedDora = tileName.endsWith('r');
            var normalTileName = isRedDora ? tileName.slice(0, -1) : tileName;

            // 在手牌中查找
            for (var i = 0; i < mr.hand.length; i++) {
                var t = mr.hand[i];
                if (!t || !t.val) continue;

                var type = t.val.type;
                var idx = t.val.index;
                var dora = t.val.dora === true;

                var suits = ['p', 'm', 's', 'z'];
                var suit = suits[type] || '?';
                var tName = idx + suit;

                // 處理字牌
                if (type === 3) {
                    var honors = ['?', 'E', 'S', 'W', 'N', 'P', 'F', 'C'];
                    tName = honors[idx] || tName;
                }

                // 精確匹配
                if (isRedDora) {
                    if (tName === normalTileName && dora) {
                        foundTile = t;
                        foundIndex = i;
                        break;
                    }
                } else {
                    if (tName === tileName && !dora) {
                        foundTile = t;
                        foundIndex = i;
                        break;
                    }
                    // 如果找不到普通牌但有赤牌，也可以使用
                    if (tName === tileName && foundTile === null) {
                        foundTile = t;
                        foundIndex = i;
                    }
                }
            }

            if (foundTile) {
                // 使用 NetAgent 發送打牌請求
                if (window.app && window.app.NetAgent) {
                    window.app.NetAgent.sendReq2MJ('FastTest', 'inputOperation', {
                        type: 1,
                        tile: foundTile.val.toString(),
                        moqie: false,
                        timeuse: 1
                    });
                    return {success: true, index: foundIndex, tile: tileName};
                }

                // 備用：直接操作遊戲 API
                if (typeof mr.DoDiscardTile === 'function') {
                    mr.DoDiscardTile(foundTile);
                    return {success: true, method: 'DoDiscardTile', index: foundIndex};
                }
            }

            return {success: false, error: 'tile not found: ' + tileName};
        })()
        """
    }

    private func generateChiScript(tileName: String) -> String {
        return """
        (function() {
            var dm = window.view.DesktopMgr.Inst;
            if (!dm || !dm.oplist) return {success: false, error: 'no oplist'};

            var chiOps = dm.oplist.filter(o => o.type === 2);
            if (chiOps.length === 0) return {success: false, error: 'no chi ops'};

            var chosenOp = chiOps[0];

            if (window.app && window.app.NetAgent) {
                var combination = chosenOp.combination || [];
                window.app.NetAgent.sendReq2MJ('FastTest', 'inputChiPengGang', {
                    type: 2,
                    index: 0,
                    timeuse: 1
                });
                return {success: true, combination: combination};
            }
            return {success: false, error: 'no NetAgent'};
        })()
        """
    }

    private func generatePonScript() -> String {
        return """
        (function() {
            var dm = window.view.DesktopMgr.Inst;
            if (!dm || !dm.oplist) return {success: false, error: 'no oplist'};

            var ponOp = dm.oplist.find(o => o.type === 3);
            if (!ponOp) return {success: false, error: 'no pon op'};

            if (window.app && window.app.NetAgent) {
                window.app.NetAgent.sendReq2MJ('FastTest', 'inputChiPengGang', {
                    type: 3,
                    index: 0,
                    timeuse: 1
                });
                return {success: true};
            }
            return {success: false, error: 'no NetAgent'};
        })()
        """
    }

    private func generateKanScript() -> String {
        return """
        (function() {
            var dm = window.view.DesktopMgr.Inst;
            if (!dm || !dm.oplist) return {success: false, error: 'no oplist'};

            // 找任何類型的槓 (4=暗槓, 5=大明槓, 6=加槓)
            var kanOp = dm.oplist.find(o => o.type === 4 || o.type === 5 || o.type === 6);
            if (!kanOp) return {success: false, error: 'no kan op'};

            if (window.app && window.app.NetAgent) {
                window.app.NetAgent.sendReq2MJ('FastTest', 'inputChiPengGang', {
                    type: kanOp.type,
                    index: 0,
                    timeuse: 1
                });
                return {success: true, kanType: kanOp.type};
            }
            return {success: false, error: 'no NetAgent'};
        })()
        """
    }

    private func generateHoraScript() -> String {
        return """
        (function() {
            var dm = window.view.DesktopMgr.Inst;
            if (!dm || !dm.oplist) return {success: false, error: 'no oplist'};

            // 找和牌操作 (8=自摸, 9=榮和)
            var horaOp = dm.oplist.find(o => o.type === 8 || o.type === 9);
            if (!horaOp) return {success: false, error: 'no hora op'};

            if (window.app && window.app.NetAgent) {
                window.app.NetAgent.sendReq2MJ('FastTest', 'inputOperation', {
                    type: horaOp.type,
                    timeuse: 1
                });
                return {success: true, horaType: horaOp.type === 8 ? 'tsumo' : 'ron'};
            }
            return {success: false, error: 'no NetAgent'};
        })()
        """
    }

    private func generatePassScript() -> String {
        return """
        (function() {
            var dm = window.view.DesktopMgr.Inst;
            if (!dm) return {success: false, error: 'no dm'};

            var mr = dm.mainrole;
            if (mr && typeof mr.QiPaiPass === 'function') {
                mr.QiPaiPass();
                return {success: true, method: 'QiPaiPass'};
            }

            // 備用：使用 NetAgent
            if (window.app && window.app.NetAgent) {
                window.app.NetAgent.sendReq2MJ('FastTest', 'inputOperation', {
                    cancel_operation: true,
                    timeuse: 1
                });
                return {success: true, method: 'NetAgent'};
            }

            return {success: false, error: 'no method available'};
        })()
        """
    }
}
