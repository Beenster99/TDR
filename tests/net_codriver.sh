#!/usr/bin/env bash
# A solo player and their AI co-driver over localhost: a headless dedicated
# server (2 drivers per car) and one headless client. Sam hands the car to
# the AI co-driver at the mandatory stop (--hand-over), runs the pit wall
# while the host's AI drives, then calls the car in and takes the wheel back
# (--request-swap). Passes when both changes happen in the box and Sam
# finishes the race in their own car.
#   GODOT=/path/to/godot tests/net_codriver.sh
set -u
GODOT="${GODOT:-godot}"
DIR="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${PORT:-24795}"
LOG="${LOG_DIR:-$(mktemp -d)}"
COMMON=(--headless --path "$DIR")
"$GODOT" "${COMMON[@]}" -- --server --port "$PORT" --track spielberg --laps 6 --pit-stops 1 --drivers 2 --ai 2 --min-players 1 --quit-after-race >"$LOG/server.log" 2>&1 &
S=$!
sleep 2
"$GODOT" "${COMMON[@]}" -- --join 127.0.0.1 --port "$PORT" --name Sam --car bmw_m4_gt3 --hand-over --request-swap --autodrive --ready --quit-after-race >"$LOG/sam.log" 2>&1 &
A=$!
( sleep "${TIMEOUT:-700}"; kill $S $A 2>/dev/null ) &
W=$!
wait $A; wait $S
kill $W 2>/dev/null
ok=0
for f in server sam; do
  echo "--- $f"; grep -E "^\[|^P[0-9]" "$LOG/$f.log"
  grep -q "^\[results\]" "$LOG/$f.log" || { echo "$f saw no results"; ok=1; }
  if grep -q "SCRIPT ERROR" "$LOG/$f.log"; then grep -A2 "SCRIPT ERROR" "$LOG/$f.log" | head -9; ok=1; fi
done
grep -q "^\[coop\] Sam: Driver change at the next stop" "$LOG/sam.log" || { echo "sam never asked for a driver change"; ok=1; }
grep -q "^\[coop\] driver change: car [0-9]* now driven by [A-Z]" "$LOG/server.log" || { echo "server never changed drivers"; ok=1; }
grep -q "^\[coop\] Sam is now pit_wall of car [0-9]* (driving car -1)" "$LOG/sam.log" || { echo "sam never moved to the pit wall"; ok=1; }
grep -q "^\[coop\] driver change: car [0-9]* now driven by Sam" "$LOG/server.log" || { echo "sam never got the wheel back"; ok=1; }
grep -q "^\[coop\] Sam is now driver of car [0-9]* (driving car [0-9]*)" "$LOG/sam.log" || { echo "sam's machine never took the car back"; ok=1; }
grep -E "^P[0-9].*Sam.*stops [23]" "$LOG/server.log" | grep -vq "pen" || { echo "Sam's car should make 2-3 stops without penalties"; ok=1; }
[ $ok -eq 0 ] && echo "NET CODRIVER PASS" || { echo "NET CODRIVER FAIL (logs in $LOG)"; exit 1; }
