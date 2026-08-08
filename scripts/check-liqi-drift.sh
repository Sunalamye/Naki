#!/usr/bin/env bash
#
# 檢查 docs/protocol/liqi.json 與雀魂 live CDN 是否仍然一致。
#
# CLAUDE.md 寫著「repo snapshot 與 live CDN byte-identical」，但在這支腳本出現之前
# **沒有任何機制維持那句話為真**——它只是某一天的觀察，之後就靠人記得。
#
# 協定漂移的後果是靜默的：field number 錯一個，解析出來的東西看起來仍然合理，
# 只是值不對。2026-08-01 的 match_mode 對照表整組偏移一格就是這類問題
# （雖然那份表根本不在 liqi.json 裡，見下方「這支腳本驗不到什麼」）。
#
#   用法:
#     scripts/check-liqi-drift.sh          比對，不一致就非零退出
#     scripts/check-liqi-drift.sh --update 一致性檢查失敗時把新版寫進 repo
#
# ## 這支腳本驗不到什麼
#
# **最重要的一條：它比對的基準本身就已經過期。**
#
# `res/proto/liqi.json` 是 **Laya 時代的遺留資源**。雀魂的 web client 已經遷到
# Unity WebGL，protobuf descriptor 改放在 asset bundle 裡的 `Protol/*_pb.lua`，
# 那個 JSON 不再跟著更新——它的 resource prefix 是 `v0.11.243.w`，而 live client
# 的 productVersion 是 4.0.45。
#
# 實證：repo（＝CDN）這一份的 `ReqSelfOperation` **沒有 `auto_operation` 欄位**，
# 而那個欄位在 live client 上是存在的。
#
# 所以「repo 與 CDN byte-identical」只證明**兩邊是同一份過期檔案**，
# 不證明 schema 正確。這支腳本綠燈 ≠ 沒有漂移；它只能抓到「CDN 那份自己變了」。
#
# 要真正偵測漂移，得比照 Akagi 從 Unity bundle chain 抽 descriptor
# （client HTML → clientBundleSettings → warehouse → texture profile → bundle_info_so
# → `Protol/*_pb.lua` + `docs/proto_config.bytes`）。那是一個獨立的工程，尚未做。
#
# 其餘驗不到的（本來就在範圍外）：
#   - match_mode 這類「數值語意」（房間 id、錯誤碼）——那些要從流量學
#   - 伺服器行為（哪個動作在哪個時機才會帶 operation）
#
set -uo pipefail

REPO_JSON="$(cd "$(dirname "$0")/.." && pwd)/docs/protocol/liqi.json"
# port 可被覆寫：DebugServer 在 8765 被佔時會退到 8766+，而實際 port 只存在
# 記憶體裡。寫死的話，舊 instance 佔著 8765 時腳本會**成功連到舊的那個**
# （不是連不上），preflight 全過然後對舊 instance 開真的友人房。
API="${NAKI_API:-http://127.0.0.1:8765}"
UPDATE=0
[ "${1:-}" = "--update" ] && UPDATE=1

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

[ -f "$REPO_JSON" ] || { echo "✗ 找不到 $REPO_JSON"; exit 1; }

# ── 取得 live manifest ──
#
# 走執行中的 Naki，而不是自己猜 CDN 網域：prefix 每次改版都會變，
# 而 App 已經載入過正確的那一份。沒有 App 在跑就沒得比。
curl -s --max-time 5 "$API/status" >/dev/null 2>&1 || {
  echo "✗ Naki 沒有在跑。這支腳本靠執行中的 App 取得 live manifest"
  echo "  （prefix 每次改版都會變，自己猜網址只會拿到舊版或 404）"
  exit 1
}

echo "取得 live resource manifest…"
PREFIX="$(curl -s --max-time 20 -X POST "$API/js" --data-binary @- <<'EOF' | python3 -c "
import json,sys
try:
    r = json.load(sys.stdin).get('result')
    print(json.loads(r).get('prefix') or '')
except Exception:
    print('')
"
return fetch('resversion0.11.252.w.json')
  .then(function (r) { return r.json(); })
  .then(function (j) {
    var e = j.res && j.res['res/proto/liqi.json'];
    return JSON.stringify({ prefix: e && e.prefix });
  })
  .catch(function (e) { return JSON.stringify({ error: String(e) }); });
EOF
)"

if [ -z "$PREFIX" ]; then
  # version.json 的版本號會變，先問一次再組 resversion 檔名
  VER="$(curl -s --max-time 15 -X POST "$API/js" \
    -d 'return fetch("version.json").then(function(r){return r.json()}).then(function(j){return j.version})' \
    | python3 -c "import json,sys; print(json.load(sys.stdin).get('result',''))")"
  [ -n "$VER" ] || { echo "✗ 取不到 version.json"; exit 1; }
  echo "  version = $VER"
  PREFIX="$(curl -s --max-time 25 -X POST "$API/js" --data-binary @- <<EOF | python3 -c "
import json,sys
try:
    print(json.loads(json.load(sys.stdin)['result']).get('prefix') or '')
except Exception:
    print('')
"
return fetch('resversion${VER}.json')
  .then(function (r) { return r.json(); })
  .then(function (j) {
    var e = j.res && j.res['res/proto/liqi.json'];
    return JSON.stringify({ prefix: e && e.prefix });
  })
  .catch(function (e) { return JSON.stringify({ error: String(e) }); });
EOF
)"
fi

[ -n "$PREFIX" ] || { echo "✗ manifest 裡找不到 res/proto/liqi.json 的 prefix"; exit 1; }
echo "  liqi.json prefix = $PREFIX"

# prefix 已含前導 v，不可再補（見 docs/majsoul-unity-protocol.md）
echo "下載 live liqi.json…"
curl -s --max-time 30 -X POST "$API/js" --data-binary @- > "$TMP/live.raw" <<EOF
return fetch('/1/${PREFIX}/res/proto/liqi.json')
  .then(function (r) { return r.text(); })
  .then(function (t) { return t; })
  .catch(function (e) { return 'FETCH_ERROR ' + e; });
EOF

python3 - "$TMP/live.raw" "$TMP/live.json" <<'PY'
import json, sys
try:
    o = json.load(open(sys.argv[1]))
    text = o.get("result")
    if not isinstance(text, str) or text.startswith("FETCH_ERROR"):
        print("✗ 下載失敗:", str(text)[:120]); sys.exit(1)
    # 存成原樣，byte 比對才有意義
    open(sys.argv[2], "w").write(text)
except SystemExit:
    raise
except Exception as e:
    print("✗ 解析回應失敗:", e); sys.exit(1)
PY
[ -s "$TMP/live.json" ] || exit 1

REPO_SHA="$(shasum -a 256 "$REPO_JSON" | awk '{print $1}')"
LIVE_SHA="$(shasum -a 256 "$TMP/live.json" | awk '{print $1}')"

echo
echo "repo : $REPO_SHA  ($(wc -c < "$REPO_JSON" | tr -d ' ') bytes)"
echo "live : $LIVE_SHA  ($(wc -c < "$TMP/live.json" | tr -d ' ') bytes)"
echo

if [ "$REPO_SHA" = "$LIVE_SHA" ]; then
  echo "✅ 一致"
  exit 0
fi

echo "⚠️ 不一致——協定可能改版了"
echo
# 結構差異比 byte 差異有用：JSON 格式化差異不影響語意
python3 - "$REPO_JSON" "$TMP/live.json" <<'PY'
import json, sys

def messages(path):
    d = json.load(open(path))
    out = {}
    def walk(node, prefix):
        if not isinstance(node, dict):
            return
        for k, v in node.items():
            if k == "nested" and isinstance(v, dict):
                for name, body in v.items():
                    p = f"{prefix}.{name}" if prefix else name
                    if isinstance(body, dict) and "fields" in body:
                        out[p] = {fn: fv.get("id") for fn, fv in body["fields"].items()}
                    walk(body, p)
            elif isinstance(v, dict):
                walk(v, prefix)
    walk(d, "")
    return out

a, b = messages(sys.argv[1]), messages(sys.argv[2])
added = sorted(set(b) - set(a))
removed = sorted(set(a) - set(b))
changed = []
for name in sorted(set(a) & set(b)):
    if a[name] != b[name]:
        diffs = []
        for f in sorted(set(a[name]) | set(b[name])):
            if a[name].get(f) != b[name].get(f):
                diffs.append(f"{f}: {a[name].get(f)} → {b[name].get(f)}")
        changed.append((name, diffs))

print(f"新增 message: {len(added)}  移除: {len(removed)}  欄位有變: {len(changed)}")
for n in added[:10]:   print(f"  + {n}")
for n in removed[:10]: print(f"  - {n}")
for n, ds in changed[:15]:
    print(f"  ~ {n}")
    for d in ds[:6]:
        print(f"      {d}")
if len(changed) > 15:
    print(f"  …還有 {len(changed) - 15} 個 message 有欄位變動")
print()
print("欄位編號有變 = 解析會靜默錯掉（值看起來合理但不對）。")
print("先確認上面的變動不影響 Naki 用到的欄位，再決定要不要 --update。")
PY

if [ "$UPDATE" -eq 1 ]; then
  cp "$TMP/live.json" "$REPO_JSON"
  echo
  echo "已更新 $REPO_JSON"
  echo "⚠️ 記得同步 docs/majsoul-unity-protocol.md 裡記錄的 SHA-256："
  echo "   $LIVE_SHA"
fi

exit 1
