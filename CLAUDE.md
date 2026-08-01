# CLAUDE.md

Naki（鳴き）是原生 macOS／iOS 雀魂 AI 助手。Swift 解析 Liqi、MortalSwift／Core ML 在本機推論，SwiftUI 顯示推薦；自動模式會在使用者自己的測試帳號送出遊戲動作。

## 不可違反的邊界

- 只操作使用者自己的測試帳號；不可使用主帳號。
- 不得提交 session token、credential、account id 或完整敏感 log。
- 修改 WebSocket bridge、自動打牌或任何會送 Liqi request 的行為前先確認。
- 動作、匹配、建房、強制重連與帳號外觀變更都不是唯讀查詢。
- destructive operation 要先做 preflight、備份／rollback、非零失敗與 cleanup。

## 查詢 Naki 的規則

所有「目前 Naki 是什麼狀態」的回答，先以正在執行的 Naki loopback API 查證，再用 source／test 解釋；不能拿舊文件自證。

唯讀順序：

```bash
curl http://127.0.0.1:8765/status
curl http://127.0.0.1:8765/bot/status
curl http://127.0.0.1:8765/game/state
curl http://127.0.0.1:8765/game/hand
curl http://127.0.0.1:8765/game/ops
```

需要頁面能力 probe 才用 `/js`，且 code 是 function body，必須寫 `return`：

```bash
curl -X POST http://127.0.0.1:8765/js \
  -d 'return JSON.stringify({canvas:!!document.getElementById("unity-canvas"),laya:typeof window.Laya})'
```

`/game/*`／`/bot/*` 回傳的是 Naki 從 WebSocket 累積的 Swift state，不是 server 即時完整 snapshot。沒有 live App 或沒有對局時要明確標「未做 runtime 驗證」。

<IMPORTANT>
所有 Naki MCP 操作使用 `.claude/skills/naki-mcp-proxy/SKILL.md`；live registry 目前是 42 tools。先 `tools/list`，不要依記憶呼叫舊 Laya 工具。
</IMPORTANT>

## 專案基準

| Property | Current value |
|----------|---------------|
| App version | 2.3.0 |
| macOS target | 26.0 |
| iOS target | 17.0 |
| Swift | 5.0 project setting |
| Web client | Unity WebGL `chs_t-WebGL-release-4.0.45(45)`（2026-08-01 live） |
| AI package | local resolution MortalSwift 0.5.0／`802dc3d…` |
| Debug／MCP | loopback port 8765，same process／same port |

Xcode dependency requirement 是 MortalSwift `[0.5.0,0.6.0)`，不是 exact；`Package.resolved` 被 ignore，clone 不保證同 revision。

## Build／test

```bash
open Naki.xcodeproj
xcodebuild build -project Naki.xcodeproj -scheme Naki
xcodebuild test -project Naki.xcodeproj -scheme Naki -only-testing:NakiTests
```

開始前先看 `git status`、Xcode／package resolution 與現有 Naki process。NakiTests 是 app-hosted，會啟動 test host 並使用相同暫存 log 名稱；若正式 Naki 正在跑，可能觸發 `akagi_websocket.log` rotation。未經確認不要在 live 對局期間跑 tests。

## 現行架構

```text
Majsoul Unity WebGL
  → naki-websocket.js
  → websocketBridge
  → LiqiParser
  → MajsoulBridge
  → MJAIEventStream
  → NativeBotController / MortalSwift / Core ML
  → recommendations

OptionalOperationList
  → LiqiOperationStore
  → AutoPlayDecisionResolver
  → LiqiActionSender
  → __nakiWebSocket.sendRaw
```

主要檔案：

| 責任 | 檔案 |
|------|------|
| 平台 factory | `command/ViewModels/WebViewModelProtocol.swift` |
| WebPage path | `command/ViewModels/WebViewModel.swift` |
| Legacy path | `command/ViewModels/LegacyWebViewModel.swift` |
| coordinator | `command/Views/WebViewController.swift` |
| WS injection | `command/Services/Bridge/WebSocketInterceptor.swift` |
| parser／bridge | `command/Services/Bridge/LiqiParser.swift`、`MajsoulBridge.swift` |
| oplist／sender | `command/Services/Bridge/LiqiOperationStore.swift`、`LiqiActionSender.swift` |
| decision | `command/Services/Bot/AutoPlayDecisionResolver.swift` |
| AI | `command/Services/Bot/NativeBotController.swift` |
| WebGL highlighter | `command/Resources/JavaScript/naki-core.js` |
| sendRaw | `command/Resources/JavaScript/naki-websocket.js` |

## Unity 與 Liqi 必知事實

- `Laya`、`GameMgr`、`uiscript`、`view.DesktopMgr`、`cfg`、`app.NetAgent` 不存在。
- 狀態與動作一律走 Liqi；不可用 DOM tile、Laya sprite 或座標點擊。
- JS 仍可做 WebSocket、WebGL、resource 與頁面 probe；不是整層 JS 都失效。
- request envelope：`[type][msgId LE][protobuf{field1=method,field2=payload}]`。
- normal ActionPrototype 需 XOR；sync restore payload 不再 XOR。
- FastTest 對局 request 走 `/game-gateway`，lobby request 走 `/gateway`。
- `sendRaw` 成功只代表 WebSocket 接受 bytes；真正成功要看同 msgId RESPONSE／權威 action。
- field number 只查 `docs/protocol/liqi.json`。2026-08-01 repo snapshot 與 live CDN byte-identical。
- MJAI 字牌 `E/S/W/N/P/F/C`；雀魂字牌 `1z`–`7z`。

## 平台差距

`WebViewModelFactory`：OS 26+ 用 WebPage `WebViewModel`；iOS 17–25 用 `LegacyWebViewModel`。macOS deployment target 是 26，所以 macOS 不走 Legacy。

只有新 path 使用 `AutoPlayDecisionResolver`。Legacy 仍直接送 AI 第一推薦，沒有 oplist action、seat、stale 或 fail-closed 檢查。禁止寫「兩條路功能一致」。

## 自摸問題的 current truth

resolver 純邏輯會讓 server tsumo／ron 凌駕 AI，且 13 個專項 tests 通過；但 integration 還有兩個 P0：

1. `WebViewModel` 仍要求 recommendations 非空才進主動作。空推薦 + type 8 可能完全不呼叫 resolver。
2. hora sender 沒把 `LiqiSendResult` 回給外層；呼叫後可能不論失敗都 `markHandled`。

正確修法：由 oplist arrival 驅動、先處理 hora；sender 回傳結果，收到成功 send／最好同 msgId RESPONSE 或 `ActionHule` 後才 handled；失敗保留 pending、bounded retry；Legacy 收斂到同一 resolver。

在完成 live fixture「server `[1,7,8]` + AI discard → resolver hora → RESPONSE → ActionHule」前，不得宣稱漏自摸已修復。

## MortalSwift／模型

- local resolution 是 0.5.0，但 bundled Core ML 仍是固定 Mortal v4 四麻模型。
- observation `1012 × 34`，action mask 46。
- libriichi parity 是兩套固定 fixtures 的逐格測試；Debug／Release 各 47 tests 通過，不是全狀態證明。
- 0.5.0 沒換 model blobs；沒有千局級 strength benchmark。不得稱「最新最強模型」。
- `is3P` 不會換模型；三麻仍送進四麻 model，不應宣稱支援。

## WebGL 高亮

現行 `__nakiHighlight` 以 `_MainTex_ST` UV 解 tile identity，在 `drawElements(count===6)` 前暫改 `_Tint`／`_Color`，draw 後還原。這不是 Laya material，也不是 `count===606`／ObjectToWorld 位置法。

live tinted counter 證明 hook 有執行，不證明每次染對。已知限制：同名牌全染、只攔特定 WebGL2 draw、popup 是 frequency heuristic、沒有 screenshot regression。

MCP 的 6 個 `highlight_*` 是未接新 hook 的相容失敗樁；不可用它們否定 App 內建自動 highlighter。

## 假功能不得留在 UI／文件

位置校準、推薦溫度、旋轉 Laya 高亮已移除。「隱藏玩家名稱」toggle 仍必定無效：Swift 呼叫不存在的 `setHidden`，現有 JS 又依賴不存在的 `uiscript`。後續需移除或真正實作，文件不可宣稱可用。

## 文件

- `docs/majsoul-unity-protocol.md`：唯一 Unity／Liqi／AI／高亮 current truth。
- `docs/architecture-deep-dive.md`：Naki current code architecture。
- `docs/majsoul-config-tables.md`：由 live manifest fresh parse 的 config 附錄。
- `docs/protocol/liqi.json`：協定欄位 schema。
- `AUDIT.md`：當前驗證差距與完成判準，不是歷史日誌。

## 驗收回報

回報必須分開：已修改、已驗證、未驗證、已知風險。單測通過不能替代 WebView／server／視覺與 failure-path 驗收；沒有可重查 evidence 的推論不得寫成事實。
