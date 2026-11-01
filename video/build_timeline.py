"""Builds video/timeline.json for render.swift: Tarn's 38-second launch video.

Cut to "Electro Dreams" by Arulo (Mixkit, free licence) at 120 BPM, so every cut lands on a beat
(a multiple of 0.5 s). The video starts 60 s into the track: the build-up carries the opening words,
the track goes silent for half a beat at 0:03, and the drop lands on the name at 0:04. The last four
seconds use the track's own ending (make_video.sh joins the two parts).

Footage is the demo recording (video/footage/main.mov, a 2560x1600 window) and the first-run
recording (onboarding.mov). Long waits are cut and streaming answers are sped up; the video says so.

    python3 video/build_timeline.py
"""

import json
from pathlib import Path

HERE = Path(__file__).parent

# Camera framings on the window: (x, y) = the point at the frame's centre, 0..1 from the top left;
# z = zoom, where 1 shows the window's full width (and 0.9/z of its height). The chat column runs
# from x 0.25 to 0.87, so z <= 1.58 keeps whole lines in frame; closer shots are deliberate close-ups.
# Answers sit at the bottom of the chat, just above the message box, so chat framings end at the box
# (y ~0.95): the caption then covers the box, never the answer.
COMPOSER = (0.55, 0.54, 1.6)        # the centred box on a new chat
COLUMN = (0.555, 0.66, 1.55)        # the chat column, down to the message box
COLUMN_HIGH = (0.555, 0.59, 1.55)   # the same, a little higher, for long finished answers
CARD = (0.555, 0.6, 1.55)           # the "Create Q4_Launch_Sync_Summary.docx?" card and its buttons
CARD_DOC = (0.42, 0.5, 2.4)         # close-up: the document inside that card
DONE = (0.5, 0.62, 1.9)             # close-up: "Done! I've saved Q4_Launch_Sync_Summary.docx"
ASK_EMAIL = (0.645, 0.62, 1.75)     # the sent message with the email screenshot
ASK_LEASE = (0.65, 0.66, 1.75)      # the sent message with the PDF
ASK = (0.553, 0.7, 1.62)            # a sent message and the steps under it ("Saved to memory", "Searched the web")
SETUP = (0.5, 0.47, 1.12)           # first run: "Setting up Tarn for your Mac"
SETUP_IN = (0.5, 0.47, 1.4)


def big(*lines, dur=1.0):
    return {"type": "big", "dur": dur, "lines": list(lines), "drift": 0.025}


def clip(dur, map_, cam, caption=None, src="footage/main.mov", note=True, drift=0.02, captionUntil=None):
    """map_: [(local s, source s), ...]; cam: [(local s, framing), ...]. Repeat a local time to cut."""
    seg = {"type": "clip", "dur": dur, "src": src, "drift": drift,
           "map": [[a, b] for a, b in map_],
           "cam": [[t, *f] for t, f in cam]}
    if caption:
        seg["caption"] = caption
    if captionUntil is not None:
        seg["captionUntil"] = captionUntil
    if note:
        seg["note"] = True
    return seg


def hold(a, b, framing):
    return [(a, framing), (b, framing)]


segments = [
    # 0:00 The build-up: what this is, in three beats.
    {**big("YOUR MAC"), "instant": True},                             # frame one is the thumbnail
    big("HAS ITS OWN"),
    big("AI NOW."),
    {"type": "black", "dur": 0.5},                                     # the track's half-beat of silence
    clip(0.25, [(0, 91.0), (0.25, 91.25)], hold(0, 0.25, CARD_DOC), note=False, drift=0),
    clip(0.25, [(0, 155.0), (0.25, 155.25)], hold(0, 0.25, COLUMN_HIGH), note=False, drift=0),
    # 0:04 The drop.
    big("TARN"),
    # 0:05 Meeting notes in a shared folder -> a formatted Word document, approved before it's written.
    clip(7.0,
         [(0, 27.75), (1.0, 28.75),                     # the last second of typing
          (1.0, 35.3), (1.5, 42.3),                     # it looks in the folder and reads the notes
          (1.5, 47.8), (3.0, 64.8),                     # the summary streams
          (3.0, 89.3), (5.0, 92.8),                     # "Create Q4_Launch_Sync_Summary.docx?" -> Allow once
          (5.0, 100.7), (6.0, 103.4), (7.0, 104.4)],    # "Done! I've saved ..."
         hold(0, 1.0, COMPOSER) + hold(1.0, 3.0, COLUMN)
         + hold(3.0, 3.9, CARD_DOC) + [(4.35, CARD), (5.0, CARD)] + hold(5.0, 7.0, DONE),
         "turns messy notes into a word doc.", captionUntil=3.0),
    # 0:12 A screenshot of an email -> the reply.
    clip(4.0,
         [(0, 110.5), (1.0, 112.5), (1.0, 126.9), (3.0, 130.4), (4.0, 131.4)],
         hold(0, 1.0, ASK_EMAIL) + hold(1.0, 4.0, COLUMN),
         "replies to an email from a screenshot."),
    # 0:16 A rental agreement PDF -> what to watch out for.
    clip(4.0,
         [(0, 136.3), (1.0, 140.8), (1.0, 141.0), (3.0, 154.1), (4.0, 155.1)],
         hold(0, 1.0, ASK_LEASE) + hold(1.0, 3.0, COLUMN) + [(3.4, COLUMN_HIGH), (4.0, COLUMN_HIGH)],
         "reads the fine print before you sign."),
    # 0:20 Memory: it saves what you tell it about yourself.
    clip(4.0,
         [(0, 9.3), (1.0, 10.3), (1.0, 16.3), (2.0, 19.7), (3.0, 20.9), (4.0, 21.9)],
         hold(0, 1.0, COMPOSER) + hold(1.0, 4.0, ASK),
         "remembers how you like things."),
    # 0:24 The web.
    clip(4.0,
         [(0, 166.7), (1.0, 171.2), (1.0, 171.3), (2.75, 191.4), (4.0, 192.65)],
         hold(0, 1.0, ASK) + hold(1.0, 4.0, COLUMN),
         "looks things up for you."),
    # 0:28 First run: it reads the Mac's chip and memory and picks the model. The screen says it all.
    clip(2.0, [(0, 14.0), (2.0, 20.0)], [(0, SETUP), (0.5, SETUP), (1.6, SETUP_IN), (2.0, SETUP_IN)],
         src="footage/onboarding.mov", note=False, drift=0),
    # 0:30 What it isn't.
    big("NO ACCOUNT."),
    big("NO SUBSCRIPTION."),
    big("WORKS OFFLINE."),
    big("ALL YOURS."),
    # 0:34 The track's last bars.
    {"type": "end", "dur": 4.0, "lines": ["free, private ai for your mac."]},
]

total = sum(s["dur"] for s in segments)
assert abs(total - 38.0) < 1e-6, total
t = 0.0
for s in segments:
    assert abs(t * 2 - round(t * 2)) < 1e-6 or s["dur"] == 0.25, f"cut off the beat at {t}"
    t += s["dur"]
timeline = {"fps": 60, "width": 1920, "height": 1080, "segments": segments}
(HERE / "timeline.json").write_text(json.dumps(timeline, indent=1))
print(f"timeline.json: {len(segments)} segments, {total:.1f} s")
