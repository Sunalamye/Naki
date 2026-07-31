# Majsoul 客戶端配置表（`lqc.lqbin`）

**日期**: 2026-07-31
**狀態**: 全部 **已驗證**（實際下載並解析成功）
**重要性**: 這推翻了先前「客戶端配置表隨引擎搬進 wasm，JS 端無法觸及」的結論。

---

## 一句話結論

**雀魂的客戶端配置表沒有消失，只是從 `window.cfg` 全域物件變成可下載的資源檔。**
`res/config/lqc.lqbin`（17.5 MB）搭配 `res/proto/config.proto` 是**自描述**格式——
表結構與資料都在檔案裡，不需要猜任何欄位編號。

> 舊指引作廢：`CLAUDE.md` / `AUDIT.md` §9 說「`cfg` 在 Unity 客戶端下不存在，
> 客戶端配置表隨引擎搬進 wasm，JS 端無法觸及」。**前半句對（全域物件確實沒了），
> 後半句錯**——配置資料仍以資源檔公開提供。

---

## 取得方式

與 `liqi.json` 同一條路徑（見 [majsoul-unity-protocol.md](majsoul-unity-protocol.md) 的協定取得法）：

```
/1/version.json                      → { version: "0.11.252.w", ... }
/1/resversion<version>.json          → { res: { "<path>": { prefix: "0.11.252.w" }, ... } }
/1/v<prefix>/<path>
```

實測 URL（2026-07-31）：

```
https://game.maj-soul.com/1/v0.10.1.w/res/proto/config.proto     771 bytes
https://game.maj-soul.com/1/v0.11.252.w/res/config/lqc.lqbin      17,483,020 bytes
```

> ⚠️ `resversion` 的 `prefix` 欄位**已含版本字串本身**，組 URL 時是 `"/1/v" + prefix + "/" + path`。
> 多補一個 `v` 會拿到 `NoSuchKey`（實際踩過）。
> 另注意 `config.proto` 與 `lqc.lqbin` 的 prefix **不同版本**，必須各自查表，不能共用。

---

## 格式（`config.proto` 全文語意）

```protobuf
message Field       { string field_name=1; uint32 array_length=2; string pb_type=3; uint32 pb_index=4; }
message SheetMeta   { string category=1; string key=2; }
message SheetSchema { string name=1; SheetMeta meta=2; repeated Field fields=3; }
message TableSchema { string name=1; repeated SheetSchema sheets=2; }
message SheetData   { string table=1; string sheet=2; repeated bytes data=3; }
message ConfigTables{ string version=1; string header_hash=2;
                      repeated TableSchema schemas=3; repeated SheetData datas=4; }
```

要點：**每一列資料是一個 protobuf 訊息，其欄位編號 = schema 裡該欄位的 `pb_index`**。
所以解析流程是「先讀 schemas → 再用 schema 解 datas」，全程零猜測。

## 規模（實測）

| 項目 | 數值 |
|------|------|
| tables | 41 |
| sheets（table.sheet 組合） | 263 |
| 資料列總數 | 119,289 |

解析工具：`tools/parse_lqc.py`（列出所有表 / 依關鍵字查 schema）、
`tools/dump_sheet.py`（依 schema 解出指定 sheet 的資料列）。

```bash
python3 tools/parse_lqc.py lqc.lqbin                    # 列出所有 table.sheet = rows
python3 tools/parse_lqc.py lqc.lqbin mjp                # 查 schema
python3 tools/dump_sheet.py lqc.lqbin item_definition.view 20
```

---

## 牌面／牌背外觀（回答「能不能控制牌的顏色」）

外觀道具定義在 **`item_definition.view`**（450 列）：

```
 1 id: uint32          2 res_name: string     3 audio_id: uint32
 4 character_id: uint32 5 sargs[4]: string    6 old_effect_mark: uint32
 7 hand_version: uint32 8 seat_related: uint32
```

`res_name` 前綴即類別，實測分布：

| 前綴 | 數量 | 含義 |
|------|------|------|
| `tablecloth_` | 70 | 牌桌布 |
| `effect_` | 62 | 特效 |
| `liqi_` | 61 | 立直棒 |
| **`mjp_`** | **57** | **牌背** |
| `sxz_` | 56 | 手繪／裝飾 |
| `ron_` | 55 | 和牌特效 |
| `hand_` | 27 | 手部 |
| `beijing_` | 21 | 背景 |
| `headframe_` | 15 | 頭像框 |
| **`mjpface_`** | **3** | **牌面** |

實測樣本（item id ↔ 名稱）：

```
牌面 mjpface:  305718 mjpface_2308event
               305725 mjpface_default
             30710001 mjpface_25summer

牌背 mjp:      305015 mjp_yellow    305016 mjp_green    305017 mjp_rosered
               305045 mjp_default   305700 mjp_youling  305702 mjp_hl  …（共 57）
```

### 套用途徑（協定層）

```
.lq.Lobby.useCommonView    ReqUseCommonView { index=3 }              → ResCommon
.lq.Lobby.saveCommonViews  ReqSaveCommonViews { views=1(ViewSlot),
                                                save_index=2, is_use=3, name=4 } → ResCommon
.lq.Lobby.fetchAllCommonViews  ReqCommon → ResAllcommonViews { views=1, use=2, error=3 }

ViewSlot { slot=1, item_id=2, type=3, item_id_list=4 }
```

### 界線（誠實說明）

| 想做的事 | 可行性 |
|----------|--------|
| 換**整套**牌面／牌背外觀 | ✅ 協定支援，但**需帳號已擁有該 item** |
| **單張**牌高亮／變色（標示推薦牌） | ❌ **做不到**。外觀是整套套用，協定層沒有 per-tile 介面 |
| 從 Unity 內部改單張牌材質 | ❌ 做不到，見 [majsoul-unity-protocol.md](majsoul-unity-protocol.md) 的可控面分析 |

> 實測補充：在**對局中**送 `fetchAllCommonViews` 會回 `Error{code:1004}`，
> 大廳類請求需回到大廳才能操作。
> **這是會改變帳號外觀的操作**，依 CLAUDE.md「Ask：Account-related operations」，
> 執行前必須先向使用者確認。

---

## 其他值得注意的表

（`python3 tools/parse_lqc.py lqc.lqbin` 可列全部 263 個）

| 表 | 列數 | 用途線索 |
|----|------|---------|
| `item_definition.item` | 1093 | 道具總表 |
| `item_definition.skin` | 488 | 角色皮膚 |
| `desktop.matchmode` | 52 | 對局模式定義（`lobby_start_match` 的 `matchMode` 值） |
| `desktop.friend_room` | 17 | 友人房規則選項（`pre_rule` 合法值） |
| `desktop.field_spell` | 15 | 場地效果 |
| `achievement.achievement` | 566 | 成就 |
| `activity.*` | 大量 | 活動 |

---

## 用配置表解掉的兩個「未驗證」項

### 1. `GameMode.mode` 數值語意

`desktop.matchmode` 每列有 `room`（1=銅之間 / 2=銀之間 / 3=金之間…）與 `mode`（0/1/2），
同一個 room 恰好三列對應 mode 0、1、2：

```
id=1 room=1 mode=0 銅之間  can_sumup=1
id=2 room=1 mode=1 銅之間  can_sumup=1   levelpoint 10/5
id=3 room=1 mode=2 銅之間  can_sumup=1   levelpoint 20/10
id=4 room=2 mode=0 銀之間  can_sumup=0
id=5 room=2 mode=1 銀之間  can_sumup=1   levelpoint 20/10
id=6 room=2 mode=2 銀之間  can_sumup=1   levelpoint 40/20
```

mode 越大 levelpoint（段位點）越高 → **mode 1 = 東風戰、mode 2 = 半莊戰**。

> **runtime 交叉驗證通過**：`room_create` 以 `mode=2` 開的友人房，實際對局
> 從東1打到南1（完整半莊），確認 mode 2 = 半莊戰。此項可從「未驗證」移除。

### 2. 友人房 `pre_rule` 的合法值

`desktop.friend_room` 的 `pre_rule` 欄位即 `ReqCreateRoom.pre_rule`（field 5）可填值：

```
""(標準)  xuezhandaodi(血戰到底)  jiuchao(九蓮)  reveal_discard(暗夜)
chuanma(川麻)  dora3(三寶牌)  field_spell(場地效果)  zhanxing(占星)
tianming(天命)  yongchang(用場)  hunzhiyiji(魂之一擊)  wanxiangxiuluo
longzhimuyu  beishui  xiakeshang  qiangduozhizhan
```

`id=1` 對應四人（`siren.png`）、`id=2` 對應三人（`sanren.png`）；
`set_jushu` 標示該規則是否可設定局數。
