#!/usr/bin/env bash
#
# 連續跑 N 局段位場，收集異常訊號。
#
# 為什麼用 log marker 而不是 /game/state：`inGame` 在對局結束後不會歸位
# （AUDIT §16.4），拿它判斷「這局結束了沒」會永遠卡在 true。
# `[協調器] start_game` / `end_game` 是事件流真正的邊界，跟 UI 狀態無關。
#
# 這個腳本會送出真正的匹配請求，會影響段位分。只在測試帳號上跑。
#
# 開局走友人房 + 人機（room_quick_test），不走段位場匹配：
#   1. 不影響段位分，可以無限重跑
#   2. 不用等真人湊滿，十局跑得完
#   3. 段位場的 match_mode 對照表是錯的（見下方註解）
#
# ⚠️ room_quick_test 之後**一定要 bot_sync**。startRoom 會讓伺服器真的開局，
#    但 WebView 客戶端有時收不到 NotifyRoomGameStart，就停在大廳，
#    而 /game/state 會顯示 inGame:false——看起來完全像開局失敗。
#    強制重連時伺服器會把進行中的對局推回來，客戶端才會進場。
#
#   用法: scripts/soak-test.sh [局數]
#
set -uo pipefail

GAMES="${1:-10}"

API="http://127.0.0.1:8765"
OUT="${SOAK_OUT:-/tmp/naki-soak}"
POLL=5
# 開局後多久沒看到 start_game 就重試
MATCH_TIMEOUT=90
# 「以為在對局中」但完全沒有牌局活動超過這麼久，就當成卡住
STALL_SECS=150
# 卡住時最多自救幾次，超過就停下來讓人看
MAX_UNSTICK=3
# 連續建房失敗幾次才放棄（暫時性競態不該一次就停）
MAX_CREATE_FAILS=5

mkdir -p "$OUT"
REPORT="$OUT/report.txt"
: > "$REPORT"

say() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$REPORT"; }

# grep -c 的 exit code 不可靠（0 筆時 exit 1），一律經過這裡取數字
count() { grep -cE "$1" "$OUT/window.log" 2>/dev/null | head -1 | tr -dc '0-9' | sed 's/^$/0/'; }

# MCP 2026-07-28 起工具結果同時回 `structuredContent`（真的 JSON 物件）與
# `content[0].text`（同一份 JSON 的字串化，留給舊 client）。比對一律走前者：
# 先把回應切到 `structuredContent` 之後，再用**未跳脫**的 pattern 比對——
# text 那份裡的引號都是 \"，不可能誤中。
# （舊版要先 `tr -d '\\'` 去跳脫，連續踩了三次 serverAccepted / success 對不上；
#   結構化輸出之後那個 workaround 已移除。）
# ⚠️ 需要 2026-08-02 之後的 Naki binary。對著舊版跑，這兩個判斷會一律回 false，
#    表現成 lobby_ready 探測失敗並在 preflight 之後停下——是大聲失敗，不是靜默誤判。
structured() { sed 's/.*"structuredContent"://' "$1" 2>/dev/null; }
rejected() { structured "$1" | grep -q '"serverAccepted":[[:space:]]*false'; }
accepted() { structured "$1" | grep -q '"serverAccepted":[[:space:]]*true'; }

# lobby session 是否可用。bot_sync 會把連線關掉重建，重建後那條 socket
# 還沒完成登入，這時送 createRoom 伺服器一律回 error 1004。
# 用一個唯讀請求探到成功為止，才代表可以送真正的動作。
lobby_ready() {
  local i
  for i in $(seq 1 "${1:-20}"); do
    # 用 lobby_account_info 當探針，不用 lobby_server_time——後者即使在
    # session 正常時也會被伺服器拒（2026-08-01 實測），當探針會永遠通不過。
    mcp lobby_account_info "{}" > "$OUT/probe.json" 2>&1 || true
    accepted "$OUT/probe.json" && return 0
    sleep 2
  done
  return 1
}

# 伺服器認不認為我們正在對局中。
#
# 不用 /game/hand 的 tehaiCount：對局剛開始時手牌還是 0，會誤判成「沒在打」，
# 然後去建房，伺服器回 error 1023（局中不能建房）。
# fetchGamingInfo 有 connect_token 才是權威答案。
game_active() {
  mcp lobby_status "{}" > "$OUT/gaming.json" 2>&1 || true
  structured "$OUT/gaming.json" | grep -q '"field2"'
}

mcp() {
  curl -s --max-time 10 "$API/mcp" -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"$1\",\"arguments\":${2:-\{\}}}}"
}

cleanup() {
  local code=$?
  say "── 收尾：離開測試房 ──"
  mcp room_leave "{}" >/dev/null 2>&1 || true
  say "報告: $REPORT"
  exit $code
}
trap cleanup EXIT INT TERM

# ---------- preflight ----------
say "── preflight ──"
STATUS="$(curl -s --max-time 5 "$API/status" || true)"
[ -n "$STATUS" ] || { say "✗ Naki loopback API 沒有回應，先啟動 App"; exit 1; }

BRIDGE_LOG="$(printf '%s' "$STATUS" | sed -n 's/.*"Bridge"[^"]*"\([^"]*\)".*/\1/p' | sed 's|\\/|/|g')"
[ -f "$BRIDGE_LOG" ] || { say "✗ 找不到 bridge log: $BRIDGE_LOG"; exit 1; }
say "bridge log: $BRIDGE_LOG"

ACCT="$(curl -s --max-time 5 "$API/game/state" | sed -n 's/.*"accountId"[^0-9]*\([0-9]*\).*/\1/p')"
say "accountId: ${ACCT:-unknown}  目標局數: $GAMES  開局方式: 友人房+人機"

# 從現在開始看 log，不要把歷史紀錄算進來
START_LINE=$(wc -l < "$BRIDGE_LOG" | tr -d " ")
say "log 起點: 第 $START_LINE 行"

# 啟動時可能已經有一局在跑，它的 start_game 在 START_LINE 之前。
# 不補這一筆的話 starts 會是 0，腳本會在對局中又去開一間新房。
# 用手牌張數判斷而不是 inGame——inGame 在對局結束後不會歸位（AUDIT §16.4）。
PRIOR_START=0
if game_active; then
  PRIOR_START=1
  say "偵測到進行中的對局（伺服器有 connect_token），先等它結束"
fi

# ---------- 主迴圈 ----------
done_games=0
in_game=0
last_progress=$(date +%s)
last_activity=-1
unstick_count=0
create_fails=0
match_sent_at=0

# 這些是「值得人看一眼」的訊號，不是全部 log
ANOMALY_RE='❌|⚠️|均勻分布|決策覆蓋|捨棄過期|第 [2-9] 次嘗試|時發生錯誤|ERROR|不送出'

while [ "$done_games" -lt "$GAMES" ]; do
  now=$(date +%s)
  tail -n +$((START_LINE + 1)) "$BRIDGE_LOG" > "$OUT/window.log" 2>/dev/null || true

  # grep -c 沒找到時會「印 0 且 exit 1」，用 `|| echo 0` 會得到兩個 0，
  # 後面的 [ ] 比較就整串壞掉。統一走 count()。
  # 用 [協調器] 那條，不用 [消費者]：
  #   - start_game 兩邊都有（消費者 + 協調器），任選一個即可
  #   - end_game **只有協調器有**。消費者那條在 handler 拋錯時格式會變成
  #     「[消費者] 處理 end_game 時發生錯誤」，而 botNotInitialized 每局都會發生
  #     （AUDIT §16.6.2），所以抓 [消費者] end_game 永遠是 0 —— 腳本會一直
  #     以為對局還在進行，卡死不前。
  starts=$(( $(count '\[協調器\] start_game') + PRIOR_START ))
  ends=$(count '\[協調器\] end_game')

  if [ "$ends" -gt "$done_games" ]; then
    done_games=$ends
    in_game=0
    match_sent_at=0
    last_progress=$now
    last_activity=-1
    unstick_count=0
    say "🏁 第 $done_games/$GAMES 局結束"
    grep -nE "$ANOMALY_RE" "$OUT/window.log" | tail -20 > "$OUT/anom-$done_games.txt" 2>/dev/null || true
    n=$(wc -l < "$OUT/anom-$done_games.txt" 2>/dev/null | tr -d ' ')
    n=${n:-0}
    [ "$n" -gt 0 ] && say "   ⚠ 本局異常訊號 $n 條 → $OUT/anom-$done_games.txt"
    continue
  fi

  if [ "$starts" -gt "$ends" ]; then
    if [ "$in_game" -eq 0 ]; then
      in_game=1
      say "▶ 第 $((done_games + 1)) 局開始"
    fi

    # ── 停滯偵測 ──
    #
    # 「以為在對局中」不等於真的在打。實測過兩種卡法：
    #   1. 伺服器開了局但客戶端沒進場（startRoom 之後常見）
    #   2. 客戶端斷線但 log 沒有結束事件
    # 兩種都表現成「安靜地什麼都不發生」，沒有這道 watchdog 會卡到天荒地老。
    #
    # 判準用「牌局活動的行數有沒有增加」，不用時間或 UI 狀態——
    # 有人在打牌就一定會有 oplist／推薦的 log。
    activity=$(count 'oplist 更新|updated recommendations|副露後推論')
    if [ "$activity" -ne "$last_activity" ]; then
      last_activity=$activity
      last_progress=$now
    elif [ $((now - last_progress)) -ge "$STALL_SECS" ]; then
      unstick_count=$((unstick_count + 1))
      if [ "$unstick_count" -gt "$MAX_UNSTICK" ]; then
        say "✗ 連續 $MAX_UNSTICK 次自救無效，停止（活動行數卡在 ${activity}）"
        exit 1
      fi
      say "⏱ ${STALL_SECS}s 沒有任何牌局活動 → 自救 $unstick_count/${MAX_UNSTICK}：強制重連"
      mcp bot_sync "{}" > "$OUT/sync.json" 2>&1 || true
      last_progress=$now
      sleep 12
      continue
    fi
    # 截圖交給 scripts/action-shots.sh：定時拍會錯過「輪到自己」那一刻，
    # 而那正是要檢查高亮與半透明的時機。
    sleep "$POLL"
    continue
  fi

  # 不在對局中 → 開一局新的（或重試逾時的那一次）
  if [ "$match_sent_at" -eq 0 ] || [ $((now - match_sent_at)) -ge "$MATCH_TIMEOUT" ]; then
    [ "$match_sent_at" -ne 0 ] && say "⟳ 開局逾時 ${MATCH_TIMEOUT}s，重試"

    if ! lobby_ready 20; then
      say "✗ lobby session 遲遲沒就緒（唯讀探測一直被拒），停止"
      exit 1
    fi

    # 走到這裡代表 log 上沒有「未結束的對局」。但伺服器可能仍有一局
    # （fetchGamingInfo 有 connect_token）——那是「伺服器開了局、客戶端沒進去」，
    # startRoom 之後常發生。這時該做的是把客戶端拉進去，不是等。
    #
    # ⚠️ 這裡曾經寫成「有對局就等待」，結果是死結：能讓客戶端進場的
    #    bot_sync 正好被這個閘門擋掉，而且每輪重置計時器所以永遠不逾時。
    if game_active; then
      say "   伺服器有對局但客戶端不在裡面 → 強制重連進場"
      mcp bot_sync "{}" > "$OUT/sync.json" 2>&1 || true
      match_sent_at=$now
      sleep 10
      continue
    fi

    # 上一局的友人房不會自己消失，還在裡面時 createRoom 會被拒（error 1105）。
    # 這一步在第一局是多餘的（本來就不在房裡），但無害，換來每一輪的乾淨起點。
    mcp room_leave "{}" > "$OUT/leave.json" 2>&1 || true
    sleep 2

    say "🎲 建立測試房並開局"
    mcp room_quick_test "{}" > "$OUT/start.json" 2>&1 || true
    if rejected "$OUT/start.json"; then
      # 建房被拒有兩種：系統性（參數錯，重試無用）與暫時性（客戶端正在進場、
      # 上一局還沒清乾淨）。實測後者佔多數——腳本判斷「不在對局中」的那一瞬間，
      # 客戶端可能正好在進場，幾秒後 createRoom 就會被拒。
      # 所以不再一次失敗就退出，改成連續失敗才放棄。
      create_fails=$((create_fails + 1))
      say "   建房被拒（連續 $create_fails/${MAX_CREATE_FAILS}）"
      if [ "$create_fails" -ge "$MAX_CREATE_FAILS" ]; then
        say "✗ 連續 $MAX_CREATE_FAILS 次建房失敗，停止"
        structured "$OUT/start.json" | head -c 400 | tee -a "$REPORT"; echo | tee -a "$REPORT"
        exit 1
      fi
      match_sent_at=0
      sleep 15
      continue
    fi
    create_fails=0

    # startRoom 讓伺服器開局，但客戶端有時收不到 NotifyRoomGameStart。
    # 先給它自己進場的機會，真的沒進去才強制重連——無條件 bot_sync 會把
    # 剛建好的連線又拆掉，下一輪 createRoom 就打在沒登入的 socket 上（error 1004）。
    # 把客戶端弄進場：等一下 → 重連 → 再等 → 再重連，最多 3 輪。
    #
    # 實測 startRoom 之後客戶端**幾乎不會自己進場**（連續兩局都是），所以「等它」
    # 只是浪費時間；但太早 bot_sync 也沒用——伺服器那邊的對局還沒準備好。
    # 先前的版本第一次 bot_sync 在 3 秒後送出，永遠無效，要等 90 秒逾時後
    # 第二次才成功，**每局固定浪費約 2 分鐘**。
    #
    # 改成先給 8 秒讓伺服器把局準備好，再重連；沒進去就每 20 秒再試一次。
    entered=0
    for round in 1 2 3; do
      for _ in $(seq 1 4); do
        sleep 2
        tail -n +$((START_LINE + 1)) "$BRIDGE_LOG" > "$OUT/window.log" 2>/dev/null || true
        if [ "$(count '\[協調器\] start_game')" -gt "$done_games" ]; then entered=1; break; fi
      done
      [ "$entered" -eq 1 ] && break
      say "   客戶端沒自己進場，強制重連（第 $round 次）"
      mcp bot_sync "{}" > "$OUT/sync.json" 2>&1 || true
      for _ in $(seq 1 6); do
        sleep 2
        tail -n +$((START_LINE + 1)) "$BRIDGE_LOG" > "$OUT/window.log" 2>/dev/null || true
        if [ "$(count '\[協調器\] start_game')" -gt "$done_games" ]; then entered=1; break; fi
      done
      [ "$entered" -eq 1 ] && break
    done

    match_sent_at=$(date +%s)
  fi
  sleep "$POLL"
done

# ---------- 總結 ----------
say "── 完成 $done_games 局 ──"
total=$(count "$ANOMALY_RE")
say "異常訊號合計: $total 條"
if [ "$total" -gt 0 ]; then
  say "分類統計:"
  grep -oE "$ANOMALY_RE" "$OUT/window.log" | sort | uniq -c | sort -rn | tee -a "$REPORT"
fi
say "截圖: $(ls "$OUT"/*.png 2>/dev/null | wc -l | tr -d ' ') 張"
