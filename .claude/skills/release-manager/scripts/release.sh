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
[ "$BRANCH" = "main" ] || echo "⚠️  目前在 ${BRANCH}（通常應在 main）"

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
  read -p "以上檢查沒問題，繼續發布 v${VERSION}？(y/n) " -n 1 -r; echo
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

# ── 2. Test gate ─────────────────────────────────────────────
# 測試壞掉不該發布。刻意只跑 NakiTests：`-scheme Naki` 會連 NakiUITests 一起跑，
# 而那個要啟真 App、綁 8765、載 live Majsoul WebGL（走 CDN），拿它當發布門禁
# 等於把發布綁在網路與 live 頁面上。
echo "▶ Test（NakiTests）"
rm -rf build-test
xcodebuild test -project Naki.xcodeproj -scheme Naki -configuration Debug \
  -only-testing:NakiTests -derivedDataPath ./build-test \
  2>&1 | grep -E "error:|Executed .* tests|TEST (SUCCEEDED|FAILED)" | tail -3
echo "  測試通過"

# ── 3. Bump 版本（三個位置，pattern 對得上實際檔案）──────────────
#
# **必須在 build 之前。** 舊版把 build 排在 bump 前面，於是打包出去的 binary
# 帶的是**上一版**的 MARKETING_VERSION——`AppVersion.swift` 的 doc comment 正是
# 在防這件事，而腳本自己當時還印著「版本此時還是舊號，稍後 bump」。
echo "▶ Bump 版本 → $VERSION"

# bump 之後工作樹就髒了。任何一步失敗都要還原，否則會留下一個「版本號已改、
# 但沒有 commit 也沒有產物」的中間狀態，下次跑 preflight 會被自己擋下來。
BUMPED=1
rollback_bump() {
  [ "${BUMPED:-0}" = "1" ] || return 0
  echo "↩︎  發布未完成，還原版本號改動"
  git checkout -- README.md CLAUDE.md Naki.xcodeproj/project.pbxproj 2>/dev/null || true
}
trap rollback_bump EXIT INT TERM

# 3a. project.pbxproj：MARKETING_VERSION（多個 config，全改）
sed -i '' "s/MARKETING_VERSION = [0-9][0-9.]*;/MARKETING_VERSION = $VERSION;/g" Naki.xcodeproj/project.pbxproj
CNT=$(grep -c "MARKETING_VERSION = $VERSION;" Naki.xcodeproj/project.pbxproj || echo 0)
echo "  MARKETING_VERSION 改了 $CNT 處"
# 3b. README badge：badge/version-X-green（小寫 version）
sed -i '' "s#badge/version-[0-9][0-9.]*-green#badge/version-$VERSION-green#" README.md
# 3c. CLAUDE.md：| App version | X（...  —— 實際格式，不是 | Version |
sed -i '' "s/| App version | [0-9][0-9.]*/| App version | $VERSION/" CLAUDE.md
echo "  README badge / CLAUDE.md App version 已更新（有改到就會顯示在 diff）"

# ── 4. Build（Release，清乾淨；含當前 pin 的 MortalSwift）───────
echo "▶ Build（Release）"
rm -rf build dist build-ios
xcodebuild clean build -project Naki.xcodeproj -scheme Naki -configuration Release \
  -derivedDataPath ./build CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO \
  2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | tail -3
APP_PATH=$(find ./build -name "Naki.app" -type d | head -1)
[ -n "$APP_PATH" ] || { echo "❌ 找不到 Naki.app"; exit 1; }

# 版本號真的進到產物裡了嗎——bump 與 build 的順序是這支腳本踩過的坑，用事實確認。
BUILT_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
  "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo "?")
[ "$BUILT_VERSION" = "$VERSION" ] || {
  echo "❌ 產物版本號是 $BUILT_VERSION，不是 $VERSION（bump 與 build 的順序又反了？）"; exit 1; }
echo "  built: ${APP_PATH}（CFBundleShortVersionString = $BUILT_VERSION ✓）"

# iOS target 不進發布產物，但要編得過——`command/` 是兩個 target 共用的，
# 而 `ContentView.swift` 的 iOSLayout 有一百多行只在 iOS 編譯。沒有這一步，
# 那段程式碼在所有文件化的指令裡一次都碰不到。
echo "▶ Build（iOS，只驗編譯）"
xcodebuild build -project Naki.xcodeproj -scheme Naki-M -sdk iphonesimulator \
  -configuration Release -derivedDataPath ./build-ios \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO \
  2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | tail -3

# ── 5. Package DMG + ZIP ─────────────────────────────────────
echo "▶ Package"
mkdir -p dist
( cd "$(dirname "$APP_PATH")" && zip -r -y -q "$OLDPWD/dist/Naki.zip" Naki.app )
rm -rf /tmp/naki_dmg && mkdir -p /tmp/naki_dmg && cp -R "$APP_PATH" /tmp/naki_dmg/
ln -s /Applications /tmp/naki_dmg/Applications   # DMG 內要有 Applications 捷徑供拖入
hdiutil create -volname "Naki" -srcfolder /tmp/naki_dmg -ov -format UDZO dist/Naki.dmg >/dev/null
rm -rf /tmp/naki_dmg
ls -lh dist/ | awk 'NR>1{print "  "$5, $9}'

# ── 6. Commit + tag ──────────────────────────────────────────
echo "▶ Commit + tag"
git add README.md CLAUDE.md Naki.xcodeproj/project.pbxproj \
  Naki.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved 2>/dev/null || true
git commit -q -m "chore: Release v$VERSION"
git tag -a "v$VERSION" -m "Release v$VERSION"
# 版本改動已經進了 commit，rollback 的對象不存在了
BUMPED=0
echo "  commit $(git rev-parse --short HEAD) + tag v$VERSION"

# ── 7. Push（main + tag，origin=Sunalamye SSH）────────────────
echo "▶ Push origin main + v$VERSION"
git push origin main
git push origin "v$VERSION"

# ── 8. GitHub release ────────────────────────────────────────
echo "▶ GitHub release"
gh release create "v$VERSION" --repo "$REPO" --title "Naki v$VERSION" \
  --notes "$NOTES" dist/Naki.dmg dist/Naki.zip

echo "════════ ✅ Released ════════"
echo "🔗 https://github.com/$REPO/releases/tag/v$VERSION"
