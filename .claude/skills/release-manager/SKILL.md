---
name: release-manager
description: Build, package, tag, and release Naki app to GitHub. Use when the user asks to "release", "publish", "tag", "build DMG/ZIP", or "upgrade version". Handles the complete release workflow from build to GitHub release creation.
allowed-tools: Read, Glob, Grep, Write, Edit, Bash, mcp__XcodeBuildMCP__build_macos
---

# Release Manager Skill

This skill handles the complete release workflow for Naki, including building, packaging, tagging, and GitHub release creation.

## Release Workflow Overview

```
1. Generate Release Notes (from commits)
     ↓
2. Build App (xcodebuild)
     ↓
3. Create Packages (DMG + ZIP)
     ↓
4. Update Version (README, CLAUDE.md, project.pbxproj)
     ↓
5. Create Git Tag
     ↓
6. Push to Remote
     ↓
7. Create GitHub Release with Assets
```

## Step 0: Generate Release Notes

### Get Previous Tag

```bash
# 獲取最新的 tag
PREV_TAG=$(git describe --tags --abbrev=0)
echo "Previous tag: $PREV_TAG"
```

### List Commits Since Last Tag

```bash
# 列出自上次 tag 以來的所有 commits
git log $PREV_TAG..HEAD --oneline --pretty=format:"%s"
```

### Generate Categorized Release Notes

```bash
#!/bin/bash
# generate-release-notes.sh

PREV_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "")

if [ -z "$PREV_TAG" ]; then
  echo "No previous tag found, listing all commits"
  COMMITS=$(git log --oneline --pretty=format:"%s")
else
  echo "Commits since $PREV_TAG:"
  COMMITS=$(git log $PREV_TAG..HEAD --oneline --pretty=format:"%s")
fi

echo ""
echo "## What's Changed"
echo ""

# Features
FEATURES=$(echo "$COMMITS" | grep "^feat:" | sed 's/^feat: /- /')
if [ -n "$FEATURES" ]; then
  echo "### New Features"
  echo "$FEATURES"
  echo ""
fi

# Fixes
FIXES=$(echo "$COMMITS" | grep "^fix:" | sed 's/^fix: /- /')
if [ -n "$FIXES" ]; then
  echo "### Bug Fixes"
  echo "$FIXES"
  echo ""
fi

# Refactoring
REFACTORS=$(echo "$COMMITS" | grep "^refactor:" | sed 's/^refactor: /- /')
if [ -n "$REFACTORS" ]; then
  echo "### Refactoring"
  echo "$REFACTORS"
  echo ""
fi

# Style
STYLES=$(echo "$COMMITS" | grep "^style:" | sed 's/^style: /- /')
if [ -n "$STYLES" ]; then
  echo "### Improvements"
  echo "$STYLES"
  echo ""
fi

# Docs
DOCS=$(echo "$COMMITS" | grep "^docs:" | sed 's/^docs: /- /')
if [ -n "$DOCS" ]; then
  echo "### Documentation"
  echo "$DOCS"
  echo ""
fi

# Chore
CHORES=$(echo "$COMMITS" | grep "^chore:" | sed 's/^chore: /- /')
if [ -n "$CHORES" ]; then
  echo "### Other Changes"
  echo "$CHORES"
  echo ""
fi
```

### Example Output

Based on commits between `v2.0.0` and `HEAD`:

```markdown
## What's Changed

### New Features
- 重構 iOS 佈局，新增左側推薦面板
- 新增動作按鈕推薦高亮功能
- 新增隱藏玩家名稱功能
- 新增 MCP Server 支援，讓 Claude Code 直接操作遊戲
- 支援 iOS/macOS 跨平台 UI 設計
- 持久化保存自動打牌模式設定

### Bug Fixes
- 修復立直按鈕推薦高亮未顯示的問題
- 整合按鈕高亮到推薦系統流程

### Refactoring
- 重構 MCP 架構，實現 HTTP 調用 MCP 統一入口
- 重構推薦模式控制邏輯

### Improvements
- 優化 iPhone 推薦列表的機率顯示樣式
- 統一代碼格式和繁體中文用語

### Documentation
- 添加 WebPage.callJavaScript 需要 return 語句的重要說明
- 更新文檔使用 MCP 工具取代 curl 命令
- 新增 Apple Silicon 架構限制說明
```

## Step-by-Step Commands

### Step 1: Build Release App

```bash
# Clean and build release configuration
xcodebuild clean build \
  -project Naki.xcodeproj \
  -scheme Naki \
  -configuration Release \
  -derivedDataPath ./build \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO

# Or using MCP tool
mcp__XcodeBuildMCP__build_macos({
  projectPath: "/Users/soane/Documents/githubCio/Naki/Naki.xcodeproj",
  scheme: "Naki",
  configuration: "Release"
})
```

### Step 2: Locate Built App

```bash
# Find the built .app
APP_PATH=$(find ./build -name "Naki.app" -type d | head -1)
echo "Built app at: $APP_PATH"
```

### Step 3: Create Distribution Directory

```bash
mkdir -p dist
```

### Step 4: Create ZIP Package

```bash
# Create ZIP from .app
cd "$(dirname "$APP_PATH")"
zip -r -y ../../../dist/Naki.zip Naki.app
cd -
```

### Step 5: Create DMG Package

```bash
# Create temporary DMG directory
mkdir -p dmg_temp
cp -R "$APP_PATH" dmg_temp/

# Create DMG
hdiutil create -volname "Naki" \
  -srcfolder dmg_temp \
  -ov -format UDZO \
  dist/Naki.dmg

# Cleanup
rm -rf dmg_temp
```

### Step 6: Verify Packages

```bash
ls -lh dist/
# Should show:
# - Naki.dmg (~XX MB)
# - Naki.zip (~XX MB)
```

### Step 7: Update README Version Badge

```bash
# Replace version badge
VERSION="1.3.0"  # Set your version
sed -i '' "s/Version-[0-9.]*-green/Version-$VERSION-green/" README.md
```

### Step 8: Commit Version Update

```bash
git add README.md
git commit -m "docs: Update README for v$VERSION"
```

### Step 9: Create Git Tag

```bash
git tag -a "v$VERSION" -m "Release v$VERSION"
```

### Step 10: Push Changes and Tag

```bash
git push origin main
git push origin "v$VERSION"
```

### Step 11: Create GitHub Release

```bash
gh release create "v$VERSION" \
  --title "Naki v$VERSION" \
  --notes "$(cat <<'EOF'
## What's Changed

- Feature 1
- Feature 2
- Bug fix 1

## Downloads

- **Naki.dmg** - macOS 安裝映像檔（拖入 Applications 即可）
- **Naki.zip** - macOS 應用程式壓縮檔
EOF
)" \
  dist/Naki.dmg dist/Naki.zip
```

Or use auto-generated notes:

```bash
gh release create "v$VERSION" \
  --title "Naki v$VERSION" \
  --generate-notes \
  dist/Naki.dmg dist/Naki.zip
```

## Version Number Guidelines

採用 [Semantic Versioning](https://semver.org/)：

| 版本類型 | 格式 | 說明 | 範例 |
|---------|------|------|------|
| MAJOR | X.0.0 | 不相容的 API 變更 | 1.0.0 → 2.0.0 |
| MINOR | 0.X.0 | 向下相容的功能新增 | 1.0.0 → 1.1.0 |
| PATCH | 0.0.X | 向下相容的問題修復 | 1.0.0 → 1.0.1 |

### When to Increment

- **PATCH**: Bug 修復、小調整、文檔更新
- **MINOR**: 新功能、新 MCP 工具、UI 改進
- **MAJOR**: 架構重構、不相容的變更、重大功能

## Pre-release Checklist

Before starting the release:

- [ ] All changes committed and pushed
- [ ] All tests pass (if applicable)
- [ ] Build succeeds without errors
- [ ] No uncommitted changes: `git status`
- [ ] On correct branch (usually `main`)
- [ ] Previous release tag exists: `git tag -l`

## Quick Release Script

For convenience, run all steps:

```bash
#!/bin/bash
# release.sh - Naki 完整發布腳本
VERSION=$1

if [ -z "$VERSION" ]; then
  echo "Usage: ./release.sh <version>"
  echo "Example: ./release.sh 2.1.0"
  exit 1
fi

set -e  # Exit on error

# 獲取上一個 tag
PREV_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "")
echo "📋 Previous tag: $PREV_TAG"

# 生成 Release Notes
echo "📝 Generating release notes..."
COMMITS=$(git log $PREV_TAG..HEAD --oneline --pretty=format:"%s" 2>/dev/null || git log --oneline --pretty=format:"%s")

generate_section() {
  local prefix=$1
  local title=$2
  local items=$(echo "$COMMITS" | grep "^$prefix:" | sed "s/^$prefix: /- /")
  if [ -n "$items" ]; then
    echo "### $title"
    echo "$items"
    echo ""
  fi
}

RELEASE_NOTES=$(cat <<EOF
## What's Changed

$(generate_section "feat" "New Features")
$(generate_section "fix" "Bug Fixes")
$(generate_section "refactor" "Refactoring")
$(generate_section "style" "Improvements")
$(generate_section "docs" "Documentation")
$(generate_section "chore" "Other Changes")

## Downloads

| 檔案 | 說明 |
|-----|------|
| **Naki.dmg** | macOS 安裝映像檔（拖入 Applications） |
| **Naki.zip** | macOS 應用程式壓縮檔 |

## System Requirements

- macOS 13.0+ (Ventura)
- Apple Silicon (M1/M2/M3)
EOF
)

echo "$RELEASE_NOTES"
echo ""

# 確認繼續
read -p "Continue with release? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  exit 1
fi

echo "🔨 Building Naki..."
xcodebuild clean build \
  -project Naki.xcodeproj \
  -scheme Naki \
  -configuration Release \
  -derivedDataPath ./build \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO

APP_PATH=$(find ./build -name "Naki.app" -type d | head -1)
echo "✅ Built: $APP_PATH"

echo "📦 Creating packages..."
mkdir -p dist

# ZIP
cd "$(dirname "$APP_PATH")"
zip -r -y ../../../dist/Naki.zip Naki.app
cd - > /dev/null

# DMG
rm -rf dmg_temp
mkdir -p dmg_temp
cp -R "$APP_PATH" dmg_temp/
hdiutil create -volname "Naki" \
  -srcfolder dmg_temp \
  -ov -format UDZO \
  dist/Naki.dmg
rm -rf dmg_temp

echo "✅ Packages created:"
ls -lh dist/

echo "📝 Updating versions..."
# README.md
sed -i '' "s/Version-[0-9.]*-green/Version-$VERSION-green/" README.md
# CLAUDE.md
sed -i '' "s/\*\*Version\*\*: [0-9.]*/\*\*Version\*\*: $VERSION/" CLAUDE.md
# project.pbxproj
sed -i '' 's/MARKETING_VERSION = [0-9.]*;/MARKETING_VERSION = '"$VERSION"';/g' \
  Naki.xcodeproj/project.pbxproj

echo "🏷️ Creating tag v$VERSION..."
git add README.md CLAUDE.md Naki.xcodeproj/project.pbxproj
git commit -m "chore: Release v$VERSION"
git tag -a "v$VERSION" -m "Release v$VERSION"
git push origin main
git push origin "v$VERSION"

echo "🚀 Creating GitHub release..."
gh release create "v$VERSION" \
  --title "Naki v$VERSION" \
  --notes "$RELEASE_NOTES" \
  dist/Naki.dmg dist/Naki.zip

echo "✅ Released v$VERSION successfully!"
echo "🔗 https://github.com/soandsoprogrammer/Naki/releases/tag/v$VERSION"
```

## Troubleshooting

### Build Fails

```bash
# Check Xcode version
xcodebuild -version

# List available schemes
xcodebuild -project Naki.xcodeproj -list

# Build with verbose output
xcodebuild build -project Naki.xcodeproj -scheme Naki -configuration Release 2>&1 | tee build.log
```

### DMG Creation Fails

```bash
# Check if hdiutil is available
which hdiutil

# Check disk space
df -h

# Try with different format
hdiutil create -volname "Naki" \
  -srcfolder dmg_temp \
  -ov -format UDBZ \
  dist/Naki.dmg
```

### GitHub CLI Not Authorized

```bash
# Login to GitHub
gh auth login

# Or use token
echo "YOUR_TOKEN" | gh auth login --with-token

# Verify auth
gh auth status
```

### Tag Already Exists

```bash
# Delete local tag
git tag -d "v$VERSION"

# Delete remote tag (be careful!)
git push origin --delete "v$VERSION"
```

## File Locations

| 項目 | 路徑 |
|------|------|
| 專案檔案 | `Naki.xcodeproj` |
| 構建輸出 | `./build/` |
| 發布產物 | `./dist/` |
| 版本說明 | `RELEASE.md` |
| README | `README.md` |

## Reference Documents

- See `@RELEASE.md` for detailed release process
- See `@README.md` for version badge location
