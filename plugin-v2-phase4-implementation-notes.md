# plugin-v2 Phase 4 implementation notes

分支 `plugin-v2-phase4`，基於 main `2d02a03`。設計：`docs/plan/plugin-v2-phase4.md`。log：`.swfd/logs/p4/`。

## 授權

- 用戶 2026-10-17 裁決開工，主線派工。CLAUDE.md「修改 WebSocket bridge 前先確認」由這次派工涵蓋，範圍限 spike 分支，不合併、不 push。

## 改了什麼

| 檔案 | 改動 |
|---|---|
| `naki-websocket.js` | message listener 改 capture；`localEvents` 改名 `syntheticEvents`，本地回應與變長改寫共用；新增 `deliverReshaped`、頁面鎖死、`diagnostics().reshape` |
| `naki-plugins.js` | `ctx.replace` 長度不等時整包替換；`ctx.drop`（NOTIFY、`dropReceive`、L3）；`isReshapeForbidden`；鏈的 drop 短路與拋錯撤回；drop 也觸發污染；`isWellFormed` 允許 RESPONSE 省略 field 1；`api.reshapeLocked` |
| `scripts/plugin-v2-p4-regression.cjs` | 新增，17 條，三種假 dispatcher |
| `scripts/plugin-v2-regression.cjs` | 第 8 條拿掉「receive 只能等長」的斷言，那是本包刻意改掉的契約 |
| `NakiTests/JSContractTests.swift` | 新增 `testMessageListenerIsRegisteredInCapturePhase` |
| 文件 | `docs/plan/plugin-v2-phase4.md`（新增）、`docs/plugin-api-v1.md`「v2 Phase 4（草案）」段、`docs/plugin-system-design.md` §11 #6 gate 文字 |

## 驗證

| 項目 | 結果 | log |
|---|---|---|
| `plugin-v2-p4-regression` | 17／17 | 指令輸出 |
| `plugin-v2-regression` | 21／21 | 同上 |
| `plugin-v2-b2-regression` | 68／68 | 同上 |
| `plugin-regression ../naki-plugins` | 38／38 | 同上 |
| `keepalive-regression` | 11／11 | 同上 |
| JS 變異 | 16／16 被抓 | `mutation.log`、`mutate.cjs` |
| `JSContractTests`＋`NakiWebSocketScriptTests` | 19／0 | `targeted-tests.log` |
| Swift 變異（拿掉 capture） | 新測試變紅 | `swift-mutation-capture.log` |
| NakiTests 全量 | 1179／0 | `test-full.log` |

## 未驗證

- 沒有 live：WebKit 實際派發、大廳連線、遊戲吃變長內容、`window` `error` 是否同步。
- 沒跑 `replay-check.sh`、`soak-test.sh`。
- `injectReceive`、`respondLocally` 未實作。

## Deviations

1. **禁改名單放寬為全部 `.lq.FastTest.*`**。派工列的是 `authGame`、`syncGame`、`enterGame`。probe 樣本只有 heartbeat，其他對局 RESPONSE（例如 `inputOperation`）也是自動打牌的依據，選較嚴的一側。
2. **receive `drop` 只限 NOTIFY**。`plugin-v2.md` §1 寫 drop 用於 receive 與 send，沒有限 type。RESPONSE 被丟遊戲會一直等，與 send 側不給裸 drop 同理。
3. **`dropReceive` 受 L3 總開關把關**。`plugin-v2.md` §4.5 #7 的 L3 清單沒有列 `dropReceive`，`plugin-system-design.md` §8.1 有列。兩者不一致，採較嚴的 §8.1。
4. **Blob 原事件維持 observe-only**。非同步展開後再重派會讓後續訊息先交付。
5. **RESPONSE 的變長 replace 不得帶非空 method**。canonical re-encode 只會省略空 field 1，不會寫出 method。帶 method 的 RESPONSE 遊戲端行為未知，直接拒絕。
6. **`rewriteAllow` 解不開變長改寫的禁改名單**。等長仍可解，維持 v1。
7. **鎖死 log 經 `naki-plugins` 的 `pluginLog` 送出**。`BridgeMessageContractTests.testSenderPayloadsUseSocketIdField` 要求 `naki-websocket.js` 送 Swift 的每則訊息都帶 `socketId`，不帶 `id`。第一版直接送 `plugin_event` 被它擋下，改成 `__nakiPlugins.reshapeLocked()`。
8. **變長 replace 是 L2**。沿用 `plugin-v2.md` §4.2，不自行升級；是否升 L3 列入未決問題。
9. **派工說「三套既有 node」**。repo 實有四套（含 `keepalive-regression`），四套都跑。

## 給下一輪

- 未決問題清單在設計 §8。
- 合併前的 live 驗收在設計 §7 末段。
