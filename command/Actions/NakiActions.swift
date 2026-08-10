//
//  NakiActions.swift
//  Naki
//
//  副作用的型別化入口（Action 層）
//
//  Naki 的副作用（送 Liqi、重連、截圖、改模式、執行 JS）一律包成 Action：
//  `@MainActor struct` + `callAsFunction` + 一個真實 init（吃 service）
//  + 一個 `#if DEBUG` 的 stub init（吃 closure）。closure 只存在於型別內部一個
//  private 欄位，**不是跨層傳遞的貨幣**。
//
//  換回裸 closure 逐層注入會同時失去三件事：
//
//  1. **依賴出現在型別上。** 一串 `var x: ((A) -> B)?` 會讓 `DebugServer` 的欄位
//     長得像 HTTP server 的設定，實際上是整個 MCP 工具層的依賴表；漏接一個就是
//     執行期的 `xxx_callback_not_configured`，編譯期一句話都不會說。
//  2. **測試有 stub 點。** 否則要測「送出失敗時 MCP 回什麼」得先有真的頁面
//     ＋真的 HTTP server。
//  3. **Preview 拉得起來。** View 呼叫的是 Action 本身而不是某個可為 nil 的物件，
//     沒接線時仍有按鈕行為可看，不是只剩靜態畫面。
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

  private nonisolated(unsafe) let run: (String) async throws -> Any?

  private init(run: @escaping (String) async throws -> Any?) {
    self.run = run
  }

  /// 真實實作：走 `WebSession` 的 JS 通道。
  ///
  /// 函式體語意（要值就寫 `return`）由 session 統一，平台差異（WebPage 的
  /// `callJavaScript` vs WKWebView 的 IIFE 包裝）在 `WebSessionBackend` 內部。
  /// 兩條 path 共用這一份，不各自把同一段橋接抄一次。
  init(session: WebSession) {
    self.init(run: { [weak session] script in
      guard let session else {
        throw NakiActionError.notAvailable("JavaScript execution")
      }
      return try await session.callJavaScript(script)
    })
  }

  /// 真實實作：直接對某個 backend（backend 自己要跑 JS 時用，例如 forceReconnect）
  init(backend: any WebSessionBackend) {
    self.init(run: { [weak backend] script in
      guard let backend else {
        throw NakiActionError.notAvailable("JavaScript execution")
      }
      return try await backend.callJavaScript(script)
    })
  }

  /// 沒有頁面可執行時的實作：一律 throw。
  ///
  /// 回 nil 是不行的——MCP 的 `execute_js` 靠這個錯誤把「頁面還沒接上」
  /// 跟「腳本回 null」分開。
  static let unavailable = ExecuteJavaScriptAction()

  /// Preview／未接線的預設值。
  ///
  /// `nonisolated` 的理由是 `@Entry`：`NakiEnvironment` 的預設值在 `EnvironmentKey`
  /// 的 **nonisolated** `defaultValue` 裡求值，那裡叫不動 `@MainActor` 的 init。
  /// 直接寫進 stored property（而不是轉呼叫私有 init）也是同一個原因。
  nonisolated init() {
    self.run = { _ in throw NakiActionError.notAvailable("JavaScript execution") }
  }

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

  /// 視窗內容轉 PNG。**有 sheet 時截 sheet。**
  ///
  /// 先前 `windows.first` 多半挑中主視窗，所以進階設定（attached sheet，屬於
  /// 另一個 `NSWindow`）怎麼截都是它後面的遊戲畫面——設定頁等於無法用這支 API 驗。
  /// 改成「有 sheet 就截 sheet」：那才是使用者當下在看的東西。
  ///
  /// **已知限制：截不到 toolbar。** `contentView` 不含 titlebar／toolbar 區域，而模式
  /// 切換、延遲 stepper、MCP／連線指示與雲端開關全在那裡。試過的兩條路都不行：
  ///
  /// - 改截 theme frame（`contentView.superview`）：位置有了，但 `cacheDisplay`
  ///   畫不出 NSToolbar 裡的 SwiftUI hosting view，整排控制項變成白色空塊——
  ///   那比缺一塊更糟，看起來像 UI 壞了。
  /// - `CGWindowListCreateImage`：macOS 26 SDK 已標記 unavailable，替代的
  ///   ScreenCaptureKit 需要螢幕錄製授權；為了截自己的視窗要求那個權限不成比例。
  ///
  /// **第二個限制：SwiftUI 的部分內容 `cacheDisplay` 畫不出來。** 截設定 sheet 時
  /// TextField、按鈕與警示文字有出來，但 GroupBox 背景與多數標籤是空白的。
  /// 同一個成因（AppKit 的離屏快取拿不到 SwiftUI 的託管層），只是 toolbar 剛好整排都中。
  /// 所以這支 API 對**遊戲畫面與決策側欄**是可靠的（那是一般的 SwiftUI 內容區），
  /// 對 sheet 只能當粗略參考，對 toolbar 無效。
  ///
  /// **不要繞道 `screencapture` 用螢幕座標補**：那會拍到視窗以外的東西
  /// （實測就截到了同座標上的另一個 App），而且視窗一移動座標就失效。
  static func windowScreenshot() -> Result<Data, Error> {
    #if os(macOS)
      let app = NSApplication.shared
      let base =
        app.mainWindow
        ?? app.keyWindow
        ?? app.windows.first(where: { $0.isVisible && $0.contentView != nil })
      guard let target = base?.attachedSheet ?? base else {
        return .failure(NakiActionError.notAvailable("no visible window"))
      }
      guard
        let view = target.contentView,
        view.bounds.width > 0, view.bounds.height > 0,
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
      else {
        return .failure(NakiActionError.notAvailable("no drawable window content"))
      }
      view.cacheDisplay(in: view.bounds, to: rep)
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

// MARK: - StartUnifiedMatchAction / CancelUnifiedMatchAction

/// 統一匹配排隊（`.lq.Lobby.startUnifiedMatch`）——**現行**的段位場入口。
///
/// ⚠️ 真的會排進伺服器隊列，只在測試帳號使用。
///
/// `matchSid` 是字串且沒有靜態表；值要從 `ObservedMatchSids`（攔客戶端流量）取得。
@MainActor
struct StartUnifiedMatchAction {

  private let perform: (String, String, Int) async -> LiqiActionResult

  private init(perform: @escaping (String, String, Int) async -> LiqiActionResult) {
    self.perform = perform
  }

  /// 真實實作：組 spec + 送出（欄位編號查 docs/protocol/liqi.json 的 ReqStartUnifiedMatch）
  init(send: SendActionAction) {
    self.init(perform: { matchSid, clientVersionString, awaitMs in
      let spec = LiqiRequestBuilder.startUnifiedMatch(
        matchSid: matchSid, clientVersionString: clientVersionString)
      return LiqiActionResult(spec: spec, outcome: await send(spec, awaitResponseMs: awaitMs))
    })
  }

  #if DEBUG
    init(stub: @escaping (String, String, Int) async -> LiqiActionResult) {
      self.init(perform: stub)
    }
  #endif

  func callAsFunction(
    matchSid: String,
    clientVersionString: String = "",
    awaitResponseMs: Int
  ) async -> LiqiActionResult {
    await perform(matchSid, clientVersionString, awaitResponseMs)
  }
}

/// 取消統一匹配（`.lq.Lobby.cancelUnifiedMatch`）。
///
/// `match_sid` 必填：伺服器要知道取消哪一條隊列（與 `cancelMatch` 同樣語意）。
@MainActor
struct CancelUnifiedMatchAction {

  private let perform: (String, Int) async -> LiqiActionResult

  private init(perform: @escaping (String, Int) async -> LiqiActionResult) {
    self.perform = perform
  }

  /// 真實實作
  init(send: SendActionAction) {
    self.init(perform: { matchSid, awaitMs in
      let spec = LiqiRequestBuilder.cancelUnifiedMatch(matchSid: matchSid)
      return LiqiActionResult(spec: spec, outcome: await send(spec, awaitResponseMs: awaitMs))
    })
  }

  #if DEBUG
    init(stub: @escaping (String, Int) async -> LiqiActionResult) {
      self.init(perform: stub)
    }
  #endif

  func callAsFunction(matchSid: String, awaitResponseMs: Int) async -> LiqiActionResult {
    await perform(matchSid, awaitResponseMs)
  }
}

// MARK: - TriggerAutoPlayAction

/// 手動要求自動打牌跑一輪（MCP `bot_trigger` / HTTP `POST /bot/trigger`）。
///
/// 只是「排進引擎的下一輪」，不自己送：三麻 fail-closed、無推薦、無 oplist
/// 三道閘門在 `AutoPlayEngine.runManualCycle` 裡。
@MainActor
struct TriggerAutoPlayAction {

  private nonisolated(unsafe) let perform: () -> Void

  private init(perform: @escaping () -> Void) {
    self.perform = perform
  }

  /// 真實實作
  init(runtime: NakiRuntime) {
    self.init(perform: { [weak runtime] in runtime?.triggerAutoPlayNow() })
  }

  /// 這條 path 不提供自動送出時的實作
  static let unavailable = TriggerAutoPlayAction()

  /// Preview／未接線的預設值；`nonisolated` 的理由見 `ExecuteJavaScriptAction.init()`。
  nonisolated init() {
    self.perform = {}
  }

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
/// 「關閉了幾條連線」要小心：`WebPage.callJavaScript` 是函式體語意，
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
/// 腳本字串（`NakiWebSocketScript.forceReconnect`）與回傳值解讀（`closedCount(from:)`）
/// 各只有一份還不夠：呼叫它的每個地方（MCP `bot_sync`、UI 按鈕）都得走這個型別，
/// 否則 do/catch 與結果解讀又會變成各寫一次、各自漂移。
@MainActor
struct ForceReconnectAction {

  private nonisolated(unsafe) let perform: () async -> ForceReconnectOutcome

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

  /// 真實實作 B：把「怎麼重連」交回 `WebSession`（UI 按鈕與 MCP `bot_sync` 用）。
  ///
  /// 兩條 path 的重連手段不同（WebPage 走 JS 關連線，Legacy 走 `reload()`），
  /// 呼叫端不該知道差別，也不該替某一條 path 選錯手段。
  init(session: WebSession) {
    self.init(perform: { [weak session] in
      guard let session else { return .failed("web_session_deallocated") }
      return await session.forceReconnect()
    })
  }

  /// Preview／未接線
  static let unavailable = ForceReconnectAction()

  /// Preview／未接線的預設值；`nonisolated` 的理由見 `ExecuteJavaScriptAction.init()`。
  nonisolated init() {
    self.perform = { .failed("not_wired") }
  }

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
/// 由 `NakiRuntime.setAutoPlayMode` 呼叫——這裡不再抄第二份判斷，
/// 它存在的意義是讓 UI 與 Preview 有一個不需要整個 runtime 的注入點。
@MainActor
struct SetAutoPlayModeAction {

  private nonisolated(unsafe) let perform: (AutoPlayMode) -> Void

  private init(perform: @escaping (AutoPlayMode) -> Void) {
    self.perform = perform
  }

  /// 真實實作
  init(runtime: NakiRuntime) {
    self.init(perform: { [weak runtime] mode in runtime?.setAutoPlayMode(mode) })
  }

  /// Preview／未接線：什麼都不做
  static let noop = SetAutoPlayModeAction()

  /// Preview／未接線的預設值；`nonisolated` 的理由見 `ExecuteJavaScriptAction.init()`。
  nonisolated init() {
    self.perform = { _ in }
  }

  #if DEBUG
    init(stub: @escaping (AutoPlayMode) -> Void) {
      self.init(perform: stub)
    }
  #endif

  func callAsFunction(_ mode: AutoPlayMode) {
    perform(mode)
  }
}

// MARK: - StartFullAutoNowAction

/// 在大廳按下「開始」時立刻排一場，不等 `end_game`。
///
/// 為什麼需要它：續局引擎是由 `end_game` 驅動的，而**在大廳切到全自動時根本沒有
/// `end_game` 可等**——不補這條，使用者按了「開始」會什麼都不發生，
/// 得自己先手動開一局才會進入循環。
///
/// 對局中按下去也安全：權威在伺服器，已經在對局中時 `startUnifiedMatch` 會被拒，
/// 引擎照樣會在這局的 `end_game` 正常續局。這裡不自己判斷「在不在對局中」——
/// `GameStore.inGame` 對局結束後不會歸位（AUDIT §16.4），拿它判斷會卡死。
@MainActor
struct StartFullAutoNowAction {

  private nonisolated(unsafe) let perform: () -> Void

  private init(perform: @escaping () -> Void) {
    self.perform = perform
  }

  /// 真實實作
  init(runtime: NakiRuntime) {
    self.init(perform: { [weak runtime] in runtime?.startFullAutoNow() })
  }

  /// Preview／未接線：什麼都不做
  static let noop = StartFullAutoNowAction()

  nonisolated init() {
    self.perform = {}
  }

  #if DEBUG
    init(stub: @escaping () -> Void) {
      self.init(perform: stub)
    }
  #endif

  func callAsFunction() {
    perform()
  }
}

// MARK: - DeleteBotAction

/// 刪除原生 Bot（進階設定的「刪除 Bot」按鈕）。
///
/// 只清 Bot 與屬於這一局的資料；`gameState` 刻意保留（座位來源，
/// 見 `GameStore.clearAfterBotDeleted`）。
@MainActor
struct DeleteBotAction {

  private nonisolated(unsafe) let perform: () -> Void

  private init(perform: @escaping () -> Void) {
    self.perform = perform
  }

  /// 真實實作：bot 的擁有者是 coordinator
  init(coordinator: NakiWebCoordinator) {
    self.init(perform: { [weak coordinator] in coordinator?.deleteBot() })
  }

  /// Preview／未接線
  static let noop = DeleteBotAction()

  /// Preview／未接線的預設值；`nonisolated` 的理由見 `ExecuteJavaScriptAction.init()`。
  nonisolated init() {
    self.perform = {}
  }

  #if DEBUG
    init(stub: @escaping () -> Void) {
      self.init(perform: stub)
    }
  #endif

  func callAsFunction() {
    perform()
  }
}

// MARK: - ToggleDebugServerAction

/// 啟動／停止 MCP Server（工具列指示燈與進階設定共用）。
@MainActor
struct ToggleDebugServerAction {

  private nonisolated(unsafe) let perform: () -> Void

  private init(perform: @escaping () -> Void) {
    self.perform = perform
  }

  /// 真實實作
  init(runtime: NakiRuntime) {
    self.init(perform: { [weak runtime] in runtime?.toggleDebugServer() })
  }

  /// Preview／未接線
  static let noop = ToggleDebugServerAction()

  /// Preview／未接線的預設值；`nonisolated` 的理由見 `ExecuteJavaScriptAction.init()`。
  nonisolated init() {
    self.perform = {}
  }

  #if DEBUG
    init(stub: @escaping () -> Void) {
      self.init(perform: stub)
    }
  #endif

  func callAsFunction() {
    perform()
  }
}

// MARK: - ReloadPageAction

/// 重新載入雀魂頁面（工具列的重新載入鈕）。
///
/// ⚠️ 與 `ForceReconnectAction` 不同：這是整頁重載，會丟掉目前的 WebSocket 與
/// 頁面狀態；重建 Bot 請用重連。
@MainActor
struct ReloadPageAction {

  private nonisolated(unsafe) let perform: () -> Void

  private init(perform: @escaping () -> Void) {
    self.perform = perform
  }

  /// 真實實作
  init(session: WebSession) {
    self.init(perform: { [weak session] in session?.reload() })
  }

  /// Preview／未接線
  static let noop = ReloadPageAction()

  /// Preview／未接線的預設值；`nonisolated` 的理由見 `ExecuteJavaScriptAction.init()`。
  nonisolated init() {
    self.perform = {}
  }

  #if DEBUG
    init(stub: @escaping () -> Void) {
      self.init(perform: stub)
    }
  #endif

  func callAsFunction() { perform() }
}

// MARK: - 切換雀魂區服

/// 換到另一個區服並重新載入頁面。
///
/// 與 `ReloadPageAction` 分開而不是加參數：那個是「重載目前這一頁」，這個會**換掉
/// URL**。各服帳號不互通，所以切換等於登出重來——把它做成兩個不同的動作，
/// 呼叫端就不會不小心把「重新載入」寫成換服。
@MainActor
struct SwitchServerAction {

  private nonisolated(unsafe) let perform: (MajsoulServer) -> Void

  private init(perform: @escaping (MajsoulServer) -> Void) {
    self.perform = perform
  }

  /// 真實實作
  init(session: WebSession) {
    self.init(perform: { [weak session] server in session?.switchServer(to: server) })
  }

  /// Preview／未接線
  static let noop = SwitchServerAction()

  nonisolated init() {
    self.perform = { _ in }
  }

  #if DEBUG
    init(stub: @escaping (MajsoulServer) -> Void) {
      self.init(perform: stub)
    }
  #endif

  func callAsFunction(_ server: MajsoulServer) {
    perform(server)
  }
}

// MARK: - SetHidePlayerNamesAction

/// 隱藏玩家名稱開關（設定 Toggle）。
///
/// 持久化寫進 `SettingsStore`，推送走 `naki-websocket.js` 的 `__nakiHideNames`；
/// 兩件事都在 `WebSession.setHidePlayerNames` 一處。
@MainActor
struct SetHidePlayerNamesAction {

  private nonisolated(unsafe) let perform: (Bool) -> Void

  private init(perform: @escaping (Bool) -> Void) {
    self.perform = perform
  }

  /// 真實實作
  init(session: WebSession) {
    self.init(perform: { [weak session] hide in session?.setHidePlayerNames(hide) })
  }

  /// Preview／未接線
  static let noop = SetHidePlayerNamesAction()

  /// Preview／未接線的預設值；`nonisolated` 的理由見 `ExecuteJavaScriptAction.init()`。
  nonisolated init() {
    self.perform = { _ in }
  }

  #if DEBUG
    init(stub: @escaping (Bool) -> Void) {
      self.init(perform: stub)
    }
  #endif

  func callAsFunction(_ hide: Bool) {
    perform(hide)
  }
}

// MARK: - WebViewAction

/// 交出這條 path 對應的 WebView。
///
/// View 因此不需要知道有 WebPage 與 WKWebView 兩種實作，也不需要 `as?` 撈具體型別——
/// 那個轉型一失敗就只剩一個永遠轉圈的 `ProgressView`，沒有任何錯誤訊息。
@MainActor
struct WebViewAction {

  private nonisolated(unsafe) let build: () -> AnyView

  private init(build: @escaping () -> AnyView) {
    self.build = build
  }

  /// 真實實作
  init(session: WebSession) {
    self.init(build: { [weak session] in
      session?.makeView() ?? AnyView(ProgressView("正在初始化..."))
    })
  }

  /// Preview／未接線：不建立任何 WebView（Preview 不該真的連上雀魂）
  static let placeholder = WebViewAction()

  /// Preview／未接線的預設值；`nonisolated` 的理由見 `ExecuteJavaScriptAction.init()`。
  nonisolated init() {
    self.build = { AnyView(ProgressView("正在初始化...")) }
  }

  #if DEBUG
    init(stub: @escaping () -> AnyView) {
      self.init(build: stub)
    }
  #endif

  func callAsFunction() -> AnyView {
    build()
  }
}

// MARK: - Action 集合

/// View 層可用的副作用全集（`NakiEnvironment.actions`）。
///
/// 為什麼是一個 struct 而不是讓 View 各自 `@Environment` 拿：這些動作要嘛全部
/// 來自同一個 runtime，要嘛全部是 Preview 的空實作。分開注入的話會出現
/// 「一半接線、一半沒接」這種只在執行期才看得出來的半殘狀態。
///
/// 預設值全部無副作用，**只給 Preview**（見 `NakiEnvironment`）。
@MainActor
struct NakiActions {

  /// 在遊戲頁面執行 JS（函式體語意）
  var executeJavaScript: ExecuteJavaScriptAction
  /// 熱插拔：開關插件（免 reload；持久化 + 對當前頁面注入 enable/disable）
  var setPluginEnabled: SetPluginEnabledAction
  /// 重掃插件目錄（URL 匯入落地後刷新清單）
  var rescanPlugins: RescanPluginsAction
  /// 移除插件（刪目錄 + 熱停用 + 重掃）
  var removePlugin: RemovePluginAction
  /// 強制斷線重連以重建 Bot
  var forceReconnect: ForceReconnectAction
  /// 切換自動打牌模式
  var setAutoPlayMode: SetAutoPlayModeAction
  /// 全自動：立刻排一場（大廳按「開始」時用，不等 end_game）
  var startFullAutoNow: StartFullAutoNowAction
  /// 手動要求自動打牌跑一輪
  var triggerAutoPlay: TriggerAutoPlayAction
  /// 刪除原生 Bot
  var deleteBot: DeleteBotAction
  /// 啟動／停止 MCP Server
  var toggleDebugServer: ToggleDebugServerAction
  /// 重新載入雀魂頁面
  var reloadPage: ReloadPageAction
  /// 換到另一個區服（換 URL，不是重載）
  var switchServer: SwitchServerAction
  /// 隱藏玩家名稱開關
  var setHidePlayerNames: SetHidePlayerNamesAction
  /// 交出這條 path 的 WebView
  var webView: WebViewAction

  /// Preview／未接線：全部無副作用。
  ///
  /// 沒有預設引數（而是一個獨立的 `nonisolated init()`）的理由：Swift 5 語言模式下
  /// **預設引數運算式在 nonisolated 上下文求值**，碰不到 `@MainActor` 的 static，
  /// 而 `@Entry` 的 `defaultValue` 正是那種上下文。
  nonisolated init() {
    self.executeJavaScript = ExecuteJavaScriptAction()
    self.setPluginEnabled = SetPluginEnabledAction()
    self.rescanPlugins = RescanPluginsAction()
    self.removePlugin = RemovePluginAction()
    self.forceReconnect = ForceReconnectAction()
    self.setAutoPlayMode = SetAutoPlayModeAction()
    self.startFullAutoNow = StartFullAutoNowAction()
    self.triggerAutoPlay = TriggerAutoPlayAction()
    self.deleteBot = DeleteBotAction()
    self.toggleDebugServer = ToggleDebugServerAction()
    self.reloadPage = ReloadPageAction()
    self.switchServer = SwitchServerAction()
    self.setHidePlayerNames = SetHidePlayerNamesAction()
    self.webView = WebViewAction()
  }

  /// 正式路徑：由 `NakiRuntime` 一次組好（十個全部明講，漏一個編譯期就不過）
  init(executeJavaScript: ExecuteJavaScriptAction,
       setPluginEnabled: SetPluginEnabledAction,
       rescanPlugins: RescanPluginsAction,
       removePlugin: RemovePluginAction,
       forceReconnect: ForceReconnectAction,
       setAutoPlayMode: SetAutoPlayModeAction,
       startFullAutoNow: StartFullAutoNowAction,
       triggerAutoPlay: TriggerAutoPlayAction,
       deleteBot: DeleteBotAction,
       toggleDebugServer: ToggleDebugServerAction,
       reloadPage: ReloadPageAction,
       switchServer: SwitchServerAction,
       setHidePlayerNames: SetHidePlayerNamesAction,
       webView: WebViewAction) {
    self.executeJavaScript = executeJavaScript
    self.setPluginEnabled = setPluginEnabled
    self.rescanPlugins = rescanPlugins
    self.removePlugin = removePlugin
    self.forceReconnect = forceReconnect
    self.setAutoPlayMode = setAutoPlayMode
    self.startFullAutoNow = startFullAutoNow
    self.triggerAutoPlay = triggerAutoPlay
    self.deleteBot = deleteBot
    self.toggleDebugServer = toggleDebugServer
    self.reloadPage = reloadPage
    self.switchServer = switchServer
    self.setHidePlayerNames = setHidePlayerNames
    self.webView = webView
  }
}

// MARK: - 熱插拔插件開關

/// 開關插件（免 reload）。真實實作把工作交給 `NakiRuntime.setPluginEnabled`：
/// 持久化到 `enabledPluginIds` + 對當前頁面注入 enable/disable JS。
struct SetPluginEnabledAction {

  private nonisolated(unsafe) let perform: (String, Bool) -> Void

  private init(perform: @escaping (String, Bool) -> Void) {
    self.perform = perform
  }

  /// 真實實作
  init(runtime: NakiRuntime) {
    self.init(perform: { [weak runtime] id, enabled in
      runtime?.setPluginEnabled(id: id, enabled: enabled)
    })
  }

  /// Preview／未接線
  static let noop = SetPluginEnabledAction()

  /// Preview／未接線的預設值；`nonisolated` 的理由見 `ExecuteJavaScriptAction.init()`。
  nonisolated init() {
    self.perform = { _, _ in }
  }

  #if DEBUG
    init(stub: @escaping (String, Bool) -> Void) {
      self.init(perform: stub)
    }
  #endif

  func callAsFunction(_ id: String, _ enabled: Bool) {
    perform(id, enabled)
  }
}

// MARK: - 重掃插件

/// 重掃插件目錄（URL 匯入落地後刷新 `pluginDescriptors`）。
struct RescanPluginsAction {

  private nonisolated(unsafe) let perform: () -> Void

  private init(perform: @escaping () -> Void) {
    self.perform = perform
  }

  init(runtime: NakiRuntime) {
    self.init(perform: { [weak runtime] in runtime?.rescanPlugins() })
  }

  static let noop = RescanPluginsAction()
  nonisolated init() { self.perform = { } }

  #if DEBUG
    init(stub: @escaping () -> Void) { self.init(perform: stub) }
  #endif

  func callAsFunction() { perform() }
}

// MARK: - 移除插件

/// 移除插件（刪目錄 + 熱停用 + 重掃）。destructive 但可逆。
struct RemovePluginAction {

  private nonisolated(unsafe) let perform: (String) -> Void

  private init(perform: @escaping (String) -> Void) {
    self.perform = perform
  }

  init(runtime: NakiRuntime) {
    self.init(perform: { [weak runtime] id in runtime?.removePlugin(id: id) })
  }

  static let noop = RemovePluginAction()
  nonisolated init() { self.perform = { _ in } }

  #if DEBUG
    init(stub: @escaping (String) -> Void) { self.init(perform: stub) }
  #endif

  func callAsFunction(_ id: String) { perform(id) }
}
