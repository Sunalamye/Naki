# inject-receive 實作筆記

基底 main `d51e22b`，分支 `feat/inject-receive`。設計 `docs/archive/plan/inject-receive-design-2026-10-18.md`（a875ff3），主線 2026-10-18 裁決 15 項全採納、4 項待裁決定案如下。契約 `docs/plugin-api-v1.md` 文末「v2 Phase 4」。log 在主 repo `.swfd/logs/inject-receive/r1-*`。

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
| 4 | b2 §4.2 第 3b 步寫「有守衛者的 `respondLocally` 被接受」 | 守衛方法上任何被接受的提案（含非守衛插件）在第 3 步不成立時都是本地成功 | 提案者已拿到 `ok:true`，照送等於送出插件說不要送的請求；本地成功不外送，比照送保守。守衛者自己的呼叫被拒才算第 3 步失敗（設計 §2.4） |
| 5 | 設計 §2.5：`failSafe` 看到 `tx.local` 就回本地成功 | 只取代 `failSafe` 的「照送」路徑；守衛方法 bridge 出錯仍是 `bridge_error` 本地錯誤 | §4.2 第 2 步優先於 3b；兩者都不外送，以既有表格順序為準（`IR-9`） |
| 6 | 設計 §3.2：`send_inflight_overflow` 只在交易結算且未撤回時發 | 這筆造成溢出、結算後該連線仍失準才發 | 撤回時表已變動會保守維持失準（PS-33），此時拒發是真的，照實通知；乾淨撤回會解除失準，不發。原寫法的 `!failed` 條件在測試下是等價變異（DG3 初版存活），改寫後 DG3 改守「不看結算後是否仍失準」並被殺 |
| 7 | 設計 §3.3：不在別的插件 hook 中途呼叫插件 | 延後只看 `api.dispatch` 的巢狀深度 | 觸發點在 `dispatch` 之外的插件程式碼裡（例如 `localResponse` 計時器呼叫的 `onInjectResponse`、`onRecommendations` 內同步造成接收失敗）時會立即交付，可能落在那個 hook 中途。只是唯讀通知，沒有外送與記帳影響，列已知限制 |
| 8 | 設計 §1.5 拒收檢查都在插件層 | 連線相關的三項（`no_connection`、`receive_untrusted`、`inject_busy`）在 `naki-websocket.js` 判，接收不可信另在連線資訊上記 `recvLost` | 連線狀態的擁有者是 websocket 層；`recvLost` 與插件層 `recvLostSockets` 在同一個呼叫點設定。待交付上限以參數傳入，常數仍集中在 `naki-plugins.js`（裁決 b） |
| 9 | — | `closed` 清 `degradedSeen` 不列變異 | socketId 每條連線唯一，關閉後不會再出現同 id，清除只為釋放記憶體，行為不可觀察 |
| 10 | 設計 §1.5：`isReshapeForbidden`＋`FORBIDDEN_METHODS` | 照做 | 目前 `FORBIDDEN_METHODS` 是 `isReshapeForbidden` 的子集，拿掉後者那一半是等價變異，不列；保留是為了日後 receive 禁改名單新增項目時自動適用 |

## 實作摘要

- `injectReceive`：`naki-plugins.js` 驗 L3、bytes、envelope、名單，入口 `hostCopy`；`naki-websocket.js` 的 `injectReceive` 驗連線並 `setTimeout 0` 排程，`deliverInjected` 依序：重查接收不可信、送 Swift（帶 `synthetic:true`，失敗就不交付遊戲）、`dispatchEvent`（登記 `syntheticEvents`）、觀察項排進 `recvQueue` 尾再 `flushReceive`。連線釋放時清空 `info.injected`。
- 合成觀察：`flushReceive` 把 `synthetic` 經 `dispatchToPlugins` 帶進 `raw`；`runChain` 的 `isNaki` 含 `raw.synthetic`；`makeCtx` 標 `ctx.synthetic`、`ctx.syntheticBy`，合成 ctx 沒有 `sendRequest`（其餘寫入函式本來就因 `isNaki` 或 `mutable:false` 不掛）。
- `respondLocally`：提案存在 `raw.tx.local`，拒絕紀錄在 `raw.tx.refused`；`callHook` 以 `openCtx` 判斷 hook 是否仍在執行（`too_late`）；`raw.sendOriginal` 判 `rewritten`。守衛方法在 `guardedVerdict` 依 `guardFailure(guard, tx)`（第 3 步含 `respondFailure`，之後 3b）判，守衛者全部退出時有提案也本地成功；非守衛方法由 `api.dispatch` 在判決後改為 `localOk`；`failSafe` 的照送路徑看到提案改為 `localOk`。`localOk` 與 `blockSend` 同形狀，`local:'ok'`、`reason:'respond_locally'`，走既有 `respondLocal`。
- 遊戲 `last`：`gameLast` 抽出；`dispatch` 對遊戲送出的本地結局、`failSafe` 擋下與本地成功都呼叫。
- 退化事件：`degrade` 只記入 `pendingDegraded`（每 (連線, reason) 一次），`deliverDegraded` 在 `dispatchDepth` 為 0 時交付；交付點為 `dispatch` 結束、`receiveLost` 結束、`sendSettled`、`reshapeLocked`。ctx 凍結，`effects` 也凍結。
- Swift：`JSContractTests.testRespondForbiddenListCoversLiqiParserSideEffectMethods`；`PluginsPageView` L3 說明與 `Localizable.xcstrings` 四語系同步。LiqiParser、bridge、AutoPlay 未改。

## 驗證

| 階段 | 結果 | log |
|---|---|---|
| 基線（d51e22b，改動前） | b2 243／v2 21／p4 24／keepalive 11／plugin-regression 39／local-unlock 9，全 0 fail | `r1-base-*.log` |
| 先紅（新 b2 對 d51e22b 的 JS） | 18 fail：`IR-1`～`IR-17` 全紅、`PS-19` 紅 | `r1-red-on-d51e22b.log` |
| 行為紅（只留守衛兩種模式的 `IR-10` 與 `PS-19`） | 2 fail：base 注入拿 64000（落在遊戲接下來 256 號內），`PS-19` 拿 64512 | `r1-red-behavior-on-d51e22b.log` |
| 實作後 | b2 260／v2 21／p4 24／keepalive 11／plugin-regression 39／local-unlock 9，全 0 fail | `r1-final-*.log` |
| 變異（新增 42） | 42/42 killed（DG3 初版存活，見 Deviation 6，改寫後重跑 killed） | `r1-mutate-new-a.log`、`r1-mutate-new-b.log`、`r1-mutate-dg3.log` |
| 變異（全量 218） | 216/218，只剩等價 T7、U10；過期定義 12 條已依新程式碼更新（V9、V16、N5、PS15、PS33、PS44、PS45、PS49、PS60、PS73、PS75、PS82，語意不變） | `r1-mutate-full-1.log`～`-3.log` |
| Swift 先紅 | JS 名單暫拿掉 `cancelMatch`：新契約測試紅，列出 `.lq.Lobby.cancelMatch`；已還原 | `r1-swift-red.log` |
| Swift 指定 | `JSContractTests` 8、`PluginSendGuardTests` 12、`LocalizationCatalogTests` 2、`PluginRegistryTests` 17，共 39，0 failures | `r1-swift-build-final.log`、`r1-swift-targeted.log` |

全量 NakiTests 未跑（裁決只要求指定）。

## live 另案（測試帳號，未做）

- 合成 NOTIFY 相對當前這則的抵達順序（`setTimeout 0` 的推論：capture listener 內的 microtask 仍早於遊戲 handler，依 HTML 規範，node harness 重現不了）。
- 一則無害 NOTIFY 的 `injectReceive`：遊戲與 Swift 各收一次。
- 一個非守衛、無副作用 Lobby 方法的 `respondLocally`：遊戲在 `ws.send` 返回後收到回應、不卡。
- 32 則／1 MiB 上限是否合理。

## 已知風險

- 三個功能都只有單測，未 live 驗證。
- 退化事件在 `dispatch` 以外的插件程式碼中觸發時可能在該 hook 中途交付（Deviation 7）。
- `window.__nakiWebSocket.injectReceive` 頁面程式可直接呼叫，跳過 L3 與名單（同 realm 不防，契約已寫）。
- Swift log 對本地成功仍印「Blocked request: <method> (respond_locally)」：沿用守衛擋下的字樣，未改 Swift。
