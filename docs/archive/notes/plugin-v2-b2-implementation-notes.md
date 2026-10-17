# 插件 v2：送出守衛（N1、N2）與 PV2-B2 實作筆記

**設計**：`docs/archive/plan/plugin-v2-b2.md`
**分支**：`pv2-b2-design`（worktree `Naki-wt-pv2b2`，基準 main `4761f6e`；wip `ccd1e0b` 與第五輪 commit，未合併、未 rebase）
**log**：主 repo `.swfd/logs/pv2-b2-design/`

## 範圍

- 設計：N1、N2、PV2-B2 四個原語、Phase 4 gate 判定、工作包切分。
- spike：N1 的污染狀態持續生效、N2 對守衛方法的 fail-closed、錯誤回應建構、每筆 msgId 結局紀錄（`naki-plugins.js`）；manifest `sendGuard`（`PluginRegistry.swift`）；node 與 XCTest。
- 不做：變長 replace、drop、`injectReceive`、`respondLocally`、插件頁 UI。

## 決策

1. **污染狀態放 `naki-plugins.js` 閉包**：送出判定要在 `ws.send` 內同步完成，Swift 無法同步否決；閉包是插件碰不到、`disable`／`setGrant` 也不清的位置。Swift 只收 `plugin_event`（`kind: 'tainted'`）。
2. **判定放在整條鏈之後**：`dispatch` 先算守衛者，跑鏈時記每個守衛者放行或拋錯，最後由 `guardVerdict` 一次判定。現行鏈的程式碼原樣搬進 `runChain`，fail-open 的還原邏輯不變。
3. **錯誤回應只寫 `Error{code}`**：19 個守衛方法的 Res 型別 field 1 都是 `Error`（`liqi.json` 以 python 盤點，Lobby 419 個方法中另有 19 個不是）。
4. **錯誤碼暫定 6**：非 0、非 session 層、伺服器實際回過。遊戲端行為需 live。
5. **`dispatch` 早退條件改成「registry 空且無污染」**：否則插件全部停用後守衛直接失效（變異 M10 驗證）。

## Deviations

| # | 偏離 | 採用的保守選項 | 理由 |
|---|---|---|---|
| D1 | 派工允許改 `naki-websocket.js`，但 spike **沒有改** | 接線改動寫成 patch（`.swfd/logs/pv2-b2-design/proposed-ws-send-wiring.patch`），node 測試在記憶體套用；另有一條測試鎖住「不套 patch 時守衛無效」 | CLAUDE.md「修改 WebSocket bridge 前先確認」，且 `plugin-v2-adr-2026-10-14.md` 主線決定「動到 `ws.send` 接線前先向用戶確認」；派工訊息不是用戶確認，也沒有確認證據 |
| D2 | 污染觸發比 `unlock-plugin.md` §8.2 寬：任何成功改動大廳訊息的 `onReceive`（含等長、直接改 `ctx.bytes`）都算 | 寬的那一邊 | 等長改寫同樣能讓大廳顯示未擁有項目；寧可多守 |
| D3 | 守衛方法被任何插件改寫 ⇒ 擋下 | 擋下 | 守衛者放行的是改寫前的 bytes |
| D4 | 有守衛者時，isNaki（Naki 自送、插件號段）的守衛方法也擋下 | 擋下；第二輪改為不跑鏈、獨立擋下（`naki_traffic`） | I2「伺服器永遠不收到未擁有物品的請求」不分來源。第一輪的理由「isNaki 不跑 hook」不成立：`observeNakiTraffic` 的 observer 會跑（審查第 6 條） |
| D5 | `sendGuard` 的方法檢查放在 JS `register`，不在 Swift manifest 驗證；第二輪由禁改名單改為 19 個方法的允許名單 | 拒絕註冊並記 log | 只維護一份名單；代價是這種插件在 Swift 端顯示為有效但不會註冊（插件不跑，等同未啟用，不會污染）。插件頁要顯示拒絕原因（N1 工作包） |
| D6 | 錯誤碼沒有 live 依據 | 暫定 6，單一常數 | 見決策 4；live 驗收在設計 §7.3 第 2 項，該步驟不送任何守衛方法給伺服器 |
| D7 | receive `drop` 收窄成只對 NOTIFY | 只設計 NOTIFY | drop RESPONSE 會讓遊戲卡住、Swift `pendingRequests` 不清；與送出側不給裸 drop 同理 |
| D9 | Blob 拒送範圍比審查要求寬：已註冊未污染的守衛者存在時也拒送 | 寬的那一邊 | 否則守衛方法可經 Blob 繞過 N2，設計 §7.3 的「不外送」不成立；Unity 送 TypedArray，預期無影響（未 live 驗證） |
| D10 | 第 9 條沒有證明 msgId 跨連線唯一，而是改 Swift 的收件時點 | REQUEST 與合成 RESPONSE 在同一個 task 連續送 Swift | 第三輪起只作同一連線內的補充；跨連線由 `LiqiParser` 的連線維度配對處理（D12），「不需改 parser」的說法撤回 |
| D11 | R2 第一次紅只證明 unhandled rejection（測試 helper 未回傳 hook 值） | 以重建修前行為的變異補紅證據 | 修前的 spike 原檔未另存，無法原樣重跑 |
| D12 | 主線放行的是 `LiqiParser`（與必要的 `LiqiResponseStore`）；實際另改了 `MajsoulBridge` 兩個簽名與 `WebSocketInterceptor` 兩個呼叫點 | 最小改動：只加 `socketId` 參數（預設 0），不改其他行為 | 不把 `socketId` 從 bridge 訊息傳進 parser，就無法依連線隔離；改動面仍在配對狀態範圍內 |
| D13 | （已由 D17、D18 改寫）有守衛者時，Naki 內部錯誤會擋下任何方法 | — | 擴及對局連線，審查第三輪第 1 條判為【擋】 |
| D14 | 「改寫成守衛方法」在 `replace` 階段拒絕，而不是依原方法型別合成錯誤 | 拒絕改寫，原請求照送 | 原方法未守衛，照送不違反 I2；依任意原型別合錯誤需要 schema（PV2-C） |
| D15 | （已撤回，見 D19）成對交付的反方向以「不可能」處理 | — | 論證錯誤：core 吞掉 `postMessage` 例外，不等於送達 |
| D16 | thenable 回傳 fulfil 時計為成功 | 計為成功 | hook 本身沒有失敗；只是守衛不接受非同步放行 |
| D17 | 用戶裁決（2026-10-15）：守衛只作用在已確認的大廳連線（`/gateway`；判定方式已由 D25 改為握手鎖定）；對局連線與 `.lq.FastTest.*` 在守衛查找前繞過。第四輪審查若仍有【擋】，解鎖 v1 暫停 | 照裁決 | 審查第三輪第 1 條：D13 的拒送擴及對局動作 |
| D18 | D13 改寫：大廳上已知非守衛方法遇內部錯誤時還原原 bytes 照送；只有守衛方法或「無法辨識且有守衛者」才拒送 | 照主線指示 | 拒送範圍只留在無法判斷的情況 |
| D19 | D15 撤回；成對交付改為單一 bridge 訊息（`localResponse` 欄位），Swift 兩份都解得開才處理 | 單一訊息 | Astra 以正式 `sendToSwift` 重現兩種半套；core 吞掉 `postMessage` 例外，JS 無從確認送達 |
| D20 | 為了成對處理，`WebSocketInterceptor.handleWebSocketMessage` 再改：抽出 `handleReceived`；`majsoulBridge` 改 `private(set)` 供測試 | 最小改動 | 原子處理必須在 Swift 端；測試需要讀 `lastParsed` |
| D21 | 就地改寫成守衛方法：撤回並計插件失敗，照原樣送出（不再擋下） | 照審查第三輪第 5 條 | 擋下且無回應會讓心跳之類的請求失敗 |
| D22 | Naki 身分只看 msgId 的缺口另開工作包，本輪只證明在守衛範圍內的後果是多擋 | 照主線指示 | 見設計 §4.6 |
| D23 | （已由 D27 改寫）大廳上守衛查找持續拋錯時，大廳所有非 FastTest 請求（含心跳）都被拒送 | 接受，記為已知風險 | 主線規則「已確認大廳連線上無法辨識才拒送」的直接結果；只有插件 grant 壞掉才會發生 |
| D8 | PV2-B2 拆成 B2a（變長 replace＋respondLocally）與選做的 B2b（drop＋injectReceive） | 先做有消費者的 | 解鎖插件不需要 drop 與 injectReceive（`unlock-plugin.md` N4）；少一個主路徑改動 |
| D25 | 用戶裁決（2026-10-17）：連線角色由協定握手鎖定，URL 不參與。第一個 `.lq.Lobby.*` 請求 ⇒ lobby、第一個 `.lq.FastTest.*` ⇒ game、`.lq.Route.*` 不改、鎖定後不變、關閉清除；只有 lobby 進守衛 | unknown 與 game fail-open；鎖定放在 `dispatch` 第一步，早於零插件早退與守衛判定；`failSafe` 也鎖定；unknown 上解析失敗的請求與 Blob 照送 | 取捨：解析 URL 比對 pathname 仍是形狀假設，而 live 已證實第二個請求揭露角色。代價是設計 §1.4 的保證範圍限定（D28–D32）。零插件時每條連線多解析到鎖定為止（通常兩筆），換來之後才啟用的守衛不漏認大廳 |
| D26 | 第四輪第 2 條：FastTest 與非 lobby 連線在 `dispatch` 開頭就走現行鏈；`runChain` 的就地改寫檢查改由呼叫端旗標決定（只有 `guardedSend` 傳 true），污染判定改看角色 | 完全不讀守衛狀態 | 取捨：lobby 上的 FastTest 被就地改成守衛方法時不再撤回，記為保證範圍限定（設計 §1.4 第 2、4 項；「屬 U4」已由 D29 撤回）。live 未見 lobby 連線上的 FastTest |
| D27 | 第四輪第 3 條（D23 縮窄；只看原方法見 D33）：lobby 上守衛查找拋錯時，只拒送原方法或改寫後方法在 `GUARDABLE_METHODS` 者與解析不出者；其他還原原 bytes 照送 | 照 Astra 建議與主線指示；判斷只用閉包常數與 parser | 取捨：守衛壞掉期間守衛方法仍全拒（換裝失敗），心跳、探針、排隊、匹配恢復。不開外送缺口：插件能守衛的方法只在名單內，放行的都不是可守衛方法（設計 §1.3；I2 論證已由 D31 改寫） |
| D28 | 第五輪第 1 條：`sendRaw` 無大廳候選時退回 game，共存插件的 `sendRequest` 可外送守衛方法 | 採納為保證範圍限定（設計 §1.4 第 1 項），不改程式 | `naki-websocket.js` 不得改（用戶既有裁決），無法在 `sendRaw` 層證明不可能。取捨：解鎖插件自己不注入，限定「頁面上沒有其他 `injectSend` 插件」比在 JS 加連線角色檢查少動送出主路徑 |
| D29 | 第五輪第 2 條：不經 `ctx.replace` 的就地改寫不檢查 | 採納為保證範圍限定：保證只涵蓋遵守 `ctx.replace` 契約的插件；撤回「屬 U4」 | 第四輪第 2 條要求現行鏈不讀守衛狀態，兩者衝突時保留對局可用性。誤用（快取封包）也可能觸發，所以寫進確認稿，不以惡意帶過 |
| D30 | 第五輪第 3 條：unknown 連線上的第一個 Lobby Blob 照送，非同步副本才鎖 lobby | 採納為文件限定；不採程式修法（unknown 上有守衛者時拒送 Blob） | 程式修法違反用戶裁決「unknown fail-open」，且若客戶端真改用 Blob，lobby 上的 Blob 全拒、大廳已不可用，修法救不回保證。live 未見 Blob；`diagnostics().send.Blob` 可觀測。空窗證明與 §4.5 全稱句改為限同步可解析 |
| D31 | 第五輪第 4 條：D27 的名單不能單獨證明 I2 | 採納：I2 對名單外方法改依解鎖設計 §3.7 三條件 | 名單只代表可宣告守衛，`useBagItem` 等同為 `ResCommon` 的方法照送；D27 不比守衛健康時多放行 |
| D32 | 第五輪第 5 條：D26 的繞過限定封包形態 | 採納為文件限定，不改程式 | 改成「lobby 上原方法是 FastTest 一律照送」要在 `failSafe` 保留原方法狀態，多一條跨呼叫狀態；live 未見 lobby FastTest（YAGNI） |
| D33 | 第五輪第 6 條補變異時發現：D27 的「改寫後方法」檢查只會多擋。查找出錯時送出的是還原後的原 bytes，改寫後的方法不會外送 | 改為只看原方法（測試 `R6-6`） | 雙側檢查讓「非守衛請求被就地改成未受守衛的可守衛方法、之後內部出錯」時，原請求被拒且無回應；放寬不開外送缺口 |

## 驗證紀錄

| 項目 | 結果 | log |
|---|---|---|
| macOS build（DerivedData 隔離） | BUILD SUCCEEDED | `build-macos.log` |
| NakiTests 全量（`-only-testing:NakiTests`） | 1141 tests，0 failures（main 1138＋新增 3） | `test-full.log` |
| `plugin-regression.cjs`（外部插件 `naki-plugins` master `94fa197`） | 29／29 | `plugin-regression.log` |
| `plugin-v2-regression.cjs` | 21／21 | `plugin-v2-regression.log` |
| `plugin-v2-b2-regression.cjs`（新） | 13／13 | `plugin-v2-b2-regression.log` |
| JS 變異 | 12／12 被抓（M11 第一輪存活，補「鏈內部錯誤」測試後被抓） | `mutation-js.log` |
| Swift 變異 | 未做 | — |
| live | 未做（派工禁止啟動 App 與送封包） | — |

## 審查第二輪（Astra 14 條，2026-10-15）

回應：`docs/archive/review/plugin-v2-b2-review-response.md`。14 條全採納，0 反駁。

| 項目 | 結果 | log |
|---|---|---|
| 反例修前 | 11 條 not ok（R1a、R1b、R2、R3、R4、R5、R6、R7、R8、R9、R14） | `round2-red.log` |
| 反例修後 | `plugin-v2-b2-regression.cjs` 27／27（含修後補的 R3b、R4c） | `round2-green.log` |
| 既有 node | 29／29、21／21 | `round2-plugin-regression.log`、`round2-plugin-v2-regression.log` |
| 變異（修正點＋接線＋第一輪三個代表） | 20／20 被抓 | `round2-mutation-js.log` |
| 接線 patch | 重產，`git apply --check` 通過，45 行增刪；`naki-websocket.js` 本檔未改 | `proposed-ws-send-wiring.patch`、`round2-patch-check.log` |
| macOS build | BUILD SUCCEEDED | `round2-build-macos.log` |
| NakiTests 全量（最終樹） | 1144 tests，0 failures（第一輪 1141＋第二輪 Swift 配對測試 3） | `round2-test-full.log` |

## 審查第三輪（Astra 第二輪新發現 7 條，2026-10-15）

回應：`plugin-v2-b2-review-response.md`「第二輪」。7 條全採納，0 反駁。

| 項目 | 結果 | log |
|---|---|---|
| JS 反例修前 | 7 條 not ok（R301、R302、R3c、R4d、R4e、R5b、R6b） | `round3-red-js.log` |
| Swift 反例修前 | `testLocalExchangeOnOneSocketDoesNotConsumeAnotherSocketsPending` 失敗 | `round3-red-swift.log` |
| 修後 | node 34／34；`PluginSendGuardTests` 8／8 | `round3-green-js.log`、`round3-green-swift.log` |
| 變異 | JS 與接線 9／9 被抓；Swift 配對鍵變異被 2 條測試抓到 | `round3-mutation-js.log`、`round3-mutation-swift.log` |
| 接線 patch | 重產，`git apply --check` 通過，61 行增刪 | `proposed-ws-send-wiring.patch`、`round3-patch-check.log` |
| 全量驗收 | build 綠；NakiTests 1146 個、0 failures（1144＋本輪 Swift 2）；plugin-regression 29／29、plugin-v2-regression 21／21 | `round3-build-macos.log`、`round3-test-full.log`、`round3-plugin-*.log` |

## 審查第四輪（Astra 第三輪新發現 6 條，2026-10-15）

**用戶裁決（2026-10-15）**：守衛收窄到只守大廳連線，再修一輪；第四輪審查若仍有【擋】，解鎖 v1 暫停。

回應：`plugin-v2-b2-review-response.md`「第三輪」。6 條全採納（第 4 條依主線指示只證明後果），0 反駁。

| 項目 | 結果 | log |
|---|---|---|
| JS 反例修前 | 7 條 not ok（R4-1a、R4-1b、R4-1c、R4-1d、R4-2、R4-3、R4-5） | `round4-red-js.log` |
| 修後 | node 43／43；`PluginSendGuardTests` 11／11 | `round4-green-js.log`、`round4-green-swift.log` |
| 變異 | JS 與接線 10／10 被抓；Swift S1、S2 被抓 | `round4-mutation-js.log`、`round4-mutation-swift-S1.log`、`round4-mutation-swift-S2.log` |
| 接線 patch | 重產，`git apply --check` 通過，53 行增刪；`naki-websocket.js` 本檔未改 | `proposed-ws-send-wiring.patch`、`round4-patch-check.log` |

| 全量驗收 | build 綠；NakiTests 1149 個、0 failures（1146＋本輪 Swift 3）；plugin-regression 29／29、plugin-v2-regression 21／21 | `round4-build-macos.log`、`round4-test-full.log`、`round4-plugin-*.log` |

## D24：解鎖 v1 暫停（2026-10-15，依 D17 用戶裁決執行）
第四輪 Astra 審查（`.swfd/logs/pv2-b2-review/astra-review4.md`）仍有 1 條【擋】：`isLobbyUrl` 以子字串判定，`/game-gateway?next=/gateway`、hostname 含 gateway 的對局連線會被納入守衛並拒送。依 D17「第四輪仍有【擋】則解鎖 v1 暫停」，本工作包停在 spike，不套接線 patch、不合併。
狀態：spike 與四輪審查保留在分支 pv2-b2-design；第三輪 6 條中 5 條已修、1 條部分。恢復時的待辦：URL 解析後以已確認 pathname 判定角色（第四輪 1）、FastTest 繞過涵蓋舊鏈例外與鏈後檢查（第四輪 2）、D23 縮窄為只拒送 GUARDABLE_METHODS 與無法解析者（第四輪 3）、D22 Naki 身分缺口。
恢復：2026-10-17 用戶裁決照「協定握手鎖定角色」繼續（見下方第五輪）。
取捨：四輪擋數 7→2→2→1，每輪修好上一輪又在更外圍找到新缺口；守衛位在 Naki 送出主路徑，誤判直接傷對局可用性，為本機外觀插件承擔此風險不划算，故遵守事先設下的停損點，不臨時加輪。

## 審查第五輪（Astra 第四輪 3 條，2026-10-17）

**用戶裁決（2026-10-17）**：解鎖守衛照「協定握手鎖定角色」繼續，送第五輪審查；不做整體架構抽象化；D22 維持另開工作包。

回應：`plugin-v2-b2-review-response.md`「第四輪」。3 條全採納，0 反駁。

| 項目 | 結果 | log |
|---|---|---|
| JS 反例修前 | 11 條 not ok（R5-1a～g、R5-2a、R5-2b、R5-3、R5-3b）；R5-1h 修前已綠，以變異 M3 補紅 | `round5-red-js.log` |
| 修後 | node 55／55；`PluginSendGuardTests` 11／11 | `round5-green-js.log`、`round5-green-swift.log` |
| 既有 node | 29／29（naki-plugins `94fa197`）、21／21 | `round5-plugin-regression.log`、`round5-plugin-v2-regression.log` |
| 變異 | 8／8 被抓（scratch 複本執行，worktree 未動） | `round5-mutation-js.log` |
| 接線 patch | 重產，`git apply --check` 通過，53 行增、2 行刪；套用後與記憶體接線逐 byte 相同；`naki-websocket.js` 本檔未改 | `proposed-ws-send-wiring.patch`、`round5-patch-check.log` |
| 全量 | NakiTests 1149 個、0 failures（與第四輪同；本輪未改 Swift；分支基底落後 main） | `round5-test-full.log` |

## 審查第五輪 b（Astra 第五輪 6 條應修，2026-10-17）

Astra 第五輪：0【擋】、6【應修】、0【建議】；總評可進入「向用戶確認接線與 Swift 配對改動」，確認稿須帶入適用範圍。回應：`plugin-v2-b2-review-response.md`「第五輪」。6 條全採納，0 反駁。

| 項目 | 結果 | log |
|---|---|---|
| 修前紅 | `R6-6` not ok（D33）；R6-1～5 鎖現行行為，修前即綠 | `round5b-red-js.log` |
| 修後 | node 61／61；`PluginSendGuardTests` 11／11 | `round5b-green-js.log`、`round5b-green-swift.log` |
| 既有 node | 29／29、21／21 | `round5b-plugin-regression.log`、`round5b-plugin-v2-regression.log` |
| 變異 | 13／13 被抓（N1–N5 新增；M1–M8 重跑） | `round5b-mutation-js.log` |
| 接線 patch | 未改；`git apply --check` 通過 | `round5b-patch-check.log` |
| 全量 | 未重跑（未改 Swift），沿用 1149／0 | `round5-test-full.log` |

## D34：接線套用與 rebase（2026-10-17，用戶裁決）

- **接線已套用**：`proposed-ws-send-wiring.patch` 寫進 `naki-websocket.js`（+53／−2）。Swift 配對改動（`pendingRequests` 以連線＋msgId 為鍵、socketId 傳到 `LiqiParser.parse`）本來就在本分支，用戶一併接受。
- **回歸腳本同步**：`plugin-v2-b2-regression.cjs` 刪掉 `PROPOSED_WIRING` 與 `wired()`，直接載入已接線的檔案；測試 `without the proposed wiring the verdict is ignored (fail-open)` 整條刪除。該測試的目的是防止誤以為 spike 已生效，接線套用後失去意義。其餘 60 條斷言未改。
- **rebase 基底 fd74f63**：無衝突，`LiqiParser.swift` 與 `MajsoulBridge.swift` 自動合併（預期的兩處衝突未發生）。wip commit（原 ccd1e0b）仍被帶上：54c1983 建在它之上，丟掉會讓後者失去基底，所以未用 `--onto`。
- **驗證**（主 repo `.swfd/logs/pv2-b2-wire/`）：node 回歸 60／60、29／29、21／21（`rebased-plugin*.log`）；macOS build 與 iOS Simulator build（scheme `Naki-M`，iPhone 17）皆 `BUILD SUCCEEDED`；NakiTests 全量 1154／0（= main 1143 + 11），`AuthGameErrorResponseTests` 5／5、`PluginSendGuardTests` 11／11（`rebased-test-full.log`）。
- **未驗證**：App 內 live 行為，依用戶裁決先 live 驗證再合併 main。
