# Release 發布流程

本文件說明 Naki 專案的版本發布流程。

## 前置準備

1. 確保所有功能分支已合併到 `master`
2. 確保 `dist/` 目錄包含最新的構建產物：
   - `Naki.dmg` - macOS 安裝映像檔
   - `Naki.zip` - macOS 應用程式壓縮檔

## 發布步驟

### 1. 同步遠端更新

```bash
git fetch origin
git pull origin master
# 若有 force push 導致分歧
git reset --hard origin/master
```

### 2. 合併功能分支（如有）

```bash
git checkout master
git merge <feature-branch>
git push origin master

# 刪除已合併的分支
git branch -d <feature-branch>
git push origin --delete <feature-branch>
```

### 3. 更新 README.md

更新以下內容：
- 版本 badge：`https://img.shields.io/badge/Version-X.Y.Z-green`
- TODO 列表：標記已完成項目為 `[x]`

```bash
git add README.md
git commit -m "docs: Update README for vX.Y.Z"
git push origin master
```

### 4. 創建 Git Tag

```bash
git tag -a vX.Y.Z -m "Release vX.Y.Z"
git push origin vX.Y.Z
```

### 5. 創建 GitHub Release

```bash
gh release create vX.Y.Z \
  --title "Naki vX.Y.Z" \
  --notes "## What's Changed
- 功能更新 1
- 功能更新 2

## Downloads
- **Naki.dmg** - macOS 安裝映像檔
- **Naki.zip** - macOS 應用程式壓縮檔" \
  dist/Naki.dmg dist/Naki.zip
```

若 `gh` 未授權，先執行：
```bash
gh auth login -h github.com
# 或使用 token
echo "<your-token>" | gh auth login --with-token
```

## 版本號規則

採用 [Semantic Versioning](https://semver.org/)：

| 版本 | 說明 |
|-----|------|
| MAJOR (X) | 不相容的 API 變更 |
| MINOR (Y) | 向下相容的功能新增 |
| PATCH (Z) | 向下相容的問題修復 |

範例：
- `1.0.0` → `1.0.1`：Bug 修復
- `1.0.1` → `1.1.0`：新增功能
- `1.1.0` → `2.0.0`：重大變更

## Commit Message 規範

```
<type>: <description>

[optional body]
```

| Type | 說明 |
|------|------|
| `feat` | 新功能 |
| `fix` | Bug 修復 |
| `docs` | 文件更新 |
| `refactor` | 重構 |
| `ci` | CI/CD 相關 |
| `chore` | 其他雜項 |

## 快速發布腳本

```bash
#!/bin/bash
VERSION=$1

if [ -z "$VERSION" ]; then
  echo "Usage: ./release.sh <version>"
  echo "Example: ./release.sh 1.2.0"
  exit 1
fi

# 更新 README badge
sed -i '' "s/Version-[0-9.]*-green/Version-$VERSION-green/" README.md

# Commit 和 Tag
git add README.md
git commit -m "docs: Update README for v$VERSION"
git tag -a "v$VERSION" -m "Release v$VERSION"
git push origin master
git push origin "v$VERSION"

# 創建 Release
gh release create "v$VERSION" \
  --title "Naki v$VERSION" \
  --generate-notes \
  dist/Naki.dmg dist/Naki.zip

echo "✅ Released v$VERSION"
```

儲存為 `release.sh` 並執行：
```bash
chmod +x release.sh
./release.sh 1.2.0
```
