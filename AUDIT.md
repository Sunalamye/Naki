# Naki 當前驗證報告

**驗證日期**：2026-08-01  
**程式基準**：`main`，盤點起點 `5eb1aef`  
**完整技術基準**：[docs/majsoul-unity-protocol.md](docs/majsoul-unity-protocol.md)

本檔只保留目前仍成立的驗證結果與差距，不保存歷次遷移、除錯或已被推翻的結論。

## 結論

Naki 的 Unity WebSocket → Liqi → MortalSwift → Liqi sender 主鏈已存在，四麻 observation／mask fixtures 與 resolver 純邏輯也有測試。但是「能自摸時必定自摸」尚未完成端到端驗收，而且現行 source 仍有兩個可直接造成漏和的整合漏洞。因此不能宣稱問題已完全修復，也不能把目前 bundled 權重稱為最新最強模型。

## 已驗證

| 項目 | 證據 | 結果 |
|------|------|------|
| 客戶端 | live Naki `/js` 唯讀 probe | Unity WebGL 4.0.45；Laya／DesktopMgr／uiscript 不存在 |
| Debug API | live `/status`、`/bot/status`、`/game/*` | loopback server 與 Swift protocol state 可用 |
| MCP registry | live `tools/list` | 42 tools |
| Liqi schema | live manifest fresh download + byte compare | repo `liqi.json` 與 CDN 完全相同 |
| config | live manifest fresh download + repo parser | 41 tables／263 sheets／119,289 rows |
| Mortal parity | fresh Debug／Release tests | 各 47 tests 通過；固定 fixtures obs／mask 零落差 |
| Naki unit tests | fresh NakiTests | 75 tests 通過；resolver 專項 13 tests 通過 |
| runtime ron | request／response／ActionHule trace | type 9 走 `inputOperation` 成功 |
| runtime pon | request／response／ActionChiPengGang trace | type 3 走 `inputChiPengGang` 成功 |
| WebGL hook | live `__nakiHighlight.state()` | hook 與染色分支有執行 |

## 已確認差距

### P0：自摸 resolver 仍可能不被呼叫

`AutoPlayDecisionResolver` 本身會讓 server oplist 的 tsumo／ron 凌駕 AI。但 `WebViewModel` 仍以 Mortal recommendation 是否非空作為進入自動動作的條件；空推薦時，timer 只補副露 pass。

結果：server 即使給 type 8，只要 Mortal 回空推薦，就可能完全不進 resolver。

### P0：hora send 失敗仍可能被標成完成

外層在呼叫 sender 後，只看 resolved action 是 `.hora` 就 `markHandled`；沒有拿到實際 `LiqiSendResult`。沒有 game-gateway、JS send 失敗或 server 拒絕時，pending opportunity 仍可能被吃掉且不重試。

### P0：Legacy iOS 沒有 server-authoritative 保護

iOS 17–25 的 `LegacyWebViewModel` 直接使用 AI 第一推薦，沒有 resolver、oplist action 檢查、seat check、stale check 或 fail-closed。新舊路徑功能不一致。

### P1：模型版本宣稱過度

- 本機 resolve 到 MortalSwift 0.5.0，但 package requirement 是 `[0.5.0,0.6.0)`，lockfile 又未提交。
- 0.5.0 修的是 encoder／計算與 parity；bundled model blobs 沒換。
- 沒有大規模實戰 benchmark。

正確說法是「目前使用 MortalSwift 0.5.0 的 encoder/parity 修正版」；不能說「已換最新最強權重」。

### P1：三麻沒有專用模型

`is3P` 只改 Naki 狀態與標籤；推論仍建立同一個 Mortal v4 四麻 model。三麻不應宣稱支援。

### P1：仍有一個假的 UI 控制

「隱藏玩家名稱」toggle 仍在 UI：

- Swift 呼叫 `window.__nakiPlayerNames?.setHidden(...)`，但 JS 沒有 `setHidden`。
- JS 現有 hide／show／toggle 又依賴 live 已確認不存在的 `uiscript`。

所以目前必定無效。位置校準、推薦溫度與旋轉 Laya 高亮三組假控制已移除；隱藏名稱仍需移除或做出真正 Unity 實作。

### P1：遊戲內高亮只有活性證據

現行 `__nakiHighlight` 會攔 WebGL draw 並執行 tint，但尚未用 screenshot／視覺測試證明每次命中正確牌或按鈕。同名牌全染與 popup heuristic 是已知風險。

## 正確修正順序

1. 以 oplist arrival 驅動 resolver，先處理 hora，不依賴 recommendation。
2. 讓 action execution 回傳結果；hora 只有在 send 成功，最好收到同 msgId RESPONSE／權威 action 後才 handled。
3. 對失敗保留 pending、bounded retry、sequence guard 與明確錯誤 log。
4. Legacy 共用同一 resolver／sender，或在完成前禁用 Legacy 自動模式。
5. 建立端到端 fixture：AI discard + server tsumo、空推薦 + tsumo、send failure、server reject、stale snapshot、recommend/off。
6. 固定 MortalSwift dependency，再做千局級牌力評估；不要用 package 版本代替模型強度證據。

## 未驗證

- 最新 source 在「AI 想 discard、server 有 tsumo」情境能否穩定 override 並收到 `ActionHule`。
- 空 recommendation + tsumo。
- send failure／server reject／中斷 cleanup。
- Legacy iOS 17–25 實機完整對局。
- chi variants、赤五 combination、ankan／minkan／kakan。
- WebGL 高亮與 action popup 的視覺正確性。
- AI 相對其他模型的實戰強度。

## 完成判準

只有在下列條件同時成立後，才可對外寫「漏自摸已修復」：

- source 層兩個 P0 integration gap 已消失。
- resolver／integration tests 覆蓋上述正常與 failure paths。
- 測試帳號 live 對局重現原始 `[discard, riichi, tsumo] + AI discard` 情境。
- log 顯示 resolver 選 hora、送到 game-gateway、同 msgId 成功 RESPONSE，並收到 `ActionHule`。
- 測試後沒有 stale pending、重複 request、殘留 process 或非預期帳號操作。
