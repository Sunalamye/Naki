# Naki Debug HTTP API

**最後核對**：2026-08-01（source route switch + live request）  
**Base URL**：`http://127.0.0.1:8765`  
**綁定**：loopback only

HTTP Debug API 與 MCP 共用同一個 Naki process／port。Unity、Liqi 與資料語意見 [majsoul-unity-protocol.md](majsoul-unity-protocol.md)。

## 先做唯讀檢查

```bash
curl http://127.0.0.1:8765/status
curl http://127.0.0.1:8765/bot/status
curl http://127.0.0.1:8765/game/state
curl http://127.0.0.1:8765/game/hand
curl http://127.0.0.1:8765/game/ops
```

`game_*`／`bot_*` 的資料來自 Naki 已解析的 Swift 協定層，不是每次向雀魂 server 重抓完整狀態。

## 現行 routes

| Method | Path | 作用 | 是否可能改變狀態 |
|--------|------|------|------------------|
| GET | `/` | 簡要 HTML 入口 | 否 |
| GET | `/help` | JSON help | 否 |
| GET | `/status` | server、port、時間與 log path | 否 |
| POST | `/js` | 在 game page 執行 JavaScript | **依 code 而定** |
| GET | `/game/state` | Swift game snapshot | 否 |
| GET | `/game/hand` | 手牌與推薦 | 否 |
| GET | `/game/ops` | pending／latest oplist | 否 |
| POST | `/game/discard` | 送出 discard request | 是 |
| POST | `/game/action` | 送出一般遊戲動作 | 是 |
| GET | `/logs` | 記憶體內近期 log | 否 |
| DELETE | `/logs` | 清除記憶體 log | 是 |
| GET | `/bot/status` | Bot／mode／推薦 | 否 |
| POST | `/bot/trigger` | 手動觸發自動打牌 | 是 |
| GET | `/bot/ops` | oplist snapshot | 否 |
| GET | `/bot/deep` | snapshot、response 與診斷 | 否 |
| POST | `/bot/chi` | 送 chi，預設 combination index 0 | 是 |
| POST | `/bot/pon` | 送 pon，預設 combination index 0 | 是 |
| POST | `/mcp` | MCP JSON-RPC | 依 tool 而定 |

`/detect`、`/explore`、`/click`、`/calibrate`、`/ui/names*` 都不是現行 routes；呼叫會 404。

## `/js`

body 可直接是 JavaScript function body，或 JSON `{"code":"..."}`。要取得值必須顯式 `return`：

```bash
curl -X POST http://127.0.0.1:8765/js \
  -d 'return window.location.href'

curl -X POST http://127.0.0.1:8765/js \
  -d 'return JSON.stringify({
    canvas: !!document.getElementById("unity-canvas"),
    laya: typeof window.Laya,
    connections: window.__nakiWebSocket?.getConnections?.(),
    highlight: window.__nakiHighlight?.state?.()
  })'
```

推薦的 `/js` 用途是 read-only page／Unity／WebSocket／WebGL probe。不要嘗試 `DesktopMgr`、`GameMgr`、`uiscript` 或座標點擊；這些 Laya 物件不存在。

## 送出動作

下列 request 會真的影響帳號，只能用測試帳號，且先讀 `/game/ops`。

### Discard

以牌字串指定，不使用 UI index：

```bash
curl -X POST http://127.0.0.1:8765/game/discard \
  -H 'Content-Type: application/json' \
  -d '{"tile":"5m","moqie":false}'
```

`tile` 接受 MJAI（`5mr`、`E`）或雀魂（`0m`、`1z`）記法。

### 一般 action

```bash
curl -X POST http://127.0.0.1:8765/game/action \
  -H 'Content-Type: application/json' \
  -d '{"action":"pass"}'

curl -X POST http://127.0.0.1:8765/game/action \
  -H 'Content-Type: application/json' \
  -d '{"action":"riichi","tile":"5m","moqie":false}'
```

支援名稱：`discard`、`riichi`、`chi`、`pon`、`kan`、`tsumo`、`ron`、`hora`、`kyushu`、`babei`、`pass`。可用參數包括 `tile`、`moqie`、`index`、`kanType`、`timeuse`。

HTTP route 會送出 request，但「寫進 WebSocket」不等於 server 接受。需要 RESPONSE／state verification 時優先使用 MCP `game_action_verify`。

## Log

`GET /logs` 只回 Naki process 內存中的近期條目。`GET /status` 另回檔案 log path；同目錄 `.1`–`.5` 是 rotation。

App-hosted tests 也會初始化 LogManager。正式 Naki 正在跑時執行 tests 可能輪替同一暫存 log 名稱，所以 live 對局期間不要把 test host 與正式 App 的 log 混在一起。

## 回傳判讀

| 訊號 | 能證明什麼 |
|------|------------|
| `sent.success == true` | bytes 已交給 OPEN WebSocket |
| 同 msgId RESPONSE 無 error | server 已回應該 request |
| `ActionHule`／新 action／oplist sequence 前進 | 權威遊戲狀態已改變 |

驗收動作時至少記錄後兩層；只看到 HTTP 200 或 `sent.success` 不足以宣稱成功。
