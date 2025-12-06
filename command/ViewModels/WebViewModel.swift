//
//  WebViewModel.swift
//  Naki - 雀魂麻將 AI 助手
//
//  Created by Suoie on 2025/11/29.
//
//  核心視圖模型（協調器），負責：
//  - 協調各服務 (AutoPlayService, MCPServer, GameStateManager)
//  - Bot 控制 (NativeBotController + MortalSwift)
//  - WebPage 整合 (JavaScript Bridge) - 使用 macOS 26.0+ WebPage API
//
//  更新日誌:
//  - 2025/11/30: 移除 Python 依賴，純 Swift 實現
//  - 2025/12/02: v1.1.2 重構 - 提取重複程式碼，清理未使用變數
//  - 2025/12/03: v1.2.0 服務化重構 - 提取 AutoPlayService, GameStateManager
//  - 2025/12/04: v1.3.0 WebPage API - 使用 macOS 26.0+ 新 API
//

import MortalSwift
import SwiftUI
import WebKit

@Observable
@MainActor
class WebViewModel {
  var statusMessage = ""

  // 連線狀態
  var isConnected = false
  var recommendationCount = 0

  // 遊戲狀態
  var gameState = GameState()
  var botStatus = BotStatus()
  var recommendations: [Recommendation] = []
  var tehaiTiles: [String] = []
  var tsumoTile: String?
  var highlightedTile: String?

  // MARK: - Services

  /// 遊戲狀態管理器（集中管理狀態和推薦）
  private(set) var gameStateManager = GameStateManager()

  /// 自動打牌服務（協調重試機制）
  private var autoPlayService = AutoPlayService()

  // 原生 Bot 控制器 (MortalSwift)
  private var nativeBotController: NativeBotController?

  // 自動打牌控制器（UI 自動化）
  private var autoPlayController: AutoPlayController?

  // MCP Server
  private var debugServer: DebugServer?
  var isDebugServerRunning = false
  var debugServerPort: UInt16 = 8765

  // MARK: - WebPage (macOS 26.0+)

  /// WebPage 實例
  var webPage: WebPage?

  /// Web 協調器（處理 WebSocket 訊息和導覽事件）
  private var webCoordinator: NakiWebCoordinator?

  /// 導覽決策器
  private var navigationDecider: NakiNavigationDecider?

  /// 對話框展示器
  private var dialogPresenter: NakiDialogPresenter?

  // 已棄用 - 保留屬性以相容舊程式碼
  var botEngineMode: String = "native"
  var isProxyRunning: Bool = false

  /// 防止重複觸發自動打牌
  private var lastAutoPlayTriggerTime: Date = .distantPast
  private var lastAutoPlayActionType: Recommendation.ActionType?

  /// 是否已經套用過隱藏名稱設定（防止重複套用）
  private var hasAppliedHideNamesSettings = false

  /// 當前正在執行的動作ID（用於追蹤而非阻擋）
  private var currentExecutionId: UUID?

  /// 上次觸發的動作和時間（防抖動）
  private var lastTriggerKey: String?
  private var lastTriggerTime: Date?

  /// 定期檢查計時器
  private var autoPlayCheckTimer: Timer?

  init() {
    // 初始化協調器和輔助類別
    webCoordinator = NakiWebCoordinator(viewModel: self)
    navigationDecider = NakiNavigationDecider(viewModel: self)
    dialogPresenter = NakiDialogPresenter(viewModel: self)

    // 建立 WebPage 設定
    var configuration = WebPage.Configuration()

    // 設定 userContentController（JavaScript 橋接）
    let userContentController = WKUserContentController()

    // 註冊 JavaScript Bridge 處理器
    if let coordinator = webCoordinator {
      userContentController.add(coordinator.websocketHandler, name: "websocketBridge")
    }

    // 注入所有 JavaScript 模組（WebSocket 攔截、Shimmer 效果等）
    let websocketScript = WebSocketInterceptor.createUserScript()
    userContentController.addUserScript(websocketScript)

    configuration.userContentController = userContentController

    // 啟用 Web Inspector（僅用於開發除錯）
    #if DEBUG
      // WebPage 使用 isInspectable 屬性
      webPage?.isInspectable = true
    #endif

    // 建立 WebPage
    if let decider = navigationDecider, let presenter = dialogPresenter {
      webPage = WebPage(
        configuration: configuration,
        navigationDecider: decider,
        dialogPresenter: presenter
      )
    } else {
      webPage = WebPage(configuration: configuration)
    }

    // 啟用 Inspector
    #if DEBUG
      webPage?.isInspectable = true
    #endif

    // 初始化原生 Bot 控制器
    nativeBotController = NativeBotController()

    // 初始化自動打牌控制器
    autoPlayController = AutoPlayController()

    // 設定 AutoPlayService 委託
    autoPlayService.delegate = self
    autoPlayService.setWebPage(webPage)

    // 設定 AutoPlayController 的 WebPage
    autoPlayController?.setWebPage(webPage)

    // 自動啟動 MCP Server
    startDebugServer()

    // 自動設定全自動打牌模式
    autoPlayController?.setMode(.auto)

    // 啟動定期檢查計時器（每 2 秒檢查一次）
    startAutoPlayCheckTimer()

    // 監聽導航事件
    observeNavigations()

    statusMessage = "準備就緒 (全自動模式)"
  }

  /// 監聽導航事件
  private func observeNavigations() {
    guard let page = webPage else { return }

    Task {
      do {
        for try await event in page.navigations {
          switch event {
          case .startedProvisionalNavigation:
            webCoordinator?.handleNavigationStarted()
            statusMessage = "正在加載雀魂..."
            // 重置隱藏名稱設定狀態，以便重新套用
            resetHideNamesSettings()

          case .committed:
            statusMessage = "雀魂已加載，等待連接..."

          case .finished:
            print("[WebView] Page loaded successfully")

          case .receivedServerRedirect:
            break
          }
        }
      } catch {
        print("[WebView] Navigation error: \(error)")
        statusMessage = "加載失敗: \(error.localizedDescription)"
      }
    }
  }

  /// 啟動定期檢查計時器
  private func startAutoPlayCheckTimer() {
    autoPlayCheckTimer?.invalidate()
    autoPlayCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) {
      [weak self] _ in
      Task { @MainActor in
        self?.checkAndRetriggerAutoPlay()
      }
    }
  }

  /// 定期檢查：如果有推薦且沒有正在執行的動作，重新觸發
  private func checkAndRetriggerAutoPlay() {
    guard let page = webPage else { return }

    // 自動套用隱藏名稱設定（僅在遊戲可用時套用一次）
    applyHideNamesSettingsIfNeeded()

    // 檢查並更新高亮效果（如果有推薦但沒有顯示效果）
    checkAndUpdateHighlights()

    // 自動打牌檢查
    guard autoPlayController?.state.mode == .auto,
      !recommendations.isEmpty,
      currentExecutionId == nil
    else { return }

    // 檢查遊戲是否有可用操作
    let checkScript = """
      var dm = window.view.DesktopMgr.Inst;
      if (!dm || !dm.oplist || dm.oplist.length === 0) return false;
      return true;
      """

    Task {
      do {
        let result = try await page.callJavaScript(checkScript)
        if let hasOp = result as? Bool, hasOp {
          debugServer?.addLog("⏰ Timer: retrigger auto-play")
          triggerAutoPlayNow(delay: 0.1)
        }
      } catch {
        // 忽略錯誤
      }
    }
  }

  /// 檢查並更新推薦顯示
  private func checkAndUpdateHighlights() {
    // 只在顯示推薦模式下檢查（推薦/自動模式）
    guard autoPlayController?.state.mode.showRecommendation == true,
      !recommendations.isEmpty,
      let page = webPage,
      let controller = nativeBotController
    else { return }

    // 檢查是否有活躍的效果
    let checkScript = "window.__nakiRecommendHighlight?.activeEffects?.length || 0"

    Task {
      do {
        let result = try await page.callJavaScript(checkScript)
        if let effectCount = result as? Int, effectCount == 0 {
          debugServer?.addLog("⏰ Timer: refresh highlights")
          await showGameHighlightForRecommendations(recommendations, controller: controller)
        }
      } catch {
        // 忽略錯誤
      }
    }
  }

  // MARK: - Native Bot Methods

  /// 使用原生 MortalSwift 建立 Bot
  func createNativeBot(playerId: Int, is3P: Bool = false) async throws {
    guard let controller = nativeBotController else {
      throw NativeBotError.botNotInitialized
    }

    try controller.createBot(playerId: UInt8(playerId), is3P: is3P)
    botStatus = controller.botState
    statusMessage = "Bot 已建立 (Player \(playerId))"
  }

  /// 處理單一 MJAI 事件
  func processNativeEvent(_ event: [String: Any]) async throws -> [String: Any]? {
    guard let controller = nativeBotController else {
      throw NativeBotError.botNotInitialized
    }
    let response = try await controller.react(event: event)
    updateUIAfterBotResponse(from: controller)
    return response
  }

  /// 批次處理多個 MJAI 事件
  func processNativeEvents(_ events: [[String: Any]]) async throws -> [String: Any]? {
    guard let controller = nativeBotController else {
      throw NativeBotError.botNotInitialized
    }
    let response = try await controller.react(events: events)
    updateUIAfterBotResponse(from: controller)
    return response
  }

  /// 重新同步 Bot（手動重建或重連時使用）
  /// 會使用 EventStream 重放歷史事件，讓新 Bot 恢復到當前遊戲狀態
  func resyncBot() async {
    guard let coordinator = webCoordinator else {
      bridgeLog("[WebViewModel] Cannot resync: coordinator not available")
      statusMessage = "無法重建：協調器不可用"
      return
    }

    if !coordinator.eventStream.canResync() {
      bridgeLog("[WebViewModel] Cannot resync: no game in progress")
      statusMessage = "無法重建：沒有進行中的遊戲"
      return
    }

    await coordinator.resyncBot()
  }

  /// 強制 WebSocket 重連以重建 Bot 狀態
  /// 這會關閉所有雀魂 WebSocket 連接，觸發遊戲重連
  /// 伺服器會發送 authGame + syncGame 回應，從而完整重建 Bot
  func forceReconnect() async {
    guard let page = webPage else {
      bridgeLog("[WebViewModel] Cannot force reconnect: no webPage")
      statusMessage = "無法重連：WebView 不可用"
      return
    }

    bridgeLog("[WebViewModel] Force reconnecting WebSocket...")
    statusMessage = "正在強制重連..."

    let script = "window.__nakiWebSocket?.forceReconnect() || 0"
    do {
      let result = try await page.callJavaScript(script)
      let closedCount = (result as? Int) ?? 0
      bridgeLog("[WebViewModel] Force reconnect: closed \(closedCount) connections")
      statusMessage = closedCount > 0 ? "已關閉 \(closedCount) 個連接，等待重連..." : "沒有活躍的連接"
    } catch {
      bridgeLog("[WebViewModel] Force reconnect error: \(error)")
      statusMessage = "重連失敗：\(error.localizedDescription)"
    }
  }

  /// 從 Bot 控制器更新 UI 狀態並觸發自動打牌
  private func updateUIAfterBotResponse(from controller: NativeBotController) {
    bridgeLog("[WebViewModel] ===== updateUIAfterBotResponse CALLED =====")

    // 更新遊戲狀態
    gameState = controller.gameState
    botStatus = controller.botState
    tehaiTiles = controller.tehaiMjai
    tsumoTile = controller.lastTsumo
    recommendations = controller.lastRecommendations
    recommendationCount = recommendations.count

    bridgeLog("[WebViewModel] Updated recommendations: \(recommendations.count)")

    // 同步到 GameStateManager（供 UI 回應式更新）
    gameStateManager.syncFrom(controller: controller)

    // 更新推薦顯示（根據模式決定是否顯示）
    let shouldShowRecommendation = autoPlayController?.state.mode.showRecommendation ?? false

    if let firstRec = recommendations.first {
      highlightedTile = firstRec.displayTile

      // 在遊戲 UI 上顯示推薦（只在推薦/自動模式下顯示）
      if shouldShowRecommendation {
        Task {
          await showGameHighlightForRecommendations(recommendations, controller: controller)
        }
      } else {
        // 關閉模式：隱藏推薦
        Task {
          await hideGameHighlight()
        }
      }
    } else {
      // 沒有推薦時隱藏
      Task {
        await hideGameHighlight()
      }
    }

    // 觸發自動打牌
    triggerAutoPlayIfNeeded()
  }

  /// 在遊戲 UI 上顯示多個推薦的原生高亮效果
  /// 根據機率顯示不同顏色：> 0.5 綠色，0.2~0.5 紅色，< 0.2 不顯示
  private func showGameHighlightForRecommendations(
    _ recommendations: [Recommendation], controller: NativeBotController
  ) async {
    guard let page = webPage else { return }

    // 檢查第一個推薦是否為按鈕動作（非打牌）
    // 按鈕動作類型：chi/pon/kan/hora/riichi/none(pass)
    let buttonActionMap: [Recommendation.ActionType: String] = [
      .chi: "chi",
      .pon: "pon",
      .kan: "kan",
      .hora: "hora",
      .riichi: "riichi",
      .none: "pass",
    ]

    if let firstRec = recommendations.first,
      buttonActionMap[firstRec.actionType] != nil,
      firstRec.probability > 0.2
    {
      let actionMap = buttonActionMap
      if let jsAction = actionMap[firstRec.actionType] {
        let script = "window.__nakiRecommendHighlight?.moveNativeEffectToButton('\(jsAction)')"
        do {
          _ = try await page.callJavaScript(script)
          bridgeLog("[WebViewModel] Highlighted button: \(jsAction)")
        } catch {
          bridgeLog("[WebViewModel] Error highlighting button: \(error.localizedDescription)")
        }
        return
      }
    }

    // 過濾出有效的打牌推薦（機率 > 0.2）
    let validRecs = recommendations.filter { rec in
      rec.tile != nil && rec.probability > 0.2
    }

    if validRecs.isEmpty {
      await hideGameHighlight()
      return
    }

    // 建構 JavaScript 來查找所有推薦牌的位置
    var tileDataArray: [[String: Any]] = []
    for rec in validRecs {
      guard let tile = rec.tile else { continue }
      tileDataArray.append([
        "mjaiString": tile.mjaiString,
        "probability": rec.probability,
      ])
    }

    // 將資料轉為 JSON
    guard let jsonData = try? JSONSerialization.data(withJSONObject: tileDataArray),
      let jsonString = String(data: jsonData, encoding: .utf8)
    else {
      bridgeLog("[WebViewModel] Failed to serialize recommendations")
      return
    }

    let script = """
      // 先清除現有效果，確保不會有殘留
      window.__nakiRecommendHighlight?.hide();

      var mr = window.view?.DesktopMgr?.Inst?.mainrole;
      if (!mr || !mr.hand) return [];

      var tiles = \(jsonString);
      var results = [];

      // 雀魂的 type 映射：0=筒(p), 1=萬(m), 2=索(s), 3=字牌(z)
      var typeMap = {'m': 1, 'p': 0, 's': 2};
      var honorMap = {'E': [3,1], 'S': [3,2], 'W': [3,3], 'N': [3,4], 'P': [3,5], 'F': [3,6], 'C': [3,7]};

      for (var j = 0; j < tiles.length; j++) {
      var target = tiles[j].mjaiString;
      var probability = tiles[j].probability;

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

      // 在手牌中查找
      for (var i = 0; i < mr.hand.length; i++) {
      var t = mr.hand[i];
      if (t && t.val && t.val.type === tileType && t.val.index === tileValue) {
      // 如果是紅寶牌，檢查 dora 標記
      var match = false;
      if (isRed) {
          match = t.val.dora === true;
      } else {
          match = !t.val.dora;
      }
      if (match) {
          results.push({ tileIndex: i, probability: probability });
          break;
      }
      }
      }
      }

      // 呼叫高亮模組（showMultiple 內部也會 hide，但這裡已經 hide 過了）
      if (results.length > 0) {
      window.__nakiRecommendHighlight?.showMultiple(results);
      }

      return results;
      """

    do {
      let result = try await page.callJavaScript(script)
      if let results = result as? [[String: Any]] {
        bridgeLog("[WebViewModel] Highlighted \(results.count) recommendations")
      }
    } catch {
      bridgeLog("[WebViewModel] Error showing highlights: \(error.localizedDescription)")
    }
  }

  /// 隱藏遊戲 UI 上的高亮效果
  private func hideGameHighlight() async {
    guard let page = webPage else { return }

    let script = "window.__nakiRecommendHighlight?.hide()"
    do {
      _ = try await page.callJavaScript(script)
      bridgeLog("[WebViewModel] Hidden game highlight")
    } catch {
      bridgeLog("[WebViewModel] Error hiding highlight: \(error.localizedDescription)")
    }
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

    // 防抖動：如果同一個動作在短時間內已經觸發過，跳過
    // 但對於 none (pass) 動作，不使用防抖動，因為每次有新的副露機會都需要回應
    let triggerKey = "\(firstAction.rawValue)-\(tileName)"
    let now = Date()
    let isPassAction = firstAction == .none

    if !isPassAction,
      let lastKey = lastTriggerKey,
      let lastTime = lastTriggerTime,
      lastKey == triggerKey,
      now.timeIntervalSince(lastTime) < delay + 0.5
    {
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
    switch actionType {
    case .hora:
      return 1.0
    case .chi, .pon, .kan:
      return 1.5
    case .some(.none):
      return 1.0
    default:
      return 1.8
    }
  }

  /// 刪除原生 Bot
  func deleteNativeBot() {
    nativeBotController?.deleteBot()
    botStatus = BotStatus()
    recommendations = []
    tehaiTiles = []
    tsumoTile = nil
    // 隱藏遊戲 UI 上的高亮
    Task {
      await hideGameHighlight()
    }
    bridgeLog("[WebViewModel] Bot deleted and state cleared")
  }

  // MARK: - Auto Play Methods

  /// 設定自動打牌模式
  func setAutoPlayMode(_ mode: AutoPlayMode) {
    autoPlayController?.setMode(mode)
    bridgeLog("[WebViewModel] Auto-play mode set to: \(mode.rawValue)")
    debugServer?.addLog("Mode changed: \(mode.rawValue), recs: \(recommendations.count)")

    // 根據模式處理推薦顯示
    if mode.showRecommendation {
      // 推薦/自動模式：顯示推薦（如果有）
      if !recommendations.isEmpty, let controller = nativeBotController {
        Task {
          await showGameHighlightForRecommendations(recommendations, controller: controller)
        }
      }
    } else {
      // 關閉模式：隱藏推薦
      Task {
        await hideGameHighlight()
      }
    }

    // 只有全自動模式才觸發自動打牌
    if mode.isFullAuto, !recommendations.isEmpty {
      let firstAction = recommendations.first?.actionType
      let delay: TimeInterval
      switch firstAction {
      case .hora:
        delay = 0
      case .chi, .pon, .kan:
        delay = 1.5
      case .some(.none):
        delay = 1.2
      default:
        delay = 1.8
      }
      debugServer?.addLog(
        "Auto-triggering on mode change: \(firstAction?.rawValue ?? "?") (delay: \(delay)s)")
      triggerAutoPlayNow(delay: delay)
    }
  }

  /// 設定自動打牌延遲
  func setAutoPlayDelay(_ delay: TimeInterval) {
    autoPlayController?.setActionDelay(delay)
  }

  /// 設定高亮效果選項
  func setHighlightSettings(showRotatingEffect: Bool) {
    guard let page = webPage else { return }

    let script = """
      window.__nakiRecommendHighlight?.setSettings({
      showRotatingEffect: \(showRotatingEffect)
      });
      """

    Task {
      do {
        _ = try await page.callJavaScript(script)
        bridgeLog("[WebViewModel] Highlight settings: rotating=\(showRotatingEffect)")
      } catch {
        bridgeLog("[WebViewModel] Error setting highlight: \(error.localizedDescription)")
      }
    }
  }

  /// 設定是否隱藏玩家名稱
  func setHidePlayerNames(_ hide: Bool) {
    guard let page = webPage else { return }

    let script = "window.__nakiPlayerNames?.setHidden(\(hide))"

    Task {
      do {
        let result = try await page.callJavaScript(script)
        bridgeLog(
          "[WebViewModel] Hide player names: \(hide), result: \(String(describing: result))")
      } catch {
        bridgeLog("[WebViewModel] Error setting hide names: \(error.localizedDescription)")
      }
    }
  }

  /// 獲取玩家名稱隱藏狀態
  func getPlayerNamesStatus() async -> [String: Any]? {
    guard let page = webPage else { return nil }

    let script = "JSON.stringify(window.__nakiPlayerNames?.getStatus() || {})"

    do {
      let result = try await page.callJavaScript(script)
      if let jsonString = result as? String,
        let data = jsonString.data(using: .utf8),
        let status = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      {
        return status
      }
    } catch {
      bridgeLog("[WebViewModel] Error getting names status: \(error.localizedDescription)")
    }
    return nil
  }

  /// 自動套用隱藏名稱設定（在遊戲可用時套用）
  private func applyHideNamesSettingsIfNeeded() {
    guard !hasAppliedHideNamesSettings else { return }
    guard let page = webPage else { return }

    // 檢查用戶設定
    let shouldHide = UserDefaults.standard.bool(forKey: "hidePlayerNames")
    guard shouldHide else {
      // 如果用戶不想隱藏，標記為已處理，不需要再檢查
      hasAppliedHideNamesSettings = true
      return
    }

    // 檢查遊戲 API 是否可用
    let checkScript =
      "window.__nakiPlayerNames && window.uiscript?.UI_DesktopInfo?.Inst ? true : false"

    Task {
      do {
        let result = try await page.callJavaScript(checkScript)
        if let isAvailable = result as? Bool, isAvailable {
          // API 可用，套用設定
          setHidePlayerNames(true)
          hasAppliedHideNamesSettings = true
          bridgeLog("[WebViewModel] Auto-applied hide player names setting")
        }
      } catch {
        // 忽略錯誤，下次定期檢查時會再嘗試
      }
    }
  }

  /// 重置隱藏名稱設定狀態（頁面重新載入時調用）
  func resetHideNamesSettings() {
    hasAppliedHideNamesSettings = false
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
  func triggerAutoPlayNow(delay: TimeInterval = 1.2) {
    guard let page = webPage,
      let firstRec = recommendations.first
    else {
      bridgeLog("[WebViewModel] Cannot trigger: no WebPage or recommendations")
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

      // 所有動作都使用重試機制
      Task {
        await self.executeAutoPlayActionWithRetry(
          page: page, actionType: actionType, tileName: tileName, attempt: 1,
          executionId: executionId)
      }
    }
  }

  /// 最大重試次數
  private let maxRetryAttempts = 50

  /// 帶重試的自動打牌執行
  private func executeAutoPlayActionWithRetry(
    page: WebPage, actionType: Recommendation.ActionType, tileName: String, attempt: Int,
    executionId: UUID
  ) async {

    // 檢查是否被新的觸發取代
    if currentExecutionId != executionId {
      debugServer?.addLog("⏭️ Retry cancelled: superseded (attempt \(attempt))")
      return
    }

    // 先檢查是否還有操作可執行
    let checkScript = """
      var dm = window.view.DesktopMgr.Inst;
      if (!dm) return JSON.stringify({hasOp: false, reason: 'no dm'});
      if (!dm.oplist || dm.oplist.length === 0) return JSON.stringify({hasOp: false, reason: 'no oplist'});

      var opTypes = dm.oplist.map(function(o) { return o.type; });
      return JSON.stringify({hasOp: true, opTypes: opTypes, count: dm.oplist.length});
      """

    do {
      let result = try await page.callJavaScript(checkScript)

      // 再次檢查是否被取代
      if currentExecutionId != executionId {
        debugServer?.addLog("⏭️ Retry cancelled after JS: superseded")
        return
      }

      // 解析 JSON 字符串
      if let jsonString = result as? String,
        let jsonData = jsonString.data(using: .utf8),
        let dict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
        let hasOp = dict["hasOp"] as? Bool
      {

        if !hasOp {
          let reason = dict["reason"] as? String ?? "unknown"

          // 打牌 (discard) 不需要等待 oplist，直接執行
          if actionType == .discard {
            debugServer?.addLog("Discard: no oplist, exec directly")
            await executeAutoPlayAction(page: page, actionType: actionType, tileName: tileName)
            try? await Task.sleep(nanoseconds: 300_000_000)  // 0.3s
            debugServer?.addLog("✅ Discard sent")
            currentExecutionId = nil
            return
          }

          // 其他動作需要等待 oplist
          if attempt < maxRetryAttempts {
            if attempt == 1 || attempt % 10 == 0 {
              debugServer?.addLog("Wait oplist \(attempt)/\(maxRetryAttempts) (\(reason))")
            }
            try? await Task.sleep(nanoseconds: 100_000_000)  // 0.1s
            await executeAutoPlayActionWithRetry(
              page: page, actionType: actionType, tileName: tileName, attempt: attempt + 1,
              executionId: executionId)
          } else {
            if actionType == .none {
              debugServer?.addLog("✅ Pass: no oplist after \(attempt) attempts, no opportunity")
            } else {
              debugServer?.addLog("❌ No oplist after \(attempt) attempts, giving up")
            }
            currentExecutionId = nil
          }
          return
        }

        // 有操作，執行動作
        let opInfo = dict["opTypes"] as? [Int] ?? []
        debugServer?.addLog("Attempt \(attempt): ops=\(opInfo)")

        await executeAutoPlayAction(page: page, actionType: actionType, tileName: tileName)

        // pass 操作：較長間隔 (0.5s)，最多重試 5 次
        if actionType == .none {
          let maxPassRetries = 5
          if attempt >= maxPassRetries {
            debugServer?.addLog("✅ Pass sent (\(attempt) attempts)")
            return
          }
          try? await Task.sleep(nanoseconds: 500_000_000)  // 0.5s
          await checkAndRetryIfNeeded(
            page: page, actionType: actionType, tileName: tileName, attempt: attempt,
            executionId: executionId)
          return
        }

        // 其他操作：0.1 秒後檢查是否成功
        try? await Task.sleep(nanoseconds: 100_000_000)
        await checkAndRetryIfNeeded(
          page: page, actionType: actionType, tileName: tileName, attempt: attempt,
          executionId: executionId)
      } else {
        // 無法解析，直接執行一次
        debugServer?.addLog("Attempt \(attempt): check failed, exec anyway")
        await executeAutoPlayAction(page: page, actionType: actionType, tileName: tileName)
      }
    } catch {
      debugServer?.addLog("JS error: \(error.localizedDescription)")
    }
  }

  /// 檢查動作是否成功，失敗則重試
  private func checkAndRetryIfNeeded(
    page: WebPage, actionType: Recommendation.ActionType, tileName: String, attempt: Int,
    executionId: UUID
  ) async {

    // 檢查是否被新的觸發取代
    if currentExecutionId != executionId {
      debugServer?.addLog("⏭️ Check cancelled: superseded")
      return
    }

    let checkScript = """
      var dm = window.view.DesktopMgr.Inst;
      if (!dm) return JSON.stringify({success: true, reason: 'no dm'});

      var actionType = '\(actionType.rawValue)';
      var tileName = '\(tileName)';

      if (dm.oplist && dm.oplist.length > 0) {
      var opTypes = dm.oplist.map(function(o) { return o.type; });

      if (actionType === 'discard') {
      if (opTypes.indexOf(1) >= 0) {
      return JSON.stringify({success: false, reason: 'discard op still present', opTypes: opTypes});
      }
      } else if (actionType === 'chi') {
      if (opTypes.indexOf(2) >= 0) {
      return JSON.stringify({success: false, reason: 'chi op still present', opTypes: opTypes});
      }
      } else if (actionType === 'pon') {
      if (opTypes.indexOf(3) >= 0) {
      return JSON.stringify({success: false, reason: 'pon op still present', opTypes: opTypes});
      }
      } else if (actionType === 'kan') {
      if (opTypes.indexOf(4) >= 0 || opTypes.indexOf(5) >= 0 || opTypes.indexOf(6) >= 0) {
      return JSON.stringify({success: false, reason: 'kan op still present', opTypes: opTypes});
      }
      } else if (actionType === 'hora') {
      if (opTypes.indexOf(8) >= 0 || opTypes.indexOf(9) >= 0) {
      return JSON.stringify({success: false, reason: 'hora op still present', opTypes: opTypes});
      }
      } else if (actionType === 'none') {
      var hasCallOp = false;
      for (var i = 0; i < opTypes.length; i++) {
      if (opTypes[i] >= 2 && opTypes[i] <= 9) { hasCallOp = true; break; }
      }
      if (hasCallOp) {
      return JSON.stringify({success: false, reason: 'call ops still present', opTypes: opTypes});
      }
      }
      }

      return JSON.stringify({success: true, reason: 'oplist cleared or action done'});
      """

    do {
      let result = try await page.callJavaScript(checkScript)

      // 解析 JSON 字符串
      if let jsonString = result as? String,
        let jsonData = jsonString.data(using: .utf8),
        let dict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
        let success = dict["success"] as? Bool
      {

        if success {
          let reason = dict["reason"] as? String ?? "ok"
          debugServer?.addLog("✅ Action success after \(attempt) attempts (\(reason))")
          currentExecutionId = nil
          return
        }

        // 失敗，需要重試
        let opInfo = dict["opTypes"] as? [Int] ?? []

        if attempt >= maxRetryAttempts {
          debugServer?.addLog("❌ Max retries reached (\(attempt)), ops=\(opInfo)")
          currentExecutionId = nil
          return
        }

        // 重試
        debugServer?.addLog("Retry \(attempt + 1): ops still present \(opInfo)")
        await executeAutoPlayActionWithRetry(
          page: page, actionType: actionType, tileName: tileName, attempt: attempt + 1,
          executionId: executionId)
      }
    } catch {
      debugServer?.addLog("Check error: \(error.localizedDescription)")
    }
  }

  /// 實際執行自動打牌動作
  private func executeAutoPlayAction(
    page: WebPage, actionType: Recommendation.ActionType, tileName: String
  ) async {

    switch actionType {
    case .riichi:
      debugServer?.addLog("Exec: riichi...")
      let script = """
        var dm = window.view.DesktopMgr.Inst;
        if (!dm || !dm.oplist) return JSON.stringify({success: false, error: 'no oplist'});

        var riichiOp = null;
        for (var i = 0; i < dm.oplist.length; i++) {
        if (dm.oplist[i].type === 7) { riichiOp = dm.oplist[i]; break; }
        }
        if (!riichiOp) return JSON.stringify({success: false, error: 'no riichi op'});

        if (window.app && window.app.NetAgent) {
        var combination = riichiOp.combination || [];
        var tileToDiscard = combination.length > 0 ? combination[0] : null;

        window.app.NetAgent.sendReq2MJ('FastTest', 'inputOperation', {
        type: 7,
        tile: tileToDiscard,
        timeuse: 1
        });
        return JSON.stringify({success: true, tile: tileToDiscard, combinations: combination});
        }
        return JSON.stringify({success: false, error: 'no NetAgent'});
        """
      do {
        let result = try await page.callJavaScript(script)
        if let jsonString = result as? String {
          debugServer?.addLog("riichi result: \(jsonString)")
        }
      } catch {
        debugServer?.addLog("riichi error: \(error.localizedDescription)")
      }

    case .discard:
      // WebPage.callJavaScript 的 functionBody 需要 return 語句
      let findScript = """
        var mr = window.view.DesktopMgr.Inst.mainrole;
        if (!mr || !mr.hand) return JSON.stringify({index: -1, debug: 'no mainrole'});

        var target = '\(tileName)';

        var handInfo = [];
        for (var i = 0; i < mr.hand.length; i++) {
        var t = mr.hand[i];
        if (t && t.val) {
        handInfo.push('i' + i + ':t' + t.val.type + 'v' + t.val.index + (t.val.dora ? 'r' : ''));
        }
        }

        var typeMap = {'m': 1, 'p': 0, 's': 2};
        var honorMap = {'E': [3,1], 'S': [3,2], 'W': [3,3], 'N': [3,4], 'P': [3,5], 'F': [3,6], 'C': [3,7]};

        var tileType, tileValue, isRed = false;

        if (honorMap[target]) {
        tileType = honorMap[target][0];
        tileValue = honorMap[target][1];
        } else {
        tileValue = parseInt(target[0]);
        var suitChar = target[1];
        tileType = typeMap[suitChar];
        isRed = target.length > 2 && target[2] === 'r';
        }

        var debugInfo = 'want:' + target + '(t' + tileType + 'v' + tileValue + ') hand:[' + handInfo.join(',') + ']';

        for (var i = 0; i < mr.hand.length; i++) {
        var t = mr.hand[i];
        if (t && t.val && t.val.type === tileType && t.val.index === tileValue) {
        if (isRed) {
            if (t.val.dora) return JSON.stringify({index: i, debug: debugInfo + ' =>found red@' + i});
        } else {
            if (!t.val.dora) return JSON.stringify({index: i, debug: debugInfo + ' =>found@' + i});
        }
        }
        }

        for (var i = 0; i < mr.hand.length; i++) {
        var t = mr.hand[i];
        if (t && t.val && t.val.type === tileType && t.val.index === tileValue) {
        return JSON.stringify({index: i, debug: debugInfo + ' =>found(any)@' + i});
        }
        }

        if (mr.drewPai && mr.drewPai.val) {
        var t = mr.drewPai;
        debugInfo += ' tsumo:t' + t.val.type + 'v' + t.val.index;
        if (t.val.type === tileType && t.val.index === tileValue) {
        return JSON.stringify({index: mr.hand.length, debug: debugInfo + ' =>tsumo'});
        }
        }

        return JSON.stringify({index: -1, debug: debugInfo + ' =>NOT_FOUND'});
        """
      do {
        let result = try await page.callJavaScript(findScript)
        // 解析 JSON 字符串
        if let jsonString = result as? String,
          let jsonData = jsonString.data(using: .utf8),
          let dict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
          let tileIndex = dict["index"] as? Int,
          let debug = dict["debug"] as? String
        {
          debugServer?.addLog("Find: \(debug)")

          if tileIndex >= 0 {
            let discardScript =
              "window.__nakiGameAPI.smartExecute('discard', {tileIndex: \(tileIndex)})"
            do {
              _ = try await page.callJavaScript(discardScript)
              debugServer?.addLog("discard idx=\(tileIndex) OK")
            } catch {
              debugServer?.addLog("discard error: \(error.localizedDescription)")
            }
          } else {
            debugServer?.addLog("Tile not found, skipping")
          }
        } else {
          debugServer?.addLog("Find result parse failed: \(String(describing: result))")
        }
      } catch {
        debugServer?.addLog("Find error: \(error.localizedDescription)")
      }

    case .chi:
      var chiType = 0
      if tileName.hasPrefix("chi_"), let idx = Int(String(tileName.dropFirst(4))) {
        chiType = idx
      }

      let queryScript = """
        var dm = window.view.DesktopMgr.Inst;
        if (!dm || !dm.oplist) return JSON.stringify({available: false, error: 'no oplist'});

        var chiOp = null;
        for (var i = 0; i < dm.oplist.length; i++) {
        if (dm.oplist[i].type === 2) { chiOp = dm.oplist[i]; break; }
        }
        if (!chiOp) return JSON.stringify({available: false, error: 'no chi op'});

        var combinations = chiOp.combination || [];

        var targetPai = null;
        if (dm.lastpai && dm.lastpai.val) {
        targetPai = {type: dm.lastpai.val.type, index: dm.lastpai.val.index};
        }

        return JSON.stringify({
        available: true,
        combinations: combinations,
        count: combinations.length,
        targetPai: targetPai
        });
        """

      do {
        let result = try await page.callJavaScript(queryScript)
        guard let jsonString = result as? String,
          let jsonData = jsonString.data(using: .utf8),
          let dict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
          let available = dict["available"] as? Bool, available,
          let combinations = dict["combinations"] as? [String]
        else {
          debugServer?.addLog("Chi: no combinations available")
          return
        }

        let combIndex: Int
        if combinations.count == 1 {
          combIndex = 0
        } else {
          combIndex = max(0, combinations.count - 1 - chiType)
        }
        let combInfo = combinations.isEmpty ? "" : " [\(combinations.joined(separator: ", "))]"
        debugServer?.addLog("Chi: mortal=chi_\(chiType) → gameIdx=\(combIndex)\(combInfo)")

        let chiScript = "window.__nakiGameAPI.smartExecute('chi', {chiIndex: \(combIndex)})"
        do {
          let chiResult = try await page.callJavaScript(chiScript)
          debugServer?.addLog("chi result: \(String(describing: chiResult))")
        } catch {
          debugServer?.addLog("chi error: \(error.localizedDescription)")
        }
      } catch {
        debugServer?.addLog("Chi query error: \(error.localizedDescription)")
      }

    case .pon, .kan, .hora:
      let action = actionType.rawValue
      debugServer?.addLog("Exec: \(action)...")
      let script = "window.__nakiGameAPI.smartExecute('\(action)', {})"
      do {
        let result = try await page.callJavaScript(script)
        debugServer?.addLog("\(action) result: \(String(describing: result))")
      } catch {
        debugServer?.addLog("\(action) error: \(error.localizedDescription)")
      }

    case .none:
      debugServer?.addLog("Exec: pass...")
      let script = "window.__nakiGameAPI.smartExecute('pass', {})"
      do {
        let result = try await page.callJavaScript(script)
        if let resultNum = result as? Int, resultNum > 0 {
          debugServer?.addLog("pass OK")
        } else {
          debugServer?.addLog("pass result: \(String(describing: result))")
        }
      } catch {
        debugServer?.addLog("pass error: \(error.localizedDescription)")
      }

    case .unknown:
      bridgeLog("[WebViewModel] Unknown action type, skipping")
    }
  }

  // MARK: - MCP Server

  /// 啟動 MCP Server
  func startDebugServer() {
    guard debugServer == nil else {
      statusMessage = "MCP Server 已在運行"
      return
    }

    debugServer = DebugServer(port: debugServerPort)

    // 設定 JavaScript 執行回調
    // ⚠️ 重要：WebPage.callJavaScript(functionBody:) 期望的是「函數體」
    // 必須使用 return 語句才能獲取返回值，例如：
    //   ❌ "1+1"              → 返回 null
    //   ✅ "return 1+1"       → 返回 2
    //   ❌ "document.title"   → 返回 null
    //   ✅ "return document.title" → 返回 "雀魂麻将"
    // 返回 Object 時使用 JSON.stringify()，Swift 端用 JSONSerialization 解析
    debugServer?.executeJavaScript = { [weak self] script, completion in
      guard let page = self?.webPage else {
        completion(
          nil,
          NSError(
            domain: "Naki", code: -1, userInfo: [NSLocalizedDescriptionKey: "WebPage not available"]
          ))
        return
      }

      Task { @MainActor in
        do {
          let result = try await page.callJavaScript(script)
          print("[JS Debug] Script: \(script.prefix(50))...")
          print("[JS Debug] Result type: \(type(of: result)), value: \(String(describing: result))")
          completion(result, nil)
        } catch {
          print("[JS Debug] Error: \(error)")
          completion(nil, error)
        }
      }
    }

    // 設定日誌回調
    debugServer?.onLog = { [weak self] message in
      bridgeLog(message)
      Task { @MainActor in
        self?.statusMessage = message
      }
    }

    // 設定 Bot 狀態回調
    debugServer?.getBotStatus = { [weak self] in
      guard let self = self else { return [:] }

      let recs: [[String: Any]] = self.gameStateManager.recommendations.map { rec in
        return [
          "tile": rec.displayTile,
          "action": rec.actionType.rawValue,
          "label": rec.displayLabel,
          "prob": rec.probability,
          "percentage": rec.percentageString,
        ]
      }

      let result: [String: Any] = [
        "botStatus": [
          "isActive": self.gameStateManager.botStatus.isActive,
          "playerId": self.gameStateManager.botStatus.playerId,
        ],
        "gameState": [
          "bakaze": self.gameStateManager.gameState.bakazeDisplay,
          "kyoku": self.gameStateManager.gameState.kyoku,
          "honba": self.gameStateManager.gameState.honba,
        ],
        "autoPlay": [
          "mode": self.autoPlayController?.state.mode.rawValue ?? "unknown",
          "isMyTurn": self.autoPlayController?.state.isMyTurn ?? false,
          "hasPendingAction": self.autoPlayController?.state.pendingAction != nil,
        ],
        "recommendations": recs,
        "tehaiCount": self.tehaiTiles.count,
        "tsumoTile": self.tsumoTile ?? NSNull(),
      ]

      return result
    }

    // 設定手動觸發自動打牌回調
    debugServer?.triggerAutoPlay = { [weak self] in
      guard let self = self else { return }

      if let controller = self.nativeBotController,
        let lastAction = controller.lastAction
      {
        self.debugServer?.addLog("Triggering with lastAction")
        self.autoPlayController?.handleRecommendedAction(
          lastAction,
          tehai: controller.tehai,
          tsumo: controller.tsumo
        )
      } else {
        self.triggerAutoPlayNow()
      }
    }

    // 端口變更回調
    debugServer?.onPortChanged = { [weak self] newPort in
      Task { @MainActor in
        self?.debugServerPort = newPort
        self?.isDebugServerRunning = true
        self?.statusMessage = "MCP Server 已啟動: http://localhost:\(newPort)"
      }
    }

    debugServer?.start()
  }

  /// 停止 MCP Server
  func stopDebugServer() {
    debugServer?.stop()
    debugServer = nil
    isDebugServerRunning = false
    statusMessage = "MCP Server 已停止"
  }

  /// 切換 MCP Server
  func toggleDebugServer() {
    if isDebugServerRunning {
      stopDebugServer()
    } else {
      startDebugServer()
    }
  }

  // MARK: - Load URL

  /// 加載雀魂麻將
  func loadMajsoul() async {
    guard let page = webPage else { return }

    if let url = URL(string: "https://game.maj-soul.com/1/") {
      page.load(url)
      statusMessage = "正在加載雀魂麻將..."
    }
  }

  /// 加載指定 URL
  func loadURL(_ urlString: String) async {
    guard let page = webPage else { return }

    if let url = URL(string: urlString) {
      page.load(url)
      statusMessage = "正在加載 \(urlString)"
    }
  }

  // MARK: - Call JavaScript

  func callJS(function: String, params: [String: Any]) async {
    guard let page = webPage else {
      print("WebPage not ready")
      return
    }

    do {
      let jsonData = try JSONSerialization.data(withJSONObject: params)
      let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"

      let script = "\(function)(\(jsonString));"

      _ = try await page.callJavaScript(script)
    } catch {
      print("JavaScript Error: \(error.localizedDescription)")
    }
  }

  // MARK: - Deprecated Methods

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

// MARK: - AutoPlayServiceDelegate

extension WebViewModel: AutoPlayServiceDelegate {
  func autoPlayService(_ service: AutoPlayService, didLog message: String) {
    debugServer?.addLog(message)
  }

  func autoPlayService(
    _ service: AutoPlayService, didComplete actionType: Recommendation.ActionType
  ) {
    bridgeLog("[WebViewModel] AutoPlayService completed: \(actionType.rawValue)")
    statusMessage = "動作完成: \(actionType.displayName)"
    Task {
      await hideGameHighlight()
    }
  }

  func autoPlayService(
    _ service: AutoPlayService, didFail actionType: Recommendation.ActionType, error: String
  ) {
    bridgeLog("[WebViewModel] AutoPlayService failed: \(actionType.rawValue) - \(error)")
    statusMessage = "動作失敗: \(error)"
    Task {
      await hideGameHighlight()
    }
  }
}

// MARK: - Environment Key

/// WebViewModel 的 Environment Key
struct WebViewModelKey: EnvironmentKey {
  static let defaultValue: WebViewModel? = nil
}

extension EnvironmentValues {
  var webViewModel: WebViewModel? {
    get { self[WebViewModelKey.self] }
    set { self[WebViewModelKey.self] = newValue }
  }
}
