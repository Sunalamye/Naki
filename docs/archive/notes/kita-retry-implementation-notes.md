# K1 拔北請求與重試風暴 implementation notes

2026-10-09，branch `wp/k1-kita`，基準 `abd0d3a`。

## 證據

- live 房 30887（`.swfd/logs/s3-live-4/live-all.log`）：兩次拔北都是「手裡沒有北、剛摸到 `4z`」。
  送出 `080b`（只有 type=11）共 1321 次，伺服器回 7 bytes（成功打牌也是 7 bytes），從未廣播我方 `ActionBaBei`；同局電腦拔北正常。
- 歷史：`babei()` 從 `634b0a0`（2026-08-01）起就只帶 type，沒有被重構丟欄位。
  2026-08-05 D15 記錄的「拔北鏈多次成功」與「一次被靜默丟單」用同一個 payload。
- `ActionBaBei`／`RecordBaBei` 都帶 `moqie`：伺服器區分拔剛摸到的北和手裡的北。
  `080b` 等於 moqie=false。live 兩次失敗都是 moqie 應為 true 的情形，與 8/05 時好時壞相符。
- Akagi 是 MITM 唯讀，不組 request，無請求端證據。遊戲自己送的 babei request 沒有任何紀錄。
- 房 13364（`.swfd/logs/s3-live-5/`，對照錄影 `20261009-164439.mjai.jsonl`）：
  - `080b` 成功 3 次（seq 28、29、104），北都是配牌就在手、這次摸到的是別張或莊家第一摸。
  - 失敗 1 次（seq 43）：配牌的兩張北已拔完，暗槓 7p 後嶺上剛摸到北，約 60 次無回音，逾時被摸切。
  - 三局失敗（30887 兩次、13364 一次）共同點是手裡沒有別的北、北是剛摸到的那張。oplist 都是 `[1, 11]` 或 `[11]`，嶺上沒有不同的 type。
- 13364 兩個未解異常，都在該局第一摸：
  - seq 28（莊家開局）：首送 `080b` 0.98 秒無回音，重送後 59ms 出現 nukidora。回音屬於哪一送無法分辨。
  - seq 103（北在手、摸到 E）：送 `080b` 後 23ms 伺服器先廣播本家摸切 E，才回 RESPONSE。這段時間遊戲自己沒送 inputOperation。下一摸 seq 104 同樣的 `080b` 正常拔北。

## 修法

- `LiqiRequestBuilder.babei(moqie:)`：type=11，moqie 為 true 才帶。
  摸到北：`080b2801`；拔手裡的北：`080b`（與 13364 三次成功相同）。
- MCP `game_action babei` 新增可選參數 `moqie`（預設 false）。
- executor：`moqie = (tsumoTile == "N")`，與打牌的摸切判定同一來源。
- `AutoPlayEngine`：
  - 根因：15 次是**每輪**上限，`deliver` 每輪從 0 數；輪與輪之間只有 0.5 秒去抖，沒有退避也沒有總上限。
  - 同一批 oplist 一輪送不出去後跨輪退避（live 2 秒起加倍、上限 30 秒），換批即失效，送出成功清掉。
  - `no_open_majsoul_connection`：非和牌動作本輪立刻停手、停滯立刻上畫面（不等 4 拍），之後只在退避到期時探一次。
- executor：拔北的權威回音窗至少 1500ms（其他動作維持 700ms）。手裡兩張北時，過早重送可能多拔一張。

## Deviations

- **不帶 tile**：第一版照主線指定帶了 `tile="4z"`，主線複核後拿掉。8/05 與 13364 不帶 tile 都成功過，證據只支持 moqie。
- **和牌不跟著斷線停手**：既有夾具 A 鎖住「和牌遇 `no_open_majsoul_connection` 要在本輪重送」（漏和不可逆）。
  保守做法是和牌本輪照舊重送，用完才退避；非斷線的和牌失敗不退避。
- **「連線恢復」以 oplist 換批判定**：引擎沒有連線狀態訊號，接線在 `NakiRuntime.swift`（不在可改範圍）。
  重連後 resync 會帶來新一批 oplist；萬一沒有，退避上限 30 秒也會再探。
- **MCP 的 moqie 由呼叫端決定**：工具不自行推斷摸牌，不帶時送 `080b`，與修改前相同。
- **測試預設不退避**（`failureBackoff = 0`）：既有多輪測試會在同一批 oplist 上連續失敗再成功，只有 `.live` 開 2 秒。
- **「停滯指示沒出現」無法從 log 證實**：`/bot/status` 不含停滯欄位，16:43 的截圖是 16:41:47 重啟後的新程序。
  依程式碼，舊版在第 4 輪後應會回報；這次改成斷線立刻回報。
