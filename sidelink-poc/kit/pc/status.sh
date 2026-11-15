#!/bin/bash
# Show the state of the sidelink on this PC.
KIT="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
. "$KIT/common.sh"

echo "== Sidelink status - role $ROLE ($MYIP), peer $PEERNAME ($PEERIP)"
if supervisor_running; then
  echo "Supervisor : running (pid $(cat "$PIDFILE"))"
  CUR=$(grep -a "supervisor started" "$SUPLOG" | tail -1)
  echo "             $(echo "$CUR" | sed 's/ supervisor started: /  /')"
  SINCE=$(echo "$CUR" | cut -c1-19)
  RUNS=$(awk -v s="$SINCE" 'substr($0,1,19) >= s && /starting modem/' "$SUPLOG" | wc -l)
  echo "Restarts   : $((RUNS > 0 ? RUNS - 1 : 0)) since $SINCE"
else
  echo "Supervisor : NOT running (start with ./start.sh)"
fi
if modem_running; then
  echo "Modem      : running for $(ps -o etime= -p "$(pgrep -x nr-uesoftmodem | head -1)" | tr -d ' ')"
else
  echo "Modem      : not running"
fi
if ip -4 addr show dev "$TUN" 2>/dev/null | grep -q "$MYIP"; then
  echo "Interface  : $TUN up, $MYIP"
  if ping -n -q -c 3 -i 0.5 -W 2 -I "$TUN" "$PEERIP" > /tmp/sl-ping.$$ 2>&1; then
    echo "Peer ping  : OK  $(grep -o 'rtt.*' /tmp/sl-ping.$$ | cut -d/ -f5 | sed 's/$/ ms avg/')"
  else
    echo "Peer ping  : NO ANSWER ($(grep -o '[0-9]* received' /tmp/sl-ping.$$) of 3)"
  fi
  rm -f /tmp/sl-ping.$$
else
  echo "Interface  : $TUN not up yet"
fi

ML=$(latest_modem_log)
if [ -n "$ML" ] && modem_running; then
  echo "Radio      : log $ML"
  for k in PSBCH "PSSCH Stats" PSFCH; do
    L=$(grep -a "$k" "$ML" | tail -1 | grep -o "$k.*")
    [ -n "$L" ] && echo "             $L"
  done
  echo "             rate-match errors: $(grep -a -c "Problem in rate_matching" "$ML"), short USB reads: $(grep -a -c "short RF read" "$ML")"
fi
echo
echo "Last supervisor events ($SUPLOG):"
tail -n 8 "$SUPLOG" 2>/dev/null | sed 's/^/  /'
