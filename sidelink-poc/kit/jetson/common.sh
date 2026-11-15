# Shared settings and helpers for the sidelink scripts (sourced, not run).
KIT="${KIT:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)}"
. "$KIT/settings.conf"

OWNER="${SIDELINK_USER:-${SUDO_USER:-$USER}}"
OWNER_HOME="$(getent passwd "$OWNER" | cut -d: -f6)"
POC="$OWNER_HOME/nr-sl-release-poc"
STATE="$POC/run"
PIDFILE="$STATE/supervisor.pid"
STOPFILE="$STATE/stop"
REQFILE="$STATE/peer-restart"
SUPLOG="$POC/logs/supervisor.log"
# Per-run modem logs are written to RAM while the modem runs: the modem (and UHD's L/U/O prints from its
# radio threads) block on stdout, and slow disk (SD card on the Jetson) writes stalled it into RX overflows.
# Finished logs are archived gzipped to $POC/logs by the supervisor.
MODEMLOGS=/dev/shm/sl-logs
CONSOLE="$MODEMLOGS/console-$ROLE.txt"
CTRL_PORT=4049              # UDP port the supervisors use to ask each other to restart
export HOME="$OWNER_HOME"   # sl-run.sh finds ~/nr-sl-release-poc through HOME

# Frequency profile: start.sh argument > profile of the running supervisor > settings.conf
if [ -n "$SL_PROFILE" ]; then PROFILE="$SL_PROFILE"
elif [ -f "$STATE/active-profile" ]; then PROFILE="$(cat "$STATE/active-profile")"; fi

if [ "$ROLE" = a ]; then TUN=oaitun_ue1; MYIP=10.0.0.1; PEERIP=10.0.0.2; PEERNAME="Jetson ($PEER_LAN_IP)"
else                     TUN=oaitun_ue2; MYIP=10.0.0.2; PEERIP=10.0.0.1; PEERNAME="PC-A ($PEER_LAN_IP)"; fi

log() { echo "$(date '+%F %T') $*" >> "$SUPLOG"; }

freq_text() {
  case "$PROFILE" in
    n47)   echo "5910 MHz, band n47 - FARADAY CAGE ONLY" ;;
    20mhz) echo "2585.1 MHz, band n7/n38" ;;
    cbrs)  echo "3625.0 MHz, CBRS band n48 - FARADAY CAGE ONLY" ;;
    *)     echo "unknown profile '$PROFILE'" ;;
  esac
}

supervisor_running() { [ -f "$PIDFILE" ] && [ -d "/proc/$(cat "$PIDFILE")" ] && grep -q supervisor.sh "/proc/$(cat "$PIDFILE")/cmdline" 2>/dev/null; }
modem_running() { pgrep -x nr-uesoftmodem > /dev/null; }
usb_ok() { lsusb -d 2500:0020 > /dev/null 2>&1; }
latest_modem_log() { ls -t "$MODEMLOGS"/"$ROLE"-rf-"$PROFILE"-*.txt 2>/dev/null | head -1; }
# Copy a finished modem log to disk (gzipped) and keep only the 2 newest in RAM.
archive_modem_log() {
  [ -f "$1" ] && gzip -c "$1" > "$POC/logs/$(basename "$1").gz"
  ls -t "$MODEMLOGS"/"$ROLE"-rf-*.txt 2>/dev/null | tail -n +3 | xargs -r rm -f
}

# OAI adds two ip rules for the tunnel address on every start and never removes them.
clean_ip_rules() {
  local n ip
  for ip in 10.0.0.1 10.0.0.2; do   # both addresses: earlier same-PC tests left rules for the other role
    n=0; while [ $n -lt 200 ] && ip rule del from "$ip" 2>/dev/null; do n=$((n+1)); done
    n=0; while [ $n -lt 200 ] && ip rule del to "$ip" 2>/dev/null; do n=$((n+1)); done
  done
}

# Runs once the tunnel interface has its address.
setup_tun() {
  if [ -n "$RATE_LIMIT" ]; then
    # Cap what we send into the sidelink. Above ~300 kbit/s this OAI branch corrupts packets and
    # the receiver's PDCP stops delivering anything until the modem restarts.
    tc qdisc replace dev "$TUN" root tbf rate "$RATE_LIMIT" burst 6000 latency 500ms 2>/dev/null \
      || log "could not set rate limit on $TUN"
  fi
  pkill -f "iperf3 -s -B $MYIP" 2>/dev/null
  runuser -u "$OWNER" -- iperf3 -s -B "$MYIP" -D > /dev/null 2>&1 || log "could not start iperf3 server"
  return 0
}

stop_modem() {
  modem_running || return 0
  pkill -INT -x nr-uesoftmodem
  for _ in $(seq 1 15); do modem_running || return 0; sleep 1; done
  log "modem did not stop on SIGINT; killing it"
  pkill -KILL -x nr-uesoftmodem
  sleep 1
}

cleanup_net() {
  pkill -f "iperf3 -s -B $MYIP" 2>/dev/null
  pkill -f "python3 - $PEER_LAN_IP $CTRL_PORT" 2>/dev/null   # restart-request listener
  tc qdisc del dev "$TUN" root 2>/dev/null
  clean_ip_rules
}

fix_owner() { chown -R "$OWNER:$OWNER" "$POC/logs" "$STATE" "$MODEMLOGS" 2>/dev/null; }

# Keep CPU frequency high and deep idle states off while the modem runs (fewer USB/timing stalls).
tune_host() {
  command -v powerprofilesctl > /dev/null && powerprofilesctl set performance 2>/dev/null
  command -v cpupower > /dev/null && cpupower idle-set -D 2 > /dev/null 2>&1
  command -v jetson_clocks > /dev/null && jetson_clocks > /dev/null 2>&1   # Jetson: max CPU/EMC clocks
  return 0
}
