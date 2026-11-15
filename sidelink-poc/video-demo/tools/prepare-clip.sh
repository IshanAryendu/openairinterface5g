#!/bin/bash
# Make a clip that suits live streaming over the sidelink (run on the PC: it has ffmpeg).
#   tools/prepare-clip.sh INPUT_VIDEO [NAME] [KBIT_PER_S] [HEIGHT]
#   e.g. tools/prepare-clip.sh ~/Videos/talk.mp4 talk 180 480   ->  clips/talk.mp4
# Output: 25 fps, no audio, no B-frames, a keyframe every 12 frames (a lost frame then damages at most
# 0.5 s), rate-capped so keyframes stay small. Keep the bitrate under about 300 kbit/s: the link carried
# about 380 kbit/s without loss in testing. Then copy the clip into clips/ on the Jetson as well, e.g.
#   scp clips/talk.mp4 labuser@192.0.2.72:Desktop/sidelink-video-demo/clips/
# and set CLIP=clips/talk.mp4 in demo.conf on the Jetson.
HERE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
IN="$1"; NAME="${2:-$(basename "${1%.*}")_stream}"; R="${3:-180}"; H="${4:-480}"
if [ ! -f "$IN" ]; then sed -n 2,9p "$0"; exit 1; fi
command -v ffmpeg > /dev/null || { echo "ffmpeg is not installed on this machine"; exit 1; }
OUT="$HERE/clips/$NAME.mp4"
ffmpeg -hide_banner -loglevel error -y -i "$IN" -an -vf "scale=-2:$H,fps=25" -c:v libx264 -preset slow -profile:v high \
  -pix_fmt yuv420p -g 12 -keyint_min 12 -sc_threshold 0 -bf 0 -b:v "${R}k" -maxrate "$((R * 12 / 10))k" -bufsize "$((R * 6 / 10))k" "$OUT" \
  && echo "Wrote $OUT ($(stat -c %s "$OUT") bytes)"
