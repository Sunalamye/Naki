# Majsoul Bridge 訊息處理流程比對

## 🔴 關鍵問題總結

### 問題 1：Bot 模型重建
**Python**: 每次收到 `start_game` 都會創建**新的模型**
```python
if e["type"] == "start_game":
    self.player_id = e["id"]
    self.model = model.load_model(self.player_id)  # 每次都創建新模型！
```

**Swift (已實作)**: 每次 `start_game` 都刪除舊 Bot 並創建新的，`end_game` 時清理
- 已實作於 `NakiWebCoordinator.handleMJAIEvent`（`command/Views/WebViewController.swift:165-194`）

### 問題 2：XOR 編碼差異
- **Notify (ActionPrototype)**: `data` 欄位需要 **XOR 解碼**
- **SyncGame (gameRestore.actions)**: `data` 欄位 **不需要 XOR 解碼**

### 問題 3：斷線重連時不應發送額外的 start_game
**Python (Akagi)**: syncGame 只處理 `gameRestore.actions`，**不發送額外的 start_game**
```python
# bridge.py:178-193
if ((liqi_message['method'] == '.lq.FastTest.syncGame' or liqi_message['method'] == '.lq.FastTest.enterGame')
    and liqi_message['type'] == MsgType.Res):
    self.syncing = True
    syncGame_msgs = LiqiProto().parse_syncGame(liqi_message)  # 只提取 actions
    parsed_list = []
    for msg in syncGame_msgs:
        parsed = self.parse_liqi(msg)  # 將每個 action 當作 ActionPrototype 處理
        if parsed:
            parsed_list.extend(parsed)
    self.syncing = False
    return parsed_list  # 返回所有解析後的 MJAI 事件（不含 start_game）
```

**Swift (原問題)**: `parseSyncGameRestore` 會額外發送 `start_game`，導致：
- 如果 authGame 已處理過，會重複發送 start_game
- Bot 被不必要地重建

---

## Python 完整流程

### 1. 主循環 (akagi.py main_loop)
```python
mjai_msgs = mitm_client.dump_messages()  # 獲取所有 MJAI 事件列表
if mjai_msgs:
    mjai_response = mjai_controller.react(mjai_msgs)  # 發送所有事件給控制器
    mjai_bot.react(input_list=mjai_msgs)  # 也發送給 UI Bot
```

### 2. Controller.react() - 事件批處理
```python
def react(self, events: list[dict]) -> dict:
    # 自動切換模型邏輯
    for event in events:
        if event["type"] == "start_game":
            self.starting_game = True
            self.temp_mjai_msg = []
            self.temp_mjai_msg.append(event)
            continue
        if event["type"] == "start_kyoku" and self.starting_game:
            self.starting_game = False
            # 根據分數判斷三麻/四麻
            if scores == [35000, 35000, 35000, 0]:
                self.choose_bot_name("mortal3p")
            else:
                self.choose_bot_name("mortal")
            continue

    events = self.temp_mjai_msg + events
    self.temp_mjai_msg = []
    ans = self.bot.react(json.dumps(events))  # 發送 JSON 數組！
    return json.loads(ans)
```

### 3. Bot.react() - 模型生命週期管理
```python
def react(self, events: str) -> str:
    events = json.loads(events)  # 解析 JSON 數組

    for e in events:
        if e["type"] == "start_game":
            self.player_id = e["id"]
            self.model = model.load_model(self.player_id)  # ⭐ 每次都創建新模型！
            continue

        if self.model is None:
            continue

        if e["type"] == "end_game":
            self.player_id = None
            self.model = None  # ⭐ 結束時清空模型
            continue

        return_action = self.model.react(json.dumps(e))  # 發送單個事件給模型

    return return_action or '{"type":"none"}'
```

---

## Swift 流程 (已實作)

Bot 生命週期（每次 `start_game` 重建 Bot / `end_game` 清理）**已實作**於
`NakiWebCoordinator.handleMJAIEvent`（`command/Views/WebViewController.swift:159-199`）。
與 Python Akagi 行為一致。

### 已實作行為：

1. **Bot 每局重建** — `start_game` 時 `deleteNativeBot()` 再 `createNativeBot(playerId:)`
2. **事件透過 `MJAIEventStream` 消費者依序處理**（`startEventConsumer`）
3. **`end_game` 清理** — 清空 Bot 與推薦/手牌/摸牌狀態

---

## 實作位置

### 1. `NakiWebCoordinator.handleMJAIEvent` — start_game 重建 Bot

`command/Views/WebViewController.swift:165-184`

```swift
case "start_game":
    guard let playerId = event["id"] as? Int else {
        bridgeLog("[協調器] 錯誤: start_game 沒有 id 欄位!")
        return
    }
    eventStream.startNewGame()
    eventStream.emit(event)
    viewModel?.deleteNativeBot()                       // ⭐ 每次都刪除舊 Bot
    do {
        try await viewModel?.createNativeBot(playerId: playerId)  // ⭐ 再創建新的
        startEventConsumer()
    } catch {
        bridgeLog("[協調器] 錯誤: 建立 Bot 失敗: \(error)")
    }
```

### 2. `NakiWebCoordinator.handleMJAIEvent` — end_game 清理

`command/Views/WebViewController.swift:186-194`

```swift
case "end_game":
    eventStream.emit(event)
    eventStream.endGame()
    viewModel?.deleteNativeBot()
    viewModel?.recommendations = []
    viewModel?.tehaiTiles = []
    viewModel?.tsumoTile = nil
    viewModel?.statusMessage = "遊戲結束"
```

### 3. MortalBot 重新初始化

`NativeBotController.createBot(playerId:is3P:)`（`throws`）每次都建立新的
`MortalBot(playerId:version:4, useBundledModel:true)`（MortalSwift v0.3.0，actor），
確保收到 `start_game` 時狀態完全重置。

---

## 訊息流程對照表

| 場景 | 訊息類型 | Method | XOR 解碼 |
|------|----------|--------|----------|
| 正常遊戲 | Notify | .lq.ActionPrototype | **是** |
| 斷線重連 | Response | .lq.FastTest.syncGame → gameRestore.actions | **否** |
| 進入遊戲 | Response | .lq.FastTest.enterGame → gameRestore.actions | **否** |

---

## 斷線重連完整流程 (Akagi 實現)

### 觸發條件
- `.lq.FastTest.syncGame` Response - 斷線後重新連接
- `.lq.FastTest.enterGame` Response - 重新進入遊戲房間

### Python 處理流程 (liqi.py)

#### 1. parse_syncGame - 提取歷史 actions
```python
def parse_syncGame(self, syncGame):
    assert syncGame['method'] == '.lq.FastTest.syncGame' or syncGame['method'] == '.lq.FastTest.enterGame'
    msgs = []
    if 'gameRestore' in syncGame['data']:
        for action in syncGame['data']['gameRestore']['actions']:
            msgs.append(self.parse_syncGameActions(action))
    return msgs
```

#### 2. parse_syncGameActions - 包裝為 ActionPrototype 格式
```python
def parse_syncGameActions(self, dict_obj):
    # ⚠️ 關鍵：直接 base64 解碼，不調用 decode()（XOR）
    dict_obj['data'] = MessageToDict(
        getattr(pb, dict_obj['name']).FromString(base64.b64decode(dict_obj['data'])),
        always_print_fields_with_no_presence=True
    )
    msg_id = -1
    result = {'id': msg_id, 'type': MsgType.Notify,
              'method': '.lq.ActionPrototype', 'data': dict_obj}
    return result
```

#### 3. 對比 Notify 的 XOR 解碼
```python
# Notify 訊息需要 XOR 解碼
if 'data' in dict_obj:
    B = base64.b64decode(dict_obj['data'])
    action_proto_obj = getattr(pb, dict_obj['name']).FromString(decode(B))  # decode() = XOR
    action_dict_obj = MessageToDict(action_proto_obj, always_print_fields_with_no_presence=True)
    dict_obj['data'] = action_dict_obj
```

### XOR 解碼函數 (liqi.py:21-26)
```python
keys = [0x84, 0x5e, 0x4e, 0x42, 0x39, 0xa2, 0x1f, 0x60, 0x1c]

def decode(data: bytes):
    data = bytearray(data)
    for i in range(len(data)):
        u = (23 ^ len(data)) + 5 * i + keys[i % len(keys)] & 255
        data[i] ^= u
    return bytes(data)
```

### 斷線重連流程圖

```
斷線重連場景:
┌─────────────────────────────────────────────────────────────────┐
│ 1. 用戶斷線                                                      │
│ 2. 用戶重新連接                                                  │
│ 3. 發送 syncGame 請求                                            │
│ 4. 收到 syncGame 響應:                                           │
│    ┌─────────────────────────────────────────────────────────┐  │
│    │ syncGame Response                                        │  │
│    │ ├── error                                                │  │
│    │ ├── is_end                                               │  │
│    │ ├── step                                                 │  │
│    │ └── gameRestore                                          │  │
│    │     ├── snapshot (GameSnapshot)                          │  │
│    │     │   ├── chang, ju, ben, liqibang                     │  │
│    │     │   ├── tiles (當前手牌)                              │  │
│    │     │   ├── doras                                        │  │
│    │     │   └── scores                                       │  │
│    │     └── actions[] (歷史動作列表，不需要 XOR 解碼)          │  │
│    │         ├── ActionNewRound                               │  │
│    │         ├── ActionDealTile                               │  │
│    │         ├── ActionDiscardTile                            │  │
│    │         └── ...                                          │  │
│    └─────────────────────────────────────────────────────────┘  │
│ 5. 處理方式:                                                     │
│    - ❌ 不發送額外的 start_game（authGame 已處理過）             │
│    - ✅ 設置 syncing = true 標誌                                 │
│    - ✅ 將 actions[] 逐一解析為 MJAI 事件                        │
│    - ✅ 設置 syncing = false                                     │
│    - ✅ 返回所有 MJAI 事件給 Bot 處理                            │
└─────────────────────────────────────────────────────────────────┘

App 完全重啟後重連:
┌─────────────────────────────────────────────────────────────────┐
│ 1. 用戶重新登入                                                  │
│ 2. authGame Request → 重置 Bridge 狀態，獲取 accountId           │
│ 3. authGame Response → 獲取 seatList，發送 start_game            │
│ 4. syncGame Response → 只處理 gameRestore.actions（不發 start_game）│
│ 5. Bot 收到 start_game 後已重建，接收歷史 actions 恢復狀態        │
└─────────────────────────────────────────────────────────────────┘
```

---

## 遊戲生命週期

```
新遊戲開始:
┌──────────────────────────────────────────────┐
│ authGame Request → 重置 Bridge 狀態           │
│ authGame Response → start_game (創建新 Bot)   │
│ ActionNewRound → start_kyoku                  │
│ ActionDealTile → tsumo (開始接收推薦)          │
│ ... 遊戲進行中 ...                             │
│ ActionHule/ActionNoTile → end_kyoku           │
│ NotifyGameEndResult → end_game (清理 Bot)     │
└──────────────────────────────────────────────┘

第二局 (連莊或換莊):
┌──────────────────────────────────────────────┐
│ ActionNewRound → start_kyoku (Bot 狀態保持)   │
│ ActionDealTile → tsumo                        │
│ ... 遊戲進行中 ...                             │
│ ActionHule/ActionNoTile → end_kyoku           │
└──────────────────────────────────────────────┘

新一場遊戲:
┌──────────────────────────────────────────────┐
│ authGame Request → 重置 Bridge 狀態           │
│ authGame Response → start_game (⭐ 必須重建 Bot)│
│ ...                                           │
└──────────────────────────────────────────────┘
```

---

## 關鍵修復點

1. ✅ **每次 `start_game` 都重建 Bot** - 這是 Python 版本的行為
2. ✅ **XOR 解碼邏輯正確** - syncGame 中的 actions 不需要 XOR
3. ✅ **狀態正確重置** - end_kyoku 時清空推薦，start_kyoku 時重置局狀態
4. ✅ **seatList 解析修復** - 使用 field 3 的 packed seatList，而非 PlayerGameView 的 accountId
5. ✅ **斷線重連不發送額外 start_game** - syncGame 只處理 gameRestore.actions (2025/12/01 已修復)

### 問題 3：seatList 解析錯誤 (2025/11/30 已修復)

**原錯誤**:
- `parseAuthGameResponse` 從 PlayerGameView (field 2) 提取 accountId 組成 seatList
- 但 field 2 是每個玩家的詳細資訊，包含多個欄位
- 導致 seatList 只有用戶自己的 accountId：`[24578744]`

**正確做法** (Python):
```python
seatList = liqi_message['data']['seatList']  # field 3
self.seat = seatList.index(self.accountId)
```

**修復後**:
- 使用 field 3 的 packed seatList：`[12, 11, 24578744, 13]`
- `seatList.firstIndex(of: 24578744)` = 2 ✅
- 用戶座位正確為 2，而非錯誤的 0

### 問題 4：斷線重連發送額外 start_game (2025/12/01 已修復)

**原錯誤**:
- `parseSyncGameRestore` 會額外發送 `start_game` 事件
- 但 `authGame` 響應已經發送過 `start_game`
- 導致 Bot 被不必要地重建兩次

**Akagi 的行為** (bridge.py:178-193):
```python
# syncGame 只處理 gameRestore.actions，不發送 start_game
if ((liqi_message['method'] == '.lq.FastTest.syncGame' or liqi_message['method'] == '.lq.FastTest.enterGame')
    and liqi_message['type'] == MsgType.Res):
    self.syncing = True
    syncGame_msgs = LiqiProto().parse_syncGame(liqi_message)
    # ... 處理 actions ...
    self.syncing = False
    return parsed_list  # 不含 start_game
```

**修復後** (MajsoulBridge.swift):
- 添加 `syncing` 和 `hasReceivedAuthGame` 標誌位
- `parseSyncGameRestore` 不再發送額外的 `start_game`
- 只處理 `gameRestore.actions` 來恢復遊戲狀態
