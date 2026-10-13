#!/bin/bash
# 用法：bash scripts/ui-token-gate.sh [repo 根目錄]（預設腳本所在 repo）
# WP-A 清理閘＋WP-B 動效閘：0 hit 才算過。
# 排除：TileImage.swift 整檔（牌身）；標有「實測對齊值」的行（WebSocket 膠囊，實測對齊值，WP-E 實機驗收後決定）。
ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT/command/Views" || exit 2
files=$(ls *.swift | grep -v '^TileImage.swift$')
fail=0
check() { local name=$1; shift; local out; out=$("$@" | grep -v '實測對齊值'); if [ -n "$out" ]; then echo "FAIL $name"; echo "$out"; fail=1; else echo "PASS $name (0 hit)"; fi; }
check spacing-padding grep -nE '(spacing|minLength):([^)]*[^A-Za-z0-9_.])?[1-9]|\.padding\(([^)]*[^A-Za-z0-9_.])?[1-9]' $files
check cornerRadius grep -nE 'cornerRadius: *[0-9]' $files
check opacity grep -nE '\.opacity\([^)]*[0-9]\.[0-9]' $files
# 裸狀態色：排除 PanelLayout 定義行、註解行與 categoryColor 函式體
check colors awk '
  FNR==1 { inCat=0 }
  /var categoryColor/ { inCat=1 }
  inCat && /^    \}[ ]*$/ { inCat=0; next }
  !inCat && !/static let (danger|warning|success|info|neutral)/ && !/^[ ]*\/\// \
    && /(^|[^A-Za-z0-9_])\.(red|orange|green|blue|gray|yellow)([^A-Za-z0-9_]|$)|Color\.(red|orange|green|blue|gray|yellow)/ \
    { print FILENAME ":" FNR ":" $0 }' $files
# 動效（WP-B）：時長只在 PanelLayout 定義；入口外無 reduceMotion 分支；含 WebView 的版面區段（macOS Layout 到 Game Panel）不掛隱式動畫
durations() { grep -n 'duration:' $files | grep -v 'static let [a-zA-Z]*: Animation = '; }
reduceBranches() { grep -nE 'reduceMotion \?|if !?reduceMotion' $files | grep -v 'reduceMotion ? nil : base'; }
check motion-duration durations
check motion-reduce-branch reduceBranches
check motion-webview-subtree awk '/MARK: - macOS Layout/ { on=1 } /MARK: - Game Panel/ { on=0 } on && /^[ ]*\.animation\(/ { print FILENAME ":" FNR ":" $0 }' ContentView.swift
exit $fail
