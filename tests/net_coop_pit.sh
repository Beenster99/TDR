#!/usr/bin/env bash
# Co-op pit stop over localhost: a headless dedicated server and three headless
# clients sharing one car (car share 1): Alice drives (windscreen, then left
# wheel man), Carol is pit crew (lays out the tyres and guns, air lance, then
# left gun man) and Bob is the strategist (fuel man). The crew game's
# autoplay plays each of them on their own machine. Passes when every
# player's jobs reached the car, the stop was played (not given up), and
# everyone gets the results.
#   GODOT=/path/to/godot tests/net_coop_pit.sh
set -u
GODOT="${GODOT:-godot}"
DIR="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${PORT:-24797}"
LOG="${LOG_DIR:-$(mktemp -d)}"
COMMON=(--headless --path "$DIR")
"$GODOT" "${COMMON[@]}" -- --server --port "$PORT" --track spielberg --laps 2 --pit-stops 1 --ai 2 --min-players 3 --quit-after-race >"$LOG/server.log" 2>&1 &
S=$!
sleep 2
"$GODOT" "${COMMON[@]}" -- --join 127.0.0.1 --port "$PORT" --name Alice --car bmw_m4_gt3 --team 1 --role driver --pit-job wheel_l --autodrive --crew-autoplay --ready --quit-after-race >"$LOG/alice.log" 2>&1 &
A=$!
sleep 1
"$GODOT" "${COMMON[@]}" -- --join 127.0.0.1 --port "$PORT" --name Bob --car bmw_m4_gt3 --team 1 --role strategist --crew-autoplay --ready --quit-after-race >"$LOG/bob.log" 2>&1 &
B=$!
sleep 1
"$GODOT" "${COMMON[@]}" -- --join 127.0.0.1 --port "$PORT" --name Carol --car bmw_m4_gt3 --team 1 --role pit_crew --pit-job gun_l --crew-autoplay --ready --quit-after-race >"$LOG/carol.log" 2>&1 &
C=$!
( sleep "${TIMEOUT:-600}"; kill $S $A $B $C 2>/dev/null ) &
W=$!
wait $A; wait $B; wait $C; wait $S
kill $W 2>/dev/null
ok=0
for f in server alice bob carol; do
  echo "--- $f"; grep -E "^\[|^P[0-9]" "$LOG/$f.log"
  grep -q "^\[results\]" "$LOG/$f.log" || { echo "$f saw no results"; ok=1; }
  if grep -q "SCRIPT ERROR" "$LOG/$f.log"; then grep -A2 "SCRIPT ERROR" "$LOG/$f.log" | head -9; ok=1; fi
done
grep -q "^\[pit crew\] .* played screen+wheel_l: .*gave up false" "$LOG/alice.log" || { echo "alice didn't play windscreen + left wheel man"; ok=1; }
grep -q "^\[pit crew\] .* played fuel: .*gave up false" "$LOG/bob.log" || { echo "bob didn't play the fuel man"; ok=1; }
grep -q "^\[pit crew\] .* played lance+gun_l: .*gave up false" "$LOG/carol.log" || { echo "carol didn't play tyres, guns, lance + left gun man"; ok=1; }
# The stop wasn't held to the crew's give-up time (1.6 x standard).
line=$(grep -m1 "^\[pit crew\]" "$LOG/alice.log")
st=$(echo "$line" | sed -E 's/.*stationary ([0-9.]+) s, standard ([0-9.]+) s.*/\1 \2/')
awk -v a="$st" 'BEGIN { split(a, v, " "); exit !(v[1] > 0 && v[1] < v[2] * 1.4) }' || { echo "stop too slow: $st"; ok=1; }
grep -E "^P[0-9].*Alice.*stops 1" "$LOG/server.log" | grep -vq "pen" || { echo "shared car missed its stop or got a penalty"; ok=1; }
[ $ok -eq 0 ] && echo "NET COOP PIT PASS" || { echo "NET COOP PIT FAIL (logs in $LOG)"; exit 1; }
