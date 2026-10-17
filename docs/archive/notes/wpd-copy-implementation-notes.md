# WP-D 文案 implementation notes

分支 `wp-d-copy`，基底 main 8f3a029，未 commit。log 在主 repo `.swfd/logs/wp-d/`。

## 已修改

- `command/Views/DecisionSidebar.swift`：可用動作、等待牌局資料…、牌局資訊（a11y）、建議來源、計算位置、本機、改用本機；`DecisionAlerts` 四句換成 §4.2 新文案。
- `command/Views/StatusBanners.swift`：三個橫幅標題換成 §4.2 新文案；第二行摘要不動。
- `command/Views/ContentView.swift`：工具列日誌鈕 label 與 help 都改「紀錄」、遊戲面板鈕 help 改「決策面板」、`ConnectionIndicator` 值改「已連線／未連線」、a11y label 改「遊戲連線」、`ServerPickerView` Toggle 改「記住伺服器」。
- `command/Views/PluginsPageView.swift`：分頁 rawValue 改「紀錄」「權限」，匯入鈕改「預覽／預覽中…」，分頁 doc comment 跟著改名。rawValue 只用於顯示與 `id`，沒有持久化或 identifier 引用。
- `command/Views/LogPanel.swift`：標題改「紀錄」。
- `command/Resources/Localizable.xcstrings`：406 → 399 key。22 個舊 key 原位改名並寫入四語系；刪除 `已連接`（共用既有「已連線」）、`顯示或隱藏日誌`、`Log`（併入「紀錄」）、`移除插件？`（WP-C 孤兒），以及清理階段的 `顯示或隱藏遊戲面板`、`JavaScript 注入失敗`、`牌局封包解析失敗`。格式沿用原檔（indent 2、不排序、結尾換行）。
- 新增 `scripts/xcstrings-gate.py`：檢查 sourceLanguage、四語系齊且 state translated、占位符多重集合一致（`%1$@` 去位置號、排除 `%%`）。可帶 catalog 路徑參數。
- 新增 `NakiTests/LocalizationCatalogTests.swift`：同三條規則，以 `JSONSerialization` 讀原始檔（`#filePath` 回推）。
- 未改：Models、Services、Actions、pbxproj、`AdvancedSettingsSheet.swift`、`MajsoulConnectionSettingsBox.swift`、WP-F 列（ContentView 380／382／661／841）。

### 新 key 四語系（供復驗）

| zh-Hant（key） | en | ja | ko | zh-Hans |
|---|---|---|---|---|
| 可用動作 | Available actions | 使用できる操作 | 가능한 동작 | 可用动作 |
| 等待牌局資料… | Waiting for game data… | 対局データを待機中… | 대국 데이터 대기 중… | 等待牌局数据… |
| 牌局資訊 | Game info | 対局情報 | 대국 정보 | 牌局信息 |
| 建議來源 | Recommendation source | おすすめの情報源 | 추천 출처 | 建议来源 |
| 計算位置 | Computed on | 計算の実行場所 | 계산 위치 | 计算位置 |
| 本機 | This device | このデバイス | 이 기기 | 本机 |
| 改用本機 | Fell back to this device | このデバイスに切替 | 이 기기로 전환 | 改用本机 |
| 未連線 | Disconnected | 未接続 | 연결 안 됨 | 未连接 |
| 遊戲連線 | Game connection | ゲーム接続 | 게임 연결 | 游戏连接 |
| 紀錄 | Log | ログ | 로그 | 日志 |
| 決策面板 | Decision panel | 判断パネル | 판단 패널 | 决策面板 |
| 權限 | Permissions | 権限 | 권한 | 权限 |
| 預覽 | Preview | プレビュー | 미리보기 | 预览 |
| 預覽中… | Loading preview… | プレビューを取得中… | 미리보기 불러오는 중… | 预览中… |
| 記住伺服器 | Remember server | サーバーを記憶 | 서버 기억하기 | 记住服务器 |
| 頁面沒載入，讀不到牌局 | Page didn't load; can't read the game | ページが読み込まれず、対局を読み取れません | 페이지가 로드되지 않아 대국을 읽을 수 없습니다 | 页面没加载，读不到牌局 |
| App 元件載入失敗 | App component failed to load | App のコンポーネントの読み込みに失敗 | App 구성 요소 로드 실패 | App 组件加载失败 |
| 這局資料讀不懂：本局不給建議、不自動打 | Can't read this round's data: no recommendations or auto-play this round | この局のデータを読み取れません：この局ではおすすめも自動プレイもしません | 이번 국 데이터를 읽을 수 없습니다: 이번 국은 추천도 자동 플레이도 하지 않습니다 | 这局数据读不懂：本局不给建议、不自动打 |
| 雲端失敗，改用本機（已 %lld 手） | Cloud failed, using this device (%lld moves so far) | クラウド失敗、このデバイスに切替（%lld 手目） | 클라우드 실패, 이 기기로 전환 (%lld수째) | 云端失败，改用本机（已 %lld 手） |
| 雲端失敗，改用本機三麻（已 %lld 手） | Cloud failed, using 3P on this device (%lld moves so far) | クラウド失敗、このデバイスの三麻に切替（%lld 手目） | 클라우드 실패, 이 기기의 3인 마작으로 전환 (%lld수째) | 云端失败，改用本机三麻（已 %lld 手） |
| 自動打牌卡住 %lld 秒：該出手卻沒送出（%@） | Auto-play stuck for %lld s: it should have acted but sent nothing (%@) | 自動打牌が %lld 秒止まっています：出すべき操作を送信していません（%@） | 자동 대국 %lld초 멈춤: 해야 할 동작을 보내지 않음 (%@) | 自动打牌卡住 %lld 秒：该出手却没发送（%@） |
| 三麻建議下一手才會出現 | 3P recommendations appear from the next move | 三麻のおすすめは次の手から表示されます | 3인 마작 추천은 다음 수부터 표시됩니다 | 三麻建议下一手才会出现 |

用詞對齊相鄰 key：本機＝このデバイス／이 기기（同「本機 Core ML」「此裝置」）；建議＝おすすめ／추천（同「推薦」）；決策面板＝判断パネル／판단 패널（同「顯示決策面板」）；三麻＝三麻／3인 마작。多對一合併「顯示/隱藏日誌」「顯示或隱藏日誌」「Log」→「紀錄」：四語系取原 `Log` 的值（Log／ログ／로그／日志），逐語系確認語意為名詞「日誌」，不再帶「顯示／隱藏」動詞（狀態由 a11y value「已顯示／已隱藏」表達）。

## 已驗證

| 項目 | 結果 | log |
|---|---|---|
| 舊 key 殘留（Swift 帶引號完整 key、xcstrings key） | 全 0；`Log`／`信任`／`抓取` 的前綴命中是其他字串，精確比對 0 | `grep-acceptance.txt` |
| 新 key 在 Swift 出現；表格「不變」列與 WP-F 列仍在 | 符合 | `grep-acceptance.txt` |
| `scripts/xcstrings-gate.py` | 基底 406 key 0 failures；清理後 399 key 0 failures | `gate-xcstrings-base.log`、`cleanup-gate-xcstrings.log` |
| `LocalizationCatalogTests` + `AppLanguageTests` | 9 tests 0 failures（清理後） | `cleanup-test-l10n.log` |
| 反例：刪「紀錄」的 ko | 閘 exit 1（`FAIL '紀錄' 缺 ko`）；測試 rc 65、`紀錄 缺 ko`；還原後 `cmp` 相同、閘 0 failures | `counter-gate.log`、`counter-test.log`、`counter-restore.txt` |
| 反例：占位符（ja 漏 `%@`、en `%lld`→`%@`） | 閘 exit 1，兩條 FAIL（暫存副本，未動原檔） | `counter-gate-placeholder.log` |
| 全套 NakiTests（清理後） | 1020 tests，0 failures | `cleanup2-test-all.log` |
| 側欄快照 diff 對應「可用動作」 | 主線復驗比對 HEAD 與新圖確認 | 主線復驗 |
| 快照重錄（統帥代決） | 整 class 帶旗標重錄，再不帶旗標跑整 class：14 tests 0 failures | `cleanup-snapshot-record.log`、`cleanup-snapshot-verify.log`、`cleanup-rerecorded.txt` |
| macOS Debug／Release、iOS Simulator Debug／Release | 4 個 BUILD SUCCEEDED；清理後 macOS Debug 再建一次通過（四個 build 為清理前結果） | `build-*.log`、`cleanup2-build-macos-debug.log` |
| `scripts/ui-token-gate.sh` | 7 項 0 hit（清理後再一次（`cleanup2-token-gate.log`）） | `gate.log`、`cleanup-gate.log` |
| 真實偏好檔 | xml 無差異，sha256 與原始相同（清理後再驗） | `prefs-before.xml`、`cleanup2-prefs-after.xml`、`cleanup2-prefs-diff.txt`、`cleanup2-sha-after.txt` |
| 測試後程序 | 只剩執行前即存在的 NLS swiftpm-testing-helper（pid 24282，與 Naki 無關） | `pgrep-before.txt`／`pgrep-after.txt` |
| live App | 執行期間 loopback 無回應，測試未與 live Naki 並存 | `pending-before.txt` |
| catalog key 層級 diff | 刪 26（22 改名＋4 刪除）、增 22，每個新 key 在 Swift 有引用；保留的 380 key 與 HEAD 深度相等，所以「不變」「不改」與 WP-F 列的 catalog 條目全未動 | `grep-acceptance.txt` |
| WP-F 檔案未動、build 後 xcstrings 未被 Xcode 改寫 | `git diff --stat` 只有本包 6 檔；`git status` 另有 3 個新檔 | `git-status-final.txt` |

## 未驗證

- 實機外觀：工具列 tooltip、插件頁分頁、詳情面板、三種橫幅在 en／ja／ko 的寬度與截斷。
- VoiceOver 實際朗讀。
- UI 測試未跑（派工禁止）；派工已核對 UI 測試無舊字串引用，本包未再驗。
- ja／ko 翻譯未經母語者校對。

## 已知風險

- 快照 16 張重錄（統帥代決；BotFailureBanner 2 張由主線還原，基底雜訊非文案），多於預期的 12 張。多出的 4 張：`DecisionSidebar` compact／regular 各 light／dark 四張（diff 2.7‰～5.1‰，門檻內，來自「可用動作」，復驗比對 HEAD 與新圖確認）。清單與 diff 值見 `snapshot-diffs.txt`，實際重錄名單見 `cleanup-rerecorded.txt`。
- 新 key 寫在舊 key 原位，檔案本來就未排序；Xcode 下次開檔可能重排，產生與內容無關的 diff。
- 閘與 `LocalizationCatalogTests` 是同一規則的兩份實作，改規則要兩邊一起改。
- 「紀錄」合併後，日誌鈕的 VoiceOver 名稱從「顯示或隱藏日誌」變成名詞「紀錄」，開關語意只剩 a11y value。

## Deviations

1. 設計文件列號已漂移，以派工的現行列號為準：320／322／601／781 → 380／382／661／841。
2. 主線裁決：改。遊戲面板鈕 Button label 由「顯示或隱藏遊戲面板」改「決策面板」（ContentView 457），與 help 同字共用 key；舊 key 刪除。
3. 主線裁決：改。橫幅 a11y label「JavaScript 注入失敗」改「App 元件載入失敗」（StatusBanners 144），「牌局封包解析失敗」改「這局資料讀不懂：本局不給建議、不自動打」（192），皆與橫幅標題同字共用 key；兩個舊 key 刪除。派工寫「這局資料讀不懂」，但標題 key 是含後半句的全文，照保守選項沿用全文而不新增短 key。
4. 「移除插件？」在 §4.1「不變」列，但 Swift 已無引用（WP-C 改原地確認），依派工刪除；派工優先於表格。
5. `ConnectionIndicator` 膠囊上的「WebSocket」標字不在表內，不改。
6. `PluginsPageView` 內「信任」相關的警語與 Label「信任邊界與 L3 權限」不在表內，不改；分頁已改名「權限」，Label 仍寫「信任邊界」。
7. 部分改名 key 的 comment 重寫成新用途（可用動作、等待牌局資料…、本機、紀錄、預覽、預覽中…），其餘沿用原 comment；原因：這些 key 的用途隨文案改變，沿用舊 comment 會誤導翻譯者。
8. 強化（變異測試）依派工改為反例：缺 ko 與占位符不符各一。

## 復驗修訂（主線裁決）

- 「雲端失敗，改用本機（已 %lld 手）」「…本機三麻…」ja／ko 改回連續語意（手連続／수 연속 不用序數 手目／수째），ja 「切替」改「切り替え」。
- 「自動打牌卡住」ja 改「自動プレイ」、ko 改「자동 플레이」，與既有 key「自動打牌」及封包解析橫幅一致。

## 交接 WP-F

- `AdvancedSettingsSheet.swift:673` 三麻提醒仍寫「決策來源」，要改「建議來源」。

## 下一輪

- 日誌面板「清除日誌」「日誌分類」「顯示日誌」「日誌」與「紀錄」混用，不在 §4.1 表內。
