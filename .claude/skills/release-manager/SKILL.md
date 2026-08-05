---
name: release-manager
description: Build, package, tag, and release Naki app to GitHub. Use when the user asks to "release", "publish", "tag", "build DMG/ZIP", or "upgrade version". Handles the complete release workflow from build to GitHub release creation.
allowed-tools: Read, Glob, Grep, Write, Edit, Bash
---

# Release Manager Skill

把 Naki 發到 GitHub（build → package → tag → push → release）。**2026-08-02 硬化版**：
把上一次真實發布踩到的坑固化進來，之後照這份跑就不用重試。

## 一句話流程

```bash
# 先過「發布前決策 gate」（見下），再跑：
bash .claude/skills/release-manager/scripts/release.sh <version> --yes
# version 不帶 v，例如 2.7.1
```

腳本會 preflight（工作樹乾淨、版本沒撞 tag、gh 授權、MortalSwift pin 提示）→ build →
package（DMG 含 /Applications 捷徑）→ bump 三處版本 → commit → tag → push origin main + tag →
gh release。**push origin main 要用戶明示授權**（全域規則）；`--yes` 只跳互動確認，不代表授權 push。

## 發布前決策 gate（腳本不做，要先想清楚）

### 1. 版本號（semver）

`git describe --tags` 看最新。**不能重用已存在的 tag**（腳本會擋）。
PATCH＝bug 修復（2.7.0→2.7.1）｜MINOR＝新功能／大重構但對外相容（2.6.0→2.7.0）｜MAJOR＝不相容。

### 2. ⚠️ MortalSwift 依賴要不要一起發（最容易漏，漏了 release 會靜默缺料）

**Naki 用 `XCRemoteSwiftPackageReference` 綁 MortalSwift（remote git tag）。**
MortalSwift 有本地未 push 的 commit／tag 時，Naki 的 Release build 會用 **remote 舊版**——
AI 修正（紅五 decode、振聽…）**不在 binary 裡，而且不報錯**。上次就是這個坑。

要包含 MortalSwift 修正，發 Naki **之前**先做：

```bash
cd ../MortalSwift
git ls-remote --tags origin                  # remote 有沒有那個 tag
git push origin <branch>:master              # 確認是 ff、8 commit 沒動 .github（別洗掉 CI）
git push origin v<x.y.z>
cd ../Naki
# re-pin：改 minimumVersion（只改 MortalSwift 那段，別動 MCPKit）→ 重解 → 提交 Package.resolved
xcodebuild -resolvePackageDependencies -project Naki.xcodeproj -scheme Naki
# 確認 Package.resolved 的 mortalswift 指到新版；它是 tracked（已從 .gitignore 移出）
```

腳本 preflight 會印目前 pin 的 revision 提醒你。不確定就先做完這步再跑 release.sh。

### 3. push 目標

`git remote -v` 確認 `origin = git@github.com:Sunalamye/Naki.git`。`gh auth status` 要是 Sunalamye。
NEVER force push、NEVER 推別人的 main。

## 上次踩到的坑（都已修進 release.sh）

| 坑 | 症狀 | 修法 |
|----|------|------|
| 舊 sed pattern 對不上檔案 | 版本**靜默沒改**（badge 是小寫 `version-`、CLAUDE.md 是 `\| App version \|`） | pattern 對齊實際檔；`MARKETING_VERSION` 有 12 處 |
| MortalSwift 依賴沒處理 | release binary 缺 AI 修正、無報錯 | 見決策 gate 2；preflight 印 pin |
| DMG 沒有 /Applications | 拖不進去 | `ln -s /Applications` 進 DMG 來源 |
| 版本撞已存在 tag | tag 失敗到一半 | preflight `git rev-parse v$VERSION` 先擋 |
| `read -p` 互動 | agent 跑不動 | `--yes` |
| 最終 URL 寫錯帳號 | 貼錯連結 | `$REPO=Sunalamye/Naki` |
| Package.resolved 沒 commit | clean clone 拿舊 revision | 腳本 `git add` 有含它 |
| 舊 instance 佔 8765 | 新 build 退到 8766 | 重啟前 `pkill -x Naki` |
| `set -u` 下 `$VAR` 緊接中文 | echo 到 CJK 前的變數（`$APP_PATH（版本…`）被誤判成 unbound variable，腳本中途死掉（2.7.2 因此改手動發布） | 變數後面接非 ASCII 一律 `${VAR}` 界定邊界；改腳本後 `grep -nP '\$[A-Za-z_][A-Za-z0-9_]*[^\x00-\x7f]'` 掃殘留 |

## Troubleshooting

- Build fails → `xcodebuild -project Naki.xcodeproj -list`
- gh not authorized → `gh auth login`（Sunalamye 帳號）
- Tag exists → 換版本號，別 `-d` 刪已 push 的 tag
- release binary 少 AI 修正 → 漏了決策 gate 2；push MortalSwift + re-pin 再重發

---

**Release Manager v2.0** — 硬化版，MortalSwift-dependency-first + 上次踩坑固化

## ⚠️ 2026-08-05 新坑（未修，發布前必查）

| 坑 | 症狀 | 修法（擇一，使用者尚未拍板） |
|----|------|------|
| LookInsideServer.framework 被連進 target，Release ad-hoc 簽名（`-`）與該 framework 的 LookInside Team ID 不符 | **Release 版啟動即 SIGABRT**（dyld: different Team IDs 拒載）；Debug 正常，所以 build/test 全綠也看不出來 | ① framework embed 改 Debug-only（正解）② 打包時 `codesign -f -s -` 重簽 ③ 打包腳本剝掉該 framework |

**當前 `dist/Naki.zip`／`Naki.dmg`（2026-08-05 深夜版）就是這個會閃退的包，不可發佈**；
修好前 release.sh 的 preflight 應加「啟動一次 Release .app 並 curl /status」的 smoke test
——「build 成功」不代表「啟動成功」，這次就是活例。
