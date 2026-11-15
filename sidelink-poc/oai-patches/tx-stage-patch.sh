#!/bin/bash
# Idempotent PoC instrumentation: once per second log where phy_procedures_nrUE_SL_TX spends its time for
# PSCCH/PSSCH slots: clear = zero the frequency-domain buffer, sci1 = PSCCH, ulsch = PSSCH encode/modulate/map,
# extra = CSI-RS/PSFCH, ofdm = phase rotation + IFFT + cyclic prefix.
set -e
cd ~/nr-sl-release-poc/oai
python3 - openair1/SCHED_NR_UE/phy_procedures_nr_ue_sl.c <<'PY'
import sys
c = sys.argv[1]; t = open(c).read()
if "poc_tx_stages" in t:
    print("already patched"); sys.exit(0)
NL = chr(92) + "n"
helper = '''// Local PoC instrumentation (tx-stage-patch.sh)
#include <time.h>
static inline uint64_t poc_us3(void) { struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts); return ts.tv_sec * 1000000ULL + ts.tv_nsec / 1000; }
static void poc_tx_stages(uint64_t a, uint64_t b, uint64_t c, uint64_t d, uint64_t e)
{
  static uint64_t n, sa, sb, sc, sd, se, mc, me, last;
  n++; sa += a; sb += b; sc += c; sd += d; se += e;
  if (c > mc) mc = c;
  if (e > me) me = e;
  uint64_t now = poc_us3();
  if (now - last >= 1000000) {
    if (last)
      LOG_I(PHY, "PoC TX stages: %lu pssch slots: clear %lu, sci1 %lu, ulsch %lu (max %lu), extra %lu, ofdm %lu (max %lu) us avg__NL__",
            (unsigned long)n, (unsigned long)(sa / n), (unsigned long)(sb / n), (unsigned long)(sc / n), (unsigned long)mc,
            (unsigned long)(sd / n), (unsigned long)(se / n), (unsigned long)me);
    n = sa = sb = sc = sd = se = mc = me = 0;
    last = now;
  }
}

bool phy_procedures_nrUE_SL_TX(PHY_VARS_NR_UE *ue,'''.replace("__NL__", NL)
a = "bool phy_procedures_nrUE_SL_TX(PHY_VARS_NR_UE *ue,"
assert t.count(a) == 1, "func anchor"
t = t.replace(a, helper, 1)
def ins(anchor, new, after=False):
    global t
    assert t.count(anchor) == 1, "anchor: " + anchor
    t = t.replace(anchor, (anchor + new) if after else (new + anchor))
ins("  memset(txdataF_buf, 0, sizeof(txdataF_buf));\n", "  uint64_t poc_q0 = poc_us3();\n")
ins("  memset(txdataF_buf, 0, sizeof(txdataF_buf));\n", "  uint64_t poc_q1 = poc_us3(), poc_q2 = poc_q1, poc_q3 = poc_q1; bool poc_pssch = false;\n", after=True)
ins("    csi_params->scramb_id = phy_data->pscch_Nid % (1 << 10);\n", "    poc_q2 = poc_us3(); poc_pssch = true;\n")
ins("    sl_phy_params->pscch.num_pscch_tx ++;\n", "    poc_q3 = poc_us3();\n")
ins('    LOG_D(NR_PHY, "Sending SL data ' + NL + '");\n', "    poc_q4 = poc_us3();\n")
ins("  if (tx_action) {\n", "  uint64_t poc_q4 = poc_us3();\n")
ins('  LOG_D(NR_PHY, "****** end Sidelink TX-Chain', "  if (poc_pssch) poc_tx_stages(poc_q1 - poc_q0, poc_q2 - poc_q1, poc_q3 - poc_q2, poc_q4 - poc_q3, poc_us3() - poc_q4);\n")
open(c, "w").write(t)
print("patched")
PY
grep -n "poc_q[0-9] = \|poc_tx_stages(" openair1/SCHED_NR_UE/phy_procedures_nr_ue_sl.c | cut -c1-150
