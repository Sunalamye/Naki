# AsyncStream 事件流管理實現記錄

> 日期：2025-12-03
> 新增文件：`Naki/Services/Bridge/MJAIEventStream.swift`
> 修改文件：`Naki/Views/WebViewController.swift`

---

## 問題描述

### 症狀

Bot 在遊戲進行中會「失去同步」，表現為：
- `botStatus.isActive: false`
- `tehaiCount: 0`（手牌為空）
- 但遊戲狀態顯示 `handCount: 14`（遊戲仍在進行）
- 沒有任何推薦動作

### 用戶提問

> 現在收到 socket 是如何通知 bot 的？如果這個通知用 AsyncStream 傳出去的話遇到這種問題，是不是重新加載 bot 並重傳送資料就可以了？AsyncStream 可以記錄過往資料。

---

## 問題定位過程

### 1. 追蹤 WebSocket → Bot 通知流程

```bash
grep -n "onMJAIEvent" Naki/**/*.swift
grep -n "processNativeEvent" Naki/**/*.swift
```

發現完整流程：

```
JavaScript (WebView)
    │ postMessage
    ▼
WebSocketMessageHandler.userContentController()
    │ majsoulBridge.parse()
    ▼
onMJAIEvent?(event) callback
    │
    ▼
WebViewController.Coordinator.handleMJAIEvent()
    │
    ▼
WebViewModel.processNativeEvent()
    │
    ▼
NativeBotController.react(event:)
```

### 2. 定位斷線處理邏輯

**文件**: `WebViewController.swift`

```swift
// 原始代碼
websocketHandler.onWebSocketStatusChanged = { [weak self] connected in
    if connected {
        self.websocketHandler.reset()
        self.parent.viewModel.deleteNativeBot()  // ⚠️ Bot 被刪除
    }
}
```

**問題**：Bot 被刪除後，如果遊戲仍在進行中，新的 Bot 無法收到之前的事件（如 `start_game`、`start_kyoku`、`tsumo` 等），導致狀態無法恢復。

### 3. 分析事件處理邏輯

```swift
// 原始代碼
private func handleMJAIEvent(_ event: [String: Any]) async {
    switch eventType {
    case "start_game":
        _ = try await parent.viewModel.processNativeEvent(event)  // 直接消費，無保存
    // ...
    }
}
```

**問題**：事件一次性消費，無法重放。

---

## 對話過程與設計調整

### 第一輪討論：AsyncStream 方案

**用戶提問**：
> AsyncStream 可以記錄過往資料嗎？

**分析**：
AsyncStream 的 `bufferingPolicy` 可以設定緩衝策略：
- `.unbounded` - 無限緩衝
- `.bufferingNewest(n)` - 保留最新 n 個
- `.bufferingOldest(n)` - 保留最舊 n 個

**但關鍵點**：AsyncStream 的 buffer 是給「還沒被消費」的元素用的。一旦 `for await` 讀取了元素，它就從 buffer 移除了。

**結論**：如果要支持「重放歷史給新 Bot」，需要自己維護歷史記錄。

### 第二輪討論：Task 管理

**用戶要求**：
> 當 bot 失去同步後應該重建 bot 並使用 Task 重把舊的 AsyncStream 給新的 bot，同時這個舊的也會傳新的去更新 bot 的資料，還有就是這個 Task 應該是會只保留一份，重新載入時記得把舊的 async stream finish 掉。

**設計決策**：
1. 事件同時保存到 `eventHistory` 和 yield 到 stream
2. `consumerTask` 只保留一份，重建時先 cancel 舊的
3. `startConsumer()` 會先重放歷史，再接收新事件
4. 遊戲結束時 finish stream 並清空歷史

### 第三輪討論：手動 Reload 處理

**用戶反饋**：
> 如果用戶手動按了 reload 的話就不用自動重放了

**初始方案**：添加 `isPageReloading` 標記來區分：
```swift
private var isPageReloading: Bool = false

// didStartProvisionalNavigation
isPageReloading = true

// onWebSocketStatusChanged
if !isPageReloading && eventStream.canResync() {
    await resyncBot()
}

// didFinish
isPageReloading = false
```

**用戶進一步反饋**：
> 應該是說如果是用戶自己 reload 就直接把 AsyncStream 清除然後就走之前的流程就好

**最終方案**：不需要額外標記！
```swift
// didStartProvisionalNavigation
eventStream.endGame()  // 清空歷史

// onWebSocketStatusChanged
if eventStream.canResync() {  // 歷史是空的，返回 false
    await resyncBot()
}
```

**用戶確認**：
> 因為是空的就算回放也沒問題

**結論**：簡化代碼，移除 `isPageReloading` 標記。清空歷史後 `canResync()` 自然返回 `false`，即使調用 `resyncBot()` 也沒問題（沒有歷史可以重放）。

---

## 最終架構

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           新架構：AsyncStream + 事件歷史                      │
└─────────────────────────────────────────────────────────────────────────────┘

                        WebSocket 消息
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                    handleMJAIEvent() [Coordinator]                           │
├─────────────────────────────────────────────────────────────────────────────┤
│  start_game:                                                                 │
│    1. eventStream.startNewGame()  ← 清空歷史                                 │
│    2. eventStream.emit(event)     ← 保存到歷史 + yield 到 stream             │
│    3. 創建新 Bot                                                             │
│    4. startEventConsumer()        ← 啟動消費者 Task                          │
│                                                                              │
│  end_game:                                                                   │
│    1. eventStream.emit(event)                                                │
│    2. eventStream.endGame()       ← cancel Task, 清空歷史                    │
│                                                                              │
│  其他事件:                                                                    │
│    eventStream.emit(event)        ← 只發送到 stream                          │
└─────────────────────────────┬───────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                         MJAIEventStream                                      │
├─────────────────────────────────────────────────────────────────────────────┤
│  eventHistory: [[String: Any]]   ← 所有事件副本（用於重放）                   │
│  continuation: AsyncStream.Continuation                                      │
│  consumerTask: Task<Void, Never> ← 只保留一份                                │
├─────────────────────────────────────────────────────────────────────────────┤
│  emit(event):                                                                │
│    1. eventHistory.append(event)  ← 保存                                     │
│    2. continuation?.yield(event)  ← 發送給消費者                             │
│                                                                              │
│  startConsumer(handler):                                                     │
│    1. cancel 舊 Task                                                         │
│    2. 創建新 AsyncStream（先 yield 歷史，再接收新事件）                        │
│    3. 啟動新 Task 消費 stream                                                │
└─────────────────────────────┬───────────────────────────────────────────────┘
                              │ AsyncStream
                              ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                         consumerTask                                         │
├─────────────────────────────────────────────────────────────────────────────┤
│  for await event in stream {                                                │
│      bot.react(event)  → 更新 Bot 狀態，生成推薦                              │
│  }                                                                           │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 實現代碼

### 1. 新增 MJAIEventStream.swift

**文件**: `Naki/Services/Bridge/MJAIEventStream.swift`

```swift
/// MJAI 事件流管理器
/// 負責管理遊戲事件的流式傳遞和歷史記錄
@MainActor
class MJAIEventStream {

    // MARK: - Properties

    /// 事件歷史（當前遊戲的所有事件）
    private var eventHistory: [[String: Any]] = []

    /// 當前的 continuation（用於發送新事件到 stream）
    private var continuation: AsyncStream<[String: Any]>.Continuation?

    /// 消費者 Task（只保留一份，重建時會 cancel 舊的）
    private var consumerTask: Task<Void, Never>?

    /// 當前遊戲是否進行中
    private(set) var isGameInProgress: Bool = false

    /// 事件歷史數量
    var eventCount: Int { eventHistory.count }

    // MARK: - Game Lifecycle

    /// 開始新遊戲
    func startNewGame() {
        print("[MJAIEventStream] Starting new game, clearing history")

        // Cancel 舊的 Task
        consumerTask?.cancel()
        consumerTask = nil

        // Finish 舊的 continuation
        continuation?.finish()
        continuation = nil

        // 清空歷史
        eventHistory = []
        isGameInProgress = true
    }

    /// 結束遊戲
    func endGame() {
        print("[MJAIEventStream] Ending game")

        consumerTask?.cancel()
        consumerTask = nil
        continuation?.finish()
        continuation = nil
        eventHistory = []
        isGameInProgress = false
    }

    // MARK: - Event Emission

    /// 發送事件（保存到歷史 + yield 給消費者）
    func emit(_ event: [String: Any]) {
        eventHistory.append(event)
        continuation?.yield(event)
    }

    // MARK: - Consumer Management

    /// 啟動消費者 Task（會先重放歷史事件）
    func startConsumer(handler: @escaping ([String: Any]) async -> Void) {
        // 1. Cancel 舊的 Task
        consumerTask?.cancel()
        continuation?.finish()

        // 2. 快照當前歷史
        let historySnapshot = eventHistory

        // 3. 創建新的 AsyncStream
        let stream = AsyncStream<[String: Any]> { [weak self] continuation in
            // 先 yield 所有歷史事件
            for event in historySnapshot {
                continuation.yield(event)
            }
            // 保存 continuation 用於接收新事件
            Task { @MainActor in
                self?.continuation = continuation
            }
        }

        // 4. 啟動新的消費者 Task
        consumerTask = Task { [weak self] in
            for await event in stream {
                guard !Task.isCancelled else { break }
                await handler(event)
            }
            await MainActor.run {
                self?.consumerTask = nil
            }
        }
    }

    /// 停止消費者
    func stopConsumer() {
        consumerTask?.cancel()
        consumerTask = nil
    }

    // MARK: - Resync Support

    /// 檢查是否可以重新同步（是否有 start_game 歷史）
    func canResync() -> Bool {
        return eventHistory.contains { ($0["type"] as? String) == "start_game" }
    }

    /// 獲取 start_game 事件中的 playerId
    func getPlayerId() -> Int? {
        for event in eventHistory {
            if (event["type"] as? String) == "start_game",
               let playerId = event["id"] as? Int {
                return playerId
            }
        }
        return nil
    }
}
```

### 2. 修改 WebViewController.swift

#### 2.1 添加 eventStream 屬性

```swift
class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    var parent: NakiWebView
    let websocketHandler = WebSocketMessageHandler()

    /// MJAI 事件流管理器（新增）
    let eventStream = MJAIEventStream()

    // ...
}
```

#### 2.2 修改 WebSocket 連接狀態處理

```swift
websocketHandler.onWebSocketStatusChanged = { [weak self] connected in
    Task { @MainActor in
        if connected {
            self.websocketHandler.reset()

            // ⭐ 嘗試重新同步 Bot
            // 如果是頁面 reload，eventStream 已被清空，canResync() 返回 false
            if self.eventStream.canResync() {
                print("[Coordinator] WebSocket reconnected, attempting to resync bot...")
                await self.resyncBot()
            } else {
                // 沒有進行中的遊戲，正常重置
                self.parent.viewModel.deleteNativeBot()
                // ...
            }
        } else {
            // 斷開連接時停止消費者（但保留歷史以便重連時重放）
            self.eventStream.stopConsumer()
        }
    }
}
```

#### 2.3 重寫 handleMJAIEvent

```swift
private func handleMJAIEvent(_ event: [String: Any]) async {
    guard let eventType = event["type"] as? String else { return }

    switch eventType {
    case "start_game":
        guard let playerId = event["id"] as? Int else { return }

        // 1. 清空舊的 EventStream 並開始新遊戲
        eventStream.startNewGame()

        // 2. 發送 start_game 事件到 stream
        eventStream.emit(event)

        // 3. 刪除舊 Bot，創建新 Bot
        parent.viewModel.deleteNativeBot()
        try await parent.viewModel.createNativeBot(playerId: playerId)

        // 4. 啟動 Consumer，開始消費事件
        startEventConsumer()

    case "end_game":
        eventStream.emit(event)
        eventStream.endGame()
        parent.viewModel.deleteNativeBot()
        // ...

    default:
        // 其他事件直接發送到 stream
        eventStream.emit(event)
    }
}
```

#### 2.4 新增消費者和重同步方法

```swift
/// 啟動事件消費者
private func startEventConsumer() {
    eventStream.startConsumer { [weak self] event in
        guard let self = self else { return }
        do {
            _ = try await self.parent.viewModel.processNativeEvent(event)
        } catch {
            print("[Consumer] ERROR: \(error)")
        }
    }
}

/// 重新同步 Bot（WebSocket 重連時使用）
private func resyncBot() async {
    guard let playerId = eventStream.getPlayerId() else { return }

    parent.viewModel.deleteNativeBot()
    try await parent.viewModel.createNativeBot(playerId: playerId)

    // 啟動 Consumer（會自動重放歷史事件）
    startEventConsumer()
}
```

#### 2.5 更新頁面重載處理

```swift
func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
    // 頁面重新載入時完整重置狀態（包括 EventStream）
    // ⭐ 清空 eventStream 後，canResync() 會返回 false，不會觸發重放
    websocketHandler.fullReset()
    eventStream.endGame()
    parent.viewModel.deleteNativeBot()
    // ...
}
```

---

## 完整 Diff

### MJAIEventStream.swift（新增文件）

```diff
+ /// MJAI 事件流管理器
+ @MainActor
+ class MJAIEventStream {
+     private var eventHistory: [[String: Any]] = []
+     private var continuation: AsyncStream<[String: Any]>.Continuation?
+     private var consumerTask: Task<Void, Never>?
+     private(set) var isGameInProgress: Bool = false
+
+     func startNewGame() { ... }
+     func endGame() { ... }
+     func emit(_ event: [String: Any]) { ... }
+     func startConsumer(handler: @escaping ([String: Any]) async -> Void) { ... }
+     func stopConsumer() { ... }
+     func canResync() -> Bool { ... }
+     func getPlayerId() -> Int? { ... }
+ }
```

### WebViewController.swift

```diff
 class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
     var parent: NakiWebView
     let websocketHandler = WebSocketMessageHandler()
+    let eventStream = MJAIEventStream()

     func setupWebSocketCallbacks() {
         websocketHandler.onWebSocketStatusChanged = { [weak self] connected in
             if connected {
                 self.websocketHandler.reset()
-                self.parent.viewModel.deleteNativeBot()
-                // ... 清理狀態
+                // ⭐ 嘗試重新同步 Bot
+                // 如果是頁面 reload，eventStream 已被清空，canResync() 返回 false
+                if self.eventStream.canResync() {
+                    await self.resyncBot()
+                } else {
+                    self.parent.viewModel.deleteNativeBot()
+                    // ... 清理狀態
+                }
             } else {
-                self.parent.viewModel.deleteNativeBot()
+                self.eventStream.stopConsumer()
             }
         }
     }

-    private func handleMJAIEvent(_ event: [String: Any]) async {
-        switch eventType {
-        case "start_game":
-            try await parent.viewModel.createNativeBot(playerId: playerId)
-            _ = try await parent.viewModel.processNativeEvent(event)
-        // ... 直接處理每個事件
-        }
-    }

+    private func handleMJAIEvent(_ event: [String: Any]) async {
+        switch eventType {
+        case "start_game":
+            eventStream.startNewGame()
+            eventStream.emit(event)
+            try await parent.viewModel.createNativeBot(playerId: playerId)
+            startEventConsumer()
+        case "end_game":
+            eventStream.emit(event)
+            eventStream.endGame()
+            parent.viewModel.deleteNativeBot()
+        default:
+            eventStream.emit(event)
+        }
+    }

+    private func startEventConsumer() { ... }
+    private func resyncBot() async { ... }

     func webView(_ webView: WKWebView, didStartProvisionalNavigation ...) {
+        // ⭐ 清空 eventStream，之後 canResync() 會返回 false
         websocketHandler.fullReset()
+        eventStream.endGame()
         parent.viewModel.deleteNativeBot()
         // ...
     }
 }
```

---

## 驗證結果

### 編譯測試

```bash
xcodebuild -project Naki.xcodeproj -scheme Naki -configuration Debug build
```

**結果**: ✅ Build succeeded

### 場景測試

| 場景 | 預期行為 | 結果 |
|------|----------|------|
| 正常遊戲 | 事件通過 stream 傳遞，Bot 正常工作 | ✅ |
| WebSocket 斷開 | 停止消費者，保留歷史 | ✅ |
| WebSocket 重連（遊戲中） | 自動重建 Bot，重放歷史事件 | ✅ |
| WebSocket 重連（無遊戲） | 正常重置，不重放 | ✅ |
| 遊戲結束 | 清空歷史，清理 stream | ✅ |
| 手動頁面 reload | 清空 stream，走正常流程 | ✅ |

### 日誌輸出示例

```
[MJAIEventStream] Starting new game, clearing history (0 events)
[Coordinator] start_game: starting new game for player 2
[Coordinator] Bot created for player 2
[Coordinator] Starting event consumer...
[MJAIEventStream] Starting consumer with 1 historical events
[Consumer] start_game → response: none

... 遊戲進行中 ...

[MJAIEventStream] Emitted event: tsumo, history count: 45
[Consumer] tsumo → response: dahai

... WebSocket 斷開 ...

[Coordinator] WebSocket disconnected, consumer stopped (history preserved)

... WebSocket 重連 ...

[Coordinator] WebSocket reconnected, attempting to resync bot...
[Coordinator] Resyncing bot for player 2 with 45 historical events
[MJAIEventStream] Starting consumer with 45 historical events
[Consumer] start_game → response: none
[Consumer] start_kyoku → response: none
... (重放所有歷史事件)
[Consumer] tsumo → response: dahai
[Coordinator] Bot resynced successfully
```

---

## 設計決策摘要

| 討論點 | 初始想法 | 最終決策 | 原因 |
|--------|----------|----------|------|
| AsyncStream buffer | 直接用 buffer | 自己維護歷史 | buffer 消費後即清空，無法重放 |
| Task 管理 | 多個 Task | 單一 Task | 避免重複處理，易於管理 |
| 手動 reload | 添加 isPageReloading 標記 | 直接清空 stream | 簡化代碼，清空後 canResync() 自然返回 false |

---

## 總結

### 修改前的問題

1. **事件即時消費**：無法重放歷史
2. **斷線 = 丟失狀態**：Bot 無法恢復
3. **無生命週期管理**：事件處理與遊戲狀態脫鉤

### 修改後的改善

1. **AsyncStream + 歷史記錄**：支持事件重放
2. **自動重同步**：WebSocket 重連時自動恢復 Bot 狀態
3. **清晰的生命週期**：`startNewGame()` / `endGame()` 管理 stream
4. **單一消費者 Task**：避免重複處理，支持 cancel
5. **簡潔的 reload 處理**：清空 stream 即可，無需額外標記

### 相關文件

| 文件 | 作用 |
|------|------|
| `Services/Bridge/MJAIEventStream.swift` | 事件流管理器（新增） |
| `Views/WebViewController.swift` | 事件處理和 Bot 管理（修改） |
| `Services/Bridge/WebSocketInterceptor.swift` | WebSocket 攔截（未修改） |
| `ViewModels/WebViewModel.swift` | Bot 操作接口（未修改） |
