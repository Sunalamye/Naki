#!/bin/bash
# release.sh — Naki 完整發布腳本（2026-08-02 硬化版，v2.0）
#
# 用法：bash release.sh <version> [--yes]
#   <version>  例如 2.7.1（**不要**帶 v 前綴）
#   --yes      非互動：跳過人工確認（agent 執行用）
#
# 這個腳本只做 Naki 這個 repo 的機械步驟。跨 repo 依賴（MortalSwift）與版本語意
# 是**決策**，由呼叫者在跑這支之前處理好——見 SKILL.md 的「發布前決策 gate」。
# 腳本會在 preflight 檢查 MortalSwift pin 有沒有落後 remote，落後就擋下來。

set -euo pipefail

VERSION="${1:-}"
YES="${2:-}"
REPO="Sunalamye/Naki"

if [ -z "$VERSION" ]; then
  echo "用法：bash release.sh <version> [--yes]（version 不帶 v，例如 2.7.1）"; exit 1
fi
if [[ "$VERSION" == v* ]]; then
  echo "❌ version 不要帶 v 前綴（腳本自己加）：傳 ${VERSION#v} 就好"; exit 1
fi

echo "════════ Naki Release v$VERSION ════════"

# ── 0. Preflight ─────────────────────────────────────────────
echo "▶ Preflight"

# 0a. 工作樹乾淨（版本 sed 之後才 commit，先要求乾淨才能區分改動）
if [ -n "$(git status --porcelain)" ]; then
  echo "❌ 工作樹不乾淨。先 commit / stash 再發布："; git status --short; exit 1
fi

# 0b. 分支
BRANCH=$(git rev-parse --abbrev-ref HEAD)
[ "$BRANCH" = "main" ] || echo "⚠️  目前在 $BRANCH（通常應在 main）"

# 0c. 版本不能撞已存在的 tag
if git rev-parse "v$VERSION" >/dev/null 2>&1; then
  echo "❌ tag v$VERSION 已存在。挑一個新版本號（git tag 看清單）。"; exit 1
fi
PREV_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "")
echo "  上一個 tag：${PREV_TAG:-（無）}"

# 0d. MortalSwift 依賴：pin 有沒有落後 remote（避免 release 靜默漏掉 AI 修正）
#     Naki 用 XCRemoteSwiftPackageReference 綁 MortalSwift；如果本地 MortalSwift 有
#     未 push 的 commit/tag，Naki 的 Release build 會用 remote 舊版 → AI 修正不在 binary 裡。
RESOLVED="Naki.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
if [ -f "$RESOLVED" ]; then
  MS_REV=$(python3 -c "import json;d=json.load(open('$RESOLVED'));print(next((p['state'].get('revision','')[:12] for p in d.get('pins',[]) if 'mortal' in p.get('identity','')),''))" 2>/dev/null || echo "")
  echo "  MortalSwift pin：${MS_REV:-（未知）}"
  echo "  ⚠️  確認這個 revision 已 push 到 MortalSwift remote，且含你要的 AI 修正。"
  echo "     （不確定就先跑 SKILL.md 的『MortalSwift 依賴先發』步驟再回來。）"
fi

# 0e. gh 授權
gh auth status >/dev/null 2>&1 || { echo "❌ gh 未授權：gh auth login"; exit 1; }

if [ "$YES" != "--yes" ]; then
  read -p "以上檢查沒問題，繼續發布 v$VERSION？(y/n) " -n 1 -r; echo
  [[ $REPLY =~ ^[Yy]$ ]] || exit 1
fi

# ── 1. Release notes（自 PREV_TAG）────────────────────────────
echo "▶ Release notes"
RANGE="HEAD"; [ -n "$PREV_TAG" ] && RANGE="$PREV_TAG..HEAD"
COMMITS=$(git log $RANGE --pretty=format:"- %s" 2>/dev/null || echo "")
NOTES=$(cat <<EOF
## Naki v$VERSION

$COMMITS

**完整 changelog**: https://github.com/$REPO/compare/${PREV_TAG:-HEAD}...v$VERSION
EOF
)

# ── 2. Build（Release，清乾淨；含當前 pin 的 MortalSwift）───────
echo "▶ Build（Release）"
rm -rf build dist
xcodebuild clean build -project Naki.xcodeproj -scheme Naki -configuration Release \
  -derivedDataPath ./build CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO \
  2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | tail -3
APP_PATH=$(find ./build -name "Naki.app" -type d | head -1)
[ -n "$APP_PATH" ] || { echo "❌ 找不到 Naki.app"; exit 1; }
BUILT_VER=$(/usr/bin/defaults read "$(cd "$(dirname "$APP_PATH")" && pwd)/Naki.app/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "?")
echo "  built app 版本：$BUILT_VER（此時還是舊版號，稍後 bump）"

# ── 3. Package DMG + ZIP ─────────────────────────────────────
echo "▶ Package"
mkdir -p dist
( cd "$(dirname "$APP_PATH")" && zip -r -y -q "$OLDPWD/dist/Naki.zip" Naki.app )
rm -rf /tmp/naki_dmg && mkdir -p /tmp/naki_dmg && cp -R "$APP_PATH" /tmp/naki_dmg/
ln -s /Applications /tmp/naki_dmg/Applications   # DMG 內要有 Applications 捷徑供拖入
hdiutil create -volname "Naki" -srcfolder /tmp/naki_dmg -ov -format UDZO dist/Naki.dmg >/dev/null
rm -rf /tmp/naki_dmg
ls -lh dist/ | awk 'NR>1{print "  "$5, $9}'

# ── 4. Bump 版本（三個位置，pattern 對得上實際檔案）──────────────
echo "▶ Bump 版本 → $VERSION"
# 4a. project.pbxproj：MARKETING_VERSION（多個 config，全改）
sed -i '' "s/MARKETING_VERSION = [0-9][0-9.]*;/MARKETING_VERSION = $VERSION;/g" Naki.xcodeproj/project.pbxproj
CNT=$(grep -c "MARKETING_VERSION = $VERSION;" Naki.xcodeproj/project.pbxproj || echo 0)
echo "  MARKETING_VERSION 改了 $CNT 處"
# 4b. README badge：badge/version-X-green（小寫 version）
sed -i '' "s#badge/version-[0-9][0-9.]*-green#badge/version-$VERSION-green#" README.md
# 4c. CLAUDE.md：| App version | X（...  —— 實際格式，不是 | Version |
sed -i '' "s/| App version | [0-9][0-9.]*/| App version | $VERSION/" CLAUDE.md
echo "  README badge / CLAUDE.md App version 已更新（有改到就會顯示在 diff）"

# ── 5. Commit + tag ──────────────────────────────────────────
echo "▶ Commit + tag"
git add README.md CLAUDE.md Naki.xcodeproj/project.pbxproj \
  Naki.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved 2>/dev/null || true
git commit -q -m "chore: Release v$VERSION"
git tag -a "v$VERSION" -m "Release v$VERSION"
echo "  commit $(git rev-parse --short HEAD) + tag v$VERSION"

# ── 6. Push（main + tag，origin=Sunalamye SSH）────────────────
echo "▶ Push origin main + v$VERSION"
git push origin main
git push origin "v$VERSION"

# ── 7. GitHub release ────────────────────────────────────────
echo "▶ GitHub release"
gh release create "v$VERSION" --repo "$REPO" --title "Naki v$VERSION" \
  --notes "$NOTES" dist/Naki.dmg dist/Naki.zip

echo "════════ ✅ Released ════════"
echo "🔗 https://github.com/$REPO/releases/tag/v$VERSION"
