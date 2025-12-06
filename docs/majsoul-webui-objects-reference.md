# Majsoul WebUI Objects Complete Reference

**日期**: 2025-12-04
**來源**: JavaScript Laya 引擎 (window.view.DesktopMgr.Inst)
**重要**: 這些對象屬於 **Majsoul 遊戲的 WebUI**，不是 Naki 的代碼

---

## 目錄

1. [如何查找物件 (Finding Objects)](#如何查找物件-finding-objects)
2. [遊戲管理器 (Game Manager)](#遊戲管理器-game-manager)
3. [主玩家物件 (Mainrole)](#主玩家物件-mainrole)
4. [牌物件結構 (Tile Object)](#牌物件結構-tile-object)
5. [牌類型映射 (Type Mapping)](#牌類型映射-type-mapping)
6. [效果物件 (Effect Objects)](#效果物件-effect-objects)
7. [宝牌指示牌 (Dora Indicators)](#宝牌指示牌-dora-indicators)
8. [操作類型 (Operation Types)](#操作類型-operation-types)
9. [Laya Sprite3D 屬性](#laya-sprite3d-屬性)

---

## 如何查找物件 (Finding Objects)

### 使用 MCP 工具查詢（推薦）

Naki 提供 MCP 工具，可直接在 AI 助手中查詢和檢查遊戲物件。

#### 1. 基本 API 查詢

```
# 獲取完整 API 文檔
mcp__naki__get_help

# 執行 JavaScript 並查看結果
mcp__naki__execute_js({ code: "YOUR_SCRIPT" })

# 查看實時日誌
mcp__naki__get_logs
```

#### 2. 查詢遊戲管理器

```
# 檢查 DesktopMgr 是否存在
mcp__naki__execute_js({ code: "window.view?.DesktopMgr?.Inst" })

# 獲取遊戲狀態結構
mcp__naki__execute_js({ code: "Object.keys(window.view.DesktopMgr.Inst)" })

# 查詢手牌
mcp__naki__execute_js({ code: "window.view.DesktopMgr.Inst.mainrole.hand.length" })
```

### 使用 HTTP 端點（傳統方式）

```bash
curl http://localhost:8765/help | jq .                                    # API 文檔
curl -X POST http://localhost:8765/js -d "YOUR_SCRIPT"                    # 執行 JS
curl http://localhost:8765/logs                                           # 日誌
```

### 在 JavaScript 中查詢

#### 檢查遊戲管理器是否可用

```javascript
// 最安全的訪問方式
const inst = window.view?.DesktopMgr?.Inst;

if (inst) {
  console.log("✅ 遊戲管理器可用");
  console.log("手牌數:", inst.mainrole.hand.length);
  console.log("宝牌數:", inst.dora.length);
} else {
  console.log("❌ 遊戲管理器未初始化");
}
```

#### 查詢所有頂級屬性

```javascript
const inst = window.view.DesktopMgr.Inst;

// 獲取所有屬性名稱
const keys = Object.keys(inst);
console.log("遊戲管理器屬性:", keys);

// 獲取所有方法
const methods = Object.getOwnPropertyNames(Object.getPrototypeOf(inst));
console.log("遊戲管理器方法:", methods);
```

#### 查詢手牌詳細信息

```javascript
const inst = window.view.DesktopMgr.Inst;
const hand = inst.mainrole.hand;

// 列出所有手牌
hand.forEach((tile, index) => {
  console.log(`${index}: ${tile.val.type}-${tile.val.index} (isDora: ${tile.isDora})`);
});

// 查詢特定牌
const firstTile = hand[0];
console.log("第一張牌的所有屬性:", Object.keys(firstTile));
console.log("val 物件:", firstTile.val);
console.log("效果物件:", {
  dora: firstTile._doraeffect,
  recommend: firstTile._recommendeffect
});
```

#### 查詢效果物件

```javascript
const inst = window.view.DesktopMgr.Inst;

// 查詢宝牌效果
console.log("宝牌 3D 效果:", inst.effect_dora3D);
console.log("宝牌 3D 陰影:", inst.effect_dora3D_touying);

// 查詢推薦高亮效果
console.log("推薦高亮效果:", inst.effect_recommend);
console.log("推薦高亮激活狀態:", inst.effect_recommend?.active);

// 查詢所有效果物件的屬性
const effects = {
  dora3D: inst.effect_dora3D,
  dora3D_touying: inst.effect_dora3D_touying,
  doraPlane: inst.effect_doraPlane,
  recommend: inst.effect_recommend,
  shadow: inst.effect_shadow
};

Object.entries(effects).forEach(([name, effect]) => {
  console.log(`${name}:`, {
    active: effect?.active,
    visible: effect?.visible,
    alpha: effect?.alpha,
    name: effect?.name
  });
});
```

#### 查詢牌物件的所有屬性

```javascript
const tile = window.view.DesktopMgr.Inst.mainrole.hand[0];

// 列出所有屬性（包括繼承的）
const allProps = new Set();
let obj = tile;
while (obj) {
  Object.getOwnPropertyNames(obj).forEach(prop => allProps.add(prop));
  obj = Object.getPrototypeOf(obj);
}
console.log("牌物件的所有屬性:", Array.from(allProps).sort());

// 列出自訂屬性
const ownProps = Object.getOwnPropertyNames(tile);
console.log("牌物件的自訂屬性:", ownProps);

// 獲取屬性描述符
const descriptors = Object.getOwnPropertyDescriptors(tile);
Object.entries(descriptors).forEach(([name, desc]) => {
  console.log(`${name}:`, {
    value: desc.value,
    writable: desc.writable,
    configurable: desc.configurable,
    enumerable: desc.enumerable
  });
});
```

#### 查詢宝牌指示牌

```javascript
const inst = window.view.DesktopMgr.Inst;
const dora = inst.dora;

console.log("宝牌數量:", dora.length);

dora.forEach((doraInfo, index) => {
  const typeNames = ['p', 'm', 's', 'z'];
  const typeName = typeNames[doraInfo.type];
  console.log(`宝牌 ${index}: ${doraInfo.index + 1}${typeName}`);
  console.log({
    type: doraInfo.type,
    index: doraInfo.index,
    dora: doraInfo.dora,
    transparent: doraInfo.touming,
    whiteTile: doraInfo.baida
  });
});
```

#### 查詢操作列表

```javascript
const inst = window.view.DesktopMgr.Inst;
const oplist = inst.oplist;

console.log("可用操作:", oplist.map(op => op.name));

const opNames = {
  0: 'none', 1: 'dapai', 2: 'chi', 3: 'pon',
  4: 'ankan', 5: 'minkan', 6: 'kakan', 7: 'riichi',
  8: 'tsumo', 9: 'ron', 10: 'kyushu', 11: 'babei'
};

oplist.forEach(op => {
  console.log(`操作 ${op.index}: ${opNames[op.index] || op.name}`);
});
```

### 使用 MCP 工具的完整工作流（推薦）

#### 1. 驗證連接

```
# 獲取 API 狀態
mcp__naki__get_status

# 獲取完整文檔
mcp__naki__get_help
```

#### 2. 執行 JavaScript 查詢

```
# 查詢手牌詳細信息
mcp__naki__execute_js({ code: `
const inst = window.view?.DesktopMgr?.Inst;
if (inst) {
  inst.mainrole.hand.map((t, i) => ({
    index: i,
    type: t.val.type,
    number: t.val.index + 1,
    isDora: t.isDora
  }));
}
` })
```

#### 3. 監控物件變更

```
# 設置宝牌效果攔截
mcp__naki__execute_js({ code: "window.__nakiDoraHook?.hook()" })

# 查詢變更歷史
mcp__naki__execute_js({ code: "window.__nakiDoraHook?.getHistory()" })
```

#### 4. 測試推薦高亮

```
# 顯示第 3 張牌的推薦高亮
mcp__naki__execute_js({ code: "window.__nakiRecommendHighlight?.show(3)" })

# 查詢當前狀態
mcp__naki__execute_js({ code: "window.__nakiRecommendHighlight?.getStatus()" })

# 隱藏高亮
mcp__naki__execute_js({ code: "window.__nakiRecommendHighlight?.hide()" })
```

### 常見查詢命令速查表

#### MCP 工具（推薦）

| 任務 | MCP 工具 |
|------|------|
| **檢查遊戲是否已加載** | `mcp__naki__execute_js({ code: "!!window.view?.DesktopMgr?.Inst" })` |
| **查詢手牌數** | `mcp__naki__execute_js({ code: "window.view.DesktopMgr.Inst.mainrole.hand.length" })` |
| **列出手牌** | `mcp__naki__execute_js({ code: "window.view.DesktopMgr.Inst.mainrole.hand.map((t,i)=>({i,t:t.val.type,n:t.val.index+1}))" })` |
| **獲取 Bot 狀態和 AI 推薦** | `mcp__naki__bot_status` |
| **獲取遊戲狀態** | `mcp__naki__game_state` |
| **查看日誌** | `mcp__naki__get_logs` |

#### HTTP 端點（傳統方式）

| 任務 | 命令 |
|------|------|
| **檢查遊戲是否已加載** | `curl -X POST http://localhost:8765/js -d "!!window.view?.DesktopMgr?.Inst"` |
| **查詢手牌數** | `curl -X POST http://localhost:8765/js -d "window.view.DesktopMgr.Inst.mainrole.hand.length"` |
| **獲取 Bot 狀態** | `curl http://localhost:8765/bot/status` |
| **查看日誌** | `curl http://localhost:8765/logs` |

### 故障排查

#### 遊戲管理器未定義

```javascript
// 檢查是否在遊戲加載後執行
if (!window.view?.DesktopMgr?.Inst) {
  console.error("遊戲未加載完成，等待中...");

  // 輪詢直到遊戲加載
  const checkGame = setInterval(() => {
    if (window.view?.DesktopMgr?.Inst) {
      clearInterval(checkGame);
      console.log("遊戲已加載！");
    }
  }, 100);
}
```

#### 手牌陣列為空

```javascript
// 檢查是否處於遊戲中
const hand = window.view.DesktopMgr.Inst.mainrole.hand;
if (hand.length === 0) {
  console.log("可能不在遊戲中或還未摸牌");
  console.log("遊戲狀態:", window.view.DesktopMgr.Inst.gamestate);
}
```

#### 效果物件未初始化

```javascript
// 檢查效果物件的狀態
const effect = window.view.DesktopMgr.Inst.effect_recommend;
if (!effect) {
  console.error("推薦效果物件未初始化");
} else if (effect.active === undefined) {
  console.error("推薦效果物件未完全初始化");
} else {
  console.log("推薦效果物件正常:", effect.active);
}
```

---

## 遊戲管理器 (Game Manager)

### 訪問路徑

```javascript
window.view.DesktopMgr.Inst
```

**檔案**: `Naki/Resources/JavaScript/naki-game-api.js:127-180`

### 完整結構

```javascript
{
  // ========== 玩家管理 ==========
  mainrole: {
    hand: [Tile, Tile, ...],         // 主玩家手牌 (最多 14 張)
    hand3d: Sprite3D,                // 3D 手牌渲染物件
    HandPaiPlane: {},                // 平面手牌渲染

    // 方法
    setChoosePai(tile, boolean): void,    // 選擇要打的牌
    DoDiscardTile(): void,                // 執行打牌動作
    DoOperation(opIndex): void,           // 執行指定操作
    QiPaiNoPass(): void,                  // 副露確認
  },

  players: [
    { /* Player 1 */ },
    { /* Player 2 */ },
    { /* Player 3 */ }
  ],                                 // 其他三位玩家物件陣列

  seat: number,                      // 自己的座位號 (0-3)

  // ========== 遊戲狀態 ==========
  gamestate: number,                 // 當前遊戲狀態值
  oplist: [                          // 可用操作列表
    { name: 'dapai', index: 0 },
    { name: 'chi', index: 1 },
    // ... 更多操作
  ],

  choosed_op: number,                // 選擇的操作索引
  choosed_op_combine: number,        // 選擇的組合索引
  choosed_pai: Tile | null,          // 當前選擇的牌物件

  // ========== 效果物件（關鍵）==========
  effect_dora3D: Sprite3D,           // ⭐ 宝牌 3D 閃光效果
  effect_dora3D_touying: Sprite3D,   // 宝牌 3D 陰影效果
  effect_doraPlane: Sprite3D,        // 宝牌平面效果
  effect_recommend: Sprite3D,        // ⭐ 推薦高亮效果 (AI 用)
  effect_shadow: Sprite3D,           // 一般陰影效果

  // ========== 宝牌指示牌 ==========
  dora: [
    {
      dora: boolean,                 // 是否為寶牌
      index: number,                 // 牌號 (0-8)
      type: number,                  // 牌類 (0=p筒, 1=m萬, 2=s索, 3=z字)
      touming: boolean,              // 是否透明
      baida: boolean                 // 白牌標記
    }
  ],

  // ========== 其他 ==========
  lastpai: Tile | null              // 最後打出的牌物件
}
```

### 重要屬性說明

| 屬性 | 類型 | 說明 |
|------|------|------|
| `mainrole.hand` | `Tile[]` | **最重要**: 手牌陣列（不是排序的，和 UI 顯示順序相同） |
| `effect_recommend` | `Sprite3D` | 推薦高亮效果（設定 `.active = true/false`） |
| `dora` | `Object[]` | 宝牌指示牌數據 |
| `oplist` | `Object[]` | 當前可用的操作列表 |

---

## 主玩家物件 (Mainrole)

### 訪問路徑

```javascript
window.view.DesktopMgr.Inst.mainrole
```

**檔案**: `Naki/Resources/JavaScript/naki-game-api.js:189-200`

### 方法 (Methods)

#### 選擇牌

```javascript
mainrole.setChoosePai(tileObject, true);   // 選擇要打的牌
mainrole.setChoosePai(tileObject, false);  // 取消選擇
```

#### 執行打牌

```javascript
mainrole.DoDiscardTile();  // 確認並打出選擇的牌
```

#### 執行操作

```javascript
mainrole.DoOperation(operationIndex);  // 執行指定索引的操作
```

#### 副露確認

```javascript
mainrole.QiPaiNoPass();  // 確認吃/碰/槓操作
```

### 其他屬性

- `hand3d: Sprite3D` - 3D 手牌容器物件
- `HandPaiPlane: Object` - 平面渲染層（用於 2D Canvas）
- 多個內部狀態追蹤屬性

---

## 牌物件結構 (Tile Object)

### 訪問路徑

```javascript
const tile = window.view.DesktopMgr.Inst.mainrole.hand[index];  // 獲取手牌中的牌
```

**檔案**: `Naki/Resources/JavaScript/naki-game-api.js:250-264`

### 完整結構

```javascript
{
  // ========== 牌值信息（最重要）==========
  val: {
    type: number,          // ⭐ 牌類: 0=筒(p), 1=萬(m), 2=索(s), 3=字(z)
    index: number,         // ⭐ 牌號: 0-8 (需要 +1 才是顯示的牌號)
    dora: boolean          // ⭐ 是否為紅寶牌 (5mr/5pr/5sr)
  },

  // ========== 位置和狀態 ==========
  index: number,           // 在手中的位置 (0-13)
  isDora: boolean,         // 是否為宝牌（已棄用，用 val.dora 代替）
  ispaopai: boolean,       // 白牌標記 (雪白牌)
  isGap: boolean,          // 間隔標記 (牌之間的空隙)
  is_open: boolean,        // 打開/公開狀態
  valid: boolean,          // 是否有效

  // ========== 效果物件（關鍵）==========
  _doraeffect: Sprite3D,   // ⭐ 宝牌閃光效果物件
  _recommendeffect: Sprite3D,  // ⭐ 推薦高亮效果物件
  _clickeffect: Object,    // 點擊效果物件

  // ========== 3D 渲染相關 ==========
  mySelf: Sprite3D,        // 牌的 3D Sprite 物件
  transform: {
    position: { x, y, z }, // 世界座標
    scale: { x, y, z },
    rotation: { x, y, z, w }
  },

  // ========== 座標和深度 ==========
  pos_x: number,           // UI 中的 X 座標
  z: number,               // Z 深度 (用於排序)

  // ========== 材質 ==========
  origin_mat: Material,    // 原始材質

  // ========== 動畫 ==========
  anim: Animation | null,       // 動畫物件
  anim_start_time: number,      // 動畫開始時間
  anim_life_time: number,       // 動畫持續時間

  // ========== Laya Sprite3D 屬性 ==========
  _destroyed: boolean,
  _id: number,
  _enable: boolean,
  _owner: object,
  _events: object,
  _activeInHierarchy: boolean,

  // ========== 其他 ==========
  bedraged: boolean,
  huansanzhangEnabled: boolean,
  $_GID: string              // 全局 ID
}
```

### 關鍵屬性速查

| 屬性 | 類型 | 範圍 | 說明 |
|------|------|------|------|
| `val.type` | `number` | 0-3 | 0=筒, 1=萬, 2=索, 3=字 |
| `val.index` | `number` | 0-8 | 牌號 (需 +1) |
| `val.dora` | `boolean` | - | 是否紅寶牌 (5mr/5pr/5sr) |
| `index` | `number` | 0-13 | 手中位置 |
| `isDora` | `boolean` | - | 宝牌標記（已棄用） |
| `_doraeffect` | `Sprite3D` | - | 宝牌效果物件 |
| `_recommendeffect` | `Sprite3D` | - | 推薦高亮物件 |
| `pos_x` | `number` | - | UI X 座標 |
| `z` | `number` | - | 渲染深度 |

### 牌物件的完整屬性列表

```javascript
[
  // Laya Sprite3D 基礎
  "_destroyed", "_id", "_enable", "_owner",
  "started", "_events",

  // 自訂屬性
  "mySelf", "bei",
  "acitve", "val", "valid",
  "_clickeffect",

  // 動畫
  "anim", "anim_start_time", "anim_life_time",

  // 牌狀態
  "isDora",              // 宝牌標記
  "ispaopai",            // 白牌標記
  "isGap",               // 間隔標記
  "is_open",             // 打開狀態
  "huansanzhangEnabled",

  // 位置
  "index",               // 在手中的位置
  "pos_x",               // X 座標

  // 效果
  "_recommendeffect",    // 推薦高亮效果
  "_doraeffect",         // 宝牌閃光效果

  // 其他
  "z",                   // Z 深度
  "bedraged",
  "origin_mat",
  "$_GID"
]
```

---

## 牌類型映射 (Type Mapping)

### Majsoul 牌類型編碼

```javascript
// 牌類型映射
const typeMap = {
  'p': 0,   // 筒子 (Pinzu) - Characters
  'm': 1,   // 萬子 (Manzu) - Circles
  's': 2,   // 索子 (Souzu) - Bamboo
  'z': 3    // 字牌 (Jihai) - Honors
};

// 字牌詳細映射
const honorMap = {
  'E': [3, 1],  // 東 (East)
  'S': [3, 2],  // 南 (South)
  'W': [3, 3],  // 西 (West)
  'N': [3, 4],  // 北 (North)
  'P': [3, 5],  // 白 (White Dragon)
  'F': [3, 6],  // 發 (Green Dragon)
  'C': [3, 7]   // 中 (Red Dragon)
};
```

**檔案**: `Naki/ViewModels/WebViewModel.swift:234-235`

### 牌號轉換

#### ⚠️ 重要更正：Index 轉換規則

**原始遊戲數據到人類可讀的牌號:**
- **數字牌 (type 0-2)**: `index 直接 = 牌號` (1-9，不需要 +-1)
- **字牌 (type 3)**: 使用下表映射

```javascript
// 正確的轉換方式（Majsoul 原始數據 → 可讀牌號）

// 數字牌
const typeMap = {
  0: 'p',   // 筒子
  1: 'm',   // 萬子
  2: 's'    // 索子
};

// 字牌映射
const honorMap = {
  0: 'E',   // 東
  1: 'S',   // 南
  2: 'W',   // 西
  3: 'N',   // 北
  4: 'P',   // 白
  5: 'F',   // 發
  6: 'C'    // 中
};

// 示例：原始遊戲數據轉換
const examples = [
  { type: 1, index: 2 } → "2m" (2萬),
  { type: 1, index: 4 } → "4m" (4萬),
  { type: 0, index: 3 } → "3p" (3筒),
  { type: 2, index: 1 } → "1s" (1索),
  { type: 3, index: 3 } → "N"  (北),
  { type: 3, index: 6 } → "C"  (中)
];

// 反向轉換（MJAI 字串到 Majsoul 查詢時使用）
const mjaiString = "5mr";  // 紅五萬
const tileValue = parseInt(mjaiString[0]);     // 5
// ⭐ 更正：index = tileValue（直接等於，不需要 -1）
const majsoulIndex = tileValue;                // 5
```

### 查找牌的正確方式

**檔案**: `Naki/ViewModels/WebViewModel.swift:252-264`

⚠️ **已更正：根據實際遊戲數據，index 直接等於牌號**

```javascript
// ✅ 正確的牌查找邏輯（已更正）
function findTileInHand(tileValue, suitChar, isRed) {
  const typeMap = {'m': 1, 'p': 0, 's': 2};
  const tileType = typeMap[suitChar];
  // ⭐ 更正：index 直接 = tileValue（不需要 -1）
  const tileIndex = tileValue;  // 例：MJAI "2m" → index=2

  const hand = window.view.DesktopMgr.Inst.mainrole.hand;

  for (let i = 0; i < hand.length; i++) {
    const tile = hand[i];
    if (tile && tile.val &&
        tile.val.type === tileType &&
        tile.val.index === tileIndex) {

      // 檢查紅寶牌標記
      if (isRed && tile.val.dora) {
        return i;  // 找到紅寶牌
      } else if (!isRed && !tile.val.dora) {
        return i;  // 找到普通牌
      }
    }
  }

  return -1;  // 未找到
}
```

### ⚠️ 關鍵警告

**千萬不要這樣做**：

```javascript
// ❌ 錯誤：直接使用 Swift tehai 陣列索引
const tileIndex = tehai.findIndex(t => t.val.type === 1);
mr.setChoosePai(mr.hand[tileIndex], true);  // 會點到錯誤的牌！
```

**原因**:
- Swift 的 `tehai` 陣列是 **排序的** (`sort { $0.index < $1.index }`)
- Majsoul 的 UI 顯示牌不是排序的，而是按**視覺順序**
- 陣列索引完全不匹配

---

## 效果物件 (Effect Objects)

### 效果模板對照表

| 模板 | 子節點名稱 | 用途 | 動畫類型 |
|------|-----------|------|----------|
| `effect_dora3D` | "dora" | 其他場景用 | `anim.Bling` |
| `effect_doraPlane` | "effect" | ⭐ **紅寶牌實際使用** | `anim.RunUV` |
| `effect_dora3D_touying` | "dora" | 透明/陰影效果 | `anim.Bling` |

### 動畫類型說明

```javascript
// 兩種動畫類型
anim.Bling   // 透明度閃爍動畫（修改 albedoColor.w）
anim.RunUV   // ⭐ UV 流動動畫（紅寶牌實際使用的效果）
```

### 宝牌效果創建流程 ⭐

**重要發現**: 紅寶牌使用的是 `effect_doraPlane` + `anim.RunUV`，而不是 `effect_dora3D` + `anim.Bling`。

#### 完整創建代碼

```javascript
function createDoraEffect(tile) {
  const mgr = window.view.DesktopMgr.Inst;

  // 1. ⭐ 使用 effect_doraPlane（不是 effect_dora3D）
  const template = mgr.effect_doraPlane;
  const effect = template.clone();

  // 2. ⭐ 掛到牌的 mySelf 上（不是 "effect" 容器）
  tile.mySelf.addChild(effect);

  // 3. 設置位置和縮放（相對於牌的本地座標）
  effect.transform.localPosition = new Laya.Vector3(0, 0, 0);
  effect.transform.localScale = new Laya.Vector3(1, 1, 1);

  // 4. 啟用效果
  effect.active = true;

  // 5. ⭐ 添加 RunUV 動畫（不是 Bling）
  effect.getChildAt(0).addComponent(anim.RunUV);

  // 6. 保存引用以便後續清除
  tile._doraeffect = effect;

  return effect;
}

// 使用示例
const hand = window.view.DesktopMgr.Inst.mainrole.hand;
const tile = hand[0];  // 第一張牌
createDoraEffect(tile);
```

#### 清除效果

```javascript
function removeDoraEffect(tile) {
  if (tile._doraeffect) {
    tile._doraeffect.destroy();
    tile._doraeffect = null;
  }
}
```

#### 反轉動畫方向

使用 `scale.x = -1` 可以翻轉 RunUV 動畫的播放方向：

```javascript
function createReversedDoraEffect(tile) {
  const mgr = window.view.DesktopMgr.Inst;

  // 1. Clone effect_doraPlane
  const effect = mgr.effect_doraPlane.clone();

  // 2. 掛到牌上
  tile.mySelf.addChild(effect);

  // 3. 設置位置
  effect.transform.localPosition = new Laya.Vector3(0, 0, 0);

  // 4. ⭐ 用負 scale 翻轉動畫方向
  effect.transform.localScale = new Laya.Vector3(-1, 1, 1);

  // 5. 啟用
  effect.active = true;

  // 6. 添加 RunUV 動畫
  effect.getChildAt(0).addComponent(anim.RunUV);

  return effect;
}
```

**注意**: 直接修改 `runUV.v` 或 `runUV.__v` 無效，因為 RunUV 內部使用共享的閉包變數。

#### 調整效果顏色

透過修改材質的 `albedoColor` 可以改變效果顏色：

```javascript
function setDoraEffectColor(runUV, r, g, b, a) {
  var color = runUV.mat.albedoColor;
  color.x = r;  // 紅
  color.y = g;  // 綠
  color.z = b;  // 藍
  color.w = a;  // 透明度/亮度
  runUV.mat.albedoColor = color;
}

// 常用顏色 (值 > 1 會更亮，原始值為 2)
setDoraEffectColor(runUV, 2, 2, 2, 2);  // 白色（原始）
setDoraEffectColor(runUV, 2, 0, 0, 2);  // 紅色
setDoraEffectColor(runUV, 0, 2, 0, 2);  // 綠色
setDoraEffectColor(runUV, 0, 0, 2, 2);  // 藍色
setDoraEffectColor(runUV, 2, 2, 0, 2);  // 黃色
setDoraEffectColor(runUV, 2, 0, 2, 2);  // 紫色
setDoraEffectColor(runUV, 0, 2, 2, 2);  // 青色
```

#### 完整的自定義效果示例

```javascript
function createCustomDoraEffect(tile, options) {
  const mgr = window.view.DesktopMgr.Inst;
  const defaults = {
    reverse: false,
    color: { r: 2, g: 2, b: 2, a: 2 }
  };
  const opts = Object.assign({}, defaults, options);

  // 創建效果
  const effect = mgr.effect_doraPlane.clone();
  tile.mySelf.addChild(effect);
  effect.transform.localPosition = new Laya.Vector3(0, 0, 0);

  // 設置方向
  const scaleX = opts.reverse ? -1 : 1;
  effect.transform.localScale = new Laya.Vector3(scaleX, 1, 1);

  effect.active = true;

  // 添加動畫
  const runUV = effect.getChildAt(0).addComponent(anim.RunUV);

  // 設置顏色
  const color = runUV.mat.albedoColor;
  color.x = opts.color.r;
  color.y = opts.color.g;
  color.z = opts.color.b;
  color.w = opts.color.a;
  runUV.mat.albedoColor = color;

  return { effect, runUV };
}

// 使用示例
const tile = window.view.DesktopMgr.Inst.mainrole.hand[0];

// 創建反向紅色效果
createCustomDoraEffect(tile, {
  reverse: true,
  color: { r: 2, g: 0, b: 0, a: 2 }
});
```

### 雙層旋轉 Bling 效果 ⭐

Naki 推薦高亮使用的是雙層旋轉 Bling 效果，比單層 RunUV 更醒目。

#### 效果特點

- **雙層疊加**: 90° 和 180° 兩層效果疊加
- **持續旋轉**: 每 30ms 旋轉 3 度
- **Bling 閃爍**: tick=300 快速閃爍
- **顏色區分**: 綠色 (>50%) / 紅色 (20-50%)

#### 完整實現代碼

```javascript
function createDualRotatingEffect(tile, color) {
  const mgr = window.view.DesktopMgr.Inst;
  const effects = [];
  const blings = [];

  // 創建兩層效果 (90° 和 180°)
  [90, 180].forEach(rotation => {
    const effect = mgr.effect_doraPlane.clone();
    tile.mySelf.addChild(effect);

    effect.transform.localPosition = new Laya.Vector3(0, 0, 0);
    effect.transform.localRotationEuler = new Laya.Vector3(0, 0, rotation);
    effect.transform.localScale = new Laya.Vector3(1, 1, 1);
    effect.active = true;

    // 添加 Bling 動畫（比 RunUV 更容易控制速度）
    const child = effect.getChildAt(0);
    const bling = child.addComponent(anim.Bling);
    bling.tick = 300;  // 快速閃爍

    // 設置顏色
    if (color && bling.mat) {
      const c = bling.mat.albedoColor;
      c.x = color.r;
      c.y = color.g;
      c.z = color.b;
      c.w = color.a;
      bling.mat.albedoColor = c;
    }

    effects.push(effect);
    blings.push(bling);
  });

  return { effects, blings };
}

// 啟動旋轉動畫
function startRotation(effects) {
  return setInterval(() => {
    effects.forEach(effect => {
      if (effect && effect.transform) {
        const z = effect.transform.localRotationEuler.z + 3;
        effect.transform.localRotationEuler = new Laya.Vector3(0, 0, z);
      }
    });
  }, 30);
}

// 使用示例
const tile = window.view.DesktopMgr.Inst.mainrole.hand[0];
const { effects, blings } = createDualRotatingEffect(tile, { r: 0, g: 2, b: 0, a: 2 });
const intervalId = startRotation(effects);

// 清除
// clearInterval(intervalId);
// effects.forEach(e => e.destroy());
```

#### 顏色配置

```javascript
const colors = {
  green: { r: 0, g: 2, b: 0, a: 2 },  // 高機率推薦 (>50%)
  red:   { r: 2, g: 0, b: 0, a: 2 }   // 中機率推薦 (20-50%)
};
```

### ⚠️ 常見錯誤

| 錯誤做法 | 正確做法 | 結果 |
|---------|---------|------|
| 使用 `effect_dora3D` | 使用 `effect_doraPlane` | 子節點結構不同 |
| 使用 `anim.Bling` | 使用 `anim.RunUV` | 動畫效果不同 |
| 掛到 "effect" 容器 | 掛到 `tile.mySelf` | 位置會錯誤 |
| 設置世界座標 | 設置本地座標 (0,0,0) | 效果會消失 |

### 宝牌閃光效果模板

#### 訪問路徑

```javascript
window.view.DesktopMgr.Inst.effect_dora3D      // 3D 效果
window.view.DesktopMgr.Inst.effect_doraPlane   // ⭐ 平面效果（紅寶牌用）
window.view.DesktopMgr.Inst.effect_dora3D_touying  // 陰影效果
```

#### 屬性

```javascript
{
  name: "effect_dora",
  visible: boolean,                  // 是否可見
  active: boolean,                   // 是否激活
  _activeInHierarchy: boolean,       // 在層級中的激活狀態
  alpha: number,                     // 透明度 (0-1)
  parent: Sprite3D,                  // 父節點
  numChildren: number,               // 子節點數量
  // ... 其他 Laya Sprite3D 屬性
}
```

#### 檢查效果結構

```javascript
// 檢查紅寶牌的實際效果結構
const hand = window.view.DesktopMgr.Inst.mainrole.hand;
const redDora = hand.find(t => t.val && t.val.dora);

if (redDora && redDora._doraeffect) {
  const effect = redDora._doraeffect;
  console.log({
    effectName: effect.name,
    childName: effect.getChildAt(0).name,  // 應該是 "effect"
    parentName: effect.parent.name,         // 應該是 "pai"
    animationType: effect.getChildAt(0)._components[0] instanceof anim.RunUV
      ? "RunUV" : "Bling"
  });
}
```

## 宝牌指示牌 (Dora Indicators)

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

### 使用示例

```javascript
// 獲取第一個宝牌指示牌
const firstDora = window.view.DesktopMgr.Inst.dora[0];
console.log(`宝牌: ${firstDora.type}-${firstDora.index}`);

// Majsoul 類型轉 MJAI
const doraType = ['p', 'm', 's', 'z'][firstDora.type];
const doraMjai = `${firstDora.index + 1}${doraType}`;
```

---

## 操作類型 (Operation Types)

### 操作編碼表

**檔案**: `Naki/Resources/JavaScript/naki-game-api.js:212-223`

```javascript
const opNames = {
  0: 'none',      // 無操作
  1: 'dapai',     // 打牌（棄牌）
  2: 'chi',       // 吃 (チー)
  3: 'pon',       // 碰 (ポン)
  4: 'ankan',     // 暗槓 (暗カン)
  5: 'minkan',    // 明槓 (明カン)
  6: 'kakan',     // 加槓 (加カン)
  7: 'riichi',    // 立直 (リーチ)
  8: 'tsumo',     // 自摸/和牌 (ツモ)
  9: 'ron',       // 榮和/他家和 (ロン)
  10: 'kyushu',   // 九種九牌 (九種九牌)
  11: 'babei'     // 流局 (流局)
};
```

### 訪問操作列表

```javascript
const oplist = window.view.DesktopMgr.Inst.oplist;
// [{ name: 'dapai', index: 0 }, { name: 'riichi', index: 1 }, ...]
```

---

## Laya Sprite3D 屬性

Majsoul 使用 **Laya 3D 引擎**，所有效果物件都是 `Sprite3D` 類型。

### 常用 Sprite3D 屬性

```javascript
{
  // 基本屬性
  name: string,                  // 物件名稱
  active: boolean,               // 是否激活
  visible: boolean,              // 是否可見

  // 變換
  transform: {
    position: { x, y, z },       // 位置
    rotation: { x, y, z, w },    // 旋轉 (四元數)
    scale: { x, y, z }           // 縮放
  },

  // 層級
  parent: Sprite3D,              // 父物件
  _childs: [Sprite3D],           // 子物件陣列

  // 渲染
  meshRender: MeshRender,        // 網格渲染器
  layer: number,                 // 層級

  // 物理
  rigidbody3D: Rigidbody3D,      // 剛體（如有）

  // 內部
  _id: number,
  _owner: Object,
  _enable: boolean,
  _destroyed: boolean,
  _activeInHierarchy: boolean,
  _events: Object
}
```

### 常用方法

```javascript
// 激活/停用
sprite.active = true;
sprite.active = false;

// 顯示/隱藏
sprite.visible = true;
sprite.visible = false;

// 獲取位置
const pos = sprite.transform.position;

// 設定位置
sprite.transform.position = new Laya.Vector3(x, y, z);

// 子物件操作
const child = sprite.getChildByName("name");
sprite.addChild(childSprite);
sprite.removeChild(childSprite);
```

---

## Naki JavaScript 模組

### naki-game-api.js

**檔案**: `Naki/Resources/JavaScript/naki-game-api.js`
**行數**: 897
**用途**: 遊戲狀態查詢和直接 API 調用

#### 匯出的全域物件

```javascript
window.__nakiGameAPI = {
  getGameState(): Object,           // 獲取完整遊戲狀態
  getHandTiles(): Tile[],           // 獲取手牌陣列
  getDora(): Object[],              // 獲取宝牌指示牌
  getOperations(): Object[],        // 獲取可用操作
  // ... 更多方法
}

window.__nakiDoraHook = {
  hook(): boolean,                  // 攔截宝牌效果變更
  getHistory(): Object              // 獲取攔截歷史
}

window.__nakiRecommendHighlight = {
  show(tileIndex): boolean,         // 顯示推薦高亮
  hide(): boolean,                  // 隱藏推薦高亮
  getStatus(): Object               // 獲取狀態
}
```

---

## 完整流程示例

### 1. 獲取遊戲信息

```javascript
const inst = window.view.DesktopMgr.Inst;
const hand = inst.mainrole.hand;
const dora = inst.dora;
const oplist = inst.oplist;

console.log(`手牌數: ${hand.length}`);
console.log(`宝牌: ${dora[0].type}-${dora[0].index}`);
console.log(`可用操作: ${oplist.map(op => op.name).join(', ')}`);
```

### 2. 查找並選擇牌

```javascript
// 找出要打的牌 (5萬)
const targetTile = hand.find(t =>
  t.val.type === 1 && t.val.index === 4 && !t.val.dora
);

if (targetTile) {
  // 選擇牌
  inst.mainrole.setChoosePai(targetTile, true);

  // 執行打牌操作
  inst.mainrole.DoDiscardTile();
}
```

### 3. 顯示推薦高亮

```javascript
// 推薦打第 3 張牌
const recommendedIndex = 3;

// 顯示高亮
window.__nakiRecommendHighlight.show(recommendedIndex);

// 延遲後隱藏
setTimeout(() => {
  window.__nakiRecommendHighlight.hide();
}, 2000);
```

### 4. 監控宝牌變更

```javascript
// 啟動宝牌攔截
window.__nakiDoraHook.hook();

// 獲取歷史
const history = window.__nakiDoraHook.getHistory();
console.log(`宝牌變更歷史: ${history.count} 次`);
```

---

## 動作按鈕 UI (UI_ChiPengHu)

### 訪問路徑

```javascript
window.uiscript.UI_ChiPengHu.Inst
```

**用途**: 吃/碰/槓/過等動作按鈕的 UI 容器

### 結構

```javascript
{
  container_btns: {
    x: 812,                    // 容器 X 位置
    y: 821,                    // 容器 Y 位置
    numChildren: 15,           // 子按鈕數量
    // 子按鈕...
  },

  // 直接訪問按鈕
  btn_chi: Button,             // 吃按鈕 (索引 4)
  btn_peng: Button,            // 碰按鈕 (索引 5)
  btn_gang: Button,            // 槓按鈕 (索引 6)
  btn_lizhi: Button,           // 立直按鈕 (索引 7)
  btn_hu: Button,              // 和/榮和按鈕 (索引 8)
  btn_zimo: Button,            // 自摸按鈕 (索引 10)
  btn_cancel: Button,          // 過/取消按鈕 (索引 14)
  btn_jiuzhongjiupai: Button,  // 九種九牌 (索引 2)
  btn_babei: Button,           // 流局 (索引 3)
  btn_anpai: Button,           // 暗牌 (索引 9)
  btn_kaipai: Button,          // 開牌 (索引 11)
  btn_suoding: Button,         // 鎖定 (索引 12)
  btn_anpailiqi: Button,       // 暗牌立直 (索引 13)
  btn_liqi10: Button,          // 立直 10 (索引 0)
  btn_liqi5: Button,           // 立直 5 (索引 1)
}
```

### 按鈕結構

```javascript
// 單一按鈕屬性
{
  name: string,        // 按鈕名稱，如 "btn_chi"
  x: number,           // 相對於容器的 X 位置
  y: number,           // 相對於容器的 Y 位置
  width: number,       // 按鈕寬度（通常 384）
  height: number,      // 按鈕高度
  visible: boolean,    // 是否可見
  _selected: boolean   // 是否被選中
}
```

### 按鈕索引表

| 索引 | 名稱 | 用途 |
|-----|------|------|
| 0 | btn_liqi10 | 立直 10 |
| 1 | btn_liqi5 | 立直 5 |
| 2 | btn_jiuzhongjiupai | 九種九牌 |
| 3 | btn_babei | 流局 |
| 4 | btn_chi | 吃 |
| 5 | btn_peng | 碰 |
| 6 | btn_gang | 槓 |
| 7 | btn_lizhi | 立直 |
| 8 | btn_hu | 和/榮和 |
| 9 | btn_anpai | 暗牌 |
| 10 | btn_zimo | 自摸 |
| 11 | btn_kaipai | 開牌 |
| 12 | btn_suoding | 鎖定 |
| 13 | btn_anpailiqi | 暗牌立直 |
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

console.log("可見按鈕:", visibleBtns);
```

### 按鈕 3D 效果座標映射

將 `effect_recommend` 移動到按鈕位置的座標映射：

| 按鈕位置（從右到左） | UI center_x | 3D x | 3D y | 3D z |
|---------------------|-------------|------|------|------|
| 第1個（過，最右） | 1719 | 27.5 | 4.5 | -0.52 |
| 第2個 | 1335 | 20.5 | 4.5 | -0.52 |
| 第3個 | - | 13.5 | 4.5 | -0.52 |

**計算公式**:
```javascript
// 按鈕索引從右到左排列（0 = 最右邊）
var posX = 27.5 - (btnIndex * 7);
var posY = 4.5;
var posZ = -0.52;
```

### 移動效果到按鈕位置

```javascript
function moveEffectToButton(actionType) {
    var mgr = view.DesktopMgr.Inst;
    var ui = uiscript.UI_ChiPengHu.Inst;
    var container = ui.container_btns;

    // 按鈕名稱映射（支援的動作類型）
    var btnNameMap = {
        'chi': 'btn_chi',
        'pon': 'btn_peng',
        'kan': 'btn_gang',
        'hora': 'btn_hu',
        'riichi': 'btn_lizhi',
        'pass': 'btn_cancel'
    };

    var targetBtnName = btnNameMap[actionType];

    // 獲取可見按鈕並排序
    var visibleBtns = [];
    for (var i = 0; i < container.numChildren; i++) {
        var btn = container.getChildAt(i);
        if (btn.visible) {
            visibleBtns.push({
                name: btn.name,
                center_x: container.x + btn.x + btn.width / 2
            });
        }
    }
    visibleBtns.sort(function(a, b) { return b.center_x - a.center_x; });

    // 找到目標按鈕索引
    var btnIndex = -1;
    for (var i = 0; i < visibleBtns.length; i++) {
        if (visibleBtns[i].name === targetBtnName) {
            btnIndex = i;
            break;
        }
    }

    if (btnIndex === -1) return false;

    // 計算 3D 位置
    var posX = 27.5 - (btnIndex * 7);
    var effect = mgr.effect_recommend;
    var child = effect._childs[0];

    child.transform.localPosition = new Laya.Vector3(posX, 4.5, -0.52);
    effect.active = true;

    return true;
}
```

---

## 大廳 UI (Lobby UI)

### 訪問路徑

```javascript
window.GameMgr.Inst                    // 遊戲管理器
window.GameMgr.Inst.uimgr              // UI 管理器
window.GameMgr.Inst.uimgr._ui_lobby    // 大廳 UI
```

### 核心結構

```javascript
GameMgr.Inst.uimgr
├── _root                              // 根容器
├── _lobby_root                        // 大廳根容器
├── _mj_root                           // 麻將桌根容器
├── _ui_lobby (主大廳 UI)
│   ├── nowpage: number                // 當前頁面索引 (0=主頁, 1=段位場, ...)
│   ├── locking: boolean               // 是否鎖定
│   ├── page0 (主頁面)
│   │   ├── btn_dajiangsai             // 大將賽按鈕
│   │   ├── btn_yibanchang             // 段位場按鈕 (x:1183, y:368, w:543, h:190)
│   │   └── btn_yourenfang             // 友人房按鈕
│   ├── page_rank (段位場頁面)
│   │   ├── me                         // 頁面容器
│   │   ├── p0                         // 內容區域
│   │   └── content0                   // 滾動內容
│   ├── page_friend (好友頁面)
│   ├── page_match (比賽頁面)
│   │   ├── btns[0-4]                  // 比賽分類按鈕
│   │   └── content                    // 比賽列表
│   └── page_east_north (東北場?)
├── _ui_waitingroom (等待房間 UI)
│   ├── btnPrepare                     // 準備按鈕
│   ├── btnStart                       // 開始按鈕
│   ├── btnCancel                      // 取消按鈕
│   ├── room_id                        // 房間 ID
│   └── playerSeats                    // 玩家座位
└── _uis[105] (匹配 UI - ⭐關鍵)
    ├── addMatch(match_mode)           // 開始匹配
    ├── cancelPiPei()                  // 取消匹配
    ├── current_count                  // 當前匹配數量
    ├── cells                          // 匹配項目列表
    └── inopen                         // 是否已展開
```

### 遊戲狀態屬性

```javascript
GameMgr.Inst
├── account_id: number                 // 帳戶 ID
├── player_name: string                // 玩家名稱
├── logined: boolean                   // 是否已登入
├── ingame: boolean                    // 是否在遊戲中
├── in_shilian: boolean                // 是否在試煉中
├── in_ab_match: boolean               // 是否在 AB 賽中
├── in_kuangdu: boolean                // 是否在狂賭模式
├── in_activity_mode: number           // 活動模式
├── custom_match_id: number            // 自定義比賽 ID
├── beinvited_roomid: number           // 被邀請的房間 ID
├── _current_scene: string             // 當前場景
├── _scene_lobby                       // 大廳場景
└── _scene_mj                          // 麻將場景
```

### 匹配模式 ID 對照表

| ID | 房間 | 模式 | 段位限制 | 描述 |
|---|---|---|---|---|
| 1 | 銅之間 | 0 | 10101-10203 | 四麻東風 |
| 2 | 銅之間 | 1 | 10101-10203 | 四麻半莊 |
| 3 | 銅之間 | 2 | 10101-10203 | 四麻 |
| 4 | 銀之間 | 0 | 10201-10303 | 四麻東風 |
| 5 | 銀之間 | 1 | 10201-10303 | 四麻半莊 |
| 6-8 | 金之間 | 0-2 | 10301-10403 | 四麻 |
| 9-11 | 玉之間 | 0-2 | 10401-10503 | 四麻 |
| 14-15 | 王座間 | - | 10501-10720 | 四麻 |
| 17-18 | 銅之間 | 11-12 | 20101-20203 | 三麻 |
| 19-20 | 銀之間 | 11-12 | 20201-20303 | 三麻 |
| 26-29 | 休閒場 | - | - | 休閒普通場 |
| 30 | 寶牌狂熱 | - | - | 特殊模式 |

**段位編碼規則**:
- `10xxx` = 四麻段位, `20xxx` = 三麻段位
- 第二位: 1=雀士, 2=雀傑, 3=雀豪, 4=雀聖, 5=魂天
- 第三位: 等級 (01-03)
- 第四位: 星數 (1-3)

### 自動開始遊戲完整流程

#### 步驟 1: 切換到段位場頁面

```javascript
var lobby = window.GameMgr.Inst.uimgr._ui_lobby;
lobby.setPage(1);  // 切換到段位場

// 驗證
console.log(lobby.nowpage);  // 應該是 1
console.log(lobby.page_rank.me.visible);  // 應該是 true
```

#### 步驟 2: 開始匹配 (⭐關鍵 API)

```javascript
var matchUI = window.GameMgr.Inst.uimgr._uis[105];

// 開始匹配 - 傳入 match_mode ID
matchUI.addMatch(4);  // 銀之間東風

// 驗證匹配狀態
console.log(matchUI.current_count);  // 應該 >= 1
console.log(matchUI.inopen);         // 應該是 true
console.log(matchUI.cells[0].match_id);  // 應該是 4
```

#### 步驟 3: 取消匹配

```javascript
var matchUI = window.GameMgr.Inst.uimgr._uis[105];
matchUI.cancelPiPei();

// 驗證
console.log(matchUI.current_count);  // 應該是 0
```

#### 步驟 4: 模擬按鈕點擊 (替代方案)

```javascript
// 模擬點擊段位場按鈕
var btn = window.GameMgr.Inst.uimgr._ui_lobby.page0.btn_yibanchang;
var fakeEvent = new Laya.Event();
fakeEvent.type = 'click';
fakeEvent.target = btn;
btn.event('click', fakeEvent);
```

### 網絡 API 參考

#### Protobuf 服務方法

```javascript
// 通過 sendReq2Lobby 調用
app.NetAgent.sendReq2Lobby(action, method, data, callback);

// 匹配相關
'matchGame'              // 開始匹配 (ReqJoinMatchQueue)
'cancelMatch'            // 取消匹配
'startUnifiedMatch'      // 統一匹配開始 (ReqStartUnifiedMatch)
'cancelUnifiedMatch'     // 統一匹配取消

// 查詢相關
'fetchCurrentMatchInfo'  // 當前匹配信息
'fetchGamingInfo'        // 遊戲進行中信息
'fetchAccountInfo'       // 帳戶信息 (含段位)
'fetchQueueInfo'         // 隊列信息

// 房間相關
'fetchRoom'              // 獲取房間
'createRoom'             // 創建房間
'joinRoom'               // 加入房間
'leaveRoom'              // 離開房間
'readyPlay'              // 準備
'startRoom'              // 開始房間
```

#### 請求結構

```javascript
// ReqJoinMatchQueue (matchGame)
{
  match_mode: number,           // 匹配模式 ID
  client_version_string: string // 客戶端版本 (可選)
}

// ReqStartUnifiedMatch (startUnifiedMatch)
{
  match_sid: string,            // 匹配 Session ID
  client_version_string: string // 客戶端版本 (可選)
}
```

#### 錯誤碼參考

| 錯誤碼 | 含義 |
|-------|------|
| 2 | 通用錯誤 |
| 157 | 隊列信息不可用 |
| 1302 | 未在匹配中 |
| 1306 | 匹配失敗 (段位不符或其他限制) |

### 帳戶段位查詢

```javascript
// 獲取帳戶信息
app.NetAgent.sendReq2Lobby('Lobby', 'fetchAccountInfo', {
    account_id: window.GameMgr.Inst.account_id
}, function(err, res) {
    if (res && res.account) {
        console.log('四麻段位:', res.account.level.id);   // 如 10202
        console.log('三麻段位:', res.account.level3.id);  // 如 20101
        console.log('四麻分數:', res.account.level.score);
    }
});

// 段位 ID 解析
// 10202 = 四麻 雀士二 2星
// 第1位: 1=四麻, 2=三麻
// 第2位: 段位 (0=初心, 1=雀士, 2=雀傑, 3=雀豪, 4=雀聖, 5=魂天)
// 第3-4位: 等級和星數
```

### 匹配配置查詢

```javascript
// 獲取匹配模式配置
var matchmode = window.cfg.desktop.matchmode;

matchmode.forEach(function(mode, id) {
    console.log({
        id: id,
        room: mode.room,
        room_name: mode.room_name_chs,
        level_limit: mode.level_limit,      // 段位下限
        level_limit_ceil: mode.level_limit_ceil,  // 段位上限
        is_open: mode.is_open
    });
});
```

### 完整自動開始遊戲示例

```javascript
(function() {
    var gm = window.GameMgr.Inst;
    var uimgr = gm.uimgr;
    var lobby = uimgr._ui_lobby;
    var matchUI = uimgr._uis[105];

    // 1. 檢查是否已登入且不在遊戲中
    if (!gm.logined) {
        console.error('未登入');
        return;
    }
    if (gm.ingame) {
        console.error('已在遊戲中');
        return;
    }

    // 2. 切換到段位場頁面
    if (lobby.nowpage !== 1) {
        lobby.setPage(1);
    }

    // 3. 等待頁面切換完成後開始匹配
    setTimeout(function() {
        // 銀之間東風 (match_mode = 4)
        var result = matchUI.addMatch(4);

        if (result) {
            console.log('✅ 開始匹配成功');
            console.log('匹配數量:', matchUI.current_count);
        } else {
            console.error('❌ 匹配失敗');
        }
    }, 500);
})();
```

---

## 閒置檢測與心跳機制 (Idle Detection & Heartbeat)

### ⚠️ 重要：兩種不同的閒置機制

Majsoul 有**兩種獨立**的閒置機制，不要混淆：

| 機制 | 觸發場景 | 閾值 | 結果 | 解決方法 |
|------|---------|------|------|---------|
| **大廳閒置登出** | 在大廳/牌局外長時間無動作 | 50 分鐘 | 強制登出 | `clientHeatBeat()` |
| **遊戲中操作超時** | 在牌局中輪到你時不操作 | 依房間設定 | 自動出牌/跳過 | 無法客戶端阻止（伺服器控制）|

### 機制 1：大廳閒置登出

這是**客戶端**檢測的閒置機制，可以透過心跳重置。

| 項目 | 值 | 說明 |
|------|-----|------|
| **心跳函數** | `GameMgr.Inst.clientHeatBeat()` | 重置閒置計時器 |
| **上次心跳時間** | `GameMgr.Inst._last_heatbeat_time` | Unix 時間戳 (ms) |
| **閒置檢測間隔** | 360 秒 (6 分鐘) | Laya.timer 定時器 |
| **警告閾值** | 3000 秒 (50 分鐘) | 顯示 `UI_Hangup_Warn` |
| **強制登出** | 警告後繼續閒置 | 顯示 `UI_Hanguplogout` |

### 機制 2：遊戲中操作超時（自動出牌）

這是**伺服器端**控制的超時機制，客戶端**無法阻止**。

當輪到玩家操作但超過時限時：
1. 伺服器發送超時通知
2. 客戶端執行 `DesktopMgr.Inst.OperationTimeOut()` 或 `_PendingAuto()`
3. 自動執行預設動作（通常是 pass 或摸切）

```javascript
// OperationTimeOut 的邏輯（反混淆後）：
// 1. 如果有榮和選項 → 自動榮和
// 2. 如果有自摸選項 → 自動自摸
// 3. 如果有打牌選項 → 自動打牌（通常是摸切）
// 4. 否則 → pass
```

**注意**：這個超時由伺服器控制，無法透過客戶端心跳阻止。要避免自動出牌，需要在時限內做出操作。

### 訪問路徑

```javascript
// 心跳相關
window.GameMgr.Inst._last_heatbeat_time    // 上次心跳時間
window.GameMgr.Inst.clientHeatBeat()       // 發送心跳
window.GameMgr.Inst.sendLoginBeat()        // 登入心跳

// 閒置警告 UI
window.uiscript.UI_Hangup_Warn.Inst        // 閒置警告彈窗
window.uiscript.UI_Hanguplogout.Inst       // 強制登出彈窗
```

### 手動發送心跳

```javascript
// 發送心跳並驗證
var inst = window.GameMgr.Inst;
var before = inst._last_heatbeat_time;
inst.clientHeatBeat();
var after = inst._last_heatbeat_time;

console.log({
    updated: before !== after,
    previousTime: new Date(before).toISOString(),
    currentTime: new Date(after).toISOString()
});
```

### 檢查閒置狀態

```javascript
(function() {
    var inst = window.GameMgr.Inst;
    var now = Date.now();
    var lastHeartbeat = inst._last_heatbeat_time;
    var idleSeconds = Math.floor((now - lastHeartbeat) / 1000);
    var warnThreshold = 3000;  // 50 分鐘

    return {
        idleSeconds: idleSeconds,
        idleMinutes: Math.floor(idleSeconds / 60),
        timeUntilWarn: Math.max(0, warnThreshold - idleSeconds),
        recommendation: idleSeconds > 2400 ? "建議立即發送心跳" : "狀態正常"
    };
})()
```

### 使用 MCP 工具

```
# 發送心跳
mcp__naki__lobby_heartbeat

# 檢查閒置狀態
mcp__naki__lobby_idle_status
```

### 定時器結構 (Laya.timer)

遊戲使用 Laya 引擎的定時器系統：

```javascript
// 查看所有定時器
var timer = window.Laya.timer;
var handlers = timer._handlers;

// 過濾特定間隔的定時器
handlers.filter(h => h && h.delay === 360000);  // 6 分鐘
handlers.filter(h => h && h.delay === 60000);   // 1 分鐘
```

### 閒置檢測源碼分析

360 秒定時器中的關鍵邏輯（反混淆後）：

```javascript
function checkIdle() {
    if (game.LobbyNetMgr.Inst.isOK) {
        // 向伺服器請求時間同步
        app.NetAgent.sendReq2Lobby('Lobby', 'serverTime', {}, function(err, res) {
            if (!err && res.now) {
                serverTimeDelta = 1000 * res.now - Laya.timer.currTimer;
            }
        });

        // 計算閒置時間
        var idleSeconds = (Laya.timer.currTimer - lastActiveTime) / 1000;

        // 超過 3000 秒 (50 分鐘) 顯示警告
        if (idleSeconds >= 3000) {
            uiscript.UI_Hangup_Warn.Inst.show();
        }
    }
}
```

---

## 如何查找遊戲 UI 元素（逆向工程流程）

本節記錄如何通過探索找到遊戲內部的 UI 元素和 API，以閒置檢測機制的發現過程為例。

### 流程概述

```
1. 確定目標功能
   ↓
2. 搜尋相關關鍵字
   ↓
3. 追蹤物件引用
   ↓
4. 分析定時器和回調
   ↓
5. 驗證和測試
```

### 步驟 1: 確定目標功能

**目標**: 找到遊戲中的閒置檢測機制，因為過一段時間會被自動登出。

**思路**:
- 登出時會有彈窗，可以搜尋相關的 UI
- 可能有 "idle"、"timeout"、"logout"、"heartbeat" 等關鍵字

### 步驟 2: 搜尋相關關鍵字

#### 在 GameMgr 中搜尋

```javascript
// 搜尋心跳/超時相關屬性
var inst = window.GameMgr.Inst;
var allKeys = Object.keys(inst);

var timeRelated = allKeys.filter(k =>
    k.toLowerCase().includes('time') ||
    k.toLowerCase().includes('heart') ||
    k.toLowerCase().includes('timeout') ||
    k.toLowerCase().includes('idle')
);

console.log(timeRelated);
// 結果: ["_last_heatbeat_time", "account_refresh_time", ...]
```

#### 在 uiscript 中搜尋對話框

```javascript
// 搜尋登出/警告相關的 UI
var uiscript = window.uiscript;
var dialogKeys = Object.keys(uiscript).filter(k =>
    k.toLowerCase().includes('logout') ||
    k.toLowerCase().includes('hangup') ||
    k.toLowerCase().includes('disconnect') ||
    k.toLowerCase().includes('idle')
);

console.log(dialogKeys);
// 結果: ["UI_Hangup_Warn", "UI_Hanguplogout", "UI_Disconnect", ...]
```

### 步驟 3: 追蹤物件引用

#### 查看 GameMgr 原型上的方法

```javascript
var proto = Object.getPrototypeOf(window.GameMgr.Inst);
var methods = Object.getOwnPropertyNames(proto);

var heartbeatMethods = methods.filter(k =>
    k.toLowerCase().includes('heart') ||
    k.toLowerCase().includes('beat')
);

console.log(heartbeatMethods);
// 結果: ["clientHeatBeat", "sendLoginBeat"]
```

#### 測試找到的函數

```javascript
// 測試 clientHeatBeat 是否能更新時間
var inst = window.GameMgr.Inst;
var before = inst._last_heatbeat_time;
inst.clientHeatBeat();
var after = inst._last_heatbeat_time;

console.log({
    before: before,
    after: after,
    changed: before !== after  // true = 函數有效
});
```

### 步驟 4: 分析定時器和回調

#### 查看 Laya 定時器

```javascript
// 獲取所有重複執行的定時器
var timer = window.Laya.timer;
var handlers = timer._handlers || [];

// 統計不同間隔的定時器數量
var delays = {};
for (var i = 0; i < handlers.length; i++) {
    var h = handlers[i];
    if (h && h.repeat) {
        var d = h.delay;
        if (!delays[d]) delays[d] = 0;
        delays[d]++;
    }
}

console.log(delays);
// 結果: {1: 26, 500: 13, 1000: 2, 15000: 1, 60000: 2, 180000: 1, 360000: 1}
```

#### 查看特定間隔的定時器內容

```javascript
// 查看 360 秒 (6 分鐘) 定時器
var handler = handlers.find(h => h && h.delay === 360000);

if (handler) {
    console.log({
        delay: handler.delay,
        repeat: handler.repeat,
        method: handler.method.toString().substring(0, 500)
    });
}
```

#### 分析混淆代碼

360 秒定時器的混淆代碼：

```javascript
function(){
    if(game[$E[3874]].Inst.isOK){
        app[$g[296]][$B[300]]($I[339],$E[10982],{},function(P,q){
            P||q[$E[54]]||(h[$6[4172]]=1000*q[$I[11006]]-Laya[$M[51]][$B[550]]);
        });
        var P=(Laya[$I[51]][$3[550]]-h[$g[10948]])/1000;
        P>=3000 && uiscript[$3[7842]].Inst.show();
    }
}
```

**關鍵發現**:
- `P >= 3000` → 3000 秒 (50 分鐘) 閾值
- `uiscript[$3[7842]].Inst.show()` → 顯示某個 UI（警告彈窗）

### 步驟 5: 驗證和測試

#### 確認 UI 組件

```javascript
// 檢查找到的 UI 是否存在
var hangupWarn = window.uiscript.UI_Hangup_Warn;
var hangupLogout = window.uiscript.UI_Hanguplogout;

console.log({
    warnExists: !!hangupWarn,
    logoutExists: !!hangupLogout,
    warnMethods: hangupWarn.prototype ? Object.getOwnPropertyNames(hangupWarn.prototype) : [],
    logoutMethods: hangupLogout.prototype ? Object.getOwnPropertyNames(hangupLogout.prototype) : []
});
// 結果: warnMethods: ["constructor", "onCreate", "show", "close"]
```

#### 測試完整流程

```javascript
// 驗證心跳機制
var inst = window.GameMgr.Inst;
var now = Date.now();
var lastHeartbeat = inst._last_heatbeat_time;
var idleSeconds = Math.floor((now - lastHeartbeat) / 1000);

console.log({
    idleSeconds: idleSeconds,
    idleMinutes: Math.floor(idleSeconds / 60),
    warnAt: 3000,  // 50 分鐘
    willWarnIn: Math.max(0, 3000 - idleSeconds) + " 秒"
});

// 發送心跳重置計時器
inst.clientHeatBeat();
console.log("心跳已發送，計時器已重置");
```

### 常用搜尋模式

| 目標 | 搜尋關鍵字 | 搜尋位置 |
|------|-----------|----------|
| **網絡相關** | socket, net, connect, ws | `window.net`, `app.NetAgent` |
| **UI 彈窗** | dialog, popup, confirm, warn | `window.uiscript.UI_*` |
| **遊戲狀態** | state, status, mode, phase | `GameMgr.Inst`, `DesktopMgr.Inst` |
| **定時任務** | timer, interval, schedule | `Laya.timer._handlers` |
| **用戶操作** | click, touch, input, action | `mainrole`, `oplist` |
| **動畫效果** | effect, anim, bling | `effect_*`, `anim.*` |

### 工具函數

```javascript
// 通用搜尋函數
function searchObject(obj, keyword, maxDepth = 2, currentDepth = 0) {
    if (currentDepth > maxDepth) return [];
    var results = [];

    Object.keys(obj).forEach(key => {
        if (key.toLowerCase().includes(keyword.toLowerCase())) {
            results.push({
                path: key,
                type: typeof obj[key],
                value: typeof obj[key] === 'function' ? '[function]' : obj[key]
            });
        }
    });

    return results;
}

// 使用示例
searchObject(window.GameMgr.Inst, 'heart');
searchObject(window.uiscript, 'logout');
```

---

## 相關資源

### Shader 資源

| Shader | URL | 用途 |
|--------|-----|------|
| cartoon_pai.vs | `https://game.maj-soul.com/1/v0.10.237.w/shader/cartoon_pai/cartoon_pai.vs` | 牌面頂點著色器 |
| cartoon_pai.ps | `https://game.maj-soul.com/1/v0.10.237.w/shader/cartoon_pai/cartoon_pai.ps` | 牌面像素著色器 |
| outline.vs | `https://game.maj-soul.com/1/v0.10.1.w/shader/outline/outline.vs` | 邊框頂點著色器 |
| outline.ps | `https://game.maj-soul.com/1/v0.10.1.w/shader/outline/outline.ps` | 邊框像素著色器 |

### 紋理資源

| 紋理 | URL | 用途 |
|------|-----|------|
| dora_shine.png | `https://game.maj-soul.com/1/chs_t/myres/mjdesktop/` | 宝牌閃光紋理 |
| bg_dora.png | `https://game.maj-soul.com/1/chs_t/myres/mjdesktop/` | 宝牌背景 |

---

**文檔版本**: 1.3
**更新日期**: 2025-12-06
**驗證狀態**: ✅ 通過 Debug Server 和 JavaScript 直接查詢驗證
**變更記錄**:
- v1.3: 新增閒置檢測與心跳機制章節、如何查找遊戲 UI 元素（逆向工程流程）章節
- v1.2: 新增大廳 UI (Lobby UI) 章節，包含自動開始遊戲完整流程
- v1.1: 新增動作按鈕 UI (UI_ChiPengHu) 章節
