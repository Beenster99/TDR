#!/usr/bin/env bash
# Films race highlights in the game for the main menu background
# (modules/ui/media/highlights.ogv): AI races on different tracks, weather
# and times of day, recorded with Godot's movie maker (no HUD). Each race is
# fast-forwarded to --film-from seconds, then filmed at normal speed; the
# clips are cross-faded into a seamless loop and encoded as Theora.
#   GODOT=/path/to/godot modules/ui/tools/record_highlights.sh
# Needs a display (or Xvfb: DISPLAY=:91 after `Xvfb :91 -screen 0 1920x1080x24 &`)
# and ffmpeg with libtheora. Slow on a software renderer (a few minutes per clip).
set -eu
GODOT="${GODOT:-godot}"
DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
OUT="${OUT:-$DIR/modules/ui/media/highlights.ogv}"
WORK="${WORK:-$(mktemp -d)}"
FPS=30
RES="${RES:-1600x900}"
KEEP="${KEEP:-8}"
# name | race options (film-from = race seconds to skip to)
CLIPS=(
  "spa_golden|--track spa --class GT3 --ai 18 --weather dry --time 18 --zoom 0.13 --film-from 35"
  "mugello_day|--track mugello --class GT3 --ai 18 --weather dry --time 14 --zoom 0.05 --rotate-camera --film-from 30"
  "monza_multiclass|--track monza --class multi --ai 26 --weather overcast --time 12 --zoom 0.14 --film-from 25"
  "silverstone_rain|--track silverstone --class GT3 --ai 18 --weather light_rain --time 13 --zoom 0.08 --film-from 40"
)
# Film without the driving aids on screen, in a window of exactly RES.
cat >"$WORK/film_settings.cfg" <<'CFG'
[prefs]
display_mode="windowed"
aid_driving_line=0
aid_braking_zones=false
show_fps=false
CFG
PARTS=()
for c in "${CLIPS[@]}"; do
  IFS='|' read -r name opts <<<"$c"
  if [ ! -s "$WORK/$name.mp4" ]; then
    echo "[highlights] filming $name"
    # Generous frame budget: loading + fast-forward + the clip itself.
    # shellcheck disable=SC2086
    "$GODOT" --path "$DIR" --resolution "$RES" --write-movie "$WORK/$name.avi" --fixed-fps $FPS \
      --quit-after $(( (KEEP + 2) * FPS + 220 )) -- --single --autodrive --laps 5 --no-hud \
      --settings "$WORK/film_settings.cfg" $opts >"$WORK/$name.log" 2>&1 || true
    start=$(grep -o "rolling at frame [0-9]*" "$WORK/$name.log" | grep -o "[0-9]*$" || echo 200)
    ss=$(python3 -c "print(round(($start + 15) / $FPS, 3))")
    ffmpeg -y -loglevel error -ss "$ss" -t "$KEEP" -i "$WORK/$name.avi" -an -vf "fps=$FPS,format=yuv420p" \
      -c:v libx264 -crf 14 "$WORK/$name.mp4"
  fi
  PARTS+=("$WORK/$name.mp4")
done
# Cross-fade the clips into one loop, ending with a fade back into the first
# clip, then cut so the last frame leads straight into the first.
FADE=1
inputs=()
for p in "${PARTS[@]}" "${PARTS[0]}"; do inputs+=(-i "$p"); done
filter=""
prev="[0:v]"
offset=0
n=${#PARTS[@]}
for i in $(seq 1 "$n"); do
  len=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "${PARTS[$((i-1))]}")
  offset=$(python3 -c "print(round($offset + $len - $FADE, 3))")
  filter+="${prev}[$i:v]xfade=transition=fade:duration=$FADE:offset=$offset[v$i];"
  prev="[v$i]"
done
ffmpeg -y -loglevel error "${inputs[@]}" -filter_complex "${filter%;}" -map "$prev" -an \
  -ss "$FADE" -t "$(python3 -c "print(round($offset, 3))")" \
  -c:v libtheora -q:v 5 -g 90 "$OUT"
ls -la "$OUT"
echo "[highlights] done: $OUT"
