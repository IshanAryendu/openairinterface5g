#!/bin/bash
# Idempotent PoC instrumentation: once per second log the TX send() behaviour in usrp_lib.cpp.
#   lead_start/lead_end = estimated time between "now" and the burst's TX timestamp when send() starts/returns
#   (device time estimated from the end of the latest RX block + host time elapsed since that read returned;
#   RX USB latency makes this an over-estimate). Negative lead => the burst is late (UHD "L").
set -e
cd ~/nr-sl-release-poc/oai
U=radio/USRP/usrp_lib.cpp
python3 - "$U" <<'PY'
import sys
u = sys.argv[1]
s = open(u).read()
if "poc_tx_stats" in s:
    print("already patched"); sys.exit(0)
helper = r'''
// Local PoC instrumentation (tx-timing-patch.sh)
#include <time.h>
static inline long long poc_us(void) { struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts); return ts.tv_sec * 1000000LL + ts.tv_nsec / 1000; }
static long long poc_rx_end_ts = 0, poc_rx_host_us = 0;   // end timestamp of the last RX block, host time it returned
static void poc_tx_stats(long long send_us, long long lead_start, long long lead_end)
{
  static long long n, ssum, smax, lsmin = 1LL << 40, lemin = 1LL << 40, late_s, late_e, short_e, last;
  n++; ssum += send_us; if (send_us > smax) smax = send_us;
  if (lead_start < lsmin) lsmin = lead_start;
  if (lead_end < lemin) lemin = lead_end;
  if (lead_start < 0) late_s++;
  if (lead_end < 0) late_e++;
  if (lead_end < 300) short_e++;
  long long now = poc_us();
  if (now - last >= 1000000) {
    if (last)
      LOG_I(HW, "PoC TX timing: %lld sends, send avg %lld max %lld us, lead at start min %lld us (late %lld), lead at end min %lld us (late %lld, <300us %lld)\n",
            n, ssum / n, smax, lsmin, late_s, lemin, late_e, short_e);
    n = ssum = smax = late_s = late_e = short_e = 0; lsmin = lemin = 1LL << 40;
    last = now;
  }
}

static int trx_usrp_write(openair0_device *device,'''
anchor = "\nstatic int trx_usrp_write(openair0_device *device,"
assert s.count(anchor) == 1, "write anchor"
s = s.replace(anchor, helper, 1)

old = """    else {
      ret = (int)s->tx_stream->send(&(((int16_t *)buff_tx[0])[0]), nsamps, s->tx_md);
    }

    if (ret != nsamps) LOG_E(HW,"[xmit] tx samples %d != %d\\n",ret,nsamps);
    return ret;"""
new = """    else {
      long long t0 = poc_us();
      long long dev0 = poc_rx_end_ts + (t0 - poc_rx_host_us) * (long long)s->sample_rate / 1000000;
      ret = (int)s->tx_stream->send(&(((int16_t *)buff_tx[0])[0]), nsamps, s->tx_md);
      long long t1 = poc_us();
      long long dev1 = poc_rx_end_ts + (t1 - poc_rx_host_us) * (long long)s->sample_rate / 1000000;
      if (poc_rx_host_us)
        poc_tx_stats(t1 - t0, (timestamp - dev0) * 1000000 / (long long)s->sample_rate,
                     (timestamp + nsamps - dev1) * 1000000 / (long long)s->sample_rate);
    }

    if (ret != nsamps) LOG_E(HW,"[xmit] tx samples %d != %d\\n",ret,nsamps);
    return ret;"""
assert s.count(old) == 1, "send anchor"
s = s.replace(old, new)

old = """  s->rx_count += nsamps;
  s->rx_timestamp = have_first_ts ? first_ts : s->rx_md.time_spec.to_ticks(s->sample_rate);
  *ptimestamp = s->rx_timestamp;"""
new = """  s->rx_count += nsamps;
  s->rx_timestamp = have_first_ts ? first_ts : s->rx_md.time_spec.to_ticks(s->sample_rate);
  *ptimestamp = s->rx_timestamp;
  poc_rx_end_ts = s->rx_timestamp + samples_received; poc_rx_host_us = poc_us();"""
assert s.count(old) == 1, "read anchor"
s = s.replace(old, new)
open(u, "w").write(s)
print("patched")
PY
grep -n "poc_tx_stats\|poc_rx_end_ts =" $U
