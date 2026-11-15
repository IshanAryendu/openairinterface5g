#!/bin/bash
# Idempotent PoC instrumentation (needs slot-timing-patch.sh applied first):
#  "PoC RX lag": how far the RU thread runs behind the radio clock (max - min over 1 s of host time minus the
#               device timestamp of the newest sample read). ~0.1 ms = on time; > TX lead = TX stream starves (U/L).
#  "PoC TX split": time per sidelink TX slot in MAC (scheduler/RLC/PDCP), PHY (encode/modulate) and radio write.
set -e
cd ~/nr-sl-release-poc/oai
python3 - executables/nr-ue.c <<'PY'
import sys
c = sys.argv[1]; t = open(c).read()
if "poc_tx_split" in t:
    print("already patched"); sys.exit(0)
assert "slot_timing_stats" in t, "apply slot-timing-patch.sh first"
BS = chr(92)
helper = '''
// Local PoC instrumentation (tx-profile-patch.sh)
static inline uint64_t poc_us2(void) { struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts); return ts.tv_sec * 1000000ULL + ts.tv_nsec / 1000; }
static void poc_tx_split(bool action, uint64_t mac, uint64_t phy, uint64_t wr)
{
  static uint64_t n, na, msum, mmax, psum, pmax, wsum, wmax, imsum, immax, tot_max, last;
  if (action) {
    na++; msum += mac; psum += phy; wsum += wr;
    if (mac > mmax) mmax = mac;
    if (phy > pmax) pmax = phy;
    if (wr > wmax) wmax = wr;
    if (mac + phy + wr > tot_max) tot_max = mac + phy + wr;
  } else {
    n++; imsum += mac + phy; if (mac + phy > immax) immax = mac + phy;
  }
  uint64_t now = poc_us2();
  if (now - last >= 1000000) {
    if (last)
      LOG_I(PHY, "PoC TX split: %lu tx slots: mac avg %lu max %lu, phy avg %lu max %lu, write avg %lu max %lu, total max %lu us | %lu idle sl slots: avg %lu max %lu us__NL__",
            (unsigned long)na, (unsigned long)(na ? msum / na : 0), (unsigned long)mmax, (unsigned long)(na ? psum / na : 0), (unsigned long)pmax,
            (unsigned long)(na ? wsum / na : 0), (unsigned long)wmax, (unsigned long)tot_max,
            (unsigned long)n, (unsigned long)(n ? imsum / n : 0), (unsigned long)immax);
    n = na = msum = mmax = psum = pmax = wsum = wmax = imsum = immax = tot_max = 0;
    last = now;
  }
}

void processSlotTX(void *arg) {
'''.replace("__NL__", BS + "n")
a = "\nvoid processSlotTX(void *arg) {\n"
assert t.count(a) == 1, "processSlotTX anchor"
t = t.replace(a, helper, 1)

old = """    sl_tx_action = phy_procedures_nrUE_SL_TX(UE, proc, &phy_data);
"""
new = """    poc_p1 = poc_us2();
    sl_tx_action = phy_procedures_nrUE_SL_TX(UE, proc, &phy_data);
"""
assert t.count(old) == 1, "sl tx anchor"
t = t.replace(old, new)
old = """  bool sl_tx_action = false;
"""
new = """  bool sl_tx_action = false;
  uint64_t poc_p0 = poc_us2(), poc_p1 = poc_p0;
"""
assert t.count(old) == 1, "p0 anchor"
t = t.replace(old, new)
old = """  RU_write(rxtxD, sl_tx_action);
}
"""
new = """  uint64_t poc_p2 = poc_us2();
  RU_write(rxtxD, sl_tx_action);
  if (proc->tx_slot_type == NR_SIDELINK_SLOT)
    poc_tx_split(sl_tx_action, poc_p1 - poc_p0, poc_p2 - poc_p1, poc_us2() - poc_p2);
}
"""
assert t.count(old) == 1, "RU_write anchor"
t = t.replace(old, new)

# RX lag
helper2 = '''
// Local PoC instrumentation (tx-profile-patch.sh): RU thread backlog relative to the radio clock
static void poc_rx_lag(uint64_t host_us, int64_t dev_ticks, int samples_per_subframe)
{
  static int64_t dmin = INT64_MAX, dmax = INT64_MIN, last, n05, n10, n20, n;
  int64_t d = (int64_t)host_us - dev_ticks * 1000 / samples_per_subframe;   // us, arbitrary constant offset
  if (d < dmin) dmin = d;
  if (d > dmax) dmax = d;
  n++;
  if (d - dmin > 500) n05++;
  if (d - dmin > 1000) n10++;
  if (d - dmin > 2000) n20++;
  if ((int64_t)host_us - last >= 1000000) {
    if (last)
      LOG_I(PHY, "PoC RX lag: max %ld us behind the radio clock; slots >0.5ms %ld >1ms %ld >2ms %ld of %ld__NL__",
            (long)(dmax - dmin), (long)n05, (long)n10, (long)n20, (long)n);
    dmin = INT64_MAX; dmax = INT64_MIN; n = n05 = n10 = n20 = 0;
    last = host_us;
  }
}

void *UE_RU_thread(void *arg)'''.replace("__NL__", BS + "n")
a = "\nvoid *UE_RU_thread(void *arg)"
assert t.count(a) == 1
t = t.replace(a, helper2, 1)
old = """            uint64_t t1 = poc_now_us();
            UE_processing(UE, &curMsgSl, readBlockSizeSl, writeBlockSizeSl, writeTimestampSl, &txFifoSl, PC5);"""
new = """            uint64_t t1 = poc_now_us();
            poc_rx_lag(t1, (int64_t)timestampSl + readBlockSizeSl, UE->SL_UE_PHY_PARAMS.sl_frame_params.samples_per_subframe);
            UE_processing(UE, &curMsgSl, readBlockSizeSl, writeBlockSizeSl, writeTimestampSl, &txFifoSl, PC5);"""
assert t.count(old) == 1, "loop anchor"
t = t.replace(old, new)
open(c, "w").write(t)
print("patched")
PY
grep -n "poc_tx_split\|poc_rx_lag" executables/nr-ue.c | head
