#!/usr/bin/env bash
#
# 雲端推論異常監看：在你還沒發現之前，用 macOS 通知告訴你。
#
# 監看當次 session 的 events.log，命中以下模式就彈通知＋記錄：
#   1. 「null reaction」        — 事件流與伺服器脫節（2026-08-05 起幻覺窗口已
#                                 在源頭根除，剩下的每一筆都值得查，log 會附
#                                 上傳尾巴）
#   2. 「雲端推論失敗／不可用」 — 斷路器開了，決策退回（三麻＝本手無推薦）
#   3. 「強制重連」             — watchdog 自救觸發（通常代表前面已經卡過）
#   4. 送出停滯                 — 「第 N 次嘗試」後 15 秒內沒有任何新事件行，
#                                 疑似伺服器丟單（23:15:14 那型）
#
#   用法: scripts/cloud-watch.sh          # 前景跑，Ctrl-C 停
#         scripts/cloud-watch.sh &        # 背景跑
#
set -uo pipefail

API="http://127.0.0.1:8765"

STATUS="$(curl -s --max-time 5 "$API/status" || true)"
[ -n "$STATUS" ] || { echo "✗ Naki loopback API 沒有回應"; exit 1; }
EVENTS="$(printf '%s' "$STATUS" | sed -n 's/.*"eventLog"[^"]*"\([^"]*\)".*/\1/p' | sed 's|\\/|/|g')"
[ -f "$EVENTS" ] || { echo "✗ 找不到 event log: $EVENTS"; exit 1; }
echo "watching: $EVENTS"

notify() {
  local title="$1" body="$2"
  osascript -e "display notification \"$body\" with title \"Naki 雲端監看\" subtitle \"$title\" sound name \"Basso\"" 2>/dev/null
  echo "[$(date +%H:%M:%S)] 🔔 $title — $body"
}

python3 - "$EVENTS" << 'PY'
import sys, time, subprocess, os, re

path = sys.argv[1]
def notify(title, body):
    body = body.replace('"', "'")[:180]
    subprocess.run(["osascript", "-e",
        f'display notification "{body}" with title "Naki 雲端監看" subtitle "{title}" sound name "Basso"'],
        capture_output=True)
    print(f"🔔 {title} — {body}", flush=True)

f = open(path, encoding="utf-8", errors="replace")
f.seek(0, os.SEEK_END)          # 只看新行，歷史不重報
last_line_at = time.monotonic()
pending_attempt = None           # (單調時間, 行內容)

while True:
    line = f.readline()
    if not line:
        # 停滯偵測：有送出嘗試、之後 15 秒沒有任何新行
        if pending_attempt and time.monotonic() - pending_attempt[0] > 15:
            notify("疑似送出停滯", "送出後 15 秒無任何事件："
                   + pending_attempt[1].strip()[-80:])
            pending_attempt = None
        time.sleep(1)
        continue

    last_line_at = time.monotonic()
    if "次嘗試" in line:
        pending_attempt = (time.monotonic(), line)
    else:
        pending_attempt = None   # 任何後續事件＝伺服器有回應牌局在走

    if "沒有權威回音" in line:
        notify("送出可能被丟單", line.strip()[-140:])
    elif "null reaction" in line:
        notify("事件流脫節", line.split("null reaction", 1)[-1].strip()[:160])
    elif "雲端推論失敗" in line or "雲端推論不可用" in line:
        notify("雲端失敗（已退避）", line.strip()[-120:])
    elif "強制重連" in line and "預期內" not in line:
        notify("watchdog 自救重連", line.strip()[-120:])
PY
