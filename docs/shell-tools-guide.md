# Shell Tools 使用指南

## ⚠️ 重要：AI Agent 必須遵守的 Shell 工具使用規範

本指南定義了 AI Agent 在執行命令列操作時應使用的現代化工具，以提高效率和準確性。

## 📋 工具使用對照表

| 任務類型 | 必須使用 | 禁止使用 | 版本 |
|---------|---------|----------|------|
| 查找檔案 | `fd` | `find`, `ls -R` | 10.3.0 |
| 搜尋文字 | `rg` (ripgrep) | `grep`, `ag` | 14.1.1 |
| 程式碼結構分析 | `ast-grep` | `grep`, `sed` | 0.40.0 |
| 互動式選擇 | `fzf` | 手動過濾 | 0.66.1 |
| 處理 JSON | `jq` | `python -m json.tool` | 1.7.1 |
| 處理 YAML/XML | `yq` | 手動解析 | 4.48.1 |

## 🛠 工具詳細說明

### 1. fd - 快速檔案查找

**用途**：取代傳統 `find` 命令，更快且預設忽略 `.gitignore` 中的檔案

**使用範例**：
```bash
# 查找所有 Swift 檔案
fd -e swift

# 在特定目錄查找
fd "ViewController" Naki/

# 查找包含特定模式的檔案名
fd "Bridge"

# 顯示隱藏檔案
fd -H "config"

# 區分大小寫搜尋
fd -s "ViewModel"
```

### 2. rg (ripgrep) - 高效文字搜尋

**用途**：取代 `grep`，極快的搜尋速度，自動遵循 `.gitignore`

**使用範例**：
```bash
# 基本搜尋
rg "func authenticate"

# 只在 Swift 檔案中搜尋
rg "ViewModel" -t swift

# 顯示上下文（前後各 3 行）
rg "TODO" -C 3

# 忽略大小寫
rg -i "observable"

# 搜尋多個模式
rg -e "@Observable" -e "@Published"

# 只顯示檔案名
rg -l "MajsoulBridge"

# 反向搜尋（不包含的行）
rg -v "deprecated"

# 使用正則表達式
rg "func \w+\(.*\) async"
```

### 3. ast-grep - 程式碼結構分析

**用途**：基於抽象語法樹的程式碼搜尋，理解程式碼語義而非純文字匹配

**使用範例**：
```bash
# 查找所有 async 函數
ast-grep --pattern 'func $FUNC($$) async'

# 查找特定類別的方法
ast-grep --pattern 'class $CLASS { $$ func $METHOD($$) $$ }'

# 在 Swift 檔案中搜尋
ast-grep -l swift --pattern '@Observable'

# 結構化搜尋 published 屬性
ast-grep --pattern '@Published var $VAR: $TYPE'
```

### 4. fzf - 互動式模糊查找

**用途**：互動式命令列模糊查找工具，可與其他命令組合使用

**使用範例**：
```bash
# 模糊查找檔案
fd -t f | fzf

# 查找並開啟檔案
vim $(fzf)

# 與 git 結合查找 commit
git log --oneline | fzf

# 多選模式
fd -t f | fzf -m

# 預覽模式
fzf --preview 'cat {}'
```

### 5. jq - JSON 處理器

**用途**：強大的 JSON 查詢和轉換工具，常用於 API 回應分析

**使用範例**：
```bash
# 格式化 JSON
curl http://localhost:8765/bot/status | jq '.'

# 提取特定欄位
jq '.botStatus' bot_state.json

# 陣列操作
jq '.recommendations[0]' game.json

# 過濾條件
jq '.tiles[] | select(.suit == "m")'

# 轉換結構
jq '.tiles[] | {number, suit}'

# 組合多個值
jq -s '.' file1.json file2.json
```

### 6. yq - YAML/XML 處理器

**用途**：YAML 和 XML 查詢和轉換，常用於配置檔案處理

**使用範例**：
```bash
# 讀取 YAML 值
yq '.version' config.yaml

# 修改 YAML 值
yq -i '.version = "1.2.1"' config.yaml

# YAML 轉 JSON
yq -o=json config.yaml

# 提取陣列元素
yq '.services[0]' config.yaml

# 過濾條件
yq '.settings[] | select(.enabled == true)'
```

## 📝 實際應用場景

### 場景 1：查找專案中所有的 ViewController

**應使用**：
```bash
fd "ViewController" -e swift Naki/
```

**不應使用**：
```bash
find Naki/ -name "*ViewController*.swift"
```

### 場景 2：搜尋專案中的 TODO 或 FIXME 註解

**應使用**：
```bash
rg "TODO|FIXME" -t swift -C 2
```

**不應使用**：
```bash
grep -r "TODO\|FIXME" --include="*.swift" -A 2 -B 2
```

### 場景 3：分析 Debug Server 的 JSON 回應

**應使用**：
```bash
curl http://localhost:8765/bot/status | jq '.recommendations[] | {action, q_value}'
```

**不應使用**：
```bash
curl http://localhost:8765/bot/status | python -m json.tool
```

### 場景 4：查找使用 @Published 或 @Observable 的屬性

**應使用**：
```bash
rg "@Published|@Observable" -t swift -C 1
```

**或使用 ast-grep（更精確）**：
```bash
ast-grep --pattern '@Published var $VAR: $TYPE'
```

### 場景 5：找出所有異步函數

**應使用**：
```bash
rg "func.*async" -t swift
```

**或使用 ast-grep（語義層面）**：
```bash
ast-grep --pattern 'func $FUNC($$) async'
```

## ⚡️ 性能比較

| 任務 | 傳統工具 | 現代工具 | 速度提升 |
|-----|---------|---------|---------|
| 檔案搜尋 | `find` | `fd` | ~10x |
| 文字搜尋 | `grep` | `rg` | ~5-10x |
| JSON 處理 | `python -m json.tool` | `jq` | ~20x |
| 程式碼分析 | `grep` + `sed` | `ast-grep` | 語義精確度 100% |

## 使用原則

### AI Agent 必須遵守的規則：

1. **優先使用現代工具**
   - 如果工具已安裝，必須使用對應的現代工具
   - 禁止在已有更好替代方案時使用傳統命令

2. **工具未安裝時的處理**
   - 如果必要工具未安裝，先詢問使用者是否安裝
   - 提供清晰的安裝指令
   - 說明使用該工具的優勢

3. **效率優先**
   - 選擇最適合任務的工具
   - 避免過度複雜的命令組合
   - 優先考慮可讀性和可維護性

4. **錯誤處理**
   - 檢查工具是否可用
   - 提供替代方案（如果工具不可用）
   - 清晰說明錯誤原因

## 📚 延伸學習資源

- **fd**: https://github.com/sharkdp/fd
- **ripgrep**: https://github.com/BurntSushi/ripgrep
- **ast-grep**: https://ast-grep.github.io/
- **fzf**: https://github.com/junegunn/fzf
- **jq**: https://jqlang.github.io/jq/
- **yq**: https://github.com/mikefarah/yq
