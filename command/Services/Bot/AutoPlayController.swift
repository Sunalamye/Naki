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
    case off = "關閉"            // 不自動打牌；目前 AI、側欄與 WebGL 高亮仍可能更新
    case recommend = "推薦"      // 顯示推薦，需要手動打牌
    case auto = "自動"           // 顯示推薦，自動執行推薦動作

    /// 產品意圖上的顯示旗標；目前 View／WebGL highlighter 尚未讀取它。
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

    // MARK: - Initialization

    init() {
        bridgeLog("\(logTag) 控制器已初始化 (UI 模式)")
    }

    // MARK: - Configuration

    /// 設置 WebPage 引用
    func setWebPage(_ webPage: WebPage?) {
        self.webPage = webPage
        bridgeLog("\(logTag) WebPage 已設定")
    }

    /// 設置自動打牌模式
    func setMode(_ mode: AutoPlayMode) {
        state.mode = mode
        bridgeLog("\(logTag) 模式設定為: \(mode.rawValue)")

        if mode == .off {
            cancelPendingAction()
        }
    }

    /// 設置動作延遲
    func setActionDelay(_ delay: TimeInterval) {
        state.actionDelay = max(0.5, min(5.0, delay))
    }

    // MARK: - Game State Updates

    /// 通知輪到自己的回合
    func notifyMyTurn(canDiscard: Bool, canRiichi: Bool, canChi: Bool, canPon: Bool, canKan: Bool, canAgari: Bool) {
        state.isMyTurn = true
        bridgeLog("\(logTag) 我的回合 - 可打牌=\(canDiscard), 可立直=\(canRiichi), 可吃=\(canChi), 可碰=\(canPon), 可槓=\(canKan), 可和=\(canAgari)")
    }

    /// 通知回合結束
    func notifyTurnEnd() {
        state.isMyTurn = false
        cancelPendingAction()
    }

    // MARK: - Action Execution

    /// 取消待處理動作
    func cancelPendingAction() {
        actionTimer?.invalidate()
        actionTimer = nil
        state.pendingAction = nil
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
