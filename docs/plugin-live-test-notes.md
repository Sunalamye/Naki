# Plugin 系統 — 人機場 live 實測筆記（D）

以**執行中的 Naki loopback（8765）+ 截圖 + 現行程式碼**為準；不採信先前 session 的完成宣稱。
測試日：2026-08-11。房間：友人場・四人東（room_quick_test 建房補三人機 + bot_sync 進場）。
帳號為使用者測試帳號。

## 已 live 驗證通過（資料路徑）

- 插件 runtime／熱插拔 `setGrant`／`__nakiHighlight.set`／`setNameMask`／`__nakiHideNames`／canvas 全活（`/js` probe）。
- 兩插件（naki-plugin-ex-name-hider、tile-highlighter）注入 + 註冊：`__nakiPlugins.list()` 回兩筆。
- JS→Swift `plugin_event` bridge：Swift log 出現 `[Plugin] …registered`、`setNameMask(true)`、`highlight <tile> p=…`。
- 兩插件在 live 對局 `onReceive` 觸發：name-hider 呼叫 setNameMask、tile-highlighter 讀 `__nakiRecommendations` 挑最高機率打牌呼叫 set。

## 視覺效果：人機場**未通過**，兩個不同根因

### 1. 牌面變色 — 內建高亮未移除，覆蓋插件

- `WebSession.syncHighlight()`（L275）每次推薦更新都注入 `GameHighlightScript.make(...)`，
  即 `window.__nakiHighlight.set([top→綠[0.45,1,0.5]，其餘→灰[0.62,0.62,0.68,0.55]])`。
- live `__nakiHighlight.state().targets` 抓到的正是這組綠+灰（非插件的綠 `[0.2,1,0.4]`）。
- 結論：畫面上的變色是**內建 `GameHighlightScript`** 畫的，插件的 set() 被 syncHighlight 覆蓋。
- 先前 session 記為「已移除內建、改由插件接管」——與現行程式碼**不符**，該改動疑似在
  working-tree divergence 中遺失（摘要已多次記錄同類事故）。
- 修法（需 Swift 改 + rebuild + 重驗）：讓 `GameHighlightScript.make` 的自動高亮收斂
  （保留 `__nakiHighlight` API，只拿掉自動驅動的 set），插件才能真正接管顏色。

### 2. 暱稱隱藏 — 渲染層校準在人機場認錯 draw

- 插件正確呼叫 `setNameMask(true)`；`nameMaskStatus()` 回 `enabled:true`。
- 但 `targets` 指到的 draw **不是**人機場玩家名：`maskProbe` 掃 ord 0/1/3/4，
  四張截圖名字（「電腦（簡單）」×3、「明天吃飯」）**全都仍可見**。
- 幾何校準（少像素 + ≥3 象限）在人機場挑錯——人機名為客戶端生成，draw 特徵與真人不同。
- CLAUDE.md 早記渲染層名字遮罩只在**銅之間（真人）** live 驗過；人機場屬已知難題。
- 另有**插件層真 bug**：原 name-hider 在 `authGame`（牌桌未渲染）就呼叫 setNameMask，
  之後 `lastApplied` dedup 永不重試 → 校準對空畫面跑必敗。

  已修（本機驗證重試邏輯，尚未 push）：改為「未認出名字（`nameMaskStatus().targets===0`）
  且非校準中就重試 setNameMask，認出才停」。此修法讓它在渲染層已驗證的房間（銅之間）能運作；
  人機場仍受核心校準限制。re-arm 測試證實：牌桌渲染後手動 re-arm，`targets:1`、
  `masked` 遞增——校準機制本身可跑，只是**選錯 draw**。

## Deviations（偏離計畫時選保守選項）

- **不在 live session 盲改 `naki-core.js` 的名字幾何校準。** 那段是 hard-won（shader／貼圖／
  字數都試過不穩，最後才收斂到幾何），且動它會波及**銅之間已驗證**的行為，live 無法完整
  regression。保守做法：先只修插件層 bug，把人機場核心校準當獨立 scoped 任務交由使用者定奪。
- **不自動 push name-hider 修法到 naki-plugins repo。** 全域規則：commit 前確認 why、不自動 push。
- **不自動移除內建 `GameHighlightScript` 高亮。** 那會拿掉「未裝插件的使用者」看得到的推薦顏色，
  是行為變更；雖與先前（遺失的）決策一致，仍先向使用者確認再 rebuild。

## 待決策（都需動核心/ rebuild，故停下請示）

1. 是否重新套用「移除內建自動高亮、保留 API」——讓插件真正接管牌面變色。
2. 人機場暱稱隱藏是否要做（改 naki-core.js 校準辨識人機名，較深、風險較高），或只需銅之間（已驗證）即可。
3. name-hider 插件修法是否 commit + push 到 naki-plugins repo。
