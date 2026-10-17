# plugin-devlog-seal 實作紀錄

目標：宿主見證 `devLog` 紀錄的頁尾，供插件側匯出腳本驗完整性（外部審查指出頁面側無法自證）。

## 做法
- `naki-plugins.js`：新增 `devLogSealed` 集合與 `devLogSeal`；`devLog` 在封存後回 false；`beginBootstrap` 成功時清空計數與封存狀態。
- seal 行走 `pluginLog`（`plugin_event`/`log`），Swift `handlePluginEvent` 原樣落檔為 `[Plugin] <id>：<json>`，與 `devLog` 同格式，Swift 端零改動。
- `count` 取既有 `devLogCounts`（只計 `sendToSwift` 確認交付的 `devLog`）。seal 不寫入計數、不受 500 上限影響。
- 測試：`scripts/plugin-v2-b2-regression.cjs` 新增 7 案（先紅後綠）。

## Deviations
- 純物件判定只用原型鏈（`null` 或原型的原型為 `null`），不另用 `Object.prototype.toString`：變異證明後者是多餘守衛；原型鏈寫法同時容許跨 realm 物件。
- 沒有新增 Swift 測試：Swift 端未改動，既有 `plugin_event` 契約案（`BridgeMessageContractTests`）已涵蓋 `id`/`msg` 欄位；JSContractTests 無 `devLog` 案可延伸。
- `ctx.log` 不受封存影響（範圍僅 `devLog`／`devLogSeal`）。
- `beginBootstrap` 重設會讓重設前的計數歸零，屬「每頁一輪」語意，同 realm 程式可藉此重置，歸入 §8 信任邊界。
