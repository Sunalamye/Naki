# 守衛插件主動污染 API 實作筆記

`ctx.taint()` 與 `ctx.isTainted()` 掛在 makeCtx，走既有 `taint()`（同一個集合、同一則 `tainted` 事件）。契約在 `docs/plugin-api-v1.md` 送出守衛段。

## Deviations

- **沒有 `api.taint`**：`register` 不回傳每插件專屬物件，全域 `__nakiPlugins.taint(id)` 無法驗證呼叫者，會讓插件污染別人。保守選擇是只提供 ctx 版本。
- **未擴大 `guardState()`**：它是診斷用，未記載於契約，本次不寫進契約。契約明說插件不得依賴它，改用 `ctx.isTainted()`。
- **任務敘述「污染後 L3 開啟＋守衛者放行仍不送」與現行行為不符**：現行規則是已污染者在 L3 開著且仍在鏈上、守衛該方法、有放行時會送出（既有測試「re-registered tainted plugin must approve again」）。依「行為與現行污染完全相同」不改規則。測試改驗：L3 關為 `outbound_disabled`、停用後為 `not_on_chain`、重新啟用仍污染。
- `JSContractTests` 沒有契約文件字串測試，未更動。
- **補測「只能污染自己」**：傳參數給 `taint()` 不影響結果；以「有參數才用參數」變異驗證該案例會紅，已還原。契約改為只列 `onReceive`／`onSend`／`onInjectResponse` 有 `taint`，`onRecommendations`／`onDisable` 沒有，程式不動。
