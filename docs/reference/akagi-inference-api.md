# Akagi 推論伺服器 API 參考

**資料日期**：2026-08-01
**來源**：[`src/bot/api.rs`](https://github.com/shinkuan/Akagi/blob/v3/src/bot/api.rs)（657 行）與 [`src/bot/native.rs`](https://github.com/shinkuan/Akagi/blob/v3/src/bot/native.rs)，v3 分支逐行讀出

這份是**外部參考**，不是 Naki 的實作規格。目的：要自架 inference server 或設計 Naki 的遠端推論時，有一份已經在生產環境跑的協定可以對照，而不是從零猜。

Akagi 是 Apache-2.0。這裡只記錄協定形狀與設計理由，沒有複製程式碼。

---

## 端點總覽

| 端點 | 方法 | 認證 | 逾時 | 用途 |
|------|------|------|------|------|
| `/v3/react` | POST | Bearer | **2 秒** | 決策（在對局關鍵路徑上）|
| `/v3/key` | GET | Bearer | 8 秒 | 金鑰方案、到期、即時限額 |
| `/v3/models` | GET | Bearer | 8 秒 | 這把金鑰可用的模型 |
| `/v3/redeem` | POST | **無** | 8 秒 | 兌換碼換金鑰 |
| `/healthz` | GET | **無** | 8 秒 | 存活 + 每模型佇列深度 |

Base URL 會做正規化：去掉前後空白與尾端斜線。

---

## `POST /v3/react`

### Request

```json
{
  "model": "mortal-4p",        // 可省略；省略時伺服器用該遊戲的預設
  "player_id": 1,              // 0–3
  "events": [ /* mjai 事件 */ ]
}
```

`events` 是**一批**，決策點是**最後一個元素**；前面的是自上次反應以來累積的事件。
`model` 為空字串時會被過濾掉不送（`skip_serializing_if`），不是送空字串。

### Response

```json
{
  "reaction": { "type": "dahai", "actor": 1, "pai": "1m", "tsumogiri": false },
  "candidates": [
    { "action": "dahai:W", "prob": 0.85 },
    { "action": "reach",   "prob": 0.11 }
  ],
  "model": "mortal-4p"
}
```

三個欄位**全部可省略**（`serde(default)`），空物件 `{}` 也能解析成功。

- `reaction`：標準 mjai 事件，`actor == player_id`。**該座位對最後那個事件沒有合法動作時為 `null`**。
- `candidates`：top-k，`action` 是**粗標籤**（`dahai:W` / `reach` / `pon`），確切的牌在 `reaction` 裡。`candidates[0]` 對應 `reaction`。
- `model`：實際服務這次請求的模型 id。

### 為什麼 react 的逾時是 2 秒（其他是 8 秒）

原始碼註解講得很清楚：

> Majsoul's turn timer is ~5s plus a shared time bank, and a reach costs **two** react calls (declare, then discard), so the whole two-step has to fit inside one turn.

立直要兩次呼叫（宣告 + 打牌），兩次都必須擠進同一個回合。2 秒 × 2 = 4 秒，還留一點給網路與本地處理。

> Keep this tight: a hung server falls back to the local model **promptly** instead of making the bot miss its turn.

**逾時設定不是隨便挑的數字，是從遊戲規則反推的。** Naki 若要做遠端推論，同樣要從雀魂的回合計時器往回算，不能照抄 2 秒——Naki 的送出還有自己的延遲模型要扣。

---

## `GET /v3/key`

```json
{
  "plan": "pro",
  "expires_at": "2026-12-31T00:00:00Z",
  "usage_today": 1234,
  "rpd": 20000,
  "rpm": 10.0,
  "topk": 5
}
```

⚠️ **`rpm` 是浮點數**。原始碼有專門的註解：

> The server reports this as a float (e.g. `10.0`), so it is typed `f64` — deserializing it into an integer would fail the parse.

這是那種只有踩過才會知道的細節。

---

## `GET /v3/models`

回應是**包了一層**的：

```json
{ "models": [ { "id": "mortal-4p", "game": "4p", "desc": "…" } ] }
```

不是裸陣列。`game` 用來區分四麻／三麻。

---

## `POST /v3/redeem`（無認證）

```json
{
  "code": "XXXX-XXXX",
  "email": "user@example.com",   // 可省略；把新金鑰綁到帳號
  "renew_key": "existing-key"    // 可省略；有值時是續期而非新發
}
```

回應：

```json
{
  "key": "32 字元金鑰",      // 只在「新發」時出現
  "key_last4": "abcd",
  "plan": "pro",
  "expires_at": "…",
  "extended": false          // true = 疊加到既有金鑰，沒有發新的
}
```

> The raw 32-char key — present **only** when a new key is minted (`extended == false`). Never re-shown on a renewal.

續期時不會再給完整金鑰，只給後四碼。

---

## `GET /healthz`（無認證）

```json
{
  "status": "ok",
  "models": ["mortal-4p", "mortal-3p"],
  "queue_depth": { "mortal-4p": 3 }
}
```

`queue_depth` 是**每模型**的佇列深度，可以用來顯示壅塞狀況。

---

## 錯誤處理

非 2xx 一律走同一個 `check`：

1. 取 `Retry-After` header
2. 讀 body，嘗試解出 `{"error": "..."}` 的字串
3. 解不出來就取 body 前 200 字元
4. 組成 `"{what} failed: HTTP {code} — {msg} (retry after {N}s)"`

**伺服器端只要回 `{"error": "..."}` 就能得到人看得懂的訊息。** 這個約定很輕，值得沿用。

---

## 斷路器（`native.rs`）

```
BREAKER_BASE * 2^(failures-1)，上限 BREAKER_MAX
5s → 10s → 20s → 40s → 80s → 120s（封頂）
```

| 方法 | 行為 |
|------|------|
| `allows()` | `open_until` 是 None 或已過期 → 允許 |
| `record_success()` | 失敗計數歸零、關閉斷路器 |
| `record_failure()` | 開啟斷路器，回傳這次的視窗長度（供 log）|
| `reset()` | 使用者改設定時呼叫——那是明確的「現在再試一次」|

還有一個 `healthy` 旗標，**只在狀態改變時才發通知**：

> Toasts fire only on a change of this flag, so a persistently-down server doesn't spam a toast per turn.

伺服器持續掛著時不會每一手都跳一次通知。

### 為什麼需要斷路器

> a dead server costs **one slow turn per window** instead of a request timeout on every decision

沒有它，伺服器掛掉時每個決策都要等滿逾時。以 2 秒 × 一局 100 手 = 200 秒純空等；Naki 若用 5 秒預算就是 500 秒。

---

## 三個值得直接抄的設計

### 1. 本地模型同時是「合法動作閘門」

不是只當 fallback。**不能動作時直接跳過遠端呼叫**——省一次 round-trip，而且避免把「這一手沒事可做」也算進限額。

### 2. 每個決策點重讀設定

> Re-reading per decision is what lets the user enable cloud inference, fix a mistyped key, or switch models **mid-game** — a change resets the Breaker so the new settings are tried on the very next move.

不是啟動時讀一次。改設定立刻生效，而且會 reset 斷路器。

### 3. `ApiClient` 要重用不要每次建

> Each `ApiClient` builds its own `reqwest::Client`, and with it a fresh connection pool — so **hold one and reuse it** rather than constructing one per request, or every call pays a new TCP + TLS handshake.

只在 URL 或金鑰改變時重建。

---

## 兩個安全實作值得注意

### Proxy 錯誤絕不回顯 proxy 字串

```rust
// Proxy URLs often carry `user:pass@host`; the error text lands in
// toasts and persisted logs, so it must not contain the secret.
```

而且有一個專門的測試斷言錯誤訊息**不含**密碼與主機名。原因是那些訊息會進到使用者回報 bug 時附上的 log。

支援的 scheme：`http://` `https://` `socks5://` `socks5h://`，**大小寫不敏感**（從供應商後台貼過來的 `HTTP://` 也能用）。`socks5h` 讓 DNS 在 proxy 端解析。

### 購買流程沒有 client secret

> Prices are **server-owned** — only the product id crosses the wire, and no client secret is embedded in the binary.

桌面 app 的 binary 一定會被逆向，所以價格與金鑰簽發都在伺服器端。

---

## 自架時哪些可以不做

要接自己的伺服器，這些整塊不需要：

| 不需要 | 理由 |
|--------|------|
| `/v3/redeem` | 沒有付費就沒有兌換 |
| `/v3/key` | 沒有限額要查 |
| PayPal handshake（`purchase.rs`）| 同上 |
| Bearer 認證 | loopback 或內網可省；跨網路仍建議留 |

**最小可用集合是 `/react` 一個端點**。`/healthz` 值得留著——它讓 UI 能在對局開始前就告訴使用者伺服器是否可用，而不是等到第一手才發現。

---

## 對 Naki 的差異

| | Akagi | Naki 若要做 |
|---|---|---|
| 送什麼 | mjai 事件批次 | 一樣（可與 `StreamBot` 共用協定）|
| react 逾時 | 2 秒（立直要兩次） | 要從雀魂回合計時器**扣掉自己的延遲模型**再算 |
| 斷路器 | 5s → 120s | 直接沿用 |
| 本地 fallback | 內建 candle 模型 | 內建 Mortal Core ML |
| 認證 | Bearer | 自架可省，跨網路要留 |
| 平台 | 單一 binary | macOS + iOS，**遠端是 iOS 唯一的外部 AI 路徑** |

實作計畫見 [`pluggable-bots-plan.md`](../pluggable-bots-plan.md)。
