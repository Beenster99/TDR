#!/usr/bin/env bash
# Co-op over localhost: a headless dedicated server and two headless clients
# who share one car (car share 1). Alice drives, Bob is pit crew + strategist
# and asks to take the wheel at the mandatory pit stop. Passes when the
# driver change happens in the box, the car moves to Bob's machine, Bob drives
# it to the flag, and everyone gets the results.
#   GODOT=/path/to/godot tests/net_coop.sh
set -u
GODOT="${GODOT:-godot}"
DIR="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${PORT:-24793}"
LOG="${LOG_DIR:-$(mktemp -d)}"
COMMON=(--headless --path "$DIR")
"$GODOT" "${COMMON[@]}" -- --server --port "$PORT" --track spielberg --laps 2 --pit-stops 1 --ai 2 --min-players 2 --quit-after-race >"$LOG/server.log" 2>&1 &
S=$!
sleep 2
"$GODOT" "${COMMON[@]}" -- --join 127.0.0.1 --port "$PORT" --name Alice --car bmw_m4_gt3 --team 1 --role driver --autodrive --ready --quit-after-race >"$LOG/alice.log" 2>&1 &
A=$!
sleep 1
"$GODOT" "${COMMON[@]}" -- --join 127.0.0.1 --port "$PORT" --name Bob --car bmw_m4_gt3 --team 1 --role pit_wall --request-swap --autodrive --ready --quit-after-race >"$LOG/bob.log" 2>&1 &
B=$!
( sleep "${TIMEOUT:-500}"; kill $S $A $B 2>/dev/null ) &
W=$!
wait $A; wait $B; wait $S
kill $W 2>/dev/null
ok=0
for f in server alice bob; do
  echo "--- $f"; grep -E "^\[|^P[0-9]" "$LOG/$f.log"
  grep -q "^\[results\]" "$LOG/$f.log" || { echo "$f saw no results"; ok=1; }
  if grep -q "SCRIPT ERROR" "$LOG/$f.log"; then grep -A2 "SCRIPT ERROR" "$LOG/$f.log" | head -9; ok=1; fi
done
# One car for the two of them: 2 AI + 1 shared car.
grep -q "^\[race\] SERVER, 3 cars" "$LOG/server.log" || { echo "server did not race 3 cars (2 AI + 1 shared)"; ok=1; }
grep -q "^\[race\] CLIENT, 3 cars, 2 laps, local car -1" "$LOG/bob.log" || { echo "bob should start on the pit wall"; ok=1; }
grep -q "^\[coop\] Bob asked to take over" "$LOG/bob.log" || { echo "bob never asked for the wheel"; ok=1; }
grep -q "^\[coop\] driver change: car [0-9]* now driven by Bob" "$LOG/server.log" || { echo "server never changed drivers"; ok=1; }
grep -q "^\[coop\] Bob is now driver of car [0-9]* (driving car [0-9]*)" "$LOG/bob.log" || { echo "bob never took the wheel"; ok=1; }
grep -q "^\[coop\] Alice is now pit_wall of car [0-9]* (driving car -1)" "$LOG/alice.log" || { echo "alice never moved to the pit wall"; ok=1; }
# The stop counted, with the driver change time in it, and nobody was penalised for it.
grep -E "^P[0-9].*Alice.*stops 1" "$LOG/server.log" | grep -vq "pen" || { echo "shared car missed its stop or got a penalty"; ok=1; }
grep -E "^P[0-9].*Alice" "$LOG/server.log" | grep -q "DNF" && { echo "shared car did not finish"; ok=1; }
[ $ok -eq 0 ] && echo "NET COOP PASS" || { echo "NET COOP FAIL (logs in $LOG)"; exit 1; }
