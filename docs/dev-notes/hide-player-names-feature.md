# 隱藏玩家名稱功能開發筆記

**日期**: 2025-12-05
**功能**: 隱藏遊戲中玩家名稱顯示
**版本**: 新增功能

---

## 目錄

1. [功能需求](#功能需求)
2. [探索過程](#探索過程)
3. [實現方案](#實現方案)
4. [代碼修改](#代碼修改)
5. [測試結果](#測試結果)
6. [對話記錄](#對話記錄)

---

## 功能需求

### 背景

用戶希望在 Naki app 中加入隱藏玩家名稱的功能，用於保護隱私或錄製時不顯示其他玩家的暱稱。

### 需求清單

- [x] 在設定頁面加入開關
- [x] 支援 MCP Server 工具控制
- [x] 支援 Debug Server HTTP endpoint
- [x] 遊戲開始時自動套用設定
- [x] 設定持久化（重啟 app 後保留）

---

## 探索過程

### 步驟 1: 探索 Majsoul WebUI 結構

首先使用 MCP 的 `execute_js` 工具探索遊戲中的對象結構：

```javascript
// 檢查 GameMgr 是否有相關設定
GameMgr.Inst.hide_desktop_name  // 發現有內建設定，但效果不明顯
```

### 步驟 2: 尋找玩家名稱顯示位置

探索 `UI_DesktopInfo` 對象，發現玩家資訊存放位置：

```javascript
// 玩家資訊陣列
uiscript.UI_DesktopInfo.Inst._player_infos
// 結構: Array(4) - 四個玩家的資訊

// 每個玩家的結構
_player_infos[i] = {
    name: Sprite,      // 名稱容器
    score: Sprite,     // 分數顯示
    score_origin: ..., // 其他屬性
    ...
}
```

### 步驟 3: 檢查名稱容器內容

深入探索 `name` 容器的結構：

```javascript
// 名稱容器是一個 Sprite，包含子節點
_player_infos[i].name._children
// 通常有 2-3 個子節點，其中包含 Text 節點顯示暱稱

// 每個子節點的 text 屬性
_player_infos[i].name._children[0].text  // 玩家暱稱
```

### 步驟 4: 測試隱藏方法

嘗試使用 `visible` 屬性隱藏名稱：

```javascript
// 隱藏單個玩家名稱
uiscript.UI_DesktopInfo.Inst._player_infos[0].name.visible = false

// 遍歷隱藏所有玩家名稱
var infos = uiscript.UI_DesktopInfo.Inst._player_infos;
for (var i = 0; i < infos.length; i++) {
    if (infos[i] && infos[i].name) {
        infos[i].name.visible = false;
    }
}
```

**測試結果**: 成功隱藏玩家名稱！

### 關於內建設定 `hide_desktop_name`

發現 Majsoul 有內建的 `GameMgr.Inst.hide_desktop_name` 設定，但：
- 設為 `true` 後調用 `refreshNames()` 效果不明顯
- 可能需要特定時機才能生效
- 決定使用直接設置 `visible` 的方式，更可靠

---

## 實現方案

### 架構設計

```
用戶操作 (設定開關 / MCP / Debug Server)
         ↓
WebViewModel.setHidePlayerNames()
         ↓
JavaScript: window.__nakiPlayerNames.setHidden()
         ↓
遍歷 _player_infos 設置 visible 屬性
```

### 自動套用機制

```
App 啟動
    ↓
定期檢查遊戲 API 是否可用 (2秒間隔)
    ↓
API 可用時，讀取 UserDefaults 中的設定
    ↓
調用 setHidePlayerNames() 套用設定
    ↓
標記已套用，避免重複執行
```

---

## 代碼修改

### 1. JavaScript API (`naki-game-api.js`)

新增 `window.__nakiPlayerNames` 模組：

```javascript
// 玩家名稱顯示控制模組
window.__nakiPlayerNames = {
    hidden: false,

    hide: function() {
        try {
            var infos = uiscript.UI_DesktopInfo.Inst._player_infos;
            if (!infos) return false;
            for (var i = 0; i < infos.length; i++) {
                if (infos[i] && infos[i].name) {
                    infos[i].name.visible = false;
                }
            }
            this.hidden = true;
            return true;
        } catch (e) {
            return false;
        }
    },

    show: function() {
        try {
            var infos = uiscript.UI_DesktopInfo.Inst._player_infos;
            if (!infos) return false;
            for (var i = 0; i < infos.length; i++) {
                if (infos[i] && infos[i].name) {
                    infos[i].name.visible = true;
                }
            }
            this.hidden = false;
            return true;
        } catch (e) {
            return false;
        }
    },

    toggle: function() {
        return this.hidden ? this.show() : this.hide();
    },

    setHidden: function(hide) {
        return hide ? this.hide() : this.show();
    },

    getStatus: function() {
        return {
            hidden: this.hidden,
            available: typeof uiscript !== 'undefined' &&
                       uiscript.UI_DesktopInfo &&
                       uiscript.UI_DesktopInfo.Inst
        };
    }
};
```

### 2. Swift API (`WebViewModel.swift`)

新增方法：

```swift
// MARK: - Player Names Visibility

/// 設置是否隱藏玩家名稱
func setHidePlayerNames(_ hide: Bool) {
    guard let page = webPage else {
        bridgeLog("[WebViewModel] Cannot set hide names: webPage is nil")
        return
    }

    let script = "window.__nakiPlayerNames?.setHidden(\(hide))"
    Task {
        do {
            let result = try await page.callJavaScript(script)
            bridgeLog("[WebViewModel] Hide player names: \(hide), result: \(String(describing: result))")
        } catch {
            bridgeLog("[WebViewModel] Error setting hide names: \(error.localizedDescription)")
        }
    }
}

/// 獲取玩家名稱顯示狀態
func getPlayerNamesStatus() async -> [String: Any]? {
    guard let page = webPage else { return nil }

    let script = "JSON.stringify(window.__nakiPlayerNames?.getStatus() || {})"
    do {
        let result = try await page.callJavaScript(script)
        if let jsonString = result as? String,
           let data = jsonString.data(using: .utf8),
           let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return json
        }
    } catch {
        bridgeLog("[WebViewModel] Error getting names status: \(error.localizedDescription)")
    }
    return nil
}

/// 自動套用隱藏名稱設定
func applyHideNamesSettingsIfNeeded() {
    guard !hasAppliedHideNamesSettings else { return }

    let hideNames = UserDefaults.standard.bool(forKey: "hidePlayerNames")
    if hideNames {
        setHidePlayerNames(true)
        hasAppliedHideNamesSettings = true
        bridgeLog("[WebViewModel] Auto-applied hide player names setting")
    }
}
```

### 3. 設定 UI (`ContentView.swift`)

在 `AdvancedSettingsSheet` 中新增隱私設定區塊：

```swift
// 隱私設定
@AppStorage("hidePlayerNames") private var hidePlayerNames: Bool = false

// 在 ScrollView 中新增 GroupBox
GroupBox {
    Toggle(isOn: $hidePlayerNames) {
        VStack(alignment: .leading, spacing: 2) {
            Text("隱藏玩家名稱")
            Text("隱藏遊戲中所有玩家的暱稱顯示")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
    .onChange(of: hidePlayerNames) { _, newValue in
        viewModel.setHidePlayerNames(newValue)
    }
} label: {
    Label("隱私設定", systemImage: "eye.slash")
}
```

### 4. Debug Server (`DebugServer.swift`)

#### HTTP Endpoints

| Endpoint | Method | 說明 |
|----------|--------|------|
| `/ui/names` | GET | 獲取玩家名稱顯示狀態 |
| `/ui/names/hide` | POST | 隱藏玩家名稱 |
| `/ui/names/show` | POST | 顯示玩家名稱 |
| `/ui/names/toggle` | POST | 切換玩家名稱顯示 |

#### MCP Tools

| 工具名稱 | 說明 |
|----------|------|
| `ui_names_status` | 獲取玩家名稱顯示狀態 |
| `ui_names_hide` | 隱藏所有玩家名稱 |
| `ui_names_show` | 顯示所有玩家名稱 |
| `ui_names_toggle` | 切換玩家名稱顯示狀態 |

---

## 測試結果

### 功能測試

| 測試項目 | 結果 |
|----------|------|
| 設定開關切換 | ✅ 通過 |
| MCP 工具控制 | ✅ 通過 |
| HTTP endpoint | ✅ 通過 |
| 自動套用設定 | ✅ 通過 |
| 設定持久化 | ✅ 通過 |

### 構建結果

```
Build succeeded
- Errors: 0
- Warnings: 1 (Swift 6 相關，不影響功能)
```

---

## 對話記錄

### 對話 1: 功能需求

**User**: 我想在app加上一個功能是隱藏 用戶名稱 幫我看一下webui 上有沒有顯示玩家名稱相關的內容

**Claude Code**:
- 使用 MCP explore 工具探索遊戲對象
- 找到 `GameMgr.Inst.hide_desktop_name` 和 `UI_DesktopInfo.Inst._player_infos`

---

### 對話 2: 測試隱藏功能

**User**: 可以測試一下 hide 嗎

**Claude Code**:
- 執行 JavaScript 測試隱藏所有玩家名稱
- 設置 `_player_infos[i].name.visible = false`

---

### 對話 3: 確認功能

**User**: 成功了

**Claude Code**: 確認隱藏功能可行，準備實現完整功能

---

### 對話 4: 實現需求

**User**: 是的 同時要在 mcp 與 debug server 中加入該功能的使用與說明

**Claude Code**:
- 實現 JavaScript API 模組
- 新增 Swift 方法
- 新增設定 UI
- 新增 HTTP endpoints
- 新增 MCP 工具
- 更新文檔

---

### 對話 5: 文檔記錄

**User**: 把這一次的調整寫成一個詳細的 md 文件 怎麼找 怎麼改 為什麼改 結果如何包含我與你的對話內容調整方向 也要記錄 放到 @docs/dev-notes 中 完成後 commit

**Claude Code**: 創建本文件並提交

---

## 相關文件

| 文件 | 修改內容 |
|------|----------|
| `command/Resources/JavaScript/naki-game-api.js` | 新增 `__nakiPlayerNames` 模組 |
| `command/ViewModels/WebViewModel.swift` | 新增隱藏名稱相關方法 |
| `command/Views/ContentView.swift` | 新增隱私設定 UI |
| `command/Services/Debug/DebugServer.swift` | 新增 endpoints 和 MCP 工具 |

---

## 後續優化建議

1. **段位隱藏**: 可以考慮同時隱藏段位顯示
2. **分數隱藏**: 可以選擇性隱藏分數
3. **快捷鍵**: 加入快捷鍵快速切換
4. **自定義文字**: 用固定文字替代真實暱稱

---

**文件創建日期**: 2025-12-05
**最後更新**: 2025-12-05
