#!/bin/bash
# Idempotent PoC patch: a falsely detected control message must not stop the modem.
#
# Now and then noise passes the SCI check ("DCI false positive" lines in the log are the ones that were
# caught). On 14 Nov 2026 one got through with MCS index 31 and 2 layers: the MAC logged "Invalid MCS index
# 31 for MCS table 0", the PHY computed 0 coded bits and stopped the whole modem with
#   Assertion (G>0) failed!  In nr_slsch_procedures() ... phy_procedures_nr_ue_sl.c
# and the link was down until the supervisors had restarted both sides (about 40 s).
# Fix: such a PSSCH is ignored with a warning. (This kit runs 1 layer; anything else is treated as invalid.)
set -e
cd ~/nr-sl-release-poc/oai
python3 - <<'PY'
import re
f = "openair1/SCHED_NR_UE/phy_procedures_nr_ue_sl.c"
t = open(f).read()
if "sci-sanity-patch.sh" in t:
    print("already patched:", f)
else:
    pat = re.compile(r"  AssertFatal\(G>0,\"G is 0 : rb_size.*?pssch_pdu->num_layers\);\n", re.S)
    assert len(pat.findall(t)) == 1, "assert anchor"
    new = ("  // Local PoC patch (sci-sanity-patch.sh): a falsely detected SCI (impossible MCS / layer count) is ignored\n"
           "  // instead of stopping the modem.\n"
           "  if (G <= 0 || pssch_pdu->num_layers != 1\n"
           "      || (pssch_pdu->mod_order != 2 && pssch_pdu->mod_order != 4 && pssch_pdu->mod_order != 6 && pssch_pdu->mod_order != 8)) {\n"
           "    LOG_W(NR_PHY, \"%d.%d ignoring PSSCH with invalid parameters (Qm %u, layers %u, G %d): false SCI detection\\n\",\n"
           "          frame_rx, slot_rx, pssch_pdu->mod_order, pssch_pdu->num_layers, (int)G);\n"
           "    return 0;\n"
           "  }\n")
    t = pat.sub(lambda m: new, t)
    open(f, "w").write(t)
    print("patched:", f)
PY
grep -n "sci-sanity-patch.sh" openair1/SCHED_NR_UE/phy_procedures_nr_ue_sl.c
echo "Now rebuild:  cd ~/nr-sl-release-poc/oai/cmake_targets/ran_build/build && ninja nr-uesoftmodem"
