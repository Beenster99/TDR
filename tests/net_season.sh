#!/usr/bin/env bash
# An online season over localhost: a headless dedicated server hosts a
# one-round season with driven qualifying, two headless clients join and
# drive with the AI. Passes when the server records the qualifying and the
# race in the season, and both clients see both sessions' results.
#   GODOT=/path/to/godot tests/net_season.sh
set -u
GODOT="${GODOT:-godot}"
DIR="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${PORT:-24792}"
LOG="${LOG_DIR:-$(mktemp -d)}"
COMMON=(--headless --path "$DIR")
"$GODOT" "${COMMON[@]}" -- --server --port "$PORT" --laps 1 --ai 2 --min-players 2 --season 1 --qualifying driven --quit-after-season >"$LOG/server.log" 2>&1 &
S=$!
sleep 2
"$GODOT" "${COMMON[@]}" -- --join 127.0.0.1 --port "$PORT" --name Alice --car mclaren_720s_gt3 --autodrive --ready --quit-after-season >"$LOG/alice.log" 2>&1 &
A=$!
"$GODOT" "${COMMON[@]}" -- --join 127.0.0.1 --port "$PORT" --name Bob --car bmw_m4_gt3 --autodrive --ready --quit-after-season >"$LOG/bob.log" 2>&1 &
B=$!
( sleep "${TIMEOUT:-700}"; kill $S $A $B 2>/dev/null ) &
W=$!
wait $A; wait $B; wait $S
kill $W 2>/dev/null
ok=0
for f in server alice bob; do
  echo "--- $f"; grep -E "^\[|^P[0-9]" "$LOG/$f.log"
  [ "$(grep -c '^\[results\]' "$LOG/$f.log")" -ge 2 ] || { echo "$f did not see qualifying and race results"; ok=1; }
  grep -E "SCRIPT ERROR|ERROR:" "$LOG/$f.log" | head -5
done
grep -q "^\[season\].*qualifying recorded" "$LOG/server.log" || { echo "server never recorded qualifying"; ok=1; }
grep -q "^\[season\].*race recorded, next: finished" "$LOG/server.log" || { echo "server never recorded the race"; ok=1; }
grep -q "pts" "$LOG/alice.log" || { echo "alice saw no points"; ok=1; }
[ $ok -eq 0 ] && echo "NET SEASON PASS" || { echo "NET SEASON FAIL (logs in $LOG)"; exit 1; }
