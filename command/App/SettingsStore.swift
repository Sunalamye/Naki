//
//  SettingsStore.swift
//  Naki
//
//  p3-4：使用者設定的單一持有者（`NakiEnvironment.settings`）。
//
//  先前這些值散在三處：`UserDefaults.standard` 的字串 key（兩個 view model 各寫一次）、
//  View 的 `@AppStorage("HidePlayerNames")`、以及「這條 path 支不支援自動送出」
//  這種只有 view model 知道的能力旗標。View 因此必須認得 view model 才問得到
//  「選單上要不要有『自動』」，而 key 字串在三個檔案裡各寫一次。
//

import Foundation
import SwiftUI

/// 使用者設定與「這條 WebView 路徑能做什麼」的唯一持有者。
///
/// 邊界：
/// - 自動打牌**模式**不在這裡。它的持久化權威是 `AutoPlayModeStore`、收斂權威是
///   `AutoPlayAvailability.commit`，而「現在生效的是哪一個」住在 `GameStore`（p3-3）。
///   這裡只放「這條 path 允不允許 `.auto` 這個選項」。
/// - 牌局資料不在這裡（`GameStore`）。
@Observable
@MainActor
final class SettingsStore {

    /// 隱藏玩家名稱的持久化 key。
    ///
    /// 先前這個字串在 `WebViewModel`、`LegacyWebViewModel`、`AdvancedSettingsSheet`
    /// 各寫一次（其中一份是 `WebViewModel.hidePlayerNamesKey` static、另外兩份是字面值）。
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

    // MARK: - 自動打牌基準延遲

    /// 延遲 stepper 的持久化 key。
    ///
    /// p2-6：延遲控制在 p1-3 被整個移除（當時它寫進去的值零讀取點，是假控制）。
    /// 這次做回來並接真——不是取代 `ActionDelayModel` 的隨機分布（那是防偵測的刻意
    /// 設計），而是當它的**縮放係數**：stepper 的秒數乘在整個抽樣值上，1.0s 等於現行行為。
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
    /// 從 `actionDelayScale` 讀新值——這正是 p1-3 抓到那批假控制欠缺的「讀取端」。
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
