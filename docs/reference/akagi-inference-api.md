# Akagi 推論伺服器 API 參考

**資料日期**：2026-08-01 首讀；2026-08-04 以當日 clone 重驗全文（無過時內容）並新增文末「請求塑形與雙段語意」一節
**來源**：[`src/bot/api.rs`](https://github.com/shinkuan/Akagi/blob/v3/src/bot/api.rs)（657 行）、[`src/bot/native.rs`](https://github.com/shinkuan/Akagi/blob/v3/src/bot/native.rs)（1905 行）與 [`src/config/bot.rs`](https://github.com/shinkuan/Akagi/blob/v3/src/config/bot.rs)，v3 分支逐行讀出

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

實作計畫見 [`pluggable-bots-plan.md`](../pluggable-bots-plan.md)；Naki 端的具體接入設計見 [`cloud-inference-plan.md`](../cloud-inference-plan.md)。

---

## 2026-08-04 補充：請求塑形與雙段語意（`native.rs` 再讀）

以下是客戶端**必須**做對、但只讀 `api.rs` 看不到的部分。全部出自 `native.rs` 的 `accumulate` / `build_api_events` / `to_api_event` / `resolve_reaction` / `reach_discard`。

### 事件流是「每局視窗」，不是全對局

- `start_game` 清空重來；`start_kyoku` 清掉上一局尾巴，**但保留開頭的 `start_game` 當 `events[0]`**（API 硬性要求）。
- server 有 **512 事件上限**；一局的量遠低於此，per-kyoku 視窗就是為了保持在上限之下。
- API 關閉時也持續累積，所以局中途開啟能立刻上傳「本局至今」。

### 上傳前的 censor 與塑形（`to_api_event`）

| 事件 | 處理 |
|------|------|
| `start_kyoku.tehais` | 只露自己的手牌，其他座位一律 13 張 `"?"` |
| 別家 `tsumo.pai` | 換成 `"?"`（自己的照送）|
| `reach` | 剝掉任何非 spec 的預測 `pai` 欄位，送裸 `{"type":"reach","actor":N}` |
| 三麻 `start_game.names` | 補空字串到長度 4 |
| 三麻 `start_kyoku.scores` / `tehais` | 補 0 分／13 張 `"?"` 的幽靈第四家到長度 4 |
| 其餘公開事件 | 原樣（已是 API 形狀）|

### 立直是兩段式

server 對立直回**不含捨牌**的裸 `{"type":"reach"}`（捨牌是第二個決策）。客戶端要把 reach 附到事件流尾**再打一次 `/v3/react`** 拿 `dahai`；第二次失敗就用本地模型的立直捨牌，連本地都沒有就整個放棄 API 反應、退回本地完整決策——**沒有捨牌的 reach 會讓自動打牌卡死**。這正是 react 逾時壓 2 秒的原因（兩次呼叫要擠進同一回合）。

### `reaction: null` 的語意

HTTP 成功但 `reaction` 為 `null` ＝ server 認為該座位無合法動作。若本地閘門明明判定有動作，代表**事件流不同步**——此時打本地決策並記 warn，絕不能默默 pass 掉真回合。注意：null reaction 算 server 可達，**不觸發**斷路器；只有 transport／HTTP 錯誤才算失敗。

### 防禦性細節

- 收到 reaction 後強制把 `actor` 蓋成自己的座位（server 應該已設對，但防禦性覆寫）。
- **client 建構失敗 tombstone**：同一組建不出 client 的設定（如壞 proxy URL）只警告一次，記住失敗四元組 `(base_url, key, proxy, model)`，使用者改任何一項才重試——否則每個決策都重試又重跳 toast。
- 卡片標題標示實際服務者（`Akagi · <model>` vs `Akagi · Local`），fallback 在畫面上可見。

### 設定形狀（`config/bot.rs` 的 `NativeApiConfig`）

```
enabled: bool            # 總開關；is_active() = enabled && base_url 非空 && key 非空
base_url: string         # 預設 https://mjapi.shinkuan.me
key: string              # 32 字元英數 Bearer key
model_4p / model_3p      # 分開兩欄；空字串 ⇒ 不送 model 欄位、server 用該遊戲預設
proxy_enabled / proxy    # 開關與值分離，關掉不清值
```

四麻／三麻模型分兩欄、依 `start_game` 的 `num_players` 選用——**雲端 server 有真三麻模型**（`/v3/models` 的 `game: "3p"`），這是本地 bundled 模型沒有的能力。

---

## 附：key 的取得管道（2026-08-05 查證）

Naki 依 decisions D6 刻意不做 redeem／購買流程，所以 key 從外部取得。查證結果
（GitHub repo README＋issues＋discussions 全搜、官網 akagi.shinkuan.me 文件）：

- **官方付款通道只有一條**：Akagi App 內購（PayPal，portable build 免安裝可跑）。
  沒有網頁商店——`mjapi.shinkuan.me` 根路徑對瀏覽器直接回 Cloudflare 阻擋頁。
- **預付序號**的公開販售管道不存在於任何官方文件；唯一出口是
  [Discord](https://discord.gg/Z2wjXUK8bN)。
- 拿到序號後**不需要 Akagi App**：`POST /v3/redeem` 無認證，一條 curl 兌換，
  回應的 `key` 只在新發時出現一次。
- PayPal 受限地區（如台灣帳號）：先試結帳頁的訪客信用卡選項，不行走 Discord。
- portable build 註明的文件 repo `shinkuan/AkagiV3` **不存在**，實際 repo 是
  `shinkuan/Akagi`；官方文件站是 `akagi.shinkuan.me/zh-tw/docs`。
