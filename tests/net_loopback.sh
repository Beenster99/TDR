#!/usr/bin/env bash
# Networked race over localhost: a headless dedicated server plus two headless
# clients that drive with the AI as "human" input. Passes when both clients
# receive the server's results.
#   GODOT=/path/to/godot tests/net_loopback.sh
#   SERVER_ARGS="--weather heavy_rain --time 20 --clock-speed 60" ... (race options for the host)
set -u
GODOT="${GODOT:-godot}"
DIR="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${PORT:-24791}"
LOG="${LOG_DIR:-$(mktemp -d)}"
COMMON=(--headless --path "$DIR")
# Alice races an upgraded car from her own team save (business module); the
# host races GT3, so her pick becomes the BMW M4 GT3, which she has upgraded.
ALICE_PROFILE="$LOG/alice_profile.json"
cat >"$ALICE_PROFILE" <<'JSON'
{"version": 1, "money": 0, "cars": {"bmw_m4_gt3": {"upgrades": {"engine": 2, "aero": 3}, "livery": {"pattern": "stripes", "primary": "#0b3d91"}}}}
JSON
"$GODOT" "${COMMON[@]}" -- --server --port "$PORT" --laps 1 --ai 2 --min-players 2 --quit-after-race ${SERVER_ARGS:-} >"$LOG/server.log" 2>&1 &
S=$!
sleep 2
"$GODOT" "${COMMON[@]}" -- --join 127.0.0.1 --port "$PORT" --name Alice --car v8_mid_berlinetta --profile "$ALICE_PROFILE" --autodrive --auto-resume 4 --ready --quit-after-race >"$LOG/alice.log" 2>&1 &
A=$!
"$GODOT" "${COMMON[@]}" -- --join 127.0.0.1 --port "$PORT" --name Bob --car flat6_rear_gt --autodrive --pause-at 5 --auto-resume 2 --ready --quit-after-race >"$LOG/bob.log" 2>&1 &
B=$!
( sleep "${TIMEOUT:-400}"; kill $S $A $B 2>/dev/null ) &
W=$!
wait $A; wait $B; wait $S
kill $W 2>/dev/null
ok=0
for f in server alice bob; do
  echo "--- $f"; grep -E "^\[|^P[0-9]" "$LOG/$f.log"
  grep -q "^\[results\]" "$LOG/$f.log" || ok=1
  grep -E "SCRIPT ERROR|ERROR:" "$LOG/$f.log" | head -5
done
# Each client must have seen the other player's car (relayed through the host).
grep -q "Bob=[1-9]" "$LOG/alice.log" || { echo "alice never saw Bob's car"; ok=1; }
grep -q "Alice=[1-9]" "$LOG/bob.log" || { echo "bob never saw Alice's car"; ok=1; }
# Clocks synced with the host, so remote cars are drawn where they are now.
for f in alice bob; do grep -q "^\[net\] clock synced true .*, \([1-9][0-9]*\) of \1 remote cars placed in the present" "$LOG/$f.log" || { echo "$f did not place remote cars in the present"; ok=1; }; done
# Each client built the pit wall's race data (gaps from the host, feed items as events).
for f in alice bob; do grep -q "^\[race data\] saved" "$LOG/$f.log" || { echo "$f saved no race data"; ok=1; }; done
# Alice's upgrades reached every machine through the lobby.
for f in server bob; do grep -q "^\[setup\] Alice: .*engine.*visual" "$LOG/$f.log" || { echo "$f never got Alice's upgrades"; ok=1; }; done
# Bob presses Esc mid-race: the race pauses for everyone and everyone gets the
# menu. Bob resumes after 2 s, Alice after 4 s; then a countdown and it goes
# again everywhere (and still finishes, checked above). The race clock must
# not have run on while paused.
for f in server alice bob; do
  grep -qE "^\[pause\] .*: paused at .*, waiting for (Alice, Bob|Bob, Alice)" "$LOG/$f.log" || { echo "$f wasn't paused with both players in the menu"; ok=1; }
  grep -q "^\[pause\] .*: paused at .*, waiting for Alice$" "$LOG/$f.log" || { echo "$f didn't wait for Alice after Bob resumed"; ok=1; }
  grep -q "^\[pause\] .*: racing again" "$LOG/$f.log" || { echo "$f never raced again after the pause"; ok=1; }
  p=$(grep -m1 "^\[pause\] .*: paused at" "$LOG/$f.log" | sed -E 's/.*paused at ([0-9.]+) s.*/\1/')
  r=$(grep -m1 "^\[pause\] .*: racing again at" "$LOG/$f.log" | sed -E 's/.*racing again at ([0-9.]+) s.*/\1/')
  awk -v p="${p:-0}" -v r="${r:-99}" 'BEGIN { exit !(r - p < 1.0) }' || { echo "$f: the race ran on while paused ($p -> $r)"; ok=1; }
done
grep -q "^\[pause\] Alice pressed Resume" "$LOG/alice.log" || { echo "alice never got the menu when Bob paused"; ok=1; }
grep -q "Prize money" "$LOG/alice.log" || { echo "alice was paid no prize money"; ok=1; }
[ $ok -eq 0 ] && echo "NET LOOPBACK PASS" || { echo "NET LOOPBACK FAIL (logs in $LOG)"; exit 1; }
