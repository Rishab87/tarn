#!/bin/bash
# Builds Tarn's demo video, video/out/tarn-demo.mp4 (about 1.5 minutes, 1848x1200, 60 fps).
#
#   video/make_video.sh
#
# Needs the recording in video/footage/ (video/record.sh main …) and the music, "A Lonely Cherry
# Tree" by Pix (free to use; the channel asks for a share). The track isn't in the repo: put it at
# video/music/lonely-cherry-tree.m4a or set MUSIC.
set -euo pipefail
cd "$(dirname "$0")"
MUSIC="${MUSIC:-music/lonely-cherry-tree.m4a}"
[ -f "$MUSIC" ] || { echo "Missing music: $MUSIC (see the comment at the top of this script)"; exit 1; }

python3 build_timeline.py
node make_card.mjs
swiftc -O -o render render.swift
./render timeline.json out/raw.mp4

# The music plays from its start under the whole video, fading in and out with the picture.
DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 out/raw.mp4)
OUTRO=$(python3 -c "print(max(0, $DUR - 3.5))")
ffmpeg -v error -y -i out/raw.mp4 -i "$MUSIC" -filter_complex \
  "[1:a]atrim=0:$DUR,asetpts=PTS-STARTPTS,afade=t=in:d=1.2,afade=t=out:st=$OUTRO:d=3.5[m]" \
  -map 0:v -map "[m]" -c:v copy -c:a aac -b:a 256k -movflags +faststart out/tarn-demo.mp4
ffprobe -v error -show_entries format=duration,size -of compact out/tarn-demo.mp4
