# ADR：送出守衛第五輪（協定握手鎖定連線角色）

日期：2026-10-17。分支 `pv2-b2-design`，commit `54c1983`（未 push、未合併）。
審查原文：主 repo `.swfd/logs/pv2-b2-review/astra-review5.md`。設計者回應：`docs/plan/plugin-v2-b2-review-response.md` 第五輪段。

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
