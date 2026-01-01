# Majsoul WebUI 完整 API 架構

**日期**: 2025-12-07
**來源**: JavaScript 逆向工程分析
**遊戲引擎**: Laya 3D Engine
**適用版本**: Majsoul (雀魂) Web 版

---

## 🆕 Naki Coordinator - 統一協調器

Naki 提供了一個統一的 JavaScript 協調器 (`NakiCoordinator`)，整合了所有常用 API：

```javascript
// 快捷訪問
window.naki === window.NakiCoordinator

// 遊戲狀態
naki.state.isInGame()           // 是否在遊戲中
naki.state.canExecuteAction()   // 是否可執行操作
naki.state.getFullState()       // 完整狀態
naki.state.getHandInfo()        // 手牌資訊
naki.state.getAvailableOps()    // 可用操作

// 自動設定控制
naki.auto.getSettings()         // 獲取所有設定
naki.auto.setHule(true)         // 自動和牌
naki.auto.setNoFulu(true)       // 自動 pass (不吃碰槓)
naki.auto.setMoqie(true)        // 自動摸切
naki.auto.enableAll()           // 啟用全部
naki.auto.disableAll()          // 停用全部

// 遊戲操作
naki.action.discard(tileIndex)  // 打牌
naki.action.pass()              // 跳過
naki.action.chi(combIndex)      // 吃
naki.action.pon()               // 碰
naki.action.kan()               // 槓
naki.action.hora()              // 和牌
naki.action.riichi(tileIndex)   // 立直
naki.action.execute('pass', {}) // 通用執行

// 大廳操作
naki.lobby.getStatus()          // 大廳狀態
naki.lobby.startMatch(mode)     // 開始匹配 (1=銅東, 2=銅半, etc.)
naki.lobby.cancelMatch()        // 取消匹配

// 心跳防閒置
naki.heartbeat.send()           // 手動心跳
naki.heartbeat.enableAntiIdle() // 啟用防閒置

// 視覺效果
naki.visual.showRecommendation(tileIndex, probability)
naki.visual.hideRecommendations()
naki.visual.playerNames.hide()
naki.visual.playerNames.show()

// 網路操作
naki.network.forceReconnect()   // 強制重連
naki.network.getConnections()   // WebSocket 連接

// 診斷
naki.debug.getDiagnostics()     // 完整診斷
naki.debug.listMethods()        // 列出所有方法
```

詳見 `naki-coordinator.js` 原始碼。

---

## 目錄

1. [架構概覽](#架構概覽)
2. [頂層命名空間](#頂層命名空間)
3. [核心管理器](#核心管理器)
4. [遊戲管理器 (DesktopMgr)](#遊戲管理器-desktopmgr)
5. [網路系統](#網路系統)
6. [UI 系統](#ui-系統)
7. [麻將核心邏輯 (mjcore)](#麻將核心邏輯-mjcore)
8. [配置系統 (cfg)](#配置系統-cfg)
9. [音效系統](#音效系統)
10. [動作類別](#動作類別)
11. [渲染系統](#渲染系統)
12. [事件系統](#事件系統)
13. [輔助工具](#輔助工具)

---

## 架構概覽

```
┌─────────────────────────────────────────────────────────────────┐
│                     Majsoul WebUI Architecture                   │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐           │
│  │   GameMgr    │  │  DesktopMgr  │  │   NetAgent   │           │
│  │  (全局管理)   │  │  (遊戲桌面)   │  │  (網路代理)   │           │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘           │
│         │                 │                 │                    │
│  ┌──────▼───────┐  ┌──────▼───────┐  ┌──────▼───────┐           │
│  │    uimgr     │  │   mainrole   │  │  LobbyNetMgr │           │
│  │  (UI 管理)   │  │  (主玩家)     │  │  (大廳網路)   │           │
│  └──────────────┘  └──────────────┘  └──────────────┘           │
│                                                                  │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │                    Supporting Systems                     │   │
│  ├──────────┬──────────┬──────────┬──────────┬──────────────┤   │
│  │ AudioMgr │  ChatMgr │   cfg    │  mjcore  │   uiscript   │   │
│  │  (音效)  │  (聊天)  │  (配置)  │ (麻將核心) │    (UI)     │   │
│  └──────────┴──────────┴──────────┴──────────┴──────────────┘   │
│                                                                  │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │                      Laya 3D Engine                       │   │
│  │  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐      │   │
│  │  │  Stage  │  │  Timer  │  │ Loader  │  │ Sprite3D│      │   │
│  │  └─────────┘  └─────────┘  └─────────┘  └─────────┘      │   │
│  └──────────────────────────────────────────────────────────┘   │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

---

## 頂層命名空間

### 完整命名空間列表

| 命名空間 | 物件數 | 用途 |
|---------|--------|------|
| `window.view` | 51 | 遊戲視圖類 (DesktopMgr, ViewPlayer, 動作類) |
| `window.game` | 95 | 遊戲邏輯類 (場景, 網路, 聊天) |
| `window.app` | 8 | 應用層服務 (NetAgent, CookieMgr, Log) |
| `window.uiscript` | 200+ | UI 腳本類 (所有 UI_* 類) |
| `window.mjcore` | 10 | 麻將核心邏輯 (牌型, 操作, 和牌) |
| `window.cfg` | 32 | 遊戲配置數據 |
| `window.net` | 22 | 網路通訊類 |
| `window.ui` | 12 | UI 子命名空間 |
| `window.amulet` | 59 | 護身符模式相關 |
| `window.caps` | 27 | 膠囊渲染系統 |
| `window.capsui` | 26 | 膠囊 UI 組件 |
| `window.common` | 6 | 通用工具類 |
| `window.Laya` | 40+ | Laya 引擎核心 |
| `window.protobuf` | 31 | Protobuf 序列化 |

### 訪問示例

```javascript
// 遊戲管理器
window.GameMgr.Inst

// 桌面管理器 (遊戲中)
window.view.DesktopMgr.Inst

// 網路代理
window.app.NetAgent

// 麻將核心
window.mjcore.E_PlayOperation
```

---

## 核心管理器

### GameMgr (遊戲管理器)

**路徑**: `window.GameMgr.Inst`

#### 靜態屬性

| 屬性 | 類型 | 說明 |
|------|------|------|
| `encodeP` | function | 加密函數 |
| `Inst` | GameMgr | 單例實例 |
| `config_data` | object | 配置數據 |
| `system_email_url` | string | 系統郵件 URL |
| `prefix_url` | string | 資源前綴 URL |
| `device_id` | string | 設備 ID |
| `client_language` | string | 客戶端語言 |
| `client_type` | number | 客戶端類型 |

#### 實例屬性

```javascript
{
  // ===== 登入狀態 =====
  logined: boolean,              // 是否已登入
  account_id: number,            // 帳戶 ID
  player_name: string,           // 玩家名稱

  // ===== 遊戲狀態 =====
  ingame: boolean,               // 是否在遊戲中
  duringPaipu: boolean,          // 是否在看牌譜
  in_shilian: boolean,           // 是否在試煉中
  in_ab_match: boolean,          // 是否在 AB 賽
  in_kuangdu: boolean,           // 是否在狂賭模式
  in_saki: boolean,              // 是否在咲模式
  in_huiye: boolean,             // 是否在輝夜模式
  in_simulation: boolean,        // 是否在模擬模式
  in_activity_mode: number,      // 活動模式

  // ===== UI 相關 =====
  uimgr: UIMgr,                  // UI 管理器
  root_ui: Sprite,               // UI 根節點
  root_scene: Sprite3D,          // 場景根節點
  root_front_effect: Sprite,     // 前景效果層

  // ===== 帳戶數據 =====
  account_data: {
    account_id: number,
    nickname: string,
    title: number,
    signature: string,
    gold: number,
    diamond: number,
    avatar_id: number,
    level: object,               // 四麻段位
    level3: object,              // 三麻段位
    vip: number,
    // ... 更多
  },

  // ===== 其他 =====
  mj_server_location: string,    // 麻將伺服器位置
  mj_game_token: string,         // 遊戲 Token
  mj_game_uuid: string,          // 遊戲 UUID
  server_time_delta: number,     // 伺服器時間差
  yostar_accessToken: string,    // Yostar Token
  yostar_uid: string             // Yostar UID
}
```

---

## 遊戲管理器 (DesktopMgr)

### 訪問路徑

```javascript
window.view.DesktopMgr.Inst
```

### 靜態屬性

| 屬性 | 類型 | 說明 |
|------|------|------|
| `is_yuren_type` | function | 是否玉人類型 |
| `EnDecode` | function | 編碼/解碼 |
| `Inst` | DesktopMgr | 單例實例 |
| `player_link_state` | array | 玩家連線狀態 [4] |
| `click_prefer` | number | 點擊偏好 |
| `double_click_pass` | boolean | 雙擊跳過 |
| `en_mjp` | boolean | 啟用麻將牌 |
| `bianjietishi` | boolean | 邊界提示 |

### 實例屬性 (80+)

```javascript
{
  // ===== 遊戲狀態 =====
  started: boolean,              // 遊戲是否開始
  gameing: boolean,              // 是否正在遊戲
  rule_mode: number,             // 規則模式
  mode: number,                  // 遊戲模式
  active: boolean,               // 是否激活
  seat: number,                  // 自己座位 (0-3)

  // ===== 玩家相關 =====
  mainrole: ViewPlayer_Me,       // 主玩家物件
  players: ViewPlayer[],         // 所有玩家 [4]
  player_datas: object[],        // 玩家數據
  player_effects: object[],      // 玩家效果
  myaccountid: number,           // 自己帳戶 ID

  // ===== 牌局信息 =====
  dora: object[],                // 宝牌指示牌
  oplist: object[],              // 可用操作列表
  choosed_op: number,            // 已選操作索引
  choosed_pai: object,           // 已選牌物件
  lastpai_seat: number,          // 最後打牌座位
  lastqipai: object,             // 最後打出的牌
  tingpais: object[],            // 聽牌列表

  // ===== 自動設定 =====
  auto_hule: boolean,            // 自動和牌
  auto_nofulu: boolean,          // 不吃碰槓
  auto_moqie: boolean,           // 自動摸切
  auto_babei: boolean,           // 自動拔北
  auto_liqi: boolean,            // 自動立直

  // ===== 效果物件 =====
  effect_dora3D: Sprite3D,       // 宝牌 3D 效果
  effect_dora3D_touying: Sprite3D, // 宝牌陰影
  effect_doraPlane: Sprite3D,    // 宝牌平面效果
  effect_recommend: Sprite3D,    // 推薦高亮效果
  effect_shadow: Sprite3D,       // 陰影效果
  effect_pai_canchi: Sprite3D,   // 可吃效果

  // ===== 動作系統 =====
  actionList: object[],          // 動作列表
  action_index: number,          // 當前動作索引
  current_step: number,          // 當前步驟
  actionMap: object,             // 動作映射
  action_running: boolean,       // 動作執行中

  // ===== 其他 =====
  game_config: object,           // 遊戲配置
  gameEndResult: object,         // 遊戲結果
  duringReconnect: boolean,      // 重連中
  operation_showing: boolean,    // 操作顯示中
  liqi_select: boolean,          // 立直選擇中
  md5: string,                   // MD5
  sha256: string,                // SHA256
  paipu_config: object           // 牌譜配置
}
```

### 實例方法 (80+)

```javascript
{
  // ===== 座位相關 =====
  seat2LocalPosition(seat): Vector3,
  localPosition2Seat(pos): number,
  getPlayerName(seat): string,
  setNickname(seat, name): void,

  // ===== 模式檢查 =====
  is_dora3_mode(): boolean,
  is_peipai_open_mode(): boolean,
  is_muyu_mode(): boolean,
  is_open_hand(): boolean,
  is_shilian_mode(): boolean,
  is_xiuluo_mode(): boolean,
  is_jiuchao_mode(): boolean,
  is_reveal_mode(): boolean,
  is_huansanzhang_mode(): boolean,
  is_chuanma_mode(): boolean,
  is_jjc_mode(): boolean,
  is_top_match(): boolean,

  // ===== 動作執行 =====
  ActionRunComplete(): void,
  StartChainAction(): void,
  DoChainAction(): void,
  DoMJAction(action): void,

  // ===== 遊戲控制 =====
  initRoom(config): void,
  trySyncGame(): void,
  syncGameByStep(step): void,
  setGameStop(stop): void,
  Reset(): void,

  // ===== 自動設定 =====
  setAutoHule(auto): void,
  setAutoNoFulu(auto): void,
  setAutoMoQie(auto): void,
  setAutoBaBei(auto): void,
  setAutoLiPai(auto): void,

  // ===== 顯示相關 =====
  CreatePai3D(val): Sprite3D,
  RefreshPlayerIndicator(): void,
  SetChangJuShow(): void,
  SetLeftPaiShow(): void,
  RefreshPaiLeft(): void,
  setScores(scores): void,
  setScoreDelta(delta): void,

  // ===== 操作相關 =====
  OperationTimeOut(): void,
  WhenDoOperation(op): void,
  ClearOperationShow(): void,
  WhenDoras(doras): void,

  // ===== 動作處理 =====
  Action_QiPai(data): void,
  Action_AnPai(data): void,
  Action_LiQi(data): void,
  Action_HuanSanZhange(data): void,
  SetLastQiPai(tile): void,

  // ===== 效果顯示 =====
  ShowHuleEffect(): void,
  ShowChiPengEffect(): void,
  CloseChiPngEffect(): void,
  setChoosedPai(tile): void,
  setTingpai(tiles): void,

  // ===== 輔助方法 =====
  isPaoPai(tile): boolean,
  getPaiLeft(type, index): number,
  get_gang_count(): number,
  get_babei_count(): number,
  fetchLinks(): void
}
```

### mainrole (主玩家物件)

**路徑**: `DesktopMgr.Inst.mainrole`

#### 屬性

```javascript
{
  // ===== 基本信息 =====
  seat: number,                  // 座位
  score: number,                 // 分數
  desktop: DesktopMgr,           // 桌面管理器引用

  // ===== 手牌相關 =====
  hand: Tile[],                  // 手牌陣列 (0-14)
  hand3d: Sprite3D,              // 3D 手牌容器
  handpool: object,              // 手牌池
  can_discard: boolean,          // 可以打牌
  last_tile: Tile,               // 最後摸的牌

  // ===== 狀態 =====
  during_liqi: boolean,          // 立直中
  during_anpai: boolean,         // 暗牌中
  during_huansanzhang: boolean,  // 換三張中
  xianggonged: boolean,          // 相公

  // ===== 容器 =====
  container_qipai: Sprite3D,     // 棄牌容器
  container_ming: Sprite3D,      // 副露容器
  container_babei: Sprite3D,     // 拔北容器

  // ===== 效果 =====
  liqibang: object,              // 立直棒
  liqibang_effects: object[],    // 立直棒效果
  effect_click: object           // 點擊效果
}
```

#### 方法

```javascript
{
  // ===== 初始化 =====
  InitMe(): void,
  Reset(): void,
  NewGame(): void,

  // ===== 牌操作 =====
  TakePai(tile): void,           // 摸牌
  OnDiscardTile(tile): void,     // 打牌
  DoDiscardTile(): void,         // 執行打牌
  LiPai(): void,                 // 理牌
  AddMing(ming): void,           // 加副露
  AddGang(gang): void,           // 加槓

  // ===== 選擇操作 =====
  setChoosePai(tile, selected): void,  // 選擇牌
  ChiTiSelect(index): void,      // 吃選擇
  LiQiSelect(index): void,       // 立直選擇
  AnPaiSelect(index): void,      // 暗牌選擇

  // ===== 執行操作 =====
  QiPaiPass(): void,             // 跳過
  QiPaiNoPass(): void,           // 確認副露
  DoOperation(opIndex): void,    // 執行操作
  onBabei(): void,               // 拔北

  // ===== 和牌 =====
  HulePrepare(): void,           // 和牌準備
  Hule(): void,                  // 和牌
  Huangpai(): void,              // 荒牌

  // ===== 滑鼠事件 =====
  onMouseDown(e): void,
  onMouseMove(e): void,
  onMouseUp(e): void,
  onDoubleClick(e): void
}
```

---

## 網路系統

### NetAgent (網路代理)

**路徑**: `window.app.NetAgent`

#### 靜態方法

```javascript
{
  init(): void,

  // 大廳通訊
  sendReq2Lobby(service, method, data, callback): void,
  addListener2Lobby(method, handler): void,
  removeListener2Lobby(method, handler): void,

  // 麻將通訊
  sendReq2MJ(service, method, data, callback): void,
  addListener2MJ(method, handler): void,

  // 驗證
  checkValid1Min(): void,
  postInfo3Min(): void,

  // 統計
  lobbySummary3Min(): void,
  lobbySummary1Min(): void,
  mjSummary3Min(): void,
  mjSummary1Min(): void
}
```

#### 使用示例

```javascript
// 發送請求到大廳
app.NetAgent.sendReq2Lobby('Lobby', 'fetchAccountInfo', {
    account_id: GameMgr.Inst.account_id
}, function(err, res) {
    if (!err) {
        console.log('帳戶信息:', res.account);
    }
});

// 監聽通知
app.NetAgent.addListener2MJ('NotifyPlayerConnectionState', function(data) {
    console.log('玩家連線狀態變更:', data);
});
```

### net 命名空間

```javascript
window.net = {
  // 類
  NetRouteGroup_Entrance,        // 入口路由組
  NetRouteGroup_Single,          // 單一路由組
  NetRouteGroup,                 // 路由組
  NetRoute,                      // 路由
  Socket,                        // Socket
  LiveSocket,                    // 直播 Socket
  ContestChatSocket,             // 比賽聊天 Socket

  // 工具類
  ProtobufManager,               // Protobuf 管理器
  NotifyHandler,                 // 通知處理器
  GatewayFetcher,                // 閘道獲取器
  NetworkQualityAnalyzer,        // 網路品質分析器
  RequestClientHandle,           // 請求處理器
  RouteDelayWatcher,             // 路由延遲監視器

  // 常量
  HeaderType,                    // 標頭類型
  ProtoHeaderType,               // Proto 標頭類型
  RouteType,                     // 路由類型
  DELAY_INF,                     // 延遲無限大
  DELAY_BAD_THRESHOLD,           // 延遲差閾值
  DELAY_GOOD_THRESHOLD           // 延遲好閾值
}
```

### MJNetMgr (麻將網路管理器)

**路徑**: `window.game.MJNetMgr.Inst`

```javascript
{
  // 屬性
  playerreconnect: boolean,      // 玩家重連
  load_over: boolean,            // 加載完成
  loaded_player_count: number,   // 已加載玩家數
  real_player_count: number,     // 真實玩家數
  is_ob: boolean,                // 是否觀戰
  ob_token: string,              // 觀戰 Token
  netMJ: object,                 // 麻將網路
  token: string,                 // Token
  game_uuid: string,             // 遊戲 UUID
  server_location: string,       // 伺服器位置

  // 方法
  OpenConnect(url): void,        // 開啟連接
  openNet(): void,               // 開啟網路
  reportInfo(): void,            // 報告信息
  Close(): void,                 // 關閉
  GetAuthData(): object,         // 獲取認證數據
  OpenConnectObserve(): void     // 開啟觀戰連接
}
```

### LobbyNetMgr (大廳網路管理器)

**路徑**: `window.game.LobbyNetMgr.Inst`

```javascript
{
  // 屬性
  zone_ids: number[],            // 區域 ID
  server_name: string,           // 伺服器名稱

  // 方法
  init(): void,
  initOnLoginSuccess(): void,
  add_connect_listener(handler): void,
  remove_connect_listener(handler): void,
  close(): void
}
```

---

## UI 系統

### UIMgr (UI 管理器)

**路徑**: `window.GameMgr.Inst.uimgr`

#### 方法

```javascript
{
  // 場景切換
  openLobbyUI(): void,
  openMjDesktopUI(): void,
  openAmuletDesktopUI(): void,
  openSpotUI(): void,
  openSimulationUI(): void,
  openKuangduUI(): void,
  openHuiyeUI(): void,
  openSakiUI(): void,

  // 滑鼠控制
  disableMouse(): void,
  enableMouse(): void,

  // UI 控制
  closeUIWithTag_Lobby(): void,
  closeUIWithTag_Both(): void,
  showLobby(): void,
  intoMJDesktop(): void,

  // 場景事件
  onSceneMJ_Enable(): void,
  onSceneMJ_Disable(): void,
  onSceneLobby_Enable(): void,
  onSceneLobby_Disable(): void,

  // 彈窗顯示
  showRemind(msg): void,
  showEntrance(): void,
  ShowChipenghu(): void,
  CloseChipenghu(): void,
  ShowLiqiZimo(): void,
  CloseLiqiZimo(): void,
  ShowWin(): void,
  CloseWin(): void,
  ShowLiuJu(): void
}
```

### uiscript 命名空間 (主要 UI 類)

```javascript
window.uiscript = {
  // 基礎類
  UIBase,                        // UI 基類
  UI_PopupBase,                  // 彈窗基類
  UI_Component,                  // 組件基類

  // 遊戲 UI
  UI_ChiPengHu,                  // 吃碰槓和按鈕
  UI_HuanSanZhange,              // 換三張
  UI_PiPeiYuYue,                 // 匹配預約

  // 大廳 UI
  UI_Report,                     // 舉報
  UI_Remind,                     // 提醒
  UI_SecondConfirm_Entrance,     // 二次確認
  UI_SecondConfirm_Title,        // 標題確認

  // 閒置相關
  UI_Hangup_Warn,                // 閒置警告
  UI_Hanguplogout,               // 閒置登出

  // 商城
  UI_Shop,                       // 商店
  UI_Money,                      // 貨幣
  UI_CardPackage,                // 卡包
  UI_AmuletShop,                 // 護身符商店

  // 玩家
  UI_PlayerInfo_Edit,            // 玩家信息編輯
  UI_Nickname,                   // 暱稱
  UI_Overall,                    // 總覽

  // 活動
  UI_ActivityBase,               // 活動基類
  UI_Activity_Spot,              // 探店活動
  UI_Activity_Shoot,             // 射擊活動
  UI_Tanfang,                    // 探訪

  // 其他
  UI_Course,                     // 教程
  UI_TweenManager,               // 動畫管理器
  UI_Delete_Account,             // 刪除帳號
  UI_User_Xieyi,                 // 用戶協議
  UI_Dongtai_Kaiguan             // 動態開關
  // ... 更多
}
```

### UI_ChiPengHu (動作按鈕)

**路徑**: `window.uiscript.UI_ChiPengHu.Inst`

```javascript
{
  container_btns: {
    x: 812,
    y: 821,
    numChildren: 15,
    // 子按鈕陣列
  },

  // 按鈕引用
  btn_chi: Button,               // 吃 (index 4)
  btn_peng: Button,              // 碰 (index 5)
  btn_gang: Button,              // 槓 (index 6)
  btn_lizhi: Button,             // 立直 (index 7)
  btn_hu: Button,                // 和 (index 8)
  btn_zimo: Button,              // 自摸 (index 10)
  btn_cancel: Button,            // 過 (index 14)
  btn_jiuzhongjiupai: Button,    // 九種九牌 (index 2)
  btn_babei: Button,             // 拔北 (index 3)
  btn_anpai: Button,             // 暗牌 (index 9)
  btn_liqi10: Button,            // 立直 10 (index 0)
  btn_liqi5: Button              // 立直 5 (index 1)
}
```

---

## 麻將核心邏輯 (mjcore)

### 訪問路徑

```javascript
window.mjcore
```

### 牌型枚舉 (E_MJPai)

```javascript
mjcore.E_MJPai = {
  p: 0,    // 筒
  m: 1,    // 萬
  s: 2,    // 索
  z: 3,    // 字
  bd: 4    // 百搭
}
```

### 副露類型 (E_Ming)

```javascript
mjcore.E_Ming = {
  shunzi: 0,      // 順子 (吃)
  kezi: 1,        // 刻子 (碰)
  gang_ming: 2,   // 明槓
  gang_an: 3,     // 暗槓
  babei: 4,       // 拔北
  gang_add: 5     // 加槓
}
```

### 操作類型 (E_PlayOperation)

```javascript
mjcore.E_PlayOperation = {
  none: 0,            // 無
  dapai: 1,           // 打牌
  eat: 2,             // 吃
  peng: 3,            // 碰
  an_gang: 4,         // 暗槓
  ming_gang: 5,       // 明槓
  add_gang: 6,        // 加槓
  liqi: 7,            // 立直
  zimo: 8,            // 自摸
  rong: 9,            // 榮和
  jiuzhongjiupai: 10, // 九種九牌
  babei: 11,          // 拔北
  huansanzhang: 12,   // 換三張
  dingque: 13,        // 定缺
  reveal: 14,         // 揭露
  unveil: 15,         // 解除揭露
  locktile: 16,       // 鎖牌
  revealliqi: 17,     // 揭露立直
  selecttile: 18,     // 選牌
  po_liqi_5000: 19,   // 破立直 5000
  po_liqi_10000: 20   // 破立直 10000
}
```

### 流局類型 (E_LiuJu)

```javascript
mjcore.E_LiuJu = {
  none: 0,
  jiuzhongjiupai: 1,  // 九種九牌
  sifenglianda: 2,    // 四風連打
  sigangsanle: 3,     // 四槓散了
  sijializhi: 4,      // 四家立直
  sanjiahule: 5       // 三家和了
}
```

### 和牌類型 (E_Hu_Type)

```javascript
mjcore.E_Hu_Type = {
  rong: 0,        // 榮和
  zimo: 1,        // 自摸
  qianggang: 2    // 搶槓
}
```

### MJPai 類

```javascript
mjcore.MJPai = {
  // 靜態方法
  Create(type, index): MJPai,
  RandomCreate(): MJPai,
  isSame(a, b): boolean,
  Distance(a, b): number,
  DoraMet(tile, dora): boolean,
  getBackTilingOffset(): Vector2,

  // 實例方法 (prototype)
  IsZ(): boolean,           // 是否字牌
  IsLaoTou(): boolean,      // 是否老頭
  IsYao(): boolean,         // 是否么九
  IsSiXi(): boolean,        // 是否四喜
  IsSanYan(): boolean,      // 是否三元
  Clone(): MJPai,           // 複製
  numValue(): number,       // 數值
  toString(): string,       // 字符串
  getNextCard(): MJPai,     // 下一張
  getPrevCard(): MJPai      // 上一張
}
```

---

## 配置系統 (cfg)

### 訪問路徑

```javascript
window.cfg
```

### 配置模塊列表

| 模塊 | 說明 |
|------|------|
| `cfg.achievement` | 成就配置 |
| `cfg.activity` | 活動配置 |
| `cfg.amulet` | 護身符配置 |
| `cfg.animation` | 動畫配置 |
| `cfg.audio` | 音效配置 |
| `cfg.character` | 角色配置 |
| `cfg.chest` | 寶箱配置 |
| `cfg.desktop` | 桌面配置 (含 matchmode) |
| `cfg.events` | 事件配置 |
| `cfg.exchange` | 兌換配置 |
| `cfg.fan` | 役種配置 |
| `cfg.fandesc` | 役種描述 |
| `cfg.game_live` | 遊戲直播配置 |
| `cfg.global` | 全局配置 |
| `cfg.info` | 信息配置 |
| `cfg.item_definition` | 物品定義 |
| `cfg.level_definition` | 等級定義 |
| `cfg.mall` | 商城配置 |
| `cfg.outfit_config` | 裝扮配置 |
| `cfg.quest_crew` | 任務配置 |
| `cfg.rank_introduce` | 段位介紹 |
| `cfg.season` | 賽季配置 |
| `cfg.shoot` | 射擊配置 |
| `cfg.shops` | 商店配置 |
| `cfg.simulation` | 模擬配置 |
| `cfg.spot` | 探店配置 |
| `cfg.str` | 字符串配置 |
| `cfg.tournament` | 錦標賽配置 |
| `cfg.tutorial` | 教程配置 |
| `cfg.vip` | VIP 配置 |
| `cfg.voice` | 語音配置 |

### 使用示例

```javascript
// 獲取角色配置
var character = cfg.character;
console.log(character.emoji);   // 表情
console.log(character.cutin);   // 特寫
console.log(character.skin);    // 皮膚

// 獲取匹配模式
var matchmode = cfg.desktop.matchmode;
matchmode.forEach(function(mode, id) {
    console.log({
        id: id,
        room: mode.room,
        room_name: mode.room_name_chs,
        level_limit: mode.level_limit
    });
});

// 獲取役種信息
var fan = cfg.fan;
console.log('役種數量:', Object.keys(fan).length);
```

---

## 音效系統

### AudioMgr (音效管理器)

**路徑**: `window.view.AudioMgr`

#### 靜態方法

```javascript
{
  init(): void,

  // 角色語音
  PlayCharactorSound(charId, soundId): void,
  PlayCharactorSound_Teshu(charId, soundId): void,
  PlayCharactorSoundInSpot(charId, soundId): void,

  // 環境音效
  PlayAmbientSoundInSpot(): void,
  StopAmbientSoundInSpot(): void,

  // 音效播放
  PlaySound(soundId): void,
  PlayLoopSound(soundId): void,
  playABBBSound(soundId): void,
  playABBBSoundById(soundId): void,

  // 音頻控制
  PlayAudio(audioId): void,
  StopAudio(audioId): void,
  GetAudioChannel(audioId): AudioChannel,

  // 音樂控制
  PlayMusic(musicId): void,
  StopMusic(): void,
  PlayLiqiBgm(): void,
  PlayLiqiBgmInSushe(): void,

  // 音量控制
  setCVvolume(volume): void,
  getCVvolume(): number,
  setCVmute(mute): void,
  getCVmute(): boolean,
  refresh_music_volume(): void,
  setMusicVolume(volume): void,
  resetAllConfig(): void
}
```

### BgmListMgr (背景音樂管理器)

**路徑**: `window.view.BgmListMgr`

```javascript
{
  init(): void,
  saveConfig(): void,
  resetAllConfig(): void,
  stopBgm(): void,

  // 大廳 BGM
  PlayLobbyBgm(): void,
  NextLobbyBgm(): void,
  findIndexInLobby(bgmId): number,

  // 麻將 BGM
  PlayMJBgm(): void,
  NextMJBgm(): void,
  findIndexInMJ(bgmId): number,

  // 事件 BGM
  PlayEventBgm(eventId): void,
  ResetBgm(): void,

  // 配置
  baned_bgm_lobby_list: number[],
  bgm_lobby_mode: number,
  baned_bgm_mj_list: number[],
  bgm_mj_mode: number
}
```

---

## 動作類別

### 訪問路徑

```javascript
window.view.Action*
```

### 動作類列表

| 類 | 說明 |
|-----|------|
| `ActionBase` | 動作基類 |
| `ActionNewRound` | 新回合 |
| `ActionDealTile` | 發牌 |
| `ActionDiscardTile` | 打牌 |
| `ActionChiPengGang` | 吃碰槓 |
| `ActionAnGangAddGang` | 暗槓加槓 |
| `ActionLiqi` | 立直 |
| `ActionHule` | 和了 |
| `ActionNoTile` | 荒牌 |
| `ActionLiuJu` | 流局 |
| `ActionGangResult` | 槓結果 |
| `ActionGangResultEnd` | 槓結果結束 |
| `ActionNewCard` | 新牌 |
| `ActionOperation` | 操作 |
| `ActionBabei` | 拔北 |
| `ActionRevealTile` | 揭露牌 |
| `ActionUnveilTile` | 解除揭露 |
| `ActionLockTile` | 鎖牌 |
| `ActionChangeTile` | 換牌 |
| `ActionFillAwaitingTiles` | 填充等待牌 |
| `ActionSelectGap` | 選擇缺 |
| `ActionHuleXueZhanMid` | 血戰中途和 |
| `ActionHuleXueZhanEnd` | 血戰結束和 |

---

## 渲染系統

### Laya 引擎

```javascript
window.Laya = {
  // 核心
  stage: Stage,                  // 舞台
  timer: Timer,                  // 計時器
  scaleTimer: Timer,             // 縮放計時器
  loader: Loader,                // 加載器
  render: Render,                // 渲染器

  // 配置
  Config: object,                // 配置
  version: string,               // 版本

  // 事件
  Event: Event,                  // 事件類
  EventDispatcher: EventDispatcher,

  // 輸入
  Keyboard: Keyboard,
  KeyBoardManager: KeyBoardManager,
  MouseManager: MouseManager,
  TouchManager: TouchManager,

  // 顯示
  Graphics: Graphics,
  GraphicsBounds: GraphicsBounds,
  Style: Style,
  Font: Font,
  BitmapFont: BitmapFont,

  // 濾鏡
  Filter: Filter,
  ColorFilterAction: ColorFilterAction,

  // 數學
  Arith: Arith,
  Bezier: Bezier,

  // 3D
  Vector3: Vector3,
  Quaternion: Quaternion,
  Matrix4x4: Matrix4x4,
  Sprite3D: Sprite3D,
  MeshSprite3D: MeshSprite3D
}
```

### caps 渲染系統

```javascript
window.caps = {
  // 材質
  BaseMaterial,
  Material_Outline,
  Material_TwoSided,
  Material_TouMingPai,
  Material_Clip,

  // 著色器
  ShaderInitor,
  Cartoon,
  Cartoon_Pai,
  Cartoon_Tile_Back,
  Cartoon_Alpha,
  TwoSided,
  TouMingPai,

  // 效果
  Outline,
  ColorOverlay,
  TextureBlend,
  GaussianBlur,
  ColorAdjustment,
  Shader_RanShao,

  // 腳本
  CapsLanVM,
  CodeTree,
  CodeTreeType,
  CodeReturnValue,
  CapsValue,
  EValueType
}
```

### ViewPai (牌渲染)

```javascript
window.view.ViewPai.prototype = {
  SetTianMingYellow(): void,
  ShowUp(): void,
  ShowBack(): void,
  ShowRot(): void,
  ShowStand(): void,
  RefreshDora(): void,
  RemoveDora(): void,
  ResetShow(): void,
  OnChoosedPai(): void,
  GetDefaultColor(): Color,
  SetRevealState(state): void,
  ChangeVal(val): void,
  PlayRevealFailedAnim(): void,
  ResetAllTimer(): void,
  setMeshColor(color): void
}
```

### HandPai3D (3D 手牌)

```javascript
window.view.HandPai3D.prototype = {
  SetVal(val): void,
  SetIndex(index): void,
  IsNew(): boolean,
  Stand(): void,
  FullDown(): void,
  Cover(): void,
  ClearAnim(): void,
  DoAnim_FullDown(): void,
  DoAnim_Cover(): void,
  DoAnim_Stand(): void,
  DoAnim_CoverToFulldown(): void,
  Update(): void,
  Destory(): void
}
```

---

## 事件系統

### EventCode (事件代碼)

```javascript
window.EventCode = {
  // 活動
  ACTIVITY_PERIOD_TASK_GET_REWARD: "ActivityPeriodTaskGetReward",
  ACTIVITY_PERIOD_TASK_GET_REWARD_FINISH: "ActivityPeriodTaskGetRewardFinish",
  REMOVE_ACTIVITY: "RemoveActivity",
  ACTIVITY_SPOT_UPDATE: "ActivitySpotUpdate",
  ACTIVITY_PERIOD_TASK_UPDATE: "ActivityPeriodTaskUpdate",
  ACTIVITY_RANDOM_TASK_UPDATE: "ActivityRandomTaskUpdate",

  // 匹配
  OPEN_MATCH_UI: "OpenMatchUI",
  CLOSE_MATCH_UI: "CloseMatchUI",

  // 房間
  ON_CLICK_JOIN_ROOM: "OnClickJoinRoom",

  // 徽章
  BADGE_DATA_UPDATE: "BadgeDataUpdate",

  // 分析
  ON_MAKA_ANALYSIS_COUNT_CHANGE: "OnMakaAnalysisCountChange",
  ON_MAKA_ANALYSIS_LIST_CHANGE: "OnMakaAnalysisListChange",
  ON_MAKA_ANALYSIS_COMPLETE: "OnMakaAnalysisComplete",
  ON_FETCH_MAKA_DETAIL_COMPLETE: "OnFetchMakaDetailComplete",
  ON_MAKA_ANALYSIS_WINDOW_CLOSE: "OnMakaAnalysisWindowClose",
  MAKA_MAINTAIN_CHANGE: "MakaMaintainChange",

  // 商城
  MONTH_TICKET_CHANGE: "MonthTicketChange",

  // 投票
  CLOTHES_VOTE_FAMALE_RANK_UPDATE: "ClothesVoteFamaleRankUpdate",
  CLOTHES_VOTE_MALE_RANK_UPDATE: "ClothesVotemaleRankUpdate",
  CLOTHES_VOTE_HOT_PROGRESS_UPDATE: "ClothesVoteHotProgressUpdate",
  CLOTHES_VOTE_COUNT_UPDATE: "ClothesVoteCountUpdate",
  CLOTHES_VOTE_PROGRESS_REWARDED_UPDATE: "ClothesVoteProgressRewardedUpdate"
}
```

### ProtoCode (協議代碼)

```javascript
window.ProtoCode = {
  SPOTLOGGING: "spot_detail",
  MATCH_UNIFIED: "startUnifiedMatch",
  STOPMATCH_UNIFIED: "cancelUnifiedMatch",
  COMPLETE_PERIOD_ACTIVITY_TASK: "completePeriodActivityTask",
  COMPLETE_PERIOD_ACTIVITY_TASK_BATCH: "completePeriodActivityTaskBatch",
  REQUEST_CREATE_ROOM: "createRoom",
  ISLAND_ACTIVITY_MOVE: "islandActivityMove",
  ISLAND_ACTIVITY_BUY: "islandActivityBuy",
  ISLAND_ACTIVITY_SELL: "islandActivitySell",
  ISLAND_ACTIVITY_TIDY_BAG: "islandActivityTidyBag",
  ISLAND_ACTIVITY_UNLOCK_BAG_GRID: "islandActivityUnlockBagGrid",
  REQ_CREATE_CUSTOMIZED_CONTEST: "createCustomizedContest",
  UPDATE_MANAGER_CUSTOMIZED_CONTEST: "updateManagerCustomizedContest",
  GENERATE_CONTEST_MANAGER_LOGINCODE: "generateContestManagerLoginCode",
  FETCH_MANAGER_CUSTOMIZED_CONTEST_LIST: "fetchManagerCustomizedContestList",
  FETCH_CUSTOMIZED_CONTEST_LIST: "fetchCustomizedContestList",
  FETCH_MULTI_ACCOUNT_BRIEF: "fetchMultiAccountBrief",
  FETCH_MAIL_INFO: "fetchMailInfo"
}
```

---

## 輔助工具

### common 命名空間

```javascript
window.common = {
  MatrixUtils,                   // 矩陣工具
  ConfigHelper,                  // 配置輔助
  DateConver,                    // 日期轉換
  HttpMgr,                       // HTTP 管理器
  ProtoHelper,                   // Protobuf 輔助
  SpriteAdapter                  // Sprite 適配器
}
```

### ProtoHelper

```javascript
common.ProtoHelper = {
  getCode(code): string,         // 獲取代碼
  getServer(server): string,     // 獲取伺服器
  codeDictionary: object,        // 代碼字典
  serverDictionary: object       // 伺服器字典
}
```

### CookieMgr

```javascript
app.CookieMgr = {
  setCookie(key, value): void,
  getCookie(key): string
}
```

### Taboo (禁言系統)

```javascript
app.Taboo = {
  init(): void,
  add_extra_word(word): void,
  remove_extra_word(word): void,
  test(text): boolean
}
```

### LoginMgr (登入管理器)

```javascript
game.LoginMgr = {
  relogin(): void,
  onReconnectLogin(): void,
  onLoginSuccess(): void,
  onFastLogin(): void,
  eventHandler: object,
  account: string,
  password: string,
  sociotype: number,
  access_token: string
}
```

### ChatMgr (聊天管理器)

**路徑**: `window.game.ChatMgr`

```javascript
{
  init(): void
  // 實例方法需通過 ChatMgr.Inst 訪問
}
```

---

## 場景系統

### 場景類列表

```javascript
window.game = {
  Scene_Lobby,       // 大廳場景
  Scene_MJ,          // 麻將場景
  Scene_Amulet,      // 護身符場景
  Scene_Spot,        // 探店場景
  Scene_Kuangdu,     // 狂賭場景
  Scene_Huiye,       // 輝夜場景
  Scene_Saki,        // 咲場景
  Scene_Simulation,  // 模擬場景
  Scene_Hesu,        // 河蘇場景
  Scene_Activity_Base // 活動基礎場景
}
```

### 場景狀態

```javascript
// 檢查當前場景
var gm = GameMgr.Inst;
console.log({
  currentScene: gm.root_scene ? gm.root_scene.name : null,
  ingame: gm.ingame,
  duringPaipu: gm.duringPaipu
});
```

---

## 快速參考

### 常用路徑

| 用途 | 路徑 |
|------|------|
| 遊戲管理器 | `GameMgr.Inst` |
| 桌面管理器 | `view.DesktopMgr.Inst` |
| 主玩家 | `view.DesktopMgr.Inst.mainrole` |
| 手牌 | `view.DesktopMgr.Inst.mainrole.hand` |
| 宝牌 | `view.DesktopMgr.Inst.dora` |
| 操作列表 | `view.DesktopMgr.Inst.oplist` |
| 網路代理 | `app.NetAgent` |
| UI 管理器 | `GameMgr.Inst.uimgr` |
| 動作按鈕 | `uiscript.UI_ChiPengHu.Inst` |
| 配置 | `cfg.*` |
| 音效 | `view.AudioMgr` |

### 操作類型速查

| 代碼 | 名稱 | 說明 |
|------|------|------|
| 0 | none | 無操作 |
| 1 | dapai | 打牌 |
| 2 | eat | 吃 |
| 3 | peng | 碰 |
| 4 | an_gang | 暗槓 |
| 5 | ming_gang | 明槓 |
| 6 | add_gang | 加槓 |
| 7 | liqi | 立直 |
| 8 | zimo | 自摸 |
| 9 | rong | 榮和 |
| 10 | jiuzhongjiupai | 九種九牌 |
| 11 | babei | 拔北 |

### 牌類型速查

| 代碼 | 名稱 | MJAI |
|------|------|------|
| 0 | 筒 | p |
| 1 | 萬 | m |
| 2 | 索 | s |
| 3 | 字 | z |

---

**文檔版本**: 1.0
**創建日期**: 2025-12-07
**驗證方式**: JavaScript 逆向工程分析
