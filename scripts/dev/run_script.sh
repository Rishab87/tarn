#!/bin/zsh
# Plays a JSON chat script through the Debug build (DEBUG-only -TarnScript hook), auto-approving
# tool actions, prints the log, then checks the engine stopped when the app quit.
#   scripts/dev/run_script.sh <profile> <models-dir> <script.json>
set -u
PROFILE=$1; MODELS=$2; SCRIPT=$3
ROOT=${0:A:h:h:h}
APP=$ROOT/build/DerivedData/Build/Products/Debug/Tarn.app
rm -f "$PROFILE/tour.log"
envs=(--env TARN_DATA_DIR="$PROFILE" --env TARN_MODELS_DIR="$MODELS")
[[ -n ${TARN_LLAMA_SERVER:-} ]] && envs+=(--env TARN_LLAMA_SERVER="$TARN_LLAMA_SERVER")
bg=(-g); [[ -n ${FOREGROUND:-} ]] && bg=()   # FOREGROUND=1 opens the app in front (with animations)
open -n $bg "${envs[@]}" "$APP" --args -TarnScript "$SCRIPT" -TarnAutoApprove YES ${=EXTRA_ARGS:-}
sleep 3
PID=$(pgrep -n -f "$APP/Contents/MacOS/Tarn")
seen=0
while kill -0 $PID 2>/dev/null; do
  if [[ -f $PROFILE/tour.log ]]; then
    lines=("${(@f)$(<$PROFILE/tour.log)}")
    while (( seen < ${#lines} )); do seen=$((seen+1)); echo "$(date +%H:%M:%S) ${lines[$seen]}"; done
  fi
  sleep 1
done
echo "$(date +%H:%M:%S) app quit"
sleep 2.5
if pgrep -x llama-server >/dev/null && pgrep -fl llama-server | grep -q "$MODELS"; then echo "LEAK: engine still running"; pkill -f "llama-server -m $MODELS"; else echo "engine stopped with the app"; fi
