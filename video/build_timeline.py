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


def typing_start(send: float, prompt: str) -> float:
    return send - len(prompt) / TYPE_CPS - 0.5


m = marks("main")
o = marks("onboarding") if (HERE / "footage" / "onboarding.marks").exists() else None

PROMPTS = {
    "chat": "Plan a relaxed weekend in Jaipur for two. Keep it short, with a rough budget in rupees.",
    "web": "What's the weather in Delhi this weekend? Search the web and keep it brief.",
    "image": "Split this bill between the 3 of us, in one line.",
    "memory": "I live in Pune and I'm vegetarian. Remember that.",
    "recall": "Suggest a dinner for tonight, in one line.",
    "folder": "Read trip.txt and make a packing list file for it.",
}

# Camera framing on the 1280x800 window (x, y = centre in 0..1 from top-left, z = zoom).
FULL = (0.5, 0.5, 1.0)
COMPOSER_EMPTY = (0.555, 0.53, 1.6)   # the centred box on a new chat
ANSWER = (0.56, 0.56, 1.32)           # the reply, above the bottom composer


def cams(*keys):
    return [{"t": t, "x": c[0], "y": c[1], "z": c[2]} for t, c in keys]


def scene(name, beats, caption, typing_part=0.32, tail=0.6, cam=None, type_caption=True, cut=False, end_key=None):
    """A clip that shows the prompt being typed (slowed to fit `typing_part` of the segment),
    then the answer arriving, sped up to fill the rest."""
    send = m[f"{name}-send"]
    start = typing_start(send, PROMPTS[name])
    done = m[end_key or f"{name}-done"] + tail
    seg = {
        "type": "clip",
        "src": "footage/main.mov",
        "beats": beats,
        "caption": caption,
        "map": [[0, start], [typing_part, send + 0.25], [1, done]],
        "cam": cam or cams((0, COMPOSER_EMPTY), (typing_part, COMPOSER_EMPTY), (typing_part + 0.12, ANSWER), (1, ANSWER)),
    }
    if not type_caption:
        seg["typeCaption"] = False
    if cut:
        seg["cut"] = True
    return seg


segments = [
    {"type": "text", "beats": 8, "lines": ["ai for everyone."]},
    {"type": "text", "beats": 8, "lines": ["it lives on your mac."]},
    {"type": "logo", "beats": 2},
    scene("chat", 12, "plan a weekend."),
    scene("web", 8, "look things up."),
    scene("image", 10, "split the bill."),
    scene("memory", 8, "it remembers you."),
    scene("recall", 6, "it remembers you.", type_caption=False),
    scene("folder", 12, "works in your folders.", typing_part=0.22,
          cam=cams((0, COMPOSER_EMPTY), (0.22, COMPOSER_EMPTY), (0.34, ANSWER), (1, ANSWER))),
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
