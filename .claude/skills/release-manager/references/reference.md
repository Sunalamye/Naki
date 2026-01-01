# Release Manager Reference

## Version Locations - 所有需要更新版本的位置

**重要**: 發布新版本時，以下所有位置的版本號都需要同步更新！

### 1. README.md (Badge)

**位置**: `README.md:4`
**格式**:
```markdown
<img src="https://img.shields.io/badge/Version-X.Y.Z-green" alt="Version">
```

**更新命令**:
```bash
VERSION="2.1.0"
sed -i '' "s/Version-[0-9.]*-green/Version-$VERSION-green/" README.md
```

### 2. CLAUDE.md (Project Version)

**位置**: `CLAUDE.md:13`
**格式**:
```markdown
- **Version**: X.Y.Z
```

**更新命令**:
```bash
VERSION="2.1.0"
sed -i '' "s/\*\*Version\*\*: [0-9.]*/\*\*Version\*\*: $VERSION/" CLAUDE.md
```

### 3. Xcode Project (MARKETING_VERSION)

**位置**: `Naki.xcodeproj/project.pbxproj`
**格式**: 多處 `MARKETING_VERSION = X.Y.Z;`

**更新命令**:
```bash
VERSION="2.1.0"
# 更新主要 Naki scheme 的版本（行 651, 683）
sed -i '' 's/MARKETING_VERSION = [0-9.]*;/MARKETING_VERSION = '"$VERSION"';/g' \
  Naki.xcodeproj/project.pbxproj
```

**注意**: project.pbxproj 中有多個 target 的 MARKETING_VERSION：
- Naki (主應用) - **必須更新**
- Naki-M (測試版) - 可選
- Tests - 可選

### 4. MCP Server Version (MCPHandler.swift)

**位置**: `command/Services/MCP/MCPHandler.swift:125`
**格式**:
```swift
"version": "X.Y.Z"
```

**更新命令**:
```bash
VERSION="2.1.0"
sed -i '' 's/"version": "[0-9.]*"/"version": "'"$VERSION"'"/' \
  command/Services/MCP/MCPHandler.swift
```

---

## Complete Version Update Script

```bash
#!/bin/bash
VERSION=$1

if [ -z "$VERSION" ]; then
  echo "Usage: ./update-version.sh <version>"
  echo "Example: ./update-version.sh 2.1.0"
  exit 1
fi

echo "Updating all version references to $VERSION..."

# 1. README.md badge
sed -i '' "s/Version-[0-9.]*-green/Version-$VERSION-green/" README.md
echo "✅ README.md"

# 2. CLAUDE.md
sed -i '' "s/\*\*Version\*\*: [0-9.]*/\*\*Version\*\*: $VERSION/" CLAUDE.md
echo "✅ CLAUDE.md"

# 3. project.pbxproj (all occurrences)
sed -i '' 's/MARKETING_VERSION = [0-9.]*;/MARKETING_VERSION = '"$VERSION"';/g' \
  Naki.xcodeproj/project.pbxproj
echo "✅ project.pbxproj"

# 4. MCPHandler.swift
sed -i '' 's/"version": "[0-9.]*"/"version": "'"$VERSION"'"/' \
  command/Services/MCP/MCPHandler.swift
echo "✅ MCPHandler.swift"

echo ""
echo "🔍 Verifying changes..."
echo "README.md:"
grep -o 'Version-[0-9.]*-green' README.md
echo "CLAUDE.md:"
grep 'Version' CLAUDE.md | head -1
echo "project.pbxproj:"
grep 'MARKETING_VERSION' Naki.xcodeproj/project.pbxproj | head -2
echo "MCPHandler.swift:"
grep '"version"' command/Services/MCP/MCPHandler.swift | head -1

echo ""
echo "✅ All versions updated to $VERSION"
```

---

## Build Configuration

### Debug vs Release

| 配置 | 用途 | Code Sign |
|------|------|-----------|
| Debug | 開發測試 | 不需要 |
| Release | 發布版本 | 可選（ad-hoc 或 Developer ID） |

### Build Commands

```bash
# Debug build
xcodebuild build \
  -project Naki.xcodeproj \
  -scheme Naki \
  -configuration Debug

# Release build (unsigned)
xcodebuild build \
  -project Naki.xcodeproj \
  -scheme Naki \
  -configuration Release \
  -derivedDataPath ./build \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO

# Release build (signed with Developer ID)
xcodebuild build \
  -project Naki.xcodeproj \
  -scheme Naki \
  -configuration Release \
  -derivedDataPath ./build \
  CODE_SIGN_IDENTITY="Developer ID Application: Your Name"
```

### Build Output Locations

```
./build/Build/Products/Release/Naki.app    # Release 產物
./build/Build/Products/Debug/Naki.app      # Debug 產物
```

---

## DMG Creation Details

### Basic DMG

```bash
# 創建簡單 DMG
hdiutil create -volname "Naki" \
  -srcfolder /path/to/Naki.app \
  -ov -format UDZO \
  Naki.dmg
```

### DMG with Applications Shortcut

```bash
# 創建帶 Applications 捷徑的 DMG
mkdir -p dmg_staging
cp -R Naki.app dmg_staging/
ln -s /Applications dmg_staging/Applications

hdiutil create -volname "Naki" \
  -srcfolder dmg_staging \
  -ov -format UDZO \
  Naki.dmg

rm -rf dmg_staging
```

### DMG Formats

| 格式 | 說明 | 大小 |
|------|------|------|
| UDZO | zlib 壓縮（推薦） | 最小 |
| UDBZ | bzip2 壓縮 | 較小，較慢 |
| UDRO | 只讀 | 無壓縮 |
| UDRW | 讀寫 | 可修改 |

---

## ZIP Creation

```bash
# 創建 ZIP（保留符號連結）
cd /path/to/containing/folder
zip -r -y Naki.zip Naki.app

# 或使用 ditto（macOS 推薦）
ditto -c -k --keepParent Naki.app Naki.zip
```

---

## GitHub Release

### Using gh CLI

```bash
# 創建 release 並上傳資產
gh release create v2.1.0 \
  --title "Naki v2.1.0" \
  --notes "Release notes here" \
  dist/Naki.dmg dist/Naki.zip

# 使用自動生成的 release notes
gh release create v2.1.0 \
  --title "Naki v2.1.0" \
  --generate-notes \
  dist/Naki.dmg dist/Naki.zip

# 創建 draft release
gh release create v2.1.0 \
  --title "Naki v2.1.0" \
  --draft \
  dist/Naki.dmg dist/Naki.zip

# 創建 prerelease
gh release create v2.1.0-beta \
  --title "Naki v2.1.0 Beta" \
  --prerelease \
  dist/Naki.dmg dist/Naki.zip
```

### Release Notes Template

```markdown
## What's Changed

### New Features
- Feature 1
- Feature 2

### Improvements
- Improvement 1

### Bug Fixes
- Fix 1

## Downloads

| 檔案 | 說明 |
|-----|------|
| **Naki.dmg** | macOS 安裝映像檔（拖入 Applications） |
| **Naki.zip** | macOS 應用程式壓縮檔 |

## System Requirements

- macOS 13.0+ (Ventura)
- Apple Silicon (M1/M2/M3)

## Installation

1. 下載 `Naki.dmg`
2. 打開 DMG 文件
3. 將 Naki 拖入 Applications 資料夾
4. 首次運行可能需要在「系統偏好設定」>「安全性與隱私」中允許執行
```

---

## Git Tag Management

### Create Tag

```bash
# 創建帶註釋的 tag
git tag -a v2.1.0 -m "Release v2.1.0"

# 推送 tag
git push origin v2.1.0

# 推送所有 tags
git push origin --tags
```

### Delete Tag

```bash
# 刪除本地 tag
git tag -d v2.1.0

# 刪除遠端 tag
git push origin --delete v2.1.0
```

### List Tags

```bash
# 列出所有 tags
git tag -l

# 列出匹配模式的 tags
git tag -l "v2.*"

# 查看 tag 詳情
git show v2.1.0
```

---

## Current Version Status

**最後檢查**: 2025-12-05

| 位置 | 當前版本 | 需要同步 |
|------|---------|---------|
| README.md | 2.0.0 | ✅ |
| CLAUDE.md | 1.2.0 | ⚠️ 需更新 |
| project.pbxproj | 1.1.2 | ⚠️ 需更新 |
| MCPHandler.swift | 2.0.0 | ✅ |

**建議**: 在下次發布前，先同步所有版本號到最新版本。

---

## Checklist for Each Release

### Pre-release
- [ ] 確認所有變更已 commit
- [ ] 確認在正確的分支 (main/master)
- [ ] 執行 `git pull` 同步遠端

### Version Update
- [ ] 更新 README.md badge
- [ ] 更新 CLAUDE.md version
- [ ] 更新 project.pbxproj MARKETING_VERSION
- [ ] 更新 MCPHandler.swift version

### Build & Package
- [ ] Clean build 成功
- [ ] 創建 dist/ 目錄
- [ ] 生成 Naki.zip
- [ ] 生成 Naki.dmg
- [ ] 驗證包大小合理

### Git Operations
- [ ] Commit 版本更新
- [ ] 創建 tag
- [ ] Push commits
- [ ] Push tag

### GitHub Release
- [ ] 創建 release
- [ ] 上傳 DMG 和 ZIP
- [ ] 編寫 release notes
- [ ] 驗證下載連結有效
