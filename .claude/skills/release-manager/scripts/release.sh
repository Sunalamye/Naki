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
sed -i '' "s/| Version | [0-9.]* |/| Version | $VERSION |/" CLAUDE.md
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
