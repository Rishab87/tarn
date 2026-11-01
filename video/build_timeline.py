"""Builds video/timeline.json for render.swift: Tarn's demo video, about 1.5 minutes.

A normal demo, not a motion piece: the whole Mac as recorded (menu bar, desktop, Dock), with a slow
camera that moves in to read and back out to show the Mac. Where the recording waits on the AI, a
soft dissolve skips ahead; dissolves start on a beat of the music ("A Lonely Cherry Tree" by Pix,
~99.4 BPM). Streaming answers play faster than real time, and the video says so while they do.

Recording: video/footage/main.mov (2940x1912, the whole screen) and main.marks, from
video/record.sh main … -TarnDemoWindow 1200x750 -TarnScene dusk.

    python3 video/build_timeline.py
"""

import json
from pathlib import Path

HERE = Path(__file__).parent
BEAT, FIRST_BEAT = 60 / 99.38, 0.49

# Camera framings on the screen: (x, y) = the point at the frame's centre, 0..1 from the top left;
# z = zoom, where 1 is the whole screen. The window fills the frame at z 1.225; nothing goes past 2.
WHOLE = (0.5, 0.5, 1.0)
WINDOW = (0.5, 0.472, 1.225)
COMPOSER = (0.548, 0.495, 1.65)      # the message box on a new chat, with the greeting above
LOW = (0.55, 0.65, 1.7)              # a message just sent and the steps under it
STREAM = (0.55, 0.47, 1.45)          # a long answer
CARD = (0.553, 0.52, 1.7)            # "Create Q4_Launch_Summary.docx?" and its buttons
DONE = (0.53, 0.52, 1.75)            # "Done! I've saved …"
ANSWER = (0.55, 0.47, 1.5)           # a finished answer
WATER = (0.78, 0.31, 2.0)            # the water counter's popover, top right


def shot(pieces, cam, fade=0.6):
    """pieces: [(source start, source end, speed), …] played back to back; cam: [(local s, framing)]."""
    local, keys = 0.0, []
    for a, b, speed in pieces:
        keys.append([round(local, 4), a])
        local += (b - a) / speed
        keys.append([round(local, 4), b])
    return {"type": "clip", "src": "footage/main.mov", "dur": local, "map": keys,
            "cam": [[t, *f] for t, f in cam], "fadeIn": fade}


def move(t0, t1, a, b):
    """Hold framing a until t0, then ease to b by t1."""
    return [(t0, a), (t1, b)]


# Times are seconds into this recording (main.marks; answer start times read off the footage).
segments = [
    # The whole Mac, then in to the message box as the first message is typed and sent.
    shot([(0.9, 9.6, 1.0)], [(0, WHOLE)] + move(2.0, 4.4, WHOLE, COMPOSER) + move(7.7, 9.0, COMPOSER, LOW), fade=0),
    # It saves the fact to memory, then answers.
    shot([(13.3, 17.5, 2.1), (17.5, 20.6, 1.0)], [(0, LOW), (5.1, LOW)]),
    # A shared folder: turn the meeting notes into a Word document.
    shot([(20.7, 27.4, 1.0)], move(0.0, 2.4, WINDOW, COMPOSER) + [(6.7, COMPOSER)]),
    shot([(33.6, 41.4, 3.0)], [(0, LOW), (2.6, LOW)]),                       # it looks in the folder, reads the notes
    shot([(46.5, 60.5, 4.0)], [(0, STREAM), (3.5, STREAM)]),                 # the summary streams
    shot([(76.4, 81.2, 1.0)], move(0.0, 4.8, CARD, (0.55, 0.51, 1.78))),     # it asks before writing the file
    shot([(88.3, 93.4, 1.0)], [(0, DONE)] + move(2.9, 5.1, DONE, WHOLE)),    # "Done! I've saved …", out to the Mac
    # A screenshot of an email: draft the reply.
    shot([(93.5, 101.0, 1.0)], move(0.6, 3.0, WHOLE, COMPOSER) + move(5.3, 6.6, COMPOSER, LOW) + [(7.5, LOW)]),
    shot([(118.9, 125.0, 1.4)], [(0, ANSWER), (4.36, ANSWER)]),
    # A rental agreement PDF: what to watch out for.
    shot([(124.8, 129.6, 1.0)], move(0.0, 2.2, WINDOW, COMPOSER) + [(4.8, COMPOSER)]),
    shot([(133.3, 146.0, 2.6), (146.0, 148.0, 1.0)], [(0, ANSWER), (6.9, ANSWER)]),
    # The web: a beginner 5K plan.
    shot([(147.8, 152.9, 1.0)], move(0.0, 2.2, WINDOW, COMPOSER) + [(5.1, COMPOSER)]),
    shot([(157.5, 166.5, 3.0)], [(0, LOW), (3.0, LOW)]),
    # The plan streams in; that answer tips the water counter past a litre (sparkle, "Level up");
    # its popover explains the count; then slowly back out to the whole Mac.
    shot([(166.3, 200.2, 6.0), (200.2, 212.9, 1.0)],
         [(0, ANSWER), (5.65, ANSWER)] + move(5.65, 7.4, ANSWER, WINDOW) + move(9.2, 10.8, WINDOW, WATER)
         + move(13.6, 16.6, WATER, WHOLE) + [(18.3, WHOLE)]),
    {"type": "card", "dur": 6.5, "frames": "card", "fadeIn": 1.2,
     "lines": ["tarn", "an ai that lives on your mac.", "music: a lonely cherry tree by pix"]},
]

# Start every dissolve on a beat: stretch or squeeze the shot before it a touch (under 0.31 s).
t = 0.0
for i, seg in enumerate(segments):
    if i + 1 < len(segments) and segments[i + 1].get("fadeIn") and seg["type"] == "clip":
        end = t + seg["dur"]
        beat = FIRST_BEAT + round((end - FIRST_BEAT) / BEAT) * BEAT
        if abs(beat - end) < 0.31:
            scale = (beat - t) / seg["dur"]
            seg["map"] = [[round(k[0] * scale, 4), k[1]] for k in seg["map"]]
            seg["cam"] = [[round(k[0] * scale, 4), *k[1:]] for k in seg["cam"]]
            seg["dur"] = beat - t
    t += seg["dur"]

for seg in segments:
    seg["dur"] = round(seg["dur"], 4)
total = sum(s["dur"] for s in segments)
timeline = {"fps": 60, "width": 1848, "height": 1200, "fadeIn": 1.2, "fadeOut": 1.2, "segments": segments}
(HERE / "timeline.json").write_text(json.dumps(timeline, indent=1))
print(f"timeline.json: {len(segments)} segments, {total:.1f} s")
