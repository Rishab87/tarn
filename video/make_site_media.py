"""Cuts the website's looping clips from the demo recording (video/footage/main.mov + .marks).

Each clip is a list of (start, end, speed) pieces of the recording, joined and sped up, then
cropped and encoded small (H.264, no audio, fast start) with a poster frame.

    python3 video/make_site_media.py
"""

import subprocess
from pathlib import Path

HERE = Path(__file__).parent
OUT = HERE.parent / "website" / "media"
SRC = HERE / "footage" / "main.mov"
TYPE_CPS = 28


def marks() -> dict[str, float]:
    out = {}
    for line in (HERE / "footage" / "main.marks").read_text().splitlines():
        t, key = line.split()
        out[key] = float(t)
    return out


m = marks()
PROMPTS = {
    "chat": "Plan a relaxed weekend in Jaipur for two. Keep it short, with a rough budget in rupees.",
    "web": "What's the weather in Delhi this weekend? Search the web and keep it brief.",
    "image": "Split this bill between the 3 of us, in one line.",
    "memory": "I live in Pune and I'm vegetarian. Remember that.",
    "recall": "Suggest a dinner for tonight, in one line.",
    "folder": "Read trip.txt and make a packing list file for it.",
}


def typing(name: str) -> float:
    return m[f"{name}-send"] - len(PROMPTS[name]) / TYPE_CPS - 0.5


# Crops on the 2560x1600 recording (the app window at 2x).
FULL = "crop=2560:1600:0:0"
TRANSCRIPT = "crop=1844:1382:512:160"   # 4:3 around the chat column, without the sidebar

CLIPS = {
    "hero": dict(crop=FULL, size="1920:1200", crf=21, pieces=[
        (typing("chat") - 0.8, m["chat-send"] + 0.4, 1.3),
        (m["chat-send"] + 0.4, m["chat-done"], 4.0),
        (m["chat-done"], m["chat-done"] + 2.0, 1.0),
    ]),
    "split-the-bill": dict(crop=TRANSCRIPT, size="800:600", crf=24, pieces=[
        (m["image-send"] - 0.3, m["image-done"], 2.5),
        (m["image-done"], m["image-done"] + 2.0, 1.0),
    ]),
    "remembers-you": dict(crop=TRANSCRIPT, size="800:600", crf=24, pieces=[
        (m["memory-send"] - 0.3, m["memory-done"] + 1.0, 2.0),
        (m["recall-send"] - 0.3, m["recall-done"] + 2.0, 1.6),
    ]),
    "looks-things-up": dict(crop=TRANSCRIPT, size="800:600", crf=24, pieces=[
        (m["web-send"] - 0.3, m["web-done"], 3.0),
        (m["web-done"], m["web-done"] + 2.0, 1.0),
    ]),
    "packs-for-goa": dict(crop=TRANSCRIPT, size="800:600", crf=24, pieces=[
        (m["folder-send"] - 0.3, m["approval"] - 1.0, 8.0),
        (m["approval"] - 1.0, m["folder-done"] + 2.0, 2.2),
    ]),
}


def build(name: str, crop: str, size: str, crf: int, pieces: list[tuple[float, float, float]]) -> None:
    parts, labels = [], []
    for i, (a, b, speed) in enumerate(pieces):
        parts.append(f"[0:v]trim=start={a:.3f}:end={b:.3f},setpts=(PTS-STARTPTS)/{speed},fps=30,{crop},scale={size}:flags=lanczos[p{i}]")
        labels.append(f"[p{i}]")
    graph = ";".join(parts) + f";{''.join(labels)}concat=n={len(pieces)}:v=1:a=0,format=yuv420p[v]"
    mp4 = OUT / f"{name}.mp4"
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(SRC), "-filter_complex", graph, "-map", "[v]",
                    "-c:v", "libx264", "-preset", "slow", "-crf", str(crf), "-profile:v", "high",
                    "-movflags", "+faststart", "-an", str(mp4)], check=True)
    # Poster: the finished moment near the end, for slow connections and reduced motion.
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-sseof", "-0.6", "-i", str(mp4), "-frames:v", "1", "-q:v", "3", str(OUT / f"{name}.jpg")], check=True)
    secs = float(subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(mp4)],
                                capture_output=True, text=True).stdout)
    print(f"{name}: {secs:.1f} s, {mp4.stat().st_size / 1e6:.2f} MB")


OUT.mkdir(parents=True, exist_ok=True)
for name, spec in CLIPS.items():
    build(name, **spec)
