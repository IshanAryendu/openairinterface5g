#!/bin/bash
# Sidelink supervisor (runs as root, started by start.sh - do not run by hand).
#  - Restarts nr-uesoftmodem after a crash (e.g. UHD "bad vrt header" USB fault).
#  - Watchdog: restarts it when the link was up and then the peer stops answering for WATCHDOG_SECS.
#  - Peer coordination: both modems must restart together. If only one restarts, the other one's
#    PDCP keeps its old sequence numbers and discards everything from the fresh side forever.
#    So every self-initiated start sends "SIDELINK-RESTART" (UDP, office LAN) to the peer's
#    supervisor, which then restarts its own modem (without sending a notice back).
KIT="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
. "$KIT/common.sh"

echo $$ > "$PIDFILE"
mkdir -p "$MODEMLOGS"
echo "$PROFILE" > "$STATE/active-profile"
rm -f "$STOPFILE" "$REQFILE"
trap 'touch "$STOPFILE"' TERM INT

# Listen for restart requests from the peer supervisor (only from PEER_LAN_IP).
python3 - "$PEER_LAN_IP" "$CTRL_PORT" "$REQFILE" <<'PY' > /dev/null 2>&1 &
import socket, sys
peer, port, flag = sys.argv[1], int(sys.argv[2]), sys.argv[3]
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("0.0.0.0", port))
while True:
    data, addr = s.recvfrom(256)
    if addr[0] == peer and data.startswith(b"SIDELINK-RESTART"):
        with open(flag, "w") as f:
            f.write(data.decode(errors="replace"))
PY
LISTENER=$!

notify_peer() {
  for _ in 1 2 3; do
    echo "SIDELINK-RESTART $ROLE $(date +%s)" > "/dev/udp/$PEER_LAN_IP/$CTRL_PORT" 2>/dev/null
    sleep 0.2
  done
}

RUNS=0; QUICK=0; REQUESTED=0
log "supervisor started: role $ROLE, profile $PROFILE ($(freq_text)), txgain $TXGAIN, rxgain $RXGAIN, TA $TA, max MCS $MAXMCS, extra args ${EXTRA_ARGS:-none}, rate limit ${RATE_LIMIT:-off}, watchdog ${WATCHDOG_SECS}s"
tune_host

while [ ! -e "$STOPFILE" ]; do
  clean_ip_rules
  if [ $REQUESTED = 0 ]; then
    notify_peer
    log "sent restart request to peer supervisor ($PEER_LAN_IP) so both sides start fresh"
  fi
  REQUESTED=0
  rm -f "$REQFILE"
  RUNS=$((RUNS+1))
  log "starting modem (run $RUNS)"
  T0=$(date +%s)
  SL_CPUS="$MODEM_CPUS" SL_RX_TO_TX="${RX_TO_TX:-4}" SL_LOGDIR="$MODEMLOGS" SL_TXGAIN=$TXGAIN SL_RXGAIN=$RXGAIN SL_TA=$TA SL_MAXMCS=$MAXMCS SL_MCS=$MAXMCS SL_FO=1 \
    "$POC/scripts/sl-run.sh" "$ROLE" rf "$PROFILE" $EXTRA_ARGS > "$CONSOLE" 2>&1 < /dev/null &
  RUNPID=$!

  CONFIGURED=0; LINKED=0; DOWN=0; TICK=0
  while kill -0 "$RUNPID" 2>/dev/null; do
    sleep 1; TICK=$((TICK+1))
    if [ -e "$STOPFILE" ]; then log "stop requested"; stop_modem; break; fi
    if [ -e "$REQFILE" ]; then
      rm -f "$REQFILE"
      AGE=$(( $(date +%s) - T0 ))
      # A modem that has not exchanged data yet is already in a fresh state.
      if [ $LINKED = 1 ] || [ $AGE -gt 30 ]; then
        log "peer is restarting its modem; restarting ours too"
        stop_modem; REQUESTED=1; break
      fi
    fi
    [ $((TICK % 5)) = 0 ] || continue
    if [ $CONFIGURED = 0 ] && ip -4 addr show dev "$TUN" 2>/dev/null | grep -q "$MYIP"; then
      setup_tun && CONFIGURED=1
      log "link interface $TUN is up ($MYIP); waiting for peer $PEERIP"
    fi
    [ $CONFIGURED = 1 ] || continue
    if ping -n -q -c 1 -W 3 -I "$TUN" "$PEERIP" > /dev/null 2>&1; then
      [ $LINKED = 0 ] && log "LINK UP: peer $PEERIP answers over the sidelink"
      LINKED=1; DOWN=0
    else
      DOWN=$((DOWN+5))
      [ $LINKED = 1 ] && [ $DOWN = 15 ] && log "peer $PEERIP not answering (15 s)"
      if [ $LINKED = 1 ] && [ "$WATCHDOG_SECS" -gt 0 ] && [ $DOWN -ge "$WATCHDOG_SECS" ]; then
        log "WATCHDOG: no answer from peer for ${DOWN}s after the link was up; restarting both modems"
        stop_modem
        break
      fi
    fi
  done
  wait "$RUNPID" 2>/dev/null
  DUR=$(( $(date +%s) - T0 ))
  ML=$(latest_modem_log)
  WHY=$(grep -a -m1 -o -E "bad vrt header[^\"]*|Assertion.*|segfault.*|RF read returned.*" "$ML" 2>/dev/null | head -c 160)
  log "modem exited after ${DUR}s${WHY:+: $WHY}"
  archive_modem_log "$ML"
  fix_owner
  [ -e "$STOPFILE" ] && break
  [ "$AUTO_RESTART" = 1 ] || { log "AUTO_RESTART=0, not restarting"; break; }
  if [ $REQUESTED = 1 ]; then
    sleep 2
    continue
  fi
  if [ $DUR -lt 60 ]; then QUICK=$((QUICK+1)); else QUICK=0; fi
  if [ $QUICK -ge 3 ]; then
    log "modem failed $QUICK times in a row within 60 s; waiting 60 s before trying again (check the radio/USB)"
    sleep 60
  else
    sleep 5
  fi
  usb_ok || log "B210 not found on USB; will retry"
done

stop_modem
cleanup_net
kill "$LISTENER" 2>/dev/null
rm -f "$STATE/active-profile" "$REQFILE"
fix_owner
log "supervisor stopped"
rm -f "$PIDFILE"
