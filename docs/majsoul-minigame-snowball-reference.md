# Majsoul 雪球小遊戲框架說明（Laya 時代・已作廢）

> # ⚠️ 已作廢：本文依賴的 `window.uiscript` 與 `window.cfg` 都不存在了
>
> **雀魂於 `chs_t-WebGL-release-4.0.45(45)` 改用 Unity WebGL 客戶端**（原為 Laya 3D + JS）。
> 2026-07-31 runtime 實測確認：`window.uiscript`、`window.cfg`、`window.GameMgr`、
> `window.Laya` **全部不存在**。
>
> 因此本文的**每一段程式碼都失效**：
> `uiscript.UI_Activity_SnowBall_*`、`SnowBallData._inst`、`SnowBallEffectMgr`、
> `window.cfg.snowball.*`，以及文末的
> [「客戶端設定表」](#客戶端設定表已失效)（`cfg.snowball.snowball_monster_group.rows_`
> 改 `round_time` / `attack_delay`）——**照抄必定拋錯。**
>
> 保留本文的唯一理由：小遊戲的**規則與數值**（雪球傷害/CD/MP、Buff 等級、章節解鎖條件）
> 是伺服器端設計，作為遊戲知識仍有參考價值；只有**存取路徑**死了。
>
> Unity 時代的正確互動方式（Liqi protobuf）見
> **[majsoul-unity-protocol.md](majsoul-unity-protocol.md)**。
> 活動類請求的 payload schema **未驗證**。

**原文日期**: 2026-01-01（Laya 時代）
**作廢日期**: 2026-07-31
**來源**: JavaScript 逆向分析 (window.uiscript, window.cfg.snowball)
**重要**: 這些物件屬於 **Majsoul 遊戲的 WebUI**，不是 Naki 的代碼

---

## 目錄

1. [概述](#概述)
2. [UI 類別結構](#ui-類別結構)
3. [列舉類型](#列舉類型)
4. [核心類別方法](#核心類別方法)
5. [設定檔結構](#設定檔結構)
6. [遊戲流程](#遊戲流程)
7. [核心機制](#核心機制)
8. [存取範例](#存取範例)

---

## 概述

雪球小遊戲 (Snowball Activity) 是雀魂的季節性活動，玩家透過投擲雪球攻擊怪物/Boss，共有多個章節關卡。

**活動 ID**: 251201

---

## UI 類別結構

### 相關類別 (15 個)

| 類別 | 類型 | 用途 |
|------|------|------|
| `UI_Activity_SnowBall_Main` | UI | 主入口、大廳介面 |
| `UI_Activity_SnowBall_Game` | UI | 戰鬥中遊戲介面 |
| `UI_Activity_SnowBall_Result` | UI | 回合結果顯示 |
| `UI_Activity_SnowBall_VS` | UI | 戰鬥前 VS 畫面 |
| `UI_Activity_SnowBall_Task` | UI | 任務/成就列表 |
| `UI_Activity_SnowBall_Upgrade` | UI | Buff 升級商店 |
| `UI_Activity_SnowBall_Reward` | UI | 獎勵領取 |
| `UI_SnowBall_Spine` | UI | Spine 動畫控制器 |
| `SnowBallData` | Singleton | 遊戲狀態/資料管理器 |
| `SnowballRandom` | Utility | 遊戲隨機數生成 |
| `SnowBallEffectMgr` | Manager | 視覺效果（雪球、擊中、KO）|
| `ESnowBallPlayerType` | Enum | 玩家類型列舉 |
| `ESnowBallEventType` | Enum | 事件類型列舉 |
| `ESnowBallResultType` | Enum | 結果類型列舉 |
| `ESnowBallSpineAnim` | Enum | Spine 動畫列舉 |

### 訪問路徑

```javascript
// 主介面
window.uiscript.UI_Activity_SnowBall_Main.Inst

// 戰鬥介面
window.uiscript.UI_Activity_SnowBall_Game.Inst

// 資料管理器
SnowBallData._inst

// 效果管理器
SnowBallEffectMgr

// 設定檔
window.cfg.snowball
```

---

## 列舉類型

```javascript
// 玩家類型
ESnowBallPlayerType = {
  player: 0,
  boss: 1
}

// 事件類型
ESnowBallEventType = {
  mp: 0,      // MP 事件
  wave: 1,    // 波次事件
  hit: 2,     // 擊中事件
  throw: 3,   // 投擲事件
  offset: 4   // 偏移事件
}

// 結果類型
ESnowBallResultType = {
  none: 0,       // 無結果
  playerWin: 1,  // 玩家勝利
  bossWin: 2,    // Boss 勝利
  timeOut: 3,    // 超時
  allDie: 4      // 全滅
}

// Spine 動畫
ESnowBallSpineAnim = {
  Attack: 'attack',
  Die: 'die',
  Win: 'win',
  Enter: 'enter',
  Idle: 'idle',
  Hit: 'hit'
}
```

---

## 核心類別方法

### UI_Activity_SnowBall_Main（主入口）

```javascript
// 靜態屬性
UI_Activity_SnowBall_Main.haveRedPoint  // 是否有紅點
UI_Activity_SnowBall_Main.Inst          // 單例實例
UI_Activity_SnowBall_Main.activityId    // 活動 ID
UI_Activity_SnowBall_Main.currencyId    // 貨幣 ID
UI_Activity_SnowBall_Main.needShow      // 是否需要顯示

// 實例方法
inst.show()              // 顯示主介面
inst.hide()              // 隱藏
inst.startGame()         // 開始遊戲
inst.showRules()         // 顯示規則
inst.backToHome()        // 返回首頁
inst.refreshRedPoint()   // 刷新紅點
inst.refreshNextReward() // 刷新下一個獎勵
inst.initScene()         // 初始化場景
inst.destroyScene()      // 銷毀場景
inst.stopBgm()           // 停止背景音樂
inst.refreshBgm()        // 刷新背景音樂
inst.onDisable()         // 禁用時回調
inst.onEnable()          // 啟用時回調
inst.onActivityFinish()  // 活動結束時回調
```

### UI_Activity_SnowBall_Game（戰鬥介面）

```javascript
// 靜態屬性
UI_Activity_SnowBall_Game.Inst        // 單例實例
UI_Activity_SnowBall_Game.activityId  // 活動 ID

// 實例方法
inst.startRound()        // 開始回合
inst.endRound()          // 結束回合
inst.prepareEnd()        // 準備結束
inst.updateState()       // 更新狀態
inst.showCombo()         // 顯示連擊
inst.hideCombo()         // 隱藏連擊
inst.onEliminate()       // 消滅敵人時
inst.refreshBtn()        // 刷新按鈕
inst.showPlayer()        // 顯示玩家
inst.refreshRound()      // 刷新回合資訊
inst.refreshCDShow()     // 刷新冷卻顯示
inst.removeFlyingItem()  // 移除飛行物
inst.show()              // 顯示
inst.hide()              // 隱藏
inst.reset()             // 重置
inst.onEnable()          // 啟用時回調
inst.onDisable()         // 禁用時回調
```

### SnowBallData（遊戲狀態管理器）

```javascript
// 獲取實例
var data = SnowBallData._inst;

// 屬性
data.speed              // 遊戲速度
data.autoAttack         // 自動攻擊開關
data.highestLevel       // 最高通關關卡
data.pause              // 暫停狀態
data.resume             // 繼續狀態
data.currTimer          // 當前計時器
data.nowTime            // 當前時間
data.leftMoney          // 剩餘貨幣

// 初始化方法
data.initData()           // 初始化資料
data.initNewRoundData()   // 初始化新回合資料
data.reset()              // 重置

// 遊戲控制方法
data.playGame()           // 開始遊戲
data.throwSnowball()      // 投擲雪球
data.prepareThrow()       // 準備投擲
data.dealBossAction()     // 處理 Boss 行動
data.dealMPAction()       // 處理 MP 行動
data.checkEvent()         // 檢查事件
data.sortEvents()         // 排序事件
data.processingData()     // 處理資料
data.refreshNowTick()     // 刷新當前 tick

// 資料更新方法
data.updateData()           // 更新資料
data.updateUpgradeData()    // 更新升級資料
data.refreshData()          // 刷新資料
data.updateRewardByChanges()// 根據變更更新獎勵
data.updateRewardData()     // 更新獎勵資料

// 查詢方法
data.nowLevelConfig()       // 獲取當前關卡設定
data.getPlayerMaxHP()       // 獲取玩家最大 HP
data.finishedMaxLevel()     // 是否完成最高關
data.haveUnrecivedReward()  // 是否有未領取獎勵
data.getRewardUnlockRest()  // 獲取獎勵解鎖剩餘
data.getRewardState()       // 獲取獎勵狀態

// 錯誤處理
data.onGameError()          // 遊戲錯誤時回調
```

### SnowBallEffectMgr（視覺效果管理器）

```javascript
// 初始化
SnowBallEffectMgr.init()        // 初始化
SnowBallEffectMgr.initEffect()  // 初始化效果

// 效果顯示
SnowBallEffectMgr.showBall(params)   // 顯示雪球
SnowBallEffectMgr.showHit(params)    // 顯示擊中效果
SnowBallEffectMgr.showKO(params)     // 顯示 KO 效果
SnowBallEffectMgr.showDie(params)    // 顯示死亡效果
SnowBallEffectMgr.newEffect(type)    // 創建新效果

// 效果控制
SnowBallEffectMgr.hideEffect()       // 隱藏效果
SnowBallEffectMgr.refreshAnim()      // 刷新動畫
SnowBallEffectMgr.clear()            // 清除所有效果
SnowBallEffectMgr.destory()          // 銷毀
```

---

## 設定檔結構

設定檔位於 `window.cfg.snowball`，包含以下子設定：

### 活動設定 (snowball_activity)

```javascript
window.cfg.snowball.snowball_activity
```

| 參數 | 值 | 說明 |
|------|-----|------|
| activity_id | 251201 | 活動 ID |
| hp | 5 | 玩家初始血量 |
| mp | 15 | 初始 MP 值 |
| mp_recover | 30 | MP 回復速率 (每 tick) |
| tick | 30 | 遊戲 tick 間隔 |
| attack_interval | 5 | 攻擊間隔 |
| critical_hit | 2 | 暴擊傷害倍率 |
| player_luk | 10 | 玩家基礎幸運值 |
| skill_item | 30900097 | 技能道具 ID |

### 攻擊組別 (snowball_attack_group)

```javascript
window.cfg.snowball.snowball_attack_group
```

| 軌道 (track) | CD | 傷害 (atk) | 飛行時間 | MP 消耗 |
|--------------|-----|-----------|---------|---------|
| 0 (小雪球) | 90 | 1 | 30 | 5 |
| 1 (中雪球) | 150 | 2 | 36 | 8 |
| 2 (大雪球) | 210 | 3 | 45 | 11 |

### 攻擊等級 (snowball_attack_level)

```javascript
window.cfg.snowball.snowball_attack_level
```

| 等級 | 雪球數量加成 | MP Buff | CD Buff |
|------|-------------|---------|---------|
| 1 | 0 | 0 | 0 |
| 2 | +1 | +1 | 0 |
| 3 | +2 | +1 | -30 |
| 4 | +2 | +2 | -60 |

### 玩家 Buff (player_snowball_buff)

```javascript
window.cfg.snowball.player_snowball_buff
```

| 類型 | 說明 | 等級 1-4 效果 |
|------|------|--------------|
| 0 | 小雪球攻擊升級 | 連結 attack_level |
| 1 | 中雪球攻擊升級 | 連結 attack_level |
| 2 | 大雪球攻擊升級 | 連結 attack_level |
| 3 | 幸運值加成 | 0 / +5 / +15 / +25 |

**升級費用**: 0 / 3 / 5 / 7 貨幣

### 怪物群組 (snowball_monster_group)

```javascript
window.cfg.snowball.snowball_monster_group
```

- **5 個章節**，每章 9 關（共 45+ 關）
- **怪物 ID**: `monster_001` ~ `monster_010`
- **Boss ID**: `boss_001` ~ `boss_004`

每關設定：

| 參數 | 說明 |
|------|------|
| hp | 怪物/Boss 血量 |
| attack_delay | 攻擊延遲 |
| reward | 通關獎勵 |
| round_time | 回合時間 (1800 ticks = 30 秒) |
| unlock_day | 解鎖所需天數 (0/7/14) |

---

## 遊戲流程

```
┌─────────────────────────────────────────────────────────────┐
│                     遊戲流程圖                               │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  1. UI_Activity_SnowBall_Main.show()                       │
│     └─ 進入活動主介面                                       │
│                    ↓                                        │
│  2. UI_Activity_SnowBall_VS.show()                         │
│     └─ 戰前 VS 畫面（顯示對手資訊）                         │
│                    ↓                                        │
│  3. UI_Activity_SnowBall_Game.startRound()                 │
│     └─ 戰鬥開始                                             │
│         │                                                   │
│         ├─→ [玩家操作]                                      │
│         │   └─ SnowBallData.throwSnowball(track)           │
│         │       └─ SnowBallEffectMgr.showBall()            │
│         │           └─ SnowBallEffectMgr.showHit()         │
│         │                                                   │
│         └─→ [Boss 行動]                                     │
│             └─ SnowBallData.dealBossAction()               │
│                    ↓                                        │
│  4. UI_Activity_SnowBall_Result.show()                     │
│     └─ 結果顯示                                             │
│         │                                                   │
│         ├─→ [playerWin] 玩家勝利                            │
│         ├─→ [bossWin] Boss 勝利                             │
│         ├─→ [timeOut] 超時                                  │
│         └─→ [allDie] 全滅                                   │
│                    ↓                                        │
│  5. UI_Activity_SnowBall_Reward                            │
│     └─ 領取獎勵                                             │
│                    ↓                                        │
│  6. UI_Activity_SnowBall_Upgrade                           │
│     └─ 升級 Buff（可選）                                    │
│                    ↓                                        │
│     [返回主介面或繼續下一關]                                 │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

---

## 核心機制

### 雪球類型

| 類型 | 軌道 | 傷害 | CD | MP 消耗 | 特點 |
|------|------|------|-----|---------|------|
| 小雪球 | 0 | 1 | 90 | 5 | 快速、低消耗 |
| 中雪球 | 1 | 2 | 150 | 8 | 均衡 |
| 大雪球 | 2 | 3 | 210 | 11 | 高傷害、慢速 |

### MP 系統

- **初始 MP**: 15
- **回復速率**: 30 (每 tick)
- **消耗**: 依雪球類型 (5/8/11)

### Buff 系統

4 類升級，每類 4 級：

| 升級類型 | 效果 |
|---------|------|
| 攻擊升級 (0-2) | 增加雪球數量、MP Buff、CD 減少 |
| 幸運升級 (3) | 增加暴擊率 (+0/5/15/25) |

### 章節解鎖

| 章節 | 解鎖條件 |
|------|---------|
| 1 | 立即解鎖 |
| 2 | 累計遊玩 7 天 |
| 3 | 累計遊玩 14 天 |

### Boss 戰

- 每章第 9 關為 Boss 關
- Boss 血量較高
- 特殊攻擊模式

---

## 存取範例

### 基本存取

```javascript
// 檢查活動是否可用
var isAvailable = !!window.uiscript.UI_Activity_SnowBall_Main;

// 獲取主介面實例
var mainUI = window.uiscript.UI_Activity_SnowBall_Main.Inst;

// 獲取遊戲介面實例
var gameUI = window.uiscript.UI_Activity_SnowBall_Game.Inst;

// 獲取資料管理器
var data = SnowBallData._inst;
```

### 查詢遊戲狀態

```javascript
(function() {
  var data = SnowBallData._inst;
  if (!data) return { error: '遊戲未初始化' };

  return {
    currentLevel: data.highestLevel,
    money: data.leftMoney,
    autoAttack: data.autoAttack,
    hasReward: data.haveUnrecivedReward()
  };
})()
```

### 查詢關卡設定

```javascript
(function() {
  var data = SnowBallData._inst;
  if (!data) return { error: '遊戲未初始化' };

  var levelCfg = data.nowLevelConfig();
  return {
    hp: levelCfg.hp,
    attackDelay: levelCfg.attack_delay,
    roundTime: levelCfg.round_time,
    reward: levelCfg.reward
  };
})()
```

### 查詢 Buff 狀態

```javascript
(function() {
  var cfg = window.cfg.snowball.player_snowball_buff;
  if (!cfg) return { error: '設定未載入' };

  return cfg.map(function(buff, index) {
    return {
      type: index,
      levels: buff.length,
      costs: buff.map(function(b) { return b.cost; })
    };
  });
})()
```

### 使用 MCP 工具查詢

```
# 查詢雪球小遊戲狀態
mcp__naki__execute_js({ code: "SnowBallData._inst" })

# 查詢當前關卡
mcp__naki__execute_js({ code: "SnowBallData._inst?.nowLevelConfig()" })

# 查詢設定檔
mcp__naki__execute_js({ code: "window.cfg.snowball.snowball_activity" })
```

---

## 相關資源

### 其他小遊戲 UI

雀魂還有其他小遊戲，結構類似：

| 小遊戲 | UI 類別前綴 |
|-------|------------|
| 射擊遊戲 | `UI_Activity_Shoot_*` |
| 挖掘遊戲 | `UI_Activity_Wajue_*` |
| 翻牌遊戲 | `UI_Activity_Fanpai_*` |
| 海盜遊戲 | `UI_Activity_Haidao_*` |
| RPG 模式 | `UI_Rpg_*` |
| 模擬經營 | `UI_Simulation_*` |

---

## 客戶端設定表（已失效）

舊版 Laya 客戶端可從 `window.cfg` 讀寫本地設定表；Unity 客戶端已無此物件，
該路徑不再存在。本節原有的本地設定修改範例已移除（內容已失效且無遷移價值）。


**文檔版本**: 1.2（作廢標註）
**更新日期**: 2026-07-31
**驗證狀態**: ⛔ **已作廢** — 內容於 2026-01-01 在 Laya 客戶端驗證通過；
2026-07-31 實測雀魂已改用 Unity WebGL，本文所有存取路徑失效。
規則/數值部分仍有參考價值，程式碼部分請勿使用。
