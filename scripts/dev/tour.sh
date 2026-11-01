#!/bin/zsh
# Full from-scratch UI tour of the Debug build (fresh profile, real model download, bundled
# engine). Screenshots every screen the app asks for, logs engine memory, then checks the
# engine stopped when the app quit.
#   scripts/dev/tour.sh <scratch-profile> <scratch-models-dir> <screenshot-dir>
set -u
PROFILE=$1; MODELS=$2; OUT=$3
ROOT=${0:A:h:h:h}
APP=$ROOT/build/DerivedData/Build/Products/Debug/Tarn.app
mkdir -p "$OUT" "$MODELS"
# KEEP_PROFILE=1 reuses an onboarded profile (skips onboarding); otherwise start from scratch.
if [[ -z ${KEEP_PROFILE:-} ]]; then rm -rf "$PROFILE"; fi
mkdir -p "$PROFILE"; rm -f "$PROFILE/tour.log" "$PROFILE/tour.ack"
envs=(--env TARN_DATA_DIR="$PROFILE" --env TARN_MODELS_DIR="$MODELS")
[[ -n ${TARN_LLAMA_SERVER:-} ]] && envs+=(--env TARN_LLAMA_SERVER="$TARN_LLAMA_SERVER")
open -n "${envs[@]}" "$APP" --args -TarnTour YES
sleep 3
PID=$(pgrep -n -f "$APP/Contents/MacOS/Tarn")
echo "app pid $PID"
seen=0; last_mem=0
while kill -0 $PID 2>/dev/null; do
  if [[ -f $PROFILE/tour.log ]]; then
    lines=("${(@f)$(<$PROFILE/tour.log)}")
    while (( seen < ${#lines} )); do
      seen=$((seen+1)); line=${lines[$seen]}
      echo "$(date +%H:%M:%S) $line"
      if [[ $line == SHOT* ]]; then
        parts=(${=line}); name=${parts[2]}; win=${parts[3]}
        wid=$("$ROOT/scripts/dev/winid" $PID $win)
        if [[ -n $wid ]]; then screencapture -x -o -l $wid "$OUT/$name.png"; else echo "  no $win window for $name"; fi
        echo $name > "$PROFILE/tour.ack"
      fi
    done
  fi
  if (( SECONDS - last_mem > 20 )); then
    last_mem=$SECONDS
    epid=$(pgrep -x llama-server | head -1)
    [[ -n $epid ]] && echo "$(date +%H:%M:%S) MEM engine rss=$(( $(ps -o rss= -p $epid) / 1024 )) MB, pressure=$(sysctl -n kern.memorystatus_vm_pressure_level)"
  fi
  sleep 0.4
done
echo "$(date +%H:%M:%S) app exited"
sleep 2.5
if pgrep -f "llama-server -m $MODELS" >/dev/null; then echo "LEAK: engine still running"; pkill -f "llama-server -m $MODELS"; else echo "engine stopped with the app"; fi
