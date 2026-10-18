# inject-receive 實作筆記

基底 main `d51e22b`，分支 `feat/inject-receive`。設計 `docs/archive/plan/inject-receive-design-2026-10-18.md`（a875ff3），主線 2026-10-18 裁決 15 項全採納、4 項待裁決定案如下。契約 `docs/plugin-api-v1.md` 文末「v2 Phase 4」。log 在主 repo `.swfd/logs/inject-receive/r1-*`（第一輪）、`r2-*`（第二輪）；Astra 原文在 `.swfd/logs/inject-receive-review/astra-review1.md`。

## 裁決（2026-10-18，主線）

| 項 | 裁決 | 落點 |
|---|---|---|
| a | 本地結局（`respondLocally`、守衛本地錯誤、`failSafe` 擋下）更新遊戲 `last`，同包修 pair-source 遺留缺口；不提交未答 | `gameLast`；`IR-10`、`PS-19` |
| b | 32 筆／1 MiB 是啟發式；具名常數集中放；宿主接收端沒有既有位元組上限可對齊，取 1 MiB；契約與本筆記標「未以 live 量測」 | `SYNTHETIC_MAX_BYTES`、`INJECT_RECEIVE_MAX_PENDING`（`naki-plugins.js`） |
| c | `reshape_locked` 納入退化事件 | `IR-16` |
| d | 可改 `naki-websocket.js`，依據見 Deviation 1 | — |
| 補 1 | `setTimeout 0` 的順序推論標「未 live 驗證」；live 另案列「合成 NOTIFY 相對當前這則的抵達順序」 | 契約、本筆記「live 另案」 |
| 補 2 | 每連線每 reason 只發一次；契約寫明恢復方式是連線關閉後重連，與 `response_lost` 一致 | 契約 |

## Deviations

| # | 計畫 | 實作 | 理由 |
|---|---|---|---|
| 1 | Naki CLAUDE.md：修改 WebSocket bridge 前先確認 | 改了 `naki-websocket.js` | 用戶 2026-10-17「都自動」裁決覆蓋該條（pair-source 同樣改過該檔）；三個功能都不新增 Liqi 外送：`injectReceive` 只呼叫 `sendToSwift` 與 `dispatchEvent`，`respondLocally` 只減少外送，退化事件唯讀。主線裁決 d 記錄此依據 |
| 2 | 設計 §1.4：`raw.synthetic` 在 `dispatchRaw` 開頭跳過所有記帳分支，作為保險並有變異守住 | 只在 `runChain` 把合成算成 `isNaki`（變異 IR5 守住），`dispatchRaw` 開頭不加跳過 | 合成只能是 NOTIFY（入口型別檢查，變異 IR9 守住），NOTIFY 沒有 msgId，所有記帳分支結構上不可達；開頭再加跳過會是殺不掉的等價變異。真正的防線是入口檢查與 `isNaki` |
| 3 | 既有 `PS-19` 斷言注入拿 64512 | 改為 64256 | 裁決 a 的直接後果：被擋下的 64256 讓遊戲最後號碼前進，避號視窗改為 64257–64512；64256 本身沒有未答，可安全使用。base 上同一斷言實測 64512（`r1-red-behavior-on-d51e22b.log`） |
| 4 | ~~b2 §4.2 第 3b 步寫「有守衛者的 `respondLocally` 被接受」~~ | **撤回（第二輪第 10 條裁決）**：回到判定表，守衛方法上只收守衛者的提案，非守衛者回 `not_guardian` | 插件拿不到 `ok:true`，就不存在「照送插件說不送的請求」的問題；b2 §4.2、§5.3 與契約已同步 |
| 5 | 設計 §2.5：`failSafe` 看到 `tx.local` 就回本地成功 | 只取代 `failSafe` 的「照送」路徑；守衛方法 bridge 出錯仍是 `bridge_error` 本地錯誤 | §4.2 第 2 步優先於 3b；兩者都不外送，以既有表格順序為準（`IR-9`） |
| 6 | 設計 §3.2：`send_inflight_overflow` 只在交易結算且未撤回時發 | 這筆造成溢出、結算後該連線仍失準才發 | 撤回時表已變動會保守維持失準（PS-33），此時拒發是真的，照實通知；乾淨撤回會解除失準，不發。原寫法的 `!failed` 條件在測試下是等價變異（DG3 初版存活），改寫後 DG3 改守「不看結算後是否仍失準」並被殺 |
| 7 | ~~設計 §3.3：延後只看 `api.dispatch` 的巢狀深度~~ | **已根治（第二輪第 3、8 條）**，見 Deviation 11 | — |
| 8 | 設計 §1.5 拒收檢查都在插件層 | 連線相關的三項（`no_connection`、`receive_untrusted`、`inject_busy`）在 `naki-websocket.js` 判，接收不可信另在連線資訊上記 `recvLost` | 連線狀態的擁有者是 websocket 層；`recvLost` 與插件層 `recvLostSockets` 在同一個呼叫點設定。待交付上限以參數傳入，常數仍集中在 `naki-plugins.js`（裁決 b） |
| 9 | — | `closed` 清 `degradedSeen` 不列變異 | socketId 每條連線唯一，關閉後不會再出現同 id，清除只為釋放記憶體，行為不可觀察 |
| 10 | 設計 §1.5：`isReshapeForbidden`＋`FORBIDDEN_METHODS` | 照做 | 目前 `FORBIDDEN_METHODS` 是 `isReshapeForbidden` 的子集，拿掉後者那一半是等價變異，不列；保留是為了日後 receive 禁改名單新增項目時自動適用 |
| 11 | 第二輪裁決第 8 條：統一回呼深度（涵蓋全部插件回呼）與排空邊界 | 不計深度，退化事件一律在觸發後的下一個 task（`setTimeout 0`）交付 | 插件程式碼的進入點不只 hook：getter、`toString`、thenable 的 `then`、`onDisable` 都會在宿主流程中執行，深度計數無法列舉完整，漏一個就回到第 3 條的空窗。task 邊界時堆疊上必然沒有插件回呼，也不在送出判決與上 wire 之間，比「延到 `ws.send` 返回後」更保守（`onRecommendations` 內的送出返回時仍在 hook 中）。代價是順序：觸發後同一個 task 裡排隊的項目會先派發，契約已改寫 |
| 12 | 第二輪第 4 條 | `closed` 清 `localPending` 不列變異 | 本地回應的計時器在連線關閉後仍會執行並釋放號碼；只有排程本身拋錯時才靠關閉清除，node harness 造不出這個情況 |
| 13 | 第二輪第 7 條：交付前重查連線身分與 OPEN | 兩項都查；身分檢查不列變異 | 連線釋放時先清空 `info.injected`，交付找不到項目就返回，身分不符的情況在身分檢查之前已攔下，拿掉身分檢查是等價變異。保留作為釋放順序改動時的防線 |
| 14 | 第二輪第 1 條：合成能力成功後納入污染生命週期 | 宣告 `sendGuard` 的插件，`injectReceive`／`respondLocally` 被接受即污染，不分連線 | 既有的接收污染只看大廳；合成通知可能出現在任何連線，本地回應也可能在對局連線上。污染只讓守衛更嚴，不分連線比較保守 |

## 實作摘要

- `injectReceive`：`naki-plugins.js` 驗 L3、bytes、envelope、名單，入口 `hostCopy`；`naki-websocket.js` 的 `injectReceive` 驗連線並 `setTimeout 0` 排程，`deliverInjected` 依序：重查接收不可信、送 Swift（帶 `synthetic:true`，失敗就不交付遊戲）、`dispatchEvent`（登記 `syntheticEvents`）、觀察項排進 `recvQueue` 尾再 `flushReceive`。連線釋放時清空 `info.injected`。
- 合成觀察：`flushReceive` 把 `synthetic` 經 `dispatchToPlugins` 帶進 `raw`；`runChain` 的 `isNaki` 含 `raw.synthetic`；`makeCtx` 標 `ctx.synthetic`、`ctx.syntheticBy`，合成 ctx 沒有 `sendRequest`（其餘寫入函式本來就因 `isNaki` 或 `mutable:false` 不掛）。
- `respondLocally`：提案存在 `raw.tx.local`，拒絕紀錄在 `raw.tx.refused`；`callHook` 以 `openCtx` 判斷 hook 是否仍在執行（`too_late`）；`raw.sendOriginal` 判 `rewritten`。守衛方法在 `guardedVerdict` 依 `guardFailure(guard, tx)`（第 3 步含 `respondFailure`，之後 3b）判，守衛者全部退出時有提案也本地成功；非守衛方法由 `api.dispatch` 在判決後改為 `localOk`；`failSafe` 的照送路徑看到提案改為 `localOk`。`localOk` 與 `blockSend` 同形狀，`local:'ok'`、`reason:'respond_locally'`，走既有 `respondLocal`。
- 遊戲 `last`：`gameLast` 抽出；`dispatch` 對遊戲送出的本地結局、`failSafe` 擋下與本地成功都呼叫。第二輪起依進入順序：送出交易在第一次進入 `dispatch`（或派發前出錯時的 `failSafe`）取得序號 `tx.order`，`gameLast` 只接受不小於目前 `lastOrder` 的更新。
- 本地回應保留號碼（第二輪）：`blockSend`（有合成回應時）與 `localOk` 呼叫 `holdLocal`，`localResponse` 開頭 `releaseLocal`，`nextPluginMsgId` 把 `localPending` 列為忙碌，`closed` 清掉該連線的保留。
- 污染（第二輪）：`injectReceive` 回 `ok`、`respondLocally` 接受時，宣告 `sendGuard` 的插件立即 `taint`。
- 守衛身分（第二輪）：`runChain` 記 `raw.lobbyChain`；`respondLocally` 以呼叫當時的 `guardFor(method)` 判定，非守衛者回 `not_guardian`；拒絕與提案都帶 `guardian`。`respondFailure` 計入 `guardian` 為真的拒絕（退出後仍算），`guardFailure` 對非守衛者的提案回 `not_guardian`。
- 退化事件：`degrade` 只記入 `pendingDegraded`（每 (連線, reason) 一次）並排一個 `setTimeout 0`，`deliverDegraded` 在那個 task 排空（第二輪，取代第一輪的 `dispatchDepth` 與四個交付點）。ctx 凍結，`effects` 也凍結。
- 接收佇列（第二輪）：`checkOverflow` 抽出，網路接收與 `deliverInjected` 的觀察項共用；`deliverInjected` 先查 `wsConnections.get(ws) === info` 且 `readyState === OPEN`。
- Swift：`JSContractTests.testRespondForbiddenListCoversEverySwiftMethodBranch`（第二輪取代第一輪手列三個常數的版本，改為從 `command/Services/Bridge` 反查）；`PluginsPageView` L3 說明與 `Localizable.xcstrings` 四語系同步。LiqiParser、bridge、AutoPlay 未改。

## 驗證

| 階段 | 結果 | log |
|---|---|---|
| 基線（d51e22b，改動前） | b2 243／v2 21／p4 24／keepalive 11／plugin-regression 39／local-unlock 9，全 0 fail | `r1-base-*.log` |
| 先紅（新 b2 對 d51e22b 的 JS） | 18 fail：`IR-1`～`IR-17` 全紅、`PS-19` 紅。其中 `IR-1`～`IR-10` 因新 API 缺席而紅，不算行為證據；不依賴呼叫缺席 API 的行為紅只有退化事件七條（`IR-11`～`IR-17`）＋`PS-19`，共八條（第二輪建議 14 收窄） | `r1-red-on-d51e22b.log` |
| 行為紅（只留守衛兩種模式的 `IR-10` 與 `PS-19`） | 2 fail：base 注入拿 64000（落在遊戲接下來 256 號內），`PS-19` 拿 64512 | `r1-red-behavior-on-d51e22b.log` |
| 實作後 | b2 260／v2 21／p4 24／keepalive 11／plugin-regression 39／local-unlock 9，全 0 fail | `r1-final-*.log` |
| 變異（新增 42） | 42/42 killed（DG3 初版存活，見 Deviation 6，改寫後重跑 killed）。這 42 條對準的是第一輪既有斷言，沒有涵蓋 Astra 第一輪第 1～9 條反例（第二輪建議 14） | `r1-mutate-new-a.log`、`r1-mutate-new-b.log`、`r1-mutate-dg3.log` |
| 變異（全量 218） | 216/218，只剩等價 T7、U10；過期定義 12 條已依新程式碼更新（V9、V16、N5、PS15、PS33、PS44、PS45、PS49、PS60、PS73、PS75、PS82，語意不變） | `r1-mutate-full-1.log`～`-3.log` |
| Swift 先紅 | JS 名單暫拿掉 `cancelMatch`：新契約測試紅，列出 `.lq.Lobby.cancelMatch`；已還原 | `r1-swift-red.log` |
| Swift 指定 | `JSContractTests` 8、`PluginSendGuardTests` 12、`LocalizationCatalogTests` 2、`PluginRegistryTests` 17，共 39，0 failures | `r1-swift-build-final.log`、`r1-swift-targeted.log` |

全量 NakiTests 未跑（裁決只要求指定）。第一輪的 216/218 與 Swift 39/0 只代表當時的程式碼與測試，不能推論完整驗收。

### 第二輪（Astra 第一輪反例）

| 階段 | 結果 | log |
|---|---|---|
| 先紅（新測試對第一輪 HEAD 2d075b6） | 14 fail：`PS-19`（交付前注入拿到 64256）、`IR-8`（非守衛者提案仍被接受）、`IR-11`～`IR-13`、`IR-17`（退化事件同步交付）、`IR-18`～`IR-25` 全紅；每條失敗訊息都是行為不符（號碼、外送、交付時機），沒有測試本身的錯誤 | `r2-red.log` |
| 實作後 | b2 268／v2 21／p4 24／keepalive 11／plugin-regression 39／local-unlock 9，全 0 fail | `r2-final-*.log` |
| 變異（新增 15，對準第 1～10 條） | 15/15 killed | `r2-mutate-new.log` |
| 變異（全量 233） | 231/233，只剩等價 T7、U10。過期 14 條依新程式碼改寫（PS14、PS44、PS45、PS82、PS83、IR3、IR4、RL3、RL4、RL11、RL15，語意不變；DG1 改守「同步交付」，DG6、DG9 原交付點已不存在，改守「從不交付」與「交付後不重設排程」）。RL13 在第一次全量時存活：第 1 條修正後守衛者提案即污染，原測試走不到守衛退出分支，補 `IR-8`「守衛先退出、之後的插件提案」後殺掉 | `r2-mutate-full-1.log`、`-2.log`、`r2-mutate-rl13.log`、最終 `r2-mutate-final-1.log`、`-2.log` |
| Swift 變異（第 9 條） | 四條都紅：`LiqiParser.parseRequest` 新增以 builder 常數比較的副作用分支、`LiqiResponseStore` 新增以字面值比較的分支、比較對象是解析不了的區域變數、JS 名單拿掉 `cancelMatch`。Swift 檔還原後與 HEAD 無差異，JS 檔還原後雜湊相同 | `r2-swift-mut-S1-parser-constant.log`、`-S2-store-literal.log`、`-S3-unresolved-operand.log`、`-S4-js-list.log` |
| Swift 指定（還原後重建） | `JSContractTests` 8、`PluginSendGuardTests` 12、`LocalizationCatalogTests` 2、`PluginRegistryTests` 17，共 39，0 failures；bundle 內的 `naki-plugins.js` 與 worktree 逐 byte 相同 | `r2-swift-build-final.log`、`r2-swift-targeted-final.log` |

全量 NakiTests 仍未跑，live 仍未做。

## 審查回應（Astra 第一輪，主線 2026-10-18 裁決：4 擋 7 應修全採納、根治；4 建議照做）

| # | 等級 | 回應 | 修正 | 反例測試（先紅） | 變異 |
|---|---|---|---|---|---|
| 1 | 擋 | 採納 | 宣告 `sendGuard` 的插件，`injectReceive`／`respondLocally` 被接受即污染（Deviation 14） | `IR-18` | R2-1a、R2-1b |
| 2 | 擋 | 採納 | 拒絕紀錄帶呼叫當時的守衛身分，`respondFailure` 計入；與已退出守衛的拋錯否決一致 | `IR-19`（`response_invalid`、`respond_rejected` 兩型） | R2-2a、R2-2b |
| 3 | 擋 | 採納 | 退化事件在下一個 task 交付，終判到上 wire 之間不再有插件回呼（Deviation 11）；回呼內 `taint()` 只影響之後的送出 | `IR-20`、`IR-13` | DG1 |
| 4 | 擋 | 採納 | 本地回應交付前保留號碼（`localPending`），不算未答，交付後釋放 | `PS-19` 兩種時序、`IR-21` | R2-4a～R2-4d |
| 5 | 應修 | 採納 | `last` 依進入送出的順序更新，與號碼大小無關（涵蓋環繞） | `IR-22`（63900→63901 反例，及較小號碼的環繞類比） | R2-5a、R2-5b |
| 6 | 應修 | 採納 | 觀察項與網路接收共用 `checkOverflow` | `IR-23` | R2-6 |
| 7 | 應修 | 採納 | 交付前查連線紀錄身分與 `readyState === OPEN` | `IR-24` | R2-7（身分檢查等價，Deviation 13） |
| 8 | 應修 | 採納 | Dev 7 根治：以 task 邊界取代深度計數，涵蓋所有插件程式碼進入點（Deviation 11）；契約交付時機改寫 | `IR-20`（`onRecommendations`）、`IR-17` | DG1、DG6、DG9 |
| 9 | 應修 | 採納 | Swift 契約測試改為從 bridge 原始碼反查所有依 method 的比較，解析不了即紅 | Swift 變異 S1～S4 全紅 | S1～S4（Swift） |
| 10 | 應修 | 採納（裁決：回到判定表） | 撤回 Dev 4；非守衛者在守衛方法上回 `not_guardian`；鏈中才成為守衛方法時非守衛者的提案本地錯誤；b2 §4.2、§5.3、契約同步 | `IR-25`、`IR-8` 改寫 | R2-10a～R2-10c |
| 11 | 建議 | 照做（Astra 反駁 A 的疑慮，不涵蓋上列反例） | 無需改碼 | — | — |
| 12 | 建議 | 照做 | 契約寫明 32 筆名額沒有公平性保證，同 realm 搶占屬 U4 | — | — |
| 13 | 建議 | 照做 | 契約寫明退化 ctx 的 `url` 原樣傳入，查詢參數會出現，屬已開放的連線資訊（U4） | — | — |
| 14 | 建議 | 照做 | 第一輪驗證表的行為紅收窄為八條，42 條變異註明只對準既有斷言 | — | — |
| 15 | 應修 | 採納 | live 另案補五項（下節） | — | — |

## live 另案（測試帳號，未做）

- 合成 NOTIFY 相對當前這則的抵達順序（`setTimeout 0` 的推論：capture listener 內的 microtask 仍早於遊戲 handler，依 HTML 規範，node harness 重現不了）。
- 一則無害 NOTIFY 的 `injectReceive`：遊戲與 Swift 各收一次。
- 一個非守衛、無副作用 Lobby 方法的 `respondLocally`：遊戲在 `ws.send` 返回後收到回應、不卡。
- 32 則／1 MiB 上限是否合理。
- 合成誘發的送出：遊戲收到合成 NOTIFY 後自行送出的請求，照常經守衛判定（第二輪第 15 條）。
- 合成後停用／熱重載：守衛插件 `injectReceive`／`respondLocally` 被接受後停用或熱重載，守衛方法仍不外送。
- 待交付本地回應撞號：本地回應交給遊戲之前發起注入，配到的號碼避開它，遊戲不會收到同號的兩則回應。
- CLOSING 丟棄：排入後、交付前連線進入 CLOSING，遊戲與 Swift 都收不到合成通知。
- Blob 混流的觀察順序：接收以 Blob 抵達、與合成通知交錯時，遊戲收到的順序與插件觀察順序一致。

## 已知風險

- 三個功能都只有單測，未 live 驗證。
- 退化事件在下一個 task 才交付：同一個 task 裡排在後面的訊息會先派發（限制在觸發當下已生效，只是通知較晚）。
- 本地回應的交付排程本身拋錯時，保留的號碼要到連線關閉才釋放（Deviation 12），期間注入少一個可用號碼。
- 合成能力被接受即污染不分連線（Deviation 14）：守衛插件在對局連線上用 `respondLocally` 也會污染，之後停用要重載頁面才解除守衛。
- `window.__nakiWebSocket.injectReceive` 頁面程式可直接呼叫，跳過 L3 與名單（同 realm 不防，契約已寫）。
- Swift log 對本地成功仍印「Blocked request: <method> (respond_locally)」：沿用守衛擋下的字樣，未改 Swift。
