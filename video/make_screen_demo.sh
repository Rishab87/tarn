#!/bin/zsh
# Records the "Ask about your screen" demo with the real 9B model and builds two videos:
#   video/out/tarn-screen-raw.mp4    the take exactly as recorded: real time, uncut, no music
#   video/out/tarn-screen-demo.mp4   the edited version in the style of tarn-demo.mp4, with music
#
#   video/make_screen_demo.sh            record a take and build both (a retake = run it again)
#   video/make_screen_demo.sh --render   rebuild both videos from the last take, no recording
#   video/make_screen_demo.sh --dry-run  TEST ONLY: a fixture image stands in for the screen;
#                                        nothing is recorded and no video is made
#
# What happens on screen during a take (about a minute; the recording itself is ~38 s):
#   1. Every visible app is hidden (all of them come back at the end, even if the take fails).
#   2. Preview opens video/props/kestrel-install-guide.png (a made-up install guide), then Disk
#      Utility opens on your startup disk. THE VIDEO SHOWS THAT WINDOW: your disk's name, size
#      and free space, macOS version and snapshot name. Change R1/R2/Q1/Q2 to film something else.
#   3. Tarn's Debug build starts as this terminal's child (its window shows while the AI loads,
#      then closes) and the recording starts.
#   4. ⌥⌘ (simulated), a loop around Disk Utility's usage figures, a typed question, the answer.
#   5. Preview comes forward; ⇧⌥⌘ (simulated), a loop around the guide's requirements, a question.
#   6. Continue in chat: Tarn's chat window opens. Tarn quits and the recording stops.
#   7. Preview and Disk Utility quit and the hidden apps come back.
# Appearance is never changed. Quitting Disk Utility saves its window size to
# ~/Library/Preferences/com.apple.DiskUtility.plist; `defaults delete com.apple.DiskUtility` undoes it.
# Needs: Screen Recording for the terminal that runs this (Tarn is started as its child and
# inherits it), the Debug build, the Qwen3.5 9B model and its vision add-on, the music, ffmpeg, node.
set -u
ROOT=${0:A:h:h}
V=$ROOT/video
APP=$ROOT/build/DerivedData/Build/Products/Debug/Tarn.app
MODELS=${TARN_MODELS_DIR:-$HOME/Library/Application Support/Tarn/models}
MUSIC=${MUSIC:-$V/music/lonely-cherry-tree.m4a}
MODE=${1:-take}
[[ $MODE == --render ]] && MODE=render
[[ $MODE == --dry-run ]] && MODE=dry
R1=${R1:-"Disk Utility|disk"}   # what to circle; Tarn finds it on screen by its text
R2=${R2:-"Preview|guide"}
Q1=${Q1:-"How much free space do I have?"}
Q2=${Q2:-"Is that enough to install this?"}
# Optional coordination with other agents on the same Mac: a lock directory taken for the take.
LOCK=${LOCK:-}

say() { print -- "$*"; }
die() { print -- "\nStopped: $*"; exit 1; }
cd $V

# MARK: render (also the last step of a take)
render() {
  [[ -f footage/screen.mov && -f footage/screen.marks ]] || die "no take to render yet (footage/screen.mov). Run video/make_screen_demo.sh first."
  [[ -f $MUSIC ]] || die "the music is missing: put \"A Lonely Cherry Tree\" by Pix at $MUSIC"
  mkdir -p out
  say "Raw take → out/tarn-screen-raw.mp4 (real time, uncut, no music)"
  ffmpeg -v error -y -i footage/screen.mov -an -c:v libx264 -preset slow -crf 21 -pix_fmt yuv420p -movflags +faststart out/tarn-screen-raw.mp4 \
    || die "ffmpeg couldn't encode the raw take"
  say "Edited version → out/tarn-screen-demo.mp4"
  python3 build_screen_timeline.py footage/screen.marks footage/screen.mov timeline-screen.json || die "couldn't build the timeline from the take's marks"
  [[ -d card ]] || node make_card.mjs || die "couldn't draw the end card (needs node)"
  swiftc -O -o render render.swift || die "couldn't build render.swift"
  ./render timeline-screen.json out/screen-raw-edit.mp4 | tail -1
  local dur outro
  dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 out/screen-raw-edit.mp4)
  outro=$(python3 -c "print(max(0, $dur - 3.5))")
  ffmpeg -v error -y -i out/screen-raw-edit.mp4 -i "$MUSIC" -filter_complex \
    "[1:a]atrim=0:$dur,asetpts=PTS-STARTPTS,afade=t=in:d=1.2,afade=t=out:st=$outro:d=3.5[m]" \
    -map 0:v -map "[m]" -c:v copy -c:a aac -b:a 256k -movflags +faststart out/tarn-screen-demo.mp4 || die "couldn't add the music"
  rm -f out/screen-raw-edit.mp4
  for f in out/tarn-screen-raw.mp4 out/tarn-screen-demo.mp4; do
    say "  $V/$f: $(ffprobe -v error -show_entries stream=width,height,r_frame_rate:format=duration,size -of compact=p=0:nk=1 $f | tr '\n' ' ')"
  done
}
if [[ $MODE == render ]]; then render; exit 0; fi

# MARK: checks, in plain words
say "Checking what the take needs…"
command -v ffmpeg >/dev/null || die "ffmpeg isn't installed (brew install ffmpeg)."
[[ -x $APP/Contents/MacOS/Tarn ]] || die "the Debug build is missing. Build it: xcodegen generate && xcodebuild -scheme Tarn -configuration Debug -derivedDataPath build/DerivedData build"
[[ -f $MODELS/qwen3.5-9b.gguf ]] || die "the 9B model isn't in $MODELS (open Tarn once and let it download, or set TARN_MODELS_DIR)."
[[ -f $MODELS/qwen3.5-9b.mmproj.gguf ]] || die "the 9B model's vision add-on isn't in $MODELS (send Tarn an image once so it downloads)."
[[ $MODE == dry || -f $MUSIC ]] || die "the music is missing: put \"A Lonely Cherry Tree\" by Pix at $MUSIC"
for tool in stage make_screen_props; do
  [[ -x $tool && $tool -nt $tool.swift ]] || swiftc -O -o $tool $tool.swift 2>/dev/null || die "couldn't build $tool.swift"
done
./stage locked && die "the Mac's screen is locked. Unlock it and run this again (a take needs the desktop)."
./stage can-record || die "this terminal doesn't have Screen Recording permission. Allow it in System Settings → Privacy & Security → Screen & System Audio Recording, then quit and reopen the terminal."
if [[ $MODE == take ]]; then
  [[ -z $(./stage running com.apple.Preview) ]] || die "Preview is open. Quit it first (its windows would be filmed, and the take quits the Preview it opens)."
  [[ -z $(./stage running com.apple.DiskUtility) ]] || die "Disk Utility is open. Quit it first."
fi
[[ -z $(pgrep -f "$APP/Contents/MacOS/Tarn") ]] || die "a Tarn Debug build from this folder is already running. Quit it first."
[[ -f props/kestrel-install-guide.png ]] || ./make_screen_props props >/dev/null || die "couldn't draw the demo document"

# The lock (if asked for) covers everything below: the 9B and the staged screen.
LOCKED=""
if [[ -n $LOCK ]]; then
  for i in {1..600}; do
    if mkdir "$LOCK" 2>/dev/null; then LOCKED=1; break; fi
    pid=$(grep -o 'pid=[0-9]*' "$LOCK/owner" 2>/dev/null | head -1 | cut -d= -f2)
    if [[ -n $pid ]] && ! kill -0 $pid 2>/dev/null; then rm -rf "$LOCK"; continue; fi
    (( i % 30 == 1 )) && say "Waiting for the lock: $(cat "$LOCK/owner" 2>/dev/null)"
    sleep 1
  done
  [[ -n $LOCKED ]] || die "the lock stayed busy for 10 minutes."
  echo "circle-ask (Claude, exp/circle-ask) make_screen_demo $MODE pid=$$" > "$LOCK/owner"
fi
others=$(pgrep -x llama-server)
if [[ -n $others ]]; then
  [[ -n $LOCKED ]] && rm -rf "$LOCK"
  die "another AI engine is running (llama-server pid $others). Wait for it to finish; this script never stops processes it didn't start."
fi

# MARK: staging, with a restore that always runs
APPEARANCE=$(defaults read -g AppleInterfaceStyle 2>/dev/null || echo Light)
HIDDEN=""; STARTED=(); TARN=""; REC=""
restore() {
  [[ -n $REC ]] && kill -0 $REC 2>/dev/null && kill -INT $REC 2>/dev/null && wait $REC 2>/dev/null
  [[ -n $TARN ]] && kill -0 $TARN 2>/dev/null && kill $TARN 2>/dev/null && sleep 2
  for p in $STARTED; do ./stage quit $p; done
  [[ -n $HIDDEN ]] && ./stage unhide ${=HIDDEN}
  [[ -n $HIDDEN && -n $(./stage still-hidden ${=HIDDEN}) ]] && sleep 1 && ./stage unhide ${=HIDDEN}
  [[ -n $LOCKED ]] && rm -rf "$LOCK"
  # Say what state the Mac is back in.
  local left=""
  for p in $STARTED; do kill -0 $p 2>/dev/null && left+=" $p"; done
  [[ -n $TARN ]] && kill -0 $TARN 2>/dev/null && left+=" tarn:$TARN"
  local still=""
  [[ -n $HIDDEN ]] && still=$(./stage still-hidden ${=HIDDEN})
  local now=$(defaults read -g AppleInterfaceStyle 2>/dev/null || echo Light)
  say "Restored: apps hidden for the take: ${HIDDEN:-none}; still hidden: ${still:-none}. Apps the take opened still running: ${left:-none}. Appearance: $now (was $APPEARANCE)."
}
trap restore EXIT INT TERM

PROFILE=$V/.demo-profile
[[ $MODE == dry ]] && PROFILE=$V/.dryrun-profile
rm -rf $PROFILE; mkdir -p $PROFILE
print '{"onboarded": true, "theme": "system", "webSearch": false, "memoryEnabled": false, "screenAsk": false, "autoUpdate": false}' > $PROFILE/settings.json
python3 - "$ROOT/Tarn/Resources/catalog.json" > $PROFILE/models.json <<'PY'
import json, sys
c = json.load(open(sys.argv[1])); ms = c["models"] if isinstance(c, dict) else c
m = next(x for x in ms if x["id"] == "qwen3.5-9b")
print(json.dumps([{"id": m["id"], "fileName": "qwen3.5-9b.gguf", "sha256": m["file"]["sha256"], "size": m["file"]["size"],
                   "installedAt": "2026-01-01T00:00:00Z", "visionFileName": "qwen3.5-9b.mmproj.gguf"}]))
PY

args=(-TarnDemo screen -TarnOffline YES -ApplePersistenceIgnoreState YES -TarnScreenDemoQ1 "$Q1" -TarnScreenDemoQ2 "$Q2")
if [[ $MODE == dry ]]; then
  say "DRY RUN: a fixture image stands in for the screen. Nothing is recorded; this checks the hand, the panel and the answers."
  args+=(-TarnScreenDemoFixture "$V/props/DRY-RUN-fixture-screen.png" -TarnScreenDemoRegion1 "fixture|80,140,560,220" -TarnScreenDemoRegion2 "fixture|808,316,504,196")
else
  args+=(-TarnScreenDemoRegion1 "$R1" -TarnScreenDemoRegion2 "$R2")
  HIDDEN=$(./stage hide)
  say "Hid for the take: pids ${HIDDEN:-none}"
  open -a Preview "$V/props/kestrel-install-guide.png" --args -ApplePersistenceIgnoreState YES
  for i in {1..20}; do [[ -n $(./stage running com.apple.Preview) ]] && break; sleep 0.25; done
  STARTED+=($(./stage running com.apple.Preview))
  sleep 1.5
  open -a "Disk Utility" --args -ApplePersistenceIgnoreState YES
  for i in {1..20}; do [[ -n $(./stage running com.apple.DiskUtility) ]] && break; sleep 0.25; done
  STARTED+=($(./stage running com.apple.DiskUtility))
  sleep 2
fi

# Tarn runs as this terminal's child, so its capture uses the terminal's Screen Recording grant.
TARN_DATA_DIR=$PROFILE TARN_MODELS_DIR=$MODELS "$APP/Contents/MacOS/Tarn" "${args[@]}" > $PROFILE/stdout.log 2>&1 &
TARN=$!
say "Tarn pid $TARN; loading the AI…"
for i in {1..360}; do
  grep -qE "WAIT-RECORDER|^ERROR" $PROFILE/tour.log 2>/dev/null && break
  kill -0 $TARN 2>/dev/null || break
  sleep 0.5
done
if grep -q "^ERROR" $PROFILE/tour.log 2>/dev/null || ! grep -q WAIT-RECORDER $PROFILE/tour.log 2>/dev/null; then
  grep -E "^(ERROR|INFO)" $PROFILE/tour.log 2>/dev/null
  if grep -q "NO-SCREEN-RECORDING" $PROFILE/tour.log 2>/dev/null; then
    die "Tarn can't capture the screen. Run this from a terminal that has Screen Recording (Tarn inherits it)."
  fi
  die "Tarn didn't get ready (see $PROFILE/tour.log)."
fi
engine=""
for w in $(pgrep -P $TARN); do e=$(pgrep -P $w -x llama-server); [[ -n $e ]] && engine=$e; done
[[ -n $LOCKED ]] && echo "circle-ask (Claude, exp/circle-ask) make_screen_demo $MODE pid=$$ tarn=$TARN engine=$engine" > "$LOCK/owner"

mkdir -p footage
START=""
if [[ $MODE == take ]]; then
  rm -f footage/screen.mov footage/screen.marks
  ffmpeg -hide_banner -loglevel error -f avfoundation -pixel_format nv12 -framerate 60 -capture_cursor 0 \
    -i "Capture screen 0:none" -c:v h264_videotoolbox -b:v 50M -g 30 -pix_fmt yuv420p -y footage/screen.mov &
  REC=$!
  START=$(python3 -c 'import time; print(f"{time.time():.3f}")')
  for i in {1..100}; do [[ $(stat -f%z footage/screen.mov 2>/dev/null || echo 0) -gt 200000 ]] && break; sleep 0.05; done
fi
[[ -n $START ]] && say "Recording; the demo runs now." || say "The demo runs now (not recording)."
echo go > $PROFILE/tour.ack
seen=0
while kill -0 $TARN 2>/dev/null; do
  if [[ -f $PROFILE/tour.log ]]; then
    lines=("${(@f)$(<$PROFILE/tour.log)}")
    while (( seen < ${#lines} )); do seen=$((seen+1)); [[ ${lines[$seen]} == (TEXT*|ANSWER*|ERROR*|INFO\ chat*) ]] && say "  ${lines[$seen]}"; done
  fi
  sleep 0.5
done
sleep 0.5
if [[ -n $REC ]]; then kill -INT $REC 2>/dev/null; wait $REC 2>/dev/null; REC=""; fi
if [[ -n $engine ]]; then for i in {1..10}; do kill -0 $engine 2>/dev/null || break; sleep 0.5; done; kill -0 $engine 2>/dev/null && say "Warning: engine $engine outlived Tarn" && kill $engine; fi
grep -q "^DONE" $PROFILE/tour.log || { grep -E "^ERROR" $PROFILE/tour.log; die "the demo didn't finish, so this take can't be used. Run the script again for a retake."; }

if [[ $MODE == dry ]]; then say "Dry run finished (no recording)."; exit 0; fi
python3 - $PROFILE/tour.log $START > footage/screen.marks <<'PY'
import sys
start = float(sys.argv[2])
for line in open(sys.argv[1]):
    p = line.split()
    if p and p[0] == "MARK":
        print(f"{float(p[1]) - start:.3f} {p[2]}")
    elif p and p[0] == "BOX":
        print(line.strip())
PY
cp $PROFILE/tour.log footage/screen.log
trap - EXIT INT TERM
restore
render
say "\nBoth answers from this take are above (TEXT1, TEXT2). If either is wrong, run this script again for a retake."
