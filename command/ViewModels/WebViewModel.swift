//
//  WebViewModel.swift
//  Naki - 雀魂麻將 AI 助手
//
//  Created by Suoie on 2025/11/29.
//
//  核心視圖模型（協調器），負責：
//  - 協調各服務 (MCPServer, GameStateManager, NativeBotController)
//  - Bot 控制 (NativeBotController + MortalSwift)
//  - WebPage 整合 (JavaScript Bridge) - 使用 macOS 26.0+ WebPage API
//
//  更新日誌:
//  - 2025/11/30: 移除 Python 依賴，純 Swift 實現
//  - 2025/12/02: v1.1.2 重構 - 提取重複程式碼，清理未使用變數
//  - 2025/12/03: v1.2.0 服務化重構 - 提取 GameStateManager（AutoPlayService 已移除，自動打牌邏輯內建於本檔）
//  - 2025/12/04: v1.3.0 WebPage API - 使用 macOS 26.0+ 新 API
//

import MortalSwift
import SwiftUI
import WebKit

/// 這條 path 整個建立在 `WebPage` 上（macOS 26 / iOS 26 才有的 API），所以型別本身就標
/// 26+。macOS deployment target 是 26，標不標對 macOS 沒差；但 iOS target 是 17，
/// 不標的話 `Naki-M` 連編譯都過不了。唯一的建立點是 `WebViewModelFactory.create()`
/// 的 `#available` 分支。
@available(macOS 26.0, iOS 26.0, *)
@Observable
@MainActor
class WebViewModel: WebViewModelProtocol {
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

  // 原生 Bot 控制器 (MortalSwift)
  private var nativeBotController: NativeBotController?

  /// 自動打牌模式（唯一有人讀的自動打牌設定；持久化見 `AutoPlayModeStore`）
  private(set) var autoPlayMode: AutoPlayMode = AutoPlayModeStore.defaultMode

  /// Liqi 動作／大廳請求送出器（Unity 時代唯一有效的動作面）
  ///
  /// 舊的 `window.naki.action.*` 依賴 Laya 物件，Unity WebGL 客戶端已不存在；
  /// 所有動作改組成 Liqi REQUEST 經 `window.__nakiWebSocket.sendRaw` 送出。
  private(set) var liqiSender = LiqiActionSender()

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
  static let hidePlayerNamesKey = "HidePlayerNames" 

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

    // 注入所有 JavaScript 模組（WebSocket 攔截、WebGL 高亮）。
    // nil = 模組載入失敗且沒有 fallback：不注入任何東西，改在下面把失敗掛到 UI。
    if let websocketScript = WebSocketInterceptor.createUserScript() {
      userContentController.addUserScript(websocketScript)
    }

    configuration.userContentController = userContentController

    // 註：這裡原本還有一份 `#if DEBUG webPage?.isInspectable = true`。
    // 它在 `webPage` 被建立**之前**執行，optional chaining 對 nil 直接短路，
    // 一行都沒生效；真正有效的是下面建立完 WebPage 之後那份。

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

    // 設定 Liqi 送出通道（protobuf → base64 → JS sendRaw）
    configureLiqiSender()

    // 自動啟動 MCP Server
    startDebugServer()

    // 沿用上次選的模式。
    // 舊行為是每次啟動都硬設 .auto，於是使用者選的「關閉」一重啟就被沖掉，
    // 看起來像「選了關閉還是會自動打牌」。
    autoPlayMode = AutoPlayModeStore.load()
    bridgeLog("[WebViewModel] 自動打牌模式（沿用上次）: \(autoPlayMode.rawValue)")

    // 啟動定期檢查計時器（每 1 秒檢查一次）
    startAutoPlayCheckTimer()

    // 監聽導航事件
    observeNavigations()

    // JS 注入失敗時不要顯示「準備就緒」——那正是舊 fallback 最危險的地方：
    // 看起來一切正常，實際上一個動作都送不出去。
    if let failure = JSInjectionState.shared.report.failureSummary {
      statusMessage = "錯誤：JavaScript 注入失敗，Naki 無法讀牌局也無法送出動作（\(failure)）"
    } else {
      statusMessage = "準備就緒 (全自動模式)"
    }
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
            systemLog("[生命週期] 頁面開始載入")
            // 重置隱藏名稱設定狀態，以便重新套用
            resetHideNamesSettings()

          case .committed:
            statusMessage = "雀魂已加載，等待連接..."

          case .finished:
            print("[WebView] 頁面載入成功")
            systemLog("[生命週期] 頁面載入完成")
            // JS 模組的開關是 closure 內的變數，reload 會歸零，必須重新套用
            applyHideNamesSettingsIfNeeded()

          case .receivedServerRedirect:
            break

          @unknown default:
            break
          }
        }
      } catch {
        print("[WebView] 導覽錯誤: \(error)")
        statusMessage = "加載失敗: \(error.localizedDescription)"
      }
    }
  }

  // MARK: - Liqi 動作送出

  /// 設定 `LiqiActionSender` 的送出通道與日誌
  ///
  /// 送出鏈：Swift 組 envelope → base64 → `window.__nakiWebSocket.sendRaw(base64)`
  /// → JS 端取第一條 OPEN 的雀魂連線 `ws.send(buffer)`。
  /// JS 回報 `{success, bytes, socketId}` 或 `{success:false, reason}`。
  private func configureLiqiSender() {
    // `addLog` 內部就會寫進 LogManager（並更新狀態列），所以這裡不能再 bridgeLog 一次；
    // 先前兩行都寫，同一件事在 `/logs` 會以兩種前綴各出現一次。
    // server 還沒建起來時仍要留紀錄，所以走 bridgeLog fallback。
    liqiSender.logHandler = { [weak self] message in
      let line = "[WebViewModel] \(message)"
      if let server = self?.debugServer {
        server.addLog(line)
      } else {
        bridgeLog(line)
      }
    }

    // 腳本字串與回傳值解析都在 `NakiWebSocketScript`（Legacy 路徑走同一份）
    liqiSender.sendHandler = { [weak self] base64 in
      guard let self, let page = self.webPage else {
        return .failure("no_webpage")
      }
      do {
        return NakiWebSocketScript.sendResult(
          from: try await page.callJavaScript(NakiWebSocketScript.sendRaw(base64: base64)))
      } catch {
        return .failure("js_error: \(error.localizedDescription)")
      }
    }
  }

  /// 啟動定期檢查計時器（每 1 秒檢查一次）
  private func startAutoPlayCheckTimer() {
    autoPlayCheckTimer?.invalidate()
    autoPlayCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) {
      [weak self] _ in
      guard let self else { return }
      Task { @MainActor in
        self.checkAndRetriggerAutoPlay()
      }
    }
  }

  /// 定期檢查：如果有推薦且沒有正在執行的動作，重新觸發
  /// 走與事件路徑相同的去抖（triggerAutoPlayIfNeeded），共用 lastTriggerKey/lastTriggerTime，
  /// 避免計時器重複觸發同一推薦；若推薦為 discard，額外確認仍輪到自己打牌後才觸發。
  private func checkAndRetriggerAutoPlay() {
    guard webPage != nil else { return }

    // 註：遊戲內高亮 / 隱藏玩家名稱的輪詢已移除。
    // 雀魂已改用 Unity WebGL 客戶端，window.view.DesktopMgr / Laya / uiscript 均不存在，
    // 相關注入只會靜默失敗形成假訊號；推薦一律由原生面板
    // (Views/RecommendationView.swift、Views/BotStatusView.swift) 呈現。

    let snapshot = LiqiOperationStore.shared.pending
    let decision = AutoPlayGate.evaluate(.init(
      isAutoMode: autoPlayMode == .auto,
      isSanma: gameState.is3P,
      hasActionInFlight: currentExecutionId != nil,
      snapshot: snapshot,
      recommendations: recommendations,
      now: Date(),
      callPassGrace: Self.callPassGrace))

    switch decision {
    case .skip:
      // 刻意不記 log：這條路一秒跑一次，記下來會把 log 淹掉。
      // 要看被哪一關擋住時，改用 /bot/deep（回傳同一組輸入）重新判一次。
      return

    case .forceHora:
      guard let snapshot else { return }
      logAutoPlayEvent("🎯 oplist 有和牌但模型無推薦 → 交給 resolver (ops=\(snapshot.rawTypes))")
      triggerAutoPlayNow(delay: 0, forcedAction: .hora)

    case .sendPass:
      guard let snapshot,
            let callOp = snapshot.operations.compactMap({ $0.type })
              .first(where: { $0.isCallOpportunity })
      else { return }
      // pass 要送 inputChiPengGang 還是 inputOperation，取決於這批機會的類型
      // （吃/碰/大明槓走前者，榮和等走後者），故從快照裡實際的機會操作取通道。
      logAutoPlayEvent("⏰ 副露機會無推薦(Mortal 判斷不做) → 自動送出過 (ops=\(snapshot.rawTypes))")
      let channel = callOp.channel
      let sequence = snapshot.sequence

      // 這裡曾經是「先 markHandled 再 await pass()」：送出失敗時這批機會
      // 在沒有送出任何 request 的情況下就被消化，只能等伺服器逾時代打。
      // 改成由 AutoPassDispatcher 在**送出成功之後**才 markHandled。
      //
      // 代價是「決定要送」到「真的送出去」之間多了一段空窗，而 1 秒輪詢
      // 只看 currentExecutionId 有沒有東西；不佔住執行位的話下一拍會對同一批
      // oplist 再送一次過。所以這裡沿用既有的 executionId 機制當互斥，
      // 並保證每條結束路徑都會歸零（殘留會讓輪詢被永久停用）。
      let executionId = UUID()
      currentExecutionId = executionId
      Task { [weak self] in
        guard let self else { return }
        await AutoPassDispatcher.send(
          sequence: sequence,
          store: LiqiOperationStore.shared,
          isCurrent: { self.currentExecutionId == executionId },
          log: { self.logAutoPlayEvent($0) },
          send: { await self.liqiSender.pass(channel: channel) })
        self.clearExecutionIfCurrent(executionId)
      }

    case .proceed:
      debugServer?.addLog("⏰ 計時器: 檢查重新觸發 (ops=\(snapshot?.rawTypes ?? []))")
      // 共用事件路徑的去抖邏輯（lastTriggerKey/lastTriggerTime），避免同一推薦被重複觸發
      triggerAutoPlayIfNeeded()
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
      bridgeLog("[WebViewModel] 無法重新同步: 協調器不可用")
      statusMessage = "無法重建：協調器不可用"
      return
    }

    if !coordinator.eventStream.canResync() {
      bridgeLog("[WebViewModel] 無法重新同步: 無進行中的遊戲")
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
      bridgeLog("[WebViewModel] 無法強制重連: 無 webPage")
      statusMessage = "無法重連：WebView 不可用"
      return
    }

    bridgeLog("[WebViewModel] 強制重連 WebSocket...")
    statusMessage = "正在強制重連..."

    do {
      // callJavaScript 是函式體語意：腳本必須自帶 return，否則恆回 nil（見 NakiWebSocketScript）
      let result = try await page.callJavaScript(NakiWebSocketScript.forceReconnect)
      let closedCount = NakiWebSocketScript.closedCount(from: result)
      bridgeLog("[WebViewModel] 強制重連: 關閉了 \(closedCount) 個連線")
      statusMessage = closedCount > 0 ? "已關閉 \(closedCount) 個連接，等待重連..." : "沒有活躍的連接"
    } catch {
      bridgeLog("[WebViewModel] 強制重連錯誤: \(error)")
      statusMessage = "重連失敗：\(error.localizedDescription)"
    }
  }

  /// 從 Bot 控制器更新 UI 狀態並觸發自動打牌
  private func updateUIAfterBotResponse(from controller: NativeBotController) {
    bridgeLog("[WebViewModel] ===== updateUIAfterBotResponse 被調用 =====")

    // 更新遊戲狀態
    gameState = controller.gameState
    botStatus = controller.botState
    tehaiTiles = controller.tehaiMjai
    tsumoTile = controller.lastTsumo
    recommendations = controller.lastRecommendations
    recommendationCount = recommendations.count

    bridgeLog("[WebViewModel] 已更新推薦: \(recommendations.count)")

    // 同步到 GameStateManager（供 UI 回應式更新）
    gameStateManager.syncFrom(controller: controller)

    // 推薦一律由原生 SwiftUI 面板呈現：ContentView 直接綁 `recommendations` /
    // `botStatus`（RecommendationView、BotStatusView），@Observable 會自動刷新。
    // 側欄的顯示閘門在 `RecommendationView` 內（讀 `autoPlayMode.showRecommendation`）：
    // 資料層保持真實，`/bot/status` 仍看得到模型實際算出什麼。
    //
    // `highlightedTile` 是「現在標了哪一張」的對外欄位，`.off` 時必須是 nil，
    // 否則它會宣稱畫面上有一個其實已經被 clear() 掉的標記。
    highlightedTile = autoPlayMode.showRecommendation ? recommendations.first?.displayTile : nil

    // 遊戲畫面內高亮：Unity 下由 naki-core.js 的 __nakiHighlight 攔 WebGL draw，
    // 依 atlas UV 暫時改 _Tint / _Color，draw 後立刻還原。
    syncGameHighlight()

    // 觸發自動打牌
    triggerAutoPlayIfNeeded()
  }

  /// 根據當前推薦觸發自動打牌
  private func triggerAutoPlayIfNeeded() {
    let hasRecs = !recommendations.isEmpty

    guard autoPlayMode == .auto, hasRecs else { return }

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

    debugServer?.addLog("自動檢查: \(firstAction.rawValue)-\(tileName) (延遲: \(delay)秒)")
    triggerAutoPlayNow(delay: delay)
  }

  /// 計算動作延遲時間
  ///
  /// 交給 `ActionDelayModel`。以前這裡是每種動作一個固定秒數——固定時序是指紋，
  /// 而且 1.9 秒的窗口讓 `/screenshot`（要 1–2 秒）常常拍到牌已經打掉之後。
  private func calculateDelay(for actionType: Recommendation.ActionType?) -> TimeInterval {
    ActionDelayModel.delay(for: actionType)
  }

  // MARK: - 遊戲畫面內高亮

  /// 依目前推薦，暫時改 Unity 畫該牌時的 tint。
  ///
  /// Unity WebGL 沒有 JS per-tile object；JS 從 `_MainTex_ST` atlas UV 辨識牌名。
  /// Swift 只傳牌 identity 與顏色，不推算螢幕位置或手牌 index。
  ///
  /// 腳本內容由純函式 `GameHighlightScript.make` 決定（見該處：唯一能對
  /// 「`.off` 是不是真的清空」寫機械測試的地方）。
  private func syncGameHighlight() {
    guard let page = webPage else { return }

    let script = GameHighlightScript.make(
      mode: autoPlayMode,
      recommendations: recommendations,
      tehaiTiles: tehaiTiles,
      snapshot: LiqiOperationStore.shared.latest)

    Task { _ = try? await page.callJavaScript(script) }
  }

  /// 自動打牌的關鍵節點：同時進 Debug buffer 與 naki-events.log
  ///
  /// 這些是「為什麼這樣打／為什麼沒打」的唯一線索，不能混在 parser 細節裡。
  private func logAutoPlayEvent(_ message: String) {
    debugServer?.addLog(message)
    eventLog(message)
  }

  /// 刪除原生 Bot
  func deleteNativeBot() {
    nativeBotController?.deleteBot()
    botStatus = BotStatus()
    recommendations = []
    tehaiTiles = []
    tsumoTile = nil
    highlightedTile = nil
    // GameStateManager 是 /bot/status 與 SwiftUI 面板的實際資料來源；
    // 不一併重置的話，對局結束後畫面會一直停在上一局的手牌與推薦。
    gameStateManager.reset()
    syncGameHighlight()   // 推薦已清空 → 會送出 clear()，避免標記留在畫面上
    bridgeLog("[WebViewModel] Bot 已刪除並清除狀態")
  }

  // MARK: - Auto Play Methods

  /// 設定自動打牌模式
  func setAutoPlayMode(_ mode: AutoPlayMode) {
    // 收斂＋持久化走與 Legacy 同一個入口（這條路 `supportsAutoPlay` 為 true，
    // 所以 clamp 是恆等式；共用是為了讓「選了什麼／記住什麼」只有一份定義）。
    autoPlayMode = AutoPlayAvailability.commit(mode, autoPlaySupported: supportsAutoPlay)
    bridgeLog("[WebViewModel] 自動打牌模式設定為: \(autoPlayMode.rawValue)")
    debugServer?.addLog("模式已變更: \(autoPlayMode.rawValue), 推薦數: \(recommendations.count)")

    // 模式一改就要立刻反映在畫面上，不能等下一次 Bot 回應：
    // 切到 `.off` 時把遊戲內標記清掉，切回 `.recommend` / `.auto` 時重新染上。
    // （側欄是 SwiftUI 綁定，讀 `autoPlayMode` 會自己重畫。）
    highlightedTile = autoPlayMode.showRecommendation ? recommendations.first?.displayTile : nil
    syncGameHighlight()

    // 只有全自動模式才觸發自動打牌（用生效值，不是要求值）
    if autoPlayMode.isFullAuto, !recommendations.isEmpty {
      let firstAction = recommendations.first?.actionType
      let delay = ActionDelayModel.delay(for: firstAction)
      debugServer?.addLog(
        "模式變更時自動觸發: \(firstAction?.rawValue ?? "?") (延遲: \(delay)秒)")
      triggerAutoPlayNow(delay: delay)
    }
  }

  // 註：`setAutoPlayDelay(_:)` 已移除。它唯一的寫入點是 toolbar 的 Stepper，
  // 而寫進去的值沒有任何讀取者——真正的送出延遲由 `ActionDelayModel` 依動作
  // 類型隨機決定（刻意設計，避免固定節奏）。UI 上的 Stepper 一併移除。

  /// 設定是否隱藏玩家名稱
  ///
  /// 走協定層：`naki-websocket.js` 在遊戲解析封包之前，就地把 `ResAuthGame`
  /// 的 nickname bytes 換成等長 ASCII。之所以不走 UI 層，是因為舊的
  /// `__nakiPlayerNames.hide()` 依賴 `uiscript.UI_DesktopInfo`，那在 Unity
  /// 客戶端不存在（見 AUDIT §13）。
  ///
  /// 只對「開啟之後才開始的對局」生效——名牌在 authGame 當下就設定完了，
  /// 對局中途才打開不會回頭改已經畫出來的畫面。
  func setHidePlayerNames(_ hide: Bool) {
    UserDefaults.standard.set(hide, forKey: WebViewModel.hidePlayerNamesKey)
    guard let page = webPage else { return }
    let script = "return window.__nakiHideNames?.setEnabled(\(hide)) ?? false"

    Task {
      do {
        let result = try await page.callJavaScript(script)
        bridgeLog("[WebViewModel] 隱藏玩家名稱: \(hide), 結果: \(String(describing: result))")
      } catch {
        bridgeLog("[WebViewModel] 設定隱藏名稱錯誤: \(error.localizedDescription)")
      }
    }
  }


  /// 獲取玩家名稱隱藏狀態
  func getPlayerNamesStatus() async -> [String: Any]? {
    guard let page = webPage else { return nil }

    let script = "return JSON.stringify(window.__nakiHideNames?.getStatus() ?? {})"

    do {
      let result = try await page.callJavaScript(script)
      if let jsonString = result as? String,
        let data = jsonString.data(using: .utf8),
        let status = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      {
        return status
      }
    } catch {
      bridgeLog("[WebViewModel] 取得名稱狀態錯誤: \(error.localizedDescription)")
    }
    return nil
  }

  /// 重置隱藏名稱設定狀態（頁面重新載入時調用）
  /// 註：自動套用（applyHideNamesSettingsIfNeeded）已移除——它依賴
  /// `window.uiscript.UI_DesktopInfo`，Unity WebGL 客戶端不存在此物件，
  /// 每秒輪詢只會永遠檢查失敗。UI 與 MCP ui_names_* 已移除；Swift API 暫留協定相容。
  func resetHideNamesSettings() {
    hasAppliedHideNamesSettings = false
  }

  /// 頁面載入完成後把持久化的隱藏名稱設定推回 JS
  ///
  /// 這個 flag 以前只被 reset、沒有人讀，等於設定在 reload 之後就消失了。
  func applyHideNamesSettingsIfNeeded() {
    guard !hasAppliedHideNamesSettings else { return }
    hasAppliedHideNamesSettings = true
    guard UserDefaults.standard.bool(forKey: WebViewModel.hidePlayerNamesKey) else { return }
    setHidePlayerNames(true)
  }

  // 註：`cancelAutoPlayAction()` / `confirmAutoPlayAction()` 已移除。
  // 這條路徑上沒有「先提示、等使用者確認」的流程：推薦一產生就依模式決定是否送出。
  // 兩者要取消／確認的那個 pending action 容器（連同它的 Timer）從來沒被建立過。

  /// 手動觸發自動打牌（使用當前推薦）
  /// - Parameter forcedAction: 不看 AI 推薦、直接以這個動作進入決策流程。
  ///   用於「伺服器提供和牌但模型沒有推薦」——最終仍由 resolver 覆核。
  func triggerAutoPlayNow(delay: TimeInterval = 1.2) {
    triggerAutoPlayNow(delay: delay, forcedAction: nil)
  }

  func triggerAutoPlayNow(delay: TimeInterval,
                          forcedAction: Recommendation.ActionType?) {
    guard webPage != nil else {
      bridgeLog("[WebViewModel] 無法觸發: 無 WebPage")
      return
    }

    // 三麻 fail-closed（與 `AutoPlayGate` / `AutoPlayDecisionResolver` 同一條規則）。
    //
    // 這裡是手動觸發（含 MCP `bot_trigger`）的入口，不經過 1 秒輪詢的閘門，
    // 所以要自己擋一次。內建模型只有四麻一份，三麻的推薦不該被自動送出。
    if gameState.is3P {
      bridgeLog("[WebViewModel] 略過觸發: 三麻不支援自動送出（只有四麻模型）")
      debugServer?.addLog("⏭️ 三麻對局：自動送出已停用（僅支援四麻）")
      return
    }

    let actionType: Recommendation.ActionType
    let tileName: String
    if let forcedAction {
      actionType = forcedAction
      tileName = LiqiOperationStore.shared.pending?.contextTile ?? ""
    } else if let firstRec = recommendations.first {
      actionType = firstRec.actionType
      tileName = firstRec.displayTile
    } else {
      bridgeLog("[WebViewModel] 無法觸發: 無推薦")
      return
    }

    // 沒有 oplist 就別排這次觸發。
    //
    // 以前不管有沒有 oplist 都會排進 `executeAutoPlayActionWithRetry`，
    // 於是在「伺服器根本還沒授權」的時機空轉 50×0.1s 然後印 ❌，
    // 看起來像故障，其實是安全機制在正常運作。實測兩個觸發情境：
    //   1. 立直後的強制摸切 —— 客戶端自己摸切，伺服器不再送 oplist
    //   2. 和牌結算到新局發牌之間 —— 模型已看到新手牌但還不能動作
    // 兩者都會在真正可動作時由 oplist 到達重新觸發，不需要在這裡等。
    //
    // forcedAction（伺服器提供和牌但模型無推薦）不受此限：那條路的前提
    // 就是 oplist 裡有和牌，本來就有 snapshot。
    if forcedAction == nil, LiqiOperationStore.shared.pending == nil {
      bridgeLog("[WebViewModel] 略過觸發: 尚無 oplist（\(actionType.rawValue) \(tileName)）")
      return
    }

    // 生成執行 ID 用於追蹤
    let executionId = UUID()
    currentExecutionId = executionId

    bridgeLog("[WebViewModel] 觸發: \(actionType.rawValue) - \(tileName) (延遲: \(delay)秒)")
    debugServer?.addLog("觸發: \(actionType.rawValue) - \(tileName)")

    // 延遲執行避免太快
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
      guard let self = self else { return }

      // 檢查是否被更新的觸發取代
      if self.currentExecutionId != executionId {
        self.debugServer?.addLog("跳過: 已被新觸發取代")
        return
      }

      // 所有動作都使用重試機制
      Task {
        await self.executeAutoPlayActionWithRetry(
          actionType: actionType, tileName: tileName, attempt: 1,
          executionId: executionId)
      }
    }
  }

  /// 副露機會在多久之後才允許「因為沒推薦而自動送過」
  ///
  /// 只要比「oplist 到達 → 推論完成 → 推薦同步到 view model」的總延遲長就夠。
  /// 實測該延遲在 100ms 量級，2 秒有 20 倍餘裕；而伺服器等 300 秒，
  /// 多等 2 秒沒有任何代價。
  static let callPassGrace: TimeInterval = 2.0

  /// 最大重試次數
  ///
  /// 從 50（5 秒）降到 15（1.5 秒）。觸發點已經確認過 oplist 存在，
  /// 這裡要處理的只是「延遲期間 oplist 剛好被換掉」的短暫空窗；
  /// 等 5 秒不會讓它變得比較可能出現，只會讓失敗訊息晚 3.5 秒才出現。
  private let maxRetryAttempts = 15

  /// 僅在 executionId 仍為當前執行時清除 currentExecutionId。
  /// 避免遞迴／延遲後外層路徑清掉「已被新觸發取代」的執行 ID；
  /// 所有終止路徑（成功／放棄／逾時／錯誤／catch）都必須經此歸零，
  /// 否則 currentExecutionId 殘留會讓 1 秒輪詢（checkAndRetriggerAutoPlay 以
  /// currentExecutionId == nil 為前提）被永久停用，自動打牌黏著卡死。
  private func clearExecutionIfCurrent(_ executionId: UUID) {
    if currentExecutionId == executionId {
      currentExecutionId = nil
    }
  }

  /// 帶重試的自動打牌執行
  ///
  /// 保留原本的 executionId 守衛 / 去抖 / 重試框架，只把「怎麼把動作送出去」換成
  /// Liqi protobuf；可用操作（oplist）改讀協定層快照 `LiqiOperationStore`
  /// （Unity 客戶端沒有 `DesktopMgr.Inst.oplist`）。
  private func executeAutoPlayActionWithRetry(
    actionType: Recommendation.ActionType, tileName: String, attempt: Int,
    executionId: UUID
  ) async {

    // 檢查是否被新的觸發取代
    if currentExecutionId != executionId {
      debugServer?.addLog("⏭️ 重試已取消: 被取代 (第 \(attempt) 次)")
      return
    }

    // 先檢查是否還有操作可執行（協定層 oplist）
    guard let snapshot = LiqiOperationStore.shared.pending else {
      // 沒有 oplist 就不送。
      //
      // 舊行為是「打牌不等 oplist，直接送出」——那等於在沒有伺服器授權的情況下
      // 硬送，實測有一半以上根本不是我們的回合而被丟棄，而且會繞過終局保護
      // （伺服器可能正提供自摸，我們卻盲送打牌）。合法性的權威在 oplist，
      // 缺資料一律 fail closed，等下一批 oplist 到齊再說。
      if attempt < maxRetryAttempts {
        if attempt == 1 || attempt % 10 == 0 {
          debugServer?.addLog("等待 oplist \(attempt)/\(maxRetryAttempts)")
        }
        try? await Task.sleep(nanoseconds: 100_000_000)  // 0.1s
        await executeAutoPlayActionWithRetry(
          actionType: actionType, tileName: tileName, attempt: attempt + 1,
          executionId: executionId)
      } else {
        if actionType == .none {
          debugServer?.addLog("✅ Pass: \(attempt) 次嘗試後無 oplist, 無機會")
        } else {
          debugServer?.addLog("⏭️ \(attempt) 次嘗試後 oplist 仍未到，這次不送（等下一批）")
        }
        clearExecutionIfCurrent(executionId)
      }
      return
    }

    // 送出前的唯一決策點。
    //
    // 不直接照 `actionType` 送——那是「觸發當下」的 AI 推薦，
    // 中間隔了 1.0–1.8 秒的延遲，這段期間 oplist 可能已經換了一批。
    // Resolver 會做三件事：終局保護（伺服器提供自摸就一定自摸，凌駕 AI）、
    // 模式閘門、以及確認該動作真的在這批 oplist 裡。
    let decision = AutoPlayDecisionResolver.resolve(
      snapshot: snapshot,
      recommendations: recommendations,
      mode: autoPlayMode,
      // 座位來源在 `WebViewModelProtocol.autoPlaySeat` 一份定義（Legacy 走同一個）
      seat: autoPlaySeat,
      isSanma: gameState.is3P)

    let resolvedAction: Recommendation.ActionType
    let resolvedTile: String
    switch decision {
    case .send(let action, let tile):
      resolvedAction = action
      resolvedTile = tile.isEmpty ? tileName : tile
    case .surfaceOnly(let action, _):
      debugServer?.addLog("模式非自動，僅顯示不送出: \(action.rawValue)")
      clearExecutionIfCurrent(executionId)
      return
    case .none(let reason):
      debugServer?.addLog("⏭️ 不送出: \(reason)")
      clearExecutionIfCurrent(executionId)
      return
    }

    if resolvedAction != actionType {
      logAutoPlayEvent("⚠️ 決策覆蓋: AI 建議 \(actionType.rawValue) → 實際送出 \(resolvedAction.rawValue)")
    }

    // 送出前最後確認這批 oplist 沒被換掉（決策到送出之間對局可能已往前走）
    guard AutoPlayDecisionResolver.isStillValid(
      decidedOn: snapshot, current: LiqiOperationStore.shared.pending)
    else {
      logAutoPlayEvent("⏭️ oplist 已更新，捨棄過期決策 (seq=\(snapshot.sequence))")
      clearExecutionIfCurrent(executionId)
      return
    }

    logAutoPlayEvent("第 \(attempt) 次嘗試: ops=\(snapshot.rawTypes) → \(resolvedAction.rawValue)")
    let sendResult = await executeAutoPlayAction(
      actionType: resolvedAction, tileName: resolvedTile)

    // 和牌：成功才收工，失敗一定要重試。
    //
    // 這裡曾經是不論結果都 log「✅ 已宣告和牌」+ markHandled + return，
    // 判斷的是「我呼叫過那個函式」而不是「封包真的送出去了」。
    // 送出失敗（沒有 game-gateway、JS 拒絕、伺服器回 error）時和牌機會就永久消失，
    // 而且 log 上還寫著成功——漏和是不可逆的，不能這樣處理。
    //
    // markHandled 由 executeAutoPlayAction 在確認 success 後才做，這裡不重覆標記。
    if resolvedAction == .hora {
      if sendResult?.success == true {
        logAutoPlayEvent("✅ 已宣告和牌")
        clearExecutionIfCurrent(executionId)
        return
      }
      if attempt >= maxRetryAttempts {
        logAutoPlayEvent("❌ 和牌送出失敗 \(attempt) 次, 放棄 (\(sendResult?.logLine ?? "no result"))")
        clearExecutionIfCurrent(executionId)
        return
      }
      logAutoPlayEvent("⚠️ 和牌送出失敗, 重試 \(attempt + 1)/\(maxRetryAttempts)")
      try? await Task.sleep(nanoseconds: 200_000_000)
      await executeAutoPlayActionWithRetry(
        actionType: resolvedAction, tileName: resolvedTile,
        attempt: attempt + 1, executionId: executionId)
      return
    }

    // pass 操作：較長間隔 (0.5s)，最多重試 5 次
    if resolvedAction == .none {
      let maxPassRetries = 5
      if attempt >= maxPassRetries {
        debugServer?.addLog("✅ Pass 已發送 (第 \(attempt) 次)")
        clearExecutionIfCurrent(executionId)
        return
      }
      try? await Task.sleep(nanoseconds: 500_000_000)  // 0.5s
      await checkAndRetryIfNeeded(
        actionType: resolvedAction, tileName: resolvedTile, attempt: attempt, executionId: executionId)
      return
    }

    // 其他操作：0.1 秒後檢查是否成功
    try? await Task.sleep(nanoseconds: 100_000_000)
    await checkAndRetryIfNeeded(
      actionType: resolvedAction, tileName: resolvedTile, attempt: attempt, executionId: executionId)
  }

  /// 檢查動作是否成功，失敗則重試
  ///
  /// 判準改為協定層：動作送出成功時會把當批 oplist 標記為已處理，
  /// 因此「仍有未處理的 oplist」＝動作沒送出去（或被 JS 端拒絕），需要重試。
  private func checkAndRetryIfNeeded(
    actionType: Recommendation.ActionType, tileName: String, attempt: Int, executionId: UUID
  ) async {

    // 檢查是否被新的觸發取代
    if currentExecutionId != executionId {
      debugServer?.addLog("⏭️ 檢查已取消: 被取代")
      return
    }

    guard let snapshot = LiqiOperationStore.shared.pending else {
      debugServer?.addLog("✅ 動作成功, 第 \(attempt) 次 (oplist 已消化)")
      clearExecutionIfCurrent(executionId)
      return
    }

    if attempt >= maxRetryAttempts {
      debugServer?.addLog("❌ 已達最大重試次數 (\(attempt)), ops=\(snapshot.rawTypes)")
      clearExecutionIfCurrent(executionId)
      return
    }

    debugServer?.addLog("重試 \(attempt + 1): ops 仍存在 \(snapshot.rawTypes)")
    await executeAutoPlayActionWithRetry(
      actionType: actionType, tileName: tileName, attempt: attempt + 1, executionId: executionId)
  }

  /// 實際送出自動打牌動作（Liqi protobuf）
  ///
  /// 舊實作呼叫 `window.naki.action.*`（Laya 物件），Unity WebGL 客戶端已不存在，
  /// 那條路徑永遠靜默失敗。現在一律由 `LiqiActionSender` 組 Liqi REQUEST，
  /// 經 `window.__nakiWebSocket.sendRaw` 送出；需要 index／槓型／和牌型的動作
  /// 由協定層 oplist 快照推導。
  ///
  /// 7-case switch 與「成功才 markHandled」都在 `AutoPlayActionExecutor`（p2-1 收斂，
  /// Legacy 路徑與測試 harness 走同一份）；這裡只負責把 view model 的上下文
  /// （推薦、這一巡摸到的牌、兩條 log 通道）接上去。
  @discardableResult
  private func executeAutoPlayAction(
    actionType: Recommendation.ActionType, tileName: String
  ) async -> LiqiSendResult? {
    await AutoPlayActionExecutor.execute(
      action: actionType,
      tile: tileName,
      snapshot: LiqiOperationStore.shared.pending,
      recommendations: recommendations,
      tsumoTile: tsumoTile,
      sender: liqiSender,
      store: LiqiOperationStore.shared,
      log: { self.debugServer?.addLog($0) },
      event: { self.logAutoPlayEvent($0) })
  }

  // MARK: - 協定層狀態快照（MCP 狀態類工具的資料來源）

  /// 組出「Swift 協定層的遊戲快照」。
  ///
  /// Unity 客戶端下 `window.view.DesktopMgr.Inst` 不存在，舊的 `/game/state`、`/game/hand`、
  /// `/game/ops` 全部讀不到東西。這些資訊本來就從 Liqi notify 流進 Swift，
  /// 由 `MajsoulBridge` → `NativeBotController` → `GameStateManager` 維護，
  /// 以及 `LiqiOperationStore`（可用操作）持有，這裡只是把它們攤成 JSON。
  ///
  /// ⚠️ 這是 **Naki 自己看到的狀態**，不是向伺服器查詢的結果；
  /// 若 Naki 錯過封包（例如中途啟動），這裡會不完整——用 `bot_sync` 觸發重連重建。
  func protocolGameSnapshot() -> [String: Any] {
    let state = gameStateManager.gameState
    let bot = gameStateManager.botStatus

    var snapshot: [String: Any] = [
      "source": "swift-protocol-layer",
      "note": "Unity 客戶端沒有 JS 遊戲物件；本資料由 Liqi 封包在 Swift 端重建",
      "accountId": webCoordinator?.websocketHandler.majsoulAccountId ?? 0,
      "gameState": [
        "bakaze": state.bakazeString,
        "bakazeDisplay": state.bakazeDisplay,
        "kyoku": state.kyoku,
        "kyokuDisplay": state.kyokuDisplayName,
        "honba": state.honba,
        "kyotaku": state.kyotaku,
        "jikaze": state.jikazeString,
        "scores": state.scores,
        "doraIndicators": state.doraIndicators,
        "seat": state.playerId,
        "is3P": state.is3P,
        "inGame": gameStateManager.isInGame,
      ],
      "bot": [
        "isActive": bot.isActive,
        "model": bot.modelName,
        "seat": bot.playerId,
        "is3P": bot.is3P,
        "canDiscard": bot.canDiscard,
        "canRiichi": bot.canRiichi,
        "canChi": bot.canChi,
        "canPon": bot.canPon,
        "canKan": bot.canKan,
        "canAgari": bot.canAgari,
      ],
      "hand": [
        "tehai": tehaiTiles,
        "tehaiCount": tehaiTiles.count,
        "tsumo": tsumoTile as Any? ?? NSNull(),
        "notation": "MJAI（5mr = 紅五萬；E/S/W/N/P/F/C = 字牌）",
      ] as [String: Any],
      "recommendations": gameStateManager.recommendations.map { rec in
        [
          "tile": rec.displayTile,
          "action": rec.actionType.rawValue,
          "label": rec.displayLabel,
          "prob": rec.probability,
          "percentage": rec.percentageString,
        ] as [String: Any]
      },
      // 註：`isMyTurn` / `hasPendingAction` 已移除——它們的來源欄位
      // 從來沒有人寫過真值（恆 false / 恆 nil）。
      // 要判斷「輪到誰」請看 `operations.pending`（server-authoritative）。
      "autoPlay": [
        "mode": autoPlayMode.rawValue
      ],
    ]

    // 可用操作（協定層 oplist；pending = 尚未被動作層消化）
    let store = LiqiOperationStore.shared
    var operations: [String: Any] = [:]
    operations["pending"] = store.pending?.dictionary ?? NSNull()
    operations["latest"] = store.latest?.dictionary ?? NSNull()
    snapshot["operations"] = operations

    return snapshot
  }

  // MARK: - MCP Server

  // 截圖是真正的平台分歧（AppKit）：iOS 沒有 `NSApplication`，
  // `captureScreenshot` 回調在 iOS 分支直接回錯誤。Debug Server 本身兩個平台都跑。
  #if os(macOS)
  /// 整個視窗（Naki 側欄 + 遊戲畫面）轉成 PNG
  static func windowScreenshot() -> Data? {
    guard let window = NSApplication.shared.windows.first(where: { $0.isVisible && $0.contentView != nil }),
          let content = window.contentView,
          content.bounds.width > 0, content.bounds.height > 0,
          let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds)
    else { return nil }
    content.cacheDisplay(in: content.bounds, to: rep)
    return rep.representation(using: .png, properties: [:])
  }
  #endif

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
    //   ✅ "return document.title" → 返回 "雀魂麻將"
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
          print("[JS 除錯] 腳本: \(script.prefix(50))...")
          print("[JS 除錯] 結果類型: \(type(of: result)), 值: \(String(describing: result))")
          completion(result, nil)
        } catch {
          print("[JS 除錯] 錯誤: \(error)")
          completion(nil, error)
        }
      }
    }

    // 設定截圖回調
    //
    // `contentView.cacheDisplay` 就抓得到 WKWebView 的內容——實測 macOS 26 上
    // WebView 那塊會正常出現在 bitmap 裡（`?mode=view` 拍到的載入畫面可證）。
    //
    // 原本還疊了一層 `WebPage.exported(as: .image())`，是為了防「WKWebView 跨
    // process 渲染、cacheDisplay 抓不到」。那個顧慮在這裡不成立，而合成本身
    // 反而製造了瑕疵（web 影像的 frame 與底圖對不齊，畫面底部出現重複的功能列），
    // 而且 `exported` 在 macOS 回的是 **TIFF** 不是 PNG。所以整層拿掉。
    //
    // 也沒有用 OS 層的 `screencapture`：那要「螢幕錄製」權限，視窗被遮住、
    // 在其他 Space 或最小化都拍不到。
    debugServer?.captureScreenshot = { completion in
      Task { @MainActor in
        #if os(macOS)
        if let png = Self.windowScreenshot() {
          completion(png, nil)
        } else {
          completion(nil, NSError(domain: "Naki", code: -1,
                                  userInfo: [NSLocalizedDescriptionKey: "no visible window"]))
        }
        #else
        completion(nil, NSError(domain: "Naki", code: -1,
                                userInfo: [NSLocalizedDescriptionKey: "macOS only"]))
        #endif
      }
    }

    // 狀態列回調——只更新 UI。
    // 訊息進 LogManager 由 `DebugServer.log()` 一手包辦；這裡再 bridgeLog 一次就會雙寫。
    debugServer?.onStatusMessage = { [weak self] message in
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
        // `isMyTurn` / `hasPendingAction` 已移除（恆 false／恆 nil 的假欄位）
        "autoPlay": [
          "mode": self.autoPlayMode.rawValue
        ],
        "recommendations": recs,
        "tehaiCount": self.tehaiTiles.count,
        "tsumoTile": self.tsumoTile ?? NSNull(),
      ]

      return result
    }

    // 設定手動觸發自動打牌回調
    // 統一走 WebViewModel 主自動打牌路徑：推薦 → gate → resolver → LiqiActionSender，
    // 沒有第二條「照手牌排序索引直接打」的捷徑
    debugServer?.triggerAutoPlay = { [weak self] in
      guard let self = self else { return }
      self.triggerAutoPlayNow()
    }

    // 設定 Liqi 請求送出回調（MCP 工具的動作／大廳面）
    // 舊的 JS 路徑（GameMgr.uimgr / NetAgent / DesktopMgr）在 Unity 客戶端全部不存在，
    // 所有 MCP 動作類工具改由這裡送 protobuf。
    debugServer?.sendLiqi = { [weak self] spec, awaitMs in
      guard let self = self else { return .unavailable("webviewmodel_deallocated") }
      return await self.liqiSender.sendAwaitingResponse(spec, awaitResponseMs: awaitMs)
    }

    // 設定遊戲狀態快照回調（MCP 狀態類工具的資料來源）
    debugServer?.getGameSnapshot = { [weak self] in
      guard let self = self else { return [:] }
      return self.protocolGameSnapshot()
    }

    // 設定自動心跳（防閒置）開關：Unity 下 GameMgr.clientHeatBeat 已不存在，
    // 改由 Swift 定期送 .lq.Lobby.heatbeat
    debugServer?.setAntiIdle = { [weak self] enabled, interval in
      guard let self = self else { return [:] }
      if enabled != nil || interval != nil {
        self.liqiSender.setAntiIdle(
          enabled: enabled ?? self.liqiSender.antiIdleEnabled, intervalSeconds: interval)
      }
      return self.liqiSender.antiIdleStatus
    }

    // 端口變更回調
    debugServer?.onPortChanged = { [weak self] newPort in
      Task { @MainActor in
        self?.debugServerPort = newPort
        self?.isDebugServerRunning = true
        self?.statusMessage = "MCP Server 已啟動: http://localhost:\(newPort)"
        systemLog("[生命週期] MCP Server 已啟動 port=\(newPort)")
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
    systemLog("[生命週期] MCP Server 已停止")
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

  /// 重新載入目前頁面
  func reload() {
    guard let page = webPage else { return }
    page.reload()
    statusMessage = "正在重新載入…"
  }

  // MARK: - View

  /// WebPage path 對應的 View。由 VM 自己指定，`AdaptiveNakiWebView` 不再判版本。
  func makeWebView() -> AnyView {
    AnyView(NakiWebView())
  }

  // MARK: - WebViewModelProtocol 補齊

  /// 在遊戲頁面執行 JS。
  ///
  /// 注意：`WebPage.callJavaScript` 的腳本是**函式體**，取值必須自己寫 `return`
  /// （這也是 Debug Server `/js` 端點的同一個規則）。
  func executeJavaScript(_ script: String) async throws -> Any? {
    guard let page = webPage else { return nil }
    return try await page.callJavaScript(script)
  }

  // MARK: - Call JavaScript

  func callJS(function: String, params: [String: Any]) async {
    guard let page = webPage else {
      print("WebPage 尚未準備好")
      return
    }

    do {
      let jsonData = try JSONSerialization.data(withJSONObject: params)
      let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"

      let script = "\(function)(\(jsonString));"

      _ = try await page.callJavaScript(script)
    } catch {
      print("JavaScript 錯誤: \(error.localizedDescription)")
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

// 註：`WebViewModelKey` / `EnvironmentValues.webViewModel` 統一定義在
// `WebViewModelProtocol.swift`，型別是 `any WebViewModelProtocol?`，
// 這樣 View 才能同時吃新版（WebPage）與 Legacy（WKWebView）兩種實作。
// 這裡不再另外定義具體型別版本，否則兩個同名 extension 會讓 View 端的
// `@Environment(\.webViewModel)` 產生 ambiguous use 編譯錯誤。

// MARK: - 遊戲畫面內高亮腳本（純函式）

/// 由「模式 + 推薦 + 手牌 + oplist」算出要送給 `window.__nakiHighlight` 的一行 JS。
///
/// 抽成 `nonisolated` 純函式的唯一理由是**可驗收**：p1-4 的驗收條件之一是
/// 「`.off` 時遊戲內高亮清空、切回 auto 恢復」。原本這段邏輯埋在需要 `WebPage`
/// 的 `syncGameHighlight()` 裡，除了真的開一局之外沒有任何辦法確認它有沒有做到；
/// 現在至少「送出去的腳本是什麼」可以逐條鎖住（真的染對顏色仍需 live 驗證）。
nonisolated enum GameHighlightScript {

    /// 清空所有標記
    static let clear = "window.__nakiHighlight?.clear();"

    /// - Parameters:
    ///   - mode: `.off` 一律回 `clear`——「關閉」關的就是顯示
    ///   - recommendations: 目前推薦（只看第一名）
    ///   - tehaiTiles: 自家手牌（MJAI），用來把非推薦牌調淡
    ///   - snapshot: 協定層 oplist（副露組合與彈出面板判斷都取自它，不用推測）
    static func make(mode: AutoPlayMode,
                     recommendations: [Recommendation],
                     tehaiTiles: [String],
                     snapshot: LiqiOperationSnapshot?) -> String {

        // `.off` 的語意是「不顯示推薦」。以前這裡沒讀 mode，於是關閉模式下遊戲畫面
        // 仍然照常染色——使用者關掉的東西還在動，是 AUDIT §13 那類「介面與行為不符」。
        // 回 clear 而不是「什麼都不送」：上一輪留在畫面上的標記也要收掉。
        guard mode.showRecommendation else { return clear }

        // 標記的是「哪一張牌」而不是「第幾張」。
        // JS 端從遊戲畫牌時的圖集 UV 認出牌面，所以這裡只要給牌名，
        // 不必知道它排在第幾個——手牌張數變動、立直抬牌、畫面邊緣混入別的牌
        // 都不再影響。
        var marks: [[String: Any]] = []

        if let top = recommendations.first {
            switch top.actionType {
            case .discard, .riichi:
                // 綠：建議打出的牌。顏色是乘在牌面貼圖上的，太深會看不見牌面，
                // 所以只壓非主色通道。
                marks.append(["tile": top.displayTile, "color": [0.45, 1.0, 0.5]])

                // 其餘手牌調淡，讓推薦那張自己浮出來。
                //
                // 只染推薦牌的話，在花色鮮豔的牌面皮膚上對比度不夠——
                // 把其他牌壓下去比把一張牌拉上來更有效，也比較不吵。
                // 第 4 個分量是 alpha 倍率，會乘在遊戲原本的 alpha 上。
                let recommended = top.displayTile
                for tile in Set(tehaiTiles).sorted() where tile != recommended {
                    marks.append(["tile": tile, "color": [0.62, 0.62, 0.68, 0.55]])
                }
            case .chi, .pon, .kan:
                // 橙：副露會用掉的手牌（組合取自協定層的 oplist，不是推測）
                let liqiType: LiqiOperationType? = {
                    switch top.actionType {
                    case .chi: return .chi
                    case .pon: return .pon
                    case .kan: return snapshot?.kanOperation
                    default: return nil
                    }
                }()
                let combo = liqiType.flatMap { snapshot?.operation(of: $0) }?.combination.first
                for tile in (combo?.split(separator: "|") ?? []).compactMap({
                    LiqiTileCode.mjai(fromMajsoul: String($0))
                }) {
                    marks.append(["tile": tile, "color": [1.0, 0.75, 0.4]])
                }
            default:
                break   // 和了 / 過：沒有對應的手牌可標
            }
        }

        // 副露彈出面板（吃／碰／跳過按鈕）：位置不在 uniform 裡，JS 端靠「只在有機會時
        // 才出現」自行辨識，這裡只負責告訴它「現在有機會、用什麼顏色」。
        //
        // **只在 Mortal 建議副露時才染色**。建議「過」時不要動它——
        // 把整個面板調暗會讓按鈕看起來像壞掉或被停用（實測畫面確認過），
        // 而且「沒有標記」本身就已經表達「這個機會不值得」。
        var popup = "null"
        if let top = recommendations.first, snapshot?.isCallOpportunity == true {
            switch top.actionType {
            case .chi, .pon, .kan, .hora: popup = "[0.45,1.0,0.5]"
            default: break
            }
        }

        guard !marks.isEmpty || popup != "null" else { return clear }

        let payload = (try? JSONSerialization.data(withJSONObject: marks))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return "window.__nakiHighlight?.set(\(payload), \(popup));"
    }
}
