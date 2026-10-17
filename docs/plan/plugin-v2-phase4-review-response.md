# plugin-v2 Phase 4 審查回應

設計：`plugin-v2-phase4.md`。審查原文：主 repo `.swfd/logs/p4-review/astra-review1.md`。log：本 worktree `.swfd/logs/p4/`（第二輪檔名以 `r2-` 開頭，變異為 `mutation-r2.log`）。

## 第一輪（Astra，審查 HEAD 9d8fd6c）

結果：3【擋】、5【應修】、1【建議】。主線裁決全部採納；第 3 條改為合併 gate，第 9 條採納為「不做」。

| 條 | 類別 | 內容 | 處理 | 證據 |
|---|---|---|---|---|
| 1 | 擋 | 名單漏 `NotifyGameTerminate` | 採納。名單改以 Swift 消費端反查：`MajsoulBridge`、`LiqiParser` 的字面值，加上登入回應、`startUnifiedMatch` 回應與表情廣播。補進 `NotifyGameTerminate`、三個登入回應、`oauth2Auth`、`startUnifiedMatch`、`NotifyGameBroadcast`。新增一致性測試，從 Swift 原始碼抽 method 逐一比對 JS，缺一即紅 | `JSContractTests.testReshapeForbiddenListCoversEverySwiftConsumedMethod`；Swift 變異（JS 拿掉 `NotifyGameTerminate`）變紅 `r2-swift-mutation-terminate.log`；node 禁改案例；JS 變異 N1、N2 |
| 2 | 擋 | 攔後交付非原子、失敗記成成功 | 採納。編碼與建事件前置到 stop 之前；建構期失敗才 fail-open。攔後 bridge 拒收、dispatch 拋錯進入故障：鎖死＋診斷（socketId、method、msgId、候選改寫者、kind、錯誤），不重送原事件。統計分「嘗試」與「交付」。`sendToSwift` 改為回傳是否送達 | node 故障注入三案（編碼失敗、bridge 拒收、dispatch 拋錯）；JS 變異 M8、N3–N6 |
| 3 | 擋 | 合併所需 live 未成立 | 採納為合併 gate。本輪只修 spike 與文件；設計 §8 列 L1–L7，標「合併前必跑」 | 設計 §8 |
| 4 | 應修 | 「與 main 等價」須限定 | 採納。設計 §1.2 改為型別 × 遊戲註冊方式表：非 capture 的 ArrayBuffer 與 TypedArray 一致；遊戲改用 capture 時 Naki 刻意優先，是行為變更；Blob 是遊戲先收、插件與 Swift 非同步 | node main 差異比較（零插件與等長兩組，對 `2d02a03` 的 JS 逐一相同，含 byteOffset 非 0 的 TypedArray） |
| 5 | 應修 | kill-switch 錯誤名稱過度確定、無中繼資料 | 採納。改名「合成派發期間錯誤」（`synthetic_dispatch_error`），記中繼資料與候選改寫者；全頁鎖死保留 | node kill-switch 案例斷言 kind、method、候選、錯誤訊息與 log 文字；JS 變異 M9、N10 |
| 6 | 應修 | `rewriteReceive` 授權被靜默擴大 | 採納。新增 `reshapeReceive` 明確選用，`PluginManifest.validate` 要求它與 `rewriteReceive` 一起宣告，grant 原樣下發。未選用的插件長度不等仍回 `false`。契約段寫遷移說明 | `PluginManifestValidationTests.testReshapeReceiveRequiresRewriteReceive`；node 未選用案例；JS 變異 N7 |
| 7 | 應修 | hook 撤回契約誤寫 | 採納。契約改為「回到該 hook 進入前的鏈狀態」 | node 案例：A 成功、B 改寫＋drop 後拋錯，交付 A 的結果；JS 變異 N8 |
| 8 | 應修 | 測試未覆蓋關鍵邊界 | 採納。補故障注入、main 差異比較、TypedArray offset、Blob 完整交付（假 `FileReader`，斷言 Swift 收到完整 bytes 且型別為 blob）。`nostop` 不再當通過證據：新增哨兵，偵測到 stop 失效即記 `stop_ineffective` 並鎖死 | node 23 條；JS 變異 N9 |
| 9 | 建議 | 不擴別名封鎖、不加單插件復原 | 採納為不做。名單以 canonical 全名比對 | 設計 §4 |

**表態表**：#3 維持 L2（另加選用）、#4 不加 drop 替代、#5 `injectReceive` 寫弱順序契約（設計 §2.3）、#7 全頁鎖死。其餘需 live 的項目進設計 §8。

### 採納過程中的連帶改動

- 哨兵是第二個 message listener。`plugin-regression.cjs` 與 `plugin-v2-regression.cjs` 的假 socket 以「最後註冊者」覆蓋同類 listener，主 listener 因此被蓋掉、13 條變紅。改成保留第一個註冊的 message listener，也就是 Naki 主 listener。這是 harness 的限制，不是行為回歸。
- `JSContractTests.testMessageListenerIsRegisteredInCapturePhase` 的期望改為 `message:true,message:false`。
- 變異 M3 第一版沒有真的改變順序（漏網），改寫成把 Swift 送出延到重派之後，被 6 條抓到。

### 驗證（第二輪）

| 項目 | 結果 |
|---|---|
| `plugin-v2-p4-regression` | 23／23 |
| `plugin-v2-regression` | 21／21 |
| `plugin-v2-b2-regression` | 68／68 |
| `plugin-regression ../naki-plugins` | 38／38 |
| `keepalive-regression` | 11／11 |
| JS 變異 | 26／26 被抓（第一輪 16＋新 10） |
| JSContract、NakiWebSocketScript、PluginManifestValidation、PluginRegistry、BridgeMessageContract | 57／0 |
| NakiTests 全量 | 1181／0 |

### 仍未驗證

- 設計 §8 的 L1–L7 全部（live）。
- `reshapeReceive` 的 manifest 錯誤字串沒有加翻譯；catalog 查不到時原樣顯示。

## Astra 第二輪（0 擋 1 應修 3 建議，主線裁決全採納）

原文 `.swfd/logs/p4-review/astra-review2.md`。第一輪 1–9 條核對：1、2、4–7、9 已修；3、8 部分（live 未跑；哨兵敘述過滿，即本輪應修 1）。

| # | 等級 | 問題 | 處理 | 證據 |
|---|---|---|---|---|
| 1 | 應修 | 哨兵只能偵測原事件抵達哨兵的失效，文件寫得過滿 | 採納。設計 §1.1、§5 限縮為「只偵測原事件抵達哨兵」，列出盲區一（原事件 stop 無效，但後註冊的遊戲 capture handler 以有效 stop 阻斷）與盲區二（哨兵未註冊或自身失效沒有獨立偵測）。補反例測試。notes 寫明舊 harness「保留第一個 listener」不當順序證據，順序證據只來自 P4 多 listener harness 與 live L4–L6 | node 反例 `known blind spot: ...`：遊戲 capture handler 收兩份、`faults` 0、不鎖、後續 replace 仍成功；設計 §5「哨兵」、§7；notes D11 |
| 2 | 建議 | D10 應稱為已記錄的降級交付 | 採納為文件。D10 改名；寫明鎖定只停後續變長 replace／drop，不重同步、不停遊戲與自動操作；`delivered` 不代表解碼成功，驗收要與 `faults` 一起看 | 設計 §5 表與 kill-switch 段；契約段；notes D10 |
| 3 | 建議 | 名單反查是有限掃描 | 採納為文件。敘述限縮為「兩檔字面值＋三組常數的明確盤點」，不宣稱日後新增消費端必被擋。Lobby 未封鎖的 `fetchCharacterInfo`、`fetchAccountCharacterInfo`、`fetchAccountInfo`、`fetchAllCommonViews` 列為允許變長的合法用例 | 設計 §4 |
| 4 | 建議 | Swift validate 不是授權邊界 | 採納為文件。契約段與設計 §2.1 寫明 grant／L3 與插件同 realm，validate 是選用條件不是隔離邊界，沿用既有信任模型 | 契約段 Phase 4；設計 §2.1 |

### 驗證（第三輪）

| 項目 | 結果 |
|---|---|
| `plugin-v2-p4-regression` | 24／24 |
| JSContract、NakiWebSocketScript | 20／0（`.swfd/logs/p4/r3-targeted-tests.log`） |

### 仍未驗證

- 設計 §8 的 L1–L7 全部（live）。盲區一在實際 WebKit 是否會出現也未驗證。
