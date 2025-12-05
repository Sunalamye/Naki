//
//  AutoPlayController.swift
//  Naki
//
//  Created by Claude on 2025/12/01.
//  自動打牌控制器 - 管理自動打牌模式 (UI 自動化方案)
//  Updated: 2025/12/04 - 遷移至 WebPage API (macOS 26.0+)
//

import Combine
import Foundation
import WebKit
import MortalSwift


// MARK: - Auto Play Mode

/// 自動打牌模式
enum AutoPlayMode: String, CaseIterable {
    case off = "關閉"            // 不顯示推薦，不自動打牌（AI 仍在背景運算）
    case recommend = "推薦"      // 顯示推薦，需要手動打牌
    case auto = "自動"           // 顯示推薦，自動執行推薦動作

    /// 是否顯示推薦（推薦和自動模式都顯示）
    var showRecommendation: Bool {
        return self != .off
    }

    /// 是否啟用自動打牌（只有自動模式）
    var isFullAuto: Bool {
        return self == .auto
    }
}

// MARK: - Auto Play Action

/// 自動打牌的動作類型 (UI 版本)
enum AutoPlayAction {
    /// 打牌 (tileIndex: 手牌中的位置 0-12, 或 13 表示摸牌)
    case discard(tileIndex: Int, isRiichi: Bool)
    /// 跳過 (不吃/碰/槓)
    case pass
    /// 吃
    case chi
    /// 碰
    case pon
    /// 槓 (大明槓/暗槓/加槓)
    case kan
    /// 和牌 (自摸/榮和)
    case hora
    /// 流局
    case ryukyoku
    /// 九種九牌
    case kyushukyuhai
}

// MARK: - Auto Play State

/// 自動打牌狀態
struct AutoPlayState {
    var mode: AutoPlayMode = .auto  // 預設開啟全自動
    var isMyTurn: Bool = false
    var pendingAction: AutoPlayAction? = nil
    var lastActionTime: Date? = nil
    var actionDelay: TimeInterval = 1.0  // 動作間隔（秒）
    var errorCount: Int = 0
    var maxErrors: Int = 3
}

// MARK: - Auto Play Controller

/// 自動打牌控制器 (UI 自動化版本)
/// 使用 WebPage API (macOS 26.0+)
@available(macOS 26.0, *)
class AutoPlayController: ObservableObject {

    // MARK: - Published Properties

    @Published var state = AutoPlayState()
    @Published var lastError: String? = nil

    // MARK: - Private Properties

    /// WebPage 引用（用於執行 JavaScript）
    private weak var webPage: WebPage?

    /// 動作執行計時器
    private var actionTimer: Timer?

    /// 日誌標籤
    private let logTag = "[AutoPlay]"

    /// 當前手牌 (用於計算打牌的索引)
    private var currentTehai: [Tile] = []

    /// 當前摸牌
    private var currentTsumo: Tile? = nil

    // MARK: - Initialization

    init() {
        bridgeLog("\(logTag) Controller initialized (UI mode)")
    }

    // MARK: - Configuration

    /// 設置 WebPage 引用
    func setWebPage(_ webPage: WebPage?) {
        self.webPage = webPage
        bridgeLog("\(logTag) WebPage set")
    }

    /// 設置自動打牌模式
    func setMode(_ mode: AutoPlayMode) {
        state.mode = mode
        bridgeLog("\(logTag) Mode set to: \(mode.rawValue)")

        if mode == .off {
            cancelPendingAction()
        }
    }

    /// 設置動作延遲
    func setActionDelay(_ delay: TimeInterval) {
        state.actionDelay = max(0.5, min(5.0, delay))
    }

    /// 更新手牌狀態
    func updateHandState(tehai: [Tile], tsumo: Tile?) {
        currentTehai = tehai
        currentTsumo = tsumo
    }

    // MARK: - Game State Updates

    /// 通知輪到自己的回合
    func notifyMyTurn(canDiscard: Bool, canRiichi: Bool, canChi: Bool, canPon: Bool, canKan: Bool, canAgari: Bool) {
        state.isMyTurn = true
        bridgeLog("\(logTag) My turn - canDiscard=\(canDiscard), canRiichi=\(canRiichi), canChi=\(canChi), canPon=\(canPon), canKan=\(canKan), canAgari=\(canAgari)")
    }

    /// 通知回合結束
    func notifyTurnEnd() {
        state.isMyTurn = false
        cancelPendingAction()
    }

    // MARK: - Action Execution

    /// 處理 AI 推薦動作
    /// - Parameters:
    ///   - action: MJAIAction 推薦動作
    ///   - tehai: 當前手牌
    ///   - tsumo: 當前摸牌
    ///   - immediately: 是否立即執行（跳過延遲）
    func handleRecommendedAction(_ action: MJAIAction, tehai: [Tile], tsumo: Tile?, immediately: Bool = false) {
        // off 模式下不處理自動打牌（但 AI 推薦仍在背景運行）
        guard state.mode != .off else { return }

        // 更新手牌狀態
        updateHandState(tehai: tehai, tsumo: tsumo)

        // 轉換為自動打牌動作
        guard let autoPlayAction = createUIAction(from: action) else {
            bridgeLog("\(logTag) Cannot convert action: \(action)")
            return
        }

        state.pendingAction = autoPlayAction

        if state.mode.isFullAuto {
            // 全自動模式：延遲後執行
            if immediately {
                executeAction(autoPlayAction)
            } else {
                scheduleAction(autoPlayAction)
            }
        } else {
            // 推薦確認模式：等待用戶確認
            bridgeLog("\(logTag) Action pending confirmation: \(autoPlayAction)")
        }
    }

    /// 從 MJAIAction 創建 UI 動作
    private func createUIAction(from mjaiAction: MJAIAction) -> AutoPlayAction? {
        switch mjaiAction {
        case .dahai(let action):
            // 找到要打的牌在手牌中的索引
            let tile = action.pai
            let isRiichi = false  // riichi 會作為獨立動作處理

            // 檢查是否是摸切
            if action.tsumogiri, currentTsumo == tile {
                return .discard(tileIndex: 13, isRiichi: isRiichi)
            }

            // 在手牌中查找
            if let index = currentTehai.firstIndex(of: tile) {
                return .discard(tileIndex: index, isRiichi: isRiichi)
            }

            // 如果手牌中找不到，可能是摸牌
            if currentTsumo == tile {
                return .discard(tileIndex: 13, isRiichi: isRiichi)
            }

            bridgeLog("\(logTag) Tile \(tile.mjaiString) not found in hand")
            return nil

        case .reach:
            // 立直通常伴隨 dahai，這裡只處理立直按鈕點擊
            // 實際打牌會在下一個 dahai 動作中處理
            return nil

        case .chi:
            return .chi

        case .pon:
            return .pon

        case .daiminkan, .ankan, .kakan:
            return .kan

        case .hora:
            return .hora

        case .ryukyoku:
            return .ryukyoku

        case .pass:
            return .pass

        case .nukidora:
            // 北抜き - 三麻專用，暫不支援
            return nil
        }
    }

    /// 確認並執行待處理動作
    func confirmPendingAction() {
        guard let action = state.pendingAction else {
            bridgeLog("\(logTag) No pending action to confirm")
            return
        }

        executeAction(action)
    }

    /// 取消待處理動作
    func cancelPendingAction() {
        actionTimer?.invalidate()
        actionTimer = nil
        state.pendingAction = nil
    }

    /// 調度動作執行（帶延遲）
    private func scheduleAction(_ action: AutoPlayAction) {
        actionTimer?.invalidate()

        let delay = state.actionDelay
        bridgeLog("\(logTag) Scheduling action with \(delay)s delay")

        actionTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.executeAction(action)
        }
    }

    /// 執行動作 (透過 UI 自動化)
    private func executeAction(_ action: AutoPlayAction) {
        guard let webPage = webPage else {
            bridgeLog("\(logTag) Error: WebPage not available")
            lastError = "WebPage 不可用"
            return
        }

        let script = generateJavaScript(for: action)
        bridgeLog("\(logTag) Executing: \(script)")

        Task { @MainActor [weak self] in
            do {
                _ = try await webPage.callJavaScript(script)
                bridgeLog("\(self?.logTag ?? "") Action executed successfully")
                self?.handleActionSuccess()
            } catch {
                bridgeLog("\(self?.logTag ?? "") JS error: \(error.localizedDescription)")
                self?.handleActionError(error.localizedDescription)
            }
        }
    }

    /// 生成執行動作的 JavaScript 代碼
    /// ⭐ 使用 smartExecute：優先直接 API，失敗則備用座標點擊
    private func generateJavaScript(for action: AutoPlayAction) -> String {
        // 手牌數量（用於計算摸牌位置）
        let handCount = currentTehai.count

        switch action {
        case .discard(let tileIndex, let isRiichi):
            // 傳遞 handCount 讓 JS 知道實際手牌數
            if isRiichi {
                return "window.__nakiGameAPI.smartExecute('riichi', {tileIndex: \(tileIndex), handCount: \(handCount)})"
            } else {
                return "window.__nakiGameAPI.smartExecute('discard', {tileIndex: \(tileIndex), handCount: \(handCount)})"
            }

        case .pass:
            return "window.__nakiGameAPI.smartExecute('pass', {})"

        case .chi:
            return "window.__nakiGameAPI.smartExecute('chi', {})"

        case .pon:
            return "window.__nakiGameAPI.smartExecute('pon', {})"

        case .kan:
            return "window.__nakiGameAPI.smartExecute('kan', {})"

        case .hora:
            return "window.__nakiGameAPI.smartExecute('hora', {})"

        case .ryukyoku:
            return "window.__nakiGameAPI.smartExecute('ryukyoku', {})"

        case .kyushukyuhai:
            return "window.__nakiGameAPI.smartExecute('kyushu', {})"
        }
    }

    /// 處理動作成功
    private func handleActionSuccess() {
        state.pendingAction = nil
        state.lastActionTime = Date()
        state.errorCount = 0
        lastError = nil
    }

    /// 處理動作失敗
    private func handleActionError(_ error: String) {
        state.errorCount += 1
        lastError = error

        if state.errorCount >= state.maxErrors {
            bridgeLog("\(logTag) Too many errors, disabling auto-play")
            setMode(.off)
            lastError = "錯誤過多，已停止自動打牌"
        }
    }

    // MARK: - Status

    /// 獲取狀態描述
    var statusDescription: String {
        switch state.mode {
        case .off:
            return "自動打牌已關閉"
        case .recommend:
            if let _ = state.pendingAction {
                return "等待確認..."
            } else {
                return "推薦確認模式"
            }
        case .auto:
            if state.isMyTurn {
                return "自動執行中..."
            } else {
                return "全自動模式"
            }
        }
    }
}
