# ADR：送出守衛第五輪（協定握手鎖定連線角色）

日期：2026-10-17。分支 `pv2-b2-design`，commit `54c1983`（未 push、未合併）。
審查原文：主 repo `.swfd/logs/pv2-b2-review/astra-review5.md`。設計者回應：`docs/archive/review/plugin-v2-b2-review-response.md` 第五輪段。

## 用戶裁決

- 解除第四輪停損。守衛改以協定握手鎖定連線角色，URL 不再參與判定；不做整體架構抽象化。
- D22（Naki 自送身分只看 msgId）維持另開工作包。

## 依據的 live 事實（2026-10-17，測試帳號，`.swfd/logs/unlock-handshake-20261017/`）

每條連線第一個請求是 `.lq.Route.requestConnection`，第二個揭露角色：`/gateway` 是 `.lq.Lobby.oauth2Login` 或備援的 `.lq.Lobby.prepareLogin`；`/game-gateway` 是 `.lq.FastTest.authGame`。遊戲 msgId 計數器全域跨連線遞增，同一時刻不同連線不撞號。對局結束後重連序列相同；對局中途重連未觀察（推論同）。

## 審查結果與裁決

Astra 第五輪：0【擋】、6【應修】、0【建議】。第四輪三條：1 已修、2 部分（對應新 5）、3 已修。設計者六條全採納、0 反駁，反駁率 0，不觸發重讀。主線逐條檢視是否過度採納：

| 條 | 內容 | 採納方式 | 主線判定 |
|---|---|---|---|
| 1 | `sendRaw` 無大廳候選時退回 game，共存插件 `sendRequest` 可外送 | 保證範圍限定（D28） | 外送類，`naki-websocket.js` 不得改，限定正確 |
| 2 | 不經 `ctx.replace` 的就地改寫不檢查 | 保證範圍限定（D29），撤回「屬 U4」 | 加檢查會讓現行鏈重讀 sendGuard，與第四輪第 2 條衝突；限定正確 |
| 3 | 首筆 Lobby Blob 在 unknown 外送，之後才鎖 lobby | 文件限定（D30），不採程式修法 | 程式修法（unknown 上拒 Blob）違反「unknown fail-open」裁決，且客戶端送 TypedArray 是整個守衛的前提；採納 |
| 4 | D27 名單不能單獨證明 I2 | 文件論證修正（D31），接上 `unlock-plugin.md` §3.7 | 正確，本設計不單獨宣稱 I2 |
| 5 | D26 繞過須限定封包形態 | 文件限定（D32） | 改程式要多一條跨呼叫狀態，live 未見 lobby 上 FastTest，YAGNI 成立 |
| 6 | M3 無零插件紅證據 | 補五個變異（D33），並修 D27 只看原方法 | 修改正確：出錯時實際送出的是還原後的原 bytes，改寫後方法與送出內容無關 |

## 驗證（主 repo `.swfd/logs/pv2-b2-design/round5*-*.log`）

plugin-v2-b2 61／61、plugin-regression 29／29、plugin-v2-regression 21／21、變異 13／13 被抓、PluginSendGuardTests 11／11、NakiTests 全量 1149／0（round5，第五輪 b 未改 Swift 故未重跑）、接線 patch `git apply --check` 通過。Astra 自行重跑 node 三套與八個變異一致。

## 保證範圍（設計 §1.4，確認稿必須逐條揭露）

守衛保證「已鎖定為 lobby 的連線上，同步可解析、經 `ctx.replace` 契約改寫的守衛方法不原樣外送」。七項不在保證內：sendRaw 退回對局、不經 `ctx.replace` 的就地改寫、Blob 空窗、lobby 上被改壞的 FastTest 會被拒送、已鎖 game 的連線上的 Lobby 請求不守衛、unknown 上 Naki 解析不出而伺服器解得開的守衛方法照送、角色清除只靠接線呼叫 `closed`。不宣稱 I2 全域成立。

## 下一個節點

「向用戶確認接線與 Swift 配對改動」：接線 patch（`.swfd/logs/pv2-b2-design/proposed-ws-send-wiring.patch`）尚未套用，`naki-websocket.js` 未改，守衛在 App 內目前不生效。Swift 配對改動（`pendingRequests` 以連線＋msgId 為鍵，範圍比放行清單多兩個檔案，D12）仍待用戶確認。分支基底 `4761f6e` 落後 main `fd74f63`，套用後需 rebase 並在 main 上重跑全量。

## 未驗證

live、WebKit runtime、App 內行為；對局中途重連握手；錯誤碼 6 在遊戲端的表現；大廳換裝請求落在哪條 `/gateway`。

## 用戶裁決（第二次，2026-10-17）

1. 套用送出守衛的接線 patch（`naki-websocket.js`）。
2. 接受 Swift 配對改動（`pendingRequests` 以「連線＋msgId」為鍵，socketId 傳到 `LiqiParser.parse`）。
3. 測試通過後先 live 驗證再合併 main。

## live 結果（2026-10-17，測試帳號，主 repo `.swfd/logs/pv2-b2-live/`）

接線後 e5852ea Debug build，兩局人機。已驗：角色鎖定與握手一致（兩條 `/gateway` 為 lobby、`/game-gateway` 為 game、關閉即清）；守衛者在場時大廳心跳、Naki 自送 `lobby_server_time`、自動打牌（每筆 inputOperation 有 RESPONSE）不受影響；停用守衛者後不誤擋；`register` 在 live 拒絕不可守衛方法。

**未驗證：守衛「真的擋下」。** `GUARDABLE_METHODS` 19 個全是換裝、稱號、角色、領獎類，I2 禁止對真伺服器送出，主線不授權用無效 payload 試；本機 sink 變體被 WebKit 擋下（https 頁面連 `ws://127.0.0.1` 只得 readyState 3）。實擋目前只有 `PluginSendGuardTests` 11、`plugin-v2-b2-regression` 60、變異 13 覆蓋。裁決全文 `.swfd/logs/pv2-b2-live/decision-live-guard-test.md`。

合併：用戶裁決 2026-10-17 合併進 main 並移除 worktree；確認稿與發版說明須揭露上述未驗證項與 §1.4 七項限定。

連線失敗不觸發 close 的殘留已於 fix/ws-error-cleanup 修正（commit 見該分支，error 且 readyState 為 CLOSED 時與 close 同路徑清理，只執行一次）。

## 2026-10-17 後續裁決：守衛名單擴充與插件主動污染

解鎖插件 v1 盤點 `liqi.json` 後找出 13 個不在 `GUARDABLE_METHODS`、但請求可能帶入補進外觀 id 的大廳方法（聊天、好友訊息、client message、logReport 表情、活動角色、建房與賽事的 extendinfo），以及兩個對局連線方法（`broadcastInGame`、`inputGameGMCommand`）。

- **不立刻擴充名單**。守衛是 fail-closed：污染後這些方法到頁面重載都不送，把聊天與建房加進去等於啟用解鎖插件就不能聊天、不能開房。先在 v2.20.0 上 live 只觀察不點擊，看遊戲是否真的把補進的 id 送進這些入口，再依證據決定擴充哪幾個。
- **對局連線守衛延後**。守衛結構上只在大廳連線；要不要支援 FastTest 另案。
- **先做插件主動污染 API 與污染查詢契約**（工作包 guard-taint-api）：讓插件在任何改寫前自行標污染，不必依賴「大廳改寫一次」或未記載的 `guardState()`。這是純增加、不改既有行為，且不受 live 結果影響。
