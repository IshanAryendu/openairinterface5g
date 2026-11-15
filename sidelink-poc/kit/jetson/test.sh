#!/bin/bash
# Test the sidelink from this PC to the peer (both PCs must be started).
#   ./test.sh         ping + UDP both directions (about 1 minute)
#   ./test.sh full    also TCP both directions (about 2 minutes)
# Results are also saved to ~/nr-sl-release-poc/logs/test-<time>.txt
KIT="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
. "$KIT/common.sh"
MODE="${1:-quick}"
UDP_RATE=80k     # stays under RATE_LIMIT (100 kbit/s incl. headers)
OUT="$POC/logs/test-$(date +%Y%m%d-%H%M%S).txt"

{
echo "== Sidelink test $(date '+%F %T'): $MYIP -> $PEERIP, $(freq_text)"
if ! ping -n -q -c 6 -i 0.5 -W 3 -I "$TUN" "$PEERIP" > /dev/null 2>&1; then
  echo "The peer does not answer. Check ./status.sh on both PCs."
  exit 1
fi
RES=()

echo; echo "-- 1. ping, 40 packets"
P=$(ping -n -c 40 -i 0.5 -W 3 -I "$TUN" "$PEERIP" | tail -2)
echo "$P"
RES+=("ping              : $(echo "$P" | grep -o '[0-9.]*% packet loss'), avg $(echo "$P" | grep -o 'rtt.*' | cut -d/ -f5) ms")

udp() {  # $1 = label, $2 = extra iperf args
  local O
  O=$(iperf3 -c "$PEERIP" -B "$MYIP" -u -b $UDP_RATE -l 200 -t 20 --connect-timeout 10000 $2 2>&1)
  echo "$O" | grep -E "receiver|sender|error" | tail -2
  RES+=("$1: $(echo "$O" | grep receiver | grep -o '[0-9.]* [KM]bits/sec.*(.*%)' | tail -1)")
  [ -n "$(echo "$O" | grep receiver)" ] || RES[-1]="$1: FAILED $(echo "$O" | grep -m1 -i error)"
}
tcp() {
  local O
  O=$(iperf3 -c "$PEERIP" -B "$MYIP" -t 20 --connect-timeout 10000 $2 2>&1)
  echo "$O" | grep -E "receiver|sender|error" | tail -2
  RES+=("$1: $(echo "$O" | grep receiver | grep -o '[0-9.]* [KM]bits/sec' | tail -1)")
  [ -n "$(echo "$O" | grep receiver)" ] || RES[-1]="$1: FAILED $(echo "$O" | grep -m1 -i error)"
}

echo; echo "-- 2. UDP $UDP_RATE, this PC -> peer, 20 s";  udp "UDP this PC -> peer" ""
echo; echo "-- 3. UDP $UDP_RATE, peer -> this PC, 20 s";  udp "UDP peer -> this PC" "-R"
if [ "$MODE" = full ]; then
  echo; echo "-- 4. TCP, this PC -> peer, 20 s";  tcp "TCP this PC -> peer" ""
  echo; echo "-- 5. TCP, peer -> this PC, 20 s";  tcp "TCP peer -> this PC" "-R"
fi

echo; echo "== Summary (UDP: rate, jitter, lost/total)"
printf '  %s\n' "${RES[@]}"
} 2>&1 | tee "$OUT"
