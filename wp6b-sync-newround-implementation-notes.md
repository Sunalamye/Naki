# wp6b-sync-newround implementation notes

## 計畫
- 重連 syncGame 的 actions 不含 ActionNewRound 時，由 snapshot 合成 start_kyoku，插在重放事件之前（對應 shinkuan/Akagi 982ff48）。
- snapshot 手牌 14 張時，前 13 張排序進 tehai，第 14 張補一個本家 tsumo。

## 實作
- `MajsoulBridge.parseSyncGameRestore`：actions 不含 ActionNewRound（含 actions 為空）且有 gameState → 先呼叫 `parseGameState`，再重放 actions。actions 含 ActionNewRound → 只重放，與改前相同。
- `MajsoulBridge.parseGameState`：14 張時末張轉 tsumo 事件，放在 kan-dora 事件之後。
- 事件順序：`start_kyoku` → snapshot kan-dora（doras[1...]）→ snapshot tsumo（14 張時）→ 重放事件。

## Deviations
- **判斷條件用 action 名稱而非重放結果。** 規格寫「重放結果不含 start_kyoku 就合成」。改為「actions 不含名為 ActionNewRound 的 action 才合成」。差別只在 ActionNewRound 存在但解析失敗（分數／手牌壞掉而 roundBlocked）時：規格會改用 snapshot 開局，本實作維持改前行為（不合成、保持 blocking）。理由：不改既有 fail-closed 路徑，比較保守。
- **parseGameState 先於重放執行。** 規格只要求事件插在前面。先跑 snapshot 會先把 `doras` 設成完整清單，重放 action 帶的 doras 不會多於它，`parseAction` 就不會重複補發 kan-dora（測試 `testRestoreActionsWithoutNewRoundStartFromSnapshotWithoutDuplicateDora` 覆蓋）。若改成先重放再合成，同一張 dora 會被重放與 snapshot 各發一次。
- **parseGameState 回 nil（roundBlocked）時。** 保守選項：不合成，函式照舊只回重放事件。由於 `parseGameState` 失敗會設 `roundBlocked = true`，接著重放的局內事件會被 `parseAction` 既有的 roundBlocked 閘門丟掉（只留 end_kyoku）。這比改前（無 start_kyoku 仍餵局內事件）更保守；只發生在「無 ActionNewRound 且 snapshot 壞掉」的組合。此組合沒有專屬測試（未驗證）。
- **tsumo 放在 kan-dora 之後。** 規格只說「start_kyoku 之後」。dora 先於 tsumo 讓 bot 在本家決策點前已知全部寶牌。
- **14 張只看 `count == 14`。** 超過 14 張維持 `prefix(13)`、不發 tsumo（伺服器不應送出，未見樣本）。第 14 張轉換失敗時不發 tsumo，與 `parseNewRound` 一致。

## 未驗證
- 真實伺服器是否會送「actions 非空但不含 ActionNewRound」的 syncGame：未知，無 hex 樣本。本修正是 fail-safe。
- 14 張 snapshot 中最後一張是否就是剛摸的牌：伺服器排序未知（推測與 Akagi 同假設）。
- 未啟動 App，無 runtime 驗證。

## 復驗後補充
- **parseGameState 回 nil 且 actions 非空時會亮 blocking 橫幅。** `recordBlockingFault`（如 `GameSnapshot.tiles`）設 `roundBlocked = true`，重放與之後的 live 局內事件都被擋（end_kyoku 除外），直到下一個 ActionNewRound 成功。改前此組合不記 fault、照樣餵沒有 start_kyoku 的局內事件。
- **快照是當下狀態，actions 是歷史（推測風險）。** actions 從局中開始時，start_kyoku 帶的是當下手牌，重放的本家 dahai 會再從手牌移除一次；14 張快照補了 tsumo、重放又有本家 ActionDealTile 時會出現兩個本家 tsumo。與 Akagi 982ff48 做法相同；改前此組合連 start_kyoku 都沒有。MortalSwift 對此的反應未驗證。

## Release 影響面
- 只影響重連（syncGame／enterGame）且伺服器未送 ActionNewRound 的情況：actions 從局中開始，或 actions 為空且快照手牌 14 張（多一個 tsumo）。
- 正常開局（ActionNewRound notify）與含 ActionNewRound 的重連，事件逐 byte 不變（`testRestoreActionsWithNewRoundIgnoreSnapshot`，獨立復驗 C 段）。
