# plugin-load-source 實作筆記

目標：宿主標記插件載入來源（`loadSource`）與提供早期 log（`devLog`），來源見 Astra review4 新發現 2、4。

## 做法
- `naki-plugins.js`：`bootstrapState` idle→loading→done；`loadSource` getter（loading 時 `'document-start'`，否則 `'hot'`）；`beginBootstrap`／`endBootstrap` 每頁只成功一輪。
- `PluginRegistry.buildInjectionScript`：插件源碼前後各串一行 begin／end。`enableScript`（熱啟用）不帶標記。
- `devLog`：沿用 `pluginLog`，每插件 500 行計數。

## Deviations
- `devLog` 的「正在載入」判定用「持有宿主 grant」而非另設載入旗標：載入中（含熱啟用 `register` 之前）的插件必有 grant，且停用即清 grant，語意等價且不需第二個狀態；未知 id 仍丟棄。
- 沒有為 begin／end 加防偽簽章：同 realm 無法防惡意插件（契約 §8），改以「每頁一輪」避免熱插件重入 document-start。
- 注入 script 若有插件語法錯，整段不解析、begin 也不會跑，狀態維持 idle，其後熱啟用仍回 `'hot'`（安全方向）。
