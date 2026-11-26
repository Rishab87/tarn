#!/bin/zsh
# Drives the Debug build's "Ask about your screen" hooks against a scratch profile, prints the
# app's log as it runs, and waits for it to quit.
#   scripts/dev/screen_ask.sh <profile> <models-dir> <app args...>
# e.g. scripts/dev/screen_ask.sh /tmp/p "$HOME/Library/Application Support/Tarn/models" \
#        -TarnScreenAskBatch batch.json -TarnOffline YES
# LOCK=<dir> takes that lock directory (mkdir, atomic) for the run and writes the app and
# engine PIDs to LOCK/owner; the run refuses to start if someone else holds it.
# Only processes this script started are ever signalled (never a pattern-wide pkill), so other
# Tarn copies sharing the models folder are left alone.
set -u
PROFILE=$1; MODELS=$2; shift 2
ROOT=${0:A:h:h:h}
APP=$ROOT/build/DerivedData/Build/Products/Debug/Tarn.app
mkdir -p "$PROFILE"; rm -f "$PROFILE/tour.log"
if [[ -n ${LOCK:-} ]]; then
  mkdir "$LOCK" 2>/dev/null || { echo "lock held: $(cat "$LOCK/owner" 2>/dev/null)"; exit 3; }
  echo "circle-ask (starting)" > "$LOCK/owner"
fi
release() { [[ -n ${LOCK:-} && -d $LOCK ]] && rm -rf "$LOCK" && echo "lock released"; }
open -n -g --env TARN_DATA_DIR="$PROFILE" --env TARN_MODELS_DIR="$MODELS" "$APP" --args "$@"
sleep 2
PID=$(pgrep -n -f "$APP/Contents/MacOS/Tarn")
[[ -z $PID ]] && { cat "$PROFILE/tour.log" 2>/dev/null || echo "app didn't start"; release; exit 0; }
echo "app pid $PID"
engine=""
seen=0
while kill -0 $PID 2>/dev/null; do
  if [[ -z $engine ]]; then
    for w in $(pgrep -P $PID); do e=$(pgrep -P $w -x llama-server); [[ -n $e ]] && engine=$e; done
    if [[ -n $engine ]]; then
      echo "engine pid $engine"
      [[ -n ${LOCK:-} ]] && echo "circle-ask app=$PID engine=$engine" > "$LOCK/owner"
    fi
  fi
  if [[ -f $PROFILE/tour.log ]]; then
    lines=("${(@f)$(<$PROFILE/tour.log)}")
    while (( seen < ${#lines} )); do seen=$((seen+1)); echo "$(date +%H:%M:%S) ${lines[$seen]}"; done
  fi
  sleep 0.5
done
if [[ -f $PROFILE/tour.log ]]; then
  lines=("${(@f)$(<$PROFILE/tour.log)}")
  while (( seen < ${#lines} )); do seen=$((seen+1)); echo "$(date +%H:%M:%S) ${lines[$seen]}"; done
fi
echo "$(date +%H:%M:%S) app quit"
if [[ -n $engine ]]; then
  for i in {1..10}; do kill -0 $engine 2>/dev/null || break; sleep 0.5; done
  if kill -0 $engine 2>/dev/null; then echo "LEAK: engine $engine outlived the app"; kill $engine; else echo "engine stopped with the app"; fi
fi
release
