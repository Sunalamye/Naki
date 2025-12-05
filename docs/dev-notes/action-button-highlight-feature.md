# 動作按鈕高亮功能開發筆記

**日期**: 2025-12-05
**功能**: 為動作按鈕（碰/吃/槓/過等）添加推薦高亮效果
**檔案**: `command/Resources/JavaScript/naki-autoplay.js`

---

## 背景

原本的推薦高亮只會顯示在手牌上，使用 `effect_recommend` 3D 效果移動到指定手牌位置。用戶希望擴展此功能，讓動作按鈕（碰、吃、槓、過等）也能顯示推薦高亮。

### 用戶原始需求

> 幫我查找畫面上 碰過 的 ui 位置，現在的推薦只會推在手牌上，我想連碰吃槓和摸過的按鈕也加上，參考一下現在的設計是怎麼做到的，我記得是移動 x,y 軸而已，所以現在要做的是找到那些事件按鈕的位置

---

## 探索過程

### 1. 找到現有的高亮機制

在 `naki-autoplay.js` 中找到 `__nakiRecommendHighlight` 模組：

```javascript
// 位於 naki-autoplay.js:488-520
moveNativeEffect: function(tileIndex) {
    const targetX = hand[tileIndex].pos_x;
    child.transform.localPosition = new Laya.Vector3(targetX, 1.66, -0.52);
    effect.active = true;
}
```

關鍵發現：
- `effect_recommend` 是一個 Laya 3D Sprite3D 物件
- 通過移動其子物件的 `localPosition` 來改變位置
- 手牌的 `pos_x` 是 3D 座標系統中的 X 值

### 2. 找到按鈕 UI 物件

使用 MCP `execute_js` 探索 Majsoul WebUI：

```javascript
// 找到按鈕容器
var ui = uiscript.UI_ChiPengHu.Inst;
var container = ui.container_btns;  // x=812, y=821
```

容器內的按鈕（共 15 個）：
| 索引 | 名稱 | 用途 |
|-----|------|------|
| 4 | btn_chi | 吃 |
| 5 | btn_peng | 碰 |
| 6 | btn_gang | 槓 |
| 7 | btn_lizhi | 立直 |
| 8 | btn_hu | 和（榮和） |
| 10 | btn_zimo | 自摸 |
| 14 | btn_cancel | 過/跳過 |

### 3. WebPage API 注意事項

**重要**: Majsoul 的 WebPage API 有特殊限制（參考 git commit a65c718）：
- 不支援 IIFE (Immediately Invoked Function Expression)
- 必須使用直接的 `return` 語句
- 必須使用 ES5 語法（無箭頭函數、includes、find 等）

錯誤示例：
```javascript
// ❌ 不支援
(function(){ return result; })();
```

正確示例：
```javascript
// ✅ 正確
var result = {};
// ... 處理邏輯
return JSON.stringify(result);
```

---

## 座標映射研究

### 問題：2D UI 座標 vs 3D 效果座標

按鈕是 2D UI 元素，而 `effect_recommend` 是 3D 物件。需要找出兩者的映射關係。

### 測試過程

#### 測試 1: 初始計算嘗試

嘗試用 UI 座標直接計算：
```javascript
var btn_center_x = container.x + btn.x + btn.width / 2;  // = 1335
var btn_pos_x = (btn_center_x - 260) * 2.55 / 96;  // = 28.55
```

**結果**: 位置錯誤，顯示在「過」按鈕後面

#### 測試 2: 手動微調找到正確位置

通過用戶實時反饋，逐步微調找到正確位置：

**btn_peng (碰) 測試序列**:
- x=28.55 → 錯誤（太遠）
- x=18, y=3.5 → **正確！**

**btn_cancel (過) 測試序列**:
- x=24, y=3.5 → 看得到但位置不對
- x=24, y=4.5 → 接近
- x=26, y=4.5 → 接近
- x=27, y=4.5 → 接近
- x=27.5, y=4.5 → **正確！**

**btn_chi (吃) 測試**:
- x=21.5, y=4.5 → 接近
- x=20.5, y=4.5 → **正確！**

### 最終映射公式

| 按鈕位置（從右到左） | UI center_x | 3D x | 3D y |
|---------------------|-------------|------|------|
| 第1個（過，最右） | 1719 | 27.5 | 4.5 |
| 第2個 | 1335 | 20.5 | 4.5 |
| 第3個 | - | 13.5 | 4.5 |

**計算公式**:
```
3D_x = 27.5 - (按鈕索引 × 7)
3D_y = 4.5
3D_z = -0.52
```

其中：
- 按鈕索引 0 = 最右邊的按鈕（通常是「過」）
- 每個按鈕間距 = 7 個 3D 單位
- UI 間距 384 像素 ≈ 7 個 3D 單位 → **約 55 像素/3D單位**

---

## 實現方案

### 新增方法: `moveNativeEffectToButton`

位置: `naki-autoplay.js` 的 `__nakiRecommendHighlight` 模組

```javascript
moveNativeEffectToButton: function(actionType) {
    // 1. 按鈕名稱映射
    const btnNameMap = {
        'chi': 'btn_chi',
        'pon': 'btn_peng',
        'kan': 'btn_gang',
        'hu': 'btn_hu',
        'zimo': 'btn_zimo',
        'ron': 'btn_hu',
        'hora': 'btn_hu',
        'pass': 'btn_cancel',
        // ...
    };

    // 2. 獲取所有可見按鈕，按 center_x 從大到小排序
    const visibleBtns = [];
    for (let i = 0; i < container.numChildren; i++) {
        const btn = container.getChildAt(i);
        if (btn.visible) {
            visibleBtns.push({
                name: btn.name,
                center_x: container.x + btn.x + btn.width / 2
            });
        }
    }
    visibleBtns.sort((a, b) => b.center_x - a.center_x);

    // 3. 找到目標按鈕索引
    const btnIndex = visibleBtns.findIndex(b => b.name === targetBtnName);

    // 4. 計算 3D 位置
    const posX = 27.5 - (btnIndex * 7);
    const posY = 4.5;
    const posZ = -0.52;

    // 5. 移動效果
    child.transform.localPosition = new Laya.Vector3(posX, posY, posZ);
    effect.active = true;
}
```

### 支援的動作類型

| actionType | 對應按鈕 |
|------------|---------|
| chi | btn_chi |
| pon | btn_peng |
| kan | btn_gang |
| hu / ron / hora | btn_hu |
| zimo | btn_zimo |
| pass / cancel | btn_cancel |
| riichi | btn_lizhi |
| ryukyoku / kyushu | btn_jiuzhongjiupai |

---

## 使用方式

```javascript
// 移動高亮到「吃」按鈕
window.__nakiRecommendHighlight.moveNativeEffectToButton('chi');

// 移動高亮到「過」按鈕
window.__nakiRecommendHighlight.moveNativeEffectToButton('pass');

// 隱藏高亮
window.__nakiRecommendHighlight.hideNativeEffect();
```

---

## 關鍵發現

### 1. UI 座標系統與 3D 座標系統無法直接轉換

UI 座標（像素）和 3D 座標之間沒有簡單的線性關係，原因：
- 攝像機投影的影響
- UI 層和 3D 層是獨立的渲染系統
- 不同解析度下的縮放行為不同

### 2. 按鈕位置是動態排列的

按鈕根據可用動作動態顯示，位置取決於：
- 當前可見按鈕的數量
- 按鈕在容器中的相對位置

因此需要：
1. 動態獲取可見按鈕列表
2. 根據排序後的索引計算位置
3. 不能使用固定座標

### 3. 3D 效果的 Y 值不同於手牌

- 手牌高亮: y = 1.66
- 按鈕高亮: y = 4.5（更高，因為按鈕在畫面上方）

---

## 測試驗證

### 測試用例 1: 兩個按鈕（吃 + 過）

```javascript
// 輸入
visibleBtns = [
    { name: 'btn_cancel', center_x: 1719 },  // index 0
    { name: 'btn_chi', center_x: 1335 }      // index 1
]

// btn_chi 的位置
posX = 27.5 - (1 * 7) = 20.5  ✓

// btn_cancel 的位置
posX = 27.5 - (0 * 7) = 27.5  ✓
```

### 測試用例 2: 三個按鈕

預測第三個按鈕位置：
```javascript
posX = 27.5 - (2 * 7) = 13.5  ✓ (用戶確認正確)
```

---

## 後續工作

1. **整合到推薦系統**: 當 AI 推薦動作時，自動調用 `moveNativeEffectToButton`
2. **處理多選情況**: 如吃牌時有多個選擇
3. **動畫過渡**: 添加從手牌到按鈕的平滑移動效果

---

## 相關檔案

- `command/Resources/JavaScript/naki-autoplay.js:538-629` - moveNativeEffectToButton 實現
- `docs/majsoul-webui-objects-reference.md` - WebUI 物件參考

---

## 變更記錄

| 日期 | 版本 | 變更內容 |
|------|------|---------|
| 2025-12-05 | 1.0 | 初始實現，新增 moveNativeEffectToButton 方法 |
