"""Original French-house-style track for Tarn's launch video (synthesized, no samples).

122 BPM, F minor-ish disco loop: four-on-the-floor kick, offbeat hats, claps, a funky
octave bassline, filtered chord stabs with sidechain pumping, and a filter sweep that opens
into the drop. Writes video/music.wav and video/beats.json (beat times for editing).

Run: uv run --with numpy --with scipy video/music.py
"""
import json
import numpy as np
from scipy.signal import butter, lfilter, sosfilt
from scipy.io import wavfile

SR = 44100
BPM = 122
BEAT = 60 / BPM
BAR = 4 * BEAT
BARS = 20                      # ~39 s
N = int(BARS * BAR * SR) + SR  # 1 s tail
rng = np.random.default_rng(7)

def t_of(n):
    return np.arange(n) / SR

def env_exp(n, decay):
    return np.exp(-t_of(n) / decay)

def place(buf, sig, start_s, gain=1.0):
    i = int(start_s * SR)
    j = min(len(buf), i + len(sig))
    if i < len(buf):
        buf[i:j] += sig[: j - i] * gain

def kick():
    n = int(0.45 * SR)
    t = t_of(n)
    f = 48 + 110 * np.exp(-t / 0.045)
    ph = 2 * np.pi * np.cumsum(f) / SR
    s = np.sin(ph) * env_exp(n, 0.16)
    click = rng.standard_normal(n) * env_exp(n, 0.002) * 0.3
    return np.tanh(1.6 * (s + click))

def clap():
    n = int(0.3 * SR)
    noise = rng.standard_normal(n)
    sos = butter(2, [900, 3200], btype="band", fs=SR, output="sos")
    s = sosfilt(sos, noise)
    e = np.zeros(n)
    for off in (0, 0.011, 0.022):  # the classic triple-hit clap
        k = int(off * SR)
        e[k:] += env_exp(n - k, 0.03 if off < 0.02 else 0.12)
    return s * e * 0.9

def hat(open_=False):
    n = int((0.22 if open_ else 0.06) * SR)
    s = rng.standard_normal(n)
    sos = butter(4, 7000, btype="high", fs=SR, output="sos")
    return sosfilt(sos, s) * env_exp(n, 0.07 if open_ else 0.015)

def saw(freq, n, detune=0.0):
    t = t_of(n)
    out = np.zeros(n)
    for d in (-detune, 0.0, detune):
        f = freq * (1 + d)
        out += 2 * ((t * f) % 1.0) - 1
    return out / 3

def note(m):  # MIDI note -> Hz
    return 440.0 * 2 ** ((m - 69) / 12)

# Chords (two bars each loop of 4): Fm9, Db maj7, Eb6, C7sus -> resolve
CHORDS = [[53, 56, 60, 63, 67], [49, 53, 56, 60, 65], [51, 55, 58, 60, 63], [48, 53, 55, 58, 64]]
BASS = [41, 37, 39, 36]  # F, Db, Eb, C (low)

drums = np.zeros(N)
bass = np.zeros(N)
chords = np.zeros(N)
sidechain = np.ones(N)
K = kick()
for bar in range(BARS):
    for b in range(4):
        start = bar * BAR + b * BEAT
        intro = bar < 4
        if not (intro and bar < 2):
            place(drums, K, start, 0.95)
            # sidechain: duck chords/bass after each kick
            i = int(start * SR)
            n = int(0.32 * SR)
            duck = 1 - 0.75 * np.exp(-t_of(n) / 0.09)
            j = min(N, i + n)
            sidechain[i:j] = np.minimum(sidechain[i:j], duck[: j - i])
        if b in (1, 3) and bar >= 4:
            place(drums, clap(), start, 0.55)
        place(drums, hat(open_=True), start + BEAT / 2, 0.22 if not intro else 0.12)
        if bar >= 8:
            place(drums, hat(), start + BEAT / 4, 0.12)
            place(drums, hat(), start + 3 * BEAT / 4, 0.12)

# Bass: funky octave pattern on 16ths, from bar 4
pattern = [1, 0, 0, 1, 0, 0, 1, 0, 1, 0, 0, 1, 0, 1, 0, 0]
octave = [0, 0, 0, 12, 0, 0, 0, 0, 12, 0, 0, 0, 0, 12, 0, 0]
for bar in range(4, BARS):
    root = BASS[(bar // 2) % 4]
    for s16 in range(16):
        if pattern[s16]:
            n = int(BEAT / 4 * 0.9 * SR)
            f = note(root + octave[s16])
            sig = saw(f, n, 0.004) * env_exp(n, 0.09)
            place(bass, sig, bar * BAR + s16 * BEAT / 4, 0.5)
sos_b = butter(2, 520, btype="low", fs=SR, output="sos")
bass = np.tanh(1.4 * sosfilt(sos_b, bass))

# Chord stabs on the "and" of each beat with a slowly opening low-pass filter
for bar in range(BARS):
    ch = CHORDS[(bar // 2) % 4]
    for b in range(4):
        n = int(BEAT * 0.45 * SR)
        stab = sum(saw(note(m), n, 0.006) for m in ch) / len(ch)
        stab *= env_exp(n, 0.16)
        place(chords, stab, bar * BAR + b * BEAT + BEAT / 2, 0.8)

# Filter sweep: closed during the intro, opens fully at the drop (bar 4), dips in the
# breakdown (bars 12-13) and opens again for the finale.
cut = np.empty(N)
t = t_of(N)
bars_t = t / BAR
cut = np.where(bars_t < 4, 300 + (3600 - 300) * (bars_t / 4) ** 2, 5200)
cut = np.where((bars_t >= 12) & (bars_t < 14), 900 + 4300 * ((bars_t - 12) / 2) ** 2, cut)
filtered = np.zeros(N)
block = 1024
zi = None
for i in range(0, N, block):
    b_, a_ = butter(2, min(cut[i], SR / 2 - 100), btype="low", fs=SR)
    seg = chords[i:i + block]
    if zi is None:
        zi = np.zeros(max(len(a_), len(b_)) - 1)
    out, zi = lfilter(b_, a_, seg, zi=zi)
    filtered[i:i + block] = out
chords = filtered

# Riser into the drop (bar 3-4) and final crash
riser_n = int(BAR * SR)
riser = rng.standard_normal(riser_n) * np.linspace(0, 1, riser_n) ** 2
sos_r = butter(2, 2500, btype="high", fs=SR, output="sos")
place(drums, sosfilt(sos_r, riser), 3 * BAR, 0.18)

mix = drums * 0.9 + bass * 0.55 * sidechain + chords * 0.45 * sidechain
# Fade out over the last bar
fade_start = int((BARS - 1) * BAR * SR)
mix[fade_start:] *= np.linspace(1, 0, N - fade_start)
mix = np.tanh(1.3 * mix)
mix /= np.max(np.abs(mix)) * 1.05
stereo = np.stack([mix, np.roll(mix, 12)], axis=1)  # tiny Haas widening
wavfile.write("video/music.wav", SR, (stereo * 32767).astype(np.int16))
beats = [round(i * BEAT, 4) for i in range(BARS * 4 + 1)]
json.dump({"bpm": BPM, "beat": BEAT, "bar": BAR, "drop_bar": 4, "breakdown_bars": [12, 14], "beats": beats},
          open("video/beats.json", "w"), indent=1)
print(f"music.wav: {len(mix) / SR:.1f}s at {BPM} BPM")
