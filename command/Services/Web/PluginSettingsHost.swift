//
//  PluginSettingsHost.swift
//  Naki
//
//  插件自帶設定頁（manifest `settingsUI`）的宿主。設計見 docs/archive/plan/plugin-v2.md §A。
//
//  設定頁跑在 Naki 自己的 WKWebView：獨立 configuration、非持久 data store、不注入任何 Naki
//  模組，與遊戲頁不共用 realm。頁面只拿到 `window.naki.get/set`，值仍存在 SettingsStore
//  （`plugin.<id>.<key>`），只接受 `settings` schema 宣告過的 key 與型別。
//
//  用 WKWebView 而非 WebPage：iOS target 是 17，WebPage 要 26；WKScriptMessageHandlerWithReply
//  兩個平台都有，一條路徑就好。
//

import SwiftUI
import WebKit

nonisolated enum PluginSettingsBridge {
    static let handlerName = "nakiSettings"

    static let shim = """
    window.naki = Object.freeze({
      get: function (key) { return window.webkit.messageHandlers.nakiSettings.postMessage({ op: 'get', key: key }); },
      set: function (key, value) { return window.webkit.messageHandlers.nakiSettings.postMessage({ op: 'set', key: key, value: value }); }
    });
    """

    /// `{op:'get', key?}` 回該 key（省略 key 回全部）的值：使用者覆寫 ?? default；
    /// `{op:'set', key, value}` 驗 key 與型別後寫入並回 true。第二個值非 nil ⇒ JS 端 Promise reject。
    static func reply(to body: Any, schema: [String: PluginSettingField],
                      read: (String) -> Any?, write: (String, Any) -> Void) -> (Any?, String?) {
        guard let message = body as? [String: Any], let op = message["op"] as? String else {
            return (nil, "bad_message")
        }
        let key = message["key"] as? String
        func current(_ key: String, _ field: PluginSettingField) -> Any {
            field.accept(read(key)) ?? field.defaultValue.jsonValue
        }
        switch op {
        case "get" where key == nil:
            return (schema.reduce(into: [String: Any]()) { $0[$1.key] = current($1.key, $1.value) }, nil)
        case "get":
            guard let key, let field = schema[key] else { return (nil, "unknown_key") }
            return (current(key, field), nil)
        case "set":
            guard let key, let field = schema[key] else { return (nil, "unknown_key") }
            guard let value = field.accept(message["value"]) else { return (nil, "type_mismatch") }
            write(key, value)
            return (true, nil)
        default:
            return (nil, "unknown_op")
        }
    }
}

struct PluginSettingsWebView {
    let pageURL: URL
    let directory: URL
    let handle: (Any) -> (Any?, String?)

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func makeWebView(pageURL: URL, directory: URL, coordinator: Coordinator) -> WKWebView {
        coordinator.directory = directory.resolvingSymlinksInPath()
        coordinator.pageURL = pageURL.resolvingSymlinksInPath()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let controller = configuration.userContentController
        controller.addUserScript(WKUserScript(source: PluginSettingsBridge.shim,
                                              injectionTime: .atDocumentStart, forMainFrameOnly: true))
        controller.addScriptMessageHandler(coordinator, contentWorld: .page, name: PluginSettingsBridge.handlerName)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = coordinator
        webView.loadFileURL(pageURL, allowingReadAccessTo: directory)
        return webView
    }

    final class Coordinator: NSObject, WKScriptMessageHandlerWithReply, WKNavigationDelegate {
        var handle: (Any) -> (Any?, String?) = { _ in (nil, "unavailable") }
        var directory: URL?
        var pageURL: URL?

        nonisolated deinit {}

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage,
                                   replyHandler: @escaping (Any?, String?) -> Void) {
            guard message.frameInfo.isMainFrame,
                  message.frameInfo.request.url?.resolvingSymlinksInPath() == pageURL else {
                return replyHandler(nil, "not_settings_page")
            }
            let (value, error) = handle(message.body)
            replyHandler(value, error)
        }

        /// 主框架只能停在 manifest 指定的設定頁；iframe 只能載入插件目錄內的 file URL（沒有 bridge）。
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let url = navigationAction.request.url?.resolvingSymlinksInPath()
            let allowed = navigationAction.targetFrame?.isMainFrame == true
                ? url == pageURL
                : url.flatMap { url in directory.map { url.isFileURL && url.path.hasPrefix($0.path + "/") } } == true
            decisionHandler(allowed ? .allow : .cancel)
        }
    }
}

#if os(macOS)
extension PluginSettingsWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView {
        context.coordinator.handle = handle
        return Self.makeWebView(pageURL: pageURL, directory: directory, coordinator: context.coordinator)
    }
    func updateNSView(_ nsView: WKWebView, context: Context) { context.coordinator.handle = handle }
    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.configuration.userContentController.removeAllScriptMessageHandlers()
    }
}
#else
extension PluginSettingsWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView {
        context.coordinator.handle = handle
        return Self.makeWebView(pageURL: pageURL, directory: directory, coordinator: context.coordinator)
    }
    func updateUIView(_ uiView: WKWebView, context: Context) { context.coordinator.handle = handle }
    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.configuration.userContentController.removeAllScriptMessageHandlers()
    }
}
#endif
