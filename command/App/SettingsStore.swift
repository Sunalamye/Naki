//
//  SettingsStore.swift
//  Naki
//
//  使用者設定的單一持有者（`NakiEnvironment.settings`）。
//
//  持久化 key、設定值與「這條 path 支不支援自動送出」的能力旗標都住在這裡：
//  View 問「選單上要不要有『自動』」不必認得頁面 service，key 字串也只有一份定義。
//

import Foundation
import SwiftUI

/// 使用者設定與「這條 WebView 路徑能做什麼」的唯一持有者。
///
/// 邊界：
/// - 自動打牌**模式**不在這裡。它的持久化權威是 `AutoPlayModeStore`、收斂權威是
///   `AutoPlayAvailability.commit`，而「現在生效的是哪一個」住在 `GameStore`。
///   這裡只放「這條 path 允不允許 `.auto` 這個選項」。
/// - 牌局資料不在這裡（`GameStore`）。
/// 雀魂的區服。
///
/// **三個服跑同一份 client**：2026-08-09 實測三個 `version.json` 完全相同
/// （`0.11.252.w`），所以 Liqi 協定一致——Naki 不需要為不同服準備不同的 parser，
/// 也不需要在 UI 上把非國服標成「未驗證」。這個結論會隨雀魂改版失效，
/// 換服之後解析大量失敗的話，先回頭比對這三個 `version.json`。
///
/// URL 是**唯一定義點**：`WebSession.loadMajsoul` 與選擇畫面都讀這裡，
/// 不要在別處再寫一次字面值（先前那份寫死在 `WebSession.swift` 的 URL 就是這樣長出來的）。
enum MajsoulServer: String, CaseIterable, Identifiable, Sendable {
    case cn
    case jp
    case intl

    nonisolated var id: String { rawValue }

    /// 各服自己的招牌，不是翻譯——選單上要能對應到使用者實際看到的畫面。
    nonisolated var displayName: String {
        switch self {
        case .cn:   return "雀魂麻將"
        case .jp:   return "じゃんたま"
        case .intl: return "MahjongSoul"
        }
    }

    nonisolated var regionName: String {
        switch self {
        case .cn:   return "國服"
        case .jp:   return "日服"
        case .intl: return "國際服"
        }
    }

    nonisolated var urlString: String {
        switch self {
        case .cn:   return "https://game.maj-soul.com/1/"
        case .jp:   return "https://game.mahjongsoul.com/"
        case .intl: return "https://mahjongsoul.game.yo-star.com/"
        }
    }

    nonisolated var url: URL? { URL(string: urlString) }

    /// 選單第二行顯示的網域（讓人看得出自己要連去哪，尤其國服與國際服長得不像）
    nonisolated var host: String { URL(string: urlString)?.host ?? urlString }
}

@Observable
@MainActor
final class SettingsStore {

    /// 隱藏玩家名稱的持久化 key —— **唯一定義點**。
    ///
    /// UI 的 Toggle 與 `WebSession` 都讀這個 static，不要在別處再寫一次字面值。
    nonisolated static let hidePlayerNamesKey = "HidePlayerNames"

    /// 在遊戲解析封包前把暱稱改寫成 Player 1–4（實作見 `naki-websocket.js` 的 `__nakiHideNames`）。
    ///
    /// 寫入即持久化：UI 的 Toggle 與 `WebSession.setHidePlayerNames` 讀寫同一份。
    /// 初值直接從 `UserDefaults` 取（stored property 的預設值運算式），這樣 `init` 就不必
    /// 走 setter——`@Entry` 的預設值要在 nonisolated 的 `defaultValue` 裡建起來。
    var hidePlayerNames: Bool = UserDefaults.standard
        .bool(forKey: SettingsStore.hidePlayerNamesKey)
    {
        didSet {
            guard hidePlayerNames != oldValue else { return }
            UserDefaults.standard.set(hidePlayerNames, forKey: Self.hidePlayerNamesKey)
        }
    }

    // MARK: - 雀魂區服

    nonisolated static let majsoulServerKey = "MajsoulServer"
    nonisolated static let pinMajsoulServerKey = "PinMajsoulServer"

    /// 要連哪個區服。預設國服＝這個功能出現之前的寫死行為，升級不會換掉任何人的服。
    ///
    /// 存 `rawValue` 而不是 index：日後在中間插一個新區服，index 會讓所有人默默換服。
    var majsoulServer: MajsoulServer =
        MajsoulServer(rawValue: UserDefaults.standard
            .string(forKey: SettingsStore.majsoulServerKey) ?? "") ?? .cn
    {
        didSet {
            guard majsoulServer != oldValue else { return }
            UserDefaults.standard.set(majsoulServer.rawValue, forKey: Self.majsoulServerKey)
        }
    }

    /// 啟動時是否**跳過**詢問，直接用 `majsoulServer`。
    ///
    /// 預設 false＝每次啟動都問。選擇畫面上那個「以後都用這個」勾選就是寫這個值，
    /// 設定頁可以隨時取消（取消之後下次啟動又會問）。
    ///
    /// 預設值剛好等於 `UserDefaults.bool` 對未設定 key 的回傳（false），所以不必
    /// `register(defaults:)`——與 `showStatusBar` 同一個理由，哪天要改預設就得補註冊。
    var pinMajsoulServer: Bool = UserDefaults.standard
        .bool(forKey: SettingsStore.pinMajsoulServerKey)
    {
        didSet {
            guard pinMajsoulServer != oldValue else { return }
            UserDefaults.standard.set(pinMajsoulServer, forKey: Self.pinMajsoulServerKey)
        }
    }

    /// 狀態訊息浮層的持久化 key。
    nonisolated static let showStatusBarKey = "ShowStatusBar"

    /// 牌桌底部那條狀態訊息浮層要不要顯示（**只有 iOS 讀**）。
    ///
    /// 預設關閉：它疊在牌桌上，而內容多半是「已連線到雀魂伺服器」這種一次性回饋，
    /// 或 `skip:noOplist` 這種診斷輸出——兩者都不值得長期佔著手牌上方那條。要看的人
    /// 自己開，真正不會自己好的錯誤走橫幅（`JSInjectionFailureBanner` 那一組），
    /// 不受這個開關影響。
    ///
    /// **預設值剛好等於 `UserDefaults.bool` 對未設定 key 的回傳值（false）**，所以不必
    /// `register(defaults:)`。哪天要把預設改成 true，就得補註冊——沒補的話新裝的人會
    /// 拿到 false，而程式碼上看起來是 true。
    ///
    /// macOS 不讀它：那邊的狀態列是 `safeAreaInset` 排版的一列，不疊在任何東西上，
    /// 沒有這個開關要解決的問題。
    var showStatusBar: Bool = UserDefaults.standard
        .bool(forKey: SettingsStore.showStatusBarKey)
    {
        didSet {
            guard showStatusBar != oldValue else { return }
            UserDefaults.standard.set(showStatusBar, forKey: Self.showStatusBarKey)
        }
    }

    // MARK: - 自動打牌基準延遲

    /// 延遲 stepper 的持久化 key。
    ///
    /// 它不取代 `ActionDelayModel` 的隨機分布（那是防偵測的刻意設計），而是當它的
    /// **縮放係數**：stepper 的秒數乘在整個抽樣值上，1.0s 等於現行行為。
    /// 讀取端是 `AutoPlayEngine`（經 `Context.actionDelayScale`）→ `ActionDelayModel.delay(for:scale:)`。
    ///
    /// 持久化機制與 mode 同一套（單一 UserDefaults key、重啟還原）；差別是它沒有需要
    /// 一次性遷移的舊 key，所以直接住在 `SettingsStore` 而不必像 `AutoPlayModeStore` 另立型別。
    nonisolated static let actionDelaySecondsKey = "naki.actionDelaySeconds"

    /// stepper 範圍與步進（UI 與 clamp 共用同一份定義）。
    ///
    /// 1.0s＝現行行為；向下更快、向上更慢。
    nonisolated static let actionDelayRange: ClosedRange<Double> = 0.5...3.0
    nonisolated static let actionDelayStep: Double = 0.1
    nonisolated static let defaultActionDelaySeconds: Double = 1.0

    /// 把任意輸入夾回合法區間（防止舊版或外部寫入落在範圍外）。
    nonisolated static func clampActionDelay(_ value: Double) -> Double {
        min(max(value, actionDelayRange.lowerBound), actionDelayRange.upperBound)
    }

    /// 讀取持久化的基準秒數（沒有存檔回預設 1.0s；越界值夾回區間）。
    nonisolated static func loadActionDelaySeconds(_ defaults: UserDefaults = .standard) -> Double {
        guard defaults.object(forKey: actionDelaySecondsKey) != nil else {
            return defaultActionDelaySeconds
        }
        return clampActionDelay(defaults.double(forKey: actionDelaySecondsKey))
    }

    /// 寫入基準秒數（寫入即夾回區間，永不持久化越界值）。
    nonisolated static func saveActionDelaySeconds(_ value: Double,
                                                   to defaults: UserDefaults = .standard) {
        defaults.set(clampActionDelay(value), forKey: actionDelaySecondsKey)
    }

    /// 使用者設定的自動打牌基準延遲（秒）。UI 顯示成 `1.0s`。
    ///
    /// 寫入即持久化：stepper 的 Binding 直接讀寫這一份，`AutoPlayEngine` 每一輪
    /// 從 `actionDelayScale` 讀新值——少了這個讀取端，stepper 就只是個假控制。
    var actionDelaySeconds: Double = SettingsStore.loadActionDelaySeconds() {
        didSet {
            let clamped = Self.clampActionDelay(actionDelaySeconds)
            if clamped != actionDelaySeconds {
                actionDelaySeconds = clamped   // 二次進 didSet：clamped==self → 下面 guard 擋住
                return
            }
            guard actionDelaySeconds != oldValue else { return }
            Self.saveActionDelaySeconds(actionDelaySeconds)
        }
    }

    /// 基準秒數 → `ActionDelayModel.delay(for:scale:)` 的縮放係數。
    ///
    /// 語意是「基準秒數 / 1.0」——基準預設 1.0s，所以係數就等於秒數；除法留著是為了
    /// 讓「1.0s＝現行行為（scale 1.0）」寫在型別上，而不是靠 reader 記得預設值剛好是 1。
    /// 抽成 `nonisolated static` 是為了不必建立實例（更不必碰 `.standard`）就能單測這條換算。
    nonisolated static func actionDelayScale(forSeconds seconds: Double) -> Double {
        seconds / defaultActionDelaySeconds
    }

    /// 給 `AutoPlayEngine.Context.actionDelayScale` 讀的縮放係數。
    var actionDelayScale: Double {
        Self.actionDelayScale(forSeconds: actionDelaySeconds)
    }

    // MARK: - 全自動：三麻還是四麻

    /// 「全自動」續局要排哪一種的持久化 key。
    nonisolated static let fullAutoPrefersSanmaKey = "naki.fullAutoPrefersSanma"

    /// 預設四麻。
    ///
    /// 不是隨手挑的預設：bundled Core ML 是四麻模型，三麻走雲端-only（見 CLAUDE.md），
    /// 雲端沒設定時三麻一手都不會打。把預設放在「一定能打」的那一邊。
    nonisolated static func loadFullAutoPrefersSanma(
        from defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: fullAutoPrefersSanmaKey)
    }

    /// 全自動續局排三麻（true）還是四麻（false）。寫入即持久化。
    ///
    /// 讀取端是 `AutoRematchEngine.Context.prefersSanma`；它只影響**續局排哪一種**，
    /// 不影響進行中的對局（那由伺服器發的 `start_game.is3P` 決定）。
    var fullAutoPrefersSanma: Bool = SettingsStore.loadFullAutoPrefersSanma() {
        didSet {
            guard fullAutoPrefersSanma != oldValue else { return }
            UserDefaults.standard.set(fullAutoPrefersSanma,
                                      forKey: Self.fullAutoPrefersSanmaKey)
        }
    }

    /// 續局在段位允許的房間裡挑最低還是最高的持久化 key。
    nonisolated static let fullAutoRoomPreferenceKey = "naki.fullAutoRoomPreference"

    /// 預設挑**最低**的房間。
    ///
    /// 段位場輸了會掉分，掉到門檻以下就退房。挑最低＝對手最弱、掉段風險最小，
    /// 是「放著讓它一直打」這個情境下唯一不會愈打愈糟的預設。
    nonisolated static func loadFullAutoRoomPreference(
        from defaults: UserDefaults = .standard) -> RoomPreference {
        (defaults.string(forKey: fullAutoRoomPreferenceKey))
            .flatMap(RoomPreference.init(rawValue:)) ?? .lowest
    }

    /// 續局挑房偏好。寫入即持久化。
    var fullAutoRoomPreference: RoomPreference = SettingsStore.loadFullAutoRoomPreference() {
        didSet {
            guard fullAutoRoomPreference != oldValue else { return }
            UserDefaults.standard.set(fullAutoRoomPreference.rawValue,
                                      forKey: Self.fullAutoRoomPreferenceKey)
        }
    }

    // MARK: - 雲端推論（docs/cloud-inference-plan.md）

    /// 三個非機密欄位走 UserDefaults（與本檔既有 pattern 同款）；
    /// **API key 走 Keychain**（`CloudKeyStore`）——credential 不落入
    /// 可能被 bug report 附上的 plist。
    nonisolated static let cloudEnabledKey = "naki.cloud.enabled"
    nonisolated static let cloudBaseURLKey = "naki.cloud.baseURL"
    nonisolated static let cloudModel4PKey = "naki.cloud.model4p"
    nonisolated static let cloudModel3PKey = "naki.cloud.model3p"

    /// 預設伺服器（Akagi 官方；與其 `DEFAULT_API_BASE_URL` 一致）。
    /// 預填省得使用者打字；沒貼 key 之前 `isActive` 恆為 false，不會連線。
    nonisolated static let defaultCloudBaseURL = "https://mjapi.shinkuan.me"

    /// 啟用雲端推論。開著但 URL/key 缺任一 ⇒ 實際仍是本地（`CloudInferenceConfig.isActive`）。
    var cloudInferenceEnabled: Bool = UserDefaults.standard
        .bool(forKey: SettingsStore.cloudEnabledKey)
    {
        didSet {
            guard cloudInferenceEnabled != oldValue else { return }
            UserDefaults.standard.set(cloudInferenceEnabled, forKey: Self.cloudEnabledKey)
        }
    }

    /// 推論伺服器 base URL。
    var cloudServerURL: String = UserDefaults.standard
        .string(forKey: SettingsStore.cloudBaseURLKey) ?? SettingsStore.defaultCloudBaseURL
    {
        didSet {
            guard cloudServerURL != oldValue else { return }
            UserDefaults.standard.set(cloudServerURL, forKey: Self.cloudBaseURLKey)
        }
    }

    /// Bearer API key。讀寫都在 Keychain；這份只是 UI 綁定用的記憶體鏡像。
    var cloudAPIKey: String = CloudKeyStore.load() {
        didSet {
            guard cloudAPIKey != oldValue else { return }
            CloudKeyStore.save(cloudAPIKey)
        }
    }

    /// 四麻模型 id；空字串 ⇒ 伺服器預設。
    var cloudModel4P: String = UserDefaults.standard
        .string(forKey: SettingsStore.cloudModel4PKey) ?? ""
    {
        didSet {
            guard cloudModel4P != oldValue else { return }
            UserDefaults.standard.set(cloudModel4P, forKey: Self.cloudModel4PKey)
        }
    }

    /// 三麻模型 id；空字串 ⇒ 伺服器預設。
    /// 雲端是 Naki 目前**唯一**的真三麻推論路徑（本地 fallback 仍是四麻模型，
    /// 三麻局 fallback 時 `decisionSource` 會如實顯示降級）。
    var cloudModel3P: String = UserDefaults.standard
        .string(forKey: SettingsStore.cloudModel3PKey) ?? ""
    {
        didSet {
            guard cloudModel3P != oldValue else { return }
            UserDefaults.standard.set(cloudModel3P, forKey: Self.cloudModel3PKey)
        }
    }

    /// 給 `NativeBotController.cloudConfigProvider` 的值快照（每決策點重讀）。
    var cloudConfig: CloudInferenceConfig {
        CloudInferenceConfig(enabled: cloudInferenceEnabled,
                             baseURL: cloudServerURL,
                             apiKey: cloudAPIKey,
                             model4P: cloudModel4P,
                             model3P: cloudModel3P)
    }

    /// 目前這條 WebView 路徑是否提供自動送出。
    ///
    /// 不是使用者設定，而是「設定選單上有沒有這個選項」的依據：
    /// WebPage path（macOS/iOS 26+）是 true；Legacy path（iOS 17–25 的 WKWebView）是 false
    /// ——那條路缺輪詢閘門與重試保護，而且沒有任何實機對局驗證（見 `AutoPlayAvailability`）。
    ///
    /// **只由 `NakiRuntime` 在建立 `WebSession` 之後寫入一次**（能力由 backend 決定，
    /// 而 backend 要先有 settings 才能建；順序上必須是兩步）。
    private(set) var supportsAutoPlay = true

    /// `nonisolated`：`NakiEnvironment` 的 Preview 預設值要在 `@Entry` 生成的
    /// **nonisolated** `EnvironmentKey.defaultValue` 裡建起來。
    nonisolated init() {}

    /// `@MainActor` class 在 NakiTests host 釋放會 SIGABRT（見 CLAUDE.md「專案結構的坑」）
    nonisolated deinit {}

    /// 由 `NakiRuntime` 在選定 WebView backend 之後告知這條 path 的能力
    func adoptAutoPlaySupport(_ supported: Bool) {
        supportsAutoPlay = supported
    }
}
