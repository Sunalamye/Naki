# WP-F1 UI 測試隔離鉤子 implementation notes

基底 main `803981e`，分支 `wp-f1-isolation`，未 commit。log 在主 repo `.swfd/logs/wp-f1/`。

## 已修改
- `SettingsStore.standard` 改由兩個純函式算出：`SettingsStore.resolveSuiteName(environment:)`（名稱）與 `resolveDefaults(environment:)`（含無效名稱退回）：test host 落 `naki.tests.host`（優先）；Debug 下有 `NAKI_UI_TEST_DEFAULTS_SUITE` 就落該 suite，空字串落 `naki.tests.ui`；其餘回 nil＝`.standard`。`UserDefaults(suiteName:)` 回 nil 時也落 `naki.tests.ui`。
- `CloudKeyStore.service` 改由 `CloudKeyStore.resolveService(environment:)` 算出：Debug 下有 `NAKI_UI_TEST_KEYCHAIN_SERVICE` 就用該值，空字串或等於正式 service 都改用 `org.naki.cloud-inference.uitest`。
- 兩個 key 的字面值只出現在 `#if DEBUG` 內，Release 產物裡沒有這兩個字串。
- `L10n.defaults`、`ObservedMatchSids` 的 `init(defaults:)` 預設值、ContentView 的 `@AppStorage(SettingsStore.pinMajsoulServerKey, store:)` 都改經 `SettingsStore.standard`。
- 新增 `NakiTests/UITestIsolationTests.swift`（清理後 7 個測試，環境 key 寫字面值）。
- `CLAUDE.md`「專案結構的坑」test host 那條改成現況（清理時依主線裁決）。
- `NakiTests/ObservedMatchSidsTests.swift` 的還原改成 `redirect(to: SettingsStore.standard)`。

### grep 落點（`command`／`Naki`／`Naki-M`，pattern：`UserDefaults.standard`、`@AppStorage`、`UserDefaults(`、`= .standard`、`\.standard`）
| 落點 | 結論 |
|---|---|
| `SettingsStore.standard` 定義 | 本包改，鉤子所在 |
| `SettingsStore` 內 `defaults` 與各 inline 初值、`load…`／`save…` 預設參數 | 已經過 `SettingsStore.standard` |
| `AutoPlayModeStore.defaults`（`AutoPlayMode.swift`） | 已經過 `SettingsStore.standard`（WP-0p） |
| `L10n.defaults` | 本包改 |
| ContentView `serverPinned` 的 `@AppStorage`（實際在 300 行，派工寫 240） | 本包改 |
| `ObservedMatchSids` 的 `init(defaults:)` | 本包改；`makeForTesting`／`redirect` 由呼叫端傳 suite，不需改 |
| `DecisionSidebar` 的 `PanelLayout.standard` | 不需改：動畫 token，與 UserDefaults 無關 |
| `AutoPlayMode.swift` 註解裡的舊版 `@AppStorage("AutoPlayMode")` | 不需改：只是註解 |
| `Naki/`、`Naki-M/` | 0 hit |
| 補查 `SceneStorage`／`CFPreferences`／`SecItem` | 只有 `CloudKeyStore` 用 `SecItem`，本包改；其餘 0 hit |

### LogManager
`LogManager.init` 以 `XCTestConfigurationFilePath` 決定要不要輪替 `~/Library/Logs/Naki`。UI 測試啟動的 App 不是 test host，會照常建立 log 目錄並輪替舊 session（有 `games/` 的只留 `games/`）。這不碰設定檔或 Keychain，依派工不改，列為已知風險。

## 已驗證
- 清理後、復驗修訂前（log 前綴 `cleanup-`，數字為當時值）：四個目標類別 25 個測試綠（`cleanup-test-targeted.log`）；全套 1027 個、0 failures（`cleanup-test-full.log`）；macOS Debug／Release build 成功（`cleanup-build-macos-debug.log`、`cleanup-build-macos-release.log`）；Release 產物 `strings` 0 個 `NAKI_UI_TEST`；`ui-token-gate.sh` exit 0；Keychain 屬性（略去修改時間）前後相同（`cleanup-keychain-*.txt`）。
- 實測 `UserDefaults(suiteName:)` 對 `NSGlobalDomain` 與 App 自己的 bundle id 都回 nil；兩者經 `resolveDefaults` 都落 `naki.tests.ui`，不落真實設定檔。
- 兩條新測試的變異都被抓到：退回路徑改成 `.standard`（`cleanup-mutant-fallback.log`）、`ObservedMatchSids.init` 預設改回 `.standard`（`cleanup-mutant-sids.log`）。
- 全套 NakiTests 1025 個、0 failures（基底 1020，本包加 5），`PlatformDivergenceTests`、`TestHostDefaultsTests` 都通過：`test-full.log`。
- 四個 build 都 `BUILD SUCCEEDED`：`build-macos-debug.log`、`build-macos-release.log`、`build-ios-debug.log`、`build-ios-release.log`。
- 兩條 build-for-testing 都 `TEST BUILD SUCCEEDED`：`bft-macos.log`、`bft-ios.log`。
- 真實偏好檔 sha256 前後相同，xml diff 為空：`sha-before.txt`、`sha-after.txt`、`plist-diff.txt`；備份在 `plist-backup/`。
- `security find-generic-password -s org.naki.cloud-inference`（無 `-g`）的屬性前後相同：`keychain-before.txt`、`keychain-after.txt`。`.uitest` service 前後都不存在：`keychain-uitest-*.txt`。
- `scripts/ui-token-gate.sh` 0 hit、exit 0：`ui-token-gate.log`。`scripts/xcstrings-gate.py` exit 0：`xcstrings-gate.log`。
- 變異測試，6 個全被抓到：
  - 讀錯 defaults key：`mutant-wrong-suite-key.log`。
  - suite 空字串照用：`mutant-empty-suite.log`。
  - 讀錯 Keychain key：`mutant-wrong-service-key.log`。
  - service 空字串或正式值照用：`mutant-empty-service.log`。
  - `L10n.defaults` 退回 `.standard`：`mutant-l10n-standard.log`。
  - 拿掉兩處 `#if DEBUG`（DEBUG 外生效）：Release 產物 strings 從 0 hit 變 2 hit，`mutant-debug-outside.log`、`strings-check.txt`。單測只跑 Debug，這條只能用產物檢查驗。
- 測試前後 `pgrep -lf "Naki.app|xctest"` 只剩無關的 NLS swiftpm helper（pid 24282，執行前就在）：`pgrep-before.txt`、`pgrep-after.txt`。

## 未驗證
- 帶 launchEnvironment 啟動 App 時，鉤子真的生效：本包不跑 UI 測試，F2 才會驗。
- ContentView `@AppStorage` 換 store 後的實際畫面行為與 `store:` 參數：沒有單測，只有 build。
- ContentView `@AppStorage` 的 `store:` 沒有測試鎖住（只有 build）。
- 執行時 Naki 未啟動，8765 無回應（`pending-before.txt`），沒有 live 對局。

## 已知風險
- **F2 派工必讀**：UI 測試啟動的 App 不是 test host，AutoPlayEngine 與 DebugServer 都會啟動（`NakiRuntime.init`，依派工不改）。新的隔離 suite 沒有存過模式，會套新安裝預設 `.auto`，而 WebView 用真實雀魂登入狀態。F2 要在測試的 launchEnvironment 或 suite 內先固定模式，或確保不進遊戲頁。
- **F2 派工必讀**：test host 建構 `SettingsStore` 時，`cloudAPIKey` 初值仍讀真實 Keychain（只讀，既有行為，本包不改）。
- **F2 派工必讀**：`LogManager` 的輪替（見上），UI 測試啟動的 App 會輪替真實 `~/Library/Logs/Naki`。
- `SettingsStore.isTestHost` 與 `resolveSuiteName` 各讀一次 `XCTestConfigurationFilePath`，`LogManager` 再一次，共三處。

## Deviations
- 純函式回傳 suite 名稱（`String?`）而不是 `UserDefaults`：`UserDefaults(suiteName:)` 每次回新實例，無法用身分比對；比名稱也不必在單測裡建 suite、不再多出 `naki.tests.*` 空殼 plist。
- （已被 `resolveDefaults` 與前綴防線取代，見「復驗修訂」）空字串、或 suite 名稱無效時，退回固定測試 suite／service，不退回真實落點：key 一出現就代表 UI 測試，保守選項是不碰真實資料。Keychain 的 service 等於正式值時同樣退回。
- test host 與 UI 測試 key 同時存在時，test host 優先，由 `testTestHostWinsOverUITestSuite` 鎖住。
- 改了 `NakiTests/ObservedMatchSidsTests.swift`（不在派工清單）：原本的還原寫法是 `redirect(to: .standard)`，在 test host 會把 `.shared` 指回真實設定檔。
- 第一次「DEBUG 外生效」變異的腳本定位錯誤，沒套上變異；第二次把 SettingsStore 另一組 `#endif` 也註解掉，build 失敗。兩次都作廢，第三次只動鉤子函式內那一組才算數。
- 清理：`defaultsSuiteName` 改名 `resolveSuiteName`，與 `resolveService` 風格一致；新增 `resolveDefaults` 把「無效名稱退回 `naki.tests.ui`」從 `standard` 的內嵌 closure 抽成可測純函式；`naki.tests.ui` 字面值收成一個私有常數。
- 清理：補兩條測試（無效 suite 名稱退回、`ObservedMatchSids` 預設落點）；`CLAUDE.md` 過時段依主線裁決改寫。
- 清理時的副作用與修復：`ObservedMatchSids` 預設落點的變異讓 `.shared` 落到真實設定檔，teardown 的 `reset()` 刪掉了真實 plist 的 `naki.observedMatchSids`（內容是舊測試殘留的 `sync-sid`／`v1` 一筆）。已從 `plist-backup/akagi-before.plist` 原值寫回，xml 與清理前逐行相同；檔案 sha256 因二進位重新序列化而改變（清理前 322a0e8c…，之後 65787f46…），內容不變。教訓：這類變異會寫真實檔，應先備份或改用只讀斷言驗證。

## 復驗修訂
復驗前後的驗證在 log 前綴 `fix-`：全套 1028 個、0 failures（`fix-test-full.log`）；macOS Debug build 成功（`fix-build-macos-debug.log`）；真實 plist 修訂前後 xml diff 為空（`fix-plist-after.xml`）。
- `testObservedMatchSidsDefaultsToSettingsStoreStandard` 改唯讀。理由：舊寫法經 `.shared` 做 record／reset，預設落點錯時會寫並刪真實設定檔（清理階段的變異已造成一次）。新寫法在 `ObservedMatchSids` 的 `#if DEBUG` 內加 `makeWithDefaultDefaults()` 與 `defaultsForTesting`，以 `===` 比對 `SettingsStore.standard`；不碰 `.shared`，也不再順序相依。
- `resolveSuiteName` 對環境值不以 `naki.tests.` 開頭者（含空字串、路徑、App bundle id）一律退回 `naki.tests.ui`，與 `CloudKeyStore` 擋正式 service 對稱。理由：suite 名稱若是路徑或 bundle id，可能指向真實 domain 或任意檔案。新增 `testSuiteWithoutTestPrefixFallsBack` 傳 `/tmp/x`、`org.39c154f25912233a.akagi`、空字串。
- 前綴防線之後，`UserDefaults(suiteName:)` 回 nil 的退回在 `resolveDefaults` 內只剩防禦用途，保留。
