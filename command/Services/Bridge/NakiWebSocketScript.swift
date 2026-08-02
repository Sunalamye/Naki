//
//  NakiWebSocketScript.swift
//  Naki
//
//  `window.__nakiWebSocket` 這一層 JS 片段的唯一來源。
//
//  由來（AUDIT P0-2）：`WebPage.callJavaScript` 與 `WKWebView.callAsyncJavaScript`
//  都是**函式體語意**——沒寫 `return` 就恆回 nil。同一段 forceReconnect 腳本在專案裡
//  被抄了三份，其中 `WebViewModel` 那份漏了 `return`，於是 `closedCount` 恆為 0：
//  連線其實已經關掉了，UI 卻永遠顯示「沒有活躍的連接」。
//
//  字串集中在這裡，就不會再出現「兩種寫法、其中一種漏 return」的分岔。
//

import Foundation

/// Naki 注入的 WebSocket 模組（`command/Resources/JavaScript/naki-websocket.js`）對應的 JS 片段。
///
/// 這些字串一律以 **function body** 的形式撰寫（必須自帶 `return`），
/// 因為所有呼叫端（WebPage / WKWebView / MCP `execute_js` / DebugServer `/js`）都是函式體語意。
enum NakiWebSocketScript {

  /// 強制關閉所有雀魂 WebSocket 連線，觸發遊戲自動重連。
  ///
  /// 回傳值是被關閉的連線數（JS number）。模組尚未注入時 `?.` 會短路成 undefined，
  /// `|| 0` 讓結果收斂成 0 而不是 undefined。
  static let forceReconnect = "return window.__nakiWebSocket?.forceReconnect() || 0"

  /// 把 `forceReconnect` 的 JS 回傳值轉成關閉數。
  ///
  /// JS number 過橋後可能是 `Int`、`Double` 或 `NSNumber`（依 WebPage / WKWebView 而異），
  /// 直接 `as? Int` 在部分路徑上會失敗並靜默變成 0——那正是「已關閉卻顯示 0」的第二種成因。
  static func closedCount(from result: Any?) -> Int {
    switch result {
    case let value as Int:
      return value
    case let value as Double:
      // NaN／Inf／超出 Int 範圍的值直接 Int(...) 會 trap，一律當作 0
      guard value.isFinite, value > -9_007_199_254_740_992, value < 9_007_199_254_740_992 else {
        return 0
      }
      return Int(value)
    case let value as NSNumber:
      return value.intValue
    case let value as String:
      return Int(value) ?? 0
    default:
      return 0
    }
  }
}
