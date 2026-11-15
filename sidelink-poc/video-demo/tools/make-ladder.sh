#!/bin/bash
# Make the "ladder" for the adaptive demo: the same clip encoded once per MCS, each at the bitrate that MCS
# can carry (run on the PC: it has ffmpeg).
#   tools/make-ladder.sh INPUT_VIDEO NAME [HEIGHT] ["MCS:KBIT MCS:KBIT ..."]
#   e.g. tools/make-ladder.sh clips/source/siren_720p.mp4 siren
# Output: clips/ladder-NAME/mcsNN.mp4 and clips/ladder-NAME/ladder.txt (what sllive.py --ladder reads).
# Then copy the folder to the Jetson (the sender is the side that needs it) and select it there with
# LADDER=clips/ladder-NAME in demo.conf:
#   scp -r clips/ladder-NAME labuser@192.0.2.72:Desktop/sidelink-video-demo/clips/
#
# The default table follows what the link carried on 14 Nov 2026 after the HARQ feedback fix (one-way UDP,
# Jetson -> PC, CBRS): MCS 9 carried 1200 kbit/s without loss and collapsed at 1400; the limit is about 230
# transport blocks per second on the Jetson, so a lower MCS (smaller blocks) carries proportionally less
# (MCS 5 failed at 650 kbit/s, MCS 0 at 200). The table uses roughly 60-70 % of that, the lowest level less.
# MCS 10 and 17 are left out (same block size as MCS 9 and 16). MCS 11-16 are 16QAM, 18-22 are 64QAM.
# All levels: 25 fps, no audio, no B-frames, a keyframe every 12 frames at the same positions (the sender
# switches level only at a keyframe), two-pass so the average bitrate is what the table says.
HERE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
IN="$1"; NAME="$2"; H="${3:-480}"
TABLE="${4:-0:80 1:120 2:160 3:220 4:290 5:370 6:450 7:540 8:630 9:740 11:830 12:900 13:950 14:1000 15:1050 16:1100 18:1150 19:1200 20:1250 21:1300 22:1350}"
if [ ! -f "$IN" ] || [ -z "$NAME" ]; then sed -n 2,10p "$0"; exit 1; fi
command -v ffmpeg > /dev/null || { echo "ffmpeg is not installed on this machine"; exit 1; }
OUT="$HERE/clips/ladder-$NAME"; mkdir -p "$OUT"; rm -f "$OUT"/mcs*.mp4 "$OUT/ladder.txt"
TMP="$(mktemp -d "$OUT/.pass.XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
{ echo "# MCS  file        (made by tools/make-ladder.sh from $(basename "$IN"), ${H}p, $(date +%F))"; } > "$OUT/ladder.txt"
for item in $TABLE; do
  M="${item%%:*}"; R="${item##*:}"; F="$(printf "mcs%02d.mp4" "$M")"
  ENC=(-an -vf "scale=-2:$H,fps=25" -c:v libx264 -preset slow -profile:v high -level 3.1 -pix_fmt yuv420p
       -g 12 -keyint_min 12 -sc_threshold 0 -bf 0 -b:v "${R}k" -maxrate "$((R * 12 / 10))k" -bufsize "$((R * 6 / 10))k"
       -passlogfile "$TMP/p$M")
  ffmpeg -hide_banner -loglevel error -y -i "$IN" "${ENC[@]}" -pass 1 -f null /dev/null \
    && ffmpeg -hide_banner -loglevel error -y -i "$IN" "${ENC[@]}" -pass 2 "$OUT/$F" || { echo "encoding failed for MCS $M"; exit 1; }
  KB="$(ffprobe -v error -select_streams v:0 -show_entries stream=bit_rate -of csv=p=0 "$OUT/$F")"
  printf "%-5s %-11s # %s kbit/s video (target %s)\n" "$M" "$F" "$((KB / 1000))" "$R" >> "$OUT/ladder.txt"
  echo "MCS $M: $F, $((KB / 1000)) kbit/s"
done
echo "Wrote $OUT/ladder.txt. Now copy clips/ladder-$NAME to the Jetson (see the top of this script)."
