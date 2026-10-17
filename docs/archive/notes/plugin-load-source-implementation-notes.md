# plugin-load-source 實作筆記

目標：宿主標記插件載入來源（`loadSource`）與提供早期 log（`devLog`），來源見 Astra review4 新發現 2、4。

## 做法
- `naki-plugins.js`：`bootstrapState` idle→loading→done；`loadSource` getter（loading 時 `'document-start'`，否則 `'hot'`）；`beginBootstrap`／`endBootstrap` 每頁只成功一輪。
- `PluginRegistry.buildInjectionScript`：插件源碼前後各串一行 begin／end。`enableScript`（熱啟用）不帶標記。
- `devLog`：沿用 `pluginLog`，每插件 500 行計數。

## Deviations
- `devLog` 的「正在載入」判定用「持有宿主 grant」而非另設載入旗標：載入中（含熱啟用 `register` 之前）的插件必有 grant，且停用即清 grant，語意等價且不需第二個狀態；未知 id 仍丟棄。
- 沒有為 begin／end 加防偽簽章：同 realm 無法防惡意插件（契約 §8），改以「每頁一輪」避免熱插件重入 document-start。
- 頁面無啟用插件，或注入 script 語法錯時，begin 從未被呼叫，狀態維持 idle；之後任何同 realm 程式呼叫 `beginBootstrap()` 可取得 `'document-start'`。跳出 try 讓 end 不執行同理。兩者皆屬 §8 信任邊界內的刻意繞過，`loadSource` 不是安全證明。
- 第二輪：`pluginLog` 回傳 `sendToSwift` 的真實投遞結果，`devLog` 失敗不佔配額；測試用的 `sendToSwift` 假件改回傳 true 以貼近真實實作。

- 復驗第二輪殘留：`pluginLog` 以 `=== true` 判定；naki-core 缺席時第 28 行退回的空函式回 undefined，若改成 `!== false` 會誤判已送達。三模組一起注入，此路徑正式環境走不到，未加測試。
