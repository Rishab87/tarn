"""Builds video/timeline-screen.json for render.swift: the "Ask about your screen" demo.

One continuous shot of the real screen at real time (nothing is sped up or cut, so every wait
for the model is on screen), framed by the same slow camera as the main demo, then the end card
on the pixel tarn. Small pills say what the scripted hand does ("holding ⌥⌘"), and a "real
time" tag sits where the main video says "sped up".

Input: footage/<name>.marks from make_screen_demo.sh: "<seconds> <mark>" lines, and
"BOX <name> x y w h" lines in screen points from the top left (BOX screen is the display).

    python3 video/build_screen_timeline.py [footage/screen.marks] [footage/screen.mov] [timeline-screen.json]
"""

import json
import sys
from pathlib import Path

HERE = Path(__file__).parent
BEAT, FIRST_BEAT = 60 / 99.38, 0.49   # "A Lonely Cherry Tree" by Pix, as in build_timeline.py

marks_path = Path(sys.argv[1]) if len(sys.argv) > 1 else HERE / "footage/screen.marks"
src = sys.argv[2] if len(sys.argv) > 2 else "footage/screen.mov"
out = Path(sys.argv[3]) if len(sys.argv) > 3 else HERE / "timeline-screen.json"

marks, boxes = {}, {}
for line in marks_path.read_text().splitlines():
    p = line.split()
    if not p:
        continue
    if p[0] == "BOX":
        boxes[p[1]] = tuple(float(v) for v in p[2:6])
    else:
        marks[p[1]] = float(p[0])

SW, SH = boxes.get("screen", (0, 0, 1470, 956))[2:]
WHOLE = (0.5, 0.5, 1.0)


def frame(*names, fill=0.82, zmax=1.9):
    """Camera framing that fits the union of these boxes, as (x, y, zoom)."""
    rs = [boxes[n] for n in names if n in boxes]
    if not rs:
        return WHOLE
    x0 = min(r[0] for r in rs); y0 = min(r[1] for r in rs)
    x1 = max(r[0] + r[2] for r in rs); y1 = max(r[1] + r[3] for r in rs)
    z = fill / max((x1 - x0) / SW, (y1 - y0) / SH)
    return ((x0 + x1) / 2 / SW, (y0 + y1) / 2 / SH, max(1.0, min(zmax, z)))


def m(name, default=None):
    if name in marks:
        return marks[name]
    if default is not None:
        return default
    raise SystemExit(f"{marks_path} has no '{name}' mark: the take didn't finish. Run make_screen_demo.sh again.")


# The clip: from just before the first ⌥⌘ to the end of the chat shot, at speed 1.
t0 = max(0.0, m("start") + 0.6)
cam = []


def key(t, f):
    cam.append([round(t - t0, 3), *[round(v, 4) for v in f]])


key(t0, WHOLE)
captions = []
for beat in (1, 2):
    chord, draw, panel = m(f"chord{beat}"), m(f"draw{beat}"), m(f"panel{beat}")
    done = m(f"done{beat}")
    captions.append({"from": round(chord - 0.1 - t0, 3), "to": round(m(f"overlay{beat}") + 0.9 - t0, 3),
                     "text": "holding ⌥⌘" if beat == 1 else "holding ⇧⌥⌘"})
    key(draw, WHOLE)                                   # the ripple and the frozen screen, whole
    key(draw + 1.0, frame(f"sel{beat}", fill=0.6))     # in on the loop as it closes
    key(panel + 0.3, frame(f"sel{beat}", fill=0.6))
    key(panel + 1.4, frame(f"panel{beat}", fill=0.86))  # over to the box: the question, then the answer
    key(done + 0.9, frame(f"panel{beat}", fill=0.86))
    nxt = m("chord2") if beat == 1 else m("continue")
    key(max(done + 2.0, nxt - 0.05), WHOLE)            # back out before the next hold
chat = m("chat")
key(chat + 0.1, WHOLE)
key(chat + 1.6, frame("chat", fill=0.9))
end = m("end")
key(end, frame("chat", fill=0.9))

# Cut at the end of the chat shot, on a beat, so the dissolve into the card lands on the music.
dur = end - t0
beat_end = FIRST_BEAT + round((dur - FIRST_BEAT) / BEAT) * BEAT
if beat_end <= dur:
    dur = beat_end
cam = [k for k in cam if k[0] <= dur] + ([[round(dur, 3), *cam[-1][1:]]] if cam[-1][0] > dur else [])
cam.sort(key=lambda k: k[0])
clip = {"type": "clip", "src": src, "dur": round(dur, 4), "map": [[0, t0], [round(dur, 4), round(t0 + dur, 4)]],
        "cam": cam, "fadeIn": 0, "tag": "real time", "captions": captions}
card = {"type": "card", "dur": 6.5, "frames": "card", "fadeIn": 1.2,
        "lines": ["tarn", "circle anything on your mac and ask.", "music: a lonely cherry tree by pix"]}
timeline = {"fps": 60, "width": 1848, "height": 1200, "fadeIn": 1.2, "fadeOut": 1.2, "segments": [clip, card]}
out.write_text(json.dumps(timeline, indent=1))
print(f"{out.name}: real-time clip {dur:.1f} s (source {t0:.1f}–{t0 + dur:.1f} s) + card 6.5 s = {dur + 6.5:.1f} s")
for k in cam:
    print("  cam", k)
