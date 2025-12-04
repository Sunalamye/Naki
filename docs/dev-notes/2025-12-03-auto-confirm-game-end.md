# 開發筆記：自動點擊遊戲結束確認對話框

**日期**: 2025-12-03
**版本**: v3.1 → v3.2 (事件驅動)
**開發者**: Claude + Soane

---

## 1. 問題背景

### 1.1 用戶需求
用戶在遊戲結束後（終局），需要手動點擊確認按鈕才能繼續。希望實現**自動點擊確認**功能。

### 1.2 初始誤解
一開始我誤解了用戶的需求，以為是「立直(riichi)後的確認」：

```
用戶: 幫我看看 log 我想要可以自動點擊確認
我: (查看 log 後發現 riichi 後 oplist 超時)
我: 這是立直確認的問題，讓我修改...
用戶: 不需要調整這些
用戶: 我剛剛的確認是 game 完整結束了 最終局打完
```

**教訓**: 需要先確認用戶的具體需求場景，不要根據 log 自行推測。

---

## 2. 問題定位過程

### 2.1 確認遊戲狀態
用戶提示「現在就是終局結束」，於是我開始探測 UI 狀態：

```bash
# 檢查 view 物件
curl -s -X POST http://localhost:8765/js -d 'typeof window.view'
# 結果: "object"

# 檢查 DesktopMgr
curl -s -X POST http://localhost:8765/js -d 'window.view.DesktopMgr && window.view.DesktopMgr.Inst ? "exists" : "no"'
# 結果: "exists"
```

### 2.2 尋找遊戲結束相關 UI
```bash
# 搜尋結束/結果相關的 UI 類別
curl -s -X POST http://localhost:8765/js -d 'Object.keys(window.uiscript || {}).filter(k => k.includes("End") || k.includes("Result") || k.includes("Confirm") || k.includes("Summary"))'
```

結果發現多個相關類別：
```javascript
[
  "UI_SecondConfirm_Entrance",
  "UI_SecondConfirm",
  "UI_GameEnd",           // ⭐ 這個是我們要的
  "UI_Spot_End",
  "UI_Simulation_Game_End",
  "UI_AnotherGameConfirm"
]
```

### 2.3 確認 UI_GameEnd 狀態
```bash
# 檢查 UI_GameEnd 是否有實例
curl -s -X POST http://localhost:8765/js -d 'window.uiscript.UI_GameEnd && window.uiscript.UI_GameEnd.Inst ? "has instance" : "no instance"'
# 結果: "has instance"

# 檢查 UI 是否可見
curl -s -X POST http://localhost:8765/js -d 'var ge = window.uiscript.UI_GameEnd.Inst; ge && ge.me ? "UI visible" : "UI hidden"'
# 結果: "UI visible"
```

### 2.4 尋找按鈕
```bash
curl -s -X POST http://localhost:8765/js -d 'var ge = window.uiscript.UI_GameEnd.Inst; Object.keys(ge).filter(k => k.includes("btn") || k.includes("Btn") || k.includes("button"))'
```

結果：
```javascript
[
  "btns",
  "btn_next",      // ⭐ 下一局
  "btn_back",      // 返回
  "btn_close",     // 關閉
  "btn_again",     // 再來一局
  "btn_checkPaipu", // 查看牌譜
  "btn_click"
]
```

### 2.5 探索按鈕結構
```bash
curl -s -X POST http://localhost:8765/js -d 'var ge = window.uiscript.UI_GameEnd.Inst; var btn = ge.btn_next; btn ? Object.keys(btn).slice(0,30) : "no btn"'
```

發現按鈕有 `_clickHandler` 屬性：
```javascript
["toggle", "_bitmap", "_text", ..., "_clickHandler", ...]
```

### 2.6 測試點擊
```bash
curl -s -X POST http://localhost:8765/js -d 'var ge = window.uiscript.UI_GameEnd.Inst; var btn = ge.btn_next; if (btn && btn._clickHandler) { btn._clickHandler.run(); "clicked"; } else { "no handler"; }'
# 結果: "clicked"
```

**用戶確認**: 「點擊成功」

---

## 3. 解決方案演進

### 3.1 第一版：輪詢檢測 (v3.1)
最初使用 `setInterval` 每秒檢測 UI 狀態。

**問題**: 用戶詢問「現在是會一直檢測嗎？每一秒」，希望有更好的方法。

### 3.2 第二版：事件驅動 (v3.2) ✅ 最終方案

#### 探索事件系統
```bash
# 探索 NetAgent 的方法
curl -s -X POST http://localhost:8765/js -d '
Object.keys(window.app.NetAgent).filter(k => typeof window.app.NetAgent[k] === "function")
'
# 結果: ["init", "checkValid1Min", "postInfo3Min", "sendReq2Lobby",
#        "addListener2Lobby", "removeListener2Lobby", "sendReq2MJ", "addListener2MJ"]
```

發現 `addListener2MJ` 方法！這是雀魂的消息監聯器。

#### 找到遊戲結束消息
從 `MajsoulBridge.swift` 中發現：
```swift
if method == ".lq.NotifyGameEndResult" || method == ".lq.NotifyGameTerminate" {
    results.append(["type": "end_game"])
}
```

#### 最終代碼實現
**位置**: `Naki/Services/Bridge/WebSocketInterceptor.swift` 第 1438-1517 行

```javascript
// ⭐ 自動確認遊戲結束對話框（事件驅動版本）
window.__nakiAutoConfirm = {
    enabled: true,
    lastConfirmTime: 0,
    listenersAdded: false,

    // 檢查並自動點擊確認
    check: function() {
        if (!this.enabled) return;

        try {
            // 檢查 UI_GameEnd 是否顯示
            var ge = window.uiscript && window.uiscript.UI_GameEnd && window.uiscript.UI_GameEnd.Inst;
            if (ge && ge.me) {
                // 防止重複點擊（3秒內不重複）
                var now = Date.now();
                if (now - this.lastConfirmTime < 3000) return;

                // 找到確認按鈕並點擊
                var btn = ge.btn_next || ge.btn_confirm || ge.btn_close;
                if (btn && btn._clickHandler) {
                    console.log('[Naki] Auto-confirming game end dialog');
                    btn._clickHandler.run();
                    this.lastConfirmTime = now;
                    sendToSwift('auto_confirm', { type: 'game_end', success: true });
                }
            }
        } catch (e) {
            // 忽略錯誤
        }
    },

    // 添加事件監聽器
    addListeners: function() {
        if (this.listenersAdded) return;
        if (!window.app || !window.app.NetAgent) {
            console.log('[Naki] NetAgent not ready, will retry...');
            return false;
        }

        var self = this;

        // 監聽遊戲結束結果
        window.app.NetAgent.addListener2MJ('NotifyGameEndResult', {
            call: function(data) {
                console.log('[Naki] NotifyGameEndResult received');
                setTimeout(function() { self.check(); }, 2000);
            }
        });

        // 監聽遊戲終止
        window.app.NetAgent.addListener2MJ('NotifyGameTerminate', {
            call: function(data) {
                console.log('[Naki] NotifyGameTerminate received');
                setTimeout(function() { self.check(); }, 2000);
            }
        });

        this.listenersAdded = true;
        console.log('[Naki] Auto-confirm listeners added (event-driven)');
        return true;
    },

    // 初始化
    init: function() {
        var self = this;
        // 嘗試添加監聽器，如果失敗則重試
        var tryAdd = function() {
            if (!self.addListeners()) {
                setTimeout(tryAdd, 2000);
            }
        };
        tryAdd();
    }
};

// 延遲初始化（等待遊戲載入）
setTimeout(function() {
    window.__nakiAutoConfirm.init();
}, 5000);
```

---

## 4. 版本比較

| 方式 | 輪詢 (v3.1) | 事件驅動 (v3.2) |
|------|------------|----------------|
| CPU 使用 | 每秒執行一次 | 只在事件發生時執行 |
| 響應速度 | 最多延遲 1 秒 | 收到消息後 2 秒 |
| 代碼優雅度 | 一般 | 更好 |
| 可靠性 | 依賴 UI 狀態 | 依賴網路消息 |
| 資源消耗 | 持續消耗 | 幾乎零消耗 |

---

## 5. 技術細節

### 5.1 雀魂 UI 結構
```
window.uiscript
├── UI_GameEnd              // 遊戲結束對話框
│   └── Inst                // 單例實例
│       ├── me              // 是否顯示 (truthy = 顯示)
│       ├── btn_next        // 下一局按鈕
│       ├── btn_back        // 返回按鈕
│       ├── btn_close       // 關閉按鈕
│       ├── btn_again       // 再來一局按鈕
│       └── btn_checkPaipu  // 查看牌譜按鈕
```

### 5.2 雀魂消息系統
```
window.app.NetAgent
├── addListener2MJ(msgName, handler)  // 添加遊戲消息監聽
├── removeListener2MJ(msgName)        // 移除監聽
├── sendReq2MJ(service, method, data) // 發送請求
└── addListener2Lobby(...)            // 大廳消息監聽
```

### 5.3 按鈕點擊方式
雀魂的 UI 按鈕使用 Laya 引擎，按鈕物件有 `_clickHandler` 屬性：
```javascript
button._clickHandler.run()  // 觸發點擊事件
```

### 5.4 防抖動機制
使用 `lastConfirmTime` 記錄上次點擊時間，3秒內不重複點擊，避免：
- 多次點擊造成異常
- 用戶手動點擊後又被自動點擊

---

## 6. 使用方式

### 6.1 自動生效
重新編譯 app 後，自動確認功能會在遊戲載入 5 秒後自動初始化。

### 6.2 手動控制
```bash
# 禁用自動確認
curl -X POST http://localhost:8765/js -d 'window.__nakiAutoConfirm.enabled = false'

# 啟用自動確認
curl -X POST http://localhost:8765/js -d 'window.__nakiAutoConfirm.enabled = true'

# 手動觸發檢查
curl -X POST http://localhost:8765/js -d 'window.__nakiAutoConfirm.check()'

# 檢查監聽器狀態
curl -X POST http://localhost:8765/js -d 'window.__nakiAutoConfirm.listenersAdded'
```

---

## 7. 相關文件

| 文件 | 修改內容 |
|------|----------|
| `Naki/Services/Bridge/WebSocketInterceptor.swift` | 新增 `__nakiAutoConfirm` 模組（事件驅動版） |

---

## 8. 後續可能的改進

1. **支援更多對話框**: 如 `UI_AnotherGameConfirm`（再來一局確認）
2. **配置化**: 允許用戶在 app 設定中開關自動確認
3. **日誌記錄**: 在 Debug Server 中記錄自動確認事件
4. **UI 指示**: 在 app 狀態列顯示自動確認狀態

---

## 9. 對話記錄摘要

| 階段 | 發言者 | 內容摘要 |
|------|--------|----------|
| 開始 | 用戶 | 想要自動點擊確認，可以用 localhost:8765/help |
| 誤解 | Claude | 查看 log，誤以為是 riichi 確認問題 |
| 糾正 | 用戶 | 「不需要調整這些」「是 game 完整結束了」 |
| 定位 | Claude | 探測 UI_GameEnd，找到 btn_next |
| 驗證 | Claude | 測試 `btn._clickHandler.run()` |
| 確認 | 用戶 | 「點擊成功」 |
| v3.1 | Claude | 實現輪詢版自動確認（每秒檢測） |
| 優化 | 用戶 | 「現在是會一直檢測嗎？有沒有更好的方法」 |
| 探索 | Claude | 發現 `addListener2MJ` 事件監聽 API |
| v3.2 | Claude | 改為事件驅動版本 |
| 文檔 | 用戶 | 「把這次調整寫成詳細的 md 文件」 |

---

## 10. 總結

### 關鍵學習

1. **溝通確認**: 先確認用戶的具體需求場景，不要根據技術 log 自行推測
2. **探索方法**: 使用 `/js` 端點動態探測遊戲 UI 和 API 結構
3. **漸進式開發**: 先測試單點功能，確認可行後再實現完整方案
4. **即時驗證**: 通過直接注入代碼快速驗證，無需每次重新編譯
5. **持續優化**: 用戶反饋後從輪詢改為事件驅動，提升效能

### 技術收穫

- 發現雀魂的 `NetAgent.addListener2MJ` API 可用於監聽遊戲消息
- 了解 Laya 引擎的按鈕點擊機制 `_clickHandler.run()`
- 掌握雀魂 UI 結構 `window.uiscript.UI_XXX.Inst`
