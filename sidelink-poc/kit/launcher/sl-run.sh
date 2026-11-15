#!/bin/bash
# NR sidelink launcher for the sl-release-1.0 PoC (runbook sections 9-11, 21.2).
#
#   sl-run.sh <role> <mode> [profile] [extra nr-uesoftmodem args...]
#     role:    a  = SyncRef UE (PC-A, RFsim server)
#              b  = nearby UE  (PC-B, RFsim client)
#     mode:    rfsim | rf
#     profile: 20mhz (default, 51 PRB at 2585.1 MHz) | n47 (51 PRB at 5910 MHz, ITS band) | cbrs (51 PRB at 3625 MHz, n48) | stock (106 PRB, RFsim only)
#
# Environment overrides:
#   SL_RFSIM_SERVER  role b + rfsim: PC-A management IP (default 127.0.0.1 = same-host smoke test only)
#   SL_SERIAL        rf mode: local B210 serial (default: the single B210 found on this PC)
#   SL_TXGAIN        rf mode: OAI TX attenuation arg, 0 = max gain (default 40, see runbook 11)
#   SL_RXGAIN        rf mode: OAI RX gain arg incl. calibration offset (default 80)
#   SL_TA            rf mode: sidelink TX timing advance in samples (PoC patch --sl-ta, default 0).
#                    OTA 2026-10-27: B needed 128 (working window ~100..160) for A to decode it.
#   SL_FO            rf mode: 1 (default) = --ue-fo-compensation, 0 = off
#   SL_MAXMCS        hard cap on PSSCH MCS (PoC patch --sl-max-mcs, default 16). OTA decode fails at MCS >= 19
#                    on this branch while still reporting success, which silently drops all IP traffic.
# OTA settings that worked 2026-10-27: both SL_TXGAIN=0 SL_RXGAIN=110; B also SL_TA=128.
#
# Logs go to ~/nr-sl-release-poc/logs/<role>-<mode>-<profile>-<timestamp>.txt
set -euo pipefail

ROOT="$HOME/nr-sl-release-poc"
BUILD="$ROOT/oai/cmake_targets/ran_build/build"
ROLE="${1:-}"; MODE="${2:-}"; PROFILE="${3:-20mhz}"
shift $(( $# < 3 ? $# : 3 )) || true

case "$ROLE" in a) CONF_ROLE=a; ROLE_ARGS=(--sync-ref) ;; b) CONF_ROLE=b; ROLE_ARGS=() ;;
  *) sed -n '2,20p' "$0"; exit 1 ;; esac
CONF="$ROOT/config/${CONF_ROLE}-${PROFILE}.conf"
[ -f "$CONF" ] || { echo "No config $CONF"; exit 1; }

COMMON=(--sa --sl-mode 2 --numerology 1 --mcs "${SL_MCS:-0}" --sl-max-mcs "${SL_MAXMCS:-16}" --thread-pool -1,-1,-1,-1
        --log_config.global_log_options level,nocolor,time)

case "$MODE" in
  rfsim)
    if [ "$ROLE" = a ]; then ADDR=server; else ADDR="${SL_RFSIM_SERVER:-127.0.0.1}"; fi
    # The sidelink simulator has its own address/port options (default 127.0.0.1:4143).
    MODE_ARGS=(--rfsim --rfsimulator.serveraddr "$ADDR" --rfsimulator.serverport 4048
               --rfsimulator.serveraddrsl "$ADDR" --rfsimulator.serverportsl 4048) ;;
  rf)
    case "$PROFILE" in 20mhz|n47|cbrs) ;; *) echo "rf mode only with the 51-PRB profiles (20mhz = 2585.1 MHz, n47 = 5910 MHz)"; exit 1 ;; esac
    if pgrep -x nr-uesoftmodem >/dev/null; then echo "nr-uesoftmodem already running; stop it first (one modem per radio)"; exit 1; fi
    SERIAL="${SL_SERIAL:-$(uhd_find_devices 2>/dev/null | awk '/serial:/{print $2; exit}')}"
    [ -n "$SERIAL" ] || { echo "No B210 found"; exit 1; }
    echo ">>> RF TRANSMIT on B210 $SERIAL. Both RF paths must have 60 dB attenuation (runbook 3A.7). Ctrl+C within 5 s to abort."
    sleep 5
    MODE_ARGS=(--ue-nb-ant-rx 1 --ue-nb-ant-tx 1
               --ue-rxgain "${SL_RXGAIN:-80}" --ue-txgain "${SL_TXGAIN:-40}"
               --rx_subdev A:A --tx_subdev A:A
               --sl-ta "${SL_TA:-0}" $([ "${SL_FO:-1}" = 1 ] && echo --ue-fo-compensation)
               --usrp-args "type=b200,serial=$SERIAL,clock_source=internal,time_source=internal") ;;
  *) sed -n '2,20p' "$0"; exit 1 ;;
esac

LOG="${SL_LOGDIR:-$ROOT/logs}/${ROLE}-${MODE}-${PROFILE}-$(date +%Y%m%d-%H%M%S).txt"
echo "Config: $CONF  ->  log: $LOG"
cd "$BUILD"
# SL_CPUS (e.g. 1-5): keep the modem off CPUs that service the B210 USB interrupts.
PIN=(); [ -n "${SL_CPUS:-}" ] && PIN=(taskset -c "$SL_CPUS")
sudo env -u RFSIMULATOR LD_LIBRARY_PATH="$PWD" SL_TX_INLINE="${SL_TX_INLINE:-1}" SL_RX_TO_TX="${SL_RX_TO_TX:-4}" "${PIN[@]}" ./nr-uesoftmodem -O "$CONF" \
  "${ROLE_ARGS[@]}" "${COMMON[@]}" "${MODE_ARGS[@]}" "$@" 2>&1 | tee "$LOG"
