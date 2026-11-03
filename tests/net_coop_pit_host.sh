#!/usr/bin/env bash
# Two-player co-op pit stop where a player hosts (no dedicated server): Bob
# hosts and is the strategist (fuel man), Alice joins and drives (windscreen,
# then left wheel man). The crew game's autoplay plays each of them. Passes
# when both played their jobs, the stop wasn't held to the give-up time, and
# both see the results.
#   GODOT=/path/to/godot tests/net_coop_pit_host.sh
set -u
GODOT="${GODOT:-godot}"
DIR="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${PORT:-24798}"
LOG="${LOG_DIR:-$(mktemp -d)}"
COMMON=(--headless --path "$DIR")
"$GODOT" "${COMMON[@]}" -- --host --port "$PORT" --name Bob --car bmw_m4_gt3 --team 1 --role strategist --track spielberg --laps 2 --pit-stops 1 --ai 2 --min-players 2 --crew-autoplay --ready --quit-after-race >"$LOG/bob.log" 2>&1 &
B=$!
sleep 2
"$GODOT" "${COMMON[@]}" -- --join 127.0.0.1 --port "$PORT" --name Alice --car bmw_m4_gt3 --team 1 --role driver --pit-job wheel_l --autodrive --crew-autoplay --ready --quit-after-race >"$LOG/alice.log" 2>&1 &
A=$!
( sleep "${TIMEOUT:-600}"; kill $A $B 2>/dev/null ) &
W=$!
wait $A; wait $B
kill $W 2>/dev/null
ok=0
for f in bob alice; do
  echo "--- $f"; grep -E "^\[|^P[0-9]" "$LOG/$f.log"
  grep -q "^\[results\]" "$LOG/$f.log" || { echo "$f saw no results"; ok=1; }
  if grep -q "SCRIPT ERROR" "$LOG/$f.log"; then grep -A2 "SCRIPT ERROR" "$LOG/$f.log" | head -9; ok=1; fi
done
grep -q "^\[pit crew\] .* played screen+wheel_l: .*gave up false" "$LOG/alice.log" || { echo "alice didn't play windscreen + left wheel man"; ok=1; }
grep -q "^\[pit crew\] .* played fuel: .*gave up false" "$LOG/bob.log" || { echo "bob (host) didn't play the fuel man"; ok=1; }
line=$(grep -m1 "^\[pit crew\]" "$LOG/alice.log")
st=$(echo "$line" | sed -E 's/.*stationary ([0-9.]+) s, standard ([0-9.]+) s.*/\1 \2/')
awk -v a="$st" 'BEGIN { split(a, v, " "); exit !(v[1] > 0 && v[1] < v[2] * 1.4) }' || { echo "stop too slow: $st"; ok=1; }
[ $ok -eq 0 ] && echo "NET COOP PIT HOST PASS" || { echo "NET COOP PIT HOST FAIL (logs in $LOG)"; exit 1; }
