#!/bin/bash
# Stop the NR sidelink on this PC: supervisor, modem (radio stops transmitting), iperf3 server, network leftovers.
KIT="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
. "$KIT/common.sh"

if ! supervisor_running && ! modem_running; then
  echo "Sidelink is not running on this PC."
  sudo -n env SIDELINK_USER="$USER" KIT="$KIT" bash -c '. "$KIT/common.sh"; cleanup_net' 2>/dev/null
  exit 0
fi

echo "Stopping the sidelink on this PC..."
sudo true || { echo "sudo failed"; exit 1; }
sudo mkdir -p "$STATE"
sudo touch "$STOPFILE"

if supervisor_running; then
  for i in $(seq 1 30); do supervisor_running || break; sleep 1; done
  if supervisor_running; then
    echo "Supervisor did not exit in time; killing it."
    sudo kill -KILL "$(cat "$PIDFILE")" 2>/dev/null
  fi
fi

# Make sure nothing is left, even if the supervisor was gone already.
sudo env SIDELINK_USER="$USER" KIT="$KIT" bash -c '. "$KIT/common.sh"; stop_modem; cleanup_net; fix_owner; rm -f "$PIDFILE" "$STATE/active-profile"'

if modem_running; then
  echo "WARNING: nr-uesoftmodem is still running (pid $(pgrep -x nr-uesoftmodem))."
  exit 1
fi
echo "Stopped. The radio is no longer transmitting."
echo "Logs: $POC/logs (supervisor.log, $ROLE-rf-*.txt.gz); newest modem logs also in $MODEMLOGS"
