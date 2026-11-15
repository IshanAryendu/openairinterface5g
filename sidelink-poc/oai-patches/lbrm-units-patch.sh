#!/bin/bash
# Idempotent PoC patch: the sidelink RECEIVER used the wrong unit for the LDPC "limited buffer" size.
#
# Rate matching reads the coded bits out of a circular buffer of Ncb = min(N, 3*TBS_LBRM/2) bits. The sender
# (nr_ulsch_coding.c) passes TBS_LBRM in bits (57376 for this 51-PRB carrier, so Ncb = N: no limit). The
# sidelink receiver (nr_slsch_procedures() in phy_procedures_nr_ue_sl.c) passed tbslbrm >> 3, i.e. bytes,
# into a field that the decoder reads as bits, so it used Ncb = 10758 bits.
#   - QPSK, first transmission: about 7900 coded bits per block, below 10758: unaffected. That is why
#     MCS 0-9 worked.
#   - 16QAM / 64QAM: about 15800 / 23700 coded bits per block. The receiver wrapped everything after bit
#     10758 back onto the start of the buffer (the information bits). MCS 10 (code rate 0.33) survived that
#     only with a clean signal; MCS 11 and above never decoded - over the air and in the RF simulator.
#   - Retransmissions (redundancy versions 2, 3, 1) of any block whose codeword is longer than 10758 bits
#     (MCS 4 and above) started at the wrong place in the buffer, so they could never be decoded either.
# Fix: pass the value in bits, as the sender and the gNB code do.
set -e
cd ~/nr-sl-release-poc/oai
python3 - <<'PY'
f = "openair1/SCHED_NR_UE/phy_procedures_nr_ue_sl.c"
t = open(f).read()
if "lbrm-units-patch.sh" in t:
    print("already patched:", f)
else:
    old = "  pusch_pdu.maintenance_parms_v3.tbSizeLbrmBytes=slsch_pdu->tbslbrm>>3;\n"
    assert t.count(old) == 1, "anchor"
    new = ("  // Local PoC patch (lbrm-units-patch.sh): despite its name this field is read as BITS by the decoder,\n"
           "  // and the sender uses bits; \">>3\" here made the receiver's circular buffer 8 times too short.\n"
           "  pusch_pdu.maintenance_parms_v3.tbSizeLbrmBytes=slsch_pdu->tbslbrm;\n")
    open(f, "w").write(t.replace(old, new))
    print("patched:", f)
PY
grep -n "lbrm-units-patch.sh" openair1/SCHED_NR_UE/phy_procedures_nr_ue_sl.c
echo "Now rebuild:  cd ~/nr-sl-release-poc/oai/cmake_targets/ran_build/build && ninja nr-uesoftmodem"
