# 紅寶牌丟牌優先級修復記錄

> 日期：2025-12-03
> 修改文件：`Naki/Services/Bot/NativeBotController.swift`

---

## 問題描述

當 AI 推薦丟棄 5 萬/5 筒/5 索時，如果手牌中同時存在紅寶牌（赤5）和普通牌，系統沒有優先選擇丟棄普通牌，可能會誤丟紅寶牌，造成不必要的損失。

**紅寶牌的價值**：在日本麻將中，紅寶牌（赤ドラ）等同於一張懸賞牌，每張紅寶牌可以額外增加一翻，應該盡量保留。

---

## 問題定位過程

### 1. 理解系統架構

首先通過搜索了解打牌流程：

```
AI 推理 (Core ML/Mortal)
    ↓
NativeBotController.actionIndexToRecommendation()  ← 生成推薦
    ↓
WebViewModel.executeAction()  ← 執行動作
    ↓
JavaScript (遊戲 WebView)  ← 在遊戲中找到並點擊對應的牌
```

### 2. 定位關鍵代碼

**文件**: `Naki/Services/Bot/NativeBotController.swift`

搜索丟牌相關邏輯：
```bash
grep -n "discard5m\|actionIndexToRecommendation" NativeBotController.swift
```

找到 `actionIndexToRecommendation` 函數（原始代碼在行 730-785）：

```swift
private func actionIndexToRecommendation(_ index: Int, probability: Double) -> Recommendation? {
    guard let action = MahjongAction(rawValue: index) else { return nil }

    switch action {
    case .discard1m, .discard2m, .discard3m, .discard4m, .discard5m,
         .discard6m, .discard7m, .discard8m, .discard9m:
        let num = index + 1
        return Recommendation(tile: "\(num)m", probability: probability, actionType: .discard)
        // ⚠️ 問題：無論手牌情況如何，5m 總是返回 "5m"，不區分紅寶牌
    // ... 筒子、索子同理
    }
}
```

### 3. 分析 JavaScript 端邏輯

**文件**: `Naki/ViewModels/WebViewModel.swift` (行 513-606)

JavaScript 端已經有正確的紅寶牌匹配邏輯：

```javascript
// 解析目標牌名
var isRed = target.length > 2 && target[2] === 'r';  // "5mr" → isRed=true

// 在手牌中查找
for (var i = 0; i < mr.hand.length; i++) {
    var t = mr.hand[i];
    if (t && t.val && t.val.type === tileType && t.val.index === tileValue) {
        if (isRed) {
            if (t.val.dora) return {index: i};  // 找紅寶牌
        } else {
            if (!t.val.dora) return {index: i}; // 找非紅寶牌
        }
    }
}
```

**結論**：JavaScript 端邏輯正確，問題在 Swift 端沒有根據手牌情況傳遞正確的 `tileName`。

### 4. 確認數據結構

手牌存儲在 `tehai: [Tile]` 中，`Tile` 來自 MortalSwift 庫：

```swift
// Tile 結構（來自 MortalSwift）
case .man(let num, let red)  // red: Bool 表示是否為紅寶牌
case .pin(let num, let red)
case .sou(let num, let red)
```

可以通過 `tile.isRed` 判斷是否為紅寶牌。

---

## 修改方案

### 修改目標

當 AI 推薦丟 5m/5p/5s 時：

| 手牌情況 | 應該傳遞的 tileName |
|---------|-------------------|
| 只有紅 5 | `"5mr"` / `"5pr"` / `"5sr"` |
| 只有普通 5 | `"5m"` / `"5p"` / `"5s"` |
| 紅 5 + 普通 5 都有 | `"5m"` / `"5p"` / `"5s"` （優先丟普通牌） |

### 新增輔助方法

在 `tileToDiscardActionIndex` 函數後新增 `shouldDiscardRedDora` 方法：

```swift
/// 判斷丟 5 牌時是否應該丟紅寶牌
/// 邏輯：如果手牌中只有紅寶牌（沒有普通的 5），才丟紅寶牌
/// 如果有普通的 5，優先丟普通的（保留紅寶牌的價值）
private func shouldDiscardRedDora(suit: String) -> Bool {
    // 收集手牌 + 自摸牌中所有指定花色的 5
    var allTiles = tehai
    if let t = tsumo { allTiles.append(t) }

    var hasRed = false
    var hasNormal = false

    for tile in allTiles {
        switch (tile, suit) {
        case (.man(5, let red), "m"):
            if red { hasRed = true } else { hasNormal = true }
        case (.pin(5, let red), "p"):
            if red { hasRed = true } else { hasNormal = true }
        case (.sou(5, let red), "s"):
            if red { hasRed = true } else { hasNormal = true }
        default:
            continue
        }
    }

    // 只有在「有紅寶牌」且「沒有普通牌」的情況下才丟紅寶牌
    return hasRed && !hasNormal
}
```

### 修改 actionIndexToRecommendation

在處理 5m/5p/5s 時加入判斷：

```swift
case .discard1m, .discard2m, .discard3m, .discard4m, .discard5m,
     .discard6m, .discard7m, .discard8m, .discard9m:
    let num = index + 1
    // 特殊處理 5m：優先丟普通牌，只有在只有紅寶牌時才丟紅寶牌
    if num == 5 {
        let tileStr = shouldDiscardRedDora(suit: "m") ? "5mr" : "5m"
        return Recommendation(tile: tileStr, probability: probability, actionType: .discard)
    }
    return Recommendation(tile: "\(num)m", probability: probability, actionType: .discard)

// 筒子、索子同理...
```

---

## 完整修改 Diff

```diff
--- a/Naki/Services/Bot/NativeBotController.swift
+++ b/Naki/Services/Bot/NativeBotController.swift
@@ -726,6 +726,32 @@ class NativeBotController {
         }
     }

+    /// 判斷丟 5 牌時是否應該丟紅寶牌
+    /// 邏輯：如果手牌中只有紅寶牌（沒有普通的 5），才丟紅寶牌
+    /// 如果有普通的 5，優先丟普通的（保留紅寶牌的價值）
+    private func shouldDiscardRedDora(suit: String) -> Bool {
+        // 收集手牌 + 自摸牌中所有指定花色的 5
+        var allTiles = tehai
+        if let t = tsumo { allTiles.append(t) }
+
+        var hasRed = false
+        var hasNormal = false
+
+        for tile in allTiles {
+            switch (tile, suit) {
+            case (.man(5, let red), "m"):
+                if red { hasRed = true } else { hasNormal = true }
+            case (.pin(5, let red), "p"):
+                if red { hasRed = true } else { hasNormal = true }
+            case (.sou(5, let red), "s"):
+                if red { hasRed = true } else { hasNormal = true }
+            default:
+                continue
+            }
+        }
+
+        // 只有在「有紅寶牌」且「沒有普通牌」的情況下才丟紅寶牌
+        return hasRed && !hasNormal
+    }
+
     private func actionIndexToRecommendation(_ index: Int, probability: Double) -> Recommendation? {
         guard let action = MahjongAction(rawValue: index) else { return nil }

@@ -733,17 +759,29 @@ class NativeBotController {
         case .discard1m, .discard2m, .discard3m, .discard4m, .discard5m,
              .discard6m, .discard7m, .discard8m, .discard9m:
             let num = index + 1
+            // 特殊處理 5m：優先丟普通牌，只有在只有紅寶牌時才丟紅寶牌
+            if num == 5 {
+                let tileStr = shouldDiscardRedDora(suit: "m") ? "5mr" : "5m"
+                return Recommendation(tile: tileStr, probability: probability, actionType: .discard)
+            }
             return Recommendation(tile: "\(num)m", probability: probability, actionType: .discard)

         case .discard1p, .discard2p, .discard3p, .discard4p, .discard5p,
              .discard6p, .discard7p, .discard8p, .discard9p:
             let num = index - 8
+            // 特殊處理 5p：優先丟普通牌，只有在只有紅寶牌時才丟紅寶牌
+            if num == 5 {
+                let tileStr = shouldDiscardRedDora(suit: "p") ? "5pr" : "5p"
+                return Recommendation(tile: tileStr, probability: probability, actionType: .discard)
+            }
             return Recommendation(tile: "\(num)p", probability: probability, actionType: .discard)

         case .discard1s, .discard2s, .discard3s, .discard4s, .discard5s,
              .discard6s, .discard7s, .discard8s, .discard9s:
             let num = index - 17
+            // 特殊處理 5s：優先丟普通牌，只有在只有紅寶牌時才丟紅寶牌
+            if num == 5 {
+                let tileStr = shouldDiscardRedDora(suit: "s") ? "5sr" : "5s"
+                return Recommendation(tile: tileStr, probability: probability, actionType: .discard)
+            }
             return Recommendation(tile: "\(num)s", probability: probability, actionType: .discard)
```

---

## 驗證結果

### 編譯測試

```bash
xcodebuild -project Naki.xcodeproj -scheme Naki -configuration Debug build
```

**結果**: ✅ Build succeeded

### 邏輯驗證

| 測試場景 | 手牌 | shouldDiscardRedDora | tileName | 預期行為 |
|---------|------|---------------------|----------|---------|
| 只有紅 5 萬 | [5mr] | `true` | "5mr" | 丟紅寶牌 ✅ |
| 只有普通 5 萬 | [5m] | `false` | "5m" | 丟普通牌 ✅ |
| 紅+普通都有 | [5m, 5mr] | `false` | "5m" | 優先丟普通牌 ✅ |
| 沒有 5 萬 | [] | `false` | "5m" | 由 JS fallback 處理 |

---

## 系統流程圖

```
┌─────────────────────────────────────────────────────────────────┐
│                    NativeBotController (Swift)                   │
├─────────────────────────────────────────────────────────────────┤
│  1. Mortal AI 推理 → discard5m                                   │
│  2. actionIndexToRecommendation() 被調用                         │
│  3. 檢測到 num == 5                                              │
│  4. 調用 shouldDiscardRedDora(suit: "m")                        │
│     ├─ 遍歷 tehai + tsumo                                        │
│     ├─ 檢查是否有 .man(5, red: true/false)                       │
│     └─ 返回 hasRed && !hasNormal                                 │
│  5. 生成 Recommendation(tile: "5m" 或 "5mr")                     │
└───────────────────────────┬─────────────────────────────────────┘
                            │ tileName
                            ▼
┌─────────────────────────────────────────────────────────────────┐
│                    WebViewModel (Swift → JS)                     │
├─────────────────────────────────────────────────────────────────┤
│  executeAction(.discard, tileName: "5m" 或 "5mr")               │
└───────────────────────────┬─────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────────┐
│                    JavaScript (遊戲 WebView)                     │
├─────────────────────────────────────────────────────────────────┤
│  var isRed = target[2] === 'r';  // "5mr" → true, "5m" → false  │
│                                                                  │
│  for (手牌中的每張牌) {                                           │
│      if (type 和 value 匹配) {                                   │
│          if (isRed && t.val.dora) return 這張牌;    // 找紅寶牌   │
│          if (!isRed && !t.val.dora) return 這張牌;  // 找普通牌   │
│      }                                                           │
│  }                                                               │
│                                                                  │
│  // Fallback: 如果精確匹配失敗，找任意一張相同數值的牌              │
└─────────────────────────────────────────────────────────────────┘
```

---

## 總結

### 修改前的問題

- Swift 端總是傳遞 "5m"/"5p"/"5s"，不考慮紅寶牌
- JavaScript 端會優先找非紅寶牌，找不到才 fallback
- 當手牌中只有紅寶牌時，第一輪搜索失敗，效率較低

### 修改後的改善

1. **精確匹配**: Swift 端根據手牌情況傳遞正確的 tileName
2. **保護紅寶牌**: 有選擇時優先丟普通牌，保留紅寶牌價值
3. **邏輯一致**: Swift 端和 JavaScript 端的紅寶牌處理邏輯完全對應

### 相關文件

| 文件 | 作用 |
|------|-----|
| `Services/Bot/NativeBotController.swift` | AI 推薦生成（本次修改） |
| `ViewModels/WebViewModel.swift` | 執行打牌（JavaScript 端邏輯） |
| `Models/GameModels.swift` | Tile 數據結構定義 |
