"""Builds video/timeline.json for render.swift from the demo recordings' scene marks.

Every segment length is a whole number of beats at 120 BPM, so cuts land on the beat of the
soundtrack (Electro Dreams by Arulo, Mixkit free license; the drop is at 16.0 s in the track and
the video starts 8 s before it).

    python3 video/build_timeline.py
"""

import json
from pathlib import Path

HERE = Path(__file__).parent
TYPE_CPS = 28  # the demo types at 28 characters a second, then pauses 0.5 s before sending


def marks(name: str) -> dict[str, float]:
    out = {}
    for line in (HERE / "footage" / f"{name}.marks").read_text().splitlines():
        t, key = line.split()
        out[key] = float(t)
    return out


m = marks("main")
o = marks("onboarding") if (HERE / "footage" / "onboarding.marks").exists() else None

PROMPTS = {
    "memory": "I'm a product manager at a fintech startup, and I like short answers in bullet points. Remember that.",
    "doc": "Turn my meeting notes into a clean summary with decisions and action items with owners, and save it as a Word doc.",
    "email": "Draft a reply: I'll send them by Thursday 5 pm, and Pune dipped because the store was being renovated in August.",
    "lease": "I'm about to sign this rental agreement. What should I watch out for? Keep it short.",
    "web": "Find a good beginner 5K plan online and turn it into a simple 3-days-a-week schedule. Keep it short.",
    "post": "Write a short LinkedIn post announcing our UPI autopay launch.",
}

# Camera framing on the 1280x800 window (x, y = centre in 0..1 from top-left, z = zoom).
COMPOSER_EMPTY = (0.555, 0.53, 1.6)   # the centred box on a new chat
ANSWER = (0.56, 0.58, 1.3)            # the reply, above the bottom composer
CARD = (0.6, 0.6, 1.42)               # the "Create … ?" approval card


def cams(*keys):
    return [{"t": t, "x": c[0], "y": c[1], "z": c[2]} for t, c in keys]


def scene(name, beats, caption, typing_part=0.4, show_typing=2.6, tail=1.2, type_caption=True):
    """The last `show_typing` seconds of the prompt being typed, then the answer arriving,
    sped up to fill the rest of the segment."""
    send = m[f"{name}-send"]
    typed = len(PROMPTS[name]) / TYPE_CPS + 0.5
    start = send - min(typed, show_typing)
    done = m[f"{name}-done"] + tail
    seg = {
        "type": "clip", "src": "footage/main.mov", "beats": beats, "caption": caption,
        "map": [[0, start], [typing_part, send + 0.3], [1, done]],
        "cam": cams((0, COMPOSER_EMPTY), (typing_part, COMPOSER_EMPTY), (typing_part + 0.1, ANSWER), (1, ANSWER)),
    }
    if not type_caption:
        seg["typeCaption"] = False
    return seg


send, card, done = m["doc-send"], m["approval"], m["doc-done"]
doc = {
    "type": "clip", "src": "footage/main.mov", "beats": 14, "caption": "turns messy notes into a clean doc.",
    "map": [[0, send - 3.2], [0.3, send + 0.3], [0.42, card + 0.3], [0.74, card + 3.1], [1, done + 1.5]],
    "cam": cams((0, COMPOSER_EMPTY), (0.3, COMPOSER_EMPTY), (0.4, CARD), (0.74, CARD), (0.84, ANSWER), (1, ANSWER)),
}

segments = [
    {"type": "text", "beats": 8, "lines": ["ai for everyone."]},
    {"type": "text", "beats": 8, "lines": ["it lives on your mac."]},
    {"type": "logo", "beats": 2},
    doc,
    scene("email", 10, "replies to your email."),
    scene("lease", 10, "reads the fine print."),
    scene("memory", 6, "remembers how you work.", typing_part=0.5),
    scene("post", 8, "remembers how you work.", type_caption=False),
    scene("web", 8, "looks things up."),
]

if o:
    segments.append({
        "type": "clip", "src": "footage/onboarding.mov", "beats": 6, "caption": "picks the right ai for your mac.",
        "map": [[0, o["setup"] + 0.3], [1, o["setup"] + 7.0]],
        "cam": cams((0, (0.5, 0.5, 1.0)), (1, (0.5, 0.55, 1.18))),
    })
else:
    segments[-1]["beats"] += 6

segments += [
    {"type": "slams", "beats": 6, "words": ["no account.", "no subscription.", "nothing leaves your mac."]},
    {"type": "end", "beats": 10, "lines": ["free, private ai for your mac."]},
]

total = sum(s["beats"] for s in segments)
assert total == 96, total
timeline = {"fps": 60, "width": 1920, "height": 1080, "bpm": 120, "segments": segments}
(HERE / "timeline.json").write_text(json.dumps(timeline, indent=2))
print(f"timeline.json: {len(segments)} segments, {total} beats = {total / 2:.0f} s")
