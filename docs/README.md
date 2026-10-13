# Naki 文件索引

**最後核對**：2026-10-13  
**原則**：本索引只列目前可用的文件；Laya、DesktopMgr、座標點擊與過渡期調查不再提供入口。

## 先看哪一份

| 需求 | 文件 |
|------|------|
| Unity、Liqi、Mortal、自動打牌、自摸與高亮的 current truth | [majsoul-unity-protocol.md](majsoul-unity-protocol.md) |
| Naki Swift／JS 元件與資料流 | [architecture-deep-dive.md](architecture-deep-dive.md) |
| 當前 `lqc.lqbin` 下載、hash 與解析結果 | [majsoul-config-tables.md](majsoul-config-tables.md) |
| MCP 工具清單與安全用法 | [mcp-server-guide.md](mcp-server-guide.md) |
| HTTP Debug API | [debug-api-help-endpoint.md](debug-api-help-endpoint.md) |
| Liqi field schema | [protocol/liqi.json](protocol/liqi.json) |
| Shell 工具約定 | [shell-tools-guide.md](shell-tools-guide.md) |
| 插件 API 契約（`apiVersion: 1`） | [plugin-api-v1.md](plugin-api-v1.md) |
| 插件系統設計、授權與風險 | [plugin-system-design.md](plugin-system-design.md) |
| iOS 插件診斷 | [ios-plugin-debugging.md](ios-plugin-debugging.md) |
| Unity wasm heap 存取（隱藏名稱的來由） | [unity-heap-access.md](unity-heap-access.md) |
| Akagi 雲端推論 API 外部參考 | [reference/akagi-inference-api.md](reference/akagi-inference-api.md) |
| 雲端推論設計（as-implemented）與決策 | [cloud-inference-plan.md](cloud-inference-plan.md)、[cloud-inference-decisions.md](cloud-inference-decisions.md) |

Repo 根目錄另有：

- [`README.md`](../README.md)：使用者導向的產品說明。
- [`CLAUDE.md`](../CLAUDE.md)：agent 操作邊界與 current facts。
- [`AUDIT.md`](../AUDIT.md)：目前驗證差距與完成判準。
- [`RELEASE.md`](../RELEASE.md)：release 流程。

## Current baseline

- 雀魂 live client：Unity WebGL `chs_t-WebGL-release-4.0.45(45)`。
- 狀態與動作：Liqi protobuf；Laya globals 不存在。
- AI：MortalSwift 釘在 0.6.0／`da7238c`（lockfile 已提交），但 bundled 權重未更新，沒有「最強」benchmark。
- 四麻：有固定 parity fixtures。三麻：本地 `AkagiSanmaBot`（MortalSwift `AkagiSanma`，模仿天鳳人類，強度不是 Mortal 等級），2026-10-09 三局 live 已驗。
- 自摸：recommendation gate 與 send-result 兩個 P0 在 source 層已收斂（`AUDIT.md` 為準），仍缺 live 對局驗證。
- MCP：靜態註冊 40 個工具（2026-10-13 計數；現行數字一律現查 `tools/list`）。
- 配置：2026-08-01 live manifest fresh parse 為 41 tables／263 sheets／119,289 rows。

## 文件維護規則

1. 先以 Naki loopback API 或當前程式碼查證，再更新文件。
2. runtime 事實附日期與 client／resource version。
3. 「sendRaw 成功」「server RESPONSE」「權威 action」分三層描述。
4. 單元測試、live 對局、視覺驗收與牌力 benchmark 不互相替代。
5. 被 current code 推翻的內容直接移除；歷史需要時從 git history 取回，不在 active docs 內保留兩套說法。

## 設計與審查紀錄（有日期的決策，非每項都是現況）

| 文件 | 內容 |
|------|------|
| [design-review-2026-10-12-decisions.md](design-review-2026-10-12-decisions.md) | 2026-10-12 設計審查的裁決、工作包與各包結果；§7 為文件漂移總表 |
| [design-review-vs-akagi.md](design-review-vs-akagi.md) | 2026-08-01 對照 Akagi v3 的架構檢討 |
| [akagi-audit-p0-decisions.md](akagi-audit-p0-decisions.md) | 2026-08-07 掃 Akagi issue 對照出的三個 P0 的修法決策 |
| [pluggable-bots-plan.md](pluggable-bots-plan.md) | 2026-08-01 可選 AI 的實作計畫（第 1、2 層已落地） |
| [plugin-live-test-notes.md](plugin-live-test-notes.md) | 2026-08-11 插件系統人機場 live 實測筆記 |
| [cleanup-2026-08-06.md](cleanup-2026-08-06.md) | 2026-08-06 清理輪：credential 遮蔽、死碼、考古註釋 |
| [ui-reference/implementation-decisions.md](ui-reference/implementation-decisions.md) | 2026-08-09 UI 重設計的實作決策與實測發現（原型與各動作狀態截圖在 `ui-reference/`） |
| [ui-reference/action-states/README.md](ui-reference/action-states/README.md) | 動作狀態視覺參考的範圍與交付清單（英文；內含 `prototype.html`、`rendered/` 各狀態 PNG、牌面 sprite） |

## 歷史工作紀錄（非 current truth）

下列 `*-implementation-notes.md` 在 repo 根目錄，是各工作包當時的實作筆記：記錄做了什麼、為什麼、偏離了什麼，**不代表現況**。查現況先看上面的 current truth 文件與原始碼。專案 `CLAUDE.md` 要求每個工作包維護對應的筆記，所以不搬檔。

| 檔案 | 主題（日期） |
|------|------|
| [code-audit-implementation-notes.md](../code-audit-implementation-notes.md) | 全程式碼審查與修正（2026-09-30） |
| [reverify-implementation-notes.md](../reverify-implementation-notes.md) | 全程式碼復驗與變異測試（2026-10-08） |
| [l10n-implementation-notes.md](../l10n-implementation-notes.md) | 多國語系（2026-10-01） |
| [update-check-implementation-notes.md](../update-check-implementation-notes.md) | App 更新提醒（2026-10-01） |
| [sanma-implementation-notes.md](../sanma-implementation-notes.md) | 三麻本地推論與 Akagi 同步（2026-10-09） |
| [kita-retry-implementation-notes.md](../kita-retry-implementation-notes.md) | 拔北請求與重試風暴（2026-10-09） |
| [endpoint-guard-implementation-notes.md](../endpoint-guard-implementation-notes.md) | Debug endpoint 防護 |
| [h1-headers-implementation-notes.md](../h1-headers-implementation-notes.md) | 雀魂連線 User-Agent／header |
| [wp3-cloud-errors-implementation-notes.md](../wp3-cloud-errors-implementation-notes.md) | 雲端錯誤提示 |
| [wp5-kan-select-implementation-notes.md](../wp5-kan-select-implementation-notes.md) | 槓 selector 協定調查 |
| [wp5b-kan-kind-implementation-notes.md](../wp5b-kan-kind-implementation-notes.md) | 暗槓與加槓並存時的槓種 |
| [wp6b-sync-newround-implementation-notes.md](../wp6b-sync-newround-implementation-notes.md) | 重連同步與新局 |

## 其他資源

- release-notes：各版本發行說明（[v2.9.0](release-notes/v2.9.0.md)、[v2.10.0](release-notes/v2.10.0.md)、[v2.15.0](release-notes/v2.15.0.md)、[v2.16.0](release-notes/v2.16.0.md)）。
- [third-party/riichi-mahjong-tiles.md](third-party/riichi-mahjong-tiles.md)：牌面素材來源與授權（CC0）。
- [replay-baseline.txt](replay-baseline.txt)：錄影決策指紋清單（每行：錄影檔名、數個統計欄位、指紋；2026-08-01 起）。與 `scripts/replay-check.sh --baseline` 的格式是否一致，未驗證。
- [images/](images/)：README 使用的截圖。
