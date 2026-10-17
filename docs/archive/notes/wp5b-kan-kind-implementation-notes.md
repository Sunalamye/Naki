# wp5b-kan-kind implementation notes

## 目標
暗槓與加槓並存時，executor 依 bot 想要的槓種送 type，不再固定取 `kanOperation` 的第一個（暗槓）。

## 設計
- `Recommendation.kanKind: LiqiOperationType?`：只有 `.kan` 且來源分得出種類時有值；字串 init 新增預設 nil 參數，其他 init 一律 nil。
- 雲端 `CloudDecisionMapper` 的 reaction `ankan`／`kakan`／`daiminkan` → `.ankan`／`.kakan`／`.minkan`；粗標籤 `kan` 維持 nil。
- 三麻 `AkagiSanmaBot` 依 `SanmaAction.Kind` 填同樣三種。
- 本地 Mortal 不動（nil）。
- executor `.kan`：取 recommendations 第一個 `.kan` 列的 `kanKind`
  - 有種類且 snapshot 含該 type → 送該 type
  - 有種類但 snapshot 不含 → event「未送出，保留 oplist」並 return nil（與牌字串轉不了、立直找不到宣言牌同一條 fail-closed 路徑）
  - 無種類 → 維持 `snapshot?.kanOperation ?? .ankan`
- 不碰 index／tile（WP5 live 抓包議題）。

## Deviations
- executor 的 `execute` 沒有收 `Recommendation` 本身，只收 `action`／`tile`／`recommendations`。為了不改 `AutoPlayEngine` 呼叫端，種類從 `recommendations` 中第一個 `.kan` 列取（同立直取宣言牌的既有做法）。保守理由：不擴大改動檔案；推測 resolver 送出 `.kan` 時，清單中第一個 `.kan` 列就是 bot 的槓建議。
- 雲端測試類別 `CloudDecisionMapperTests` 實際位於 `NakiTests/CloudInferenceTests.swift`，新測試加在該類別內。
- `mutate.py` 自建 `build-test/` derived data，跑完與 `build-wp5b/` 一併刪除。

## 驗收
- `xcodebuild test -only-testing:NakiTests`：Executed 877 tests, 0 failures（基準 872＋新增 5）。log `Naki/.swfd/logs/wp5b-kan-kind/test.log`。
- 變異：AutoPlayActionExecutor.swift 3／3 殺掉。log `Naki/.swfd/logs/wp5b-kan-kind/mutate.log`。mapper 與三麻 bot 的 switch 映射沒有產生變異體，由新增單測直接鎖。

## 補充回合：resolver 也看槓種
- `AutoPlayDecisionResolver.isSupported` 改收 `Recommendation`（唯一呼叫點在同檔 resolve），`.kan` 有 `kanKind` 時要求 snapshot 含該 type，沒有時維持 `kanOperation != nil`。
- 不合法時走既有的「退同批打牌／過，否則 none」路徑，沒有新分支。這讓 executor 的未授權拒送退為第二道防線，不再於 15 次重試中反覆觸發。
- 新測試：`testKanWithAuthorizedKindIsSent`、`testKanWithUnauthorizedKindFallsBack`、`testKanWithoutKindAcceptsAnyKan`。
- 驗收：NakiTests Executed 880, 0 failures（test2.log）；resolver 變異 1／1 殺掉（mutate2.log）。
