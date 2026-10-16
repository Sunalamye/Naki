# authGame error 欄位修正

## 目標
伺服器回 `ResAuthGame.error` 時，不再被當成協定漂移而掛 blocking fault。

## 改動
- `LiqiParser.parseAuthGameResponse`：新增 `case 1`，取 `.lq.Error.code` 放進 `result["error"]`；沒有 seat_list 且有 error 時不記「沒有 seat_list」fault。
- `MajsoulBridge` authGame 回應：先看 seatList，有就照原路徑建 Bot；沒有 seatList 且有 `error` 時，只 log「伺服器拒絕 authGame，code N」，不掛 blocking fault、不發 `start_game`；都沒有仍 blocking。
- 測試：`NakiTests/AuthGameErrorResponseTests.swift`（共 5 個：被拒絕、無 error 無 seatList 仍 blocking、正常 seatList、error 與 seatList 並存、空 `error {}` 無 seatList）。

## 為什麼
對局結束後客戶端重送 authGame，伺服器回只含 error 的 33 bytes，原本落到 default 被丟棄，畫面誤報「雀魂改了協定欄位」。

## Deviations
- 只解 `code`（不解 u32_params／str_params／json_param）：目前沒有讀取端，從簡。
- error 訊息缺 code 欄位時 code 以 0 記錄，仍視為被拒絕（保守：不誤報漂移）。
- 變異 2 用 `code < 0` 讓 error 分支失效，代替直接反轉條件（`if let` 綁定無法直接反轉）。

- code 0 與 presence 的取捨：seatList 優先，避免正常回應帶空 `error {}` 時靜默不建 Bot。live 回應是否帶 field 1 未驗證。parser 端本來就只在無 seat_list 且有 error 時略過 fault，不需改。

## 驗證（log 在主 repo `.swfd/logs/authgame-error/`）
- red.log：修前 `testServerRejectionIsNotAProtocolFault` 失敗（keys=[] blocking fault，重現現場症狀）。
- green.log：3 測試全綠。
- mutation-1.log（移除 case 1）、mutation-2.log（bridge error 分支失效）：測試皆失敗，已還原。
- red-2.log / green-2.log：新增兩個測試，error 與 seatList 並存的測試在舊判斷順序下紅，修後 5 個全綠。
- mutation-3.log：判斷順序改回先看 error，並存測試失敗，已還原。
- test-full-2.log：全量 NakiTests。
