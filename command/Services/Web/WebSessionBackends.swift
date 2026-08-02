//
//  WebSessionBackends.swift
//  Naki
//
//  p3-4：`WebSessionBackend` 的兩份實作 —— **全專案唯一的平台差異**。
//
//  這裡（而不是 view model、不是 View、不是 Action）是 WebPage 與 WKWebView
//  分道揚鑣的唯一地點。上層看到的只有 `WebSession`：同一組方法、同一種
//  JS 語意（函式體）、同一種導覽事件。
//
//  選哪一個由 `WebSession.init` 的 `#available` 決定；型別的 `@available` 標註
//  只是讓 iOS 17 的 `Naki-M` 編得過（`WebPage` 是 26+ 才有的 API）。
//

import SwiftUI
import WebKit

// MARK: - WebPage backend（macOS 26 / iOS 26+）

/// 走 `WebPage` 的實作。
@available(macOS 26.0, iOS 26.0, *)
@MainActor
final class WebPageBackend: WebSessionBackend {

    let page: WebPage

    /// 導覽決策與對話框：兩者都只是「一律放行／記一行 log」，
    /// 但 `WebPage` 要求在建立時就交出來，所以必須是實例而不是 closure。
    private let decider = NakiNavigationDecider()
    private let presenter = NakiDialogPresenter()

    weak var sink: (any WebNavigationSink)? {
        didSet { startObservingNavigations() }
    }

    private var navigationTask: Task<Void, Never>?

    var isReady: Bool { true }
    let supportsAutoPlay = true

    init(userContentController: WKUserContentController) {
        var configuration = WebPage.Configuration()
        configuration.userContentController = userContentController

        page = WebPage(
            configuration: configuration,
            navigationDecider: decider,
            dialogPresenter: presenter)

        // 註：先前這行在 `webPage` 被建立**之前**執行，optional chaining 對 nil
        // 直接短路，一行都沒生效。
        #if DEBUG
            page.isInspectable = true
        #endif
    }

    nonisolated deinit {}

    // MARK: - WebSessionBackend

    /// `WebPage.callJavaScript` 本來就是函式體語意，直接轉發
    func callJavaScript(_ functionBody: String) async throws -> Any? {
        try await page.callJavaScript(functionBody)
    }

    func load(_ url: URL) {
        page.load(url)
    }

    func reload() {
        page.reload()
    }

    /// 關掉所有雀魂 WebSocket，伺服器會以 authGame + syncGame 重建整局
    func forceReconnect() async -> ForceReconnectOutcome {
        await ForceReconnectAction(javaScript: ExecuteJavaScriptAction(backend: self))()
    }

    func makeView() -> AnyView {
        AnyView(NakiWebPageView(page: page))
    }

    // MARK: - 導覽事件

    private func startObservingNavigations() {
        navigationTask?.cancel()
        navigationTask = Task { [weak self] in
            guard let page = self?.page else { return }
            do {
                for try await event in page.navigations {
                    guard let sink = self?.sink else { return }
                    switch event {
                    case .startedProvisionalNavigation: sink.webDidStartNavigation()
                    case .committed: sink.webDidCommitNavigation()
                    case .finished: sink.webDidFinishNavigation()
                    case .receivedServerRedirect: break
                    @unknown default: break
                    }
                }
            } catch {
                self?.sink?.webDidFailNavigation(error.localizedDescription)
            }
        }
    }
}

/// WebPage path 的 View。
@available(macOS 26.0, iOS 26.0, *)
struct NakiWebPageView: View {

    let page: WebPage

    var body: some View {
        WebView(page)
            // a11y: 雀魂 Unity/WebGL canvas 對 VoiceOver 與 XCUIElement 是黑盒。
            // 用 .ignore 折成單一語意葉節點（而非 .accessibilityHidden(true)，
            // 後者會把元素連同 identifier 一併移出 a11y tree，UI 測試就無法斷言存在），
            // 讓 VO 讀到「雀魂遊戲畫面」而不卡在無語意的 canvas。
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("雀魂遊戲畫面")
            .accessibilityIdentifier("majsoul-webview")
    }
}

/// 導覽決策器：一律放行（雀魂自己會在同一個 origin 內跳轉）
@available(macOS 26.0, iOS 26.0, *)
@MainActor
final class NakiNavigationDecider: WebPage.NavigationDeciding {

    nonisolated deinit {}

    func decidePolicy(for action: WebPage.NavigationAction,
                      preferences: inout WebPage.NavigationPreferences)
        async -> WKNavigationActionPolicy { .allow }

    func decidePolicy(for response: WebPage.NavigationResponse)
        async -> WKNavigationResponsePolicy { .allow }

    func decideAuthenticationChallengeDisposition(for challenge: URLAuthenticationChallenge)
        async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        (.performDefaultHandling, nil)
    }
}

/// JavaScript 對話框：記一行 log，不打斷使用者
@available(macOS 26.0, iOS 26.0, *)
@MainActor
final class NakiDialogPresenter: WebPage.DialogPresenting {

    nonisolated deinit {}

    func handleJavaScriptAlert(message: String, initiatedBy frame: WebPage.FrameInfo) async {
        bridgeLog("[JS 警告] \(message)")
    }

    func handleJavaScriptConfirm(message: String, initiatedBy frame: WebPage.FrameInfo)
        async -> WebPage.JavaScriptConfirmResult {
        bridgeLog("[JS 確認] \(message)")
        return .ok
    }

    func handleJavaScriptPrompt(message: String, defaultText: String?,
                                initiatedBy frame: WebPage.FrameInfo)
        async -> WebPage.JavaScriptPromptResult {
        bridgeLog("[JS 提示] \(message)")
        return .cancel
    }

    func handleFileInputPrompt(parameters: WKOpenPanelParameters,
                               initiatedBy frame: WebPage.FrameInfo)
        async -> WebPage.FileInputPromptResult { .cancel }
}

// MARK: - Legacy backend（iOS 17–25）

/// 走 `WKWebView` 的實作。
///
/// **`supportsAutoPlay` 是 false**：這條路沒有主路徑的整層保護，而且 macOS
/// deployment target 是 26，本機根本跑不到它——沒有 iOS 17–25 實機就沒有任何
/// 對局證據。在那個證據出現以前，讓它自動送牌等於拿使用者的帳號賭一條沒驗過的路
/// （p2-2 路線 A；理由字串在 `AutoPlayAvailability.autoUnavailableReason`）。
@MainActor
final class LegacyWebBackend: NSObject, WebSessionBackend, WKNavigationDelegate, WKUIDelegate {

    let webView: WKWebView

    weak var sink: (any WebNavigationSink)?

    var isReady: Bool { true }
    let supportsAutoPlay = false

    init(userContentController: WKUserContentController) {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = userContentController
        configuration.mediaTypesRequiringUserActionForPlayback = []
        #if os(iOS)
            configuration.allowsInlineMediaPlayback = true
        #endif

        webView = WKWebView(frame: .zero, configuration: configuration)
        #if DEBUG
            webView.isInspectable = true
        #endif

        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    nonisolated deinit {}

    // MARK: - WebSessionBackend

    /// `evaluateJavaScript` 是**運算式**語意，所以這裡把函式體包成 IIFE。
    ///
    /// 這個包裝是 Legacy path 的內部細節：呼叫端一律寫函式體（要值就 `return`），
    /// 與 WebPage path 完全一致。先前它長在 `LegacyWebViewModel.executeJavaScript`
    /// 裡，而「這條 path 的腳本要不要自帶 return」只寫在註解。
    func callJavaScript(_ functionBody: String) async throws -> Any? {
        let wrapped = "(function() { \(functionBody) })()"
        return try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(wrapped) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: result)
                }
            }
        }
    }

    func load(_ url: URL) {
        webView.load(URLRequest(url: url))
    }

    func reload() {
        webView.reload()
    }

    /// 這條 path 沒有 `__nakiWebSocket.forceReconnect()` 之外的保證，改走整頁重載。
    ///
    /// 回 `.reloaded` 而不是假裝關了 0 條連線：`closedConnections: 0` 會被讀成
    /// 「找不到連線可關」。
    func forceReconnect() async -> ForceReconnectOutcome {
        webView.reload()
        return .reloaded
    }

    func makeView() -> AnyView {
        AnyView(LegacyNakiWebView(webView: webView))
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        sink?.webDidStartNavigation()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        sink?.webDidCommitNavigation()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        sink?.webDidFinishNavigation()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        sink?.webDidFailNavigation(error.localizedDescription)
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction)
        async -> WKNavigationActionPolicy { .allow }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse)
        async -> WKNavigationResponsePolicy { .allow }

    // MARK: - WKUIDelegate

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async {
        bridgeLog("[JS 警告] \(message)")
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async -> Bool {
        bridgeLog("[JS 確認] \(message)")
        return true
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo) async -> String? {
        bridgeLog("[JS 提示] \(prompt)")
        return nil
    }
}

/// Legacy path 的 View —— **只負責把既有的 `WKWebView` 放進 SwiftUI**。
///
/// 先前這個 representable 還兼任「建立 WKWebView、組 configuration、把 webView
/// 塞回 view model（`viewModel as? LegacyWebViewModel`）、決定要不要載入雀魂」。
/// 那個 `as?` 一失敗就什麼都不會發生，而且沒有任何錯誤訊息。
struct LegacyNakiWebView: View {

    let webView: WKWebView

    var body: some View {
        LegacyWebViewRepresentable(webView: webView)
            // a11y: 與 WebPage path 同一組標註（見 `NakiWebPageView`）
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("雀魂遊戲畫面")
            .accessibilityIdentifier("majsoul-webview")
    }
}

#if os(macOS)
    private struct LegacyWebViewRepresentable: NSViewRepresentable {
        let webView: WKWebView
        func makeNSView(context: Context) -> WKWebView { webView }
        func updateNSView(_ nsView: WKWebView, context: Context) {}
    }
#else
    private struct LegacyWebViewRepresentable: UIViewRepresentable {
        let webView: WKWebView
        func makeUIView(context: Context) -> WKWebView { webView }
        func updateUIView(_ uiView: WKWebView, context: Context) {}
    }
#endif
