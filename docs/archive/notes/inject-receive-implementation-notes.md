# inject-receive 實作筆記

基底 main `d51e22b`，分支 `feat/inject-receive`。設計 `docs/archive/plan/inject-receive-design-2026-10-18.md`（a875ff3），主線 2026-10-18 裁決 15 項全採納、4 項待裁決定案如下。契約 `docs/plugin-api-v1.md` 文末「v2 Phase 4」。log 在主 repo `.swfd/logs/inject-receive/r1-*`（第一輪）、`r2-*`（第二輪）、`r3-*`（第三輪）；Astra 原文在 `.swfd/logs/inject-receive-review/astra-review1.md`、`astra-review2.md`。

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
| 12 | ~~第二輪第 4 條：`closed` 清 `localPending` 不列變異~~ | **撤回（第三輪第 4 條）**：故障注入（替換 `setTimeout` 使排程拋錯）造得出來，`IR-28` 測關閉清除，變異 R3-4e 守住 | — |
| 13 | 第二輪第 7 條：交付前重查連線身分與 OPEN | 兩項都查；身分檢查不列變異 | 連線釋放時先清空 `info.injected`，交付找不到項目就返回，身分不符的情況在身分檢查之前已攔下，拿掉身分檢查是等價變異。保留作為釋放順序改動時的防線 |
| 14 | 第二輪第 1 條：合成能力成功後納入污染生命週期 | 宣告 `sendGuard` 的插件，`injectReceive`／`respondLocally` 被接受即污染，不分連線 | 既有的接收污染只看大廳；合成通知可能出現在任何連線，本地回應也可能在對局連線上。污染只讓守衛更嚴，不分連線比較保守 |
| 15 | 第三輪第 1 條裁決：共用方法來源 | 新增 `LiqiSideEffectMethods`（放在 `LiqiRequestBuilder.swift`），改寫 `LiqiParser`、`MajsoulBridge`、`LiqiResponseStore`、`WebSocketInterceptor` 的分支改引用它，移除 `LiqiParser.loginResponseMethods`、`LiqiResponseStore.broadcastMethod` 兩個別名 | 改的是 Swift bridge 生產碼，但只換名稱來源、不改行為；涵蓋這四個檔的 21 個測試類別全綠（`r3-swift-targeted-final.log`）。集合放在 builder 檔，是因為它要引用 builder 的方法常數，而原始碼規則把 builder 檔當成唯一允許出現這些常數的地方 |
| 16 | ~~第三輪第 1 條裁決：字面值比對~~（**第四輪第 4 條取代**，見 Deviation 21） | 規則掃整個 `command/Services/Bridge`（builder 檔除外）的所有 `.lq.` 字面值，不只比較式；另禁止引用 builder 方法常數。例外逐檔以實際值比對：`LiqiResponseStore` 的 error 欄位表鍵、動作頻道兩個方法名、`LiqiActionSender` 的 `heatbeatMethod` | 只看字面值抓不到 Astra 列的四種寫法（它們都用 builder 常數），所以加常數規則。註解裡的字面值也算，寧可誤紅。範圍只到 bridge 目錄，其他目錄的 Swift 不掃（列已知風險） |
| 17 | 第三輪第 4 條：超限回 `local_busy` | 上限只限 `respondLocally`；守衛擋下一律保留、不計上限 | 守衛擋下是強制結局，不能改成送出；遊戲每筆送出各占一個號碼，交付在下一個 task，量由遊戲自己的送出決定 |
| 18 | — | 第一輪 `deliverInjected` 在 `naki-websocket.js` 直接送 `plugin_event` 並帶 `id`，違反 bridge 欄位契約（`BridgeMessageContractTests` 紅）；改經插件層 `injectDropped` 記 log | 第一、二輪的 Swift 指定測試沒納入 `BridgeMessageContractTests`，第三輪擴大範圍才抓到。log 行為不變（`IR-4`、`IR-24`），變異 R3-5 守住 |
| 19 | — | `PluginSendGuardTests.testLogSaysBlockedForGuardedLocalExchangeAndSentOtherwise` 單獨跑 | 它以 `LogManager.entries` 的筆數切片，大批執行寫滿 5000 筆上限後切不到新行而紅；單獨跑 12/12 綠。這是既有測試的順序相依，與本包無關，本包不修 |
| 20 | 第四輪第 1、2 條：保留以交易為單位 | 保留改為物件集合 `localHolds`，物件記在送出交易 `tx.hold`；`respondLocally` 接受時建立，`blockSend` 沿用或建立，`localOk` 只轉移（不建立）。判決帶出 `hold`，`naki-websocket.js` 交付與排程失敗時原樣交回 `localResponse`／`localDropped`（兩個內部 API 的參數因此改變） | 冪等靠集合成員：移出後再移出無作用，交易上已有保留就不再建立。`localOk` 若也建立會是殺不掉的等價變異（接受時必已建立），所以只轉移。排程失敗只可能發生在 `handleMessage` 返回之後，同一筆交易不會再經 `failSafe` 結案，所以「移出後不再建立」不會造成未保留的交付 |
| 21 | 第四輪第 4 條：掃描擴到 `command/Services`、例外整行比對（builder 本體部分由 Deviation 25 取代） | 照做；builder 本體依裁決只由「集合完整性」那條覆蓋，不掃內容（它的 16 行 `LiqiRequestSpec(method:)` 是送出定義）。完整性以原始碼比對：每個 `static let` 名稱必須出現在 `consumed`／`all` 的定義中，集合定義裡的字面值與 builder 常數值都要在 `all` | Swift 的 static 屬性無法反射列舉，只能讀原始碼。整行比對下，集合新增方法時原本的例外行可能不再命中而「過期」紅（V6 同時觸發這條），這是刻意的：例外要跟著集合重審 |
| 22 | 第四輪第 5 條：關閉丟棄寫 `injectDropped` reason `closed` | log 原因寫「連線已關閉」 | 與交付當下 CLOSING 丟棄同一句（`IR-24` 既有斷言），插件看到的是同一種結局；每則一行（`IR-4` 斷言恰好一行） |
| 23 | — | `blockSend` 沒有回應可交付時（例如 bridge 出錯時 bytes 已無法解析、有守衛者）釋放接受提案時的保留 | 接受即占容量後，這條路徑若不釋放會永久占位到連線關閉。故障模型：派發完成後 bytes 變成無法解析再拋錯（`IR-34`），變異 R4-2b 守住 |
| 24 | 第五輪第 1 條：同 key 再觸發要能喚醒排程 | 去重只包住入隊；之後只要有待交付事件且未排程就重排。「沒有待交付就不排」這個條件保留，已以 `IR-36` 覆蓋（變異 R6-1） | ~~原論證「只多排空 task、不可觀察」~~ **撤回（第六輪第 1 條）**：拿掉條件時，重觸發已交付的退化會先排一個 task，之後的新退化搭上它，比它之後才排的計時器先交付（`B→marker`）；保留時是 `marker→B`。`IR-36` 斷言後者 |
| 25 | 第五輪第 2 條：完整性也掃 builder 本體 | builder 本體併進 `testServicesBranchOnlyOnTheSideEffectMethodSet` 的逐行掃描，只略過常數宣告行與 `LiqiRequestSpec(method: 名稱, fields: …)` 送出定義行；宣告形式另由 `testEverySideEffectConstantIsInTheSet` 檢查 | 送出定義是 builder 的本職，不是分支；其他任何一行提到集合外的方法（例如 W10 在 builder 裡新增比較函式）都會紅。這取代 Deviation 21「builder 本體不掃內容」 |

## 實作摘要

- `injectReceive`：`naki-plugins.js` 驗 L3、bytes、envelope、名單，入口 `hostCopy`；`naki-websocket.js` 的 `injectReceive` 驗連線並 `setTimeout 0` 排程，`deliverInjected` 依序：重查接收不可信、送 Swift（帶 `synthetic:true`，失敗就不交付遊戲）、`dispatchEvent`（登記 `syntheticEvents`）、觀察項排進 `recvQueue` 尾再 `flushReceive`。連線釋放時清空 `info.injected`。
- 合成觀察：`flushReceive` 把 `synthetic` 經 `dispatchToPlugins` 帶進 `raw`；`runChain` 的 `isNaki` 含 `raw.synthetic`；`makeCtx` 標 `ctx.synthetic`、`ctx.syntheticBy`，合成 ctx 沒有 `sendRequest`（其餘寫入函式本來就因 `isNaki` 或 `mutable:false` 不掛）。
- `respondLocally`：提案存在 `raw.tx.local`，拒絕紀錄在 `raw.tx.refused`；`callHook` 以 `openCtx` 判斷 hook 是否仍在執行（`too_late`）；`raw.sendOriginal` 判 `rewritten`。守衛方法在 `guardedVerdict` 依 `guardFailure(guard, tx)`（第 3 步含 `respondFailure`，之後 3b）判，守衛者全部退出時有提案也本地成功；非守衛方法由 `api.dispatch` 在判決後改為 `localOk`；`failSafe` 的照送路徑看到提案改為 `localOk`。`localOk` 與 `blockSend` 同形狀，`local:'ok'`、`reason:'respond_locally'`，走既有 `respondLocal`。
- 遊戲 `last`：`gameLast` 抽出；`dispatch` 對遊戲送出的本地結局、`failSafe` 擋下與本地成功都呼叫。第二輪起依進入順序：送出交易在第一次進入 `dispatch`（或派發前出錯時的 `failSafe`）取得序號 `tx.order`，`gameLast` 只接受不小於目前 `lastOrder` 的更新。
- 本地回應保留號碼（第二輪）：`blockSend`（有合成回應時）與 `localOk` 呼叫 `holdLocal`，`localResponse` 開頭 `releaseLocal`，`nextPluginMsgId` 把 `localPending` 列為忙碌，`closed` 清掉該連線的保留。第三輪：`respondLocal` 排不進交付時呼叫 `localDropped` 立即釋放；`respondLocally` 在該連線保留滿 `LOCAL_PENDING_LIMIT`（256）時回 `local_busy`；`diagnostics().localPending`。
- 污染（第二輪）：`injectReceive` 回 `ok`、`respondLocally` 接受時，宣告 `sendGuard` 的插件立即 `taint`。
- 守衛身分（第二輪）：`runChain` 記 `raw.lobbyChain`；`respondLocally` 以呼叫當時的 `guardFor(method)` 判定，非守衛者回 `not_guardian`；拒絕與提案都帶 `guardian`。`respondFailure` 計入 `guardian` 為真的拒絕（退出後仍算），`guardFailure` 對非守衛者的提案回 `not_guardian`。
- 退化事件：`degrade` 只記入 `pendingDegraded`（每 (連線, reason) 一次）並排一個 `setTimeout 0`，`deliverDegraded` 在那個 task 交付（第二輪，取代第一輪的 `dispatchDepth` 與四個交付點）。第三輪：只交付 `splice(0)` 取出的批次，回呼內新觸發的排到下一個 task；每個插件的 hook 取得與呼叫在同一個 try 內、只讀一次，失敗記在該插件。ctx 凍結，`effects` 也凍結。
- 接收佇列（第二輪）：`checkOverflow` 抽出，網路接收與 `deliverInjected` 的觀察項共用；`deliverInjected` 先查 `wsConnections.get(ws) === info` 且 `readyState === OPEN`。
- Swift：第三輪改為共用來源 `LiqiSideEffectMethods`（Deviation 15、16）；`JSContractTests` 第四輪起四條：`testEverySideEffectConstantIsInTheSet`（集合完整性）、`testServicesBranchOnlyOnTheSideEffectMethodSet`（原始碼規則，取代第三輪的 `testBridgeBranchesOnlyUseTheSideEffectMethodSet`）、`testReshapeForbiddenListCoversEverySwiftConsumedMethod`（`consumed`）、`testRespondForbiddenListCoversEverySwiftSideEffectMethod`（`all`）。第二輪的正則反查已移除。`PluginsPageView` L3 說明與 `Localizable.xcstrings` 四語系同步。AutoPlay 未改。

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

### 第三輪（Astra 第二輪）

| 階段 | 結果 | log |
|---|---|---|
| 先紅（新測試對 31307ac） | 3 fail：`IR-26`（回呼內再退化在同一批交付）、`IR-27`（getter 拋錯後健康插件零通知）、`IR-28`（缺 `localPending` 診斷；排程失敗、上限、關閉三段的行為紅由 R3-4a～e 變異補證） | `r3-red.log` |
| 實作後 | b2 271／v2 21／p4 24／keepalive 11／plugin-regression 39／local-unlock 9，全 0 fail。`IR-10` 改為每 100 筆讓出一個 task（一次 300 筆會撞上新的 256 上限） | `r3-final-*.log` |
| 變異（新增 9＋DG10 改錨點） | 10/10 killed | `r3-mutate-new.log` |
| 變異（全量 242） | 240/242，只剩等價 T7、U10 | `r3-mutate-final-1.log`、`-2.log` |
| Swift 變異（Astra 四種寫法＋三條） | 七條全紅：以 builder 常數寫成 switch、Set、字典、反向比較（V1～V4，原始碼規則抓到）；`LiqiResponseStore` 新增集合外字面值（V5）；集合新增方法但 JS 未更新（V6）；JS 名單拿掉 `cancelMatch`（V7）。每條還原後 sha256 相同 | `r3-swift-mut-V1-builder-const.log`～`V7-js-list.log` |
| Swift 指定（還原後重建） | 21 個類別（含 parser、bridge、ResponseStore、WebSocket 相關）275 tests 0 failures；`PluginSendGuardTests` 單獨 12/0（Deviation 19）；bundle 內兩個 JS 與 worktree 逐 byte 相同 | `r3-swift-build-final.log`、`r3-swift-targeted-final.log`、`r3-swift-sendguard-final.log` |

可重現的故障測試（建議 5）：排程失敗（`IR-28` 以替換 `setTimeout` 注入）、getter 拋錯（`IR-27`）、號碼耗盡（`IR-28` 的 257 筆）。


### 第四輪（Astra 第三輪）

| 階段 | 結果 | log |
|---|---|---|
| 先紅（新測試對 640f60a） | 6 fail：`IR-4`（關閉丟棄零行 log）、`IR-9`（dispatch 後拋錯，交付後殘留 1 筆保留）、`IR-29`（hook 內重入 256 筆全部 `ok:true`）、`IR-30`（每筆送出保留 2 筆）、`IR-31`（排程失敗後永久 `inject_busy`）、`IR-32`（退化排程失敗拋進送出）。`IR-33`（同 task 300 筆，建議 6）修前即綠，是補覆蓋 | `r4-red.log` |
| 實作後 | b2 277／v2 21／p4 24／keepalive 11／plugin-regression 39／local-unlock 9，全 0 fail | `r4-final-*.log` |
| 變異（新增 12） | 首跑 10/12：R4-2b（無回應時不釋放）、R4-2c（關閉清掉所有連線）存活；補 `IR-34` 與 `IR-28` 跨連線斷言後 12/12 | `r4-mutate-new.log`、`r4-mutate-new-2.log` |
| 變異（全量 254） | 252/254，只剩等價 T7、U10。過期錨點 10 條依新程式碼改寫（PS73、IR11、DG1、DG6、R2-4a～d、R3-4c、R3-4e）；R2-4b 改守「本地成功不帶出保留」 | `r4-mutate-full-1.log`、`-2.log` |
| Swift 變異（新規則） | W1～W6 全紅：集合新增常數漏加 `all`（W1）、typealias＋跨行引用 builder 常數（W2）、例外字面值在同檔另一行重用（W3）、例外常數在同檔另一行重用（W4）、bridge 目錄外新增字面值（W5）、例外行已不存在（W6）。第三輪 V1～V7 重跑仍全紅。每條還原後 sha256 相同 | `r4-swift-mut-W1-*.log`～`W6-*.log`、`r4-swift-mut-V1-*.log`～`V7-*.log` |
| Swift 指定（還原後重建） | 20 個類別 276 tests 0 failures；`PluginSendGuardTests` 單獨 12/0（Deviation 19）；bundle 內兩個 JS 與 worktree 逐 byte 相同 | `r4-swift-build-final.log`、`r4-swift-targeted.log`、`r4-swift-sendguard-alone.log` |

可重現的故障測試：計時器拋錯（`IR-28`、`IR-31`、`IR-32`）、派發完成後拋錯（`IR-9`、`IR-30`、`IR-34`）、hook 內重入（`IR-29`）。


### 第五輪（Astra 第四輪）

| 階段 | 結果 | log |
|---|---|---|
| 先紅（新測試對 02fd3dc） | 1 fail：`IR-32` 新增的同連線同 reason 路徑（首次排程拋錯、恢復計時器、同 reason 再觸發，零通知） | `r5-red.log` |
| 實作後 | b2 278／v2 21／p4 24／keepalive 11／plugin-regression 39／local-unlock 9，全 0 fail。`IR-35`（守衛者被 `local_busy` 拒絕是本地錯誤）鎖住新契約，修前即綠 | `r5-final-*.log` |
| 變異（新增 R5-1＋DG2 改錨點） | 2/2 killed | `r5-mutate-new.log`、`r5-mutate-dg2.log` |
| 變異（全量 255） | 253/255，只剩等價 T7、U10 | `r5-mutate-full-1.log`、`-2.log` |
| Swift 變異（新規則） | W7（常數加 `: String` 型別註記＋集合外分支）、W8（改 `static var`＋分支）、W9（computed 形式，報「認不出的宣告形式」）、W10（builder 本體新增比較函式）全紅；W1～W6、V1～V7 在新規則下重跑仍全紅；每條還原後 sha256 相同 | `r5-swift-mut-*.log` |
| Swift 指定（還原後重建） | 20 個類別 276 tests 0 failures；`PluginSendGuardTests` 單獨 12/0；bundle 內兩個 JS 與 worktree 逐 byte 相同 | `r5-swift-build-final.log`、`r5-swift-targeted.log`、`r5-swift-sendguard-alone.log` |


### 第六輪（Astra 第五輪）

| 階段 | 結果 | log |
|---|---|---|
| 新測試（只加測試與文件，程式未改） | `IR-36`（重觸發已交付的退化不新增排程：`marker` 先於新退化 B；第七輪起另以可控 `setTimeout` 計數直接斷言新增排程為 0）、`IR-4` 送 Swift 失敗恰好一行「injectReceive 未交付：送 Swift 失敗」。兩者鎖住既有行為，對 d61b899 即綠；有效性由下列變異證明 | `r6-tests.log` |
| 六套 node | b2 279／v2 21／p4 24／keepalive 11／plugin-regression 39／local-unlock 9，全 0 fail | `r6-final-*.log` |
| 變異（新增 2） | R6-1（拿掉「無待交付不排」）由 `IR-36` 殺、R6-2（送 Swift 失敗不記 log）由 `IR-4` 殺，2/2 | `r6-mutate-new.log` |
| 全量變異、Swift | 依裁決免跑：JS 邏輯與 Swift 都未改（`git diff d61b899 -- command/` 為空） | — |

### 第七輪（Astra 第六輪建議，純測試）

| 階段 | 結果 | log |
|---|---|---|
| b2 | 279/0；`IR-36` 新增可控 scheduler 計數，重觸發已交付的 A 新增排程 0 | `r7-b2.log` |
| 變異 R6-1 | 仍殺（`IR-36` 的計數斷言：變異版新增排程 1） | `r7-mutate-r6-1.log` |

### 復驗（Opus，主線 2026-10-18）

宣稱全部成立；全量 NakiTests 1187/0（證據 `.swfd/logs/verify-pair-source/ir-*`）。Dev 19 的合跑紅未在 d51e22b 基準上對照，「與本包無關」屬推論。契約依復驗補兩句：退化事件可能在連線關閉後才送達；`respondLocally` 的 `ok:true` 不保證交付。

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

第三輪（Astra 第二輪，主線裁決 0 擋 4 應修 1 建議全採納）：

| # | 等級 | 回應 | 修正 | 測試 | 變異 |
|---|---|---|---|---|---|
| 1 | 應修 | 採納（裁決：共用來源） | `LiqiSideEffectMethods`＋原始碼規則（Deviation 15、16） | Swift V1～V7 全紅 | V1～V7（Swift） |
| 2 | 應修 | 採納 | 批次快照，回呼內新事件留給下一個 task | `IR-26` | R3-2 |
| 3 | 應修 | 採納 | hook 取得與呼叫一起隔離、只讀一次、失敗記在該插件 | `IR-27` | R3-3a、R3-3b |
| 4 | 應修 | 採納 | 每連線 256 上限與 `local_busy`、排程失敗立即釋放、`diagnostics().localPending`、契約改寫；撤回 Dev 12 | `IR-28` | R3-4a～R3-4e |
| 5 | 建議 | 照做 | live 再補三項；三種故障本輪寫成可重現測試 | `IR-27`、`IR-28` | — |

第四輪（Astra 第三輪，主線裁決 0 擋 5 應修 1 建議全採納）：

| # | 等級 | 回應 | 修正 | 測試 | 變異 |
|---|---|---|---|---|---|
| 1 | 應修 | 採納 | 接受當下即按交易保留並計入上限（Deviation 20） | `IR-29`、`IR-28` 跨連線 | R4-1a～R4-1d |
| 2 | 應修 | 採納 | 保留每交易至多一筆、移出冪等；無回應可交付時釋放（Deviation 20、23） | `IR-9` 清理斷言、`IR-30`、`IR-34` | R4-2a～R4-2c |
| 3 | 應修 | 採納 | `injectReceive` 排程失敗撤回並回 `schedule_failed`；退化旗標排程成功才設，失敗留待下次觸發（政策寫進契約） | `IR-31`、`IR-32` | R4-3a～R4-3d |
| 4 | 應修 | 採納 | 集合完整性測試；掃描擴到 `command/Services`、字面值與常數名兜底、例外整行比對且只用一次；契約收窄為實際規則（Deviation 21） | Swift W1～W6、V1～V7 全紅 | W1～W6、V1～V7（Swift） |
| 5 | 應修 | 採納（裁決：補交付） | 關閉時排隊的合成項各寫一行 log（Deviation 22）；b2 RESPONSE field 1 改「可省略」、API 名單來源改 `LiqiSideEffectMethods`、b2「超過 256」改「已有 256」 | `IR-4` 改為恰好一行 | R4-5、IR11 |
| 6 | 建議 | 照做 | `IR-10` 保留分批版，另加同 task 300 筆 `IR-33`；契約改寫守衛擋下不受上限、不是有界佇列、耗用資源屬 U4；live 補容量量測 | `IR-33` | — |

第五輪（Astra 第四輪，主線裁決 0 擋 3 應修全採納）：

| # | 等級 | 回應 | 修正 | 測試 | 變異 |
|---|---|---|---|---|---|
| 1 | 應修 | 採納 | 去重入隊與喚醒排程分開（Deviation 24） | `IR-32` 同連線同 reason 路徑 | R5-1、DG2 |
| 2 | 應修 | 採納 | builder 解析支援型別註記與 `static var`，認不出的宣告形式明確報紅；builder 本體逐行掃描（Deviation 25） | Swift W7～W10 全紅 | W7～W10（Swift） |
| 3 | 應修 | 採納 | API 與 b2 的拒絕結局限定為「非守衛方法、且整筆沒有已接受提案時照常送出」，守衛方法一律見 §4.2，已有提案交付先到者 | `IR-35`、`IR-7`、`IR-8` | — |

第六輪（Astra 第五輪，主線裁決 0 擋 3 應修全採納）：

| # | 等級 | 回應 | 修正 | 測試 | 變異 |
|---|---|---|---|---|---|
| 1 | 應修 | 採納（裁決：保留條件） | 撤回 Dev 24 的不可觀察論證，改述為已以 `IR-36` 覆蓋 | `IR-36` | R6-1 |
| 2 | 應修 | 採納 | 契約改為送 Swift 失敗也寫一行插件 log（與實作一致） | `IR-4` 送 Swift 失敗模式 | R6-2 |
| 3 | 應修 | 採納 | live 清單容量項改為非守衛／守衛兩組對照 | — | — |

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
- WebKit 上退化通知的時機：相對造成它的送出與其 microtask，通知在之後的 task（第三輪建議 5）。
- 回呼內再退化：`onConnectionDegraded` 內造成另一條連線退化，新事件在下一個 task 才到。
- 對局合成後 kill-switch：守衛插件在對局連線上 `injectReceive`／`respondLocally` 被接受後關 L3，守衛方法仍不外送。
- 本地回應容量（第四輪建議 6、第六輪第 3 條），兩組對照：非守衛方法且整筆沒有已接受提案時，第 257 筆 `local_busy` 後照常外送；守衛方法上守衛者第 257 筆被拒為 `respond_rejected` 本地錯誤、零外送。兩組都量 WebKit 上的記憶體與交付延遲。
- 守衛洪流：同一個 task 大量被擋的守衛方法送出（不受上限）期間注入回 `msgid_busy`、交付後恢復，量測保留筆數與恢復時間（第四輪建議 6）。

## 已知風險

- 三個功能都只有單測，未 live 驗證。
- 退化事件在下一個 task 才交付：同一個 task 裡排在後面的訊息會先派發（限制在觸發當下已生效，只是通知較晚）。
- 同一個 task 裡大量本地回應（守衛擋下不設上限）會暫時占住號段，注入可能回 `msgid_busy`，下一個 task 交付後恢復。守衛擋下的保留不是有界佇列，同 realm 刻意洪流耗用資源屬 U4。
- 原始碼規則（Deviation 21）抓不到字串拼接或插值組出的方法名、以別名常數轉手的值；`command/Services` 以外（`App`、`Actions` 等）的 Swift 不掃；builder 本體的常數宣告與送出定義行不逐行掃（宣告形式另有檢查）。
- 退化事件排程失敗時不自行重試：若之後再也沒有新的退化觸發，那批事件不會交付。
- `PluginSendGuardTests` 的 log 測試在大批執行時因 `LogManager` 5000 筆上限而紅（Deviation 19，既有問題）。
- 合成能力被接受即污染不分連線（Deviation 14）：守衛插件在對局連線上用 `respondLocally` 也會污染，之後停用要重載頁面才解除守衛。
- `window.__nakiWebSocket.injectReceive` 頁面程式可直接呼叫，跳過 L3 與名單（同 realm 不防，契約已寫）。
- Swift log 對本地成功仍印「Blocked request: <method> (respond_locally)」：沿用守衛擋下的字樣，未改 Swift。
