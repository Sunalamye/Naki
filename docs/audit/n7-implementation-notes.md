# N7 實作筆記：authGame 外觀改寫等價測試

基準 main 129a67f，分支 n7-equivalence。只加測試，未改產品程式碼。
測試檔：`NakiTests/AuthGameRewriteEquivalenceTests.swift`（8 條）。

## 做法

- 測試中組出 `ResAuthGame` bytes（欄位號查 `docs/protocol/liqi.json`），帳號 id 與暱稱都是匿名測試值。
- 用測試內的最小 protobuf 走訪器，只改 account_id 等於自家的那筆 `PlayerGameView`，改寫的外觀欄位：
  avatar_id(2)、title(3)、avatar_frame(8)、views(10).item_id、character(6).skin(5)、character.views(4).item_id。
- 改寫前後的 bytes 各自經 envelope 餵給全新的 `MajsoulBridge`：登入、authGame、`ActionNewRound`、`ActionDiscardTile`。
- 比對快照：authGame 事件（含 `start_game` 的 id、is3P、names）、後續事件、`lastParsed["data"]`（含 players、seatList）、fault 清單、blocking。

## 涵蓋情境

| 測試 | 內容 |
|---|---|
| `testBaselineScenariosProduceExpectedStartGame` | 四種桌況的基準非空轉：座位、is3P、names 數量、自家暱稱位置；缺 seat_list 留下 heuristic fault |
| `testEqualLengthAppearanceRewriteLeavesBridgeOutputUnchanged` | 四麻、三麻、缺 seat_list、重連（reset 後第二次 authGame，is_game_start=true）。等長改寫（值 XOR 1），整包長度不變，快照逐項相等 |
| `testVariableLengthAppearanceRewriteLeavesBridgeOutputUnchanged_reference` | 參考，v0.1 不需要。外觀 id 由 3 bytes 變 4 bytes，整包變長，快照仍相等 |
| `testMisrewritingAccountIdIsDetected` | 反向鎖：改自家 account_id，快照必須不同；缺 seat_list 時 `start_game` 消失 |
| `testMisrewritingSeatListIsDetected` | 反向鎖：seat_list 反轉，自家座位 2 變 1 |
| `testMisrewritingNicknameIsDetected` | 反向鎖：改自家 nickname，快照必須不同 |
| `testVarintLengthDependsOnValueAndCrossesAt16384` | 127／128、16383／16384、2097151／2097152 的 varint 長度；跨 16383／16384 時「長度不同」 |
| `testTitleCrossingVarintBoundaryChangesPacketLengthButNotBridgeOutput` | title 16383 換 16384，整包多 1 byte，Naki 輸出不變 |

另有 `assertDiffConfinedToSelfAppearance`：每次改寫都驗證只有自家 players 的外觀欄位不同，其餘 entry（含他人 players、seat_list）逐位元組相同，自家 account_id 與 nickname 不動，且確實有外觀差異（防空轉）。

## 結論（對插件 v0.1）

- 等長改寫對 Naki 安全：四種桌況下解析結果與 MJAI 事件流與改寫前完全相同（見上表第 2 列）。
- 等長與否取決於「新舊實際值」的 varint 長度，不取決於欄位型別。16383 到 16384 從 2 bytes 變 3 bytes，等長 in-place 改寫不可行，插件端必須先比較兩值的 varint 長度，不同就不能 in-place。
- 變長改寫在 Naki 端同樣不影響輸出（參考測試），但外層 length prefix 與 envelope 要由改寫方重算；這一段只有測試內的改寫器驗過，不代表插件實作正確。

## 未涵蓋

- 真實 live 封包形狀：沒有抓真實 authGame；欄位集合依 `liqi.json` 推出，真實封包可能有其他欄位（如 robots、game_config、team 欄位）或 unknown field。
- `robots`(7) 內的 PlayerGameView 與人機場；`game_config`(5) 內容。
- syncGame／enterGame 的重連封包（本測試的重連只涵蓋第二次 authGame）。
- 變長改寫時 WebSocket frame 或遊戲端 decoder 的行為；本測試只驗 Naki 這一側。
- 插件實際改寫程式本身；測試使用的是測試內的改寫器。

## Deviations

- 無偏離計畫。測試資料的 varint 變長量原先取 +1_000_000 仍是 3 bytes，改為 +100_000_000（4 bytes），屬測試資料修正。
