#!/bin/zsh
# Headless end-to-end check: opens the Debug build against a scratch profile, sends one message
# through the real agent loop (DEBUG-only -TarnAutoSend hook), waits for the answer, prints it,
# then quits the app and its engine.
#   scripts/dev/autosend.sh <profile-dir> <models-dir> "question" [folder]
set -u
PROFILE=$1; MODELS=$2; QUESTION=$3; FOLDER=${4:-}
ROOT=${0:A:h:h:h}
APP=$ROOT/build/DerivedData/Build/Products/Debug/Tarn.app
rm -rf "$PROFILE/chats"
args=(-TarnAutoSend "$QUESTION")
[[ -n $FOLDER ]] && args+=(-TarnAutoFolder "$FOLDER")
open -n -g --env TARN_DATA_DIR=$PROFILE --env TARN_MODELS_DIR=$MODELS --env TARN_LLAMA_SERVER=${TARN_LLAMA_SERVER:-/opt/homebrew/bin/llama-server} "$APP" --args "${args[@]}"
cleanup() {
  # Force-kill the app on purpose: the engine watchdog must take llama-server down with it.
  pkill -9 -f "$APP/Contents/MacOS/Tarn" 2>/dev/null
  sleep 2.5
  if pgrep -f "llama-server -m $MODELS" >/dev/null; then echo "LEAK: engine survived the app"; pkill -f "llama-server -m $MODELS"; else echo "engine stopped with the app"; fi
}
trap cleanup EXIT
for i in {1..300}; do
  sleep 1
  f=$(ls "$PROFILE"/chats 2>/dev/null | grep json | head -1)
  [[ -n $f ]] && f="$PROFILE/chats/$f"
  [[ -z $f ]] && continue
  st=$(python3 -c "import json,sys; m=json.load(open('$f'))['messages']; a=[x for x in m if x['role']=='assistant']; print(a[-1].get('status','') if a else '')" 2>/dev/null)
  [[ $st == done || $st == error || $st == stopped ]] && break
done
sleep 2
python3 - "$PROFILE" <<'PY'
import json, sys, glob
p = sys.argv[1]
for f in glob.glob(f"{p}/chats/*.json"):
    c = json.load(open(f))
    print("TITLE:", c["title"])
    for m in c["messages"]:
        if m["role"] == "user":
            print("USER:", m["text"][:200]); continue
        print("ASSISTANT status=%s tokens=%s ms=%s error=%s" % (m.get("status"), m.get("tokens"), m.get("ms"), m.get("error")))
        for b in m["blocks"]:
            if b["type"] == "text": print("  [text]", b["text"][:700].replace("\n", " ⏎ "))
            elif b["type"] == "thinking": print("  [thinking]", len(b["text"]), "chars")
            else:
                t = b["tool"]; print("  [tool]", t["name"], t["status"], "|", t["label"], "|", (t.get("result") or "")[:160].replace("\n", " "))
s = json.load(open(f"{p}/settings.json"))
print("WATER:", s.get("water"))
PY
