#!/usr/bin/env bash
#
# 把所有錄下的對局重跑一遍，輸出每局的決策摘要。
#
# 這支的用途是**改完程式碼後快速驗證**：不必真的打一局（12–14 分鐘），
# 直接把錄影餵回 Bot 看決策有沒有變。搭配 --baseline 可以跟上次的結果 diff。
#
# 能驗什麼：observation encoder、resolver 規則、副露後推論、決策順序。
# 不能驗什麼：送出通道、oplist 時序、WebGL 高亮、UI——那些不在事件流裡。
#
#   用法:
#     scripts/replay-check.sh                    重跑當次 session 的所有錄影
#     scripts/replay-check.sh --session <dir>    指定 session 目錄
#     scripts/replay-check.sh --save <file>      把結果存成 baseline
#     scripts/replay-check.sh --baseline <file>  跟 baseline 比對，有差異就非零退出
#
set -uo pipefail

API="http://127.0.0.1:8765"
SESSION=""
SAVE=""
BASELINE=""
OUT="${REPLAY_OUT:-/tmp/naki-replay}"

while [ $# -gt 0 ]; do
  case "$1" in
    --session)  SESSION="$2"; shift 2 ;;
    --save)     SAVE="$2"; shift 2 ;;
    --baseline) BASELINE="$2"; shift 2 ;;
    -h|--help)  sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "未知參數: $1"; exit 2 ;;
  esac
done

mkdir -p "$OUT"

mcp() {
  curl -s --max-time 120 "$API/mcp" -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"$1\",\"arguments\":${2:-\{\}}}}"
}

# 取工具結果的 JSON。MCP 2026-07-28 起優先讀 `structuredContent`（真的 JSON 物件）；
# 舊 server 沒有這個欄位時才退回 `content[0].text`（同一份 JSON 的字串化）。
unwrap() {
  python3 -c "
import json,sys
try:
    r=json.load(sys.stdin)['result']
    if 'structuredContent' in r:
        print(json.dumps(r['structuredContent']))
    else:
        print(r['content'][0]['text'])
except Exception as e:
    print('{\"error\": \"%s\"}' % e)
"
}

curl -s --max-time 5 "$API/status" >/dev/null || { echo "✗ Naki loopback API 沒有回應"; exit 1; }

ARGS='{}'
[ -n "$SESSION" ] && ARGS="{\"session\":\"$SESSION\"}"
mcp replay_list "$ARGS" | unwrap > "$OUT/list.json"

GAMES=$(python3 -c "
import json
o=json.load(open('$OUT/list.json'))
for g in o.get('games', []):
    print(g['file'])
")

if [ -z "$GAMES" ]; then
  echo "沒有錄影可以重跑。"
  python3 -c "
import json
o=json.load(open('$OUT/list.json'))
print(' 目錄:', o.get('directory'))
print(' 說明:', o.get('note'))"
  exit 1
fi

echo "找到 $(echo "$GAMES" | wc -l | tr -d ' ') 局錄影"
echo

: > "$OUT/summary.txt"
total_decisions=0
total_errors=0

while IFS= read -r file; do
  [ -z "$file" ] && continue
  a="{\"file\":\"$file\",\"limit\":500}"
  [ -n "$SESSION" ] && a="{\"file\":\"$file\",\"session\":\"$SESSION\",\"limit\":500}"
  mcp replay_game "$a" | unwrap > "$OUT/replay-$file.json"

  python3 - "$OUT/replay-$file.json" "$file" >> "$OUT/summary.txt" <<'PY'
import json, sys, hashlib
path, name = sys.argv[1], sys.argv[2]
try:
    o = json.load(open(path))
except Exception as e:
    print(f"{name}\tPARSE_ERROR\t{e}")
    sys.exit(0)
if "decisions" not in o:
    print(f"{name}\tTOOL_ERROR\t{str(o)[:120]}")
    sys.exit(0)
ds = o["decisions"]
# 決策指紋：事件序 + 動作，用來跟 baseline 比對
fp = hashlib.sha256(
    "\n".join(f"{d['index']}:{d['event']}:{json.dumps(d['action'], sort_keys=True)}" for d in ds)
    .encode()
).hexdigest()[:16]
print(f"{name}\t{o['events']}\t{len(ds)}\t{len(o.get('errors', []))}\t{fp}")
PY
done <<< "$GAMES"

echo "錄影檔                          事件   決策  錯誤  指紋"
echo "------------------------------------------------------------"
awk -F'\t' '{printf "%-30s %5s %5s %5s  %s\n", $1, $2, $3, $4, $5}' "$OUT/summary.txt"
echo

total_decisions=$(awk -F'\t' '{s+=$3} END {print s+0}' "$OUT/summary.txt")
total_errors=$(awk -F'\t' '{s+=$4} END {print s+0}' "$OUT/summary.txt")
echo "合計: $total_decisions 個決策, $total_errors 個錯誤"

if [ -n "$SAVE" ]; then
  cp "$OUT/summary.txt" "$SAVE"
  echo "baseline 已存: $SAVE"
fi

if [ -n "$BASELINE" ]; then
  if [ ! -f "$BASELINE" ]; then
    echo "✗ baseline 不存在: $BASELINE"; exit 1
  fi
  echo
  if diff -u "$BASELINE" "$OUT/summary.txt" > "$OUT/diff.txt"; then
    echo "✅ 與 baseline 完全一致（決策沒有改變）"
  else
    echo "⚠️ 與 baseline 有差異："
    cat "$OUT/diff.txt"
    echo
    echo "指紋不同代表決策變了。這不一定是壞事——修 bug 本來就會改變決策，"
    echo "但你必須能解釋每一個變化。無法解釋的差異就是回歸。"
    exit 1
  fi
fi

[ "$total_errors" -gt 0 ] && exit 1
exit 0
