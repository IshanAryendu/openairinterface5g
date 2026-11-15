#!/bin/bash
# Idempotent PoC instrumentation: once per second log how the RU thread spends each sidelink slot:
#   wait = time blocked in rfdevice_trx() (radio read; ~0 means we are behind real time)
#   proc = time in UE_processing() (TX build + write when SL_TX_INLINE=1, plus RX dispatch)
# The TX deadline is ~3 slots (1.5 ms) after the read returns, minus USB latency.
set -e
cd ~/nr-sl-release-poc/oai
C=executables/nr-ue.c
python3 - "$C" <<'PY'
import sys
c = sys.argv[1]
t = open(c).read()
if "slot_timing_stats" in t:
    print("already patched"); sys.exit(0)
helper = r'''
// Local PoC instrumentation (slot-timing-patch.sh)
static inline uint64_t poc_now_us(void) { struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts); return ts.tv_sec * 1000000ULL + ts.tv_nsec / 1000; }
static void slot_timing_stats(uint64_t wait_us, uint64_t proc_us)
{
  static uint64_t n, wsum, psum, pmax, wzero, p500, p1000, p1500, last;
  n++; wsum += wait_us; psum += proc_us; if (proc_us > pmax) pmax = proc_us;
  if (wait_us < 20) wzero++;
  if (proc_us > 500) p500++;
  if (proc_us > 1000) p1000++;
  if (proc_us > 1500) p1500++;
  uint64_t now = poc_now_us();
  if (now - last >= 1000000) {
    if (last)
      LOG_I(PHY, "PoC slot timing: %lu slots, wait avg %lu us (behind %lu), proc avg %lu max %lu us, >0.5ms %lu >1ms %lu >1.5ms %lu\n",
            (unsigned long)n, (unsigned long)(wsum / n), (unsigned long)wzero, (unsigned long)(psum / n), (unsigned long)pmax,
            (unsigned long)p500, (unsigned long)p1000, (unsigned long)p1500);
    n = wsum = psum = pmax = wzero = p500 = p1000 = p1500 = 0;
    last = now;
  }
}

void *UE_RU_thread(void *arg)'''
anchor = "\nvoid *UE_RU_thread(void *arg)"
assert t.count(anchor) == 1
t = t.replace(anchor, helper, 1)
old = """            update_curMsg(UE, &curMsgSl, absolute_slot, nb_slot_frame, PC5);
            rfdevice_trx(UE, &UE->rfdevice_sl, UE->common_vars.rxdata_sl, slot_nr, &readBlockSizeSl, &writeBlockSizeSl, &timestampSl, &writeTimestampSl, &timing_advance_sl, PC5);
            UE_processing(UE, &curMsgSl, readBlockSizeSl, writeBlockSizeSl, writeTimestampSl, &txFifoSl, PC5);
        }
        break;

      default:"""
new = """            update_curMsg(UE, &curMsgSl, absolute_slot, nb_slot_frame, PC5);
            uint64_t t0 = poc_now_us();
            rfdevice_trx(UE, &UE->rfdevice_sl, UE->common_vars.rxdata_sl, slot_nr, &readBlockSizeSl, &writeBlockSizeSl, &timestampSl, &writeTimestampSl, &timing_advance_sl, PC5);
            uint64_t t1 = poc_now_us();
            UE_processing(UE, &curMsgSl, readBlockSizeSl, writeBlockSizeSl, writeTimestampSl, &txFifoSl, PC5);
            slot_timing_stats(t1 - t0, poc_now_us() - t1);
        }
        break;

      default:"""
assert t.count(old) == 1, "loop anchor"
t = t.replace(old, new)
open(c, "w").write(t)
print("patched")
PY
grep -n "slot_timing_stats" $C
