#!/bin/bash
# Idempotent PoC patch: --sl-max-mcs <n> hard-caps the sidelink PSSCH MCS after CQI/BLER link adaptation.
set -e
cd ~/nr-sl-release-poc/oai
H=executables/nr-uesoftmodem.h; C=openair2/LAYER2/NR_MAC_UE/nr_slsch_scheduler.c
python3 - "$H" "$C" <<'PY'
import sys
BS = chr(92)
h, c = sys.argv[1], sys.argv[2]
lines = [l for l in open(h).read().split("\n") if '"sl-max-mcs"' not in l]   # drop any earlier attempt
opt = ('  {"sl-max-mcs",                   "PoC patch: hard cap on sidelink PSSCH MCS after link adaptation' + BS + 'n", 0, '
       '.iptr=&(nrUE_params.sl_max_mcs_cap), .defintval=28, TYPE_INT, 0}, ' + BS)
i = next(k for k, l in enumerate(lines) if '{"sl-ta",' in l)
lines.insert(i + 1, opt)
s = "\n".join(lines)
if "int            sl_max_mcs_cap;" not in s:
    s = s.replace("  int            timing_advance_sl;\n", "  int            timing_advance_sl;\n  int            sl_max_mcs_cap;\n")
open(h, "w").write(s)
t = open(c).read()
if "sl_max_mcs_cap" not in t:
    t = t.replace("  uint16_t sl_max_num_reserve = ",
      "  // Local PoC patch: hard MCS cap. OTA, the PSSCH receiver fails rate matching at MCS >= 19 on this branch\n"
      "  // (while still reporting the TB as correct), so link adaptation must not go there.\n"
      "  if (sched_pssch->mcs > get_nrUE_params()->sl_max_mcs_cap)\n"
      "    sched_pssch->mcs = get_nrUE_params()->sl_max_mcs_cap;\n\n"
      "  uint16_t sl_max_num_reserve = ", 1)
    open(c, "w").write(t)
PY
grep -n "sl-max-mcs\|sl_max_mcs_cap" $H $C
git diff > ~/nr-sl-release-poc/logs/local-patch-usrp.patch; git diff | sha256sum
