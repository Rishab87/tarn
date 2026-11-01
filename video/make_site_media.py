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
    "memory": "I'm a product manager at a fintech startup, and I like short answers in bullet points. Remember that.",
    "doc": "Turn my meeting notes into a clean summary with decisions and action items with owners, and save it as a Word doc.",
}

# Crops on the 2560x1600 recording (the app window at 2x).
FULL = "crop=2560:1600:0:0"
CHAT = "crop=1840:1150:620:380"   # 16:10 around the conversation, without the sidebar

send, card, done = m["doc-send"], m["approval"], m["doc-done"]
CLIPS = {
    "hero": dict(crop=FULL, size="1920:1200", crf=21, pieces=[
        (send - len(PROMPTS["doc"]) / TYPE_CPS - 0.8, send + 0.3, 1.4),
        (send + 0.3, card + 0.2, 8.0),
        (card + 0.2, card + 3.2, 1.0),
        (card + 3.2, done + 0.5, 5.0),
        (done + 0.5, done + 1.9, 1.0),
    ]),
    "replies-to-email": dict(crop=CHAT, size="1040:650", crf=23, pieces=[
        (m["email-send"] - 0.2, 126.5, 6.0),
        (126.5, m["email-done"], 1.4),
        (m["email-done"], m["email-done"] + 2.5, 1.0),
    ]),
    "reads-the-fine-print": dict(crop=CHAT, size="1040:650", crf=23, pieces=[
        (m["lease-send"] - 0.2, 140.7, 3.0),
        (140.7, m["lease-done"], 1.8),
        (m["lease-done"], m["lease-done"] + 2.5, 1.0),
    ]),
    "remembers-you": dict(crop=CHAT, size="1040:650", crf=23, pieces=[
        (m["memory-send"] - 0.2, m["memory-done"] + 1.0, 2.0),
        (m["post-send"] - 0.2, 207.7, 6.0),
        (207.7, m["post-done"], 1.6),
        (m["post-done"], m["post-done"] + 2.5, 1.0),
    ]),
    "looks-things-up": dict(crop=CHAT, size="1040:650", crf=23, pieces=[
        (m["web-send"] - 0.2, 173.7, 6.0),
        (173.7, m["web-done"], 2.6),
        (m["web-done"], m["web-done"] + 2.5, 1.0),
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
