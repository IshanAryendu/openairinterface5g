#!/bin/bash
# Start the NR sidelink on this PC and keep it running in the background.
#   ./start.sh            use PROFILE from settings.conf
#   ./start.sh 20mhz      this run only: 2585.1 MHz      ./start.sh n47   this run only: 5910 MHz      ./start.sh cbrs   this run only: 3625 MHz
# Start it on both PCs (either order). Closing this window does not stop the link; use ./stop.sh.
KIT="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
[ -n "$1" ] && export SL_PROFILE="$1"
. "$KIT/common.sh"

case "$PROFILE" in n47|20mhz|cbrs) ;; *) echo "Unknown profile '$PROFILE' (use n47, 20mhz or cbrs)"; exit 1 ;; esac

if supervisor_running; then
  echo "The sidelink is already running on this PC (supervisor pid $(cat "$PIDFILE"))."
  echo "Use ./status.sh to check it or ./stop.sh to shut it down."
  exit 0
fi
if modem_running; then
  echo "An nr-uesoftmodem started outside these scripts is running. Run ./stop.sh first."
  exit 1
fi

echo "=============================================================="
echo " NR sidelink start - this PC: role $ROLE, sidelink IP $MYIP"
echo " Peer: $PEERNAME, sidelink IP $PEERIP"
echo " Frequency: $(freq_text)"
echo " TX gain arg $TXGAIN, RX gain arg $RXGAIN, TA $TA, max MCS $MAXMCS, rate limit ${RATE_LIMIT:-off}"
echo "=============================================================="
if [ "$PROFILE" = n47 ]; then
  echo "!! 5.9 GHz is NOT authorized for open-air use here. Both radios must be inside the Faraday cage."
  echo "!! Press Ctrl+C within 5 s to abort."
  sleep 5
fi

echo "Checking sudo (you may be asked for your password)..."
sudo true || { echo "sudo failed"; exit 1; }
usb_ok || { echo "No USRP B210 found on USB. Plug it into a USB 3 (blue) port and try again."; exit 1; }

mkdir -p "$STATE" "$POC/logs"
[ -f "$SUPLOG" ] && [ "$(stat -c %s "$SUPLOG")" -gt 5000000 ] && mv -f "$SUPLOG" "$SUPLOG.old"
touch "$SUPLOG"

# Let sidelink traffic and the peer's restart requests through the firewall when ufw is on.
if sudo ufw status 2>/dev/null | grep -q "Status: active"; then
  UFW=$(sudo ufw status)
  echo "$UFW" | grep -q "on $TUN" || { sudo ufw allow in on "$TUN" > /dev/null && echo "Firewall: allowed traffic on $TUN"; }
  echo "$UFW" | grep -E "^$CTRL_PORT/udp .*$PEER_LAN_IP" > /dev/null || {
    sudo ufw allow proto udp from "$PEER_LAN_IP" to any port "$CTRL_PORT" > /dev/null &&
      echo "Firewall: allowed restart requests from $PEER_LAN_IP (UDP $CTRL_PORT)"; }
fi

START_LINE=$(wc -l < "$SUPLOG")
sudo env SIDELINK_USER="$USER" SL_PROFILE="$PROFILE" setsid -f bash "$KIT/supervisor.sh" > /dev/null 2>&1 < /dev/null
sleep 2
supervisor_running || { echo "The supervisor failed to start. See $SUPLOG"; exit 1; }

echo "Started in the background. The radio starts transmitting in about 10 s."
echo "Waiting for the link to the peer (start the other PC too if you have not)."
echo "Ctrl+C stops waiting only; the link keeps running."
echo
for i in $(seq 1 90); do
  sleep 2
  NEW=$(tail -n +"$((START_LINE+1))" "$SUPLOG")
  [ -n "$NEW" ] && echo "$NEW" | sed 's/^/  /'
  START_LINE=$(wc -l < "$SUPLOG")
  if echo "$NEW" | grep -q "LINK UP"; then
    echo
    echo "LINK IS UP. Try:  ping -I $TUN $PEERIP     or run ./test.sh"
    exit 0
  fi
  supervisor_running || { echo "The supervisor stopped. See $SUPLOG"; exit 1; }
done
echo
echo "No link after 3 minutes. The modem keeps running and retrying."
echo "Check that the other PC is started, then run ./status.sh."
