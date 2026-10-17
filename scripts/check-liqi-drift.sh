#!/usr/bin/env bash
#
# 檢查 docs/protocol/liqi.json 是否仍與雀魂官方 Unity 資源包裡的協定描述一致。
#
# 協定漂移的後果是靜默的：field number 錯一個，解析出來的東西看起來仍然合理，只是值不對。
#
#   用法:
#     scripts/check-liqi-drift.sh          比對，不一致就非零退出
#     scripts/check-liqi-drift.sh --update 不一致時把重抽的新版寫進 repo（仍以 1 退出）
#
# 基準：`scripts/extract-liqi.py` 從官方資源包重抽（client HTML → clientBundleSettings →
# warehouse → DXT bundle_info_so → `Protol/*_pb.lua` + `proto_config.bytes`），轉成同格式
# 後與 repo 檔逐位元組比對。只讀公開靜態資源，不需要 Naki 在跑，也不送任何遊戲請求。
# 舊版比對的 CDN `res/proto/liqi.json` 是 Laya 時代的遺留檔，已不再更新，不再使用。
#
# 需要能 import UnityPy 的 python，以 LIQI_PYTHON 指定（預設 python3），例如：
#   "$(proto bin python)" -m venv ~/.cache/naki-liqi && ~/.cache/naki-liqi/bin/pip install UnityPy
#   LIQI_PYTHON=~/.cache/naki-liqi/bin/python scripts/check-liqi-drift.sh
#
# 驗不到的：match_mode 這類數值語意（房間 id、錯誤碼）要從流量學；伺服器行為
# （哪個動作在哪個時機才會帶 operation）也不在 schema 裡。
#
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO_JSON="$ROOT/docs/protocol/liqi.json"
EXTRACT="$ROOT/scripts/extract-liqi.py"
PY="${LIQI_PYTHON:-python3}"
UPDATE=0
[ "${1:-}" = "--update" ] && UPDATE=1

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

[ -f "$REPO_JSON" ] || { echo "✗ 找不到 $REPO_JSON"; exit 1; }
"$PY" -I -c 'import UnityPy' 2>/dev/null || { echo "✗ $PY 無法 import UnityPy（見檔頭的 LIQI_PYTHON 說明）"; exit 1; }

echo "從官方資源包重抽協定描述…"
(cd "$TMP" && "$PY" -I "$EXTRACT" fetch "$TMP/raw") || { echo "✗ 下載或解包失敗"; exit 1; }
(cd "$TMP" && "$PY" -I "$EXTRACT" build "$TMP/raw" "$TMP/live.json") || { echo "✗ 轉換失敗"; exit 1; }

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
(cd "$TMP" && "$PY" -I "$EXTRACT" diff "$REPO_JSON" "$TMP/live.json")
echo
echo "欄位編號有變 = 解析會靜默錯掉（值看起來合理但不對）。"
echo "先確認上面的變動不影響 Naki 用到的欄位，再決定要不要 --update。"

if [ "$UPDATE" -eq 1 ]; then
  cp "$TMP/live.json" "$REPO_JSON"
  echo
  echo "已更新 $REPO_JSON"
  echo "⚠️ 記得同步 docs/majsoul-unity-protocol.md 記錄的版本與 SHA-256："
  grep -o '"product_version": "[^"]*"' "$TMP/raw/source.json"
  echo "   $LIVE_SHA"
fi

exit 1
