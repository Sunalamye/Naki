# 雀魂現行客戶端配置表

**資料日期**：2026-08-01  
**來源**：由正在執行的 Naki 頁面讀取 `version.json`／resource manifest，再 fresh download、hash 與解析。

本文件只記錄當前資源。Unity／WebGL、Liqi、AI 與高亮的主基準見 [majsoul-unity-protocol.md](majsoul-unity-protocol.md)。

## 當前資源定位

Naki live page 回傳：

```text
version.json                    0.11.252.w
res/proto/config.proto prefix   v0.10.1.w
res/config/lqc.lqbin prefix     v0.11.252.w
```

resource manifest 的 `prefix` 已含前導 `v`，正確組法是：

```text
https://game.maj-soul.com/1/<prefix>/<path>
```

本次實際使用：

```text
https://game.maj-soul.com/1/v0.10.1.w/res/proto/config.proto
https://game.maj-soul.com/1/v0.11.252.w/res/config/lqc.lqbin
```

不要寫成 `/1/v<prefix>/...`，否則會多一個 `v`。

## 檔案驗證

| 資源 | bytes | SHA-256 |
|------|------:|---------|
| `config.proto` | 855 | `7291c02850e0eebd913a585e123355fad04f06d44c2c5388a923328ba4d07873` |
| `lqc.lqbin` | 17,483,020 | `a5959513fa31d3b5297d2dda400c86c0eacbdb4adad461b583439d7f673c9086` |

fresh parser 結果：

| 項目 | 數值 |
|------|-----:|
| tables | 41 |
| sheets | 263 |
| rows | 119,289 |

## 格式

`lqc.lqbin` 是 self-describing protobuf。`config.proto` 的核心結構是：

```protobuf
message Field       { string field_name=1; uint32 array_length=2; string pb_type=3; uint32 pb_index=4; }
message SheetMeta   { string category=1; string key=2; }
message SheetSchema { string name=1; SheetMeta meta=2; repeated Field fields=3; }
message TableSchema { string name=1; repeated SheetSchema sheets=2; }
message SheetData   { string table=1; string sheet=2; repeated bytes data=3; }
message ConfigTables{ string version=1; string header_hash=2;
                      repeated TableSchema schemas=3; repeated SheetData datas=4; }
```

每列資料的 protobuf field number 來自 schema 中的 `pb_index`。解析順序是先讀 schema，再用該 schema 解 data，不需要猜欄位。

## Repo 解析工具

- `tools/parse_lqc.py`：列出 table／sheet／row count，或依關鍵字查 schema。
- `tools/dump_sheet.py`：依 embedded schema 解出指定 sheet。

```bash
python3 tools/parse_lqc.py /path/to/lqc.lqbin
python3 tools/parse_lqc.py /path/to/lqc.lqbin mjp
python3 tools/dump_sheet.py /path/to/lqc.lqbin item_definition.view 20
```

原始 `lqc.lqbin` 不提交進 repo；引用統計前應依 live manifest 重抓並重跑，不能只複製本文件數字。

## 外觀資料

`item_definition.view` 目前 450 rows。主要 `res_name` prefix fresh 統計：

| prefix | rows | 用途線索 |
|--------|-----:|----------|
| `tablecloth_` | 70 | 牌桌布 |
| `effect_` | 62 | 特效 |
| `liqi_` | 61 | 立直棒 |
| `mjp_` | 57 | 牌背 |
| `sxz_` | 56 | 裝飾 |
| `ron_` | 55 | 和牌特效 |
| `hand_` | 27 | 手部 |
| `beijing_` | 21 | 背景 |
| `headframe_` | 15 | 頭像框 |
| `mjpface_` | 3 | 牌面 |

常用樣本：

```text
305725  mjpface_default
305015  mjp_yellow
305016  mjp_green
305017  mjp_rosered
305045  mjp_default
```

配置／協定可以切換帳號已擁有的整套牌面或牌背。這不是推薦牌高亮介面；Naki 的單張推薦高亮走 WebGL draw hook，兩者不可混為一談。

## 其他已解析表

| sheet | rows | 用途 |
|-------|-----:|------|
| `item_definition.item` | 1,093 | 道具總表 |
| `item_definition.skin` | 488 | 角色皮膚 |
| `desktop.matchmode` | 52 | 對局模式 |
| `desktop.friend_room` | 17 | 友人房規則 |
| `desktop.field_spell` | 15 | 場地效果 |
| `achievement.achievement` | 566 | 成就 |

`desktop.matchmode` 的 runtime cross-check 仍支持 mode 1 = 東風、mode 2 = 半莊。友人房 `pre_rule` 應由當前 `desktop.friend_room` 查合法值，不把歷史硬編碼清單當長期 API。

## 安全邊界

- 下載與解析公開資源是唯讀。
- `fetchAllCommonViews` 等 lobby query 需要正確 `/gateway`；在對局線送出會失敗。
- `useCommonView`／`saveCommonViews` 會改帳號外觀，不屬唯讀查詢，執行前必須明確確認且只用測試帳號。
