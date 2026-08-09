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
# 先過「發布前決策 gate」（見下）、先把 release notes 寫好，再跑：
bash .claude/skills/release-manager/scripts/release.sh <version> --yes --notes-file notes.md
# version 不帶 v，例如 2.7.1
```

**`--notes-file` 要帶。** 沒帶不會壞，但 release 頁只會有下載表格與 changelog 連結。
notes 怎麼寫見下面「release notes 是寫出來的」。

腳本會 preflight（工作樹乾淨、版本沒撞 tag、gh 授權、MortalSwift pin 提示）→ **test（NakiTests）**
→ **bump 三處版本** → build（macOS Release + **iOS device archive**）→ package（DMG 含
/Applications 捷徑、ZIP、**IPA**）→ commit → tag → push origin main + tag → gh release。
**push origin main 要用戶明示授權**（全域規則）；`--yes` 只跳互動確認，不代表授權 push。

2026-08-07 修正的三件事（順序不要再改回去）：

- **bump 必須排在 build 之前。** 舊版是 build → package → bump，於是打包出去的 binary
  帶的是**上一版**版本號。腳本自己當時還印著「版本此時還是舊號，稍後 bump」。
  現在 build 之後會用 `PlistBuddy` 讀產物的 `CFBundleShortVersionString` 比對，
  對不上就非零退出——同一個坑不靠人記得。
- **測試是門禁。** 只跑 `-only-testing:NakiTests`：`-scheme Naki` 會連 `NakiUITests`
  一起跑，而那個要啟真 App、綁 8765、載 live Majsoul WebGL（走 CDN），
  拿它當發布門禁等於把發布綁在網路與 live 頁面上。
- **iOS 要編一次。** `command/` 是兩個 target 共用的，而 `ContentView.swift` 的
  `iOSLayout` 有一百多行只在 iOS 編譯；在此之前所有文件化的指令都只 build
  `-scheme Naki`，那段程式碼一次都碰不到。`Naki-M.xcscheme` 已補進
  `xcshareddata`（先前只靠 Xcode autocreate，clean clone 不一定有）。

2026-08-09 加的一件事：

- **iOS 產出 IPA。** 那一步從 `-sdk iphonesimulator` 的編譯驗證，換成
  `-destination 'generic/platform=iOS'` 的 `xcodebuild archive`，因為 simulator 產物是
  arm64-simulator，**裝不到手機上**。archive 之後把 `.app` 包成
  `Payload/<App>.app` 再 zip 成 `dist/Naki-M.ipa`（`Payload` 這個目錄名是側載工具認的，
  不能改），並掛進 `gh release`。IPA 走 `CODE_SIGNING_ALLOWED=NO` **刻意不簽名**——
  Naki 沒有 App Store 管道，使用者用 AltStore / Sideloadly 自行簽名安裝。
  archive 產物同樣做 `CFBundleShortVersionString` 比對，理由與 macOS 那道一樣：
  IPA 的版本號沒人會去點開看。

bump 之後有 `trap` 保護：任何一步失敗都會 `git checkout` 還原三個版本號檔案，
不留下「版本已改、但沒 commit 也沒產物」的中間狀態（那會讓下次 preflight 擋下自己）。

## 發錯版本號怎麼收（2026-08-09 實作過一次）

2.10.0 這批含新功能（區服選擇），一開始發成了 `2.9.1`。semver 上新功能是 MINOR
不是 PATCH，所以撤掉重發。

**「別刪已 push 的 tag」是預設，不是絕對。** 那條規則保護的是「別人手上的 ref 跟遠端
對不上」，所以刪之前先確認那個前提不成立：

```bash
gh release view v<版本> --repo Sunalamye/Naki --json assets,createdAt \
  --jq '(.assets[] | "\(.name): 下載 \(.downloadCount) 次")'
gh repo view Sunalamye/Naki --json forkCount --jq .forkCount
```

**下載數全 0 且 forks 0** 才刪。有任何一個資產被下載過，就別刪——改用下一個版本號。

撤除的順序（release 先於 tag，否則 GitHub 上會留一個指向不存在 tag 的 release）：

```bash
gh release delete v<版本> --repo Sunalamye/Naki --yes
git push --delete origin v<版本>
git tag -d v<版本>
```

**`chore: Release v<舊版本>` 那個 commit 留著不動。** 它已經 push 出去了，改寫已推送的
歷史要 force push，而那是全域硬規則。版本號的真相由 tag 決定——歷史裡留一個沒有 tag
的 release commit，比 force push 乾淨。重發之後版本序列會長成
`2.9.0 → (2.9.1 無 tag) → 2.10.0`，那是誠實的紀錄。

重發就是正常跑一次 `release.sh`：它會從 `2.9.1` bump 到 `2.10.0`，PREV_TAG 自動回到
`v2.9.0`（因為 v2.9.1 已不存在），changelog 連結不會指向死 tag。

**時間成本**：刪 tag 是幾秒鐘的事，但重發要完整跑一遍 test + 兩個 build + 打包，
約 8–10 分鐘。「改個 tag 應該很快」在這裡不成立。

## release notes 是寫出來的，不是 `git log` 倒出來的

2.9.0 的第一版 notes 是機械生成的，長這樣：14 條 raw commit 標題倒在最上面
（第一條 `chore: bump 2.9.0`），下載表格被壓到最底下。點進 release 頁的人要的是
**「這版對我有什麼差別」**跟**「檔案在哪」**——commit 標題兩者都答不出來，
它是寫給改程式碼的人看的。

所以腳本現在不生成改動清單了：`--notes-file` 帶一份寫好的 markdown 進來，
沒帶就只有下載表格與 changelog 連結（寧可少講，也不要用雜訊充版面）。

寫的時候：

- **下載表格擺最前面**，含平台需求與「未簽名要怎麼裝」
- 用**使用者看得到的差別**破題，不是用改了哪個檔案。
  例：「iPhone 上的牌桌只佔中間一小塊，左右各 25% 黑邊」→ 為什麼 → 現在如何
- 修復講**症狀**（「一碰畫面就崩潰」），不講 commit 標題（「移除隱式動畫」）
- **已知限制要寫**。未簽名 IPA、沒有實機驗證的東西、預設關閉的功能——
  這些寫出來比事後收 issue 便宜
- 完整 changelog 給連結就好，不要展開

v2.9.0 的成品可以當範本：https://github.com/Sunalamye/Naki/releases/tag/v2.9.0

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
- Tag exists → 換版本號。**已 push 的 tag 預設不刪**，除非下面那個判準成立
- release binary 少 AI 修正 → 漏了決策 gate 2；push MortalSwift + re-pin 再重發

---

**Release Manager v2.0** — 硬化版，MortalSwift-dependency-first + 上次踩坑固化

## LookInsideServer 閃退（2026-08-05 記錄，2026-08-09 已不復現）

當時的症狀：LookInsideServer.framework 被連進 target，Release 的 ad-hoc 簽名（`-`）
與該 framework 的 Team ID 不符 → **Release 版啟動即 SIGABRT**（dyld 拒載），
而 Debug 正常，所以 build/test 全綠也看不出來。

**2026-08-09 複驗：不再復現。** 兩項證據——`grep LookInside Naki.xcodeproj/project.pbxproj`
零命中（framework 已不在 target 裡）；Release build 實際啟動後進程存活、自己綁住 8765、
`/status` 回 `running` 且 `logFile` 指向 host（不是 CoreSimulator）。

那次複驗踩到一個假陽性值得記著：**simulator 裡跑著的 Naki-M 會先佔住 8765**，
於是 `curl /status` 回的是 simulator 那個 app 的狀態，看起來像 macOS 版活得好好的。
分辨方法是看回應裡的 `logFile`／`eventLog` 路徑有沒有 `CoreSimulator`。
smoke test 前先 `xcrun simctl shutdown booted` + `pkill -x Naki`，並用
`lsof -nP -iTCP:8765 -sTCP:LISTEN` 確認沒人佔。

「build 成功」不代表「啟動成功」這句仍然成立，只是這個特定成因已經消失。
