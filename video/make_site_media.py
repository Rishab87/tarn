"""Cuts the website's looping clips from the demo recording (video/footage/main.mov + .marks).

The recording is the whole screen; the clips crop the Tarn window out of it (the window's RECT is
in the marks file). Each clip is a list of (start, end, speed) pieces of the recording, joined and
sped up, then encoded small (H.264, no audio, fast start) with a poster frame.

    python3 video/make_site_media.py
"""

import subprocess
from pathlib import Path

HERE = Path(__file__).parent
OUT = HERE.parent / "website" / "media"
SRC = HERE / "footage" / "main.mov"


def read_marks() -> tuple[dict[str, float], tuple[int, int, int, int]]:
    marks, rect = {}, None
    for line in (HERE / "footage" / "main.marks").read_text().splitlines():
        a, b = line.split()
        if a == "RECT":
            rect = tuple(int(v) for v in b.split(","))
        else:
            marks[b] = float(a)
    return marks, rect


m, (rx, ry, rw, rh) = read_marks()
# When each answer's text starts streaming, after the wait (seconds into the recording), read off
# the footage. Holds after an answer end before the demo opens its next chat (about 1.5 s later).
TEXT = {"memory": 13.6, "doc": 46.6, "email": 119.0, "lease": 133.3, "web": 166.0}

# The screen is recorded at 2x. The window, whole (16:10), and the conversation without the
# sidebar, also 16:10.
WINDOW = f"crop={rw * 2}:{rh * 2}:{rx * 2}:{ry * 2}"
SIDEBAR = 146
chat_w = (rw - SIDEBAR) * 2
chat_h = round(chat_w * 10 / 16 / 2) * 2
CHAT = f"crop={chat_w}:{chat_h}:{(rx + SIDEBAR) * 2}:{(ry + rh) * 2 - chat_h}"

send, card, done = m["doc-send"], m["approval"], m["doc-done"]
CLIPS = {
    "hero": dict(crop=WINDOW, size="1920:1200", crf=21, pieces=[
        (send - 4.6, send + 0.3, 1.4),
        (TEXT["doc"], card + 0.2, 6.0),
        (card + 0.2, card + 3.4, 1.0),
        (card + 3.4, done + 0.5, 4.0),
        (done + 0.5, done + 1.5, 1.0),
    ]),
    "replies-to-email": dict(crop=CHAT, size="1040:650", crf=23, pieces=[
        (m["email-send"] - 0.2, m["email-send"] + 1.5, 1.0),
        (TEXT["email"] - 0.3, m["email-done"], 1.4),
        (m["email-done"], m["email-done"] + 1.4, 1.0),
    ]),
    "reads-the-fine-print": dict(crop=CHAT, size="1040:650", crf=23, pieces=[
        (m["lease-send"] - 0.2, m["lease-send"] + 1.5, 1.0),
        (TEXT["lease"] - 0.3, m["lease-done"], 1.8),
        (m["lease-done"], m["lease-done"] + 1.6, 1.0),
    ]),
    "remembers-you": dict(crop=CHAT, size="1040:650", crf=23, pieces=[
        (m["memory-send"] - 0.2, TEXT["memory"] - 0.3, 3.0),
        (TEXT["memory"] - 0.3, TEXT["memory"] + 3.9, 2.0),
        (TEXT["memory"] + 3.9, m["memory-done"], 1.0),
        (m["memory-done"], m["memory-done"] + 1.5, 1.0),
    ]),
    "looks-things-up": dict(crop=CHAT, size="1040:650", crf=23, pieces=[
        (m["web-send"] - 0.2, TEXT["web"] - 0.3, 8.0),
        (TEXT["web"] - 0.3, m["web-done"], 4.0),
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


if __name__ == "__main__":
    assert all(TEXT.values()), "measure TEXT from the footage first"
    OUT.mkdir(parents=True, exist_ok=True)
    for name, spec in CLIPS.items():
        build(name, **spec)
