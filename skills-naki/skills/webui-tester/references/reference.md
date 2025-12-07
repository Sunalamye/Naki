# Majsoul WebUI Objects Complete Reference

**來源**: JavaScript Laya 引擎 (window.view.DesktopMgr.Inst)
**重要**: 這些對象屬於 **Majsoul 遊戲的 WebUI**，不是 Naki 的代碼

---

## 目錄

1. [如何查找物件](#如何查找物件)
2. [遊戲管理器](#遊戲管理器)
3. [主玩家物件](#主玩家物件)
4. [牌物件結構](#牌物件結構)
5. [牌類型映射](#牌類型映射)
6. [效果物件](#效果物件)
7. [宝牌指示牌](#宝牌指示牌)
8. [操作類型](#操作類型)
9. [Laya Sprite3D 屬性](#laya-sprite3d-屬性)
10. [動作按鈕 UI](#動作按鈕-ui)

---

## 如何查找物件

### 使用 MCP 工具（推薦）

```
# 獲取完整 API 文檔
mcp__naki__get_help

# 執行 JavaScript（必須有 return！）
mcp__naki__execute_js({ code: "return YOUR_SCRIPT" })

# 查看實時日誌
mcp__naki__get_logs
```

### 常見查詢命令

| 任務 | MCP 命令 |
|------|----------|
| 檢查遊戲是否加載 | `mcp__naki__execute_js({ code: "return !!window.view?.DesktopMgr?.Inst" })` |
| 查詢手牌數 | `mcp__naki__execute_js({ code: "return window.view.DesktopMgr.Inst.mainrole.hand.length" })` |
| 列出手牌 | `mcp__naki__execute_js({ code: "return window.view.DesktopMgr.Inst.mainrole.hand.map((t,i)=>({i,t:t.val.type,n:t.val.index}))" })` |
| Bot 狀態 | `mcp__naki__bot_status` |
| 遊戲狀態 | `mcp__naki__game_state` |
| 執行動作並驗證 | `mcp__naki__game_action_verify` |

### 🆕 動作驗證 (game_action_verify)

執行動作並等待驗證結果，確認動作是否成功：

```javascript
// Pass 並驗證（使用內建 auto-nofulu）
mcp__naki__game_action_verify({ action: "pass", useBuiltin: true })

// 打牌並驗證
mcp__naki__game_action_verify({ action: "discard", tileIndex: 5 })

// 吃牌並驗證（指定組合索引）
mcp__naki__game_action_verify({ action: "chi", combinationIndex: 0, timeout: 3000 })

// 和牌（使用內建 auto-hule）
mcp__naki__game_action_verify({ action: "hora", useBuiltin: true })
```

**返回值**:
```json
{
  "success": true,
  "verified": true,
  "reason": "oplist cleared",
  "elapsed": 150
}
```

---

## 遊戲管理器

### 訪問路徑

```javascript
window.view.DesktopMgr.Inst
```

### 完整結構

```javascript
{
  // ========== 玩家管理 ==========
  mainrole: {
    hand: [Tile, Tile, ...],         // 主玩家手牌 (最多 14 張)
    hand3d: Sprite3D,                // 3D 手牌渲染物件
  },

  players: [Player, Player, Player], // 其他三位玩家
  seat: number,                      // 自己的座位號 (0-3)

  // ========== 遊戲狀態 ==========
  gamestate: number,                 // 當前遊戲狀態值
  oplist: [{ name, index }],         // 可用操作列表
  choosed_op: number,                // 選擇的操作索引
  choosed_pai: Tile | null,          // 當前選擇的牌物件

  // ========== 效果物件（關鍵）==========
  effect_dora3D: Sprite3D,           // 宝牌 3D 閃光效果
  effect_doraPlane: Sprite3D,        // 宝牌平面效果（紅寶牌用）
  effect_recommend: Sprite3D,        // 推薦高亮效果 (AI 用)

  // ========== 宝牌指示牌 ==========
  dora: [{
    dora: boolean,
    index: number,   // 牌號 (0-8)
    type: number,    // 牌類 (0=p, 1=m, 2=s, 3=z)
  }],
}
```

---

## 主玩家物件

### 訪問路徑

```javascript
window.view.DesktopMgr.Inst.mainrole
```

### 方法

```javascript
// 選擇牌
mainrole.setChoosePai(tileObject, true);   // 選擇
mainrole.setChoosePai(tileObject, false);  // 取消

// 執行打牌
mainrole.DoDiscardTile();

// 執行操作
mainrole.DoOperation(operationIndex);

// 副露確認
mainrole.QiPaiNoPass();
```

---

## 牌物件結構

### 訪問路徑

```javascript
const tile = window.view.DesktopMgr.Inst.mainrole.hand[index];
```

### 完整結構

```javascript
{
  // ========== 牌值信息（最重要）==========
  val: {
    type: number,    // 牌類: 0=筒(p), 1=萬(m), 2=索(s), 3=字(z)
    index: number,   // 牌號: 1-9 (數牌) 或 1-7 (字牌)
    dora: boolean    // 是否為紅寶牌 (5mr/5pr/5sr)
  },

  // ========== 位置和狀態 ==========
  index: number,           // 在手中的位置 (0-13)
  isDora: boolean,         // 是否為宝牌
  pos_x: number,           // UI 中的 X 座標
  z: number,               // Z 深度

  // ========== 效果物件（關鍵）==========
  _doraeffect: Sprite3D,       // 宝牌閃光效果物件
  _recommendeffect: Sprite3D,  // 推薦高亮效果物件

  // ========== 3D 渲染相關 ==========
  mySelf: Sprite3D,        // 牌的 3D Sprite 物件
  transform: {
    position: { x, y, z },
    scale: { x, y, z },
    rotation: { x, y, z, w }
  },
}
```

### 關鍵屬性速查

| 屬性 | 類型 | 說明 |
|------|------|------|
| `val.type` | number | 0=筒, 1=萬, 2=索, 3=字 |
| `val.index` | number | 牌號 (1-9 或 1-7) |
| `val.dora` | boolean | 是否紅寶牌 |
| `index` | number | 手中位置 (0-13) |
| `_doraeffect` | Sprite3D | 宝牌效果物件 |
| `_recommendeffect` | Sprite3D | 推薦高亮物件 |

---

## 牌類型映射

### Majsoul 牌類型編碼

```javascript
// 牌類型映射
const typeMap = {
  'p': 0,   // 筒子 (Pinzu)
  'm': 1,   // 萬子 (Manzu)
  's': 2,   // 索子 (Souzu)
  'z': 3    // 字牌 (Jihai)
};

// 字牌詳細映射 (MJAI 格式)
const honorMap = {
  'E': [3, 1],  // 東
  'S': [3, 2],  // 南
  'W': [3, 3],  // 西
  'N': [3, 4],  // 北
  'P': [3, 5],  // 白
  'F': [3, 6],  // 發
  'C': [3, 7]   // 中
};
```

### 牌號轉換

**數字牌 (type 0-2)**: `index 直接 = 牌號` (1-9)
**字牌 (type 3)**: 使用 honorMap 映射

```javascript
// 示例轉換
{ type: 1, index: 2 } → "2m" (2萬)
{ type: 0, index: 5 } → "5p" (5筒)
{ type: 3, index: 3 } → "N"  (北)
```

### 查找牌的正確方式

```javascript
function findTileInHand(tileValue, suitChar, isRed) {
  const typeMap = {'m': 1, 'p': 0, 's': 2};
  const tileType = typeMap[suitChar];
  const tileIndex = tileValue;  // index = 牌號

  const hand = window.view.DesktopMgr.Inst.mainrole.hand;

  for (let i = 0; i < hand.length; i++) {
    const tile = hand[i];
    if (tile && tile.val &&
        tile.val.type === tileType &&
        tile.val.index === tileIndex) {
      // 檢查紅寶牌標記
      if (isRed && tile.val.dora) return i;
      if (!isRed && !tile.val.dora) return i;
    }
  }
  return -1;
}
```

---

## 效果物件

### 效果模板對照表

| 模板 | 用途 | 動畫類型 |
|------|------|----------|
| `effect_dora3D` | 其他場景用 | `anim.Bling` |
| `effect_doraPlane` | 紅寶牌實際使用 | `anim.RunUV` |

### 宝牌效果創建

```javascript
function createDoraEffect(tile) {
  const mgr = window.view.DesktopMgr.Inst;

  // 1. 使用 effect_doraPlane（不是 effect_dora3D）
  const template = mgr.effect_doraPlane;
  const effect = template.clone();

  // 2. 掛到牌的 mySelf 上
  tile.mySelf.addChild(effect);

  // 3. 設置位置
  effect.transform.localPosition = new Laya.Vector3(0, 0, 0);
  effect.transform.localScale = new Laya.Vector3(1, 1, 1);
  effect.active = true;

  // 4. 添加 RunUV 動畫
  effect.getChildAt(0).addComponent(anim.RunUV);

  // 5. 保存引用
  tile._doraeffect = effect;

  return effect;
}
```

### 調整效果顏色

```javascript
function setDoraEffectColor(runUV, r, g, b, a) {
  var color = runUV.mat.albedoColor;
  color.x = r;  // 紅
  color.y = g;  // 綠
  color.z = b;  // 藍
  color.w = a;  // 亮度
  runUV.mat.albedoColor = color;
}

// 常用顏色 (值 > 1 會更亮)
setDoraEffectColor(runUV, 2, 2, 2, 2);  // 白色
setDoraEffectColor(runUV, 2, 0, 0, 2);  // 紅色
setDoraEffectColor(runUV, 0, 2, 0, 2);  // 綠色
```

### 雙層旋轉 Bling 效果

```javascript
function createDualRotatingEffect(tile, color) {
  const mgr = window.view.DesktopMgr.Inst;
  const effects = [];

  // 創建兩層效果 (90° 和 180°)
  [90, 180].forEach(rotation => {
    const effect = mgr.effect_doraPlane.clone();
    tile.mySelf.addChild(effect);

    effect.transform.localPosition = new Laya.Vector3(0, 0, 0);
    effect.transform.localRotationEuler = new Laya.Vector3(0, 0, rotation);
    effect.active = true;

    // 添加 Bling 動畫
    const bling = effect.getChildAt(0).addComponent(anim.Bling);
    bling.tick = 300;  // 快速閃爍

    // 設置顏色
    if (color && bling.mat) {
      const c = bling.mat.albedoColor;
      c.x = color.r; c.y = color.g; c.z = color.b; c.w = color.a;
      bling.mat.albedoColor = c;
    }

    effects.push(effect);
  });

  // 啟動旋轉動畫
  setInterval(() => {
    effects.forEach(effect => {
      const z = effect.transform.localRotationEuler.z + 3;
      effect.transform.localRotationEuler = new Laya.Vector3(0, 0, z);
    });
  }, 30);

  return effects;
}
```

---

## 宝牌指示牌

### 訪問路徑

```javascript
window.view.DesktopMgr.Inst.dora
```

### 結構

```javascript
dora: [
  {
    dora: boolean,      // 是否為宝牌
    index: number,      // 牌號 (0-8)
    type: number,       // 牌類 (0=p, 1=m, 2=s, 3=z)
    touming: boolean,   // 是否透明
    baida: boolean      // 白牌標記
  }
]
```

---

## 操作類型

### 操作編碼表

```javascript
const opNames = {
  0: 'none',      // 無操作
  1: 'dapai',     // 打牌
  2: 'chi',       // 吃
  3: 'pon',       // 碰
  4: 'ankan',     // 暗槓
  5: 'minkan',    // 明槓
  6: 'kakan',     // 加槓
  7: 'riichi',    // 立直
  8: 'tsumo',     // 自摸
  9: 'ron',       // 榮和
  10: 'kyushu',   // 九種九牌
  11: 'babei'     // 流局
};
```

### 訪問操作列表

```javascript
const oplist = window.view.DesktopMgr.Inst.oplist;
// [{ name: 'dapai', index: 0 }, { name: 'riichi', index: 1 }, ...]
```

---

## Laya Sprite3D 屬性

### 常用屬性

```javascript
{
  name: string,                  // 物件名稱
  active: boolean,               // 是否激活
  visible: boolean,              // 是否可見

  transform: {
    position: { x, y, z },       // 位置
    rotation: { x, y, z, w },    // 旋轉 (四元數)
    scale: { x, y, z }           // 縮放
  },

  parent: Sprite3D,              // 父物件
  _childs: [Sprite3D],           // 子物件陣列
}
```

### 常用方法

```javascript
// 激活/停用
sprite.active = true;

// 設定位置
sprite.transform.position = new Laya.Vector3(x, y, z);

// 子物件操作
const child = sprite.getChildByName("name");
sprite.addChild(childSprite);
```

---

## 動作按鈕 UI

### 訪問路徑

```javascript
window.uiscript.UI_ChiPengHu.Inst
```

### 按鈕索引表

| 索引 | 名稱 | 用途 |
|-----|------|------|
| 4 | btn_chi | 吃 |
| 5 | btn_peng | 碰 |
| 6 | btn_gang | 槓 |
| 7 | btn_lizhi | 立直 |
| 8 | btn_hu | 和/榮和 |
| 10 | btn_zimo | 自摸 |
| 14 | btn_cancel | 過/取消 |

### 獲取可見按鈕

```javascript
var ui = uiscript.UI_ChiPengHu.Inst;
var container = ui.container_btns;
var visibleBtns = [];

for (var i = 0; i < container.numChildren; i++) {
    var btn = container.getChildAt(i);
    if (btn.visible) {
        visibleBtns.push({
            name: btn.name,
            x: btn.x,
            center_x: container.x + btn.x + btn.width / 2
        });
    }
}
return visibleBtns;
```

### 按鈕 3D 效果座標映射

```javascript
// 按鈕索引從右到左排列（0 = 最右邊）
var posX = 27.5 - (btnIndex * 7);
var posY = 4.5;
var posZ = -0.52;
```

---

## Naki JavaScript 模組

### 全域物件

```javascript
window.__nakiGameAPI = {
  getGameState(),     // 獲取完整遊戲狀態
  getHandTiles(),     // 獲取手牌陣列
  getDora(),          // 獲取宝牌指示牌
  getOperations(),    // 獲取可用操作
}

window.__nakiDoraHook = {
  hook(),             // 攔截宝牌效果變更
  getHistory()        // 獲取攔截歷史
}

window.__nakiRecommendHighlight = {
  show(tileIndex),    // 顯示推薦高亮
  hide(),             // 隱藏推薦高亮
  getStatus()         // 獲取狀態
}
```

---

## 故障排查

### 遊戲管理器未定義

```javascript
if (!window.view?.DesktopMgr?.Inst) {
  console.error("遊戲未加載完成");
}
```

### 手牌陣列為空

```javascript
const hand = window.view.DesktopMgr.Inst.mainrole.hand;
if (hand.length === 0) {
  console.log("可能不在遊戲中或還未摸牌");
}
```

### 效果物件未初始化

```javascript
const effect = window.view.DesktopMgr.Inst.effect_recommend;
if (!effect || effect.active === undefined) {
  console.error("效果物件未初始化");
}
```

---

**文檔版本**: 1.1
**更新日期**: 2025-12-05
