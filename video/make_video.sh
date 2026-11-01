#!/bin/bash
# Builds Tarn's launch video, video/out/tarn-launch.mp4 (38 s, 1920x1080, 60 fps).
#
#   video/make_video.sh
#
# Needs the recordings in video/footage/ (video/record.sh) and the soundtrack, "Electro Dreams" by
# Arulo from mixkit.co (free licence, no credit needed). The licence doesn't allow sharing the track
# itself, so it isn't in the repo: put it at video/music/electro-dreams.mp3 or set MUSIC.
set -euo pipefail
cd "$(dirname "$0")"
MUSIC="${MUSIC:-music/electro-dreams.mp3}"
[ -f "$MUSIC" ] || { echo "Missing soundtrack: $MUSIC (see the comment at the top of this script)"; exit 1; }

python3 build_timeline.py
swiftc -O -o render render.swift
./render timeline.json out/raw.mp4

# 0:00-0:34 is the track from 60 s (the build-up, then the drop at 64 s); 0:34-0:38 is its
# ending (108-112 s). Both joins are on a bar line; a 20 ms fade hides the seam.
ffmpeg -v error -y -i out/raw.mp4 -i "$MUSIC" -filter_complex \
  "[1:a]atrim=60:94,asetpts=PTS-STARTPTS,afade=t=in:d=0.02,afade=t=out:st=33.98:d=0.02[a];
   [1:a]atrim=108:112,asetpts=PTS-STARTPTS,afade=t=in:d=0.02,afade=t=out:st=3.6:d=0.4[b];
   [a][b]concat=n=2:v=0:a=1[m]" \
  -map 0:v -map "[m]" -c:v copy -c:a aac -b:a 256k -movflags +faststart out/tarn-launch.mp4
ffprobe -v error -show_entries format=duration,size -of compact out/tarn-launch.mp4
