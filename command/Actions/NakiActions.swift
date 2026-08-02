//
//  NakiActions.swift
//  Naki
//
//  p3-3：副作用的型別化入口（Action 層）
//
//  由來：Naki 的副作用（送 Liqi、重連、截圖、改模式、執行 JS）原本以 **9 個裸 closure**
//  四跳注入：
//
//      WebViewModel → DebugServer → MCPHandler → DefaultNakiMCPContext → tool
//
//  每一跳都是 `var x: ((A) -> B)?`，於是：
//
//  1. **型別簽章看不出依賴。** `DebugServer` 的欄位長得像 HTTP server 的設定，
//     實際上是整個 MCP 工具層的依賴表；漏接一個就是執行期的
//     `xxx_callback_not_configured`，編譯期一句話都不會說。
//  2. **沒有 stub 點。** closure 由 `WebViewModel.startDebugServer()` 就地寫死，
//     要測「送出失敗時 MCP 回什麼」得先有 WebPage + 真的 HTTP server。
//  3. **Preview 拉不起來。** View 直接呼叫 `viewModel?.forceReconnect()`，
//     沒有 view model 就等於沒有那顆按鈕的行為，Preview 只能看靜態畫面。
//
//  這一層的形狀是 SwiftUI 社群的 Action 模式：`@MainActor struct` + `callAsFunction`
//  + 一個真實 init（吃 service）+ 一個 `#if DEBUG` 的 stub init（吃 closure）。
//  結果是**依賴出現在型別上**、**測試與 Preview 有注入點**，而 closure 只存在於
//  型別內部一個 private 欄位，不再是跨層傳遞的貨幣。
//
//  邊界：Action 只包「做這件事」；決策（要不要做、做哪一個）仍在
//  `AutoPlayGate` / `AutoPlayDecisionResolver` / `AutoPlayEngine`，
//  資料仍在 `GameStore` / `LiqiOperationStore`。
//

import Foundation
import SwiftUI

#if canImport(AppKit)
  import AppKit
#endif

// MARK: - 共用錯誤

/// 「這條 path 上沒有這個能力」。
///
/// 刻意不用 MCPKit 的 `MCPToolError`：Action 層被 UI 與 MCP 共用，
/// 不應該把 MCP 的型別拖進 View。訊息格式保持含有能力名稱，
/// MCP 端的錯誤字串因此與遷移前一致（`… is not available`）。
enum NakiActionError: LocalizedError {
  case notAvailable(String)

  var errorDescription: String? {
    switch self {
    case .notAvailable(let capability):
      return "\(capability) is not available"
    }
  }
}

/// 送出一筆 Liqi 請求的完整結果：**送了什麼**（spec）＋**發生了什麼**（outcome）。
///
/// MCP 工具的輸出需要 spec（method／欄位）才能解釋 outcome，而 spec 是由 Action
/// 內部組出來的。回傳成對的值，呼叫端就不必為了拿 spec 再組一次
/// ——組兩次正是「參數改了一邊、輸出報告另一邊」這種漂移的來源。
struct LiqiActionResult {
  let spec: LiqiRequestSpec
  let outcome: LiqiToolSendOutcome
}

// MARK: - ExecuteJavaScriptAction

/// 在遊戲頁面執行一段 JavaScript。
///
/// ⚠️ 腳本是**函式體語意**：取值必須自己寫 `return`（見 `NakiWebSocketScript` 檔頭）。
@MainActor
struct ExecuteJavaScriptAction {

  private let run: (String) async throws -> Any?

  private init(run: @escaping (String) async throws -> Any?) {
    self.run = run
  }

  /// 真實實作：走這條 WebView path 自己的 JS 通道
  /// （WebPage 的 `callJavaScript` 或 WKWebView 的 `evaluateJavaScript`）。
  ///
  /// 兩條 path 先前各自把同一段橋接抄進 `debugServer.executeJavaScript` 的 closure 裡；
  /// 現在共用 view model 已經有的 `executeJavaScript(_:)`，抄寫消失。
  init(viewModel: any WebViewModelProtocol) {
    self.init(run: { [weak viewModel] script in
      guard let viewModel else {
        throw NakiActionError.notAvailable("JavaScript execution")
      }
      return try await viewModel.executeJavaScript(script)
    })
  }

  /// 沒有頁面可執行時的實作：一律 throw。
  ///
  /// 回 nil 是不行的——MCP 的 `execute_js` 靠這個錯誤把「頁面還沒接上」
  /// 跟「腳本回 null」分開。
  static let unavailable = ExecuteJavaScriptAction(run: { _ in
    throw NakiActionError.notAvailable("JavaScript execution")
  })

  #if DEBUG
    /// 測試／Preview 用的 stub。
    init(stub: @escaping (String) async throws -> Any?) {
      self.init(run: stub)
    }
  #endif

  func callAsFunction(_ script: String) async throws -> Any? {
    try await run(script)
  }
}

// MARK: - CaptureScreenshotAction

/// 把整個視窗（Naki 側欄 + 遊戲畫面）輸出成 PNG。
///
/// 走 AppKit 的 `cacheDisplay` 而不是 OS 層的 `screencapture`：後者需要「螢幕錄製」
/// 權限，而且抓的是螢幕上那塊區域——視窗被遮住、在其他 Space、或最小化就拍不到。
///
/// 也沒有再疊 `WebPage.exported(as: .image())`：實測 `cacheDisplay` 就抓得到
/// WKWebView 的內容，而合成本身反而製造瑕疵（web 影像 frame 與底圖對不齊），
/// 且 `exported` 在 macOS 回的是 TIFF 不是 PNG。
@MainActor
struct CaptureScreenshotAction {

  private let capture: () async -> Result<Data, Error>

  private init(capture: @escaping () async -> Result<Data, Error>) {
    self.capture = capture
  }

  /// 真實實作（平台分歧只在這一個型別裡；iOS 沒有 `NSApplication`）
  init() {
    self.init(capture: { Self.windowScreenshot() })
  }

  /// 沒有可截圖的視窗來源時的實作
  static let unavailable = CaptureScreenshotAction(capture: {
    .failure(NakiActionError.notAvailable("screenshot"))
  })

  #if DEBUG
    init(stub: @escaping () async -> Result<Data, Error>) {
      self.init(capture: stub)
    }
  #endif

  func callAsFunction() async -> Result<Data, Error> {
    await capture()
  }

  /// 整個視窗轉 PNG（原本是 `WebViewModel.windowScreenshot`）
  static func windowScreenshot() -> Result<Data, Error> {
    #if os(macOS)
      guard
        let window = NSApplication.shared.windows.first(where: {
          $0.isVisible && $0.contentView != nil
        }),
        let content = window.contentView,
        content.bounds.width > 0, content.bounds.height > 0,
        let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds)
      else {
        return .failure(NakiActionError.notAvailable("no visible window"))
      }
      content.cacheDisplay(in: content.bounds, to: rep)
      guard let png = rep.representation(using: .png, properties: [:]) else {
        return .failure(NakiActionError.notAvailable("png encoding"))
      }
      return .success(png)
    #else
      return .failure(NakiActionError.notAvailable("window screenshot (macOS only)"))
    #endif
  }
}

// MARK: - SendActionAction

/// 送出一筆 Liqi REQUEST，可選擇等待同 msgId 的 RESPONSE。
///
/// 這是 Unity 時代唯一有效的動作面：舊的 `window.naki.action.*` 依賴 Laya 物件，
/// Unity WebGL 客戶端不存在。真正的封包組裝與 `sendRaw` 在 `LiqiActionSender`；
/// 這一層只負責「把它變成可注入、可 stub 的一個呼叫」。
///
/// ⚠️ 送出成功只代表 WebSocket 接受了 bytes；真正成功要看同 msgId 的 RESPONSE
/// 或權威 action（見 CLAUDE.md）。
@MainActor
struct SendActionAction {

  private let send: (LiqiRequestSpec, Int) async -> LiqiToolSendOutcome

  private init(send: @escaping (LiqiRequestSpec, Int) async -> LiqiToolSendOutcome) {
    self.send = send
  }

  /// 真實實作
  init(sender: LiqiActionSender) {
    self.init(send: { [weak sender] spec, awaitMs in
      guard let sender else { return .unavailable("liqi_sender_deallocated") }
      return await sender.sendAwaitingResponse(spec, awaitResponseMs: awaitMs)
    })
  }

  /// 這條 path 不提供動作送出時的實作（例如尚未驗證的 Legacy 路徑）
  static func unavailable(_ reason: String) -> SendActionAction {
    SendActionAction(send: { _, _ in .unavailable(reason) })
  }

  #if DEBUG
    init(stub: @escaping (LiqiRequestSpec, Int) async -> LiqiToolSendOutcome) {
      self.init(send: stub)
    }
  #endif

  func callAsFunction(_ spec: LiqiRequestSpec, awaitResponseMs: Int) async -> LiqiToolSendOutcome {
    await send(spec, awaitResponseMs)
  }
}

// MARK: - StartMatchAction / CancelMatchAction

/// 段位場排隊（`.lq.Lobby.matchGame`）。
///
/// ⚠️ 真的會排進伺服器隊列，只在測試帳號使用。
@MainActor
struct StartMatchAction {

  private let perform: (UInt32, String, Int) async -> LiqiActionResult

  private init(perform: @escaping (UInt32, String, Int) async -> LiqiActionResult) {
    self.perform = perform
  }

  /// 真實實作：組 spec + 送出（spec 的欄位編號查 docs/protocol/liqi.json）
  init(send: SendActionAction) {
    self.init(perform: { matchMode, clientVersionString, awaitMs in
      let spec = LiqiRequestBuilder.matchGame(
        matchMode: matchMode, clientVersionString: clientVersionString)
      return LiqiActionResult(spec: spec, outcome: await send(spec, awaitResponseMs: awaitMs))
    })
  }

  #if DEBUG
    init(stub: @escaping (UInt32, String, Int) async -> LiqiActionResult) {
      self.init(perform: stub)
    }
  #endif

  func callAsFunction(
    matchMode: UInt32,
    clientVersionString: String = "",
    awaitResponseMs: Int
  ) async -> LiqiActionResult {
    await perform(matchMode, clientVersionString, awaitResponseMs)
  }
}

/// 取消段位場排隊（`.lq.Lobby.cancelMatch`）。
///
/// `match_mode` 是必填：伺服器要知道取消哪一條隊列。
@MainActor
struct CancelMatchAction {

  private let perform: (UInt32, Int) async -> LiqiActionResult

  private init(perform: @escaping (UInt32, Int) async -> LiqiActionResult) {
    self.perform = perform
  }

  /// 真實實作
  init(send: SendActionAction) {
    self.init(perform: { matchMode, awaitMs in
      let spec = LiqiRequestBuilder.cancelMatch(matchMode: matchMode)
      return LiqiActionResult(spec: spec, outcome: await send(spec, awaitResponseMs: awaitMs))
    })
  }

  #if DEBUG
    init(stub: @escaping (UInt32, Int) async -> LiqiActionResult) {
      self.init(perform: stub)
    }
  #endif

  func callAsFunction(matchMode: UInt32, awaitResponseMs: Int) async -> LiqiActionResult {
    await perform(matchMode, awaitResponseMs)
  }
}

// MARK: - TriggerAutoPlayAction

/// 手動要求自動打牌跑一輪（MCP `bot_trigger` / HTTP `POST /bot/trigger`）。
///
/// 只是「排進引擎的下一輪」，不自己送：三麻 fail-closed、無推薦、無 oplist
/// 三道閘門在 `AutoPlayEngine.runManualCycle` 裡。
@MainActor
struct TriggerAutoPlayAction {

  private let perform: () -> Void

  private init(perform: @escaping () -> Void) {
    self.perform = perform
  }

  /// 真實實作
  init(viewModel: any WebViewModelProtocol) {
    self.init(perform: { [weak viewModel] in viewModel?.triggerAutoPlayNow() })
  }

  /// 這條 path 不提供自動送出時的實作
  static let unavailable = TriggerAutoPlayAction(perform: {})

  #if DEBUG
    init(stub: @escaping () -> Void) {
      self.init(perform: stub)
    }
  #endif

  func callAsFunction() {
    perform()
  }
}

// MARK: - SetAntiIdleAction

/// 自動心跳（防閒置）開關。
///
/// Unity 下 `GameMgr.Inst.clientHeatBeat()` 不存在，改由 Swift 定期送
/// `.lq.Lobby.heatbeat`。`enabled == nil && intervalSeconds == nil` 表示只查狀態。
///
/// 回傳 nil = 這條 path 沒有心跳能力（MCP 工具據此回 `anti_idle_not_configured`，
/// 而不是回一份空狀態假裝成功）。
@MainActor
struct SetAntiIdleAction {

  private let perform: (Bool?, TimeInterval?) -> [String: Any]?

  private init(perform: @escaping (Bool?, TimeInterval?) -> [String: Any]?) {
    self.perform = perform
  }

  /// 真實實作
  init(sender: LiqiActionSender) {
    self.init(perform: { [weak sender] enabled, interval in
      guard let sender else { return nil }
      if enabled != nil || interval != nil {
        sender.setAntiIdle(
          enabled: enabled ?? sender.antiIdleEnabled, intervalSeconds: interval)
      }
      return sender.antiIdleStatus
    })
  }

  /// 沒有心跳能力
  static let unavailable = SetAntiIdleAction(perform: { _, _ in nil })

  #if DEBUG
    init(stub: @escaping (Bool?, TimeInterval?) -> [String: Any]?) {
      self.init(perform: stub)
    }
  #endif

  func callAsFunction(enabled: Bool?, intervalSeconds: TimeInterval?) -> [String: Any]? {
    perform(enabled, intervalSeconds)
  }
}

// MARK: - GameSnapshotAction

/// 目前登入帳號 id 的來源（由 `WebSocketMessageHandler` 從登入／authGame 回應解析）。
///
/// 抽成協定的唯一理由是**方向**：Action 層不該 import View 層去拿一個 Int，
/// 而 `WebSocketMessageHandler` 也不該知道有 MCP 這件事。
@MainActor
protocol NakiAccountIdSource: AnyObject {
  var majsoulAccountId: Int { get }
}

/// Swift 協定層的遊戲狀態快照（MCP 狀態類工具與 `/game/*` 的資料來源）。
///
/// ⚠️ 這是 **Naki 自己看到的狀態**，不是向伺服器查詢的結果。
@MainActor
struct GameSnapshotAction {

  private let build: () -> [String: Any]

  private init(build: @escaping () -> [String: Any]) {
    self.build = build
  }

  /// 真實實作：`GameStore`（局況／Bot／手牌／推薦／模式）
  /// + `LiqiOperationStore`（oplist）+ 登入帳號 id。
  ///
  /// - Parameter accountSource: nil 表示這條 path 拿不到 account id（回 0）
  init(store: GameStore, accountSource: (any NakiAccountIdSource)?) {
    self.init(build: { [weak accountSource] in
      NakiStatePayload.gameSnapshot(store: store, accountId: accountSource?.majsoulAccountId ?? 0)
    })
  }

  #if DEBUG
    init(stub: @escaping () -> [String: Any]) {
      self.init(build: stub)
    }
  #endif

  func callAsFunction() -> [String: Any] {
    build()
  }
}

// MARK: - ForceReconnectAction

/// 強制重連的結果。
///
/// 「關閉了幾條連線」是 p0-2 的重點：`WebPage.callJavaScript` 是函式體語意，
/// 腳本漏 `return` 會讓這個數字恆為 0——連線其實已經關掉，UI 卻說「沒有活躍的連接」。
enum ForceReconnectOutcome {
  /// 走 `__nakiWebSocket.forceReconnect()`，關閉了 n 條連線
  case closed(Int)
  /// 走整頁重載（Legacy path）
  case reloaded
  /// 沒做成
  case failed(String)

  var success: Bool {
    switch self {
    case .closed(let count): return count > 0
    case .reloaded: return true
    case .failed: return false
    }
  }

  /// 狀態列文字（兩條 path 與 UI 共用同一份措辭）
  var statusMessage: String {
    switch self {
    case .closed(let count):
      return count > 0 ? "已關閉 \(count) 個連接，等待重連..." : "沒有活躍的連接"
    case .reloaded:
      return "正在重新連接..."
    case .failed(let reason):
      return "重連失敗：\(reason)"
    }
  }

  /// MCP `bot_sync` 的輸出
  var dictionary: [String: Any] {
    switch self {
    case .closed(let count):
      return [
        "success": count > 0,
        "closedConnections": count,
        "message": count > 0
          ? "已關閉 \(count) 個連線，遊戲將自動重連並重建 Bot" : "沒有找到可關閉的連線",
      ]
    case .reloaded:
      return ["success": true, "closedConnections": 0, "message": "已重新載入頁面以重建連線"]
    case .failed(let reason):
      return ["success": false, "closedConnections": 0, "error": reason]
    }
  }
}

/// 強制斷線重連以重建 Bot 狀態。
///
/// p0-2 的 helper（`NakiWebSocketScript.forceReconnect` + `closedCount(from:)`）直接
/// 演化成這個型別：那兩個 static 解決的是「腳本字串只有一份」，但**呼叫它的三個地方**
/// （WebViewModel、MCP `bot_sync`、UI 按鈕）仍各自寫一次 do/catch 與結果解讀。
@MainActor
struct ForceReconnectAction {

  private let perform: () async -> ForceReconnectOutcome

  private init(perform: @escaping () async -> ForceReconnectOutcome) {
    self.perform = perform
  }

  /// 真實實作 A：JS 通道。關掉所有雀魂 WebSocket，伺服器會以 authGame + syncGame 重建。
  init(javaScript: ExecuteJavaScriptAction) {
    self.init(perform: {
      do {
        return .closed(NakiWebSocketScript.closedCount(
          from: try await javaScript(NakiWebSocketScript.forceReconnect)))
      } catch {
        return .failed(error.localizedDescription)
      }
    })
  }

  /// 真實實作 B：把「怎麼重連」交回 view model（UI 按鈕用）。
  ///
  /// 兩條 path 的重連手段不同（WebPage 走 JS 關連線，Legacy 走 `reload()`），
  /// UI 不該知道差別，也不該替某一條 path 選錯手段。
  init(viewModel: any WebViewModelProtocol) {
    self.init(perform: { [weak viewModel] in
      guard let viewModel else { return .failed("viewmodel_deallocated") }
      return await viewModel.forceReconnect()
    })
  }

  /// Preview／未接線
  static let unavailable = ForceReconnectAction(perform: { .failed("not_wired") })

  #if DEBUG
    init(stub: @escaping () async -> ForceReconnectOutcome) {
      self.init(perform: stub)
    }
  #endif

  @discardableResult
  func callAsFunction() async -> ForceReconnectOutcome {
    await perform()
  }
}

// MARK: - SetAutoPlayModeAction

/// 切換自動打牌模式。
///
/// 收斂（Legacy 不支援 `.auto`）與持久化都在 `AutoPlayAvailability.commit`，
/// 由 view model 的 `setAutoPlayMode` 呼叫——這裡不再抄第二份判斷，
/// 它存在的意義是讓 UI 與 Preview 有一個不需要 view model 的注入點。
@MainActor
struct SetAutoPlayModeAction {

  private let perform: (AutoPlayMode) -> Void

  private init(perform: @escaping (AutoPlayMode) -> Void) {
    self.perform = perform
  }

  /// 真實實作
  init(viewModel: any WebViewModelProtocol) {
    self.init(perform: { [weak viewModel] mode in viewModel?.setAutoPlayMode(mode) })
  }

  /// Preview／未接線：什麼都不做
  static let noop = SetAutoPlayModeAction(perform: { _ in })

  #if DEBUG
    init(stub: @escaping (AutoPlayMode) -> Void) {
      self.init(perform: stub)
    }
  #endif

  func callAsFunction(_ mode: AutoPlayMode) {
    perform(mode)
  }
}
