#!/usr/bin/env bash
# Networked race over localhost: a headless dedicated server plus two headless
# clients that drive with the AI as "human" input. Passes when both clients
# receive the server's results.
#   GODOT=/path/to/godot tests/net_loopback.sh
set -u
GODOT="${GODOT:-godot}"
DIR="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${PORT:-24791}"
LOG="$(mktemp -d)"
COMMON=(--headless --path "$DIR")
"$GODOT" "${COMMON[@]}" -- --server --port "$PORT" --laps 1 --ai 2 --min-players 2 --quit-after-race >"$LOG/server.log" 2>&1 &
S=$!
sleep 2
"$GODOT" "${COMMON[@]}" -- --join 127.0.0.1 --port "$PORT" --name Alice --car v8_mid_berlinetta --autodrive --ready --quit-after-race >"$LOG/alice.log" 2>&1 &
A=$!
"$GODOT" "${COMMON[@]}" -- --join 127.0.0.1 --port "$PORT" --name Bob --car flat6_rear_gt --autodrive --ready --quit-after-race >"$LOG/bob.log" 2>&1 &
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
[ $ok -eq 0 ] && echo "NET LOOPBACK PASS" || { echo "NET LOOPBACK FAIL (logs in $LOG)"; exit 1; }
