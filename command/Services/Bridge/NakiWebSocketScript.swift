//
//  NakiWebSocketScript.swift
//  Naki
//
//  Swift 呼叫頁面 API（`window.__naki*`）的 JS 片段集中處。
//
//  例外：`GameHighlightScript`（高亮 payload 的純函式）與 `NakiRuntime`／`PluginRegistry`
//  的插件腳本留在原處；`JSContractTests` 掃整個 `command/`，不論字串放在哪裡，
//  呼叫的方法都必須在注入的 JS 裡存在——JS 改名時 `?.` 會讓呼叫靜默變成 no-op。
//
//  `WebPage.callJavaScript` 與 `WKWebView.callAsyncJavaScript` 都是**函式體語意**
//  ——漏寫 `return` 不會報錯，只會恆回 nil。forceReconnect 少了 `return`，
//  `closedCount` 就恆為 0：連線其實已經關掉了，UI 卻永遠顯示「沒有活躍的連接」。
//
//  字串集中在這裡，就不會出現「兩種寫法、其中一種漏 return」的分岔。
//

import Foundation

/// Naki 注入的頁面模組（`command/Resources/JavaScript/naki-*.js`）對應的 JS 片段。
///
/// 這些字串一律以 **function body** 的形式撰寫（必須自帶 `return`），
/// 因為所有呼叫端（WebPage / WKWebView / MCP `execute_js` / DebugServer `/js`）都是函式體語意。
enum NakiWebSocketScript {

  /// 強制關閉所有雀魂 WebSocket 連線，觸發遊戲自動重連。
  ///
  /// 回傳值是被關閉的連線數（JS number）。模組尚未注入時 `?.` 會短路成 undefined，
  /// `|| 0` 讓結果收斂成 0 而不是 undefined。
  static let forceReconnect = "return window.__nakiWebSocket?.forceReconnect() || 0"

  /// 把一筆已編碼的 Liqi REQUEST（base64）丟進第一條 OPEN 的雀魂 WebSocket。
  ///
  /// base64 只含 `A-Za-z0-9+/=`，可安全放進單引號字串。
  /// 模組缺席時回短碼：直接呼叫會丟 TypeError，到 Swift 變成 `js_error: <自由文字>`。
  static func sendRaw(base64: String) -> String {
    "return JSON.stringify(window.__nakiWebSocket && window.__nakiWebSocket.sendRaw"
      + " ? window.__nakiWebSocket.sendRaw('\(base64)') : {success: false, reason: 'no_websocket_module'})"
  }

  /// 更新唯讀推薦通道並通知插件（插件 hook 見 `naki-plugins.js` 的 `recommendationsChanged`）。
  static func publishRecommendations(json: String, contextJSON: String) -> String {
    """
    window.__nakiRecommendations = \(json);
    window.__nakiRecommendationContext = \(contextJSON);
    if (window.__nakiPlugins && window.__nakiPlugins.recommendationsChanged) {
      window.__nakiPlugins.recommendationsChanged(window.__nakiRecommendations, window.__nakiRecommendationContext);
    }
    """
  }

  /// 背景保活開關（`naki-core.js` 的 `__nakiKeepAlive`）。
  static func setKeepAlive(_ enabled: Bool) -> String {
    "window.__nakiKeepAlive?.set(\(enabled)); return null;"
  }

  /// 喚醒被系統暫停的 WebContent，回傳頁面是否隱藏。
  static let keepAliveTick = "return window.__nakiKeepAlive ? window.__nakiKeepAlive.tick() : false"

  /// 把 `sendRaw` 的 JS 回傳值解析成送出結果。
  ///
  /// JS 端回 `{success:true, bytes, socketId}` 或 `{success:false, reason}`，
  /// 經 `JSON.stringify` 過橋。這份解析全專案只有一份：分兩份的代價是
  /// 「JS 回報的失敗原因有沒有被保留」這種細節可以在其中一份悄悄失傳。
  ///
  /// 失敗時的 detail 一律是可辨識的短碼，不是自由文字——它會被寫進 log 供事後對照。
  static func sendResult(from result: Any?) -> LiqiRawSendResult {
    guard let json = result as? String,
      let data = json.data(using: .utf8),
      let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return .failure("unparsable_js_result")
    }

    if dict["success"] as? Bool == true {
      let bytes = dict["bytes"] as? Int ?? -1
      let socketId = dict["socketId"].map { "\($0)" } ?? "?"
      return LiqiRawSendResult(success: true, detail: "socket=\(socketId) bytes=\(bytes)")
    }
    return .failure(dict["reason"] as? String ?? "unknown_reason")
  }

  /// Double 能精確表示整數的上限（2^53）；絕對值達此上限的輸入視為不可信，回 0。
  private static let exactIntegerLimit = 9_007_199_254_740_992.0

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
      guard value.isFinite, abs(value) < exactIntegerLimit else { return 0 }
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
