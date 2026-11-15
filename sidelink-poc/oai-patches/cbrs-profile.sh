#!/bin/bash
# Idempotent: add a "cbrs" frequency profile (CBRS band n48, carrier centre 3625.02 MHz, 51 PRB / 30 kHz)
# to the sidelink kit and allow band n48 in the OAI sidelink config check.
#   PointA  ARFCN 641056 = 3000 MHz + (641056-600000) x 15 kHz = 3615.84 MHz
#   SL-SSB  ARFCN 641658 = PointA + 301 REs x 30 kHz           = 3624.87 MHz   (same offset as the other profiles)
#   centre  = PointA + 51 PRB x 12 x 30 kHz / 2                = 3625.02 MHz
set -e
POC=~/nr-sl-release-poc; KIT=~/Desktop/sidelink
for r in a b; do
  python3 - "$POC/config/$r-20mhz.conf" "$POC/config/$r-cbrs.conf" <<'PY'
import sys
t = open(sys.argv[1]).read()
for old, new in [("        sl_absoluteFrequencySSB             = 516990;", "        sl_absoluteFrequencySSB             = 641658;"),
                 ("        sl_absoluteFrequencyPointA          = 515184;", "        sl_absoluteFrequencyPointA          = 641056;"),
                 ("# this is 2584.95 MHz => 301 REs from PointA 25 PRBs + 1 RE", "# cbrs (n48): 3624.87 MHz (ARFCN 600000 + (f-3000 MHz)/15 kHz), same 301-RE offset from PointA"),
                 ("# this is 2575.92 MHz (center frequency is 2585.1 MHz", "# cbrs (n48): 3615.84 MHz PointA, carrier center 3625.02 MHz (51 PRB x 30 kHz)")]:
    assert t.count(old) == 1, old
    t = t.replace(old, new)
open(sys.argv[2], "w").write(t)
PY
done
grep -n "sl_absoluteFrequency" $POC/config/a-cbrs.conf $POC/config/b-cbrs.conf
# OAI: accept band n48 for sidelink
python3 - "$POC/oai/openair2/LAYER2/NR_MAC_UE/config_ue_sl.c" <<'PY'
import sys
f = sys.argv[1]; t = open(f).read()
if "sl_band = 48" in t:
    print("band check already patched")
else:
    old = """  else if (pointA_ARFCN >= 514000 && pointA_ARFCN <= 524000)
    sl_band = 38;
"""
    new = old + """  else if (pointA_ARFCN >= 636668 && pointA_ARFCN <= 646666) // Local PoC patch (cbrs-profile.sh): CBRS n48, 3550-3700 MHz
    sl_band = 48;
"""
    assert t.count(old) == 1, "band anchor"
    open(f, "w").write(t.replace(old, new)); print("band check patched")
PY
# kit plumbing
R=$POC/scripts/sl-run.sh
grep -q "20mhz|n47|cbrs" $R || sed -i 's/case "$PROFILE" in 20mhz|n47) ;;/case "$PROFILE" in 20mhz|n47|cbrs) ;;/' $R
grep -q "cbrs (51 PRB" $R || sed -i 's/^#     profile: 20mhz (default, 51 PRB at 2585.1 MHz) | n47 (51 PRB at 5910 MHz, ITS band) |/#     profile: 20mhz (default, 51 PRB at 2585.1 MHz) | n47 (51 PRB at 5910 MHz, ITS band) | cbrs (51 PRB at 3625 MHz, n48) |/' $R
C=$KIT/common.sh
grep -q "cbrs)" $C || sed -i 's/^    20mhz) echo "2585.1 MHz, band n7\/n38" ;;/    20mhz) echo "2585.1 MHz, band n7\/n38" ;;\n    cbrs)  echo "3625.0 MHz, CBRS band n48 - FARADAY CAGE ONLY" ;;/' $C
F=$KIT/settings.conf
grep -q "cbrs  = 3625" $F || sed -i 's/^#            20mhz = 2585.1 MHz (the authorized over-the-air frequency)./#            20mhz = 2585.1 MHz (the authorized over-the-air frequency).\n#            cbrs  = 3625.0 MHz (CBRS band n48). Only inside the Faraday cage./' $F
sed -i 's/^PROFILE=.*/PROFILE=cbrs/' $F
grep -n "cbrs" $R $C $F | cut -c1-170
grep -ln "20mhz\|n47" $KIT/*.sh | tr "\n" " "; echo
