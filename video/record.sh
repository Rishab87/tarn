#!/bin/zsh
# Records the Debug demo of Tarn for the demo video and the website's clips: the whole screen (menu
# bar, desktop, Dock) at 60 fps without the cursor. For the take, every other app is hidden and the
# Mac switches to light mode; both are put back afterwards, even if the take is interrupted.
#   video/record.sh <onboarding|main> <profile> <models-dir> [extra app args…]
# Writes video/footage/<mode>.mov and video/footage/<mode>.marks (scene times in seconds from the
# start of the recording, and the window's RECT x,y,w,h in points from the top left).
# Needs Screen Recording permission for the terminal running it.
set -u
MODE=$1; PROFILE=$2; MODELS=$3; shift 3
ROOT=${0:A:h:h}
APP=$ROOT/build/DerivedData/Build/Products/Debug/Tarn.app
OUT=$ROOT/video/footage; mkdir -p $OUT
rm -f "$PROFILE/tour.log" "$PROFILE/tour.ack" "$OUT/$MODE.mov"

WAS_DARK=$(osascript -e 'tell application "System Events" to tell appearance preferences to get dark mode')
# Take the list of names first, then hide by name: hiding while iterating the live list skips apps.
HIDDEN=$(osascript <<'AS'
tell application "System Events"
  set names to name of every application process whose visible is true and background only is false
  repeat with n in names
    try
      set visible of application process (n as text) to false
    end try
  end repeat
  set AppleScript's text item delimiters to linefeed
  return names as text
end tell
AS
)
echo "hidden for the take: ${HIDDEN//$'\n'/, }"
restore() {
  osascript -e "tell application \"System Events\" to tell appearance preferences to set dark mode to $WAS_DARK"
  for app in ${(f)HIDDEN}; do osascript -e "tell application \"System Events\" to set visible of process \"$app\" to true" 2>/dev/null; done
}
trap restore EXIT
osascript -e 'tell application "System Events" to tell appearance preferences to set dark mode to false'

envs=(--env TARN_DATA_DIR="$PROFILE" --env TARN_MODELS_DIR="$MODELS")
[[ -n ${TARN_LLAMA_SERVER:-} ]] && envs+=(--env TARN_LLAMA_SERVER="$TARN_LLAMA_SERVER")
open -n "${envs[@]}" "$APP" --args -TarnDemo $MODE -ApplePersistenceIgnoreState YES "$@"
for i in {1..60}; do grep -q WAIT-RECORDER "$PROFILE/tour.log" 2>/dev/null && break; sleep 0.5; done
ffmpeg -hide_banner -loglevel error -f avfoundation -pixel_format nv12 -framerate 60 -capture_cursor 0 \
  -i "Capture screen 0:none" -c:v h264_videotoolbox -b:v 50M -g 30 -pix_fmt yuv420p -y "$OUT/$MODE.mov" &
REC=$!
START=$(python3 -c 'import time; print(f"{time.time():.3f}")')
# Wait until frames are actually being written before the demo starts, so the marks line up.
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
    elif p and p[0] == "RECT":
        print(f"RECT {p[1]}")
PY
cat "$OUT/$MODE.marks"
ls -la "$OUT/$MODE.mov"
