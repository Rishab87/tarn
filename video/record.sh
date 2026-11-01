#!/bin/zsh
# Records the Debug demo of Tarn for the launch video and website clips.
#   video/record.sh <onboarding|main> <profile> <models-dir> [extra app args…]
# Writes video/footage/<mode>.mov (the app window only, no cursor, 60 fps) and
# video/footage/<mode>.marks (scene times in seconds from the start of the recording).
# Needs Screen Recording permission for the terminal running it.
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
# RECT x,y,w,h is the window in points from the top-left of the screen; capture is at 2x.
IFS=, read X Y W H <<< "$(grep -m1 '^RECT' "$PROFILE/tour.log" | cut -d' ' -f2)"
CROP="crop=$((W*2)):$((H*2)):$((X*2)):$((Y*2))"
echo "recording $CROP"
ffmpeg -hide_banner -loglevel error -f avfoundation -pixel_format nv12 -framerate 60 -capture_cursor 0 \
  -i "Capture screen 0:none" -vf "$CROP" -c:v h264_videotoolbox -b:v 40M -g 30 -pix_fmt yuv420p -y "$OUT/$MODE.mov" &
REC=$!
START=$(python3 -c 'import time; print(f"{time.time():.3f}")')
# Wait until frames are actually being written before the demo starts. Measured: the first frame
# lands ~0.3 s after launch, so START (taken at launch) lines marks up with the video within a frame or two.
for i in {1..100}; do [[ $(stat -f%z "$OUT/$MODE.mov" 2>/dev/null || echo 0) -gt 200000 ]] && break; sleep 0.05; done
echo go > "$PROFILE/tour.ack"
sleep 2
PID=$(pgrep -n -f "$APP/Contents/MacOS/Tarn")
while [[ -n $PID ]] && kill -0 $PID 2>/dev/null; do sleep 0.5; done
sleep 0.5
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
