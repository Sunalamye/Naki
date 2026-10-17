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

守衛保證「已鎖定為 lobby 的連線上，同步可解析、經 `ctx.replace` 契約改寫的守衛方法不原樣外送」。原本七項不在保證內；sendRaw 退回對局、不經 `ctx.replace` 的就地改寫、Blob 空窗三項已於 2026-10-17 由 guard-gaps 修掉（見文末）。剩四項：lobby 上同步可辨識的 FastTest 不守衛（observer 只改得到副本，bridge 出錯時照送遊戲未被碰過的原內容；guard-gaps 第五輪前是拒送改壞的 bytes）、已鎖 game 的連線上 Naki 自送或遊戲自送的 Lobby 請求不守衛、unknown 上 Naki 解析不出而伺服器解得開的守衛方法照送、角色清除只靠接線呼叫 `closed`（`close` 與 `error` 都經 `release` 呼叫一次）。不宣稱 I2 全域成立。

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

## 2026-10-17 晚：已知限制不得只列不測（用戶裁決）

用戶看到 v2.20.0「已知限制」五條，指出其中多數明明可測可修。檢討：
- 「守衛真擋未 live 驗」是主線自己在 live 規則寫了「不換裝」造成的；同值 no-op（帳號已擁有且裝備中）不改伺服器狀態、不違反 I2，現已開例外並派 live。
- 「sendRaw 退回、就地改寫、Blob 空窗」三條是審查時以「保證範圍限定」收掉（D28／D29），沒有回頭補程式；現派 guard-gaps 修，不可修者要寫證明。
- 「改寫顯示值畫面是否跟著變」已由解鎖 v1 第二輪 live 驗過，只是沒回填。
- 「對局結束誤報、連線失敗清理」只缺 live 重現，派 known-limits-live。
- `injectReceive`／`respondLocally` 是功能缺口，排在上述之後另案。
規則：release note 的「已知限制」只能列**證明不可測或不可修**的項目，其餘要在下一版前驗掉或修掉。

## 2026-10-17 21:25 主線裁決：插件測試紀錄的頁尾完整性改由宿主見證

外部審查（解鎖 v1.1 第十輪）證明：隔離測試插件用 localStorage 的 tail／prev 鍵自證「final 之後沒有遺失行」不可靠——prev 是可過期快照、同 realm 可改、同 origin 多頁共用單鍵、寫失敗未 fail-closed；整輪最後一個 nav 更無任何見證。

裁決：Naki 新增 `__nakiPlugins.devLogSeal(pluginId, meta)`，由宿主落檔一行 seal（count 由宿主計、插件不可偽造），封存後該頁 devLog 一律拒收。插件側驗收改依 seal 行；匯入順序改依宿主時間戳排序、不可證則拒驗。

取捨：多一個宿主 API（小包 plugin-devlog-seal），換掉三個 localStorage 鍵與一整套可被繞過的頁面側證明；不選「操作者手動 quit App 當封存」是因為時序無法由紀錄本身證明。

## 2026-10-17 後續裁決：保證範圍三條改為修掉（guard-gaps）

用戶裁決「能修就修，不得只列限制」。D28–D30 三條改以程式修掉，只改 `naki-plugins.js`，`naki-websocket.js` 不動。設計細節在 `plugin-v2-b2.md` §1.4，判斷與 Deviations 在 `docs/archive/notes/guard-gaps-implementation-notes.md`。

| 原條 | 修法 | 與先前裁決的關係 |
|---|---|---|
| D28 `sendRaw` 退回 | 注入標記帶 msgId 與注入 envelope bytes，兩者都相同的送出派發才算注入；落到非大廳連線、方法屬 `GUARDABLE_METHODS` 且有守衛者 ⇒ `tainted_fallback` 擋下，結果與大廳 `naki_traffic` 相同 | 不改 `naki-websocket.js`；Naki 自送不受影響 |
| D29 就地改寫 | 非大廳連線上 hook 就地、經 `ctx.replace` 或在 thenable 的 `then` 裡同步改成 `GUARDABLE_METHODS` 即撤回、計 hook 失敗，只用閉包常數 | 不讀 `sendGuard`，第四輪第 2 條不受影響（`R5-2b` 綠） |
| D30 Blob 空窗 | 角色未定的連線比照 lobby，有守衛者時拒送 Blob | 推翻原「unknown fail-open」的這一處。獨立風險：只有 `authGame` 改用 Blob 時，對局連線持續被拒、角色持續 unknown、不會自行恢復，大廳照常（`GG2-5`）。保留拒送策略 |

Astra 第一輪（主 repo `.swfd/logs/guard-gaps-review/astra-review1.md`）：1【擋】5【應修】，主線全採納。擋 1 是 game 連線上的 `ctx.replace` 改成守衛方法仍外送，已併入 D29 的修法；其餘是注入標記綁定派發、常數先行排除、成功記帳順序、Blob 獨立風險揭露、補變異與固定回歸。

Astra 第二輪（`astra-review2.md`）：2【擋】1【應修】1【建議】，主線全採納。兩個擋是第二輪引入的回歸（`65a7865` 不會發生）：thenable 的 `then` 在驗證之後才執行、可同步改回守衛方法；注入標記可被注入前的同號派發用掉。修法：先接管 thenable 再驗證；注入以 msgId＋bytes 綁定，不再「用掉」。

Astra 第三輪（`astra-review3.md`）：1【擋】1【應修】1【建議】，主線全採納（根治而非再補一層驗證）。擋 1：驗證之後的失敗記帳仍執行插件程式碼（錯誤的 `message` getter、第 10 次的 `onDisable`），可把保留的 bytes 改成守衛方法外送。修法：每個 hook 驗證完成即定案送出快照，記帳後還原成快照；快照、撤回、還原用原生 `slice`／`set`。§1.4 第 2 項區分「本次外送內容」與「派發後改保留參照」，並另列「遊戲重用 buffer」前提。同日 rebase 到 main `ffe0670`，本 ADR 尾端兩段裁決並存。

Astra 第四輪（`astra-review4.md`）：2【擋】2【應修】，主線全採納並撤回第四輪 Deviation 13（「記帳後還原到快照、保留原物件同一性」與外送等價）：插件在副本實例上定義 `constructor`／`byteLength` getter，或後插件的 `onSend` getter 改前插件保留的 bytes，都能在快照之後改到實際外送內容。改採根治：送出鏈上插件只拿宿主副本，宿主只讀內部槽物化成自有快照再驗證，外送只用未外露的原物件或宿主快照。主線同時解除原 D28「`naki-websocket.js` 不得改」的限制（理由：Astra 兩輪證明同一性保留無法成立）；實作最後不需要改它，既有的「鏈回傳值取代原物件」路徑已足夠。

Astra 第五輪（`astra-review5.md`）：1【擋】1【建議】，主線全採納。擋 1：送出 `ctx.replace` 以 `new Uint8Array(newBytes)` 包裝插件的 `ArrayBuffer`／SAB／resizable，與插件共用記憶體；入口驗過後插件改成 SKIN 或改 msgId，hook 結束因 `replaced` 跳過守衛檢查，照樣外送。修法：入口先以宿主 `hostCopy` 物化，只收 TypedArray，驗證與採用同一份；hook 結束一律完整重驗。receive 變長 `replace` 一併先物化。建議 2 的入口型別矩陣以測試固定，表列在 notes 第六輪。

Astra 第六輪（`astra-review6.md`）：2【擋】2【應修】1【建議】，主線全採納，撤回 notes Deviation 22、24。擋 2（主裁決）：就地改不得換 method，換 method 只能經 `replace` 走完整 `rewriteSend` 規則；同時消除應修 3 的回應配對過期。擋 1：鏈尾對最終候選以目前狀態終判（送出禁改名單、type／msgId、守衛規則），不過就整筆退回遊戲原內容並記在最後改動的 hook；大廳上鏈中才出現的守衛者（註冊或經同步 receive 重入污染）未在鏈上放行，視同 `not_on_chain` 擋下。應修 4：receive 等長 `replace` 先物化，以實際長度選路。建議 5：本 ADR 保證範圍段與設計 §1.4 第 4 項更正。

Astra 第七輪（`astra-review7.md`）：1【擋】4【應修】，主線全採納，notes Deviation 26–34 採納。擋 1：守衛的放行沒有綁定狀態，守衛者在同一筆送出中被污染（含另一條大廳連線、實際 local-unlock 插件的 2301）或同 id 重新註冊後，舊放行仍有效。修法：放行綁定註冊實例代號與污染版本，鏈尾不符即 `not_on_chain`。應修：成功記帳等本筆鏈尾判定（鏈尾違規可累計到自動停用）；歸責用 register 時固定的 id；未污染守衛者在鏈中全部退出時本筆解除守衛、送原請求；就地改與等長 receive `replace` 補結構檢查。

Astra 第八輪（`astra-review8.md`）：2【應修】1【建議】，主線全採納，notes Deviation 35–43 採納。應修 1：解除守衛退回原請求時，回應配對仍是被撤回的新 method；改為守衛判決後依實際上 wire 的內容提交。應修 2：記帳以 id 查表，舊實例能重設或停用同 id 的新實例；改為記帳一律綁註冊實例，實例已換掉就丟棄。建議 3：契約補「退出前已拋錯／回 thenable 的守衛者否決仍有效」。

Astra 第九輪（`astra-review9.md`）：2【應修】1【建議】，主線全採納，notes Deviation 44–47 採納（45 前提被推翻、改寫）。應修 1：本地結案在遊戲回呼之後刪配對，會刪掉遊戲在合成錯誤回呼內以同 msgId 新送請求的配對；改為擋下當下撤銷被擋請求的配對、擋下不提交配對，本地結案不碰配對。應修 2：`disable` 尾端無條件清失敗計數與 grant，會清掉 `onDisable` 內同 id 新註冊的實例；改為 registry 沒有同 id 新實例時才清。建議 3：§1.4 區分原請求解析失敗（照送，殘餘風險）與 hook 產生的解析不出改寫（撤回）。

Astra 第十輪（`astra-review10.md`）：1【應修】1【建議】，主線全採納，notes Deviation 48–51 採納。應修 1（既有缺口，屬本包「配對依實際外送內容」範圍）：bridge 故障退回原 bytes 時，配對仍停在 `replace` 後的 method；改為 `failSafe` 照送的每個出口把配對改回原請求，擋下的出口仍撤銷。建議 2：Dev 49–51 的邊界收進固定回歸，並在 §1.4 明載跨來源 msgId 碰撞沒有配對隔離。
