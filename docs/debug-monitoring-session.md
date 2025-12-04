# Naki Debug Server 監控方法文檔

> 記錄日期: 2025-12-03
> 作者: Claude Code AI Assistant

## 目錄

1. [背景與需求](#背景與需求)
2. [發現 Debug Server](#發現-debug-server)
3. [監控方法詳解](#監控方法詳解)
4. [好處與壞處分析](#好處與壞處分析)
5. [對話記錄與調整過程](#對話記錄與調整過程)
6. [監控結果摘要](#監控結果摘要)
7. [API 參考](#api-參考)

---

## 背景與需求

### 用戶需求
用戶要求：
> "幫我持續觀測 log 與 ui 的變化 可以打 localhost/help 這個 api 查詢如何使用"

### 任務目標
1. 找到正確的 API 端點
2. 查詢 API 使用說明
3. 持續監控 log 和遊戲狀態變化
4. 即時回報 Bot 的操作

---

## 發現 Debug Server

### 第一步：嘗試 localhost/help

最初嘗試直接調用 `http://localhost/help`，但失敗了：
- Port 80 沒有服務
- 嘗試常見端口 (8080, 3000, 5000, 8000) 也失敗

### 第二步：搜尋專案結構

使用 Glob 工具搜尋 Swift 文件：
```
**/*.swift
```

發現 `DebugServer.swift` 文件：
```
/Users/soane/Documents/githubCio/Naki/Naki/Services/Debug/DebugServer.swift
```

### 第三步：閱讀源碼找到端口

從 `DebugServer.swift` 第 44 行找到：
```swift
init(port: UInt16 = 8765) {
    self.port = port
}
```

**結論**: Debug Server 運行在 **port 8765**

### 第四步：驗證端點

```bash
curl -s http://localhost:8765/help
```

成功返回 JSON 格式的 API 文檔！

---

## 監控方法詳解

### 方法一：單次查詢

最簡單的監控方式，適合偶爾檢查：

```bash
# 查詢 Bot 狀態
curl -s http://localhost:8765/bot/status

# 查詢日誌
curl -s http://localhost:8765/logs
```

### 方法二：輪詢監控（採用的方式）

使用 shell 循環定期輪詢：

```bash
for i in 1 2 3 4 5 6 7 8; do
  curl -s http://localhost:8765/bot/status 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
gs=d['gameState']
rec=d['recommendations']
r=f' → {rec[0][\"tile\"]}' if rec else ''
print(f'{gs[\"bakaze\"]}{gs[\"kyoku\"]}局{gs[\"honba\"]}本 手牌:{d[\"tehaiCount\"]} 自摸:{d[\"tsumoTile\"] or \"-\"}{r}')
" 2>/dev/null
  sleep 2.5
done
```

### 方法三：日誌過濾

過濾掉 Request 日誌，只顯示有意義的操作：

```bash
curl -s http://localhost:8765/logs | python3 -c "
import json,sys
d=json.load(sys.stdin)
for l in d['logs'][-20:]:
    if 'Request:' not in l:
        msg = l.split(']')[1].strip() if ']' in l else l
        print(msg)
"
```

### 為什麼選擇輪詢方式？

1. **Debug Server 不支援 WebSocket** - 無法使用推送通知
2. **HTTP API 設計** - 適合請求/響應模式
3. **簡單可靠** - 不需要額外依賴
4. **可控制頻率** - 通過 sleep 調整輪詢間隔

---

## 好處與壞處分析

### 好處

| 項目 | 說明 |
|------|------|
| **即時性** | 每 2-3 秒更新一次狀態，能即時看到 Bot 操作 |
| **簡單** | 使用標準工具 (curl, python3)，無需安裝額外套件 |
| **非侵入式** | 只讀取狀態，不影響遊戲運行 |
| **可定制** | 可調整輪詢頻率、過濾條件、輸出格式 |
| **跨平台** | 任何有 curl 的環境都能使用 |
| **完整資訊** | 可獲取遊戲狀態、手牌、推薦、日誌等所有資訊 |

### 壞處

| 項目 | 說明 |
|------|------|
| **輪詢開銷** | 持續發送 HTTP 請求會產生少量開銷 |
| **非即時** | 有 2-3 秒延遲，可能錯過快速操作的瞬間狀態 |
| **日誌混入** | Request 日誌會混入真正的操作日誌 |
| **需要手動啟動** | 每次監控都要手動執行命令 |
| **無法監控 UI** | 只能監控數據，無法直接看到 UI 變化（這是 macOS App，不是模擬器） |
| **JSON 解析錯誤** | 當服務器重啟或忙碌時，可能返回空響應導致解析失敗 |

### 改進建議

1. **增加錯誤處理** - 捕獲 JSON 解析錯誤
2. **WebSocket 支援** - 未來可考慮在 Debug Server 增加 WebSocket 推送
3. **日誌分類** - 將 Request 日誌分開存儲，便於過濾
4. **監控腳本** - 封裝成專門的監控腳本，方便重複使用

---

## 對話記錄與調整過程

### 對話 1：初始需求

**用戶**:
> 幫我持續觀測 log 與 ui 的變化 可以打 localhost/help 這個 api 查詢如何使用

**AI 理解**:
- 需要找到 API 端點
- 需要持續監控日誌和狀態

### 對話 2：發現問題

**AI 嘗試**:
1. 調用 `localhost/help` → 失敗（port 80 無服務）
2. 嘗試常見端口 → 失敗
3. 搜尋專案 Swift 文件 → 發現 `DebugServer.swift`
4. 讀取源碼 → 找到 port 8765
5. 驗證 `localhost:8765/help` → 成功！

### 對話 3：用戶澄清

**用戶**:
> 不需要開模擬器

**AI 調整**:
- 這是 macOS App，不是 iOS App
- 不需要使用模擬器相關工具
- 專注於 HTTP API 監控

### 對話 4：監控實施

**AI 行動**:
1. 調用 `/help` 獲取 API 文檔
2. 調用 `/logs` 獲取日誌
3. 調用 `/bot/status` 獲取 Bot 狀態
4. 使用 shell 循環持續輪詢

### 對話 5：文檔需求

**用戶**:
> 你是怎麼監控的 為什麼這樣監控 有什麼好處 壞處是什麼
> 把這一次的調整寫成一個詳細的 md 文件 怎麼找 怎麼改 為什麼改 結果如何包含我與你的對話內容調整方向 也要記錄
> 放到 docs 中

**AI 行動**:
- 撰寫本文檔，記錄完整過程

---

## 監控結果摘要

### 遊戲進度

| 時間 | 遊戲狀態 | Bot 操作 | 結果 |
|------|---------|---------|------|
| 06:47 | 東1局0本 | 打出 N（北） | ✅ |
| 06:48 | 東1局0本 | 打出 9p（筒九） | ✅ |
| 06:48 | 東1局0本 | 打出 9m（萬九） | ✅ |
| 06:49 | 東1局0本 | 吃 (chi) 操作 | ✅ |
| 06:49 | 東1局0本 | 打出 8s（索八） | ✅ |
| 06:49 | 東1局0本 | 碰 (pon) 操作 | ✅ |
| 06:56 | 東1局0本 | 和牌 (hora) | ✅ |
| 06:56 | 東1局1本 | 新局開始 | - |
| 06:57 | 東1局1本 | 吃 (chi) 操作 | ✅ |

### 觀察到的問題

1. **oplist 超時**: 偶爾出現 "No oplist after 30 attempts" 錯誤
2. **Server 重啟**: Debug Server 曾重啟，導致日誌清空
3. **JSON 解析失敗**: 服務器忙碌時返回空響應

### Bot 運作評估

- **整體運作**: 正常 ✅
- **打牌操作**: 成功率 100%
- **副露操作**: 吃碰都能正常執行
- **和牌判斷**: 正確識別並執行

---

## API 參考

### 主要端點

| 端點 | 方法 | 說明 |
|------|------|------|
| `/` | GET | HTML 首頁 |
| `/help` | GET | JSON 格式 API 文檔 |
| `/status` | GET | 服務器狀態 |
| `/logs` | GET | 獲取日誌 |
| `/bot/status` | GET | Bot 狀態（推薦用於監控） |
| `/bot/trigger` | POST | 手動觸發自動打牌 |
| `/game/state` | GET | 遊戲狀態 |
| `/game/hand` | GET | 手牌資訊 |
| `/game/ops` | GET | 可用操作 |

### 快速監控命令

```bash
# 一次性查看所有狀態
curl -s http://localhost:8765/bot/status | python3 -m json.tool

# 查看最新 10 條日誌
curl -s http://localhost:8765/logs | python3 -c "
import json,sys
d=json.load(sys.stdin)
for l in d['logs'][-10:]:
    print(l)
"

# 持續監控（每 3 秒）
while true; do
  clear
  echo "=== Bot Status ==="
  curl -s http://localhost:8765/bot/status | python3 -m json.tool
  echo ""
  echo "=== Recent Logs ==="
  curl -s http://localhost:8765/logs | python3 -c "
import json,sys
d=json.load(sys.stdin)
for l in d['logs'][-5:]:
    if 'Request:' not in l:
        print(l.split(']')[1].strip() if ']' in l else l)
"
  sleep 3
done
```

---

## 結論

本次監控任務成功達成以下目標：

1. ✅ 找到正確的 API 端點（port 8765）
2. ✅ 獲取完整的 API 使用文檔
3. ✅ 實現持續監控 log 和 Bot 狀態
4. ✅ 觀察到 Bot 正常運作（打牌、副露、和牌）
5. ✅ 記錄完整的監控過程和方法

監控方式雖然是輪詢而非即時推送，但對於 Debug 和開發階段來說已經足夠實用。未來如有需要更即時的監控，可考慮在 Debug Server 中增加 WebSocket 支援。
