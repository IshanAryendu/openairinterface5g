#!/bin/bash
# NR sidelink live video demo - the ONE script to run, on BOTH machines (either order).
#
#   ./run-demo.sh           start the radio link, then the video stream. Ctrl+C (or closing the video window on
#                           the receiver) stops the stream AND turns the radio off.
#   ./run-demo.sh stop      stop the stream and the radio (from another terminal or over SSH)
#   ./run-demo.sh status    show what is running and the latest statistics
#
# The side this machine plays comes from the sidelink kit (~/Desktop/sidelink/settings.conf):
#   ROLE=a (SyncRef, the Jetson) -> SENDER: streams the clip (and shows it too if LOCAL_DISPLAY=1)
#   ROLE=b (the PC)              -> RECEIVER: shows the frames as they arrive, with loss statistics
# With ADAPT=1 in demo.conf (the default) the sender adapts by itself: it raises the MCS and the video bitrate
# while the receiver reports <= 1 % of frames lost in 10 s, and steps back down when it reports more.
# Settings for the demo are in demo.conf next to this script. Everything the demo writes stays in this folder.
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
KIT="$HOME/Desktop/sidelink"; POC="$HOME/nr-sl-release-poc"
CMD="${1:-start}"

# Started by double-click (no terminal): reopen in a terminal window so the output can be seen.
if [ "$CMD" = start ] && [ ! -t 1 ] && [ -z "$DEMO_NO_TERM" ] && [ -n "$DISPLAY$WAYLAND_DISPLAY" ] && command -v gnome-terminal > /dev/null; then
  exec gnome-terminal --title "Sidelink video demo" -- bash -c "DEMO_NO_TERM=1 \"$HERE/run-demo.sh\"; echo; read -n 1 -s -r -p \"Finished. Press any key to close this window.\""
fi

say() { printf "%s\n" "$*"; }
die() { say "ERROR: $*"; exit 1; }
get() { sed -n "s/^$1=\([^ #]*\).*/\1/p" "$KIT/settings.conf" | head -1; }

[ -f "$KIT/settings.conf" ] || die "sidelink kit not found in $KIT"
[ -f "$HERE/demo.conf" ] || die "demo.conf is missing from $HERE"
. "$HERE/demo.conf"

ROLE="$(get ROLE)"
case "$ROLE" in
  a) SIDE=sender;   MYIP=10.0.0.1; PEERIP=10.0.0.2; WANT_MCS="$SENDER_MAXMCS";   WANT_OFF="$SENDER_RX_TO_TX" ;;
  b) SIDE=receiver; MYIP=10.0.0.2; PEERIP=10.0.0.1; WANT_MCS="$RECEIVER_MAXMCS"; WANT_OFF="$RECEIVER_RX_TO_TX" ;;
  *) die "ROLE in $KIT/settings.conf is \"$ROLE\" (expected a or b)" ;;
esac
case "$PROFILE" in
  cbrs)  BAND="CBRS band n48, centre 3625.02 MHz" ;;
  20mhz) BAND="band n38, centre 2585.1 MHz" ;;
  n47)   BAND="V2X band n47, centre 5910 MHz" ;;
  *)     BAND="profile $PROFILE" ;;
esac
CLIPPATH="$HERE/$CLIP"
ADAPT="${ADAPT:-0}"; LADDERPATH="$HERE/${LADDER:-clips/ladder-siren}"

modem_running() { pgrep -x nr-uesoftmodem > /dev/null; }
link_up() { ping -c 2 -i 0.3 -W 1 -I "$MYIP" "$PEERIP" > /dev/null 2>&1; }
stream_running() { pgrep -f "$HERE/sllive.py" > /dev/null; }
# Only one run-demo.sh at a time: its process id is kept in logs/.run-demo.pid while it runs.
PIDFILE="$HERE/logs/.run-demo.pid"
other_instance() {
  local p; p="$(cat "$PIDFILE" 2> /dev/null)"
  [ -n "$p" ] && [ "$p" != "$$" ] && grep -aq "run-demo.sh" "/proc/$p/cmdline" 2> /dev/null && echo "$p"
}

case "$CMD" in
  stop)
    P="$(other_instance)"
    if [ -n "$P" ]; then                      # a running run-demo.sh stops its own stream and radio when told to
      kill -TERM "$P" 2> /dev/null
      for i in $(seq 1 40); do [ -d "/proc/$P" ] || break; sleep 0.5; done
      [ -d "/proc/$P" ] && kill -KILL "$P" 2> /dev/null
      say "run-demo.sh (process $P) stopped."
    fi
    rm -f "$PIDFILE"
    pkill -f "$HERE/sllive.py" 2> /dev/null && say "Video stream stopped."
    "$KIT/stop.sh"
    exit 0 ;;
  status)
    say "This machine: $SIDE (kit role $ROLE), $BAND"
    if modem_running; then say "Radio modem : running"; else say "Radio modem : stopped (not transmitting)"; fi
    if link_up; then say "Sidelink    : peer $PEERIP answers"; else say "Sidelink    : no answer from peer $PEERIP"; fi
    if stream_running; then say "Video stream: running"; else say "Video stream: not running"; fi
    P="$(other_instance)"; [ -n "$P" ] && say "run-demo.sh : running (process $P)"
    if modem_running; then say "Modem MCS   : $(python3 "$HERE/tools/mcsctl.py" show 2> /dev/null | cut -c1-150)"; fi
    L="$(ls -t "$HERE"/logs/*.log 2> /dev/null | head -1)"
    if [ -n "$L" ]; then say "Latest log  : $L"; tail -n 3 "$L" | cut -c1-150; fi
    exit 0 ;;
  start) ;;
  *) sed -n 2,12p "$0"; exit 1 ;;
esac

# ---------------------------------------------------------------------------------------------- checks
[ -f "$POC/config/$ROLE-$PROFILE.conf" ] || die "frequency profile \"$PROFILE\" is not installed ($POC/config/$ROLE-$PROFILE.conf). See oai-patches/README.txt"
grep -q SL_RX_TO_TX "$POC/scripts/sl-run.sh" 2> /dev/null || die "the kit launcher lacks the RX->TX offset setting. See oai-patches/README.txt"
grep -aq SL_RX_TO_TX "$POC/oai/cmake_targets/ran_build/build/nr-uesoftmodem" 2> /dev/null || die "the modem build lacks the RX->TX offset patch. See oai-patches/README.txt"
if [ "$SIDE" = sender ] && [ "$ADAPT" = 1 ]; then
  [ -f "$LADDERPATH/ladder.txt" ] || die "no ladder in $LADDERPATH (make it on the PC with tools/make-ladder.sh and copy it here, or set ADAPT=0)"
  grep -aq sl-mcs-ctl "$POC/oai/cmake_targets/ran_build/build/nr-uesoftmodem" 2> /dev/null || die "the modem build lacks the run-time MCS patch (needed for ADAPT=1). See oai-patches/README.txt"
elif [ "$SIDE" = sender ]; then
  [ -f "$CLIPPATH" ] || die "clip not found: $CLIPPATH (set CLIP in demo.conf)"
fi
python3 -c "import gi; gi.require_version(\"Gst\", \"1.0\")" 2> /dev/null || die "python3-gi / GStreamer is not installed"
P="$(other_instance)"; [ -n "$P" ] && die "run-demo.sh is already running here (process $P). Use ./run-demo.sh stop first."
stream_running && die "the video stream is already running here. Use ./run-demo.sh stop first."

say "=================================================================="
say " NR sidelink live video demo - this machine is the $(echo $SIDE | tr a-z A-Z)"
say " Radio: $BAND, 20 MHz carrier, RX->TX offset $WANT_OFF slots"
if [ "$SIDE" = sender ] && [ "$ADAPT" = 1 ]; then
  say " MCS and video bitrate: AUTOMATIC (start MCS $START_MCS, range $MIN_MCS..$MAX_MCS,"
  say "   limit $TARGET_LOSS % of frames lost in $LOSS_WINDOW s). Ladder: ${LADDER:-clips/ladder-siren}"
elif [ "$SIDE" = sender ]; then
  say " MCS $WANT_MCS (fixed). Clip: $CLIP"
fi
say " Run this same script on the other machine too (either order). Ctrl+C stops."
say "=================================================================="

# The radio settings the demo was measured with. A changed kit file is first copied to backups/.
CHANGED=""; BACKED=""
setk() {
  local cur; cur="$(get "$1")"
  if grep -q "^$1=" "$KIT/settings.conf"; then [ "$cur" = "$2" ] && return; fi
  if [ -z "$BACKED" ]; then cp "$KIT/settings.conf" "$HERE/backups/settings.conf.$(date +%Y%m%d-%H%M%S)"; BACKED=1; fi
  if grep -q "^$1=" "$KIT/settings.conf"; then sed -i "s|^$1=[^ #]*|$1=$2|" "$KIT/settings.conf"; else echo "$1=$2" >> "$KIT/settings.conf"; fi
  CHANGED=1; say "  kit setting $1: \"$cur\" -> \"$2\" (previous settings.conf saved in backups/)"
}
mkdir -p "$HERE/logs" "$HERE/backups"
echo $$ > "$PIDFILE"
setk PROFILE "$PROFILE"; setk MAXMCS "$WANT_MCS"; setk RX_TO_TX "$WANT_OFF"; setk RATE_LIMIT ""

LOG=""
cleanup() {
  trap - EXIT INT TERM
  say; say "Stopping the demo on this machine..."
  pkill -P $$ 2> /dev/null                  # whatever this script is still waiting for
  pkill -f "$HERE/sllive.py" 2> /dev/null
  rm -f "$PIDFILE"
  if [ "$STOP_RADIO_ON_EXIT" = 1 ]; then "$KIT/stop.sh" 2>&1 | grep -v "^Logs:"
  else say "Radio left running (STOP_RADIO_ON_EXIT=0 in demo.conf). ./run-demo.sh stop turns it off."; fi
  [ -n "$LOG" ] && say "Stream log: $LOG"
}
trap cleanup EXIT
trap "exit 130" INT TERM

# ----------------------------------------------------------------------------------------------- radio
start_radio() {
  if [ -n "$CHANGED" ] && modem_running; then say "Settings changed: restarting the radio."; "$KIT/stop.sh" > /dev/null 2>&1; sleep 2; fi
  if modem_running && link_up; then say "Radio link is already up."; return 0; fi
  local try i
  for try in 1 2 3; do
    say "Starting the radio (attempt $try of 3). Waiting up to 3 minutes for the other machine..."
    "$KIT/start.sh" 2>&1 | sed "s/^/   /" &
    wait $!
    for i in 1 2 3 4 5 6; do link_up && return 0; sleep 2; done
    say "No link. Restarting the radio."
    "$KIT/stop.sh" > /dev/null 2>&1; sleep 3
  done
  return 1
}
start_radio || die "the sidelink did not come up. Is run-demo.sh running on the other machine? (./run-demo.sh status)"
say "Sidelink is up: peer $PEERIP answers."

# ---------------------------------------------------------------------------------------------- stream
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
if [ -z "$WAYLAND_DISPLAY$DISPLAY" ]; then            # started over SSH: use the machine's own screen
  if [ -S "$XDG_RUNTIME_DIR/wayland-0" ]; then
    export WAYLAND_DISPLAY=wayland-0
  else
    if [ -e /tmp/.X11-unix/X1 ]; then export DISPLAY=:1; else export DISPLAY=:0; fi
    if [ -z "$XAUTHORITY" ] && [ -f "$XDG_RUNTIME_DIR/gdm/Xauthority" ]; then export XAUTHORITY="$XDG_RUNTIME_DIR/gdm/Xauthority"; fi
  fi
fi
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="$HERE/logs/$SIDE-$STAMP.log"
cd "$HERE"
# The stream runs in the background and the script waits for it, so that Ctrl+C reaches this script at once.
if [ "$SIDE" = receiver ]; then
  say "Opening the video window. Frames appear as soon as the sender is streaming."
  python3 -u "$HERE/sllive.py" recv > >(tee "$LOG") 2>&1 &
else
  INFO="Radio: NR sidelink (OAI, USRP B210), $BAND, 20 MHz carrier (51 PRB, 30 kHz SCS), Jetson -> PC"
  PIN=(); [ -n "$SENDER_CPUS" ] && PIN=(taskset -c "$SENDER_CPUS")
  INH=(); command -v gnome-session-inhibit > /dev/null && INH=(gnome-session-inhibit --inhibit idle)
  if [ "$ADAPT" = 1 ]; then
    SRC=(--ladder "$LADDERPATH" --start-mcs "$START_MCS" --min-mcs "$MIN_MCS" --max-mcs "$MAX_MCS" --target "$TARGET_LOSS"
         --window "$LOSS_WINDOW" --max-hold "$MAX_RETRY_WAIT" --first-wait "${FIRST_RETRY_WAIT:-30}" --tx-limit "${TX_SLOT_LIMIT:-0}" --trace "$HERE/logs/adapt-$STAMP.csv")
    say "Streaming with automatic MCS / bitrate. Trace: logs/adapt-$STAMP.csv"
  else
    SRC=("$CLIPPATH"); INFO="$INFO, MCS $WANT_MCS (fixed)"
    say "Streaming the clip."
  fi
  LOCAL=(); if [ "${LOCAL_DISPLAY:-0}" = 1 ]; then LOCAL=(--local); say "The clip also plays on this screen (LOCAL_DISPLAY=1)."; fi
  "${PIN[@]}" "${INH[@]}" python3 -u "$HERE/sllive.py" send "${SRC[@]}" "${LOCAL[@]}" --info "$INFO" > >(tee "$LOG") 2>&1 &
fi
wait $!
