#!/bin/zsh
# Records the debug demo of Tarn for the launch video.
#   video/record.sh <onboarding|main> <profile> <models-dir> [extra app args…]
# Writes video/footage/<mode>.mov and video/footage/<mode>.marks (scene times in seconds
# from the start of the recording).
set -u
MODE=$1; PROFILE=$2; MODELS=$3; shift 3
ROOT=${0:A:h:h}
APP=$ROOT/build/DerivedData/Build/Products/Debug/Tarn.app
OUT=$ROOT/video/footage; mkdir -p $OUT
rm -f "$PROFILE/tour.log" "$PROFILE/tour.ack" "$OUT/$MODE.mov"
envs=(--env TARN_DATA_DIR="$PROFILE" --env TARN_MODELS_DIR="$MODELS")
[[ -n ${TARN_LLAMA_SERVER:-} ]] && envs+=(--env TARN_LLAMA_SERVER="$TARN_LLAMA_SERVER")
open -n "${envs[@]}" "$APP" --args -TarnDemo $MODE "$@"
for i in {1..60}; do grep -q WAIT-RECORDER "$PROFILE/tour.log" 2>/dev/null && break; sleep 0.5; done
RECT=$(grep -m1 '^RECT' "$PROFILE/tour.log" | cut -d' ' -f2)
echo "recording rect $RECT"
screencapture -v -x -V 600 -R $RECT "$OUT/$MODE.mov" &
REC=$!
START=$(python3 -c 'import time; print(f"{time.time():.3f}")')
sleep 0.3
echo go > "$PROFILE/tour.ack"
PID=$(pgrep -n -f "$APP/Contents/MacOS/Tarn")
while kill -0 $PID 2>/dev/null; do sleep 0.5; done
kill -INT $REC 2>/dev/null; wait $REC 2>/dev/null
python3 - "$PROFILE/tour.log" "$START" > "$OUT/$MODE.marks" <<'PY'
import sys
start = float(sys.argv[2])
for line in open(sys.argv[1]):
    p = line.split()
    if p and p[0] == "MARK":
        print(f"{float(p[1]) - start:.3f} {p[2]}")
PY
cat "$OUT/$MODE.marks"
ls -la "$OUT/$MODE.mov"
