#!/usr/bin/env bash
#
# 兩種時機自動截圖：
#   1. 輪到自己、模型給出推薦（檔名 act-…）
#   2. 出現異常訊號（檔名 ERR-…）
#
# 截「推薦產生的那一刻」而不是送出之後：自動打牌會等 1.0–1.9 秒才送，
# 這段時間正是高亮／半透明效果在畫面上的樣子。送出後牌已經打掉了，再截就看不到。
#
# 只認 `oplist=[...]` 非空的推薦——那代表伺服器真的授權我們動作。
# `oplist=-` 的推薦來自事件重播，一局開始幾秒內會產生幾十筆，全截會塞爆磁碟。
#
# 異常同時看 events 與 bridge 兩個 log：`❌`、`時發生錯誤` 這類只會出現在
# bridge，`均勻分布`、`決策覆蓋` 這類在 events，只 tail 一個會漏。
#
# 存成 JPEG 而不是原始 PNG：一張全解析度 PNG 約 4 MB，一局 80 手、10 局就是
# 3 GB。sips 轉檔後約 200 KB，肉眼要看的細節都還在。
#
#   用法: scripts/action-shots.sh [輸出目錄]
#
set -uo pipefail

# port 可被覆寫：DebugServer 在 8765 被佔時會退到 8766+，而實際 port 只存在
# 記憶體裡。寫死的話，舊 instance 佔著 8765 時腳本會**成功連到舊的那個**
# （不是連不上），preflight 全過然後對舊 instance 開真的友人房。
API="${NAKI_API:-http://127.0.0.1:8765}"
OUT="${1:-${SHOTS_OUT:-/tmp/naki-shots}}"
mkdir -p "$OUT"

STATUS="$(curl -s --max-time 5 "$API/status" || true)"
[ -n "$STATUS" ] || { echo "✗ Naki loopback API 沒有回應"; exit 1; }
# `/status` 是單層 REST JSON（不是 MCP envelope），所以這裡只需要還原路徑裡的 `\/`；
# MCP 那邊的「JSON 包在 JSON 字串裡」已由 structuredContent 解決，見 soak-test.sh。
pick() { printf '%s' "$STATUS" | sed -n "s/.*\"$1\"[^\"]*\"\([^\"]*\)\".*/\1/p" | sed 's|\\/|/|g'; }

EVENTS="$(pick eventLog)"
BRIDGE="$(pick Bridge)"
[ -f "$EVENTS" ] || { echo "✗ 找不到 event log: $EVENTS"; exit 1; }
[ -f "$BRIDGE" ] || { echo "✗ 找不到 bridge log: $BRIDGE"; exit 1; }
echo "events: $EVENTS"
echo "bridge: $BRIDGE"
echo "output: $OUT"

ANOMALY_RE='❌|⚠️|均勻分布|決策覆蓋|捨棄過期|第 [2-9] 次嘗試|時發生錯誤|ERROR|不送出'

last_shot_at=0
shot() {
  local tag="$1"
  local now
  now=$(date +%s)
  # 同一秒內的連續訊號只截一張——截圖本身要 1 秒以上，排隊只會越積越慢
  [ $((now - last_shot_at)) -lt 1 ] && return 0
  last_shot_at=$now

  local base="$OUT/$(date +%H%M%S)-$tag"
  curl -s --max-time 20 "$API/screenshot" -o "$base.png" 2>/dev/null || return 0
  # 轉 JPEG 並縮到寬 1600；成功才刪原檔，失敗就留 PNG，不要兩邊都沒有
  if sips -s format jpeg -s formatOptions 70 -Z 1600 "$base.png" --out "$base.jpg" >/dev/null 2>&1; then
    rm -f "$base.png"
  fi
  echo "$(date +%H:%M:%S) 📸 $tag"
}

cleanup() { kill 0 2>/dev/null; }
trap cleanup EXIT INT TERM

# 兩個 log 併成一條流。都從檔尾開始，不重播歷史。
{ tail -F -n 0 "$EVENTS" 2>/dev/null & tail -F -n 0 "$BRIDGE" 2>/dev/null & } | while IFS= read -r line; do

  # --- 異常優先：先判，免得被下面的 continue 濾掉 ---
  if printf '%s' "$line" | grep -qE "$ANOMALY_RE"; then
    kind="$(printf '%s' "$line" | grep -oE "$ANOMALY_RE" | head -1 \
            | tr -d ' ' | tr -c '[:alnum:]' '_' | cut -c1-16)"
    shot "ERR-${kind:-x}"
    continue
  fi

  # --- 輪到自己 ---
  case "$line" in
    *"oplist=[""]"*) continue ;;
    *"oplist=-"*)    continue ;;
    *"updated recommendations"*|*"副露後推論"*) ;;
    *) continue ;;
  esac

  ops="$(printf '%s' "$line" | sed -n 's/.*oplist=\[\([0-9, ]*\)\].*/\1/p' | tr -d ' ,')"
  top="$(printf '%s' "$line" | sed -n 's/.*\[\([a-z]*\):\([^@]*\)@.*/\1-\2/p' | tr -d ' /')"
  shot "act-ops${ops:-x}-${top:-none}"
done
