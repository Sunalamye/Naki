# 登入回應 error 欄位修正

## 目標
`ResLogin.error`（field 1，巢狀 `.lq.Error`）解出真實 code，而不是把巢狀 message 的首個 tag byte 當 code。

## 改動
- `LiqiParser.parseErrorCode`：解巢狀 blocks 取 field 1 varint，缺 code 回 0。
- `parseLoginResponse` 與 `parseAuthGameResponse` 的 `case 1` 共用它。
- 測試：`NakiTests/LoginErrorResponseTests.swift`（5 個：成功無 error、code 1002、空 error、多欄位、缺 code 欄位）。

## 為什麼
舊寫法對 `error { code: 1002 }` 回 8（`0x08` tag byte），多欄位時回 16，空 message 則完全沒有 error key。

## Deviations
- 讀取端：`MajsoulBridge` 只讀 authGame 的 `error`，登入的 `error` 目前無人讀取，故不改行為、不動 Bridge。
- 登入 `error` 現在即使是空 message 也會有 key（值 0），與 authGame 一致。
- 只解 `code`，不解 u32_params／str_params／json_param（從簡）。

## 驗證（log 在主 repo `.swfd/logs/login-error/`）
- red.log：修前 5 個中 4 個失敗（得到 8、16、nil）。
- green.log：修後 5 個全綠。
- test-full.log：全量 NakiTests。
