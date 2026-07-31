# 📚 Naki 文檔中心

本目錄包含 Naki 專案的所有技術文檔。

**最後更新**: 2026-07-31

> ⚠️ **2026-07-31：雀魂已改用 Unity WebGL**（`chs_t-WebGL-release-4.0.45(45)`）。
> 所有 Laya JS 物件（`GameMgr` / `DesktopMgr` / `uiscript` / `cfg` / `NetAgent` / `Laya`）
> **實測不存在**。互動一律改走 Liqi protobuf →
> [majsoul-unity-protocol.md](majsoul-unity-protocol.md)。

---

## 📖 文檔分類

### 🎯 用戶指南

| 文檔 | 說明 | 行數 |
|------|------|------|
| [mcp-server-guide.md](mcp-server-guide.md) | MCP Server 完整指南，47 個工具 | 257 |

### 🏗 架構與技術

| 文檔 | 說明 | 行數 |
|------|------|------|
| [majsoul-unity-protocol.md](majsoul-unity-protocol.md) | ⭐ **Unity 時代唯一有效的雀魂互動參考**（Liqi envelope、攔截/注入、PoC、未驗證項） | 300 |
| [architecture-deep-dive.md](architecture-deep-dive.md) | 架構深度詳解、協議轉換、服務初始化 | 265 |

### ⛔ 已作廢（Laya 時代存檔）

只保留協議層線索與歷史骨架，**程式碼片段一律不可照抄**。完整原文在 git history。

| 文檔 | 狀態 | 行數 |
|------|------|------|
| [majsoul-webui-objects-reference.md](majsoul-webui-objects-reference.md) | 已作廢改寫（原 2,157 行 Laya 物件參考） | 226 |
| [majsoul-webui-api-architecture.md](majsoul-webui-api-architecture.md) | 已作廢改寫（原 1,410 行 API 架構） | 172 |
| [majsoul-minigame-snowball-reference.md](majsoul-minigame-snowball-reference.md) | 已作廢（依賴 `cfg` / `uiscript`）；規則數值仍可參考 | 600 |

### 🛠 開發工具

| 文檔 | 說明 | 行數 |
|------|------|------|
| [shell-tools-guide.md](shell-tools-guide.md) | 現代 Shell 工具使用規範 | 262 |
| [debug-api-help-endpoint.md](debug-api-help-endpoint.md) | Debug Server API 說明 | 396 |

### 📝 開發筆記

| 文檔 | 說明 |
|------|------|
| [dev-notes/](dev-notes/) | 功能開發過程記錄 |
| [claude-md-refactoring-journal.md](claude-md-refactoring-journal.md) | CLAUDE.md 重構歷程 |

---

## 🎯 快速導航

### 我想...

| 目標 | 查看文檔 |
|------|---------|
| 配置 Claude Code | [mcp-server-guide.md](mcp-server-guide.md) |
| 理解架構設計 | [architecture-deep-dive.md](architecture-deep-dive.md) |
| **和雀魂互動（讀狀態 / 送動作）** | [majsoul-unity-protocol.md](majsoul-unity-protocol.md) |
| 調試應用 | [debug-api-help-endpoint.md](debug-api-help-endpoint.md) |
| 使用 Shell 工具 | [shell-tools-guide.md](shell-tools-guide.md) |
| 查 Laya 時代舊做法（僅考古） | [majsoul-webui-objects-reference.md](majsoul-webui-objects-reference.md) |

---

## 📊 統計

| 類別 | 文檔數 | 總行數 |
|------|--------|--------|
| 用戶指南 | 1 | 257 |
| 架構與技術（現行） | 2 | 565 |
| 已作廢存檔 | 3 | 998 |
| 開發工具 | 2 | 440 |
| 開發筆記 | 2+ | ~1,400 |

（作廢改寫後，Laya 相關文件由 ~3,570 行縮至 998 行；原文可由 git history 取回。）

---

## 🔄 文檔維護

### 更新頻率

- **mcp-server-guide.md** - 每次新增 MCP 工具時更新
- **architecture-deep-dive.md** - 架構變更時更新
- **majsoul-unity-protocol.md** - 每次抓到新的實測封包 / 驗證新方法時更新
- **shell-tools-guide.md** - 工具版本更新時檢查

### 已知問題

- ⛔ `majsoul-webui-*.md` 與 `majsoul-minigame-*.md` **已作廢**（雀魂 4.0.45 換 Unity WebGL）
- `majsoul-unity-protocol.md` 中「尚未驗證的部分」佔比不小，引用前務必看標註
- dev-notes 部分文件為開發中記錄，可能不完整

---

**維護者**: Claude Code + User
