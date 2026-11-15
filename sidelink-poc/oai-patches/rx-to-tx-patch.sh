#!/bin/bash
# Idempotent PoC patch: make the RX->TX slot offset (DURATION_RX_TO_TX, compiled in as 4 slots = 2 ms) a runtime
# setting: env SL_RX_TO_TX=4..12 (default 4 = original behaviour).
#
# Problem: a TX slot must reach the B210 within (offset-1) slots of the RX read returning, minus USB latency.
# With offset 4 that is ~1.5 ms; building a PSSCH slot on the Jetson takes up to ~1.1 ms, so many bursts arrive
# after their timestamp (UHD "L"/"U") and are dropped/truncated on air.
#
# BOTH peers must use the same value: the SLSCH sender predicts the PSFCH feedback slot from it and the
# receiver schedules its PSFCH/CSI report from it.
#
# Done as a local override in the 4 .c files that use the macro, so impl_defs_top.h (and a full rebuild) is untouched.
set -e
cd ~/nr-sl-release-poc/oai
cat > executables/poc_rx_to_tx.h <<'H'
// Local PoC patch (rx-to-tx-patch.sh): runtime RX->TX slot offset, env SL_RX_TO_TX (4..12, default 4).
#ifndef POC_RX_TO_TX_H
#define POC_RX_TO_TX_H
#include <stdlib.h>
static inline int poc_rx_to_tx(void)
{
  static int v = 0;
  if (v == 0) {
    const char *e = getenv("SL_RX_TO_TX");
    int x = e ? atoi(e) : 4;
    v = (x < 4 || x > 12) ? 4 : x;
  }
  return v;
}
#undef DURATION_RX_TO_TX
#define DURATION_RX_TO_TX (poc_rx_to_tx())
// get_feedback_slot() is a lookup table keyed on (PSSCH slot + 4), hard-coded for the 6DL/4UL sidelink TDD pattern.
// The PSFCH slot does not depend on the RX->TX offset, so the key keeps the original constant.
#define POC_PSFCH_TABLE_OFFSET 4
#endif
H
python3 - <<'PY'
files = {
 "executables/nr-ue.c": '#include "LAYER2/nr_pdcp/nr_pdcp_oai_api.h"\n',
 "openair2/LAYER2/NR_MAC_UE/nr_ue_scheduler.c": '#include "LAYER2/RLC/rlc.h"\n',
 "openair2/LAYER2/NR_MAC_UE/nr_ue_procedures.c": '#include "common/utils/LOG/vcd_signal_dumper.h"\n',
 "openair2/LAYER2/NR_MAC_UE/nr_ue_procedures_sl.c": '#include "executables/nr-uesoftmodem.h"\n',
}
inc = '#include "executables/poc_rx_to_tx.h"\n'
for f, anchor in files.items():
    t = open(f).read()
    if "poc_rx_to_tx.h" in t:
        print("already patched:", f); continue
    i = t.rfind(anchor)
    assert i >= 0 and t.count(anchor) == 1, "anchor " + f
    assert t.find("DURATION_RX_TO_TX", 0, i) < 0 or f.endswith("nr-ue.c"), "use before include " + f
    t = t[:i + len(anchor)] + inc + t[i + len(anchor):]
    open(f, "w").write(t)
    print("patched:", f)
# one-time startup log in the RU thread
f = "executables/nr-ue.c"
t = open(f).read()
if "PoC patch: RX->TX offset" not in t:
    a = "void *UE_RU_thread(void *arg)\n{\n"
    assert t.count(a) == 1, "RU thread anchor"
    t = t.replace(a, a + '  LOG_I(PHY, "PoC patch: RX->TX offset %d slots (SL_RX_TO_TX)\\n", DURATION_RX_TO_TX);\n')
    open(f, "w").write(t)
    print("log added")
PY
grep -n "poc_rx_to_tx.h\|RX->TX offset" executables/nr-ue.c openair2/LAYER2/NR_MAC_UE/nr_ue_scheduler.c openair2/LAYER2/NR_MAC_UE/nr_ue_procedures.c openair2/LAYER2/NR_MAC_UE/nr_ue_procedures_sl.c
# PSFCH feedback-slot table is keyed on (PSSCH slot + 4): keep that key constant at both call sites.
python3 - <<'PY'
import re
f = "openair2/LAYER2/NR_MAC_UE/nr_ue_scheduler.c"
t = open(f).read()
old = """      int rcv_tx_frame = (frame + ((slot + DURATION_RX_TO_TX) / nr_slots_frame)) % 1024;
      int rcv_tx_slot = (slot + DURATION_RX_TO_TX) % nr_slots_frame;
      int psfch_slot = get_feedback_slot(psfch_period, rcv_tx_slot);"""
if old in t:
    assert t.count(old) == 1
    open(f, "w").write(t.replace(old, old.replace("DURATION_RX_TO_TX", "POC_PSFCH_TABLE_OFFSET")))
    print("psfch key fixed:", f)
else:
    assert "slot + POC_PSFCH_TABLE_OFFSET) % nr_slots_frame" in t, "scheduler anchor"; print("psfch key already fixed:", f)
f = "openair2/LAYER2/NR_MAC_UE/nr_ue_procedures_sl.c"
t = open(f).read()
old = """  int scs = get_softmodem_params()->numerology;
  uint16_t tx_slot = (rx_ind->slot + DURATION_RX_TO_TX) % nr_slots_per_frame[scs];
  uint16_t tx_frame = (rx_ind->sfn + (rx_ind->slot + DURATION_RX_TO_TX) / nr_slots_per_frame[scs]) % 1024;

  uint8_t ack_nack = (rx_ind->rx_indication_body + pdu_id)->rx_slsch_pdu.ack_nack;"""
if old in t:
    assert t.count(old) == 1
    open(f, "w").write(t.replace(old, old.replace("DURATION_RX_TO_TX", "POC_PSFCH_TABLE_OFFSET")))
    print("psfch key fixed:", f)
else:
    assert "rx_ind->slot + POC_PSFCH_TABLE_OFFSET) % nr_slots_per_frame" in t, "procedures_sl anchor"; print("psfch key already fixed:", f)
PY
grep -n "POC_PSFCH_TABLE_OFFSET" openair2/LAYER2/NR_MAC_UE/nr_ue_scheduler.c openair2/LAYER2/NR_MAC_UE/nr_ue_procedures_sl.c
# launcher plumbing: settings.conf RX_TO_TX -> supervisor SL_RX_TO_TX -> modem environment
R=~/nr-sl-release-poc/scripts/sl-run.sh
grep -q SL_RX_TO_TX $R || sed -i 's|SL_TX_INLINE="${SL_TX_INLINE:-1}" |SL_TX_INLINE="${SL_TX_INLINE:-1}" SL_RX_TO_TX="${SL_RX_TO_TX:-4}" |' $R
V=~/Desktop/sidelink/supervisor.sh
grep -q SL_RX_TO_TX $V || sed -i 's|SL_CPUS="$MODEM_CPUS" |SL_CPUS="$MODEM_CPUS" SL_RX_TO_TX="${RX_TO_TX:-4}" |' $V
C=~/Desktop/sidelink/settings.conf
grep -q '^RX_TO_TX=' $C || echo 'RX_TO_TX=4             # RX->TX slot offset (4..8). MUST be identical on both machines. 4 = OAI default; 6 gives the Jetson 1 ms more TX headroom.' >> $C
grep -n "SL_RX_TO_TX" $R $V; grep -n "^RX_TO_TX" $C
